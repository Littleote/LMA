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
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    // Open directories
    const dir_path = std.fs.path.dirname(path) orelse "../";
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    // Output CSV directory
    SaveInfo.csv_dir = try utils.forceOpen(dir, "csv", .{});
    defer SaveInfo.csv_dir.?.close();

    // Output BIN directory
    SaveInfo.bin_dir = try utils.forceOpen(dir, "bin", .{});
    defer SaveInfo.bin_dir.?.close();

    var data: Clusters = .init(gpa);
    var last_header = try data.headers.addOne(gpa);
    var last_second: usize = 0;
    var last_save: usize = @divFloor(last_second, save_frequency);
    last_header.start = @intCast(data.array.items.len);
    last_header.epoch = @intCast(last_second);
    var group: std.Io.Group = .init;

    // Async saving
    defer group.wait(io);
    var save_buffer: [16]SaveInfo = undefined;
    var queue: std.Io.Queue(SaveInfo) = .init(&save_buffer);

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
                queue.putOneUncancelable(io, .{ .data = data, .save_time = null });
                group.async(io, saveFiles, .{ &io, &queue });
                const size = .{ .headers = data.headers.items.len, .array = data.array.items.len };
                data = .init(gpa);
                try data.headers.ensureTotalCapacity(gpa, size.headers);
                try data.array.ensureTotalCapacity(gpa, size.array);

                while (@divFloor(second, save_frequency) != last_save) : (last_save += 1) {
                    queue.putOneUncancelable(io, .{ .data = .init(gpa), .save_time = last_save });
                    group.async(io, saveFiles, .{ &io, &queue });
                }
            }
            last_header = try data.headers.addOne(gpa);
            last_header.start = @intCast(data.array.items.len);
            last_header.epoch = @intCast(second);
        }
        try data.array.append(gpa, .{
            .nanosecond = @intFromFloat(@round(4 * 1_000_000_000 * (time.fpart))),
            .longitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .latitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .altitude = try std.fmt.parseFloat(f32, iterator.next().?),
            .dBm = try std.fmt.parseFloat(f16, iterator.next().?),
            // Both 0 and -1 Indicate a noise value
            .cluster = @enumFromInt(lma.math.as(u32, @max(0, try std.fmt.parseInt(isize, iterator.next().?, 10)))),
        });
    }
    last_header.size = @intCast(data.array.items.len - last_header.start);
    queue.putOneUncancelable(io, .{ .data = data, .save_time = null });
    group.async(io, saveFiles, .{ &io, &queue });
    data.headers.items.len = 0;
    data.array.items.len = 0;
    while (@divFloor(60 * 60 * 24, save_frequency) != last_save) : (last_save += 1) {
        queue.putOneUncancelable(io, .{ .data = .init(gpa), .save_time = last_save });
        group.async(io, saveFiles, .{ &io, &queue });
    }
}

const SaveInfo = struct {
    data: Clusters,
    save_time: ?usize,

    var csv_dir: ?std.fs.Dir = null;
    var bin_dir: ?std.fs.Dir = null;
};

fn saveFiles(io: *const std.Io, queue: *std.Io.Queue(SaveInfo)) void {
    var info = queue.getOneUncancelable(io.*);
    if (SaveInfo.bin_dir) |dir|
        saveBin(&info.data, info.save_time, dir);
    if (SaveInfo.csv_dir) |dir|
        saveCsv(&info.data, info.save_time, dir);
    info.data.deinit();
}

fn saveCsv(data: *const Clusters, save_time: ?usize, dir: std.fs.Dir) void {
    const time = utils.saveTime(
        save_time,
        if (data.headers.items.len == 0) null else data.headers.items[0].epoch,
        save_frequency,
    );

    var buffer: [4096]u8 = undefined;
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
}

fn saveBin(data: *const Clusters, save_time: ?usize, dir: std.fs.Dir) void {
    const time = utils.saveTime(
        save_time,
        if (data.headers.items.len == 0) null else data.headers.items[0].epoch,
        save_frequency,
    );

    var buffer: [4096]u8 = undefined;
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
}
