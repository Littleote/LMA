const std = @import("std");

const lma = @import("../lma.zig");
const Signal = lma.data.types.Signal;
const Point = lma.data.types.Point;
const SubSlice = lma.index.SubSlice;

pub const probing = @import("match/probing.zig");
pub const search = @import("match/search.zig");

pub const Float = f32;
pub const TimeSpan = SubSlice;
const Nano = lma.nano.Nano;

/// Step size for discretizing the signal during the crosscorrelation calculation.
pub const Step = struct {
    /// Step size in seconds.
    step: Float,
    /// How much to shift a bit to get the step size with fixed precision 30.2 ns.
    shift: u5,

    /// Generate a step size of `2^pow` ns.
    pub fn fromPower(pow: i8) Step {
        const shift: u5 = @intCast(pow + 2);
        return .{
            .step = lma.nano.fromNano(Float, @as(Nano, 1) << shift),
            .shift = shift,
        };
    }

    /// Generate a step size of `2^N` ns that best approximates `desired_step` s.
    ///
    /// Some methods may fail for steps smaller than 1 nanosecond.
    pub fn fromStep(desired_step: Float) Step {
        return .fromPower(@intFromFloat(@round(@log2(std.time.ns_per_s * desired_step))));
    }

    /// Calculate index into correlation vector
    pub fn get(step: Step, corr: []const Float, t0: Nano, t1: Nano) Float {
        const offset_round = corr.len << (step.shift - 1);
        const idx = (offset_round +% t0 -% t1) >> step.shift;
        return if (idx < corr.len) corr[idx] else 0;
    }
};

/// Method to generate the time series from the station data.
pub const Weights = enum {
    /// Indicator using the mili-watts from the lightinings.
    ///
    /// NOTE:
    /// Very noisy, due to high values being exponentially more representative.
    power,

    /// Indicator using the decibels with the noise level (-75 dBm) set to zero.
    decibels,

    /// Indicator using a non-parametric rescaling of the power to the range [0, 1].
    cumulative,

    /// Constant value `1` set for all observations.
    constant,

    /// Combination of a baseline constant `1` value and the rescaled decibels (with the noise level at -75 dBm).
    @"const+decibels",

    const bin_count = 120;
    const noise_level = 75.0;

    inline fn binning(dBm: f16) usize {
        return @intFromFloat(@trunc(std.math.clamp(dBm + 90, 0, bin_count - 1)));
    }

    /// Generate the time series from the station data.
    pub fn calculate(method: Weights, slice: []const Signal, weights: []Float) void {
        switch (method) {
            .power => {
                const factor = @log2(10.0) / 10.0;
                // Upscale power by 100_000 to make the mean order of magnitude around 1
                for (slice, weights) |signal, *w| w.* = @exp2(16.5 + factor * lma.cast.as(Float, signal.dBm));
            },
            .decibels => {
                // Downscale decibels to make the values near 1
                for (slice, weights) |signal, *w| w.* = @max(0.0, lma.cast.as(Float, signal.dBm) / noise_level + 1.0);
            },
            .cumulative => {
                var bins: [bin_count]Float = @splat(0);
                const inc = 1.0 / lma.cast.to(Float, slice.len);
                for (slice) |signal| bins[binning(signal.dBm)] += inc;
                for (1..bin_count) |idx| bins[idx] += bins[idx - 1];
                for (slice, weights) |signal, *w| w.* = bins[binning(signal.dBm)];
            },
            .constant => {
                @memset(weights, 1);
            },
            .@"const+decibels" => {
                for (slice, weights) |signal, *w| w.* = @max(0.0, lma.cast.as(Float, signal.dBm) / noise_level + 2.0);
            },
        }
    }
};

/// Data corresponding to an event with extra information to help the matching
pub const Candidate = struct {
    pub const Mask = u32;
    pub const MaskBit = packed struct(u8) {
        is_set: bool,
        _padding: u2 = 0,
        bit: u5,

        pub fn set(bit: u5) MaskBit {
            return .{ .is_set = true, .bit = bit };
        }

        pub const unset: MaskBit = .{ .is_set = false, .bit = 0 };

        pub inline fn getBit(self: MaskBit) ?u5 {
            if (self.is_set) self.bit else null;
        }
    };

    /// Event time since start of the second with fixed precision 30.2 ns.
    nanosecond: Nano,
    /// Index of the event in the signal data relative to the start of the second.
    index: u32,
    /// Event power in decibel-milliwatts.
    dBm: f16,
    /// Index of the station that generated the event.
    station: u8,
    /// Bit in the mask to indicate that this event has already been matched.
    mask: MaskBit,
};

/// Predicate for signal time comparison.
fn signalBefore(time: u32, signal: Signal) bool {
    return signal.nanosecond < time;
}

/// Find the index of the first event at or after the requested time.
fn findTime(slice: []const Signal, time: Nano) u32 {
    return @intCast(std.sort.partitionPoint(Signal, slice, time, signalBefore));
}

/// Find the sub-slice corresponding the given time span.
pub fn getSpan(slice: []const Signal, span: TimeSpan) SubSlice {
    const start = findTime(slice, span.start);
    return .init(start, findTime(slice[start..], span.end()));
}

test findTime {
    var buffer: [16]Signal = getSignals(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    try std.testing.expect(findTime(&buffer, 0) == 0);
    try std.testing.expect(findTime(&buffer, std.math.maxInt(u32)) == 16);
    try std.testing.expect(findTime(&buffer, buffer[12].nanosecond) == 12);
    try std.testing.expect(findTime(&buffer, buffer[3].nanosecond + 5) == 4);
    try std.testing.expect(findTime(&buffer, buffer[9].nanosecond - 5) == 9);
}

test getSpan {
    var sequence: [16]Signal = getSignals(1, &.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 });

    try std.testing.expectEqual(SubSlice.initRange(3, 7), getSpan(&sequence, .initRange(7, 11)));
    try std.testing.expectEqual(SubSlice.initRange(0, 1), getSpan(&sequence, .initRange(1, 5)));
    try std.testing.expectEqual(SubSlice.initRange(13, 16), getSpan(&sequence, .initRange(17, 23)));
}

/// Find the correlation between the sparse time series X and Y.
///
/// The time of the events are in `signal[i].nanosecond`.
/// The height of the events from the in `weight[i]`.
/// The width of the sampling is `step`.
/// The output cross-correlation is `corr[i]`.
///
/// The correlation is calculated for a total of `corr.len` lags centered on `0`.
/// This means that `corr.len` should be odd.
pub fn correlation(signal_x: []const Signal, weights_x: []const Float, signal_y: []const Signal, weights_y: []const Float, step: Step, corr: []Float) void {
    std.debug.assert(corr.len & 1 == 1);
    const offset_round: usize = @intCast(corr.len << (step.shift - 1));
    const above: u32 = @intCast(offset_round);
    const below: u32 = above - 1;
    var span_start: u32 = 0;
    var span_end: u32 = 0;
    var upper: u32 = 0;
    @memset(corr, 0);
    for (signal_x, weights_x) |x, wx| {
        const threshold = x.nanosecond +| above;
        var backoff: u5 = 0;
        upper = span_end;
        while (upper < signal_y.len) : ({
            upper += @as(u32, 1) << backoff;
            backoff += 1;
        }) {
            if (signal_y[upper].nanosecond > threshold) break;
        } else {
            upper = @intCast(signal_y.len);
        }
        span_end = span_end + findTime(signal_y[span_end..upper], threshold);
        span_start = span_start + findTime(signal_y[span_start..span_end], x.nanosecond -| below);
        for (signal_y[span_start..span_end], weights_y[span_start..span_end]) |y, wy| {
            const idx = (offset_round + x.nanosecond - y.nanosecond) >> step.shift;
            corr[idx] += wx * wy;
        }
    }
}

/// Computes the cross-correlation matrix for the given time span.
/// The results are then transformed to an approximation of the log-likelihood function.
///
/// If the indices for the lower triangle have a size of zero, the cross-correlation for that pair is not computed.
/// If the indices for the upper triangle have a non-zero size, the cross-correlation is copied and reversed from the lower triangle.
///
/// The values of `indices[i, j]` indicate the index in `buffer[k..l]` where to store the result.
/// The values of `aux_buffer[0..i]` should be at least as big as the biggest cross-correlation.
pub fn correlationMatrix(signals: []const []const Signal, weights: []const []const Float, span: TimeSpan, step: Step, buffer: []Float, indices: []const SubSlice, aux_buffer: []Float) void {
    const stations: u32 = @intCast(signals.len);
    const shape: lma.grid.Shape = .init(stations, stations);
    for (0..stations) |row| {
        const row_split = getSpan(signals[row], span);
        for (0..row) |col| {
            const col_split = getSpan(signals[col], span);
            const corr = indices[shape.ravel(row, col)].getReference(Float, buffer);
            if (corr.len == 0) continue;
            correlation(
                row_split.getConst(Signal, signals[row]),
                row_split.getConst(Float, weights[row]),
                col_split.getConst(Signal, signals[col]),
                col_split.getConst(Float, weights[col]),
                step,
                corr,
            );
            quantileScale(corr, aux_buffer[0..corr.len]);

            const rev_corr = indices[shape.ravel(col, row)].getReference(Float, buffer);
            if (rev_corr.len == 0) continue;
            @memcpy(rev_corr, corr);
            std.mem.reverse(Float, rev_corr);
        }
    }

    lma.grid.apply(Float).loglikelihoodApprox(buffer, 0.7412898443291327);
}

test "autocorrelation" {
    var signal: [16]Signal = getSignals(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    var weights: [16]Float = @splat(1);
    var corr_buffer: [5]Float = @splat(std.math.nan(Float));

    correlation(&signal, &weights, &signal, &weights, .fromPower(-1), &corr_buffer);
    try std.testing.expect(corr_buffer[corr_buffer.len >> 1] == 16.0);
    corr_buffer[corr_buffer.len >> 1] = 0;
    try std.testing.expect(std.mem.allEqual(Float, &corr_buffer, 0));
}

test correlation {
    const length = 20;
    const signal_x: [length]Signal = getSignals(4, &.{ 6, 7, 11, 15, 23, 33, 37, 43, 46, 51, 59, 66, 75, 84, 86, 93, 101, 109, 118, 120 });
    const weights_x: [length]Float = .{ 10, 10, 1, 5, 8, 4, 3, 8, 3, 1, 1, 5, 6, 6, 7, 9, 5, 2, 5, 10 };
    const signal_y: [length]Signal = getSignals(4, &.{ 6, 16, 25, 35, 40, 44, 45, 49, 55, 56, 59, 63, 72, 74, 78, 82, 86, 94, 95, 97 });
    const weights_y: [length]Float = .{ 9, 2, 2, 8, 10, 10, 4, 7, 8, 3, 1, 4, 6, 10, 5, 5, 7, 5, 5, 4 };
    var corr: [21]Float = @splat(std.math.nan(Float));
    const expected: [21]Float = .{ 69, 79, 98, 100, 86, 5, 48, 81, 167, 135, 140, 162, 91, 139, 63, 9, 89, 119, 107, 45, 82 };

    correlation(&signal_x, &weights_x, &signal_y, &weights_y, .fromPower(0), &corr);

    try std.testing.expectEqualSlices(Float, &expected, &corr);
}

/// Normalize a set of values using the interquartile range (IQR).
///
/// Translate and reescale the values to map the first and third quantile to -0.5 and 0.5 respectively.
pub fn quantileScale(corr: []Float, aux: []Float) void {
    const ceil: usize = if ((aux.len - 1) % 4 != 0) 1 else 0;
    const q1_idx: usize = @divFloor(aux.len - 1, 4);
    const q3_idx: usize = @divFloor(3 * (aux.len - 1), 4);

    // Only partially sorting the list at the first and third quantile is required
    @memcpy(aux, corr);
    lma.sort.partialPdq(Float, aux, &.{ q1_idx, q1_idx + ceil, q3_idx, q3_idx + ceil }, {}, std.sort.asc(Float));

    const q1 = (aux[q1_idx] + aux[q1_idx + ceil]) / 2;
    const q3 = (aux[q3_idx] + aux[q3_idx + ceil]) / 2;
    const iqr = (q3 - q1);
    const center = (q1 + q3) / 2;
    lma.grid.apply(Float).standardise(corr, center, iqr);
}

test quantileScale {
    var corr: [11]Float = .{ 12, 15, 0, 3, 3, 7, 9, 19, 18, 4, 6 };
    var aux: [11]Float = @splat(std.math.nan(Float));
    const expected: [11]Float = .{ 0.35, 0.65, -0.85, -0.55, -0.55, -0.15, 0.05, 1.05, 0.95, -0.45, -0.25 };

    quantileScale(&corr, &aux);

    try std.testing.expectEqualSlices(Float, &expected, &corr);
}

pub const Matching = struct {
    buffers: Buffers,
    corr: Correlation,
    config: Config,

    pub const Buffers = struct {
        indices: []u16,
        nanos: []Nano,
        masks: []Candidate.Mask,
        candidates: []Candidate,

        pub fn init(gpa: std.mem.Allocator, config: Config) error{OutOfMemory}!Buffers {
            var out: Buffers = .{
                .indices = &.{},
                .nanos = &.{},
                .masks = &.{},
                .candidates = &.{},
            };

            errdefer out.deinit(gpa);
            out.indices = try gpa.alloc(u16, config.network_size);
            out.nanos = try gpa.alloc(lma.nano.Nano, config.network_size);
            out.masks = try gpa.alloc(Candidate.Mask, config.network_size);
            out.candidates = try gpa.alloc(Candidate, config.network_size * config.max_matches);

            return out;
        }

        pub fn deinit(self: *Buffers, gpa: std.mem.Allocator) void {
            gpa.free(self.indices);
            gpa.free(self.nanos);
            gpa.free(self.masks);
            gpa.free(self.candidates);

            self.* = undefined;
        }
    };

    pub const Correlation = struct {
        matrix: []const SubSlice,
        time_matrix: []Nano,
        step: Step,
        shape: lma.grid.Shape,
        correlation: []Float,
        aux_buffer: []Float,
        window_size: Nano,
        refresh_rate: Nano,

        fn endpoints(self: Correlation, start: u32) SubSlice {
            const half_range = self.window_size >> 1;
            const center = @max(half_range, @min(start +| (self.refresh_rate >> 1), std.math.maxInt(u32) - half_range));
            const from = center - half_range;
            const to = center + half_range;
            return .initRange(from, to);
        }

        pub fn update(self: *const Correlation, signals: []const []const Signal, weights: []const []const Float, time: Nano) Nano {
            correlationMatrix(signals, weights, self.endpoints(time), self.step, self.correlation, self.matrix, self.aux_buffer);
            return time +| self.refresh_rate;
        }
    };

    pub const Config = struct {
        max_time_delta: []Nano,
        max_matches: u16,
        network_size: u8,
    };

    /// For each signal `s_0`, find the set of possible candidate signals `S = {s_1, ..., s_n}`
    /// that belong to the same emission.
    ///
    /// This set is then passed to the provided solver along the correlation matrix
    pub fn process(
        self: *const Matching,
        signals: []const []const Signal,
        weights: []const []const Float,
        point_buffer: []Point,
        solver: *lma.pipeline.ToaSolver,
    ) usize {
        const count = signals.len;
        std.debug.assert(count <= self.config.network_size);
        const max_nano: u32 = std.math.maxInt(u32);
        var points: std.ArrayList(Point) = .initBuffer(point_buffer);

        // Merge
        std.debug.assert(self.buffers.indices.len >= count);
        const index = self.buffers.indices[0..count];
        @memset(index, 0);
        std.debug.assert(self.buffers.nanos.len >= count);
        const nanos = self.buffers.nanos[0..count];
        for (0..count) |idx| nanos[idx] = if (signals[idx].len > 0) signals[idx][0].nanosecond else max_nano;
        std.debug.assert(self.buffers.masks.len >= count);
        const masks = self.buffers.masks[0..count];
        @memset(masks, 0);

        // Correlation
        var update_time: Nano = std.sort.min(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
        update_time = self.corr.update(signals, weights, update_time);

        // Matching
        // std.debug.assert(self.buffers.candidates.len > count * options.network.max_station_candidates);

        while (true) {
            const idx = std.sort.argMin(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
            defer {
                index[idx] += 1;
                masks[idx] >>= 1;
                nanos[idx] = if (index[idx] >= signals[idx].len) max_nano else signals[idx][index[idx]].nanosecond;
            }
            // End after processing all
            if (nanos[idx] == max_nano) {
                @branchHint(.unlikely);
                break;
            }
            // Skip already matched signals
            if (masks[idx] & 1 == 1) {
                @branchHint(.unlikely);
                continue;
            }
            // Update outdated correlation matrix
            if (nanos[idx] > update_time) {
                @branchHint(.unlikely);
                update_time = self.corr.update(signals, weights, update_time);
            }

            // Match buffer
            const initial: Candidate = .{
                .nanosecond = nanos[idx],
                .index = index[idx],
                .dBm = signals[idx][index[idx]].dBm,
                .station = @intCast(idx),
                .mask = .set(0),
            };
            var candidates: std.ArrayList(Candidate) = .initBuffer(self.buffers.candidates);

            // Get all possible paired signals
            for (0..signals.len) |station| {
                const base = index[station];
                const signal = signals[station][base..];
                for (signal[0..@min(signal.len, self.config.max_matches)], 0..) |entry, offset| {
                    if (nanos[idx] + self.config.max_time_delta[self.corr.shape.ravel(idx, station)] < entry.nanosecond) break;
                    const mask: Candidate.MaskBit = if (offset < @typeInfo(Candidate.Mask).int.bits) .set(@intCast(offset)) else .unset;
                    if (mask.is_set and (masks[station] >> mask.bit) & 1 == 1) continue;
                    candidates.appendAssumeCapacity(.{
                        .nanosecond = entry.nanosecond,
                        .index = @intCast(base + offset),
                        .dBm = entry.dBm,
                        .station = @intCast(station),
                        .mask = mask,
                    });
                }
            }

            if (solver.solve(initial, candidates.items, masks, &self.corr)) |point| points.appendAssumeCapacity(point);
        }
        return points.items.len;
    }

    // /// For each signal `s_0`, find the set of possible candidate signals `S = {s_1, ..., s_n}`
    // /// that belong to the same emission.
    // ///
    // /// This set is then passed to the provided solver along the correlation matrix
    // fn processInner(
    //     self: *const Matching,
    //     signals: []const []const Signal,
    //     weights: []const []const Float,
    // ) usize {
    //     const count = signals.len;
    //     std.debug.assert(count <= self.config.network_size);
    //     const max_nano: u32 = std.math.maxInt(u32);

    //     // Merge
    //     std.debug.assert(self.buffers.indices.len >= count);
    //     const index = self.buffers.indices[0..count];
    //     @memset(index, 0);
    //     std.debug.assert(self.buffers.nanos.len >= count);
    //     const nanos = self.buffers.nanos[0..count];
    //     for (0..count) |idx| nanos[idx] = if (signals[idx].len > 0) signals[idx][0].nanosecond else max_nano;
    //     std.debug.assert(self.buffers.masks.len >= count);
    //     const masks = self.buffers.masks[0..count];
    //     @memset(masks, 0);

    //     // Correlation
    //     var update_time: Nano = std.sort.min(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
    //     update_time = self.corr.update(signals, weights, update_time);

    //     // Matching
    //     // std.debug.assert(self.buffers.candidates.len > count * options.network.max_station_candidates);

    //     while (true) {
    //         const idx = std.sort.argMin(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
    //         defer {
    //             index[idx] += 1;
    //             masks[idx] >>= 1;
    //             nanos[idx] = if (index[idx] >= signals[idx].len) max_nano else signals[idx][index[idx]].nanosecond;
    //         }
    //         // End after processing all
    //         if (nanos[idx] == max_nano) {
    //             @branchHint(.unlikely);
    //             break;
    //         }
    //         // Skip already matched signals
    //         if (masks[idx] & 1 == 1) {
    //             @branchHint(.unlikely);
    //             continue;
    //         }
    //         // Update outdated correlation matrix
    //         if (nanos[idx] > update_time) {
    //             @branchHint(.unlikely);
    //             update_time = self.corr.update(signals, weights, update_time);
    //         }

    //         // Match buffer
    //         const initial: Candidate = .{
    //             .nanosecond = nanos[idx],
    //             // .index = index[idx],
    //             .dBm = signals[idx][index[idx]].dBm,
    //             .station = @intCast(idx),
    //             .mask = .set(0),
    //         };
    //         var candidates: std.ArrayList(Candidate) = .initBuffer(self.buffers.candidates);

    //         // Get all possible paired signals
    //         for (0..signals.len) |station| {
    //             const base = index[station];
    //             const signal = signals[station][base..];
    //             for (signal[0..@min(signal.len, self.config.max_matches)], 0..) |entry, offset| {
    //                 if (nanos[idx] + self.config.max_time_delta[self.corr.shape.ravel(idx, station)] < entry.nanosecond) break;
    //                 const mask: Candidate.MaskBit = if (offset < @typeInfo(Candidate.Mask).int.bits) .set(@intCast(offset)) else .unset;
    //                 if (mask.is_set and (masks[station] >> mask.bit) & 1 == 1) continue;
    //                 candidates.appendAssumeCapacity(.{
    //                     .nanosecond = entry.nanosecond,
    //                     // .index = @intCast(base + offset),
    //                     .dBm = entry.dBm,
    //                     .station = @intCast(station),
    //                     .mask = mask,
    //                 });
    //             }
    //         }

    //         // dispatch(initial, candidates.items, self, payload);
    //     }
    // }

    test Buffers {
        const test_fn = struct {
            pub fn test_fn(gpa: std.mem.Allocator) error{OutOfMemory}!void {
                var buffers: Buffers = try .init(gpa, .{
                    .network_size = 64,
                    .max_matches = 128,
                    .max_time_delta = &.{},
                });
                buffers.deinit(gpa);
            }
        }.test_fn;

        try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{});
    }

    // test process {
    //     const length = 74;
    //     const signals: [5][]const Signal = .{
    //         &getSignals(1, &.{ 15, 19, 23, 31, 41, 61, 80, 85, 92, 105, 107, 114, 122, 137, 155 }),
    //         &getSignals(1, &.{ 27, 36, 46, 66, 83, 103, 109, 125, 141, 142, 161, 165, 183, 203, 223 }),
    //         &getSignals(1, &.{ 32, 40, 41, 43, 53, 54, 65, 69, 81, 100, 103, 104, 105 }),
    //         &getSignals(1, &.{ 21, 28, 37, 55, 71, 76, 86, 97, 99, 101, 109, 119, 123, 130 }),
    //         &getSignals(1, &.{ 27, 42, 61, 62, 77, 81, 94, 105, 117, 122, 129, 134, 150, 154, 167, 172, 181 }),
    //     };

    //     var buffer: Buffers = try .init(std.testing.allocator, .{});
    //     defer buffer.deinit(std.testing.allocator);

    //     Matching.process(&.{}, signals, weights, out, solver);
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
};

inline fn getSignals(scale: u32, comptime times: []const u32) [times.len]Signal {
    var out: [times.len]Signal = undefined;
    for (times, &out) |nano, *signal| {
        signal.* = .{
            .nanosecond = scale * nano,
            .dBm = 0.0,
        };
    }
    return out;
}

comptime {
    _ = Step;
    _ = Weights;
    _ = Candidate;
    _ = Matching;
    _ = probing;
    _ = search;
}
