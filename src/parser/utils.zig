const std = @import("std");

pub fn saveTime(save: ?u64, time: ?u64, save_frequency: u64) u64 {
    return save_frequency * if (save) |save_number| save_number else @divFloor(time.? + (save_frequency >> 1), save_frequency);
}

pub fn fileName(buffer: []u8, time: u64, extension: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{d:0>2}h-{d:0>2}min-{d:0>2}s.{s}",
        .{
            @divFloor(time, 60 * 60),
            @mod(@divFloor(time, 60), 60),
            @mod(time, 60),
            extension,
        },
    ) catch unreachable;
}
