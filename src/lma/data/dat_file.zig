const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const data = lma.data;
const cast = lma.cast;

/// Helper function to parse u8 slice at idx as u16 little endian
fn toNative(bytes: []align(@alignOf(u16)) u8) []u16 {
    std.debug.assert(bytes.len % @sizeOf(u16) == 0);
    return switch (builtin.target.cpu.arch.endian()) {
        .little => @ptrCast(bytes),
        .big => swap: {
            const swap: []u16 = @ptrCast(bytes);
            std.mem.byteSwapAllElements(u16, swap);
            break :swap swap;
        },
    };
}

test toNative {
    const values = [_]u16{ 0x0001, 0x0010, 0x0100, 0x1000 };
    var bytes: [values.len * @sizeOf(u16)]u8 align(@alignOf(u16)) = "\x01\x00\x10\x00\x00\x01\x00\x10".*;
    try std.testing.expectEqualSlices(u16, &values, toNative(&bytes));
}

pub const SignalParser = struct {
    const Signal = data.Signal;
    const List = Signal.List;
    const log = std.log.scoped(lma.log.hierarchy.signal_file);

    pub const Error = error{ OutOfMemory, BadFile, UnsupportedVersion };

    pub const Config = struct {};

    const Section = struct {
        start: usize,
        packets: usize,
        epoch: u64,
        correction: i16 = 0,
    };

    /// Load a Time of Arrival '.dat' file from a reader
    pub fn read(
        list: *List,
        r: *Reader,
        config: Config,
    ) (error{ReadFailed} || Error)!void {
        const buffer = r.allocRemainingAlignedSentinel(
            list.allocator,
            .unlimited,
            .of(u16),
            null,
        ) catch |e| switch (e) {
            error.OutOfMemory, error.ReadFailed => |err| return err,
            error.StreamTooLong => unreachable,
        };
        defer list.allocator.free(buffer);

        if (buffer.len % @sizeOf(u16) != 0) {
            log.err("Malformed or truncated file has length 0x{x}, not a multiple of 0x{x}.", .{ buffer.len, @sizeOf(u16) });
            return error.BadFile;
        }

        const parser: SignalParser = try .init(toNative(buffer), config);

        try parser.parse(list);
    }

    const latest_version = 13;
    const supported_versions = [_]u16{12};

    buffer: []const u16,
    version: u16,
    config: Config,

    /// Initialize the parser constants for the given file
    fn init(buffer: []const u16, config: Config) Error!SignalParser {
        for (0..buffer.len - 1) |start| {
            const head: HeaderBasic = .initRaw(buffer[start..][0..2]);
            if (head.valid()) {
                const version: u16 = head.version();
                if (std.mem.findScalar(u16, &supported_versions, version)) |_| {
                    return .{
                        .buffer = buffer[start..],
                        .version = version,
                        .config = config,
                    };
                } else {
                    log.err("Version {d} is not supported.", .{version});
                    return error.UnsupportedVersion;
                }
            }
        } else {
            log.err("No valid initial header found.", .{});
            return error.BadFile;
        }
    }

    /// Parse the given signal dat file
    fn parse(self: SignalParser, signals: *List) error{ OutOfMemory, BadFile }!void {
        const gpa = signals.allocator;

        const sections = try self.parseHeaders(gpa);
        defer gpa.free(sections);

        if (sections.len == 0) return;

        signals.start_epoch = sections[0].epoch;
        const end_epoch = sections[sections.len - 1].epoch + 1;
        var epoch: u64 = signals.start_epoch;
        var start: u32 = 0;

        const headers: usize = @intCast(end_epoch - signals.start_epoch);
        var packets: usize = 0;
        for (sections) |section| packets += section.packets;

        try signals.headers.ensureTotalCapacityPrecise(gpa, headers);
        try signals.array.ensureTotalCapacityPrecise(gpa, packets);

        for (sections) |section| {
            if (section.epoch < epoch or end_epoch <= section.epoch) {
                @branchHint(.cold);
                log.warn(
                    "Header {d} followed by header {d}. Ignoring latest section with header {d}.",
                    .{ epoch - 1, section.epoch, section.epoch },
                );
                continue;
            }
            signals.headers.appendNTimesAssumeCapacity(.{
                .start = start,
                .size = 0,
            }, @intCast(section.epoch - epoch));

            const elems = signals.array.addManyAsSliceAssumeCapacity(section.packets);
            const size = self.parseSection(section, elems);

            signals.headers.appendAssumeCapacity(.{ .start = start, .size = size });
            start += size;
            epoch = section.epoch + 1;

            signals.array.items.len = start;
        }
    }

    /// Find the start of the next header.
    fn nextHeader(self: SignalParser, pos: usize) ?usize {
        switch (self.version) {
            inline 12 => |version| {
                const Header = Headers[version];

                var offset: usize = pos;
                while (true) {
                    // Search header marker and validate it
                    const match = std.mem.findScalarPos(
                        u16,
                        self.buffer,
                        offset + Header.marker_offset,
                        0xAA55,
                    ) orelse return null;
                    offset = match - Header.marker_offset;
                    const header: Header = .initRaw(self.buffer[offset..][0..Header.len]);
                    if (header.valid()) return offset;
                    offset += 1;
                }
            },
            else => unreachable,
        }
    }

    /// Extract all the information from the headers.
    fn parseHeaders(self: SignalParser, gpa: Allocator) error{OutOfMemory}![]Section {
        var sections: std.ArrayList(Section) = .empty;
        errdefer sections.deinit(gpa);

        var start: usize = self.header_size();
        while (self.nextHeader(start)) |end| {
            const header = self.parseHeader(start, end) orelse continue;
            try sections.append(gpa, header);
            start = end + self.header_size();
        }

        try sections.shrinkToLen(gpa);
        return sections.toOwnedSliceAssert();
    }

    /// Parse header to generate the section information of a block
    fn parseHeader(self: SignalParser, block_start: usize, block_end: usize) ?Section {
        switch (self.version) {
            inline 12 => |version| {
                const Header = Headers[version];
                const Packet = Packets[version];

                const header: Header = .initRaw(self.buffer[block_end..][0..Header.len]);
                const packets = std.math.divExact(
                    usize,
                    block_end - block_start,
                    Packet.len,
                ) catch |err| switch (err) {
                    error.DivisionByZero => unreachable,
                    error.UnexpectedRemainder => {
                        log.warn(
                            "Header {f} missaligned. Discarding its corresponding section {d}.",
                            .{ header, header.epoch() },
                        );
                        return null;
                    },
                };
                if (packets != header.reportedPackets()) {
                    log.info(
                        "Expecting {d} duplicate packets in section {d}",
                        .{ packets -| header.reportedPackets(), header.epoch() },
                    );
                }
                return header.parseHeader(block_start, packets);
            },
            else => unreachable,
        }
    }

    fn parseSection(self: SignalParser, section: Section, out: []Signal) u32 {
        std.debug.assert(out.len < std.math.maxInt(u32));
        switch (self.version) {
            inline 12 => |version| {
                const Packet = Packets[version];

                const factor: f64 = std.time.ns_per_s / (std.time.ns_per_s / 40.0 + cast.to(f64, section.correction));

                comptime std.debug.assert(@alignOf(Packet) == @alignOf(u16));
                const packets: []const Packet = @ptrCast(
                    self.buffer[section.start..][0 .. section.packets * Packet.len],
                );
                for (packets, out, 0..) |packet, *signal, idx| {
                    signal.* = packet.buildSignal(factor) catch |err| switch (err) {
                        error.NextSecond => {
                            log.warn(
                                "Invalid time in packet {f}, discarding the {d} remaining packets of section {d}.",
                                .{ packet, out.len - idx, section.epoch },
                            );
                            return @intCast(idx);
                        },
                    };
                }
                return @intCast(out.len);
            },
            else => unreachable,
        }
    }

    test parseHeader {
        const Entry = struct { input: []const u16, section: Section };

        var parser: SignalParser = .{ .buffer = &.{}, .version = 0, .config = .{} };
        var entries: [latest_version][]const Entry = @splat(&.{});

        entries[12] = &.{
            .{
                .input = &.{ 0x860A, 0xC000, 0x8B59, 0x8600, 0x8000, 0x8101, 0x3039, 0x8000, 0xAA55 },
                .section = .{ .start = 0, .packets = 0, .correction = 12345, .epoch = 12345 },
            },
            .{
                .input = &.{ 0x860A, 0x8000, 0xA464, 0xAB71, 0x8000, 0x8101, 0x3039, 0x8000, 0xAA55 },
                .section = .{ .start = 0, .packets = 0, .correction = -12345, .epoch = 77777 },
            },
        };

        inline for (supported_versions) |version| {
            parser.version = version;
            for (entries[version], 1..) |entry, idx| {
                errdefer std.debug.print("For version {d}, example {d}.\n", .{ version, idx });

                parser.buffer = entry.input;
                const section = parser.parseHeader(0, 0) orelse return error.InvalidHeader;
                errdefer {
                    std.debug.print("Expected {any} but found {any}.\n", .{ entry.section, section });
                    const header: Headers[version] = .initRaw(entry.input[0..Headers[version].len]);
                    std.debug.print("Input = {f}.\n", .{header});
                }

                try std.testing.expect(std.meta.eql(entry.section, section));
            }
        }
    }

    test parseSection {
        const Entry = struct { input: []const u16, section: Section, signal: Signal };

        var parser: SignalParser = undefined;
        var entries: [latest_version][]const Entry = @splat(&.{});

        entries[12] = &.{
            .{
                .input = &.{ 0x168E, 0x181C, 0x4D7B },
                .section = .{ .start = 0, .packets = 1, .epoch = 0, .correction = 0 },
                .signal = .{ .nanosecond = 4 * 40 * 12345678, .dBm = 0.488 * 123.0 - 111.0, .padding = 1234 },
            },
            .{
                .input = &.{ 0x168E, 0x181C, 0x4D7B },
                .section = .{ .start = 0, .packets = 1, .epoch = 0, .correction = 1 },
                .signal = .{ .nanosecond = 1975308401, .dBm = 0.488 * 123.0 - 111.0, .padding = 1234 },
            },
            .{
                .input = &.{ 0xD32A, 0xD5D8, 0xAAAA },
                .section = .{ .start = 0, .packets = 1, .epoch = 0, .correction = 0 },
                .signal = .{ .nanosecond = 4 * 40 * 0xAAAAAA, .dBm = 0.488 * 0xAA.0 - 111.0, .padding = 0x2AA },
            },
        };

        var parsed: Signal = undefined;
        const parsed_buffer: []Signal = (&parsed)[0..1];
        inline for (supported_versions) |version| {
            parser.version = version;
            for (entries[version], 1..) |entry, idx| {
                errdefer std.debug.print("For version {d}, example {d}.\n", .{ version, idx });

                parser.buffer = entry.input;
                try std.testing.expect(parser.parseSection(entry.section, parsed_buffer) == 1);
                errdefer {
                    std.debug.print("Expected {any} but found {any}.\n", .{ entry.signal, parsed });
                    const packet: Packets[version] = .initRaw(entry.input[0..Packets[version].len]);
                    std.debug.print("Input = {f}.\n", .{packet});
                    std.debug.print("Section = {any}.\n", .{entry.section});
                }

                try std.testing.expect(std.meta.eql(entry.signal, parsed));
            }
        }
    }

    fn header_size(self: SignalParser) usize {
        return switch (self.version) {
            inline 12 => |version| Headers[version].len,
            else => unreachable,
        };
    }

    fn packet_size(self: SignalParser) usize {
        return switch (self.version) {
            inline 12 => |version| Packets[version].len,
            else => unreachable,
        };
    }

    test "supported_versions" {
        inline for (supported_versions) |version| {
            const Header = Headers[version];
            const Packet = Packets[version];

            var signals_buffer: [1]Signal = @splat(undefined);
            var parser: SignalParser = .{
                .version = version,
                .buffer = &@as([Header.len + Packet.len]u16, @splat(0xAAAA)),
                .config = .{},
            };
            _ = parser.nextHeader(0);

            _ = parser.parseHeader(0, Packet.len) orelse unreachable;
            _ = parser.parseSection(.{
                .start = Header.len,
                .packets = 1,
                .epoch = 0,
                .correction = 0,
            }, &signals_buffer);
        }
    }

    fn Mixin(T: type) type {
        return struct {
            const len = @divExact(@sizeOf(T), @sizeOf(u16));

            inline fn fromBytesW(bytes: *const [len]u16) T {
                return @as(*const T, @ptrCast(bytes)).*;
            }

            inline fn asBytesW(ptr: *const T) *const [len]u16 {
                return @ptrCast(ptr);
            }

            fn headerEpoch(value: T) u32 {
                return @as(u32, value._2.second) +
                    @as(u32, value._2.minute) * std.time.s_per_min +
                    @as(u32, value._3.hour) * std.time.s_per_hour;
            }

            fn format(value: T, w: *Writer) Writer.Error!void {
                var separator = true;
                const info = @typeInfo(T).@"struct";
                inline for (info.field_names, info.field_types) |name, ty| {
                    const fmt = comptime blk: {
                        var fmt: []const u8 = "";
                        var underscore = true;
                        const sub_info = @typeInfo(ty).@"struct";
                        for (sub_info.field_names, sub_info.field_types) |sub_name, sub_ty| {
                            if (underscore) underscore = false else fmt = "_" ++ fmt;
                            fmt = std.fmt.comptimePrint(
                                "{{[{s}]b:0>{d}}}",
                                .{ sub_name, @typeInfo(sub_ty).int.bits },
                            ) ++ fmt;
                        }
                        break :blk fmt.*;
                    };
                    if (separator) separator = false else try w.writeByte('/');
                    try w.print(&fmt, @field(value, name));
                }
            }

            fn matches(value: T, mask: T, expected: T) bool {
                for (asBytesW(&value), asBytesW(&mask), asBytesW(&expected)) |v, m, e|
                    if ((v & m) != e) return false;
                return true;
            }
        };
    }

    const Headers = blk: {
        var versions: [latest_version]type = @splat(undefined);
        versions[12] = HeaderV12;
        break :blk versions;
    };

    const HeaderBasic = extern struct {
        _0: packed struct(u16) { _unknown_1: u7, version: u5, _unknown_2: u3, _one: u1 = 0b1 },
        _1: packed struct(u16) { _unknown: u15, _one: u1 = 0b1 },

        fn valid(self: @This()) bool {
            const mask: @This() = .initRaw(
                &.{ 0x8000, 0x8000 },
            );
            const expected: @This() = .initRaw(
                &.{ 0x8000, 0x8000 },
            );

            return mixin.matches(self, mask, expected);
        }

        fn version(self: @This()) u16 {
            return self._0.version;
        }

        const mixin = Mixin(@This());

        pub const format = mixin.format;
        const initRaw = mixin.fromBytesW;
        const len = mixin.len;
    };

    const HeaderV12 = extern struct {
        // vYYYYYYY_1xxxvvvv
        _0: packed struct(u16) { year: u7, version: u5, _unknown: u3, _one: u1 = 0b1 },
        // xxxxxxxx_1Cxxxxxx
        _1: packed struct(u16) { _unknown: u14, correction_sign: u1, _one: u1 = 0b1 },
        // ssmmmmmm_1xxxssss
        _2: packed struct(u16) { minute: u6, second: u6, _unknown: u3, _one: u1 = 0b1 },
        // DDDDMMMM_1xhhhhhD
        _3: packed struct(u16) { month: u4, day: u5, hour: u5, _unknown: u1, _one: u1 = 0b1 },
        // eeeeeeee_1eeeeeee
        _4: packed struct(u16) { packets: u15, _one: u1 = 0b1 },
        // NNNNNNNN_1SSSSSSS
        _5: packed struct(u16) { network_id: u8, station_id: u7, _one: u1 = 0b1 },
        // cccccccc_1ccccccc
        _6: packed struct(u16) { correction_abs: u15, _one: u1 = 0b1 },
        // xxxxxxxx_1xxxxxxx
        _7: packed struct(u16) { _unknown: u15, _one: u1 = 0b1 },
        // 01010101_10101010
        _8: packed struct(u16) { marker: u16 = 0xAA55 },

        fn parseHeader(self: @This(), start: usize, packets: usize) Section {
            return .{
                .start = start,
                .packets = packets,
                .epoch = self.epoch(),
                .correction = self.correction(),
            };
        }

        fn correction(self: @This()) i16 {
            return @as(i16, self._6.correction_abs) *
                @as(i16, if (self._1.correction_sign == 0) -1 else 1);
        }

        fn reportedPackets(self: @This()) u16 {
            return self._4.packets;
        }

        fn valid(self: @This()) bool {
            const mask: @This() = .initRaw(
                &.{ 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0xFFFF },
            );
            const expected: @This() = .initRaw(
                &.{ 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0xAA55 },
            );

            return mixin.matches(self, mask, expected);
        }

        const marker_offset = 8;

        const mixin = Mixin(@This());

        pub const format = mixin.format;
        const initRaw = mixin.fromBytesW;
        const epoch = mixin.headerEpoch;
        const len = mixin.len;
    };

    const Packets = blk: {
        var versions: [latest_version]type = @splat(undefined);
        versions[12] = PacketV12;
        break :blk versions;
    };

    const PacketV12 = extern struct {
        const Above = packed struct(u16) { low: u4, high: u7, _pad: u5 = 0 };

        // nnnnnnnn_0aaaannn
        _0: packed struct(u16) { nano: u11, above_low: u4, _zero: u1 = 0b0 },
        // mmmmmmmm_11mmmmmm
        _1: packed struct(u16) { micro: u14, _one: u2 = 0b11 },
        // XXXXXXXX_0aaaaaaa
        _2: packed struct(u16) { max_power: u8, above_high: u7, _zero: u1 = 0b0 },

        fn nano_x40(packet: @This()) u32 {
            const scale: u32 = 2000;
            return scale * packet._1.micro + packet._0.nano;
        }

        fn nanosecond(self: @This(), factor: f64) error{NextSecond}!lma.nano.Nano {
            const nano_float = @round(4 * cast.to(f64, self.nano_x40()) * factor);
            if (nano_float > 4_000_000_000) return error.NextSecond;
            return @intFromFloat(nano_float);
        }

        fn above(self: @This()) u16 {
            return @backingInt(Above{ .low = self._0.above_low, .high = self._2.above_high });
        }

        fn buildSignal(self: @This(), factor: f64) error{NextSecond}!Signal {
            return .{
                .nanosecond = try self.nanosecond(factor),
                .dBm = @floatCast(0.488 * cast.to(f32, self._2.max_power) - 111.0),
                .padding = self.above(),
            };
        }

        const mixin = Mixin(@This());

        pub const format = mixin.format;
        const initRaw = mixin.fromBytesW;
        const len = mixin.len;
    };

    comptime {
        std.testing.refAllDecls(@This());
    }
};

pub const output = struct {
    const Point = data.Point;
    const Station = data.Station;
    const ParseError = data.ParseError;

    const log = std.log.scoped(lma.log.hierarchy.points_file);

    pub fn read(
        points: *Point.List,
        r: *Reader,
    ) ParseError!void {
        innerRead(points, r) catch |err| return switch (err) {
            else => |new_err| new_err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerRead(
        points: *Point.List,
        r: *Reader,
    ) (error{StreamTooLong} || ParseError)!void {
        var start_time: ?u64 = null;
        var header_count: ?u32 = null;
        var values_count: ?u32 = null;
        var station_count: ?usize = null;

        // Advance to data section
        while (try r.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "Number of seconds")) {
                @branchHint(.unpredictable);
                header_count = std.fmt.parseInt(u32, line[28..], 10) catch return error.InvalidHeader;
            } else if (std.mem.startsWith(u8, line, "Number of stations")) {
                @branchHint(.unpredictable);
                station_count = std.fmt.parseInt(usize, line[20..], 10) catch return error.InvalidHeader;
            } else if (std.mem.startsWith(u8, line, "Data start time")) {
                @branchHint(.unpredictable);
                const time = line[line.len - 8 ..];
                const hour = std.fmt.parseInt(u64, time[0..2], 10) catch return error.InvalidHeader;
                const minute = std.fmt.parseInt(u64, time[3..5], 10) catch return error.InvalidHeader;
                const second = std.fmt.parseInt(u64, time[6..8], 10) catch return error.InvalidHeader;
                start_time = (hour * 60 + minute) * 60 + second;
            } else if (std.mem.startsWith(u8, line, "Station information")) {
                @branchHint(.unpredictable);
                if (station_count) |count| for (0..count) |_| {
                    _ = try r.takeDelimiter('\n');
                };
            } else if (std.mem.startsWith(u8, line, "Number of events")) {
                @branchHint(.unpredictable);
                values_count = std.fmt.parseInt(u32, line[18..], 10) catch return error.InvalidHeader;
            } else if (std.mem.startsWith(u8, line, "*** data ***")) {
                @branchHint(.unpredictable);
                break;
            }
        } else {
            @branchHint(.unlikely);
            log.err("Missing data section", .{});
            return error.BadFile;
        }

        var missing = false;
        if (start_time == null) {
            @branchHint(.unlikely);
            log.err("Missing data start time", .{});
            missing = true;
        }
        if (header_count == null) {
            @branchHint(.unlikely);
            log.err("Missing number of seconds", .{});
            missing = true;
        }
        if (values_count == null) {
            @branchHint(.unlikely);
            log.err("Missing number of events", .{});
            missing = true;
        }
        if (missing) {
            @branchHint(.unlikely);
            return error.InvalidHeader;
        }

        try parsePoints(points, r, start_time.?, header_count.? + 1, values_count.?);
    }

    pub fn readSkipPrologue(
        points: *Point.List,
        r: *Reader,
        start_epoch: u64,
        headers: u32,
        entries: u32,
    ) (error{StreamTooLong} || ParseError)!void {
        while (try r.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "*** data ***")) {
                @branchHint(.unpredictable);
                break;
            }
        } else {
            @branchHint(.unlikely);
            log.err("Missing data section", .{});
            return error.BadFile;
        }
        parsePoints(points, r, start_epoch, headers, entries) catch |e| return switch (e) {
            else => |err| err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn parsePoints(
        points: *Point.List,
        r: *Reader,
        start_epoch: u64,
        headers: u32,
        entries: u32,
    ) (error{StreamTooLong} || ParseError)!void {
        points.start_epoch = start_epoch;
        if (headers == 0 or entries == 0) return;

        // Parse data section
        std.debug.assert(points.headers.items.len == 0);
        points.array.clearRetainingCapacity();
        try points.headers.ensureTotalCapacityPrecise(points.allocator, headers);
        try points.array.ensureTotalCapacityPrecise(points.allocator, entries);

        var epoch: [5]u8 = undefined;
        const start_second = start_epoch % (24 * 60 * 60);
        _ = std.fmt.bufPrint(&epoch, "{d: >5}", .{start_second}) catch unreachable;

        var head: data.segmented.Header = .init(0, 0);
        defer if (head.size != 0) points.headers.appendAssumeCapacity(head);

        while (try r.takeDelimiter('\n')) |line| {
            if (!std.mem.eql(u8, &epoch, line[0..5])) advance: {
                // TODO guarantee at least 5 characters
                @memcpy(&epoch, line[0..5]);
                const current_epoch = points.start_epoch + points.headers.items.len;
                const next_epoch = try parseEpoch(&epoch);
                if (current_epoch == next_epoch) break :advance;
                points.headers.appendAssumeCapacity(head);
                head = .init(@intCast(points.array.items.len), 0);

                if (next_epoch < current_epoch) {
                    @branchHint(.cold);
                    log.err("Entries out of order. Value at {d}.XXX followed by {d}.XXX", .{ current_epoch, next_epoch });
                    return error.BadFile;
                } else if (start_epoch + headers <= next_epoch) {
                    @branchHint(.cold);
                    log.err("Entries too late. Expected values before {d}.000 but found {d}.XXX", .{ start_second + headers, next_epoch });
                    return error.BadFile;
                }

                points.headers.appendNTimesAssumeCapacity(head, @intCast(next_epoch - current_epoch - 1));
            }
            const current_value = points.array.addOneAssumeCapacity();

            var it = std.mem.tokenizeScalar(u8, line, ' ');

            current_value.nanosecond = try getInt(u32, it.next(), -9, 10);
            current_value.latitude = try getFloat(f32, it.next());
            current_value.longitude = try getFloat(f32, it.next());
            current_value.altitude = try getFloat(f32, it.next());
            current_value.measure_error = try getFloat(f16, it.next());
            current_value.dBW = try getFloat(f16, it.next());
            current_value.station_mask = try getInt(u32, it.next(), 2, 16);
            head.size += 1;
        } else return;
        comptime unreachable;
    }

    pub fn write(
        points: *const data.Point.List,
        w: *Writer,
        header: WriteHeader,
    ) Writer.Error!void {
        if (header.command) |args| {
            // Program invocation: CLI INVOCATION
            try w.writeAll("Program invocation:");
            for (args) |arg| {
                try w.print(" {s}", .{arg});
            }
            try w.writeByte('\n');
        }
        if (header.version) |version| {
            // Program version: VERSION
            try w.print("Program version: {s}\n", .{version});
        }
        // File created: FORMATTED DATE
        if (header.date) |date| {
            // File created: FORMATTED DATE
            try w.print("File created: {s}\n", .{date});
        }
        if (header.time) |time| {
            // Data start time: YY/MM/DD HH:MM:SS
            try w.print(
                "Data start time: {[YY]d:0>2}/{[MM]d:0>2}/{[DD]d:0>2} {[hh]d:0>2}:{[mm]d:0>2}:{[ss]d:0>2}\n",
                .{
                    .YY = @as(u8, @intCast(@mod(time.year, 100))),
                    .MM = time.month,
                    .DD = time.day,
                    .hh = time.hour,
                    .mm = time.minute,
                    .ss = time.second,
                },
            );
            // Number of seconds analyzed: ANALYSIS_TIME
            try w.print("Number of seconds analyzed: {d}\n", .{time.analyzed});
        }

        // Location: NETWORK_NAME
        try w.print("Location: {f}\n", .{header.network.fmtNetwork("UNNAMED")});

        // Coordinate center (lat,lon,alt): LATITUDE  LONGITUDE  DUMMY_ALTITUDE
        var network_xyz = lma.math(f64).vector.zero;
        for (header.network.stations.items) |station|
            network_xyz += lma.pipeline.transform.gpsToXYZ(
                f64,
                .{ .elems = .{ station.latitude, station.longitude, station.altitude, 0 } },
            ).build();
        const center = lma.pipeline.transform.xyzToSurface(
            f64,
            .init(network_xyz / lma.math(f64).vector.splat(cast.to(f64, header.network.stations.items.len))),
        );
        try w.print(
            "Coordinate center (lat,lon,alt): {d:.8} {d:.8} -1000.00\n",
            .{ center.x(), center.y() },
        );
        // Coordinate frame: cartesian
        try w.writeAll("Coordinate frame: cartesian\n");
        // Maximum diameter of LMA (km): DIAMETER
        // Maximum light-time across LMA (ns): DIAMETER / C

        // Number of stations: STATIONS_LEN
        try w.print("Number of stations: {d}\n", .{header.network.stations.items.len});
        // Number of active stations: SIZE_UNION_SETS
        var active_count: usize = 0;
        for (0..lma.constants.network.max_network) |idx| {
            for (header.stats) |stats| {
                if (stats.stations[idx].solutions != 0) {
                    active_count += 1;
                    break;
                }
            }
        }
        try w.print("Number of active stations: {d}\n", .{active_count});

        // Active stations: LETTER_SET_1 LETTER_SET_2 ...
        try w.writeAll("Active stations:");
        for (header.stats) |stats| {
            try w.writeByte(' ');
            for (stats.stations, 0..) |station, idx| {
                if (station.solutions != 0) try w.writeByte(header.network.stations.items[idx].stationLetter());
            }
        }
        try w.writeByte('\n');

        // Minimum number of stations per solution: 6
        // Maximum reduced chi-squared: 0.75
        // Maximum number of chi-squared iterations: 20

        // Station information: id, name, lat(d), lon(d), alt(m), delay(ns), board_rev, rec_ch
        // Sta_info: LETTER  NAME  LATITUDE  LONGITUDE  ALTITUDE  DELAY  REVISION  CHANNEL
        try w.writeAll(
            "Station information: id, name, lat(d), lon(d), alt(m), delay(ns), board_rev, rec_ch\n",
        );
        for (header.network.stations.items) |station| {
            try w.print("Sta_info: {c}  {s: <16}  {d: >11.7}  {d: >11.7}  {d: >7.2}  {d: >3.0} {d: >1} {d: >2}\n", .{
                station.stationLetter(),
                station.name,
                station.latitude,
                station.longitude,
                station.altitude,
                lma.nano.fromNano(f32, station.delay) * std.time.ns_per_s,
                station.revision,
                station.channel,
            });
        }

        // Station data: id, name, win(us), data_ver, rms_error(ns), sources, %, <P/P_m>, active
        // Sta_data: LETTER  NAME  WINDOW(80)_OR_0  VERSION(12)_OR_0  RMS(40)_OR_0  SOLUTIONS  SOLUTIONS % TOTAL_SOLUTIONS  MEAN ARITHMETIC POWER ERROR  ACTIVE(A)_OR_NA
        try w.writeAll("Station data: id, name, win(us), data_ver, rms_error(ns), sources, %, <P/P_m>, active\n");
        for (header.stats) |stats| {
            for (header.network.stations.items, 0..) |station, idx| {
                const info = stats.stations[idx];
                const active = info.solutions != 0;
                const pow_delta = std.math.pow(f64, 10.0, @floatCast(info.log_pow_diff / @as(f128, @max(1, info.solutions)) / 10.0));
                try w.print("Sta_data: {c}  {s: <16}  {d: >4}  {d: >4}  {d: >3}  {d: >7}  {d: >4.1}  {d: >4.2}  {s: >2}\n", .{
                    station.stationLetter(),
                    station.name,
                    @as(u32, if (active) 80 else 0),
                    @as(u32, if (active) 12 else 0),
                    lma.pipeline.ToaSolver.rms * std.time.ns_per_s,
                    info.solutions,
                    100 * cast.to(f32, info.solutions) / cast.to(f32, @max(1, stats.counts.out_solutions)),
                    @as(f32, if (active) @floatCast(pow_delta) else 0.0),
                    if (active) "A" else "NA",
                });
            }
        }

        // Station mask order: REVERSE_STATIONS_LETTER_SET
        try w.writeAll("Station mask order: ");
        var station_iter = std.mem.reverseIterator(header.network.stations.items);
        while (station_iter.next()) |station| {
            try w.writeByte(station.stationLetter());
        }
        try w.writeByte('\n');
        // Data: time (UT sec of day), lat, lon, alt(m), reduced chi^2, P(dBW), mask
        try w.writeAll("Data: time (UT sec of day), lat, lon, alt(m), reduced chi^2, P(dBW), mask\n");
        // Data format: 15.9f 12.8f 13.8f 9.2f 6.2f 5.1f 10x
        try w.writeAll("Data format: 15.9f 12.8f 13.8f 9.2f 6.2f 5.1f 10x\n");
        // Number of events: SOLUTIONS
        var solutions: usize = 0;
        for (header.stats) |stats| solutions += stats.counts.out_solutions;
        try w.print("Number of events: {d}\n", .{solutions});

        try w.writeAll("*** data ***\n");
        var it = points.epochIterator(null, null);
        while (it.nextEpoch()) |info| {
            for (info.values) |entry| {
                // Data format: 15.9f 12.8f 13.8f 9.2f 6.2f 5.1f 10x
                try w.print("{d:15.9} {d:12.8} {d:13.8} {d:9.2} {d:6.2} {d:5.1} 0x{x:0>8}\n", .{
                    cast.to(f64, info.epoch) + lma.nano.fromNano(f64, entry.nanosecond),
                    entry.latitude,
                    entry.longitude,
                    entry.altitude,
                    entry.measure_error,
                    entry.dBW,
                    entry.station_mask,
                });
            }
        }
        try w.flush();
    }

    pub const WriteHeader = struct {
        network: *const data.Station.List,
        stats: []const lma.pipeline.ToaSolver.Statistics,
        time: ?Time = null,
        date: ?[]const u8 = null,
        version: ?[]const u8 = null,
        command: ?[]const []const u8 = null,

        pub const Time = struct {
            year: i16,
            month: u8,
            day: u8,

            hour: u8,
            minute: u8,
            second: u8,

            analyzed: u32,
        };
    };

    inline fn getFloat(Float: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Float {
        return std.fmt.parseFloat(Float, std.mem.trim(u8, try unwrapToken(s), " ")) catch {
            log.err("Value {q} is not a valid number", .{s.?});
            return error.InvalidValue;
        };
    }

    inline fn getInt(Int: type, s: ?[]const u8, comptime start: isize, base: u8) error{ BadFile, InvalidValue }!Int {
        const unwrapped = try unwrapToken(s);
        if (unwrapped.len <= @abs(start)) {
            log.err(
                "Value {q} is too short. Should be at least {d} long.",
                .{ unwrapped, @abs(start + 1) },
            );
            return error.InvalidValue;
        }
        const slice_start: usize = if (start < 0) lma.index.offset(usize, unwrapped.len, start) else @intCast(start);
        return std.fmt.parseInt(Int, unwrapped[slice_start..], base) catch {
            const info = @typeInfo(Int).int;
            log.err(
                "Value {q} is not a valid integer of type {c}{d}",
                .{ s.?, if (info.signedness == .signed) 'i' else 'u', info.bits },
            );
            return error.InvalidValue;
        };
    }

    inline fn getString(s: ?[]const u8) error{BadFile}![]const u8 {
        return std.mem.trim(u8, try unwrapToken(s), " ");
    }

    inline fn unwrapToken(s: ?[]const u8) error{BadFile}![]const u8 {
        return s orelse {
            log.err("Line terminated while reading", .{});
            return error.BadFile;
        };
    }

    /// Helper function to parse an epoch value padded with spaces at the start
    fn parseEpoch(bytes: []const u8) error{InvalidValue}!usize {
        const number = std.mem.trimStart(u8, bytes, " ");
        return std.fmt.parseInt(usize, number, 10) catch error.InvalidValue;
    }

    test parseEpoch {
        const epoch_1234 = try parseEpoch("       1234");
        const epoch_5678 = try parseEpoch("5678");

        try std.testing.expect(epoch_1234 == 1234);
        try std.testing.expect(epoch_5678 == 5678);
    }

    comptime {
        std.testing.refAllDecls(@This());
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
