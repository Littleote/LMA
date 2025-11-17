const std = @import("std");
const builtin = @import("builtin");
const args = @import("args");

const toa = @import("toa.zig");
const points = @import("points.zig");
const clusters = @import("clusters.zig");

pub fn main() !void {
    const Allocator = if (builtin.mode == std.builtin.OptimizeMode.Debug) std.heap.DebugAllocator(.{}) else std.heap.GeneralPurposeAllocator(.{});
    var allocator: Allocator = .init;
    const gpa = allocator.allocator();
    defer _ = allocator.deinit();

    const options = args.parseWithVerbForCurrentProcess(
        struct {
            input: ?[]const u8 = null,

            pub const shorthands = .{
                .i = "input",
            };
        },
        union(enum) {
            toa: struct {},
            points: points.Args,
            clusters: clusters.Args,
        },
        gpa,
        .print,
    ) catch return;
    defer options.deinit();

    if (options.options.input == null) @panic("Missing input field");
    if (options.verb == null) @panic("Missing subcommand field");

    switch (options.verb.?) {
        .toa => try toa.parse(gpa, options.options.input.?),
        .points => |*specific| try points.parse(gpa, options.options.input.?, specific),
        .clusters => |*specific| try clusters.parse(gpa, options.options.input.?, specific),
    }
}
