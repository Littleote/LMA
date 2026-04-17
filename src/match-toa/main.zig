const std = @import("std");

const lma = @import("lma");
const match = lma.pipeline.match;
const sol = lma.pipeline.solver;
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
pub const Precise = sol.Float;
pub const math = lma.pipeline.math(Precise);

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
    var points_buffer: [max_stations]sol.Vec = undefined;
    const points: []sol.Vec = points_buffer[0..count];
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

    inline for (comptime std.meta.fieldNames(Solver.Counts)) |field| {
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
    stations: []sol.Vec,
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
            distance_matrix[shape.ravel(row, col)] = @floatCast(math.vector.norm2(station1 - station2));
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

    const candidates_buffer = try gpa.alloc(match.Signal, max_stations * max_matches);
    defer gpa.free(candidates_buffer);
    const dfs_buffer = try gpa.alloc(Float, max_stations * max_matches * min_stations * 2);
    defer gpa.free(dfs_buffer);
    var merge_buffer: match.Merge.Array = try .initCapacity(gpa, max_stations);
    merge_buffer.len = merge_buffer.capacity;
    defer merge_buffer.deinit(gpa);

    var memory_buffer: [5]Solver.Source = undefined;
    var solver: Solver = .init(stations, null, &memory_buffer, dfs_buffer);
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
        sources.items = match.match(
            signals,
            weights,
            candidates_buffer,
            merge_buffer,
            &.{
                .step = step,
                .shape = shape,
                .network = .{ .max_size = max_stations, .max_station_candidates = max_matches },
                .corr = .{
                    .matrix = corr_matrix,
                    .aux_buffer = &unscaled_correlation_buffer,
                    .window_size = lma.nano.ratio / 5,
                    .refresh_rate = lma.nano.ratio / 10,
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

const Solver = struct {
    const length = math.vector.norm2;
    const vec3 = math.vector.vec3;
    inline fn space_time(space: math.Vec, time: sol.Float) math.Vec {
        return space + math.vector.vec4(0, 0, 0, time);
    }

    pub const Counts = struct {
        buffer_set: usize = 0,
        buffer_source: usize = 0,
        solve_linear: usize = 0,
        solve_lm: usize = 0,
        out_initial: usize = 0,
        out_refined: usize = 0,
        out_solutions: usize = 0,
    };

    const Source = struct {
        point: math.Vec,
        time: sol.Float,

        /// Compute the power as dBW at source from a buffer.
        fn dBW(self: *const Source, solver: *const Solver, buffer: *const Buffer) sol.Float {
            var total: f32 = 0;
            for (buffer.entries[0..buffer.len]) |entry| {
                const dbm: f32 = @floatCast(solver.signals[entry.station][entry.index].dBm);
                const area = math.vector.norm2Square(entry.point - self.point);
                const log_surface = 10.0 * @log10(4.0 * std.math.pi * area);
                total += dbm + lma.cast.as(f32, log_surface);
            }
            // Subtract 30 to convert from dBm to dBW
            return (total / buffer.len) - 30.0;
        }

        fn isFinite(self: *const Source) bool {
            return std.math.isFinite(self.time);
        }

        pub fn toVec(self: *const Source) sol.Vec {
            return space_time(self.point, self.time);
        }

        pub fn toPoint(self: *const Source, solver: *const Solver, buffer: *const Buffer) lma.data.types.Point {
            const chi_sq = sol.ls.toaError(buffer.data[0..buffer.len], self.toVec()) / xyz_rms_squared / lma.cast.to(sol.Float, buffer.len - 4);
            const xyz = self.point + buffer.ref_point;
            const t = (self.time + buffer.ref_time) / c;
            const gps = lma.pipeline.transform.xyzToGPS(f32, math.ElemVec.init(xyz).cast(f32));
            const nano = lma.nano.toNano(t);
            if (nano == std.math.maxInt(u32)) {
                std.debug.print("{any}\n", .{self});
                for (buffer.entries[0..buffer.len]) |entry| {
                    std.debug.print("{any}\n", .{entry});
                }
                @panic("Bad time");
            }
            var mask: u32 = 0;
            for (buffer.entries[0..buffer.len]) |entry| {
                mask |= @as(u32, 1) << @intCast(entry.station);
            }

            return .{
                .nanosecond = nano,
                .latitude = gps.x(),
                .longitude = gps.y(),
                .altitude = gps.z(),
                .station_mask = mask,
                .measure_error = @floatCast(chi_sq),
                .dBW = @floatCast(self.dBW(solver, buffer)),
            };
        }
    };

    const Buffer = struct {
        const Entry = struct {
            point: sol.Vec,
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

        ref_point: sol.Vec,
        ref_time: sol.Float,

        pub fn at(ref_point: sol.Vec, ref_time: sol.Float) Buffer {
            return .{
                .len = 0,
                .keys = @splat(null),
                .entries = undefined,
                .data = undefined,
                .ref_point = ref_point,
                .ref_time = ref_time,
            };
        }

        pub fn clear(self: *Buffer) void {
            self.len = 0;
            self.keys = @splat(null);
        }

        pub fn append(self: *Buffer, obj: *const Entry) u8 {
            const key: u8 = @intCast(if (self.keys[obj.station]) |idx| idx else blk: {
                const key = self.len;
                self.len += 1;
                break :blk key;
            });

            self.entries[key] = obj.*;
            self.data[key] = space_time(obj.point, obj.time);
            self.keys[obj.station] = key;
            return key;
        }
    };

    stations: []const sol.Vec,
    signals: []const []const lma.data.types.ToA,
    counts: Counts = .{},
    memory: []Source = &.{},
    dfs_buffer: ?[]Float = null,

    pub fn init(stations: []const sol.Vec, signals: ?[]const []const lma.data.types.ToA, memory_buffer: ?[]Source, dfs_buffer: ?[]Float) Solver {
        if (memory_buffer) |buf| @memset(buf, .{ .point = math.vector.zero, .time = -std.math.inf(sol.Float) });
        return .{
            .stations = stations,
            .signals = signals orelse &.{},
            .counts = .{},
            .memory = memory_buffer orelse &.{},
            .dfs_buffer = dfs_buffer,
        };
    }

    inline fn fromNano(nanosecond: u32) Precise {
        return lma.nano.fromNano(Precise, nanosecond);
    }

    const c = lma.constants.c / lma.constants.refractive_index.airRange(1_000, 8_000);

    const xyz_rms = (0.000_000_040 * c);
    const xyz_rms_squared = xyz_rms * xyz_rms;

    pub fn solve(self: *Solver, initial: match.Signal, candidates: []const match.Signal, skip: []u32, options: *const match.Options) ?lma.data.types.Point {
        // if (self.dfs_buffer) |buf| {
        //     var iter: match.BeamSearch(min_stations) = .init(initial, candidates, buf, options, &.{ .query = .likely, .width = min_stations });

        //     while (iter.next()) |set| {
        //         if (self.solveSet(set, candidates, skip)) |point| return point;
        //     }
        // }

        for (self.memory) |prev_source| {
            if (self.solveFromPoint(initial, &prev_source, candidates, skip)) |point| return point;
        }

        if (self.dfs_buffer) |buf| {
            var iter: match.DepthFirstSearch(min_stations) = .init(initial, candidates, buf, options, &.compromise);

            while (iter.next()) |set| {
                if (self.solveSet(set, candidates, skip)) |point| return point;
            }
        }
        return null;
    }

    fn initialSolution(self: *Solver, buffer: *Buffer) ?Source {
        if (buffer.len < 5) return null;

        self.counts.solve_linear += 1;
        var source = solveLinear(buffer);

        // Assert the solution is reasonable
        {
            if (length(source.point) > max_distance) return null;
            const max_error = bufferError(buffer, &source);
            if (max_error > 1_000) return null;
        }

        // Enforce constraints
        const trans = lma.pipeline.transform;
        var gps = trans.xyzToGPS(f64, .init(source.point + buffer.ref_point));
        gps.refAt(.z).* = @abs(gps.z());
        source = .{
            .point = trans.gpsToXYZ(sol.Float, gps).build() - buffer.ref_point,
            .time = -@abs(source.time),
        };

        // Clean solution
        self.counts.solve_lm += 1;
        source = solveGN(buffer, &source, .{ .common = .{ .max_iterations = 5 } }) catch return null;
        // Assert the solution is reasonable
        {
            if (length(source.point) > max_distance) return null;
            if (source.time > 0) return null;
            const max_error = bufferError(buffer, &source);
            if (max_error > 500) return null;
        }

        self.counts.out_initial += 1;
        return source;
    }

    fn refinedSolution(self: *Solver, buffer: *Buffer, input: *const Source) ?Source {
        if (buffer.len < 5) return null;

        // Solve quadratic optimization with L-M
        self.counts.solve_lm += 1;
        const source = solveGN(buffer, input, .{ .common = .{ .max_iterations = 100 } }) catch return null;

        // Assert the solution is reasonable
        {
            if (length(source.point) > max_distance) return null;
            if (source.time > 0) return null;
            const max_error = bufferError(buffer, &source);
            if (max_error > 150) return null;
        }

        self.counts.out_refined += 1;
        return source;
    }

    fn validateSolution(self: *Solver, buffer: *Buffer, source: *const Source) bool {
        const chi_sq = sol.ls.toaError(buffer.data[0..buffer.len], source.toVec()) / xyz_rms_squared / lma.cast.to(sol.Float, buffer.len - 4);
        const t = (source.time + buffer.ref_time) / c;

        if (t <= 0) return false;
        if (chi_sq > 5) return false;

        _ = self;
        return true;
    }

    fn addSource(self: *Solver, source: *const Source) void {
        if (self.memory.len <= 1) {
            if (self.memory.len == 1)
                self.memory[0] = source.*;
            return;
        }
        var old: usize = 0;
        var near: usize = 0;
        var t: sol.Float = self.memory[old].time;
        var dist: sol.Float = length(self.memory[old].point - source.point);
        for (1..self.memory.len) |idx| {
            if (self.memory[idx].time < t) {
                old = idx;
                t = self.memory[old].time;
            }
            const new_dist = length(self.memory[idx].point - source.point);
            if (new_dist < dist) {
                near = idx;
                dist = new_dist;
            }
        }
        if (dist < 500) {
            self.memory[near] = source.*;
        } else {
            self.memory[old] = source.*;
        }
    }

    /// Fill a buffer with the set of signals.
    ///
    /// Overrides previous signals from matching stations.
    fn bufferFromSet(self: *const Solver, buffer: *Buffer, signals: []const match.Signal) void {
        for (signals) |signal| {
            _ = buffer.append(&.{
                .point = self.stations[signal.station] - buffer.ref_point,
                .time = c * fromNano(signal.nanosecond) - buffer.ref_time,
                .index = signal.index,
                .station = signal.station,
                .mask = signal.mask,
            });
        }
    }

    /// Fill a buffer with candidates that would give a low error for the given source.
    ///
    /// Overrides previous signals from matching stations that had higher errors
    fn bufferFromSource(self: *const Solver, buffer: *Buffer, source: *const Source, candidates: []const match.Signal, threshold: sol.Float) void {
        for (candidates) |signal| {
            const point = self.stations[signal.station] - buffer.ref_point;
            const time = c * fromNano(signal.nanosecond) - buffer.ref_time;
            const err = @abs(source.time + length(point - source.point) - time);
            if (err > threshold) continue;
            if (buffer.keys[signal.station]) |key| {
                if (err > buffer.entries[key].err) continue;
            }
            _ = buffer.append(&.{
                .point = point,
                .time = time,
                .err = err,
                .index = signal.index,
                .station = signal.station,
                .mask = signal.mask,
            });
        }
    }

    /// Compute the err field of a buffer for a given source and return the greatest error.
    ///
    /// Overrides previous values of errors
    fn bufferError(buffer: *Buffer, source: *const Source) sol.Float {
        var max_error: sol.Float = 0;
        for (buffer.entries[0..buffer.len]) |*entry| {
            const delta = length(entry.point - source.point);
            const delta_t = entry.time - source.time;
            entry.err = @abs(delta - delta_t);
            max_error = @max(max_error, entry.err);
        }
        return max_error;
    }

    /// Solve the TOA problem using a linear approximation and refines the solution with Levenberg-Marquardt
    ///
    /// **NOTE**: the first element of buffer is expected to be the reference point
    pub fn solveLinear(buffer: *Buffer) Source {
        if (!@reduce(.And, buffer.data[0] == @as(sol.Vec, @splat(0)))) @panic("bad linear input");
        const equations = buffer.len - 1;
        var bias: [max_stations]sol.Float = undefined;
        var coef: [max_stations]sol.Vec = undefined;
        for (buffer.entries[1..buffer.len], 0..) |entry, idx| {
            const delta = entry.point;
            const delta_t = entry.time;
            bias[idx] = math.vector.sum(delta * delta) - delta_t * delta_t;
            coef[idx] = math.vector.splat(2) * space_time(delta, -delta_t);
        }

        // Solve linear system
        const arr: math.ElemVec = .init(sol.linear.solve(coef[0..equations], bias[0..equations], sol.linear.solveGaussian));
        if (!std.math.isFinite(arr.t())) {
            std.debug.print("{any}\n{any}\n", .{ coef[0..equations], bias[0..equations] });
            @panic("bad linear output");
        }
        return .{
            .point = vec3(arr.x(), arr.y(), arr.z()),
            .time = arr.t(),
        };
    }

    pub fn solveLM(buffer: *Buffer, input: *const Source, options: sol.ls.lm.LMOptions) error{NonFinite}!Source {
        const input_vec: sol.Vec = .{ input.point.x, input.point.y, input.point.z, input.time };

        // Solve quadratic optimization with L-M
        const arr: [4]sol.Float = sol.ls.lm.solve(buffer.data[0..buffer.len], input_vec, options);
        // std.debug.assert(std.math.isFinite(arr[3]));

        const out: Source = .{
            .point = vec3(arr.x(), arr.y(), arr.z()),
            .time = arr.t(),
        };
        return if (out.isFinite()) out else error.NonFinite;
    }

    pub fn solveGN(buffer: *Buffer, input: *const Source, options: sol.ls.gn.GNOptions) error{NonFinite}!Source {
        const input_vec: sol.Vec = space_time(input.point, input.time);

        // Solve quadratic optimization with L-M
        const arr: math.ElemVec = .init(sol.ls.gn.solve(buffer.data[0..buffer.len], input_vec, options));

        const out: Source = .{
            .point = vec3(arr.x(), arr.y(), arr.z()),
            .time = arr.t(),
        };
        return if (out.isFinite()) out else error.NonFinite;
    }

    pub fn solveFromPoint(self: *Solver, reference: match.Signal, base_source: *const Source, candidates: []const match.Signal, skip: []u32) ?lma.data.types.Point {
        var buffer: Buffer = .at(self.stations[reference.station], c * fromNano(reference.nanosecond));
        const base_point = base_source.point;
        buffer.clear();
        _ = buffer.append(&.{
            .point = math.vector.zero,
            .time = 0,
            .index = reference.index,
            .station = reference.station,
            .mask = reference.mask,
        });

        const xyz = base_point - buffer.ref_point;
        self.counts.buffer_source += 1;
        self.bufferFromSource(&buffer, &.{ .point = xyz, .time = -length(xyz) }, candidates, 1_000);
        const initial = self.initialSolution(&buffer) orelse return null;
        const source = self.refinedSolution(&buffer, &initial) orelse return null;
        if (!self.validateSolution(&buffer, &source)) return null;

        for (buffer.entries[0..buffer.len]) |entry| {
            if (entry.err < 100 and entry.mask.is_set)
                skip[entry.station] |= @as(match.Signal.Mask, 1) << entry.mask.bit;
        }

        self.counts.out_solutions += 1;
        self.addSource(&.{ .point = source.point + buffer.ref_point, .time = source.time + buffer.ref_time });
        return source.toPoint(self, &buffer);
    }

    pub fn solveSet(self: *Solver, matched: []const match.Signal, candidates: []const match.Signal, skip: []u32) ?lma.data.types.Point {
        var buffer: Buffer = .at(self.stations[matched[0].station], c * fromNano(matched[0].nanosecond));
        self.counts.buffer_set += 1;
        self.bufferFromSet(&buffer, matched);

        const initial = self.initialSolution(&buffer) orelse return null;
        self.bufferFromSource(&buffer, &initial, candidates, 1_000);
        const source = self.refinedSolution(&buffer, &initial) orelse return null;

        if (!self.validateSolution(&buffer, &source)) return null;
        const xyz = source.point + buffer.ref_point;

        for (buffer.entries[0..buffer.len]) |entry| {
            if (entry.err < 100 and entry.mask.is_set)
                skip[entry.station] |= @as(match.Signal.Mask, 1) << entry.mask.bit;
        }
        self.counts.out_solutions += 1;
        self.addSource(&.{ .point = xyz, .time = source.time + buffer.ref_time });
        return source.toPoint(self, &buffer);
    }
};
