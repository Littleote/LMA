const std = @import("std");

pub fn math(comptime Float: type) type {
    std.debug.assert(@typeInfo(Float) == .float);

    return struct {
        pub const vector = struct {
            pub const zero: Vec = @splat(0);
            pub const one: Vec = @splat(1);
            pub const unit = Axis.unit;

            pub fn vec1(x: Float) Vec {
                return .{ x, 0, 0, 0 };
            }

            pub fn vec2(x: Float, y: Float) Vec {
                return .{ x, y, 0, 0 };
            }

            pub fn vec3(x: Float, y: Float, z: Float) Vec {
                return .{ x, y, z, 0 };
            }

            pub fn vec4(x: Float, y: Float, z: Float, w: Float) Vec {
                return .{ x, y, z, w };
            }

            pub inline fn extend(comptime n: u2, vec: Vec, comptime m: u2, extra: @Tuple(&@as([m]type, @splat(Float)))) Vec {
                comptime std.debug.assert(@as(usize, n) + @as(usize, m) <= 4);
                var elem_vec: ElemVec = .init(vec);
                inline for (0..m, n..) |ti, vi| elem_vec.elems[vi] = extra[ti];
                return elem_vec.build();
            }

            pub fn splat(scalar: Float) Vec {
                return @splat(scalar);
            }

            pub fn swizzle(vec: Vec, comptime order: Swizzle) Vec {
                return @shuffle(Float, vec, undefined, order.mask());
            }

            pub fn sum(vec: Vec) Float {
                return @reduce(.Add, vec);
            }

            pub fn prodN(vec: Vec, comptime len: comptime_int) Float {
                return @reduce(.Mul, mask.apply(mask.until(len), vec, one));
            }

            pub fn dot(a: Vec, b: Vec) Float {
                return @reduce(.Add, a * b);
            }

            pub fn norm1(vec: Vec) Float {
                return @reduce(.Add, @abs(vec));
            }

            pub fn norm2(vec: Vec) Float {
                return @sqrt(@reduce(.Add, vec * vec));
            }

            pub fn normalize(vec: Vec) Vec {
                return vec / splat(norm2(vec));
            }

            pub fn norm2Square(vec: Vec) Float {
                return @reduce(.Add, vec * vec);
            }

            pub fn normInf(vec: Vec) Float {
                return @reduce(.Max, @abs(vec));
            }

            pub fn cross2(a: Vec, b: Vec) Vec {
                return swizzle(a, .yzxw) * swizzle(b, .zxyw) - swizzle(a, .zxyw) * swizzle(b, .yzxw);
            }
        };

        pub const Vec = @Vector(4, Float);

        pub const ElemVec = extern struct {
            elems: [4]Float,

            pub inline fn init(vec: Vec) ElemVec {
                return .{ .elems = vec };
            }

            pub inline fn build(self: ElemVec) Vec {
                return self.elems;
            }

            pub fn at(self: ElemVec, dim: Axis) Float {
                return self.elems[dim.idx()];
            }

            pub fn refAt(self: *ElemVec, dim: Axis) *Float {
                return &self.elems[dim.idx()];
            }

            pub inline fn x(self: ElemVec) Float {
                return self.elems[Axis.x.idx()];
            }

            pub inline fn y(self: ElemVec) Float {
                return self.elems[Axis.y.idx()];
            }

            pub inline fn z(self: ElemVec) Float {
                return self.elems[Axis.z.idx()];
            }

            pub inline fn w(self: ElemVec) Float {
                return self.elems[Axis.w.idx()];
            }

            pub const t = w;

            pub fn cast(self: ElemVec, comptime To: type) math(To).ElemVec {
                if (Float == To) return self;
                return .init(@floatCast(self.build()));
            }

            pub fn isApproxEqAbs(self: ElemVec, other: ElemVec, tol: Float) !void {
                if (vector.normInf(self.build() - other.build()) <= tol) return;
                const correct = "∈";
                const incorrect = "∉";
                std.debug.print("Not all values are within the expected tolerance:\n", .{});
                std.debug.print("===================================================\n", .{});
                for (0..4) |i| {
                    std.debug.print(
                        "{e:15} {s} {e:15} ± {e:<15} \n",
                        .{
                            self.elems[i],
                            if (@abs(self.elems[i] - other.elems[i]) < tol) correct else incorrect,
                            other.elems[i],
                            tol,
                        },
                    );
                }
                std.debug.print("===================================================\n", .{});
                return error.NotEqual;
            }

            pub fn isApproxEqRel(self: ElemVec, other: ElemVec, tol: Float) !void {
                if (vector.normInf((self.build() - other.build()) / @abs(other.build())) <= tol) return;
                const correct = "∈";
                const incorrect = "∉";
                std.debug.print("Not all values are within the expected tolerance:\n", .{});
                std.debug.print("=========================================================\n", .{});
                for (0..4) |i| {
                    std.debug.print(
                        "{e:15} {s} {e:15} * (1 ± {e}) \n",
                        .{
                            self.elems[i],
                            if (@abs(self.elems[i] - other.elems[i]) / @abs(other.elems[i]) < tol) correct else incorrect,
                            other.elems[i],
                            tol,
                        },
                    );
                }
                std.debug.print("=========================================================\n", .{});
                return error.NotEqual;
            }
        };

        pub const matrix = struct {
            /// [M] · (v)
            pub fn applyRight(mat: *const Mat, vec: Vec) Vec {
                const dot = vector.dot;
                return .{
                    dot(mat[0], vec),
                    dot(mat[1], vec),
                    dot(mat[2], vec),
                    dot(mat[3], vec),
                };
            }

            /// (v)^T · [M]
            pub fn applyLeft(vec: ElemVec, mat: *const Mat) Vec {
                const splat = vector.splat;
                return mat[0] * splat(vec.elems[0]) +
                    mat[1] * splat(vec.elems[1]) +
                    mat[2] * splat(vec.elems[2]) +
                    mat[3] * splat(vec.elems[3]);
            }

            /// Matrix operations implemented using block matrix methods.
            pub const block = struct {
                const swizzle = vector.swizzle;

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

                /// Find the inverse of a 4x4 matrix using a vectorized algorithm at the cost if some precision
                pub fn inverse(mat: *const Mat, inv_mat: *Mat) void {
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

                /// Solving 4x4 linear system using a vectorized algorithm at the cost if some precision
                pub fn solve(mat: *const [4]Vec, bias: Vec) Vec {
                    var inv_mat: [4]Vec = undefined;
                    inverse(mat, &inv_mat);

                    return .{
                        @reduce(.Add, inv_mat[0] * bias),
                        @reduce(.Add, inv_mat[1] * bias),
                        @reduce(.Add, inv_mat[2] * bias),
                        @reduce(.Add, inv_mat[3] * bias),
                    };
                }
            };

            /// Matrix operations implemented using gaussian decomposition.
            pub const gaussian = struct {
                /// Solving 4x4 linear system using gaussian elimination
                pub fn solve(mat: *const Mat, bias: Vec) Vec {
                    var gauss_mat: Mat = mat.*;
                    var x: ElemVec = .init(bias);

                    for (0..4) |r| {
                        const scale = @as(ElemVec, .init(gauss_mat[r])).elems[r];
                        gauss_mat[r] /= vector.splat(scale);
                        x.elems[r] /= scale;

                        for (0..4) |c| {
                            if (r == c) continue;
                            const coef = @as(ElemVec, .init(gauss_mat[c])).elems[r];
                            gauss_mat[c] -= gauss_mat[r] * vector.splat(coef);
                            x.elems[c] -= x.elems[r] * coef;
                        }
                    }

                    return x.build();
                }
            };

            pub const solveRight = gaussian.solve;
            pub fn solveLeft(mat: *const Mat, vec: Vec) Vec {
                return solveRight(ElemMat.init(mat).transpose().build(), vec);
            }

            /// Solve a linear system of arbitrary size (N equations and 4 variables) either
            /// * directly (if `N = 4`) (x) = [A]^-1 (b)
            /// * least squares (if `N > 4`) (x) = ([A]^T · [A])^-1 · [A]^T · (b)
            pub fn solveSystem(mat: []const Vec, bias: []const Float, comptime method: fn (*const Mat, Vec) Vec) Vec {
                std.debug.assert(mat.len >= 4);
                std.debug.assert(mat.len == bias.len);
                if (mat.len == 4) return method(mat[0..4], bias[0..4].*);

                var mat_inner: [4]Vec = @splat(@splat(0));
                var bias_inner: Vec = @splat(0);
                for (mat, bias) |row, b| {
                    const col: [4]Float = row;
                    for (col, 0..) |elem, r| mat_inner[r] += row * @as(Vec, @splat(elem));
                    bias_inner += row * @as(Vec, @splat(b));
                }
                return method(&mat_inner, bias_inner);
            }
        };

        pub const Mat = [4]Vec;

        pub const ElemMat = extern struct {
            elems: [4][4]Float,

            pub inline fn init(mat: Mat) ElemMat {
                return .{ .elems = .{ mat[0], mat[1], mat[2], mat[3] } };
            }

            pub inline fn build(self: ElemMat) Mat {
                return .{ self.elems[0], self.elems[1], self.elems[2], self.elems[3] };
            }

            pub fn cast(self: ElemMat, comptime To: type) math(To).ElemMat {
                if (Float == To) return self;
                return .init(@floatCast(self.build()));
            }

            pub fn transpose(self: ElemMat) ElemMat {
                return .{ .elems = .{
                    .{ self.elems[0][0], self.elems[1][0], self.elems[2][0], self.elems[3][0] },
                    .{ self.elems[0][1], self.elems[1][1], self.elems[2][1], self.elems[3][1] },
                    .{ self.elems[0][2], self.elems[1][2], self.elems[2][2], self.elems[3][2] },
                    .{ self.elems[0][3], self.elems[1][3], self.elems[2][3], self.elems[3][3] },
                } };
            }
        };

        pub const Axis = enum(u2) {
            x = 0,
            y = 1,
            z = 2,
            w = 3,

            pub fn dim(at: u2) Axis {
                return @enumFromInt(at);
            }

            pub fn idx(self: Axis) u2 {
                return @intFromEnum(self);
            }

            pub inline fn unit(comptime axis: Axis) Vec {
                comptime {
                    var elems: ElemVec = .init(vector.zero);
                    elems.refAt(axis).* = 1;
                    return elems.build();
                }
            }
        };

        pub const Swizzle = enum(u8) {
            pub const BitPattern = packed struct(u8) {
                x: Axis,
                y: Axis,
                z: Axis,
                w: Axis,
            };

            xxxx,
            yxxx,
            zxxx,
            wxxx,
            xyxx,
            yyxx,
            zyxx,
            wyxx,
            xzxx,
            yzxx,
            zzxx,
            wzxx,
            xwxx,
            ywxx,
            zwxx,
            wwxx,
            xxyx,
            yxyx,
            zxyx,
            wxyx,
            xyyx,
            yyyx,
            zyyx,
            wyyx,
            xzyx,
            yzyx,
            zzyx,
            wzyx,
            xwyx,
            ywyx,
            zwyx,
            wwyx,
            xxzx,
            yxzx,
            zxzx,
            wxzx,
            xyzx,
            yyzx,
            zyzx,
            wyzx,
            xzzx,
            yzzx,
            zzzx,
            wzzx,
            xwzx,
            ywzx,
            zwzx,
            wwzx,
            xxwx,
            yxwx,
            zxwx,
            wxwx,
            xywx,
            yywx,
            zywx,
            wywx,
            xzwx,
            yzwx,
            zzwx,
            wzwx,
            xwwx,
            ywwx,
            zwwx,
            wwwx,
            xxxy,
            yxxy,
            zxxy,
            wxxy,
            xyxy,
            yyxy,
            zyxy,
            wyxy,
            xzxy,
            yzxy,
            zzxy,
            wzxy,
            xwxy,
            ywxy,
            zwxy,
            wwxy,
            xxyy,
            yxyy,
            zxyy,
            wxyy,
            xyyy,
            yyyy,
            zyyy,
            wyyy,
            xzyy,
            yzyy,
            zzyy,
            wzyy,
            xwyy,
            ywyy,
            zwyy,
            wwyy,
            xxzy,
            yxzy,
            zxzy,
            wxzy,
            xyzy,
            yyzy,
            zyzy,
            wyzy,
            xzzy,
            yzzy,
            zzzy,
            wzzy,
            xwzy,
            ywzy,
            zwzy,
            wwzy,
            xxwy,
            yxwy,
            zxwy,
            wxwy,
            xywy,
            yywy,
            zywy,
            wywy,
            xzwy,
            yzwy,
            zzwy,
            wzwy,
            xwwy,
            ywwy,
            zwwy,
            wwwy,
            xxxz,
            yxxz,
            zxxz,
            wxxz,
            xyxz,
            yyxz,
            zyxz,
            wyxz,
            xzxz,
            yzxz,
            zzxz,
            wzxz,
            xwxz,
            ywxz,
            zwxz,
            wwxz,
            xxyz,
            yxyz,
            zxyz,
            wxyz,
            xyyz,
            yyyz,
            zyyz,
            wyyz,
            xzyz,
            yzyz,
            zzyz,
            wzyz,
            xwyz,
            ywyz,
            zwyz,
            wwyz,
            xxzz,
            yxzz,
            zxzz,
            wxzz,
            xyzz,
            yyzz,
            zyzz,
            wyzz,
            xzzz,
            yzzz,
            zzzz,
            wzzz,
            xwzz,
            ywzz,
            zwzz,
            wwzz,
            xxwz,
            yxwz,
            zxwz,
            wxwz,
            xywz,
            yywz,
            zywz,
            wywz,
            xzwz,
            yzwz,
            zzwz,
            wzwz,
            xwwz,
            ywwz,
            zwwz,
            wwwz,
            xxxw,
            yxxw,
            zxxw,
            wxxw,
            xyxw,
            yyxw,
            zyxw,
            wyxw,
            xzxw,
            yzxw,
            zzxw,
            wzxw,
            xwxw,
            ywxw,
            zwxw,
            wwxw,
            xxyw,
            yxyw,
            zxyw,
            wxyw,
            xyyw,
            yyyw,
            zyyw,
            wyyw,
            xzyw,
            yzyw,
            zzyw,
            wzyw,
            xwyw,
            ywyw,
            zwyw,
            wwyw,
            xxzw,
            yxzw,
            zxzw,
            wxzw,
            xyzw,
            yyzw,
            zyzw,
            wyzw,
            xzzw,
            yzzw,
            zzzw,
            wzzw,
            xwzw,
            ywzw,
            zwzw,
            wwzw,
            xxww,
            yxww,
            zxww,
            wxww,
            xyww,
            yyww,
            zyww,
            wyww,
            xzww,
            yzww,
            zzww,
            wzww,
            xwww,
            ywww,
            zwww,
            wwww,

            pub inline fn mask(comptime self: Swizzle) @Vector(4, i32) {
                comptime {
                    const bits: BitPattern = @bitCast(@intFromEnum(self));
                    return .{ bits.x.idx(), bits.y.idx(), bits.z.idx(), bits.w.idx() };
                }
            }
        };

        pub const Mask = @Vector(4, bool);

        pub const mask = struct {
            pub inline fn until(comptime n: comptime_int) Mask {
                comptime return @as([n]bool, @splat(true)) ++ @as([4 - n]bool, @splat(false));
            }

            pub inline fn after(comptime n: comptime_int) Mask {
                comptime return @as([n]bool, @splat(false)) ++ @as([4 - n]bool, @splat(true));
            }

            pub fn apply(self: Mask, a: Vec, b: Vec) Vec {
                return @select(Float, self, a, b);
            }
        };
    };
}

fn solveTest(comptime method: fn (*const math(f64).Mat, math(f64).Vec) math(f64).Vec) type {
    return struct {
        const m = math(f64);
        test "Sanity check" {
            // Sanity check
            const out: m.ElemVec = .init(m.matrix.solveSystem(&.{
                .{ 1, 0, 0, 0 },
                .{ 0, 1, 0, 0 },
                .{ 0, 0, 1, 0 },
                .{ 0, 0, 0, 1 },
            }, &.{ 1, 2, 3, 4 }, method));
            try out.isApproxEqAbs(.init(.{ 1, 2, 3, 4 }), 0);
        }

        test "Non-square matrix" {
            // Test on non-square matrix for solving as `x = [At * A] \ [At * b]`
            const out: m.ElemVec = .init(m.matrix.solveSystem(&.{
                .{ 1, 0, 0, 0 },
                .{ 0, 1, 0, 0 },
                .{ 0, 0, 1, 0 },
                .{ 0, 0, 0, 1 },
                .{ 1, 2, 0, 0 },
                .{ 0, 1, 2, 0 },
                .{ 0, 2, 1, 0 },
                .{ 0, 1, 1, 1 },
            }, &.{ 1, 2, 3, 4, 5, 8, 7, 9 }, method));
            try out.isApproxEqRel(.init(.{ 1, 2, 3, 4 }), 1e-15);
        }

        test "Random matrix" {
            // Test on a random matrix
            const out: m.ElemVec = .init(m.matrix.solveSystem(&.{
                .{ -2.05782, -0.56853, -6.83522, 3.12176 },
                .{ -3.79283, 6.48790, 3.26692, 7.57333 },
                .{ 8.92533, -5.75444, -8.67197, 4.48165 },
                .{ 2.79342, -8.87533, -3.61153, 0.15979 },
            }, &.{ -5.65858, -7.74366, -1.93671, 5.03527 }, method));
            try out.isApproxEqRel(.init(.{ 0.139687103197207, -0.777889045742257, 0.601347689515521, -0.54553796260580 }), 1e-14);
        }

        test "Ill-conditioned matrix" {
            // Test on an ill-conditioned matrix (SVD with diagonal: 2, 1, 0.5, 0.01)
            const out: m.ElemVec = .init(m.matrix.solveSystem(&.{
                .{ 0.9036135, -0.2386397, 0.0595151, 0.2205390 },
                .{ -0.2386397, 1.7831396, 0.4355547, 0.2070320 },
                .{ 0.0595151, 0.4355547, 0.7027765, 0.1763387 },
                .{ 0.2205390, 0.2070320, 0.1763387, 0.1204705 },
            }, &.{ 1.1998287, -0.2702585, -0.0967522, 0.847799 }, method));
            try out.isApproxEqRel(.init(.{ -12.34461141882552, -5.753113271600019, -8.603606899817999, 52.116448927888506 }), 1e-15);
        }

        test "Large matrix coefficients" {
            // Test on a matrix with large coefficients
            if (method == math(f64).matrix.block.solve) return error.SkipZigTest;

            const out: m.ElemVec = .init(m.matrix.solveSystem(&.{
                .{ -25094.0503091868, -29320.89929369194, 28761.046511825174, -45284.01625329256 },
                .{ 236933.65670040622, 374309.2310069331, -285236.37992312014, -131719.84256136417 },
                .{ -51283.60409959592, 202777.0964314192, 53543.638328762725, -101327.02535408735 },
                .{ -80439.37343608774, 250204.33606267622, 85228.02186822705, -161792.98778903484 },
            }, &.{ 66495541.18443215, 65063658400.42088, 9087078506.243664, 12539886849.305801 }, method));
            // WolframAlpha
            // x≈1.097341930439×10^9, y≈1.818023898439×10^7, z≈9.44402607061×10^8, w≈-2.004843713694×10^7
            try out.isApproxEqRel(.init(.{ 1.097341930439e9, 1.818023898439e7, 9.44402607061e8, -2.004843713694e7 }), 5e-10);
        }
    };
}

comptime {
    const builtin = @import("builtin");
    if (builtin.is_test) {
        _ = solveTest(math(f64).matrix.block.solve);
        _ = solveTest(math(f64).matrix.gaussian.solve);
    }
}
