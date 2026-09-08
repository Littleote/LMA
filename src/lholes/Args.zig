const std = @import("std");
const Allocator = std.mem.Allocator;

const lma = @import("lma");
const transform = lma.pipeline.transform;
const Detail = lma.grid.Bounds.Detail;
const nargs = @import("nargs");
const opt = nargs.options;

pub const Float = @import("main.zig").Float;
pub const Generator = @import("Generator.zig");

const Args = @This();

const math = lma.math(Float);

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
        center: math.Vec,
        size: math.Vec,
    },
    end_points: struct {
        origin: math.Vec,
        end: math.Vec,
    },

    pub fn lookAt(
        self: Region,
    ) math.Vec {
        return switch (self) {
            .center_size => |center_size| transform.surfaceToXYZ(Float, .init(center_size.center)).build(),
            .end_points => |end_points| blk: {
                const origin = transform.surfaceToXYZ(Float, .init(end_points.origin)).build();
                const end = transform.surfaceToXYZ(Float, .init(end_points.end)).build();
                break :blk origin + end;
            },
        };
    }

    pub fn generateBounds(self: Region, detail: Detail, rotation: *const math.Mat) lma.grid.Bounds {
        return switch (self) {
            .center_size => |center_size| .scale(detail, center_size.size),
            .end_points => |end_points| .limits(
                detail,
                transform.surfaceToPlane(Float, .init(end_points.origin), rotation),
                transform.surfaceToPlane(Float, .init(end_points.end), rotation),
            ),
        };
    }
};

const Resolution = enum(u8) {
    const vec2 = math.vector.vec2;

    micro,
    low,
    medium,
    high,
    extra,

    pub fn step(res: Resolution) math.Vec {
        return switch (res) {
            .micro => vec2(7_071.0, 7_071.0),
            .low => vec2(2_236.0, 2_236.0),
            .medium => vec2(1_000.0, 1_000.0),
            .high => vec2(500.0, 500.0),
            .extra => vec2(100.0, 100.0),
        };
    }
};
input: []const u8,
format: Format,

output: []const u8,
map: ?[]const u8,
ffmpeg: bool,

region: Region,

detail: Detail,

half_life: Float,
luminosity: Float,

pub fn deinit(self: *const Args, gpa: Allocator) void {
    gpa.free(self.input);
    gpa.free(self.output);
    if (self.map) |map| gpa.free(map);
}

pub fn generator(self: Args, gpa: Allocator, io: std.Io) !*Generator {
    return try .init(gpa, io, self.input, self.format);
}

const coord_parsers = .{
    .latitude = nargs.types.Floating(Float, .{ .min = .closed(-90), .max = .closed(90) }),
    .longitude = nargs.types.Floating(Float, .{ .min = .closed(-180), .max = .closed(180) }),
};
// fn coord(name: []const u8, config: opt.Mixed(struct{Float, Float}).Config) nargs.Node(struct{Float, Float}) {
//     return .build(opt.Mixed, ...);
// }
fn coord(config: opt.Named([2]Float).Config) nargs.Node([2]Float) {
    return .build(opt.Named, .array(.floating(.{ .min = .closed(-180), .max = .closed(180) }), config));
}

const Cli = struct {
    input: []const u8,
    info: struct {
        format: FileFormat = .bin,
        stage: Stage = .clusters,
    },
    output: []const u8,
    map: []const u8,
    ffmpeg: bool,
    region: union(enum) {
        center_scale: struct {
            center: [2]Float,
            scale: [2]Float,
        },
        end_points: struct {
            from: [2]Float,
            to: [2]Float,
        },
        preset: enum { catalunya, valencia },
    },
    detail: union(enum) {
        fixed_size: [2]u32,
        resolution: Resolution,
    },
    half_life: Float = 2.5,
    luminosity: Float = 1.0,
};

const root: nargs.Node(Cli) = .build(opt.Groups, .any(.{ .name = "holes" }, .{
    .input = .build(opt.Named, .single(.string, .{ .name = "input", .description = "Input file with the flash sources", .short = .auto })),
    .info = .build(opt.Groups, .any(.{ .name = "FILE_INFO", .show = .usage }, .{
        .format = .build(opt.Named, .single(.choice, .{ .name = "Fformat", .description = "File format" })),
        .stage = .build(opt.Named, .single(.choice, .{ .name = "Fstage", .description = "Pipeline stage of the file" })),
    })),
    .output = .build(opt.Named, .single(.string, .{ .name = "output", .description = "Output folder for the generated images", .short = .auto, .default = .init("img/demo/holes", null) })),
    .map = .build(opt.Named, .single(.string, .{
        .name = "map",
        .description = "Background map th display in the images as a geographical reference",
        .short = .auto,
        .default = .init("", "None"),
        .alternatives = &.{
            .shortcut("cat-map", "data/map/comarques-compressed.geojson", "Catalonia map"),
            .shortcut("val-map", "data/map/comarques-cv.geojson", "Valencia map"),
        },
    })),
    .ffmpeg = opt.flags.Flag(.{ .name = "ffmpeg", .description = "Generate a video from all the images using ffmpeg" }),

    .region = .build(opt.Groups, .exclusive(.{ .name = "REGION", .show = .usage }, .preset, .{
        .center_scale = .build(opt.Groups, .incremental(.{ .name = "CENTER_&_SCALE", .show = .usage }, .{
            .center = coord(.{ .name = "center", .description = "Center of the area", .shape = .{ .payload = ',' } }),
            .scale = .build(opt.Named, .array(.floating(.{}), .{ .name = "scale", .description = "Area size", .shape = .{ .payload = ',' }, .default = .init(.{ 512, 512 }, null) })),
        })),
        .end_points = .build(opt.Groups, .incremental(.{ .name = "END_POINTS", .show = .usage }, .{
            .from = coord(.{ .name = "from", .description = "Top left", .shape = .{ .payload = ',' } }),
            .to = coord(.{ .name = "to", .description = "Bottom right", .shape = .{ .payload = ',' } }),
        })),
        .preset = .build(opt.Named, .single(.choice, .{ .name = "region", .description = "Auto adjust to the given region area", .default = .init(.catalunya, "Catalunya") })),
    })),
    .detail = .build(opt.Groups, .exclusive(.{ .name = "DETAIL", .show = .usage }, .resolution, .{
        .fixed_size = .build(opt.Named, .array(.integer(.{}), .{ .name = "fixed-size", .description = "Resolution of the full image", .shape = .{ .payload = ',' } })),
        .resolution = .build(opt.Named, .single(.choice, .{ .name = "resolution", .description = "Resolution per km²", .short = .auto, .default = .init(.medium, null) })),
    })),

    .half_life = .build(opt.Named, .single(.floating(.{}), .{ .name = "half-life", .description = "Half-life for flash source persistence", .short = .auto })),
    .luminosity = .build(opt.Named, .single(.floating(.{}), .{ .name = "luminosity", .description = "Scaling of image scale", .short = .auto })),
}));

pub fn parseNargs(gpa: Allocator, io: std.Io, cli: std.process.Args) !Args {
    var command: Cli = undefined;
    {
        var tokenizer: nargs.Tokenizer = try .initFromArgs(gpa, cli);
        defer tokenizer.deinit();
        var diag: nargs.Diagnostic = .init(gpa, .default);
        defer {
            for (diag.error_list.items) |info|
                std.log.err("{f}", .{info});
            diag.deinit();
        }

        var mem = root.initMemory().*;
        while (tokenizer.peek()) |token| {
            if (root.parse(&mem, &tokenizer, &diag) == .no_match) {
                tokenizer.discardAssumeToken();
                diag.log(.unused_token, "", token);
            }
        }

        if (diag.special_flags.get(.help)) {
            var help_buf: [128]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &help_buf);
            nargs.Help.print(.{ .info = root.info }, .fancy, &stdout.interface) catch {};
            stdout.flush() catch {};
            return error.Help;
        }

        try root.init(&mem, &diag, gpa, &command);
    }
    defer root.deinit(gpa, &command);

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
                .center = math.vector.vec2(center_scale.center[0], center_scale.center[1]),
                .size = math.vector.vec2(1_000 * center_scale.scale[0], 1_000 * center_scale.scale[1]),
            } },
            .end_points => |end_points| .{ .end_points = .{
                .origin = math.vector.vec2(end_points.from[0], end_points.from[1]),
                .end = math.vector.vec2(end_points.to[0], end_points.to[1]),
            } },
            .preset => |location| switch (location) {
                .catalunya => .{ .center_size = .{ .center = math.vector.vec2(41.70, 1.75), .size = math.vector.vec2(300_000, 300_000) } },
                .valencia => @panic("Not implemented"),
            },
        },
        .detail = switch (command.detail) {
            .fixed_size => |shape| .fromGrid(.init(shape[0], shape[1])),
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
    region_first: Pair(Float),
    region_second: Pair(Float),

    resolution: Resolution,

    half_life: Float,
    luminosity: Float,

    pub fn toInner(self: *const ExternArgs) Args {
        return .{
            .input = self.input[0..self.input_len],
            .format = self.format,
            .output = self.output[0..self.output_len],
            .map = if (self.map) |map| map[0..self.map_len] else null,
            .ffmpeg = self.ffmpeg,
            .region = switch (self.region_type) {
                .center_size => .{ .center_size = .{
                    .center = math.vector.vec2(self.region_first.first, self.region_first.second),
                    .size = math.vector.vec2(self.region_second.first, self.region_second.second),
                } },
                .end_points => .{ .end_points = .{
                    .origin = math.vector.vec2(self.region_first.first, self.region_first.second),
                    .end = math.vector.vec2(self.region_second.first, self.region_second.second),
                } },
            },
            .detail = .fromStep(self.resolution.step()),
            .half_life = self.half_life,
            .luminosity = self.luminosity,
        };
    }
};

fn parseFloat(s: []const u8) !Float {
    return std.fmt.parseFloat(Float, s) catch |err| {
        std.log.err("Failure to parse \"{s}\" as a float", .{s});
        return err;
    };
}

fn parseInt(Int: type, s: []const u8) !Int {
    return std.fmt.parseInt(Int, s, 10) catch |err| {
        std.log.err("Failure to parse \"{s}\" as an integer", .{s});
        return err;
    };
}

fn parseCoords(s: []const u8) !struct { Float, Float } {
    const lat, const lon = std.mem.cutScalar(u8, s, ',') orelse {
        std.log.err("Failure to parse latitude and longitude from \"{s}\" due to missing coma separator", .{s});
        return error.Parsing;
    };
    return .{ try parseFloat(lat), try parseFloat(lon) };
}
