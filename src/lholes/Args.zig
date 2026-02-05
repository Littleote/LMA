const Args = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("lma");
const float = lma.pipeline.float;
const transform = lma.pipeline.transform;
const zlm = @import("zlm").as(float);
const nargs = @import("nargs");
const groups = nargs.groups;
const params = nargs.params;
const types = nargs.types;
pub const Generator = @import("Generator.zig");

/// Input file format for the lightning hole detection application
pub const FileFormat = enum(u8) {
    /// Internal binary format representation
    bin,
    /// UPC Internal binary or text format representation
    dat,
    /// Coma separated values
    csv,
};

/// Data processing stage that is being passed to the lightning hole detection application
/// Data must be at least in the points stage, as it requires latitude and longitude
pub const Stage = enum(u8) {
    /// Data in the clustered stage. Only non-noise values will be used
    clusters,
    /// Data in the points stage. All values will be used
    points,
};

/// Full input format specification
pub const Format = extern struct {
    file: FileFormat,
    stage: Stage,
};

pub const RegionType = enum(u8) {
    center_size,
    end_points,
};

pub const Region = union(RegionType) {
    center_size: struct {
        center: zlm.Vec2,
        size: zlm.Vec2,
    },
    end_points: struct {
        origin: zlm.Vec2,
        end: zlm.Vec2,
    },

    pub fn lookAt(
        self: Region,
    ) zlm.Vec3 {
        return switch (self) {
            .center_size => |center_size| transform.surfaceToXYZ(center_size.center),
            .end_points => |end_points| blk: {
                const origin = transform.surfaceToXYZ(end_points.origin);
                const end = transform.surfaceToXYZ(end_points.end);
                break :blk origin.add(end);
            },
        };
    }

    pub fn generateInfo(self: Region, detail: Detail, rotation: *const zlm.Mat3) lma.pipeline.grid.Info {
        return switch (self) {
            .center_size => |center_size| .scale(detail, center_size.size),
            .end_points => |end_points| .limits(
                detail,
                transform.surfaceToPlane(end_points.origin, rotation),
                transform.surfaceToPlane(end_points.end, rotation),
            ),
        };
    }
};

const Resolution = enum(u8) {
    micro,
    low,
    medium,
    high,
    extra,

    pub fn step(res: Resolution) zlm.Vec2 {
        return switch (res) {
            .micro => .new(7_071.0, 7_071.0),
            .low => .new(2_236.0, 2_236.0),
            .medium => .new(1_000.0, 1_000.0),
            .high => .new(500.0, 500.0),
            .extra => .new(100.0, 100.0),
        };
    }
};
const Detail = lma.pipeline.grid.Info.Detail;

input: []const u8,
format: Format,

output: []const u8,
map: ?[]const u8,
ffmpeg: bool,

region: Region,

detail: lma.pipeline.grid.Info.Detail,

half_life: float,
luminosity: float,

pub fn deinit(self: *const Args, gpa: Allocator) void {
    gpa.free(self.input);
    gpa.free(self.output);
    if (self.map) |map| gpa.free(map);
}

pub fn generator(self: Args, gpa: Allocator, io: std.Io) !*Generator {
    return try .init(gpa, io, self.input, self.format);
}

const coord_parsers = .{
    .latitude = types.Floating(float).interval(-90, 90, .closed),
    .longitude = types.Floating(float).interval(-180, 180, .closed),
};
fn coord(name: []const u8, options: params.Mixed(@TypeOf(coord_parsers)).Options) params.Mixed(@TypeOf(coord_parsers)) {
    return params.mixed(name, coord_parsers, options);
}

pub fn parseNargs(gpa: Allocator, io: std.Io, cli: std.process.Args) !Args {
    var root = groups.any("holes", .{
        .input = params.param("input", types.string, .single, .{ .short = .auto }),
        .info = groups.any("FILE INFO", .{
            .format = params.param("Fformat", types.options(FileFormat), .single, .{ .default = .bin }),
            .stage = params.param("Fstage", types.options(Stage), .single, .{ .default = .clusters }),
        }),
        .output = params.param("output", types.string, .single, .{ .short = .auto, .default = "img/demo/holes" }),
        .map = params.param(
            "map",
            types.string,
            .single,
            .{ .short = .auto, .default = "", .alias = &.{
                .pair("cat-map", "data/map/comarques-compressed.geojson"),
                .pair("val-map", "data/map/comarques-cv.geojson"),
            } },
        ),
        .ffmpeg = params.flag("ffmpeg", .{}),

        .region = groups.exclusive("REGION", .{
            .center_scale = groups.incremental("CENTER & SCALE", .{
                .center = coord("center", .{ .delimiter = ',' }),
                .scale = params.param("scale", types.Floating(float).init, .array(2), .{ .delimiter = ',', .default = .{ 512, 512 } }),
            }),
            .end_points = groups.incremental("END POINTS", .{
                .from = coord("from", .{ .delimiter = ',' }),
                .to = coord("to", .{ .delimiter = ',' }),
            }),
            .preset = params.param("region", types.options(enum { catalunya, valencia }), .single, .{ .default = .catalunya }),
        }, .preset),
        .detail = groups.exclusive("DETAIL", .{
            .fixed_size = params.param("fixed-size", types.Integer(u16).init, .array(2), .{ .delimiter = ',' }),
            .resolution = params.param("resolution", types.options(Resolution), .single, .{ .short = .auto, .default = .medium }),
        }, .resolution),

        .half_life = params.param("half-life", types.Floating(float).init, .single, .{ .short = .auto, .default = 2.5 }),
        .luminosity = params.param("luminosity", types.Floating(float).init, .single, .{ .short = .auto, .default = 1.0 }),
    });

    const ctx = .{ .allocator = gpa };
    var command = blk: {
        var args: nargs.Args = .init(gpa);
        defer args.deinit();
        try args.appendArguments(cli);
        break :blk try args.parseAndCreate(io, ctx, root);
    };
    defer root.destroy(ctx, &command);

    const input = try gpa.dupe(u8, command.input);
    errdefer gpa.free(input);
    const output = try gpa.dupe(u8, command.output);
    errdefer gpa.free(output);
    const maybe_map = if (command.map.len != 0) try gpa.dupe(u8, command.map) else null;
    errdefer if (maybe_map) |map| gpa.free(map);

    return .{
        .input = input,
        .format = .{ .file = command.info.format, .stage = command.info.stage },
        .output = output,
        .map = maybe_map,
        .ffmpeg = command.ffmpeg,

        .region = switch (command.region) {
            .center_scale => |center_scale| .{ .center_size = .{
                .center = .new(center_scale.center.latitude, center_scale.center.longitude),
                .size = .new(1_000 * center_scale.scale[0], 1_000 * center_scale.scale[1]),
            } },
            .end_points => |end_points| .{ .end_points = .{
                .origin = .new(end_points.from.latitude, end_points.from.longitude),
                .end = .new(end_points.to.latitude, end_points.to.longitude),
            } },
            .preset => |location| switch (location) {
                .catalunya => .{ .center_size = .{ .center = .new(41.70, 1.75), .size = .new(300_000, 300_000) } },
                .valencia => unreachable,
            },
        },
        .detail = switch (command.detail) {
            .fixed_size => |shape| .fromShape(.init(shape[0], shape[1])),
            .resolution => |resolution| .fromStep(resolution.step()),
        },

        .half_life = command.half_life,
        .luminosity = command.luminosity,
    };
}

pub fn Pair(T: type) type {
    return extern struct {
        first: T,
        second: T,
    };
}

pub const ExternArgs = extern struct {
    input: [*:0]const u8,
    input_len: usize,
    format: Format,

    output: [*:0]const u8,
    output_len: usize,
    map: ?[*:0]const u8,
    map_len: usize,
    ffmpeg: bool,

    region_type: RegionType,
    region_first: Pair(float),
    region_second: Pair(float),

    resolution: Resolution,

    half_life: float,
    luminosity: float,

    pub fn toInner(self: *const ExternArgs) Args {
        return .{
            .input = self.input[0..self.input_len],
            .format = self.format,
            .output = self.output[0..self.output_len],
            .map = if (self.map) |map| map[0..self.map_len] else null,
            .ffmpeg = self.ffmpeg,
            .region = switch (self.region_type) {
                .center_size => .{ .center_size = .{
                    .center = .new(self.region_first.first, self.region_first.second),
                    .size = .new(self.region_second.first, self.region_second.second),
                } },
                .end_points => .{ .end_points = .{
                    .origin = .new(self.region_first.first, self.region_first.second),
                    .end = .new(self.region_second.first, self.region_second.second),
                } },
            },
            .detail = .fromStep(self.resolution.step()),
            .half_life = self.half_life,
            .luminosity = self.luminosity,
        };
    }
};

fn parseFloat(s: []const u8) !float {
    return std.fmt.parseFloat(float, s) catch |err| {
        std.log.err("Failure to parse \"{s}\" as a float\n", .{s});
        return err;
    };
}

fn parseInt(Int: type, s: []const u8) !Int {
    return std.fmt.parseInt(Int, s, 10) catch |err| {
        std.log.err("Failure to parse \"{s}\" as an integer\n", .{s});
        return err;
    };
}

fn parseCoords(s: []const u8) !struct { float, float } {
    const lat, const lon = std.mem.cutScalar(u8, s, ',') orelse {
        std.log.err("Failure to parse latitude and longitude from \"{s}\" due to missing coma separator\n", .{s});
        return error.Parsing;
    };
    return .{ try parseFloat(lat), try parseFloat(lon) };
}
