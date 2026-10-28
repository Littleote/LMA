const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Module = Build.Module;

pub fn build(b: *std.Build) void {
    const opt: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .single_threaded = b.option(bool, "single-threaded", "Generate the executables in single threaded mode"),
        .emit_binary = !(b.option(bool, "no-bin", "Skip emitting the binary") orelse false),
    };
    const filter_option = b.option([]const u8, "test-filter", "Select a subset of tests to run");
    const deploy = b.option(bool, "deploy", "Generate an executable for all targets") orelse false;

    const demo: Demo = .addOptions(b);

    const artifacts: Artifacts = .init(b, null, opt);

    // EXECUTABLES
    const parser_step = b.step("parser", "Parse the selected files and generate a new file in a different format");
    if (!deploy) parser_step.dependOn(opt.installArtifact(b, artifacts.executable.parser));

    const match_step = b.step("match", "Match a set of station data files and locate the sources using time of arrival");
    if (!deploy) match_step.dependOn(opt.installArtifact(b, artifacts.executable.match));

    const holes_step = b.step("holes", "Hole detection functionality");
    if (!deploy) holes_step.dependOn(opt.installArtifact(b, artifacts.executable.holes));

    const all_step = b.step("all", "Generate all executables");
    all_step.dependOn(parser_step);
    all_step.dependOn(match_step);
    all_step.dependOn(holes_step);

    if (deploy) for (Options.deploy_targets) |target| {
        _ = Artifacts.init(
            b,
            .{
                .parser = parser_step,
                .match = match_step,
                .holes = holes_step,
            },
            .{
                .suffix = target.name,
                .optimize = .safe,
                .target = b.resolveTargetQuery(target.query),
                .single_threaded = opt.single_threaded,
                .emit_binary = true,
            },
        );
    };

    // CHECK
    // Build all programs
    const check_step = b.step("check", "Check all executables and utilities compile");
    check_step.dependOn(opt.installArtifact(b, artifacts.executable.parser));
    check_step.dependOn(opt.installArtifact(b, artifacts.executable.match));
    check_step.dependOn(opt.installArtifact(b, artifacts.executable.holes));
    check_step.dependOn(opt.installArtifact(b, artifacts.utilities.match_stats));

    // DOCS
    const install_docs = b.addInstallDirectory(.{
        .source_dir = b.addLibrary(.{ .name = "lma", .root_module = artifacts.library.lma }).getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // TEST
    const lma_tests = b.addTest(.{
        .root_module = artifacts.library.lma,
        .filters = if (filter_option) |filter| &.{filter} else &.{},
    });

    const math_tests = b.addTest(.{
        .root_module = artifacts.library.lma_math,
        .filters = if (filter_option) |filter| &.{filter} else &.{},
    });

    const test_step = b.step("test", "Run LMA tests");
    test_step.dependOn(if (opt.emit_binary) &b.addRunArtifact(lma_tests).step else &lma_tests.step);
    test_step.dependOn(if (opt.emit_binary) &b.addRunArtifact(math_tests).step else &lma_tests.step);

    // DEMOS
    demo.addDemos(b, artifacts);
}

const Options = struct {
    suffix: ?[]const u8 = null,
    emit_binary: bool,
    target: Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    single_threaded: ?bool,

    fn modifyModule(self: Options, module: *Module) *Module {
        module.resolved_target = if (module.resolved_target) |target| target else self.target;
        module.optimize = if (module.optimize) |optimize| optimize else self.optimize;
        module.single_threaded = if (module.single_threaded) |single_threaded| single_threaded else self.single_threaded;
        return module;
    }

    fn addExecutable(self: Options, b: *Build, name: []const u8, module: *Module) *Step.Compile {
        return b.addExecutable(.{
            .name = if (self.suffix) |suffix|
                b.allocator.print("{s}-{s}", .{ name, suffix }) catch @panic("OOM")
            else
                name,
            .root_module = module,
        });
    }

    fn installArtifact(self: Options, b: *Build, artifact: *Step.Compile) *Step {
        return if (self.emit_binary)
            &b.addInstallArtifact(artifact, .{}).step
        else
            &artifact.step;
    }

    const Query = struct { name: []const u8, query: std.Target.Query };
    const deploy_targets: []const Query = &.{
        .{ .name = "linux", .query = .{ .cpu_arch = .x86_64, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 }, .os_tag = .linux, .abi = .none } },
        .{ .name = "linux-rocketlake", .query = .{ .cpu_arch = .x86_64, .cpu_model = .{ .explicit = &std.Target.x86.cpu.rocketlake }, .os_tag = .linux, .abi = .none } },
        .{ .name = "linux-baseline", .query = .{ .cpu_arch = .x86_64, .cpu_model = .baseline, .os_tag = .linux, .abi = .none } },
        .{ .name = "windows", .query = .{ .cpu_arch = .x86_64, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 }, .os_tag = .windows, .abi = .none } },
        .{ .name = "windows-baseline", .query = .{ .cpu_arch = .x86_64, .cpu_model = .baseline, .os_tag = .windows, .abi = .none } },
    };
};

const Artifacts = struct {
    library: struct {
        lma: *Module,
        lma_math: *Module,
        nargs: *Module,
    },
    executable: struct {
        parser: *Step.Compile,
        match: *Step.Compile,
        holes: *Step.Compile,
    },
    utilities: struct {
        match_stats: *Step.Compile,
    },

    fn createModule(b: *Build, visibility: bool, name: []const u8, options: Module.CreateOptions) *Module {
        return if (visibility) b.addModule(name, options) else b.createModule(options);
    }

    const executable_names = @typeInfo(@FieldType(@This(), "executable")).@"struct".field_names;
    const ExecutableSteps = @Struct(.auto, null, executable_names, &@splat(*Step), &@splat(.{}));

    fn init(b: *Build, maybe_deploy: ?ExecutableSteps, opt: Options) Artifacts {
        var artifacts: Artifacts = undefined;
        artifacts.library.nargs = b.dependency("nice_args", .{
            .target = opt.target,
            .optimize = opt.optimize,
        }).module("nice_args");

        artifacts.library.lma_math = opt.modifyModule(b.createModule(.{
            .root_source_file = b.path("src/lma/math.zig"),
            .optimize = if (opt.optimize == .debug) .debug else .fast,
        }));
        artifacts.library.lma = opt.modifyModule(createModule(b, maybe_deploy == null, "lma", .{
            .root_source_file = b.path("src/lma/lma.zig"),
            .imports = &.{.{ .name = "math", .module = artifacts.library.lma_math }},
        }));

        artifacts.executable = .{
            .parser = opt.addExecutable(b, "parser", opt.modifyModule(b.createModule(.{
                .root_source_file = b.path("src/parser/main.zig"),
                .imports = &.{
                    .{ .module = artifacts.library.lma, .name = "lma" },
                    .{ .module = artifacts.library.nargs, .name = "nargs" },
                },
            }))),
            .match = opt.addExecutable(b, "match", opt.modifyModule(b.createModule(.{
                .root_source_file = b.path("src/match/main.zig"),
                .imports = &.{
                    .{ .module = artifacts.library.lma, .name = "lma" },
                    .{ .module = artifacts.library.nargs, .name = "nargs" },
                },
            }))),
            .holes = opt.addExecutable(b, "hole", opt.modifyModule(b.createModule(.{
                .root_source_file = b.path("src/lholes/main.zig"),
                .imports = &.{
                    .{ .module = artifacts.library.lma, .name = "lma" },
                    .{ .module = artifacts.library.nargs, .name = "nargs" },
                },
            }))),
        };

        inline for (executable_names) |executable| {
            const step = if (maybe_deploy) |deploy| @field(deploy, executable) else b.getInstallStep();
            step.dependOn(opt.installArtifact(b, @field(artifacts.executable, executable)));
        }

        artifacts.utilities = .{
            .match_stats = opt.addExecutable(b, "mstats", opt.modifyModule(b.createModule(.{
                .root_source_file = b.path("src/utilities/match_stats.zig"),
                .imports = &.{
                    .{ .module = artifacts.library.nargs, .name = "nargs" },
                },
            }))),
        };

        return artifacts;
    }
};

const Demo = struct {
    date_time: ?DateTime,
    parser_kind: ?ParserKind,
    match_param: ?MatchParam,
    match_param_span: ?MatchParamTimeSpan,
    signals_input: SignalFormat,
    stations_input: StationFormat,
    match_probe: bool,
    test_sequentially: ?bool,

    fn addOptions(b: *std.Build) Demo {
        return .{
            .date_time = .addOption(b),
            .parser_kind = b.option(ParserKind, "kind",
                \\File to translate for the parser demo. ("stations", "signals", "points", "clusters")
            ),
            .match_param = b.option(MatchParam, "parameter",
                \\Hyperparameter to test for the match-param demo. ("window", "dfs", "beam")
            ),
            .match_param_span = b.option(MatchParamTimeSpan, "test-timespan",
                \\Amount of time to analyze for the match-param demo. ("10min", "1min", "10sec")
            ),
            .signals_input = b.option(SignalFormat, "signals",
                \\File format of signals to consume for the match demo. ("dat", "bin", "csv")
            ) orelse .dat,
            .stations_input = b.option(StationFormat, "stations",
                \\File format of stations to consume for a demo. ("gps", "csv")
            ) orelse .gps,
            .match_probe = b.option(bool, "probe",
                \\Include probe file for the match demo
            ) orelse false,
            .test_sequentially = b.option(bool, "sequential",
                \\Guarantee that the test for match-demo can only run one at at time
            ),
        };
    }

    fn addDemos(demo: Demo, b: *std.Build, artifacts: Artifacts) void {
        inline for (demo_builders) |demo_builder| {
            demo_builder(demo, b, artifacts);
        }
    }

    fn hasFields(self: Demo, b: *Build, step: *Step, comptime requirements: []const Requirement) bool {
        var has_all = true;
        inline for (requirements) |requirement| {
            const field = @tagName(requirement.field);
            if (@typeInfo(@FieldType(Demo, field)) == .optional) {
                if (@field(self, field) == null) {
                    step.dependOn(&b.addFail(requirement.err).step);
                    has_all = false;
                }
            } else {
                std.debug.panic("Required field {s} is not optional.", .{field});
            }
        }
        return has_all;
    }

    const SignalFormat = enum { dat, bin, csv };
    const StationFormat = enum { gps, csv };
    const ParserKind = enum { stations, signals, points, clusters };
    const MatchParam = enum { window, dfs, beam };
    const MatchParamTimeSpan = enum { @"10min", @"1min", @"10sec" };

    const demo_builders = [_]DemoBuilder{ parseDemo, matchDemo, matchParamDemo, holeDemo };
    const DemoBuilder: type = fn (Demo, *Build, Artifacts) void;

    const Requirement = struct {
        err: []const u8,
        field: std.meta.FieldEnum(Demo),
    };

    const DateTime = struct {
        date: [6]u8,
        time: [6]u8,

        fn addOption(b: *std.Build) ?DateTime {
            const input = b.option([]const u8, "date", "Date and time to use as input for a demo in the format 'YYMMDD-HHMMSS'") orelse return null;
            bad_input: {
                const date, const time = std.mem.cutScalar(u8, input, '-') orelse break :bad_input;
                if (std.mem.replacementSize(u8, date, "/", "") != 6 or std.mem.replacementSize(u8, time, ":", "") != 6) break :bad_input;
                var self: DateTime = .{ .date = undefined, .time = undefined };
                _ = std.mem.replace(u8, date, "/", "", &self.date);
                _ = std.mem.replace(u8, time, ":", "", &self.time);
                return self;
            }
            std.log.err("Expected -Ddate to be in the form 'YYMMDD-HHMMSS', but received '{s}'", .{input});
            b.invalid_user_input = true;
            return null;
        }
    };

    fn parseDemo(demo: Demo, b: *std.Build, artifacts: Artifacts) void {
        const step = b.step("demo-parser", "Run the parsing demo");

        const need_date = if (demo.parser_kind) |kind| switch (kind) {
            .stations => false,
            .signals, .points, .clusters => true,
        } else true;

        switch (need_date) {
            inline else => |comptime_need_date| {
                const date_req: []const Requirement = if (comptime_need_date)
                    &.{.{ .err = "Missing date and time", .field = .date_time }}
                else
                    &.{};
                if (!demo.hasFields(b, step, date_req ++ .{
                    Requirement{ .err = "Missing kind of file to parse", .field = .parser_kind },
                })) return;
            },
        }

        const kind = demo.parser_kind.?;
        const date = if (need_date) demo.date_time.? else undefined;

        const run = b.addRunArtifact(artifacts.executable.parser);
        switch (kind) {
            .signals => run.addArgs(&.{ "signals", "--path=data/signals/" ++ date.date, "-i=sources/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".dat" }),
            .points => run.addArgs(&.{ "points", "--path=data/points/" ++ date.date, "-i=output/*_" ++ date.date ++ "_" ++ date.time ++ "_*.dat*" }),
            .clusters => run.addArgs(&.{ "clusters", "--path=data/lightnings/" ++ date.date, "-i=XCALMA_" ++ date.date ++ ".csv" }),
            .stations => run.addArgs(&.{ "stations", "--path=data/stations", "-i=upc.gps,mcat.gps", "-o=baseline.csv" }),
        }
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }

    fn holeDemo(demo: Demo, b: *std.Build, artifacts: Artifacts) void {
        const step = b.step("demo-hole", "Run the holes demo");

        if (!demo.hasFields(b, step, &.{
            .{ .err = "Missing date and time", .field = .date_time },
        })) return;

        const date = demo.date_time.?;

        const run = b.addRunArtifact(artifacts.executable.holes);
        run.addArgs(&.{
            "--region=catalunya",
            "-r=high",
            "-i=data/lightnings/" ++ date.date ++ "/bin",
            "--cat-map",
            "--ffmpeg",
        });
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }

    fn matchDemo(demo: Demo, b: *std.Build, artifacts: Artifacts) void {
        const step = b.step("demo-match", "Run the match demo");

        if (!demo.hasFields(b, step, &.{
            .{ .err = "Missing date and time", .field = .date_time },
        })) return;

        const date = demo.date_time.?;
        const inputs = demo.signals_input;
        const stations = demo.stations_input;
        const probing = demo.match_probe;

        const run = b.addRunArtifact(artifacts.executable.match);
        switch (inputs) {
            .bin => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/bin/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".bin"}),
            .csv => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/csv/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".csv"}),
            .dat => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/sources/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".dat"}),
        }
        switch (stations) {
            .csv => run.addArgs(&.{"-s=data/stations/stations.csv"}),
            .gps => run.addArgs(&.{ "--stations", "data/stations/upc.gps", "data/stations/mcat.gps" }),
        }
        run.addArgs(&.{
            "-o",
            "data/points/" ++ date.date ++ "/csv/corr-" ++ date.time[0..2] ++ "h-" ++ date.time[2..4] ++ "min-" ++ date.time[4..6] ++ "s.csv",
            "data/points/" ++ date.date ++ "/output/CUSTOM_" ++ date.date ++ "_" ++ date.time ++ "_0600.dat.gz",
            "--verbose",
            "-d=" ++ date.date,
            "-h=" ++ date.time,
            "--analyse=10:00",
        });
        if (probing) run.addArgs(&.{
            "--probe",
            "data/points/" ++ date.date ++ "/probes/" ++ date.date ++ "_" ++ date.time ++ "_0600.dat",
        });
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }

    fn matchParamDemo(demo: Demo, b: *std.Build, artifacts: Artifacts) void {
        const ParamConfig = struct {
            name: []const u8,
            arg: []const u8,
        };

        const step = b.step("demo-match-param", "Run the tests for the hyperparameters of match");

        if (!demo.hasFields(b, step, &.{
            .{ .err = "Missing date and time", .field = .date_time },
            .{ .err = "Missing parameter configuration to analyze", .field = .match_param },
            .{ .err = "Missing amount of time to analyze", .field = .match_param_span },
        })) return;

        const date = demo.date_time.?;
        const param = demo.match_param.?;
        const runtime = demo.match_param_span.?;
        const inputs = demo.signals_input;
        const stations = demo.stations_input;
        const sequential = demo.test_sequentially orelse false;

        const config: Product(ParamConfig) = switch (param) {
            .window => .{
                .items = &.{
                    &.{
                        .{ .name = "CW-500MS", .arg = "--correlation-window=0.5" },
                        .{ .name = "CW-200MS", .arg = "--correlation-window=0.2" },
                        .{ .name = "CW-100MS", .arg = "--correlation-window=0.1" },
                        .{ .name = "CW-050MS", .arg = "--correlation-window=0.05" },
                        .{ .name = "CW-020MS", .arg = "--correlation-window=0.02" },
                        .{ .name = "CW-010MS", .arg = "--correlation-window=0.01" },
                        .{ .name = "CW-005MS", .arg = "--correlation-window=0.005" },
                    },
                    &.{
                        .{ .name = "TH-0.90", .arg = "--threshold=0.95" },
                        .{ .name = "TH-0.90", .arg = "--threshold=0.90" },
                        .{ .name = "TH-0.90", .arg = "--threshold=0.85" },
                        .{ .name = "TH-0.90", .arg = "--threshold=0.80" },
                    },
                },
            },

            .dfs => .{
                .items = &.{
                    &.{
                        .{ .name = "NO-BEAM", .arg = "--beam-width=0" },
                    },
                    &.{
                        .{ .name = "DFS-01", .arg = "--depth-tries=1" },
                        .{ .name = "DFS-02", .arg = "--depth-tries=2" },
                        .{ .name = "DFS-03", .arg = "--depth-tries=3" },
                        .{ .name = "DFS-04", .arg = "--depth-tries=4" },
                        .{ .name = "DFS-06", .arg = "--depth-tries=6" },
                        .{ .name = "DFS-08", .arg = "--depth-tries=8" },
                        .{ .name = "DFS-10", .arg = "--depth-tries=10" },
                    },
                    &.{
                        .{ .name = "CW-500MS", .arg = "--correlation-window=0.5" },
                        .{ .name = "CW-100MS", .arg = "--correlation-window=0.1" },
                        .{ .name = "CW-020MS", .arg = "--correlation-window=0.02" },
                    },
                    &.{
                        .{ .name = "TH-0.95", .arg = "--threshold=0.95" },
                        .{ .name = "TH-0.90", .arg = "--threshold=0.90" },
                        .{ .name = "TH-0.85", .arg = "--threshold=0.85" },
                        .{ .name = "TH-0.80", .arg = "--threshold=0.80" },
                    },
                },
            },

            .beam => .{ .items = &.{
                &.{
                    .{ .name = "BEAM-001", .arg = "--beam-width=1" },
                    .{ .name = "BEAM-002", .arg = "--beam-width=2" },
                    .{ .name = "BEAM-005", .arg = "--beam-width=5" },
                    .{ .name = "BEAM-010", .arg = "--beam-width=10" },
                    .{ .name = "BEAM-020", .arg = "--beam-width=20" },
                    .{ .name = "BEAM-050", .arg = "--beam-width=50" },
                    .{ .name = "BEAM-100", .arg = "--beam-width=100" },
                },
                &.{
                    .{ .name = "NO-DFS", .arg = "--depth-tries=0" },
                },
                &.{
                    .{ .name = "CW-500MS", .arg = "--correlation-window=0.5" },
                    .{ .name = "CW-100MS", .arg = "--correlation-window=0.1" },
                    .{ .name = "CW-020MS", .arg = "--correlation-window=0.02" },
                },
                &.{
                    .{ .name = "TH-0.90", .arg = "--threshold=0.9" },
                },
            } },
        };

        const stats = b.addRunArtifact(artifacts.utilities.match_stats);
        var last_step: *std.Build.Step = &stats.step;
        step.dependOn(&stats.step);
        stats.addArg("--stdout");

        const config_len = config.len();
        std.debug.assert(config_len > 0);
        var name_len: usize = 0;
        for (0..config.items.len) |idx| name_len += config.get(idx, 0).name.len + 1;
        name_len -= 1;

        const name_buffer = b.allocator.alloc(u8, name_len * config_len) catch @panic("OOM");
        @memset(name_buffer, '+');

        for (0..config.len()) |idx| {
            const run = b.addRunArtifact(artifacts.executable.match);

            const name = name_buffer[name_len * idx ..][0..name_len];
            var name_unset: [*]u8 = name.ptr;
            for (0..config.items.len) |arg_idx| {
                const arg = config.get(arg_idx, idx);
                @memcpy(name_unset[0..arg.name.len], arg.name);
                name_unset = name_unset[arg.name.len + 1 ..];
                run.addArg(arg.arg);
            }

            run.setName(name);
            switch (inputs) {
                .bin => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/bin/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".bin"}),
                .csv => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/csv/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".csv"}),
                .dat => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/sources/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".dat"}),
            }
            switch (stations) {
                .csv => run.addArgs(&.{"-s=data/stations/stations.csv"}),
                .gps => run.addArgs(&.{ "--stations", "data/stations/upc.gps", "data/stations/mcat.gps" }),
            }
            switch (runtime) {
                .@"10min" => run.addArgs(&.{
                    "--analyse", "10:00",
                    "--threads", "10",
                    "--divide",  "1:00",
                }),
                .@"1min" => run.addArgs(&.{
                    "--analyse", "1:00",
                    "--threads", "10",
                    "--divide",  "6",
                }),
                .@"10sec" => run.addArgs(&.{
                    "--analyse", "10",
                    "--threads", "10",
                    "--divide",  "1",
                }),
            }
            run.addArgs(&.{
                "-o",        b.allocator.print("data/points/{s}/demo/out/{s}_{s}_{s}_0600.dat.gz", .{ date.date, name, date.date, date.time }) catch @panic("OOM"),
                "-d",        &date.date,
                "-h",        &date.time,
                "--verbose",
            });
            run.addPassthruArgs();

            stats.addFileArg2(run.captureStdOut(.{}), .{});
            if (sequential) {
                last_step.dependOn(&run.step);
                last_step = &run.step;
            }
        }

        stats.addArg("--name");
        for (0..config_len) |idx| {
            const name = name_buffer[name_len * idx ..][0..name_len];
            stats.addArg(name);
        }

        stats.addArg(b.allocator.print("--output=data/points/{s}/demo/{s}.csv", .{ date.date, @tagName(param) }) catch @panic("OOM"));
    }
};

fn Product(T: type) type {
    return struct {
        items: []const []const T,

        fn get(self: Product(T), item_idx: usize, index: usize) T {
            var option = index;
            for (self.items, 0..) |item, idx| {
                if (idx == item_idx) {
                    return item[option % item.len];
                } else {
                    option /= item.len;
                }
            }
            std.debug.panic("Out of bounds parameter {d}, with parameter count of {d}.", .{ item_idx, self.items.len });
        }

        fn len(self: Product(T)) usize {
            var total: usize = 1;
            for (self.items) |item| total *= item.len;
            return total;
        }
    };
}
