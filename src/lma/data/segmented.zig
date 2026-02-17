const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const builtin = @import("builtin");
const lma = @import("../lma.zig");
const common = lma.common;

pub const Header = common.SubSlice;

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
    /// Iterate until the last epoch in the data
    all: void,
    until_epoch: usize,

    /// Iterate until the specified epoch
    pub fn until(epoch: usize) IteratorMode {
        return .{ .until_epoch = epoch };
    }
};

pub fn Segmented(Elem: type) type {
    return struct {
        const Self = @This();

        first_epoch: u64 = 0,
        headers: std.ArrayList(Header) = .empty,
        array: std.ArrayList(Elem) = .empty,
        allocator: Allocator,

        pub fn init(gpa: Allocator) Self {
            return .{ .allocator = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.headers.deinit(self.allocator);
            self.array.deinit(self.allocator);
        }

        pub fn empty(self: *const Self) bool {
            return self.headers.items.len == 0 or self.array.items.len == 0;
        }

        pub const ParseError = (Reader.DelimiterError || Allocator.Error || error{ InvalidHeader, InvalidValue, UnsupportedVersion });

        /// Write segments to custom binary format
        pub fn toBin(self: *const Self, w: *Writer) Writer.Error!void {
            // File Header
            try w.print("LMA-{s}-{d:0>3}\n", .{ Elem.bin_tag, Elem.bin_version });
            try w.writeInt(u64, self.first_epoch, .little);
            try w.writeInt(u32, @intCast(self.headers.items.len), .little);
            try w.writeInt(u32, @intCast(self.array.items.len), .little);
            for (self.headers.items) |header| {
                try w.writeStruct(header, .little);
                try w.writeSliceEndian(Elem, self.array.items[header.start..][0..header.size], .little);
            }
            try w.flush();
        }

        /// Read segments from custom binary format
        pub fn fromBin(self: *Self, r: *Reader) Self.ParseError!void {
            const version: u8 = blk: {
                const header_len = comptime 3 + 1 + Elem.bin_tag.len + 1 + 3 + 1;
                const header = try r.take(header_len);
                var header_match: bool = true;
                header_match &= std.mem.eql(u8, header[0..4], "LMA-");
                header_match &= std.mem.eql(u8, header[4..][0..Elem.bin_tag.len], Elem.bin_tag);
                header_match &= header[4 + Elem.bin_tag.len] == '-';
                const version_string = header[5 + Elem.bin_tag.len ..][0..3];
                header_match &= header[header.len - 1] == '\n';
                if (!header_match) return error.InvalidHeader;
                break :blk std.fmt.parseInt(u8, version_string, 10) catch return error.InvalidHeader;
            };
            switch (version) {
                1 => {
                    self.first_epoch = try r.takeInt(u64, .little);
                    const headers = try r.takeInt(u32, .little);
                    const elements = try r.takeInt(u32, .little);
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

        /// Write segmented data to a CSV file
        /// When delimiter is null, use a comma (`,`)
        pub fn toCsv(self: *const Self, w: *Writer, delimiter: ?u8) Writer.Error!void {
            const del = delimiter orelse ',';
            for (Elem.csv_columns, 1..) |column, idx| {
                try w.writeAll(column);
                try w.writeByte(if (idx == Elem.csv_columns.len) '\n' else del);
            }
            for (self.headers.items, self.first_epoch..) |header, epoch| {
                for (self.array.items[header.start..][0..header.size]) |value| {
                    try value.toCsv(w, epoch, del);
                }
            }
            try w.flush();
        }

        /// Read data from CSV file as segments
        /// When delimiter is null, the most common delimiters are tested
        pub fn fromCsv(self: *Self, r: *Reader, delimiter: ?u8) Self.ParseError!void {
            // Read CSV header
            const csv_header = try r.takeDelimiter('\n') orelse return error.InvalidHeader;
            const del = delimiter orelse blk: {
                const common_delimiters = [_]u8{ ',', ';', '\t', '|' };
                for (common_delimiters) |del| {
                    const columns = 1 + std.mem.countScalar(u8, csv_header, del);
                    if (columns == Elem.csv_columns.len) break :blk del;
                }
                return error.InvalidHeader;
            };

            // Short-circuit for empty csv
            const first_line = r.peekDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            var first_value: Elem = undefined;
            self.first_epoch = try first_value.fromCsv(first_line, del);
            var last_epoch: u64 = self.first_epoch;

            // Parse entries
            errdefer self.deinit();
            var header = try self.headers.addOne(self.allocator);
            // Start first header info
            header.* = .{
                .start = @intCast(self.array.items.len),
                .size = 0,
            };
            while (try r.takeDelimiter('\n')) |line| {
                const value = try self.array.addOne(self.allocator);
                const current_epoch: u64 = try value.fromCsv(line, del);
                if (last_epoch != current_epoch) {
                    // Finish current and start next header info
                    const last_len: u32 = @intCast(self.array.items.len - 1);
                    header.size = last_len - header.start;
                    try self.headers.appendNTimes(self.allocator, .{ .start = last_len, .size = 0 }, current_epoch - last_epoch);
                    last_epoch = current_epoch;
                    header = &self.headers.items[self.headers.items.len - 1];
                }
            }
            // Finish last header info
            header.size = @intCast(self.array.items.len - header.start);
        }

        test "csv columns" {
            if (!@hasDecl(Elem, "dummyValue")) return error.SkipZigTest;
            var data: Segmented(Elem) = .init(std.testing.allocator);
            defer data.deinit();
            try randomSegments(Elem, &data, &orderedEpochs(3), 5);

            // Write to a buffer and read from it to check for issues with the CSV format
            var writer: Writer.Allocating = .init(data.allocator);
            defer writer.deinit();
            const del = ',';
            try data.toCsv(&writer.writer, del);

            var reader: Reader = .fixed(writer.written());
            const csv_header = try reader.takeDelimiter('\n') orelse {
                std.log.err("Missing CSV header in buffer\n{s}\n", .{writer.written()});
                return error.InvalidHeader;
            };
            const columns_delimiters = Elem.csv_columns.len - 1;
            if (std.mem.countScalar(u8, csv_header, del) != columns_delimiters) {
                std.log.err("Delimiter used in header\n{s}\n", .{csv_header});
                return error.InvalidHeader;
            }
            var rows: usize = 0;
            while (try reader.takeDelimiter('\n')) |line| {
                if (std.mem.countScalar(u8, line, del) != columns_delimiters) {
                    std.log.err("Column number mismatch between header\n{s}\nAnd entry\n{s}\n", .{ csv_header, line });
                    return error.InvalidValue;
                }
                rows += 1;
            }
            if (rows != 3 * 5) {
                std.log.err("Row count mismatch\n{s}\n", .{writer.written()});
                return error.InvalidValue;
            }
        }

        test "csv format round trip" {
            if (!@hasDecl(Elem, "dummyValue")) return error.SkipZigTest;
            var data: Segmented(Elem) = .init(std.testing.allocator);
            defer data.deinit();
            try randomSegments(Elem, &data, &orderedEpochs(10), 5);

            // Write to a buffer and read from it with a new Segmented instance
            var writer: Writer.Allocating = .init(data.allocator);
            defer writer.deinit();
            try data.toCsv(&writer.writer, null);

            var read_data: Segmented(Elem) = .init(std.testing.allocator);
            defer read_data.deinit();
            var reader: Reader = .fixed(writer.written());
            read_data.fromCsv(&reader, null) catch |err| {
                std.log.err("Failed to parse\n{s}\n", .{writer.written()});
                return err;
            };

            try std.testing.expect(std.mem.eql(Header, data.headers.items, read_data.headers.items));
            for (data.array.items, read_data.array.items) |original, read| {
                std.testing.expect(Elem.approxEql(original, read)) catch |err| {
                    std.log.err("Entry\n{any}\nBecame\n{any}.\n", .{ original, read });
                    return err;
                };
            }
        }

        /// Create a copy of the data
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

        /// Find the index of a header with a specific epoch
        /// If no valid index is found, return null instead
        pub fn epochIndex(self: *const Self, epoch: u64, comptime search: Search) ?u32 {
            const headers = self.headers.items;

            // Short-circuit for the empty case
            if (headers.len == 0) return null;

            if (epoch < self.first_epoch) return switch (search) {
                .at_least => 0,
                .exact, .at_most => null,
            };
            if (self.first_epoch + self.headers.items.len <= epoch) return switch (search) {
                .at_least, .exact => null,
                .at_most => @intCast(self.headers.items.len - 1),
            };

            return @intCast(epoch - self.first_epoch);
        }

        /// Create a view of the data, containing the specified epoch range
        /// The returned view is form start inclusive to end exclusive
        pub fn epochRange(self: *const Self, start: usize, end: usize) Self {
            std.debug.assert(start < end);
            var view: Self = .init(Allocator.failing);

            const start_idx = self.epochIndex(start, .at_least) orelse return view;
            const end_idx = (self.epochIndex(end - 1, .at_most) orelse return view) + 1;
            if (start_idx == end_idx) return view;

            view.first_epoch = self.first_epoch + start_idx;
            view.headers.items = self.headers.items[start_idx..end_idx];
            view.array = self.array;

            return view;
        }

        /// Iterate through all epochs from start to the given limit
        /// Epochs that are empty or have no header for it, will yield an empty slice
        pub fn epochIterator(self: *const Self, start: ?usize, mode: IteratorMode) Iterator {
            if (self.headers.items.len == 0 and start == null) return .init(self, 0, 0);
            return .init(
                self,
                start orelse self.first_epoch,
                switch (mode) {
                    .all => self.first_epoch + self.headers.items.len,
                    .until_epoch => |epoch| epoch,
                },
            );
        }

        pub const Iterator = struct {
            data: *const Self,
            epoch: u64,
            header: ?u32,
            end: u64,

            fn init(data: *const Self, epoch: u64, end: u64) @This() {
                return .{
                    .data = data,
                    .epoch = epoch,
                    .header = data.epochIndex(epoch, .exact),
                    .end = end,
                };
            }

            pub fn next(self: *@This()) ?[]Elem {
                if (self.end <= self.epoch) return null;
                defer self.epoch += 1;
                const header_idx = self.header orelse self.data.epochIndex(self.epoch, .exact) orelse return &.{};
                const header = self.data.headers.items[header_idx];
                self.header = if (header_idx + 1 >= self.data.headers.items.len) null else header_idx + 1;
                return header.getReference(Elem, self.data.array.items);
            }
        };

        /// Return the slice of values corresponding to the header at position `index`
        ///
        /// `index` must be either a valid index for headers or null
        pub fn valuesAt(self: *const Self, index: ?u32) []const Elem {
            if (index) |idx| {
                const header = self.headers.items[idx];
                return self.array.items[header.start..][0..header.size];
            }
            return &.{};
        }
    };
}

const Dummy = extern struct {
    value: u32,

    // CSV elements
    pub inline fn toCsv(self: Dummy, w: *Writer, epoch: u64, del: u8) Writer.Error!void {
        try w.print("{[seconds]d}{[delimiter]c}{[value]d}\n", .{
            .seconds = epoch,
            .delimiter = del,
            .value = self.value,
        });
    }

    pub inline fn fromCsv(self: *Dummy, line: []u8, del: u8) error{InvalidValue}!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const epoch = std.fmt.parseInt(usize, iterator.next() orelse return error.InvalidValue, 10) catch return error.InvalidValue;
        self.value = std.fmt.parseInt(u32, iterator.next() orelse return error.InvalidValue, 10) catch return error.InvalidValue;
        return epoch;
    }

    pub const csv_columns: []const []const u8 = &.{ "Epoch", "Value" };

    pub inline fn eql(first: Dummy, second: Dummy) bool {
        return first.value == second.value;
    }

    pub const approxEql = Dummy.eql;

    pub fn dummyValue(rand: std.Random) Dummy {
        return .{
            .value = rand.int(u32),
        };
    }

    pub const bin_tag = "dummy";
    pub const bin_version = 1;
};

inline fn orderedEpochs(comptime count: usize) [count]u64 {
    var buffer: [count]u64 = undefined;
    for (&buffer, 0..) |*elem, i| elem.* = i;
    return buffer;
}

fn randomSegments(Elem: type, data: *Segmented(Elem), epochs: []const u64, size: u32) !void {
    data.first_epoch = epochs[0];
    const last_epoch = epochs[epochs.len - 1] + 1;
    const epoch_count = last_epoch - data.first_epoch;
    try data.headers.ensureTotalCapacity(data.allocator, epoch_count);
    try data.array.ensureTotalCapacity(data.allocator, epochs.len * size);
    var epoch = data.first_epoch;
    for (epochs, 0..) |target_epoch, i| {
        while (epoch < target_epoch) : (epoch += 1) {
            data.headers.appendAssumeCapacity(.{ .start = @intCast(size * i), .size = 0 });
        }
        data.headers.appendAssumeCapacity(.{ .start = @intCast(size * i), .size = size });
        epoch += 1;
    }
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    for (data.array.addManyAsSliceAssumeCapacity(epochs.len * size)) |*element| {
        element.* = Elem.dummyValue(random);
    }
}

test "bin format round trip" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    try randomSegments(Dummy, &data, &.{ 2, 5, 9, 12, 13, 14, 15, 16, 18, 24 }, 5);

    // Write to a buffer and read from it with a new Segmented instance
    var writer: Writer.Allocating = .init(data.allocator);
    defer writer.deinit();
    try data.toBin(&writer.writer);

    var read_data: Segmented(Dummy) = .init(std.testing.allocator);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try read_data.fromBin(&reader);

    try std.testing.expect(data.first_epoch == read_data.first_epoch);
    try std.testing.expect(std.mem.eql(Header, data.headers.items, read_data.headers.items));
    for (data.array.items, read_data.array.items) |original, read| {
        try std.testing.expect(Dummy.eql(original, read));
    }
}

test "copy" {
    var origin: Segmented(Dummy) = .init(std.testing.allocator);
    defer origin.deinit();
    try randomSegments(Dummy, &origin, &orderedEpochs(10), 5);

    var dest = try origin.copy(origin.allocator);
    defer dest.deinit();

    try std.testing.expect(std.mem.eql(Header, origin.headers.items, dest.headers.items));
    for (origin.array.items, dest.array.items) |original, destination| {
        try std.testing.expect(Dummy.eql(original, destination));
    }
}

test "epochIndex" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();

    // Empty
    try std.testing.expect(data.epochIndex(1, .at_most) == null);
    try std.testing.expect(data.epochIndex(1, .exact) == null);
    try std.testing.expect(data.epochIndex(1, .at_least) == null);

    const epochs = [_]usize{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try randomSegments(Dummy, &data, &epochs, 0);

    // Below range
    try std.testing.expect(data.epochIndex(0, .at_most) == null);
    try std.testing.expect(data.epochIndex(0, .at_least) == 0);

    // Above range
    try std.testing.expect(data.epochIndex(25, .at_most) == 18);
    try std.testing.expect(data.epochIndex(25, .at_least) == null);

    // In range
    try std.testing.expect(data.epochIndex(12, .at_most) == 10);
    try std.testing.expect(data.epochIndex(12, .exact) == 10);
    try std.testing.expect(data.epochIndex(12, .at_least) == 10);
}

test "epochRange" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();

    // Empty
    try std.testing.expect(data.epochRange(1, 3).headers.items.len == 0);

    const epochs = [_]u64{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try randomSegments(Dummy, &data, &epochs, 0);

    // Below range
    try std.testing.expect(data.epochRange(0, 1).headers.items.len == 0);

    // Above range
    try std.testing.expect(data.epochRange(25, 30).headers.items.len == 0);

    // Outside both
    const view1 = data.epochRange(0, 30);
    try std.testing.expect(view1.first_epoch == 2);
    try std.testing.expect(view1.first_epoch + view1.headers.items.len == 21);

    // In range
    const view2 = data.epochRange(4, 14);
    try std.testing.expect(view2.first_epoch == 4);
    try std.testing.expect(view2.first_epoch + view2.headers.items.len == 14);
}

test "epochIterator" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    var iter: Segmented(Dummy).Iterator = undefined;
    var failed_buffer: [1]Dummy = undefined;
    const failed: []Dummy = &failed_buffer;

    // Empty
    iter = data.epochIterator(1, .until(3));
    try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 3);

    // Undefined lower bound
    iter = data.epochIterator(null, .until(5));
    try std.testing.expect(iter.next() == null);

    // Undefined upper bound
    iter = data.epochIterator(8, .all);
    try std.testing.expect(iter.next() == null);

    // Undefined bounds
    iter = data.epochIterator(null, .all);
    try std.testing.expect(iter.next() == null);

    const test_values = struct {
        pub const epochs = [_]u64{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
        pub fn contains(number: u64) bool {
            return std.mem.findScalar(u64, &epochs, number) != null;
        }
    };
    try randomSegments(Dummy, &data, &test_values.epochs, 5);

    // Below range
    iter = data.epochIterator(0, .until(1));
    try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 1);

    // Above range
    iter = data.epochIterator(25, .until(30));
    for (25..30) |_|
        try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 30);

    // Outside both
    iter = data.epochIterator(1, .until(23));
    for (1..23) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 23);

    // In range
    iter = data.epochIterator(4, .until(14));
    for (4..14) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 14);

    // Until the end
    iter = data.epochIterator(8, .all);
    for (8..21) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 21);

    // From the start
    iter = data.epochIterator(null, .until(10));
    for (2..10) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 10);

    // Full range
    iter = data.epochIterator(null, .all);
    for (2..21) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 21);
}

test "valuesAt" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    try randomSegments(Dummy, &data, &orderedEpochs(10), 5);

    try std.testing.expect(data.valuesAt(null).len == 0);
    for (data.array.items[10..15], data.valuesAt(2)) |sliced, located| {
        try std.testing.expect(Dummy.eql(sliced, located));
    }
}
