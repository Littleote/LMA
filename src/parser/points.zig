const std = @import("std");

const lma = @import("lma");
const data = lma.data;
const Point = data.Point;
const nargs = @import("nargs");
const opt = nargs.options;

const utils = @import("utils.zig");

pub const Cli = struct {
    path: []const u8,
};

pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "points" }, .{
    .path = .build(opt.Named, .single(.string, .{ .name = "input", .description = "Input folder with the '.dat' files.", .short = .auto })),
}));

pub fn parse(io: std.Io, gpa: std.mem.Allocator, args: Cli) !void {

    // Input directory
    var dir = try std.Io.Dir.cwd().openDir(io, args.path, .{ .iterate = true });
    defer dir.close(io);

    // Output CSV directory
    var csv_dir = try dir.createDirPathOpen(io, "../csv", .{});
    defer csv_dir.close(io);

    // Output BIN directory
    var bin_dir = try dir.createDirPathOpen(io, "../bin", .{});
    defer bin_dir.close(io);

    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;
    // Iterate for all test source files
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        var loaded = false;
        var time: ?u64 = null;
        var points: Point.List = .init(gpa);
        defer points.deinit();
        var stations: data.Station.List = .init(gpa);
        defer stations.deinit();
        {
            // Parse source file
            const file = try dir.openFile(io, entry.name, .{ .mode = .read_only });
            defer file.close(io);
            var file_reader = file.reader(io, &buffer);
            loaded = true;
            time = blk: {
                data.dat_file.output.read(
                    &file_reader.interface,
                    &points,
                ) catch |e| {
                    const err = switch (e) {
                        error.ReadFailed => file_reader.err orelse error.Unknown,
                        else => |err| err,
                    };
                    std.log.warn("Failed to read flash sources file {q}. ({})", .{ entry.name, err });
                    continue;
                };
                break :blk points.start_epoch;
            };
            if (time == null) continue;
        }
        const save_time = utils.saveTime(null, time, 60 * 10 * 1);
        // Save as CSV
        {
            const name = utils.fileName(&name_buffer, save_time, "csv");
            const csv = try csv_dir.createFile(io, name, .{});
            defer csv.close(io);
            var file_writer = csv.writer(io, &buffer);
            try Point.csv.write(&points, &file_writer.interface, null);
        }

        // Save as BIN
        {
            const name = utils.fileName(&name_buffer, save_time, "bin");
            const bin = try bin_dir.createFile(io, name, .{});
            defer bin.close(io);
            var file_writer = bin.writer(io, &buffer);
            try Point.bin.write(&points, &file_writer.interface);
        }
    }
}
