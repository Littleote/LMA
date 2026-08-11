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
        var dat_headers: std.ArrayList(Header) = try parser.parseAllHeaders(&file_reader.interface, signal_data.allocator);
        defer dat_headers.deinit(signal_data.allocator);

        file_reader.seekTo(0) catch unreachable;
        return parser.parse(dat_headers.items, &file_reader.interface, signal_data);
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
        var dat_headers: std.ArrayList(Header) = try parser.parseAllHeaders(&reader, signal_data.allocator);
        defer dat_headers.deinit(signal_data.allocator);

        reader.seek = 0;
        return parser.parse(dat_headers.items, &reader, signal_data);
    }

    const Header = struct {
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
            const is_supported = std.mem.containsAtLeastScalar2(u16, &supported_versions, version, 1);
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
            return switch (self.version) {
                10...13 => blk: {
                    const lookbehind: Offset = comptime .init(9);
                    const lookahead: Offset = comptime .init(8);
                    const preserved: Offset = comptime .init(lookbehind.count + lookahead.count);
                    std.debug.assert(lookbehind.count == (Offset.preserve(self)).count);

                    const even = ~@as(usize, 1);
                    const start = @max(lookahead.bytes, skip);

                    _ = peekPreserve(r, preserved.bytes, start, false) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => return null,
                    };
                    var consumed: usize = start;
                    r.toss(start);

                    loop: while (true) {
                        while (true) {
                            const buffer = peekPreserve(r, preserved.bytes, 2, true) catch |err| switch (err) {
                                error.ReadFailed => return error.ReadFailed,
                                error.EndOfStream => return null,
                            };
                            const maybe_idx = std.mem.indexOf(
                                u8,
                                buffer,
                                "\x55\xAA",
                            );
                            if (maybe_idx) |idx| {
                                if (idx % 2 == 0) {
                                    consumed += idx;
                                    r.toss(idx);
                                    break;
                                } else {
                                    // Keep u16 alignment and ignore bad match
                                    const discarded = 2 + (idx & even);
                                    consumed += discarded;
                                    r.toss(discarded);
                                }
                            } else {
                                // Keep u16 alignment
                                const discarded = r.bufferedLen() & even;
                                consumed += discarded;
                                r.toss(discarded);
                            }
                        }

                        var found = false;
                        const frozen_seek = r.seek;
                        defer if (!found) {
                            r.seek = frozen_seek + 2;
                            consumed += 2;
                        };

                        r.seek -= lookahead.bytes;
                        found = true;
                        if (r.seek < lookbehind.bytes) break :loop;
                        var packet_header: [lookbehind.count]u16 = undefined;
                        r.seek -= lookbehind.bytes;
                        r.readSliceEndian(u16, &packet_header, .little) catch unreachable;
                        const pattern = packet_header[lookbehind.count - 9] & masks.pattern;
                        const alternate_pattern = packet_header[lookbehind.count - 1] & masks.alternate;
                        if (alternate_pattern == 0 or pattern == self.pattern) break :loop;
                        // Only execute if no code path exited
                        found = false;
                    }
                    break :blk consumed - lookahead.bytes;
                },
                else => unreachable,
            };
        }

        /// Process an entire file saving the header metadata into an array list
        fn parseAllHeaders(self: Parser, r: *Reader, gpa: Allocator) error{ ReadFailed, OutOfMemory }!std.ArrayList(Header) {
            var headers: std.ArrayList(Header) = .empty;
            errdefer headers.deinit(gpa);

            if (try self.nextPacketHeader(r, 0) == null) return headers;

            var start: u32 = 0;
            while (try self.parseHeader(r, start)) |header| {
                start += header.size;
                try headers.append(gpa, header);
            }

            return headers;
        }

        /// Process an entire file given the header metadata
        /// saving the packet information into the data struct
        fn parse(self: Parser, headers: []const Header, r: *Reader, signal_data: *data.Signal) error{ ReadFailed, OutOfMemory, BadFile }!void {
            if (headers.len == 0) return;
            _ = try self.nextPacketHeader(r, 0) orelse unreachable;

            const header_block = Offset.header(self).bytes;
            const body = Offset.body(self).bytes;
            r.discardAll(header_block) catch |err| {
                switch (err) {
                    error.ReadFailed => |new_error| return new_error,
                    error.EndOfStream => unreachable,
                }
            };

            signal_data.start_epoch = headers[0].epoch;
            const end_epoch = headers[headers.len - 1].epoch + 1;
            var epoch: u64 = signal_data.start_epoch;

            try signal_data.headers.ensureTotalCapacityPrecise(signal_data.allocator, @intCast(end_epoch - signal_data.start_epoch));
            for (headers) |header| {
                if (epoch > header.epoch or header.epoch >= end_epoch) {
                    @branchHint(.cold);
                    if (epoch - 1 == header.epoch) {
                        std.log.warn("Header {d} followed by header {d}. Truncating to latest appreance of the header.", .{ epoch - 1, header.epoch });
                        signal_data.headers.items.len = @intCast(header.epoch - signal_data.start_epoch);
                    } else {
                        @branchHint(.cold);
                        if (header.epoch >= end_epoch) {
                            std.log.err("Header {d} outside expected range {{{d}, ..., {d}}}. Unable to keep parsing.", .{ header.epoch, signal_data.start_epoch, end_epoch - 1 });
                        } else {
                            std.log.err("Header {d} followed by header {d}. Unable to keep parsing.", .{ epoch - 1, header.epoch });
                        }
                        return error.BadFile;
                    }
                } else {
                    signal_data.headers.appendNTimesAssumeCapacity(.{
                        .start = @intCast(header.start),
                        .size = 0,
                    }, @intCast(header.epoch - epoch));
                }
                signal_data.headers.appendAssumeCapacity(.{
                    .start = @intCast(header.start),
                    .size = @intCast(header.size),
                });
                epoch = header.epoch + 1;
                const elems = try signal_data.array.addManyAsSlice(signal_data.allocator, header.size);
                for (elems) |*elem| {
                    const bytes = r.take(body) catch |err| {
                        switch (err) {
                            error.ReadFailed => |new_error| return new_error,
                            error.EndOfStream => unreachable,
                        }
                    };
                    elem.* = self.parsePacket(bytes, header);
                }
                r.discardAll(header_block) catch |err| {
                    switch (err) {
                        error.ReadFailed => |new_error| return new_error,
                        error.EndOfStream => unreachable,
                    }
                };
            }
        }

        /// Computes the size of the block and parses the dat file header
        /// Leaves the reader position on the next header
        fn parseHeader(self: Parser, r: *Reader, start: u32) error{ReadFailed}!?Header {
            const header_size = Offset.header(self).bytes;
            const preserve_size = Offset.preserve(self).bytes;

            const size = try self.nextPacketHeader(r, header_size) orelse return null;
            const header = peekPreserve(r, preserve_size, header_size, false) catch |err| {
                switch (err) {
                    error.ReadFailed => |new_error| return new_error,
                    error.EndOfStream => return null,
                }
            };

            return parseHeaderInner(self, header, start, size);
        }

        fn parseHeaderInner(self: Parser, header: []const u8, start: u32, size: usize) Header {
            const header_size = Offset.header(self).bytes;
            const body_size = Offset.body(self).bytes;

            var header_reader: Reader = .fixed(header);
            // xxxxxxxx_1xxxxxxx
            // xxxxxxxx_1xxxxxxx
            // ssmmmmmm_1xxxssss
            // DDDDMMMM_1xhhhhhD
            var time: [4]u16 = undefined;
            header_reader.readSliceEndian(u16, &time, .little) catch unreachable;

            var epoch: u32 = 0;
            // Add seconds
            epoch += @as(u32, time[2] >> 6) & 0x003F;
            // Add minutes
            epoch += @as(u32, time[2] & 0x003F) * std.time.s_per_min;
            // Add hours
            epoch += @as(u32, (time[3] >> 9) & 0x001F) * std.time.s_per_hour;

            const count = @divExact(size - header_size, body_size);
            const correction = switch (self.version) {
                6...9 => 0,
                10...13 => blk: {
                    const absolute_value: i16 = @intCast(toNative(header, 6) & 0x7FFF);
                    const sign: i16 = if ((toNative(header, 1) & 0x4000) == 0) -1 else 1;
                    break :blk sign * absolute_value;
                },
                else => unreachable,
            };

            return .{
                .start = start,
                .size = @intCast(count),
                .epoch = @intCast(epoch),
                .count_correction = correction,
            };
        }

        fn parsePacket(self: Parser, bytes: []const u8, header: Header) data.types.Signal {
            return switch (self.version) {
                10, 12 => blk: {
                    // nnnnnnnn_0aaaannn
                    // mmmmmmmm_11mmmmmm
                    // XXXXXXXX_0aaaaaaa
                    const micro: u28 = toNative(bytes, 1) & 0x3FFF;
                    const nano: u16 = toNative(bytes, 0) & 0x07FF;
                    const above_high: u12 = @intCast((toNative(bytes, 2) >> 4) & 0x07F0);
                    const above_low: u12 = @intCast((toNative(bytes, 0) >> 11) & 0x000F);
                    const packet = .{
                        .nano_x40 = 2000 * micro + nano,
                        .max = bytes[4],
                        .above = above_high + above_low,
                    };
                    const factor: f64 = std.time.ns_per_s / (std.time.ns_per_s / 40.0 + cast.to(f64, header.count_correction));
                    break :blk .{
                        .nanosecond = @intFromFloat(@round(4 * cast.to(f64, packet.nano_x40) * factor)),
                        .dBm = 0.488 * cast.to(f16, packet.max) - 111.0,
                        .padding = packet.above,
                    };
                },
                else => unreachable,
            };
        }

        test parseHeaderInner {
            var parser: Parser = undefined;
            var bytes: [latest_version]?[]const []const u8 = @splat(null);
            var header: [latest_version]?[]const Header = @splat(null);
            bytes[12] = &.{
                "0-\x00\x40\x59\x0B\x00\x064-5-\x39\x307-8-9-",
                "0-\xFF\xBF\x64\xA4\x71\x2B4-5-\x39\x307-8-9-",
            };
            header[12] = &.{
                .{ .count_correction = 12345, .start = 123, .size = (2520 - 18) / 6, .epoch = 12345 },
                .{ .count_correction = -12345, .start = 123, .size = (2520 - 18) / 6, .epoch = 77777 },
            };

            for (supported_versions) |version| {
                parser.version = version;
                for (bytes[version].?, header[version].?, 1..) |in, out, idx| {
                    const parsed = parser.parseHeaderInner(in, 123, 2520);
                    std.testing.expectEqual(
                        out,
                        parsed,
                    ) catch |err| {
                        std.debug.print("Failed to parse metadata {d} in version {d}.\n", .{ idx, version });
                        std.debug.print("Expected {any} but found {any}.\n", .{ out, parsed });
                        return err;
                    };
                }
            }
        }

        test parsePacket {
            var parser: Parser = undefined;
            var bytes: [latest_version]?[]const []const u8 = @splat(null);
            var header: [latest_version]?[]const Header = @splat(null);
            var signal: [latest_version]?[]const data.types.Signal = @splat(null);

            bytes[12] = &.{"\x8E\x16\x1C\x18\x7B\x4D"};
            header[12] = &.{.{ .start = 0, .size = 1, .epoch = 0, .count_correction = 0 }};
            signal[12] = &.{.{
                .nanosecond = 4 * 40 * 12345678,
                .dBm = 0.488 * 123.0 - 111.0,
                .padding = 1234,
            }};

            for (supported_versions) |version| {
                parser.version = version;
                for (bytes[version].?, header[version].?, signal[version].?, 1..) |in, extra, out, idx| {
                    const parsed = parser.parsePacket(in, extra);
                    std.testing.expectEqual(
                        out,
                        parsed,
                    ) catch |err| {
                        std.debug.print("Failed to parse packet {d} in version {d}.\n", .{ idx, version });
                        std.debug.print("Expected {any} but found {any}.\n", .{ out, parsed });
                        return err;
                    };
                }
            }
        }

        test "supported_versions" {
            comptime {
                var parser: Parser = .{ .pattern = 0, .version = undefined };
                for (supported_versions) |version| {
                    parser.version = version;
                    var r: Reader = .fixed(&.{});
                    _ = parser.nextPacketHeader(&r, 0) catch unreachable;
                    const header_buffer: [Offset.header(parser).bytes]u8 = @splat(0xAA);
                    const header = parser.parseHeaderInner(&header_buffer, 0, Offset.header(parser).bytes);
                    const packet_buffer: [Offset.body(parser).bytes]u8 = @splat(0xAA);
                    _ = parser.parsePacket(&packet_buffer, header);
                }
            }
        }

        const Offset = struct {
            count: usize,
            bytes: usize,

            fn init(count: usize) Offset {
                return .{
                    .count = count,
                    .bytes = 2 * count,
                };
            }

            fn header(self: Parser) Offset {
                return .init(switch (self.version) {
                    6...7 => 4,
                    8...9 => 6,
                    10...13 => 9,
                    else => unreachable,
                });
            }

            fn body(self: Parser) Offset {
                return .init(switch (self.version) {
                    6...13 => 3,
                    else => unreachable,
                });
            }

            fn preserve(self: Parser) Offset {
                return .init(switch (self.version) {
                    6...13 => 9,
                    else => unreachable,
                });
            }

            test "supported_versions" {
                comptime {
                    var parser: Parser = undefined;
                    for (supported_versions) |version| {
                        parser.version = version;
                        _ = Offset.header(parser);
                        _ = Offset.body(parser);
                        _ = Offset.preserve(parser);
                    }
                }
            }
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
