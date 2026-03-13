const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const args = @import("args");
const lma = @import("lma");
pub const Float = lma.pipeline.holes.Float;

const Args = @import("Args.zig");
const mapping = @import("map.zig");
const utils = @import("utils.zig");

const zlm = lma.pipeline.zlm(Float);

pub fn main(init: std.process.Init) !void {
    const parsed: Args = try .parseNargs(init.gpa, init.io, init.minimal.args);
    defer parsed.deinit(init.gpa);
    try run(init.gpa, init.io, parsed);
}

export fn callHoles(parsed: Args.ExternArgs) callconv(.c) ?[*:0]const u8 {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = .empty });
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

    const bounds = parsed.region.generateBounds(parsed.detail, &rotation);

    const snap = 60 * 1 * 1;
    const decay: f32 = @floatCast(std.math.pow(f64, 0.5, @as(f64, @floatFromInt(snap)) / (60.0 * parsed.half_life)));
    const freq = 40.0 / (1 - decay) / parsed.luminosity;
    const area_km = bounds.step.x * bounds.step.y / 1_000_000;
    const scale = 1 / (freq * area_km);

    // Input directory
    var input = try std.Io.Dir.cwd().openDir(io, parsed.input, .{});
    defer input.close(io);

    // Output directories
    var output = try utils.forceOpen(io, std.Io.Dir.cwd(), parsed.output, .{});
    defer output.close(io);

    // Output directories
    var image_output = try utils.forceOpen(io, output, "img", .{});
    defer image_output.close(io);

    var gen = try parsed.generator(gpa, io);
    defer {
        gen.deinit();
        gpa.destroy(gen);
    }

    // Load fixed map
    const canvas = try gpa.alloc(u8, bounds.grid.size);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    if (parsed.map) |map| {
        const in_file = try std.Io.Dir.cwd().openFile(io, map, .{ .mode = .read_only });
        defer in_file.close(io);
        var file_reader = in_file.reader(io, &.{});
        try mapping.load(gpa, &.{ .rotation = rotation, .bounds = bounds, .color = 255 }, canvas, &file_reader.interface);
    }

    try makeImages(
        gpa,
        io,
        .{
            .rotation = &rotation,
            .bounds = &bounds,
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
        try ffmpeg(io, disposable_buffer, "", parsed.output);
        try ffmpeg(io, disposable_buffer, "s_", parsed.output);
        try ffmpeg(io, disposable_buffer, "c_", parsed.output);
    }
}

pub const Params = struct {
    rotation: *const zlm.Mat3,
    bounds: *const lma.pipeline.Grid.Bounds(Float),
    generator: *Args.Generator,
    overlay: []u8,
    scaling: Float,
    decay: Float,
    snap: usize,
};

pub fn makeImages(
    gpa: Allocator,
    io: std.Io,
    config: Params,
    output: std.Io.Dir,
) !void {
    // Arena allocations
    var arena_alloc: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_alloc.allocator();
    defer arena_alloc.deinit();

    const grid = config.bounds.grid;

    // Map
    const sources = try arena.alloc(Float, grid.size);
    const density = try arena.alloc(Float, grid.size);
    // Gaussian arrays to smooth data
    const step_km_inverse = zlm.vec2(1_000, 1_000).div(config.bounds.step);
    const conv_h = try arena.alloc(Float, @intFromFloat(1 + 2 * @round(step_km_inverse.x)));
    const conv_v = try arena.alloc(Float, @intFromFloat(1 + 2 * @round(step_km_inverse.x)));
    // Scores running mean buffer and total
    var scores: lma.pipeline.Grid.apply(Float).Window = try .init(arena, grid, 5);
    const scoring = try arena.alloc(Float, grid.size);
    // Scores output contour and generated image
    const threshold = 0.9;
    const scoring_threshold = try arena.alloc(Float, grid.size);
    const contour = try arena.alloc(Float, grid.size);
    const image = try arena.alloc(u8, grid.size);
    // Hole candidates processing order and results
    const order = try lma.pipeline.holes.makeOrderBuffer(arena, grid);
    const map = try arena.alloc(lma.pipeline.holes.Cluster, grid.size);
    // Auxiliary buffers
    const aux = try arena.alloc(Float, grid.size);

    // Zero out top-down Map and total scores
    @memset(sources, 0);
    @memset(density, 0);
    @memset(scoring, 0);

    // Calculate the gaussian blur
    lma.pipeline.Grid.apply(Float).kernel.gaussian(conv_h, step_km_inverse.x);
    lma.pipeline.Grid.apply(Float).kernel.gaussian(conv_v, step_km_inverse.y);

    // File name buffer
    var name_buffer: [32]u8 = undefined;
    // File reader/writer buffer
    var buffer: [1024]u8 = undefined;

    // Spill seed array
    var seed_index: std.ArrayList(usize) = .empty;
    defer seed_index.deinit(gpa);

    while (try config.generator.next(config.rotation)) |points| {
        lma.pipeline.Grid.Bounds(Float).kde(config.bounds, sources, points, .{ .triangular = .{ .scaling = config.scaling } });
        if (@mod(config.generator.epoch, config.snap) == 0) {
            @memcpy(density, sources);
            lma.pipeline.Grid.apply(Float).convolution(grid, density, aux, conv_h, conv_v);

            // Generate all hole candidates
            lma.pipeline.holes.sort(density, order);
            try lma.pipeline.holes.findSeeds(gpa, grid, density, &seed_index);
            const seed: lma.pipeline.holes.Seed = .init(seed_index.items, null);
            var spill: lma.pipeline.holes.Spill = .init(gpa, grid, .{
                .relative = 1.2,
                .absolute = 0.05,
            });
            const size = try spill.assign(&seed, order, density, map);
            const info = try gpa.alloc(lma.pipeline.holes.Info, size);
            const range: lma.pipeline.holes.Info.ranges.Scaled = .{ .min = 0.1, .low = 2, .high = 4 };
            lma.pipeline.holes.Info.generateInfo(grid, range, seed_index.items, info, density, map);
            defer gpa.free(info);

            // Calculate the scores of all clusters
            var def_buffer: [16]Float = undefined;
            info[0].score = 0;
            for (info[1..]) |*cluster| {
                cluster.score = 0;
                if (cluster.escapes) continue;
                const factor = 1.2;
                const max_definition_score = comptime (1 - std.math.pow(Float, factor, 16.0)) / (1 - factor);
                for (cluster.definition, &def_buffer, 0..) |total, *percent, i| {
                    percent.* = lma.cast.to(Float, total) / lma.cast.to(Float, cluster.contour);
                    const expected = lma.cast.to(Float, i + 15) / 60.0;
                    cluster.score = factor * cluster.score + @as(Float, if (percent.* < expected) 1.0 else 0.0);
                }
                cluster.score /= max_definition_score;
                cluster.score *= std.math.clamp(1.5 - 4 * cluster.lowest, 0.2, 1);
                cluster.score *= std.math.clamp(lma.cast.to(Float, cluster.area) / 10.0, 0.2, 1);
            }

            // Add scores to running window
            scores.setupNext(scoring);
            for (scores.get(), map) |*in, update| {
                in.* += info[update.int()].score / lma.cast.to(Float, scores.size);
            }
            lma.pipeline.Grid.apply(Float).morph(grid, scores.get(), aux, .init(3, 3), .dilate);
            scores.apply(scoring);

            // Define lightning holes and their contour
            @memcpy(scoring_threshold, scoring);
            lma.pipeline.Grid.apply(Float).threshold(
                grid,
                scoring_threshold,
                threshold,
                .{ .above = .{ .fixed = 255.0 } },
            );
            @memcpy(contour, scoring_threshold);
            lma.pipeline.Grid.apply(Float).morph(grid, contour, aux, .init(3, 3), .dilate);
            for (density, image, config.overlay, contour, scoring_threshold) |in, *out, over, c, b| {
                out.* = if (c > b) 252 else if (over != 0) over else @intFromFloat(@min(@round(251.0 * in), 251.0));
            }

            const time = @divFloor(config.generator.epoch, config.snap);
            try save(
                io,
                output,
                std.fmt.bufPrint(&name_buffer, "{d}.bmp", .{time}) catch unreachable,
                &buffer,
                grid,
                Float,
                density,
                &lma.pipeline.image.palettes.viridis,
            );
            try save(
                io,
                output,
                std.fmt.bufPrint(&name_buffer, "c_{d}.bmp", .{time}) catch unreachable,
                &buffer,
                grid,
                u16,
                @ptrCast(map),
                &lma.pipeline.image.palettes.viridis,
            );
            try save(
                io,
                output,
                std.fmt.bufPrint(&name_buffer, "s_{d}.bmp", .{time}) catch unreachable,
                &buffer,
                grid,
                u8,
                image,
                &lma.pipeline.image.palettes.marked_viridis,
            );
            lma.pipeline.Grid.apply(Float).scalarOp(grid, sources, .mul, config.decay);
        }
    }
}

fn save(io: std.Io, dir: std.Io.Dir, name: []const u8, buffer: []u8, shape: lma.pipeline.Grid, T: type, values: []const T, palette: *const [256]lma.pipeline.image.Color) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var file_writer = file.writer(io, buffer);
    try switch (@typeInfo(T)) {
        .float => if (T == Float) lma.pipeline.image.floatToBMP(Float, shape, values, palette, &file_writer.interface) else @compileError("Invalid type"),
        .int => if (T == u8) lma.pipeline.image.bytesToBMP(shape, values, palette, &file_writer.interface) else lma.pipeline.image.intToBMP(T, shape, values, palette, &file_writer.interface),
        else => @compileError("Invalid type"),
    };
}

fn ffmpeg(io: std.Io, buffer: []u8, comptime prefix: []const u8, out: []const u8) !void {
    var disposable: std.heap.FixedBufferAllocator = .init(buffer);
    _ = try std.process.run(disposable.allocator(), io, .{
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
        .cwd = .{ .path = out },
    });
}
