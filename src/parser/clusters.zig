const std = @import("std");
const lma = @import("lma");
const Clusters = lma.data.Clusters;

const utils = @import("utils.zig");
const save_frequency = 10 * 60;

pub const Args = struct {
    delimiter: enum(u8) {
        comma = ',',
        semicolon = ';',
        tab = '\t',
        bar = '|',
        space = ' ',
    } = .space,

    pub const shorthands = .{
        .d = "delimiter",
    };
};

pub fn parse(io: std.Io, gpa: std.mem.Allocator, path: []const u8, args: *const Args) !void {
    const delimiter = @intFromEnum(args.delimiter);

    // Input file
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    // Open directories
    const dir_path = std.fs.path.dirname(path) orelse "../";
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    // Output CSV directory
    var csv_dir = try utils.forceOpen(dir, "csv", .{});
    defer csv_dir.close();
    var csv_save: std.Io.Group = .init;
    defer csv_save.wait(io);

    // Output BIN directory
    var bin_dir = try utils.forceOpen(dir, "bin", .{});
    defer bin_dir.close();

    var data: Clusters = .init(gpa);
    defer data.deinit();
    var last_header = try data.headers.addOne(gpa);
    var last_second: usize = 0;
    var last_save: usize = @divFloor(last_second, save_frequency);
    last_header.start = @intCast(data.array.items.len);
    last_header.epoch = @intCast(last_second);

    const header = try file_reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    {
        const expected = [_][]const u8{ "tim", "lon", "lat", "alt", "pow", "fnr" };
        const fields = 1 + std.mem.countScalar(u8, header, delimiter);
        if (fields != expected.len) {
            return error.HeaderMismatch;
        }
        var tokens = std.mem.tokenizeScalar(u8, header, delimiter);
        for (expected) |name| {
            const token = tokens.next().?;
            if (!std.mem.eql(u8, token, name)) {
                return error.HeaderMismatch;
            }
        }
    }

    while (try file_reader.interface.takeDelimiter('\n')) |line| {
        var iterator = std.mem.tokenizeScalar(u8, line, delimiter);
        const time = try std.fmt.parseFloat(f64, iterator.next().?);
        const second: usize = @intFromFloat(@floor(time));

        if (second != last_second) {
            @branchHint(.unlikely);
            last_second = second;
            last_header.size = @intCast(data.array.items.len - last_header.start);
            if (@divFloor(second, save_frequency) != last_save) {
                @branchHint(.unlikely);
                last_save += 1;
                {
                    try saveBin(&data, null, false, bin_dir);
                    const csv_data = try gpa.create(Clusters);
                    csv_data.* = try data.copy(gpa);
                    csv_save.async(io, saveCsv, .{ csv_data, null, true, csv_dir });
                }
                data.headers.items.len = 0;
                data.array.items.len = 0;
                while (@divFloor(second, save_frequency) != last_save) : (last_save += 1) {
                    saveBin(&data, last_save, false, bin_dir) catch break;
                    const csv_data = try gpa.create(Clusters);
                    csv_data.* = try data.copy(gpa);
                    csv_save.async(io, saveCsv, .{ csv_data, last_save, true, csv_dir });
                }
            }
            last_header = try data.headers.addOne(gpa);
            last_header.start = @intCast(data.array.items.len);
            last_header.epoch = @intCast(second);
        }
        try data.array.append(gpa, .{
            .nanosecond = @intFromFloat(@round(4 * 1_000_000_000 * (time - @floor(time)))),
            .longitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .latitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .altitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .dBm = try std.fmt.parseFloat(f16, iterator.next().?),
            // Both 0 and -1 Indicate a noise value
            .cluster = @enumFromInt(lma.math.as(u32, @max(0, try std.fmt.parseInt(isize, iterator.next().?, 10)))),
        });
    }
    last_header.size = @intCast(data.array.items.len - last_header.start);
    {
        try saveBin(&data, null, false, bin_dir);
        const csv_data = try gpa.create(Clusters);
        csv_data.* = try data.copy(gpa);
        csv_save.async(io, saveCsv, .{ csv_data, null, true, csv_dir });
    }
    data.headers.items.len = 0;
    data.array.items.len = 0;
    while (@divFloor(60 * 60 * 24, save_frequency) != last_save) : (last_save += 1) {
        saveBin(&data, last_save, false, bin_dir) catch break;
        const csv_data = try gpa.create(Clusters);
        csv_data.* = try data.copy(gpa);
        csv_save.async(io, saveCsv, .{ csv_data, last_save, true, csv_dir });
    }
}

pub fn saveCsv(data: *Clusters, save_time: ?usize, free_data: bool, dir: std.fs.Dir) void {
    const time = utils.saveTime(
        save_time,
        if (data.headers.items.len == 0) null else data.headers.items[0].epoch,
        save_frequency,
    );

    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;

    const name = utils.fileName(&name_buffer, time, "csv");
    const file = dir.createFile(name, .{}) catch {
        std.log.err("Failed to create file {s}\n", .{name});
        return;
    };
    defer file.close();
    var file_writer = file.writer(&buffer);

    data.toCsv(&file_writer.interface, null) catch {
        std.log.err("Failed to write file {s}\n", .{name});
        return;
    };
    if (free_data) {
        const gpa = data.allocator;
        data.deinit();
        gpa.destroy(data);
    }
}

fn saveBin(data: *Clusters, save_time: ?usize, free_data: bool, dir: std.fs.Dir) !void {
    const time = utils.saveTime(
        save_time,
        if (data.headers.items.len == 0) null else data.headers.items[0].epoch,
        save_frequency,
    );

    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;

    const name = utils.fileName(&name_buffer, time, "bin");
    const file = dir.createFile(name, .{}) catch {
        std.log.err("Failed to create file {s}\n", .{name});
        return;
    };
    defer file.close();
    var file_writer = file.writer(&buffer);

    data.toBin(&file_writer.interface) catch {
        std.log.err("Failed to write file {s}\n", .{name});
        return;
    };
    if (free_data) {
        const gpa = data.allocator;
        data.deinit();
        gpa.destroy(data);
    }
}
