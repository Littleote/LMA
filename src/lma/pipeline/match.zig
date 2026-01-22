const std = @import("std");
const lma = @import("../lma.zig");
const common = lma.common;
const float = lma.pipeline.float;
const ToA = lma.data.types.ToA;
const i30p2 = 4 * 1_000_000_000;

/// Step size for discretizing the signal
pub const Step = struct {
    /// Step size in seconds
    step: float,
    /// High bit of the nanosecond expressed with fixed precision 30.2
    /// Equivalent to how much to shift a bit to get the step size
    shift: u5,

    /// Generate a step size given the power of two of nanoseconds
    /// Some methods may fail for steps smaller than 1 nanosecond
    pub fn fromPower(pow: i8) Step {
        const shift: u5 = @intCast(pow + 2);
        return .{
            .step = common.cast(float, @as(u32, 1) << shift) / i30p2,
            .shift = shift,
        };
    }

    /// Generate a step size close to a desired size in seconds
    /// Some methods may fail for steps smaller than 1 nanosecond
    pub fn fromStep(desired_step: float) Step {
        return .fromShift(@intFromFloat(@round(@log2(1_000_000_000 * desired_step))));
    }
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

pub fn correlation(first: []const ToA, second: []const ToA, corr: []float, step: Step) void {
    const shift: u5 = step.shift;
    // const size: u32 = @intCast(corr.len >> 1);
    // const round: i32 = @as(i32, 1) << (shift - 1);
    const offset_round: usize = @intCast(corr.len << (shift - 1));
    const above: u32 = @intCast(offset_round); // common.as(u32, round) + size * (@as(u32, 1) << shift);
    const below: u32 = above - 1;
    var low: u32 = 0;
    var high: u32 = 0;
    var upper: u32 = 0;
    for (first) |x| {
        const threshold = x.nanosecond +| above;
        var backoff: u5 = 0;
        upper = high;
        while (upper < second.len) : ({
            upper += @as(u32, 1) << backoff;
            backoff += 1;
        }) {
            if (second[upper].nanosecond > threshold) break;
        } else {
            upper = @intCast(second.len);
        }
        high = high + findTime(second[high..upper], threshold);
        low = low + findTime(second[low..high], x.nanosecond -| below);
        for (second[low..high]) |y| {
            const idx = (offset_round + x.nanosecond - y.nanosecond) >> shift;
            // const offset: i32 = (lma.math.delta(u32, x.nanosecond, y.nanosecond) + round) >> shift;
            // const idx: u32 = lma.math.offset(u32, size, offset);
            corr[idx] += 1;
        }
    }
}

fn randomTimes(slice: []ToA, rand: std.Random) void {
    var nanosecond: u32 = 0;
    for (slice) |*entry| {
        nanosecond += 10 + common.cast(u32, (@round(1_000 * @min(100.0, rand.floatExp(f32)))));
        entry.* = .{
            .nanosecond = nanosecond,
            .dBm = common.as(f16, 200.0 * rand.float(f32) - 120.0),
        };
    }
}

test findTime {
    var buffer: [512]ToA = undefined;
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomTimes(&buffer, random);

    try std.testing.expect(findTime(&buffer, 0) == 0);
    try std.testing.expect(findTime(&buffer, std.math.maxInt(u32)) == 512);
    try std.testing.expect(findTime(&buffer, buffer[123].nanosecond) == 123);
    try std.testing.expect(findTime(&buffer, buffer[321].nanosecond + 5) == 322);
    try std.testing.expect(findTime(&buffer, buffer[98].nanosecond - 5) == 98);
}

test "autocorrelation" {
    var buffer: [512]ToA = undefined;
    var corr_buffer: [5]float = @splat(0);
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomTimes(&buffer, random);

    correlation(&buffer, &buffer, &corr_buffer, .fromPower(-1));
    try std.testing.expect(corr_buffer[corr_buffer.len >> 1] == 512.0);
    corr_buffer[corr_buffer.len >> 1] = 0;
    try std.testing.expect(std.mem.allEqual(float, &corr_buffer, 0));
}
test correlation {
    var first: [4096]ToA = undefined;
    var second: [4096]ToA = undefined;
    var corr_buffer: [15]float = @splat(0);
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomTimes(&first, random);
    randomTimes(&second, random);

    correlation(&first, &second, &corr_buffer, .fromPower(6));
}
