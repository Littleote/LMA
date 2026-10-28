const std = @import("std");
const builtin = @import("builtin");
const nargs = @import("nargs");
const opt = nargs.options;

const Cli = struct {
    test_name: []const []const u8,
    test_stdout: []const []const u8,

    table_output: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, args: std.process.Args) error{ParseFailure}!?Cli {
        var buffer: [128]u8 = undefined;
        var tokenizer = nargs.Tokenizer.initFromArgs(gpa, args, true) catch @panic("OOM");
        defer tokenizer.deinit();
        var diag: nargs.Diagnostic = .init(gpa, .{
            .continue_on_error = true,
            .log_errors = true,
            .special_flags = .init(.{
                .help = nargs.Diagnostic.Config.token_list.help,
                .version = &.{},
            }),
        });
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
        } else if (diag.special_flags.get(.version)) unreachable;

        var out: Cli = undefined;
        root.init(&mem, &diag, gpa, &out) catch {};
        if (diag.error_list.items.len > 0) {
            for (diag.error_list.items) |info| {
                std.log.err("{f}", .{info});
            }
            std.log.info("Use \"mstats --help\" to see available options.", .{});
            return error.ParseFailure;
        } else return out;
    }

    pub fn deinit(self: *Cli, gpa: std.mem.Allocator) void {
        root.deinit(gpa, self);
    }
};

const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "stats" }, .{
    .test_name = .build(opt.Named, .variable(.string, .{ .min = 1 }, .{ .name = "name", .description = "Name of a test." })),
    .test_stdout = .build(opt.Named, .variable(.string, .{ .min = 1 }, .{ .name = "stdout", .description = "Files with the stdout of a test." })),
    .table_output = .build(opt.Named, .single(.string, .{ .name = "output", .description = "Output file." })),
}));

pub fn main(init: std.process.Init) !void {
    var r_buffer: [1024]u8 = undefined;
    var w_buffer: [1024]u8 = undefined;

    var options = Cli.init(init.gpa, init.io, init.minimal.args) catch
        std.process.exit(1) orelse
        return;
    defer options.deinit(init.gpa);

    const file_out = try std.Io.Dir.cwd().createFile(init.io, options.table_output, .{});
    defer file_out.close(init.io);
    var out = file_out.writer(init.io, &w_buffer);

    try out.interface.writeAll(
        \\Config, Search tests, Memory tests, Valid by linear, Valid by quadratic, Valid solution, Wall time, Process time
        \\
    );

    for (options.test_stdout, options.test_name) |stdout, name| {
        const file = try std.Io.Dir.cwd().openFile(init.io, stdout, .{});
        defer file.close(init.io);
        var file_reader = file.reader(init.io, &r_buffer);

        try out.interface.writeAll(name);
        while (try file_reader.interface.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "Variable")) {
                if (std.mem.find(u8, line, "solve_") != null) continue;
                _, const variable = std.mem.cutScalarLast(u8, line, '=') orelse {
                    std.log.err("unexpected line:\n{q}", .{line});
                    return error.ParseFailed;
                };
                try out.interface.print(", {s}", .{std.mem.trim(u8, variable, " ")});
            }
            if (std.mem.find(u8, line, " time:") != null) {
                _, const variable = std.mem.cutScalarLast(u8, line, ':') orelse {
                    std.log.err("unexpected line:\n{q}", .{line});
                    return error.ParseFailed;
                };
                try out.interface.print(", {s}", .{std.mem.trim(u8, variable, " s")});
            }
        }
        try out.interface.writeByte('\n');
    }

    try out.flush();
}
