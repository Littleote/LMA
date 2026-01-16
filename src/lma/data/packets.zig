const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const builtin = @import("builtin");

pub const Header = packed struct(u64) {
    padding: bool = false,
    start: u31,
    size: u14,
    epoch: u18,
};

pub const Config = struct {
    version: usize,
    tag: []const u8,
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

pub fn Packets(Elem: type) type {
    return struct {
        const Self = @This();

        headers: std.ArrayList(Header) = .empty,
        array: std.ArrayList(Elem) = .empty,
        allocator: Allocator,

        // pub const Iterator = struct {
        //     data: *const Self,
        //     end: ?usize,
        //     epoch: u32,
        //     header: ?u32,

        //     pub fn init(data: *const Self, epoch: usize, end: ?usize) @This() {
        //         return .{
        //             .data = data,
        //             .chain = null,
        //             .epoch = @intCast(epoch),
        //             .header = if (data.segments.epochIndex(epoch, .at_least)) |value| @intCast(value) else null,
        //             .end = end,
        //         };
        //     }

        //     pub fn next(self: *@This()) ?[]Elem {
        //         if (self.end) |end| if (end <= self.epoch) return null;
        //         defer self.epoch += 1;
        //         const header_idx = if (self.header) |header| header else blk: {
        //             self.data = self.chain orelse return &.{};
        //             self.chain = null;
        //             if (self.epoch > self.data.header.items[0].epoch) {
        //                 self.epoch -= 86400;
        //                 if (self.end) |*end| end.* -= 86400;
        //             }
        //             self.header = if (self.data.segments.epochIndex(self.epoch, .at_least)) |value| @intCast(value) else null;
        //             break :blk self.header orelse return &.{};
        //         };
        //         const header = self.data.header.items[header_idx];
        //         if (header.epoch == self.epoch) {
        //             self.header = if (header_idx + 1 >= self.data.header.items.len) null else header_idx + 1;
        //             return self.data.array.items[header.start..][0..header.size];
        //         }
        //         return &.{};
        //     }
        // };
        pub fn init(gpa: Allocator) Self {
            return .{ .allocator = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.headers.deinit(self.allocator);
            self.array.deinit(self.allocator);
        }

        pub const ParseError = (Reader.Error || Allocator.Error || error{ InvalidHeader, InvalidValue, UnsupportedVersion });

        pub fn toBin(self: *const Self, w: *Writer) Writer.Error!void {
            // File Header
            try w.print("LMA-{s}-{d:0>3}\n", .{ Elem.name, Elem.version });
            try w.writeInt(usize, self.headers.items.len, .little);
            try w.writeInt(usize, self.array.items.len, .little);
            for (self.headers.items) |header| {
                try w.writeStruct(header, .little);
                try w.writeSliceEndian(Elem, self.array.items[header.start..][0..header.size], .little);
            }
            try w.flush();
        }

        pub fn fromBin(self: *Self, r: *Reader) Self.ParseError!void {
            const version: u8 = blk: {
                const header_len = comptime 3 + 1 + Elem.name.len + 1 + 3 + 1;
                const header = try r.take(header_len);
                var header_match: bool = true;
                header_match &= std.mem.eql(u8, header[0..4], "LMA-");
                header_match &= std.mem.eql(u8, header[4..][0..Elem.name.len], Elem.name);
                header_match &= header[4 + Elem.name.len] == '-';
                const version_string = header[5 + Elem.name.len ..][0..3];
                header_match &= header[header.len - 1] == '\n';
                if (!header_match) return error.InvalidHeader;
                break :blk std.fmt.parseInt(u8, version_string, 10) catch return error.InvalidHeader;
            };
            switch (version) {
                1 => {
                    const headers = try r.takeInt(usize, .little);
                    const elements = try r.takeInt(usize, .little);
                    try self.headers.ensureTotalCapacityPrecise(self.allocator, headers);
                    errdefer self.headers.deinit(self.allocator);
                    self.headers.items.len = headers;
                    try self.array.ensureTotalCapacityPrecise(self.allocator, elements);
                    errdefer self.array.deinit(self.allocator);
                    self.array.items.len = elements;

                    for (0..headers) |idx| {
                        self.headers.items[idx] = try r.takeStruct(Header, .little);
                        const header = self.headers.items[idx];
                        try r.readSliceEndian(Elem, self.array.items[header.start..][0..header.size], .little);
                    }
                },
                else => return error.UnsupportedVersion,
            }
        }

        pub fn toCsv(self: *const Self, w: *Writer, separator: ?u8) Writer.Error!void {
            const sep = separator orelse ',';
            try w.print(Elem.csvHeader, .{sep});
            for (self.header.items) |header| {
                for (self.array[header.start..][0..header.size]) |value| {
                    try value.toCsv(w, header, sep);
                }
            }
            try w.flush();
        }

        pub fn fromCsv(self: *Self, r: *Reader, separator: ?u8) Self.ParseError!void {
            _ = self;
            _ = r;
            _ = separator;
        }

        pub fn copy(self: *const Self, gpa: Allocator) error{OutOfMemory}!Self {
            var new_data: Self = .init(gpa);
            errdefer new_data.deinit();

            new_data.headers = try self.headers.clone(gpa);
            new_data.array = try self.array.clone(gpa);

            return new_data;
        }

        // pub fn append(self: *Self, other: *const Self) error{OutOfMemory}!T {
        //     const data: *T = @alignCast(@fieldParentPtr("segments", self));
        //     const extra_data: *const T = @alignCast(@fieldParentPtr("segments", other));

        //     const same_day = data.header.last().epoch < extra_data.header.items[0].epoch;
        //     const old_len = data.header.items.len;

        //     data.header.appendSlice(data.gpa, extra_data.header.items);
        //     data.array.appendSlice(data.gpa, extra_data.array.items);

        //     if (!same_day) {
        //         for (old_len..data.header.items.len) |idx| {
        //             data.header.items[idx].epoch += 24 * 60 * 60;
        //         }
        //     }
        // }

        pub fn epochIndex(self: *const Self, epoch: usize, search: Search) ?usize {
            const headers = self.headers.items;

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

        pub fn epochRange(self: *const Self, start: usize, end: usize) Self {
            std.debug.assert(start < end);
            var view: Self = .init(Allocator.failing);

            const start_idx = self.epochIndex(start, .at_least) orelse return view;
            const end_idx = (self.epochIndex(end - 1, .at_most) orelse return view) + 1;
            if (start_idx == end_idx) return view;

            view.headers.items = self.headers.items[start_idx..end_idx];
            view.array = self.array;

            return view;
        }

        // pub fn epochIterator(self: *const Self, start: ?usize, mode: IteratorMode) Iterator {
        //     const data: *const T = @alignCast(@fieldParentPtr("segments", self));
        //     return .init(
        //         data,
        //         start orelse data.header.items[0].epoch,
        //         switch (mode) {
        //             .unlimited => null,
        //             .limited => if (data.header.items.len > 0) data.header.getLast().epoch else 0,
        //             .until => |value| value,
        //         },
        //     );
        // }
    };
}

const Dummy = extern struct {
    value: u32,

    inline fn toCsv(self: *const Dummy, w: *Writer, header: Header, sep: u8) Writer.Error!void {
        try w.print("{[seconds]d}{[separator]c}{[value]d}\n", .{
            .seconds = header.epoch,
            .separator = sep,
            .value = self.value,
        });
    }

    inline fn fromCsv(self: *Dummy, line: []u8, sep: u8) error.InvalidValue!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, sep);
        const epoch = std.fmt.parseInt(usize, iterator.next() orelse return error.InvalidValue, 10) catch return error.InvalidValue;
        self.value = std.fmt.parseInt(u32, iterator.next() orelse return error.InvalidValue, 10) catch return error.InvalidValue;
        return epoch;
    }

    pub const name = "dummy";
    pub const version = 1;
};

fn randomPackets(data: *Packets(Dummy), headers: usize, size: usize) !void {
    try data.headers.ensureTotalCapacity(data.allocator, headers);
    try data.array.ensureTotalCapacity(data.allocator, headers * size);
    for (0..10) |i| {
        data.headers.appendAssumeCapacity(.{
            .epoch = @intCast(i),
            .start = @intCast(size * i),
            .size = @intCast(size),
        });
    }
    data.array.items.len = headers * size;
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    random.bytes(@ptrCast(@alignCast(data.array.items)));
}

test "bin format round trip" {
    var data: Packets(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    try randomPackets(&data, 10, 5);

    // Write to a buffer and read from it onto a new packet
    var writer: Writer.Allocating = .init(data.allocator);
    defer writer.deinit();
    try data.toBin(&writer.writer);

    var read_data: Packets(Dummy) = .init(std.testing.allocator);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try read_data.fromBin(&reader);

    try std.testing.expect(std.mem.eql(Header, data.headers.items, read_data.headers.items));
    try std.testing.expect(std.mem.eql(
        u8,
        @ptrCast(@alignCast(data.array.items)),
        @ptrCast(@alignCast(read_data.array.items)),
    ));
}

test "copy" {
    var origin: Packets(Dummy) = .init(std.testing.allocator);
    defer origin.deinit();
    try randomPackets(&origin, 10, 5);

    var dest = try origin.copy(origin.allocator);
    defer dest.deinit();

    try std.testing.expect(std.mem.eql(Header, origin.headers.items, dest.headers.items));
    try std.testing.expect(std.mem.eql(
        u8,
        @ptrCast(@alignCast(origin.array.items)),
        @ptrCast(@alignCast(dest.array.items)),
    ));
}

test "epochIndex" {
    var data: Packets(Dummy) = .init(std.testing.allocator);
    defer data.deinit();

    // Empty
    try std.testing.expect(data.epochIndex(1, .at_most) == null);
    try std.testing.expect(data.epochIndex(1, .exact) == null);
    try std.testing.expect(data.epochIndex(1, .at_least) == null);

    const epochs = [_]usize{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try data.headers.ensureTotalCapacityPrecise(data.allocator, epochs.len);
    for (epochs) |epoch| {
        data.headers.appendAssumeCapacity(.{
            .epoch = @intCast(epoch),
            .start = 0,
            .size = 0,
        });
    }

    // Below range
    try std.testing.expect(data.epochIndex(0, .at_most) == null);
    try std.testing.expect(data.epochIndex(0, .at_least) == 0);

    // Above range
    try std.testing.expect(data.epochIndex(25, .at_most) == 10);
    try std.testing.expect(data.epochIndex(25, .at_least) == null);

    // In range
    try std.testing.expect(data.epochIndex(9, .at_most) == 3);
    try std.testing.expect(data.epochIndex(9, .exact) == null);
    try std.testing.expect(data.epochIndex(9, .at_least) == 4);

    // Match
    try std.testing.expect(data.epochIndex(12, .at_most) == 6);
    try std.testing.expect(data.epochIndex(12, .exact) == 6);
    try std.testing.expect(data.epochIndex(12, .at_least) == 6);
}

test "epochRange" {
    var data: Packets(Dummy) = .init(std.testing.allocator);
    defer data.deinit();

    // Empty
    try std.testing.expect(data.epochRange(1, 3).headers.items.len == 0);

    const epochs = [_]usize{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try data.headers.ensureTotalCapacityPrecise(data.allocator, epochs.len);
    for (epochs) |epoch| {
        data.headers.appendAssumeCapacity(.{
            .epoch = @intCast(epoch),
            .start = 0,
            .size = 0,
        });
    }

    // Below range
    try std.testing.expect(data.epochRange(0, 1).headers.items.len == 0);

    // Above range
    try std.testing.expect(data.epochRange(25, 30).headers.items.len == 0);

    // In range
    const view1 = data.epochRange(7, 17);
    try std.testing.expect(view1.headers.items.len == 7);
    try std.testing.expect(view1.headers.items[0].epoch == 8);
    try std.testing.expect(view1.headers.getLast().epoch == 15);

    // Match
    const view2 = data.epochRange(4, 14);
    try std.testing.expect(view2.headers.items.len == 7);
    try std.testing.expect(view2.headers.items[0].epoch == 4);
    try std.testing.expect(view2.headers.getLast().epoch == 13);
}
