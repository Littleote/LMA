const std = @import("std");
const Reader = std.Io.Reader;

const data = @import("../data.zig");
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
    // TODO
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

pub const ToAParser = struct {
    pub const latest_version = 13;
    const tested_versions = [_]usize{12};

    version: usize,
    pattern: u16,

    /// Initialize the parser constants for the given file
    pub fn init(r: *Reader) error{ ReadFailed, EndOfStream }!ToAParser {
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
    pub fn nextPacketHeader(self: ToAParser, r: *Reader, skip: usize) error{
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
        self: ToAParser,
        toa: *data.ToA,
        r: *Reader,
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
        while (self.parseHeader(start, r)) |header_info| {
            const header, const metadata = header_info;
            start += header.size;
            try toa.metadata.append(toa.gpa, metadata);
            try toa.header.append(toa.gpa, header);
        } else |err| {
            switch (err) {
                error.EndOfStream => {},
                else => |new_err| return new_err,
            }
        }
    }

    /// Proces an entire file given the header metadata
    /// saving the packet information into the data struct
    pub fn parseAllPackets(
        self: ToAParser,
        toa: *data.ToA,
        r: *Reader,
    ) error{
        ReadFailed,
        OutOfMemory,
        UnsupportedVersion,
    }!void {
        if (toa.header.items.len == 0) return;
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

        toa.packet.items.len = 0;
        for (toa.header.items) |header| {
            try toa.packet.ensureUnusedCapacity(toa.gpa, header.size);
            for (0..header.size) |_| {
                const bytes = r.take(body) catch |err| {
                    switch (err) {
                        error.ReadFailed => |new_error| return new_error,
                        error.EndOfStream => unreachable,
                    }
                };
                toa.packet.appendAssumeCapacity(try self.parsePacket(bytes));
            }
            r.discardAll(offset) catch |err| {
                switch (err) {
                    error.ReadFailed => |new_error| return new_error,
                    error.EndOfStream => unreachable,
                }
            };
        }
    }

    /// Computes the size of the block and parses the metadata of the header
    /// Leaves the reader position on the next header
    pub fn parseHeader(self: ToAParser, start: u32, r: *Reader) !struct { data.ToA.Header, data.ToA.Metadata } {
        const start_offset = (try Offset.start(self)).bytes;
        const end_offset = (try Offset.end(self)).bytes;
        const body_size = (try Offset.body(self)).bytes;
        const preserve_size = (try Offset.preserve(self)).bytes;

        const size = try self.nextPacketHeader(r, start_offset);

        const header_info = try peekPreserve(r, preserve_size, start_offset, false);

        var header_reader: Reader = .fixed(header_info);
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
        return .{
            .{
                .start = start,
                .size = @intCast(count),
                .epoch = @intCast(epoch),
            },
            try self.parseMetadata(
                header_info,
            ),
        };
    }

    pub fn parseMetadata(self: ToAParser, bytes: []const u8) Unsupported!data.ToA.Metadata {
        return switch (self.version) {
            6...9 => .blank,
            10...13 => blk: {
                const absolute_value: i16 = @intCast(toNative(bytes, 6) & 0x7FFF);
                const sign: i16 = if ((toNative(bytes, 1) & 0x4000) == 0) -1 else 1;
                break :blk .{ .pd = sign * absolute_value };
            },
            else => return error.UnsupportedVersion,
        };
    }

    pub fn parsePacket(self: ToAParser, bytes: []const u8) Unsupported!data.ToA.Body.Packet {
        return switch (self.version) {
            10, 12 => blk: {
                // nnnnnnnn_0aaaannn
                // mmmmmmmm_11mmmmmm
                // XXXXXXXX_0aaaaaaa
                const micro: u28 = toNative(bytes, 1) & 0x3FFF;
                const nano: u16 = toNative(bytes, 0) & 0x07FF;
                const above_high: u12 = @intCast((toNative(bytes, 2) >> 4) & 0x07F0);
                const above_low: u12 = @intCast((toNative(bytes, 0) >> 11) & 0x000F);
                break :blk .{
                    .nano_x40 = 2000 * micro + nano,
                    .max = bytes[4],
                    .above = above_high + above_low,
                };
            },
            else => error.UnsupportedVersion,
        };
    }

    test parseMetadata {
        var parser: ToAParser = undefined;
        var bytes: [latest_version]?[]const []const u8 = @splat(null);
        var metadata: [latest_version]?[]const data.ToA.Metadata = @splat(null);
        bytes[12] = &.{
            "0-\x00\x402-3-4-5-\x39\x307-8-9-",
            "0-\xFF\xBF2-3-4-5-\x39\x307-8-9-",
        };
        metadata[12] = &.{
            .{ .pd = 12345 },
            .{ .pd = -12345 },
        };

        for (tested_versions) |version| {
            parser.version = version;
            for (bytes[version].?, metadata[version].?, 1..) |input, output, idx| {
                std.testing.expectEqual(
                    output,
                    parser.parseMetadata(input) catch unreachable,
                ) catch |err| {
                    std.log.err("Failed to parse metadata {d} in version {d}.\n", .{ idx, version });
                    return err;
                };
            }
        }
    }

    test parsePacket {
        var parser: ToAParser = undefined;
        var bytes: [latest_version]?[]const []const u8 = @splat(null);
        var packet: [latest_version]?[]const data.ToA.Body.Packet = @splat(null);

        bytes[12] = &.{"\x8E\x16\x1C\x18\x7B\x4D"};
        packet[12] = &.{.{
            .nano_x40 = 12345678,
            .above = 1234,
            .max = 123,
        }};

        for (tested_versions) |version| {
            parser.version = version;
            for (bytes[version].?, packet[version].?, 1..) |input, output, idx| {
                std.testing.expectEqual(
                    output,
                    parser.parsePacket(input) catch unreachable,
                ) catch |err| {
                    std.log.err("Failed to parse packet {d} in version {d}.\n", .{ idx, version });
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

        pub fn start(self: ToAParser) Unsupported!Offset {
            return .init(switch (self.version) {
                6...7 => 4,
                8...9 => 6,
                10...13 => 9,
                else => return error.UnsupportedVersion,
            });
        }

        pub fn end(self: ToAParser) Unsupported!Offset {
            return .init(switch (self.version) {
                6...13 => 3,
                else => return error.UnsupportedVersion,
            });
        }

        pub fn body(self: ToAParser) Unsupported!Offset {
            return .init(switch (self.version) {
                6...13 => 3,
                else => return error.UnsupportedVersion,
            });
        }

        pub fn preserve(self: ToAParser) Unsupported!Offset {
            return .init(switch (self.version) {
                6...13 => 9,
                else => return error.UnsupportedVersion,
            });
        }

        test "version_constants" {
            var parser: ToAParser = undefined;
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
        try stations.stations.ensureTotalCapacityPrecise(stations.gpa, station_count.?);

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
                        current_station.name = try stations.gpa.dupe(u8, token);
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

pub fn parsePoints(points: *data.Points, headers: usize, values: usize, r: *Reader) !void {
    if (headers == 0 or values == 0) return;

    // Parse data section
    try points.header.ensureTotalCapacityPrecise(points.gpa, headers);
    try points.value.ensureTotalCapacityPrecise(points.gpa, values);

    const peek_line = try r.peekDelimiterExclusive('\n');

    var last_epoch: [5]u8 = undefined;
    var last_header: *data.Points.Header = undefined;
    @memcpy(&last_epoch, peek_line[0..5]);
    points.header.appendAssumeCapacity(.{
        .start = 0,
        .size = 0,
        .epoch = @intCast(try parseEpoch(&last_epoch)),
    });
    last_header = &points.header.items[0];
    defer last_header.size = @intCast(points.value.items.len - last_header.start);

    while (try r.takeDelimiter('\n')) |line| {
        if (!std.mem.eql(u8, &last_epoch, line[0..5])) {
            @memcpy(&last_epoch, line[0..5]);
            last_header.size = @intCast(points.value.items.len - last_header.start);
            last_header = points.header.addOneAssumeCapacity();
            last_header.* = .{
                .start = @intCast(points.value.items.len),
                .size = 0,
                .epoch = @intCast(try parseEpoch(&last_epoch)),
            };
        }
        const current_value = points.value.addOneAssumeCapacity();

        var iterator = std.mem.tokenizeScalar(u8, line, ' ');
        var column: usize = 0;
        while (iterator.next()) |token| {
            if (token.len == 0) continue;
            switch (column) {
                0 => {
                    current_value.nanosecond = 1e-9 * try std.fmt.parseFloat(f64, token[token.len - 9 ..]);
                },
                1 => {
                    current_value.latitude = try std.fmt.parseFloat(f64, token);
                },
                2 => {
                    current_value.longitude = try std.fmt.parseFloat(f64, token);
                },
                3 => {
                    current_value.altitude = try std.fmt.parseFloat(f32, token);
                },
                4 => {
                    current_value.measure_error = try std.fmt.parseFloat(f16, token);
                },
                5 => {
                    current_value.dBW = try std.fmt.parseFloat(f16, token);
                },
                6 => {
                    current_value.station_mask = try std.fmt.parseInt(u64, token[2..], 16);
                },
                else => unreachable,
            }
            column += 1;
        }
        std.debug.assert(column == 7);
    }
}
