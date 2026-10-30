const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("lma");
const Signal = lma.data.Signal;
const Point = lma.data.Point;
const Station = lma.data.Station;
const nargs = @import("nargs");

pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

pub const WriteError = error{ WriteFailed, InvalidExtension };

const Compression = enum { gz, GZ, gzip, GZIP };

const err_msg = struct {
    const parsing = "Failed to parse {s} file {q}. ({})";
    const unpacking = "Failed to unpack {s} file {q}. ({})";
    const extension = "Unrecongnized file extension {q} for {s} file {q}.";
    const oom = "Ran out of memory while reading {s} file {s}.";
};

fn FnArgs(Fn: type, comptime start: comptime_int) type {
    const maybe_args = @typeInfo(Fn).@"fn".param_types[start..];
    var args: [maybe_args.len]type = undefined;
    for (maybe_args, &args) |maybe_arg, *arg| arg.* = maybe_arg.?;
    return @Tuple(&args);
}

pub const stations = struct {
    const file_type = "station/network";
    pub fn readAppend(list: *Station.List, file_name: []const u8, r: *Reader, date: []const u8) error{ Logged, ReadFailed }!void {
        const extension = std.fs.path.extension(file_name);
        if (std.ascii.eqlIgnoreCase(extension, ".csv"))
            try readAppendCall(list, r, file_name, Station.csv.read, .{null})
        else if (std.ascii.eqlIgnoreCase(extension, ".gps"))
            try readAppendCall(list, r, file_name, Station.gps.read, .{date})
        else if (std.ascii.eqlIgnoreCase(extension, ".loc"))
            try readAppendCall(list, r, file_name, Station.fromLoc, .{})
        else {
            std.log.warn(err_msg.extension, .{ extension, file_type, file_name });
            return error.Logged;
        }
    }

    fn readAppendCall(list: *Station.List, r: *Reader, file_name: []const u8, func: anytype, args: FnArgs(@TypeOf(func), 2)) error{ Logged, ReadFailed }!void {
        @call(.auto, func, .{ list, r } ++ args) catch |e| switch (e) {
            error.ReadFailed => |err| return err,
            error.OutOfMemory => {
                std.log.err(err_msg.oom, .{ file_type, file_name });
                @panic("OOM");
            },
            else => |err| {
                std.log.err(err_msg.parsing, .{ file_type, file_name, err });
                return error.Logged;
            },
        };
    }
};

pub const signals = struct {
    const file_type = "signal";
    pub fn read(list: *Signal.List, file_name: []const u8, r: *Reader) error{ Logged, ReadFailed }!void {
        std.debug.assert(list.headers.items.len == 0);
        std.debug.assert(list.array.items.len == 0);

        try innerRead(list, file_name, r, true);
    }

    fn innerRead(list: *Signal.List, file_name: []const u8, r: *Reader, comptime gzip: bool) error{ Logged, ReadFailed }!void {
        std.debug.assert(list.headers.items.len == 0);
        std.debug.assert(list.array.items.len == 0);

        const extension = std.fs.path.extension(file_name);
        if (gzip and
            (std.ascii.eqlIgnoreCase(extension, ".gz") or
                std.ascii.eqlIgnoreCase(extension, ".gzip")))
        {
            var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate: std.compress.flate.Decompress = .init(r, .gzip, &gzip_buffer);

            return innerRead(list, std.fs.path.stem(file_name), &flate.reader, false) catch |e| switch (e) {
                error.Logged => |err| return err,
                error.ReadFailed => {
                    switch (flate.err.?) {
                        error.ReadFailed => |err| return err,
                        else => |err| {
                            std.log.err(err_msg.unpacking, .{ file_type, file_name, err });
                            return error.Logged;
                        },
                    }
                },
            };
        } else if (std.ascii.eqlIgnoreCase(extension, ".dat"))
            try readCall(list, r, file_name, Signal.dat.read, .{.{}})
        else if (std.ascii.eqlIgnoreCase(extension, ".bin"))
            try readCall(list, r, file_name, Signal.bin.read, .{})
        else if (std.ascii.eqlIgnoreCase(extension, ".csv"))
            try readCall(list, r, file_name, Signal.csv.read, .{null})
        else {
            std.log.warn(err_msg.extension, .{ extension, file_type, file_name });
            return error.Logged;
        }
    }

    fn readCall(list: *Signal.List, r: *Reader, file_name: []const u8, func: anytype, args: FnArgs(@TypeOf(func), 2)) error{ Logged, ReadFailed }!void {
        @call(.auto, func, .{ list, r } ++ args) catch |e| switch (e) {
            error.ReadFailed => |err| return err,
            error.OutOfMemory => {
                std.log.err(err_msg.oom, .{ file_type, file_name });
                @panic("OOM");
            },
            else => |err| {
                std.log.err(err_msg.parsing, .{ "station/network", file_name, err });
                return error.Logged;
            },
        };
    }
};

pub const points = struct {
    const file_type = "points";
    pub fn write(list: *Point.List, w: *Writer, file_name: []const u8, extra: Extra) error{ Logged, WriteFailed }!void {
        try innerWrite(list, w, file_name, extra, true);
    }

    fn innerWrite(list: *Point.List, w: *Writer, file_name: []const u8, extra: Extra, comptime gzip: bool) error{ Logged, WriteFailed }!void {
        const extension = std.fs.path.extension(file_name);
        if (gzip and
            (std.ascii.eqlIgnoreCase(extension, ".gz") or
                std.ascii.eqlIgnoreCase(extension, ".gzip")))
        {
            var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate: std.compress.flate.Compress = try .init(w, &gzip_buffer, .gzip, .default);

            innerWrite(list, &flate.writer, std.fs.path.stem(file_name), extra, false) catch |e| switch (e) {
                error.Logged => |err| return err,
                // error.WriteFailed is always due to the backing writer
                error.WriteFailed => return error.WriteFailed,
            };
            try flate.finish();
            try w.flush();
        } else if (std.ascii.eqlIgnoreCase(extension, ".dat"))
            try writeCall(list, w, file_name, Point.dat.write, .{extra.dat})
        else if (std.ascii.eqlIgnoreCase(extension, ".bin"))
            try writeCall(list, w, file_name, Point.bin.write, .{})
        else if (std.ascii.eqlIgnoreCase(extension, ".csv"))
            try writeCall(list, w, file_name, Point.csv.write, .{null})
        else {
            std.log.warn(err_msg.extension, .{ extension, file_type, file_name });
            return error.Logged;
        }
    }

    fn writeCall(list: *Point.List, w: *Writer, file_name: []const u8, func: anytype, args: FnArgs(@TypeOf(func), 2)) error{ Logged, WriteFailed }!void {
        _ = file_name;

        @call(.auto, func, .{ list, w } ++ args) catch |e| switch (e) {
            error.WriteFailed => |err| return err,
        };
    }

    pub const Extra = struct {
        dat: lma.data.dat_file.output.WriteHeader,
    };
};
