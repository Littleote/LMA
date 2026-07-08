const std = @import("std");
const builtin = @import("builtin");
const nargs = @import("nargs");

const signals = @import("signals.zig");
const points = @import("points.zig");
const clusters = @import("clusters.zig");

pub const root: nargs.Node = .wrap(nargs.groups.Any(.{ .name = "PARSER" }, &.{
    .set("path", .wrap(nargs.args.param.Single(.string, .{ .name = "input", .description = "Input file to transform.", .short = .auto }))),
    .set("command", .wrap(nargs.groups.SubCommand(.{ .name = "STAGE", .greedy = false }, &.{
        .set("signals", signals.root),
        .set("points", points.root),
        .set("clusters", clusters.root),
    }))),
}));

pub fn main(init: std.process.Init) !void {
    const ctx = .{ .allocator = init.gpa };
    const Options = root.Parsed(null);
    var options: Options = undefined;
    {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const args = try init.minimal.args.toSlice(arena.allocator());

        var tokenizer: nargs.Tokenizer = .initFromStatic(args[1..]);
        var diag: nargs.Diagnostic = .init(init.gpa, .{});
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
            var stdout = std.Io.File.stdout().writer(init.io, &help_buf);
            try stdout.interface.print("{f}\n", .{std.fmt.Alt([]const nargs.Node.Help, nargs.Node.Help.format){ .data = root.help_info }});
            try stdout.flush();
            return;
        }

        try root.init(Options, &mem, &diag, ctx, &options);
    }
    defer root.deinit(Options, ctx, &options);

    switch (options.command) {
        .signals => |specific| try signals.parse(init.io, init.gpa, options.path, specific),
        .points => |specific| try points.parse(init.io, init.gpa, options.path, specific),
        .clusters => |specific| try clusters.parse(init.io, init.gpa, options.path, specific),
    }
}
