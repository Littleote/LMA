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
    return innerLoad(Type, data, Format, functions, basename, r, allow_compression) catch |e| switch (e) {
        error.ReadFailed => |err| return err,
        error.OutOfMemory => {
            std.log.err("Ran out of memory while reading file {s}.", .{file_name});
            @panic("OOM");
        },
        else => |err| {
            std.log.err("Unable to read file {q} {s}.", .{ file_name, switch (err) {
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
                return innerLoad(Type, data, Format, functions, stem, &flate.reader, false) catch |e| switch (e) {
                    error.ReadFailed => {
                        if (flate.err == null or flate.err.? == error.ReadFailed) return error.ReadFailed;
                        return error.BadFile;
                    },
                    else => |err| return err,
                };
            },
        };
        return error.InvalidExtension;
    }
}

pub fn loadStations(stations: *lma.data.Station.List, file_name: []const u8, reader: *Reader) error{ ReadFailed, Logged }!void {
    const Enum = enum {
        csv,
        gps,
        loc,

        pub fn fromCsv(data: *lma.data.Station.List, r: *Reader) ParseError!void {
            try lma.data.Station.csv.read(data, r, null);
        }

        pub fn fromGps(data: *lma.data.Station.List, r: *Reader) ParseError!void {
            try lma.data.Station.fromGps(data, r);
        }

        pub fn fromLoc(data: *lma.data.Station.List, r: *Reader) ParseError!void {
            try lma.data.Station.fromLoc(data, r);
        }

        pub fn unimplemented(_: *lma.data.Station.List, _: *Reader) ParseError!void {
            @panic("Not yet implemented");
        }
    };

    try load(
        lma.data.Station.List,
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

pub fn loadSignals(signals: *Signal.List, file_name: []const u8, reader: *Reader) error{ ReadFailed, Logged }!void {
    const Enum = enum {
        csv,
        bin,
        dat,

        pub fn fromCsv(data: *Signal.List, r: *Reader) ParseError!void {
            try Signal.csv.read(data, r, null);
        }

        pub fn fromBin(data: *Signal.List, r: *Reader) ParseError!void {
            try Signal.bin.read(data, r);
        }

        pub fn fromDat(data: *Signal.List, r: *Reader) ParseError!void {
            try lma.data.dat_file.SignalParser.read(r, data, .{});
        }
    };

    try load(
        Signal.List,
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

pub fn savePoints(data: *Point.List, aux_stations: *const Station.List, aux_statistics: []const lma.pipeline.ToaSolver.Statistics, file_name: []const u8, w: *std.Io.Writer) WriteError!void {
    try innerSavePoints(data, aux_stations, aux_statistics, std.fs.path.basename(file_name), w, true);
}

inline fn innerSavePoints(data: *Point.List, aux_stations: *const Station.List, aux_statistics: []const lma.pipeline.ToaSolver.Statistics, basename: []const u8, w: *std.Io.Writer, comptime allow_compression: bool) WriteError!void {
    const stem, const suffix = std.mem.cutScalarLast(u8, basename, '.') orelse .{ basename, "" };
    const extension: Extension = .parse(suffix);
    switch (extension) {
        .csv => try Point.csv.write(data, w, null),
        .bin => try Point.bin.write(data, w),
        .dat => try lma.data.dat_file.output.write(w, data, aux_stations, aux_statistics),
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
