const std = @import("std");

const builtin = @import("builtin");

const lma = @import("lma");
const match = lma.pipeline.match;
const ToaSolver = lma.pipeline.ToaSolver;
const nargs = @import("nargs");
const opt = nargs.options;

const files = @import("files.zig");
const runner = @import("runner.zig");
const parse_time = @import("parse_time.zig");

const CliTime = struct {
    date: parse_time.Date.Type,
    hour: parse_time.Time.Type,
    start: ?parse_time.Time.Type,
    ending: union(enum) {
        end: parse_time.Time.Type,
        total: parse_time.Seconds.Type,
    },
};
const CliFiles = struct {
    stations: []const []const u8,
    inputs: []nargs.params.io.Glob.Pattern,
    excluded: []const []const u8,
    outputs: []const []const u8,
    out_dir: ?[]const u8,
    probe: ?[]const u8,
};
const Cli = struct { threads: usize, time: CliTime, files: CliFiles, config: runner.Config };
const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "match" }, .{
    .threads = .build(opt.Named, .single(.integer(.{ .min = 1, .max_str = "unlimited" }), .{
        .name = "threads",
        .description = "Number of threads to use for execution.",
        .display = "COUNT",
        .default = .init(@intFromEnum(std.Io.Limit.unlimited), "auto"),
        .short = .auto,
    })),
    .time = .build(opt.Groups, .any(.{ .name = "DATE" }, .{
        .date = .build(opt.Named, .single(.wrap(parse_time.Date), .{
            .name = "date",
            .description = "Date from input files",
            .display = "DATE",
            .short = .auto,
        })),
        .hour = .build(opt.Named, .single(.wrap(parse_time.Time), .{
            .name = "time",
            .description = "Time from input files.",
            .display = "TIME",
            .short = .set('h'),
        })),
        .start = .optional(.{ .default = "File start time" }, .build(opt.Named, .single(.wrap(parse_time.Time), .{
            .name = "analyse-start",
            .description = "Analysis start time.",
            .display = "TIME",
            .alternatives = &.{.alias("analyze-start")},
        }))),
        .ending = .build(opt.Groups, .exclusive(.{ .name = "DATE", .show = .hidden }, .total, .{
            .end = .build(opt.Named, .single(.wrap(parse_time.Time), .{
                .name = "analyse-end",
                .description = "Analysis end time.",
                .display = "TIME",
                .alternatives = &.{.alias("analyze-end")},
            })),
            .total = .build(opt.Named, .single(.wrap(parse_time.Seconds), .{
                .name = "analyse",
                .description = "Total time to analyse as either SECONDS or HH:MM:SS.",
                .display = "SECONDS",
                .alternatives = &.{.alias("analyze")},
            })),
        })),
    })),
    .files = .build(opt.Groups, .any(.{ .name = "FILES", .show = .usage }, .{
        .stations = .build(opt.Named, .variable(.string, .{ .min = 1 }, .{
            .name = "stations",
            .description = "File with station data. Accepts \".csv\", \".gps\" and \".loc\".",
            .display = "FILE",
            .short = .auto,
        })),
        .inputs = .build(opt.Named, .variable(.wrap(nargs.params.io.Glob), .{ .min = 1 }, .{
            .name = "input",
            .description = "Glob pattern for all signal input files. Accepts \".csv\", \".dat\" and \".bin\" (with or without \".gz\").",
            .display = "GLOB",
            .short = .auto,
        })),
        .excluded = .build(opt.Named, .variable(.string, .{}, .{
            .name = "exclude",
            .description = "Stations to exclude by name. Only the station name is necessary.",
            .display = "NAME",
            .default = .init(&.{}, "none"),
        })),
        .outputs = .build(opt.Named, .variable(.string, .{ .max = 5 }, .{
            .name = "output",
            .description = "Destination file to store the results. Accepts \".csv\", \".dat\" and \".bin\" (with or without \".gz\").",
            .display = "FILE",
            .short = .auto,
            .default = .init(&.{}, "CUSTOM_{YYMMDD}_{HHMMSS}_{SSSS}.dat.gz"),
        })),
        .out_dir = .build(opt.Named, .single(.optional(.string), .{
            .name = "output-path",
            .description = "Destination path were to create the generated files.",
            .display = "PATH",
            .default = .init(null, "current working directory"),
        })),
        .probe = .build(opt.Named, .single(.optional(.string), .{
            .name = "probe",
            .description = "Points to probe the method. Accepts \".dat\".",
            .display = "FILE",
            .default = .init(null, "No probe"),
        })),
    })),
    .config = runner.config_parser,
}));

pub const Float = match.Float;
pub const Precise = ToaSolver.Float;
pub const math = lma.math(Precise);

pub const max_distance = 200_000.0;
pub const global_shift: u32 = 50_000_000;
pub const max_matches: usize = @intFromFloat(1 + @ceil(max_distance / lma.constants.c / 0.000_080));

pub var probe_data: ?match.probing.ProbeData = null;

pub fn correlation_size(dist: Float, step: match.Step) u32 {
    return 1 + 4 * lma.cast.to(u32, @round(@min(max_distance, dist) / lma.constants.c / step.step));
}

pub fn main(init: std.process.Init.Minimal) void {
    const use_debug = builtin.mode == .Debug or builtin.single_threaded;
    var allocator: if (use_debug) std.heap.DebugAllocator(.{}) else void = if (use_debug) .init else {};
    defer if (use_debug) {
        _ = allocator.deinit();
    };
    const gpa: std.mem.Allocator = if (use_debug) allocator.allocator() else std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = init.environ });
    const io = threaded.io();

    var options: Cli = undefined;
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var tokenizer: nargs.Tokenizer = .initFromStatic((init.args.toSlice(arena.allocator()) catch @panic("OOM"))[1..]);
        var diag: nargs.Diagnostic = .init(gpa, .default);
        defer {
            for (diag.error_list.items) |info|
                std.log.err("{f}", .{info});
            diag.deinit();
        }

        var mem = root.initMemory().*;
        while (tokenizer.peek()) |token| {
            if (root.parse(&mem, &tokenizer, &diag) == .no_match) {
                tokenizer.discardAssumeToken();
                diag.log(.unused_token, "", token);
            }
        }

        if (diag.special_flags.get(.help)) {
            var help_buf: [128]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &help_buf);
            nargs.Help.print(.{ .info = root.info }, .{ .name_width = 15, .tree_art = .ascii_arrow, .spacing = true }, &stdout.interface) catch {};
            stdout.flush() catch {};
            return;
        }

        root.init(&mem, &diag, gpa, &options) catch return;
    }
    defer root.deinit(gpa, &options);

    threaded.async_limit = @enumFromInt(options.threads - 1);
    threaded.concurrent_limit = @enumFromInt(options.threads - 1);

    var buffer: [1024]u8 = undefined;

    if (options.files.probe) |probe_file| probe: {
        const file = std.Io.Dir.cwd().openFile(io, probe_file, .{}) catch {
            std.log.warn("Unable to open probe file.", .{});
            break :probe;
        };
        defer file.close(io);
        var file_reader = file.reader(io, &buffer);
        probe_data = .init(gpa);
        probe_data.?.fromDat(&file_reader.interface) catch {
            probe_data.?.deinit();
            probe_data = null;
            std.log.warn("Unable to load probe.", .{});
            break :probe;
        };
    }
    defer if (probe_data) |*data| data.deinit();

    // Load stations
    var stations: lma.data.Stations = .init(gpa);
    defer stations.deinit();
    for (options.files.stations) |network| {
        const file = std.Io.Dir.cwd().openFile(io, network, .{}) catch |err| {
            std.log.err("Unable to open station/network file \"{s}\" with error {s}.", .{ network, @errorName(err) });
            continue;
        };
        defer file.close(io);
        var file_reader = file.reader(io, &buffer);
        files.loadStations(&stations, network, &file_reader.interface) catch |err| switch (err) {
            error.Logged => continue,
            error.ReadFailed => {
                std.log.err("Unable to load station/network file \"{s}\" with error {s}.", .{ network, @errorName(file_reader.err orelse error.Unknown) });
                continue;
            },
        };
    }
    const count: u32 = @intCast(stations.stations.items.len);
    if (count > lma.constants.network.max_network) @panic("Station limit reached.");

    var shift_buffer: [lma.constants.network.max_network]u32 = undefined;
    const shifts: []u32 = shift_buffer[0..count];
    var points_buffer: [lma.constants.network.max_network]math.Vec = undefined;
    const points: []math.Vec = points_buffer[0..count];
    for (stations.stations.items, points, shifts) |station, *point, *delay| {
        delay.* = global_shift - @as(u32, @bitCast(station.delay));
        point.* = lma.pipeline.transform.gpsToXYZ(Precise, station.point()).build();
    }

    // Load signals
    var active_stations: usize = 0;
    var full_signal_buffer: [lma.constants.network.max_network]lma.data.Signal = @splat(.init(gpa));
    const full_signals: []lma.data.Signal = full_signal_buffer[0..count];
    defer for (full_signals) |*signal| signal.deinit();

    for (options.files.inputs) |*pattern| {
        var glob: nargs.params.io.Glob.Iterator = pattern.iterator(io, null) catch |e| switch (e) {
            error.Canceled => unreachable,
            else => |err| {
                std.log.err("Unable to load any files matching \"{s}\" with error {}", .{ pattern.path, err });
                continue;
            },
        };
        defer glob.deinit();
        while (glob.next() catch |e| switch (e) {
            error.Canceled => unreachable,
            else => |err| blk: {
                std.log.err("Unable to load more files matching \"{s}\" with error {}", .{ pattern.path, err });
                break :blk null;
            },
        }) |entry| {
            for (options.files.excluded) |exclude| {
                const name = std.fs.path.basename(exclude);
                if (std.mem.find(u8, entry.basename, name)) |_| {
                    std.log.info(
                        \\Excluded "{s}" because it matched "{s}".
                    , .{ entry.basename, exclude });
                    continue;
                }
            }

            loadStation(io, entry.dir, entry.basename, options.time.date.string[2..8].*, options.time.hour.string, stations, full_signals) catch |err| {
                switch (err) {
                    error.BadName => std.log.warn(
                        \\File "{s}" doesn't conform to naming convention "{{CODE}}_{{NETWORK}}_{{STATION_NAME}}_{{YYMMDD}}_{{HHMMSS}}". (With YYMMDD = {s} and HHMMSS = {s})
                    , .{ entry.basename, options.time.date.string[2..8].*, options.time.hour.string }),
                    error.UnknownStation => std.log.warn(
                        \\No station associated to "{s}".
                    , .{entry.basename}),
                    error.DuplicateStation => std.log.warn(
                        \\Another file for the station associated to "{s}" has already been loaded.
                    , .{entry.basename}),
                    error.Reported => {},
                }
                continue;
            };
            active_stations += 1;
        }
    }

    if (active_stations < lma.constants.network.min_consensus) {
        std.log.err(
            "Too few stations loaded ({d}/{d}). Minimum is {d}.",
            .{ active_stations, count, lma.constants.network.min_consensus },
        );
        return;
    }

    var out_dir: std.Io.Dir = if (options.files.out_dir) |dir| std.Io.Dir.cwd().createDirPathOpen(io, dir, .{}) catch |e| switch (e) {
        error.Canceled => unreachable,
        else => |err| blk: {
            std.log.warn("Failed to open \"{s}\" with error {s} defaulting to cwd.", .{ dir, @errorName(err) });
            break :blk .cwd();
        },
    } else .cwd();

    const start_time = (options.time.start orelse options.time.hour).toSeconds();
    const end_time = switch (options.time.ending) {
        .end => |end| end.toSeconds(),
        .total => |total| start_time + total,
    };
    const analysed = end_time - start_time;

    const result = runner.run(io, gpa, points, full_signals, options.config, .init(start_time, analysed)) catch |err| switch (err) {
        error.Canceled => unreachable,
        error.OutOfMemory => @panic("OOM"),
    };
    var output = result.points;
    defer output.deinit();
    _ = result.stats;

    var default_file_buffer = "CUSTOM_YYMMDD_HHMMSS_SSSS.dat.gz"[0..].*;

    const out_files: []const []const u8 = if (options.files.outputs.len == 0) &.{
        std.fmt.bufPrint(
            &default_file_buffer,
            "CUSTOM_{s}_{s}_{d:0>4}.dat.gz",
            .{ options.time.date.string[2..8].*, (options.time.start orelse options.time.hour).string, analysed },
        ) catch unreachable,
    } else options.files.outputs;
    for (out_files) |out| {
        const err: anyerror = skip: {
            const file = out_dir.createFile(io, out, .{}) catch |err| break :skip err;
            defer file.close(io);
            var file_writer = file.writer(io, &buffer);
            files.savePoints(&output, &stations, (&result.stats)[0..1], out, &file_writer.interface) catch |err| break :skip err;
            continue;
        };
        std.log.warn(
            \\Failed to write to file "{s}" with {}
        , .{ out, err });
    }

    std.debug.print("Total points: {d}\n", .{output.array.items.len});

    if (options.config.verbose) {
        for (stations.stations.items, 0..) |*station, i| {
            const correction = lma.nano.toFixed(i32, result.stats.stations[i].calibration());
            station.delay -= correction;
        }
        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();

        stations.toCsv(&writer.writer, null) catch {};
        std.debug.print("Updated stations:\n{s}", .{writer.written()});
    }
}

// Parse and validate name, match to a loaded station and load its contents
pub fn loadStation(
    io: std.Io,
    dir: std.Io.Dir,
    file: []const u8,
    date: [6]u8,
    time: [6]u8,
    stations: lma.data.Stations,
    signals: []lma.data.Signal,
) error{ Reported, BadName, UnknownStation, DuplicateStation }!void {
    const cancel = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(cancel);

    const basename = std.fs.path.basename(file);
    var buffer: [1024]u8 = undefined;

    // CODE_GROUP_FULL_NAME_DATE_TIME.ext.ens.ion
    const stem, _ = std.mem.cutScalar(u8, basename, '.') orelse .{ basename, "" };
    var split = std.mem.splitScalar(u8, stem, '_');
    _, _ = .{
        split.next() orelse return error.BadName,
        split.next() orelse return error.BadName,
    };

    var back_split = std.mem.splitBackwardsScalar(u8, split.rest(), '_');
    const file_time, const file_date, const name = .{
        back_split.next() orelse return error.BadName,
        back_split.next() orelse return error.BadName,
        back_split.rest(),
    };

    if (file_date.len != 6 or file_time.len != 6) return error.BadName;
    if (!std.mem.eql(u8, &date, file_date) or !std.mem.eql(u8, &time, file_time)) return error.BadName;

    const handle = dir.openFile(io, file, .{}) catch |err| {
        std.log.err(
            \\Unable to open file "{s}" due to error {}.
        , .{ basename, err });
        return error.Reported;
    };
    defer handle.close(io);
    var file_reader = handle.reader(io, &buffer);

    for (stations.stations.items, 0..) |info, idx| {
        if (std.mem.eql(u8, info.name, name)) {
            if (!signals[idx].empty()) return error.DuplicateStation;
            const delay: u32 = lma.index.offset(u32, global_shift, info.delay);
            files.loadSignals(&signals[idx], basename, &file_reader.interface) catch |err| {
                switch (err) {
                    error.Logged => {},
                    error.ReadFailed => {
                        std.log.err(
                            \\Unable to load file "{s}" due to error {s}.
                        , .{ basename, @errorName(file_reader.err orelse error.Unknown) });
                    },
                }
                return error.Reported;
            };
            for (signals[idx].array.items) |*signal| {
                signal.nanosecond += delay;
            }
            break;
        }
    } else return error.UnknownStation;
}
