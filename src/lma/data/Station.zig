const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const dat_file = @import("dat_file.zig");

const Station = @This();

const log = std.log.scoped(lma.log.hierarchy.station_file);

station_id: Id,
network_id: Id,
name: []const u8,
latitude: f64,
longitude: f64,
altitude: f32,
delay: i32,
revision: u8,
channel: u8,

pub const Id = enum(u8) { _ };

pub fn stationLetter(self: *const Station) u8 {
    return idToLetter(self.station_id);
}

pub fn idToLetter(station_id: Id) u8 {
    return @backingInt(station_id) +| 0x40;
}

pub fn letterToId(station_letter: u8) Id {
    return @fromBackingInt(std.ascii.toUpper(station_letter) -| 0x40);
}

pub fn point(self: *const Station) lma.math(f64).ElemVec {
    return .{ .elems = .{ self.latitude, self.longitude, self.altitude, 0 } };
}

pub const List = struct {
    stations: std.ArrayList(Station),
    network_names: std.SinglyLinkedList,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) List {
        return .{
            .stations = .empty,
            .network_names = .{},
            .allocator = gpa,
            .arena = .init(gpa),
        };
    }

    pub fn deinit(self: *List) void {
        self.stations.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn appendNetwork(self: *List, id: Id, name: []const u8) error{OutOfMemory}!void {
        if (self.findNetworkId(id) != null) return;
        const node = try self.arena.allocator().create(Network);
        node.* = .{ .id = id, .name = try self.arena.allocator().dupe(u8, name) };
        self.network_names.prepend(&node.node);
    }

    pub fn findNetworkId(self: *const List, network_id: Id) ?*Network {
        var maybe_node = self.network_names.first;
        while (maybe_node) |node| {
            defer maybe_node = node.next;
            const network: *Network = @fieldParentPtr("node", node);
            if (network.id == network_id) return network;
        }
        return null;
    }

    pub fn findNetworkName(self: *const List, network_name: []const u8) ?*Network {
        var maybe_node = self.network_names.first;
        while (maybe_node) |node| {
            defer maybe_node = node.next;
            const network: *Network = @fieldParentPtr("node", node);
            if (std.mem.eql(u8, network.name, network_name)) return network;
        }
        return null;
    }

    pub fn fmtNetwork(self: *const List, default: []const u8) Network {
        return if (self.network_names.first) |node|
            @as(*Network, @fieldParentPtr("node", node)).*
        else
            .{ .name = default, .id = @fromBackingInt(0) };
    }

    const Network = struct {
        name: []const u8,
        id: Id,
        node: std.SinglyLinkedList.Node = .{},

        pub fn format(self: Network, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.name);
            if (self.node.next) |next| {
                const next_elem: *Network = @fieldParentPtr("node", next);
                try writer.writeByte('+');
                try next_elem.format(writer);
            }
        }
    };
};

pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

pub const csv = struct {
    const columns: []const []const u8 = &.{ "Letter", "ID", "Network ID", "Name", "Network Name", "Latitude", "Longitude", "Altitude", "Delay (ns)", "Revision", "Channel" };

    /// Write Stations to a CSV file
    /// When delimiter is null, use a comma (`,`)
    pub fn write(list: *const List, w: *Writer, delimiter: ?u8) Writer.Error!void {
        const separator = delimiter orelse ',';
        for (columns, 1..) |column, idx| {
            try w.writeAll(column);
            try w.writeByte(if (idx == columns.len) '\n' else separator);
        }
        for (list.stations.items) |station| {
            try w.print(
                "{[letter]c}{[sep]c}{[id]d}{[sep]c}{[net_id]d}{[sep]c}{[name]s}{[sep]c}{[net_name]s}{[sep]c}" ++
                    "{[lat]d:.9}{[sep]c}{[lon]d:.9}{[sep]c}{[alt]d:.3}{[sep]c}{[delay]d:.1}{[sep]c}" ++
                    "{[revision]d}{[sep]c}{[channel]d}\n",
                .{
                    .sep = separator,
                    .letter = station.stationLetter(),
                    .id = station.station_id,
                    .net_id = station.network_id,
                    .name = station.name,
                    .net_name = if (list.findNetworkId(station.network_id)) |node| node.name else "",
                    .lat = station.latitude,
                    .lon = station.longitude,
                    .alt = station.altitude,
                    .delay = std.time.ns_per_s * lma.nano.fromNano(f32, station.delay),
                    .revision = station.revision,
                    .channel = station.channel,
                },
            );
        }
        try w.flush();
    }

    /// Read Stations from a CSV file
    /// When delimiter is null, use a comma (`,`)
    pub fn read(list: *List, r: *Reader, delimiter: ?u8) ParseError!void {
        innerRead(list, r, delimiter) catch |e| return switch (e) {
            else => |err| err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerRead(list: *List, r: *Reader, delimiter: ?u8) (error{StreamTooLong} || ParseError)!void {
        // Read CSV header
        const csv_header = try r.takeDelimiter('\n') orelse {
            log.err("Empty file.", .{});
            return error.InvalidHeader;
        };
        const del = delimiter orelse blk: {
            const common_delimiters = [_]u8{ ',', ';', '\t', '|' };
            for (common_delimiters) |del| {
                const column_count = 1 + std.mem.countScalar(u8, csv_header, del);
                if (column_count == columns.len) break :blk del;
            }
            log.err("No valid delimiter found.", .{});
            return error.InvalidHeader;
        };

        while (try r.takeDelimiter('\n')) |line| {
            var iter = std.mem.splitScalar(u8, line, del);

            const elems = .{
                .letter = try getString(iter.next()),
                .id = try getInt(u8, iter.next()),
                .net_id = try getInt(u8, iter.next()),
                .name = try getString(iter.next()),
                .net_name = try getString(iter.next()),
                .lat = try getFloat(f64, iter.next()),
                .lon = try getFloat(f64, iter.next()),
                .alt = try getFloat(f32, iter.next()),
                .delay = try getFloat(f32, iter.next()),
                .revision = try getInt(u8, iter.next()),
                .channel = try getInt(u8, iter.next()),
            };

            if (elems.letter.len != 1) {
                log.err("Invalid station letter {q}.", .{elems.letter});
                return error.InvalidValue;
            }

            if (letterToId(elems.letter[0]) != @as(Id, @fromBackingInt(elems.id))) {
                log.err(
                    "Letter '{c}' (id: {d}) doesn't match station id {d}.",
                    .{ elems.letter[0], @backingInt(letterToId(elems.letter[0])), elems.id },
                );
                return error.InvalidValue;
            }

            if (elems.net_name.len != 0) {
                try list.appendNetwork(@fromBackingInt(elems.net_id), elems.net_name);
            }

            try list.stations.append(list.allocator, .{
                .station_id = @fromBackingInt(elems.id),
                .name = try list.arena.allocator().dupe(u8, elems.name),
                .network_id = @fromBackingInt(elems.net_id),
                .latitude = elems.lat,
                .longitude = elems.lon,
                .altitude = elems.alt,
                .delay = @round(4 * elems.delay),
                .revision = elems.revision,
                .channel = elems.channel,
            });
        }
    }

    test "csv format round trip" {
        var data: List = .init(std.testing.allocator);
        defer data.deinit();

        var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
        const random = rng.random();
        for (0..10) |_| {
            const buf = try data.arena.allocator().alloc(u8, random.intRangeAtMost(u8, 5, 255));
            random.bytes(buf);
            for (buf) |*byte| byte.* = (byte.* & 0x1F) + 0x5B;
            try data.stations.append(data.allocator, .{
                .station_id = letterToId(random.intRangeAtMost(u8, 'A', 'Z')),
                .network_id = @fromBackingInt(random.intRangeAtMost(u8, 1, 255)),
                .name = buf,
                .latitude = 180 * random.float(f64) - 90,
                .longitude = 360 * random.float(f64) - 180,
                .altitude = 2_000 * random.float(f32) - 1_000,
                .delay = random.intRangeAtMost(i32, -4_000, 4_000),
                .revision = random.int(u8),
                .channel = random.int(u8),
            });
        }

        // Write to a buffer and read from it with a new instance
        var writer: Writer.Allocating = .init(data.allocator);
        defer writer.deinit();
        try csv.write(&data, &writer.writer, '\t');

        var read_data: List = .init(std.testing.allocator);
        defer read_data.deinit();
        var reader: Reader = .fixed(writer.written());
        try csv.read(&read_data, &reader, null);

        for (data.stations.items, read_data.stations.items) |original, final| {
            var any_error: bool = false;
            std.testing.expect(original.station_id == final.station_id) catch {
                std.debug.print("Station ID mismatch: {d} {d}\n", .{ original.station_id, final.station_id });
                any_error = true;
            };
            std.testing.expect(original.network_id == final.network_id) catch {
                std.debug.print("Network ID mismatch: {d} {d}\n", .{ original.network_id, final.network_id });
                any_error = true;
            };
            std.testing.expect(std.mem.eql(u8, original.name, final.name)) catch {
                std.debug.print("Name mismatch:\n{s}\n{s}\n", .{ original.name, final.name });
                any_error = true;
            };
            std.testing.expect(std.math.approxEqAbs(f64, original.latitude, final.latitude, 1e-9)) catch {
                std.debug.print("Latitude mismatch: {d} {d}\n", .{ original.latitude, final.latitude });
                any_error = true;
            };
            std.testing.expect(std.math.approxEqAbs(f64, original.longitude, final.longitude, 1e-9)) catch {
                std.debug.print("Longitude mismatch: {d} {d}\n", .{ original.longitude, final.longitude });
                any_error = true;
            };
            std.testing.expect(std.math.approxEqAbs(f32, original.altitude, final.altitude, 1e-3)) catch {
                std.debug.print("Altitude mismatch: {d} {d}\n", .{ original.altitude, final.altitude });
                any_error = true;
            };
            std.testing.expect(original.delay == final.delay) catch {
                std.debug.print("Delay mismatch: {d} {d}\n", .{ original.delay, final.delay });
                any_error = true;
            };
            std.testing.expect(original.revision == final.revision) catch {
                std.debug.print("Revision mismatch: {d} {d}\n", .{ original.revision, final.revision });
                any_error = true;
            };
            std.testing.expect(original.channel == final.channel) catch {
                std.debug.print("Channel mismatch: {d} {d}\n", .{ original.channel, final.channel });
                any_error = true;
            };
            if (any_error) return error.ValueMismatch;
        }
    }

    test "csv cleanup" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, testCsvCleanup, .{});
    }

    fn testCsvCleanup(gpa: Allocator) !void {
        var data: List = .init(gpa);
        defer data.deinit();

        var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
        const random = rng.random();
        for (0..10) |_| {
            const buf = try data.arena.allocator().alloc(u8, 10);
            @memcpy(buf, "Dummy name");
            try data.stations.append(data.allocator, .{
                .station_id = letterToId(random.intRangeAtMost(u8, 'A', 'Z')),
                .network_id = @fromBackingInt(random.intRangeAtMost(u8, 1, 255)),
                .name = buf,
                .latitude = 180 * random.float(f64) - 90,
                .longitude = 360 * random.float(f64) - 180,
                .altitude = 2_000 * random.float(f32) - 1_000,
                .delay = random.intRangeAtMost(i32, -4_000, 4_000),
                .revision = random.int(u8),
                .channel = random.int(u8),
            });
        }

        // Write to a buffer and read from it with a new instance
        var writer: Writer.Allocating = .init(data.allocator);
        defer writer.deinit();
        csv.write(&data, &writer.writer, null) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        var read_data: List = .init(gpa);
        defer read_data.deinit();
        var reader: Reader = .fixed(writer.written());
        try csv.read(&read_data, &reader, null);
    }
};

pub const gps = struct {
    /// Read Stations from a GPS file
    /// When delimiter is null, use a comma (`,`)
    pub fn read(list: *List, r: *Reader, maybe_date: ?[]const u8) ParseError!void {
        innerRead(list, r, maybe_date) catch |e| return switch (e) {
            else => |err| err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerRead(list: *List, r: *Reader, maybe_date: ?[]const u8) (error{StreamTooLong} || ParseError)!void {
        const version = while (try r.takeDelimiter('\n')) |line| {
            if (line.len == 0) {
                log.err("Empty non-comment line", .{});
                return error.BadFile;
            }
            if (line[0] == '#') continue;
            const version_header = "version";
            if (std.mem.startsWith(u8, line, version_header)) {
                break getInt(usize, line[version_header.len..]) catch |e| switch (e) {
                    error.BadFile => |err| return err,
                    error.InvalidValue => return error.InvalidHeader,
                };
            } else {
                log.err("First non-comment line is not the version number", .{});
                return error.InvalidHeader;
            }
        } else {
            log.err("Missing version number", .{});
            return error.BadFile;
        };

        const old_len = list.stations.items.len;
        var network_id: Id = @fromBackingInt(0);
        switch (version) {
            2 => {
                // Network description
                while (try r.takeDelimiter('\n')) |line| {
                    if (line.len == 0) {
                        log.err("Empty non-comment line", .{});
                        return error.BadFile;
                    }
                    if (line[0] == '#') continue;
                    var iter = std.mem.tokenizeAny(u8, line, " \t");
                    _ = iter.next();
                    network_id = @fromBackingInt(try getInt(u8, iter.next()));
                    const network_name = try getString(iter.next());
                    try list.appendNetwork(network_id, network_name);
                    break;
                } else {
                    log.err("Missing network information", .{});
                    return error.BadFile;
                }

                while (try r.takeDelimiter('\n')) |line| {
                    if (line.len == 0) {
                        log.err("Empty non-comment line", .{});
                        return error.BadFile;
                    }
                    if (line[0] == '#') continue;
                    var iter = std.mem.tokenizeAny(u8, line, " \t");

                    const elems = .{
                        .letter = try getString(iter.next()),
                        .id = try getInt(u8, iter.next()),
                        .name = try getString(iter.next()),
                        .lat = try getFloat(f64, iter.next()),
                        .lon = try getFloat(f64, iter.next()),
                        .alt = try getFloat(f32, iter.next()),
                        .ignore1 = iter.next(),
                        .ignore2 = iter.next(),
                        .ignore3 = iter.next(),
                        .delay = try getFloat(f32, iter.next()),
                        .revision = try getInt(u8, iter.next()),
                        .channel = try getInt(u8, iter.next()),
                        .start = try getString(iter.next()),
                        .end = try getString(iter.next()),
                    };

                    if (elems.letter.len != 1) {
                        log.err("Invalid station letter {q}.", .{elems.letter});
                        return error.InvalidValue;
                    }

                    if (letterToId(elems.letter[0]) != @as(Id, @fromBackingInt(elems.id))) {
                        log.err(
                            "Letter '{c}' (id: {d}) doesn't match station id {d}.",
                            .{ elems.letter[0], @backingInt(letterToId(elems.letter[0])), elems.id },
                        );
                        return error.InvalidValue;
                    }

                    const entry: Station = .{
                        .station_id = @fromBackingInt(elems.id),
                        .name = try list.arena.allocator().dupe(u8, elems.name),
                        .network_id = network_id,
                        .latitude = elems.lat,
                        .longitude = elems.lon,
                        .altitude = elems.alt,
                        .delay = @round(4 * elems.delay),
                        .revision = elems.revision,
                        .channel = elems.channel,
                    };

                    if (maybe_date) |date| {
                        if (std.mem.order(u8, elems.start, date) != .gt and
                            std.mem.order(u8, date, elems.end) != .gt)
                        {
                            try list.stations.append(list.allocator, entry);
                        }
                    } else {
                        for (list.stations.items[old_len..]) |*added_entry| {
                            if (added_entry.station_id == entry.station_id) {
                                added_entry.* = entry;
                                break;
                            }
                        } else try list.stations.append(list.allocator, entry);
                    }
                }
            },
            else => return error.UnsupportedVersion,
        }
    }

    test "read latest" {
        var buffer: [1024]u8 = undefined;

        const file = try std.Io.Dir.cwd().openFile(std.testing.io, "test/data/test.gps", .{});
        var file_reader = file.reader(std.testing.io, &buffer);

        var data: List = .init(std.testing.allocator);
        defer data.deinit();

        try read(&data, &file_reader.interface, null);

        const net: *List.Network = @fieldParentPtr("node", data.network_names.first.?);
        try std.testing.expectEqual(@as(Id, @fromBackingInt(255)), net.id);
        try std.testing.expectEqualStrings("NAME", net.name);
        try std.testing.expectEqual(@as(std.SinglyLinkedList.Node, .{}), net.node);

        for (data.stations.items, 0..5) |station, idx| {
            var name_buffer: [64]u8 = undefined;
            try std.testing.expectEqualDeep(Station{
                .station_id = @fromBackingInt(1 + @as(u8, @intCast(idx))),
                .network_id = @fromBackingInt(255),
                .name = std.fmt.bufPrint(&name_buffer, "Name_{d}", .{1 + idx}) catch unreachable,
                .latitude = 42.0 + @as(f64, @floatFromInt(idx)) / 10,
                .longitude = 2.0 + @as(f64, @floatFromInt(idx)) / 10,
                .altitude = @as(f32, @floatFromInt(1 + idx)) * 10,
                .delay = 4 * (100 + 10 * @as(i32, @intCast(idx))),
                .revision = 1 + @as(u8, @intCast(idx)),
                .channel = 6 + @as(u8, @intCast(idx)),
            }, station);
        }
    }

    test "read version" {
        var buffer: [1024]u8 = undefined;

        const file = try std.Io.Dir.cwd().openFile(std.testing.io, "test/data/test.gps", .{});
        var file_reader = file.reader(std.testing.io, &buffer);

        var data: List = .init(std.testing.allocator);
        defer data.deinit();

        try read(&data, &file_reader.interface, "20210203.040506");

        const net: *List.Network = @fieldParentPtr("node", data.network_names.first.?);
        try std.testing.expectEqual(@as(Id, @fromBackingInt(255)), net.id);
        try std.testing.expectEqualStrings("NAME", net.name);
        try std.testing.expectEqual(@as(std.SinglyLinkedList.Node, .{}), net.node);

        for (data.stations.items, 0..5) |station, idx| {
            var name_buffer: [64]u8 = undefined;
            try std.testing.expectEqualDeep(Station{
                .station_id = @fromBackingInt(1 + @as(u8, @intCast(idx))),
                .network_id = @fromBackingInt(255),
                .name = std.fmt.bufPrint(&name_buffer, "Name_{c}", .{@as(u8, @intCast('A' + idx))}) catch unreachable,
                .latitude = 41.0 + @as(f64, @floatFromInt(idx)) / 10,
                .longitude = 1.0 + @as(f64, @floatFromInt(idx)) / 10,
                .altitude = @as(f32, @floatFromInt(1 + idx)) * 10 + 0.5,
                .delay = 4 * (200 + 10 * @as(i32, @intCast(idx))),
                .revision = 9,
                .channel = 99,
            }, station);
        }
    }
};

/// Read Stations from a LOC file
/// When delimiter is null, use a comma (`,`)
pub fn fromLoc(self: *List, r: *Reader) ParseError!void {
    innerFromLoc(self, r) catch |e| return switch (e) {
        else => |err| err,
        error.StreamTooLong => error.BadFile,
    };
}

fn innerFromLoc(self: *List, r: *Reader) (error{StreamTooLong} || ParseError)!void {
    const net_default: Id = @fromBackingInt(0);
    var header_components: usize = 0;
    while (try r.takeDelimiter('\n')) |line| {
        if (line.len == 0) return error.BadFile;
        if (line[0] == '#') continue;
        header_components += 1;
        if (header_components == 1) {
            try self.appendNetwork(net_default, std.mem.trim(u8, line, " "));
        }
        if (header_components >= 4) break;
    } else return error.BadFile;

    // TODO swap to peek
    while (try r.takeDelimiter('\n')) |line| {
        if (line.len == 0) {
            log.err("Line without comment nor data.", .{});
            return error.BadFile;
        }
        if (line[0] == '#') continue;

        if (std.mem.eql(u8, "END", std.mem.trim(u8, line, " "))) break;

        r.seek -= line.len + 1;
        try self.stations.append(self.allocator, .{
            .name = try self.arena.allocator().dupe(u8, try getString(try r.takeDelimiter('\n'))),
            .station_id = blk: {
                const non_empty = try getString(try r.takeDelimiter('\n'));
                if (non_empty.len != 1) {
                    log.err("Station Letter is empty.", .{});
                    return error.InvalidValue;
                }
                const letter_id = letterToId(non_empty[0]);
                break :blk letter_id;
            },
            .network_id = net_default,
            .latitude = try getFloat(f64, try r.takeDelimiter('\n')),
            .longitude = try getFloat(f64, try r.takeDelimiter('\n')),
            .altitude = try getFloat(f32, try r.takeDelimiter('\n')),
            .delay = @round(4 * (try getFloat(f32, try r.takeDelimiter('\n')))),
            .revision = try getInt(u8, try r.takeDelimiter('\n')),
            .channel = try getInt(u8, try r.takeDelimiter('\n')),
        });
    }
}

test fromLoc {
    var buffer: [1024]u8 = undefined;

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "test/data/test.loc", .{});
    var file_reader = file.reader(std.testing.io, &buffer);

    var data: List = .init(std.testing.allocator);
    defer data.deinit();

    try fromLoc(&data, &file_reader.interface);

    const net: *List.Network = @fieldParentPtr("node", data.network_names.first.?);
    try std.testing.expectEqual(@as(Id, @fromBackingInt(0)), net.id);
    try std.testing.expectEqualStrings("NAME", net.name);
    try std.testing.expectEqual(@as(std.SinglyLinkedList.Node, .{}), net.node);

    for (data.stations.items, 0..5) |station, idx| {
        var name_buffer: [64]u8 = undefined;
        try std.testing.expectEqualDeep(Station{
            .station_id = @fromBackingInt(1 + @as(u8, @intCast(idx))),
            .network_id = @fromBackingInt(0),
            .name = std.fmt.bufPrint(&name_buffer, "Name_{d}", .{1 + idx}) catch unreachable,
            .latitude = 42.0 + @as(f64, @floatFromInt(idx)) / 10,
            .longitude = 2.0 + @as(f64, @floatFromInt(idx)) / 10,
            .altitude = @as(f32, @floatFromInt(1 + idx)) * 10,
            .delay = 4 * (100 + 10 * @as(i32, @intCast(idx))),
            .revision = 1 + @as(u8, @intCast(idx)),
            .channel = 6 + @as(u8, @intCast(idx)),
        }, station);
    }
}

inline fn getFloat(Float: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Float {
    return std.fmt.parseFloat(Float, std.mem.trim(u8, try unwrapToken(s), " ")) catch {
        log.err("Value {q} is not a valid number", .{s.?});
        return error.InvalidValue;
    };
}

inline fn getInt(Int: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Int {
    return std.fmt.parseInt(Int, std.mem.trim(u8, try unwrapToken(s), " "), 10) catch {
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
        log.err("File terminated while reading", .{});
        return error.BadFile;
    };
}

comptime {
    std.testing.refAllDecls(@This());
}
