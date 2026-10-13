const std = @import("std");

const lma = @import("lma");
const Signal = lma.data.Signal;
const nargs = @import("nargs");
const opt = nargs.options;

const utils = @import("utils.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .level = .debug, .scope = lma.log.scopes.signal_file },
    },
};

pub const Cli = struct {
    const Output = struct {
        path: []const u8,
        skip: bool,
    };

    path: []const u8,
    csv: Output,
    bin: Output,
};

pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "signals" }, .{
    .path = .build(opt.Named, .single(.string, .{ .name = "input", .description = "Input folder with the '.dat' files.", .short = .auto })),
    .csv = .build(opt.Groups, .any(.{ .name = "CSV", .show = .hidden }, .{
        .path = .build(opt.Named, .single(.string, .{
            .name = "csv",
            .description = "Output folder for the '.csv' files (relative to input directory).",
            .default = .init("../csv", null),
        })),
        .skip = opt.flags.Flag(.{ .name = "skip-csv", .description = "Skip generating '.csv' files.", .set = .no_prefix }),
    })),
    .bin = .build(opt.Groups, .any(.{ .name = "BIN", .show = .hidden }, .{
        .path = .build(opt.Named, .single(.string, .{
            .name = "bin",
            .description = "Output folder for the '.bin' files (relative to input directory).",
            .default = .init("../bin", null),
        })),
        .skip = opt.flags.Flag(.{ .name = "skip-bin", .description = "Skip generating '.bin' files.", .set = .no_prefix }),
    })),
}));

pub fn parse(io: std.Io, gpa: std.mem.Allocator, args: Cli) !void {
    // Input directory
    const dat_dir = try std.Io.Dir.cwd().openDir(io, args.path, .{ .iterate = true });
    defer dat_dir.close(io);

    // Output CSV directory
    const csv_dir: ?std.Io.Dir = if (args.csv.skip) null else try dat_dir.createDirPathOpen(io, args.csv.path, .{});
    defer if (csv_dir) |dir| dir.close(io);

    // Output BIN directory
    const bin_dir: ?std.Io.Dir = if (args.bin.skip) null else try dat_dir.createDirPathOpen(io, args.bin.path, .{});
    defer if (bin_dir) |dir| dir.close(io);

    // Iterate for all test source files
    var iterator = dat_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".dat")) {
            std.log.err("Unrecognized file type {q}", .{entry.name});
            continue;
        }

        var buffer: [1024]u8 = undefined;
        var data: Signal.List = .init(gpa);
        defer data.deinit();
        {
            // Parse source file
            const file = try dat_dir.openFile(
                io,
                entry.name,
                .{ .mode = .read_only },
            );
            defer file.close(io);
            var file_reader = file.reader(io, &buffer);
            try lma.data.dat_file.SignalParser.fromReader(&file_reader.interface, &data, .{});
        }

        if (csv_dir) |dir| {
            // Save as CSV
            const name = try gpa.dupe(u8, entry.name);
            defer gpa.free(name);
            @memcpy(name[name.len - 3 ..], "csv");
            const csv = try dir.createFile(io, name, .{});
            defer csv.close(io);
            var file_writer = csv.writer(io, &buffer);

            try Signal.csv.write(&data, &file_writer.interface, null);
        }

        if (bin_dir) |dir| {
            // Save as BIN
            const name = try gpa.dupe(u8, entry.name);
            defer gpa.free(name);
            @memcpy(name[name.len - 3 ..], "bin");
            const bin = try dir.createFile(io, name, .{});
            defer bin.close(io);
            var file_writer = bin.writer(io, &buffer);
            try Signal.bin.write(&data, &file_writer.interface);
        }
    }
}
