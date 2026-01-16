const std = @import("std");
const data = @import("lma").data;

const utils = @import("utils.zig");

pub const Args = struct {
    station: ?[]const u8 = null,
    freq: usize = 60 * 10 * 1,

    pub const shorthands = .{
        .s = "station",
    };
};

pub fn parse(gpa: std.mem.Allocator, path: []const u8, args: *const Args) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Input directory
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    // Output CSV directory
    var csv_dir = try utils.forceOpen(dir, "../csv", .{});
    defer csv_dir.close();

    // Output BIN directory
    var bin_dir = try utils.forceOpen(dir, "../bin", .{});
    defer bin_dir.close();

    // Output Station directory

    var station: ?std.fs.Dir = null;
    if (args.station) |station_path| {
        station = utils.forceOpen(std.fs.cwd(), station_path, .{}) catch null;
    }
    defer if (station) |*station_dir| station_dir.close();

    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;
    // Iterate for all test source files
    var iterator = dir.iterate();
    var load_stations = station != null;
    while (try iterator.next()) |entry| {
        var loaded = false;
        var time: ?usize = null;
        var points: data.Points = .init(gpa);
        defer points.deinit();
        var stations: data.Stations = .init(gpa);
        defer stations.deinit();
        {
            // Parse source file
            const file = try dir.openFile(
                entry.name,
                .{ .mode = .read_only },
            );
            defer file.close();
            var file_reader = file.reader(io, &buffer);
            loaded = true;
            time = data.dat_file.parseOutput(
                &points,
                if (load_stations) &stations else null,
                &file_reader.interface,
            ) catch blk: {
                loaded = false;
                const upper_bound = @divTrunc(try file_reader.getSize(), 70);
                points.deinit();
                points = .init(gpa);
                file_reader.seekTo(0) catch unreachable;
                data.dat_file.parsePoints(
                    &points,
                    @min(86400, upper_bound),
                    upper_bound,
                    &file_reader.interface,
                ) catch continue;
                break :blk if (points.header.items.len == 0) null else points.header.items[0].epoch;
            };
            if (time == null) continue;
        }
        const save_time = utils.saveTime(null, time, 60 * 10 * 1);
        {
            // Save as CSV
            {
                const name = utils.fileName(&name_buffer, save_time, "csv");
                const csv = try csv_dir.createFile(name, .{});
                defer csv.close();
                var file_writer = csv.writer(&buffer);
                try points.toCsv(&file_writer.interface);
            }

            if (load_stations and loaded) {
                const csv = try station.?.createFile("stations.csv", .{});
                defer csv.close();
                var file_writer = csv.writer(&buffer);
                try stations.toCsv(&file_writer.interface);
            }
        }

        {
            // Save as BIN
            {
                const name = utils.fileName(&name_buffer, save_time, "bin");
                const bin = try bin_dir.createFile(name, .{});
                defer bin.close();
                var file_writer = bin.writer(&buffer);
                try points.toBin(&file_writer.interface);
            }

            if (load_stations and loaded) {
                const bin = try station.?.createFile("stations.bin", .{});
                defer bin.close();
                var file_writer = bin.writer(&buffer);
                try stations.toBin(&file_writer.interface);
            }
        }
        load_stations = load_stations and !loaded;
    }
}
