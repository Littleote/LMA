const std = @import("std");

pub fn math(comptime Float: type) type {
    std.debug.assert(@typeInfo(Float) == .float);

    return struct {
        pub const vector = struct {
            pub const zero: Vec = @splat(0);
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

            pub fn prodN(vec: Vec, comptime len: u2) Float {
                return @reduce(.Mul, vec + Axis.maskAfter(.dim(len)));
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
                if (vector.normInf(self.build() - other.build()) < tol) return;
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
        };

        pub const matrix = struct {
            pub fn right(mat: *const Mat, vec: Vec) Vec {
                const dot = vector.dot;
                return .{
                    dot(mat[0], vec),
                    dot(mat[1], vec),
                    dot(mat[2], vec),
                    dot(mat[3], vec),
                };
            }

            pub fn left(vec: ElemVec, mat: *const Mat) Vec {
                const splat = vector.splat;
                return mat[0] * splat(vec.elems[0]) +
                    mat[1] * splat(vec.elems[1]) +
                    mat[2] * splat(vec.elems[2]) +
                    mat[3] * splat(vec.elems[3]);
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

            pub fn cast(self: ElemVec, comptime To: type) math(To).ElemVec {
                if (Float == To) return self;
                return .init(@floatCast(self.build()));
            }
        };

        pub const Axis = enum(u2) {
            x = 0,
            y = 1,
            z = 2,
            w = 3,

            pub fn dim(len: u2) Axis {
                return @enumFromInt(len);
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

            pub inline fn maskUntil(comptime axis: Axis) Vec {
                comptime {
                    const end = @as(usize, axis.idx()) + 1;
                    var elems: ElemVec = .init(vector.zero);
                    for (0..end) |i| {
                        elems.elems[i] = 1;
                    }
                    return elems.build();
                }
            }

            pub inline fn maskAfter(comptime axis: Axis) Vec {
                comptime {
                    const end = @as(usize, axis.idx()) + 1;
                    var elems: ElemVec = .init(vector.zero);
                    for (end..4) |i| {
                        elems.elems[i] = 1;
                    }
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
    };
}
