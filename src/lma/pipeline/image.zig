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
};

pub fn toBMP(
    shape: Shape,
    values: []const u8,
    palette: *const [256]Color,
    w: *std.Io.Writer,
) !void {
    const padding = 3 - @mod(shape.columns - 1, 4);
    const start_offset = 14 + 12 + 256 * 3;

    // BitMap Header
    try w.writeAll("BM");
    try w.writeInt(
        u32,
        start_offset + @as(u32, @intCast((shape.columns + padding) * shape.rows)),
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

    // Pixel Storage
    for (0..shape.rows) |row| {
        const start = shape.ravel(row, 0);
        try w.writeAll(values[start..][0..shape.columns]);
        std.debug.assert(padding == try w.splatByte(0, padding));
    }
    try w.flush();
}

test toBMP {
    const gpa = std.testing.allocator;
    const file = try std.fs.cwd().createFile("test_image.bmp", .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&buffer);

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

    try toBMP(shape, values, &palettes.heat, &file_writer.interface);
}
