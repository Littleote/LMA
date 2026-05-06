const std = @import("std");

var emit_bin: bool = true;
var maybe_date_time: ?DateTime = null;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Generate the executables in single threaded mode.") orelse false;
    emit_bin = !(b.option(bool, "no-bin", "Skip emitting the binary.") orelse false);
    maybe_date_time = DateTime.addOption(b);

    const nargs = b.dependency("nice_args", .{
        .target = target,
        .optimize = optimize,
    }).module("nice_args");

    const lma = b.createModule(.{
        .root_source_file = b.path("src/lma/lma.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });

    docs(b, lma);

    const filter_option = b.option([]const u8, "test-filter", "Select a subset of tests to run");
    const lma_tests = b.addTest(.{
        .root_module = lma,
        .filters = if (filter_option) |filter| &.{filter} else &.{},
    });

    const run_lma_tests = b.addRunArtifact(lma_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lma_tests.step);

    parserExe(b, b.addExecutable(.{
        .name = "parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .module = lma, .name = "lma" },
                .{ .module = nargs, .name = "nargs" },
            },
            .single_threaded = single_threaded,
        }),
    }));

    matchExe(b, b.addExecutable(.{
        .name = "match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/match-toa/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .module = lma, .name = "lma" },
                .{ .module = nargs, .name = "nargs" },
            },
            .single_threaded = single_threaded,
        }),
    }));

    holesExe(b, b.addExecutable(.{
        .name = "holes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lholes/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .module = lma, .name = "lma" },
                .{ .module = nargs, .name = "nargs" },
            },
        }),
    }));
}

const DateTime = struct {
    date: [6]u8,
    time: [6]u8,

    pub fn addOption(b: *std.Build) ?DateTime {
        const input = b.option([]const u8, "date", "Date to use as input in the format 'YYMMDD-HHMMSS'") orelse return null;
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
        none,
        toa,
        points,
        clusters,
        all,
    };

    pub fn init(options: BuildOptions) ParseStage {
        return switch (options) {
            .none => .{},
            .toa => .{ .toa = true },
            .points => .{ .points = true },
            .clusters => .{ .clusters = true },
            .all => .{ .toa = true, .points = true, .clusters = true },
        };
    }

    toa: bool = false,
    points: bool = false,
    clusters: bool = false,
};

fn docs(b: *std.Build, module: *std.Build.Module) void {
    const install_docs = b.addInstallDirectory(.{
        .source_dir = b.addLibrary(.{ .name = "lma", .root_module = module }).getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}

fn parserExe(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const step = b.step(
        "parser",
        "Parse the selected files and generate the corresponding '.bin' and '.csv' files",
    );

    step.dependOn(if (emit_bin) &b.addInstallArtifact(exe, .{}).step else &exe.step);
    b.getInstallStep().dependOn(step);

    // DEMO
    const stage: ParseStage = .init(b.option(
        ParseStage.BuildOptions,
        "stage",
        "Stage to parse, generating the corresponding '.bin' and '.csv' files.",
    ) orelse .none);

    if (maybe_date_time) |date_time| {
        if (stage.toa) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-i=data/ToA/" ++ date_time.date ++ "/sources", "toa" });
            step.dependOn(&run.step);
        }
        if (stage.points) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-i=data/points/" ++ date_time.date ++ "/output", "points", "-s=data/ToA/stations" });
            step.dependOn(&run.step);
        }
        if (stage.clusters) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-i=data/lightnings/" ++ date_time.date ++ "/XCALMA_" ++ date_time.date ++ ".csv", "clusters" });
            step.dependOn(&run.step);
        }
    }
}

fn holesExe(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const step = b.step("holes", "Showcase of the hole detection functionality.");
    step.dependOn(if (emit_bin) &b.addInstallArtifact(exe, .{}).step else &exe.step);
    b.getInstallStep().dependOn(step);

    // DEMO
    if (maybe_date_time) |date_time| {
        const run_demo_grid = b.addRunArtifact(exe);
        run_demo_grid.addArgs(&.{
            "--region=catalunya",
            "-r=high",
            "-i=data/lightnings/" ++ date_time.date ++ "/bin",
            "--cat-map",
            "--ffmpeg",
        });
        step.dependOn(&run_demo_grid.step);
    }
}

fn matchExe(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const step = b.step("match", "Match a set of station data '.bin' files and locate the sources using time of arrival.");
    step.dependOn(if (emit_bin) &b.addInstallArtifact(exe, .{}).step else &exe.step);
    b.getInstallStep().dependOn(step);

    // DEMO
    if (maybe_date_time) |date_time| {
        const run_match = b.addRunArtifact(exe);
        run_match.addArgs(&.{
            "-w=const+decibels",
            "-s=data/ToA/stations/stations.bin",
            "-i=data/ToA/" ++ date_time.date ++ "/bin/*_*_*_" ++ date_time.date ++ "_" ++ date_time.time ++ ".bin",
            "-o=data/points/" ++ date_time.date ++ "/csv/corr-" ++ date_time.time[0..2] ++ "h-" ++ date_time.time[2..4] ++ "min-" ++ date_time.time[4..6] ++ "s.csv",
            "-d=data/points/" ++ date_time.date ++ "/output/CUSTOM_" ++ date_time.date ++ "_" ++ date_time.time ++ "_0600.dat",
        });
        step.dependOn(&run_match.step);
    }
}
