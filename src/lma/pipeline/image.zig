const std = @import("std");
const Shape = @import("grid.zig").Shape;

pub const Color = packed struct(u24) {
    blue: u8,
    green: u8,
    red: u8,
    // _pad: u8 = 0x00,
};

pub const palettes = struct {
    fn clamp(val: f32) u8 {
        return @intFromFloat(@min(@max(@round(255 * val), 0), 255));
    }
    fn get(val: usize) f32 {
        return @as(f32, val) / 255;
    }

    pub const black2white = blk: {
        @setEvalBranchQuota(255 * 255);
        var arr: [256]Color = undefined;
        for (&arr, 0..256) |*color, value| {
            color.* = .{
                .red = @intCast(value),
                .green = @intCast(value),
                .blue = @intCast(value),
            };
        }
        break :blk arr;
    };

    pub const blue2yellow = blk: {
        @setEvalBranchQuota(255 * 255);
        var arr: [256]Color = undefined;
        for (&arr, 0..) |*color, value| {
            color.* = .{
                .red = @intCast(value),
                .green = @intCast(value),
                .blue = 255 - @as(u8, @intCast(value)),
            };
        }
        break :blk arr;
    };

    pub const viridis = blk: {
        @setEvalBranchQuota(255 * 255);
        var arr: [256]Color = undefined;
        for (&arr, 0..) |*color, value| {
            const val = get(value);
            color.* = .{
                .red = clamp(2 * val * val - 1.5 * val + 0.5),
                .green = clamp(val),
                .blue = clamp(-val * val + val + 0.4),
            };
        }
        break :blk arr;
    };

    pub const marked_viridis = blk: {
        @setEvalBranchQuota(255 * 255);
        var arr: [256]Color = undefined;
        @memcpy(&arr, &viridis);
        arr[252] = .{ .red = 0, .blue = 0, .green = 0 };
        arr[253] = .{ .red = 255, .blue = 127, .green = 0 };
        arr[254] = .{ .red = 255, .blue = 0, .green = 127 };
        arr[255] = .{ .red = 255, .blue = 255, .green = 255 };
        break :blk arr;
    };

    pub const heat = blk: {
        @setEvalBranchQuota(255 * 255);
        var arr: [256]Color = undefined;
        for (&arr, 0..) |*color, value| {
            const val = get(value);
            color.* = .{
                .red = 255,
                .green = clamp(0.25 + 0.75 * val),
                .blue = clamp(1.5 * val * val - 1.2 * val + 0.3),
            };
        }
        break :blk arr;
    };

    pub const marked_heat = blk: {
        @setEvalBranchQuota(255 * 255);
        var arr: [256]Color = undefined;
        @memcpy(&arr, &heat);
        arr[252] = .{ .red = 0, .blue = 0, .green = 0 };
        arr[253] = .{ .red = 0, .blue = 255, .green = 0 };
        arr[254] = .{ .red = 0, .blue = 0, .green = 255 };
        arr[255] = .{ .red = 255, .blue = 255, .green = 255 };
        break :blk arr;
    };
};

const start_offset = 14 + 12 + 256 * 3;
fn padding(shape: Shape) usize {
    return 3 - @mod(shape.columns - 1, 4);
}

pub fn bytesToBMP(
    shape: Shape,
    values: []const u8,
    palette: *const [256]Color,
    w: *std.Io.Writer,
) !void {
    const pad = padding(shape);
    try writeBMPHeader(shape, palette, w);

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
    try writeBMPHeader(shape, palette, w);

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
    try writeBMPHeader(shape, palette, w);

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

pub fn writeBMPHeader(
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

test bytesToBMP {
    const gpa = std.testing.allocator;
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, "test_image.bmp", .{});
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

    try bytesToBMP(shape, values, &palettes.heat, &file_writer.interface);
}
