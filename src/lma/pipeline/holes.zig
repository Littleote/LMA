const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("../root.zig");
const pipe = lma.pipeline;
const float = pipe.float;
const grid = pipe.grid;
const math = lma.math;

const SortContext = struct {
    values: []const float,

    pub fn init(values: []const float) SortContext {
        return .{ .values = values };
    }

    pub fn lessThan(self: SortContext, a: usize, b: usize) bool {
        if (self.values[a] != self.values[b]) {
            @branchHint(.likely);
            return self.values[a] < self.values[b];
        } else {
            @branchHint(.unlikely);
            return a < b;
        }
    }
};

pub const Cluster = enum(u16) {
    none = 0,
    _,

    pub fn cluster(value: u16) Cluster {
        std.debug.assert(value != 0);
        return @enumFromInt(value);
    }

    pub fn any(value: u16) Cluster {
        return @enumFromInt(value);
    }

    pub fn int(self: Cluster) u16 {
        return @intFromEnum(self);
    }

    pub fn addToSet(value: Cluster, set: *std.ArrayList(Cluster)) void {
        if (value == .none) return;
        for (set.items) |option| {
            if (value == option) return;
        }
        set.appendAssumeCapacity(value);
    }
};

pub const Seed = struct {
    index: []const usize,
    clusters: ?[]const Cluster,
    size: u16,

    pub fn init(index: []const usize, maybe_clusters: ?[]const Cluster) Seed {
        return .{
            .index = index,
            .clusters = maybe_clusters,
            .size = if (maybe_clusters) |clusters| blk: {
                var max: u16 = 0;
                for (clusters) |c| {
                    max = @max(max, c.int());
                }
                break :blk max;
            } else @intCast(index.len + 1),
        };
    }

    pub fn cluster(self: *const Seed, idx: usize) Cluster {
        return if (self.clusters) |clusters| clusters[idx] else .cluster(@intCast(idx + 1));
    }
};

pub fn findSeeds(gpa: Allocator, shape: grid.Shape, values: []const float, seeds: *std.ArrayList(usize)) error{OutOfMemory}!void {
    seeds.items.len = 0;
    const offsets: [4]isize = .{
        shape.offset(.left),
        shape.offset(.top),
        shape.offset(.right),
        shape.offset(.bottom),
    };
    {
        const idx = shape.ravel(1, 1);
        const value = values[idx];
        var is_min = true;
        is_min = is_min and value <= values[math.offset(usize, idx, offsets[2]) catch unreachable];
        is_min = is_min and value <= values[math.offset(usize, idx, offsets[3]) catch unreachable];
        if (is_min) {
            try seeds.append(gpa, idx);
        }
    }
    for (2..shape.rows - 1) |row| {
        const idx = shape.ravel(row, 1);
        const value = values[idx];
        var is_min = true;
        is_min = is_min and value < values[math.offset(usize, idx, offsets[1]) catch unreachable];
        is_min = is_min and value <= values[math.offset(usize, idx, offsets[2]) catch unreachable];
        is_min = is_min and value <= values[math.offset(usize, idx, offsets[3]) catch unreachable];
        if (is_min) {
            try seeds.append(gpa, idx);
        }
    }
    for (2..shape.columns - 1) |col| {
        const idx = shape.ravel(1, col);
        const value = values[idx];
        var is_min = true;
        is_min = is_min and value < values[math.offset(usize, idx, offsets[0]) catch unreachable];
        is_min = is_min and value <= values[math.offset(usize, idx, offsets[2]) catch unreachable];
        is_min = is_min and value <= values[math.offset(usize, idx, offsets[3]) catch unreachable];
        if (is_min) {
            try seeds.append(gpa, idx);
        }
    }
    for (2..shape.rows - 1) |row| {
        for (2..shape.columns - 1) |col| {
            const idx = shape.ravel(row, col);
            const value = values[idx];
            var is_min = true;
            is_min = is_min and value < values[math.offset(usize, idx, offsets[0]) catch unreachable];
            is_min = is_min and value < values[math.offset(usize, idx, offsets[1]) catch unreachable];
            is_min = is_min and value <= values[math.offset(usize, idx, offsets[2]) catch unreachable];
            is_min = is_min and value <= values[math.offset(usize, idx, offsets[3]) catch unreachable];
            if (is_min) {
                try seeds.append(gpa, idx);
            }
        }
    }

    sort(values, seeds.items);
}

pub fn makeOrderBuffer(gpa: Allocator, shape: grid.Shape) error{OutOfMemory}![]usize {
    const inner_shape: grid.Shape = .init(shape.rows - 2, shape.columns - 2);
    const buffer = try gpa.alloc(usize, inner_shape.size);
    errdefer buffer;

    var idx: usize = 0;
    for (1..shape.rows - 1) |row| {
        for (1..shape.columns - 1) |col| {
            buffer[idx] = shape.ravel(row, col);
            idx += 1;
        }
    }

    return buffer;
}

pub fn sort(values: []const float, order: []usize) void {
    std.sort.block(usize, order, SortContext.init(values), SortContext.lessThan);
}

pub const Spill = struct {
    pub const Conditions = struct {
        relative: float = 1,
        absolute: float = 0,
    };

    gpa: Allocator,
    shape: grid.Shape,

    conditions: Conditions,

    spill_height: Cluster,
    floors: []float,
    mapping: []Cluster,
    guess_size: ?u16,

    pub fn init(gpa: Allocator, shape: grid.Shape, conditions: Conditions) Spill {
        return .{
            .gpa = gpa,
            .shape = shape,
            .conditions = conditions,
            .spill_height = undefined,
            .floors = undefined,
            .mapping = undefined,
            .guess_size = undefined,
        };
    }

    fn canSpill(self: *Spill, cluster: Cluster, value: float) bool {
        if (self.spill_height.int() >= cluster.int()) return false;
        const floor = self.floors[cluster.int()];
        const spills = value < @mulAdd(float, floor, self.conditions.relative, self.conditions.absolute);
        self.spill_height = if (spills) self.spill_height else cluster;
        return spills;
    }

    fn initStep(self: *Spill, seeds: *const Seed, values: []const float, map: []Cluster) error{OutOfMemory}!void {
        self.spill_height = .none;
        self.mapping = try self.gpa.alloc(Cluster, seeds.size);
        errdefer self.gpa.free(self.mapping);
        for (self.mapping, 0..) |*to, value| {
            to.* = .any(@intCast(value));
        }
        self.floors = try self.gpa.alloc(float, seeds.size);
        errdefer self.gpa.free(self.floors);
        var idx = seeds.index.len;
        while (idx > 0) {
            idx -= 1;
            map[seeds.index[idx]] = seeds.cluster(idx);
            self.floors[idx] = values[seeds.index[idx]];
        }
    }

    fn deinitStep(self: *Spill) void {
        self.gpa.free(self.mapping);
        self.mapping = undefined;
        self.gpa.free(self.floors);
        self.floors = undefined;
    }

    fn reduceMapping(self: *Spill) u16 {
        var lowest: Cluster = .cluster(1);
        var idx: u16 = 1;
        var jdx: u16 = undefined;
        while (idx < self.mapping.len) : (idx += 1) {
            if (self.mapping[idx].int() == idx) {
                const old: Cluster = .cluster(idx);
                defer lowest = .cluster(lowest.int() + 1);
                self.mapping[idx] = lowest;
                jdx = idx + 1;
                while (jdx < self.mapping.len) : (jdx += 1) {
                    if (self.mapping[jdx] == old) {
                        self.mapping[jdx] = lowest;
                    }
                }
            }
        }
        return lowest.int();
    }

    pub fn assign(self: *Spill, seeds: *const Seed, order: []const usize, values: []const float, map: []Cluster) error{ OutOfMemory, Overflow }!u16 {
        @memset(map, .none);
        const offsets: [4]isize = .{
            self.shape.offset(.left),
            self.shape.offset(.top),
            self.shape.offset(.right),
            self.shape.offset(.bottom),
        };
        var buffer: [4]Cluster = undefined;
        var options: std.ArrayList(Cluster) = .initBuffer(&buffer);
        try self.initStep(seeds, values, map);
        defer self.deinitStep();

        for (order) |idx| {
            defer options.items.len = 0;
            for (offsets) |offset|
                self.mapping[map[math.offset(usize, idx, offset) catch unreachable].int()].addToSet(&options);
            if (options.items.len == 1) {
                @branchHint(.likely);
                map[idx] = options.items[0];
            } else {
                @branchHint(.unlikely);
                if (options.items.len > 1) {
                    @branchHint(.likely);
                    std.sort.insertion(u16, @ptrCast(options.items), {}, std.sort.asc(u16));
                    if (self.canSpill(options.items[1], values[idx])) {
                        const new = options.items[0];
                        map[idx] = new;
                        for (options.items[1..]) |option| {
                            for (self.mapping) |*to| {
                                to.* = if (option == to.*) new else to.*;
                            }
                        }
                    }
                }
            }
        }

        const final_size = self.reduceMapping();
        for (0..self.shape.size) |idx| {
            map[idx] = self.mapping[map[idx].int()];
        }
        return final_size;
    }
};

pub const Info = struct {
    definition: [16]u16 = @splat(0),
    row_col: struct { u16, u16 },
    lowest: float,
    range_start: float,
    range_end: float,
    score: float,
    area: u32,
    contour: u16,
    cluster: Cluster,
    escapes: bool,
};

pub const ranges = struct {
    pub const Scaled = struct {
        min: float,
        low: float,
        high: float,

        pub fn start(self: Scaled, floor: float) float {
            return (self.min + floor) * self.low;
        }

        pub fn end(self: Scaled, floor: float) float {
            return (self.min + floor) * self.high;
        }
    };
};

pub fn generateInfo(shape: grid.Shape, range: anytype, seeds: []const usize, info: []Info, values: []const float, map: []const Cluster) void {
    const offsets: [4]isize = .{
        shape.offset(.left),
        shape.offset(.top),
        shape.offset(.right),
        shape.offset(.bottom),
    };
    for (info, 0..) |*cluster, idx| {
        cluster.* = .{
            .cluster = .any(@intCast(idx)),
            .row_col = undefined,
            .lowest = std.math.inf(float),
            .range_start = undefined,
            .range_end = undefined,
            .score = 0,
            .area = 0,
            .contour = 0,
            .escapes = false,
        };
    }
    for (seeds) |seed| {
        const cluster = &info[map[seed].int()];
        if (values[seed] < cluster.lowest) {
            cluster.lowest = values[seed];
            cluster.range_start = range.start(cluster.lowest);
            cluster.range_end = range.end(cluster.lowest);
            const row, const col = shape.unravel(seed);
            cluster.row_col = .{ @intCast(row), @intCast(col) };
        }
    }
    for (1..shape.rows - 1) |row| {
        for (1..shape.columns - 1) |col| {
            const idx = shape.ravel(row, col);
            if (map[idx] == .none) {
                @branchHint(.unpredictable);
                for (offsets) |offset| {
                    const cluster = &info[map[math.offset(usize, idx, offset) catch unreachable].int()];
                    if (cluster.cluster == .none) continue;
                    cluster.contour += 1;
                    if (values[idx] >= cluster.range_end) continue;
                    const base, const scale = .{ cluster.range_start, 16.0 / (cluster.range_end - cluster.range_start) };
                    const jdx = math.cast(usize, std.math.clamp(
                        @floor((values[idx] - base) * scale),
                        0.0,
                        16.0,
                    ));
                    cluster.definition[jdx] += 1;
                }
            } else {
                @branchHint(.likely);
                const cluster = &info[map[idx].int()];
                cluster.area += 1;
            }
        }
    }
    for (1..shape.rows - 1) |row| {
        for ([2]usize{ 1, shape.columns - 2 }) |col| {
            const cluster = &info[map[shape.ravel(row, col)].int()];
            cluster.contour += 1;
            cluster.definition[0] += 1;
            cluster.escapes = true;
        }
    }
    for (1..shape.columns - 1) |col| {
        for ([2]usize{ 1, shape.rows - 2 }) |row| {
            const cluster = &info[map[shape.ravel(row, col)].int()];
            cluster.contour += 1;
            cluster.definition[0] += 1;
            cluster.escapes = true;
        }
    }
    for (info) |*cluster| {
        var cum: u16 = 0;
        for (&cluster.definition) |*def| {
            cum += def.*;
            def.* = cum;
        }
    }
}

pub const ArrayInfo = std.MultiArrayList(Info);

// pub fn closedShapes(comptime shape: grid.Shape, values: *const shape.ComptimeGrid(float), mask: *shape.ComptimeGrid(bool), config: Config) void {
//     mask.* = @splat(@splat(true));
//     for (0..shape.rows) |row| {
//         mask[row][0] = false;
//         mask[row][shape.columns - 1] = false;
//     }
//     for (0..shape.columns) |col| {
//         mask[0][col] = false;
//         mask[shape.rows - 1][col] = false;
//     }
//     var changed = true;
//     var any = false;
//     while (changed) {
//         changed = false;
//         any = false;
//         for (1..shape.rows - 1) |row| {
//             for (1..shape.columns - 1) |col| {
//                 const value = values[row][col];
//                 const is_hole = mask[row][col];
//                 if (!is_hole) continue;
//                 const is_outside = blk: {
//                     const left = col - 1;
//                     const top = row - 1;
//                     const row_offsets: [4]usize = .{ 0, 1, 2, 1 };
//                     const col_offsets: [4]usize = .{ 1, 0, 1, 2 };
//                     for (row_offsets, col_offsets) |row_offset, col_offset| {
//                         if (mask[top + row_offset][left + col_offset]) continue;
//                         if (
//                         // zig fmt: off
//                             value <= config.min or
//                             values[top + row_offset][left + col_offset] <= value + config.decrease or
//                             config.max < value
//                         // zig fmt: on
//                         ) break :blk true;
//                     }
//                     break :blk false;
//                 };
//                 mask[row][col] = !is_outside;
//                 changed = changed or is_outside;
//                 any = any or !is_outside;
//             }
//         }
//     }
// }
