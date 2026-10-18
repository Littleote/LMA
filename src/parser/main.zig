const std = @import("std");
const builtin = @import("builtin");
const nargs = @import("nargs");
const opt = nargs.options;

const signals = @import("signals.zig");
const points = @import("points.zig");
const clusters = @import("clusters.zig");
const stations = @import("stations.zig");

const parser_info = @import("info.zon");

const Cli = struct {
    command: union(enum) {
        signals: signals.Cli,
        points: points.Cli,
        clusters: clusters.Cli,
        stations: stations.Cli,
    },

    pub fn init(gpa: std.mem.Allocator, io: std.Io, args: std.process.Args) error{ParseFailure}!?Cli {
        var buffer: [128]u8 = undefined;
        var tokenizer = nargs.Tokenizer.initFromArgs(gpa, args, true) catch @panic("OOM");
        defer tokenizer.deinit();
        var diag: nargs.Diagnostic = .init(gpa, .default);
        defer diag.deinit();

        var mem = root.initMemory().*;
        while (tokenizer.peek()) |token| {
            if (root.parse(&mem, &tokenizer, &diag) == .no_match) {
                tokenizer.discardAssumeToken();
                diag.log(.unused_token, "", token);
            }
        }

        if (diag.special_flags.get(.help)) {
            var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
            nargs.Help.print(.{ .info = root.info }, .fancy, &stdout.interface) catch {};
            stdout.flush() catch {};
            return null;
        } else if (diag.special_flags.get(.version)) {
            var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
            stdout.interface.print("{s} version {s}\n", .{ parser_info.name, parser_info.version }) catch {};
            stdout.flush() catch {};
            return null;
        }

        var out: Cli = undefined;
        root.init(&mem, &diag, gpa, &out) catch {};
        if (diag.error_list.items.len > 0) {
            for (diag.error_list.items) |info| {
                std.log.err("{f}", .{info});
            }
            std.log.info(
                "Use \"{s} {f}\" to see available options.",
                .{ parser_info.name, diag.config.special_flags.get(.help)[0] },
            );
            return error.ParseFailure;
        } else return out;
    }

    pub fn deinit(self: *Cli, gpa: std.mem.Allocator) void {
        root.deinit(gpa, self);
    }
};

const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "parser" }, .{
    .command = .build(opt.Groups, .subcommand(.{ .name = "STAGE", .greedy = false }, .{
        .signals = signals.root,
        .points = points.root,
        .clusters = clusters.root,
        .stations = stations.root,
    })),
}));

pub fn main(init: std.process.Init) !void {
    var options = Cli.init(init.gpa, init.io, init.minimal.args) catch
        std.process.exit(1) orelse
        return;
    defer options.deinit(init.gpa);

    switch (options.command) {
        .signals => |args| try signals.parse(init.io, init.gpa, args),
        .points => |args| try points.parse(init.io, init.gpa, args),
        .clusters => |args| try clusters.parse(init.io, init.gpa, args),
        .stations => |args| try stations.parse(init.io, init.gpa, args),
    }
}
