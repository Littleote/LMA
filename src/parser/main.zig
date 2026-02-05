const std = @import("std");
const builtin = @import("builtin");
const nargs = @import("nargs");

const toa = @import("toa.zig");
const points = @import("points.zig");
const clusters = @import("clusters.zig");

pub const root = nargs.groups.any("PARSER", .{
    .path = nargs.params.param("input", nargs.types.string, .single, .{ .short = .auto }),
    .command = nargs.groups.subcommand("STAGE", .{
        .toa = toa.root,
        .points = points.root,
        .clusters = clusters.root,
    }, true, .read_any(null)),
});

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
        .toa => |specific| try toa.parse(init.io, init.gpa, options.path, specific),
        .points => |specific| try points.parse(init.io, init.gpa, options.path, specific),
        .clusters => |specific| try clusters.parse(init.io, init.gpa, options.path, specific),
    }
}
