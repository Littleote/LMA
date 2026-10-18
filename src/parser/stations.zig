const std = @import("std");
const Allocator = std.mem.Allocator;

const lma = @import("lma");
const Station = lma.data.Station;
const nargs = @import("nargs");
const opt = nargs.options;

const utils = @import("utils.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .level = .debug, .scope = lma.log.scopes.station_file },
    },
};

pub const Network = union(enum) {
    const Value = nargs.Value(@This());

    id: Station.Id,
    name: []const u8,

    pub fn format(self: Network, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .id => |id| try w.print("id:{d}", .{@backingInt(id)}),
            .name => |name| try w.print("name:{s}", .{name}),
        }
    }

    const Parser = struct {
        fn parse(gpa: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Value.Error!Network {
            const mode, const value = std.mem.cutScalar(u8, buf, ':') orelse {
                diag.log(.invalid_value_reason,
                    \\Expected value in the form "id:{{ID}}" or "name:{{NAME}}", but found {q} instead.
                , .{buf});
                return error.InvalidValue;
            };
            if (std.mem.eql(u8, "id", mode)) {
                return if (std.fmt.parseInt(u8, value, 10)) |id|
                    .{ .id = @fromBackingInt(id) }
                else |_| {
                    diag.log(.invalid_value_reason,
                        \\Value {q} is not a valid network ID.
                    , .{value});
                    return error.InvalidValue;
                };
            } else if (std.mem.eql(u8, "name", mode)) {
                return .{ .name = try gpa.dupe(u8, value) };
            } else {
                diag.log(.invalid_value_reason,
                    \\Expected value in the form "id:{{ID}}" or "name:{{NAME}}", but {q} does not match any.
                , .{mode});
                return error.InvalidValue;
            }
        }

        fn copy(gpa: Allocator, other: *const Network) Allocator.Error!Network {
            return switch (other.*) {
                .id => |id| .{ .id = id },
                .name => |name| .{ .name = try gpa.dupe(u8, name) },
            };
        }

        fn deinit(gpa: Allocator, value: *Network) void {
            return switch (value.*) {
                .id => {},
                .name => |name| gpa.free(name),
            };
        }
    };

    pub const parser: Value = .{
        .parse = Parser.parse,
        .dupe = Parser.copy,
        .deinit = Parser.deinit,
        .format = format,
        .display = "NETWORK",
        .help =
        \\Network specified as either "id:{ID}" or "name:{NAME}".
        ,
    };
};

pub const Cli = struct {
    inputs: []const []const u8,
    output: []const u8,
    subset: ?[]const Network,
};

pub const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "stations" }, .{
    .inputs = .build(opt.Named, .variable(.string, .{ .min = 1 }, .{ .name = "input", .description = "Input staion/network files.", .short = .auto })),
    .output = .build(opt.Named, .single(.string, .{ .name = "output", .description = "Output staion/network '.csv' file.", .short = .auto })),
    .subset = .optional(
        .{ .default = "All networks." },
        .build(opt.Named, .variable(Network.parser, .{ .min = 1 }, .{ .name = "subset", .description = "Subset of networks to extract.", .short = .auto })),
    ),
}));

pub fn parse(io: std.Io, gpa: std.mem.Allocator, args: Cli) !void {
    var rw_buffer: [1024]u8 = undefined;

    var list: Station.List = .init(gpa);
    defer list.deinit();

    for (args.inputs) |file| {
        const Extensions = enum { @".csv", @".gps", @".loc" };
        const extension = std.meta.stringToEnum(Extensions, std.fs.path.extension(file)) orelse return error.InvalidExtension;
        const input = try std.Io.Dir.cwd().openFile(io, file, .{});
        var file_reader = input.reader(io, &rw_buffer);
        switch (extension) {
            .@".csv" => try Station.csv.read(&list, &file_reader.interface, null),
            .@".gps" => try Station.fromGps(&list, &file_reader.interface),
            .@".loc" => try Station.fromLoc(&list, &file_reader.interface),
        }
    }

    var idx: usize = 0;
    if (args.subset) |subset| while (idx < list.stations.items.len) {
        for (subset) |net| {
            const id = switch (net) {
                .id => |id| id,
                .name => |name| (list.findNetworkName(name) orelse continue).id,
            };
            if (list.stations.items[idx].network_id == id) break;
        } else {
            _ = list.stations.orderedRemove(idx);
            continue;
        }
        idx += 1;
    };

    const output = try std.Io.Dir.cwd().createFile(io, args.output, .{});
    var file_writer = output.writer(io, &rw_buffer);
    try Station.csv.write(&list, &file_writer.interface, null);
}
