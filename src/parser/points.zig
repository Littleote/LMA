const std = @import("std");

const data = @import("lma").data;
const nargs = @import("nargs");

const utils = @import("utils.zig");

pub const root = nargs.groups.any("POINTS", .{
    .station = nargs.params.param("station", nargs.types.unset(nargs.types.string), .single, .{ .short = .auto, .default = @as(?[]const u8, null) }),
    .frequency = nargs.params.param("freq", nargs.types.unsigned, .single, .{ .default = 60 * 60 * 1 }),
});

pub fn parse(io: std.Io, gpa: std.mem.Allocator, path: []const u8, args: @TypeOf(root).Type) !void {

    // Input directory
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    // Output CSV directory
    var csv_dir = try utils.forceOpen(io, dir, "../csv", .{});
    defer csv_dir.close(io);

    // Output BIN directory
    var bin_dir = try utils.forceOpen(io, dir, "../bin", .{});
    defer bin_dir.close(io);

    // Output Station directory

    var station: ?std.Io.Dir = null;
    if (args.station) |station_path| {
        station = utils.forceOpen(io, std.Io.Dir.cwd(), station_path, .{}) catch null;
    }
    defer if (station) |*station_dir| station_dir.close(io);

    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;
    // Iterate for all test source files
    var iterator = dir.iterate();
    var load_stations = station != null;
    while (try iterator.next(io)) |entry| {
        var loaded = false;
        var time: ?usize = null;
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
                break :blk if (points.headers.items.len == 0) null else points.headers.items[0].epoch;
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
                const bin = try station.?.createFile(io, "stations.bin", .{});
                defer bin.close(io);
                var file_writer = bin.writer(io, &buffer);
                try stations.toBin(&file_writer.interface);
            }
        }
        load_stations = load_stations and !loaded;
    }
}
