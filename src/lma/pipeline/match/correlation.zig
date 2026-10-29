const std = @import("std");

const lma = @import("../../lma.zig");
const match = lma.pipeline.match;
const Signal = lma.data.Signal;
const Candidate = match.Candidate;
const SubSlice = lma.index.SubSlice;
const Nano = lma.nano.Nano;

const findTime = match.findTime;
const getSpan = match.getSpan;

pub const Float = match.Float;
pub const TimeSpan = match.TimeSpan;

/// Find the correlation between the sparse time series X and Y for a range of lags.
///
/// The time of the events are in `signal[i].nanosecond`.
/// The value/height of the events are in `weight[i]`.
/// The width of the sampling is `step`.
/// The output correlation for a given lag is stored in `out[i]`.
///
/// The correlation is calculated for a total of `out.len` lags centered on `0`.
/// This means that `out.len` must be odd.
fn correlation(
    signal_x: []const Signal,
    weights_x: []const Float,
    signal_y: []const Signal,
    weights_y: []const Float,
    step: Step,
    out: []Float,
) void {
    std.debug.assert(out.len & 1 == 1);
    const offset_round: usize = @intCast(out.len << (step.shift - 1));
    const above: u32 = @intCast(offset_round);
    const below: u32 = above - 1;
    var span_start: u32 = 0;
    var span_end: u32 = 0;
    var upper: u32 = 0;
    @memset(out, 0);
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
            out[idx] += wx * wy;
        }
    }
}

/// Computes the cross-correlation for all pairs within the given time span.
/// The results are then transformed using the log-likelihood function.
///
/// The values of `{start: k, size: l} = pairs[i, j]` indicate the index in `out[k..l]` where to store the result.
/// The size of `aux_buffer` should be at least as big as the cross-correlation with the most lag values.
/// * If the indices for the lower triangle of `pairs` have a size of zero, the cross-correlation for that pair is not computed.
/// * If the indices for the upper triangle of `pairs` have a non-zero size, the cross-correlation is copied and reversed from the lower triangle.
fn pairLikelihood(
    signals: []const []const Signal,
    weights: []const []const Float,
    span: TimeSpan,
    step: Step,
    pairs: []const SubSlice,
    out: []Float,
    aux_buffer: []Float,
) void {
    const stations: u32 = @intCast(signals.len);
    const shape: lma.grid.Shape = .init(stations, stations);
    for (0..stations) |row| {
        const row_split = getSpan(signals[row], span);
        for (0..row) |col| {
            const corr = pairs[shape.ravel(row, col)].getReference(Float, out);
            if (corr.len == 0) continue;

            const col_split = getSpan(signals[col], span);
            correlation(
                row_split.getConst(Signal, signals[row]),
                row_split.getConst(Float, weights[row]),
                col_split.getConst(Signal, signals[col]),
                col_split.getConst(Float, weights[col]),
                step,
                corr,
            );
            quantileScale(corr, aux_buffer[0..corr.len]);

            if (row != col) skip: {
                const rev_corr = pairs[shape.ravel(col, row)].getReference(Float, out);
                if (rev_corr.len == 0) break :skip;
                @memcpy(rev_corr, corr);
                std.mem.reverse(Float, rev_corr);
            }
        }
    }

    lma.grid.apply(Float).loglikelihoodApprox(out, 0.7412898443291327);
}

test "autocorrelation" {
    var signal: [16]Signal = getSignals(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    var weights: [16]Float = @splat(1);
    var corr_buffer: [5]Float = @splat(std.math.nan(Float));

    correlation(&signal, &weights, &signal, &weights, .fromPower(0), &corr_buffer);
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

/// For each signal `s_0`, find the set of signals `S = {s_1, ..., s_n}` that could belong to the same emission.
///
/// The generated combinations are made with the following constraints:
/// * Neither the initial signal nor the others must not have been matched yet (the bit in `buffers.masks[i]` must be unset).
/// * The other signals must be between `s_0.nanosecond` and `s_0.nanosecond + corr.time_matrix[i, j]`.
///
/// This set is then passed to the provided function along with the correlation information to be further processed.
pub fn process(
    info: *const Info,
    buffers: *const Buffers,
    signals: []const []const Signal,
    weights: []const []const Float,
    context: anytype,
    dispatch: fn (@TypeOf(context), Candidate, []const Candidate, []Candidate.Mask, *const Info) void,
) void {
    const network_size = signals.len;
    // Network size guarantees
    std.debug.assert(network_size <= buffers.network_size);
    std.debug.assert(lma.constants.network.min_consensus <= network_size);

    // Buffer init guarantees
    std.debug.assert(network_size <= buffers.indices.len);
    std.debug.assert(network_size <= buffers.nanoseconds.len);
    std.debug.assert(network_size <= buffers.masks.len);
    std.debug.assert(network_size * buffers.max_station_candidates <= buffers.candidates.len);

    // Merge algorithm variables
    const index = buffers.indices[0..network_size];
    @memset(index, 0);

    const empty_nano: u32 = std.math.maxInt(u32);
    const nanos = buffers.nanoseconds[0..network_size];
    for (0..network_size) |idx| nanos[idx] = if (signals[idx].len > 0) signals[idx][0].nanosecond else empty_nano;

    const masks = buffers.masks[0..network_size];
    @memset(masks, 0);

    // Correlation information
    var update_time: Nano = std.sort.min(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
    update_time = info.update(signals, weights, update_time);

    while (true) {
        const idx = std.sort.argMin(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
        defer {
            index[idx] += 1;
            masks[idx] >>= 1;
            nanos[idx] = if (index[idx] >= signals[idx].len) empty_nano else signals[idx][index[idx]].nanosecond;
        }
        // End after processing all
        if (nanos[idx] == empty_nano) {
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
            update_time = info.update(signals, weights, update_time);
        }

        // Match buffer
        const initial: Candidate = .{
            .nanosecond = nanos[idx],
            .index = index[idx],
            .dBm = signals[idx][index[idx]].dBm,
            .station = @intCast(idx),
            .mask = .set(0),
        };
        var candidates: std.ArrayList(Candidate) = .initBuffer(buffers.candidates);

        // Get all possible paired signals
        for (0..signals.len) |station| {
            const base = index[station];
            const signal = signals[station][base..];
            for (signal[0..@min(signal.len, buffers.max_station_candidates)], 0..) |entry, offset| {
                if (nanos[idx] + info.time_matrix[info.shape.ravel(idx, station)] < entry.nanosecond) break;
                const mask: Candidate.MaybeBit = if (offset < @typeInfo(Candidate.Mask).int.bits) .set(@intCast(offset)) else .unset;
                if (mask.isSet(masks[station])) continue;
                candidates.appendAssumeCapacity(.{
                    .nanosecond = entry.nanosecond,
                    .index = @intCast(base + offset),
                    .dBm = entry.dBm,
                    .station = @intCast(station),
                    .mask = mask,
                });
            }
        }

        dispatch(context, initial, candidates.items, buffers.masks, info);
    }
}

test process {
    var failed = false;

    const Dispatch = struct {
        failed_indicator: *bool,
        signals: []const []const Signal,

        const max_match = 4;
        const max_time = 20;

        fn dispatch_fn(
            self: @This(),
            reference: Candidate,
            candidates: []const Candidate,
            _: []Candidate.Mask,
            _: *const Info,
        ) void {
            for (self.signals, 0..) |signal, station| {
                if (reference.station == station) {
                    // Exactly one from reference station, being itself
                    var found: usize = 0;
                    for (candidates) |candidate| {
                        if (candidate.station == reference.station) {
                            if (!std.meta.eql(candidate, reference)) {
                                std.debug.print(
                                    "Found unexpected non-reference signal\n\t{any}\n\tWith reference\n\t{any}\n",
                                    .{ candidate, reference },
                                );
                                self.failed_indicator.* = true;
                            } else found += 1;
                        }
                    }
                    if (found != 1) {
                        std.debug.print(
                            "Expected to find reference signal once but found it {d} times\n\tWith reference\n\t{any}\n",
                            .{ found, reference },
                        );
                        self.failed_indicator.* = true;
                    }
                } else {
                    // The minimum between the lookahead and the timing window
                    // End of timing window is *inclusive*
                    // Start of timing window is dependent on the order of stations
                    const start = findTime(signal, reference.nanosecond);
                    const end = @min(start + max_match, findTime(signal, reference.nanosecond + max_time + 1));
                    var signal_found: [max_match]bool = @splat(false);
                    for (candidates) |candidate| {
                        if (candidate.station == station) {
                            if (candidate.index < start or end <= candidate.index) {
                                std.debug.print(
                                    "Found unexpected signal\n\t{any}\n\tWith reference\n\t{any}\n",
                                    .{ candidate, reference },
                                );
                                self.failed_indicator.* = true;
                            } else {
                                const ptr = &signal_found[candidate.index - start];
                                if (ptr.*) {
                                    std.debug.print(
                                        "Found repeated signal\n\t{any}\n\tWith reference\n\t{any}\n",
                                        .{ candidate, reference },
                                    );
                                    self.failed_indicator.* = true;
                                } else {
                                    ptr.* = true;
                                }
                            }
                        }
                    }
                    for (signal_found, 0..) |found, idx| {
                        if (!found and start + idx < end) {
                            const candidate: Candidate = .{
                                .nanosecond = signal[start + idx].nanosecond,
                                .index = @intCast(start + idx),
                                .station = @intCast(station),
                                .dBm = std.math.nan(f16),
                                .mask = .unset,
                            };
                            std.debug.print(
                                "Missing signal {d} for station {d}\n\t{any}\n\tWith reference\n\t{any}\n",
                                .{ idx + start, station, candidate, reference },
                            );
                            self.failed_indicator.* = true;
                        }
                    }
                }
            }
        }
    };

    const entries = 5;
    const unlimited: u32 = std.math.maxInt(u32);

    // Set of signals with non-repeated numbers
    const signals: [entries][]const Signal = comptime .{
        &getSignals(1, &.{ 15, 19, 23, 31, 44, 63, 80, 85, 92, 106, 107, 114, 124, 137, 155 }),
        &getSignals(1, &.{ 26, 36, 46, 66, 83, 108, 110, 125, 141, 142, 161, 165, 183, 203, 223 }),
        &getSignals(1, &.{ 32, 40, 41, 43, 53, 54, 65, 69, 82, 100, 103, 104, 105 }),
        &getSignals(1, &.{ 21, 28, 37, 55, 71, 76, 86, 97, 99, 101, 109, 119, 123, 130 }),
        &getSignals(1, &.{ 27, 42, 61, 62, 77, 81, 94, 111, 117, 122, 129, 134, 150, 154, 167, 172, 181 }),
    };

    const weights: [entries][]const Float = comptime .{
        &@as([signals[0].len]Float, @splat(1)),
        &@as([signals[1].len]Float, @splat(1)),
        &@as([signals[2].len]Float, @splat(1)),
        &@as([signals[3].len]Float, @splat(1)),
        &@as([signals[4].len]Float, @splat(1)),
    };

    var buffer: Buffers = try .init(std.testing.allocator, 5, Dispatch.max_match);
    defer buffer.deinit(std.testing.allocator);

    var time_matrix: [entries * entries]Nano = @splat(Dispatch.max_time);
    for (0..entries) |entry| time_matrix[(entries + 1) * entry] = 0;
    const info: Info = .{
        .step = .fromPower(1),
        .shape = .init(entries, entries),
        .time_matrix = &time_matrix,
        .pair_slice = &@as([entries * entries]SubSlice, @splat(.init(0, 0))),
        .loglikelihood = &.{},
        .aux_buffer = &.{},
        .refresh_rate = unlimited,
        .window_size = unlimited,
    };

    const dispatch: Dispatch = .{
        .failed_indicator = &failed,
        .signals = &signals,
    };
    process(&info, &buffer, &signals, &weights, dispatch, Dispatch.dispatch_fn);
    if (failed) return error.BadMatch;
}

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
        return @trunc(std.math.clamp(dBm + 90, 0, bin_count - 1));
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
            .constant => @memset(weights, 1),
            .@"const+decibels" => {
                for (slice, weights) |signal, *w| w.* = @max(0.0, lma.cast.as(Float, signal.dBm) / noise_level + 2.0);
            },
        }
    }
};

/// Step size for discretizing a signal.
pub const Step = struct {
    /// Step size in seconds.
    step: Float,
    /// How much to shift a bit to get the step size with fixed precision 30.2 ns.
    shift: u5,

    /// Generate a step size of `2^pow` ns.
    pub fn fromPower(pow: u8) Step {
        const shift: u5 = @intCast(pow + 2);
        return .{
            .step = lma.nano.fromNano(Float, @as(Nano, 1) << shift),
            .shift = shift,
        };
    }

    /// Generate a step size of `2^N` ns that best approximates `desired_step`.
    pub fn fromStep(desired_step: Float) Step {
        return .fromPower(@round(@log2(std.time.ns_per_s * desired_step)));
    }

    /// Calculate index into a slice for a given lag
    pub fn get(step: Step, items: []const Float, t0: Nano, t1: Nano) ?Float {
        const offset_round = items.len << (step.shift - 1);
        const idx = (offset_round +% t0 -% t1) >> step.shift;
        return if (idx < items.len) items[idx] else null;
    }
};

/// Data for calculating, storing, and utilising the cross-correlation information
pub const Info = struct {
    /// Step size for discretizing the signal during the crosscorrelation calculation.
    step: Step,
    /// Shape of the time and correlation matrices.
    ///
    /// Should be `network_size` rows and columns.
    shape: lma.grid.Shape,
    /// Maximum relevant lag (inclusive).
    /// More lags may still be computed to ensure a good result when normalizing with robust estimators.
    ///
    /// `time_matrix[i, j]` indicates the the first lag for which the correlation between stations `i` and `j` stops being relevant.
    time_matrix: []const Nano,
    /// Range to index into `corr_buffer`.
    ///
    /// The range `{start: k, size: l} = pair_slice[i, j]` indicates that the loglikelihood values between stations `i` and `j`
    /// is stored at `loglikelihood[k..][..l]`.
    pair_slice: []const SubSlice,
    /// The values of loglikelihood between the different stations and lags indexed using `pair_slice`.
    loglikelihood: []Float,
    /// Auxiliary buffer for processing the correlation.
    ///
    /// The buffer should be at least as big as the cross-correlation with the most lag values.
    aux_buffer: []Float,

    /// Window of time to use for the cross-correlation.
    window_size: Nano,
    /// Amount of time before invalidating the cross-correlation results.
    ///
    /// This value should be equal or lower than `window_size`, with a lower value ensuring that
    /// a partial lightning is not missed due to being on the edge of the correlation window.
    refresh_rate: Nano,

    /// Get a window of size `window_size` centered at `start + refresh_rate / 2`.
    fn endpoints(self: Info, start: u32) SubSlice {
        const half_range = self.window_size >> 1;
        const center = @max(half_range, @min(start +| (self.refresh_rate >> 1), std.math.maxInt(u32) - half_range));
        const from = center - half_range;
        const to = center + half_range;
        return .initRange(from, to);
    }

    /// Update cross-correlation values to the window obtained from `time` and returning the next time it need to be updated.
    pub fn update(self: *const Info, signals: []const []const Signal, weights: []const []const Float, time: Nano) Nano {
        pairLikelihood(signals, weights, self.endpoints(time), self.step, self.pair_slice, self.loglikelihood, self.aux_buffer);
        return time +| self.refresh_rate;
    }
};

/// Collection of buffers used for the matching process
pub const Buffers = struct {
    /// Maximum number of candidates a station will provide.
    max_station_candidates: u16,
    /// Number of station present in the network.
    network_size: u8,

    /// Next unprocessed signal `indices[i]` from station `i`.
    indices: []u16,
    /// Time of the next unprocessed signal `nanos[i]` from station `i` with fixed precision 30.2 ns.
    nanoseconds: []Nano,
    /// Mask to indicate which of the next signals `0b...zyx = masks[i]` for station `i` have already been used.
    masks: []Candidate.Mask,
    /// Buffer where to store the candidates for each match.
    candidates: []Candidate,

    pub fn init(gpa: std.mem.Allocator, network_size: u8, max_matches: u16) error{OutOfMemory}!Buffers {
        std.debug.assert(network_size <= lma.constants.network.max_network);
        var out: Buffers = .{
            .max_station_candidates = max_matches,
            .network_size = network_size,

            .indices = &.{},
            .nanoseconds = &.{},
            .masks = &.{},
            .candidates = &.{},
        };

        errdefer out.deinit(gpa);
        out.indices = try gpa.alloc(u16, network_size);
        out.nanoseconds = try gpa.alloc(lma.nano.Nano, network_size);
        out.masks = try gpa.alloc(Candidate.Mask, network_size);
        out.candidates = try gpa.alloc(Candidate, network_size * max_matches);

        return out;
    }

    pub fn deinit(self: *Buffers, gpa: std.mem.Allocator) void {
        gpa.free(self.indices);
        gpa.free(self.nanoseconds);
        gpa.free(self.masks);
        gpa.free(self.candidates);

        self.* = undefined;
    }
};

test Buffers {
    const test_fn = struct {
        inline fn test_fn(gpa: std.mem.Allocator) error{OutOfMemory}!void {
            var buffers: Buffers = try .init(gpa, 32, 128);
            buffers.deinit(gpa);
        }
    }.test_fn;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{});
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
