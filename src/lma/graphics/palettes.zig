const std = @import("std");

const lma = @import("../lma.zig");
const Color = lma.graphics.Color;
const Palette = lma.graphics.Palette;
const Grid = lma.grid.Shape;

const Float = f32;
const math = lma.math(Float);
const Vec = math.Vec;

fn lerp(a: Color, b: Color, comptime n: usize) [n]Color {
    @setEvalBranchQuota(n * 100);
    var arr: [n]Color = undefined;
    const a_vec: Vec = .{ a.r, a.g, a.b, 0 };
    const b_vec: Vec = .{ b.r, b.g, b.b, 0 };
    for (0..n) |i| {
        const t: Float = lma.cast.to(Float, i) / lma.cast.to(Float, n - 1);
        const col_vec: math.ElemVec = .init(std.math.lerp(a_vec, b_vec, math.vector.splat(t)));
        arr[i] = .{ .r = @round(col_vec.x()), .g = @round(col_vec.y()), .b = @round(col_vec.z()) };
    }
    return arr;
}

fn chainLerp(comptime n: usize, keys: [n]Color, comptime indices: [n]comptime_int) [indices[n - 1]]Color {
    const len = indices[n - 1];
    var out: [len]Color = undefined;
    inline for (0.., 1..n) |a, b| {
        const idx_a, const idx_b = .{ indices[a], indices[b] };
        const true_len = idx_b - idx_a;
        const request_len = if (b == n) true_len else true_len + 1;
        out[idx_a..idx_b].* = lerp(keys[a], keys[b], request_len)[0..true_len].*;
    }
    return out;
}

pub fn sequential(a: Color, b: Color, comptime marks: []const Color) Palette {
    return lerp(a, b, 256 - marks.len) ++ marks[0..marks.len].*;
}

pub fn diverging(a: Color, b: Color, c: Color, comptime marks: []const Color) Palette {
    const len = 256 - marks.len;
    return chainLerp(3, .{ a, b, c }, .{ 0, len / 2, len }) ++ marks[0..marks.len].*;
}

// Palette shiny 16 by green guy
pub const shiny16: [16]Color = .{
    .fromHex(0x1f1723),
    .fromHex(0x3c2f52),
    .fromHex(0x8c7f90),
    .fromHex(0xbcb0b3),
    .fromHex(0xe2e2e2),
    .fromHex(0xd86830),
    .fromHex(0xf09548),
    .fromHex(0xefd081),
    .fromHex(0xb22741),
    .fromHex(0xf5464c),
    .fromHex(0xf79c88),
    .fromHex(0x4656a5),
    .fromHex(0x4995f3),
    .fromHex(0x72deeb),
    .fromHex(0x3ec54b),
    .fromHex(0xb4e656),
};

fn clamp(val: f32) u8 {
    return @round(@min(@max(255 * val, 0), 255));
}
fn get(val: usize) f32 {
    return @as(f32, val) / 255;
}

pub const black2white: Palette = lerp(.black, .white, 256);
pub const marked_black2white: Palette = lerp(.black, .white, 240) ++ shiny16;

const viridis_marks: [5]Color = .{
    .fromRgb(68, 1, 84),
    .fromRgb(59, 82, 139),
    .fromRgb(33, 145, 140),
    .fromRgb(94, 201, 98),
    .fromRgb(253, 231, 37),
};

pub const viridis: Palette = chainLerp(5, viridis_marks, .{ 0, 64, 128, 192, 256 });
pub const marked_viridis: Palette = chainLerp(5, viridis_marks, .{ 0, 60, 120, 180, 240 }) ++ shiny16;

const plasma_marks: [5]Color = .{
    .fromRgb(13, 8, 135),
    .fromRgb(126, 3, 168),
    .fromRgb(204, 71, 120),
    .fromRgb(248, 149, 64),
    .fromRgb(240, 249, 33),
};

pub const plasma: Palette = chainLerp(5, plasma_marks, .{ 0, 64, 128, 192, 256 });
pub const marked_plasma: Palette = chainLerp(5, plasma_marks, .{ 0, 60, 120, 180, 240 }) ++ shiny16;

pub const R3G3B2 = lma.graphics.color.ByteColor;

pub const r3g3b2: Palette = blk: {
    @setEvalBranchQuota(256 * 100);
    var out: Palette = undefined;
    for (0..256) |idx| {
        const col: R3G3B2 = @fromBackingInt(@as(u8, idx));
        out[idx] = col.asColor();
    }
    break :blk out;
};

const named: Palette = blk: {
    @setEvalBranchQuota(256 * 100);
    var out: Palette = @splat(.black);
    var i = 0;
    for (@typeInfo(Color).@"struct".decl_names) |name| {
        if (@TypeOf(@field(Color, name)) != Color) continue;
        out[i] = @field(Color, name);
        i += 1;
    }
    break :blk out;
};

fn drawPaletteDemo(comptime name: []const u8, palette: *const Palette) !void {
    const shape: lma.grid.Shape = comptime .init(256, 256);
    const color: lma.grid.Shape = comptime .init(16, 16);
    var canvas: [shape.size]u8 = @splat(0);

    for (0..256) |row| {
        for (0..256) |col| {
            canvas[shape.ravel(row, col)] = @intCast(color.ravel(row / 16, col / 16));
        }
    }

    var buffer: [1024]u8 = undefined;
    const output = try std.Io.Dir.cwd().createFile(std.testing.io, std.fmt.comptimePrint("test/graphics/test_palette_{s}.bmp", .{name}), .{});
    defer output.close(std.testing.io);
    var output_writer = output.writer(std.testing.io, &buffer);

    try lma.graphics.bitmap.fromBytes(shape, &canvas, palette, &output_writer.interface);
}

fn drawPaletteFromDecl(comptime name: @EnumLiteral()) !void {
    try drawPaletteDemo(@tagName(name), &@field(@This(), @tagName(name)));
}

test "palette view" {
    try drawPaletteFromDecl(.black2white);
    try drawPaletteFromDecl(.marked_black2white);
    try drawPaletteDemo("blue2yellow", &sequential(.blue, .yellow, &.{}));
    try drawPaletteDemo("diverge_red2blue", &diverging(.red, .white, .blue, &.{}));
    try drawPaletteFromDecl(.viridis);
    try drawPaletteFromDecl(.marked_viridis);
    try drawPaletteFromDecl(.plasma);
    try drawPaletteFromDecl(.marked_plasma);
    try drawPaletteFromDecl(.r3g3b2);
    try drawPaletteFromDecl(.named);
}
