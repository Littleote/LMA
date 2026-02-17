const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("../lma.zig");
const zlm = lma.pipeline.zlm;
const common = lma.common;

pub const Shape = struct {
    rows: u32,
    columns: u32,
    size: usize,

    pub fn init(rows: u32, columns: u32) Shape {
        return .{
            .rows = rows,
            .columns = columns,
            .size = common.as(usize, rows) * common.as(usize, columns),
        };
    }

    pub fn ComptimeGrid(comptime self: Shape, T: type) type {
        return [self.rows][self.columns]T;
    }

    pub fn offset(self: Shape, neighbour: Neighbour) isize {
        return neighbour.h + neighbour.v * common.as(isize, self.columns);
    }

    pub fn unravel(self: Shape, index: usize) struct { usize, usize } {
        return .{ index / self.columns, index % self.columns };
    }

    pub fn ravel(self: Shape, row: usize, column: usize) usize {
        return row * self.columns + column;
    }
};

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

pub fn Info(float: type) type {
    return struct {
        pub const Detail = union(enum) {
            shape: Shape,
            step: zlm(float).Vec2,

            pub fn fromShape(shape: Shape) Detail {
                return .{ .shape = shape };
            }

            pub fn fromStep(step: zlm(float).Vec2) Detail {
                return .{ .step = step };
            }

            pub fn getInfo(self: Detail, size: zlm(float).Vec2) struct { Shape, zlm(float).Vec2 } {
                const shape: Shape = switch (self) {
                    .shape => |shape| shape,
                    .step => |step| blk: {
                        const shape = size.div(step).add(.new(1, 1));
                        break :blk .init(@intFromFloat(@round(shape.y)), @intFromFloat(@round(shape.x)));
                    },
                };
                const count: zlm(float).Vec2 = .new(@floatFromInt(shape.columns - 1), @floatFromInt(shape.rows - 1));
                return .{ shape, size.div(count) };
            }
        };

        shape: Shape,
        size: zlm(float).Vec2,
        origin: zlm(float).Vec2,
        end: zlm(float).Vec2,
        step: zlm(float).Vec2,

        pub fn limits(detail: Detail, origin: zlm(float).Vec2, end: zlm(float).Vec2) Info(float) {
            const size = end.sub(origin);
            const shape, const step = detail.getInfo(size);
            return .{
                .shape = shape,
                .size = size,
                .origin = origin,
                .end = end,
                .step = step,
            };
        }

        pub fn scale(detail: Detail, size: zlm(float).Vec2) Info(float) {
            return .scaleTranslate(detail, .zero, size);
        }

        pub fn scaleTranslate(detail: Detail, center: zlm(float).Vec2, size: zlm(float).Vec2) Info(float) {
            const offset = size.scale(0.5);
            const shape, const step = detail.getInfo(size);
            return .{
                .shape = shape,
                .size = size,
                .origin = center.add(offset.neg()),
                .end = center.add(offset),
                .step = step,
            };
        }

        pub fn contains(self: *const Info, point: zlm(float).Vec2) bool {
            // zig fmt: off
            return (
                self.origin.x < point.x and point.x < self.end.x and
                self.origin.y < point.y and point.y < self.end.y
            );
        // zig fmt: on
        }
    };
}

pub fn update(float: type) type {
    return struct {
        pub const convolution = struct {
            pub fn call(shape: Shape, values: []float, aux: []float, horizontal: []const float, vertical: []const float) void {
                const mid_col = @divExact(horizontal.len - 1, 2);
                for (0..shape.rows) |row| {
                    for (0..shape.columns) |col| {
                        const idx = shape.ravel(row, col);
                        var val: float = 0.0;
                        for (0..horizontal.len) |diff| {
                            if (col + diff < mid_col or shape.columns <= col + diff - mid_col) continue;
                            val += horizontal[diff] * values[idx + diff - mid_col];
                        }
                        aux[idx] = val;
                    }
                }
                const mid_row = @divExact(vertical.len - 1, 2);
                for (0..shape.rows) |row| {
                    for (0..shape.columns) |col| {
                        const idx = shape.ravel(row, col);
                        var val: float = 0.0;
                        for (0..vertical.len) |diff| {
                            if (row + diff < mid_row or shape.rows <= row + diff - mid_row) continue;
                            val += vertical[diff] * aux[shape.ravel(row + diff - mid_row, col)];
                        }
                        values[idx] = val;
                    }
                }
            }

            pub fn gaussian(buffer: []float, sigma: float) void {
                var sum: float = 0.0;
                var idx: usize = 0;
                var x = -(common.cast(float, buffer.len) - 1) / 2;
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

        pub fn morph(shape: Shape, values: []float, aux: []float, op_shape: Shape, comptime op: enum { erode, dilate }) void {
            const mid_col = @divExact(op_shape.columns - 1, 2);
            for (0..shape.rows) |row| {
                for (0..shape.columns) |col| {
                    const idx = shape.ravel(row, col);
                    var val = values[idx];
                    for (0..op_shape.columns) |diff| {
                        if (col + diff < mid_col or shape.columns <= col + diff - mid_col) continue;
                        const neigh = values[idx + diff - mid_col];
                        val = switch (op) {
                            .erode => @min(val, neigh),
                            .dilate => @max(val, neigh),
                        };
                    }
                    aux[idx] = val;
                }
            }
            const mid_row = @divExact(op_shape.rows - 1, 2);
            for (0..shape.rows) |row| {
                for (0..shape.columns) |col| {
                    const idx = shape.ravel(row, col);
                    var val = aux[idx];
                    for (0..op_shape.rows) |diff| {
                        if (row + diff < mid_row or shape.rows <= row + diff - mid_row) continue;
                        const neigh = aux[shape.ravel(row + diff - mid_row, col)];
                        val = switch (op) {
                            .erode => @min(val, neigh),
                            .dilate => @max(val, neigh),
                        };
                    }
                    values[idx] = val;
                }
            }
        }

        pub const Window = struct {
            shape: Shape,
            frames: []float,
            current_frame: usize,
            size: usize,
            correction: float = 1e-7,

            pub fn init(gpa: Allocator, shape: Shape, size: usize) !Window {
                const frames = try gpa.alloc(float, shape.size * size);
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

            pub fn get(self: *Window) []float {
                return self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            }

            pub fn apply(self: *Window, values: []float) void {
                const current = self.get();
                for (values, current) |*total, add| {
                    total.* = total.* + add;
                }
            }

            pub fn setupNext(self: *Window, values: []float) void {
                self.ignore();
                const next = self.get();
                for (values, next) |*total, sub| {
                    total.* = @max(0, total.* - sub - self.correction);
                }
                self.clear();
            }

            pub fn advance(self: *Window, values: []float) void {
                const last = self.get();
                self.ignore();
                const next = self.get();
                for (values, last, next) |*total, add, sub| {
                    total.* = @max(0, total.* + add - sub - self.correction);
                }
                self.clear();
            }

            pub fn peek(self: *Window) []float {
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

        pub fn decay(shape: Shape, values: []float, factor: float) void {
            _ = shape;
            for (values) |*cell| {
                cell.* *= factor;
            }
        }

        pub const options = struct {
            pub const Triangular = struct {
                scaling: float = 1.0,
            };
        };

        pub fn triangular(shape: Shape, info: *const Info(float), grid: []float, X: []const zlm(float).Vec2, config: options.Triangular) void {
            for (X) |x| {
                const frac = x.sub(info.origin).div(info.step);
                if (frac.x < 0 or frac.y < 0) continue;
                const row: usize = @intFromFloat(@round(frac.y));
                const col: usize = @intFromFloat(@round(frac.x));
                if (shape.rows <= row + 1 or shape.columns <= col + 1) continue;
                const weight: zlm(float).Vec2 = .new(@mod(frac.x, 1), @mod(frac.y, 1));
                const idx = shape.ravel(row, col);
                grid[idx] += config.scaling * weight.x * weight.y;
                grid[idx + shape.columns] += config.scaling * weight.x * (1 - weight.y);
                grid[idx + 1 + shape.columns] += config.scaling * (1 - weight.x) * (1 - weight.y);
                grid[idx + 1] += config.scaling * (1 - weight.x) * weight.y;
            }
        }

        pub const SetValue = union(enum) {
            current: void,
            limit: void,
            fixed: float,

            pub const zero: SetValue = .{ .fixed = 0 };
        };

        pub fn threshold(
            shape: Shape,
            values: []float,
            min: float,
            comptime limits: struct { below: SetValue = .zero, above: SetValue = .current },
        ) void {
            _ = shape;
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
