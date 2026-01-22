const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const lma = @import("../lma.zig");
const data = lma.data;
const cast = lma.common.cast;

const ParseError = error{InvalidValue};
const i30p2 = 4 * 1_000_000_000;
const ParseConfig = union {
    float_opt: void,
    int_opt: struct { base: u8, has_base: bool },

    pub const float: ParseConfig = .{ .float_opt = {} };
    pub const decimal: ParseConfig = .{ .int_opt = .{ .base = 10, .has_base = false } };
    pub fn intBase(base: u8, has_base: bool) ParseConfig {
        return .{ .int_opt = .{ .base = base, .has_base = has_base } };
    }
};

inline fn parse(T: type, s: ?[]const u8, comptime config: ParseConfig) ParseError!T {
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, s orelse return error.InvalidValue) catch error.InvalidValue,
        .int => std.fmt.parseInt(T, (s orelse return error.InvalidValue)[if (config.int_opt.has_base) 2 else 0..], config.int_opt.base) catch error.InvalidValue,
        else => unreachable,
    };
}

/// Time of arrival data from the LMA stations
pub const ToA = extern struct {
    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: u32,
    /// Decibels detected with base of 1mW/m²
    dBm: f16,

    padding: u16 = 0,

    // CSV elements
    pub inline fn toCsv(self: ToA, w: *Writer, header: data.segmented.Header, del: u8) Writer.Error!void {
        try w.print("{1d:.10}{0c}{2d:.3}\n", .{
            del,
            cast(f64, header.epoch) + cast(f64, self.nanosecond) / i30p2,
            self.dBm,
        });
    }

    pub inline fn fromCsv(self: *ToA, line: []u8, del: u8) ParseError!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const time = std.math.modf(try parse(f64, iterator.next(), .float));
        const epoch: usize = @intFromFloat(time.ipart);
        const nano30p2: u32 = @intFromFloat(@round(time.fpart * i30p2));
        const decibels = try parse(f16, iterator.next(), .float);
        self.* = .{
            .nanosecond = nano30p2,
            .dBm = decibels,
        };
        return epoch;
    }

    pub const csv_columns: []const []const u8 = &.{ "Time", "Decibels-miliwatt" };

    pub fn eql(first: ToA, second: ToA) bool {
        return first.nanosecond == second.nanosecond and first.dBm == second.dBm;
    }

    pub fn approxEql(first: ToA, second: ToA) bool {
        return first.nanosecond == second.nanosecond and std.math.approxEqAbs(f16, first.dBm, second.dBm, 1e-1);
    }

    pub fn dummyValue(rand: std.Random) ToA {
        return .{
            .nanosecond = rand.uintLessThan(u32, i30p2),
            .dBm = @floatCast(200 * rand.float(f32) - 110),
        };
    }

    pub const bin_tag = "toa";
    pub const bin_version = 1;
};

/// Points indicating the sources of VHF radiation the LMA system captured
pub const Point = extern struct {
    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: u32,

    /// Latitude of the point using WGS84
    latitude: f32,
    /// Longitude of the point using WGS84
    longitude: f32,
    /// Altitude of the point using WGS84
    altitude: f32,

    /// Bitmask indicating which stations where used for this point
    station_mask: u32,
    /// Quality of the fit, lower values indicating a better fit
    measure_error: f16,

    /// Decibels detected with base of 1mW
    dBm: f16,

    /// Number of stations that participated into locating the point
    pub fn station_count(self: *const Point) u8 {
        return @intCast(@popCount(self.station_mask));
    }

    // CSV elements
    pub inline fn toCsv(self: Point, w: *Writer, header: data.segmented.Header, del: u8) Writer.Error!void {
        try w.print("{1d:.10}{0c}{2d:.8}{0c}{3d:.8}{0c}{4d:.3}{0c}{5d:.3}{0c}0x{6x:0>8}{0c}{7d:.2}\n", .{
            del,
            cast(f64, header.epoch) + cast(f64, self.nanosecond) / i30p2,
            self.latitude,
            self.longitude,
            self.altitude,
            self.dBm,
            self.station_mask,
            self.measure_error,
        });
    }

    pub inline fn fromCsv(self: *Point, line: []u8, del: u8) ParseError!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const time = std.math.modf(try parse(f64, iterator.next(), .float));
        const epoch: usize = @intFromFloat(time.ipart);
        const nano30p2: u32 = @intFromFloat(@round(time.fpart * i30p2));
        const lat = try parse(f32, iterator.next(), .float);
        const lon = try parse(f32, iterator.next(), .float);
        const alt = try parse(f32, iterator.next(), .float);
        const decibels = try parse(f16, iterator.next(), .float);
        const mask = try parse(u32, iterator.next(), .intBase(16, true));
        const fit = try parse(f16, iterator.next(), .float);
        self.* = .{
            .nanosecond = nano30p2,
            .latitude = lat,
            .longitude = lon,
            .altitude = alt,
            .dBm = decibels,
            .station_mask = mask,
            .measure_error = fit,
        };
        return epoch;
    }

    pub const csv_columns: []const []const u8 = &.{ "Time", "Latitude", "Longitude", "Altitude", "Decibels-miliwatt", "Station mask", "Fitness" };

    pub fn eql(first: Point, second: Point) bool {
        inline for (std.meta.fieldNames(Point)) |name| {
            if (@field(first, name) != @field(second, name)) return false;
        }
        return true;
    }

    pub fn approxEql(first: Point, second: Point) bool {
        return
        // zig fmt: off
            // time
            (first.nanosecond == second.nanosecond) and
            // coordinates
            (
                std.math.approxEqAbs(f32, first.latitude, second.latitude, 1e-6) and
                std.math.approxEqAbs(f32, first.longitude, second.longitude, 1e-6) and
                std.math.approxEqAbs(f32, first.altitude, second.altitude, 1e-3)
            ) and
            // mask
            (first.station_mask == second.station_mask) and
            // fitness
            std.math.approxEqAbs(f16, first.measure_error, second.measure_error, 1e-2) and
            // decibels
            std.math.approxEqAbs(f16, first.dBm, second.dBm, 1e-2);
        // zig fmt: on
    }

    pub fn dummyValue(rand: std.Random) Point {
        return .{
            .nanosecond = rand.uintLessThan(u32, i30p2),
            .latitude = rand.float(f32) * 180 - 90,
            .longitude = rand.float(f32) * 360 - 180,
            .altitude = rand.float(f32) * 20_000 - 1_000,
            .station_mask = rand.int(u32),
            .measure_error = @floatCast(rand.floatExp(f32)),
            .dBm = @floatCast(200 * rand.float(f32) - 110),
        };
    }

    pub const bin_tag = "point";
    pub const bin_version = 1;
};

/// Points indicating the sources of VHF radiation the LMA system captured
/// The points are classified as either noise with a 0
/// or as part of a lightning with a given id assigned to them
pub const Clustered = extern struct {
    pub const Cluster = enum(u32) {
        noise = 0,
        _,

        pub fn cluster(value: u32) Cluster {
            std.debug.assert(value != Cluster.noise.value);
            return @enumFromInt(value);
        }

        pub fn isNoise(self: Cluster) bool {
            return self == .noise;
        }

        pub fn id(self: Cluster) ?u32 {
            return if (self.isNoise()) null else @intFromEnum(self);
        }
    };

    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: u32,

    /// Latitude of the point using WGS84
    latitude: f32,
    /// Longitude of the point using WGS84
    longitude: f32,
    /// Altitude of the point using WGS84
    altitude: f32,

    /// Cluster assigned to the data point
    cluster: Cluster,

    /// Decibels detected with base of 1mW
    dBm: f16,

    // CSV elements
    pub inline fn toCsv(self: Clustered, w: *Writer, header: data.segmented.Header, del: u8) Writer.Error!void {
        try w.print("{1d:.10}{0c}{2d:.8}{0c}{3d:.8}{0c}{4d:.3}{0c}{5d}{0c}{6d:.3}\n", .{
            del,
            cast(f64, header.epoch) + cast(f64, self.nanosecond) / i30p2,
            self.latitude,
            self.longitude,
            self.altitude,
            @intFromEnum(self.cluster),
            self.dBm,
        });
    }

    pub inline fn fromCsv(self: *Clustered, line: []u8, del: u8) ParseError!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const time = std.math.modf(try parse(f64, iterator.next(), .float));
        const epoch: usize = @intFromFloat(time.ipart);
        const nano30p2: u32 = @intFromFloat(@round(time.fpart * i30p2));
        const lat = try parse(f32, iterator.next(), .float);
        const lon = try parse(f32, iterator.next(), .float);
        const alt = try parse(f32, iterator.next(), .float);
        _ = iterator.next();
        const decibels = try parse(f16, iterator.next(), .float);
        self.* = .{
            .nanosecond = nano30p2,
            .latitude = lat,
            .longitude = lon,
            .altitude = alt,
            .cluster = .noise,
            .dBm = decibels,
        };
        return epoch;
    }

    pub const csv_columns: []const []const u8 = &.{ "Time", "Latitude", "Longitude", "Altitude", "Cluster", "Decibels-miliwatt" };

    pub fn eql(first: Clustered, second: Clustered) bool {
        inline for (std.meta.fieldNames(Point)) |name| {
            if (@field(first, name) != @field(second, name)) return false;
        }
        return true;
    }

    pub fn approxEql(first: Clustered, second: Clustered) bool {
        return
        // zig fmt: off
            // time
            (first.nanosecond == second.nanosecond) and
            // coordinates
            (
                std.math.approxEqAbs(f32, first.latitude, second.latitude, 1e-6) and
                std.math.approxEqAbs(f32, first.longitude, second.longitude, 1e-6) and
                std.math.approxEqAbs(f32, first.altitude, second.altitude, 1e-3)
            ) and
            // cluster
            (first.cluster == second.cluster) and
            // decibels
            std.math.approxEqAbs(f16, first.dBm, second.dBm, 1e-2);
        // zig fmt: on
    }

    pub fn dummyValue(rand: std.Random) Clustered {
        return .{
            .nanosecond = rand.uintLessThan(u32, i30p2),
            .latitude = rand.float(f32) * 180 - 90,
            .longitude = rand.float(f32) * 360 - 180,
            .altitude = rand.float(f32) * 20_000 - 1_000,
            .cluster = .noise,
            .dBm = @floatCast(200 * rand.float(f32) - 110),
        };
    }

    pub const bin_tag = "cluster";
    pub const bin_version = 1;
};
