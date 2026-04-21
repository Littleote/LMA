const std = @import("std");

const lma = @import("../lma.zig");
const common = lma.common;
const Toa = lma.data.types.Toa;
const Point = lma.data.types.Point;
pub const SubSlice = lma.index.SubSlice;

pub const Float = f32;

const max_network = lma.constants.network.max_network;
const size = lma.constants.network.consensus;

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
    pub fn calculate(method: Weights, slice: []const Toa, weights: []Float) void {
        switch (method) {
            .power => {
                const factor = @log2(10.0) / 10.0;
                // Upscale power by 100_000 to make the mean order of magnitude around 1
                for (slice, weights) |toa, *w| w.* = @exp2(16.5 + factor * lma.cast.as(Float, toa.dBm));
            },
            .decibels => {
                // Downscale decibels by 100 to make the vales around 1
                for (slice, weights) |toa, *w| w.* = @max(0.0, lma.cast.as(Float, toa.dBm) / 70.0 + 1.0);
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

fn before(time: u32, toa: Toa) bool {
    return toa.nanosecond < time;
}

/// Find the index of the first value with time equal or less than requested
fn findTime(slice: []const Toa, time: u32) u32 {
    return @intCast(std.sort.partitionPoint(Toa, slice, time, before));
}

/// Find the SubSlice for the given time span
pub fn getSpan(slice: []const Toa, span: SubSlice) SubSlice {
    const start = findTime(slice, span.start);
    return .init(start, findTime(slice[start..], span.end()));
}

/// Find the correlation between the sparse signals x and y.
///
/// Time described by the nanosecond of the ToA field.
/// Weight described by the weights slice.
pub fn correlation(signal_x: []const Toa, weights_x: []const Float, signal_y: []const Toa, weights_y: []const Float, corr: []Float, step: Step) void {
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
    const iqr = q3 - q1;
    const center = (q1 + q3) / 2;
    lma.grid.apply(Float).standardise(corr, center, iqr);
}

/// Computes the lower triangle of the matrix of scaled cross-correlation vectors for the given time span.
/// If the upper triangle is non-null makes a copy with the reversed cross-correlation vectors
pub fn correlationMatrix(signals: []const []const Toa, weights: []const []const Float, span: SubSlice, step: Step, buffer: []Float, indices: []const SubSlice, aux_buffer: []Float) void {
    const stations: u32 = @intCast(signals.len);
    const shape: lma.grid.Shape = .init(stations, stations);
    for (0..stations) |row| {
        const row_split = getSpan(signals[row], span);
        for (0..row) |col| {
            const col_split = getSpan(signals[col], span);
            const corr = indices[shape.ravel(row, col)].getReference(Float, buffer);
            if (corr.len == 0) continue;
            correlation(
                row_split.getConst(Toa, signals[row]),
                row_split.getConst(Float, weights[row]),
                col_split.getConst(Toa, signals[col]),
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
}

pub const Matching = struct {
    buffers: Buffers,
    corr: Correlation,
    config: Config,

    pub const Buffers = struct {
        indices: []u16,
        nanos: []lma.nano.Nano,
        masks: []Signal.Mask,
        candidates: []Signal,

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
            out.masks = try gpa.alloc(Signal.Mask, config.network_size);
            out.candidates = try gpa.alloc(Signal, config.network_size * config.max_matches);

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

        pub fn update(self: *const Correlation, signals: []const []const Toa, weights: []const []const Float, time: lma.nano.Nano) lma.nano.Nano {
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
        signals: []const []const Toa,
        weights: []const []const Float,
        point_buffer: []Point,
        context: anytype,
        solve: fn (@TypeOf(context), Signal, []const Signal, []u32, *const Correlation) ?Point,
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
            const initial: Signal = .{
                .nanosecond = nanos[idx],
                .index = index[idx],
                .station = @intCast(idx),
                .mask = .set(0),
            };
            var candidates: std.ArrayList(Signal) = .initBuffer(self.buffers.candidates);

            // Get all possible paired signals
            for (0..signals.len) |station| {
                const base = index[station];
                const signal = signals[station][base..];
                for (signal[0..@min(signal.len, self.config.max_matches)], 0..) |toa, offset| {
                    if (nanos[idx] + self.config.max_time_delta[self.corr.shape.ravel(idx, station)] < toa.nanosecond) break;
                    const mask: Signal.MaskBit = if (offset < @typeInfo(Signal.Mask).int.bits) .set(@intCast(offset)) else .unset;
                    if (mask.is_set and (masks[station] >> mask.bit) & 1 == 1) continue;
                    candidates.appendAssumeCapacity(.{
                        .nanosecond = toa.nanosecond,
                        .index = @intCast(base + offset),
                        .station = @intCast(station),
                        .mask = mask,
                    });
                }
            }

            if (solve(context, initial, candidates.items, masks, &self.corr)) |point| points.appendAssumeCapacity(point);
        }
        return points.items.len;
    }
};

pub const Query = struct {
    min_corr: Float,
    min_weight: Float,
    min_weight_increase: Float,
    max_weight: Float = 1_000.0,

    fn query(
        self: *const Query,
        reference: Signal,
        candidates: []const Signal,
        weights: []Float,
        options: *const Matching.Correlation,
    ) void {
        for (candidates, weights[0..candidates.len]) |candidate, *weight| {
            if (weight.* == Query.bad) continue;
            weight.* += blk: {
                if (reference.station == candidate.station) break :blk Query.bad;
                const idx = options.shape.ravel(reference.station, candidate.station);
                const max_time = options.time_matrix[idx];

                const delta: u32 = @max(reference.nanosecond, candidate.nanosecond) - @min(reference.nanosecond, candidate.nanosecond);
                if (delta > max_time) break :blk Query.bad;
                const sub_slice = options.matrix[idx];
                if (sub_slice.size == 0) break :blk Query.bad;
                const corr = options.step.get(sub_slice.getConst(Float, options.correlation), reference.nanosecond, candidate.nanosecond);
                break :blk if (corr < self.min_corr) Query.bad else corr;
            } - self.min_weight_increase;
            weight.* = if (weight.* < self.min_weight) Query.bad else @min(weight.*, self.max_weight);
        }
    }

    pub const outlier: Query = .{ .min_corr = 2, .min_weight = 0, .min_weight_increase = 2 };
    pub const likely: Query = .{ .min_corr = 1, .min_weight = 1, .min_weight_increase = 1 };
    pub const any: Query = .{ .min_corr = 0, .min_weight = 0, .min_weight_increase = 0 };
    pub const permissive: Query = .{ .min_corr = 0.0, .min_weight = 0.5, .min_weight_increase = 1.0, .max_weight = 10.0 };

    pub const bad: Float = -1_000;
};

pub const BSOptions = struct {
    query: Query,
    width: ?usize,
};

pub const BeamSearch = struct {
    const Int = @Int(.unsigned, @typeInfo(Float).float.bits);
    const Chain = [size - 1]Int;
    index: usize,
    buffer: []Float,
    candidates: []const Signal,
    chains: std.ArrayList(Chain),
    out: [size]Signal,

    inline fn cut(T: type, buffer: []Float, index: usize) struct { []T, []Float } {
        const chain_size = @typeInfo(Chain).array.len;
        if (T == Float) return .{ buffer[0..index], buffer[index..] };
        if (T == Int) return .{ @ptrCast(buffer[0..index]), buffer[index..] };
        if (T == Chain) return .{ @ptrCast(buffer[0 .. index * chain_size]), buffer[index * chain_size ..] };
        @compileError("Invalid type T \"" ++ @typeName(T) ++ "\"");
    }

    pub fn buffer_size(candidates: usize, width: usize) usize {
        return (candidates + size - 1) * (width * 2);
    }

    pub fn init(initial: Signal, candidates: []const Signal, buffer: []Float, options: *const Matching.Correlation, bs_options: *const BSOptions) BeamSearch {
        const chunk = candidates.len;
        const width = bs_options.width orelse buffer.len / (chunk + size) / 2;
        std.debug.assert(buffer.len >= buffer_size(chunk, width));

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
        bs_options.query.query(initial, candidates, weights[0..chunk], options);

        for (1..size) |depth| {
            const scores = weights[0 .. chunk * chains.items.len];
            while (new_chains.items.len < new_chains.capacity) {
                const idx = std.sort.argMax(Float, scores, {}, std.sort.asc(Float)) orelse break;
                if (scores[idx] == Query.bad) break;
                scores[idx] = Query.bad;

                const group = idx / chunk;
                const elem: Int = @intCast(idx % chunk);

                const sequence = &chains.items[group];
                sequence[depth - 1] = elem;

                const weight_block = new_weights[chunk * new_chains.items.len ..][0..chunk];
                @memcpy(weight_block, weights[chunk * group ..][0..chunk]);
                bs_options.query.query(candidates[elem], candidates, weight_block, options);

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
            .chains = chains,
            .out = @splat(initial),
        };
    }

    pub fn next(self: *BeamSearch) ?[]const Signal {
        if (self.index >= self.chains.items.len) return null;
        defer self.index += 1;
        for (self.chains.items[self.index], 1..) |elem, idx| {
            self.out[idx] = self.candidates[elem];
        }
        return &self.out;
    }
};

// test BeamSearch {
//     var matrix = [_]Float{
//         0, 5, 2, 1, 2, //
//         5, 0, 6, 2, 1, //
//         2, 6, 0, 3, 1, //
//         1, 2, 3, 0, 9, //
//         2, 1, 1, 9, 0, //
//     };

//     const opt: Options = .{
//         .step = .fromPower(1),
//         .shape = .init(5, 5),
//         .corr = .{
//             .matrix = blk: {
//                 var corr: [matrix.len]?[]Float = @splat(null);
//                 for (0..matrix.len) |i| {
//                     corr[i] = matrix[i..][0..1];
//                 }
//                 break :blk &corr;
//             },
//             .aux_buffer = &.{},
//             .refresh_rate = 0,
//             .window_size = 0,
//         },
//         .network = .{ .max_size = 5, .max_station_candidates = 1 },
//         .time_matrix = &@as([5 * 5]u32, @splat(0)),
//     };

//     const signals: []const Signal = &.{
//         .{ .nanosecond = 0, .index = 0, .station = 0, .mask = .unset },
//         .{ .nanosecond = 0, .index = 0, .station = 1, .mask = .unset },
//         .{ .nanosecond = 0, .index = 0, .station = 2, .mask = .unset },
//         .{ .nanosecond = 0, .index = 0, .station = 3, .mask = .unset },
//         .{ .nanosecond = 0, .index = 0, .station = 4, .mask = .unset },
//     };

//     var buffer: [4096]Float = undefined;

//     var beams: BeamSearch = .init(signals[0], signals, &buffer, &opt, &.{ .width = 20, .query = .likely });
//     while (beams.next()) |sol| {
//         for (sol) |sig|
//             std.debug.print("{d} ", .{sig.station});
//         std.debug.print("\n", .{});
//     }
//     return error.Print;
// }

pub const DFSOptions = struct {
    pub const Attempts = enum(u16) {
        single = 1,
        unlimited = std.math.maxInt(u16),
        _,

        pub fn count(value: u16) Attempts {
            return @enumFromInt(value);
        }
    };

    query: Query,
    attempts: Attempts,

    pub const bad_value: Float = -1_000.0;

    pub const yolo: DFSOptions = .{
        .query = .{
            .min_corr = 0.0,
            .min_weight = 0.5,
            .min_weight_increase = 1.0,
            .max_weight = 10.0,
        },
        .attempts = .single,
    };

    pub const compromise: DFSOptions = .{
        .query = .{
            .min_corr = 1.0,
            .min_weight = 0.5,
            .min_weight_increase = 1.0,
            .max_weight = 10.0,
        },
        .attempts = .count(2),
    };

    pub const exhaustive: DFSOptions = .{
        .query = .{
            .min_corr = 0.5,
            .min_weight = 0.5,
            .min_weight_increase = 1.5,
            .max_weight = 5.0,
        },
        .attempts = .unlimited,
    };

    pub const unrestricted: DFSOptions = .{
        .query = .{
            .min_corr = 0.0,
            .min_weight = 0.0,
            .min_weight_increase = 0.0,
        },
        .attempts = .count(3),
    };
};

pub const DepthFirstSearch = struct {
    const max_frame_depth = size - 1;
    const Frame = struct {
        weights: []Float,
        attempt: u16 = 0,
        index: u16 = 0,
    };

    const State = enum {
        exit,
        enter,
    };

    depth: u16,
    candidates: []const Signal,
    weight_buffer: []Float,
    signals: [size]Signal,
    frames: [max_frame_depth]Frame,
    options: *const Matching.Correlation,
    dfs_options: *const DFSOptions,

    pub fn init(seed: Signal, candidates: []const Signal, weight_buffer: []Float, options: *const Matching.Correlation, dfs_options: *const DFSOptions) DepthFirstSearch {
        std.debug.assert(weight_buffer.len >= candidates.len * size);

        var self: DepthFirstSearch = .{
            .depth = 0,
            .candidates = candidates,
            .weight_buffer = weight_buffer,
            .signals = undefined,
            .frames = undefined,
            .options = options,
            .dfs_options = dfs_options,
        };

        self.frames[0] = .{ .weights = weight_buffer[0..candidates.len] };
        self.signals[0] = seed;

        @memset(self.frames[0].weights, 0);
        dfs_options.query.query(seed, candidates, self.frames[0].weights, options);

        return self;
    }

    pub fn next(self: *DepthFirstSearch) ?[]const Signal {
        const initial_state: State = if (self.depth >= max_frame_depth) .exit else .enter;
        state: switch (initial_state) {
            .exit => {
                // Return when no more matches available
                if (self.depth == 0) break :state;
                self.depth -= 1;

                // Update ols frame
                const frame: *Frame = &self.frames[self.depth];
                frame.weights[frame.index] = DFSOptions.bad_value;
                continue :state .enter;
            },
            .enter => {
                // Search for the next match
                const frame: *Frame = &self.frames[self.depth];
                frame.attempt += 1;
                if (frame.attempt > @intFromEnum(self.dfs_options.attempts)) continue :state .exit;
                const index: u16 = @intCast(std.sort.argMax(Float, frame.weights[0..self.candidates.len], {}, std.sort.asc(Float)) orelse unreachable);
                if (frame.weights[index] <= Query.bad) continue :state .exit;
                frame.index = index;

                // Advance frame depth and return on full match
                self.depth += 1;
                self.signals[self.depth] = self.candidates[index];
                if (self.depth == max_frame_depth) return &self.signals;

                // Set up new frame
                const new_frame: *Frame = &self.frames[self.depth];
                new_frame.* = .{ .weights = self.weight_buffer[self.candidates.len * self.depth ..][0..self.candidates.len] };

                @memcpy(new_frame.weights, frame.weights);
                self.dfs_options.query.query(self.candidates[index], self.candidates, new_frame.weights, self.options);
                continue :state .enter;
            },
        }
        return null;
    }
};

inline fn getToA(scale: u32, comptime times: []const u32) [times.len]Toa {
    var out: [times.len]Toa = undefined;
    for (times, &out) |nano, *toa| {
        toa.* = .{
            .nanosecond = scale * nano,
            .dBm = 0.0,
        };
    }
    return out;
}

test findTime {
    var buffer: [16]Toa = getToA(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    try std.testing.expect(findTime(&buffer, 0) == 0);
    try std.testing.expect(findTime(&buffer, std.math.maxInt(u32)) == 16);
    try std.testing.expect(findTime(&buffer, buffer[12].nanosecond) == 12);
    try std.testing.expect(findTime(&buffer, buffer[3].nanosecond + 5) == 4);
    try std.testing.expect(findTime(&buffer, buffer[9].nanosecond - 5) == 9);
}

test getSpan {
    var sequence: [16]Toa = getToA(1, &.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 });

    try std.testing.expectEqual(SubSlice.initRange(3, 7), getSpan(&sequence, .initRange(7, 11)));
    try std.testing.expectEqual(SubSlice.initRange(0, 1), getSpan(&sequence, .initRange(1, 5)));
    try std.testing.expectEqual(SubSlice.initRange(13, 16), getSpan(&sequence, .initRange(17, 23)));
}

test "autocorrelation" {
    var signal: [16]Toa = getToA(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    var weights: [16]Float = @splat(1);
    var corr_buffer: [5]Float = @splat(std.math.nan(Float));

    correlation(&signal, &weights, &signal, &weights, &corr_buffer, .fromPower(-1));
    try std.testing.expect(corr_buffer[corr_buffer.len >> 1] == 16.0);
    corr_buffer[corr_buffer.len >> 1] = 0;
    try std.testing.expect(std.mem.allEqual(Float, &corr_buffer, 0));
}

test correlation {
    const length = 20;
    const signal_x: [length]Toa = getToA(4, &.{ 6, 7, 11, 15, 23, 33, 37, 43, 46, 51, 59, 66, 75, 84, 86, 93, 101, 109, 118, 120 });
    const weights_x: [length]Float = .{ 10, 10, 1, 5, 8, 4, 3, 8, 3, 1, 1, 5, 6, 6, 7, 9, 5, 2, 5, 10 };
    const signal_y: [length]Toa = getToA(4, &.{ 6, 16, 25, 35, 40, 44, 45, 49, 55, 56, 59, 63, 72, 74, 78, 82, 86, 94, 95, 97 });
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
