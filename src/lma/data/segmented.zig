const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const cast = lma.cast;
pub const Header = lma.index.SubSlice;

pub const Search = enum {
    at_least,
    exact,
    at_most,
};

pub const Shift = struct {
    forward: u32 = 0,
    backward: u32 = 0,
};

pub fn TestConfig(Elem: type) type {
    return struct {
        dummy: fn (std.Random) Elem,
        eql: fn (Elem, Elem) bool = defaultEql,
        approxEql: fn (Elem, Elem) bool = defaultEql,

        pub fn defaultEql(a: Elem, b: Elem) bool {
            return std.meta.eql(a, b);
        }
    };
}

pub const BinConfig = struct {
    tag: []const u8,
};

pub fn CsvConfig(Elem: type) type {
    return struct {
        columns: []const []const u8,
        read: fn (out: *Elem, line: []const u8, delimiter: u8) error{InvalidValue}!u64,
        write: fn (in: Elem, writer: *Writer, epoch: u64, delimiter: u8) Writer.Error!void,

        testing: ?TestConfig(Elem) = null,
    };
}

pub fn bin(Elem: type, comptime config: BinConfig) type {
    return struct {
        const List = Segmented(Elem);

        // HEADER: "LMA-{[tag]s}-{[hash]x:0>16}\n"
        //  tag = Elem.bin.tag
        //  hash = typeHash(Elem)
        const file_tag = std.fmt.comptimePrint("LMA-{[tag]s}", .{ .tag = config.tag });
        const file_header = std.fmt.comptimePrint("{[file_tag]s}-{[hash]x:0>16}\n", .{ .file_tag = file_tag, .hash = typeHash(Elem) });

        /// Write segments to custom binary format
        pub fn write(list: *const List, w: *Writer) Writer.Error!void {
            // File Header
            try w.writeAll(file_header);
            try w.writeInt(u64, list.start_epoch, .little);
            try w.writeInt(u32, @intCast(list.headers.items.len), .little);
            try w.writeInt(u32, @intCast(list.array.items.len), .little);

            var start: u32 = 0;
            for (list.headers.items) |header| {
                const saved_header: Header = .{ .start = start, .size = header.size };
                try w.writeStruct(saved_header, .little);
                try w.writeSliceEndian(Elem, header.getConst(Elem, list.array.items), .little);
                start += header.size;
            }
            try w.flush();
        }

        /// Read segments from custom binary format
        pub fn read(list: *List, r: *Reader) List.ParseError!void {
            innerRead(list, r) catch |e| return switch (e) {
                else => |err| err,
                error.EndOfStream => error.BadFile,
            };
        }

        fn readHeader(r: *Reader) List.ParseError!void {
            const header = r.take(file_header.len) catch |e| return switch (e) {
                error.ReadFailed => |err| err,
                error.EndOfStream => error.InvalidHeader,
            };

            if (std.mem.eql(u8, file_header, header)) return;
            return if (std.mem.eql(u8, file_tag, header[0..file_tag.len]))
                error.UnsupportedVersion
            else
                error.InvalidHeader;
        }

        pub fn innerRead(list: *List, r: *Reader) (error{EndOfStream} || List.ParseError)!void {
            try readHeader(r);

            list.start_epoch = try r.takeInt(u64, .little);
            const headers = try r.takeInt(u32, .little);
            const elements = try r.takeInt(u32, .little);

            try list.headers.ensureTotalCapacityPrecise(list.allocator, headers);
            errdefer list.headers.deinit(list.allocator);
            try list.array.ensureTotalCapacityPrecise(list.allocator, elements);
            errdefer list.array.deinit(list.allocator);

            for (0..headers) |_| {
                list.headers.appendAssumeCapacity(try r.takeStruct(Header, .little));
                const header = list.headers.last().?;
                const slice = list.array.addManyAsSliceAssumeCapacity(header.size);
                try r.readSliceEndian(Elem, slice, .little);
            }
        }
    };
}

pub fn csv(Elem: type, comptime config: CsvConfig(Elem)) type {
    return struct {
        const List = Segmented(Elem);
        const common_delimiters = [_]u8{ ',', ';', '\t', '|' };

        /// Write segmented data to a CSV file
        /// When delimiter is null, use a comma (`,`)
        pub fn write(list: *const List, w: *Writer, delimiter: ?u8) Writer.Error!void {
            const del = delimiter orelse ',';
            for (config.columns, 1..) |column, idx| {
                try w.writeAll(column);
                try w.writeByte(if (idx == config.columns.len) '\n' else del);
            }
            for (list.headers.items, 0..) |header, epoch_delta| {
                const epoch: u64 = list.start_epoch + epoch_delta;
                for (list.array.items[header.start..][0..header.size]) |value| {
                    try config.write(value, w, epoch, del);
                }
            }
            try w.flush();
        }

        /// Read data from CSV file as segments
        /// When delimiter is null, the most common delimiters are tested
        pub fn read(list: *List, r: *Reader, delimiter: ?u8) List.ParseError!void {
            innerRead(list, r, delimiter) catch |e| return switch (e) {
                else => |err| err,
                error.StreamTooLong => error.BadFile,
            };
        }

        fn innerRead(list: *List, r: *Reader, delimiter: ?u8) (error{StreamTooLong} || List.ParseError)!void {
            // Read CSV header
            const csv_header = try r.takeDelimiter('\n') orelse return error.InvalidHeader;
            const del = delimiter orelse blk: {
                for (common_delimiters) |del| {
                    const columns = 1 + std.mem.countScalar(u8, csv_header, del);
                    if (columns == config.columns.len) break :blk del;
                }
                return error.InvalidHeader;
            };

            // Short-circuit for empty csv
            const first_line = r.peekDelimiterExclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return,
                else => |err| return err,
            };
            var first_value: Elem = undefined;
            list.start_epoch = try config.read(&first_value, first_line, del);
            var last_epoch: u64 = list.start_epoch;

            // Parse entries
            errdefer list.deinit();
            var header = try list.headers.addOne(list.allocator);
            // Start first header info
            header.* = .{
                .start = @intCast(list.array.items.len),
                .size = 0,
            };
            while (try r.takeDelimiter('\n')) |line| {
                const value = try list.array.addOne(list.allocator);
                const current_epoch: u64 = try config.read(value, line, del);
                if (last_epoch != current_epoch) {
                    // Finish current and start next header info
                    const last_len: u32 = @intCast(list.array.items.len - 1);
                    header.size = last_len - header.start;
                    const epoch_delta: usize = @intCast(current_epoch - last_epoch);
                    try list.headers.appendNTimes(list.allocator, .{ .start = last_len, .size = 0 }, epoch_delta);
                    last_epoch = current_epoch;
                    header = &list.headers.items[list.headers.items.len - 1];
                }
            }
            // Finish last header info
            header.size = @intCast(list.array.items.len - header.start);
        }

        test "csv columns" {
            const testing = config.testing orelse return error.SkipZigTest;

            var data: Segmented(Elem) = .init(std.testing.allocator);
            defer data.deinit();
            try randomSegments(Elem, &data, testing, &orderedEpochs(3), 5);

            // Write to a buffer and read from it to check for issues with the CSV format
            var writer: Writer.Allocating = .init(data.allocator);
            defer writer.deinit();
            const del = ',';
            try write(&data, &writer.writer, del);

            var reader: Reader = .fixed(writer.written());
            const csv_header = try reader.takeDelimiter('\n') orelse {
                std.log.err("Missing CSV header in buffer\n{s}", .{writer.written()});
                return error.InvalidHeader;
            };
            const columns_delimiters = config.columns.len - 1;
            if (std.mem.countScalar(u8, csv_header, del) != columns_delimiters) {
                std.log.err("Delimiter used in header\n{s}", .{csv_header});
                return error.InvalidHeader;
            }
            var rows: usize = 0;
            while (try reader.takeDelimiter('\n')) |line| {
                if (std.mem.countScalar(u8, line, del) != columns_delimiters) {
                    std.log.err("Column number mismatch between header\n{s}\nAnd entry\n{s}", .{ csv_header, line });
                    return error.InvalidValue;
                }
                rows += 1;
            }
            if (rows != 3 * 5) {
                std.log.err("Row count mismatch\n{s}", .{writer.written()});
                return error.InvalidValue;
            }
        }

        test "csv format round trip" {
            const testing = config.testing orelse return error.SkipZigTest;

            var data: Segmented(Elem) = .init(std.testing.allocator);
            defer data.deinit();
            try randomSegments(Elem, &data, testing, &orderedEpochs(10), 5);

            // Write to a buffer and read from it with a new Segmented instance
            var writer: Writer.Allocating = .init(data.allocator);
            defer writer.deinit();
            try write(&data, &writer.writer, null);

            var read_data: Segmented(Elem) = .init(std.testing.allocator);
            defer read_data.deinit();
            var reader: Reader = .fixed(writer.written());
            read(&read_data, &reader, null) catch |err| {
                std.log.err("Failed to parse\n{s}", .{writer.written()});
                return err;
            };

            try std.testing.expectEqualSlices(Header, data.headers.items, read_data.headers.items);
            for (data.array.items, read_data.array.items) |original, final| {
                std.testing.expect(testing.approxEql(original, final)) catch |err| {
                    std.log.err("Entry\n{any}\nBecame\n{any}.", .{ original, final });
                    return err;
                };
            }
        }
    };
}

pub fn Segmented(Elem: type) type {
    return struct {
        const Self = @This();

        /// Epoch corresponding to the first header
        start_epoch: u64 = 0,
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

        /// Epoch corresponding to one past the last header
        pub fn end_epoch(self: *const Self) u64 {
            return self.start_epoch + self.headers.items.len;
        }

        pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

        /// Create a copy of the data
        pub fn copy(self: *const Self, gpa: Allocator) error{OutOfMemory}!Self {
            var new_data: Self = .init(gpa);
            errdefer new_data.deinit();

            new_data.start_epoch = self.start_epoch;
            try new_data.headers.appendSlice(gpa, self.headers.items);
            try new_data.array.appendSlice(gpa, self.array.items);

            return new_data;
        }

        /// Create a new segmented data with all segments combined
        pub fn concatenate(segments: []const Self, gpa: Allocator) error{ OverlappingHeader, OutOfMemory }!Self {
            var elements: usize = segments[0].array.items.len;
            for (1..segments.len) |idx| {
                elements += segments[idx].array.items.len;
                if (segments[idx - 1].end_epoch() > segments[idx].start_epoch) {
                    @branchHint(.unlikely);
                    return error.OverlappingHeader;
                }
            }
            const headers: usize = @intCast(segments[segments.len - 1].end_epoch() - segments[0].start_epoch);

            var new_data: Self = .init(gpa);
            errdefer new_data.deinit();

            new_data.start_epoch = segments[0].start_epoch;
            try new_data.headers.ensureTotalCapacityPrecise(gpa, headers);
            try new_data.array.ensureTotalCapacityPrecise(gpa, elements);
            new_data.headers.appendSliceAssumeCapacity(segments[0].headers.items);
            new_data.array.appendSliceAssumeCapacity(segments[0].array.items);
            for (1..segments.len) |idx| {
                const start: u32 = @intCast(new_data.array.items.len);
                const in_between: usize = @intCast(segments[idx].start_epoch - segments[idx - 1].end_epoch());
                new_data.headers.appendNTimesAssumeCapacity(.{ .start = start, .size = 0 }, in_between);
                const slice = new_data.headers.addManyAsSliceAssumeCapacity(segments[idx].headers.items.len);
                @memcpy(slice, segments[idx].headers.items);
                for (slice) |*header| header.start += start;
                new_data.array.appendSliceAssumeCapacity(segments[idx].array.items);
            }

            return new_data;
        }

        /// Remove all unreferenced subslices from array
        pub fn compress(self: *Self) void {
            var elements: u32 = 0;
            for (self.headers.items) |header| elements += header.size;
            if (elements == self.array.items.len) return;

            var start: u32 = 0;
            for (self.headers.items) |*header| {
                const new_header: Header = .{ .start = start, .size = header.size };
                @memmove(new_header.getReference(Elem, self.array.items), header.getReference(Elem, self.array.items));
                header.* = new_header;
                start += header.size;
            }

            self.array.items.len = elements;
        }

        /// Apply a function to the subslices and shift the given amount of data to the previous or earlier epoch
        pub fn epochApplyShift(self: *Self, ctx: anytype, comptime shift: fn (@TypeOf(ctx), u64, []Elem) Shift) error{OutOfMemory}!void {
            if (self.empty()) return;
            var idx: u32 = 0;
            var last_shift = shift(ctx, self.start_epoch + idx, self.headers.items[idx].getReference(Elem, self.array.items));
            if (last_shift.backward != 0) {
                const header = &self.headers.items[0];
                const start = header.start;
                header.start += last_shift.backward;
                header.size -= last_shift.backward;
                try self.headers.insert(self.allocator, 0, .{ .start = start, .size = last_shift.backward });
                self.start_epoch -= 1;
                idx += 1;
            }
            idx += 1;
            while (idx < self.headers.items.len) : (idx += 1) {
                const new_shift = shift(ctx, self.start_epoch + idx, self.headers.items[idx].getReference(Elem, self.array.items));
                defer last_shift = new_shift;
                if (last_shift.forward != 0 or new_shift.backward != 0) {
                    const last_header = &self.headers.items[idx - 1];
                    const new_header = &self.headers.items[idx];
                    const compressed = last_header.start + last_header.size == new_header.start;

                    if (last_shift.forward == 0) {
                        if (!compressed) @memmove(
                            self.array.items[last_header.start + last_header.size ..][0..new_shift.backward],
                            self.array.items[new_header.start..][0..new_shift.backward],
                        );
                        last_header.size += new_shift.backward;
                        new_header.start += new_shift.backward;
                        new_header.size -= new_shift.backward;
                    } else if (new_shift.backward == 0) {
                        last_header.size -= last_shift.forward;
                        new_header.start -= last_shift.forward;
                        new_header.size += last_shift.forward;
                        if (!compressed) @memmove(
                            self.array.items[new_header.start..][0..last_shift.forward],
                            self.array.items[last_header.start + last_header.size ..][0..last_shift.forward],
                        );
                    } else {
                        const backward = last_header.start + last_header.size - new_shift.backward;
                        const forward = new_header.start + last_shift.forward;
                        std.mem.reverse(Elem, self.array.items[new_header.start..][0..new_shift.backward]);
                        std.mem.reverse(Elem, self.array.items[backward..][0..last_shift.forward]);
                        std.mem.reverse(Elem, self.array.items[backward..forward]);
                        last_header.size = last_header.size + new_shift.backward - last_shift.forward;
                        new_header.start = new_header.start + new_shift.backward - last_shift.forward;
                        new_header.size = new_header.size + last_shift.forward - new_shift.backward;
                    }
                }
            }
            if (last_shift.forward != 0) {
                const header = &self.headers.items[self.headers.items.len - 1];
                const start = header.start + header.size - last_shift.forward;
                header.size -= last_shift.forward;
                try self.headers.append(self.allocator, .{ .start = start, .size = last_shift.forward });
            }
        }

        /// Find the index of a header with a specific epoch
        /// If no valid index is found, return null instead
        pub fn epochIndex(self: *const Self, epoch: u64, comptime search: Search) ?u32 {
            const headers = self.headers.items;

            // Short-circuit for the empty case
            if (headers.len == 0) return null;

            if (epoch < self.start_epoch) return switch (search) {
                .at_least => 0,
                .exact, .at_most => null,
            };
            if (self.start_epoch + self.headers.items.len <= epoch) return switch (search) {
                .at_least, .exact => null,
                .at_most => @intCast(self.headers.items.len - 1),
            };

            return @intCast(epoch - self.start_epoch);
        }

        /// Create a view of the data, containing the specified epoch range
        /// The returned view is form start inclusive to end exclusive
        pub fn epochRange(self: *const Self, start: u64, end: u64) Self {
            std.debug.assert(start < end);
            var view: Self = .init(Allocator.failing);

            const start_idx = self.epochIndex(start, .at_least) orelse return view;
            const end_idx = (self.epochIndex(end - 1, .at_most) orelse return view) + 1;
            if (start_idx == end_idx) return view;

            view.start_epoch = self.start_epoch + start_idx;
            view.headers.items = self.headers.items[start_idx..end_idx];
            view.array = self.array;

            return view;
        }

        /// Iterate through all epochs from start to the given limit
        /// Epochs that are empty or have no header for it, will yield an empty slice
        pub fn epochIterator(self: *const Self, start: ?u64, end: ?u64) Iterator {
            const iter_end = end orelse self.start_epoch + self.headers.items.len;
            const iter_start = start orelse if (self.headers.items.len == 0) iter_end else self.start_epoch;
            return .init(
                self,
                iter_start,
                iter_end,
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

            pub fn nextEpoch(self: *@This()) ?struct { epoch: u64, values: []Elem } {
                const epoch = self.epoch;
                return if (self.next()) |values| .{ .epoch = epoch, .values = values } else null;
            }
        };

        /// Return the slice of values corresponding to the header at position `index`
        ///
        /// `index` must be either a valid index for headers or null
        pub fn valuesAt(self: *const Self, index: ?u32) []const Elem {
            if (index) |idx| {
                const header = self.headers.items[idx];
                return header.getConst(Elem, self.array.items);
            }
            return &.{};
        }
    };
}

fn typeHash(Type: type) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(typeRepr(Type));
    return hash.final();
}

fn typeRepr(Type: type) []const u8 {
    switch (@typeInfo(Type)) {
        .int => |info| return std.fmt.comptimePrint("{c}{d}", .{ switch (info.signedness) {
            .signed => 'i',
            .unsigned => 'u',
        }, info.bits }),
        .float => |info| return std.fmt.comptimePrint("f{d}", .{info.bits}),
        .@"enum" => |info| {
            var text: []const u8 = std.fmt.comptimePrint("enum({s})", .{typeRepr(info.tag_type)});
            var first = true;
            for (info.field_names, info.field_values) |name, val| {
                text = text ++ std.fmt.comptimePrint("{c} {s} = {d}", .{
                    if (first) '{' else ',',
                    name,
                    val,
                });
                first = false;
            }
            return text ++ " }";
        },
        .@"struct" => |info| {
            var text: []const u8 = @as(?[]const u8, switch (info.layout) {
                .auto => null,
                .@"extern" => "extern struct",
                .@"packed" => if (info.backing_integer) |int|
                    std.fmt.comptimePrint("bitpacked({s})", .{typeRepr(int)})
                else
                    null,
            }) orelse @compileError("Invalid struct type.");
            var first = true;
            for (info.field_names, info.field_types) |name, ty| {
                text = text ++ std.fmt.comptimePrint("{c} {s}: {s}", .{
                    if (first) '{' else ',',
                    name,
                    typeRepr(ty),
                });
                first = false;
            }
            return text ++ " }";
        },
        else => |_, tag| @compileError(std.fmt.comptimePrint("Unable to represent {s}.", .{@tagName(tag)})),
    }
}

const Dummy = extern struct {
    value: u32,

    // CSV elements
    const csv_fmt = csv(@This(), .{
        .columns = &.{ "Epoch", "Value" },
        .read = fromCsv,
        .write = toCsv,

        .testing = testing,
    });

    fn toCsv(self: Dummy, w: *Writer, epoch: u64, del: u8) Writer.Error!void {
        try w.print("{[seconds]d}{[delimiter]c}{[value]d}\n", .{
            .seconds = epoch,
            .delimiter = del,
            .value = self.value,
        });
    }

    fn fromCsv(self: *Dummy, line: []u8, del: u8) error{InvalidValue}!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const epoch = std.fmt.parseInt(usize, iterator.next() orelse return error.InvalidValue, 10) catch return error.InvalidValue;
        self.value = std.fmt.parseInt(u32, iterator.next() orelse return error.InvalidValue, 10) catch return error.InvalidValue;
        return epoch;
    }

    // Testing elements
    const testing: TestConfig(@This()) = .{
        .dummy = dummyValue,
        .eql = eql,
        .approxEql = approxEql,
    };

    fn eql(first: Dummy, second: Dummy) bool {
        return first.value == second.value;
    }

    const approxEql = Dummy.eql;

    fn lower(_: void, first: Dummy, second: Dummy) bool {
        return first.value < second.value;
    }

    fn dummyValue(rand: std.Random) Dummy {
        return .{ .value = rand.int(u32) };
    }

    // BIN elements
    const bin_fmt = bin(@This(), .{
        .tag = "dummy",
    });
};

inline fn orderedEpochs(comptime count: usize) [count]u64 {
    var buffer: [count]u64 = undefined;
    for (&buffer, 0..) |*elem, i| elem.* = i;
    return buffer;
}

fn randomSegments(Elem: type, data: *Segmented(Elem), testing: TestConfig(Elem), epochs: []const u64, size: u32) !void {
    data.start_epoch = epochs[0];
    const last_epoch = epochs[epochs.len - 1] + 1;
    const epoch_count = last_epoch - data.start_epoch;
    try data.headers.ensureTotalCapacity(data.allocator, @intCast(epoch_count));
    try data.array.ensureTotalCapacity(data.allocator, epochs.len * size);
    var epoch = data.start_epoch;
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
        element.* = testing.dummy(random);
    }
}

test "bin format round trip" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    try randomSegments(Dummy, &data, Dummy.testing, &.{ 2, 5, 9, 12, 13, 14, 15, 16, 18, 24 }, 5);

    // Write to a buffer and read from it with a new Segmented instance
    var writer: Writer.Allocating = .init(data.allocator);
    defer writer.deinit();
    try Dummy.bin_fmt.write(&data, &writer.writer);

    var read_data: Segmented(Dummy) = .init(std.testing.allocator);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try Dummy.bin_fmt.read(&read_data, &reader);

    try std.testing.expect(data.start_epoch == read_data.start_epoch);
    try std.testing.expectEqualSlices(Header, data.headers.items, read_data.headers.items);
    for (data.array.items, read_data.array.items) |original, read| {
        try std.testing.expect(Dummy.eql(original, read));
    }
}

test "bin format uncompressed" {
    var complete: Segmented(Dummy) = .init(std.testing.allocator);
    defer complete.deinit();
    try randomSegments(Dummy, &complete, Dummy.testing, &.{ 2, 3, 4, 7, 8, 9, 13, 14, 15, 16, 17, 18 }, 5);

    var range: Segmented(Dummy) = try complete.epochRange(5, 10).copy(std.testing.allocator);
    defer range.deinit();

    // Write to a buffer and read from it with a new Segmented instance
    var writer: Writer.Allocating = .init(range.allocator);
    defer writer.deinit();
    try Dummy.bin_fmt.write(&range, &writer.writer);
    range.compress();

    var read_data: Segmented(Dummy) = .init(std.testing.allocator);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try Dummy.bin_fmt.read(&read_data, &reader);

    try std.testing.expect(range.start_epoch == read_data.start_epoch);
    try std.testing.expectEqualSlices(Header, range.headers.items, read_data.headers.items);
    for (range.array.items, read_data.array.items) |original, destination| {
        try std.testing.expect(Dummy.eql(original, destination));
    }
}

test "copy" {
    var origin: Segmented(Dummy) = .init(std.testing.allocator);
    defer origin.deinit();
    try randomSegments(Dummy, &origin, Dummy.testing, &orderedEpochs(10), 5);

    var dest = try origin.copy(origin.allocator);
    defer dest.deinit();

    try std.testing.expect(origin.start_epoch == dest.start_epoch);
    try std.testing.expectEqualSlices(Header, origin.headers.items, dest.headers.items);
    for (origin.array.items, dest.array.items) |original, destination| {
        try std.testing.expect(Dummy.eql(original, destination));
    }
}

test "concatenate" {
    var complete: Segmented(Dummy) = .init(std.testing.allocator);
    defer complete.deinit();
    try randomSegments(Dummy, &complete, Dummy.testing, &.{ 2, 3, 4, 7, 8, 9, 13, 14, 15, 16, 17, 18 }, 5);

    var reconstructed: Segmented(Dummy) = try .concatenate(&.{
        complete.epochRange(0, 5),
        complete.epochRange(5, 10),
        complete.epochRange(10, 20),
    }, std.testing.allocator);
    defer reconstructed.deinit();
    reconstructed.compress();

    try std.testing.expect(complete.start_epoch == reconstructed.start_epoch);
    try std.testing.expectEqualSlices(Header, complete.headers.items, reconstructed.headers.items);
    for (complete.array.items, reconstructed.array.items) |original, destination| {
        try std.testing.expect(Dummy.eql(original, destination));
    }
}

test "compress" {
    var complete: Segmented(Dummy) = .init(std.testing.allocator);
    defer complete.deinit();
    try randomSegments(Dummy, &complete, Dummy.testing, &orderedEpochs(10), 5);

    var compressed = try complete.epochRange(3, 7).copy(std.testing.allocator);
    defer compressed.deinit();
    compressed.compress();

    try std.testing.expect(compressed.array.items.len == 20);
    for ([4]u64{ 3, 4, 5, 6 }) |epoch| {
        const expected = complete.valuesAt(complete.epochIndex(epoch, .exact));
        const actual = compressed.valuesAt(compressed.epochIndex(epoch, .exact));
        try std.testing.expectEqualSlices(Dummy, expected, actual);
    }
}

fn applyShiftSetConst(_: void, value: u64, slice: []Dummy) Shift {
    if (slice.len == 0) return .{};
    @memset(slice, .{ .value = @intCast(value) });
    if (value % 3 == 0) @memset(slice[0..2], .{ .value = @intCast(value + 1) });
    if (value % 5 == 0) @memset(slice[2..4], .{ .value = @intCast(value - 1) });
    return .{};
}

fn applyShiftTest(_: void, value: u64, slice: []Dummy) Shift {
    if (slice.len == 0) return .{};
    std.sort.insertion(Dummy, slice, {}, Dummy.lower);
    const first: u32 = if (value == slice[0].value) 0 else 2;
    const last: u32 = if (value == slice[slice.len - 1].value) 0 else 2;
    return .{ .backward = first, .forward = last };
}

fn applyShiftIsEpoch(failure: *?u64, value: u64, slice: []Dummy) Shift {
    for (slice) |elem| {
        if (elem.value != value)
            failure.* = value;
    }
    return .{};
}

test "epochApplyShift" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    const epochs = [_]u64{ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 };
    try randomSegments(Dummy, &data, Dummy.testing, &epochs, 10);

    var failure: ?u64 = null;
    try data.epochApplyShift({}, applyShiftSetConst);
    try data.epochApplyShift({}, applyShiftTest);
    try data.epochApplyShift(&failure, applyShiftIsEpoch);

    if (failure) |epoch| {
        std.debug.print("Expected: {d}, but found: {any}\n", .{ epoch, data.valuesAt(data.epochIndex(epoch, .exact)) });
        return error.ExpectedEqual;
    }
}

test "epochApplyShift uncompressed" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    const epochs = [_]u64{ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 };
    try randomSegments(Dummy, &data, Dummy.testing, &epochs, 10);
    for (data.headers.items) |*header| {
        header.size = 5;
    }

    var failure: ?u64 = null;
    try data.epochApplyShift({}, applyShiftSetConst);
    try data.epochApplyShift({}, applyShiftTest);
    try data.epochApplyShift(&failure, applyShiftIsEpoch);

    if (failure) |epoch| {
        std.debug.print("Expected: {d}, but found: {any}\n", .{ epoch, data.valuesAt(data.epochIndex(epoch, .exact)) });
        return error.ExpectedEqual;
    }
}

test "epochIndex" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();

    // Empty
    try std.testing.expect(data.epochIndex(1, .at_most) == null);
    try std.testing.expect(data.epochIndex(1, .exact) == null);
    try std.testing.expect(data.epochIndex(1, .at_least) == null);

    const epochs = [_]u64{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
    try randomSegments(Dummy, &data, Dummy.testing, &epochs, 0);

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
    try randomSegments(Dummy, &data, Dummy.testing, &epochs, 0);

    // Below range
    try std.testing.expect(data.epochRange(0, 1).headers.items.len == 0);

    // Above range
    try std.testing.expect(data.epochRange(25, 30).headers.items.len == 0);

    // Outside both
    const view1 = data.epochRange(0, 30);
    try std.testing.expect(view1.start_epoch == 2);
    try std.testing.expect(view1.start_epoch + view1.headers.items.len == 21);

    // In range
    const view2 = data.epochRange(4, 14);
    try std.testing.expect(view2.start_epoch == 4);
    try std.testing.expect(view2.start_epoch + view2.headers.items.len == 14);
}

test "epochIterator" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    var iter: Segmented(Dummy).Iterator = undefined;
    var failed_buffer: [1]Dummy = undefined;
    const failed: []Dummy = &failed_buffer;

    // Empty
    iter = data.epochIterator(1, 3);
    try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 3);

    // Undefined lower bound
    iter = data.epochIterator(null, 5);
    try std.testing.expect(iter.next() == null);

    // Undefined upper bound
    iter = data.epochIterator(8, null);
    try std.testing.expect(iter.next() == null);

    // Undefined bounds
    iter = data.epochIterator(null, null);
    try std.testing.expect(iter.next() == null);

    const test_values = struct {
        const epochs = [_]u64{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 20 };
        fn contains(number: u64) bool {
            return std.mem.findScalar(u64, &epochs, number) != null;
        }
    };
    try randomSegments(Dummy, &data, Dummy.testing, &test_values.epochs, 5);

    // Below range
    iter = data.epochIterator(0, 1);
    try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 1);

    // Above range
    iter = data.epochIterator(25, 30);
    for (25..30) |_|
        try std.testing.expect((iter.next() orelse failed).len == 0);
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 30);

    // Outside both
    iter = data.epochIterator(1, 23);
    for (1..23) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 23);

    // In range
    iter = data.epochIterator(4, 14);
    for (4..14) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 14);

    // Until the end
    iter = data.epochIterator(8, null);
    for (8..21) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 21);

    // From the start
    iter = data.epochIterator(null, 10);
    for (2..10) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 10);

    // Full range
    iter = data.epochIterator(null, null);
    for (2..21) |idx|
        try std.testing.expect((iter.next() orelse failed).len == @as(usize, if (test_values.contains(idx)) 5 else 0));
    try std.testing.expect(iter.next() == null);
    try std.testing.expect(iter.epoch == 21);
}

test "valuesAt" {
    var data: Segmented(Dummy) = .init(std.testing.allocator);
    defer data.deinit();
    try randomSegments(Dummy, &data, Dummy.testing, &orderedEpochs(10), 5);

    try std.testing.expect(data.valuesAt(null).len == 0);
    for (data.array.items[10..15], data.valuesAt(2)) |sliced, located| {
        try std.testing.expect(Dummy.eql(sliced, located));
    }
}
