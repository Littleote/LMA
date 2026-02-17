const std = @import("std");

const lma = @import("lma");
const max_stations = lma.constants.max_stations;
const match = lma.pipeline.match;
const nargs = @import("nargs");

const root = nargs.groups.any("match", .{
    .weight_mode = nargs.params.param("weights", nargs.types.options(lma.pipeline.match.Weights), .single, .{ .short = .auto, .default = .decibels }),
    .station = nargs.params.param("station", nargs.types.io.File.initDefaults(.open_file), .single, .{ .short = .auto }),
    .input = nargs.params.param("ipnut", nargs.types.io.Glob.init, .single, .{ .short = .auto }),
    .output = nargs.params.param("output", nargs.types.io.File.initDefaults(.create_file), .single, .{ .short = .auto }),
});

pub const Float = f32;
pub const Precise = f64;

const max_distance = 200_000.0;
const global_shift: u32 = 100_000_000;
const max_matches: usize = @intFromFloat(1 + @ceil(max_distance / lma.constants.c / 0.000_080));
const min_stations: usize = 5;

fn correlation_size(dist: Float, step: match.Step) usize {
    return 1 + 2 * lma.common.cast(usize, @round(0 + @min(max_distance, dist) / lma.constants.c / step.step));
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
    const shape: lma.pipeline.grid.Shape = .init(count, count);
    if (count > max_stations) @panic("Station limit reached.");

    var shift_buffer: [max_stations]u32 = undefined;
    const shifts: []u32 = shift_buffer[0..count];
    var points_buffer: [max_stations]lma.pipeline.zlm(Precise).Vec3 = undefined;
    const points: []lma.pipeline.zlm(Precise).Vec3 = points_buffer[0..count];
    for (stations.stations.items, points, shifts) |station, *point, *delay| {
        delay.* = global_shift - @as(u32, @bitCast(station.delay));
        point.* = lma.pipeline.transform.gpsToXYZ(Precise, station);
    }

    var distance_matrix_buffer: [max_stations * max_stations]Float = undefined;
    const distance_matrix: []Float = distance_matrix_buffer[0..shape.size];
    var time_matrix_buffer: [max_stations * max_stations]u32 = undefined;
    const time_matrix: []u32 = time_matrix_buffer[0..shape.size];
    for (points, 0..) |point1, row| {
        for (points, 0..) |point2, col| {
            distance_matrix[shape.ravel(row, col)] = @floatCast(point1.sub(point2).length());
            time_matrix[shape.ravel(row, col)] = lma.constants.nano.toNano(distance_matrix[shape.ravel(row, col)] / lma.constants.c);
        }
    }

    // Load ToA signals
    var active_stations: usize = 0;
    var full_signal_buffer: [max_stations]lma.data.ToA = @splat(.init(init.gpa));
    const full_signals: []lma.data.ToA = full_signal_buffer[0..count];
    defer for (full_signals) |*signal| signal.deinit();
    while (try options.input.next()) |entry| {
        var split = std.mem.splitScalar(u8, entry.basename, '_');
        // CODE_GROUP_NAME_DATE_TIME
        _, _, const name = .{ split.next().?, split.next().?, split.next().? };

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

    // Prepare output signal
    var output: lma.data.Points = .init(init.gpa);
    output.first_epoch = 12 * 60 * 60;
    defer output.deinit();

    // Stack allocate buffer for all signals data
    var signal_buffer: [max_stations][]const lma.data.types.ToA = @splat(&.{});
    const signals: [][]const lma.data.types.ToA = signal_buffer[0..count];

    var weight_buffer: [max_stations]std.ArrayList(Float) = @splat(.empty);
    const weights: []std.ArrayList(Float) = weight_buffer[0..count];
    defer for (weights) |*weight| weight.deinit(init.gpa);

    // Stack allocate for the division
    const subdivisions = 5;

    var split_index_buffer: [max_stations][subdivisions]match.Split = undefined;
    const split_indexes: [][subdivisions]match.Split = split_index_buffer[0..count];
    var split_signal_buffer: [max_stations][]const lma.data.types.ToA = @splat(&.{});
    const split_signal: [][]const lma.data.types.ToA = split_signal_buffer[0..count];
    var split_weight_buffer: [max_stations][]Float = @splat(&.{});
    const split_weights: [][]Float = split_weight_buffer[0..count];

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
    var corr_values_buffer = try init.gpa.alloc(Float, corr_values_buffer_size);
    defer init.gpa.free(corr_values_buffer);

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

    var merged: std.ArrayList(match.Signal) = .empty;
    defer merged.deinit(init.gpa);
    var sources: std.ArrayList(lma.data.types.Point) = .empty;
    defer sources.deinit(init.gpa);

    for (0..10 * 60) |t| {
        const header = try output.headers.addOne(init.gpa);
        header.* = .{ .start = @intCast(output.array.items.len), .size = 0 };
        defer header.size = @intCast(output.array.items.len - header.start);

        for (full_signals, signals, weights, split_indexes) |full_signal, *signal, *weight, *split_index| {
            signal.* = full_signal.valuesAt(full_signal.epochIndex(12 * 60 * 60 + t, .exact));
            weight.clearRetainingCapacity();
            const weight_slice = try weight.addManyAsSlice(init.gpa, signal.len);
            weight_mode.calculate(signal.*, weight_slice);
            match.splitTime(signal.*, split_index);
        }

        for (0..subdivisions) |division| {
            var size: usize = 0;
            for (0..count) |idx| {
                const div_index = split_indexes[idx][division];
                split_signal[idx] = div_index.get(signals[idx]);
                split_weights[idx] = div_index.get(weights[idx].items);
                size += split_signal[idx].len;
            }
            merged.clearRetainingCapacity();
            try merged.ensureTotalCapacity(init.gpa, size);
            sources.clearRetainingCapacity();
            try sources.ensureTotalCapacity(init.gpa, size);

            match.correlationMatrix(split_signal, split_weights, &unscaled_correlation_buffer, step, corr_matrix);
            match.mergeSignals(split_signal, &merged);

            const solver: Solver = .{ .points = points };
            match.synchornize(
                max_matches,
                min_stations,
                merged.items,
                &sources,
                .{ .step = step, .shape = shape, .active_stations = active_stations, .corr_matrix = corr_matrix, .time_matrix = time_matrix },
                &solver,
                Solver.solve,
            );
            try output.array.appendSlice(init.gpa, sources.items);
        }
        // Sort last block
        // Shift back and adjust previous header
    }

    {
        var file_writer = options.output.writer(init.io, &buffer);
        try output.toCsv(&file_writer.interface, null);
    }

    std.debug.print("Total points: {d}\n", .{output.array.items.len});
}

const Solver = struct {
    points: []const lma.pipeline.zlm(Precise).Vec3,

    inline fn fromNano(nanosecond: u32) Precise {
        return lma.constants.nano.fromNano(Precise, nanosecond);
    }

    inline fn square(value: anytype) @TypeOf(value) {
        return value * value;
    }

    pub fn solve(self: *const Solver, signals: []const match.Signal) ?lma.data.types.Point {
        var biases: [min_stations - 1]Precise = undefined;
        var coefficients: [min_stations - 1]@Vector(4, Precise) = undefined;
        const center = self.points[signals[0].station];
        const time = fromNano(signals[0].nanosecond);
        for (1..min_stations) |station| {
            const delta = self.points[signals[station].station].sub(center);
            const delta_t = lma.constants.c * (fromNano(signals[station].nanosecond) - time);
            biases[station - 1] = delta.length2() - square(delta_t);
            coefficients[station - 1] = .{ 2 * delta.x, 2 * delta.y, 2 * delta.z, -2 * delta_t };
        }

        const point = lma.pipeline.solver(Precise).approxSolve(coefficients, biases);
        const arr: [4]Precise = point;
        if (lma.pipeline.zlm(Precise).vec3(arr[0], arr[1], arr[2]).length() > max_distance) return null;
        const xyz: lma.pipeline.zlm(Precise).Vec3 = center.add(.new(arr[0], arr[1], arr[2]));
        const t = time + arr[3] / lma.constants.c;
        var mask: u32 = 0;
        var max_error: Precise = 0;
        for (0..min_stations) |station| {
            const delta = self.points[signals[station].station].sub(xyz).length();
            const delta_t = fromNano(signals[station].nanosecond) - t;
            mask |= @as(u32, 1) << @intCast(signals[station].station);
            if (delta_t <= 0) return null;
            max_error = @max(max_error, @abs(delta / lma.constants.c - delta_t));
        }

        const threshold = 0.000_010;
        if (max_error < threshold) {
            const gps = lma.pipeline.transform.xyzToGPS(f32, xyz);
            if (t <= 0) return null;
            const nano = lma.constants.nano.toNano(t);
            return .{
                .nanosecond = nano,
                .latitude = gps.x,
                .longitude = gps.y,
                .altitude = gps.z,
                .station_mask = mask,
                .measure_error = @floatCast(max_error / threshold),
                .dBm = 0,
            };
        }
        return null;
    }
};
