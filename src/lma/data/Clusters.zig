const Data = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const segmented = @import("segmented.zig");
pub const Segmented = segmented.Segmented(Data, .{
    .version = 1,
    .tag = "clust",
});
const Unsupported = error{UnsupportedVersion};

pub const Header = segmented.Header;
segments: Segmented = .{},

/// Data structure header
header: std.ArrayListUnmanaged(Header) = .empty,

/// Data samples
value: std.ArrayListUnmanaged(Body) = .empty,

gpa: Allocator,

pub fn init(gpa: Allocator) Data {
    return .{ .gpa = gpa };
}

/// Clean all initialized arrays
pub fn deinit(self: *Data) void {
    self.header.deinit(self.gpa);
    self.value.deinit(self.gpa);
}

pub fn toCsv(self: *const Data, w: *Writer) !void {
    try w.writeAll("Time;Latitude;Longitude;Altitude;Power;Cluster\n");
    for (self.header.items) |header| {
        for (header.start..header.start + header.size) |idx| {
            const value = self.value.items[idx];
            try w.print("{d:.9};{d:.8};{d:.8};{d:.2};{d:.1};{d}\n", .{
                @as(f64, @floatFromInt(header.epoch)) + value.nanosecond,
                value.latitude,
                value.longitude,
                value.altitude,
                value.dBW,
                value.cluster.value,
            });
        }
    }
    try w.flush();
}

test toCsv {
    var data: Data = .init(std.testing.allocator);
    defer data.deinit();
    var buffer: [1024]u8 = undefined;
    {
        // Load some values into the data structure
        const file = try std.fs.cwd().openFile("data/lightnings/250712/bin/00h-00min-00s.bin", .{ .mode = .read_only });
        defer file.close();
        var file_reader = file.reader(std.testing.io, &buffer);
        try data.fromBin(&file_reader.interface);
    }

    var discard: Writer.Discarding = .init(&buffer);
    try data.toCsv(&discard.writer);
}

pub fn toBin(self: *const Data, w: *Writer) !void {
    try w.writeAll("LMA-clust-001\n");
    try w.writeInt(usize, self.header.items.len, .little);
    try w.writeInt(usize, self.value.items.len, .little);
    for (self.header.items) |header| {
        try w.writeStruct(header, .little);
        try w.writeSliceEndian(Body, self.value.items[header.start..][0..header.size], .little);
    }
    try w.flush();
}

pub fn fromBin(self: *Data, r: *Reader) !void {
    const info = try r.take(14);
    std.debug.assert(std.mem.eql(u8, info[0..10], "LMA-clust-"));
    const version = try std.fmt.parseInt(usize, info[10..13], 10);
    std.debug.assert(info[13] == '\n');
    switch (version) {
        1 => {
            const header_len = try r.takeInt(usize, .little);
            const value_len = try r.takeInt(usize, .little);
            try self.header.ensureTotalCapacityPrecise(self.gpa, header_len);
            self.header.items.len = header_len;
            try self.value.ensureTotalCapacityPrecise(self.gpa, value_len);
            self.value.items.len = value_len;

            for (0..header_len) |idx| {
                self.header.items[idx] = try r.takeStruct(Header, .little);
                const header = self.header.items[idx];
                try r.readSliceEndian(Body, self.value.items[header.start..][0..header.size], .little);
            }
        },
        else => return error.UnsupportedVersion,
    }
}

test "BIN format" {
    const file = try std.fs.cwd().openFile("data/lightnings/250712/bin/00h-00min-00s.bin", .{ .mode = .read_only });
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

pub const Body = extern struct {
    nanosecond: f64,
    latitude: f64,
    longitude: f64,
    altitude: f32,
    cluster: Cluster,
    dBW: f16,

    pub const Cluster = packed struct(u32) {
        value: u32,

        pub const noise: Cluster = .{ .value = 0 };
        pub fn cluster(value: u32) Cluster {
            std.debug.assert(value != Cluster.noise.value);
            return .{ .value = value };
        }

        pub fn isNoise(self: Cluster) bool {
            return self == noise;
        }

        pub fn id(self: Cluster) ?u32 {
            return if (self.isNoise()) null else self.value;
        }
    };
};
