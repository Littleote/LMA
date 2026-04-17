const std = @import("std");

const lma = @import("../lma.zig");

pub const Float = f64;
pub const math = lma.pipeline.math(Float);
pub const Vec = math.Vec;
const Arr = math.ElemVec;
pub const Mat = math.Mat;
const ElemMat = math.ElemMat;

pub const linear = struct {
    const swizzle = math.vector.swizzle;

    inline fn mat_x_mat(a: Vec, b: Vec) Vec {
        return ((a * swizzle(b, .xwxw)) +
            (swizzle(a, .yxwz) * swizzle(b, .zyzy)));
    }

    inline fn adj_x_mat(a: Vec, b: Vec) Vec {
        return ((swizzle(a, .wwxx) * b) -
            (swizzle(a, .yyzz) * swizzle(b, .zwxy)));
    }

    inline fn mat_x_adj(a: Vec, b: Vec) Vec {
        return ((a * swizzle(b, .wxwx)) -
            (swizzle(a, .yxwz) * swizzle(b, .zyzy)));
    }

    pub fn blockInverse(mat: *const [4]Vec, inv_mat: *[4]Vec) void {
        @setRuntimeSafety(false);

        // Divide the matrix into 4 blocks
        const a = @shuffle(Float, mat[0], mat[1], [_]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
        const b = @shuffle(Float, mat[0], mat[1], [_]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });
        const c = @shuffle(Float, mat[2], mat[3], [_]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
        const d = @shuffle(Float, mat[2], mat[3], [_]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });

        // Calculate determinants of submatrices
        const determinants = ( //
            ( //
                @shuffle(Float, mat[0], mat[2], [_]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }) *
                    @shuffle(Float, mat[1], mat[3], [_]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) }) //
            ) - ( //
                @shuffle(Float, mat[1], mat[3], [_]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }) *
                    @shuffle(Float, mat[0], mat[2], [_]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) }) //
            ) //
        );

        // std.debug.print("BLOCK DET: {any}\n", .{determinants});

        const det_a = swizzle(determinants, .xxxx);
        const det_b = swizzle(determinants, .yyyy);
        const det_c = swizzle(determinants, .zzzz);
        const det_d = swizzle(determinants, .wwww);

        // Store common intermediate results
        const @"a_adj x b" = adj_x_mat(a, b);
        const @"d_adj x c" = adj_x_mat(d, c);

        // Determinant of the full matrix
        const trace: Vec = @splat(@reduce(.Add, @"a_adj x b" * swizzle(@"d_adj x c", .xzyw)));
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
        var x: Arr = .init(bias);

        for (0..4) |r| {
            const scale = @as(Arr, .init(gauss_mat[r])).elems[r];
            gauss_mat[r] /= math.vector.splat(scale);
            x.elems[r] /= scale;

            for (0..4) |c| {
                if (r == c) continue;
                const coef = @as(Arr, .init(gauss_mat[c])).elems[r];
                gauss_mat[c] -= gauss_mat[r] * math.vector.splat(coef);
                x.elems[c] -= x.elems[r] * coef;
            }
        }

        return x.build();
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
        if (mat.len == 4)
            return method(mat[0..4], bias[0..4].*);

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

pub const ls = least_squares;
pub const least_squares = struct {
    pub fn toaError(data: []const Vec, source: Vec) Float {
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

    inline fn toaSystem(data: []const Vec, source: Vec) struct { [4]Vec, Vec } {
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

    fn toaLine(data: []const Vec, source: Vec, dir: Vec) struct { Float, Float } {
        const space: Vec = .{ 1, 1, 1, 0 };
        const time: Vec = .{ 0, 0, 0, 1 };

        var err: Float = 0;
        var grad: Float = 0;
        for (data) |signal_i| {
            const delta = source - signal_i;
            const space_delta = delta * space;
            const time_delta = @reduce(.Add, delta * time);
            const dist = @sqrt(@reduce(.Add, space_delta * delta));

            const err_i = time_delta + dist;
            const jac = space_delta / @as(Vec, @splat(dist)) + time;

            err += err_i * err_i;
            grad += @reduce(.Add, dir * jac) * err_i;
        }
        return .{ err, grad };
    }

    pub const LSOptions = struct {
        pub const Termination = enum {
            unknown,
            bad_input,
            max_iterations,
            min_gradient,
            min_improvement,
        };

        max_iterations: usize = 1_000,
        min_gradient: Float = std.math.floatEpsAt(Float, 1),
        min_improvement: Float = std.math.floatEpsAt(Float, 1),
        termination: ?*Termination = null,

        pub fn setTermination(self: *const LSOptions, reason: Termination) void {
            if (self.termination) |termination| termination.* = reason;
        }
    };

    pub const lm = levenberg_marquardt;
    pub const levenberg_marquardt = struct {
        pub const LMOptions = struct {
            common: LSOptions,
            min_rho: Float = 0.1,
            max_delta: Float = 100,
        };

        fn gradient(mat: *const [4]Vec, bias: Vec, lambda: Float) Vec {
            var damp_mat: [4]Vec = undefined;
            const damping: Vec = .{ 1 + lambda, 1, 1, 1 };
            inline for (0..4) |r| damp_mat[r] = mat[r] * std.simd.rotateElementsRight(damping, r);
            return linear.solveGaussian(&damp_mat, bias);
        }

        fn diagonal(mat: *const [4]Vec) Vec {
            var diag: Arr = undefined;
            for (0..4) |r| {
                const row: Arr = .init(mat[r]);
                diag.elems[r] = std.math.clamp(row.elems[r], 1e-8, 1e8);
            }
            return diag.build();
        }

        /// Give an approximate solution to the ToA problem by solving the argument minimization problem
        ///
        /// NOTE: Expects time to be transformed into spatial distance (multiplied by the speed of light constant)
        pub fn solve(data: []const Vec, initial_guess: Vec, opt: LMOptions) Vec {
            var termination: LSOptions.Termination = .unknown;
            defer opt.common.setTermination(termination);
            var delta: Float = 1;
            var lambda: Float = 1;
            const leeway = 0.1;

            var source: Vec = initial_guess;
            var err = ls.toaError(data, initial_guess);
            for (0..opt.common.max_iterations) |_| {
                const mat: [4]Vec, const bias: Vec = ls.toaSystem(data, source);
                const diag = diagonal(&mat);

                var grad = linear.solveGaussian(&mat, bias);
                const outside: Float = blk: {
                    const scaled_grad = diag * grad;
                    break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad)) - delta;
                };
                const in_border = outside > -leeway * delta;
                if (outside > leeway * delta) {
                    grad = gradient(&mat, bias, lambda);
                    var norm: Float = blk: {
                        const scaled_grad = diag * grad;
                        break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad));
                    };
                    var iter: usize = 0;
                    var lambda_low: Float = 0;
                    while (iter < 10 and norm - delta > leeway * delta) : (iter += 1) {
                        lambda_low = lambda;
                        lambda *= 2;
                        grad = gradient(&mat, bias, lambda);
                        norm = blk: {
                            const scaled_grad = diag * grad;
                            break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad));
                        };
                    }
                    var lambda_high: Float = lambda;
                    while (iter < 10 and @abs(norm - delta) > leeway * delta) : (iter += 1) {
                        lambda = (lambda_low + lambda_high) / 2;
                        grad = gradient(&mat, bias, lambda);
                        norm = blk: {
                            const scaled_grad = diag * grad;
                            break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad));
                        };
                        if (norm < delta) {
                            lambda_high = lambda;
                        } else {
                            lambda_low = lambda;
                        }
                    }
                }

                const new_err = ls.toaError(data, source + grad);

                const mat_x_grad: Vec = .{
                    @reduce(.Add, mat[0] * grad),
                    @reduce(.Add, mat[1] * grad),
                    @reduce(.Add, mat[2] * grad),
                    @reduce(.Add, mat[3] * grad),
                };
                const expected_improvement = @reduce(.Add, bias * grad) - @reduce(.Add, grad * mat_x_grad) / 2;
                const rho = (err - new_err) / expected_improvement;
                if (rho < 0.25) {
                    delta /= 4;
                } else if (rho > 0.75 and in_border) {
                    delta = @min(2 * delta, opt.max_delta);
                }

                if (@reduce(.And, @abs(source * @as(Vec, @splat(opt.common.min_gradient))) >= @abs(grad)))
                    termination = .min_gradient;
                if (err * opt.common.min_improvement >= expected_improvement)
                    termination = .min_improvement;

                if (rho > opt.min_rho) {
                    source += grad;
                    err = new_err;
                }

                if (termination != .unknown) break;
            } else termination = .max_iterations;
            return source;
        }
    };

    pub const gn = gauss_newton;
    pub const gauss_newton = struct {
        pub const GNOptions = struct {
            common: LSOptions,
            c1: Float = 0.001,
            c2: Float = 0.9,
        };

        pub fn solve(data: []const Vec, initial_guess: Vec, opt: GNOptions) Vec {
            var termination: LSOptions.Termination = .unknown;
            defer opt.common.setTermination(termination);
            var source: Vec = initial_guess;
            var err = ls.toaError(data, initial_guess);
            for (0..opt.common.max_iterations) |_| {
                const mat: [4]Vec, const bias: Vec = ls.toaSystem(data, source);
                const grad: Vec = linear.solveBlocks(&mat, bias);
                const base_grad = -@reduce(.Add, grad * bias);

                var low: Float = 0;
                var high: Float = 0;
                var alpha: Float = 1;
                var iter: usize = 0;
                const new_err = blk: while (iter < 10) : (iter += 1) {
                    const new_err, const line_grad = toaLine(data, source + grad * @as(Vec, @splat(alpha)), grad);
                    if (new_err > err + opt.c1 * alpha * base_grad or -line_grad < opt.c2 * base_grad) {
                        high = alpha;
                        alpha = (high + low) / 2;
                    } else if (line_grad < opt.c2 * base_grad) {
                        low = alpha;
                        if (high == 0) alpha *= 2 else alpha = (high + low) / 2;
                    } else break :blk new_err;
                } else toaError(data, source + grad * @as(Vec, @splat(alpha)));

                const scaled_grad = grad * @as(Vec, @splat(alpha));

                if (@reduce(.And, @abs(source * @as(Vec, @splat(opt.common.min_gradient))) >= @abs(scaled_grad)))
                    termination = .min_gradient;
                if (err * opt.common.min_improvement >= err - new_err)
                    termination = .min_improvement;

                source += scaled_grad;
                err = new_err;

                if (termination != .unknown) break;
            } else termination = .max_iterations;
            return source;
        }
    };

    pub fn test_cases(Method: type) type {
        return struct {
            test "solve exact" {
                const expected: Vec = .{ 1, 2, 3, 1 };
                const tolerance: Float = 1e-14;
                const actual = Method.solve(
                    &.{
                        .{ 0, 0, 0, 1 + @sqrt(14.0) },
                        .{ 1, 0, 0, 1 + @sqrt(13.0) },
                        .{ 0, 1, 0, 1 + @sqrt(11.0) },
                        .{ 0, 0, 1, 1 + @sqrt(9.0) },
                    },
                    .{ 2, 2, 2, 1 },
                    .{ .common = .{ .max_iterations = 10, .min_gradient = 1e-15, .min_improvement = 1e-15 } },
                );
                if (!(@reduce(.Max, @abs(actual - expected)) < tolerance)) {
                    const expect_array: Arr = .init(expected);
                    const actual_array: Arr = .init(actual);
                    try std.testing.expectEqualSlices(Float, &expect_array.elems, &actual_array.elems);
                }
            }

            test "solve with noise" {
                const vec3 = math.vector.vec3;

                const source: Vec = vec3(3, 7, 0);
                const time: Float = 3;

                const stations: [8]Vec = .{
                    vec3(0, 0, 0),
                    vec3(8, 0, 0),
                    vec3(0, 4, 0),
                    vec3(0, 0, 3),
                    vec3(0, 1, 1),
                    vec3(1, 0, 9),
                    vec3(5, 6, 0),
                    vec3(6, 3, 4),
                };
                const noise: [8]Float = .{ 0.1, -0.1, 0.0, -0.2, 0.2, 0.0, 0.1, -0.1 };
                const data: [8]Vec = blk: {
                    var buf: [8]Vec = undefined;
                    for (stations, noise, &buf) |station, offset, *signal_i| {
                        signal_i.* = math.vector.extend(3, station, 1, .{time + math.vector.norm2(station - source) + offset});
                    }
                    break :blk buf;
                };

                const actual = Method.solve(
                    &data,
                    .{ 5, 5, 5, 5 + time },
                    .{ .common = .{ .max_iterations = 50, .min_gradient = 1e-15, .min_improvement = 1e-15 } },
                );

                const expected: Vec = .{ 3.0740512386798056, 6.753612727431825, 0.1813436176620304, 3.2173814008469277 };
                const expected_err = toaError(&data, expected);
                const tolerance_err: Float = 1e-14;
                const actual_err = toaError(&data, actual);
                try std.testing.expect(expected_err <= actual_err);
                try std.testing.expectApproxEqRel(expected_err, actual_err, tolerance_err);

                const tolerance: Float = 1e-8;
                if (!(@reduce(.Max, @abs(actual - expected) / expected) < tolerance)) {
                    const expect_arr: Arr = .init(expected);
                    const actual_arr: Arr = .init(actual);
                    std.debug.print("Error of {e} above tolerance {e}\n", .{ @reduce(.Max, @abs(actual - expected)), tolerance });
                    try std.testing.expectEqualSlices(Float, &expect_arr.elems, &actual_arr.elems);
                }
            }
        };
    }

    comptime {
        _ = test_cases(levenberg_marquardt);
        _ = test_cases(gauss_newton);
    }
};

comptime {
    std.testing.refAllDecls(linear);
    std.testing.refAllDecls(least_squares);
}
