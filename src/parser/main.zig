const std = @import("std");
const builtin = @import("builtin");
const nargs = @import("nargs");
const opt = nargs.options;

const signals = @import("signals.zig");
const points = @import("points.zig");
const clusters = @import("clusters.zig");

const Cli = struct { path: []const u8, command: union(enum) { signals: signals.Cli, points: points.Cli, clusters: clusters.Cli } };
const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "parser" }, .{
    .path = .build(opt.Named, .single(.string, .{ .name = "input", .description = "Input file to transform.", .short = .auto })),
    .command = .build(opt.Groups, .subcommand(.{ .name = "STAGE", .greedy = false }, .{
        .signals = signals.root,
        .points = points.root,
        .clusters = clusters.root,
    })),
}));

pub fn main(init: std.process.Init) !void {
    var options: Cli = undefined;
    {
        var tokenizer: nargs.Tokenizer = try .initFromArgs(init.gpa, init.minimal.args);
        defer tokenizer.deinit();
        var diag: nargs.Diagnostic = .init(init.gpa, .default);
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
            var stdout = std.Io.File.stdout().writer(init.io, &help_buf);
            nargs.Help.print(.{ .info = root.info }, .fancy, &stdout.interface) catch {};
            stdout.flush() catch {};
            return;
        }

        try root.init(&mem, &diag, init.gpa, &options);
    }
    defer root.deinit(init.gpa, &options);

    switch (options.command) {
        .signals => |specific| try signals.parse(init.io, init.gpa, options.path, specific),
        .points => |specific| try points.parse(init.io, init.gpa, options.path, specific),
        .clusters => |specific| try clusters.parse(init.io, init.gpa, options.path, specific),
    }
}
