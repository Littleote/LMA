const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const lma = @import("lma");
const float = lma.pipeline.float;
const zlm = @import("zlm").as(float);
const args = @import("args");
const utils = @import("utils.zig");
const Args = @import("Args.zig");
const mapping = @import("map.zig");

pub fn main() !void {
    const BackingAllocator = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void;
    var allocator: BackingAllocator = if (builtin.mode == .Debug) .init else {};
    defer if (builtin.mode == .Debug) {
        _ = allocator.deinit();
    };
    const gpa = if (builtin.mode == .Debug) allocator.allocator() else std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(gpa);

    const parsed: Args = try .parseArgs(gpa);
    defer parsed.deinit(gpa);
    try run(gpa, threaded.io(), parsed);
}

export fn callHoles(parsed: Args.ExternArgs) callconv(.c) ?[*:0]const u8 {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa);
    const io = threaded.io();
    run(gpa, io, parsed.toInner()) catch |err| switch (err) {
        else => |comtpime_err| return @errorName(comtpime_err),
    };
    return null;
}

pub fn run(gpa: Allocator, io: std.Io, parsed: Args) !void {
    const rotation: zlm.Mat3 = blk: {
        var front: zlm.Vec3 = parsed.region.lookAt();
        var side: zlm.Vec3 = .cross(.unitZ, front);
        var up: zlm.Vec3 = .cross(front, side);

        up = up.scale(1 / up.length());
        side = side.scale(1 / side.length());
        front = front.scale(1 / front.length());

        // NOTE: zlm only has v * M not M * v so we write the transpose
        break :blk .{ .fields = .{
            .{ front.x, front.y, front.z },
            .{ side.x, side.y, side.z },
            .{ up.x, up.y, up.z },
        } };
    };

    const info = parsed.region.generateInfo(parsed.detail, &rotation);

    const snap = 60 * 1 * 1;
    const decay: f32 = @floatCast(std.math.pow(f64, 0.5, @as(f64, @floatFromInt(snap)) / (60.0 * parsed.half_life)));
    const freq = 40.0 / (1 - decay) / parsed.luminosity;
    const area = info.step.x * info.step.y;
    const scale = 1 / (freq * area);

    // Input directory
    std.debug.assert(parsed.format.file == .bin and parsed.format.stage == .clusters);
    var input = try std.fs.cwd().openDir(parsed.input, .{});
    defer input.close();

    // Output directories
    var output = try utils.forceOpen(std.fs.cwd(), parsed.output, .{});
    defer output.close();

    // Output directories
    var image_output = try utils.forceOpen(output, "img", .{});
    defer image_output.close();

    var gen = try parsed.generator(gpa, io);
    defer {
        gen.deinit();
        gpa.destroy(gen);
    }

    // Load fixed map
    const canvas = try gpa.alloc(u8, info.shape.size);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    if (parsed.map) |map| {
        const in_file = try std.fs.cwd().openFile(map, .{ .mode = .read_only });
        var file_reader = in_file.reader(io, &.{});
        try mapping.load(gpa, &.{ .rotation = rotation, .info = info, .color = 255 }, canvas, &file_reader.interface);
    }

    try makeImages(
        gpa,
        .{
            .rotation = &rotation,
            .info = &info,
            .generator = gen,
            .overlay = canvas,
            .scaling = scale,
            .decay = decay,
            .snap = snap,
        },
        image_output,
    );

    const disposable_buffer = try gpa.alloc(u8, 65535);
    defer gpa.free(disposable_buffer);
    if (parsed.ffmpeg) {
        try ffmpeg(disposable_buffer, "", parsed.output);
        try ffmpeg(disposable_buffer, "s_", parsed.output);
        try ffmpeg(disposable_buffer, "c_", parsed.output);
    }
}

pub const Params = struct {
    rotation: *const zlm.Mat3,
    info: *const lma.pipeline.grid.Info,
    generator: *Args.Generator,
    overlay: []u8,
    scaling: float,
    decay: float,
    snap: usize,
};

pub fn makeImages(
    gpa: Allocator,
    config: Params,
    output: std.fs.Dir,
) !void {
    // Arena allocations
    var arena_alloc: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_alloc.allocator();
    defer arena_alloc.deinit();

    const shape = config.info.shape;

    // Map
    const sources = try arena.alloc(float, shape.size);
    const density = try arena.alloc(float, shape.size);
    // Gaussian arrays to smooth data
    const step_inverse = zlm.Vec2.one.div(config.info.step);
    const conv_h = try arena.alloc(float, @intFromFloat(1 + 2 * @round(step_inverse.x)));
    const conv_v = try arena.alloc(float, @intFromFloat(1 + 2 * @round(step_inverse.x)));
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
    @memset(sources, 0);
    @memset(density, 0);
    @memset(scoring, 0);

    // Calculate the gaussian blurr
    lma.pipeline.grid.update.convolution.gaussian(conv_h, step_inverse.x);
    lma.pipeline.grid.update.convolution.gaussian(conv_v, step_inverse.y);

    // File name buffer
    var name_buffer: [32]u8 = undefined;
    // File reader/writer buffer
    var buffer: [1024]u8 = undefined;

    // Spill seed array
    var seed_index: std.ArrayList(usize) = .empty;
    defer seed_index.deinit(gpa);

    while (try config.generator.next(config.rotation)) |points| {
        lma.pipeline.grid.update.triangular(shape, config.info, sources, points, .{ .scaling = config.scaling });
        if (@mod(config.generator.epoch, config.snap) == 0) {
            @memcpy(density, sources);
            lma.pipeline.grid.update.convolution.call(shape, density, aux, conv_h, conv_v);

            // Generate all hole candidates
            lma.pipeline.holes.sort(density, order);
            try lma.pipeline.holes.findSeeds(gpa, shape, density, &seed_index);
            const seed: lma.pipeline.holes.Seed = .init(seed_index.items, null);
            var spill: lma.pipeline.holes.Spill = .init(gpa, shape, .{
                .relative = 1.2,
                .absolute = 0.05,
            });
            const size = try spill.assign(&seed, order, density, map);
            const info = try gpa.alloc(lma.pipeline.holes.Info, size);
            const range: lma.pipeline.holes.ranges.Scaled = .{ .min = 0.1, .low = 2, .high = 4 };
            lma.pipeline.holes.generateInfo(shape, range, seed_index.items, info, density, map);
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
                    percent.* = lma.common.cast(float, total) / lma.common.cast(float, cluster.contour);
                    const expected = lma.common.cast(float, i + 15) / 60.0;
                    cluster.score = factor * cluster.score + @as(float, if (percent.* < expected) 1.0 else 0.0);
                }
                cluster.score /= max_definition_score;
                cluster.score *= std.math.clamp(1.5 - 4 * cluster.lowest, 0.2, 1);
                cluster.score *= std.math.clamp(lma.common.cast(float, cluster.area) / 10.0, 0.2, 1);
            }

            // Add scores to running window
            scores.setupNext(scoring);
            for (scores.get(), map) |*in, update| {
                in.* += info[update.int()].score / lma.common.cast(float, scores.size);
            }
            lma.pipeline.grid.update.morph(shape, scores.get(), aux, .init(3, 3), .dilate);
            scores.apply(scoring);

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
            for (density, image, config.overlay, contour, scoring_threshold) |in, *out, over, c, b| {
                out.* = if (c > b) 252 else if (over != 0) over else @intFromFloat(@min(@round(251.0 * in), 251.0));
            }

            const time = @divFloor(config.generator.epoch, config.snap);
            try save(
                output,
                std.fmt.bufPrint(&name_buffer, "{d}.bmp", .{time}) catch unreachable,
                &buffer,
                shape,
                float,
                density,
                &lma.pipeline.image.palettes.viridis,
            );
            try save(
                output,
                std.fmt.bufPrint(&name_buffer, "c_{d}.bmp", .{time}) catch unreachable,
                &buffer,
                shape,
                u16,
                @ptrCast(map),
                &lma.pipeline.image.palettes.viridis,
            );
            try save(
                output,
                std.fmt.bufPrint(&name_buffer, "s_{d}.bmp", .{time}) catch unreachable,
                &buffer,
                shape,
                u8,
                image,
                &lma.pipeline.image.palettes.marked_viridis,
            );
            lma.pipeline.grid.update.decay(shape, sources, config.decay);
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

fn ffmpeg(buffer: []u8, comptime prefix: []const u8, out: []const u8) !void {
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
            "4M",
            prefix ++ "output.mp4",
        },
        .cwd = out,
    });
}
