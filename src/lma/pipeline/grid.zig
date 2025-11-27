const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("../lma.zig");
const pipe = lma.pipeline;
const float = pipe.float;
const math = lma.math;
const zlm = @import("zlm").as(float);

pub const Shape = struct {
    rows: u32,
    columns: u32,
    size: usize,

    pub fn init(rows: u32, columns: u32) Shape {
        return .{
            .rows = rows,
            .columns = columns,
            .size = math.as(usize, rows) * math.as(usize, columns),
        };
    }

    pub fn ComptimeGrid(comptime self: Shape, T: type) type {
        return [self.rows][self.columns]T;
    }

    pub fn offset(self: Shape, neighbour: Neighbour) isize {
        return neighbour.h + neighbour.v * math.as(isize, self.columns);
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

pub const Info = struct {
    pub const Detail = union(enum) {
        shape: Shape,
        step: zlm.Vec2,

        pub fn fromShape(shape: Shape) Detail {
            return .{ .shape = shape };
        }

        pub fn fromStep(step: zlm.Vec2) Detail {
            return .{ .step = step };
        }

        pub fn getInfo(self: Detail, size: zlm.Vec2) struct { Shape, zlm.Vec2 } {
            const shape: Shape = switch (self) {
                .shape => |shape| shape,
                .step => |step| blk: {
                    const shape = size.div(step).add(.new(1, 1));
                    break :blk .init(@intFromFloat(@round(shape.y)), @intFromFloat(@round(shape.x)));
                },
            };
            const count: zlm.Vec2 = .new(@floatFromInt(shape.columns - 1), @floatFromInt(shape.rows - 1));
            return .{ shape, size.div(count) };
        }
    };

    shape: Shape,
    size: zlm.Vec2,
    origin: zlm.Vec2,
    end: zlm.Vec2,
    step: zlm.Vec2,

    pub fn limits(detail: Detail, origin: zlm.Vec2, end: zlm.Vec2) Info {
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

    pub fn scale(detail: Detail, size: zlm.Vec2) Info {
        return .scaleTranslate(detail, .zero, size);
    }

    pub fn scaleTranslate(detail: Detail, center: zlm.Vec2, size: zlm.Vec2) Info {
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

    pub fn contains(self: *const Info, point: zlm.Vec2) bool {
        // zig fmt: off
        return (
            self.origin.x < point.x and point.x < self.end.x and
            self.origin.y < point.y and point.y < self.end.y
        );
        // zig fmt: on
    }
};

inline fn toFloat(value: anytype) float {
    return @floatFromInt(value);
}

pub const update = struct {
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

        pub fn applyFrame(self: *Window, values: []float) void {
            const current = self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            for (values, current) |*total, add| {
                total.* = total.* + add;
            }
        }

        pub fn clearNextFrame(self: *Window, values: []float) []float {
            self.current_frame = (self.current_frame + 1) % self.size;
            const next = self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            for (values, next) |*total, sub| {
                total.* = @max(0, total.* - sub - self.correction);
            }
            @memset(next, 0);
            return next;
        }

        pub fn jumpToNextFrame(self: *Window, values: []float) []float {
            const last = self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            self.current_frame = (self.current_frame + 1) % self.size;
            const next = self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            for (values, last, next) |*total, add, sub| {
                total.* = @max(0, total.* + add - sub - self.correction);
            }
            @memset(next, 0);
            return next;
        }

        pub fn peekFrame(self: *Window) []float {
            const next_frame = (self.current_frame + 1) % self.size;
            const next = self.frames[self.shape.size * next_frame ..][0..self.shape.size];
            return next;
        }

        pub fn ignoreFrame(self: *Window) []float {
            self.current_frame = (self.current_frame + 1) % self.size;
            const next = self.frames[self.shape.size * self.current_frame ..][0..self.shape.size];
            @memset(next, 0);
            return next;
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

    pub fn triangular(shape: Shape, info: *const Info, grid: []float, X: []const zlm.Vec2, config: options.Triangular) void {
        for (X) |x| {
            const frac = x.sub(info.origin).div(info.step);
            if (frac.x < 0 or frac.y < 0) continue;
            const row: usize = @intFromFloat(@round(frac.y));
            const col: usize = @intFromFloat(@round(frac.x));
            if (shape.rows <= row + 1 or shape.columns <= col + 1) continue;
            const weight: zlm.Vec2 = .new(@mod(frac.x, 1), @mod(frac.y, 1));
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
                    .limit => {
                        cell.* = min;
                    },
                    .fixed => |val| {
                        cell.* = val;
                    },
                }
            } else {
                switch (limits.above) {
                    .current => {},
                    .limit => {
                        cell.* = min;
                    },
                    .fixed => |val| {
                        cell.* = val;
                    },
                }
            }
        }
    }
};
