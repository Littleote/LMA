const std = @import("std");

const root = @import("main.zig");
const cli = @import("cli.zig");

const lma = @import("lma");
const math = lma.math(ToaSolver.Float);
const match = lma.pipeline.match;
const network = lma.constants.network;

const ToaSolver = lma.pipeline.ToaSolver;
const Signal = lma.data.Signal;
const Point = lma.data.Point;
const Float = match.Float;

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    stations: []math.Vec,
    signals: []const Signal.List,
    config: cli.Options.Config,
    span: lma.index.SubSlice,
) RunError!RunReturn {
    // Verbose timing start total and per process
    const timer_start: std.Io.Timestamp = .now(io, .real);
    const resource_start: std.Io.Timestamp = .now(io, .cpu_process);

    const workers: u32 = @max(1, @divFloor(span.size + config.chunk.seconds / 2, config.chunk.seconds));
    const work: u32 = @divCeil(span.size, workers);

    const futures = try gpa.alloc(std.Io.Future(RunError!RunReturn), workers);
    defer gpa.free(futures);
    const outputs = try gpa.alloc(Point.List, workers);
    defer gpa.free(outputs);
    var statistics: ToaSolver.Statistics = .{};
    for (0..workers) |worker| {
        const work_start: u32 = span.start + lma.cast.as(u32, worker) * work;
        futures[worker] = io.async(runChunk, .{
            io,
            gpa,
            stations,
            signals,
            config,
            .initRange(work_start, @min(work_start + work, span.end())),
        });
    }
    defer for (futures) |*future| {
        var result = future.cancel(io) catch continue;
        result.points.deinit();
    };
    var output: Point.List = join: {
        for (futures, outputs) |*in, *out| {
            const results = try in.await(io);
            out.* = results.points;
            statistics.add(&results.stats);
        }
        break :join Point.List.concatenate(outputs, gpa) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            error.OverlappingHeader => unreachable,
        };
    };
    errdefer output.deinit();

    output.epochApplyShift({}, sortSegment) catch unreachable;
    try output.epochApplyShift({}, shiftBack);
    output.epochApplyShift({}, sortSegment) catch unreachable;

    if (config.verbose) {
        std.debug.print("{f}", .{statistics});
        const timer_end: std.Io.Timestamp = .now(io, .real);
        const resource_end: std.Io.Timestamp = .now(io, .cpu_process);
        std.debug.print("Wall time: {d}s\n", .{lma.cast.to(f64, std.Io.Timestamp.durationTo(timer_start, timer_end).toNanoseconds()) / std.time.ns_per_s});
        std.debug.print("Process time: {d}s\n", .{lma.cast.to(f64, std.Io.Timestamp.durationTo(resource_start, resource_end).toNanoseconds()) / std.time.ns_per_s});
    }

    return .{ .points = output, .stats = statistics };
}

const RunError = error{ Canceled, OutOfMemory };
const RunReturn = struct {
    points: Point.List,
    stats: ToaSolver.Statistics,
};

pub fn runChunk(
    io: std.Io,
    gpa: std.mem.Allocator,
    stations: []math.Vec,
    full_signals: []const Signal.List,
    config: cli.Options.Config,
    span: lma.index.SubSlice,
) RunError!RunReturn {
    const count: u32 = @intCast(stations.len);
    const shape: lma.grid.Shape = .init(count, count);

    // Calculate distance and time matrix
    const matrix_size: u16 = @as(u16, network.max_network) * @as(u16, network.max_network);
    var distance_matrix_buffer: [matrix_size]Float = undefined;
    const distance_matrix: []Float = distance_matrix_buffer[0..shape.size];
    var time_matrix_buffer: [matrix_size]u32 = undefined;
    const time_matrix: []u32 = time_matrix_buffer[0..shape.size];
    for (stations, 0..) |station1, row| {
        for (stations, 0..) |station2, col| {
            distance_matrix[shape.ravel(row, col)] = @floatCast(math.vector.norm2(station1 - station2));
            time_matrix[shape.ravel(row, col)] = lma.nano.toNano(distance_matrix[shape.ravel(row, col)] / lma.constants.c);
        }
    }

    // Prepare output signal
    var output: Point.List = .init(gpa);
    output.start_epoch = span.start;
    errdefer output.deinit();

    // Stack allocate buffer for all signals data
    var signal_buffer: [network.max_network][]const Signal = @splat(&.{});
    const signals: [][]const Signal = signal_buffer[0..count];

    var weight_arrays: [network.max_network]std.ArrayList(Float) = @splat(.empty);
    defer for (&weight_arrays) |*weight_array| weight_array.deinit(gpa);
    var weight_buffer: [network.max_network][]Float = @splat(&.{});
    const weights: [][]Float = weight_buffer[0..count];

    // Stack and heap allocate cross-correlation buffer
    const step: match.Step = comptime .fromStep(0.000_004_000);
    var corr_size: usize = 0;
    for (0..count) |row| {
        if (full_signals[row].empty()) continue;
        for (0..row) |col| {
            if (full_signals[col].empty()) continue;
            const dist = distance_matrix[shape.ravel(row, col)];
            corr_size += 2 * root.correlation_size(dist, step);
        }
    }

    var aux_corr_buffer: [root.correlation_size(root.max_distance, step)]Float = undefined;
    var corr_matrix_buffer: [matrix_size]lma.index.SubSlice = @splat(.init(0, 0));
    const corr_matrix: []lma.index.SubSlice = corr_matrix_buffer[0..shape.size];
    const corr_buffer = try gpa.alloc(Float, corr_size);
    defer gpa.free(corr_buffer);

    var corr_start: u32 = 0;
    for (0..count) |row| {
        if (full_signals[row].empty()) continue;
        for (0..row) |col| {
            if (full_signals[col].empty()) continue;
            const dist = distance_matrix[shape.ravel(row, col)];
            const size = root.correlation_size(dist, step);
            corr_matrix_buffer[shape.ravel(row, col)] = .init(corr_start, size);
            corr_start += size;
            corr_matrix_buffer[shape.ravel(col, row)] = .init(corr_start, size);
            corr_start += size;
        }
    }

    var sources: std.ArrayList(Point) = .empty;
    defer sources.deinit(gpa);

    const work_buffer = try gpa.alloc(
        Float,
        @max(
            (network.max_network * root.max_matches + network.max_consensus) * config.search.beam_width * 2,
            network.max_network * root.max_matches * network.max_consensus,
        ),
    );
    defer gpa.free(work_buffer);

    const memory_buffer = try gpa.alloc(
        ToaSolver.Source,
        config.search.memory,
    );
    defer gpa.free(memory_buffer);

    var solver: ToaSolver = .init(
        stations,
        memory_buffer,
        work_buffer,
        .{
            .beam_search = if (config.search.beam_width == 0) null else .{
                .loglikelihood = @log(config.search.probability),
                .width = config.search.beam_width,
                .consensus = config.search.consensus,
            },
            .depth_first_search = if (config.search.dfs_attempts == 0) null else .{
                .loglikelihood = @log(config.search.probability),
                .attempts = config.search.dfs_attempts,
                .consensus = config.search.consensus,
            },
            .probe = null,
        },
    );

    var match_buffers: match.Buffers = try .init(gpa, @intCast(count), root.max_matches);
    defer match_buffers.deinit(gpa);
    var match_corr: match.Correlation = .{
        .step = step,
        .shape = shape,
        .corr_matrix = corr_matrix,
        .time_matrix = time_matrix,
        .corr_buffer = corr_buffer,
        .aux_buffer = &aux_corr_buffer,
        .window_size = lma.nano.toNano(@min(1, 2 * config.correlation.window)),
        .refresh_rate = lma.nano.toNano(config.correlation.window),
    };

    for (span.start..span.end()) |time| {
        try io.checkCancel();
        var size: usize = 0;
        for (full_signals, signals, weight_arrays[0..count], weights) |full_signal, *signal, *weight_array, *weight| {
            signal.* = full_signal.valuesAt(full_signal.epochIndex(time, .exact));
            weight_array.clearRetainingCapacity();
            weight.* = try weight_array.addManyAsSlice(gpa, signal.len);
            config.correlation.weights.calculate(signal.*, weight.*);
            size += signal.len;
        }

        sources.clearRetainingCapacity();
        try sources.ensureTotalCapacity(gpa, size);

        solver.signals = signals;
        if (root.probe_data) |*probe| {
            if (probe.range.start <= time and time < probe.range.end) {
                solver.config.probe = .{ .epoch = time, .list = probe };
            } else solver.config.probe = null;
        }
        for (solver.memory) |*mem| mem.time -= 1;
        sources.items.len = match.process(&match_buffers, &match_corr, signals, weights, sources.allocatedSlice(), &solver);

        try output.headers.append(gpa, .init(@intCast(output.array.items.len), @intCast(sources.items.len)));
        try output.array.appendSlice(gpa, sources.items);
    }

    try io.checkCancel();
    return .{ .points = output, .stats = solver.statistics };
}

fn cutoffTime(time: u32, point: Point) bool {
    return time > point.nanosecond;
}

fn sortSegment(_: void, _: u64, slice: []Point) lma.data.segmented.Shift {
    // Both seem to show roughly the same performance
    // std.sort.block(Point, slice, {}, Point.earlier);
    std.sort.insertion(Point, slice, {}, Point.earlier);
    return .{};
}

fn shiftBack(_: void, _: u64, slice: []Point) lma.data.segmented.Shift {
    const split: u32 = @intCast(std.sort.partitionPoint(Point, slice, root.global_shift, cutoffTime));
    var idx: u32 = 0;
    while (idx < split) : (idx += 1) {
        slice[idx].nanosecond += lma.nano.ratio - root.global_shift;
    }
    while (idx < slice.len) : (idx += 1) {
        slice[idx].nanosecond -= root.global_shift;
    }
    return .{ .backward = split };
}
