const std = @import("std");

const lma = @import("lma");
const data = lma.data;
const Point = data.Point;
const nargs = @import("nargs");
const opt = nargs.options;

const utils = @import("utils.zig");

pub const Cli = struct {
    const Output = struct {
        path: []const u8,
        skip: bool,
    };

    input: nargs.params.io.Glob.Pattern,
    csv: Output,
    bin: Output,
};

pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "points" }, .{
    .input = .build(opt.Named, .single(.wrap(nargs.params.io.Glob), .{ .name = "input", .description = "Input '.dat' files.", .short = .auto })),
    .csv = .build(opt.Groups, .any(.{ .name = "CSV", .show = .hidden }, .{
        .path = .build(opt.Named, .single(.string, .{
            .name = "csv",
            .description = "Output folder for the '.csv' files (relative to the given directory).",
            .default = .init("csv", null),
        })),
        .skip = opt.flags.Flag(.{ .name = "skip-csv", .description = "Skip generating '.csv' files.", .set = .no_prefix }),
    })),
    .bin = .build(opt.Groups, .any(.{ .name = "BIN", .show = .hidden }, .{
        .path = .build(opt.Named, .single(.string, .{
            .name = "bin",
            .description = "Output folder for the '.bin' files (relative to the given directory).",
            .default = .init("bin", null),
        })),
        .skip = opt.flags.Flag(.{ .name = "skip-bin", .description = "Skip generating '.bin' files.", .set = .no_prefix }),
    })),
}));

pub fn parse(io: std.Io, cwd: std.Io.Dir, gpa: std.mem.Allocator, args: Cli) !void {
    var rw_buffer: [1024]u8 = undefined;

    var file_name: std.Io.Writer.Allocating = .init(gpa);
    defer file_name.deinit();

    // Input directory
    var inputs = try args.input.iterator(io, cwd);
    defer inputs.deinit();

    // Output CSV directory
    const csv_dir: ?std.Io.Dir = if (args.csv.skip) null else try cwd.createDirPathOpen(io, args.csv.path, .{});
    defer if (csv_dir) |csv| csv.close(io);

    // Output BIN directory
    const bin_dir: ?std.Io.Dir = if (args.bin.skip) null else try cwd.createDirPathOpen(io, args.bin.path, .{});
    defer if (bin_dir) |bin| bin.close(io);

    // Iterate for all test source files
    while (try inputs.next()) |entry| {
        var points: Point.List = .init(gpa);
        defer points.deinit();

        // Parse source file
        const stem = blk: {
            const extension = std.fs.path.extension(entry.basename);
            const file = try entry.dir.openFile(io, entry.basename, .{ .mode = .read_only });
            defer file.close(io);
            var file_reader = file.reader(io, &rw_buffer);
            const result = if (std.ascii.eqlIgnoreCase(extension, ".dat"))
                readDat(&points, entry.basename, &file_reader.interface)
            else if (std.ascii.eqlIgnoreCase(extension, ".gz"))
                readGZip(&points, entry.basename, &file_reader.interface)
            else {
                std.log.warn("Unrecognized file type {q}", .{entry.basename});
                continue;
            };
            break :blk result catch |e| {
                switch (e) {
                    error.Logged => {},
                    error.ReadFailed => std.log.warn("Failed to read flash sources file {q}. ({})", .{ entry.basename, file_reader.err orelse error.Unknown }),
                }
                continue;
            };
        };

        // Save as CSV
        if (csv_dir) |out_dir| {
            file_name.clearRetainingCapacity();
            try file_name.writer.print("{s}.csv", .{stem});
            const csv = try out_dir.createFile(io, file_name.written(), .{});
            defer csv.close(io);
            var file_writer = csv.writer(io, &rw_buffer);
            try Point.csv.write(&points, &file_writer.interface, null);
        }

        // Save as BIN
        if (bin_dir) |out_dir| {
            file_name.clearRetainingCapacity();
            try file_name.writer.print("{s}.bin", .{stem});
            const bin = try out_dir.createFile(io, file_name.written(), .{});
            defer bin.close(io);
            var file_writer = bin.writer(io, &rw_buffer);
            try Point.bin.write(&points, &file_writer.interface);
        }
    }
}

fn readGZip(list: *Point.List, name: []const u8, reader: *std.Io.Reader) error{ Logged, ReadFailed }![]const u8 {
    var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const stem = std.fs.path.stem(name);
    const extension = std.fs.path.extension(stem);
    var flate: std.compress.flate.Decompress = .init(reader, .gzip, &gzip_buffer);

    if (std.ascii.eqlIgnoreCase(extension, ".dat")) {
        return readDat(list, stem, &flate.reader) catch |e| switch (e) {
            error.Logged => |err| return err,
            error.ReadFailed => {
                switch (flate.err orelse error.ReadFailed) {
                    error.ReadFailed => |err| return err,
                    else => |err| {
                        std.log.warn("Failed to read flash sources file {q}. ({})", .{ name, err });
                        return error.Logged;
                    },
                }
            },
        };
    } else {
        std.log.warn("Unrecognized file type {q}", .{stem});
        return error.Logged;
    }
}

fn readDat(list: *Point.List, name: []const u8, reader: *std.Io.Reader) error{ Logged, ReadFailed }![]const u8 {
    Point.dat.read(list, reader) catch |e| switch (e) {
        error.ReadFailed => |err| return err,
        else => |err| {
            std.log.err("Failed to parse flash sources file {q}. ({})", .{ name, err });
            return error.Logged;
        },
    };

    return std.fs.path.stem(name);
}
