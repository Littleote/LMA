const std = @import("std");

const lma = @import("lma");
const Clusters = lma.data.Clusters;
const nargs = @import("nargs");

const utils = @import("utils.zig");

const save_frequency = 10 * 60;

const Delimiter = enum(u8) {
    comma = ',',
    semicolon = ';',
    tab = '\t',
    bar = '|',
    space = ' ',
};

pub const root = nargs.groups.any("CLUSTERS", .{ .delimiter = nargs.params.param("delimiter", nargs.types.options(Delimiter), .single, .{ .short = .auto, .default = .space }) });

pub fn parse(io: std.Io, gpa: std.mem.Allocator, path: []const u8, args: @TypeOf(root).Type) !void {
    const delimiter = @intFromEnum(args.delimiter);

    // Input file
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    // Open directories
    const dir_path = std.Io.Dir.path.dirname(path) orelse "../";
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    // Output CSV directory
    SaveInfo.csv_dir = try utils.forceOpen(io, dir, "csv", .{});
    defer SaveInfo.csv_dir.?.close(io);

    // Output BIN directory
    SaveInfo.bin_dir = try utils.forceOpen(io, dir, "bin", .{});
    defer SaveInfo.bin_dir.?.close(io);

    var data: Clusters = .init(gpa);
    errdefer data.deinit();
    var last_header = try data.headers.addOne(gpa);
    var last_second: u64 = 0;
    var last_save: u64 = @divFloor(last_second, save_frequency);
    last_header.start = @intCast(data.array.items.len);
    data.start_epoch = last_second;
    var group: std.Io.Group = .init;

    // Async saving
    defer group.await(io) catch {};

    const header = try file_reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    {
        const expected = [_][]const u8{ "tim", "lon", "lat", "alt", "pow", "fnr" };
        const fields = 1 + std.mem.countScalar(u8, header, delimiter);
        if (fields != expected.len) {
            std.log.err("Expected:\n{1s}{0c}{2s}{0c}{3s}{0c}{4s}{0c}{5s}{0c}{6s}\n", .{
                delimiter,
                expected[0],
                expected[1],
                expected[2],
                expected[3],
                expected[4],
                expected[5],
            });
            std.log.err("Found\n{s}\n", .{header});
            return error.HeaderMismatch;
        }
        var tokens = std.mem.tokenizeScalar(u8, header, delimiter);
        for (expected) |name| {
            const token = tokens.next().?;
            if (!std.mem.eql(u8, token, name)) {
                std.log.err("Expected:\n{1s}{0c}{2s}{0c}{3s}{0c}{4s}{0c}{5s}{0c}{6s}\n", .{
                    delimiter,
                    expected[0],
                    expected[1],
                    expected[2],
                    expected[3],
                    expected[4],
                    expected[5],
                });
                std.log.err("Found\n{s}\n", .{header});
                return error.HeaderMismatch;
            }
        }
    }

    while (try file_reader.interface.takeDelimiter('\n')) |line| {
        var iterator = std.mem.tokenizeScalar(u8, line, delimiter);
        const time = std.math.modf(try std.fmt.parseFloat(f64, iterator.next().?));
        const second: usize = @intFromFloat(time.ipart);

        if (second != last_second) {
            @branchHint(.unlikely);
            last_second = second;
            last_header.size = @intCast(data.array.items.len - last_header.start);
            if (@divFloor(second, save_frequency) != last_save) {
                @branchHint(.unlikely);
                last_save += 1;
                group.async(io, saveFiles, .{ io, data, null });
                const size = .{ .headers = data.headers.items.len, .array = data.array.items.len };
                data = .init(gpa);
                while (@divFloor(second, save_frequency) != last_save) : (last_save += 1) {
                    data.start_epoch = last_save * save_frequency;
                    group.async(io, saveFiles, .{ io, data, last_save });
                }
                data.start_epoch = last_save * save_frequency;
                try data.headers.ensureTotalCapacity(gpa, size.headers);
                try data.array.ensureTotalCapacity(gpa, size.array);
            }
            const delta = second - (data.start_epoch + data.headers.items.len) + 1;
            try data.headers.appendNTimes(gpa, .{ .start = @intCast(data.array.items.len), .size = 0 }, delta);
            last_header = &data.headers.items[data.headers.items.len - 1];
        }
        try data.array.append(gpa, .{
            .nanosecond = @intFromFloat(@round(4 * 1_000_000_000 * (time.fpart))),
            .longitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .latitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .altitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .dBW = try std.fmt.parseFloat(f16, iterator.next().?),
            // Both 0 and -1 Indicate a noise value
            .cluster = @enumFromInt(lma.cast.as(u32, @max(0, try std.fmt.parseInt(isize, iterator.next().?, 10)))),
        });
    }
    last_header.size = @intCast(data.array.items.len - last_header.start);
    group.async(io, saveFiles, .{ io, data, null });
    data.headers.items.len = 0;
    data.array.items.len = 0;
    while (@divFloor(60 * 60 * 24, save_frequency) != last_save) : (last_save += 1) {
        group.async(io, saveFiles, .{ io, Clusters.init(gpa), last_save });
    }
}

const SaveInfo = struct {
    var csv_dir: ?std.Io.Dir = null;
    var bin_dir: ?std.Io.Dir = null;
};

fn saveFiles(io: std.Io, data: Clusters, save_time: ?usize) std.Io.Cancelable!void {
    var mutable_data = data;
    defer mutable_data.deinit();
    if (SaveInfo.bin_dir) |dir|
        try saveBin(io, data, save_time, dir);
    if (SaveInfo.csv_dir) |dir|
        try saveCsv(io, data, save_time, dir);
}

fn saveCsv(io: std.Io, data: Clusters, save_time: ?usize, dir: std.Io.Dir) std.Io.Cancelable!void {
    const time = utils.saveTime(
        save_time,
        data.start_epoch,
        save_frequency,
    );

    var buffer: [4096]u8 = undefined;
    var name_buffer: [32]u8 = undefined;

    const name = utils.fileName(&name_buffer, time, "csv");
    const file = dir.createFile(io, name, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.err("Failed to create file {s}\n", .{name});
            return;
        },
    };
    defer file.close(io);
    var file_writer = file.writer(io, &buffer);

    data.toCsv(&file_writer.interface, null) catch {
        std.log.err("Failed to write file {s}\n", .{name});
        return;
    };
}

fn saveBin(io: std.Io, data: Clusters, save_time: ?usize, dir: std.Io.Dir) std.Io.Cancelable!void {
    const time = utils.saveTime(
        save_time,
        data.start_epoch,
        save_frequency,
    );

    var buffer: [4096]u8 = undefined;
    var name_buffer: [32]u8 = undefined;

    const name = utils.fileName(&name_buffer, time, "bin");
    const file = dir.createFile(io, name, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.err("Failed to create file {s}\n", .{name});
            return;
        },
    };
    defer file.close(io);
    var file_writer = file.writer(io, &buffer);

    data.toBin(&file_writer.interface) catch {
        std.log.err("Failed to write file {s}\n", .{name});
        return;
    };
}
