const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const lma = @import("lma");
const float = lma.pipeline.float;
const zlm = @import("zlm").as(float);
const args = @import("args");
const utils = @import("utils.zig");

const Resolution = enum {
    micro,
    low,
    medium,
    high,
    extra,

    pub fn shape(res: Resolution) lma.pipeline.grid.Shape {
        return switch (res) {
            .micro => .init(32, 32),
            .low => .init(255, 255),
            .medium => .init(512, 512),
            .high => .init(1024, 1024),
            .extra => .init(2048, 2048),
        };
    }
};

const step = 60 * 10 * 1;
const count = 1 * 6 * 24;
const snap = 60 * 1 * 1;

pub fn main() !void {
    const BackingAllocator = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void;
    var allocator: BackingAllocator = if (builtin.mode == .Debug) .init else {};
    defer if (builtin.mode == .Debug) {
        _ = allocator.deinit();
    };
    const gpa = if (builtin.mode == .Debug) allocator.allocator() else std.heap.smp_allocator;

    const options = args.parseForCurrentProcess(
        struct {
            input: ?[]const u8 = null,
            output: []const u8 = "img/demo/grid",
            scale: float = 500.0,
            resolution: Resolution = .medium,
            @"half-life": float = 2.5,
            luminosity: float = 1.0,
            gif: bool = false,

            pub const shorthands = .{
                .i = "input",
                .s = "scale",
                .r = "resolution",
                .h = "half-life",
                .l = "luminosity",
            };
        },
        gpa,
        .print,
    ) catch return;
    defer options.deinit();

    // NOTE: Deal with mandatory missing arguments as zig-args can't
    if (options.options.input == null) @panic("Missing input field");
    if (options.positionals.len < 2) @panic("Missing coordinates");

    const lat = std.math.degreesToRadians(
        std.fmt.parseFloat(float, options.positionals[0]) catch @panic("Invalid latitude value"),
    );
    const lon = std.math.degreesToRadians(
        std.fmt.parseFloat(float, options.positionals[1]) catch @panic("Invalid longitude value"),
    );
    const info: lma.pipeline.grid.Info = .scale(options.options.resolution.shape(), .new(options.options.scale, options.options.scale));

    const decay: f32 = @floatCast(std.math.pow(f64, 0.5, @as(f64, @floatFromInt(snap)) / (60.0 * options.options.@"half-life")));
    const freq = 5e-2 / (1 - decay) / options.options.luminosity;
    const area = info.step.dot(.one);
    const scale = 1 / (freq * area);

    const rotation: zlm.Mat3 = blk: {
        const x = @cos(lat) * @sin(lon);
        const y = @sin(lat);
        const z = @cos(lat) * @cos(lon);
        const r = 6371.0088;
        var front: zlm.Vec3 = .new(x, y, z);
        var side: zlm.Vec3 = .cross(.unitY, front);
        var up: zlm.Vec3 = .cross(front, side);

        up = up.scale(r / up.length());
        side = side.scale(r / side.length());
        front = front.scale(r / front.length());

        // NOTE: zlm only has v * M not M * v so we write the transpose
        break :blk .{ .fields = .{
            .{ side.x, side.y, side.z },
            .{ up.x, up.y, up.z },
            .{ front.x, front.y, front.z },
        } };
    };

    // Input directory
    var input = try std.fs.cwd().openDir(options.options.input.?, .{});
    defer input.close();

    // Output directories
    var output = try utils.forceOpen(std.fs.cwd(), options.options.output, .{});
    defer output.close();

    // Output directories
    var image_output = try utils.forceOpen(output, "img", .{});
    defer image_output.close();

    try makeImages(
        options.options.resolution.shape(),
        gpa,
        &rotation,
        &info,
        scale,
        decay,
        input,
        image_output,
    );

    {
        var disposable: std.heap.FixedBufferAllocator = .init(try gpa.alloc(u8, 65535));
        defer gpa.free(disposable.buffer);
        _ = try std.process.Child.run(.{
            .allocator = disposable.allocator(),
            .argv = &.{
                "ffmpeg",
                "-framerate",
                "60",
                "-v",
                "error",
                "-y",
                "-i",
                "img/%d.bmp",
                "-b:v",
                "2M",
                if (options.options.gif) "output.gif" else "output.mp4",
            },
            .cwd = options.options.output,
            .cwd_dir = output,
        });
    }
    {
        var disposable: std.heap.FixedBufferAllocator = .init(try gpa.alloc(u8, 65535));
        defer gpa.free(disposable.buffer);
        _ = try std.process.Child.run(.{
            .allocator = disposable.allocator(),
            .argv = &.{
                "ffmpeg",
                "-framerate",
                "60",
                "-v",
                "error",
                "-y",
                "-i",
                "img/c%d.bmp",
                "-b:v",
                "2M",
                if (options.options.gif) "c_output.gif" else "c_output.mp4",
            },
            .cwd = options.options.output,
            .cwd_dir = output,
        });
    }
}

pub fn makeImages(
    shape: lma.pipeline.grid.Shape,
    gpa: Allocator,
    rotation: *const zlm.Mat3,
    info: *const lma.pipeline.grid.Info,
    scale: float,
    decay: float,
    input: std.fs.Dir,
    output: std.fs.Dir,
) !void {
    var name_buffer: [32]u8 = undefined;
    var buffer: [1024]u8 = undefined;
    var array: std.ArrayList(zlm.Vec2) = try .initCapacity(gpa, 65_535);
    defer array.deinit(gpa);
    const values = try gpa.alloc(float, shape.size);
    defer gpa.free(values);
    @memset(values, 0);
    const order = try lma.pipeline.holes.makeOrderBuffer(gpa, shape);
    defer gpa.free(order);
    const map = try gpa.alloc(lma.pipeline.holes.Cluster, shape.size);
    defer gpa.free(map);
    const image = try gpa.alloc(u8, shape.size);
    defer gpa.free(image);
    var seed_index: std.ArrayList(usize) = .empty;
    defer seed_index.deinit(gpa);

    for (0..count) |idx| {
        const time = idx * step;
        var data: lma.data.Clusters = .init(gpa);
        defer data.deinit();

        {
            // Load chunk
            const name = std.fmt.bufPrint(
                &name_buffer,
                "{d:0>2}h-{d:0>2}min-{d:0>2}s.bin",
                .{
                    @divFloor(time, 60 * 60),
                    @mod(@divFloor(time, 60), 60),
                    @mod(time, 60),
                },
            ) catch unreachable;
            const file = input.openFile(name, .{ .mode = .read_only }) catch {
                std.log.warn("Missing file: {s}.\n", .{name});
                continue;
            };
            defer file.close();
            var file_reader = file.reader(&buffer);
            try data.fromBin(&file_reader.interface);
        }

        var iterator = data.segments.epochIterator(time, .{ .until = time + step });
        while (iterator.next()) |items| {
            array.items.len = 0;
            std.debug.assert(items.len <= array.capacity);
            for (items) |item| {
                if (!item.cluster.isNoise()) {
                    array.appendAssumeCapacity(lma.pipeline.transform.projection(item, rotation.*));
                }
            }
            lma.pipeline.grid.update.triangular(shape, info, values, array.items);
            if (@mod(iterator.epoch, snap) == 0) {
                lma.pipeline.holes.sort(values, order);
                try lma.pipeline.holes.findSeeds(gpa, shape, values, &seed_index);
                const seed: lma.pipeline.holes.Seed = .init(seed_index.items, null);
                var spill: lma.pipeline.holes.Spill = .init(gpa, shape, .{
                    .relative = 1.2,
                    .absolute = 8.0 / scale,
                });
                _ = try spill.assign(&seed, order, values, map);
                {
                    // Store map
                    const name = std.fmt.bufPrint(
                        &name_buffer,
                        "{d}.bmp",
                        .{@divFloor(iterator.epoch, snap)},
                    ) catch unreachable;
                    const file = try output.createFile(name, .{});
                    defer file.close();
                    var file_writer = file.writer(&buffer);
                    for (values, image) |in, *out| {
                        out.* = @intFromFloat(@min(@round(scale * in), 255.0));
                    }
                    try lma.pipeline.image.toBMP(shape, image, &lma.pipeline.image.palettes.viridis, &file_writer.interface);
                }
                {
                    // Store map
                    const name = std.fmt.bufPrint(
                        &name_buffer,
                        "c{d}.bmp",
                        .{@divFloor(iterator.epoch, snap)},
                    ) catch unreachable;
                    const file = try output.createFile(name, .{});
                    defer file.close();
                    var file_writer = file.writer(&buffer);
                    for (map, image) |in, *out| {
                        out.* = @intCast(in.int());
                    }
                    try lma.pipeline.image.toBMP(shape, image, &lma.pipeline.image.palettes.viridis, &file_writer.interface);
                }
                lma.pipeline.grid.update.decay(shape, values, decay);
            }
        }
    }
}
