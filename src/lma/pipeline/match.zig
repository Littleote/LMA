const std = @import("std");

const lma = @import("../lma.zig");
const common = lma.common;
const ToA = lma.data.types.ToA;
const Point = lma.data.types.Point;
const max_stations = lma.constants.max_stations;

pub const Float = f32;

/// Step size for discretizing the signal
pub const Step = struct {
    /// Step size in seconds
    step: Float,
    /// High bit of the nanosecond expressed with fixed precision 30.2
    /// Equivalent to how much to shift a bit to get the step size
    shift: u5,

    /// Generate a step size given the power of two of nanoseconds
    /// Some methods may fail for steps smaller than 1 nanosecond
    pub fn fromPower(pow: i8) Step {
        const shift: u5 = @intCast(pow + 2);
        return .{
            .step = lma.constants.nano.fromNano(Float, @as(u32, 1) << shift),
            .shift = shift,
        };
    }

    /// Generate a step size close to a desired size in seconds
    /// Some methods may fail for steps smaller than 1 nanosecond
    pub fn fromStep(desired_step: Float) Step {
        return .fromPower(@intFromFloat(@round(@log2(std.time.ns_per_s * desired_step))));
    }

    /// Calculate index into correlation vector
    pub fn get(step: Step, corr: []const Float, t0: u32, t1: u32) Float {
        const offset_round = corr.len << (step.shift - 1);
        const idx = (offset_round +% t0 -% t1) >> step.shift;
        return if (idx < corr.len) corr[idx] else 0;
    }
};

/// Method to generate a sparse time series given the sensors information
pub const Weights = enum {
    /// Indicator using the mili-watts from the lightinings.
    /// Very noisy, as any misidentified strong lightning has a huge impact.
    power,
    /// Indicator using the decibels with the noise level (-75 dBm) set to zero.
    decibels,
    /// Indicator using a non-parametric rescaling of the power to the range [0, 1].
    cumulative,
    /// Constant value set for all observations
    constant,

    inline fn binning(dBm: f16) usize {
        return @intFromFloat(@trunc(std.math.clamp(dBm + 90, 0, 119)));
    }

    /// Calculate the sparse time series values given the ToA data
    pub fn calculate(method: Weights, slice: []const ToA, weights: []Float) void {
        switch (method) {
            .power => {
                const factor = @log2(10.0) / 10.0;
                // Upscale power by 100_000 to make the mean order of magnitude around 1
                for (slice, weights) |toa, *w| w.* = @exp2(16.5 + factor * lma.common.as(Float, toa.dBm));
            },
            .decibels => {
                // Downscale decibels by 50 to make the mean of the vales around 1
                for (slice, weights) |toa, *w| w.* = (lma.common.as(Float, toa.dBm) + 75.0) / 50.0;
            },
            .cumulative => {
                var bins: [120]Float = @splat(0);
                // Set the total to 2 to make the mean of the vales around 1
                const inc = 2.0 / lma.common.cast(Float, slice.len);
                for (slice) |toa| bins[binning(toa.dBm)] += inc;
                for (1..120) |idx| bins[idx] += bins[idx - 1];
                for (slice, weights) |toa, *w| w.* = bins[binning(toa.dBm)];
            },
            .constant => {
                @memset(weights, 1);
            },
        }
    }
};

/// Data used from the signal to match values
pub const Signal = struct {
    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: u32,
    /// Index of the station that generate this signal
    station: u16,
    /// Position in the array for this signal
    index: u16,
};

/// Find the index of the first value with time equal or less than requested
fn findTime(slice: []const ToA, time: u32) u32 {
    // Short-circuit for the empty case
    if (slice.len == 0) return 0;

    // Binary search of the nanosecond
    var low: u32 = 0;
    var high: u32 = @intCast(slice.len);
    var size: u32 = high - low;

    while (size > 1) {
        const probe = low + @divFloor(size, 2);
        if (slice[probe].nanosecond < time) {
            low = probe + 1;
        } else if (time < slice[probe].nanosecond) {
            high = probe;
        } else {
            return probe;
        }
        size = high - low;
    }
    low = high - 1;
    return if (slice[low].nanosecond < time) high else low;
}

pub const Split = lma.common.SubSlice;

pub fn splitTime(slice: []const ToA, splits: []Split) void {
    var last: u32 = 0;
    for (splits, 1..) |*split, division| {
        const end: u32 = @intCast(findTime(slice, @intCast(division * lma.constants.nano.ratio / splits.len)));
        split.* = .{
            .start = last,
            .size = end - last,
        };
        last = end;
    }
}

/// Find the correlation between the sparse signals x and y.
///
/// Time described by the nanosecond of the ToA field.
/// Weight described by the weights slice.
pub fn correlation(signal_x: []const ToA, weights_x: []const Float, signal_y: []const ToA, weights_y: []const Float, corr: []Float, step: Step) void {
    const offset_round: usize = @intCast(corr.len << (step.shift - 1));
    const above: u32 = @intCast(offset_round);
    const below: u32 = above - 1;
    var low: u32 = 0;
    var high: u32 = 0;
    var upper: u32 = 0;
    for (signal_x, weights_x) |x, wx| {
        const threshold = x.nanosecond +| above;
        var backoff: u5 = 0;
        upper = high;
        while (upper < signal_y.len) : ({
            upper += @as(u32, 1) << backoff;
            backoff += 1;
        }) {
            if (signal_y[upper].nanosecond > threshold) break;
        } else {
            upper = @intCast(signal_y.len);
        }
        high = high + findTime(signal_y[high..upper], threshold);
        low = low + findTime(signal_y[low..high], x.nanosecond -| below);
        for (signal_y[low..high], weights_y[low..high]) |y, wy| {
            const idx = (offset_round + x.nanosecond - y.nanosecond) >> step.shift;
            corr[idx] += wx * wy;
        }
    }
}

/// Translates and reescales the correlation to map the first and third quantile
/// to -0.5 and 0.5 respectively.
pub fn quantileScale(unscaled: []const Float, scaled: []Float) void {
    @memcpy(scaled, unscaled);
    std.sort.block(Float, scaled, {}, std.sort.asc(Float));
    const divFloor = std.math.divFloor;
    const divCeil = std.math.divCeil;
    const q1 = (scaled[divFloor(usize, scaled.len - 1, 4) catch unreachable] +
        scaled[divCeil(usize, scaled.len - 1, 4) catch unreachable]) / 2;
    const q3 = (scaled[divFloor(usize, 3 * (scaled.len - 1), 4) catch unreachable] +
        scaled[divCeil(usize, 3 * (scaled.len - 1), 4) catch unreachable]) / 2;
    const iqr = q3 - q1;
    const center = (q1 + q3) / 2;
    for (unscaled, scaled) |c, *s| s.* = (c - center) / iqr;
}

/// Computes the lower triangle of the matrix of scaled cross-correlation vectors
/// If the upper triangle is non-null makes a copy with the reversed cross-correlation vectors
pub fn correlationMatrix(signals: []const []const ToA, weights: []const []const Float, aux_buffer: []Float, step: Step, corr_matrix: []?[]Float) void {
    const stations: u32 = @intCast(signals.len);
    const shape: lma.pipeline.grid.Shape = .init(stations, stations);
    for (0..stations) |row| {
        for (0..row) |col| {
            const corr = corr_matrix[shape.ravel(row, col)] orelse continue;
            const unscaled = aux_buffer[0..corr.len];
            @memset(unscaled, 0);
            correlation(
                signals[row],
                weights[row],
                signals[col],
                weights[col],
                unscaled,
                step,
            );
            quantileScale(unscaled, corr);

            const rev_corr = corr_matrix[shape.ravel(col, row)] orelse continue;
            @memcpy(rev_corr, corr);
            std.mem.reverse(Float, rev_corr);
        }
    }
}

/// Merges the signals by order of arrival.
/// In case of ties, use the earlier station
pub fn mergeSignals(signals: []const []const ToA, merged: *std.ArrayList(Signal)) void {
    const stations = signals.len;
    std.debug.assert(stations <= max_stations);
    const max_nano: u32 = std.math.maxInt(u32);
    var index: [max_stations]u16 = @splat(0);
    var nano_buffer: [max_stations]u32 = @splat(max_nano);
    const nanos: []u32 = nano_buffer[0..stations];
    for (0..stations) |idx| nanos[idx] = if (signals[idx].len > 0) signals[idx][0].nanosecond else max_nano;
    while (true) {
        var earliest = nanos[0];
        var earsliest_idx: usize = 0;
        for (nanos[1..], 1..) |nano, idx| {
            if (earliest > nano) {
                earliest = nano;
                earsliest_idx = idx;
            }
        }
        if (earliest == max_nano) {
            @branchHint(.unlikely);
            break;
        }
        merged.appendAssumeCapacity(.{
            .nanosecond = earliest,
            .station = @intCast(earsliest_idx),
            .index = index[earsliest_idx],
        });
        index[earsliest_idx] += 1;
        if (index[earsliest_idx] == signals[earsliest_idx].len) {
            @branchHint(.unlikely);
            nanos[earsliest_idx] = max_nano;
        } else {
            @branchHint(.likely);
            nanos[earsliest_idx] = signals[earsliest_idx][index[earsliest_idx]].nanosecond;
        }
    }
}

pub const SyncOptions = struct {
    step: Step,
    shape: lma.pipeline.grid.Shape,
    active_stations: usize,
    min_station_corr: Float = -0.5,
    min_total_corr: Float = 1.5,
    min_increase_corr: Float = 0.5,
    limit_max_corr: Float = 20.0,
    yolo: bool = true,
    corr_matrix: []const ?[]const Float,
    time_matrix: []const u32,

    pub const bad_value: Float = -1_000.0;
};

inline fn getCorrelation(
    reference: Signal,
    candidates: []const Signal,
    corr: []Float,
    options: SyncOptions,
) void {
    for (candidates, corr) |candidate, *corr_value| {
        corr_value.* = blk: {
            if (reference.station == candidate.station) break :blk SyncOptions.bad_value;
            const idx = options.shape.ravel(reference.station, candidate.station);
            const max_time = options.time_matrix[idx];
            const delta = @max(reference.nanosecond, candidate.nanosecond) - @min(reference.nanosecond, candidate.nanosecond);
            if (delta > max_time) break :blk SyncOptions.bad_value;
            const corr_true_value = options.step.get(options.corr_matrix[idx] orelse break :blk SyncOptions.bad_value, reference.nanosecond, candidate.nanosecond);
            break :blk if (corr_true_value < options.min_station_corr) SyncOptions.bad_value else @min(options.limit_max_corr, corr_true_value);
        };
    }
}

inline fn syncInner(
    comptime depth: usize,
    comptime buffer_size: usize,
    signal_corr: [][buffer_size]Float,
    candidates: []const Signal,
    selected: []Signal,
    options: SyncOptions,
    context: anytype,
    solve: fn (@TypeOf(context), []const Signal) ?Point,
) ?Point {
    while (true) {
        const best = std.sort.argMax(Float, signal_corr[0][0..candidates.len], {}, std.sort.asc(Float)) orelse break;
        if (signal_corr[0][best] < options.min_total_corr) break;
        selected[depth] = candidates[best];

        if (depth == 0) {
            return solve(context, selected);
        } else {
            getCorrelation(candidates[best], candidates, signal_corr[1][0..candidates.len], options);
            for (0..candidates.len) |idx| signal_corr[1][idx] += signal_corr[0][idx] - options.min_increase_corr;
            if (syncInner(
                depth - 1,
                buffer_size,
                signal_corr[1..],
                candidates,
                selected,
                options,
                context,
                solve,
            )) |point| {
                return point;
            }
        }
        signal_corr[0][best] = -100;
        if (options.yolo) break;
    }
    return null;
}

pub fn synchornize(
    comptime station_candidates: usize,
    comptime min_stations: usize,
    merged: []const Signal,
    points: *std.ArrayList(Point),
    options: SyncOptions,
    context: anytype,
    solve: fn (@TypeOf(context), []const Signal) ?Point,
) void {
    const depth = min_stations - 1;
    const max_candidates: usize = options.active_stations * station_candidates;
    var corr_buffer: [min_stations][max_stations * station_candidates]Float = undefined;
    var selected_buffer: [min_stations]Signal = undefined;

    for (merged, 1..) |signal, low| {
        selected_buffer[depth] = signal;
        const high = @min(merged.len, low + max_candidates);
        const candidates = merged[low..high];
        getCorrelation(signal, candidates, corr_buffer[0][0..candidates.len], options);
        if (syncInner(
            depth - 1,
            max_stations * station_candidates,
            &corr_buffer,
            candidates,
            &selected_buffer,
            options,
            context,
            solve,
        )) |point| {
            points.appendAssumeCapacity(point);
        }
    }
}

fn randomToA(signal: []ToA, rand: std.Random) void {
    var nanosecond: u32 = 0;
    for (signal) |*entry| {
        nanosecond += 10 + common.cast(u32, (@round(1_000 * @min(100.0, rand.floatExp(Float)))));
        entry.* = .{
            .nanosecond = nanosecond,
            .dBm = common.as(f16, 200.0 * rand.float(Float) - 120.0),
        };
    }
}

inline fn getToA(scale: u32, comptime times: []const u32) [times.len]ToA {
    var out: [times.len]ToA = undefined;
    for (times, &out) |nano, *toa| {
        toa.* = .{
            .nanosecond = scale * nano,
            .dBm = 0.0,
        };
    }
    return out;
}

test findTime {
    var buffer: [512]ToA = undefined;
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomToA(&buffer, random);

    try std.testing.expect(findTime(&buffer, 0) == 0);
    try std.testing.expect(findTime(&buffer, std.math.maxInt(u32)) == 512);
    try std.testing.expect(findTime(&buffer, buffer[123].nanosecond) == 123);
    try std.testing.expect(findTime(&buffer, buffer[321].nanosecond + 5) == 322);
    try std.testing.expect(findTime(&buffer, buffer[98].nanosecond - 5) == 98);
}

test splitTime {
    const extremes: [10]ToA = getToA(4, &.{ 0, 199_999_999, 200_000_000, 399_999_999, 400_000_000, 599_999_999, 600_000_000, 799_999_999, 800_000_000, 999_999_999 });
    var splits: [5]Split = undefined;
    const expected: [5]Split = .{
        .{ .start = 0, .size = 2 },
        .{ .start = 2, .size = 2 },
        .{ .start = 4, .size = 2 },
        .{ .start = 6, .size = 2 },
        .{ .start = 8, .size = 2 },
    };

    splitTime(&extremes, &splits);

    try std.testing.expectEqualSlices(Split, &expected, &splits);
}

test "autocorrelation" {
    var signal: [512]ToA = undefined;
    var weights: [512]Float = @splat(1);
    var corr_buffer: [5]Float = @splat(0);
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomToA(&signal, random);

    correlation(&signal, &weights, &signal, &weights, &corr_buffer, .fromPower(-1));
    try std.testing.expect(corr_buffer[corr_buffer.len >> 1] == 512.0);
    corr_buffer[corr_buffer.len >> 1] = 0;
    try std.testing.expect(std.mem.allEqual(Float, &corr_buffer, 0));
}

test correlation {
    const length = 20;
    const signal_x: [length]ToA = getToA(4, &.{ 6, 7, 11, 15, 23, 33, 37, 43, 46, 51, 59, 66, 75, 84, 86, 93, 101, 109, 118, 120 });
    const weights_x: [length]Float = .{ 10, 10, 1, 5, 8, 4, 3, 8, 3, 1, 1, 5, 6, 6, 7, 9, 5, 2, 5, 10 };
    const signal_y: [length]ToA = getToA(4, &.{ 6, 16, 25, 35, 40, 44, 45, 49, 55, 56, 59, 63, 72, 74, 78, 82, 86, 94, 95, 97 });
    const weights_y: [length]Float = .{ 9, 2, 2, 8, 10, 10, 4, 7, 8, 3, 1, 4, 6, 10, 5, 5, 7, 5, 5, 4 };
    var corr: [21]Float = @splat(0);
    const expected: [21]Float = .{ 69, 79, 98, 100, 86, 5, 48, 81, 167, 135, 140, 162, 91, 139, 63, 9, 89, 119, 107, 45, 82 };

    correlation(&signal_x, &weights_x, &signal_y, &weights_y, &corr, .fromPower(0));

    try std.testing.expectEqualSlices(Float, &expected, &corr);
}

test quantileScale {
    const unscaled: [11]Float = .{ 12, 15, 0, 3, 3, 7, 9, 19, 18, 4, 6 };
    var scaled: [11]Float = undefined;
    const expected: [11]Float = .{ 0.35, 0.65, -0.85, -0.55, -0.55, -0.15, 0.05, 1.05, 0.95, -0.45, -0.25 };

    quantileScale(&unscaled, &scaled);

    try std.testing.expectEqualSlices(Float, &expected, &scaled);
}

test mergeSignals {
    const length = 74;
    const signals: [5][]const ToA = .{
        &getToA(1, &.{ 15, 19, 23, 31, 41, 61, 80, 85, 92, 105, 107, 114, 122, 137, 155 }),
        &getToA(1, &.{ 27, 36, 46, 66, 83, 103, 109, 125, 141, 142, 161, 165, 183, 203, 223 }),
        &getToA(1, &.{ 32, 40, 41, 43, 53, 54, 65, 69, 81, 100, 103, 104, 105 }),
        &getToA(1, &.{ 21, 28, 37, 55, 71, 76, 86, 97, 99, 101, 109, 119, 123, 130 }),
        &getToA(1, &.{ 27, 42, 61, 62, 77, 81, 94, 105, 117, 122, 129, 134, 150, 154, 167, 172, 181 }),
    };

    var buffer: [length]Signal = undefined;
    var merged: std.ArrayList(Signal) = .initBuffer(&buffer);
    mergeSignals(&signals, &merged);

    const expected_times: [length]u32 = .{ 15, 19, 21, 23, 27, 27, 28, 31, 32, 36, 37, 40, 41, 41, 42, 43, 46, 53, 54, 55, 61, 61, 62, 65, 66, 69, 71, 76, 77, 80, 81, 81, 83, 85, 86, 92, 94, 97, 99, 100, 101, 103, 103, 104, 105, 105, 105, 107, 109, 109, 114, 117, 119, 122, 122, 123, 125, 129, 130, 134, 137, 141, 142, 150, 154, 155, 161, 165, 167, 172, 181, 183, 203, 223 };
    const expected_stations: [length]u16 = .{ 0, 0, 3, 0, 1, 4, 3, 0, 2, 1, 3, 2, 0, 2, 4, 2, 1, 2, 2, 3, 0, 4, 4, 2, 1, 2, 3, 3, 4, 0, 2, 4, 1, 0, 3, 0, 4, 3, 3, 2, 3, 1, 2, 2, 0, 2, 4, 0, 1, 3, 0, 4, 3, 0, 4, 3, 1, 4, 3, 4, 0, 1, 1, 4, 4, 0, 1, 1, 4, 4, 4, 1, 1, 1 };
    const expected_index: [length]u16 = .{ 0, 1, 0, 2, 0, 0, 1, 3, 0, 1, 2, 1, 4, 2, 1, 3, 2, 4, 5, 3, 5, 2, 3, 6, 3, 7, 4, 5, 4, 6, 8, 5, 4, 7, 6, 8, 6, 7, 8, 9, 9, 5, 10, 11, 9, 12, 7, 10, 6, 10, 11, 8, 11, 12, 9, 12, 7, 10, 13, 11, 13, 8, 9, 12, 13, 14, 10, 11, 14, 15, 16, 12, 13, 14 };

    for (0..length) |idx| {
        const expected: Signal = .{
            .nanosecond = expected_times[idx],
            .station = expected_stations[idx],
            .index = expected_index[idx],
        };
        if (!std.meta.eql(merged.items[idx], expected)) {
            std.debug.print("Expected:\n{any}\nFound:\n{any}\nIn position: {d}\n", .{ expected, merged.items[idx], idx });
            return error.TestExpectedEqual;
        }
    }
}
