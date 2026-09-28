const std = @import("std");
const lma = @import("../../lma.zig");
const match = lma.pipeline.match;

const Correlation = match.Correlation;
const Candidate = match.Candidate;
const Float = match.Float;

const max_consensus = lma.constants.network.max_consensus;

pub fn updateLoglikelihood(
    reference: Candidate,
    candidates: []const Candidate,
    loglikelihoods: []Float,
    correlation: *const Correlation,
) void {
    const bad = comptime -std.math.inf(Float);
    for (candidates, loglikelihoods[0..candidates.len]) |candidate, *total| {
        if (!std.math.isFinite(total.*)) continue;
        total.* += blk: {
            if (reference.station == candidate.station) break :blk bad;
            const idx = correlation.shape.ravel(reference.station, candidate.station);
            const max_time = correlation.time_matrix[idx];
            const sub_slice = correlation.corr_matrix[idx];

            const delta: i32 = @bitCast(reference.nanosecond -% candidate.nanosecond);
            if (@abs(delta) > max_time) break :blk bad;
            const offset_round = sub_slice.size << (correlation.step.shift - 1);
            const offset = (offset_round +% @as(u32, @bitCast(delta))) >> correlation.step.shift;
            break :blk if (offset < sub_slice.size) correlation.corr_buffer[sub_slice.start + offset] else bad;
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

    pub fn init(initial: Candidate, candidates: []const Candidate, buffer: []Float, corr: *const Correlation, options: *const Options) BeamSearch {
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
    corr: *const Correlation,
    options: *const Options,

    pub fn init(seed: Candidate, candidates: []const Candidate, buffer: []Float, corr: *const Correlation, options: *const Options) DepthFirstSearch {
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
