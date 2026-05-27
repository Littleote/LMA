const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("lma");
const nargs = @import("nargs");

pub const ReadError = error{ ReadFailed, InvalidExtension, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };
const ReadErrorOrOOM = ReadError || error{OutOfMemory};

pub const WriteError = error{ WriteFailed, InvalidExtension };

pub fn loadStations(data: *lma.data.Stations, file_name: []const u8, r: *Reader) ReadError!void {
    innerLoadStations(data, std.fs.path.basename(file_name), r, true) catch |err| switch (err) {
        error.OutOfMemory => {
            std.log.err(
                \\Ran out of memory while loading "{s}" station file.
            , .{file_name});
            @panic("OOM");
        },
        else => |new_err| return new_err,
    };
}

inline fn innerLoadStations(data: *lma.data.Stations, basename: []const u8, r: *Reader, comptime allow_compression: bool) ReadErrorOrOOM!void {
    const stem, const suffix = std.mem.cutScalarLast(u8, basename, '.') orelse .{ basename, "" };
    const extension: Extension = .parse(suffix);
    switch (extension) {
        .csv => try data.fromCsv(r, null),
        .bin => try data.fromBin(r),
        .dat => try data.fromDat(r),
        .gz => {
            if (!allow_compression) return error.InvalidExtension;
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate: std.compress.flate.Decompress = .init(r, .gzip, &flate_buffer);
            innerLoadStations(data, stem, &flate.reader, false) catch |err| switch (err) {
                error.ReadFailed => {
                    if (flate.err == null or flate.err.? == error.ReadFailed) return error.ReadFailed;
                    return error.BadFile;
                },
                else => return err,
            };
        },
        .unknown => return error.InvalidExtension,
    }
}

pub fn loadSignals(data: *lma.data.Toa, file_name: []const u8, r: *Reader) ReadError!void {
    innerLoadSignals(data, std.fs.path.basename(file_name), r, true) catch |err| switch (err) {
        error.OutOfMemory => {
            std.log.err(
                \\Ran out of memory while loading "{s}" station file.
            , .{file_name});
            @panic("OOM");
        },
        else => |new_err| return new_err,
    };
}

inline fn innerLoadSignals(data: *lma.data.Toa, basename: []const u8, r: *Reader, comptime allow_compression: bool) ReadErrorOrOOM!void {
    const stem, const suffix = std.mem.cutScalarLast(u8, basename, '.') orelse .{ basename, "" };
    const extension: Extension = .parse(suffix);
    switch (extension) {
        .csv => try data.fromCsv(r, null),
        .bin => try data.fromBin(r),
        .dat => try lma.data.dat_file.toa.fromReader(r, data),
        .gz => {
            if (!allow_compression) return error.InvalidExtension;
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate: std.compress.flate.Decompress = .init(r, .gzip, &flate_buffer);
            innerLoadSignals(data, stem, &flate.reader, false) catch |err| switch (err) {
                error.ReadFailed => {
                    if (flate.err == null or flate.err.? == error.ReadFailed) return error.ReadFailed;
                    return error.BadFile;
                },
                else => return err,
            };
        },
        .unknown => return error.InvalidExtension,
    }
}

pub fn savePoints(data: *lma.data.Points, aux: *const lma.data.Stations, file_name: []const u8, w: *std.Io.Writer) WriteError!void {
    try innerSavePoints(data, aux, std.fs.path.basename(file_name), w, true);
}

inline fn innerSavePoints(data: *lma.data.Points, aux: *const lma.data.Stations, basename: []const u8, w: *std.Io.Writer, comptime allow_compression: bool) WriteError!void {
    const stem, const suffix = std.mem.cutScalarLast(u8, basename, '.') orelse .{ basename, "" };
    const extension: Extension = .parse(suffix);
    switch (extension) {
        .csv => try data.toCsv(w, null),
        .bin => try data.toBin(w),
        .dat => try lma.data.dat_file.output.print(w, data, aux),
        .gz => {
            if (!allow_compression) return error.InvalidExtension;
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate: std.compress.flate.Compress = try .init(w, &flate_buffer, .gzip, .default);
            try innerSavePoints(data, aux, stem, &flate.writer, false);
            try flate.finish();
            try w.flush();
        },
        .unknown => return error.InvalidExtension,
    }
}

const Extension = enum {
    csv,
    bin,
    dat,
    gz,
    unknown,

    pub fn parse(extension: []const u8) Extension {
        return map.get(extension) orelse .unknown;
    }

    const map: std.StaticStringMap(Extension) = .initComptime(.{
        .{ "csv", .csv },
        .{ "bin", .bin },
        .{ "dat", .dat },
        .{ "gz", .gz },
    });
};
