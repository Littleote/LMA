const std = @import("std");

const lma = @import("../lma.zig");

pub fn solver(T: type) type {
    return struct {
        pub const Float = T;
        pub const Vec = @Vector(4, Float);

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

        pub const linear = struct {
            /// Vectorization for efficiently solving 4x4 linear system
            pub inline fn solveInner(mat: [4]Vec, bias: Vec) Vec {
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
                const trace: Vec = @splat(@reduce(.Add, @"a_adj x b" * swizzle(@"d_adj x c", .{ 0, 2, 1, 3 })));
                const det_m = det_a * det_d + det_b * det_c - trace;
                const sign: Vec = .{ 1, -1, -1, 1 };
                const inv_det_m = sign / det_m;

                // Blocks of the inverted matrix
                const x = inv_det_m * ((det_d * a) - mat_x_mat(b, @"d_adj x c"));
                const y = inv_det_m * ((det_b * c) - mat_x_adj(d, @"a_adj x b"));
                const z = inv_det_m * ((det_c * b) - mat_x_adj(a, @"d_adj x c"));
                const w = inv_det_m * ((det_a * d) - mat_x_mat(c, @"a_adj x b"));

                const inv_m: [4]Vec = .{
                    @shuffle(Float, x, y, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
                    @shuffle(Float, x, y, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
                    @shuffle(Float, z, w, [_]i32{ 3, 1, ~@as(i32, 3), ~@as(i32, 1) }),
                    @shuffle(Float, z, w, [_]i32{ 2, 0, ~@as(i32, 2), ~@as(i32, 0) }),
                };

                return .{
                    @reduce(.Add, inv_m[0] * bias),
                    @reduce(.Add, inv_m[1] * bias),
                    @reduce(.Add, inv_m[2] * bias),
                    @reduce(.Add, inv_m[3] * bias),
                };
            }

            /// Give an approximate solution to the ToA problem by solving the linearized equations
            /// Uses a fixed number of equations given at comptime to skip multiplying by the transpose if not necessary
            pub fn solveFixed(comptime size: usize, mat: [size]Vec, bias: [size]Float) Vec {
                if (size < 4) @compileError("Matrix has no unique solution");
                if (size == 4) return solveInner(mat, bias);
                return solve(&mat, &bias);
            }

            /// Give an approximate solution to the ToA problem by solving the linearized equations
            pub fn solve(mat: []const Vec, bias: []const Float) Vec {
                var mat_inner: [4]Vec = @splat(@splat(0));
                var bias_inner: Vec = @splat(0);
                for (mat, bias) |row, b| {
                    const col: [4]Float = row;
                    for (col, 0..) |elem, r| mat_inner[r] += row * @as(Vec, @splat(elem));
                    bias_inner += row * @as(Vec, @splat(b));
                }
                return solveInner(mat_inner, bias_inner);
            }
        };

        pub const Point = lma.pipeline.zlm(Float).Vec3;
        pub const Guess = Vec;

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

            inline fn gradient(mat: [4]Vec, bias: Vec, lambda: Float) Vec {
                var damp_mat: [4]Vec = undefined;
                const damping: Vec = .{ 1 + lambda, 1, 1, 1 };
                inline for (0..4) |r| damp_mat[r] = mat[r] * std.simd.rotateElementsRight(damping, r);
                return linear.solveInner(damp_mat, bias);
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
                const nu: Float = 2;
                var source: Vec = initial_guess;
                var best_err = lm.solutionError(data, initial_guess) - options.min_improvement;
                for (0..options.max_iterations) |_| {
                    const mat: [4]Vec, const bias: Vec = gradientSystem(data, source);

                    // Decrease lambda
                    const dec_lambda = lambda / nu;
                    const dec_grad = gradient(mat, bias, dec_lambda);
                    const dec_err = solutionError(data, source + dec_grad);

                    // Keep lambda
                    var grad = gradient(mat, bias, lambda);
                    var err = solutionError(data, source + grad);

                    if (dec_err < err) {
                        lambda = dec_lambda;
                        grad = dec_grad;
                        err = dec_err;
                    } else while (err >= best_err) {
                        const inc_lambda = lambda * nu;
                        const inc_grad = gradient(mat, bias, inc_lambda);
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
                    if (@reduce(.Add, grad * grad) <= options.min_gradient * options.min_gradient) break;
                }
                return source;
            }

            /// Give an approximate solution to the ToA problem by solving the argument minimization problem
            ///
            /// NOTE: Expects time to be transformed into spatial distance (multiplied by the speed of light constant)
            pub fn solveBasic(data: []const Vec, initial_guess: Vec, options: LMOptions) Vec {
                var source: Vec = initial_guess;
                var best_err = lm.solutionError(data, initial_guess) - options.min_improvement;
                for (0..options.max_iterations) |_| {
                    const mat: [4]Vec, const bias: Vec = gradientSystem(data, source);
                    const grad: Vec = linear.solveInner(mat, bias);
                    const err = solutionError(data, source + grad);

                    if (best_err <= err) break;
                    source += grad;
                    best_err = err - options.min_improvement;
                    if (@reduce(.Add, grad * grad) <= options.min_gradient * options.min_gradient) break;
                }
                return source;
            }
        };
    };
}

test "linear.solveFixed" {
    // Sanity check
    try std.testing.expectEqual(
        @as(solver(f32).Vec, .{ 1, 2, 3, 4 }),
        solver(f32).linear.solveFixed(4, .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        }, .{ 1, 2, 3, 4 }),
    );
    try std.testing.expectEqual(
        @as(solver(f32).Vec, .{ 0, 0, -1, 1 }),
        solver(f32).linear.solveFixed(4, .{
            .{ 1, 2, 3, 4 },
            .{ 0, 1, 2, 3 },
            .{ 0, 0, 1, 2 },
            .{ 0, 0, 0, 1 },
        }, .{ 1, 1, 1, 1 }),
    );

    {
        // Test on larger matrix
        const expected: solver(f32).Vec = .{ 1, 2, 3, 4 };
        const tolerance: solver(f32).Vec = @splat(1e-5);
        const actual = solver(f32).linear.solveFixed(8, .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
            .{ 1, 2, 0, 0 },
            .{ 0, 1, 2, 0 },
            .{ 0, 2, 1, 0 },
            .{ 0, 1, 1, 1 },
        }, .{ 1, 2, 3, 4, 5, 8, 7, 9 });
        const pred = @abs(actual - expected) <= @max(@abs(actual), @abs(expected)) * tolerance;
        if (!@reduce(.And, pred)) {
            const expect_array: [4]f32 = expected;
            const actual_array: [4]f32 = actual;
            try std.testing.expectEqualSlices(f32, &expect_array, &actual_array);
        }
    }

    {
        // Test on a real matrix
        const expected: solver(f64).Vec = .{ 0.1396871, -0.77788905, 0.60134769, -0.54553796 };
        const tolerance: solver(f64).Vec = @splat(1e-6);
        const actual = solver(f64).linear.solveFixed(4, .{
            .{ -2.05782, -0.56853, -6.83522, 3.12176 },
            .{ -3.79283, 6.48790, 3.26692, 7.57333 },
            .{ 8.92533, -5.75444, -8.67197, 4.48165 },
            .{ 2.79342, -8.87533, -3.61153, 0.15979 },
        }, .{ -5.65858, -7.74366, -1.93671, 5.03527 });
        const pred = @abs(actual - expected) <= @max(@abs(actual), @abs(expected)) * tolerance;
        if (!@reduce(.And, pred)) {
            const expect_array: [4]f64 = expected;
            const actual_array: [4]f64 = actual;
            try std.testing.expectEqualSlices(f64, &expect_array, &actual_array);
        }
    }
}

test "lm.solve" {
    const sol = solver(f32);

    const expected: sol.Vec = .{ 1, 2, 3, 1 };
    const tolerance: sol.Float = 1e-3;
    const actual = sol.lm.solve(
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
        const expect_array: [4]sol.Float = expected;
        const actual_array: [4]sol.Float = actual;
        try std.testing.expectEqualSlices(sol.Float, &expect_array, &actual_array);
    }
}

test "lm.solve with noise" {
    const sol = solver(f64);

    const source: sol.Point = .new(3, 7, 0);
    const time: sol.Float = 3;

    const stations: [8]sol.Point = .{
        .new(0, 0, 0),
        .new(8, 0, 0),
        .new(0, 4, 0),
        .new(0, 0, 3),
        .new(0, 1, 1),
        .new(1, 0, 9),
        .new(5, 6, 0),
        .new(6, 3, 4),
    };
    const noise: [8]sol.Float = .{ 0.1, -0.1, 0.0, -0.2, 0.2, 0.0, 0.1, -0.1 };
    const data: [8]sol.Vec = blk: {
        var buf: [8]sol.Vec = undefined;
        for (stations, noise, &buf) |station, offset, *signal_i| {
            signal_i.* = .{ station.x, station.y, station.z, time + station.distance(source) + offset };
        }
        break :blk buf;
    };

    const expected: sol.Vec = .{ source.x, source.y, source.z, time };
    const tolerance: sol.Float = 0.5;
    const actual = sol.lm.solve(&data, .{ 5, 5, 5, 5 + time }, .{});
    if (!(@reduce(.Max, @abs(actual - expected)) < tolerance)) {
        const expect_array: [4]sol.Float = expected;
        const actual_array: [4]sol.Float = actual;
        try std.testing.expectEqualSlices(sol.Float, &expect_array, &actual_array);
    }

    return error.SkipZigTest;
}
