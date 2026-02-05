const std = @import("std");

const lma = @import("lma");
const ToA = lma.data.ToA;
const nargs = @import("nargs");

const utils = @import("utils.zig");

pub const root = nargs.groups.any("TOA", .{});

pub fn parse(io: std.Io, gpa: std.mem.Allocator, path: []const u8, args: @TypeOf(root).Type) !void {
    _ = args;

    // Input directory
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    // Output CSV directory
    var csv_dir = try utils.forceOpen(io, dir, "../csv", .{});
    defer csv_dir.close(io);

    // Output BIN directory
    var bin_dir = try utils.forceOpen(io, dir, "../bin", .{});
    defer bin_dir.close(io);

    // Iterate for all test source files
    var iterator = dir.iterate();
    while (iterator.next(io)) |maybe_entry| {
        if (maybe_entry) |entry| {
            var buffer: [1024]u8 = undefined;
            var data: ToA = blk: {
                // Parse source file
                const file = try dir.openFile(
                    io,
                    entry.name,
                    .{ .mode = .read_only },
                );
                defer file.close(io);
                var file_reader = file.reader(io, &buffer);
                break :blk try lma.data.dat_file.toa.fromFile(&file_reader, gpa);
            };
            defer data.deinit();

            {
                // Save as CSV
                const name = try gpa.dupe(u8, entry.name);
                defer gpa.free(name);
                @memcpy(name[name.len - 3 ..], "csv");
                const csv = try csv_dir.createFile(io, name, .{});
                defer csv.close(io);
                var file_writer = csv.writer(io, &buffer);

                try data.toCsv(&file_writer.interface, null);
            }

            {
                // Save as BIN
                const name = try gpa.dupe(u8, entry.name);
                defer gpa.free(name);
                @memcpy(name[name.len - 3 ..], "bin");
                const bin = try bin_dir.createFile(io, name, .{});
                defer bin.close(io);
                var file_writer = bin.writer(io, &buffer);
                try data.toBin(&file_writer.interface);
            }
        } else break;
    } else |err| return err;
}
