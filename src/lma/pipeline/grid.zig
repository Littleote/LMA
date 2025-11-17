const std = @import("std");
const pipe = @import("../pipeline.zig");
const float = pipe.float;
const zlm = @import("zlm").as(float);

pub const Shape = struct {
    rows: usize,
    columns: usize,

    pub fn Grid(comptime self: Shape, T: type) type {
        return [self.rows][self.columns]T;
    }
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
    pub fn decay(comptime shape: Shape, grid: *shape.Grid(float), factor: float) void {
        for (grid) |*row| {
            for (row) |*cell| {
                cell.* *= factor;
            }
        }
    }

    pub fn triangular(comptime shape: Shape, info: *const Info, grid: *shape.Grid(float), X: []const zlm.Vec2) void {
        for (X) |x| {
            const frac = x.sub(info.origin).div(info.step);
            if (frac.x < 0 or frac.y < 0) continue;
            const row: usize = @intFromFloat(@round(frac.y));
            const col: usize = @intFromFloat(@round(frac.x));
            if (shape.rows <= row + 1 or shape.columns <= col + 1) continue;
            const weight: zlm.Vec2 = .new(@mod(frac.x, 1), @mod(frac.y, 1));
            grid[row][col] += weight.x * weight.y;
            grid[row + 1][col] += weight.x * (1 - weight.y);
            grid[row + 1][col + 1] += weight.x * (1 - weight.y);
            grid[row][col + 1] += (1 - weight.x) * weight.y;
        }
    }
};
