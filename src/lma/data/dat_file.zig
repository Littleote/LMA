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
    std.debug.assert(bytes.len % @alignOf(u16) == 0);
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

pub const SignalParser = struct {
    const Signal = data.Signal;
    const Signals = Signal.List;
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
    pub fn fromReader(
        r: *Reader,
        signals: *Signals,
        config: Config,
    ) (error{ReadFailed} || Error)!void {
        const buffer = r.allocRemainingAlignedSentinel(
            signals.allocator,
            .unlimited,
            .of(u16),
            null,
        ) catch |e| switch (e) {
            error.OutOfMemory, error.ReadFailed => |err| return err,
            error.StreamTooLong => unreachable,
        };
        defer signals.allocator.free(buffer);

        if (buffer.len % @alignOf(u16) != 0) return error.BadFile;

        const parser: SignalParser = try .init(toNative(buffer), config);

        try parser.parse(signals);
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
        } else return error.BadFile;
    }

    /// Parse the given signal dat file
    fn parse(self: SignalParser, signals: *Signals) error{ OutOfMemory, BadFile }!void {
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
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    const fmt = comptime blk: {
                        var fmt: []const u8 = "";
                        var underscore = true;
                        for (@typeInfo(field.type).@"struct".fields) |subfield| {
                            if (underscore) underscore = false else fmt = "_" ++ fmt;
                            fmt = std.fmt.comptimePrint(
                                "{{[{s}]b:0>{d}}}",
                                .{ subfield.name, @typeInfo(subfield.type).int.bits },
                            ) ++ fmt;
                        }
                        break :blk fmt[0..].*;
                    };
                    if (separator) separator = false else try w.writeByte('/');
                    try w.print(&fmt, @field(value, field.name));
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
            return @bitCast(Above{ .low = self._0.above_low, .high = self._2.above_high });
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
};

inline fn getFloat(Float: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Float {
    return std.fmt.parseFloat(
        Float,
        std.mem.trim(u8, s orelse return error.BadFile, " "),
    ) catch error.InvalidValue;
}

inline fn getInt(Int: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Int {
    return std.fmt.parseInt(Int, std.mem.trim(
        u8,
        s orelse return error.BadFile,
        " ",
    ), 10) catch error.InvalidValue;
}

pub const output = struct {
    pub const ParseError = error{
        ReadFailed,
        OutOfMemory,
        InvalidHeader,
        InvalidValue,
        BadFile,
    };

    pub fn parse(
        r: *Reader,
        maybe_points: ?*data.Point.List,
        maybe_stations: ?*data.Station.List,
    ) ParseError!void {
        innerParse(r, maybe_points, maybe_stations) catch |err| return switch (err) {
            else => |new_err| new_err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerParse(
        r: *Reader,
        maybe_points: ?*data.Point.List,
        maybe_stations: ?*data.Station.List,
    ) (error{StreamTooLong} || ParseError)!void {
        var start_time: ?u64 = null;
        var header_count: ?usize = null;
        var values_count: ?usize = null;
        var station_count: ?usize = null;

        // Advance to station information
        while (try r.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "Number of seconds")) {
                header_count = std.fmt.parseInt(usize, line[28..], 10) catch return error.InvalidHeader;
            } else if (std.mem.startsWith(u8, line, "Number of stations")) {
                station_count = std.fmt.parseInt(usize, line[20..], 10) catch return error.InvalidHeader;
            } else if (std.mem.startsWith(u8, line, "Data start time")) {
                const time = line[line.len - 8 ..];
                const hour = std.fmt.parseInt(usize, time[0..2], 10) catch return error.InvalidHeader;
                const minute = std.fmt.parseInt(usize, time[3..5], 10) catch return error.InvalidHeader;
                const second = std.fmt.parseInt(usize, time[6..8], 10) catch return error.InvalidHeader;
                start_time = (hour * 60 + minute) * 60 + second;
            } else if (std.mem.startsWith(u8, line, "Station information")) {
                break;
            }
        } else return error.BadFile;

        if (maybe_points == null and maybe_stations == null) return;

        // Parse station information
        if (maybe_stations) |stations| {
            try stations.stations.ensureTotalCapacityPrecise(stations.allocator, station_count.?);

            for (0..station_count.?) |_| {
                const line = (try r.takeDelimiter('\n')) orelse return error.BadFile;
                var iter = std.mem.tokenizeScalar(u8, line, ' ');
                _ = iter.next() orelse return error.BadFile;
                const current_station = stations.stations.addOneAssumeCapacity();
                current_station.* = .{
                    // Tokenizer ensures that non null entries are not empty
                    .station_id = data.Station.letterToId((iter.next() orelse return error.BadFile)[0]),
                    .network_id = @enumFromInt(0), // Unset
                    .name = try stations.arena.allocator().dupe(u8, iter.next() orelse return error.BadFile),
                    .latitude = try getFloat(f64, iter.next()),
                    .longitude = try getFloat(f64, iter.next()),
                    .altitude = try getFloat(f32, iter.next()),
                    .delay = 4 * try getInt(i32, iter.next()),
                    .revision = try getInt(u8, iter.next()),
                    .channel = try getInt(u8, iter.next()),
                };
            }
        } else {
            for (0..station_count.?) |_| {
                _ = try r.takeDelimiter('\n');
            }
        }

        if (maybe_points) |points| blk: {
            // Advance to data section
            while (try r.takeDelimiter('\n')) |line| {
                if (std.mem.startsWith(u8, line, "Number of events")) {
                    values_count = std.fmt.parseInt(usize, line[18..], 10) catch return error.InvalidHeader;
                } else if (std.mem.startsWith(u8, line, "*** data ***")) {
                    @branchHint(.unlikely);
                    break;
                }
            } else return error.BadFile;

            if (values_count == 0) break :blk;

            try innerParsePoints(r, points, start_time, header_count.? + 1, values_count.?);
        }

        // No else branch necessary to synchronize the readers as all code paths end here
        return;
    }

    pub fn parsePoints(
        r: *Reader,
        points: *data.Point.List,
        start_epoch: ?u64,
        headers: usize,
        entries: usize,
    ) ParseError!void {
        innerParsePoints(r, points, start_epoch, headers, entries) catch |e| return switch (e) {
            else => |err| err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerParsePoints(
        r: *Reader,
        points: *data.Point.List,
        start_epoch: ?u64,
        headers: usize,
        entries: usize,
    ) (error{StreamTooLong} || ParseError)!void {
        if (headers == 0 or entries == 0) return;

        // Parse data section
        try points.headers.ensureTotalCapacityPrecise(points.allocator, headers);
        try points.array.ensureTotalCapacityPrecise(points.allocator, entries);

        const peek_line = r.peekDelimiterExclusive('\n') catch |e| return switch (e) {
            error.ReadFailed => |err| err,
            error.StreamTooLong, error.EndOfStream => error.BadFile,
        };

        var last_epoch: [5]u8 = undefined;
        @memcpy(&last_epoch, peek_line[0..5]);
        points.start_epoch = try parseEpoch(&last_epoch);
        if (start_epoch != null and start_epoch.? < points.start_epoch) {
            points.start_epoch = start_epoch.?;
            _ = std.fmt.printInt(
                &last_epoch,
                start_epoch.?,
                10,
                .lower,
                .{ .alignment = .right, .width = 5, .fill = ' ' },
            );
        }
        points.headers.appendAssumeCapacity(.{
            .start = 0,
            .size = 0,
        });
        var last_header = &points.headers.items[0];
        defer last_header.size = @intCast(points.array.items.len - last_header.start);

        while (try r.takeDelimiter('\n')) |line| {
            if (!std.mem.eql(u8, &last_epoch, line[0..5])) {
                @memcpy(&last_epoch, line[0..5]);
                const array_size: u32 = @intCast(points.array.items.len);
                last_header.size = array_size - last_header.start;
                const current_epoch = points.start_epoch + points.headers.items.len - 1;
                const target_epoch = try parseEpoch(&last_epoch);
                if (target_epoch < points.start_epoch + points.headers.items.len) {
                    @branchHint(.cold);
                    return error.BadFile;
                }
                points.headers.appendNTimesAssumeCapacity(
                    .{ .start = array_size, .size = 0 },
                    @intCast(target_epoch - current_epoch),
                );
                last_header = &points.headers.items[points.headers.items.len - 1];
            }
            const current_value = points.array.addOneAssumeCapacity();

            var it = std.mem.tokenizeScalar(u8, line, ' ');
            var token: []const u8 = it.next() orelse break;
            current_value.nanosecond = 4 * (std.fmt.parseInt(
                u32,
                token[token.len - 9 ..],
                10,
            ) catch return error.InvalidHeader);
            token = it.next() orelse break;
            current_value.latitude = std.fmt.parseFloat(f32, token) catch return error.InvalidHeader;
            token = it.next() orelse break;
            current_value.longitude = std.fmt.parseFloat(f32, token) catch return error.InvalidHeader;
            token = it.next() orelse break;
            current_value.altitude = std.fmt.parseFloat(f32, token) catch return error.InvalidHeader;
            token = it.next() orelse break;
            current_value.measure_error = std.fmt.parseFloat(f16, token) catch return error.InvalidHeader;
            token = it.next() orelse break;
            current_value.dBW = std.fmt.parseFloat(f16, token) catch return error.InvalidHeader;
            token = it.next() orelse break;
            current_value.station_mask = std.fmt.parseInt(u32, token[2..], 16) catch return error.InvalidHeader;
        } else return;
        return error.BadFile;
    }

    pub fn print(
        w: *Writer,
        points: *const data.Point.List,
        stations: *const data.Station.List,
        statistics: []const lma.pipeline.ToaSolver.Statistics,
    ) Writer.Error!void {
        // Data start time: YY/MM/DD HH:MM:SS
        // Number of seconds analyzed: ANALYSIS_TIME
        // Location: NETWORK_NAME
        try w.writeAll("Location: CUSTOM\n");

        // Coordinate center (lat,lon,alt): LATITUDE  LONGITUDE  DUMMY_ALTITUDE
        var network_xyz = lma.math(f64).vector.zero;
        for (stations.stations.items) |station|
            network_xyz += lma.pipeline.transform.gpsToXYZ(
                f64,
                .{ .elems = .{ station.latitude, station.longitude, station.altitude, 0 } },
            ).build();
        const center = lma.pipeline.transform.xyzToSurface(
            f64,
            .init(network_xyz / lma.math(f64).vector.splat(cast.to(f64, stations.stations.items.len))),
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
        try w.print("Number of stations: {d}\n", .{stations.stations.items.len});
        // Number of active stations: SIZE_UNION_SETS
        var active_count: usize = 0;
        for (0..lma.constants.network.max_network) |idx| {
            for (statistics) |stats| {
                if (stats.stations[idx].solutions != 0) {
                    active_count += 1;
                    break;
                }
            }
        }
        try w.print("Number of active stations: {d}\n", .{active_count});

        // Active stations: LETTER_SET_1 LETTER_SET_2 ...
        try w.writeAll("Active stations:");
        for (statistics) |stats| {
            try w.writeByte(' ');
            for (stats.stations, 0..) |station, idx| {
                if (station.solutions != 0) try w.writeByte(stations.stations.items[idx].stationLetter());
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
        for (stations.stations.items) |station| {
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
        // Sta_data: LETTER  NAME  WINDOW(80)_OR_0  VERSION(12)_OR_0  RMS(40)_OR_0  SOLUTIONS  SOLUTIONS % TOTAL_SOLUTIONS  ???  ACTIVE(A)_OR_NA
        try w.writeAll("Station data: id, name, win(us), data_ver, rms_error(ns), sources, %, <P/P_m>, active\n");
        for (statistics) |stats| {
            for (stations.stations.items, 0..) |station, idx| {
                const info = stats.stations[idx];
                const active = info.solutions != 0;
                try w.print("Sta_data: {c}  {s: <16}  {d: >4}  {d: >4}  {d: >3}  {d: >7}  {d: >4.1}  {d: >4.2}  {s: >2}\n", .{
                    station.stationLetter(),
                    station.name,
                    @as(u32, if (active) 80 else 0),
                    @as(u32, if (active) 12 else 0),
                    lma.pipeline.ToaSolver.rms * std.time.ns_per_s,
                    info.solutions,
                    100 * cast.to(f32, info.solutions) / cast.to(f32, @max(1, stats.counts.out_solutions)),
                    @as(f32, if (active) 1.0 else 0.0),
                    if (active) "A" else "NA",
                });
            }
        }

        // Station mask order: REVERSE_STATIONS_LETTER_SET
        try w.writeAll("Station mask order: ");
        var station_iter = std.mem.reverseIterator(stations.stations.items);
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
        for (statistics) |stats| solutions += stats.counts.out_solutions;
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
};

comptime {
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(SignalParser);
}
