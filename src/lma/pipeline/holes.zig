const std = @import("std");
const Allocator = std.mem.Allocator;
const pipe = @import("../pipeline.zig");
const float = pipe.float;
const grid = pipe.grid;

pub const Config = struct {
    min: float = 0,
    max: float = std.math.inf(float),
    decrease: float = 0,
};

pub const Info = struct {
    cluster: u16,
    row_col: struct { u16, u16 },
    lowest: float,
    area: u32,
    contour: u16,
    definition: [16]u16 = @splat(0),
};

const Neighbours = packed struct(u8) {
    left: bool = false,
    top_left: bool = false,
    top: bool = false,
    top_right: bool = false,
    right: bool = false,
    bottom_right: bool = false,
    bottom: bool = false,
    bottom_left: bool = false,

    pub inline fn int(self: Neighbours) u8 {
        return @bitCast(self);
    }

    pub const none: Neighbours = .{};
    pub const fourN: Neighbours = .{
        .left = true,
        .top = true,
        .right = true,
        .bottom = true,
    };
    pub const eightN: Neighbours = @bitCast(0xFF);
};

pub const ArrayInfo = std.MultiArrayList(Info);

pub fn analyze(
    comptime shape: grid.Shape,
    gpa: Allocator,
    values: *const shape.Grid(float),
    config: Config,
) !ArrayInfo {
    const neighbours = try gpa.create(shape.Grid(Neighbours));
    defer gpa.destroy(neighbours);
    neighbours.* = @splat(@splat(.none));
    const state = try gpa.create(shape.Grid(u16));
    defer gpa.destroy(state);
    state.* = @splat(@splat(0));

    var array: ArrayInfo = .empty;
    errdefer array.deinit(gpa);
    for (1..shape.rows - 1) |row| {
        for (1..shape.columns - 1) |col| {
            neighbours[row][col].left = values[row][col] >= values[row][col - 1];
            neighbours[row][col].top = values[row][col] >= values[row - 1][col];
            neighbours[row][col].right = values[row][col] >= values[row][col + 1];
            neighbours[row][col].bottom = values[row][col] >= values[row + 1][col];

            if (neighbours[row][col] == Neighbours.none) {
                state[row][col] = @intCast(2 + array.len);
                try array.append(gpa, .{
                    .cluster = state[row][col],
                    .row_col = .{ @intCast(row), @intCast(col) },
                    .lowest = values[row][col],
                    .area = 0,
                    .contour = 0,
                });
            }
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (1..shape.rows - 1) |row| {
            for (1..shape.columns - 1) |col| {
                if (state[row][col] <= 1) {
                    const left = &state[row][col - 1];
                    const top = &state[row - 1][col];
                    const right = &state[row][col + 1];
                    const bottom = &state[row + 1][col];
                    if (left.* <= 1 and top.* <= 1 and right.* <= 1 and bottom.* <= 1) {
                        if (state[row][col] == 1) changed = true;
                        state[row][col] = 0;
                        continue;
                    }
                    const neigh = neighbours[row][col];
                    var cluster: u16 = 0;
                    var is_border = false;
                    var is_set = false;
                    if (neigh.left and left.* > 1) {
                        cluster = if (is_set) cluster else left.*;
                        is_set = true;
                        is_border = is_border or left.* != cluster;
                    }
                    if (neigh.top and top.* > 1) {
                        cluster = if (is_set) cluster else top.*;
                        is_set = true;
                        is_border = is_border or top.* != cluster;
                    }
                    if (neigh.right and right.* > 1) {
                        cluster = if (is_set) cluster else right.*;
                        is_set = true;
                        is_border = is_border or right.* != cluster;
                    }
                    if (neigh.bottom and bottom.* > 1) {
                        cluster = if (is_set) cluster else bottom.*;
                        is_set = true;
                        is_border = is_border or bottom.* != cluster;
                    }

                    if (!is_set) continue;

                    if (is_border) {
                        if (state[row][col] == 0) changed = true;
                        state[row][col] = 1;
                    } else {
                        changed = true;
                        state[row][col] = cluster;

                        if (!neigh.left and left.* != cluster) {
                            left.* = 0;
                        }
                        if (!neigh.top and top.* != cluster) {
                            top.* = 0;
                        }
                        if (!neigh.right and right.* != cluster) {
                            right.* = 0;
                        }
                        if (!neigh.bottom and bottom.* != cluster) {
                            bottom.* = 0;
                        }
                    }
                }
            }
        }
    }

    const area = array.items(.area);
    const contour = array.items(.contour);
    const definition = array.items(.definition);
    for (1..shape.rows - 1) |row| {
        for (1..shape.columns - 1) |col| {
            if (state[row][col] > 1) {
                const idx = state[row][col] - 2;
                area[idx] += 1;
                var border: u8 = 0;
                if (state[row][col - 1] == 1) {
                    border += 1;
                    const level: u8 = @intFromFloat(@round(15.0 * @max(@min((values[row][col - 1] - config.min) / (config.max - config.min), 1.0), 0.0)));
                    definition[idx][level] += 1;
                }
                if (state[row - 1][col] == 1) {
                    border += 1;
                    const level: u8 = @intFromFloat(@round(15.0 * @max(@min((values[row - 1][col] - config.min) / (config.max - config.min), 1.0), 0.0)));
                    definition[idx][level] += 1;
                }
                if (state[row][col + 1] == 1) {
                    border += 1;
                    const level: u8 = @intFromFloat(@round(15.0 * @max(@min((values[row][col + 1] - config.min) / (config.max - config.min), 1.0), 0.0)));
                    definition[idx][level] += 1;
                }
                if (state[row + 1][col] == 1) {
                    border += 1;
                    const level: u8 = @intFromFloat(@round(15.0 * @max(@min((values[row + 1][col] - config.min) / (config.max - config.min), 1.0), 0.0)));
                    definition[idx][level] += 1;
                }
                contour[idx] += border;
            }
        }
    }

    // for (state) |row| {
    //     for (row) |cell| {
    //         std.debug.print("{s}", .{switch (cell) {
    //             0 => "  ",
    //             1 => "><",
    //             else => "::",
    //         }});
    //     }
    //     std.debug.print("\n", .{});
    // }

    for (definition) |*def| {
        var cumsum: u16 = 0;
        for (def) |*val| {
            cumsum += val.*;
            val.* = cumsum;
        }
    }

    return array;
}

inline fn analyzeNeighbour(state: u16, cluster: *?u16, update: bool) bool {
    if (state > 1) {
        defer if (update) {
            cluster.* = state;
        };
        return cluster.* orelse state == state;
    }
    return false;
}

pub fn shapesDepth(
    comptime shape: grid.Shape,
    values: *const shape.Grid(float),
    mask: *const shape.Grid(bool),
    diff: *shape.Grid(float),
) void {
    const max_values = diff;
    @memcpy(max_values, values);
    var changed = true;
    while (changed) {
        changed = false;
        for (1..shape.rows - 1) |row| {
            for (1..shape.columns - 1) |col| {
                const value = max_values[row][col];
                const is_hole = mask[row][col];
                if (!is_hole) continue;
                max_values[row][col] = blk: {
                    const left = col - 1;
                    const top = row - 1;
                    const row_offsets: [4]usize = .{ 0, 1, 2, 1 };
                    const col_offsets: [4]usize = .{ 1, 0, 1, 2 };
                    var max = value;
                    for (row_offsets, col_offsets) |row_offset, col_offset| {
                        max = @max(max, max_values[top + row_offset][left + col_offset]);
                    }
                    break :blk max;
                };
                changed = changed or value != max_values[row][col];
            }
        }
    }
    for (0..shape.rows) |row| {
        for (0..shape.columns) |col| {
            diff[row][col] = max_values[row][col] - values[row][col];
        }
    }
}

pub fn closedShapes(comptime shape: grid.Shape, values: *const shape.Grid(float), mask: *shape.Grid(bool), config: Config) void {
    mask.* = @splat(@splat(true));
    for (0..shape.rows) |row| {
        mask[row][0] = false;
        mask[row][shape.columns - 1] = false;
    }
    for (0..shape.columns) |col| {
        mask[0][col] = false;
        mask[shape.rows - 1][col] = false;
    }
    var changed = true;
    var any = false;
    while (changed) {
        changed = false;
        any = false;
        for (1..shape.rows - 1) |row| {
            for (1..shape.columns - 1) |col| {
                const value = values[row][col];
                const is_hole = mask[row][col];
                if (!is_hole) continue;
                const is_outside = blk: {
                    const left = col - 1;
                    const top = row - 1;
                    const row_offsets: [4]usize = .{ 0, 1, 2, 1 };
                    const col_offsets: [4]usize = .{ 1, 0, 1, 2 };
                    for (row_offsets, col_offsets) |row_offset, col_offset| {
                        if (mask[top + row_offset][left + col_offset]) continue;
                        if (
                        // zig fmt: off
                            value <= config.min or
                            values[top + row_offset][left + col_offset] <= value + config.decrease or
                            config.max < value
                        // zig fmt: on
                        ) break :blk true;
                    }
                    break :blk false;
                };
                mask[row][col] = !is_outside;
                changed = changed or is_outside;
                any = any or !is_outside;
            }
        }
    }
}
