const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("../lma.zig");
const earth = lma.constants.earth;
const zlm = lma.pipeline.zlm;
const data = lma.data;

pub const Coordinates = enum {
    surface,
    gps,
    xyz,
};

inline fn square(value: anytype) @TypeOf(value) {
    return value * value;
}

inline fn hasFields(comptime fields: []const []const u8, comptime names: []const []const u8) bool {
    comptime {
        for (names) |name| {
            for (fields) |field| {
                if (std.mem.eql(u8, field, name)) break;
            } else return false;
        }
        return true;
    }
}

inline fn isVec(comptime coord: Coordinates, Value: type) bool {
    const fields = comptime std.meta.fieldNames(Value);
    return switch (coord) {
        .surface => !hasFields(fields, &.{ "latitude", "longitude" }),
        .gps => !hasFields(fields, &.{ "latitude", "longitude", "altitude" }),
        .xyz => true,
    };
}

/// Transform a set of surface coordinates into a plane of XYZ space.
/// After transforming into XYZ, rotate space and return the YZ plane
pub fn surfaceToPlane(float: type, item: anytype, rotation: *const zlm(float).Mat3) zlm(float).Vec2 {
    const point = surfaceToXYZ(float, item);
    const proj = point.transform(rotation.*);
    return .new(proj.y, proj.z);
}

/// Transform a set of surface coordinates into XYZ space
pub fn surfaceToXYZ(Float: type, item: anytype) zlm(Float).Vec3 {
    const is_vec2 = isVec(.surface, @TypeOf(item));
    const lat = std.math.degreesToRadians(if (is_vec2) item.x else item.latitude);
    const lon = std.math.degreesToRadians(if (is_vec2) item.y else item.longitude);
    const n = square(earth.semimajor) / @sqrt(square(earth.semimajor * @cos(lat)) + square(earth.semiminor * @sin(lat)));
    const n_prime = square(earth.semiminor) / square(earth.semimajor) * n;
    return .new(
        @floatCast(n * @cos(lat) * @cos(lon)),
        @floatCast(n * @cos(lat) * @sin(lon)),
        @floatCast(n_prime * @sin(lat)),
    );
}

/// Transform a set of gps coordinates into XYZ space
pub fn gpsToXYZ(Float: type, item: anytype) zlm(Float).Vec3 {
    const is_vec3 = isVec(.gps, @TypeOf(item));
    const lat: Float = @floatCast(std.math.degreesToRadians(if (is_vec3) item.x else item.latitude));
    const lon: Float = @floatCast(std.math.degreesToRadians(if (is_vec3) item.y else item.longitude));
    const alt: Float = @floatCast(if (is_vec3) item.z else item.altitude);
    const n = square(earth.semimajor) / @sqrt(square(earth.semimajor * @cos(lat)) + square(earth.semiminor * @sin(lat)));
    const n_prime = square(earth.semiminor) / square(earth.semimajor) * n;
    return .new(
        (n + alt) * @cos(lat) * @cos(lon),
        (n + alt) * @cos(lat) * @sin(lon),
        (n_prime + alt) * @sin(lat),
    );
}

/// Transform a set of XYZ coordinates into surface coordinates
/// Assumes the height in the surface result to be exactly 0
pub fn xyzToSurface(Float: type, item: anytype) zlm(Float).Vec2 {
    const x: Float = @floatCast(item.x);
    const y: Float = @floatCast(item.y);
    const z: Float = @floatCast(item.z);

    const p = @sqrt(square(x) + square(y));
    const e2 = comptime 1 - square(earth.semiminor / earth.semimajor);

    return .new(
        std.math.radiansToDegrees(std.math.atan(z / p / (1 - e2))),
        std.math.radiansToDegrees(std.math.atan2(y, x)),
    );
}

/// Transform a set of XYZ coordinates into surface coordinates
pub fn xyzToGPS(Float: type, item: anytype) zlm(Float).Vec3 {
    const x: Float = @floatCast(item.x);
    const y: Float = @floatCast(item.y);
    const z: Float = @floatCast(item.z);

    const p = @sqrt(square(x) + square(y));
    var r_curvature: Float = undefined;
    const e2 = comptime 1 - square(earth.semiminor / earth.semimajor);

    var lat: Float = std.math.atan(z / p / (1 - e2));
    const lon: Float = std.math.atan2(y, x);
    var alt: Float = 0.0;

    for (0..4) |_| {
        r_curvature = earth.semimajor / @sqrt(1 - e2 * square(@sin(lat)));
        alt = p / @cos(lat) - r_curvature;
        lat = std.math.atan(z / p / (1 - e2 * (r_curvature / (r_curvature + alt))));
    }

    return .new(
        std.math.radiansToDegrees(lat),
        std.math.radiansToDegrees(lon),
        alt,
    );
}

test surfaceToXYZ {
    try std.testing.expect(zlm(f32).Vec3.approxEqAbs(
        surfaceToXYZ(f32, zlm(f32).vec2(0.0, 0.0)),
        .new(earth.semimajor, 0.0, 0.0),
        1,
    ));
    try std.testing.expect(zlm(f32).Vec3.approxEqAbs(
        surfaceToXYZ(f32, zlm(f32).vec2(0.0, 90.0)),
        .new(0.0, earth.semimajor, 0.0),
        1,
    ));
    try std.testing.expect(zlm(f32).Vec3.approxEqAbs(
        surfaceToXYZ(f32, zlm(f32).vec2(90.0, 0.0)),
        .new(0.0, 0.0, earth.semiminor),
        1,
    ));
    try std.testing.expect(zlm(f64).Vec3.approxEqAbs(
        surfaceToXYZ(f64, zlm(f64).vec2(41.3825000, 2.1769444)),
        .new(4_789_156.212, 182_050.875, 4_194_389.648),
        0.010,
    ));
}

test gpsToXYZ {
    try std.testing.expect(zlm(f64).Vec3.approxEqAbs(
        gpsToXYZ(f64, zlm(f64).vec3(41.3825000, 2.1769444, 0)),
        .new(4_789_156.212, 182_050.875, 4_194_389.648),
        0.010,
    ));
    try std.testing.expect(zlm(f64).Vec3.approxEqAbs(
        gpsToXYZ(f64, zlm(f64).vec3(48.856667, 2.352222, 10_000)),
        .new(4_207_483.029, 172_831.196, 4_787_616.904),
        0.010,
    ));
}

test xyzToSurface {
    try std.testing.expect(zlm(f32).Vec2.approxEqAbs(
        xyzToSurface(f32, zlm(f32).vec3(earth.semimajor, 0.0, 0.0)),
        .new(0.0, 0.0),
        1,
    ));
    try std.testing.expect(zlm(f32).Vec2.approxEqAbs(
        xyzToSurface(f32, zlm(f32).vec3(0.0, earth.semimajor, 0.0)),
        .new(0.0, 90.0),
        1,
    ));
    try std.testing.expect(zlm(f32).Vec2.approxEqAbs(
        xyzToSurface(f32, zlm(f32).vec3(0.0, 0.0, earth.semiminor)),
        .new(90.0, 0.0),
        1,
    ));
    try std.testing.expect(zlm(f64).Vec2.approxEqAbs(
        xyzToSurface(f64, zlm(f64).vec3(4_789_156.212, 182_050.875, 4_194_389.648)),
        .new(41.3825000, 2.1769444),
        0.010,
    ));
}

test xyzToGPS {
    try std.testing.expect(zlm(f64).Vec3.approxEqAbs(
        xyzToGPS(f64, zlm(f64).vec3(4_789_156.212, 182_050.875, 4_194_389.648)),
        .new(41.3825000, 2.1769444, 0),
        0.010,
    ));
    try std.testing.expect(zlm(f64).Vec3.approxEqAbs(
        xyzToGPS(f64, zlm(f64).vec3(4_207_483.029, 172_831.196, 4_787_616.904)),
        .new(48.856667, 2.352222, 10_000),
        0.010,
    ));
}
