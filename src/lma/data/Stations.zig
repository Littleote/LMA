const Data = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const dat_file = @import("dat_file.zig");

stations: std.ArrayList(Info),
gpa: Allocator,

pub fn init(gpa: Allocator) Data {
    return .{
        .stations = .empty,
        .gpa = gpa,
    };
}

pub fn deinit(self: *Data) void {
    for (self.stations.items) |*station| {
        station.deinit(self.gpa);
    }
    self.stations.deinit(self.gpa);
}

pub fn toCsv(data: *const Data, w: *Writer) !void {
    try w.writeAll("Name;Latitude;Longitude;Altitude;Delay\n");
    for (data.stations.items) |station| {
        try w.print("{s};{};{};{};{}\n", .{
            station.name orelse &.{},
            station.latitude,
            station.longitude,
            station.altitude,
            station.delay,
        });
    }
    try w.flush();
}

test toCsv {
    var data: Data = .init(std.testing.allocator);
    defer data.deinit();
    var buffer: [1024]u8 = undefined;
    {
        // Load some values into the data structure
        const file = try std.fs.cwd().openFile("data/ToA/stations/stations.bin", .{ .mode = .read_only });
        defer file.close();
        var file_reader = file.reader(std.testing.io, &buffer);
        try data.fromBin(&file_reader.interface);
    }

    var discard: Writer.Discarding = .init(&buffer);
    try data.toCsv(&discard.writer);
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
            try self.stations.ensureTotalCapacityPrecise(self.gpa, station_count);
            for (0..station_count) |_| {
                const packet = try r.takeStruct(Info.Packet, .little);
                self.stations.appendAssumeCapacity(try .build(packet, self.gpa, r));
            }
        },
        else => return error.UnsupportedVersion,
    }
}

test "BIN format" {
    const file = try std.fs.cwd().openFile("data/ToA/stations/stations.bin", .{ .mode = .read_only });
    defer file.close();
    var file_reader = file.reader(std.testing.io, &.{});

    var to_buffer: Writer.Allocating = .init(std.testing.allocator);
    defer to_buffer.deinit();
    _ = try file_reader.interface.streamRemaining(&to_buffer.writer);

    const input = try to_buffer.toOwnedSlice();
    defer std.testing.allocator.free(input);

    var data: Data = .init(std.testing.allocator);
    defer data.deinit();
    // Attempt round trip conversion for a sanity check
    var reader: Reader = .fixed(input);
    try data.fromBin(&reader);
    try data.toBin(&to_buffer.writer);

    const output = to_buffer.written();

    try std.testing.expect(std.mem.eql(u8, input, output));
}

pub fn fromDat(self: *Data, r: *Reader) !void {
    _ = try dat_file.parseOutput(null, self, r);
}

test fromDat {
    const file = try std.fs.cwd().openFile("data/points/250712/output/XCALMA_250712_012000_0600.dat", .{ .mode = .read_only });
    defer file.close();
    var buffer: [1024]u8 = undefined;

    var data: Data = .init(std.testing.allocator);
    defer data.deinit();

    var file_reader = file.reader(std.testing.io, &buffer);
    _ = try data.fromDat(&file_reader.interface);
}

pub const Info = struct {
    name: ?[]const u8,
    latitude: f64,
    longitude: f64,
    altitude: f64,
    delay: f64,

    pub const Packet = extern struct {
        latitude: f64,
        longitude: f64,
        altitude: f32,
        delay: f16,
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
                .altitude = @floatCast(self.altitude),
                .delay = @floatCast(self.delay),
                .name_length = @intCast(name.len),
            },
            name,
        };
    }
};
