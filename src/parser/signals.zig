const std = @import("std");

const lma = @import("lma");
const Signal = lma.data.Signal;
const nargs = @import("nargs");
const opt = nargs.options;

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

    input: nargs.params.io.Glob.Pattern,
    csv: Output,
    bin: Output,
};

pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "signals" }, .{
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
        var data: Signal.List = .init(gpa);
        defer data.deinit();

        {
            // Parse source file
            const extension = std.fs.path.extension(entry.basename);
            const file = try entry.dir.openFile(io, entry.basename, .{ .mode = .read_only });
            defer file.close(io);
            var file_reader = file.reader(io, &rw_buffer);
            const result = if (std.ascii.eqlIgnoreCase(extension, ".dat"))
                Signal.dat.read(&data, &file_reader.interface, .{})
            else if (std.ascii.eqlIgnoreCase(extension, ".csv"))
                Signal.csv.read(&data, &file_reader.interface, null)
            else if (std.ascii.eqlIgnoreCase(extension, ".bin"))
                Signal.bin.read(&data, &file_reader.interface)
            else {
                std.log.warn("Unrecognized file type {q}", .{entry.basename});
                continue;
            };

            result catch |e| {
                switch (e) {
                    error.ReadFailed => std.log.warn("Failed to read signal file {q}. ({})", .{ entry.basename, file_reader.err orelse error.Unknown }),
                    else => |err| std.log.err("Failed to parse signal file {q}. ({})", .{ entry.basename, err }),
                }
                continue;
            };
        }

        if (csv_dir) |out_dir| {
            // Save as CSV
            file_name.clearRetainingCapacity();
            try file_name.writer.print("{s}.csv", .{std.fs.path.stem(entry.basename)});
            const csv = try out_dir.createFile(io, file_name.written(), .{});
            defer csv.close(io);
            var file_writer = csv.writer(io, &rw_buffer);

            try Signal.csv.write(&data, &file_writer.interface, null);
        }

        if (bin_dir) |out_dir| {
            // Save as BIN
            file_name.clearRetainingCapacity();
            try file_name.writer.print("{s}.bin", .{std.fs.path.stem(entry.basename)});
            const bin = try out_dir.createFile(io, file_name.written(), .{});
            defer bin.close(io);
            var file_writer = bin.writer(io, &rw_buffer);
            try Signal.bin.write(&data, &file_writer.interface);
        }
    }
}
