const std = @import("std");
const lma = @import("../lma.zig");

pub fn solver(Float: type) type {
    return struct {
        inline fn swizzle(vec: @Vector(4, Float), comptime mask: @Vector(4, i32)) @Vector(4, Float) {
            return @shuffle(Float, vec, undefined, mask);
        }

        inline fn mat_x_mat(a: @Vector(4, Float), b: @Vector(4, Float)) @Vector(4, Float) {
            // zig fmt: off
            return (
                (a * swizzle(b, .{ 0, 3, 0, 3 })) +
                (swizzle(a, .{ 1, 0, 3, 2 }) * swizzle(b, .{ 2, 1, 2, 1 }))
            );
            // zig fmt: on
        }

        inline fn adj_x_mat(a: @Vector(4, Float), b: @Vector(4, Float)) @Vector(4, Float) {
            // zig fmt: off
            return (
                (swizzle(a, .{ 3, 3, 0, 0 }) * b) -
                (swizzle(a, .{ 1, 1, 2, 2 }) * swizzle(b, .{ 2, 3, 0, 1 }))
            );
            // zig fmt: on
        }

        inline fn mat_x_adj(a: @Vector(4, Float), b: @Vector(4, Float)) @Vector(4, Float) {
            // zig fmt: off
            return (
                (a * swizzle(b, .{ 3, 0, 3, 0 })) -
                (swizzle(a, .{ 1, 0, 3, 2 }) * swizzle(b, .{ 2, 1, 2, 1 }))
            );
            // zig fmt: on
        }

        /// Give an approximate solution to the ToA problem by solving the linearized equations
        pub fn approxSolve(mat: [4]@Vector(4, Float), bias: [4]Float) @Vector(4, Float) {
            @setRuntimeSafety(false);

            // Divide the matrix into 4 blocks
            const a = @shuffle(Float, mat[0], mat[1], [_]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
            const b = @shuffle(Float, mat[0], mat[1], [_]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });
            const c = @shuffle(Float, mat[2], mat[3], [_]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
            const d = @shuffle(Float, mat[2], mat[3], [_]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });

            // Calculate determinants of submatrices
            // zig fmt: off
            const determinants = (
                (
                    @shuffle(Float, mat[0], mat[2], [_]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }) *
                    @shuffle(Float, mat[1], mat[3], [_]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) })
                ) - (
                    @shuffle(Float, mat[1], mat[3], [_]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }) *
                    @shuffle(Float, mat[0], mat[2], [_]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) })
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
            const trace: @Vector(4, Float) = @splat(@reduce(.Add, @"a_adj x b" * swizzle(@"d_adj x c", .{ 0, 2, 1, 3 })));
            const det_m = det_a * det_d + det_b * det_c - trace;
            const sign: @Vector(4, Float) = .{ 1, -1, -1, 1 };
            const inv_det_m = sign / det_m;

            // Blocks of the inverted matrix
            const x = inv_det_m * ((det_d * a) - mat_x_mat(b, @"d_adj x c"));
            const y = inv_det_m * ((det_b * c) - mat_x_adj(d, @"a_adj x b"));
            const z = inv_det_m * ((det_c * b) - mat_x_adj(a, @"d_adj x c"));
            const w = inv_det_m * ((det_a * d) - mat_x_mat(c, @"a_adj x b"));

            const inv_m: [4]@Vector(4, Float) = .{
                @shuffle(Float, x, y, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
                @shuffle(Float, x, y, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
                @shuffle(Float, z, w, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
                @shuffle(Float, z, w, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
            };

            const vector_bias: @Vector(4, Float) = bias;

            return .{
                @reduce(.Add, inv_m[0] * vector_bias),
                @reduce(.Add, inv_m[1] * vector_bias),
                @reduce(.Add, inv_m[2] * vector_bias),
                @reduce(.Add, inv_m[3] * vector_bias),
            };
        }
    };
}

test "approxSolve" {
    // Sanity check
    try std.testing.expectEqual(
        solver(f32).approxSolve(.{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        }, .{ 1, 2, 3, 4 }),
        .{ 1, 2, 3, 4 },
    );
    try std.testing.expectEqual(
        solver(f32).approxSolve(.{
            .{ 1, 2, 3, 4 },
            .{ 0, 1, 2, 3 },
            .{ 0, 0, 1, 2 },
            .{ 0, 0, 0, 1 },
        }, .{ 1, 1, 1, 1 }),
        .{ 0, 0, -1, 1 },
    );

    // Test on a real matrix
    const expected: @Vector(4, f64) = .{ 0.1396871, -0.77788905, 0.60134769, -0.54553796 };
    const tolerance: @Vector(4, f64) = @splat(1e-6);
    const actual = solver(f64).approxSolve(.{
        .{ -2.05782, -0.56853, -6.83522, 3.12176 },
        .{ -3.79283, 6.48790, 3.26692, 7.57333 },
        .{ 8.92533, -5.75444, -8.67197, 4.48165 },
        .{ 2.79342, -8.87533, -3.61153, 0.15979 },
    }, .{ -5.65858, -7.74366, -1.93671, 5.03527 });
    const pred = @abs(actual - expected) <= @max(@abs(actual), @abs(expected)) * tolerance;
    if (std.simd.countTrues(pred) != 4) {
        const expect_array: [4]f64 = expected;
        const actual_array: [4]f64 = actual;
        try std.testing.expectEqualSlices(f64, &expect_array, &actual_array);
    }
}
