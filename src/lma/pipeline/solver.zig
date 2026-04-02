const std = @import("std");

const lma = @import("../lma.zig");

pub const Float = f64;
pub const Point = lma.pipeline.zlm(Float).Vec3;
pub const Vec = @Vector(4, Float);
const Arr = [4]Float;

pub const linear = struct {
    inline fn swizzle(vec: Vec, comptime mask: @Vector(4, i32)) Vec {
        return @shuffle(Float, vec, undefined, mask);
    }

    inline fn mat_x_mat(a: Vec, b: Vec) Vec {
        // zig fmt: off
        return (
            (a * swizzle(b, .{ 0, 3, 0, 3 })) +
            (swizzle(a, .{ 1, 0, 3, 2 }) * swizzle(b, .{ 2, 1, 2, 1 }))
        );
        // zig fmt: on
    }

    inline fn adj_x_mat(a: Vec, b: Vec) Vec {
        // zig fmt: off
        return (
            (swizzle(a, .{ 3, 3, 0, 0 }) * b) -
            (swizzle(a, .{ 1, 1, 2, 2 }) * swizzle(b, .{ 2, 3, 0, 1 }))
        );
        // zig fmt: on
    }

    inline fn mat_x_adj(a: Vec, b: Vec) Vec {
        // zig fmt: off
        return (
            (a * swizzle(b, .{ 3, 0, 3, 0 })) -
            (swizzle(a, .{ 1, 0, 3, 2 }) * swizzle(b, .{ 2, 1, 2, 1 }))
        );
        // zig fmt: on
    }

    pub fn blockInverse(mat: *const [4]Vec, inv_mat: *[4]Vec) void {
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

        // std.debug.print("BLOCK DET: {any}\n", .{determinants});

        const det_a = swizzle(determinants, @splat(0));
        const det_b = swizzle(determinants, @splat(1));
        const det_c = swizzle(determinants, @splat(2));
        const det_d = swizzle(determinants, @splat(3));

        // Store common intermediate results
        const @"a_adj x b" = adj_x_mat(a, b);
        const @"d_adj x c" = adj_x_mat(d, c);

        // Determinant of the full matrix
        const trace: Vec = @splat(@reduce(.Add, @"a_adj x b" * swizzle(@"d_adj x c", .{ 0, 2, 1, 3 })));
        const det_m = det_a * det_d + det_b * det_c - trace;
        const sign: Vec = .{ 1, -1, -1, 1 };
        const inv_det_m = sign / det_m;

        // Blocks of the inverted matrix
        const x = inv_det_m * ((det_d * a) - mat_x_mat(b, @"d_adj x c"));
        const y = inv_det_m * ((det_b * c) - mat_x_adj(d, @"a_adj x b"));
        const z = inv_det_m * ((det_c * b) - mat_x_adj(a, @"d_adj x c"));
        const w = inv_det_m * ((det_a * d) - mat_x_mat(c, @"a_adj x b"));

        inv_mat.* = .{
            @shuffle(Float, x, y, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
            @shuffle(Float, x, y, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
            @shuffle(Float, z, w, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
            @shuffle(Float, z, w, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
        };
    }

    /// Solving 4x4 linear system using gaussian elimination
    pub fn solveGaussian(mat: *const [4]Vec, bias: Vec) Vec {
        var gauss_mat: [4]Vec = mat.*;
        var x: Arr = bias;

        for (0..4) |r| {
            const scale = @as(Arr, gauss_mat[r])[r];
            gauss_mat[r] /= @as(Vec, @splat(scale));
            x[r] /= scale;

            for (0..4) |c| {
                if (r == c) continue;
                const coef = @as(Arr, gauss_mat[c])[r];
                gauss_mat[c] -= gauss_mat[r] * @as(Vec, @splat(coef));
                x[c] -= x[r] * coef;
            }
        }

        return x;
    }

    /// Vectorization for efficiently solving 4x4 linear system at the cost of some precision
    pub fn solveBlocks(mat: *const [4]Vec, bias: Vec) Vec {
        var inv_mat: [4]Vec = undefined;
        blockInverse(mat, &inv_mat);

        return .{
            @reduce(.Add, inv_mat[0] * bias),
            @reduce(.Add, inv_mat[1] * bias),
            @reduce(.Add, inv_mat[2] * bias),
            @reduce(.Add, inv_mat[3] * bias),
        };
    }

    /// Give an approximate solution to the ToA problem by solving the linearized equations
    /// Uses a fixed number of equations given at comptime to skip multiplying by the transpose if not necessary
    pub fn solveFixed(comptime size: usize, mat: *const [size]Vec, bias: *const [size]Float, comptime method: fn (*const [4]Vec, Vec) Vec) Vec {
        if (size < 4) @compileError("Matrix has no unique solution");
        if (size == 4) return method(mat, bias.*);
        return solve(mat, bias, method);
    }

    /// Give an approximate solution to the ToA problem by solving the linearized equations
    pub fn solve(mat: []const Vec, bias: []const Float, comptime method: fn (*const [4]Vec, Vec) Vec) Vec {
        var mat_inner: [4]Vec = @splat(@splat(0));
        var bias_inner: Vec = @splat(0);
        for (mat, bias) |row, b| {
            const col: [4]Float = row;
            for (col, 0..) |elem, r| mat_inner[r] += row * @as(Vec, @splat(elem));
            bias_inner += row * @as(Vec, @splat(b));
        }
        return method(&mat_inner, bias_inner);
    }

    fn test_cases(comptime method: fn (*const [4]Vec, Vec) Vec) type {
        return struct {
            test "Sanity check" {
                // Sanity check
                try std.testing.expectEqual(
                    @as(Vec, .{ 1, 2, 3, 4 }),
                    method(&.{
                        .{ 1, 0, 0, 0 },
                        .{ 0, 1, 0, 0 },
                        .{ 0, 0, 1, 0 },
                        .{ 0, 0, 0, 1 },
                    }, .{ 1, 2, 3, 4 }),
                );
                try std.testing.expectEqual(
                    @as(Vec, .{ 0, 0, -1, 1 }),
                    method(&.{
                        .{ 1, 2, 3, 4 },
                        .{ 0, 1, 2, 3 },
                        .{ 0, 0, 1, 2 },
                        .{ 0, 0, 0, 1 },
                    }, .{ 1, 1, 1, 1 }),
                );
            }

            test "Non-square matrix" {
                // Test on non-square matrix for solving as `x = [At * A] \ [At * b]`
                const expected: Vec = .{ 1, 2, 3, 4 };
                const tolerance: Vec = @splat(1e-5);
                const actual = solveFixed(8, &.{
                    .{ 1, 0, 0, 0 },
                    .{ 0, 1, 0, 0 },
                    .{ 0, 0, 1, 0 },
                    .{ 0, 0, 0, 1 },
                    .{ 1, 2, 0, 0 },
                    .{ 0, 1, 2, 0 },
                    .{ 0, 2, 1, 0 },
                    .{ 0, 1, 1, 1 },
                }, &.{ 1, 2, 3, 4, 5, 8, 7, 9 }, method);
                const pred = @abs(actual - expected) <= @max(@abs(actual), @abs(expected)) * tolerance;
                if (!@reduce(.And, pred)) {
                    const expect_array: [4]Float = expected;
                    const actual_array: [4]Float = actual;
                    try std.testing.expectEqualSlices(Float, &expect_array, &actual_array);
                }
            }

            test "Random matrix" {
                // Test on a random matrix
                const expected: Vec = .{ 0.139687103197207, -0.777889045742257, 0.601347689515521, -0.545537962605801 };
                const tolerance: Float = 1e-15;
                const actual = method(&.{
                    .{ -2.05782, -0.56853, -6.83522, 3.12176 },
                    .{ -3.79283, 6.48790, 3.26692, 7.57333 },
                    .{ 8.92533, -5.75444, -8.67197, 4.48165 },
                    .{ 2.79342, -8.87533, -3.61153, 0.15979 },
                }, .{ -5.65858, -7.74366, -1.93671, 5.03527 });
                if (!(@reduce(.Max, @abs(actual - expected)) < tolerance)) {
                    const expect_array: [4]Float = expected;
                    const actual_array: [4]Float = actual;
                    try std.testing.expectEqualSlices(Float, &expect_array, &actual_array);
                }
            }

            test "Ill-conditioned matrix" {
                // Test on an ill-conditioned matrix (SVD with diagonal: 2, 1, 0.5, 0.01)
                const expected: Vec = .{ -12.34461141882552, -5.753113271600019, -8.603606899817999, 52.116448927888506 };
                const tolerance: Float = 1e-15;
                const actual = method(&.{
                    .{ 0.9036135, -0.2386397, 0.0595151, 0.2205390 },
                    .{ -0.2386397, 1.7831396, 0.4355547, 0.2070320 },
                    .{ 0.0595151, 0.4355547, 0.7027765, 0.1763387 },
                    .{ 0.2205390, 0.2070320, 0.1763387, 0.1204705 },
                }, .{ 1.1998287, -0.2702585, -0.0967522, 0.847799 });
                if (!(@reduce(.Max, @abs(actual - expected) / expected) < tolerance)) {
                    const expect_array: [4]Float = expected;
                    const actual_array: [4]Float = actual;
                    try std.testing.expectEqualSlices(Float, &expect_array, &actual_array);
                }
            }

            test "Large matrix coefficients" {
                // Test on a matrix with large coefficients

                if (method == solveBlocks) return error.SkipZigTest;

                // WolframAlpha
                // x≈1.097341930439×10^9, y≈1.818023898439×10^7, z≈9.44402607061×10^8, w≈-2.004843713694×10^7
                const expected: Vec = .{ 1.097341930439e9, 1.818023898439e7, 9.44402607061e8, -2.004843713694e7 };
                const tolerance: Float = 5e-2;
                const actual = solve(&.{
                    .{ -25094.0503091868, -29320.89929369194, 28761.046511825174, -45284.01625329256 },
                    .{ 236933.65670040622, 374309.2310069331, -285236.37992312014, -131719.84256136417 },
                    .{ -51283.60409959592, 202777.0964314192, 53543.638328762725, -101327.02535408735 },
                    .{ -80439.37343608774, 250204.33606267622, 85228.02186822705, -161792.98778903484 },
                }, &.{ 66495541.18443215, 65063658400.42088, 9087078506.243664, 12539886849.305801 }, method);
                if (!(@reduce(.Max, @abs(actual - expected) / expected) < tolerance)) {
                    const expect_array: [4]Float = expected;
                    const actual_array: [4]Float = actual;
                    try std.testing.expectEqualSlices(Float, &expect_array, &actual_array);
                }
            }
        };
    }

    comptime {
        _ = test_cases(solveBlocks);
        _ = test_cases(solveGaussian);
    }
};

pub const lm = levenberg_marquardt;
pub const levenberg_marquardt = struct {
    pub fn solutionError(data: []const Vec, source: Vec) Float {
        const space: Vec = .{ 1, 1, 1, 0 };
        const time: Vec = .{ 0, 0, 0, 1 };

        var err: Float = 0;
        for (data) |signal_i| {
            const delta = source - signal_i;
            const space_delta = delta * space;
            const time_delta = @reduce(.Add, delta * time);
            const dist = @sqrt(@reduce(.Add, space_delta * delta));

            const err_i = time_delta + dist;
            err += err_i * err_i;
        }
        return err;
    }

    inline fn gradientSystem(data: []const Vec, source: Vec) struct { [4]Vec, Vec } {
        const space: Vec = .{ 1, 1, 1, 0 };
        const time: Vec = .{ 0, 0, 0, 1 };

        var mat: [4]Vec = @splat(@splat(0));
        var bias: Vec = @splat(0);
        for (data) |signal_i| {
            const delta = source - signal_i;
            const space_delta = delta * space;
            const time_delta = @reduce(.Add, delta * time);
            const dist = @sqrt(@reduce(.Add, space_delta * delta));

            const err_i = time_delta + dist;
            const jac = space_delta / @as(Vec, @splat(dist)) + time;
            const jac_arr: [4]Float = jac;

            for (jac_arr, 0..) |elem, r| mat[r] += jac * @as(Vec, @splat(elem));
            bias -= jac * @as(Vec, @splat(err_i));
        }
        return .{ mat, bias };
    }

    fn gradient(mat: *const [4]Vec, bias: Vec, lambda: Float) Vec {
        var damp_mat: [4]Vec = undefined;
        const damping: Vec = .{ 1 + lambda, 1, 1, 1 };
        inline for (0..4) |r| damp_mat[r] = mat[r] * std.simd.rotateElementsRight(damping, r);
        return linear.solveGaussian(&damp_mat, bias);
    }

    pub const LMOptions = struct {
        max_iterations: usize = 1_000,
        min_gradient: Float = @sqrt(std.math.floatEpsAt(Float, 1)),
        min_improvement: Float = std.math.floatEpsAt(Float, 1),
    };

    /// Give an approximate solution to the ToA problem by solving the argument minimization problem
    ///
    /// NOTE: Expects time to be transformed into spatial distance (multiplied by the speed of light constant)
    pub fn solve(data: []const Vec, initial_guess: Vec, options: LMOptions) Vec {
        var lambda: Float = 1e-4;
        const nu: Float = 1.5;
        var source: Vec = initial_guess;
        var best_err = lm.solutionError(data, initial_guess) - options.min_improvement;
        for (0..options.max_iterations) |_| {
            const mat: [4]Vec, const bias: Vec = gradientSystem(data, source);

            // Decrease lambda
            const dec_lambda = lambda / nu;
            const dec_grad = gradient(&mat, bias, dec_lambda);
            const dec_err = solutionError(data, source + dec_grad);

            // Keep lambda
            var grad = gradient(&mat, bias, lambda);
            var err = solutionError(data, source + grad);

            if (dec_err < err) {
                lambda = dec_lambda;
                grad = dec_grad;
                err = dec_err;
            } else while (err >= best_err) {
                const inc_lambda = lambda * nu;
                const inc_grad = gradient(&mat, bias, inc_lambda);
                const inc_err = solutionError(data, source + inc_grad);

                if (inc_err < err) {
                    lambda = inc_lambda;
                    grad = inc_grad;
                    err = inc_err;
                } else break;
            }

            if (best_err <= err) break;
            source += grad;
            best_err = err - options.min_improvement;
            if (@reduce(.Add, grad * grad) <= options.min_gradient) break;
        }
        return source;
    }

    /// Give an approximate solution to the ToA problem by solving the argument minimization problem without dampening
    ///
    /// NOTE: Expects time to be transformed into spatial distance (i.e. multiplied by the speed of light constant)
    pub fn solveBasic(data: []const Vec, initial_guess: Vec, options: LMOptions) Vec {
        var source: Vec = initial_guess;
        var best_err = lm.solutionError(data, initial_guess) - options.min_improvement;
        for (0..options.max_iterations) |_| {
            const mat: [4]Vec, const bias: Vec = gradientSystem(data, source);
            const grad: Vec = linear.solveBlocks(&mat, bias);
            const err = solutionError(data, source + grad);

            if (best_err <= err) break;
            source += grad;
            best_err = err - options.min_improvement;
            if (@reduce(.Add, grad * grad) <= options.min_gradient * options.min_gradient) break;
        }
        return source;
    }

    test solve {
        const expected: Vec = .{ 1, 2, 3, 1 };
        const tolerance: Float = 1e-3;
        const actual = solve(
            &.{
                .{ 0, 0, 0, 1 + @sqrt(14.0) },
                .{ 1, 0, 0, 1 + @sqrt(13.0) },
                .{ 0, 1, 0, 1 + @sqrt(11.0) },
                .{ 0, 0, 1, 1 + @sqrt(9.0) },
            },
            .{ 2, 2, 2, 1 },
            .{ .min_gradient = 1e-12, .min_improvement = 0 },
        );
        if (!(@reduce(.Max, @abs(actual - expected)) < tolerance)) {
            const expect_array: Arr = expected;
            const actual_array: Arr = actual;
            try std.testing.expectEqualSlices(Float, &expect_array, &actual_array);
        }
    }

    test "solve with noise" {
        const source: Point = .new(3, 7, 0);
        const time: Float = 3;

        const stations: [8]Point = .{
            .new(0, 0, 0),
            .new(8, 0, 0),
            .new(0, 4, 0),
            .new(0, 0, 3),
            .new(0, 1, 1),
            .new(1, 0, 9),
            .new(5, 6, 0),
            .new(6, 3, 4),
        };
        const noise: [8]Float = .{ 0.1, -0.1, 0.0, -0.2, 0.2, 0.0, 0.1, -0.1 };
        const data: [8]Vec = blk: {
            var buf: [8]Vec = undefined;
            for (stations, noise, &buf) |station, offset, *signal_i| {
                signal_i.* = .{ station.x, station.y, station.z, time + station.distance(source) + offset };
            }
            break :blk buf;
        };

        const expect_arr: Vec = .{ 3.074051238391461, 6.753612729722382, 0.181343617094229, 3.217381399104787 };
        const tolerance: Float = 1e-7;
        const actual = solve(&data, .{ 5, 5, 5, 5 + time }, .{ .max_iterations = 50, .min_gradient = 0, .min_improvement = 0 });
        if (!(@reduce(.Max, @abs(actual - expect_arr)) < tolerance)) {
            const expect_array: Arr = expect_arr;
            const actual_array: Arr = actual;
            try std.testing.expectEqualSlices(Float, &expect_array, &actual_array);
        }

        const expected_err = solutionError(&data, expect_arr);
        const tolerance_err: Float = 1e-12;
        const actual_err = solutionError(&data, actual);
        try std.testing.expectApproxEqAbs(expected_err, actual_err, tolerance_err);
    }
};

comptime {
    std.testing.refAllDecls(linear);
    std.testing.refAllDecls(levenberg_marquardt);
}
