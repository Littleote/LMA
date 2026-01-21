const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const lma = @import("../lma.zig");
const data = lma.data;
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
            std.log.err("Falied to convert at index {d}. Expected {x}, but got {x}.\n", .{ idx, value, toNative(bytes, idx) });
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

        pub const vtable: Reader.VTable = .{
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

    // Works when seek is less than preseve target
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
fn parseEpoch(bytes: []const u8) !usize {
    const number = std.mem.trimStart(u8, bytes, " ");
    return std.fmt.parseInt(usize, number, 10);
}

test parseEpoch {
    const epoch_1234 = try parseEpoch("       1234");
    const epoch_5678 = try parseEpoch("5678");

    try std.testing.expect(epoch_1234 == 1234);
    try std.testing.expect(epoch_5678 == 5678);
}

pub const toa = struct {
    /// Load a Time of Arrival '.dat' file from a seeking file reader
    pub fn fromFile(file_reader: *std.fs.File.Reader, gpa: Allocator) !data.ToA {
        const parser: Parser = try .init(&file_reader.interface);

        file_reader.seekTo(0) catch unreachable;
        var dat_headers: std.ArrayList(Header) = .empty;
        defer dat_headers.deinit(gpa);
        try parser.parseAllHeaders(&file_reader.interface, gpa, &dat_headers);

        file_reader.seekTo(0) catch unreachable;
        return parser.parse(&file_reader.interface, gpa, &dat_headers);
    }

    /// Load a Time of Arrival '.dat' file from a reader
    pub fn fromReader(r: *Reader, gpa: Allocator) !data.ToA {
        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();
        _ = try r.streamRemaining(&writer.writer);

        return fromBuffer(writer.written(), gpa);
    }

    /// Load a Time of Arrival '.dat' file from a buffer
    pub fn fromBuffer(buffer: []const u8, gpa: Allocator) !data.ToA {
        var reader: Reader = .fixed(buffer);
        const parser: Parser = try .init(&reader);

        reader.seek = 0;
        var dat_headers: std.ArrayList(Header) = .empty;
        defer dat_headers.deinit(gpa);
        try parser.parseAllHeaders(&reader, gpa, &dat_headers);

        reader.seek = 0;
        return parser.parse(&reader, gpa, &dat_headers);
    }

    pub const Header = struct {
        start: u32,
        epoch: u32,
        size: u16,
        count_correction: i16 = 0,
    };

    pub const Parser = struct {
        pub const latest_version = 13;
        const tested_versions = [_]usize{12};

        version: usize,
        pattern: u16,

        /// Initialize the parser constants for the given file
        pub fn init(r: *Reader) error{ ReadFailed, EndOfStream }!Parser {
            var lookahead: []u8 = undefined;
            const packet_start: u16 = while (true) {
                lookahead = try r.peek(4);
                if (lookahead[1] >> 7 == 1 and lookahead[3] >> 7 == 1) {
                    break toNative(lookahead, 0);
                }
                r.toss(2);
            };

            return .{
                .version = (packet_start >> 7) & 0x001F,
                .pattern = packet_start & masks.pattern,
            };
        }

        /// Advance the reader until the header of the next packet found
        pub fn nextPacketHeader(self: Parser, r: *Reader, skip: usize) error{
            UnsupportedVersion,
            ReadFailed,
            EndOfStream,
        }!usize {
            return switch (self.version) {
                10...13 => blk: {
                    const lookbehind: Offset = comptime .init(9);
                    const lookahead: Offset = comptime .init(8);
                    const preserved: Offset = comptime .init(lookbehind.count + lookahead.count);
                    std.debug.assert(lookbehind.count == (try Offset.preserve(self)).count);

                    const even = ~@as(usize, 1);
                    const start = @max(lookahead.bytes, skip);

                    _ = try peekPreserve(r, preserved.bytes, start, false);
                    var consumed: usize = start;
                    r.toss(start);

                    loop: while (true) {
                        while (true) {
                            const buffer = try peekPreserve(r, preserved.bytes, 2, true);
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
                                    // Keep u16 alignement and ignore bad match
                                    const discarded = 2 + (idx & even);
                                    consumed += discarded;
                                    r.toss(discarded);
                                }
                            } else {
                                // Keep u16 alignement
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
                        std.debug.assert(r.seek >= lookahead.bytes);
                        r.seek -= lookahead.bytes;
                        found = true;
                        if (r.seek < lookbehind.bytes) break :loop;
                        var packet_header: [lookbehind.count]u16 = undefined;
                        r.seek -= lookbehind.bytes;
                        try r.readSliceEndian(u16, &packet_header, .little);
                        const pattern = packet_header[lookbehind.count - 9] & masks.pattern;
                        const alternate_pattern = packet_header[lookbehind.count - 1] & masks.alternate;
                        if (alternate_pattern == 0 or pattern == self.pattern) break :loop;
                        // Only execute if no code path exited
                        found = false;
                    }
                    break :blk consumed - lookahead.bytes;
                },
                else => error.UnsupportedVersion,
            };
        }

        /// Proces an entire file saving the header metadata into the data struct
        pub fn parseAllHeaders(
            self: Parser,
            r: *Reader,
            gpa: Allocator,
            headers: *std.ArrayList(Header),
        ) error{
            UnsupportedVersion,
            ReadFailed,
            OutOfMemory,
        }!void {
            _ = self.nextPacketHeader(r, 0) catch |err| {
                switch (err) {
                    error.EndOfStream => return,
                    else => |new_err| return new_err,
                }
            };

            var start: u32 = 0;
            while (self.parseHeader(r, start)) |header| {
                start += header.size;
                try headers.append(gpa, header);
            } else |err| {
                switch (err) {
                    error.EndOfStream => {},
                    else => |new_err| return new_err,
                }
            }
        }

        /// Proces an entire file given the header metadata
        /// saving the packet information into the data struct
        pub fn parse(
            self: Parser,
            r: *Reader,
            gpa: Allocator,
            headers: *const std.ArrayList(Header),
        ) error{
            ReadFailed,
            OutOfMemory,
            UnsupportedVersion,
        }!data.ToA {
            var parsed: data.ToA = .init(gpa);
            errdefer parsed.deinit();
            if (headers.items.len == 0) return parsed;
            _ = self.nextPacketHeader(r, 0) catch |err| {
                switch (err) {
                    error.ReadFailed => |new_error| return new_error,
                    error.UnsupportedVersion, error.EndOfStream => unreachable,
                }
            };

            // Reading headers already needs these values to exist
            const start = (Offset.start(self) catch unreachable).bytes;
            const offset = start + (Offset.end(self) catch unreachable).bytes;
            const body = (Offset.body(self) catch unreachable).bytes;
            r.discardAll(start) catch |err| {
                switch (err) {
                    error.ReadFailed => |new_error| return new_error,
                    error.EndOfStream => unreachable,
                }
            };

            try parsed.headers.ensureTotalCapacityPrecise(gpa, headers.items.len);
            for (headers.items) |header| {
                parsed.headers.appendAssumeCapacity(.{
                    .start = @intCast(header.start),
                    .size = @intCast(header.size),
                    .epoch = @intCast(header.epoch),
                });
                try parsed.array.ensureUnusedCapacity(gpa, header.size);
                for (0..header.size) |_| {
                    const bytes = r.take(body) catch |err| {
                        switch (err) {
                            error.ReadFailed => |new_error| return new_error,
                            error.EndOfStream => unreachable,
                        }
                    };
                    parsed.array.appendAssumeCapacity(try self.parsePacket(bytes, header));
                }
                r.discardAll(offset) catch |err| {
                    switch (err) {
                        error.ReadFailed => |new_error| return new_error,
                        error.EndOfStream => unreachable,
                    }
                };
            }
            return parsed;
        }

        /// Computes the size of the block and parses the dat file header
        /// Leaves the reader position on the next header
        pub fn parseHeader(self: Parser, r: *Reader, start: u32) !Header {
            const start_offset = (try Offset.start(self)).bytes;
            const preserve_size = (try Offset.preserve(self)).bytes;

            const size = try self.nextPacketHeader(r, start_offset);
            const header = try peekPreserve(r, preserve_size, start_offset, false);

            return parseHeaderInner(self, header, start, size);
        }

        pub fn parseHeaderInner(self: Parser, header: []const u8, start: u32, size: usize) !Header {
            const start_offset = (try Offset.start(self)).bytes;
            const end_offset = (try Offset.end(self)).bytes;
            const body_size = (try Offset.body(self)).bytes;

            var header_reader: Reader = .fixed(header);
            // xxxxxxxx_xxxxxxxx
            // xxxxxxxx_xxxxxxxx
            // ssmmmmmm_xxxxssss
            // xxxxxxxx_xxhhhhhx
            var time: [4]u16 = undefined;
            header_reader.readSliceEndian(u16, &time, .little) catch unreachable;

            var epoch: u32 = 0;
            // Add seconds
            epoch += @as(u32, time[2] >> 6) & 0x003F;
            // Add minutes
            epoch += @as(u32, time[2] & 0x003F) * std.time.s_per_min;
            // Add hours
            epoch += @as(u32, (time[3] >> 9) & 0x001F) * std.time.s_per_hour;

            const count = @divExact(size - start_offset - end_offset, body_size);
            const correction = switch (self.version) {
                6...9 => 0,
                10...13 => blk: {
                    const absolute_value: i16 = @intCast(toNative(header, 6) & 0x7FFF);
                    const sign: i16 = if ((toNative(header, 1) & 0x4000) == 0) -1 else 1;
                    break :blk sign * absolute_value;
                },
                else => return error.UnsupportedVersion,
            };

            return .{
                .start = start,
                .size = @intCast(count),
                .epoch = @intCast(epoch),
                .count_correction = correction,
            };
        }

        pub fn parsePacket(self: Parser, bytes: []const u8, header: Header) Unsupported!data.types.ToA {
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
                    const factor: f64 = std.time.ns_per_s / (std.time.ns_per_s / 40.0 + lma.math.cast(f64, header.count_correction));
                    break :blk .{
                        .nanosecond = @intFromFloat(@round(4 * lma.math.cast(f64, packet.nano_x40) * factor)),
                        .dBm = 0.488 * lma.math.cast(f16, packet.max) - 111.0,
                        .padding = packet.above,
                    };
                },
                else => error.UnsupportedVersion,
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
                .{ .count_correction = 12345, .start = 123, .size = (2520 - 24) / 6, .epoch = 12345 },
                .{ .count_correction = -12345, .start = 123, .size = (2520 - 24) / 6, .epoch = 77777 },
            };

            for (tested_versions) |version| {
                parser.version = version;
                for (bytes[version].?, header[version].?, 1..) |input, output, idx| {
                    const parsed = parser.parseHeaderInner(input, 123, 2520) catch unreachable;
                    std.testing.expectEqual(
                        output,
                        parsed,
                    ) catch |err| {
                        std.log.err("Failed to parse metadata {d} in version {d}.\n", .{ idx, version });
                        std.log.err("Expected {any} but found {any}.\n", .{ output, parsed });
                        return err;
                    };
                }
            }
        }

        test parsePacket {
            var parser: Parser = undefined;
            var bytes: [latest_version]?[]const []const u8 = @splat(null);
            var header: [latest_version]?[]const Header = @splat(null);
            var signal: [latest_version]?[]const data.types.ToA = @splat(null);

            bytes[12] = &.{"\x8E\x16\x1C\x18\x7B\x4D"};
            header[12] = &.{.{ .start = 0, .size = 1, .epoch = 0, .count_correction = 0 }};
            signal[12] = &.{.{
                .nanosecond = 4 * 40 * 12345678,
                .dBm = 0.488 * 123.0 - 111.0,
                .padding = 1234,
            }};

            for (tested_versions) |version| {
                parser.version = version;
                for (bytes[version].?, header[version].?, signal[version].?, 1..) |input, extra, output, idx| {
                    const parsed = parser.parsePacket(input, extra) catch unreachable;
                    std.testing.expectEqual(
                        output,
                        parsed,
                    ) catch |err| {
                        std.log.err("Failed to parse packet {d} in version {d}.\n", .{ idx, version });
                        std.log.err("Expected {any} but found {any}.\n", .{ output, parsed });
                        return err;
                    };
                }
            }
        }

        pub const Offset = struct {
            count: usize,
            bytes: usize,

            pub fn init(count: usize) Offset {
                return .{
                    .count = count,
                    .bytes = 2 * count,
                };
            }

            pub fn start(self: Parser) Unsupported!Offset {
                return .init(switch (self.version) {
                    6...7 => 4,
                    8...9 => 6,
                    10...13 => 9,
                    else => return error.UnsupportedVersion,
                });
            }

            pub fn end(self: Parser) Unsupported!Offset {
                return .init(switch (self.version) {
                    6...13 => 3,
                    else => return error.UnsupportedVersion,
                });
            }

            pub fn body(self: Parser) Unsupported!Offset {
                return .init(switch (self.version) {
                    6...13 => 3,
                    else => return error.UnsupportedVersion,
                });
            }

            pub fn preserve(self: Parser) Unsupported!Offset {
                return .init(switch (self.version) {
                    6...13 => 9,
                    else => return error.UnsupportedVersion,
                });
            }

            test "version_constants" {
                var parser: Parser = undefined;
                for (tested_versions) |version| {
                    parser.version = version;
                    _ = Offset.start(parser) catch {
                        std.log.err("Failed to find 'start' constant in version {d}.\n", .{version});
                        return error.TestFailed;
                    };
                    _ = Offset.end(parser) catch {
                        std.log.err("Failed to find 'end' constant in version {d}.\n", .{version});
                        return error.TestFailed;
                    };
                    _ = Offset.body(parser) catch {
                        std.log.err("Failed to find 'body' constant in version {d}.\n", .{version});
                        return error.TestFailed;
                    };
                    _ = Offset.preserve(parser) catch {
                        std.log.err("Failed to find 'preserve' constant in version {d}.\n", .{version});
                        return error.TestFailed;
                    };
                }
            }
        };
    };
};

pub fn parseOutput(maybe_points: ?*data.Points, maybe_stations: ?*data.Stations, r: *Reader) !?usize {
    var start_time: ?usize = null;
    var header_count: ?usize = null;
    var values_count: ?usize = null;
    var station_count: ?usize = null;

    // Advance to station informtion
    while (try r.takeDelimiter('\n')) |line| {
        if (std.mem.startsWith(u8, line, "Number of seconds")) {
            header_count = try std.fmt.parseInt(usize, line[28..], 10);
        } else if (std.mem.startsWith(u8, line, "Number of stations")) {
            station_count = try std.fmt.parseInt(usize, line[20..], 10);
        } else if (std.mem.startsWith(u8, line, "Data start time")) {
            const time = line[line.len - 8 ..];
            const hour = try std.fmt.parseInt(usize, time[0..2], 10);
            const minute = try std.fmt.parseInt(usize, time[3..5], 10);
            const second = try std.fmt.parseInt(usize, time[6..8], 10);
            start_time = (hour * 60 + minute) * 60 + second;
        } else if (std.mem.startsWith(u8, line, "Station information")) {
            break;
        }
    } else return error.EndOfStream;

    if (maybe_points == null and maybe_stations == null) return start_time;

    // Parse station information
    if (maybe_stations) |stations| {
        try stations.stations.ensureTotalCapacityPrecise(stations.allocator, station_count.?);

        for (0..station_count.?) |_| {
            const current_station = stations.stations.addOneAssumeCapacity();
            current_station.* = .init;
            const line = (try r.takeDelimiter('\n')).?;
            var iterator = std.mem.tokenizeScalar(u8, line, ' ');
            var column: usize = 0;
            while (iterator.next()) |token| {
                if (token.len == 0) continue;
                switch (column) {
                    0, 1 => {},
                    2 => {
                        current_station.name = try stations.allocator.dupe(u8, token);
                    },
                    3 => {
                        current_station.latitude = try std.fmt.parseFloat(f64, token);
                    },
                    4 => {
                        current_station.longitude = try std.fmt.parseFloat(f64, token);
                    },
                    5 => {
                        current_station.altitude = try std.fmt.parseFloat(f64, token);
                    },
                    6 => {
                        current_station.delay = try std.fmt.parseFloat(f64, token);
                    },
                    7, 8 => break,
                    else => unreachable,
                }
                column += 1;
            }
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
                values_count = try std.fmt.parseInt(usize, line[18..], 10);
            } else if (std.mem.startsWith(u8, line, "*** data ***")) {
                @branchHint(.unlikely);
                break;
            }
        } else return error.EndOfStream;

        if (values_count == 0) break :blk;

        try parsePoints(points, header_count.? + 1, values_count.?, r);
    }

    // No else branch necessaryto synchronize the readers as all code paths end here
    return start_time;
}

pub fn parsePoints(points: *data.Points, headers: usize, entries: usize, r: *Reader) !void {
    if (headers == 0 or entries == 0) return;

    // Parse data section
    try points.headers.ensureTotalCapacityPrecise(points.allocator, headers);
    try points.array.ensureTotalCapacityPrecise(points.allocator, entries);

    const peek_line = try r.peekDelimiterExclusive('\n');

    var last_epoch: [5]u8 = undefined;
    @memcpy(&last_epoch, peek_line[0..5]);
    points.headers.appendAssumeCapacity(.{
        .start = 0,
        .size = 0,
        .epoch = @intCast(try parseEpoch(&last_epoch)),
    });
    var last_header = &points.headers.items[0];
    defer last_header.size = @intCast(points.array.items.len - last_header.start);

    while (try r.takeDelimiter('\n')) |line| {
        if (!std.mem.eql(u8, &last_epoch, line[0..5])) {
            @memcpy(&last_epoch, line[0..5]);
            last_header.size = @intCast(points.array.items.len - last_header.start);
            last_header = points.headers.addOneAssumeCapacity();
            last_header.* = .{
                .start = @intCast(points.array.items.len),
                .size = 0,
                .epoch = @intCast(try parseEpoch(&last_epoch)),
            };
        }
        const current_value = points.array.addOneAssumeCapacity();

        var iterator = std.mem.tokenizeScalar(u8, line, ' ');
        var column: usize = 0;
        while (iterator.next()) |token| {
            if (token.len == 0) continue;
            switch (column) {
                0 => {
                    current_value.nanosecond = 4 * try std.fmt.parseInt(u32, token[token.len - 9 ..], 10);
                },
                1 => {
                    current_value.latitude = try std.fmt.parseFloat(f32, token);
                },
                2 => {
                    current_value.longitude = try std.fmt.parseFloat(f32, token);
                },
                3 => {
                    current_value.altitude = try std.fmt.parseFloat(f32, token);
                },
                4 => {
                    current_value.measure_error = try std.fmt.parseFloat(f16, token);
                },
                5 => {
                    current_value.dBm = try std.fmt.parseFloat(f16, token);
                },
                6 => {
                    current_value.station_mask = try std.fmt.parseInt(u32, token[2..], 16);
                },
                else => unreachable,
            }
            column += 1;
        }
        std.debug.assert(column == 7);
    }
}

comptime {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(toa.Parser);
}
