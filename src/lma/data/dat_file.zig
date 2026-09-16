const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const data = lma.data;
const cast = lma.cast;

const Unsupported = error{UnsupportedVersion};

const masks = struct {
    pub const pattern: u16 = 0x9FFF;
    pub const alternate: u16 = 0x8000;
};

/// Helper function to parse u8 slice at idx as u16 little endian
fn toNative(bytes: []const u8, idx: usize) u16 {
    return std.mem.littleToNative(u16, @bitCast(bytes[2 * idx ..][0..2].*));
}

test toNative {
    const bytes = "\x01\x00\x10\x00\x00\x01\x00\x10";
    const values = [_]u16{ 0x0001, 0x0010, 0x0100, 0x1000 };
    for (values, 0..) |value, idx| {
        std.testing.expect(value == toNative(bytes, idx)) catch |err| {
            std.debug.print("Failed to convert at index {d}. Expected {x}, but got {x}.\n", .{ idx, value, toNative(bytes, idx) });
            return err;
        };
    }
}

/// Helper function to peek from a reader guaranteeing the last `preserve` bytes are preserved
fn peekPreserve(r: *Reader, preserve: usize, n: usize, comptime greedy: bool) error{ EndOfStream, ReadFailed }![]u8 {
    const valid_preserve = @min(preserve, r.seek);
    r.seek -= valid_preserve;
    const buffer = try if (greedy) r.peekGreedy(valid_preserve + n) else r.peek(valid_preserve + n);
    r.seek += valid_preserve;
    return buffer[valid_preserve..];
}

test peekPreserve {
    const DummyReader = struct {
        fn stream(r: *Reader, w: *std.Io.Writer, limit: std.Io.Limit) Reader.StreamError!usize {
            _ = r;
            return try w.splatByte(0, @intFromEnum(limit));
        }

        const vtable: Reader.VTable = .{
            .stream = &@This().stream,
        };
    };

    var buffer: [16]u8 = @splat(0);
    var r: Reader = .{
        .buffer = &buffer,
        .seek = 0,
        .end = 0,
        .vtable = &DummyReader.vtable,
    };

    // Works when seek is less than preserve target
    _ = peekPreserve(&r, 7, 3, false) catch unreachable;
    r.toss(3);
    _ = peekPreserve(&r, 7, 5, false) catch unreachable;
    r.toss(5);

    // Preserved bytes don't get discarded
    _ = peekPreserve(&r, 7, 9, true) catch unreachable;
    try std.testing.expect(r.seek >= 7);
    r.toss(9);
    _ = peekPreserve(&r, 7, 3, true) catch unreachable;
    try std.testing.expect(r.seek >= 7);
    r.toss(3);
    _ = peekPreserve(&r, 7, 2, false) catch unreachable;
    try std.testing.expect(r.seek >= 7);
    r.toss(2);
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

pub const signals = struct {
    pub const ReadError = error{ ReadFailed, OutOfMemory, BadFile, UnsupportedVersion };

    /// Load a Time of Arrival '.dat' file from a seeking file reader
    pub fn fromFile(file_reader: *std.Io.File.Reader, signal_data: *data.Signal) ReadError!void {
        const parser: Parser = Parser.init(&file_reader.interface) catch |err| return switch (err) {
            error.EndOfStream => error.BadFile,
            else => |new_err| new_err,
        };

        file_reader.seekTo(0) catch unreachable;
        var sections: std.ArrayList(Section) = try parser.parseAllHeaders(&file_reader.interface, signal_data.allocator);
        defer sections.deinit(signal_data.allocator);

        file_reader.seekTo(0) catch unreachable;
        return parser.parse(sections.items, &file_reader.interface, signal_data);
    }

    /// Load a Time of Arrival '.dat' file from a reader
    pub fn fromReader(r: *Reader, signal_data: *data.Signal) ReadError!void {
        var writer: std.Io.Writer.Allocating = .init(signal_data.allocator);
        defer writer.deinit();
        _ = r.streamRemaining(&writer.writer) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };

        return fromBuffer(writer.written(), signal_data);
    }

    /// Load a Time of Arrival '.dat' file from a buffer
    pub fn fromBuffer(buffer: []const u8, signal_data: *data.Signal) ReadError!void {
        var reader: Reader = .fixed(buffer);
        const parser: Parser = Parser.init(&reader) catch |err| return switch (err) {
            error.EndOfStream => error.BadFile,
            else => |new_err| new_err,
        };

        reader.seek = 0;
        var sections: std.ArrayList(Section) = try parser.parseAllHeaders(&reader, signal_data.allocator);
        defer sections.deinit(signal_data.allocator);

        reader.seek = 0;
        return parser.parse(sections.items, &reader, signal_data);
    }

    const Section = struct {
        start: u32,
        epoch: u32,
        size: u16,
        count_correction: i16 = 0,
    };

    const Parser = struct {
        const latest_version = 13;
        const supported_versions = [_]u16{12};

        version: u16,
        pattern: u16,

        /// Initialize the parser constants for the given file
        fn init(r: *Reader) error{ ReadFailed, EndOfStream, UnsupportedVersion }!Parser {
            var lookahead: []u8 = undefined;
            const packet_start: u16 = while (true) {
                lookahead = try r.peek(4);
                if (lookahead[1] >> 7 == 1 and lookahead[3] >> 7 == 1) {
                    break toNative(lookahead, 0);
                }
                r.toss(2);
            };

            const version: u16 = (packet_start >> 7) & 0x001F;
            const is_supported = std.mem.findScalar(u16, &supported_versions, version) != null;
            if (!is_supported) {
                std.log.err("Version {d} is not supported.", .{version});
                return error.UnsupportedVersion;
            }

            return .{
                .version = version,
                .pattern = packet_start & masks.pattern,
            };
        }

        /// Advance the reader until the header of the next packet found
        fn nextPacketHeader(self: Parser, r: *Reader, skip: usize) error{ReadFailed}!?usize {
            switch (self.version) {
                inline 12 => |version| {
                    const Header = Headers[version];

                    _ = r.take(skip) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => return null,
                    };

                    const even = ~@as(usize, 1);
                    var consumed: usize = skip;

                    while (true) {
                        // Search until marker sequence is found
                        while (r.peekGreedy(@sizeOf(Header))) |buffer| {
                            const maybe_idx = std.mem.indexOfPos(u8, buffer, Header.marker_offset, "\x55\xAA");
                            const discarded = if (maybe_idx) |idx|
                                if (idx % 2 == 0) {
                                    const discarded = idx - Header.marker_offset;
                                    consumed += discarded;
                                    r.toss(discarded);
                                    break;
                                } else
                                // Keep u16 alignment and ignore missaligned match
                                (idx & even) + 2 - Header.marker_offset
                            else
                                // Keep u16 alignment
                                (buffer.len & even) - Header.marker_offset;

                            consumed += discarded;
                            r.toss(discarded);
                        } else |err| switch (err) {
                            error.ReadFailed => return error.ReadFailed,
                            error.EndOfStream => return null,
                        }

                        // Search already read the full Header
                        const header = r.peekStruct(Header, .little) catch unreachable;
                        if (header.valid()) return consumed else r.toss(2);
                    }
                },
                else => unreachable,
            }
        }

        /// Process an entire file saving the header metadata into an array list
        fn parseAllHeaders(self: Parser, r: *Reader, gpa: Allocator) error{ ReadFailed, OutOfMemory }!std.ArrayList(Section) {
            var sections: std.ArrayList(Section) = .empty;
            errdefer sections.deinit(gpa);

            if (try self.nextPacketHeader(r, 0) == null) return sections;

            var start: u32 = 0;
            while (try self.parseHeader(r, start)) |header| {
                start += header.size;
                try sections.append(gpa, header);
            }

            return sections;
        }

        /// Process an entire file given the header metadata
        /// saving the packet information into the data struct
        fn parse(self: Parser, sections: []const Section, r: *Reader, signal_data: *data.Signal) error{ ReadFailed, OutOfMemory, BadFile }!void {
            if (sections.len == 0) return;
            _ = try self.nextPacketHeader(r, 0) orelse unreachable;

            r.discardAll(self.header_size()) catch |err| {
                switch (err) {
                    error.ReadFailed => |new_error| return new_error,
                    error.EndOfStream => unreachable,
                }
            };

            signal_data.start_epoch = sections[0].epoch;
            const end_epoch = sections[sections.len - 1].epoch + 1;
            var epoch: u64 = signal_data.start_epoch;
            var buffer_index: u32 = 0;

            try signal_data.headers.ensureTotalCapacityPrecise(signal_data.allocator, @intCast(end_epoch - signal_data.start_epoch));
            for (sections) |section| {
                if (epoch > section.epoch or section.epoch >= end_epoch) {
                    @branchHint(.cold);
                    std.log.warn("Header {d} followed by header {d}. Ignoring latest section with header {d}.", .{ epoch - 1, section.epoch, section.epoch });
                    r.discardAll(section.size * self.packet_size()) catch |err| {
                        switch (err) {
                            error.ReadFailed => |new_error| return new_error,
                            error.EndOfStream => unreachable,
                        }
                    };
                } else {
                    signal_data.headers.appendNTimesAssumeCapacity(.{
                        .start = buffer_index,
                        .size = 0,
                    }, @intCast(section.epoch - epoch));

                    const elems = try signal_data.array.addManyAsSlice(signal_data.allocator, section.size);
                    const buffer_size = self.parsePackets(section, r, elems) catch |err| switch (err) {
                        error.ReadFailed => |new_error| return new_error,
                        error.EndOfStream => unreachable,
                    };

                    signal_data.headers.appendAssumeCapacity(.{
                        .start = buffer_index,
                        .size = buffer_size,
                    });
                    buffer_index += buffer_size;
                    epoch = section.epoch + 1;

                    signal_data.array.items.len = buffer_index;
                }

                r.discardAll(self.header_size()) catch |err| {
                    switch (err) {
                        error.ReadFailed => |new_error| return new_error,
                        error.EndOfStream => unreachable,
                    }
                };
            }
        }

        /// Computes the size of the block and parses the dat file header.
        ///
        /// Leaves the reader position at the start of the next header.
        fn parseHeader(self: Parser, r: *Reader, start: u32) error{ReadFailed}!?Section {
            switch (self.version) {
                inline 12 => |version| {
                    const size = try self.nextPacketHeader(r, @sizeOf(Headers[version])) orelse return null;
                    const header = r.peekStruct(Headers[version], .little) catch |err| {
                        switch (err) {
                            error.ReadFailed => |new_error| return new_error,
                            error.EndOfStream => return null,
                        }
                    };

                    return header.parseHeader(start, size);
                },
                else => unreachable,
            }
        }

        fn parsePackets(self: Parser, section: Section, r: *Reader, out: []data.types.Signal) Reader.Error!u32 {
            std.debug.assert(out.len < std.math.maxInt(u32));
            switch (self.version) {
                10, 12 => {
                    const factor: f64 = std.time.ns_per_s / (std.time.ns_per_s / 40.0 + cast.to(f64, section.count_correction));

                    var filled: u32 = 0;
                    for (0..out.len) |_| {
                        const packet = try r.takeStruct(PacketV12, .little);
                        out[filled] = packet.buildSignal(factor) catch |err| switch (err) {
                            error.NextSecond => {
                                std.log.warn("Invalid time in packet {f}, discarding packet.", .{packet});
                                continue;
                            },
                        };
                        filled += 1;
                    }
                    return filled;
                },
                else => unreachable,
            }
        }

        test parseHeader {
            var bytes: [latest_version]?[]const []const u8 = @splat(null);
            var sections: [latest_version]?[]const Section = @splat(null);
            bytes[12] = &.{
                "0-\x00\x40\x59\x0B\x00\x064-5-\x39\x307-8-9-",
                "0-\xFF\xBF\x64\xA4\x71\x2B4-5-\x39\x307-8-9-",
            };
            sections[12] = &.{
                .{ .count_correction = 12345, .start = 123, .size = (2520 - 18) / 6, .epoch = 12345 },
                .{ .count_correction = -12345, .start = 123, .size = (2520 - 18) / 6, .epoch = 77777 },
            };

            inline for (supported_versions) |version| {
                const HeaderVersion = Headers[version];
                for (bytes[version].?, sections[version].?, 1..) |in, out, idx| {
                    errdefer std.debug.print("For version {d}, example {d}.\n", .{ version, idx });

                    var r: Reader = .fixed(in);
                    const header = r.takeStruct(HeaderVersion, .little) catch unreachable;
                    const parsed = header.parseHeader(123, 2520);
                    errdefer std.debug.print("Expected {any} but found {any}.\n", .{ out, parsed });

                    try std.testing.expectEqual(out, parsed);
                }
            }
        }

        test parsePackets {
            var parser: Parser = undefined;
            var bytes: [latest_version]?[]const []const u8 = @splat(null);
            var sections: [latest_version]?[]const Section = @splat(null);
            var signal: [latest_version]?[]const data.types.Signal = @splat(null);

            bytes[12] = &.{
                "\x8E\x16\x1C\x18\x7B\x4D",
                &PacketV12.initRaw(&.{
                    0b1_1010_01100101010,
                    0b1_1_01010111011000,
                    0b1_0101010_10101010,
                }).asBytes(),
            };
            sections[12] = &.{
                .{ .start = 0, .size = 1, .epoch = 0, .count_correction = 0 },
                .{ .start = 0, .size = 1, .epoch = 0, .count_correction = 0 },
            };
            signal[12] = &.{
                .{ .nanosecond = 4 * 40 * 12345678, .dBm = 0.488 * 123.0 - 111.0, .padding = 1234 },
                .{ .nanosecond = 4 * 40 * 0xAAAAAA, .dBm = 0.488 * 0xAA.0 - 111.0, .padding = 0x2AA },
            };

            for (supported_versions) |version| {
                parser.version = version;
                for (bytes[version].?, sections[version].?, signal[version].?, 1..) |in, extra, out, idx| {
                    errdefer std.debug.print("For version {d}, example {d}.\n", .{ version, idx });

                    var r: Reader = .fixed(in);
                    var parsed: data.types.Signal = undefined;
                    try std.testing.expect(parser.parsePackets(extra, &r, (&parsed)[0..1]) catch unreachable == 1);
                    errdefer std.debug.print("Expected {any} but found {any}.\n", .{ out, parsed });

                    try std.testing.expectEqual(out, parsed);
                }
            }
        }

        fn header_size(self: Parser) usize {
            return switch (self.version) {
                inline 12 => |version| @sizeOf(Headers[version]),
                else => unreachable,
            };
        }

        fn packet_size(self: Parser) usize {
            return switch (self.version) {
                inline 12 => |version| @sizeOf(Packets[version]),
                else => unreachable,
            };
        }

        test "supported_versions" {
            comptime {
                for (supported_versions) |version| {
                    var parser: Parser = .{ .pattern = 0, .version = version };
                    const Header = Headers[version];
                    const Packet = Packets[version];

                    var reader: Reader = .fixed(&.{});
                    _ = parser.nextPacketHeader(&reader, 0) catch unreachable;

                    const header: *const Header = &.initRaw(&@splat(0xAAAA));
                    const segment = header.parseHeader(0, @sizeOf(Header));

                    var packets_reader: Reader = .fixed(&Packet.initRaw(&@splat(0xAAAA)).asBytes());
                    var signals_buffer: [1]lma.data.types.Signal = @splat(undefined);
                    _ = parser.parsePackets(segment, &packets_reader, &signals_buffer) catch unreachable;
                }
            }
        }

        fn Mixin(T: type) type {
            return struct {
                const u8_size = @sizeOf(T);
                const u16_size = @divExact(@sizeOf(T), 2);

                inline fn fromBytes(bytes: *const [u8_size]u8) T {
                    var out = @as(*align(1) const T, @ptrCast(bytes)).*;
                    if (builtin.target.cpu.arch.endian() != .little) {
                        std.mem.byteSwapAllElements(u16, @ptrCast(&out));
                    }
                    return out;
                }

                inline fn fromBytesW(bytes: *const [u16_size]u16) T {
                    return @as(*const T, @ptrCast(bytes)).*;
                }

                inline fn asBytes(ptr: *const T) [u8_size]u8 {
                    var out: [u8_size]u8 align(2) = @as(*const [u8_size]u8, @ptrCast(ptr)).*;
                    if (builtin.target.cpu.arch.endian() != .little) {
                        std.mem.byteSwapAllElements(u16, @ptrCast(&out));
                    }
                    return out;
                }

                inline fn asBytesW(ptr: *const T) *const [u16_size]u16 {
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

            const mixin = Mixin(@This());

            pub const format = mixin.format;
            const initRaw = mixin.fromBytesW;
            const asBytes = mixin.asBytes;
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
            _4: packed struct(u16) { events: u15, _one: u1 = 0b1 },
            // NNNNNNNN_1SSSSSSS
            _5: packed struct(u16) { network_id: u8, station_id: u7, _one: u1 = 0b1 },
            // cccccccc_1ccccccc
            _6: packed struct(u16) { correction_abs: u15, _one: u1 = 0b1 },
            // xxxxxxxx_1xxxxxxx
            _7: packed struct(u16) { _unknown: u15, _one: u1 = 0b1 },
            // 01010101_10101010
            _8: packed struct(u16) { marker: u16 = 0xAA55 },

            fn parseHeader(self: HeaderV12, start: u32, size: usize) Section {
                return .{
                    .start = start,
                    .size = @intCast(@divExact(size - @sizeOf(HeaderV12), @sizeOf(PacketV12))),
                    .epoch = self.epoch(),
                    .count_correction = self.correction(),
                };
            }

            fn correction(self: HeaderV12) i16 {
                return @as(i16, self._6.correction_abs) *
                    @as(i16, if (self._1.correction_sign == 0) -1 else 1);
            }

            fn valid(self: HeaderV12) bool {
                const mask: HeaderV12 = .initRaw(
                    &.{ 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0xFFFF },
                );
                const expected: HeaderV12 = .initRaw(
                    &.{ 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0xAA55 },
                );

                return mixin.matches(self, mask, expected);
            }

            const marker_offset = @offsetOf(HeaderV12, "_8");

            const mixin = Mixin(@This());

            pub const format = mixin.format;
            const initRaw = mixin.fromBytesW;
            const asBytes = mixin.asBytes;
            const epoch = mixin.headerEpoch;
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

            fn nanosecond(self: PacketV12, factor: f64) error{NextSecond}!lma.nano.Nano {
                const nano_float = @round(4 * cast.to(f64, self.nano_x40()) * factor);
                if (nano_float > 4_000_000_000) return error.NextSecond;
                return @intFromFloat(nano_float);
            }

            fn above(self: PacketV12) u16 {
                return @bitCast(Above{ .low = self._0.above_low, .high = self._2.above_high });
            }

            fn buildSignal(self: PacketV12, factor: f64) error{NextSecond}!lma.data.types.Signal {
                return .{
                    .nanosecond = try self.nanosecond(factor),
                    .dBm = @floatCast(0.488 * cast.to(f32, self._2.max_power) - 111.0),
                    .padding = self.above(),
                };
            }

            const mixin = Mixin(@This());

            pub const format = mixin.format;
            const initRaw = mixin.fromBytesW;
            const asBytes = mixin.asBytes;
        };
    };
};

inline fn getFloat(Float: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Float {
    return std.fmt.parseFloat(Float, std.mem.trim(u8, s orelse return error.BadFile, " ")) catch error.InvalidValue;
}

inline fn getInt(Int: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Int {
    return std.fmt.parseInt(Int, std.mem.trim(u8, s orelse return error.BadFile, " "), 10) catch error.InvalidValue;
}

pub const output = struct {
    pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile };

    pub fn parse(r: *Reader, maybe_points: ?*data.Points, maybe_stations: ?*data.Stations) ParseError!void {
        innerParse(r, maybe_points, maybe_stations) catch |err| return switch (err) {
            else => |new_err| new_err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerParse(r: *Reader, maybe_points: ?*data.Points, maybe_stations: ?*data.Stations) (error{StreamTooLong} || ParseError)!void {
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
                    .letter = (iter.next() orelse return error.BadFile)[0],
                    .id = 0, // Unset
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

    pub fn parsePoints(r: *Reader, points: *data.Points, start_epoch: ?u64, headers: usize, entries: usize) ParseError!void {
        innerParsePoints(r, points, start_epoch, headers, entries) catch |err| return switch (err) {
            else => |new_err| new_err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerParsePoints(r: *Reader, points: *data.Points, start_epoch: ?u64, headers: usize, entries: usize) (error{StreamTooLong} || ParseError)!void {
        if (headers == 0 or entries == 0) return;

        // Parse data section
        try points.headers.ensureTotalCapacityPrecise(points.allocator, headers);
        try points.array.ensureTotalCapacityPrecise(points.allocator, entries);

        const peek_line = r.peekDelimiterExclusive('\n') catch |err| return switch (err) {
            error.ReadFailed => |new_err| new_err,
            error.StreamTooLong, error.EndOfStream => error.BadFile,
        };

        var last_epoch: [5]u8 = undefined;
        @memcpy(&last_epoch, peek_line[0..5]);
        points.start_epoch = try parseEpoch(&last_epoch);
        if (start_epoch != null and start_epoch.? < points.start_epoch) {
            points.start_epoch = start_epoch.?;
            _ = std.fmt.printInt(&last_epoch, start_epoch.?, 10, .lower, .{ .alignment = .right, .width = 5, .fill = ' ' });
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
                points.headers.appendNTimesAssumeCapacity(.{ .start = array_size, .size = 0 }, @intCast(target_epoch - current_epoch));
                last_header = &points.headers.items[points.headers.items.len - 1];
            }
            const current_value = points.array.addOneAssumeCapacity();

            var it = std.mem.tokenizeScalar(u8, line, ' ');
            var token: []const u8 = it.next() orelse break;
            current_value.nanosecond = 4 * (std.fmt.parseInt(u32, token[token.len - 9 ..], 10) catch return error.InvalidHeader);
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
        points: *const data.Points,
        stations: *const data.Stations,
        statistics: []const lma.pipeline.ToaSolver.Statistics,
    ) Writer.Error!void {
        // Data start time: YY/MM/DD HH:MM:SS
        // Number of seconds analyzed: ANALYSIS_TIME
        // Location: NETWORK_NAME
        try w.writeAll("Location: CUSTOM\n");

        // Coordinate center (lat,lon,alt): LATITUDE  LONGITUDE  DUMMY_ALTITUDE
        var network_xyz = lma.math(f64).vector.zero;
        for (stations.stations.items) |station|
            network_xyz += lma.pipeline.transform.gpsToXYZ(f64, .{ .elems = .{ station.latitude, station.longitude, station.altitude, 0 } }).build();
        const center = lma.pipeline.transform.xyzToSurface(f64, .init(network_xyz / lma.math(f64).vector.splat(lma.cast.to(f64, stations.stations.items.len))));
        try w.print("Coordinate center (lat,lon,alt): {d:.8} {d:.8} -1000.00\n", .{ center.x(), center.y() });
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
                if (station.solutions != 0) try w.writeByte(stations.stations.items[idx].letter);
            }
        }
        try w.writeByte('\n');

        // Minimum number of stations per solution: 6
        // Maximum reduced chi-squared: 0.75
        // Maximum number of chi-squared iterations: 20

        // Station information: id, name, lat(d), lon(d), alt(m), delay(ns), board_rev, rec_ch
        // Sta_info: LETTER  NAME  LATITUDE  LONGITUDE  ALTITUDE  DELAY  REVISION  CHANNEL
        try w.writeAll("Station information: id, name, lat(d), lon(d), alt(m), delay(ns), board_rev, rec_ch\n");
        for (stations.stations.items) |station| {
            try w.print("Sta_info: {c}  {s: <16}  {d: >11.7}  {d: >11.7}  {d: >7.2}  {d: >3.0} {d: >1} {d: >2}\n", .{
                station.letter,
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
                    station.letter,
                    station.name,
                    @as(u32, if (active) 80 else 0),
                    @as(u32, if (active) 12 else 0),
                    lma.pipeline.ToaSolver.rms * std.time.ns_per_s,
                    info.solutions,
                    100 * lma.cast.to(f32, info.solutions) / lma.cast.to(f32, @max(1, stats.counts.out_solutions)),
                    @as(f32, if (active) 1.0 else 0.0),
                    if (active) "A" else "NA",
                });
            }
        }

        // Station mask order: REVERSE_STATIONS_LETTER_SET
        try w.writeAll("Station mask order: ");
        var station_iter = std.mem.reverseIterator(stations.stations.items);
        while (station_iter.next()) |station| {
            try w.writeByte(station.letter);
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
        var it = points.epochIterator(null, .all);
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
    std.testing.refAllDecls(signals.Parser);
}
