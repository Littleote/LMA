const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("lma");
const nargs = @import("nargs");

pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

pub const WriteError = error{ WriteFailed, InvalidExtension };

const Compression = enum { gz, GZ, gzip, GZIP };

pub fn load(
    Type: type,
    data: *Type,
    Format: type,
    functions: std.EnumArray(Format, fn (*Type, *Reader) ParseError!void),
    file_name: []const u8,
    r: *Reader,
    comptime allow_compression: bool,
) error{ ReadFailed, Logged }!void {
    const basename = std.fs.path.basename(file_name);
    return innerLoad(Type, data, Format, functions, basename, r, allow_compression) catch |err| switch (err) {
        error.ReadFailed => |new_err| return new_err,
        error.OutOfMemory => {
            std.log.err("Ran out of memory while reading file {s}.", .{file_name});
            @panic("OOM");
        },
        else => |new_err| {
            std.log.err("Unable to read file \"{s}\" {s}.", .{ file_name, switch (new_err) {
                error.InvalidHeader => "because of an invalid header",
                error.InvalidValue => "because of an invalid value",
                error.BadFile => "because the file is malformed",
                error.UnsupportedVersion => "because the version is not supported",
                error.InvalidExtension => "because it has an unknown file extension",
            } });
            return error.Logged;
        },
    };
}

pub fn innerLoad(
    Type: type,
    data: *Type,
    Format: type,
    functions: std.EnumArray(Format, fn (*Type, *Reader) ParseError!void),
    basename: []const u8,
    r: *Reader,
    comptime allow_compression: bool,
) (error{InvalidExtension} || ParseError)!void {
    const stem, const suffix = std.mem.cutScalarLast(u8, basename, '.') orelse .{ basename, "" };
    if (std.meta.stringToEnum(Format, suffix)) |format| {
        switch (format) {
            inline else => |comptime_format| {
                const fun = comptime functions.get(comptime_format);
                try fun(data, r);
            },
        }
    } else {
        if (allow_compression) if (std.meta.stringToEnum(Compression, suffix)) |format| switch (format) {
            .gz, .GZ, .gzip, .GZIP => {
                var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                var flate: std.compress.flate.Decompress = .init(r, .gzip, &flate_buffer);
                return innerLoad(Type, data, Format, functions, stem, &flate.reader, false) catch |err| switch (err) {
                    error.ReadFailed => {
                        if (flate.err == null or flate.err.? == error.ReadFailed) return error.ReadFailed;
                        return error.BadFile;
                    },
                    else => |new_err| return new_err,
                };
            },
        };
        return error.InvalidExtension;
    }
}

pub fn loadStations(stations: *lma.data.Stations, file_name: []const u8, reader: *Reader) error{ ReadFailed, Logged }!void {
    const Enum = enum {
        csv,
        gps,
        loc,

        pub fn fromCsv(data: *lma.data.Stations, r: *Reader) ParseError!void {
            try data.fromCsv(r, null);
        }

        pub fn fromGps(data: *lma.data.Stations, r: *Reader) ParseError!void {
            try data.fromGps(r);
        }

        pub fn fromLoc(data: *lma.data.Stations, r: *Reader) ParseError!void {
            try data.fromLoc(r);
        }

        pub fn unimplemented(_: *lma.data.Stations, _: *Reader) ParseError!void {
            @panic("Not yet implemented");
        }
    };

    try load(
        lma.data.Stations,
        stations,
        Enum,
        .init(.{
            .csv = Enum.fromCsv,
            .gps = Enum.fromGps,
            .loc = Enum.fromLoc,
        }),
        file_name,
        reader,
        false,
    );
}

pub fn loadSignals(signals: *lma.data.Signal, file_name: []const u8, reader: *Reader) error{ ReadFailed, Logged }!void {
    const Enum = enum {
        csv,
        bin,
        dat,

        pub fn fromCsv(data: *lma.data.Signal, r: *Reader) ParseError!void {
            try data.fromCsv(r, null);
        }

        pub fn fromBin(data: *lma.data.Signal, r: *Reader) ParseError!void {
            try data.fromBin(r);
        }

        pub fn fromDat(data: *lma.data.Signal, r: *Reader) ParseError!void {
            try lma.data.dat_file.signals.fromReader(r, data);
        }
    };

    try load(
        lma.data.Signal,
        signals,
        Enum,
        .init(.{
            .csv = Enum.fromCsv,
            .bin = Enum.fromBin,
            .dat = Enum.fromDat,
        }),
        file_name,
        reader,
        true,
    );
}

pub fn savePoints(data: *lma.data.Points, aux_stations: *const lma.data.Stations, aux_statistics: []const lma.pipeline.ToaSolver.Statistics, file_name: []const u8, w: *std.Io.Writer) WriteError!void {
    try innerSavePoints(data, aux_stations, aux_statistics, std.fs.path.basename(file_name), w, true);
}

inline fn innerSavePoints(data: *lma.data.Points, aux_stations: *const lma.data.Stations, aux_statistics: []const lma.pipeline.ToaSolver.Statistics, basename: []const u8, w: *std.Io.Writer, comptime allow_compression: bool) WriteError!void {
    const stem, const suffix = std.mem.cutScalarLast(u8, basename, '.') orelse .{ basename, "" };
    const extension: Extension = .parse(suffix);
    switch (extension) {
        .csv => try data.toCsv(w, null),
        .bin => try data.toBin(w),
        .dat => try lma.data.dat_file.output.print(w, data, aux_stations, aux_statistics),
        .gz => {
            if (!allow_compression) return error.InvalidExtension;
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate: std.compress.flate.Compress = try .init(w, &flate_buffer, .gzip, .default);
            try innerSavePoints(data, aux_stations, aux_statistics, stem, &flate.writer, false);
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
