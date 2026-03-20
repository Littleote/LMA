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
    var futures: [minutes]std.Io.Future(RunError!struct { lma.data.Points, Solver.Counts }) = undefined;
    var outputs: [minutes]lma.data.Points = undefined;
    var counts: Solver.Counts = .{};
    for (0..minutes) |idx| {
        futures[idx] = init.io.async(run, .{ init.io, init.gpa, points, full_signals, weight_mode, .init(@intCast(start_time + idx * 1 * 60), 1 * 60) });
    }
    defer for (&outputs) |*output| output.deinit();
    var maybe_err: RunError!void = {};
    for (0..minutes) |idx| {
        const result = if (maybe_err) futures[idx].await(init.io) else |_| futures[idx].cancel(init.io);
        outputs[idx], const new_counts = result catch |err| default: {
            maybe_err = err;
            break :default .{ .init(.failing), Solver.Counts{} };
        };
        inline for (comptime std.meta.fieldNames(Solver.Counts)) |field| {
            @field(counts, field) += @field(new_counts, field);
        }
    }
    var output: lma.data.Points = try .concatenate(&outputs, init.gpa);
    defer output.deinit();

    output.epochApplyShift({}, sortSegment) catch unreachable;
    try output.epochApplyShift({}, shiftBack);
    output.epochApplyShift({}, sortSegment) catch unreachable;

    std.debug.print("Total Queries: {d}\n", .{counts.set_queries});
    std.debug.print("Total Linear Matches: {d}\n", .{counts._matches});
    std.debug.print("Total Linear Matches Refined: {d}\n", .{counts._tuned});
    std.debug.print("Total L-M Matches: {d}\n", .{counts._solutions});

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

const RunError = error{ Canceled, OutOfMemory };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    stations: []sol.Point,
    full_signals: []const lma.data.ToA,
    weight_mode: lma.pipeline.match.Weights,
    span: lma.SubSlice,
) RunError!struct { lma.data.Points, Solver.Counts } {
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

    var solver: Solver = .{ .points = stations };
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

        sources.items = match.match(
            .{ .max_network = 32, .min_candidates = min_stations, .pairing_window = max_matches },
            signals,
            weights,
            &.{
                .step = step,
                .shape = shape,
                .search = //.exhaustive,
                .{
                    .min_pair_corr = 0.5,
                    .min_base_corr = 1.5,
                    .min_cum_corr = 1.5,
                    .corr_limit = 3.0,
                    .attempts = .count(3),
                },
                // Config for plane detection
                .corr = .{
                    .matrix = corr_matrix,
                    .aux_buffer = &unscaled_correlation_buffer,
                    .window_size = std.math.maxInt(u32),
                    .refresh_rate = std.math.maxInt(u32),
                    // .window_size = lma.nano.ratio / 5,
                    // .refresh_rate = lma.nano.ratio / 10,
                },
                .time_matrix = time_matrix,
            },
            sources.allocatedSlice(),
            @as(*Solver, &solver),
            Solver.solve,
        );

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
    pub const Counts = struct {
        set_queries: usize = 0,
        _matches: usize = 0,
        _tuned: usize = 0,
        _solutions: usize = 0,
    };

    const Buffer = struct {
        const Entry = struct {
            point: sol.Point,
            time: sol.Float,
            err: sol.Float = std.math.inf(Float),
            index: u16,
            station: u8,
            mask: match.Signal.MaskBit,
        };

        len: u8,
        keys: [max_stations]?u8,
        entries: [max_stations]Entry,
        data: [max_stations]sol.Vec,

        ref_point: sol.Point,
        ref_time: sol.Float,

        pub fn at(ref_point: sol.Point, ref_time: sol.Float) Buffer {
            return .{
                .len = 0,
                .keys = @splat(null),
                .entries = undefined,
                .data = undefined,
                .ref_point = ref_point,
                .ref_time = ref_time,
            };
        }

        pub inline fn append(self: *Buffer, obj: Entry) u8 {
            const key: u8 = @intCast(if (self.keys[obj.station]) |idx| idx else blk: {
                const key = self.len;
                self.len += 1;
                break :blk key;
            });

            self.entries[key] = obj;
            self.data[key] = .{ obj.point.x, obj.point.y, obj.point.z, obj.time };
            self.keys[obj.station] = key;
            return key;
        }
    };

    points: []const lma.pipeline.zlm(Precise).Vec3,
    counts: Counts = .{},

    inline fn fromNano(nanosecond: u32) Precise {
        return lma.nano.fromNano(Precise, nanosecond);
    }

    inline fn square(value: anytype) @TypeOf(value) {
        return value * value;
    }

    const c = lma.constants.c / lma.constants.refractive_index.airRange(1_000, 8_000);

    pub fn solve(self: *Solver, initial: match.Signal, candidates: []const match.Signal, skip: []u32, options: *const match.Options) ?lma.data.types.Point {
        var iter: match.DepthFirstSearch(.{
            .max_network = 32,
            .min_candidates = min_stations,
            .pairing_window = max_matches,
        }) = .init(initial, candidates, options);
        while (iter.next()) |set| {
            var buffer: Buffer = .at(self.points[initial.station], c * fromNano(initial.nanosecond));
            _ = &buffer;
            if (self.solveSet(set, candidates, skip)) |point| return point;
        }
        return null;
    }

    fn populateBuffer(self: *const Solver, buffer: *Buffer, signals: []const match.Signal) void {
        for (signals) |signal| {
            _ = buffer.append(.{
                .point = self.points[signal.station].sub(buffer.ref_point),
                .time = c * fromNano(signal.nanosecond) - buffer.ref_time,
                .index = signal.index,
                .station = signal.station,
                .mask = signal.mask,
            });
        }
    }

    pub fn solveSet(self: *Solver, matched: []const match.Signal, candidates: []const match.Signal, skip: []u32) ?lma.data.types.Point {
        self.counts.set_queries += 1;
        var buffer: Buffer = .at(self.points[matched[0].station], c * fromNano(matched[0].nanosecond));
        self.populateBuffer(&buffer, matched);

        const xyz_rms = (0.000_000_040 * c);
        const xyz_rms_squared = xyz_rms * xyz_rms;

        var guess: [4]sol.Float = blk: {
            // Calculate centered coefficients
            var biases: [min_stations - 1]sol.Float = undefined;
            var coefficients: [min_stations - 1]sol.Vec = undefined;
            for (buffer.entries[1..buffer.len], 0..) |entry, idx| {
                const delta = entry.point;
                const delta_t = entry.time;
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
            for (buffer.entries[0..buffer.len]) |*entry| {
                const delta = entry.point.sub(xyz).length();
                const delta_t = entry.time - t;
                if (delta_t <= 0) return null;
                entry.err = @abs(delta - delta_t);
                max_error = @max(max_error, entry.err);
            }

            if (max_error > 1_000) return null;

            // Flip height
            var gps = lma.pipeline.transform.xyzToGPS(f32, xyz.add(buffer.ref_point));
            gps.z = @abs(gps.z);
            self.counts._matches += 1;
            const above_xyz = lma.pipeline.transform.gpsToXYZ(sol.Float, gps).sub(buffer.ref_point);
            break :blk .{ above_xyz.x, above_xyz.y, above_xyz.z, t };
        };

        guess = blk: {
            // Solve quadratic optimization with L-M
            const arr: [4]sol.Float = sol.lm.solve(buffer.data[0..buffer.len], guess, .{
                .max_iterations = 100,
                .min_gradient = 10,
                .min_improvement = 100,
            });
            const xyz: sol.Point = .new(arr[0], arr[1], arr[2]);
            const t: sol.Float = arr[3];
            if (xyz.length() > max_distance) return null;

            // Assert the solution is reasonable
            var max_error: sol.Float = 0;
            for (buffer.entries[0..buffer.len]) |*entry| {
                const delta = entry.point.sub(xyz).length();
                const delta_t = entry.time - t;
                if (delta_t <= 0) return null;
                entry.err = @abs(delta - delta_t);
                max_error = @max(entry.err, max_error);
            }

            if (max_error > 500) return null;

            self.counts._tuned += 1;
            break :blk .{ xyz.x, xyz.y, xyz.z, t };
        };

        // Extract coefficients
        for (candidates) |signal| {
            const point = self.points[signal.station].sub(buffer.ref_point);
            const time = c * fromNano(signal.nanosecond) - buffer.ref_time;
            const err = @abs(guess[3] + point.sub(.new(guess[0], guess[1], guess[2])).length() - time);
            if (err > 1_000) continue;
            if (buffer.keys[signal.station]) |key| {
                if (err > buffer.entries[key].err) continue;
            }
            _ = buffer.append(.{
                .point = point,
                .time = time,
                .err = err,
                .index = signal.index,
                .station = signal.station,
                .mask = signal.mask,
            });
        }

        guess = blk: {
            if (buffer.len < 5) return null;

            // Solve quadratic optimization with L-M
            const arr: [4]sol.Float = sol.lm.solve(buffer.data[0..buffer.len], guess, .{ .max_iterations = 100 });
            const xyz: sol.Point = .new(arr[0], arr[1], arr[2]);
            const t: sol.Float = arr[3];
            if (xyz.length() > max_distance) return null;

            // Assert the solution is reasonable
            var max_error: sol.Float = 0;
            for (buffer.entries[0..buffer.len]) |*entry| {
                const delta = entry.point.sub(xyz).length();
                const delta_t = entry.time - t;
                if (delta_t <= 0) return null;
                entry.err = @abs(delta - delta_t);
                max_error = @max(entry.err, max_error);
            }
            if (max_error > 250) return null;

            break :blk .{ xyz.x, xyz.y, xyz.z, t };
        };

        const chi_sq = sol.lm.solutionError(buffer.data[0..buffer.len], guess) /
            xyz_rms_squared / lma.cast.to(sol.Float, buffer.len - 4);
        const xyz = sol.Point.new(guess[0], guess[1], guess[2]).add(buffer.ref_point);
        const t = (guess[3] + buffer.ref_time) / c;
        if (t <= 0) return null;
        if (chi_sq > 10) return null;
        const gps = lma.pipeline.transform.xyzToGPS(f32, xyz);
        const nano = lma.nano.toNano(t);
        var mask: u32 = 0;
        for (buffer.entries[0..buffer.len]) |entry| {
            mask |= @as(u32, 1) << @intCast(entry.station);
            if (entry.err < 100 and entry.mask.is_set)
                skip[entry.station] |= @as(match.Signal.Mask, 1) << entry.mask.bit;
        }
        self.counts._solutions += 1;

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
