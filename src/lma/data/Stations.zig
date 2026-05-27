const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const dat_file = @import("dat_file.zig");

const Data = @This();

stations: std.ArrayList(Info),
allocator: Allocator,

pub fn init(gpa: Allocator) Data {
    return .{
        .stations = .empty,
        .allocator = gpa,
    };
}

pub fn deinit(self: *Data) void {
    for (self.stations.items) |*station| {
        station.deinit(self.allocator);
    }
    self.stations.deinit(self.allocator);
}

const csv_columns: []const []const u8 = &.{ "Name", "Latitude", "Longitude", "Altitude", "Delay (ns)" };

pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

/// Write Stations to a CSV file
/// When delimiter is null, use a comma (`,`)
pub fn toCsv(self: *const Data, w: *Writer, delimiter: ?u8) Writer.Error!void {
    const del = delimiter orelse ',';
    for (csv_columns, 1..) |column, idx| {
        try w.writeAll(column);
        try w.writeByte(if (idx == csv_columns.len) '\n' else del);
    }
    for (self.stations.items) |station| {
        try w.print("{1s}{0c}{2d:.9}{0c}{3d:.9}{0c}{4d:.3}{0c}{5d:.1}\n", .{
            del,
            station.name orelse &.{},
            station.latitude,
            station.longitude,
            station.altitude,
            std.time.ns_per_s * lma.nano.fromNano(f32, station.delay),
        });
    }
    try w.flush();
}

inline fn getFloat(Float: type, s: ?[]const u8) error{InvalidValue}!Float {
    return std.fmt.parseFloat(Float, s orelse return error.InvalidValue) catch error.InvalidValue;
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
        const name = iter.next() orelse return error.InvalidHeader;
        try self.stations.append(self.allocator, .{
            .name = &.{},
            .latitude = try getFloat(f64, iter.next()),
            .longitude = try getFloat(f64, iter.next()),
            .altitude = try getFloat(f32, iter.next()),
            .delay = @round(4 * (try getFloat(f32, iter.next()))),
        });
        self.stations.items[self.stations.items.len - 1].name = try self.allocator.dupe(u8, name);
    }
}

test "csv format round trip" {
    var data: Data = .init(std.testing.allocator);
    defer data.deinit();

    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    for (0..10) |_| {
        const buf = try data.allocator.alloc(u8, random.intRangeAtMost(u8, 5, 120));
        errdefer data.allocator.free(buf);
        random.bytes(buf);
        for (buf) |*byte| byte.* = (byte.* & 0x1F) + 0x5B;
        try data.stations.append(data.allocator, .{
            .name = buf,
            .latitude = 180 * random.float(f64) - 90,
            .longitude = 360 * random.float(f64) - 180,
            .delay = random.intRangeAtMost(i32, -4_000, 4_000),
            .altitude = 2_000 * random.float(f32) - 1_000,
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
        std.testing.expect(std.mem.eql(u8, original.name.?, read.name.?)) catch {
            std.debug.print("Name mismatch:\n{s}\n{s}\n", .{ original.name.?, read.name.? });
            any_error = true;
        };
        std.testing.expect(std.math.approxEqAbs(f64, original.latitude, read.latitude, 1e-9)) catch {
            std.debug.print("latitude mismatch: {d} {d}\n", .{ original.latitude, read.latitude });
            any_error = true;
        };
        std.testing.expect(std.math.approxEqAbs(f64, original.longitude, read.longitude, 1e-9)) catch {
            std.debug.print("longitude mismatch: {d} {d}\n", .{ original.longitude, read.longitude });
            any_error = true;
        };
        std.testing.expect(std.math.approxEqAbs(f32, original.altitude, read.altitude, 1e-3)) catch {
            std.debug.print("altitude mismatch: {d} {d}\n", .{ original.altitude, read.altitude });
            any_error = true;
        };
        std.testing.expect(original.delay == read.delay) catch {
            std.debug.print("delay mismatch: {d} {d}\n", .{ original.delay, read.delay });
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
        const buf = try data.allocator.alloc(u8, 10);
        errdefer data.allocator.free(buf);
        @memcpy(buf, "Dummy name");
        try data.stations.append(data.allocator, .{
            .name = buf,
            .latitude = 180 * random.float(f64) - 90,
            .longitude = 360 * random.float(f64) - 180,
            .delay = random.intRangeAtMost(i32, -4_000, 4_000),
            .altitude = 2_000 * random.float(f32) - 1_000,
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

pub fn toBin(data: *const Data, w: *Writer) Writer.Error!void {
    try w.writeAll("LMA-station-001\n");
    try w.writeInt(usize, data.stations.items.len, .little);
    for (data.stations.items) |station| {
        const packet, const name = station.pack();
        try w.writeStruct(packet, .little);
        try w.writeAll(name);
    }
    try w.flush();
}

pub fn fromBin(self: *Data, r: *Reader) ParseError!void {
    self.innerFromBin(r) catch |err| return switch (err) {
        else => |new_err| new_err,
        error.EndOfStream => error.BadFile,
    };
}

fn innerFromBin(self: *Data, r: *Reader) (error{EndOfStream} || ParseError)!void {
    const info = r.take(16) catch |err| return switch (err) {
        error.ReadFailed => |new_err| new_err,
        error.EndOfStream => error.InvalidHeader,
    };
    std.debug.assert(std.mem.eql(u8, info[0..12], "LMA-station-"));
    const version = std.fmt.parseInt(usize, info[12..15], 10) catch return error.InvalidHeader;
    std.debug.assert(info[15] == '\n');
    switch (version) {
        1 => {
            const station_count = try r.takeInt(usize, .little);
            try self.stations.ensureTotalCapacityPrecise(self.allocator, station_count);
            for (0..station_count) |_| {
                const packet = try r.takeStruct(Info.Packet, .little);
                self.stations.appendAssumeCapacity(try .build(packet, self.allocator, r));
            }
        },
        else => return error.UnsupportedVersion,
    }
}

test "bin format round trip" {
    var data: Data = .init(std.testing.allocator);
    defer data.deinit();

    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    for (0..10) |_| {
        const buf = try data.allocator.alloc(u8, random.intRangeAtMost(u8, 5, 120));
        errdefer data.allocator.free(buf);
        random.bytes(buf);
        try data.stations.append(data.allocator, .{
            .name = buf,
            .latitude = 180 * random.float(f64) - 90,
            .longitude = 360 * random.float(f64) - 180,
            .delay = random.intRangeAtMost(i32, -4_000, 4_000),
            .altitude = 2_000 * random.float(f32) - 1_000,
        });
    }

    // Write to a buffer and read from it with a new instance
    var writer: Writer.Allocating = .init(data.allocator);
    defer writer.deinit();
    try data.toBin(&writer.writer);

    var read_data: Data = .init(std.testing.allocator);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try read_data.fromBin(&reader);

    for (data.stations.items, read_data.stations.items) |original, read| {
        std.testing.expect(Info.eql(original, read)) catch |err| {
            std.log.err("Entry\n{any}\nBecame\n{any}\n", .{ original, read });
            return err;
        };
        try std.testing.expect(std.mem.eql(u8, original.name.?, read.name.?));
    }
}

test "bin cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBinCleanup, .{});
}

fn testBinCleanup(gpa: Allocator) !void {
    var data: Data = .init(gpa);
    defer data.deinit();

    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = rng.random();
    for (0..10) |_| {
        const buf = try data.allocator.alloc(u8, 10);
        errdefer data.allocator.free(buf);
        @memcpy(buf, "Dummy name");
        try data.stations.append(data.allocator, .{
            .name = buf,
            .latitude = 180 * random.float(f64) - 90,
            .longitude = 360 * random.float(f64) - 180,
            .delay = random.intRangeAtMost(i32, -4_000, 4_000),
            .altitude = 2_000 * random.float(f32) - 1_000,
        });
    }

    // Write to a buffer and read from it with a new instance
    var writer: Writer.Allocating = .init(data.allocator);
    defer writer.deinit();
    data.toBin(&writer.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    var read_data: Data = .init(gpa);
    defer read_data.deinit();
    var reader: Reader = .fixed(writer.written());
    try read_data.fromBin(&reader);
}

pub fn fromDat(self: *Data, r: *Reader) !void {
    _ = try dat_file.output.parse(r, null, self);
}

pub const Info = struct {
    name: ?[]const u8,
    latitude: f64,
    longitude: f64,
    altitude: f32,
    delay: i32,

    pub const Packet = extern struct {
        latitude: f64,
        longitude: f64,
        altitude: f32,
        delay: i32,
        name_length: u16,
    };

    pub const init: Info = .{
        .name = null,
        .latitude = 0,
        .longitude = 0,
        .altitude = 0,
        .delay = 0,
    };

    pub fn deinit(self: Info, gpa: Allocator) void {
        if (self.name) |name| {
            gpa.free(name);
        }
    }

    pub fn point(self: *const Info) lma.math(f64).ElemVec {
        return .{ .elems = .{ self.latitude, self.longitude, self.altitude, 0 } };
    }

    pub fn eql(first: Info, second: Info) bool {
        if (first.name) |first_name| {
            if (second.name) |second_name| {
                if (!std.mem.eql(u8, first_name, second_name)) return false;
            } else return false;
        } else if (second.name != null) return false;
        return
        // zig fmt: off
            first.latitude == second.latitude and
            first.longitude == second.longitude and
            first.altitude == second.altitude and
            first.delay == second.delay;
        // zig fmt: on
    }

    pub fn build_partial(packet: Packet) Info {
        return .{
            .name = null,
            .latitude = packet.latitude,
            .longitude = packet.longitude,
            .altitude = packet.altitude,
            .delay = packet.delay,
        };
    }

    pub fn build(packet: Packet, gpa: Allocator, r: *Reader) !Info {
        var out: Info = build_partial(packet);
        if (packet.name_length != 0) {
            out.name = try r.readAlloc(gpa, packet.name_length);
        }
        return out;
    }

    pub fn pack(self: Info) struct { Packet, []const u8 } {
        const name =
            self.name orelse &.{};
        return .{
            .{
                .latitude = self.latitude,
                .longitude = self.longitude,
                .altitude = self.altitude,
                .delay = self.delay,
                .name_length = @intCast(name.len),
            },
            name,
        };
    }
};
