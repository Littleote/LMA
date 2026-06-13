const std = @import("std");
const builtin = @import("builtin");
const nargs = @import("nargs");

const signals = @import("signals.zig");
const points = @import("points.zig");
const clusters = @import("clusters.zig");

pub const root: nargs.Node = .wrap(nargs.groups.Any(.{ .name = "PARSER" }, &.{
    .set("path", .wrap(nargs.args.param.Single(.string, .{ .name = "input", .short = .auto }))),
    .set("command", .wrap(nargs.groups.SubCommand(.{ .name = "STAGE", .greedy = false }, &.{
        .set("signals", signals.root),
        .set("points", points.root),
        .set("clusters", clusters.root),
    }))),
}));

pub fn main(init: std.process.Init) !void {
    const ctx = .{ .allocator = init.gpa };
    var options = blk: {
        var args: nargs.Args = .init(init.gpa);
        defer args.deinit();
        try args.appendArguments(init.minimal.args);
        break :blk try args.parseAndCreate(init.io, ctx, root);
    };
    defer root.destroy(ctx, &options);

    switch (options.command) {
        .signals => |specific| try signals.parse(init.io, init.gpa, options.path, specific),
        .points => |specific| try points.parse(init.io, init.gpa, options.path, specific),
        .clusters => |specific| try clusters.parse(init.io, init.gpa, options.path, specific),
    }
}
