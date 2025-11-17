const std = @import("std");
const Dir = std.fs.Dir;

pub fn forceOpen(dir: Dir, path: []const u8, args: Dir.OpenOptions) !Dir {
    const new_dir = dir.openDir(path, args) catch |err| blk: {
        if (err == error.FileNotFound) {
            try dir.makePath(path);
            break :blk dir.openDir(path, args) catch unreachable;
        }
        return err;
    };
    return new_dir;
}
