const std = @import("std");
const Allocator = std.mem.Allocator;
const pipe = @import("../pipeline.zig");
const float = pipe.float;
const zlm = @import("zlm").as(float);
const data = @import("../data.zig");

pub fn coordToPlane(item: anytype, rotation: zlm.Mat3) zlm.Vec2 {
    const point = coordToSpace(item);
    const proj = point.transform(rotation);
    return .new(proj.x, proj.y);
}

pub fn coordToSpace(item: anytype) zlm.Vec3 {
    const is_vec2 = @TypeOf(item) == zlm.Vec2;
    const lat = std.math.degreesToRadians(if (is_vec2) item.x else item.latitude);
    const lon = std.math.degreesToRadians(if (is_vec2) item.y else item.longitude);
    return .new(
        @floatCast(@cos(lat) * @sin(lon)),
        @floatCast(@sin(lat)),
        @floatCast(@cos(lat) * @cos(lon)),
    );
}
