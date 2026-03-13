const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const lma = @import("../lma.zig");
const zlm = lma.pipeline.zlm;
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
        pub const Vec2 = zlm(Float).Vec2;

        pub const Detail = union(enum) {
            grid: Grid,
            step: Vec2,

            pub fn fromGrid(grid: Grid) Detail {
                return .{ .grid = grid };
            }

            pub fn fromStep(step: Vec2) Detail {
                return .{ .step = step };
            }

            pub fn getBounds(self: Detail, size: Vec2) struct { Grid, Vec2 } {
                const grid: Grid = switch (self) {
                    .grid => |grid| grid,
                    .step => |step| blk: {
                        const grid = size.div(step).add(.new(1, 1));
                        break :blk .init(@intFromFloat(@round(grid.y)), @intFromFloat(@round(grid.x)));
                    },
                };
                const count: Vec2 = .new(@floatFromInt(grid.columns - 1), @floatFromInt(grid.rows - 1));
                return .{ grid, size.div(count) };
            }
        };

        const kde_method = struct {
            pub const options = struct {
                pub const Triangular = struct {
                    scaling: Float = 1.0,
                };
            };

            pub fn triangular(bounds: *const Bounds(Float), values: []Float, points: []const Vec2, config: options.Triangular) void {
                const grid = bounds.grid;
                for (points) |x| {
                    const frac = x.sub(bounds.origin).div(bounds.step);
                    if (frac.x < 0 or frac.y < 0) continue;
                    const row: usize = @intFromFloat(@round(frac.y));
                    const col: usize = @intFromFloat(@round(frac.x));
                    if (grid.rows <= row + 1 or grid.columns <= col + 1) continue;
                    const weight: Vec2 = .new(@mod(frac.x, 1), @mod(frac.y, 1));
                    const idx = grid.ravel(row, col);
                    values[idx] += config.scaling * weight.x * weight.y;
                    values[idx + grid.columns] += config.scaling * weight.x * (1 - weight.y);
                    values[idx + 1 + grid.columns] += config.scaling * (1 - weight.x) * (1 - weight.y);
                    values[idx + 1] += config.scaling * (1 - weight.x) * weight.y;
                }
            }
        };

        grid: Grid,
        size: Vec2,
        origin: Vec2,
        end: Vec2,
        step: Vec2,

        pub fn limits(detail: Detail, origin: Vec2, end: Vec2) Bounds(Float) {
            const size = end.sub(origin);
            const grid, const step = detail.getBounds(size);
            return .{
                .grid = grid,
                .size = size,
                .origin = origin,
                .end = end,
                .step = step,
            };
        }

        pub fn scale(detail: Detail, size: Vec2) Bounds(Float) {
            return .scaleTranslate(detail, .zero, size);
        }

        pub fn scaleTranslate(detail: Detail, center: Vec2, size: Vec2) Bounds(Float) {
            const half_size = size.scale(0.5);
            const grid, const step = detail.getBounds(size);
            return .{
                .grid = grid,
                .size = size,
                .origin = center.add(half_size.neg()),
                .end = center.add(half_size),
                .step = step,
            };
        }

        pub fn contains(self: *const Bounds, point: Vec2) bool {
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

                pub fn run(options: @This(), bounds: *const Bounds(Float), values: []Float, points: []const Vec2) void {
                    const grid = bounds.grid;
                    for (points) |x| {
                        const frac = x.sub(bounds.origin).div(bounds.step);
                        if (frac.x < 0 or frac.y < 0) continue;
                        const row: usize = @intFromFloat(@round(frac.y));
                        const col: usize = @intFromFloat(@round(frac.x));
                        if (grid.rows <= row + 1 or grid.columns <= col + 1) continue;
                        const weight: Vec2 = .new(@mod(frac.x, 1), @mod(frac.y, 1));
                        const idx = grid.ravel(row, col);
                        values[idx] += options.scaling * weight.x * weight.y;
                        values[idx + grid.columns] += options.scaling * weight.x * (1 - weight.y);
                        values[idx + 1 + grid.columns] += options.scaling * (1 - weight.x) * (1 - weight.y);
                        values[idx + 1] += options.scaling * (1 - weight.x) * weight.y;
                    }
                }
            },
        };

        pub fn kde(bounds: *const Bounds(Float), values: []Float, points: []const Vec2, method: Kde) void {
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
                elementWiseOp(self.grid, values, .add, current);
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

        pub fn elementWiseOp(grid: Grid, lhs: []Type, comptime operation: Operator, rhs: []Type) void {
            _ = grid;
            for (lhs, rhs) |*l, r| {
                l.* = switch (operation) {
                    .add => l.* + r,
                    .sub => l.* - r,
                    .mul => l.* * r,
                    .div => l.* / r,
                    .max => @max(l.*, r),
                    .min => @min(l.*, r),
                };
            }
        }

        pub fn scalarOp(grid: Grid, values: []Type, comptime operation: Operator, scalar: Type) void {
            _ = grid;
            for (values) |*v| {
                v.* = switch (operation) {
                    .add => v.* + scalar,
                    .sub => v.* - scalar,
                    .mul => v.* * scalar,
                    .div => v.* / scalar,
                    .max => @max(v.*, scalar),
                    .min => @min(v.*, scalar),
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
            grid: Grid,
            values: []Type,
            min: Type,
            comptime limits: struct { below: SetValue = .zero, above: SetValue = .current },
        ) void {
            _ = grid;
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
    };
}
