const std = @import("std");

pub const Color = color.Color;
pub const Palette = [256]Color;

pub const color = @import("graphics/color.zig");
pub const bitmap = @import("graphics/bitmap.zig");
pub const palettes = @import("graphics/palettes.zig");
pub const draw = @import("graphics/draw.zig");

comptime {
    std.testing.refAllDecls(@This());
}
