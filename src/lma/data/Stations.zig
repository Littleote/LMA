const Data = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const dat_file = @import("dat_file.zig");
const lma = @import("../lma.zig");

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

/// Write Stations to a CSV file
/// When delimiter is null, use a comma (`,`)
pub fn toCsv(self: *const Data, w: *Writer, delimiter: ?u8) Writer.Error!void {
    const del = delimiter orelse ',';
    const csv_columns: []const []const u8 = &.{ "Name", "Latitude", "Longitude", "Altitude", "Delay (ns)" };
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
            std.time.ns_per_s * lma.constants.nano.fromNano(f32, station.delay),
        });
    }
    try w.flush();
}

test toCsv {
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

    var discard: Writer.Discarding = .init(&.{});
    try data.toCsv(&discard.writer, null);
}

pub fn toBin(data: *const Data, w: *Writer) !void {
    try w.writeAll("LMA-station-001\n");
    try w.writeInt(usize, data.stations.items.len, .little);
    for (data.stations.items) |station| {
        const packet, const name = station.pack();
        try w.writeStruct(packet, .little);
        try w.writeAll(name);
    }
    try w.flush();
}

pub fn fromBin(self: *Data, r: *Reader) !void {
    const info = try r.take(16);
    std.debug.assert(std.mem.eql(u8, info[0..12], "LMA-station-"));
    const version = try std.fmt.parseInt(usize, info[12..15], 10);
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

pub fn fromDat(self: *Data, r: *Reader) !void {
    _ = try dat_file.parseOutput(null, self, r);
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
