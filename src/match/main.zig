const std = @import("std");

const builtin = @import("builtin");

const lma = @import("lma");
const match = lma.pipeline.match;
const ToaSolver = lma.pipeline.ToaSolver;
const nargs = @import("nargs");
const files = @import("files.zig");
const runner = @import("runner.zig");
const parse_time = @import("parse_time.zig");

const root: nargs.Node = .wrap(nargs.groups.Any(.{ .name = "match", .show = .compact }, &.{
    .set("threads", .wrap(nargs.args.param.Single(.integer(usize, .{ .min = 1, .max_str = "unlimited" }), .{
        .name = "threads",
        .description = "Number of threads to use for execution.",
        .display = "COUNT",
        .default = .{ .inner = .{ .values = @intFromEnum(std.Io.Limit.unlimited) }, .description = "auto" },
        .short = .auto,
    }))),
    .set("time", .wrap(nargs.groups.Any(.{ .name = "DATE" }, &.{
        .set("date", .wrap(nargs.args.param.Single(.wrap(parse_time.Date), .{
            .name = "date",
            .description = "Date specified as either YYYYMMDD or YYMMDD. Accepts '/' as date separators.",
            .display = "DATE",
            .short = .auto,
        }))),
        .set("time", .wrap(nargs.args.param.Single(.wrap(parse_time.Time), .{
            .name = "time",
            .description = "Time specified as HHMMSS. Accepts ':' as time separators.",
            .display = "TIME",
            .short = .set('h'),
        }))),
        .set("seconds", .wrap(nargs.args.param.Single(.wrap(parse_time.Seconds), .{
            .name = "analyse",
            .description = "Total time to analyse as either SECONDS or HH:MM:SS.",
            .display = "SECONDS",
        }))),
    }))),
    .set("files", .wrap(nargs.groups.Any(.{ .name = "FILES", .show = .compact }, &.{
        .set("stations", .wrap(nargs.args.param.Variable(.string, .{ .min = 1 }, .{
            .name = "stations",
            .description = "File with station data. Accepts \".csv\", \".gps\" and \".loc\".",
            .display = "FILE",
            .short = .auto,
        }))),
        .set("inputs", .wrap(nargs.args.param.Variable(.wrap(nargs.types.io.Glob), .{ .min = 1 }, .{
            .name = "input",
            .description = "Glob pattern for all signal input files. Accepts \".csv\", \".dat\" and \".bin\" (with or without \".gz\").",
            .display = "GLOB",
            .short = .auto,
        }))),
        .set("excluded", .wrap(nargs.args.param.Variable(.string, .{}, .{
            .name = "exclude",
            .description = "Input signal files to exclude by name. Exclusion has higher precedence than inclusion. Only the file name is necessary (with its extension).",
            .display = "FILE",
            .default = .fromStrings(&.{}, "none"),
        }))),
        .set("outputs", .wrap(nargs.args.param.Variable(.string, .{ .max = 5 }, .{
            .name = "output",
            .description = "Destination file to store the results. Defaults to \"CUSTOM_{YYMMDD}_{HHMMSS}_{SECONDS}.dat.gz\". Accepts \".csv\", \".dat\" and \".bin\" (with or without \".gz\").",
            .display = "FILE",
            .short = .auto,
            .default = .fromStrings(&.{}, "CUSTOM_{YYMMDD}_{HHMMSS}_{SSSS}.dat.gz"),
        }))),
        .set("out_dir", .wrap(nargs.args.param.Single(.optional(.string), .{
            .name = "output-path",
            .description = "Destination path were to create the generated files.",
            .display = "PATH",
            .default = .{ .inner = .{ .values = null }, .description = "current working directory" },
        }))),
        .set("probe", .wrap(nargs.args.param.Single(.optional(.string), .{ .name = "probe", .description = "Points to probe the method. Accepts \".dat\".", .display = "FILE" }))),
    }))),
    .set("config", runner.config_parser),
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

    const ctx = .{ .allocator = gpa, .io = io };
    const Options = root.Parsed(null);
    var options: Options = undefined;
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const args = init.args.toSlice(arena.allocator()) catch @panic("OOM while parsing CLI args.");

        var tokenizer: nargs.Tokenizer = .initFromStatic(args[1..]);
        var diag: nargs.Diagnostic = .init(gpa, .{});
        defer {
            for (diag.error_list.items) |info| {
                std.log.err("{s}: {s}", .{ @tagName(info.err), info.message });
            }
            diag.deinit();
        }

        var mem = root.initMemory().*;
        var help = false;
        while (tokenizer.peek()) |token| {
            if (root.parse(&tokenizer, &mem, &diag) == .no_match) {
                tokenizer.discardAssumeToken();
                switch (token) {
                    .short => |short| if (short.name == 'h') {
                        help = true;
                        continue;
                    },
                    .long => |long| if (std.mem.eql(u8, "help", long.name)) {
                        help = true;
                        continue;
                    },
                    else => {},
                }
                diag.log(.unused_argument, "{f}", .{token});
            }
        }

        if (help) {
            var help_buf: [128]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &help_buf);
            stdout.interface.print("{f}\n", .{std.fmt.Alt([]const nargs.Node.Help, nargs.Node.Help.format){ .data = root.help_info }}) catch {};
            stdout.flush() catch {};
            return;
        }

        root.init(Options, &mem, &diag, ctx, &options) catch return;
    }
    defer root.deinit(Options, ctx, &options);

    const config: runner.Config = .{
        .beam_width = options.config.beam_width,
        .dfs_attempts = options.config.dfs_attempts,
        .memory = options.config.memory,
        .probability = options.config.probability,
        .verbose = options.config.verbose,
        .weights = options.config.weights,
        .chunk = options.config.chunk,
    };

    threaded.async_limit = @enumFromInt(options.threads - 1);
    threaded.concurrent_limit = @enumFromInt(options.threads - 1);

    var buffer: [1024]u8 = undefined;

    if (options.files.probe) |probe_file| probe: {
        const file = std.Io.Dir.cwd().openFile(io, probe_file, .{}) catch break :probe;
        defer file.close(io);
        var file_reader = file.reader(io, &buffer);
        probe_data = .init(gpa);
        probe_data.?.fromDat(&file_reader.interface) catch {
            probe_data.?.deinit();
            probe_data = null;
            std.log.err("TODO", .{});
            break :probe;
        };
    }
    defer if (probe_data) |*data| data.deinit();

    // Load stations
    var stations: lma.data.Stations = .init(gpa);
    defer stations.deinit();
    for (options.files.stations) |network| {
        const file = std.Io.Dir.cwd().openFile(io, network, .{}) catch {
            std.log.err("TODO", .{});
            continue;
        };
        defer file.close(io);
        var file_reader = file.reader(io, &buffer);
        files.loadStations(&stations, network, &file_reader.interface) catch |err| switch (err) {
            error.Logged => continue,
            error.ReadFailed => {
                std.log.err("TODO", .{});
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

    for (options.files.inputs) |*const_glob| {
        const glob: *nargs.types.io.GlobWalker = @constCast(const_glob);
        while (glob.next() catch |err| switch (err) {
            error.Canceled => unreachable,
            else => |new_err| blk: {
                std.log.err("TODO {}", .{new_err});
                break :blk null;
            },
        }) |entry| {
            for (options.files.excluded) |exclude| {
                const name = std.fs.path.basename(exclude);
                if (std.mem.eql(u8, entry.basename, name)) continue;
            }

            loadStation(io, entry.dir, entry.path, options.time.date.string[2..8].*, options.time.time.string, stations, full_signals) catch |err| {
                switch (err) {
                    error.BadName => std.log.err(
                        \\File "{s}" doesn't conform to naming convention "{{CODE}}_{{NETWORK}}_{{STATION_NAME}}_{{YYMMDD}}_{{HHMMSS}}". (With YYMMDD = {s} and HHMMSS = {s})
                    , .{ entry.basename, options.time.date.string[2..8].*, options.time.time.string }),
                    error.UnknownStation => std.log.err(
                        \\No station associated to "{s}".
                    , .{entry.basename}),
                    error.Reported => {},
                }
                continue;
            };
            active_stations += 1;
        }
    }

    var out_dir: std.Io.Dir = if (options.files.out_dir) |dir| std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| switch (err) {
        error.Canceled => unreachable,
        else => |new_err| blk: {
            std.log.err("TODO {} defaulting to cwd.", .{new_err});
            break :blk .cwd();
        },
    } else .cwd();

    const start_time = options.time.time.toSeconds();

    const result = runner.run(io, gpa, points, full_signals, config, .init(start_time, options.time.seconds)) catch |err| switch (err) {
        error.Canceled => unreachable,
        error.OutOfMemory => @panic("OOM"),
    };
    var output = result.points;
    defer output.deinit();
    _ = result.stats;

    var default_file_buffer = "CUSTOM_YYMMDD_HHMMSS_SSSS.dat.gz"[0..].*;

    const out_files: []const []const u8 = if (options.files.outputs.len == 0) &.{
        std.fmt.bufPrint(&default_file_buffer, "CUSTOM_{s}_{s}_{d:0>4}.dat.gz", .{ options.time.date.string[2..8].*, options.time.time.string, options.time.seconds }) catch unreachable,
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

    if (config.verbose) {
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

// TODO
pub fn loadStation(io: std.Io, dir: std.Io.Dir, file: []const u8, date: [6]u8, time: [6]u8, stations: lma.data.Stations, signals: []lma.data.Signal) error{ Reported, BadName, UnknownStation }!void {
    const basename = std.fs.path.basename(file);
    var buffer: [1024]u8 = undefined;

    // CODE_GROUP_FULL_NAME_DATE_TIME.dat
    const stem, _ = std.mem.cutScalarLast(u8, basename, '.').?;
    var split = std.mem.splitScalar(u8, stem, '_');
    _, _ = .{ split.next().?, split.next().? };

    var back_split = std.mem.splitBackwardsScalar(u8, split.rest(), '_');
    const file_time, const file_date, const name = .{ back_split.next().?, back_split.next().?, back_split.rest() };

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
            std.debug.assert(signals[idx].empty());
            const delay: u32 = lma.index.offset(u32, global_shift, info.delay);
            files.loadSignals(&signals[idx], basename, &file_reader.interface) catch |err| {
                std.log.err(
                    \\Unable to load file "{s}" due to error {}.
                , .{ basename, err });
                return error.Reported;
            };
            for (signals[idx].array.items) |*signal| {
                signal.nanosecond += delay;
            }
            break;
        }
    } else return error.UnknownStation;
}
