const std = @import("std");

const lma = @import("lma");
const Signal = lma.data.Signal;
const nargs = @import("nargs");
const opt = nargs.options;

const utils = @import("utils.zig");

pub const Cli = struct {};
pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "signals" }, .{}));

pub fn parse(io: std.Io, gpa: std.mem.Allocator, path: []const u8, args: Cli) !void {
    _ = args;

    // Input directory
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    // Output CSV directory
    var csv_dir = try dir.createDirPathOpen(io, "../csv", .{});
    defer csv_dir.close(io);

    // Output BIN directory
    var bin_dir = try dir.createDirPathOpen(io, "../bin", .{});
    defer bin_dir.close(io);

    // Iterate for all test source files
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, "dat")) {
            std.log.err("Unrecognized file type \"{s}\"", .{entry.name});
            continue;
        }

        var buffer: [1024]u8 = undefined;
        var data: Signal = .init(gpa);
        defer data.deinit();
        {
            // Parse source file
            const file = try dir.openFile(
                io,
                entry.name,
                .{ .mode = .read_only },
            );
            defer file.close(io);
            var file_reader = file.reader(io, &buffer);
            try lma.data.dat_file.signals.fromFile(&file_reader, &data);
        }

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
    }
}
