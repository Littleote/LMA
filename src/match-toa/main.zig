const std = @import("std");

const lma = @import("lma");
const match = lma.pipeline.match;
const ToaSolver = lma.pipeline.ToaSolver;
const nargs = @import("nargs");
const files = @import("files.zig");

const max_stations = 32;
const root = nargs.groups.any("match", .{
    .weight_mode = nargs.params.param("corr-weight", nargs.types.options(lma.pipeline.match.Weights), .single, .{ .short = .set('w'), .default = .decibels }),
    .station = nargs.params.param("station", nargs.types.string, .single, .{ .short = .auto }),
    .input = nargs.params.param("input", nargs.types.io.Glob.init, .single, .{ .short = .auto }),
    .outputs = nargs.params.param("output", nargs.types.string, .unlimited, .{ .short = .auto }),
    .probe = nargs.params.param("probe", nargs.types.unset(nargs.types.string), .single, .{ .default = @as(?[]const u8, null) }),
});

pub const Float = match.Float;
pub const Precise = ToaSolver.Float;
pub const math = lma.math(Precise);

const max_distance = 200_000.0;
const global_shift: u32 = 50_000_000;
const max_matches: usize = @intFromFloat(1 + @ceil(max_distance / lma.constants.c / 0.000_080));
const min_stations: usize = 6;

var probe_data: ?match.probing.ProbeData = null;

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

    if (options.probe) |probe_file| {
        const file = try std.Io.Dir.cwd().openFile(init.io, probe_file, .{});
        defer file.close(init.io);
        var file_reader = file.reader(init.io, &buffer);
        probe_data = .init(init.gpa);
        errdefer probe_data.?.deinit();
        try probe_data.?.fromDat(&file_reader.interface);
    }
    defer if (probe_data) |*data| data.deinit();

    // Load stations
    var stations: lma.data.Stations = .init(init.gpa);
    defer stations.deinit();
    {
        const file = try std.Io.Dir.cwd().openFile(init.io, options.station, .{});
        defer file.close(init.io);
        var file_reader = file.reader(init.io, &buffer);
        try files.loadStations(&stations, options.station, &file_reader.interface);
    }
    const count: u32 = @intCast(stations.stations.items.len);
    if (count > max_stations) @panic("Station limit reached.");

    var shift_buffer: [max_stations]u32 = undefined;
    const shifts: []u32 = shift_buffer[0..count];
    var points_buffer: [max_stations]math.Vec = undefined;
    const points: []math.Vec = points_buffer[0..count];
    for (stations.stations.items, points, shifts) |station, *point, *delay| {
        delay.* = global_shift - @as(u32, @bitCast(station.delay));
        point.* = lma.pipeline.transform.gpsToXYZ(Precise, station.point()).build();
    }

    // Load Toa signals
    var active_stations: usize = 0;
    var full_signal_buffer: [max_stations]lma.data.Toa = @splat(.init(init.gpa));
    const full_signals: []lma.data.Toa = full_signal_buffer[0..count];
    defer for (full_signals) |*signal| signal.deinit();

    var date: ?[6]u8 = null;
    var time: ?[6]u8 = null;

    while (try options.input.next()) |entry| {
        // CODE_GROUP_FULL_NAME_DATE_TIME.dat
        const stem, _ = std.mem.cutScalarLast(u8, entry.basename, '.').?;
        var split = std.mem.splitScalar(u8, stem, '_');
        _, _ = .{ split.next().?, split.next().? };

        var back_split = std.mem.splitBackwardsScalar(u8, split.rest(), '_');
        const file_time, const file_date, const name = .{ back_split.next().?, back_split.next().?, back_split.rest() };

        if (file_date.len != 6 or file_time.len != 6) {
            std.log.err(
                \\Invalid file name: "{s}"
                \\Date and time must be 6 characters but found:
                \\    date: "{s}"
                \\    time: "{s}"
            , .{ entry.basename, file_date, file_time });
            return error.BadName;
        }
        if (date == null and time == null) {
            date = file_date[0..6].*;
            time = file_time[0..6].*;
        } else {
            if (!std.mem.eql(u8, &date.?, file_date) or !std.mem.eql(u8, &time.?, file_time)) {
                std.log.err("Invalid file name: {s}\n", .{entry.basename});
                std.log.err(
                    \\Invalid file name: "{s}"
                    \\Date and time must match for all input files
                    \\    date: "{s}" != "{s}"
                    \\    time: "{s}" != "{s}"
                , .{ entry.basename, &date.?, file_date, &time.?, file_time });
                return error.BadName;
            }
        }

        const file = try entry.dir.openFile(init.io, entry.basename, .{});
        defer file.close(init.io);
        var file_reader = file.reader(init.io, &buffer);

        for (stations.stations.items, 0..) |info, idx| {
            if (std.mem.eql(u8, info.name.?, name)) {
                std.debug.assert(full_signals[idx].empty());
                try files.loadSignals(&full_signals[idx], entry.basename, &file_reader.interface);
                for (full_signals[idx].array.items) |*toa| {
                    toa.nanosecond += shifts[idx];
                }
                active_stations += 1;
                break;
            }
        } else {
            std.log.warn("Unknown station \"{s}\"", .{name});
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
    const timer_start: std.Io.Timestamp = .now(init.io, .real);
    const resource_start: std.Io.Timestamp = .now(init.io, .cpu_process);
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

    std.debug.print("{f}", .{counts});
    const timer_end: std.Io.Timestamp = .now(init.io, .real);
    const resource_end: std.Io.Timestamp = .now(init.io, .cpu_process);
    std.debug.print("Wall time: {d}s\n", .{lma.cast.to(f64, std.Io.Timestamp.durationTo(timer_start, timer_end).toNanoseconds()) / std.time.ns_per_s});
    std.debug.print("Process time: {d}s\n", .{lma.cast.to(f64, std.Io.Timestamp.durationTo(resource_start, resource_end).toNanoseconds()) / std.time.ns_per_s});

    for (options.outputs) |out| {
        const err: anyerror = skip: {
            const file = std.Io.Dir.cwd().createFile(init.io, out, .{}) catch |err| break :skip err;
            defer file.close(init.io);
            var file_writer = file.writer(init.io, &buffer);
            files.savePoints(&output, &stations, out, &file_writer.interface) catch |err| break :skip err;
            continue;
        };
        std.log.warn(
            \\Failed to write to file "{s}" with {}
        , .{ out, err });
    }

    std.debug.print("Total points: {d}\n", .{output.array.items.len});

    if (false) {
        var err_buffer: [max_stations]f32 = undefined;
        counts.calibration(&err_buffer);
        for (stations.stations.items, 0..) |*station, i| {
            const correction = lma.nano.toFixed(i32, err_buffer[i]);
            station.delay += correction;
        }
        var writer: std.Io.Writer.Allocating = .init(init.gpa);
        defer writer.deinit();

        stations.toCsv(&writer.writer, null) catch {};
        std.debug.print("Updated stations:\n{s}", .{writer.written()});
    }
}

const RunError = error{ Canceled, OutOfMemory };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    stations: []math.Vec,
    full_signals: []const lma.data.Toa,
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

    const bs_width = 5;
    const work_buffer = try gpa.alloc(
        Float,
        @max(
            (max_stations * max_matches + min_stations) * bs_width * 2,
            max_stations * max_matches * min_stations,
        ),
    );
    defer gpa.free(work_buffer);

    var memory_buffer: [4]ToaSolver.Source = undefined;
    var probe: match.probing.Probe = undefined;
    const probe_ptr: ?*match.probing.Probe = if (probe_data) |*data| blk: {
        probe = .{ .data = data };
        break :blk &probe;
    } else null;
    var solver: ToaSolver = .init(
        stations,
        &memory_buffer,
        work_buffer,
        .{
            .beam_search = .{ .query = .permissive, .width = bs_width, .consensus = min_stations },
            .depth_first_search = .{ .query = .permissive, .attempts = .count(2), .consensus = min_stations },
            .probe = probe_ptr,
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
        if (probe_ptr) |ptr| {
            ptr.current_epoch = time;
            ptr.signals = signals;
        }
        for (solver.memory) |*mem| mem.time -= 1;
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
