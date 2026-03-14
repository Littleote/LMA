const std = @import("std");

const lma = @import("lma");
const match = lma.pipeline.match;
const nargs = @import("nargs");

const max_stations = 32;
const sol = lma.pipeline.solver(Precise);
const root = nargs.groups.any("match", .{
    .weight_mode = nargs.params.param("weights", nargs.types.options(lma.pipeline.match.Weights), .single, .{ .short = .auto, .default = .decibels }),
    .station = nargs.params.param("station", nargs.types.io.File.initDefaults(.open_file), .single, .{ .short = .auto }),
    .input = nargs.params.param("ipnut", nargs.types.io.Glob.init, .single, .{ .short = .auto }),
    .output = nargs.params.param("output", nargs.types.io.File.initDefaults(.create_file), .single, .{ .short = .auto }),
    .dat_output = nargs.params.param("dat-output", nargs.types.unset(nargs.types.io.File.initDefaults(.create_file)), .single, .{ .short = .auto, .default = @as(?[]u8, null) }),
});

pub const Float = f32;
pub const Precise = f64;

const max_distance = 200_000.0;
const global_shift: u32 = 50_000_000;
const max_matches: usize = @intFromFloat(1 + @ceil(max_distance / lma.constants.c / 0.000_080));
const min_stations: usize = 6;

fn correlation_size(dist: Float, step: match.Step) usize {
    return 1 + 4 * lma.cast.to(usize, @round(@min(max_distance, dist) / lma.constants.c / step.step));
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
    // const shape: lma.pipeline.Grid = .init(count, count);
    if (count > max_stations) @panic("Station limit reached.");

    var shift_buffer: [max_stations]u32 = undefined;
    const shifts: []u32 = shift_buffer[0..count];
    var points_buffer: [max_stations]sol.Point = undefined;
    const points: []sol.Point = points_buffer[0..count];
    for (stations.stations.items, points, shifts) |station, *point, *delay| {
        delay.* = global_shift - @as(u32, @bitCast(station.delay));
        point.* = lma.pipeline.transform.gpsToXYZ(Precise, station);
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

    const start_time = blk: {
        const hour = try std.fmt.parseInt(u32, time.?[0..2], 10);
        const minute = try std.fmt.parseInt(u32, time.?[2..4], 10);
        const second = try std.fmt.parseInt(u32, time.?[4..6], 10);
        break :blk (hour * 60 + minute) * 60 + second;
    };

    // Run program asynchronously divided by minutes
    const minutes = 10;
    var completed: usize = 0;
    var futures: [minutes]std.Io.Future(error{ Canceled, OutOfMemory }!lma.data.Points) = undefined;
    var outputs: [minutes]lma.data.Points = undefined;
    for (0..minutes) |idx| {
        futures[idx] = init.io.async(run, .{ init.io, init.gpa, points, full_signals, weight_mode, .init(@intCast(start_time + idx * 1 * 60), 1 * 60) });
    }
    defer {
        for (0..minutes) |idx| {
            if (idx < completed) {
                outputs[idx].deinit();
            } else {
                outputs[idx] = futures[idx].cancel(init.io) catch continue;
                outputs[idx].deinit();
            }
        }
    }
    for (0..minutes) |idx| {
        completed = idx;
        outputs[idx] = try futures[idx].await(init.io);
    }
    var output: lma.data.Points = try .concatenate(&outputs, init.gpa);
    defer output.deinit();

    output.epochApplyShift({}, sortSegment) catch unreachable;
    try output.epochApplyShift({}, shiftBack);
    output.epochApplyShift({}, sortSegment) catch unreachable;

    std.debug.print("Total Queries: {d}\n", .{Solver.queries});
    std.debug.print("Total Linear Matches: {d}\n", .{Solver.matches});
    std.debug.print("Total Linear Matches Refined: {d}\n", .{Solver.tuned});
    std.debug.print("Total L-M Matches: {d}\n", .{Solver.solutions});

    {
        var file_writer = options.output.writer(init.io, &buffer);
        try output.toCsv(&file_writer.interface, null);
    }
    if (options.dat_output) |dat_file| {
        var file_writer = dat_file.writer(init.io, &buffer);
        try lma.data.dat_file.output.print(&file_writer.interface, &output, &stations);
    }

    std.debug.print("Total points: {d}\n", .{output.array.items.len});
}

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    stations: []sol.Point,
    full_signals: []const lma.data.ToA,
    weight_mode: lma.pipeline.match.Weights,
    span: lma.SubSlice,
) error{ Canceled, OutOfMemory }!lma.data.Points {
    Solver.local_queries = 0;
    Solver.local_matches = 0;
    Solver.local_tuned = 0;
    Solver.local_solutions = 0;
    defer {
        _ = @atomicRmw(usize, &Solver.queries, .Add, Solver.local_queries, .monotonic);
        _ = @atomicRmw(usize, &Solver.matches, .Add, Solver.local_matches, .monotonic);
        _ = @atomicRmw(usize, &Solver.tuned, .Add, Solver.local_tuned, .monotonic);
        _ = @atomicRmw(usize, &Solver.solutions, .Add, Solver.local_solutions, .monotonic);
    }

    const count: u32 = @intCast(stations.len);
    const shape: lma.pipeline.Grid = .init(count, count);

    // Calculate distance and time matrix
    var distance_matrix_buffer: [max_stations * max_stations]Float = undefined;
    const distance_matrix: []Float = distance_matrix_buffer[0..shape.size];
    var time_matrix_buffer: [max_stations * max_stations]u32 = undefined;
    const time_matrix: []u32 = time_matrix_buffer[0..shape.size];
    for (stations, 0..) |station1, row| {
        for (stations, 0..) |station2, col| {
            distance_matrix[shape.ravel(row, col)] = @floatCast(station1.sub(station2).length());
            time_matrix[shape.ravel(row, col)] = lma.nano.toNano(distance_matrix[shape.ravel(row, col)] / lma.constants.c);
        }
    }

    // Prepare output signal
    var output: lma.data.Points = .init(gpa);
    output.start_epoch = span.start;
    errdefer output.deinit();

    // Stack allocate buffer for all signals data
    var signal_buffer: [max_stations][]const lma.data.types.ToA = @splat(&.{});
    const signals: [][]const lma.data.types.ToA = signal_buffer[0..count];

    var weight_arrays: [max_stations]std.ArrayList(Float) = @splat(.empty);
    defer for (&weight_arrays) |*weight_array| weight_array.deinit(gpa);
    var weight_buffer: [max_stations][]Float = @splat(&.{});
    const weights: [][]Float = weight_buffer[0..count];

    // Stack and heap allocate cross-correlation buffer
    const step: match.Step = comptime .fromStep(0.000_004_000);
    var corr_values_buffer_size: usize = 0;
    for (0..count) |row| {
        if (full_signals[row].empty()) continue;
        for (0..row) |col| {
            if (full_signals[col].empty()) continue;
            const dist = distance_matrix[shape.ravel(row, col)];
            corr_values_buffer_size += 2 * correlation_size(dist, step);
        }
    }

    var unscaled_correlation_buffer: [correlation_size(max_distance, step)]Float = undefined;
    var corr_matrix_buffer: [max_stations * max_stations]?[]Float = @splat(null);
    const corr_matrix: []?[]Float = corr_matrix_buffer[0..shape.size];
    var corr_values_buffer = try gpa.alloc(Float, corr_values_buffer_size);
    defer gpa.free(corr_values_buffer);

    var corr_values_buffer_index: usize = 0;
    for (0..count) |row| {
        if (full_signals[row].empty()) continue;
        for (0..row) |col| {
            if (full_signals[col].empty()) continue;
            const dist = distance_matrix[shape.ravel(row, col)];
            const size = correlation_size(dist, step);
            corr_matrix_buffer[shape.ravel(row, col)] = corr_values_buffer[corr_values_buffer_index..][0..size];
            corr_values_buffer_index += size;
            corr_matrix_buffer[shape.ravel(col, row)] = corr_values_buffer[corr_values_buffer_index..][0..size];
            corr_values_buffer_index += size;
        }
    }

    var sources: std.ArrayList(lma.data.types.Point) = .empty;
    defer sources.deinit(gpa);

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

        const solver: Solver = .{ .points = stations };
        sources.items = match.match(
            .{ .max_network = 32, .min_candidates = min_stations, .pairing_window = max_matches },
            signals,
            weights,
            &.{
                .step = step,
                .shape = shape,
                .search = .exhaustive,
                // .{
                //     .min_pair_corr = 0.5,
                //     .min_base_corr = 1.5,
                //     .min_cum_corr = 1.5,
                //     .corr_limit = 3.0,
                //     .attempts = .count(3),
                // },
                // Config for plane detection
                .corr = .{
                    .matrix = corr_matrix,
                    .aux_buffer = &unscaled_correlation_buffer,
                    .window_size = lma.nano.ratio / 5,
                    .refresh_rate = lma.nano.ratio / 10,
                },
                .time_matrix = time_matrix,
            },
            sources.allocatedSlice(),
            &solver,
            Solver.solve,
        );

        try output.headers.append(gpa, .init(@intCast(output.array.items.len), @intCast(sources.items.len)));
        try output.array.appendSlice(gpa, sources.items);
    }

    try io.checkCancel();
    return output;
}

fn cutoffTime(time: u32, point: lma.data.types.Point) bool {
    return time > point.nanosecond;
}

fn sortSegment(_: void, _: u64, slice: []lma.data.types.Point) lma.data.segmented.Shift {
    std.sort.block(lma.data.types.Point, slice, {}, lma.data.types.Point.earlier);
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

const Solver = struct {
    threadlocal var local_queries: usize = 0;
    var queries: usize = 0;
    threadlocal var local_matches: usize = 0;
    var matches: usize = 0;
    threadlocal var local_tuned: usize = 0;
    var tuned: usize = 0;
    threadlocal var local_solutions: usize = 0;
    var solutions: usize = 0;

    const Buffer = struct {
        const Object = struct {
            point: sol.Point,
            time: sol.Float,
            err: sol.Float = std.math.inf(Float),
            index: u16,
            station: u16,
        };

        len: usize = 0,
        points: [max_stations]sol.Point = undefined,
        times: [max_stations]sol.Float = undefined,
        data: [max_stations]sol.Vec = undefined,
        err: [max_stations]sol.Float = undefined,
        indexes: [max_stations]u16 = undefined,
        stations: [max_stations]u16 = undefined,
        keys: [max_stations]?u16 = @splat(null),

        pub inline fn append(self: *Buffer, obj: Object) u16 {
            const key: u16 = @intCast(if (self.keys[obj.station]) |idx| idx else blk: {
                const key = self.len;
                self.len += 1;
                break :blk key;
            });

            self.points[key] = obj.point;
            self.times[key] = obj.time;
            self.data[key] = .{ obj.point.x, obj.point.y, obj.point.z, obj.time };
            self.err[key] = obj.err;
            self.indexes[key] = obj.index;
            self.stations[key] = obj.station;
            self.keys[obj.station] = key;
            return key;
        }
    };

    points: []const lma.pipeline.zlm(Precise).Vec3,

    inline fn fromNano(nanosecond: u32) Precise {
        return lma.nano.fromNano(Precise, nanosecond);
    }

    inline fn square(value: anytype) @TypeOf(value) {
        return value * value;
    }

    pub fn solve(self: *const Solver, matched: []const match.Signal, candidates: []const match.Signal, skip: []u32) ?lma.data.types.Point {
        Solver.local_queries += 1;
        var buffers: Buffer = .{};

        const c = lma.constants.c / lma.constants.refractive_index.air_up_to(8_000);
        const xyz_rms = (0.000_000_040 * c);
        const xyz_rms_squared = xyz_rms * xyz_rms;
        const xyz_center = self.points[matched[0].station];
        const t_center = fromNano(matched[0].nanosecond);
        _ = buffers.append(.{
            .point = .zero,
            .time = 0,
            .station = matched[0].station,
            .index = matched[0].index,
        });

        var guess: [4]sol.Float = blk: {
            // Calculate centered coefficients
            var biases: [min_stations - 1]sol.Float = undefined;
            var coefficients: [min_stations - 1]sol.Vec = undefined;
            for (matched[1..], 0..) |signal, idx| {
                const key = buffers.append(.{
                    .point = self.points[signal.station].sub(xyz_center),
                    .time = c * (fromNano(signal.nanosecond) - t_center),
                    .index = signal.index,
                    .station = signal.station,
                });
                const delta = buffers.points[key];
                const delta_t = buffers.times[key];
                biases[idx] = delta.length2() - square(delta_t);
                coefficients[idx] = .{ 2 * delta.x, 2 * delta.y, 2 * delta.z, -2 * delta_t };
            }

            // Solve linear system
            const arr: [4]sol.Float = sol.linear.solveFixed(min_stations - 1, coefficients, biases);
            const xyz: sol.Point = .new(arr[0], arr[1], arr[2]);
            const t: sol.Float = arr[3];
            if (xyz.length() > max_distance) return null;

            // Assert the solution is reasonable
            var max_error: sol.Float = 0;
            for (0..buffers.len) |key| {
                const delta = buffers.points[key].sub(xyz).length();
                const delta_t = buffers.times[key] - t;
                if (delta_t <= 0) return null;
                buffers.err[key] = @abs(delta - delta_t);
                max_error = @max(max_error, buffers.err[key]);
            }

            if (max_error > 1_000) return null;

            // Flip height
            var gps = lma.pipeline.transform.xyzToGPS(f32, xyz.add(xyz_center));
            gps.z = @abs(gps.z);
            Solver.local_matches += 1;
            const above_xyz = lma.pipeline.transform.gpsToXYZ(sol.Float, gps).sub(xyz_center);
            break :blk .{ above_xyz.x, above_xyz.y, above_xyz.z, t };
        };

        guess = blk: {
            // Solve quadratic optimization with L-M
            const arr: [4]sol.Float = sol.lm.solve(buffers.data[0..buffers.len], guess, .{
                .max_iterations = 100,
                .min_gradient = 10,
                .min_improvement = 100,
            });
            const xyz: sol.Point = .new(arr[0], arr[1], arr[2]);
            const t: sol.Float = arr[3];
            if (xyz.length() > max_distance) return null;

            // Assert the solution is reasonable
            var max_error: sol.Float = 0;
            for (0..buffers.len) |key| {
                const delta = buffers.points[key].sub(xyz).length();
                const delta_t = buffers.times[key] - t;
                if (delta_t <= 0) return null;
                buffers.err[key] = @abs(delta - delta_t);
                max_error = @max(buffers.err[key], max_error);
            }

            if (max_error > 500) return null;
            // const chi_sq = sol.lm.solutionError(points, times, guess) / xyz_rms_squared / lma.cast.to(sol.Float, buffers.len - 4);
            // if (chi_sq > 50) return null;

            Solver.local_tuned += 1;
            break :blk .{ xyz.x, xyz.y, xyz.z, t };
        };

        // Extract coefficients
        for (candidates) |signal| {
            const point = self.points[signal.station].sub(xyz_center);
            const time = c * (fromNano(signal.nanosecond) - t_center);
            const err = @abs(guess[3] + point.sub(.new(guess[0], guess[1], guess[2])).length() - time);
            if (err > 1_000) continue;
            if (buffers.keys[signal.station]) |key| {
                if (err > buffers.err[key]) continue;
            }
            _ = buffers.append(.{
                .point = point,
                .time = time,
                .err = err,
                .index = signal.index,
                .station = signal.station,
            });
        }

        guess = blk: {
            if (buffers.len < 5) return null;

            // Solve quadratic optimization with L-M
            const arr: [4]sol.Float = sol.lm.solve(buffers.data[0..buffers.len], guess, .{ .max_iterations = 100 });
            const xyz: sol.Point = .new(arr[0], arr[1], arr[2]);
            const t: sol.Float = arr[3];
            if (xyz.length() > max_distance) return null;

            // Assert the solution is reasonable
            var max_error: sol.Float = 0;
            for (0..buffers.len) |key| {
                const delta = buffers.points[key].sub(xyz).length();
                const delta_t = buffers.times[key] - t;
                if (delta_t <= 0) return null;
                buffers.err[key] = @abs(delta - delta_t);
                max_error = @max(buffers.err[key], max_error);
            }

            if (max_error > 250) return null;
            // const chi_sq = sol.lm.solutionError(buffers.points[0..buffers.len], buffers.times[0..buffers.len], guess) /
            //     (xyz_rms * xyz_rms) / lma.cast.to(sol.Float, buffers.len - 4);
            // if (chi_sq > 10) return null;

            break :blk .{ xyz.x, xyz.y, xyz.z, t };
        };

        const chi_sq = sol.lm.solutionError(buffers.data[0..buffers.len], guess) /
            xyz_rms_squared / lma.cast.to(sol.Float, buffers.len - 4);
        const xyz = sol.Point.new(guess[0], guess[1], guess[2]).add(xyz_center);
        const t = guess[3] / c + t_center;
        if (t <= 0) return null;
        if (chi_sq > 10) return null;
        const gps = lma.pipeline.transform.xyzToGPS(f32, xyz);
        const nano = lma.nano.toNano(t);
        var mask: u32 = 0;
        for (0..buffers.len) |key| {
            mask |= @as(u32, 1) << @intCast(buffers.stations[key]);
            if (buffers.err[key] < 100)
                skip[buffers.stations[key]] |= @as(u32, 1) << @intCast(buffers.indexes[key]);
        }
        Solver.local_solutions += 1;

        return .{
            .nanosecond = nano,
            .latitude = gps.x,
            .longitude = gps.y,
            .altitude = gps.z,
            .station_mask = mask,
            .measure_error = @floatCast(chi_sq),
            .dBm = 0,
        };
    }
};
