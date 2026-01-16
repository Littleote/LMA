const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Header = packed struct(u64) {
    start: u32,
    size: u14,
    epoch: u18,
};

pub const Config = struct {
    version: usize,
    tag: []const u8,
    extra: ?[]const u8 = null,
    value: []const u8 = "value",
    packet: ?[]const u8 = null,
};

pub const Search = enum {
    at_least,
    exact,
    at_most,
};

pub const IteratorMode = union(enum) {
    limited: void,
    unlimited: void,
    until: usize,
};

fn arrayListChild(T: type) type {
    return @typeInfo(@FieldType(T, "items")).pointer.child;
}

pub fn Segmented(T: type, comptime config: Config) type {
    return struct {
        const Self = @This();

        pub const Iterator = struct {
            const Elem = arrayListChild(@FieldType(T, config.value));

            data: *const T,
            chain: ?*const T,
            end: ?usize,
            epoch: u32,
            header: ?u32,

            pub fn init(data: *const T, epoch: usize, end: ?usize) @This() {
                return .{
                    .data = data,
                    .chain = null,
                    .epoch = @intCast(epoch),
                    .header = if (data.segments.epochIndex(epoch, .at_least)) |value| @intCast(value) else null,
                    .end = end,
                };
            }

            pub fn next(self: *@This()) ?[]Elem {
                if (self.end) |end| if (end <= self.epoch) return null;
                defer self.epoch += 1;
                const header_idx = if (self.header) |header| header else blk: {
                    self.data = self.chain orelse return &.{};
                    self.chain = null;
                    if (self.epoch > self.data.header.items[0].epoch) {
                        self.epoch -= 86400;
                        if (self.end) |*end| end.* -= 86400;
                    }
                    self.header = if (self.data.segments.epochIndex(self.epoch, .at_least)) |value| @intCast(value) else null;
                    break :blk self.header orelse return &.{};
                };
                const header = self.data.header.items[header_idx];
                if (header.epoch == self.epoch) {
                    self.header = if (header_idx + 1 >= self.data.header.items.len) null else header_idx + 1;
                    return @field(self.data, config.value).items[header.start..][0..header.size];
                }
                return &.{};
            }
        };

        pub fn append(self: *Self, other: *const Self) error{OutOfMemory}!*T {
            const data: *T = @alignCast(@fieldParentPtr("segments", self));
            const extra_data: *const T = @alignCast(@fieldParentPtr("segments", other));

            const same_day = data.header.items[data.header.items.len - 1].epoch < extra_data.header.items[0].epoch;
            const old_len = data.header.items.len;

            try data.header.appendSlice(data.gpa, extra_data.header.items);
            if (config.extra) |extra| try @field(data, extra).appendSlice(data.gpa, @field(extra_data, extra).items);
            try @field(data, config.value).appendSlice(data.gpa, @field(extra_data, config.value).items);
            if (config.packet) |packet| try @field(data, packet).appendSlice(data.gpa, @field(extra_data, packet).items);

            if (!same_day) {
                for (old_len..data.header.items.len) |idx| {
                    data.header.items[idx].epoch += 24 * 60 * 60;
                }
            }
            return data;
        }

        pub fn epochIndex(self: *const Self, epoch: usize, search: Search) ?usize {
            const data: *const T = @alignCast(@fieldParentPtr("segments", self));
            const headers = data.header.items;

            // Shortcircuit for the empty case
            if (headers.len == 0) return null;

            // Binary search as epochs should be sorted
            var low: usize = 0;
            var high: usize = headers.len;
            var size: usize = high - low;

            while (size > 1) {
                const probe = low + @divFloor(size, 2);
                if (headers[probe].epoch < epoch) {
                    low = probe + 1;
                } else if (epoch < headers[probe].epoch) {
                    high = probe;
                } else {
                    return probe;
                }
                size = high - low;
            }
            low = high - 1;
            return if (headers[low].epoch < epoch) switch (search) {
                .at_least => if (high == headers.len) null else high,
                .at_most => low,
                .exact => null,
            } else if (epoch < headers[low].epoch) switch (search) {
                .at_least => low,
                .at_most => if (low == 0) null else low - 1,
                .exact => null,
            } else low;
        }

        pub fn epochRange(self: *const Self, start: usize, end: usize) T {
            std.debug.assert(start < end);
            const data: *const T = @alignCast(@fieldParentPtr("segments", self));
            var view: T = .init(Allocator.failing);

            const start_idx = self.epochIndex(start, .at_least) orelse return view;
            const end_idx = (self.epochIndex(end - 1, .at_most) orelse return view) + 1;
            if (start_idx == end_idx) return view;

            view.header.items = data.header.items[start_idx..end_idx];
            if (config.extra) |extra| @field(view, extra).items = @field(data, extra).items[start_idx..end_idx];
            @field(view, config.value) = @field(data, config.value);
            if (config.packet) |packet| @field(view, packet) = @field(data, packet);

            return view;
        }

        pub fn epochIterator(self: *const Self, start: ?usize, mode: IteratorMode) Iterator {
            const data: *const T = @alignCast(@fieldParentPtr("segments", self));
            return .init(
                data,
                start orelse data.header.items[0].epoch,
                switch (mode) {
                    .unlimited => null,
                    .limited => if (data.header.items.len > 0) data.header.getLast().epoch else 0,
                    .until => |value| value,
                },
            );
        }

        pub fn copy(self: *const Self, gpa: Allocator) error{OutOfMemory}!T {
            const old_data: *const T = @alignCast(@fieldParentPtr("segments", self));
            var new_data: T = .init(gpa);
            errdefer new_data.deinit();

            new_data.header = try old_data.header.clone(gpa);
            if (config.extra) |extra| @field(new_data, extra) = try @field(old_data, extra).clone(gpa);
            @field(new_data, config.value) = try @field(old_data, config.value).clone(gpa);
            if (config.packet) |packet| @field(new_data, packet) = try @field(old_data, packet).clone(gpa);

            return new_data;
        }

        test Self {
            comptime {
                // Headers are present
                if (!@hasField(T, "header")) {
                    @compileError("Missing mandatory field \"header\" for segmented type " ++ @typeName(T));
                } else if (@FieldType(T, "header") != std.ArrayList(Header)) {
                    @compileError("Wrong type for \"header\" field for segmented type " ++ @typeName(T));
                }
                if (config.extra) |extra| {
                    if (!@hasField(T, extra)) {
                        @compileError("Missing mandatory field \"" ++ extra ++ "\" for segmented type " ++ @typeName(T));
                    }
                }

                // Values are present
                if (!@hasField(T, config.value)) {
                    @compileError("Missing mandatory field \"" ++ config.value ++ "\" for segmented type " ++ @typeName(T));
                }
                if (config.packet) |packet| {
                    if (!@hasField(T, packet)) {
                        @compileError("Missing mandatory field \"" ++ packet ++ "\" for segmented type " ++ @typeName(T));
                    }
                }

                // Extra fields are present
                if (!@hasField(T, "gpa")) {
                    @compileError("Missing mandatory field \"gpa\" for segmented type " ++ @typeName(T));
                } else if (@FieldType(T, "gpa") != Allocator) {
                    @compileError("Wrong type for \"gpa\" field for segmented type " ++ @typeName(T));
                }
                if (!@hasField(T, "segments")) {
                    @compileError("Missing mandatory field \"segments\" for segmented type " ++ @typeName(T));
                } else if (@FieldType(T, "segments") != Self) {
                    @compileError("Wrong type for \"segments\" field for segmented type " ++ @typeName(T));
                }
            }
        }
    };
}

const Dummy = struct {
    pub const dummy_header: Header = .{ .start = 32, .size = 10, .epoch = 7 };
    pub fn dummy_epoch(epoch: usize) Header {
        return .{ .start = 69, .size = 71, .epoch = @intCast(epoch) };
    }

    pub const Extra = extern struct {
        value: u32,
        pub const dummy: Extra = .{ .value = 48957317 };
    };

    pub const Value = struct {
        value: u32,
        pub const dummy: Value = .{ .value = 8445671 };
    };

    pub const Packet = extern struct {
        value: u32,
        pub const dummy: Packet = .{ .value = 16856178 };
    };

    segments: Segmented(Dummy, .{
        .extra = "extra",
        .value = "val",
        .packet = "packet",
        .tag = "dummy",
        .version = 0,
    }) = .{},

    header: std.ArrayList(Header) = .empty,
    extra: std.ArrayList(Extra) = .empty,
    val: std.ArrayList(Value) = .empty,
    packet: std.ArrayList(Packet) = .empty,
    gpa: Allocator,

    pub fn init(gpa: Allocator) Dummy {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Dummy) void {
        self.header.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.val.deinit(self.gpa);
        self.packet.deinit(self.gpa);
    }

    pub fn eql(self: *const Dummy, other: *const Dummy, comptime field: []const u8) bool {
        const Slice = @FieldType(@FieldType(Dummy, field), "items");
        const T = @typeInfo(Slice).pointer.child;
        const lhs: []const T = @field(self, field).items;
        const rhs: []const T = @field(other, field).items;
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |left, right| {
            if (std.meta.eql(left, right)) {
                @branchHint(.likely);
            } else {
                @branchHint(.unlikely);
                return false;
            }
        }
        return true;
    }
};

test Dummy {
    var dummy: Dummy = .init(std.testing.allocator);
    defer dummy.deinit();
    _ = dummy.segments;
}

test "copy" {
    var origin: Dummy = .init(std.testing.allocator);
    defer origin.deinit();

    try origin.header.appendNTimes(origin.gpa, Dummy.dummy_header, 10);
    try origin.extra.appendNTimes(origin.gpa, .dummy, 10);
    try origin.val.appendNTimes(origin.gpa, .dummy, 100);
    try origin.packet.appendNTimes(origin.gpa, .dummy, 100);

    var dest = try origin.segments.copy(origin.gpa);
    defer dest.deinit();

    try std.testing.expect(Dummy.eql(&origin, &dest, "header"));
    try std.testing.expect(Dummy.eql(&origin, &dest, "extra"));
    try std.testing.expect(Dummy.eql(&origin, &dest, "val"));
    try std.testing.expect(Dummy.eql(&origin, &dest, "packet"));
}

test "epochIndex" {
    var dummy: Dummy = .init(std.testing.allocator);
    defer dummy.deinit();

    // Empty
    try std.testing.expect(dummy.segments.epochIndex(1, .at_most) == null);
    try std.testing.expect(dummy.segments.epochIndex(1, .exact) == null);
    try std.testing.expect(dummy.segments.epochIndex(1, .at_least) == null);

    const epochs = [_]usize{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try dummy.header.ensureTotalCapacityPrecise(dummy.gpa, epochs.len);
    for (epochs) |epoch| {
        dummy.header.appendAssumeCapacity(Dummy.dummy_epoch(epoch));
    }

    // Below range
    try std.testing.expect(dummy.segments.epochIndex(0, .at_most) == null);
    try std.testing.expect(dummy.segments.epochIndex(0, .at_least) == 0);

    // Above range
    try std.testing.expect(dummy.segments.epochIndex(25, .at_most) == 10);
    try std.testing.expect(dummy.segments.epochIndex(25, .at_least) == null);

    // In range
    try std.testing.expect(dummy.segments.epochIndex(9, .at_most) == 3);
    try std.testing.expect(dummy.segments.epochIndex(9, .exact) == null);
    try std.testing.expect(dummy.segments.epochIndex(9, .at_least) == 4);

    // Match
    try std.testing.expect(dummy.segments.epochIndex(12, .at_most) == 6);
    try std.testing.expect(dummy.segments.epochIndex(12, .exact) == 6);
    try std.testing.expect(dummy.segments.epochIndex(12, .at_least) == 6);
}

test "epochRange" {
    var dummy: Dummy = .init(std.testing.allocator);
    defer dummy.deinit();

    // Empty
    try std.testing.expect(dummy.segments.epochRange(1, 3).header.items.len == 0);

    const epochs = [_]usize{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try dummy.header.ensureTotalCapacityPrecise(dummy.gpa, epochs.len);
    for (epochs) |epoch| {
        dummy.header.appendAssumeCapacity(Dummy.dummy_epoch(epoch));
    }
    try dummy.extra.appendNTimes(dummy.gpa, .dummy, epochs.len);

    // Below range
    try std.testing.expect(dummy.segments.epochRange(0, 1).header.items.len == 0);

    // Above range
    try std.testing.expect(dummy.segments.epochRange(25, 30).header.items.len == 0);

    // In range
    const view1 = dummy.segments.epochRange(7, 17);
    try std.testing.expect(view1.header.items.len == 7);
    try std.testing.expect(view1.header.items[0].epoch == 8);
    try std.testing.expect(view1.header.getLast().epoch == 15);

    // Match
    const view2 = dummy.segments.epochRange(4, 14);
    try std.testing.expect(view2.header.items.len == 7);
    try std.testing.expect(view2.header.items[0].epoch == 4);
    try std.testing.expect(view2.header.getLast().epoch == 13);
}
