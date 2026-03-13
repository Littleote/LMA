const std = @import("std");

const lma = @import("../lma.zig");
const common = lma.common;
const ToA = lma.data.types.ToA;
const Point = lma.data.types.Point;
pub const SubSlice = lma.SubSlice;

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
            .step = lma.nano.fromNano(Float, @as(u32, 1) << shift),
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
    /// Combination of a baseline constant value and the rescaled decibels
    @"const+decibels",

    inline fn binning(dBm: f16) usize {
        return @intFromFloat(@trunc(std.math.clamp(dBm + 90, 0, 119)));
    }

    /// Calculate the sparse time series values given the ToA data
    pub fn calculate(method: Weights, slice: []const ToA, weights: []Float) void {
        switch (method) {
            .power => {
                const factor = @log2(10.0) / 10.0;
                // Upscale power by 100_000 to make the mean order of magnitude around 1
                for (slice, weights) |toa, *w| w.* = @exp2(16.5 + factor * lma.cast.as(Float, toa.dBm));
            },
            .decibels => {
                // Downscale decibels by 100 to make the vales around 1
                for (slice, weights) |toa, *w| w.* = lma.cast.as(Float, toa.dBm) / 100.0 + 1.0;
            },
            .cumulative => {
                var bins: [120]Float = @splat(0);
                const inc = 1.0 / lma.cast.to(Float, slice.len);
                for (slice) |toa| bins[binning(toa.dBm)] += inc;
                for (1..120) |idx| bins[idx] += bins[idx - 1];
                for (slice, weights) |toa, *w| w.* = bins[binning(toa.dBm)];
            },
            .constant => {
                @memset(weights, 1);
            },
            .@"const+decibels" => {
                for (slice, weights) |toa, *w| w.* = lma.cast.as(Float, toa.dBm) / 100.0 + 2.0;
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

fn before(time: u32, toa: ToA) bool {
    return toa.nanosecond < time;
}

/// Find the index of the first value with time equal or less than requested
fn findTime(slice: []const ToA, time: u32) u32 {
    return @intCast(std.sort.partitionPoint(ToA, slice, time, before));
}

/// Find the SubSlice for the given time span
pub fn getSpan(slice: []const ToA, span: SubSlice) SubSlice {
    const start = findTime(slice, span.start);
    return .init(start, findTime(slice[start..], span.end()));
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
    @memset(corr, 0);
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
/// to approximately -0.5 and 0.5 respectively.
pub fn quantileScale(unscaled: []const Float, scaled: []Float) void {
    @memcpy(scaled, unscaled);
    std.sort.block(Float, scaled, {}, std.sort.asc(Float));
    const ceil: usize = if ((scaled.len - 1) % 4 != 0) 1 else 0;
    const q1_idx: usize = @divFloor(scaled.len - 1, 4);
    const q3_idx: usize = @divFloor(3 * (scaled.len - 1), 4);
    const q1 = (scaled[q1_idx] + scaled[q1_idx + ceil]) / 2;
    const q3 = (scaled[q3_idx] + scaled[q3_idx + ceil]) / 2;
    const iqr = q3 - q1;
    const center = (q1 + q3) / 2;
    for (unscaled, scaled) |c, *s| s.* = (c - center) / iqr;
}

/// Computes the lower triangle of the matrix of scaled cross-correlation vectors for the given time span.
/// If the upper triangle is non-null makes a copy with the reversed cross-correlation vectors
pub fn newCorrelationMatrix(signals: []const []const ToA, weights: []const []const Float, aux_buffer: []Float, span: SubSlice, step: Step, corr_matrix: []const ?[]Float) void {
    const stations: u32 = @intCast(signals.len);
    const shape: lma.pipeline.Grid = .init(stations, stations);
    for (0..stations) |row| {
        const row_split = getSpan(signals[row], span);
        for (0..row) |col| {
            const col_split = getSpan(signals[col], span);
            const corr = corr_matrix[shape.ravel(row, col)] orelse continue;
            const unscaled = aux_buffer[0..corr.len];
            correlation(
                row_split.getConst(ToA, signals[row]),
                row_split.getConst(Float, weights[row]),
                col_split.getConst(ToA, signals[col]),
                col_split.getConst(Float, weights[col]),
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

pub const Config = struct {
    max_network: u16,
    min_candidates: u16,
    pairing_window: u16,
};

pub const Options = struct {
    pub const Search = struct {
        pub const Attempts = enum(u16) {
            single = 1,
            unlimited = std.math.maxInt(u16),
            _,

            pub fn count(value: u16) Attempts {
                return @enumFromInt(value);
            }
        };

        min_pair_corr: Float,
        min_base_corr: Float,
        min_cum_corr: Float,
        corr_limit: Float,
        attempts: Attempts,

        pub const bad_value: Float = -1_000.0;

        pub const yolo: Search = .{
            .min_pair_corr = 0.0,
            .min_base_corr = 1.5,
            .min_cum_corr = 1.0,
            .corr_limit = 10.0,
            .attempts = .single,
        };

        pub const exhaustive: Search = .{
            .min_pair_corr = 0.5,
            .min_base_corr = 2.0,
            .min_cum_corr = 1.5,
            .corr_limit = 5.0,
            .attempts = .unlimited,
        };

        pub const unrestricted: Search = .{
            .min_pair_corr = 0.0,
            .min_base_corr = 0.0,
            .min_cum_corr = 0.0,
            .corr_limit = 10.0,
            .attempts = .count(3),
        };
    };

    pub const Correlation = struct {
        matrix: []const ?[]Float,
        aux_buffer: []Float,
        window_size: u32,
        refresh_rate: u32,

        pub fn endpoints(self: Correlation, start: u32) SubSlice {
            const from = start +| (self.refresh_rate / 2) -| (self.window_size / 2);
            const to = start +| (self.refresh_rate / 2) +| (self.window_size / 2);
            return .initRange(from, to);
        }
    };

    step: Step,
    shape: lma.pipeline.Grid,

    search: Search,
    corr: Correlation,
    time_matrix: []const u32,
};

inline fn queryCorrelation(
    reference: Signal,
    candidates: []const Signal,
    corr_buffer: []Float,
    options: *const Options,
) []Float {
    for (candidates, corr_buffer[0..candidates.len]) |candidate, *corr_value| {
        corr_value.* = blk: {
            if (reference.station == candidate.station) break :blk Options.Search.bad_value;
            const idx = options.shape.ravel(reference.station, candidate.station);
            const max_time = options.time_matrix[idx];
            const delta = @max(reference.nanosecond, candidate.nanosecond) - @min(reference.nanosecond, candidate.nanosecond);
            if (delta > max_time) break :blk Options.Search.bad_value;
            const corr_true_value = options.step.get(options.corr.matrix[idx] orelse break :blk Options.Search.bad_value, reference.nanosecond, candidate.nanosecond);
            break :blk if (corr_true_value < options.search.min_pair_corr) Options.Search.bad_value else @min(options.search.corr_limit, corr_true_value);
        };
    }
    return corr_buffer[0..candidates.len];
}

inline fn matchInner(
    comptime config: Config,
    comptime depth: usize,
    candidates: []const Signal,
    matches: *[config.min_candidates]Signal,
    weights: []Float,
    skips: []u32,
    options: *const Options,
    context: anytype,
    solve: fn (@TypeOf(context), []const Signal, []const Signal, []u32) ?Point,
) ?Point {
    if (depth == 0) {
        return solve(context, matches, candidates, skips);
    } else {
        var weight_buffer: [config.max_network * config.pairing_window]Float = undefined;
        for (0..@intFromEnum(options.search.attempts)) |_| {
            const best = std.sort.argMax(Float, weights, {}, std.sort.asc(Float)) orelse break;
            if (weights[best] < options.search.min_base_corr) break;
            matches[config.min_candidates - depth] = candidates[best];

            const new_weights = queryCorrelation(candidates[best], candidates, &weight_buffer, options);
            for (weights, new_weights) |w, *nw| nw.* += w - options.search.min_cum_corr;

            if (matchInner(
                config,
                depth - 1,
                candidates,
                matches,
                new_weights,
                skips,
                options,
                context,
                solve,
            )) |point| return point;
            weights[best] = Options.Search.bad_value;
        }
        return null;
    }
}

pub fn match(
    comptime config: Config,
    signals: []const []const ToA,
    weights: []const []const Float,
    options: *const Options,
    point_buffer: []Point,
    context: anytype,
    solve: fn (@TypeOf(context), []const Signal, []const Signal, []u32) ?Point,
) []Point {
    std.debug.assert(signals.len <= config.max_network);
    const max_nano: u32 = std.math.maxInt(u32);
    var points: std.ArrayList(Point) = .initBuffer(point_buffer);

    // Merge
    var index: [config.max_network]u16 = @splat(0);
    var nano_buffer: [config.max_network]u32 = undefined;
    var skips: [config.max_network]u32 = @splat(0);
    for (0..signals.len) |idx| nano_buffer[idx] = if (signals[idx].len > 0) signals[idx][0].nanosecond else max_nano;
    const nanos: []u32 = nano_buffer[0..signals.len];

    // Correlation
    var last_update: u32 = std.sort.min(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
    newCorrelationMatrix(signals, weights, options.corr.aux_buffer, options.corr.endpoints(last_update), options.step, options.corr.matrix);

    // Matching
    var matches: [config.min_candidates]Signal = @splat(.{ .nanosecond = 4_000_000_000, .index = 99, .station = 99 });
    var candidate_buffer: [config.max_network * config.pairing_window]Signal = undefined;
    var weight_buffer: [config.max_network * config.pairing_window]Float = undefined;

    while (true) {
        const idx = std.sort.argMin(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
        defer {
            index[idx] += 1;
            skips[idx] >>= 1;
            nanos[idx] = if (index[idx] >= signals[idx].len) max_nano else signals[idx][index[idx]].nanosecond;
        }
        // End after processing all
        if (nanos[idx] == max_nano) {
            @branchHint(.unlikely);
            break;
        }
        // Skip already matched signals
        if (skips[idx] & 1 == 1) {
            @branchHint(.unlikely);
            continue;
        }
        // Update outdated correlation matrix
        if (nanos[idx] > last_update + options.corr.refresh_rate) {
            @branchHint(.unlikely);
            last_update = nanos[idx];
            newCorrelationMatrix(signals, weights, options.corr.aux_buffer, options.corr.endpoints(last_update), options.step, options.corr.matrix);
        }

        // Match buffer
        const initial: Signal = .{
            .nanosecond = nanos[idx],
            .index = 0,
            .station = @intCast(idx),
        };
        matches[0] = initial;
        var candidates: std.ArrayList(Signal) = .initBuffer(&candidate_buffer);

        // Get all possible paired signals
        for (0..signals.len) |station| {
            const signal = signals[station][index[station]..];
            for (signal[0..@min(signal.len, config.pairing_window)], 0..) |toa, bit_idx| {
                if (nanos[idx] + options.time_matrix[options.shape.ravel(idx, station)] < toa.nanosecond) break;
                if ((skips[station] >> @intCast(bit_idx)) & 1 == 1) continue;
                candidates.appendAssumeCapacity(.{
                    .nanosecond = toa.nanosecond,
                    .index = @intCast(bit_idx),
                    .station = @intCast(station),
                });
            }
        }

        // std.debug.print("CANDIDATES:\n", .{});
        // for (candidates.items) |c| {
        //     std.debug.print("\t{any}\n", .{c});
        // }

        if (matchInner(
            config,
            config.min_candidates - 1,
            candidates.items,
            &matches,
            queryCorrelation(initial, candidates.items, &weight_buffer, options),
            skips[0..signals.len],
            options,
            context,
            solve,
        )) |point|
            points.appendAssumeCapacity(point);
    }
    return points.items;
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
    var buffer: [16]ToA = getToA(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    try std.testing.expect(findTime(&buffer, 0) == 0);
    try std.testing.expect(findTime(&buffer, std.math.maxInt(u32)) == 16);
    try std.testing.expect(findTime(&buffer, buffer[12].nanosecond) == 12);
    try std.testing.expect(findTime(&buffer, buffer[3].nanosecond + 5) == 4);
    try std.testing.expect(findTime(&buffer, buffer[9].nanosecond - 5) == 9);
}

test getSpan {
    var sequence: [16]ToA = getToA(1, &.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 });

    try std.testing.expectEqual(SubSlice.initRange(3, 7), getSpan(&sequence, .initRange(7, 11)));
    try std.testing.expectEqual(SubSlice.initRange(0, 1), getSpan(&sequence, .initRange(1, 5)));
    try std.testing.expectEqual(SubSlice.initRange(13, 16), getSpan(&sequence, .initRange(17, 23)));
}

test "autocorrelation" {
    var signal: [16]ToA = getToA(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    var weights: [16]Float = @splat(1);
    var corr_buffer: [5]Float = @splat(std.math.nan(Float));

    correlation(&signal, &weights, &signal, &weights, &corr_buffer, .fromPower(-1));
    try std.testing.expect(corr_buffer[corr_buffer.len >> 1] == 16.0);
    corr_buffer[corr_buffer.len >> 1] = 0;
    try std.testing.expect(std.mem.allEqual(Float, &corr_buffer, 0));
}

test correlation {
    const length = 20;
    const signal_x: [length]ToA = getToA(4, &.{ 6, 7, 11, 15, 23, 33, 37, 43, 46, 51, 59, 66, 75, 84, 86, 93, 101, 109, 118, 120 });
    const weights_x: [length]Float = .{ 10, 10, 1, 5, 8, 4, 3, 8, 3, 1, 1, 5, 6, 6, 7, 9, 5, 2, 5, 10 };
    const signal_y: [length]ToA = getToA(4, &.{ 6, 16, 25, 35, 40, 44, 45, 49, 55, 56, 59, 63, 72, 74, 78, 82, 86, 94, 95, 97 });
    const weights_y: [length]Float = .{ 9, 2, 2, 8, 10, 10, 4, 7, 8, 3, 1, 4, 6, 10, 5, 5, 7, 5, 5, 4 };
    var corr: [21]Float = undefined;
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

// test mergeSignals {
//     const length = 74;
//     const signals: [5][]const ToA = .{
//         &getToA(1, &.{ 15, 19, 23, 31, 41, 61, 80, 85, 92, 105, 107, 114, 122, 137, 155 }),
//         &getToA(1, &.{ 27, 36, 46, 66, 83, 103, 109, 125, 141, 142, 161, 165, 183, 203, 223 }),
//         &getToA(1, &.{ 32, 40, 41, 43, 53, 54, 65, 69, 81, 100, 103, 104, 105 }),
//         &getToA(1, &.{ 21, 28, 37, 55, 71, 76, 86, 97, 99, 101, 109, 119, 123, 130 }),
//         &getToA(1, &.{ 27, 42, 61, 62, 77, 81, 94, 105, 117, 122, 129, 134, 150, 154, 167, 172, 181 }),
//     };

//     var buffer: [length]Signal = undefined;
//     var merged: std.ArrayList(Signal) = .initBuffer(&buffer);
//     mergeSignals(&signals, &merged);

//     const expected_times: [length]u32 = .{ 15, 19, 21, 23, 27, 27, 28, 31, 32, 36, 37, 40, 41, 41, 42, 43, 46, 53, 54, 55, 61, 61, 62, 65, 66, 69, 71, 76, 77, 80, 81, 81, 83, 85, 86, 92, 94, 97, 99, 100, 101, 103, 103, 104, 105, 105, 105, 107, 109, 109, 114, 117, 119, 122, 122, 123, 125, 129, 130, 134, 137, 141, 142, 150, 154, 155, 161, 165, 167, 172, 181, 183, 203, 223 };
//     const expected_stations: [length]u16 = .{ 0, 0, 3, 0, 1, 4, 3, 0, 2, 1, 3, 2, 0, 2, 4, 2, 1, 2, 2, 3, 0, 4, 4, 2, 1, 2, 3, 3, 4, 0, 2, 4, 1, 0, 3, 0, 4, 3, 3, 2, 3, 1, 2, 2, 0, 2, 4, 0, 1, 3, 0, 4, 3, 0, 4, 3, 1, 4, 3, 4, 0, 1, 1, 4, 4, 0, 1, 1, 4, 4, 4, 1, 1, 1 };
//     const expected_index: [length]u16 = .{ 0, 1, 0, 2, 0, 0, 1, 3, 0, 1, 2, 1, 4, 2, 1, 3, 2, 4, 5, 3, 5, 2, 3, 6, 3, 7, 4, 5, 4, 6, 8, 5, 4, 7, 6, 8, 6, 7, 8, 9, 9, 5, 10, 11, 9, 12, 7, 10, 6, 10, 11, 8, 11, 12, 9, 12, 7, 10, 13, 11, 13, 8, 9, 12, 13, 14, 10, 11, 14, 15, 16, 12, 13, 14 };

//     for (0..length) |idx| {
//         const expected: Signal = .{
//             .nanosecond = expected_times[idx],
//             .station = expected_stations[idx],
//             .index = expected_index[idx],
//         };
//         if (!std.meta.eql(merged.items[idx], expected)) {
//             std.debug.print("Expected:\n{any}\nFound:\n{any}\nIn position: {d}\n", .{ expected, merged.items[idx], idx });
//             return error.TestExpectedEqual;
//         }
//     }
// }
