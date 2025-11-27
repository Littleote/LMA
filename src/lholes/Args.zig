const Args = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const lma = @import("lma");
const float = lma.pipeline.float;
const zlm = @import("zlm").as(float);
const args = @import("args");
const utils = @import("utils.zig");

const Parse = struct {
    // Input directory [Mandatory]
    input: ?[]const u8 = null,
    // Output directory for images
    output: []const u8 = "img/demo/holes",

    // center (lat, lon) and size (w, [h])
    at: ?[]const u8 = null,
    scale: ?[]const u8 = null,

    // origin (lat, lon) and end (lat, lon)
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,

    resolution: Resolution = .medium,
    @"half-life": float = 2.5,
    luminosity: float = 1.0,

    pub const shorthands = .{
        .i = "input",
        .r = "resolution",
        .h = "half-life",
        .l = "luminosity",
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
            .center_size => |center_size| lma.pipeline.transform.coordToSpace(center_size.center),
            .end_points => |end_points| blk: {
                const origin = lma.pipeline.transform.coordToSpace(end_points.origin);
                const end = lma.pipeline.transform.coordToSpace(end_points.end);
                break :blk origin.add(end);
            },
        };
    }

    pub fn generateInfo(self: Region, step: zlm.Vec2, rotation: zlm.Mat3) lma.pipeline.grid.Info {
        return switch (self) {
            .center_size => |center_size| .scale(.fromStep(step), center_size.size),
            .end_points => |end_points| .limits(
                .fromStep(step),
                lma.pipeline.transform.coordToPlane(end_points.origin, rotation),
                lma.pipeline.transform.coordToPlane(end_points.end, rotation),
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
            .micro => .new(7.071, 7.071),
            .low => .new(2.236, 2.236),
            .medium => .new(1.0, 1.0),
            .high => .new(0.5, 0.5),
            .extra => .new(0.1, 0.1),
        };
    }
};

input: []const u8,
format: Format,

output: []const u8,

region: Region,

resolution: Resolution,

half_life: float,
luminosity: float,

pub fn deinit(self: *const Args, gpa: Allocator) void {
    gpa.free(self.input);
    gpa.free(self.output);
}

pub fn parseArgs(gpa: Allocator) !Args {
    const parsed = try args.parseForCurrentProcess(
        Parse,
        gpa,
        .print,
    );
    defer parsed.deinit();
    if (parsed.positionals.len != 0) {
        std.debug.print("Positional arguments provided but non expected. Used coma separated values without spaces for specifying multiple values\n", .{});
        return error.Parsing;
    }

    if (parsed.options.at == null and parsed.options.scale != null) {
        std.debug.print("Missing argument \"at\", required when using \"scale\"\n", .{});
        return error.Parsing;
    }
    if (parsed.options.from == null and parsed.options.to != null) {
        std.debug.print("Missing argument \"from\", required when using \"to\"\n", .{});
        return error.Parsing;
    }

    const region: Region = if (parsed.options.at) |at| blk: {
        const scale = parsed.options.scale orelse "512";
        const lat, const lon = try parseCoords(at);
        const width, const height = std.mem.cutScalar(u8, scale, ',') orelse .{ scale, scale };
        break :blk .{ .center_size = .{
            .center = .new(lat, lon),
            .size = .new(try parseFloat(width), try parseFloat(height)),
        } };
    } else if (parsed.options.from) |from| blk: {
        const to = parsed.options.to orelse {
            std.debug.print("Missing argument \"to\", required when using \"from\"\n", .{});
            return error.Parsing;
        };
        const origin = try parseCoords(from);
        const end = try parseCoords(to);
        break :blk .{ .end_points = .{
            .origin = .new(origin[0], origin[1]),
            .end = .new(end[0], end[1]),
        } };
    } else blk: {
        std.debug.print("Defaulting to catalonia due to no region specified\n", .{});
        break :blk .{ .center_size = .{ .center = .new(42.1, 1.8), .size = .new(500, 500) } };
    };
    std.debug.print("{any}\n", .{region});

    const input = try gpa.dupe(u8, parsed.options.input orelse {
        std.debug.print("Missing argument \"input\"\n", .{});
        return error.Parsing;
    });
    errdefer gpa.free(input);
    const output = try gpa.dupe(u8, parsed.options.output);
    errdefer gpa.free(output);

    return .{
        .input = input,
        .format = .{ .file = .bin, .stage = .clusters },
        .output = output,

        .region = region,
        .resolution = parsed.options.resolution,

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
            .resolution = self.resolution,
            .half_life = self.half_life,
            .luminosity = self.luminosity,
        };
    }
};

fn parseFloat(s: []const u8) !float {
    return std.fmt.parseFloat(float, s) catch |err| {
        std.debug.print("Failure to parse \"{s}\" as a float\n", .{s});
        return err;
    };
}

fn parseCoords(s: []const u8) !struct { float, float } {
    const lat, const lon = std.mem.cutScalar(u8, s, ',') orelse {
        std.debug.print("Failure to parse latitude and longitude from \"{s}\" due to missing coma separator\n", .{s});
        return error.Parsing;
    };
    return .{ try parseFloat(lat), try parseFloat(lon) };
}
