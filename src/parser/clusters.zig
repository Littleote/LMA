const std = @import("std");
const Data = @import("lma").data.Clusters;

const utils = @import("utils.zig");
const save_frequency = 10 * 60;

pub const Args = struct {
    delimiter: enum(u8) {
        comma = ',',
        semicolon = ';',
        dot = '.',
        colon = ':',
        space = ' ',
        tab = '\t',
        dash = '-',
    } = .space,

    pub const shorthands = .{
        .d = "delimiter",
    };
};

pub fn parse(gpa: std.mem.Allocator, path: []const u8, args: *const Args) !void {
    const delimiter = @intFromEnum(args.delimiter);

    // Input file
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&buffer);

    // Open directories
    const dir_path = std.fs.path.dirname(path) orelse "../";
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    // Output CSV directory
    var csv_dir = try utils.forceOpen(dir, "csv", .{});
    defer csv_dir.close();

    // Output BIN directory
    var bin_dir = try utils.forceOpen(dir, "bin", .{});
    defer bin_dir.close();

    var data: Data = .init(gpa);
    defer data.deinit();
    var last_header = try data.header.addOne(gpa);
    var last_second: usize = 0;
    var last_save: usize = @divFloor(last_second, save_frequency);
    last_header.start = @intCast(data.value.items.len);
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

    defer {
        last_header.size = @intCast(data.value.items.len - last_header.start);
        saveData(&data, bin_dir, csv_dir, null) catch {};
        data.header.items.len = 0;
        data.value.items.len = 0;
        while (@divFloor(60 * 60 * 24, save_frequency) != last_save) : (last_save += 1) {
            saveData(&data, bin_dir, csv_dir, last_save) catch break;
        }
    }
    while (try file_reader.interface.takeDelimiter('\n')) |line| {
        var iterator = std.mem.tokenizeScalar(u8, line, delimiter);
        const time = try std.fmt.parseFloat(f64, iterator.next().?);
        const second: usize = @intFromFloat(@floor(time));

        if (second != last_second) {
            @branchHint(.unlikely);
            last_second = second;
            last_header.size = @intCast(data.value.items.len - last_header.start);
            if (@divFloor(second, save_frequency) != last_save) {
                @branchHint(.unlikely);
                last_save += 1;
                try saveData(&data, bin_dir, csv_dir, null);
                data.header.items.len = 0;
                data.value.items.len = 0;
                while (@divFloor(second, save_frequency) != last_save) : (last_save += 1) {
                    try saveData(&data, bin_dir, csv_dir, last_save);
                }
            }
            last_header = try data.header.addOne(gpa);
            last_header.start = @intCast(data.value.items.len);
            last_header.epoch = @intCast(second);
        }
        try data.value.append(gpa, .{
            .nanosecond = time - @floor(time),
            .longitude = try std.fmt.parseFloat(f64, iterator.next().?),
            .latitude = try std.fmt.parseFloat(f64, iterator.next().?),
            .altitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .dBW = try std.fmt.parseFloat(f16, iterator.next().?),
            // Both 0 and -1 Indicate a noise value
            .cluster = .{ .value = @intCast(@max(0, try std.fmt.parseInt(isize, iterator.next().?, 10))) },
        });
    }
}

fn saveData(data: *const Data, bin_dir: std.fs.Dir, csv_dir: std.fs.Dir, save: ?usize) !void {
    const time = utils.saveTime(save, data.header.items[0].epoch, save_frequency);
    var buffer: [1024]u8 = undefined;
    var name_buffer: [32]u8 = undefined;

    {
        const name = utils.fileName(&name_buffer, time, "bin");
        const file = try bin_dir.createFile(name, .{});
        defer file.close();
        var file_writer = file.writer(&buffer);
        try data.toBin(&file_writer.interface);
    }

    {
        const name = utils.fileName(&name_buffer, time, "csv");
        const file = try csv_dir.createFile(name, .{});
        defer file.close();
        var file_writer = file.writer(&buffer);
        try data.toCsv(&file_writer.interface);
    }
}
