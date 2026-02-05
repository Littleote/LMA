const std = @import("std");
const Dir = std.Io.Dir;

pub fn forceOpen(io: std.Io, dir: Dir, path: []const u8, args: Dir.OpenOptions) !Dir {
    const new_dir = dir.openDir(io, path, args) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk try dir.createDirPathOpen(io, path, .{ .open_options = args });
        }
        return err;
    };
    return new_dir;
}

pub fn saveTime(save: ?usize, time: ?usize, save_frequency: usize) usize {
    return save_frequency * if (save) |save_number| save_number else @divFloor(time.?, save_frequency);
}

pub fn fileName(buffer: []u8, time: usize, extension: []const u8) []const u8 {
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
