const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const lma = @import("../lma.zig");
const math = lma.pipeline.math;
const cast = lma.cast;

const Grid = @This();

rows: u32,
columns: u32,
size: u32,

pub fn init(rows: u32, columns: u32) Grid {
    return .{ .rows = rows, .columns = columns, .size = rows * columns };
}

pub fn ComptimeGrid(comptime self: Grid, T: type) type {
    return [self.rows][self.columns]T;
}

pub fn offset(self: Grid, neighbour: Neighbour) isize {
    return neighbour.h + neighbour.v * cast.as(isize, self.columns);
}

pub fn unravel(self: Grid, index: usize) struct { usize, usize } {
    return .{ index / self.columns, index % self.columns };
}

pub fn ravel(self: Grid, row: usize, column: usize) usize {
    return row * self.columns + column;
}

const Neighbour = packed struct(u4) {
    h: i2,
    v: i2,

    pub fn init(h: i2, v: i2) Neighbour {
        return .{ .h = h, .v = v };
    }

    pub fn fromInt(int: u4) Neighbour {
        return @bitCast(int);
    }

    pub fn toInt(self: Neighbour) u4 {
        return @bitCast(self);
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

pub fn Bounds(Float: type) type {
    assert(@typeInfo(Float) == .float);
    return struct {
        const vector = math(Float).vector;
        pub const Vec = math(Float).Vec;

        pub const Detail = union(enum) {
            grid: Grid,
            step: Vec,

            pub fn fromGrid(grid: Grid) Detail {
                return .{ .grid = grid };
            }

            pub fn fromStep(step: Vec) Detail {
                return .{ .step = step };
            }

            pub fn getBounds(self: Detail, size: Vec) struct { Grid, Vec } {
                const grid: Grid = switch (self) {
                    .grid => |grid| grid,
                    .step => |step| blk: {
                        const grid: math(Float).ElemVec = .init(size / step + vector.splat(1));
                        break :blk .init(@intFromFloat(@round(grid.at(.y))), @intFromFloat(@round(grid.at(.x))));
                    },
                };
                const count: Vec = vector.vec2(@floatFromInt(grid.columns - 1), @floatFromInt(grid.rows - 1));
                return .{ grid, size / count };
            }
        };

        grid: Grid,
        size: Vec,
        origin: Vec,
        end: Vec,
        step: Vec,

        pub fn limits(detail: Detail, origin: Vec, end: Vec) Bounds(Float) {
            const size = end - origin;
            const grid, const step = detail.getBounds(size);
            return .{
                .grid = grid,
                .size = size,
                .origin = origin,
                .end = end,
                .step = step,
            };
        }

        pub fn scale(detail: Detail, size: Vec) Bounds(Float) {
            return .scaleTranslate(detail, vector.zero, size);
        }

        pub fn scaleTranslate(detail: Detail, center: Vec, size: Vec) Bounds(Float) {
            const half_size = size * vector.splat(0.5);
            const grid, const step = detail.getBounds(size);
            return .{
                .grid = grid,
                .size = size,
                .origin = center - half_size,
                .end = center + half_size,
                .step = step,
            };
        }

        pub fn contains(self: *const Bounds, point: Vec) bool {
            // zig fmt: off
            return (
                self.origin.x < point.x and point.x < self.end.x and
                self.origin.y < point.y and point.y < self.end.y
            );
            // zig fmt: on
        }

        pub const Kde = union(enum) {
            triangular: struct {
                scaling: Float = 1.0,

                pub fn run(options: @This(), bounds: *const Bounds(Float), values: []Float, points: []const Vec) void {
                    const grid = bounds.grid;
                    for (points) |x| {
                        const frac: math(Float).ElemVec = .init((x - bounds.origin) / bounds.step);
                        if (frac.x() < 0 or frac.y() < 0) continue;
                        const row: usize = @intFromFloat(@round(frac.y()));
                        const col: usize = @intFromFloat(@round(frac.x()));
                        if (grid.rows <= row + 1 or grid.columns <= col + 1) continue;
                        const weight: struct { x: Float, y: Float } = .{ .x = @mod(frac.x(), 1), .y = @mod(frac.y(), 1) };
                        const idx = grid.ravel(row, col);
                        values[idx] += options.scaling * weight.x * weight.y;
                        values[idx + grid.columns] += options.scaling * weight.x * (1 - weight.y);
                        values[idx + 1 + grid.columns] += options.scaling * (1 - weight.x) * (1 - weight.y);
                        values[idx + 1] += options.scaling * (1 - weight.x) * weight.y;
                    }
                }
            },
        };

        pub fn kde(bounds: *const Bounds(Float), values: []Float, points: []const Vec, method: Kde) void {
            switch (method) {
                inline else => |options| options.run(bounds, values, points),
            }
        }
    };
}

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

        pub fn convolution(grid: Grid, values: []Type, aux: []Type, horizontal: []const Type, vertical: []const Type) void {
            axisConvolution(.columns, grid, values, aux, vertical);
            axisConvolution(.rows, grid, aux, values, horizontal);
        }

        pub fn axisConvolution(comptime axis: Axis, grid: Grid, input: []Type, output: []Type, array: []const Type) void {
            const mid_point = @divExact(array.len - 1, 2);
            for (0..grid.rows) |row| {
                for (0..grid.columns) |col| {
                    const idx = grid.ravel(row, col);
                    var val: Type = 0.0;
                    for (0..array.len) |diff| {
                        switch (axis) {
                            .rows => {
                                if (col + diff < mid_point or grid.columns <= col + diff - mid_point) continue;
                                val += array[diff] * input[idx + diff - mid_point];
                            },
                            .columns => {
                                if (row + diff < mid_point or grid.rows <= row + diff - mid_point) continue;
                                val += array[diff] * input[grid.ravel(row + diff - mid_point, col)];
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

        pub fn morph(grid: Grid, values: []Type, aux: []Type, size: Grid, comptime operation: MorphOperation) void {
            axisMorph(.rows, grid, values, aux, size.rows, operation);
            axisMorph(.columns, grid, aux, values, size.columns, operation);
        }

        pub fn axisMorph(comptime axis: Axis, grid: Grid, input: []Type, output: []Type, size: u32, comptime operation: MorphOperation) void {
            const mid_point = @divExact(size - 1, 2);
            for (0..grid.rows) |row| {
                for (0..grid.columns) |col| {
                    const idx = grid.ravel(row, col);
                    var val = input[idx];
                    for (0..size) |diff| {
                        const neighbour = switch (axis) {
                            .rows => blk: {
                                if (col + diff < mid_point or grid.columns <= col + diff - mid_point) continue;
                                break :blk input[idx + diff - mid_point];
                            },
                            .columns => blk: {
                                if (row + diff < mid_point or grid.rows <= row + diff - mid_point) continue;
                                break :blk input[grid.ravel(row + diff - mid_point, col)];
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
            grid: Grid,
            frames: []Type,
            current_frame: usize,
            size: usize,
            correction: Type = 1e-7,

            pub fn init(gpa: Allocator, grid: Grid, size: usize) !Window {
                const frames = try gpa.alloc(Type, grid.size * size);
                @memset(frames, 0);
                return .{
                    .grid = grid,
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
                return self.frames[self.grid.size * self.current_frame ..][0..self.grid.size];
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
                const next = self.frames[self.grid.size * next_frame ..][0..self.grid.size];
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
    };
}
