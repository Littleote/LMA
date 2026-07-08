const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const dat_file = @import("dat_file.zig");

const Data = @This();

stations: std.ArrayList(Info),
allocator: Allocator,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator) Data {
    return .{
        .stations = .empty,
        .allocator = gpa,
        .arena = .init(gpa),
    };
}

pub fn deinit(self: *Data) void {
    self.stations.deinit(self.allocator);
    self.arena.deinit();
}

const csv_columns: []const []const u8 = &.{ "Letter", "ID", "Name", "Latitude", "Longitude", "Altitude", "Delay (ns)", "Revision", "Channel" };

pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

/// Write Stations to a CSV file
/// When delimiter is null, use a comma (`,`)
pub fn toCsv(self: *const Data, w: *Writer, delimiter: ?u8) Writer.Error!void {
    const separator = delimiter orelse ',';
    for (csv_columns, 1..) |column, idx| {
        try w.writeAll(column);
        try w.writeByte(if (idx == csv_columns.len) '\n' else separator);
    }
    for (self.stations.items) |station| {
        try w.print(
            "{[letter]c}{[sep]c}{[id]d}{[sep]c}{[name]s}{[sep]c}" ++
                "{[lat]d:.9}{[sep]c}{[lon]d:.9}{[sep]c}{[alt]d:.3}{[sep]c}{[delay]d:.1}{[sep]c}" ++
                "{[revision]d}{[sep]c}{[channel]d}\n",
            .{
                .sep = separator,
                .letter = station.letter,
                .id = station.id,
                .name = station.name,
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

inline fn getFloat(Float: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Float {
    return std.fmt.parseFloat(Float, std.mem.trim(u8, s orelse return error.BadFile, " ")) catch error.InvalidValue;
}

inline fn getInt(Int: type, s: ?[]const u8) error{ BadFile, InvalidValue }!Int {
    return std.fmt.parseInt(Int, std.mem.trim(u8, s orelse return error.BadFile, " "), 10) catch error.InvalidValue;
}

/// Read Stations from a CSV file
/// When delimiter is null, use a comma (`,`)
pub fn fromCsv(self: *Data, r: *Reader, delimiter: ?u8) ParseError!void {
    self.innerFromCsv(r, delimiter) catch |err| return switch (err) {
        else => |new_err| new_err,
        error.StreamTooLong => error.BadFile,
    };
}

fn innerFromCsv(self: *Data, r: *Reader, delimiter: ?u8) (error{StreamTooLong} || ParseError)!void {
    // Read CSV header
    const csv_header = try r.takeDelimiter('\n') orelse return error.InvalidHeader;
    const del = delimiter orelse blk: {
        const common_delimiters = [_]u8{ ',', ';', '\t', '|' };
        for (common_delimiters) |del| {
            const columns = 1 + std.mem.countScalar(u8, csv_header, del);
            if (columns == csv_columns.len) break :blk del;
        }
        return error.InvalidHeader;
    };

    while (try r.takeDelimiter('\n')) |line| {
        var iter = std.mem.splitScalar(u8, line, del);
        try self.stations.append(self.allocator, .{
            .letter = if (iter.next()) |letter| blk: {
                const non_empty = std.mem.trim(u8, letter, " ");
                if (non_empty.len != 1) return error.InvalidValue;
                break :blk non_empty[0];
            } else return error.BadFile,
            .id = try getInt(u8, iter.next()),
            .name = try self.arena.allocator().dupe(u8, std.mem.trim(u8, iter.next() orelse return error.BadFile, " ")),
            .latitude = try getFloat(f64, iter.next()),
            .longitude = try getFloat(f64, iter.next()),
            .altitude = try getFloat(f32, iter.next()),
            .delay = @round(4 * (try getFloat(f32, iter.next()))),
            .revision = try getInt(u8, iter.next()),
            .channel = try getInt(u8, iter.next()),
        });
    }
}

test "csv format round trip" {
    var data: Data = .init(std.testing.allocator);
    defer data.deinit();

    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    for (0..10) |_| {
        const buf = try data.arena.allocator().alloc(u8, random.intRangeAtMost(u8, 5, 255));
        random.bytes(buf);
        for (buf) |*byte| byte.* = (byte.* & 0x1F) + 0x5B;
        try data.stations.append(data.allocator, .{
            .letter = random.intRangeAtMost(u8, 'A', 'Z'),
            .id = random.intRangeAtMost(u8, 1, 255),
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
    try data.toCsv(&writer.writer, '\t');

    var read_data: Data = .init(std.testing.allocator);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try read_data.fromCsv(&reader, null);

    for (data.stations.items, read_data.stations.items) |original, read| {
        var any_error: bool = false;
        std.testing.expect(original.letter == read.letter) catch {
            std.debug.print("Letter mismatch: {d} {d}\n", .{ original.letter, read.letter });
            any_error = true;
        };
        std.testing.expect(original.id == read.id) catch {
            std.debug.print("ID mismatch: {d} {d}\n", .{ original.id, read.id });
            any_error = true;
        };
        std.testing.expect(std.mem.eql(u8, original.name, read.name)) catch {
            std.debug.print("Name mismatch:\n{s}\n{s}\n", .{ original.name, read.name });
            any_error = true;
        };
        std.testing.expect(std.math.approxEqAbs(f64, original.latitude, read.latitude, 1e-9)) catch {
            std.debug.print("Latitude mismatch: {d} {d}\n", .{ original.latitude, read.latitude });
            any_error = true;
        };
        std.testing.expect(std.math.approxEqAbs(f64, original.longitude, read.longitude, 1e-9)) catch {
            std.debug.print("Longitude mismatch: {d} {d}\n", .{ original.longitude, read.longitude });
            any_error = true;
        };
        std.testing.expect(std.math.approxEqAbs(f32, original.altitude, read.altitude, 1e-3)) catch {
            std.debug.print("Altitude mismatch: {d} {d}\n", .{ original.altitude, read.altitude });
            any_error = true;
        };
        std.testing.expect(original.delay == read.delay) catch {
            std.debug.print("Delay mismatch: {d} {d}\n", .{ original.delay, read.delay });
            any_error = true;
        };
        std.testing.expect(original.revision == read.revision) catch {
            std.debug.print("Revision mismatch: {d} {d}\n", .{ original.revision, read.revision });
            any_error = true;
        };
        std.testing.expect(original.channel == read.channel) catch {
            std.debug.print("Channel mismatch: {d} {d}\n", .{ original.channel, read.channel });
            any_error = true;
        };
        if (any_error) return error.ValueMismatch;
    }
}

test "csv cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCsvCleanup, .{});
}

fn testCsvCleanup(gpa: Allocator) !void {
    var data: Data = .init(gpa);
    defer data.deinit();

    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    for (0..10) |_| {
        const buf = try data.arena.allocator().alloc(u8, 10);
        @memcpy(buf, "Dummy name");
        try data.stations.append(data.allocator, .{
            .letter = random.intRangeAtMost(u8, 'A', 'Z'),
            .id = random.intRangeAtMost(u8, 1, 255),
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
    data.toCsv(&writer.writer, null) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    var read_data: Data = .init(gpa);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try read_data.fromCsv(&reader, null);
}
/// Read Stations from a GPS file
/// When delimiter is null, use a comma (`,`)
pub fn fromGps(self: *Data, r: *Reader) ParseError!void {
    self.innerFromGps(r) catch |err| return switch (err) {
        else => |new_err| new_err,
        error.StreamTooLong => error.BadFile,
    };
}

fn innerFromGps(self: *Data, r: *Reader) (error{StreamTooLong} || ParseError)!void {
    const version = while (try r.takeDelimiter('\n')) |line| {
        if (line.len == 0) return error.BadFile;
        if (line[0] == '#') continue;
        const version_header = "version";
        if (std.mem.startsWith(u8, line, version_header)) {
            break getInt(usize, line[version_header.len..]) catch |err| switch (err) {
                error.BadFile => |new_err| return new_err,
                error.InvalidValue => return error.InvalidHeader,
            };
        } else return error.InvalidHeader;
    } else return error.BadFile;

    const old_len = self.stations.items.len;
    switch (version) {
        2 => {
            // Network description
            while (try r.takeDelimiter('\n')) |line| {
                if (line.len == 0) return error.BadFile;
                if (line[0] == '#') continue;
                break;
            } else return error.BadFile;

            while (try r.takeDelimiter('\n')) |line| {
                if (line.len == 0) return error.BadFile;
                if (line[0] == '#') continue;
                var iter = std.mem.tokenizeAny(u8, line, " \t");
                const entry: Info = .{
                    .letter = if (iter.next()) |letter| blk: {
                        const non_empty = std.mem.trim(u8, letter, " ");
                        if (non_empty.len != 1) return error.InvalidValue;
                        break :blk non_empty[0];
                    } else return error.BadFile,
                    .id = try getInt(u8, iter.next()),
                    .name = try self.arena.allocator().dupe(u8, iter.next() orelse return error.BadFile),
                    .latitude = try getFloat(f64, iter.next()),
                    .longitude = try getFloat(f64, iter.next()),
                    .altitude = try getFloat(f32, iter.next()),
                    .delay = @round(4 * (try getFloat(f32, discard_3: {
                        _ = iter.next();
                        _ = iter.next();
                        _ = iter.next();
                        break :discard_3 iter.next();
                    }))),
                    .revision = try getInt(u8, iter.next()),
                    .channel = try getInt(u8, iter.next()),
                };
                _ = iter.next();
                _ = iter.next() orelse return error.BadFile;

                for (self.stations.items[old_len..]) |*new_entry| {
                    if (new_entry.id == entry.id) {
                        new_entry.* = entry;
                        break;
                    }
                } else try self.stations.append(self.allocator, entry);
            }
        },
        else => return error.UnsupportedVersion,
    }
}

test fromGps {
    var buffer: [1024]u8 = undefined;

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "test/data/test.gps", .{});
    var file_reader = file.reader(std.testing.io, &buffer);

    var data: Data = .init(std.testing.allocator);
    defer data.deinit();

    try data.fromGps(&file_reader.interface);

    for (data.stations.items, 0..5) |station, idx| {
        var name_buffer: [64]u8 = undefined;
        try std.testing.expectEqualDeep(Info{
            .letter = 'A' + @as(u8, @intCast(idx)),
            .id = 1 + @as(u8, @intCast(idx)),
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

test "fromGpsFuzzing" {
    const gpsFuzzer = struct {
        pub fn gpsFuzzer(_: void, smith: *std.testing.Smith) anyerror!void {
            var data: Data = .init(std.testing.allocator);
            defer data.deinit();

            var buf: [1024]u8 = undefined;
            var fuzz_reader: FuzzReader = .init(smith, &buf);

            data.fromGps(&fuzz_reader.interface) catch return;
            @panic("Found me!");
        }
    }.gpsFuzzer;

    try std.testing.fuzz({}, gpsFuzzer, .{});
}

const FuzzReader = struct {
    interface: Reader,
    next: [255]u8,
    next_end: u8,
    smith: *std.testing.Smith,

    pub fn init(smith: *std.testing.Smith, buffer: []u8) FuzzReader {
        return .{
            .interface = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &vtable },
            .smith = smith,
            .next = undefined,
            .next_end = 0,
        };
    }

    pub fn fuzzStream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *FuzzReader = @fieldParentPtr("interface", r);
        if (self.next_end != 0)
            return try w.write(limit.slice(self.next[0..self.next_end]));

        if (self.smith.eos()) return error.EndOfStream;
        var writer: Writer = .fixed(&self.next);
        switch (self.smith.value(enum { comment, newline, whitespace, text, character, integer, float })) {
            .comment => {
                try writer.writeByte('#');
            },
            .newline => {
                try writer.writeByte('\n');
            },
            .whitespace => {
                const slice = writer.unusedCapacitySlice();
                const len = self.smith.valueRangeAtMost(u32, 1, @intCast(slice.len));
                @memset(slice[0..len], ' ');
                writer.end += len;
            },
            .character => {
                try writer.writeByte(self.smith.value(u8));
            },
            .text => {
                const slice = limit.slice(r.buffer[r.end..]);
                const len = self.smith.slice(slice);
                r.end += len;
                return 0;
            },
            .integer => {
                const num = self.smith.value(i16);
                try writer.printInt(num, 10, .lower, .{});
            },
            .float => {
                const num = self.smith.value(f32);
                writer.printFloat(num, .{ .mode = .scientific }) catch {};
            },
        }
        self.next_end = @intCast(writer.end);
        return 0;
    }

    pub const vtable: Reader.VTable = .{
        .stream = fuzzStream,
    };
};

/// Read Stations from a LOC file
/// When delimiter is null, use a comma (`,`)
pub fn fromLoc(self: *Data, r: *Reader) ParseError!void {
    self.innerFromLoc(r) catch |err| return switch (err) {
        else => |new_err| new_err,
        error.StreamTooLong => error.BadFile,
    };
}

fn innerFromLoc(self: *Data, r: *Reader) (error{StreamTooLong} || ParseError)!void {
    var header_components: usize = 0;
    while (try r.takeDelimiter('\n')) |line| {
        if (line.len == 0) return error.BadFile;
        if (line[0] == '#') continue;
        header_components += 1;
        if (header_components >= 4) break;
    } else return error.BadFile;

    // TODO swap to peek
    while (try r.takeDelimiter('\n')) |line| {
        if (line.len == 0) return error.BadFile;
        if (line[0] == '#') continue;
        if (std.mem.eql(u8, "END", std.mem.trim(u8, line, " "))) break;

        r.seek -= line.len + 1;
        try self.stations.append(self.allocator, .{
            .name = try self.arena.allocator().dupe(u8, std.mem.trim(u8, try r.takeDelimiter('\n') orelse return error.BadFile, " ")),
            .letter = if (try r.takeDelimiter('\n')) |letter| blk: {
                const non_empty = std.mem.trim(u8, letter, " ");
                if (non_empty.len != 1) return error.InvalidValue;
                break :blk non_empty[0];
            } else return error.BadFile,
            .id = 0,
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

    var data: Data = .init(std.testing.allocator);
    defer data.deinit();

    try data.fromLoc(&file_reader.interface);

    for (data.stations.items, 0..5) |station, idx| {
        var name_buffer: [64]u8 = undefined;
        try std.testing.expectEqualDeep(Info{
            .letter = 'A' + @as(u8, @intCast(idx)),
            .id = 0,
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

// pub fn toBin(data: *const Data, w: *Writer) Writer.Error!void {
//     try w.writeAll("LMA-station-001\n");
//     try w.writeInt(usize, data.stations.items.len, .little);
//     for (data.stations.items) |station| {
//         const packet, const name = station.pack();
//         try w.writeStruct(packet, .little);
//         try w.writeAll(name);
//     }
//     try w.flush();
// }

// pub fn fromBin(self: *Data, r: *Reader) ParseError!void {
//     self.innerFromBin(r) catch |err| return switch (err) {
//         else => |new_err| new_err,
//         error.EndOfStream => error.BadFile,
//     };
// }

// fn innerFromBin(self: *Data, r: *Reader) (error{EndOfStream} || ParseError)!void {
//     const info = r.take(16) catch |err| return switch (err) {
//         error.ReadFailed => |new_err| new_err,
//         error.EndOfStream => error.InvalidHeader,
//     };
//     std.debug.assert(std.mem.eql(u8, info[0..12], "LMA-station-"));
//     const version = std.fmt.parseInt(usize, info[12..15], 10) catch return error.InvalidHeader;
//     std.debug.assert(info[15] == '\n');
//     switch (version) {
//         1 => {
//             const station_count = try r.takeInt(usize, .little);
//             try self.stations.ensureTotalCapacityPrecise(self.allocator, station_count);
//             for (0..station_count) |_| {
//                 const packet = try r.takeStruct(Info.Packet, .little);
//                 self.stations.appendAssumeCapacity(try .build(packet, self.allocator, r));
//             }
//         },
//         else => return error.UnsupportedVersion,
//     }
// }

// test "bin format round trip" {
//     var data: Data = .init(std.testing.allocator);
//     defer data.deinit();

//     var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
//     const random = rng.random();
//     for (0..10) |_| {
//         const buf = try data.allocator.alloc(u8, random.intRangeAtMost(u8, 5, 120));
//         errdefer data.allocator.free(buf);
//         random.bytes(buf);
//         try data.stations.append(data.allocator, .{
//             .name = buf,
//             .latitude = 180 * random.float(f64) - 90,
//             .longitude = 360 * random.float(f64) - 180,
//             .delay = random.intRangeAtMost(i32, -4_000, 4_000),
//             .altitude = 2_000 * random.float(f32) - 1_000,
//         });
//     }

//     // Write to a buffer and read from it with a new instance
//     var writer: Writer.Allocating = .init(data.allocator);
//     defer writer.deinit();
//     try data.toBin(&writer.writer);

//     var read_data: Data = .init(std.testing.allocator);
//     defer read_data.deinit();
//     var reader: Reader = .fixed(writer.written());
//     try read_data.fromBin(&reader);

//     for (data.stations.items, read_data.stations.items) |original, read| {
//         std.testing.expect(Info.eql(original, read)) catch |err| {
//             std.log.err("Entry\n{any}\nBecame\n{any}\n", .{ original, read });
//             return err;
//         };
//         try std.testing.expect(std.mem.eql(u8, original.name.?, read.name.?));
//     }
// }

// test "bin cleanup" {
//     try std.testing.checkAllAllocationFailures(std.testing.allocator, testBinCleanup, .{});
// }

// fn testBinCleanup(gpa: Allocator) !void {
//     var data: Data = .init(gpa);
//     defer data.deinit();

//     var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
//     const random = rng.random();
//     for (0..10) |_| {
//         const buf = try data.allocator.alloc(u8, 10);
//         errdefer data.allocator.free(buf);
//         @memcpy(buf, "Dummy name");
//         try data.stations.append(data.allocator, .{
//             .name = buf,
//             .latitude = 180 * random.float(f64) - 90,
//             .longitude = 360 * random.float(f64) - 180,
//             .delay = random.intRangeAtMost(i32, -4_000, 4_000),
//             .altitude = 2_000 * random.float(f32) - 1_000,
//         });
//     }

//     // Write to a buffer and read from it with a new instance
//     var writer: Writer.Allocating = .init(data.allocator);
//     defer writer.deinit();
//     data.toBin(&writer.writer) catch |err| switch (err) {
//         error.WriteFailed => return error.OutOfMemory,
//     };

//     var read_data: Data = .init(gpa);
//     defer read_data.deinit();
//     var reader: Reader = .fixed(writer.written());
//     try read_data.fromBin(&reader);
// }

pub fn fromDat(self: *Data, r: *Reader) !void {
    _ = try dat_file.output.parse(r, null, self);
}

pub const Info = struct {
    id: u8,
    letter: u8,
    name: []const u8,
    latitude: f64,
    longitude: f64,
    altitude: f32,
    delay: i32,
    revision: u8,
    channel: u8,

    pub fn point(self: *const Info) lma.math(f64).ElemVec {
        return .{ .elems = .{ self.latitude, self.longitude, self.altitude, 0 } };
    }
};
