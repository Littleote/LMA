const std = @import("std");
const Allocator = std.mem.Allocator;
const lma = @import("../lma.zig");
const earth = lma.constants.earth;
const math = lma.pipeline.math;
const data = lma.data;

pub const Coordinates = enum {
    surface,
    gps,
    xyz,
};

inline fn square(value: anytype) @TypeOf(value) {
    return value * value;
}

/// Transform a set of surface coordinates into a plane of XYZ space.
/// After transforming into XYZ, rotate space and return the YZ plane
pub fn surfaceToPlane(Float: type, point: math(Float).ElemVec, rotation: *const math(Float).Mat) math(Float).Vec {
    const xyz = surfaceToXYZ(Float, point).build();
    const rot = math(Float).matrix.right(rotation, xyz);
    return rot * math(Float).Axis.maskUntil(.dim(2));
}

/// Transform a set of surface coordinates into XYZ space
pub fn surfaceToXYZ(Float: type, point: math(Float).ElemVec) math(Float).ElemVec {
    const lat = std.math.degreesToRadians(point.x());
    const lon = std.math.degreesToRadians(point.y());
    const n = square(earth.semimajor) / @sqrt(square(earth.semimajor * @cos(lat)) + square(earth.semiminor * @sin(lat)));
    const n_prime = square(earth.semiminor) / square(earth.semimajor) * n;
    return .{ .elems = .{
        n * @cos(lat) * @cos(lon),
        n * @cos(lat) * @sin(lon),
        n_prime * @sin(lat),
        0,
    } };
}

/// Transform a set of gps coordinates into XYZ space
pub fn gpsToXYZ(Float: type, point: math(Float).ElemVec) math(Float).ElemVec {
    const lat = std.math.degreesToRadians(point.x());
    const lon = std.math.degreesToRadians(point.y());
    const alt = point.z();
    const n = square(earth.semimajor) / @sqrt(square(earth.semimajor * @cos(lat)) + square(earth.semiminor * @sin(lat)));
    const n_prime = square(earth.semiminor) / square(earth.semimajor) * n;
    return .{ .elems = .{
        (n + alt) * @cos(lat) * @cos(lon),
        (n + alt) * @cos(lat) * @sin(lon),
        (n_prime + alt) * @sin(lat),
        0,
    } };
}

/// Transform a set of XYZ coordinates into surface coordinates
/// Assumes the height in the surface result to be exactly 0
pub fn xyzToSurface(Float: type, point: math(Float).ElemVec) math(Float).ElemVec {
    const x = point.x();
    const y = point.y();
    const z = point.z();

    const p = @sqrt(square(x) + square(y));
    const e2 = comptime 1 - square(earth.semiminor / earth.semimajor);

    return .{ .elems = .{
        std.math.radiansToDegrees(std.math.atan(z / p / (1 - e2))),
        std.math.radiansToDegrees(std.math.atan2(y, x)),
        0,
        0,
    } };
}

/// Transform a set of XYZ coordinates into surface coordinates
pub fn xyzToGPS(Float: type, point: math(Float).ElemVec) math(Float).ElemVec {
    const x = point.x();
    const y = point.y();
    const z = point.z();

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

    return .{ .elems = .{
        std.math.radiansToDegrees(lat),
        std.math.radiansToDegrees(lon),
        alt,
        0,
    } };
}

test surfaceToXYZ {
    try surfaceToXYZ(f32, .{ .elems = .{ 0.0, 0.0, 0, 0 } }).isApproxEqAbs(.init(.{ earth.semimajor, 0.0, 0.0, 0 }), 1);
    try surfaceToXYZ(f32, .{ .elems = .{ 0.0, 90.0, 0, 0 } }).isApproxEqAbs(.init(.{ 0.0, earth.semimajor, 0.0, 0 }), 1);
    try surfaceToXYZ(f64, .{ .elems = .{ 90.0, 0.0, 0, 0 } }).isApproxEqAbs(.init(.{ 0.0, 0.0, earth.semiminor, 0 }), 1);

    try surfaceToXYZ(f64, .{ .elems = .{ 41.3825000, 2.1769444, 0, 0 } }).isApproxEqAbs(.init(.{ 4_789_156.212, 182_050.875, 4_194_389.648, 0 }), 0.010);
}

test gpsToXYZ {
    try gpsToXYZ(f64, .{ .elems = .{ 41.3825000, 2.1769444, 0.0, 0 } }).isApproxEqAbs(.init(.{ 4_789_156.212, 182_050.875, 4_194_389.648, 0 }), 0.010);
    try gpsToXYZ(f64, .{ .elems = .{ 48.856667, 2.352222, 10_000.0, 0 } }).isApproxEqAbs(.init(.{ 4_207_483.029, 172_831.196, 4_787_616.904, 0 }), 0.010);
}

test xyzToSurface {
    try xyzToSurface(f32, .{ .elems = .{ earth.semimajor, 0.0, 0.0, 0 } }).isApproxEqAbs(.init(.{ 0.0, 0.0, 0, 0 }), 1);
    try xyzToSurface(f32, .{ .elems = .{ 0.0, earth.semimajor, 0.0, 0 } }).isApproxEqAbs(.init(.{ 0.0, 90.0, 0, 0 }), 1);
    try xyzToSurface(f32, .{ .elems = .{ 0.0, 0.0, earth.semiminor, 0 } }).isApproxEqAbs(.init(.{ 90.0, 0.0, 0, 0 }), 1);

    try xyzToSurface(f64, .{ .elems = .{ 4_789_156.212, 182_050.875, 4_194_389.648, 0 } }).isApproxEqAbs(.init(.{ 41.3825000, 2.1769444, 0, 0 }), 0.010);
}

test xyzToGPS {
    try xyzToGPS(f64, .{ .elems = .{ 4_789_156.212, 182_050.875, 4_194_389.648, 0 } }).isApproxEqAbs(.init(.{ 41.3825000, 2.1769444, 0.0, 0 }), 0.010);
    try xyzToGPS(f64, .{ .elems = .{ 4_207_483.029, 172_831.196, 4_787_616.904, 0 } }).isApproxEqAbs(.init(.{ 48.856667, 2.352222, 10_000.0, 0 }), 0.010);
}
