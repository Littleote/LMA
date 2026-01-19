const std = @import("std");
const lma = @import("lma");
const ToA = lma.data.ToA;

const utils = @import("utils.zig");

pub fn parse(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    // Input directory
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    // Output CSV directory
    var csv_dir = try utils.forceOpen(dir, "../csv", .{});
    defer csv_dir.close();

    // Output BIN directory
    var bin_dir = try utils.forceOpen(dir, "../bin", .{});
    defer bin_dir.close();

    // Iterate for all test source files
    var iterator = dir.iterate();
    while (iterator.next()) |maybe_entry| {
        if (maybe_entry) |entry| {
            var buffer: [1024]u8 = undefined;
            var data: ToA = blk: {
                // Parse source file
                const file = try dir.openFile(
                    entry.name,
                    .{ .mode = .read_only },
                );
                defer file.close();
                var file_reader = file.reader(io, &buffer);
                break :blk try lma.data.dat_file.toa.fromFile(&file_reader, gpa);
            };
            defer data.deinit();

            {
                // Save as CSV
                const name = try gpa.dupe(u8, entry.name);
                defer gpa.free(name);
                @memcpy(name[name.len - 3 ..], "csv");
                const csv = try csv_dir.createFile(name, .{});
                defer csv.close();
                var file_writer = csv.writer(&buffer);

                try data.toCsv(&file_writer.interface, null);
            }

            {
                // Save as BIN
                const name = try gpa.dupe(u8, entry.name);
                defer gpa.free(name);
                @memcpy(name[name.len - 3 ..], "bin");
                const bin = try bin_dir.createFile(name, .{});
                defer bin.close();
                var file_writer = bin.writer(&buffer);
                try data.toBin(&file_writer.interface);
            }
        } else break;
    } else |err| return err;
}
