const std = @import("std");

const data = @import("lma").data;
const nargs = @import("nargs");
const opt = nargs.options;

const utils = @import("utils.zig");

pub const Cli = struct {
    path: []const u8,
    station: ?[]const u8,
};

pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "points" }, .{
    .path = .build(opt.Named, .single(.string, .{ .name = "input", .description = "Input folder with the '.dat' files.", .short = .auto })),
    .station = .optional(.{ .default = "Ignore station data." }, .build(opt.Named, .single(.string, .{
        .name = "station",
        .description = "Directory where to store the 'stations.csv' file.",
        .short = .auto,
    }))),
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

    // Output Station directory

    var station: ?std.Io.Dir = null;
    if (args.station) |station_path| {
        station = std.Io.Dir.cwd().createDirPathOpen(io, station_path, .{}) catch null;
    }
    defer if (station) |*station_dir| station_dir.close(io);

    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;
    // Iterate for all test source files
    var iterator = dir.iterate();
    var load_stations = station != null;
    while (try iterator.next(io)) |entry| {
        var loaded = false;
        var time: ?u64 = null;
        var points: data.Points = .init(gpa);
        defer points.deinit();
        var stations: data.Stations = .init(gpa);
        defer stations.deinit();
        {
            // Parse source file
            const file = try dir.openFile(io, entry.name, .{ .mode = .read_only });
            defer file.close(io);
            var file_reader = file.reader(io, &buffer);
            loaded = true;
            time = blk: {
                data.dat_file.output.parse(
                    &file_reader.interface,
                    &points,
                    if (load_stations) &stations else null,
                ) catch {
                    loaded = false;
                    const upper_bound = @divTrunc(try file_reader.getSize(), 70);
                    points.deinit();
                    points = .init(gpa);
                    file_reader.seekTo(0) catch unreachable;
                    data.dat_file.output.parsePoints(
                        &file_reader.interface,
                        &points,
                        null,
                        @min(86400, upper_bound),
                        @intCast(upper_bound),
                    ) catch continue;
                    if (!points.empty()) break :blk points.start_epoch;
                    break :blk null;
                };
                break :blk points.start_epoch;
            };
            if (time == null) continue;
        }
        const save_time = utils.saveTime(null, time, 60 * 10 * 1);
        {
            // Save as CSV
            {
                const name = utils.fileName(&name_buffer, save_time, "csv");
                const csv = try csv_dir.createFile(io, name, .{});
                defer csv.close(io);
                var file_writer = csv.writer(io, &buffer);
                try points.toCsv(&file_writer.interface, null);
            }

            if (load_stations and loaded) {
                const csv = try station.?.createFile(io, "stations.csv", .{});
                defer csv.close(io);
                var file_writer = csv.writer(io, &buffer);
                try stations.toCsv(&file_writer.interface, null);
            }
        }

        {
            // Save as BIN
            {
                const name = utils.fileName(&name_buffer, save_time, "bin");
                const bin = try bin_dir.createFile(io, name, .{});
                defer bin.close(io);
                var file_writer = bin.writer(io, &buffer);
                try points.toBin(&file_writer.interface);
            }

            if (load_stations and loaded) {
                const csv = try station.?.createFile(io, "stations.csv", .{});
                defer csv.close(io);
                var file_writer = csv.writer(io, &buffer);
                try stations.toCsv(&file_writer.interface, null);
            }
        }
        load_stations = load_stations and !loaded;
    }
}
