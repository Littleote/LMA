const std = @import("std");

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    single_threaded: bool,
};

const Exe = struct {
    parser: *std.Build.Step.Compile,
    match: *std.Build.Step.Compile,
    holes: *std.Build.Step.Compile,
};

const Demo = enum {
    parser,
    match,
    holes,
};

pub fn build(b: *std.Build) void {
    const opt: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .single_threaded = b.option(bool, "single-threaded", "Generate the executables in single threaded mode.") orelse false,
    };
    const filter_option = b.option([]const u8, "test-filter", "Select a subset of tests to run");
    const emit_bin = !(b.option(bool, "no-bin", "Skip emitting the binary.") orelse false);

    const nargs = b.dependency("nice_args", .{
        .target = opt.target,
        .optimize = opt.optimize,
    }).module("nice_args");

    const math = b.createModule(.{
        .root_source_file = b.path("src/lma/math.zig"),
        .target = opt.target,
        .optimize = if (opt.optimize == .debug) .debug else .fast,
        .single_threaded = opt.single_threaded,
    });

    const lma = b.addModule("lma", .{
        .root_source_file = b.path("src/lma/lma.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
        .single_threaded = opt.single_threaded,
        .imports = &.{.{ .name = "math", .module = math }},
    });

    const exe: Exe = .{
        .parser = b.addExecutable(.{
            .name = "parser",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/parser/main.zig"),
                .target = opt.target,
                .optimize = opt.optimize,
                .imports = &.{
                    .{ .module = lma, .name = "lma" },
                    .{ .module = nargs, .name = "nargs" },
                },
                .single_threaded = opt.single_threaded,
            }),
        }),
        .match = b.addExecutable(.{
            .name = "match",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/match/main.zig"),
                .target = opt.target,
                .optimize = opt.optimize,
                .imports = &.{
                    .{ .module = lma, .name = "lma" },
                    .{ .module = nargs, .name = "nargs" },
                },
                .single_threaded = opt.single_threaded,
            }),
        }),
        .holes = b.addExecutable(.{
            .name = "holes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lholes/main.zig"),
                .target = opt.target,
                .optimize = opt.optimize,
                .imports = &.{
                    .{ .module = lma, .name = "lma" },
                    .{ .module = nargs, .name = "nargs" },
                },
                .single_threaded = opt.single_threaded,
            }),
        }),
    };

    const parser_step = b.step("parser", "Parse the selected files and generate a new file in a different format.");
    parser_step.dependOn(if (emit_bin) &b.addInstallArtifact(exe.parser, .{}).step else &exe.parser.step);

    const match_step = b.step("match", "Match a set of station data files and locate the sources using time of arrival.");
    match_step.dependOn(if (emit_bin) &b.addInstallArtifact(exe.match, .{}).step else &exe.match.step);

    const holes_step = b.step("holes", "Hole detection functionality.");
    holes_step.dependOn(if (emit_bin) &b.addInstallArtifact(exe.holes, .{}).step else &exe.holes.step);

    const all_step = b.step("all", "Generate all executables.");
    all_step.dependOn(parser_step);
    all_step.dependOn(match_step);
    all_step.dependOn(holes_step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = b.addLibrary(.{ .name = "lma", .root_module = lma }).getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const lma_tests = b.addTest(.{
        .root_module = lma,
        .filters = if (filter_option) |filter| &.{filter} else &.{},
    });

    const math_tests = b.addTest(.{
        .root_module = math,
        .filters = if (filter_option) |filter| &.{filter} else &.{},
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(if (emit_bin) &b.addRunArtifact(lma_tests).step else &lma_tests.step);
    test_step.dependOn(if (emit_bin) &b.addRunArtifact(math_tests).step else &lma_tests.step);

    const demo_step = b.step("demo", "Run the selected demo");

    if (b.option(Demo, "demo", "")) |demo| {
        b.getInstallStep().dependOn(demo_step);
        switch (demo) {
            .parser => {
                parseDemo(b, demo_step, exe.parser);
                parser_step.dependOn(demo_step);
            },
            .match => {
                matchDemo(b, demo_step, exe.match);
                match_step.dependOn(demo_step);
            },
            .holes => {
                holeDemo(b, demo_step, exe.holes);
                holes_step.dependOn(demo_step);
            },
        }
    } else {
        b.getInstallStep().dependOn(all_step);
        demo_step.dependOn(&b.addFail("Missing demo option").step);
    }
}

const DateTime = struct {
    date: [6]u8,
    time: [6]u8,

    pub fn addOption(b: *std.Build) ?DateTime {
        const input = b.option([]const u8, "date", "Date to use as input for demo in the format 'YYMMDD-HHMMSS'") orelse return null;
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

const ParseStage = packed struct(u3) {
    pub const BuildOptions = enum {
        signals,
        points,
        clusters,
        all,
    };

    pub fn init(options: BuildOptions) ParseStage {
        return switch (options) {
            .signals => .{ .signals = true },
            .points => .{ .points = true },
            .clusters => .{ .clusters = true },
            .all => .{ .signals = true, .points = true, .clusters = true },
        };
    }

    signals: bool = false,
    points: bool = false,
    clusters: bool = false,
};

fn parseDemo(b: *std.Build, step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    var failed = false;
    const date = DateTime.addOption(b) orelse fail: {
        step.dependOn(&b.addFail("Missing date.").step);
        failed = true;
        break :fail undefined;
    };
    const stage_opt = b.option(
        ParseStage.BuildOptions,
        "stage",
        "Stage to parse, generating the corresponding '.bin' and '.csv' files.",
    ) orelse fail: {
        step.dependOn(&b.addFail("Missing stage.").step);
        failed = true;
        break :fail undefined;
    };
    if (failed) return;

    const stage: ParseStage = .init(stage_opt);

    if (stage.signals) {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "signals", "--path=data/signals/" ++ date.date, "-i=sources/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".dat" });
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }
    if (stage.points) {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "points", "--path=data/points/" ++ date.date, "-i=output/*_" ++ date.date ++ "_" ++ date.time ++ "_*.dat*" });
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }
    if (stage.clusters) {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "clusters", "--path=data/lightnings/" ++ date.date, "-i=XCALMA_" ++ date.date ++ ".csv" });
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }
}

fn holeDemo(b: *std.Build, step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    var failed = false;
    const date = DateTime.addOption(b) orelse fail: {
        step.dependOn(&b.addFail("Missing date.").step);
        failed = true;
        break :fail undefined;
    };
    if (failed) return;

    const run = b.addRunArtifact(exe);
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

fn matchDemo(b: *std.Build, step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    const InputFile = enum { bin, dat };
    const StationFile = enum { csv, gps };

    var failed = false;
    const date = DateTime.addOption(b) orelse fail: {
        step.dependOn(&b.addFail("Missing date.").step);
        failed = true;
        break :fail undefined;
    };
    const inputs = b.option(InputFile, "input", "Input sources format.") orelse .dat;
    const stations = b.option(StationFile, "station", "Station data format.") orelse .gps;
    const probing = b.option(bool, "probe", "Pass a probe file to the matching algorithm.") orelse false;
    if (failed) return;

    const run = b.addRunArtifact(exe);
    switch (inputs) {
        .bin => run.addArgs(&.{"-i=data/signals/" ++ date.date ++ "/bin/*_*_*_" ++ date.date ++ "_" ++ date.time ++ ".bin"}),
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
