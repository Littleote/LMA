const std = @import("std");
const Allocator = std.mem.Allocator;
const pipe = @import("../pipeline.zig");
const float = pipe.float;
const earth = pipe.constants.earth;
const zlm = @import("zlm").as(float);
const data = @import("../data.zig");

pub inline fn square(value: anytype) @TypeOf(value) {
    return value * value;
}

/// Transform a set of surface coordinates into a plane of XYZ space.
/// After transforming into XYZ, rotate space and return the YZ plane
pub fn surfaceToPlane(item: anytype, rotation: *const zlm.Mat3) zlm.Vec2 {
    const point = surfaceToXYZ(item);
    const proj = point.transform(rotation.*);
    return .new(proj.y, proj.z);
}

/// Transform a set of surface coordinates into XYZ space
pub fn surfaceToXYZ(item: anytype) zlm.Vec3 {
    const is_vec2 = @TypeOf(item) == zlm.Vec2;
    const lat = std.math.degreesToRadians(if (is_vec2) item.x else item.latitude);
    const lon = std.math.degreesToRadians(if (is_vec2) item.y else item.longitude);
    const n = square(earth.semimajor) / std.math.sqrt(square(earth.semimajor * @cos(lat)) + square(earth.semiminor * @sin(lat)));
    const n_prime = square(earth.semiminor) / square(earth.semimajor) * n;
    return .new(
        @floatCast(n * @cos(lat) * @cos(lon)),
        @floatCast(n * @cos(lat) * @sin(lon)),
        @floatCast(n_prime * @sin(lat)),
    );
}

test surfaceToXYZ {
    try std.testing.expect(zlm.Vec3.approxEqAbs(
        surfaceToXYZ(zlm.vec2(0.0, 0.0)),
        .new(earth.semimajor, 0.0, 0.0),
        1,
    ));
    try std.testing.expect(zlm.Vec3.approxEqAbs(
        surfaceToXYZ(zlm.vec2(0.0, 90.0)),
        .new(0.0, earth.semimajor, 0.0),
        1,
    ));
    try std.testing.expect(zlm.Vec3.approxEqAbs(
        surfaceToXYZ(zlm.vec2(90.0, 0.0)),
        .new(0.0, 0.0, earth.semiminor),
        1,
    ));
    try std.testing.expect(zlm.Vec3.approxEqAbs(
        surfaceToXYZ(zlm.vec2(41.3825000, 2.1769444)),
        .new(4_789_156.212, 182_050.875, 4_194_389.648),
        1,
    ));
}
