const std = @import("std");
const lma = @import("../lma.zig");
const Color = lma.graphics.Color;
const Shape = lma.grid.Shape;

const start_offset = 14 + 12 + 256 * 3;
fn padding(shape: Shape) usize {
    return 3 - @mod(shape.columns - 1, 4);
}

pub fn fromBytes(
    shape: Shape,
    values: []const u8,
    palette: *const [256]Color,
    w: *std.Io.Writer,
) !void {
    const pad = padding(shape);
    try writeHeader(shape, palette, w);

    // Pixel Storage
    for (0..shape.rows) |row| {
        const start = shape.ravel(row, 0);
        try w.writeAll(values[start..][0..shape.columns]);
        std.debug.assert(pad == try w.splatByte(0, pad));
    }
    try w.flush();
}

pub fn intToBMP(
    Int: type,
    shape: Shape,
    values: []const Int,
    palette: *const [256]Color,
    w: *std.Io.Writer,
) !void {
    const pad = padding(shape);
    try writeHeader(shape, palette, w);

    // Pixel Storage
    for (0..shape.rows) |row| {
        const start = shape.ravel(row, 0);
        for (values[start..][0..shape.columns]) |value| {
            try w.writeByte(@intCast(value));
        }
        std.debug.assert(pad == try w.splatByte(0, pad));
    }
    try w.flush();
}

pub fn floatToBMP(
    Float: type,
    shape: Shape,
    values: []const Float,
    palette: *const [256]Color,
    w: *std.Io.Writer,
) !void {
    const pad = padding(shape);
    try writeHeader(shape, palette, w);

    // Pixel Storage
    for (0..shape.rows) |row| {
        const start = shape.ravel(row, 0);
        for (values[start..][0..shape.columns]) |value| {
            try w.writeByte(@intFromFloat(@round(std.math.clamp(255.0 * value, 0, 255.0))));
        }
        std.debug.assert(pad == try w.splatByte(0, pad));
    }
    try w.flush();
}

pub fn writeHeader(
    shape: Shape,
    palette: *const [256]Color,
    w: *std.Io.Writer,
) !void {

    // BitMap Header
    try w.writeAll("BM");
    try w.writeInt(
        u32,
        start_offset + @as(u32, @intCast((shape.columns + padding(shape)) * shape.rows)),
        .little,
    );
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, start_offset, .little);

    // DIB Header
    try w.writeInt(u32, 12, .little);
    try w.writeInt(u16, @intCast(shape.columns), .little);
    try w.writeInt(u16, @intCast(shape.rows), .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 8, .little);

    // Color Palette
    for (palette) |color| {
        try w.writeStruct(color, .little);
    }
}

test fromBytes {
    const gpa = std.testing.allocator;
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, "test/test_bitmap_fromBytes.bmp", .{});
    defer file.close(std.testing.io);

    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(std.testing.io, &buffer);

    const shape: Shape = .init(255, 255);
    const values = try gpa.alloc(u8, shape.size);
    defer gpa.free(values);

    var generator: std.Random.DefaultPrng = .init(0);
    const rng = generator.random();
    for (0..shape.rows) |row| {
        for (0..shape.columns) |col| {
            const idx = shape.ravel(row, col);
            values[idx] = if (col < 128) @intCast(row) else rng.int(u8);
        }
    }

    try fromBytes(shape, values, &lma.graphics.palettes.plasma, &file_writer.interface);
}
