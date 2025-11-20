const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const args = b.dependency("args", .{
        .target = target,
        .optimize = optimize,
    }).module("args");

    const zlm = b.dependency("zlm", .{
        .target = target,
        .optimize = optimize,
    }).module("zlm");

    const lma = b.createModule(.{
        .root_source_file = b.path("src/lma/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = zlm, .name = "zlm" },
        },
    });

    parserExe(b, .{
        .root_source_file = b.path("src/parser/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = lma, .name = "lma" },
            .{ .module = args, .name = "args" },
        },
    });

    const filter_option = b.option([]const u8, "test-filter", "Select a subset of tests to run");
    const lma_tests = b.addTest(.{
        .root_module = lma,
        .filters = if (filter_option) |filter| &.{filter} else &.{},
    });

    const run_lma_tests = b.addRunArtifact(lma_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lma_tests.step);

    demoGrid(b, .{
        .root_source_file = b.path("src/demo/grid.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .module = lma, .name = "lma" },
            .{ .module = zlm, .name = "zlm" },
            .{ .module = args, .name = "args" },
        },
    });
}

fn parserExe(b: *std.Build, options: std.Build.Module.CreateOptions) void {
    const parser_targets: ParserTargets = .{
        .toa = b.option(
            bool,
            "parse-toa",
            "Parse the '.dat' ToA files and generate the corresponding '.bin' and '.csv' files",
        ),

        .points = b.option(
            bool,
            "parse-points",
            "Parse the '.dat' points file and generate the corresponding '.bin' and '.csv' files",
        ),

        .clusters = b.option(
            bool,
            "parse-clusters",
            "Parse the '.csv' clustered file and generate the corresponding chunked '.bin' and '.csv' files",
        ),
    };
    const parse_all = b.option(
        bool,
        "parse-all",
        "Equivalent to setting all parse options to this value. Doesn't override the parse options already specified",
    );

    const parser = b.addExecutable(.{
        .name = "parser",
        .root_module = b.createModule(options),
    });
    const parser_step = b.step(
        "parser",
        "Parse the selected files and generate the corresponding '.bin' and '.csv' files",
    );
    const default = parse_all orelse if (parser_targets.any_set()) !parser_targets.any_true(false) else false;
    parser_targets.add_targets(b, parser, parser_step, default);
}

const ParserTargets = struct {
    toa: ?bool,
    points: ?bool,
    clusters: ?bool,

    pub fn any_set(self: ParserTargets) bool {
        return (self.toa != null) or (self.points != null) or (self.clusters != null);
    }

    pub fn any_true(self: ParserTargets, default: bool) bool {
        return (self.toa orelse default) or (self.points orelse default) or (self.clusters orelse default);
    }

    pub fn add_targets(
        self: ParserTargets,
        b: *std.Build,
        exe: *std.Build.Step.Compile,
        step: *std.Build.Step,
        default: bool,
    ) void {
        if (self.toa orelse default) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-i", "data/ToA/250712/sources", "toa" });
            step.dependOn(&run.step);
        }
        if (self.points orelse default) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-i", "data/points/250712/output", "points", "-s", "data/ToA/stations" });
            step.dependOn(&run.step);
        }
        if (self.clusters orelse default) {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-i", "data/lightnings/250712/XCALMA_250712.csv", "clusters" });
            step.dependOn(&run.step);
        }
        const install = b.addInstallArtifact(exe, .{});
        step.dependOn(&install.step);
    }
};

fn demoGrid(b: *std.Build, options: std.Build.Module.CreateOptions) void {
    const demo_grid = b.addExecutable(.{
        .name = "demo-grid",
        .root_module = b.createModule(options),
    });
    const install = b.addInstallArtifact(demo_grid, .{});
    const run_demo_grid = b.addRunArtifact(demo_grid);
    run_demo_grid.addArgs(&.{ "42.11", "1.84", "-i", "data/lightnings/240802/bin" });
    const demo_grid_step = b.step("demo-grid", "Run the demo for the grid basic functionality");
    demo_grid_step.dependOn(&run_demo_grid.step);
    demo_grid_step.dependOn(&install.step);
}
