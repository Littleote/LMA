const std = @import("std");
const builtin = @import("builtin");

const lma = @import("lma");
const network = lma.constants.network;
const match = lma.pipeline.match;
const ToaSolver = lma.pipeline.ToaSolver;
const Signal = lma.data.Signal;

const files = @import("files.zig");
const runner = @import("runner.zig");
const cli = @import("cli.zig");

const match_info = @import("info.zon");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .level = .warn, .scope = lma.log.scopes.signal_file },
        .{ .level = .err, .scope = lma.log.scopes.station_file },
    },
};

pub const Float = match.Float;
pub const Precise = ToaSolver.Float;
pub const math = lma.math(Precise);

pub const max_distance = 200_000.0;
pub const global_shift: u32 = 50_000_000;
pub const max_matches: usize = @ceil(1 + max_distance / lma.constants.c / 0.000_080);

pub var probe_data: ?match.probing.List = null;

pub fn correlation_size(dist: Float, step: match.correlation.Step) u32 {
    return 1 + 4 * lma.cast.to(u32, @round(@min(max_distance, dist) / lma.constants.c / step.step));
}

pub fn main(init: std.process.Init.Minimal) void {
    var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const use_safe_allocator = builtin.mode.runtimeSafety() or builtin.single_threaded;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Footer gets zeroed while awaiting
    // Reason still unknown
    const io_gpa = if (use_safe_allocator) std.heap.page_allocator else std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(io_gpa, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = init.environ });
    const io = threaded.io();

    var options = cli.Options.init(gpa, io, init.args) catch
        std.process.exit(1) orelse
        return;
    defer options.deinit(gpa);

    {
        std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
        defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
        threaded.async_limit = @fromBackingInt(options.threads - 1);
        threaded.concurrent_limit = @fromBackingInt(options.threads - 1);
    }

    var rw_buffer: [1024]u8 = undefined;

    // Load probe file
    if (options.files.probe) |probe_file| probe: {
        const file = std.Io.Dir.cwd().openFile(io, probe_file, .{}) catch |err| {
            std.log.warn("Unable to open probe file {q}. ({})", .{ probe_file, err });
            break :probe;
        };
        defer file.close(io);
        var file_reader = file.reader(io, &rw_buffer);
        probe_data = .init(gpa);
        match.probing.dat.read(&probe_data.?, &file_reader.interface) catch |err| {
            probe_data.?.deinit();
            probe_data = null;
            std.log.warn("Failed to parse probe file {q}. ({})", .{ probe_file, err });
            break :probe;
        };
    }
    defer if (probe_data) |*data| data.deinit();

    // Load stations
    var stations: lma.data.Station.List = .init(gpa);
    defer stations.deinit();
    for (options.files.stations) |net| {
        const file = std.Io.Dir.cwd().openFile(io, net, .{}) catch |err| {
            std.log.err("Unable to open station file {q}. ({})", .{ net, err });
            continue;
        };
        defer file.close(io);
        var file_reader = file.reader(io, &rw_buffer);
        files.stations.readAppend(&stations, net, &file_reader.interface) catch |err| switch (err) {
            error.Logged => continue,
            error.ReadFailed => {
                std.log.err("Failed to read station/network file {q}. ({})", .{ net, file_reader.err orelse error.Unknown });
                continue;
            },
        };
    }

    const count: u8 = valid: {
        const count = stations.stations.items.len;
        const max = network.max_network;
        const min = options.config.search.consensus;
        if (max < count) {
            std.log.err(
                "Station limit reached ({d}/{d}).",
                .{ count, max },
            );
        } else if (count < min) {
            std.log.err(
                "Insufficient stations in the network ({d}/{d}). Minimum is {d}.",
                .{ count, max, min },
            );
        } else break :valid @intCast(count);
        std.process.exit(1);
    };

    var delay_buffer: [network.max_network]lma.nano.Nano = undefined;
    const delays: []lma.nano.Nano = delay_buffer[0..count];
    var station_points_buffer: [network.max_network]math.Vec = undefined;
    const station_points: []math.Vec = station_points_buffer[0..count];
    for (stations.stations.items, station_points, delays) |station, *station_point, *delay| {
        delay.* = global_shift - @as(u32, @bitCast(station.delay));
        station_point.* = lma.pipeline.transform.gpsToXYZ(Precise, station.point()).build();
    }

    // Load signals
    var active_stations: usize = 0;
    var signal_list_buffer: [network.max_network]Signal.List = @splat(.init(gpa));
    const signal_lists: []Signal.List = signal_list_buffer[0..count];
    defer for (signal_lists) |*list| list.deinit();

    for (options.files.inputs) |*pattern| {
        var glob = pattern.iterator(io, null) catch |e| switch (e) {
            error.Canceled => unreachable,
            else => |err| {
                std.log.err("Unable to load any signal files matching {q}. ({})", .{ pattern.path, err });
                continue;
            },
        };
        defer glob.deinit();
        while (glob.next() catch |e| switch (e) {
            error.Canceled => unreachable,
            else => |err| blk: {
                std.log.err("Unable to load any more signal files matching {q}. ({})", .{ pattern.path, err });
                break :blk null;
            },
        }) |entry| {
            for (options.files.excluded) |exclude| {
                const name = std.fs.path.basename(exclude);
                if (std.mem.find(u8, entry.basename, name)) |_| {
                    std.log.info("Excluded {q} because it matched {q}.", .{ entry.basename, exclude });
                    continue;
                }
            }

            const file = entry.dir.openFile(io, entry.basename, .{}) catch |err| {
                std.log.err("Unable to open signal file {q}. ({})", .{ entry.basename, err });
                continue;
            };
            defer file.close(io);
            var file_reader = file.reader(io, &rw_buffer);

            loadStation(
                entry.basename,
                &file_reader.interface,
                stations,
                signal_lists,
                &options,
            ) catch |err| {
                switch (err) {
                    error.BadName => std.log.warn(
                        \\File "{s}" doesn't conform to naming convention "{{CODE}}_{{NETWORK}}_{{STATION_NAME}}_{{YYMMDD}}_{{HHMMSS}}". (With YYMMDD = {s} and HHMMSS = {s})
                    , .{ entry.basename, options.time.date.string[2..8].*, options.time.hour.string }),
                    error.UnknownStation => std.log.warn("No station associated to {q}.", .{entry.basename}),
                    error.DuplicateStation => std.log.warn("Another file for the station associated to {q} has already been loaded.", .{entry.basename}),
                    error.Logged => {},
                    error.ReadFailed => std.log.err("Failed to read signal file {q}. ({})", .{ entry.basename, file_reader.err orelse error.Unknown }),
                }
                continue;
            };
            active_stations += 1;
        }
    }

    if (active_stations < options.config.search.consensus) {
        std.log.err(
            "Insufficient loaded stations in the network ({d}/{d}). Minimum is {d}.",
            .{ active_stations, count, options.config.search.consensus },
        );
        std.process.exit(1);
    }

    const time_date = options.time.date;
    const time_start = options.time.start orelse options.time.hour;
    const second_start = time_start.toSeconds();
    const second_end = switch (options.time.ending) {
        .end => |end| end.toSeconds(),
        .total => |total| second_start + total.seconds,
    };
    const analysed = second_end - second_start;

    var out_dir: std.Io.Dir = if (options.files.out_dir) |dir| std.Io.Dir.cwd().createDirPathOpen(io, dir, .{}) catch |e| switch (e) {
        error.Canceled => unreachable,
        else => |err| blk: {
            std.log.warn("Failed to open {q} ({}), defaulting to cwd.", .{ dir, err });
            break :blk .cwd();
        },
    } else .cwd();

    const default_out_file = arena.allocator().print(
        "{f}_{s}_{s}_{d:0>4}.dat.gz",
        .{
            stations.fmtNetwork("UNNAMED"),
            options.time.date.string[2..8].*,
            (options.time.start orelse options.time.hour).string,
            analysed,
        },
    ) catch @panic("OOM");

    const result = runner.run(io, gpa, station_points, signal_lists, options.config, .init(second_start, analysed)) catch |err| switch (err) {
        error.Canceled => unreachable,
        error.OutOfMemory => @panic("OOM"),
    };
    var output = result.points;
    defer output.deinit();

    if (options.config.smooth != .disabled) switch (options.config.smooth) {
        .disabled => unreachable,
        .default => lma.data.Point.smooth(&output, gpa, .default) catch {
            std.log.warn("Failed to smooth output, not enough memory, skipping this step.", .{});
        },
    };

    for (stations.stations.items, 0..) |*station, i| {
        const correction = lma.nano.toDelta(result.stats.stations[i].calibration());
        station.delay -= correction;
    }

    const out_files: []const []const u8 = if (options.files.outputs.len == 0)
        &.{default_out_file}
    else
        options.files.outputs;

    const out_extra: files.points.Extra = .{ .dat = .{
        .network = &stations,
        .stats = (&result.stats)[0..1],
        .time = .{
            .year = time_date.year,
            .month = time_date.month,
            .day = time_date.day,

            .hour = time_start.hour,
            .minute = time_start.minute,
            .second = time_start.second,

            .analyzed = analysed,
        },
        .version = match_info.name ++ "-" ++ match_info.version,
        .command = init.args.toSlice(arena.allocator()) catch null,
    } };

    for (out_files) |out| {
        const err: anyerror = skip: {
            const file = out_dir.createFile(io, out, .{}) catch |err| break :skip err;
            defer file.close(io);
            var file_writer = file.writer(io, &rw_buffer);
            files.points.write(&output, &file_writer.interface, out, out_extra) catch |err| break :skip err;
            continue;
        };
        std.log.warn("Failed to write to file {q}. ({})", .{ out, err });
    }

    bad_out: {
        var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &rw_buffer);
        defer stdout.flush() catch {};
        stdout.interface.print("Total points: {d}\n", .{output.array.items.len}) catch break :bad_out;
    }

    if (options.files.stations_out) |stations_out| stations: {
        const file = std.Io.Dir.cwd().createFile(io, stations_out, .{}) catch |err| {
            std.log.warn("Unable to generate output station/network file {q}. ({})", .{ stations_out, err });
            break :stations;
        };
        defer file.close(io);
        var file_writer = file.writer(io, &rw_buffer);

        lma.data.Station.csv.write(&stations, &file_writer.interface, null) catch {
            std.log.warn("Failed to write updated station/network data to file {q}. ({})", .{ stations_out, file_writer.err orelse error.Unknown });
            break :stations;
        };
    }
}

// Parse and validate name, match to a loaded station and load its contents
pub fn loadStation(
    file: []const u8,
    reader: *std.Io.Reader,
    stations: lma.data.Station.List,
    signal_lists: []Signal.List,
    opt: *const cli.Options,
) error{ ReadFailed, Logged, BadName, UnknownStation, DuplicateStation }!void {
    const basename = std.fs.path.basename(file);

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
    if (!std.mem.eql(u8, opt.time.date.string[2..], file_date) or
        !std.mem.eql(u8, opt.time.hour.string[0..], file_time)) return error.BadName;

    for (stations.stations.items, 0..) |info, idx| {
        if (std.mem.eql(u8, info.name, name)) {
            if (!signal_lists[idx].empty()) return error.DuplicateStation;
            const delay: u32 = lma.index.offset(u32, global_shift, info.delay);

            try files.signals.read(&signal_lists[idx], basename, reader);

            if (opt.config.decimate) |window| {
                const us_per_nano = @divExact(lma.nano.ratio, std.time.us_per_s);
                Signal.decimate(&signal_lists[idx], us_per_nano * window);
            }
            for (signal_lists[idx].array.items) |*signal| {
                signal.nanosecond += delay;
            }
            break;
        }
    } else return error.UnknownStation;
}
