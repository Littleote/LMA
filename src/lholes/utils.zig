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
