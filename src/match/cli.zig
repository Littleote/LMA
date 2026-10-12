const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("lma");
const nargs = @import("nargs");
const opt = nargs.options;
const Error = nargs.components.ValueError;
const Value = nargs.Value;

pub const command: nargs.Node(Options) = .build(opt.Groups, .any(.{ .name = "match" }, .{
    .threads = .build(opt.Named, .single(.integer(.{ .min = 1, .max_str = "unlimited" }), .{
        .name = "threads",
        .description = "Number of threads to use for execution.",
        .display = "COUNT",
        .default = .init(@intFromEnum(std.Io.Limit.unlimited), "auto"),
        .short = .auto,
    })),
    .time = .build(opt.Groups, .any(.{ .name = "DATE" }, .{
        .date = .build(opt.Named, .single(time.Date.parser, .{
            .name = "date",
            .description = "Date from input files",
            .display = "DATE",
            .short = .auto,
        })),
        .hour = .build(opt.Named, .single(time.Time.parser, .{
            .name = "time",
            .description = "Time from input files.",
            .display = "TIME",
            .short = .set('h'),
        })),
        .start = .optional(.{ .default = "File start time" }, .build(opt.Named, .single(time.Time.parser, .{
            .name = "analyse-start",
            .description = "Analysis start time.",
            .display = "TIME",
            .alternatives = &.{.alias("analyze-start")},
        }))),
        .ending = .build(opt.Groups, .exclusive(.{ .name = "DATE", .show = .hidden }, .total, .{
            .end = .build(opt.Named, .single(time.Time.parser, .{
                .name = "analyse-end",
                .description = "Analysis end time.",
                .display = "TIME",
                .alternatives = &.{.alias("analyze-end")},
            })),
            .total = .build(opt.Named, .single(time.Seconds.parser, .{
                .name = "analyse",
                .description = "Total time to analyse.",
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
    .config = .build(opt.Groups, .any(.{ .name = "CONFIG", .show = .{ .description = "LMA solver configuration" } }, .{
        .correlation = .build(opt.Groups, .any(.{ .name = "CORRELATION", .show = .hidden }, .{
            .weights = .build(opt.Named, .single(.choice, .{
                .name = "correlation-weight",
                .description = "Value to use to compute the correlation input weights",
                .display = "WEIGHT",
            })),
            .window = .build(opt.Named, .single(.floating(.{ .min = .closed(0.001), .max = .closed(1) }), .{
                .name = "correlation-window",
                .description = "Refresh rate of the correlation window, with the size being double this value.",
            })),
        })),
        .search = .build(opt.Groups, .any(.{ .name = "SEARCH", .show = .hidden }, .{
            .beam_width = .build(opt.Named, .single(.integer(.{ .max = 50 }), .{
                .name = "beam-width",
                .description = "Beam search width: Maximum number of solutions tested with this method.",
            })),
            .dfs_attempts = .build(opt.Named, .single(.integer(.{ .max = 50 }), .{
                .name = "depth-tries",
                .description = "Depth first search attempts: Number of tries to find promising combinations at each depth.",
            })),
            .memory = .build(opt.Named, .single(.integer(.{ .max = 20 }), .{
                .name = "memory",
                .description = "Number of solutions saved to check for new nearby solutions.",
            })),
            .probability = .build(opt.Named, .single(.floating(.{ .min = .open(0), .max = .closed(1) }), .{
                .name = "threshold",
                .description = "Average probability of the station combination.",
            })),
            .consensus = .build(opt.Named, .single(.integer(.{ .min = lma.constants.network.min_consensus, .max = lma.constants.network.max_consensus }), .{
                .name = "consensus",
                .description = "Minimum number of stations that must agree on a preliminary solution.",
            })),
        })),
        .verbose = opt.flags.Flag(.{
            .name = "verbose",
            .description = "Show run statistics",
        }),
        .chunk = .build(opt.Named, .single(time.Seconds.parser, .{
            .name = "divide",
            .description = "Total time to analyse per thread as either SECONDS or HH:MM:SS.",
            .display = "SECONDS",
        })),
        .decimate = .optional(.{ .default = "Work with the full data" }, .build(opt.Named, .single(.integer(.{ .min = 1, .max = 1_000 }), .{
            .name = "decimate",
            .description = "Decimation window in micro seconds (us).",
            .display = "WINDOW",
        }))),
    })),
}));

pub const Options = struct {
    threads: usize,
    time: Time,
    files: Files,
    config: Config,

    pub const Config = struct {
        correlation: Correlation,
        search: Search,
        chunk: time.Seconds = .{ .seconds = if (@import("builtin").single_threaded) 24 * 60 * 60 else 60 },
        decimate: ?u32,
        verbose: bool,

        pub const Correlation = struct {
            weights: lma.pipeline.match.Weights = .@"const+decibels",
            window: f32 = 0.1,
        };

        pub const Search = struct {
            beam_width: u16 = 0,
            dfs_attempts: u16 = 4,
            memory: u32 = 5,
            probability: f32 = 0.90,
            consensus: u8 = 6,
        };
    };

    pub const Time = struct {
        date: time.Date,
        hour: time.Time,
        start: ?time.Time,
        ending: union(enum) {
            end: time.Time,
            total: time.Seconds,
        },
    };

    pub const Files = struct {
        inputs: []nargs.params.io.Glob.Pattern,
        excluded: []const []const u8,
        stations: []const []const u8,
        out_dir: ?[]const u8,
        outputs: []const []const u8,
        probe: ?[]const u8,
    };
};

pub const time = struct {
    pub const Date = struct {
        year: u16,
        month: u8,
        day: u8,
        string: [8]u8,

        pub fn init(string: [8]u8) error{InvalidDate}!Date {
            return .{
                .year = std.fmt.parseInt(u16, string[0..4], 10) catch return error.InvalidDate,
                .month = std.fmt.parseInt(u8, string[4..6], 10) catch return error.InvalidDate,
                .day = std.fmt.parseInt(u8, string[6..8], 10) catch return error.InvalidDate,
                .string = string,
            };
        }

        pub fn format(self: Date, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d}/{d}/{d}", .{ self.year, self.month, self.day });
        }

        const Parser = struct {
            const sep: u8 = '/';
            pub fn parse(_: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Error!Date {
                return parseInner(buf) catch |err| switch (err) {
                    error.InvalidFormat => {
                        diag.log(.invalid_value_reason,
                            \\Expected a date in format YYYYMMDD, YYMMDD or (YY)YY/(M)M/(D)D but found "{s}" instead.
                        , .{buf});
                        return error.InvalidValue;
                    },
                    error.InvalidDate => {
                        diag.log(.invalid_value_reason,
                            \\"{s}" is not a valid date.
                        , .{buf});
                        return error.InvalidValue;
                    },
                };
            }

            pub fn parseInner(buf: []const u8) error{ InvalidDate, InvalidFormat }!Date {
                const sep_count = std.mem.countScalar(u8, buf, sep);
                const string: [8]u8 = if (sep_count == 0)
                    if (buf.len == 6) blk: {
                        var string: [8]u8 = "20YYMMDD".*;
                        string[2..8].* = buf[0..6].*;
                        break :blk string;
                    } else if (buf.len == 8) buf[0..8].* else return error.InvalidFormat
                else if (sep_count == 2) blk: {
                    var string: [8]u8 = "20YY0M0D".*;
                    var iter = std.mem.splitScalar(u8, buf, sep);
                    const year = iter.next().?;
                    if (year.len < 2 or 4 < year.len) return error.InvalidFormat;
                    @memcpy(string[4 - year.len ..][0..year.len], year);
                    const month = iter.next().?;
                    if (month.len < 1 or 2 < month.len) return error.InvalidFormat;
                    @memcpy(string[6 - month.len ..][0..month.len], month);
                    const day = iter.next().?;
                    if (day.len < 1 or 2 < day.len) return error.InvalidFormat;
                    @memcpy(string[8 - day.len ..][0..day.len], day);

                    break :blk string;
                } else return error.InvalidFormat;

                return .init(string);
            }
        };

        pub const parser: Value(Date) = .{
            .parse = Parser.parse,
            .dupe = Value(Date).mixin.copyOnDupe,
            .deinit = Value(Date).mixin.noDeinit,
            .format = format,
            .display = "DATE",
            .help =
            \\Date specified as one of YYYYMMDD, YYMMDD or (YY)YY/(M)M/(D)D
            ,
        };
    };

    pub const Time = struct {
        hour: u8,
        minute: u8,
        second: u8,
        string: [6]u8,

        pub fn init(string: [6]u8) error{InvalidTime}!Time {
            return .{
                .hour = std.fmt.parseInt(u8, string[0..2], 10) catch return error.InvalidTime,
                .minute = std.fmt.parseInt(u8, string[2..4], 10) catch return error.InvalidTime,
                .second = std.fmt.parseInt(u8, string[4..6], 10) catch return error.InvalidTime,
                .string = string,
            };
        }

        pub fn toSeconds(self: Time) u32 {
            return (@as(u32, self.hour) * 60 + self.minute) * 60 + self.second;
        }

        pub fn format(self: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });
        }

        const Parser = struct {
            const sep: u8 = ':';

            fn parse(_: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Error!Time {
                return parseInner(buf) catch |err| switch (err) {
                    error.InvalidFormat => {
                        diag.log(.invalid_value_reason,
                            \\Expected time in format HHMMSS or HH:MM:SS but found "{s}" instead.
                        , .{buf});
                        return error.InvalidValue;
                    },
                    error.InvalidTime => {
                        diag.log(.invalid_value_reason,
                            \\"{s}" is not a valid time.
                        , .{buf});
                        return error.InvalidValue;
                    },
                };
            }

            fn parseInner(buf: []const u8) error{ InvalidTime, InvalidFormat }!Time {
                const sep_count = std.mem.countScalar(u8, buf, sep);
                const string: [6]u8 = if (sep_count == 0 and buf.len == 6)
                    buf[0..6].*
                else if (sep_count == 2 and buf.len == 8 and buf[2] == sep and buf[5] == sep) blk: {
                    var string: [6]u8 = undefined;
                    string[0..2].* = buf[0..2].*;
                    string[2..4].* = buf[3..5].*;
                    string[4..6].* = buf[6..8].*;
                    break :blk string;
                } else return error.InvalidFormat;

                return .init(string);
            }
        };

        pub const parser: Value(Time) = .{
            .parse = Parser.parse,
            .dupe = Value(Time).mixin.copyOnDupe,
            .deinit = Value(Time).mixin.noDeinit,
            .format = format,
            .display = "TIME",
            .help =
            \\Time specified as either HHMMSS or HH:MM:SS
            ,
        };
    };

    pub const Seconds = struct {
        seconds: u32,

        pub fn format(self: Seconds, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.seconds / 3600, (self.seconds / 60) % 60, self.seconds % 60 });
        }

        const Parser = struct {
            const sep: u8 = ':';
            pub fn parse(_: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Error!Seconds {
                return parseInner(buf) catch |err| switch (err) {
                    error.InvalidFormat => {
                        diag.log(.invalid_value_reason,
                            \\Expected time in format SECONDS or (HH:)MM:SS but found "{s}" instead.
                        , .{buf});
                        return error.InvalidValue;
                    },
                    error.InvalidTime => {
                        diag.log(.invalid_value_reason,
                            \\"{s}" is not a valid time.
                        , .{buf});
                        return error.InvalidValue;
                    },
                };
            }

            pub fn parseInner(buf: []const u8) error{ InvalidTime, InvalidFormat }!Seconds {
                const sep_count = std.mem.countScalar(u8, buf, sep);
                if (sep_count == 0) {
                    return if (std.fmt.parseInt(u32, buf, 10)) |seconds|
                        .{ .seconds = seconds }
                    else |err| switch (err) {
                        error.Overflow => error.InvalidTime,
                        error.InvalidCharacter => error.InvalidFormat,
                    };
                } else if (sep_count <= 2) {
                    var seconds: u32 = 0;
                    var iter = std.mem.splitScalar(u8, buf, sep);
                    while (iter.next()) |str| {
                        seconds *= 60;
                        seconds += std.fmt.parseInt(u32, str, 10) catch |err| return switch (err) {
                            error.Overflow => error.InvalidTime,
                            error.InvalidCharacter => error.InvalidFormat,
                        };
                    }
                    return .{ .seconds = seconds };
                }
                return error.InvalidFormat;
            }
        };

        pub const parser: Value(Seconds) = .{
            .parse = Parser.parse,
            .dupe = Value(Seconds).mixin.copyOnDupe,
            .deinit = Value(Seconds).mixin.noDeinit,
            .format = format,
            .display = "SECONDS",
            .help =
            \\Seconds specified as either SECONDS or (HH:)MM:SS
            ,
        };
    };
};
