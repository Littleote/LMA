const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const lma = @import("lma.zig");
const math = lma.math;
const cast = lma.cast;

pub const Shape = struct {
    rows: u32,
    columns: u32,
    size: usize,

    pub fn init(rows: u32, columns: u32) Shape {
        return .{ .rows = rows, .columns = columns, .size = rows * columns };
    }

    pub fn ComptimeGrid(comptime self: Shape, T: type) type {
        return [self.rows][self.columns]T;
    }

    pub fn offset(self: Shape, neighbour: Neighbour) isize {
        return neighbour.h + neighbour.v * cast.as(isize, self.columns);
    }

    pub fn unravel(self: Shape, index: usize) struct { usize, usize } {
        return .{ index / self.columns, index % self.columns };
    }

    pub fn ravel(self: Shape, row: usize, column: usize) usize {
        return row * self.columns + column;
    }

    const Neighbour = packed struct(u4) {
        h: i2,
        v: i2,

        pub fn init(h: i2, v: i2) Neighbour {
            return .{ .h = h, .v = v };
        }

        pub fn fromInt(int: u4) Neighbour {
            return @fromBackingInt(int);
        }

        pub fn toInt(self: Neighbour) u4 {
            return @backingInt(self);
        }

        pub const left: Neighbour = .init(-1, 0);
        pub const top_left: Neighbour = .init(-1, -1);
        pub const top: Neighbour = .init(0, -1);
        pub const top_right: Neighbour = .init(1, -1);
        pub const right: Neighbour = .init(1, 0);
        pub const bottom_right: Neighbour = .init(1, 1);
        pub const bottom: Neighbour = .init(0, 1);
        pub const bottom_left: Neighbour = .init(-1, 1);

        pub const four_neighbours: [4]Neighbour = .{
            .left,
            .top,
            .right,
            .bottom,
        };
        pub const eight_neighbours: [8]Neighbour = .{
            .left,
            .top_left,
            .top,
            .top_right,
            .right,
            .bottom_right,
            .bottom,
            .bottom_left,
        };
    };
};

pub const Bounds = struct {
    pub const Float = f32;

    const vector = math(Float).vector;
    pub const Vec = math(Float).Vec;

    pub const Detail = union(enum) {
        shape: Shape,
        step: Vec,

        pub fn fromGrid(shape: Shape) Detail {
            return .{ .shape = shape };
        }

        pub fn fromStep(step: Vec) Detail {
            return .{ .step = step };
        }

        pub fn getBounds(self: Detail, size: Vec) struct { Shape, Vec } {
            const shape: Shape = switch (self) {
                .shape => |shape| shape,
                .step => |step| blk: {
                    const shape: math(Float).ElemVec = .init(size / step + vector.splat(1));
                    break :blk .init(@round(shape.at(.y)), @round(shape.at(.x)));
                },
            };
            const count: Vec = vector.vec2(@floatFromInt(shape.columns - 1), @floatFromInt(shape.rows - 1));
            return .{ shape, size / count };
        }
    };

    shape: Shape,
    size: Vec,
    origin: Vec,
    end: Vec,
    step: Vec,

    pub fn limits(detail: Detail, origin: Vec, end: Vec) Bounds {
        const size = end - origin;
        const shape, const step = detail.getBounds(size);
        return .{
            .shape = shape,
            .size = size,
            .origin = origin,
            .end = end,
            .step = step,
        };
    }

    pub fn scale(detail: Detail, size: Vec) Bounds {
        return .scaleTranslate(detail, vector.zero, size);
    }

    pub fn scaleTranslate(detail: Detail, center: Vec, size: Vec) Bounds {
        const half_size = size * vector.splat(0.5);
        const shape, const step = detail.getBounds(size);
        return .{
            .shape = shape,
            .size = size,
            .origin = center - half_size,
            .end = center + half_size,
            .step = step,
        };
    }

    pub fn contains(self: *const Bounds, point: Vec) bool {
        return ( //
            self.origin.x < point.x and point.x < self.end.x and //
                self.origin.y < point.y and point.y < self.end.y //
        );
    }

    pub fn mapping(self: *const Bounds, point: Vec) Vec {
        return (point - self.origin) / self.step;
    }

    pub const Kde = union(enum) {
        triangular: struct {
            scaling: Float = 1.0,

            pub fn run(options: @This(), bounds: *const Bounds, values: []Float, points: []const Vec) void {
                const shape = bounds.shape;
                for (points) |x| {
                    const frac: math(Float).ElemVec = .init((x - bounds.origin) / bounds.step);
                    if (frac.x() < 0 or frac.y() < 0) continue;
                    const row: usize = @round(frac.y());
                    const col: usize = @round(frac.x());
                    if (shape.rows <= row + 1 or shape.columns <= col + 1) continue;
                    const weight: struct { x: Float, y: Float } = .{ .x = @mod(frac.x(), 1), .y = @mod(frac.y(), 1) };
                    const idx = shape.ravel(row, col);
                    values[idx] += options.scaling * weight.x * weight.y;
                    values[idx + shape.columns] += options.scaling * weight.x * (1 - weight.y);
                    values[idx + 1 + shape.columns] += options.scaling * (1 - weight.x) * (1 - weight.y);
                    values[idx + 1] += options.scaling * (1 - weight.x) * weight.y;
                }
            }
        },
    };

    pub fn kde(bounds: *const Bounds, values: []Float, points: []const Vec, method: Kde) void {
        switch (method) {
            inline else => |options| options.run(bounds, values, points),
        }
    }
};

pub const Axis = enum { columns, rows };
pub const MorphOperation = enum { erode, dilate };
pub const Operator = enum { add, sub, mul, div, max, min };

pub fn apply(Type: type) type {
    return struct {
        const builtin = @import("builtin");

        const use_vectors = switch (builtin.zig_backend) {
            // These backends don't support vectors yet.
            .stage2_aarch64,
            .stage2_powerpc,
            .stage2_riscv64,
            => false,
            // The SPIR-V backend does not support the optimized path yet.
            .stage2_spirv => false,
            else => true,
        };

        // The naive memory comparison implementation is more useful for fuzzers to find interesting inputs.
        const vectorize = // Requirements for vectorization
            use_vectors and
            !builtin.fuzz and
            (@typeInfo(Type) == .int or @typeInfo(Type) == .float) and
            std.math.isPowerOfTwo(@bitSizeOf(Type));

        pub fn convolution(shape: Shape, values: []Type, aux: []Type, horizontal: []const Type, vertical: []const Type) void {
            axisConvolution(.columns, shape, values, aux, vertical);
            axisConvolution(.rows, shape, aux, values, horizontal);
        }

        pub fn axisConvolution(comptime axis: Axis, shape: Shape, input: []Type, output: []Type, array: []const Type) void {
            const mid_point = @divExact(array.len - 1, 2);
            for (0..shape.rows) |row| {
                for (0..shape.columns) |col| {
                    const idx = shape.ravel(row, col);
                    var val: Type = 0.0;
                    for (0..array.len) |diff| {
                        switch (axis) {
                            .rows => {
                                if (col + diff < mid_point or shape.columns <= col + diff - mid_point) continue;
                                val += array[diff] * input[idx + diff - mid_point];
                            },
                            .columns => {
                                if (row + diff < mid_point or shape.rows <= row + diff - mid_point) continue;
                                val += array[diff] * input[shape.ravel(row + diff - mid_point, col)];
                            },
                        }
                    }
                    output[idx] = val;
                }
            }
        }

        pub const kernel = struct {
            pub fn gaussian(buffer: []Type, sigma: Type) void {
                var sum: Type = 0.0;
                var idx: usize = 0;
                var x = -(cast.to(Type, buffer.len) - 1) / 2;
                const to = -x + 0.5;
                while (x < to) : ({
                    x += 1.0;
                    idx += 1;
                }) {
                    buffer[idx] = @exp(-(x * x) / (sigma * sigma));
                    sum += buffer[idx];
                }
                for (buffer) |*value| {
                    value.* /= sum;
                }
            }
        };

        pub fn morph(shape: Shape, values: []Type, aux: []Type, size: Shape, comptime operation: MorphOperation) void {
            axisMorph(.rows, shape, values, aux, size.rows, operation);
            axisMorph(.columns, shape, aux, values, size.columns, operation);
        }

        pub fn axisMorph(comptime axis: Axis, shape: Shape, input: []Type, output: []Type, size: u32, comptime operation: MorphOperation) void {
            const mid_point = @divExact(size - 1, 2);
            for (0..shape.rows) |row| {
                for (0..shape.columns) |col| {
                    const idx = shape.ravel(row, col);
                    var val = input[idx];
                    for (0..size) |diff| {
                        const neighbour = switch (axis) {
                            .rows => blk: {
                                if (col + diff < mid_point or shape.columns <= col + diff - mid_point) continue;
                                break :blk input[idx + diff - mid_point];
                            },
                            .columns => blk: {
                                if (row + diff < mid_point or shape.rows <= row + diff - mid_point) continue;
                                break :blk input[shape.ravel(row + diff - mid_point, col)];
                            },
                        };
                        val = switch (operation) {
                            .erode => @min(val, neighbour),
                            .dilate => @max(val, neighbour),
                        };
                    }
                    output[idx] = val;
                }
            }
        }

        pub const Window = struct {
            shape: Shape,
            frames: []Type,
            current_frame: usize,
            size: usize,
            correction: Type = 1e-7,

            pub fn init(gpa: Allocator, shape: Shape, size: usize) !Window {
                const frames = try gpa.alloc(Type, shape.size * size);
                @memset(frames, 0);
                return .{
                    .shape = shape,
                    .frames = frames,
                    .current_frame = 0,
                    .size = size,
                };
            }

            pub fn deinit(self: *Window, gpa: Allocator) void {
                gpa.free(self.frames);
                self.* = undefined;
            }

            pub fn get(self: *Window) []Type {
                return self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            }

            pub fn apply(self: *Window, values: []Type) void {
                const current = self.get();
                elementWiseOp(values, .add, current);
            }

            pub fn setupNext(self: *Window, values: []Type) void {
                self.ignore();
                const next = self.get();
                for (values, next) |*total, sub| {
                    total.* = @max(0, total.* - sub - self.correction);
                }
                self.clear();
            }

            pub fn advance(self: *Window, values: []Type) void {
                const last = self.get();
                self.ignore();
                const next = self.get();
                for (values, last, next) |*total, add, sub| {
                    total.* = @max(0, total.* + add - sub - self.correction);
                }
                self.clear();
            }

            pub fn peek(self: *Window) []Type {
                const next_frame = (self.current_frame + 1) % self.size;
                const next = self.frames[self.shape.size * next_frame ..][0..self.shape.size];
                return next;
            }

            pub fn ignore(self: *Window) void {
                self.current_frame = (self.current_frame + 1) % self.size;
            }

            pub fn clear(self: *Window) void {
                const frame = self.get();
                @memset(frame, 0);
            }
        };

        /// Apply an operation elementwise between two slices
        pub fn elementWiseOp(lhs: []Type, comptime operation: Operator, rhs: []Type) void {
            const n = lhs.len;
            std.debug.assert(lhs.len == rhs.len);
            var i: usize = 0;

            if (vectorize) {
                if (std.simd.suggestVectorLength(Type)) |block_size| {
                    const Block = @Vector(block_size, Type);

                    while (n - i >= block_size) : (i += block_size) {
                        const block_lhs: Block = lhs[i..][0..block_size].*;
                        const block_rhs: Block = rhs[i..][0..block_size].*;
                        lhs[i..][0..block_size].* = switch (operation) {
                            .add => block_lhs + block_rhs,
                            .sub => block_lhs - block_rhs,
                            .mul => block_lhs * block_rhs,
                            .div => block_lhs / block_rhs,
                            .max => @max(block_lhs, block_rhs),
                            .min => @min(block_lhs, block_rhs),
                        };
                    }
                }
            }

            for (lhs[i..n], rhs[i..n]) |*iterm_lhs, item_rhs| {
                iterm_lhs.* = switch (operation) {
                    .add => iterm_lhs.* + item_rhs,
                    .sub => iterm_lhs.* - item_rhs,
                    .mul => iterm_lhs.* * item_rhs,
                    .div => iterm_lhs.* / item_rhs,
                    .max => @max(iterm_lhs.*, item_rhs),
                    .min => @min(iterm_lhs.*, item_rhs),
                };
            }
        }

        /// Apply an operation with a scalar value over all values in slice
        pub fn scalarOp(values: []Type, comptime operation: Operator, scalar: Type) void {
            const n = values.len;
            var i: usize = 0;

            if (vectorize) {
                if (std.simd.suggestVectorLength(Type)) |block_size| {
                    const Block = @Vector(block_size, Type);

                    const scalar_vec: Block = @splat(scalar);
                    while (n - i >= block_size) : (i += block_size) {
                        const block: Block = values[i..][0..block_size].*;
                        values[i..][0..block_size].* = switch (operation) {
                            .add => block + scalar_vec,
                            .sub => block - scalar_vec,
                            .mul => block * scalar_vec,
                            .div => block / scalar_vec,
                            .max => @max(block, scalar_vec),
                            .min => @min(block, scalar_vec),
                        };
                    }
                }
            }

            for (values[i..n]) |*item| {
                item.* = switch (operation) {
                    .add => item.* + scalar,
                    .sub => item.* - scalar,
                    .mul => item.* * scalar,
                    .div => item.* / scalar,
                    .max => @max(item.*, scalar),
                    .min => @min(item.*, scalar),
                };
            }
        }

        pub const SetValue = union(enum) {
            current: void,
            limit: void,
            fixed: Type,

            pub const zero: SetValue = .{ .fixed = 0 };
        };

        pub fn threshold(
            values: []Type,
            min: Type,
            comptime limits: struct { below: SetValue = .zero, above: SetValue = .current },
        ) void {
            for (values) |*cell| {
                if (cell.* < min) {
                    switch (limits.below) {
                        .current => {},
                        .limit => cell.* = min,
                        .fixed => |val| cell.* = val,
                    }
                } else {
                    switch (limits.above) {
                        .current => {},
                        .limit => cell.* = min,
                        .fixed => |val| cell.* = val,
                    }
                }
            }
        }

        /// Remove the mean and standard deviation from the given slice
        pub fn standardise(values: []Type, mean: Type, sd: Type) void {
            const n = values.len;
            var i: usize = 0;

            if (vectorize) {
                if (std.simd.suggestVectorLength(Type)) |block_size| {
                    const Block = @Vector(block_size, Type);

                    const mean_vec: Block = @splat(mean);
                    const sd_vec: Block = @splat(sd);
                    while (n - i >= block_size) : (i += block_size) {
                        const block: Block = values[i..][0..block_size].*;
                        values[i..][0..block_size].* = (block - mean_vec) / sd_vec;
                    }
                }
            }

            for (values[i..n]) |*item| {
                item.* = (item.* - mean) / sd;
            }
        }

        /// A simple approximation of loglikelihood of normal distribution
        ///
        /// `l = ln(y / (y + 1))`
        ///
        /// `y = e^(2 * sqrt(2 / pi) * x)`
        pub fn loglikelihoodApprox(values: []Type, sd: Type) void {
            const coef = @sqrt(8.0 / std.math.pi) / sd;

            const n = values.len;
            var i: usize = 0;

            if (vectorize) {
                if (std.simd.suggestVectorLength(Type)) |block_size| {
                    const Block = @Vector(block_size, Type);
                    const vec_coef: Block = @splat(coef);
                    const one: Block = @splat(1);

                    while (n - i >= block_size) : (i += block_size) {
                        const block: Block = values[i..][0..block_size].*;
                        values[i..][0..block_size].* = vec_coef * block - @log(@exp(vec_coef * block) + one);
                    }
                }
            }

            for (values[i..n]) |*item| {
                item.* = coef * item.* - @log(@exp(coef * item.*) + 1);
            }
        }
    };
}
