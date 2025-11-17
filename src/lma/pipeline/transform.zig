const std = @import("std");
const Allocator = std.mem.Allocator;
const pipe = @import("../pipeline.zig");
const float = pipe.float;
const zlm = @import("zlm").as(float);
const data = @import("../data.zig");

pub fn projection(item: anytype, rotation: zlm.Mat3) zlm.Vec2 {
    const lat = std.math.degreesToRadians(item.latitude);
    const lon = std.math.degreesToRadians(item.longitude);
    const point: zlm.Vec3 = .new(
        @floatCast(@cos(lat) * @sin(lon)),
        @floatCast(@sin(lat)),
        @floatCast(@cos(lat) * @cos(lon)),
    );
    const proj = point.transform(rotation);
    return .new(proj.x, proj.y);
}

pub fn coordProjectionTransform(Body: type, items: []const Body, rotation: *const zlm.Mat3, out: *std.ArrayList(zlm.Vec2)) void {
    out.items.len = 0;
    std.debug.assert(out.capacity >= items.len);
    for (items) |item| {
        const lat = std.math.degreesToRadians(item.latitude);
        const lon = std.math.degreesToRadians(item.longitude);
        const point: zlm.Vec3 = .new(
            @floatCast(@cos(lat) * @sin(lon)),
            @floatCast(@sin(lat)),
            @floatCast(@cos(lat) * @cos(lon)),
        );
        const proj = point.transform(rotation.*);
        out.appendAssumeCapacity(.new(proj.x, proj.y));
    }
}
