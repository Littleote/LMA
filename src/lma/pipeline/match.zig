const std = @import("std");

const lma = @import("../lma.zig");
const common = lma.common;
const Signal = lma.data.types.Signal;
const Point = lma.data.types.Point;
pub const SubSlice = lma.index.SubSlice;
pub const probing = @import("probing.zig");

pub const Float = f32;

const max_network = lma.constants.network.max_network;
const max_consensus = lma.constants.network.max_consensus;

/// Step size for discretizing the signal
pub const Step = struct {
    /// Step size in seconds
    step: Float,
    /// How much to shift a bit to get the step size expressed with fixed precision 30.2
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

    /// Calculate the sparse time series values given the Toa data
    pub fn calculate(method: Weights, slice: []const Signal, weights: []Float) void {
        switch (method) {
            .power => {
                const factor = @log2(10.0) / 10.0;
                // Upscale power by 100_000 to make the mean order of magnitude around 1
                for (slice, weights) |signal, *w| w.* = @exp2(16.5 + factor * lma.cast.as(Float, signal.dBm));
            },
            .decibels => {
                // Downscale decibels by 100 to make the vales around 1
                for (slice, weights) |signal, *w| w.* = @max(0.0, lma.cast.as(Float, signal.dBm) / 70.0 + 1.0);
            },
            .cumulative => {
                var bins: [120]Float = @splat(0);
                const inc = 1.0 / lma.cast.to(Float, slice.len);
                for (slice) |signal| bins[binning(signal.dBm)] += inc;
                for (1..120) |idx| bins[idx] += bins[idx - 1];
                for (slice, weights) |signal, *w| w.* = bins[binning(signal.dBm)];
            },
            .constant => {
                @memset(weights, 1);
            },
            .@"const+decibels" => {
                for (slice, weights) |signal, *w| w.* = lma.cast.as(Float, signal.dBm) / 100.0 + 2.0;
            },
        }
    }
};

/// Data used from the signal to match values
pub const Candidate = struct {
    pub const Mask = u32;
    pub const MaskBit = packed struct(u8) {
        is_set: bool,
        _padding: u2 = 0,
        bit: u5,

        pub fn set(bit: u5) @This() {
            return .{ .is_set = true, .bit = bit };
        }
        pub const unset: @This() = .{ .is_set = false, .bit = 0 };
    };

    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: u32,
    /// Position in the array for this signal
    index: u16,
    /// Index of the station that generate this signal
    station: u8,
    /// Bit corresponding to this signal in the mask
    mask: MaskBit,
};

fn before(time: u32, signal: Signal) bool {
    return signal.nanosecond < time;
}

/// Find the index of the first value with time equal or less than requested
fn findTime(slice: []const Signal, time: u32) u32 {
    return @intCast(std.sort.partitionPoint(Signal, slice, time, before));
}

/// Find the SubSlice for the given time span
pub fn getSpan(slice: []const Signal, span: SubSlice) SubSlice {
    const start = findTime(slice, span.start);
    return .init(start, findTime(slice[start..], span.end()));
}

/// Find the correlation between the sparse signals x and y.
///
/// Time described by the nanosecond of the Toa field.
/// Weight described by the weights slice.
pub fn correlation(signal_x: []const Signal, weights_x: []const Float, signal_y: []const Signal, weights_y: []const Float, corr: []Float, step: Step) void {
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
pub fn quantileScale(corr: []Float, aux: []Float) void {
    const ceil: usize = if ((aux.len - 1) % 4 != 0) 1 else 0;
    const q1_idx: usize = @divFloor(aux.len - 1, 4);
    const q3_idx: usize = @divFloor(3 * (aux.len - 1), 4);

    // Only partially sort the list at the first and third quantile to speed computation
    @memcpy(aux, corr);
    lma.sort.partialPdq(Float, aux, &.{ q1_idx, q1_idx + ceil, q3_idx, q3_idx + ceil }, {}, std.sort.asc(Float));
    // std.sort.block(Float, scaled, {}, std.sort.asc(Float));

    const q1 = (aux[q1_idx] + aux[q1_idx + ceil]) / 2;
    const q3 = (aux[q3_idx] + aux[q3_idx + ceil]) / 2;
    const iqr = (q3 - q1);
    const center = (q1 + q3) / 2;
    lma.grid.apply(Float).standardise(corr, center, iqr);
}

/// Computes the lower triangle of the matrix of scaled cross-correlation vectors for the given time span.
/// If the upper triangle is non-null makes a copy with the reversed cross-correlation vectors
pub fn correlationMatrix(signals: []const []const Signal, weights: []const []const Float, span: SubSlice, step: Step, buffer: []Float, indices: []const SubSlice, aux_buffer: []Float) void {
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
                corr,
                step,
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

pub const Matching = struct {
    buffers: Buffers,
    corr: Correlation,
    config: Config,

    pub const Buffers = struct {
        indices: []u16,
        nanos: []lma.nano.Nano,
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
        time_matrix: []lma.nano.Nano,
        step: Step,
        shape: lma.grid.Shape,
        correlation: []Float,
        aux_buffer: []Float,
        window_size: lma.nano.Nano,
        refresh_rate: lma.nano.Nano,

        fn endpoints(self: Correlation, start: u32) SubSlice {
            const half_range = self.window_size >> 1;
            const center = @max(half_range, @min(start +| (self.refresh_rate >> 1), std.math.maxInt(u32) - half_range));
            const from = center - half_range;
            const to = center + half_range;
            return .initRange(from, to);
        }

        pub fn update(self: *const Correlation, signals: []const []const Signal, weights: []const []const Float, time: lma.nano.Nano) lma.nano.Nano {
            correlationMatrix(signals, weights, self.endpoints(time), self.step, self.correlation, self.matrix, self.aux_buffer);
            return time +| self.refresh_rate;
        }
    };

    pub const Config = struct {
        max_time_delta: []lma.nano.Nano,
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
        var update_time: lma.nano.Nano = std.sort.min(u32, nanos, {}, std.sort.asc(u32)) orelse unreachable;
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
                        .station = @intCast(station),
                        .mask = mask,
                    });
                }
            }

            if (solver.solve(initial, candidates.items, masks, &self.corr)) |point| points.appendAssumeCapacity(point);
        }
        return points.items.len;
    }
};

pub fn updateLoglikelihood(
    reference: Candidate,
    candidates: []const Candidate,
    loglikelihoods: []Float,
    options: *const Matching.Correlation,
) void {
    const bad = comptime -std.math.inf(Float);
    for (candidates, loglikelihoods[0..candidates.len]) |candidate, *total| {
        if (!std.math.isFinite(total.*)) continue;
        total.* += blk: {
            if (reference.station == candidate.station) break :blk bad;
            const idx = options.shape.ravel(reference.station, candidate.station);
            const max_time = options.time_matrix[idx];

            const delta: u32 = @max(reference.nanosecond, candidate.nanosecond) - @min(reference.nanosecond, candidate.nanosecond);
            if (delta > max_time) break :blk bad;
            const sub_slice = options.matrix[idx];
            if (sub_slice.size == 0) break :blk bad;
            const l = options.step.get(sub_slice.getConst(Float, options.correlation), reference.nanosecond, candidate.nanosecond);
            break :blk l;
        };
    }
}

pub const BeamSearch = struct {
    pub const Options = struct {
        loglikelihood: Float,
        width: usize,
        consensus: usize = max_consensus,
    };

    const Int = @Int(.unsigned, @typeInfo(Float).float.bits);
    const Chain = [max_consensus - 1]Int;
    index: usize,
    chain_len: usize,
    buffer: []Float,
    candidates: []const Candidate,
    chains: []const Chain,
    out: [max_consensus]Candidate,

    inline fn cut(T: type, buffer: []Float, index: usize) struct { []T, []Float } {
        const chain_size = @typeInfo(Chain).array.len;
        if (T == Float) return .{ buffer[0..index], buffer[index..] };
        if (T == Int) return .{ @ptrCast(buffer[0..index]), buffer[index..] };
        if (T == Chain) return .{ @ptrCast(buffer[0 .. index * chain_size]), buffer[index * chain_size ..] };
        @compileError("Invalid type T \"" ++ @typeName(T) ++ "\"");
    }

    pub fn buffer_size(candidates: usize, width: usize) usize {
        return (candidates + max_consensus - 1) * (width * 2);
    }

    pub fn init(initial: Candidate, candidates: []const Candidate, buffer: []Float, corr: *const Matching.Correlation, options: *const Options) BeamSearch {
        const chunk = candidates.len;
        const width = options.width;
        std.debug.assert(buffer.len >= buffer_size(chunk, width));
        std.debug.assert(max_consensus >= options.consensus);
        std.debug.assert(width > 0);

        // Divide the work buffer
        var unused = buffer;
        var chain_buffer: []Chain, unused = cut(Chain, unused, 2 * width);
        var weights: []Float, unused = cut(Float, unused, chunk * width);
        var new_weights: []Float, unused = cut(Float, unused, chunk * width);
        std.debug.assert(buffer.len - unused.len == buffer_size(chunk, width));

        var chains: std.ArrayList(Chain) = .initBuffer(chain_buffer[0..width]);
        var new_chains: std.ArrayList(Chain) = .initBuffer(chain_buffer[width..]);

        // Add empty chain and initialize weights as the initial signal isn't saved in the chain
        chains.appendAssumeCapacity(undefined);
        @memset(weights[0..chunk], 0);
        updateLoglikelihood(initial, candidates, weights[0..chunk], corr);

        for (1..options.consensus) |depth| {
            const scores = weights[0 .. chunk * chains.items.len];
            while (new_chains.items.len < new_chains.capacity) {
                const idx = std.sort.argMax(Float, scores, {}, std.sort.asc(Float)) orelse break;
                if (scores[idx] < options.loglikelihood * lma.cast.to(Float, depth)) break;
                scores[idx] = -std.math.inf(Float);

                const group = idx / chunk;
                const elem: Int = @intCast(idx % chunk);

                const sequence = &chains.items[group];
                sequence[depth - 1] = elem;

                const weight_block = new_weights[chunk * new_chains.items.len ..][0..chunk];
                @memcpy(weight_block, weights[chunk * group ..][0..chunk]);
                updateLoglikelihood(candidates[elem], candidates, weight_block, corr);

                new_chains.appendAssumeCapacity(sequence.*);
            }

            const chain_slice = chains.allocatedSlice();
            chains = new_chains;
            new_chains = .initBuffer(chain_slice);
            const aux_weight = weights;
            weights = new_weights;
            new_weights = aux_weight;
        }

        return .{
            .index = 0,
            .buffer = buffer,
            .candidates = candidates,
            .chains = chains.items,
            .chain_len = options.consensus - 1,
            .out = @splat(initial),
        };
    }

    pub fn next(self: *BeamSearch) ?[]const Candidate {
        if (self.index >= self.chains.len) return null;
        defer self.index += 1;
        for (self.chains[self.index][0..self.chain_len], 1..) |elem, idx| {
            self.out[idx] = self.candidates[elem];
        }
        return self.out[0 .. self.chain_len + 1];
    }
};

pub const DepthFirstSearch = struct {
    pub const Options = struct {
        pub const Attempts = enum(u16) {
            single = 1,
            unlimited = std.math.maxInt(u16),
            _,

            pub fn count(value: u16) Attempts {
                return @enumFromInt(value);
            }
        };

        loglikelihood: Float,
        attempts: Attempts,
        consensus: usize = max_consensus,
    };

    const Frame = struct {
        loglikelihood: []Float,
        attempt: u16 = 0,
        index: u16 = 0,
    };

    const State = enum {
        exit,
        enter,
    };

    depth: u16,
    candidates: []const Candidate,
    weight_buffer: []Float,
    out: [max_consensus]Candidate,
    frames: [max_consensus - 1]Frame,
    max_depth: u16,
    corr: *const Matching.Correlation,
    options: *const Options,

    pub fn init(seed: Candidate, candidates: []const Candidate, buffer: []Float, corr: *const Matching.Correlation, options: *const Options) DepthFirstSearch {
        std.debug.assert(buffer.len >= candidates.len * options.consensus);
        std.debug.assert(max_consensus >= options.consensus);

        var self: DepthFirstSearch = .{
            .depth = 0,
            .candidates = candidates,
            .weight_buffer = buffer,
            .out = undefined,
            .frames = undefined,
            .max_depth = @intCast(options.consensus - 1),
            .corr = corr,
            .options = options,
        };

        self.frames[0] = .{ .loglikelihood = buffer[0..candidates.len] };
        self.out[0] = seed;

        @memset(self.frames[0].loglikelihood, 0);
        updateLoglikelihood(seed, candidates, self.frames[0].loglikelihood, corr);

        return self;
    }

    pub fn next(self: *DepthFirstSearch) ?[]const Candidate {
        const initial_state: State = if (self.depth >= self.max_depth) .exit else .enter;
        state: switch (initial_state) {
            .exit => {
                // Return when no more matches available
                if (self.depth == 0) break :state;
                self.depth -= 1;

                // Update ols frame
                const frame: *Frame = &self.frames[self.depth];
                frame.loglikelihood[frame.index] = -std.math.inf(Float);
                continue :state .enter;
            },
            .enter => {
                // Search for the next match
                const frame: *Frame = &self.frames[self.depth];
                frame.attempt += 1;
                if (frame.attempt > @intFromEnum(self.options.attempts)) continue :state .exit;
                const index: u16 = @intCast(std.sort.argMax(Float, frame.loglikelihood[0..self.candidates.len], {}, std.sort.asc(Float)) orelse unreachable);
                if (frame.loglikelihood[index] <= self.options.loglikelihood * (1 + self.depth)) continue :state .exit;
                frame.index = index;

                // Advance frame depth and return on full match
                self.depth += 1;
                self.out[self.depth] = self.candidates[index];
                if (self.depth >= self.max_depth) return self.out[0..self.options.consensus];

                // Set up new frame
                const new_frame: *Frame = &self.frames[self.depth];
                new_frame.* = .{ .loglikelihood = self.weight_buffer[self.candidates.len * self.depth ..][0..self.candidates.len] };

                @memcpy(new_frame.loglikelihood, frame.loglikelihood);
                updateLoglikelihood(self.candidates[index], self.candidates, new_frame.loglikelihood, self.corr);
                continue :state .enter;
            },
        }
        return null;
    }
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

test "autocorrelation" {
    var signal: [16]Signal = getSignals(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    var weights: [16]Float = @splat(1);
    var corr_buffer: [5]Float = @splat(std.math.nan(Float));

    correlation(&signal, &weights, &signal, &weights, &corr_buffer, .fromPower(-1));
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

    correlation(&signal_x, &weights_x, &signal_y, &weights_y, &corr, .fromPower(0));

    try std.testing.expectEqualSlices(Float, &expected, &corr);
}

test quantileScale {
    var corr: [11]Float = .{ 12, 15, 0, 3, 3, 7, 9, 19, 18, 4, 6 };
    var aux: [11]Float = @splat(std.math.nan(Float));
    const expected: [11]Float = .{ 0.35, 0.65, -0.85, -0.55, -0.55, -0.15, 0.05, 1.05, 0.95, -0.45, -0.25 };

    quantileScale(&corr, &aux);

    try std.testing.expectEqualSlices(Float, &expected, &corr);
}

// test mergeSignals {
//     const length = 74;
//     const signals: [5][]const Toa = .{
//         &getToa(1, &.{ 15, 19, 23, 31, 41, 61, 80, 85, 92, 105, 107, 114, 122, 137, 155 }),
//         &getToa(1, &.{ 27, 36, 46, 66, 83, 103, 109, 125, 141, 142, 161, 165, 183, 203, 223 }),
//         &getToa(1, &.{ 32, 40, 41, 43, 53, 54, 65, 69, 81, 100, 103, 104, 105 }),
//         &getToa(1, &.{ 21, 28, 37, 55, 71, 76, 86, 97, 99, 101, 109, 119, 123, 130 }),
//         &getToa(1, &.{ 27, 42, 61, 62, 77, 81, 94, 105, 117, 122, 129, 134, 150, 154, 167, 172, 181 }),
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
