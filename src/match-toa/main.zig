const std = @import("std");

const lma = @import("lma");
const match = lma.pipeline.match;
const ToaSolver = lma.pipeline.ToaSolver;
const nargs = @import("nargs");

const max_stations = 32;
const root = nargs.groups.any("match", .{
    .weight_mode = nargs.params.param("weights", nargs.types.options(lma.pipeline.match.Weights), .single, .{ .short = .auto, .default = .decibels }),
    .station = nargs.params.param("station", nargs.types.io.File.initDefaults(.open_file), .single, .{ .short = .auto }),
    .input = nargs.params.param("input", nargs.types.io.Glob.init, .single, .{ .short = .auto }),
    .output = nargs.params.param("output", nargs.types.unset(nargs.types.io.File.initDefaults(.create_file)), .single, .{ .short = .auto, .default = @as(?[]u8, null) }),
    .dat_output = nargs.params.param("dat-output", nargs.types.unset(nargs.types.io.File.initDefaults(.create_file)), .single, .{ .short = .auto, .default = @as(?[]u8, null) }),
});

pub const Float = match.Float;
pub const Precise = ToaSolver.Float;
pub const math = lma.math(Precise);

const max_distance = 200_000.0;
const global_shift: u32 = 50_000_000;
const max_matches: usize = @intFromFloat(1 + @ceil(max_distance / lma.constants.c / 0.000_080));
const min_stations: usize = 6;

fn correlation_size(dist: Float, step: match.Step) u32 {
    return 1 + 4 * lma.cast.to(u32, @round(@min(max_distance, dist) / lma.constants.c / step.step));
}

pub fn main(init: std.process.Init) !void {
    const ctx = .{ .allocator = init.gpa, .io = init.io };
    var options: @TypeOf(root).Type = blk: {
        var args: nargs.Args = .init(init.gpa);
        defer args.deinit();
        try args.appendArguments(init.minimal.args);
        break :blk try args.parseAndCreate(init.io, ctx, root);
    };
    defer root.destroy(ctx, &options);

    var buffer: [1024]u8 = undefined;
    const weight_mode: lma.pipeline.match.Weights = options.weight_mode;

    // Load stations
    var stations: lma.data.Stations = .init(init.gpa);
    defer stations.deinit();
    {
        var file_reader = options.station.reader(init.io, &buffer);
        try stations.fromBin(&file_reader.interface);
    }
    const count: u32 = @intCast(stations.stations.items.len);
    // const shape: lma.grid.Shape = .init(count, count);
    if (count > max_stations) @panic("Station limit reached.");

    var shift_buffer: [max_stations]u32 = undefined;
    const shifts: []u32 = shift_buffer[0..count];
    var points_buffer: [max_stations]math.Vec = undefined;
    const points: []math.Vec = points_buffer[0..count];
    for (stations.stations.items, points, shifts) |station, *point, *delay| {
        delay.* = global_shift - @as(u32, @bitCast(station.delay));
        point.* = lma.pipeline.transform.gpsToXYZ(Precise, station.point()).build();
    }

    // Load ToA signals
    var active_stations: usize = 0;
    var full_signal_buffer: [max_stations]lma.data.ToA = @splat(.init(init.gpa));
    const full_signals: []lma.data.ToA = full_signal_buffer[0..count];
    defer for (full_signals) |*signal| signal.deinit();

    var date: ?[6]u8 = null;
    var time: ?[6]u8 = null;

    while (try options.input.next()) |entry| {
        // CODE_GROUP_FULL_NAME_DATE_TIME.dat
        const stem, _ = std.mem.cutScalarLast(u8, entry.basename, '.').?;
        var split = std.mem.splitScalar(u8, stem, '_');
        _, _ = .{ split.next().?, split.next().? };

        var back_split = std.mem.splitBackwardsScalar(u8, split.rest(), '_');
        const file_time, const file_date, const name = .{ back_split.next().?, back_split.next().?, back_split.next().? };

        if (file_date.len != 6 or file_time.len != 6) {
            std.debug.print("Invalid file name: {s}\n", .{entry.basename});
            std.debug.print("Date: {s}, Time: {s}\n", .{ file_date, file_time });
            return error.WrongFormat;
        }
        if (date == null and time == null) {
            date = file_date[0..6].*;
            time = file_time[0..6].*;
        } else {
            if (!std.mem.eql(u8, &date.?, file_date) or !std.mem.eql(u8, &time.?, file_time)) {
                std.debug.print("Invalid file name: {s}\n", .{entry.basename});
                return error.WrongFormat;
            }
        }

        const file = try entry.dir.openFile(init.io, entry.basename, .{});
        defer file.close(init.io);
        var file_reader = file.reader(init.io, &buffer);

        for (stations.stations.items, 0..) |info, idx| {
            if (std.mem.eql(u8, info.name.?, name)) {
                try full_signals[idx].fromBin(&file_reader.interface);
                for (full_signals[idx].array.items) |*toa| {
                    toa.nanosecond += shifts[idx];
                }
                active_stations += 1;
                break;
            }
        }
    }

    if (date == null or time == null) @panic("No toa signal loaded");

    const start_time = blk: {
        const hour = try std.fmt.parseInt(u32, time.?[0..2], 10);
        const minute = try std.fmt.parseInt(u32, time.?[2..4], 10);
        const second = try std.fmt.parseInt(u32, time.?[4..6], 10);
        break :blk (hour * 60 + minute) * 60 + second;
    };

    // Run program asynchronously divided by minutes
    const minutes = 10;
    var futures: [minutes]std.Io.Future(RunError!struct { lma.data.Points, ToaSolver.Counts }) = undefined;
    var counts: ToaSolver.Counts = .{};
    for (0..minutes) |idx| {
        futures[idx] = init.io.async(run, .{ init.io, init.gpa, points, full_signals, weight_mode, .init(@intCast(start_time + idx * 1 * 60), 1 * 60) });
    }
    defer for (&futures) |*future| {
        var output, _ = future.cancel(init.io) catch continue;
        output.deinit();
    };
    var output: lma.data.Points = join: {
        var outputs: [minutes]lma.data.Points = undefined;
        for (&futures, &outputs) |*in, *out| {
            out.*, const future_counts = try in.await(init.io);
            counts.add(&future_counts);
        }
        break :join try .concatenate(&outputs, init.gpa);
    };
    defer output.deinit();

    output.epochApplyShift({}, sortSegment) catch unreachable;
    try output.epochApplyShift({}, shiftBack);
    output.epochApplyShift({}, sortSegment) catch unreachable;

    inline for (comptime std.meta.fieldNames(ToaSolver.Counts)) |field| {
        std.debug.print("Var {s}: {d}\n", .{ field, @field(counts, field) });
    }

    if (options.output) |csv_file| {
        var file_writer = csv_file.writer(init.io, &buffer);
        try output.toCsv(&file_writer.interface, null);
    }
    if (options.dat_output) |dat_file| {
        var file_writer = dat_file.writer(init.io, &buffer);
        try lma.data.dat_file.output.print(&file_writer.interface, &output, &stations);
    }

    std.debug.print("Total points: {d}\n", .{output.array.items.len});
}

const RunError = error{ Canceled, OutOfMemory };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    stations: []math.Vec,
    full_signals: []const lma.data.ToA,
    weight_mode: lma.pipeline.match.Weights,
    span: lma.index.SubSlice,
) RunError!struct { lma.data.Points, ToaSolver.Counts } {
    const count: u32 = @intCast(stations.len);
    const shape: lma.grid.Shape = .init(count, count);

    // Calculate distance and time matrix
    var distance_matrix_buffer: [max_stations * max_stations]Float = undefined;
    const distance_matrix: []Float = distance_matrix_buffer[0..shape.size];
    var time_matrix_buffer: [max_stations * max_stations]u32 = undefined;
    const time_matrix: []u32 = time_matrix_buffer[0..shape.size];
    for (stations, 0..) |station1, row| {
        for (stations, 0..) |station2, col| {
            distance_matrix[shape.ravel(row, col)] = @floatCast(math.vector.norm2(station1 - station2));
            time_matrix[shape.ravel(row, col)] = lma.nano.toNano(distance_matrix[shape.ravel(row, col)] / lma.constants.c);
        }
    }

    // Prepare output signal
    var output: lma.data.Points = .init(gpa);
    output.start_epoch = span.start;
    errdefer output.deinit();

    // Stack allocate buffer for all signals data
    var signal_buffer: [max_stations][]const lma.data.types.Toa = @splat(&.{});
    const signals: [][]const lma.data.types.Toa = signal_buffer[0..count];

    var weight_arrays: [max_stations]std.ArrayList(Float) = @splat(.empty);
    defer for (&weight_arrays) |*weight_array| weight_array.deinit(gpa);
    var weight_buffer: [max_stations][]Float = @splat(&.{});
    const weights: [][]Float = weight_buffer[0..count];

    // Stack and heap allocate cross-correlation buffer
    const step: match.Step = comptime .fromStep(0.000_004_000);
    var corr_size: usize = 0;
    for (0..count) |row| {
        if (full_signals[row].empty()) continue;
        for (0..row) |col| {
            if (full_signals[col].empty()) continue;
            const dist = distance_matrix[shape.ravel(row, col)];
            corr_size += 2 * correlation_size(dist, step);
        }
    }

    var aux_corr_buffer: [correlation_size(max_distance, step)]Float = undefined;
    var corr_matrix_buffer: [max_stations * max_stations]lma.index.SubSlice = @splat(.init(0, 0));
    const corr_matrix: []lma.index.SubSlice = corr_matrix_buffer[0..shape.size];
    const corr_buffer = try gpa.alloc(Float, corr_size);
    defer gpa.free(corr_buffer);

    var corr_start: u32 = 0;
    for (0..count) |row| {
        if (full_signals[row].empty()) continue;
        for (0..row) |col| {
            if (full_signals[col].empty()) continue;
            const dist = distance_matrix[shape.ravel(row, col)];
            const size = correlation_size(dist, step);
            corr_matrix_buffer[shape.ravel(row, col)] = .init(corr_start, size);
            corr_start += size;
            corr_matrix_buffer[shape.ravel(col, row)] = .init(corr_start, size);
            corr_start += size;
        }
    }

    var sources: std.ArrayList(lma.data.types.Point) = .empty;
    defer sources.deinit(gpa);

    const dfs_buffer = try gpa.alloc(Float, max_stations * max_matches * min_stations * 2);
    defer gpa.free(dfs_buffer);

    var memory_buffer: [2]ToaSolver.Source = undefined;
    var solver: ToaSolver = .init(
        stations,
        &memory_buffer,
        dfs_buffer,
        .{
            .beam_search = .{ .query = .permissive, .width = 3 },
            .depth_first_search = .{ .query = .permissive, .attempts = .single },
        },
    );
    const config: match.Matching.Config = .{ .max_time_delta = time_matrix, .max_matches = max_matches, .network_size = @intCast(count) };
    var matching: match.Matching = .{
        .buffers = try .init(gpa, config),
        .corr = .{
            .matrix = corr_matrix,
            .time_matrix = config.max_time_delta,
            .step = step,
            .shape = shape,
            .correlation = corr_buffer,
            .aux_buffer = &aux_corr_buffer,
            .window_size = lma.nano.ratio / 5,
            .refresh_rate = lma.nano.ratio / 10,
        },
        .config = config,
    };
    defer matching.buffers.deinit(gpa);
    for (span.start..span.end()) |time| {
        try io.checkCancel();
        var size: usize = 0;
        for (full_signals, signals, weight_arrays[0..count], weights) |full_signal, *signal, *weight_array, *weight| {
            signal.* = full_signal.valuesAt(full_signal.epochIndex(time, .exact));
            weight_array.clearRetainingCapacity();
            weight.* = try weight_array.addManyAsSlice(gpa, signal.len);
            weight_mode.calculate(signal.*, weight.*);
            size += signal.len;
        }

        sources.clearRetainingCapacity();
        try sources.ensureTotalCapacity(gpa, size);

        solver.signals = signals;
        sources.items.len = matching.process(signals, weights, sources.allocatedSlice(), @as(*ToaSolver, &solver), ToaSolver.solve);

        try output.headers.append(gpa, .init(@intCast(output.array.items.len), @intCast(sources.items.len)));
        try output.array.appendSlice(gpa, sources.items);
    }

    try io.checkCancel();
    return .{ output, solver.counts };
}

fn cutoffTime(time: u32, point: lma.data.types.Point) bool {
    return time > point.nanosecond;
}

fn sortSegment(_: void, _: u64, slice: []lma.data.types.Point) lma.data.segmented.Shift {
    // Both seem to show roughly the same performance
    // std.sort.block(lma.data.types.Point, slice, {}, lma.data.types.Point.earlier);
    std.sort.insertion(lma.data.types.Point, slice, {}, lma.data.types.Point.earlier);
    return .{};
}

fn shiftBack(_: void, _: u64, slice: []lma.data.types.Point) lma.data.segmented.Shift {
    const split: u32 = @intCast(std.sort.partitionPoint(lma.data.types.Point, slice, global_shift, cutoffTime));
    var idx: u32 = 0;
    while (idx < split) : (idx += 1) {
        slice[idx].nanosecond += lma.nano.ratio - global_shift;
    }
    while (idx < slice.len) : (idx += 1) {
        slice[idx].nanosecond -= global_shift;
    }
    return .{ .backward = split };
}
