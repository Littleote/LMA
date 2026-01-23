const Args = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("lma");
const float = lma.pipeline.float;
const transform = lma.pipeline.transform;
const zlm = @import("zlm").as(float);
const args = @import("args");
pub const Generator = @import("Generator.zig");

const Parse = struct {
    // Input directory [Mandatory]
    input: ?[]const u8 = null,
    // Output directory for images
    output: []const u8 = "img/demo/holes",
    // Map overlay GeoJSON
    map: ?[]const u8 = null,
    // Generate the mp4 after finishing
    ffmpeg: ?bool = null,
    @"no-ffmpeg": bool = false,

    // center (lat, lon) and size (w, [h])
    at: ?[]const u8 = null,
    scale: ?[]const u8 = null,

    // origin (lat, lon) and end (lat, lon)
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,

    resolution: ?Resolution = null,
    @"fixed-size": ?[]const u8 = null,
    @"half-life": float = 2.5,
    luminosity: float = 1.0,

    pub const shorthands = .{
        .i = "input",
        .o = "output",
        .r = "resolution",
        .h = "half-life",
        .l = "luminosity",
        .m = "map",
    };
};

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

pub fn parseArgs(gpa: Allocator) !Args {
    const parsed = try args.parseForCurrentProcess(
        Parse,
        gpa,
        .print,
    );
    defer parsed.deinit();
    if (parsed.positionals.len != 0) {
        std.log.err("Positional arguments provided but non expected. Used coma separated values without spaces for specifying multiple values\n", .{});
        return error.Parsing;
    }

    if (parsed.options.@"no-ffmpeg" and (parsed.options.ffmpeg orelse false)) {
        std.log.err("Contradictory values for ffmpeg specified\n", .{});
        return error.Parsing;
    }

    if (parsed.options.@"fixed-size" != null and parsed.options.resolution != null) {
        std.log.err("Contradictory arguments \"fixed-size\" and \"resolution\" specified\n", .{});
        return error.Parsing;
    }

    if (parsed.options.at == null and parsed.options.scale != null) {
        std.log.err("Missing argument \"at\", required when using \"scale\"\n", .{});
        return error.Parsing;
    }
    if (parsed.options.from == null and parsed.options.to != null) {
        std.log.err("Missing argument \"from\", required when using \"to\"\n", .{});
        return error.Parsing;
    }

    const region: Region = if (parsed.options.at) |at| blk: {
        const scale = parsed.options.scale orelse "512_000";
        const lat, const lon = try parseCoords(at);
        const width, const height = std.mem.cutScalar(u8, scale, ',') orelse .{ scale, scale };
        break :blk .{ .center_size = .{
            .center = .new(lat, lon),
            .size = .new(1_000 * try parseFloat(width), 1_000 * try parseFloat(height)),
        } };
    } else if (parsed.options.from) |from| blk: {
        const to = parsed.options.to orelse {
            std.log.err("Missing argument \"to\", required when using \"from\"\n", .{});
            return error.Parsing;
        };
        const origin = try parseCoords(from);
        const end = try parseCoords(to);
        break :blk .{ .end_points = .{
            .origin = .new(origin[0], origin[1]),
            .end = .new(end[0], end[1]),
        } };
    } else blk: {
        std.log.err("Defaulting to catalonia due to no region specified\n", .{});
        break :blk .{ .center_size = .{ .center = .new(42.1, 1.8), .size = .new(300_000, 300_000) } };
    };

    const detail: Detail = if (parsed.options.@"fixed-size") |shape| blk: {
        const width, const height = std.mem.cutScalar(u8, shape, ',') orelse .{ shape, shape };
        break :blk .fromShape(.init(try parseInt(u16, height), try parseInt(u16, width)));
    } else .fromStep((parsed.options.resolution orelse Resolution.medium).step());

    const input = try gpa.dupe(u8, parsed.options.input orelse {
        std.log.err("Missing argument \"input\"\n", .{});
        return error.Parsing;
    });
    errdefer gpa.free(input);
    const output = try gpa.dupe(u8, parsed.options.output);
    errdefer gpa.free(output);
    const maybe_map = if (parsed.options.map) |map| try gpa.dupe(u8, map) else null;
    errdefer if (maybe_map) |map| gpa.free(map);

    return .{
        .input = input,
        .format = .{ .file = .bin, .stage = .clusters },
        .output = output,
        .map = maybe_map,
        .ffmpeg = parsed.options.ffmpeg orelse !parsed.options.@"no-ffmpeg",

        .region = region,
        .detail = detail,

        .half_life = parsed.options.@"half-life",
        .luminosity = parsed.options.luminosity,
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
