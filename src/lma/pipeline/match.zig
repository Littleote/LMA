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
        return .fromPower(@intFromFloat(@round(@log2(1_000_000_000 * desired_step))));
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

pub fn divide(slice: []const ToA, index: []u32) void {
    const step: u32 = @intCast(4_000_000_000 / (index.len - 1));
    for (index, 0..) |*idx, division| {
        idx.* = findTime(slice, common.as(u32, division) * step);
    }
}

/// Find the correlation between the sparse signals x and y.
///
/// Time described by the nanosecond of the ToA field.
/// Weight described by the weights slice.
pub fn correlation(time_x: []const ToA, weights_x: []const float, time_y: []const ToA, weights_y: []const float, corr: []float, step: Step) void {
    const shift: u5 = step.shift;
    const offset_round: usize = @intCast(corr.len << (shift - 1));
    const above: u32 = @intCast(offset_round);
    const below: u32 = above - 1;
    var low: u32 = 0;
    var high: u32 = 0;
    var upper: u32 = 0;
    for (time_x, weights_x) |x, wx| {
        const threshold = x.nanosecond +| above;
        var backoff: u5 = 0;
        upper = high;
        while (upper < time_y.len) : ({
            upper += @as(u32, 1) << backoff;
            backoff += 1;
        }) {
            if (time_y[upper].nanosecond > threshold) break;
        } else {
            upper = @intCast(time_y.len);
        }
        high = high + findTime(time_y[high..upper], threshold);
        low = low + findTime(time_y[low..high], x.nanosecond -| below);
        for (time_y[low..high], weights_y[low..high]) |y, wy| {
            const idx = (offset_round + x.nanosecond - y.nanosecond) >> shift;
            corr[idx] += wx * wy;
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

test divide {
    return error.SkipZigTest;
}

test "autocorrelation" {
    var times: [512]ToA = undefined;
    var weights: [512]float = @splat(1);
    var corr_buffer: [5]float = @splat(0);
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomTimes(&times, random);

    correlation(&times, &weights, &times, &weights, &corr_buffer, .fromPower(-1));
    try std.testing.expect(corr_buffer[corr_buffer.len >> 1] == 512.0);
    corr_buffer[corr_buffer.len >> 1] = 0;
    try std.testing.expect(std.mem.allEqual(float, &corr_buffer, 0));
}
test correlation {
    var times_x: [4096]ToA = undefined;
    var weights_x: [4096]float = @splat(1);
    var times_y: [4096]ToA = undefined;
    var weights_y: [4096]float = @splat(1);
    var corr_buffer: [15]float = @splat(0);
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    randomTimes(&times_x, random);
    randomTimes(&times_y, random);

    correlation(&times_x, &weights_x, &times_y, &weights_y, &corr_buffer, .fromPower(6));
}

pub fn quantile_scale(corr: []const float, scaled: []float) void {
    @memcpy(scaled, corr);
    std.sort.block(float, scaled, {}, std.sort.asc(float));
    const q1, const q3 = .{ scaled[scaled.len / 4], scaled[3 * scaled.len / 4] };
    const iqr = q3 - q1;
    for (corr, scaled) |c, *s| s.* = (c - q3) / iqr;
}

test quantile_scale {
    return error.SkipZigTest;
}

inline fn swizzle(vec: @Vector(4, float), comptime mask: @Vector(4, i32)) @Vector(4, float) {
    return @shuffle(float, vec, undefined, mask);
}

inline fn mat_x_mat(a: @Vector(4, float), b: @Vector(4, float)) @Vector(4, float) {
    // zig fmt: off
    return (
        (a * swizzle(b, .{ 0, 3, 0, 3 })) +
        (swizzle(a, .{ 1, 0, 3, 2 }) * swizzle(b, .{ 2, 1, 2, 1 }))
    );
    // zig fmt: on
}

inline fn adj_x_mat(a: @Vector(4, float), b: @Vector(4, float)) @Vector(4, float) {
    // zig fmt: off
    return (
        (swizzle(a, .{ 3, 3, 0, 0 }) * b) -
        (swizzle(a, .{ 1, 1, 2, 2 }) * swizzle(b, .{ 2, 3, 0, 1 }))
    );
    // zig fmt: on
}

inline fn mat_x_adj(a: @Vector(4, float), b: @Vector(4, float)) @Vector(4, float) {
    // zig fmt: off
    return (
        (a * swizzle(b, .{ 3, 0, 3, 0 })) -
        (swizzle(a, .{ 1, 0, 3, 2 }) * swizzle(b, .{ 2, 1, 2, 1 }))
    );
    // zig fmt: on
}

/// Give an approximate solution to the ToA problem by solving the linearized equations
pub fn approxSolve(mat: [4]@Vector(4, float), bias: @Vector(4, float)) @Vector(4, float) {
    @setRuntimeSafety(false);

    // Divide the matrix into 4 blocks
    const a = @shuffle(float, mat[0], mat[1], [_]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
    const b = @shuffle(float, mat[0], mat[1], [_]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });
    const c = @shuffle(float, mat[2], mat[3], [_]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
    const d = @shuffle(float, mat[2], mat[3], [_]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });

    // Calculate determinants of submatrices
    // zig fmt: off
    const determinants = (
        (
            @shuffle(float, mat[0], mat[2], [_]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }) *
            @shuffle(float, mat[1], mat[3], [_]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) })
        ) - (
            @shuffle(float, mat[1], mat[3], [_]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }) *
            @shuffle(float, mat[0], mat[2], [_]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) })
        )
    );
    // zig fmt: on

    const det_a = swizzle(determinants, @splat(0));
    const det_b = swizzle(determinants, @splat(1));
    const det_c = swizzle(determinants, @splat(2));
    const det_d = swizzle(determinants, @splat(3));

    // Store common intermediate results
    const @"a_adj x b" = adj_x_mat(a, b);
    const @"d_adj x c" = adj_x_mat(d, c);

    // Determinant of the full matrix
    const trace: @Vector(4, float) = @splat(@reduce(.Add, @"a_adj x b" * swizzle(@"d_adj x c", .{ 0, 2, 1, 3 })));
    const det_m = det_a * det_d + det_b * det_c - trace;
    const sign: @Vector(4, float) = .{ 1, -1, -1, 1 };
    const inv_det_m = sign / det_m;

    // Blocks of the inverted matrix
    const x = inv_det_m * ((det_d * a) - mat_x_mat(b, @"d_adj x c"));
    const y = inv_det_m * ((det_b * c) - mat_x_adj(d, @"a_adj x b"));
    const z = inv_det_m * ((det_c * b) - mat_x_adj(a, @"d_adj x c"));
    const w = inv_det_m * ((det_a * d) - mat_x_mat(c, @"a_adj x b"));

    const inv_m: [4]@Vector(4, float) = .{
        @shuffle(float, x, y, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
        @shuffle(float, x, y, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
        @shuffle(float, z, w, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
        @shuffle(float, z, w, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
    };

    return .{
        @reduce(.Add, inv_m[0] * bias),
        @reduce(.Add, inv_m[1] * bias),
        @reduce(.Add, inv_m[2] * bias),
        @reduce(.Add, inv_m[3] * bias),
    };
}

test approxSolve {
    // Sanity check
    try std.testing.expectEqual(
        approxSolve(.{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        }, .{ 1, 2, 3, 4 }),
        .{ 1, 2, 3, 4 },
    );
    try std.testing.expectEqual(
        approxSolve(.{
            .{ 1, 2, 3, 4 },
            .{ 0, 1, 2, 3 },
            .{ 0, 0, 1, 2 },
            .{ 0, 0, 0, 1 },
        }, .{ 1, 1, 1, 1 }),
        .{ 0, 0, -1, 1 },
    );

    // Test on a real matrix
    const expected: @Vector(4, float) = .{ 0.1396871, -0.77788905, 0.60134769, -0.54553796 };
    const tolerance: @Vector(4, float) = @splat(1e-6);
    const actual = approxSolve(.{
        .{ -2.05782, -0.56853, -6.83522, 3.12176 },
        .{ -3.79283, 6.48790, 3.26692, 7.57333 },
        .{ 8.92533, -5.75444, -8.67197, 4.48165 },
        .{ 2.79342, -8.87533, -3.61153, 0.15979 },
    }, .{ -5.65858, -7.74366, -1.93671, 5.03527 });
    const pred = @abs(actual - expected) <= @max(@abs(actual), @abs(expected)) * tolerance;
    if (std.simd.countTrues(pred) != 4) {
        const expect_array: [4]float = expected;
        const actual_array: [4]float = actual;
        try std.testing.expectEqualSlices(float, &expect_array, &actual_array);
    }
}
