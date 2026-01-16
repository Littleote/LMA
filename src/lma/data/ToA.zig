const Data = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const segmented = @import("segmented.zig");
pub const Segmented = segmented.Segmented(Data, .{
    .version = 1,
    .tag = "toa",
    .extra = "metadata",
    .packet = "packet",
});
const Parser = @import("dat_file.zig").ToAParser;
const Unsupported = error{UnsupportedVersion};

pub const Header = segmented.Header;
segments: Segmented = .{},

/// Data structure header
header: std.ArrayListUnmanaged(Header) = .empty,
/// Packet metadata header
metadata: std.ArrayListUnmanaged(Metadata) = .empty,

/// Compressed data format
packet: std.ArrayListUnmanaged(Body.Packet) = .empty,
/// Data samples
value: std.ArrayListUnmanaged(Body) = .empty,

gpa: Allocator,

/// Helper function to transform an integer into an f64
fn toFloat(integer: anytype) f64 {
    return @floatFromInt(integer);
}

pub fn init(gpa: Allocator) Data {
    return .{ .gpa = gpa };
}

/// Clean all initialized arrays
pub fn deinit(self: *Data) void {
    self.header.deinit(self.gpa);
    self.metadata.deinit(self.gpa);
    self.packet.deinit(self.gpa);
    self.value.deinit(self.gpa);
}

/// Populates the value array by building all packets
pub fn build_all(self: *Data) error{OutOfMemory}!void {
    try self.value.ensureTotalCapacityPrecise(self.gpa, self.packet.items.len);
    self.value.items.len = self.packet.items.len;
    for (self.header.items, 0..) |header, idx| {
        self.build_block(idx, self.value.items[header.start..][0..header.size]);
    }
}

/// Populates a slice with the values generated from the packets in section idx
pub fn build_block(self: *const Data, idx: usize, output: []Body) void {
    const header = self.header.items[idx];
    const metadata = self.metadata.items[idx];
    for (self.packet.items[header.start..][0..header.size], output) |packet, *value| {
        value.* = .build(packet, metadata);
    }
}

pub fn toCsv(self: *const Data, w: *Writer) !void {
    try w.writeAll("Seconds;Nanoseconds;Decibels;Above Threshold\n");
    for (self.header.items) |header| {
        for (header.start..header.start + header.size) |idx| {
            const value = self.value.items[idx];
            try w.print("{d};{d:.2};{d:.3};{d:.0}\n", .{
                header.epoch,
                value.nanosecond,
                value.dB,
                value.above_threshold,
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
        const file = try std.fs.cwd().openFile("data/ToA/250712/bin/LC_UPC_Bujaraloz_250712_120000.bin", .{ .mode = .read_only });
        defer file.close();
        var file_reader = file.reader(&buffer);
        try data.fromBin(&file_reader.interface);
        try data.build_all();
    }

    var discard: Writer.Discarding = .init(&buffer);
    try data.toCsv(&discard.writer);
}

pub fn toBin(self: *const Data, w: *Writer) !void {
    try w.writeAll("LMA-toa-001\n");
    try w.writeInt(usize, self.header.items.len, .little);
    try w.writeInt(usize, self.packet.items.len, .little);
    for (self.header.items, self.metadata.items) |header, metadata| {
        try w.writeStruct(header, .little);
        try w.writeStruct(metadata, .little);
        for (self.packet.items[header.start..][0..header.size]) |packet| {
            try w.writeStruct(packet, .little);
        }
    }
    try w.flush();
}

pub fn fromBin(self: *Data, r: *Reader) !void {
    const info = try r.take(12);
    std.debug.assert(std.mem.eql(u8, info[0..8], "LMA-toa-"));
    const version = try std.fmt.parseInt(usize, info[8..11], 10);
    std.debug.assert(info[11] == '\n');
    switch (version) {
        1 => {
            const header_len = try r.takeInt(usize, .little);
            const value_len = try r.takeInt(usize, .little);
            try self.header.ensureTotalCapacityPrecise(self.gpa, header_len);
            self.header.items.len = header_len;
            try self.metadata.ensureTotalCapacityPrecise(self.gpa, header_len);
            self.metadata.items.len = header_len;
            try self.packet.ensureTotalCapacityPrecise(self.gpa, value_len);
            self.packet.items.len = value_len;

            for (0..header_len) |idx| {
                self.header.items[idx] = try r.takeStruct(Header, .little);
                self.metadata.items[idx] = try r.takeStruct(Metadata, .little);
                const header = self.header.items[idx];
                for (self.packet.items[header.start..][0..header.size]) |*packet| {
                    packet.* = try r.takeStruct(Body.Packet, .little);
                }
            }
        },
        else => return error.UnsupportedVersion,
    }
}

test "BIN format" {
    const file = try std.fs.cwd().openFile("data/ToA/250712/bin/LC_UPC_Bujaraloz_250712_120000.bin", .{ .mode = .read_only });
    defer file.close();
    var file_reader = file.reader(&.{});

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
    var w: Writer.Allocating = .init(self.gpa);
    defer w.deinit();
    _ = try r.streamRemaining(&w.writer);
    try self.fromDatBuffer(w.written());
}

pub fn fromDatFile(self: *Data, file: std.fs.File, buffer: []u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var file_reader = file.reader(io, buffer);
    const parser: Parser = try .init(&file_reader.interface);
    file_reader.seekTo(0) catch unreachable;
    try parser.parseAllHeaders(self, &file_reader.interface);
    file_reader.seekTo(0) catch unreachable;
    try parser.parseAllPackets(self, &file_reader.interface);
}

pub fn fromDatBuffer(self: *Data, buffer: []u8) !void {
    var reader: Reader = .fixed(buffer);
    const parser: Parser = Parser.init(&reader) catch |err| {
        switch (err) {
            error.ReadFailed, error.EndOfStream => unreachable,
        }
    };
    reader = .fixed(buffer);
    parser.parseAllHeaders(self, &reader) catch |err| {
        switch (err) {
            error.OutOfMemory, error.UnsupportedVersion => |new_err| return new_err,
            error.ReadFailed => unreachable,
        }
    };
    reader = .fixed(buffer);
    parser.parseAllPackets(self, &reader) catch |err| {
        switch (err) {
            error.OutOfMemory, error.UnsupportedVersion => |new_err| return new_err,
            error.ReadFailed => unreachable,
        }
    };
}

test Parser {
    const file = try std.fs.cwd().openFile("data/ToA/250712/sources/LC_UPC_Bujaraloz_250712_120000.dat", .{ .mode = .read_only });
    defer file.close();
    var buffer: [1024]u8 = undefined;

    {
        var data: Data = .init(std.testing.allocator);
        defer data.deinit();

        var file_reader = file.reader(&buffer);
        _ = try data.fromDat(&file_reader.interface);
    }
    {
        var data: Data = .init(std.testing.allocator);
        defer data.deinit();

        _ = try data.fromDatFile(file, &buffer);
    }
}

pub const Metadata = packed struct(u16) {
    pd: i16 = 0,

    pub const blank: Metadata = .{};
};

pub const Body = struct {
    pub const Packet = packed struct(u48) {
        nano_x40: u28,
        above: u12,
        max: u8,
    };

    nanosecond: f64,
    dB: f64,
    above_threshold: f64,

    pub fn build(packet: Packet, metadata: Metadata) Body {
        const factor: f64 = std.time.ns_per_s / (std.time.ns_per_s / 40.0 + toFloat(metadata.pd));
        return .{
            .dB = 0.488 * toFloat(packet.max) - 111.0,
            .nanosecond = toFloat(packet.nano_x40) * factor,
            .above_threshold = toFloat(packet.above),
        };
    }
};
