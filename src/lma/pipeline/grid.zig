const std = @import("std");
const lma = @import("../root.zig");
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
            .size = math.cast(usize, rows) * math.cast(usize, columns),
        };
    }

    pub fn ComptimeGrid(comptime self: Shape, T: type) type {
        return [self.rows][self.columns]T;
    }

    pub fn offset(self: Shape, neighbour: Neighbour) isize {
        return neighbour.h + neighbour.v * math.cast(isize, self.columns);
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
    origin: zlm.Vec2,
    end: zlm.Vec2,
    step: zlm.Vec2,
    count: zlm.Vec2,

    pub fn limits(shape: Shape, origin: zlm.Vec2, end: zlm.Vec2) Info {
        const count: zlm.Vec2 = .new(@floatFromInt(shape.columns - 1), @floatFromInt(shape.rows - 1));
        return .{
            .origin = origin,
            .end = end,
            .count = count,
            .step = end.sub(origin).div(count),
        };
    }

    pub fn scale(shape: Shape, size: zlm.Vec2) Info {
        return .scaleTranslate(shape, .zero, size);
    }

    pub fn scaleTranslate(shape: Shape, center: zlm.Vec2, size: zlm.Vec2) Info {
        const offset = size.scale(0.5);
        const count: zlm.Vec2 = .new(@floatFromInt(shape.columns - 1), @floatFromInt(shape.rows - 1));
        return .{
            .origin = center.add(offset.neg()),
            .end = center.add(offset),
            .count = count,
            .step = size.div(count),
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

    // pub fn indexInner(self: *const Info, point: zlm.Vec2) ?struct { usize, usize } {

    // }
};

inline fn toFloat(value: anytype) float {
    return @floatFromInt(value);
}

pub const update = struct {
    pub fn decay(shape: Shape, values: []float, factor: float) void {
        _ = shape;
        for (values) |*cell| {
            cell.* *= factor;
        }
    }

    pub fn triangular(shape: Shape, info: *const Info, grid: []float, X: []const zlm.Vec2) void {
        for (X) |x| {
            const frac = x.sub(info.origin).div(info.step);
            if (frac.x < 0 or frac.y < 0) continue;
            const row: usize = @intFromFloat(@round(frac.y));
            const col: usize = @intFromFloat(@round(frac.x));
            if (shape.rows <= row + 1 or shape.columns <= col + 1) continue;
            const weight: zlm.Vec2 = .new(@mod(frac.x, 1), @mod(frac.y, 1));
            const idx = shape.ravel(row, col);
            grid[idx] += weight.x * weight.y;
            grid[idx + shape.columns] += weight.x * (1 - weight.y);
            grid[idx + 1 + shape.columns] += weight.x * (1 - weight.y);
            grid[idx + 1] += (1 - weight.x) * weight.y;
        }
    }
};
