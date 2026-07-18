const std = @import("std");
const Allocator = std.mem.Allocator;
const nargs = @import("nargs");
const Error = nargs.components.ValueError;
const Value = nargs.Value;

pub const Date = struct {
    const sep: u8 = '/';
    const mixin = Value(Type).mixin;

    pub fn parse(_: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Error!Type {
        return initInner(buf) catch |err| switch (err) {
            error.InvalidFormat => {
                diag.startLogWithMessage(.invalid_value,
                    \\Expected a date in format YYYYMMDD, YYMMDD or (YY)YY/(M)M/(D)D but found "{s}" instead.
                , .{buf});
                return error.InvalidValue;
            },
            error.InvalidDate => {
                diag.startLogWithMessage(.invalid_value,
                    \\"{s}" is not a valid date.
                , .{buf});
                return error.InvalidValue;
            },
        };
    }

    pub fn initInner(buf: []const u8) error{ InvalidDate, InvalidFormat }!Type {
        const sep_count = std.mem.countScalar(u8, buf, sep);
        const string: [8]u8 = if (sep_count == 0)
            if (buf.len == 6) blk: {
                var string: [8]u8 = "20YYMMDD".*;
                string[2..8].* = buf[0..6].*;
                break :blk string;
            } else if (buf.len == 8) buf[0..8].* else return error.InvalidFormat
        else if (sep_count == 2) blk: {
            var string: [8]u8 = "20YY0M0D".*;
            var iter = std.mem.splitScalar(u8, buf, sep);
            const year = iter.next().?;
            if (year.len < 2 or 4 < year.len) return error.InvalidFormat;
            @memcpy(string[4 - year.len ..][0..year.len], year);
            const month = iter.next().?;
            if (month.len < 1 or 2 < month.len) return error.InvalidFormat;
            @memcpy(string[6 - month.len ..][0..month.len], month);
            const day = iter.next().?;
            if (day.len < 1 or 2 < day.len) return error.InvalidFormat;
            @memcpy(string[8 - day.len ..][0..day.len], day);

            break :blk string;
        } else return error.InvalidFormat;

        return .init(string);
    }

    pub const dupe = mixin.copyOnDupe;
    pub const deinit = mixin.noDeinit;

    pub fn format(date: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}/{d}/{d}", .{ date.year, date.month, date.day });
    }

    pub const Type = struct {
        year: u16,
        month: u8,
        day: u8,
        string: [8]u8,

        pub fn init(string: [8]u8) error{InvalidDate}!Type {
            return .{
                .year = std.fmt.parseInt(u16, string[0..4], 10) catch return error.InvalidDate,
                .month = std.fmt.parseInt(u8, string[4..6], 10) catch return error.InvalidDate,
                .day = std.fmt.parseInt(u8, string[6..8], 10) catch return error.InvalidDate,
                .string = string,
            };
        }
    };
    pub const side_effects: nargs.Value.SideEffects = .none;
    pub const display: []const u8 = "DATE";
    pub const help: ?[]const u8 = null;
};

pub const Time = struct {
    const sep: u8 = ':';
    const mixin = Value(Type).mixin;

    pub fn parse(_: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Error!Type {
        return initInner(buf) catch |err| switch (err) {
            error.InvalidFormat => {
                diag.startLogWithMessage(.invalid_value,
                    \\Expected time in format HHMMSS or HH:MM:SS but found "{s}" instead.
                , .{buf});
                return error.InvalidValue;
            },
            error.InvalidTime => {
                diag.startLogWithMessage(.invalid_value,
                    \\"{s}" is not a valid time.
                , .{buf});
                return error.InvalidValue;
            },
        };
    }

    pub fn initInner(buf: []const u8) error{ InvalidTime, InvalidFormat }!Type {
        const sep_count = std.mem.countScalar(u8, buf, sep);
        const string: [6]u8 = if (sep_count == 0 and buf.len == 6)
            buf[0..6].*
        else if (sep_count == 2 and buf.len == 8 and buf[2] == sep and buf[5] == sep) blk: {
            var string: [6]u8 = undefined;
            string[0..2].* = buf[0..2].*;
            string[2..4].* = buf[3..5].*;
            string[4..6].* = buf[6..8].*;
            break :blk string;
        } else return error.InvalidFormat;

        return .init(string);
    }

    pub const dupe = mixin.copyOnDupe;
    pub const deinit = mixin.noDeinit;

    pub fn format(date: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ date.hour, date.minute, date.second });
    }

    pub const Type = struct {
        hour: u8,
        minute: u8,
        second: u8,
        string: [6]u8,

        pub fn init(string: [6]u8) error{InvalidTime}!Type {
            return .{
                .hour = std.fmt.parseInt(u8, string[0..2], 10) catch return error.InvalidTime,
                .minute = std.fmt.parseInt(u8, string[2..4], 10) catch return error.InvalidTime,
                .second = std.fmt.parseInt(u8, string[4..6], 10) catch return error.InvalidTime,
                .string = string,
            };
        }

        pub fn toSeconds(self: Type) u32 {
            return (@as(u32, self.hour) * 60 + self.minute) * 60 + self.second;
        }
    };
    pub const side_effects: nargs.Value.SideEffects = .none;
    pub const display: []const u8 = "TIME";
    pub const help: ?[]const u8 = null;
};
pub const Seconds = struct {
    const sep: u8 = ':';
    const mixin = Value(Type).mixin;

    pub fn parse(_: Allocator, buf: []const u8, diag: *nargs.Diagnostic) Error!Type {
        return initInner(buf) catch |err| switch (err) {
            error.InvalidTime => {
                diag.startLogWithMessage(.invalid_value,
                    \\"{s}" is not a valid time.
                , .{buf});
                return error.InvalidValue;
            },
        };
    }

    pub fn initInner(buf: []const u8) error{InvalidTime}!Type {
        const sep_count = std.mem.countScalar(u8, buf, sep);
        if (sep_count == 0) {
            return std.fmt.parseInt(u32, buf, 10) catch return error.InvalidTime;
        } else if (sep_count <= 2) {
            var seconds: u32 = 0;
            var iter = std.mem.splitScalar(u8, buf, sep);
            while (iter.next()) |str| {
                seconds *= 60;
                seconds += std.fmt.parseInt(u32, str, 10) catch return error.InvalidTime;
            }
            return seconds;
        }
        return error.InvalidTime;
    }

    pub const dupe = mixin.copyOnDupe;
    pub const deinit = mixin.noDeinit;

    pub fn format(seconds: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ seconds / 3600, (seconds / 60) % 60, seconds % 60 });
    }

    pub const Type = u32;
    pub const side_effects: nargs.Value.SideEffects = .none;
    pub const display: []const u8 = "DATE";
    pub const help: ?[]const u8 = null;
};
