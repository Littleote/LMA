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
    const freq = 20.0 / (1 - decay) / options.options.luminosity;
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
        gpa,
        options.options.resolution.shape(),
        .{
            .rotation = &rotation,
            .info = &info,
            .scaling = scale,
            .decay = decay,
        },
        input,
        image_output,
    );

    const disposable_buffer = try gpa.alloc(u8, 65535);
    defer gpa.free(disposable_buffer);
    try ffmpeg(disposable_buffer, "", options.options.gif, options.options.output);
    try ffmpeg(disposable_buffer, "s_", options.options.gif, options.options.output);
    try ffmpeg(disposable_buffer, "c_", options.options.gif, options.options.output);
}

pub const Params = struct {
    rotation: *const zlm.Mat3,
    info: *const lma.pipeline.grid.Info,
    scaling: float,
    decay: float,
};

pub fn makeImages(
    gpa: Allocator,
    shape: lma.pipeline.grid.Shape,
    config: Params,
    input: std.fs.Dir,
    output: std.fs.Dir,
) !void {
    // Arena allocations
    var arena_alloc: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_alloc.allocator();
    defer arena_alloc.deinit();

    // 2D points
    var array: std.ArrayList(zlm.Vec2) = try .initCapacity(arena, 65_535);
    // Map
    const values = try arena.alloc(float, shape.size);
    // Scores running mean buffer and total
    var scores: lma.pipeline.grid.update.Window = try .init(arena, shape, 5);
    const scoring = try arena.alloc(float, shape.size);
    // Scores output contour and generated image
    const threshold = 0.9;
    const scoring_threshold = try arena.alloc(float, shape.size);
    const contour = try arena.alloc(float, shape.size);
    const image = try arena.alloc(u8, shape.size);
    // Hole candidates processing order and results
    const order = try lma.pipeline.holes.makeOrderBuffer(arena, shape);
    const map = try arena.alloc(lma.pipeline.holes.Cluster, shape.size);
    // Auxiliary buffers
    const aux = try arena.alloc(float, shape.size);

    // Zero out top-down Map and total scores
    @memset(values, 0);
    @memset(scoring, 0);

    // File name buffer
    var name_buffer: [32]u8 = undefined;
    // File reader/writer buffer
    var buffer: [1024]u8 = undefined;

    // Spill seed array
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
                    array.appendAssumeCapacity(lma.pipeline.transform.projection(item, config.rotation.*));
                }
            }
            lma.pipeline.grid.update.triangular(shape, config.info, values, array.items, .{ .scaling = config.scaling });
            if (@mod(iterator.epoch, snap) == 0) {

                // Generate all hole candidates
                lma.pipeline.holes.sort(values, order);
                try lma.pipeline.holes.findSeeds(gpa, shape, values, &seed_index);
                const seed: lma.pipeline.holes.Seed = .init(seed_index.items, null);
                var spill: lma.pipeline.holes.Spill = .init(gpa, shape, .{
                    .relative = 1.2,
                    .absolute = 0.05,
                });
                const size = try spill.assign(&seed, order, values, map);
                const info = try gpa.alloc(lma.pipeline.holes.Info, size);
                const range: lma.pipeline.holes.ranges.Scaled = .{ .min = 0.1, .low = 1.5, .high = 3 };
                lma.pipeline.holes.generateInfo(shape, range, seed_index.items, info, values, map);
                defer gpa.free(info);

                // Calculate the scores of all clusters
                var def_buffer: [16]float = undefined;
                info[0].score = 0;
                for (info[1..]) |*cluster| {
                    cluster.score = 0;
                    if (cluster.escapes) continue;
                    const factor = 1.2;
                    const max_definition_score = comptime (1 - std.math.pow(float, factor, 16.0)) / (1 - factor);
                    for (cluster.definition, &def_buffer, 0..) |total, *percent, i| {
                        percent.* = lma.math.cast(float, total) / lma.math.cast(float, cluster.contour);
                        const expected = lma.math.cast(float, i + 15) / 60.0;
                        cluster.score = factor * cluster.score + @as(float, if (percent.* < expected) 1.0 else 0.0);
                    }
                    cluster.score /= max_definition_score;
                    cluster.score *= std.math.clamp(1.5 - 4 * cluster.lowest, 0.2, 1);
                    cluster.score *= std.math.clamp(lma.math.cast(float, cluster.area) / 10.0, 0.2, 1);
                    // if (cluster.score > threshold) {
                    //     std.debug.print("{d}: {any}\n", .{ @divFloor(iterator.epoch, snap), cluster });
                    // }
                }

                // Add scores to running window
                const iter_score = scores.clearNextFrame(scoring);
                for (iter_score, map) |*in, update| {
                    in.* += info[update.int()].score / lma.math.cast(float, scores.size);
                }
                lma.pipeline.grid.update.morph(shape, iter_score, aux, .init(3, 3), .dilate);
                scores.applyFrame(scoring);

                // Define lightning holes and their contour
                @memcpy(scoring_threshold, scoring);
                lma.pipeline.grid.update.threshold(
                    shape,
                    scoring_threshold,
                    threshold,
                    .{ .above = .{ .fixed = 255.0 } },
                );
                @memcpy(contour, scoring_threshold);
                lma.pipeline.grid.update.morph(shape, contour, aux, .init(3, 3), .dilate);
                for (values, image, contour, scoring_threshold) |in, *out, c, b| {
                    out.* = if (c > b) 252 else @intFromFloat(@min(@round(251.0 * in), 251.0));
                }

                try save(
                    output,
                    std.fmt.bufPrint(
                        &name_buffer,
                        "{d}.bmp",
                        .{@divFloor(iterator.epoch, snap)},
                    ) catch unreachable,
                    &buffer,
                    shape,
                    float,
                    values,
                    &lma.pipeline.image.palettes.viridis,
                );
                try save(
                    output,
                    std.fmt.bufPrint(
                        &name_buffer,
                        "c_{d}.bmp",
                        .{@divFloor(iterator.epoch, snap)},
                    ) catch unreachable,
                    &buffer,
                    shape,
                    u16,
                    @ptrCast(map),
                    &lma.pipeline.image.palettes.viridis,
                );
                try save(
                    output,
                    std.fmt.bufPrint(
                        &name_buffer,
                        "s_{d}.bmp",
                        .{@divFloor(iterator.epoch, snap)},
                    ) catch unreachable,
                    &buffer,
                    shape,
                    u8,
                    image,
                    &lma.pipeline.image.palettes.marked_viridis,
                );
                // {
                //     // Store map
                //     const name = std.fmt.bufPrint(
                //         &name_buffer,
                //         "s{d}.bmp",
                //         .{@divFloor(iterator.epoch, snap)},
                //     ) catch unreachable;
                //     const file = try output.createFile(name, .{});
                //     defer file.close();
                //     var file_writer = file.writer(&buffer);
                //     for (scoring_threshold, image) |in, *out| {
                //         out.* = @intFromFloat(std.math.clamp(
                //             @round(in), // 255.0 * (1 - decay) *
                //             0,
                //             255.0,
                //         ));
                //     }
                //     try lma.pipeline.image.toBMP(shape, image, &lma.pipeline.image.palettes.viridis, &file_writer.interface);
                // }
                // {
                //     // Store map
                //     const name = std.fmt.bufPrint(
                //         &name_buffer,
                //         "c{d}.bmp",
                //         .{@divFloor(iterator.epoch, snap)},
                //     ) catch unreachable;
                //     const file = try output.createFile(name, .{});
                //     defer file.close();
                //     var file_writer = file.writer(&buffer);
                //     for (map, image) |in, *out| {
                //         out.* = @intCast(in.int());
                //     }
                //     try lma.pipeline.image.toBMP(shape, image, &lma.pipeline.image.palettes.viridis, &file_writer.interface);
                // }

                // {
                //     // Store map
                //     const name = std.fmt.bufPrint(
                //         &name_buffer,
                //         "{d}.bmp",
                //         .{@divFloor(iterator.epoch, snap)},
                //     ) catch unreachable;
                //     const file = try output.createFile(name, .{});
                //     defer file.close();
                //     var file_writer = file.writer(&buffer);
                //     for (values, image, contour, scoring_threshold) |in, *out, c, b| {
                //         out.* = if (c > b) 252 else @intFromFloat(@min(@round(scale * in), 251.0));
                //     }
                //     try lma.pipeline.image.toBMP(shape, image, &lma.pipeline.image.palettes.marked_heat, &file_writer.interface);
                // }
                lma.pipeline.grid.update.decay(shape, values, config.decay);
            }
        }
    }
}

fn save(dir: std.fs.Dir, name: []const u8, buffer: []u8, shape: lma.pipeline.grid.Shape, T: type, values: []const T, palette: *const [256]lma.pipeline.image.Color) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    var file_writer = file.writer(buffer);
    try switch (@typeInfo(T)) {
        .float => if (T == float) lma.pipeline.image.floatToBMP(shape, values, palette, &file_writer.interface) else @compileError("Invalid type"),
        .int => if (T == u8) lma.pipeline.image.bytesToBMP(shape, values, palette, &file_writer.interface) else lma.pipeline.image.intToBMP(T, shape, values, palette, &file_writer.interface),
        else => @compileError("Invalid type"),
    };
}

fn ffmpeg(buffer: []u8, comptime prefix: []const u8, gif: bool, out: []const u8) !void {
    var disposable: std.heap.FixedBufferAllocator = .init(buffer);
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
            "img/" ++ prefix ++ "%d.bmp",
            "-b:v",
            "2M",
            if (gif) prefix ++ "output.gif" else prefix ++ "output.mp4",
        },
        .cwd = out,
    });
}
