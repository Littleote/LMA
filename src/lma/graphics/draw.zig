const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("../lma.zig");
const grid = lma.grid;
const cast = lma.cast;

const Float = grid.Bounds.Float;

const math = lma.math(Float);

pub const map = struct {
    pub fn loadAndDraw(gpa: Allocator, bounds: *const grid.Bounds, color: u8, canvas: []u8, projection: *const math.Mat, r: *Reader) !void {
        var writer_buffer: Writer.Allocating = .init(gpa);
        defer writer_buffer.deinit();
        _ = try r.streamRemaining(&writer_buffer.writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, writer_buffer.written(), .{});
        defer parsed.deinit();
        for (parsed.value.object.get("features").?.array.items) |region| {
            for (region.object.get("geometry").?.object.get("coordinates").?.array.items) |subregion| {
                for (subregion.array.items) |polygon| {
                    var old: math.Vec = math.vector.zero;
                    var new: math.Vec = project(parseCoordinate(polygon.array.items[0]), projection, bounds);
                    for (1..polygon.array.items.len) |idx| {
                        old = new;
                        new = project(parseCoordinate(polygon.array.items[idx]), projection, bounds);
                        drawLine(bounds.shape, canvas, old, new, color);
                    }
                }
            }
        }
    }

    fn parseCoordinate(value: std.json.Value) math.Vec {
        const pair = value.array.items[0..2];
        return math.vector.vec2(@floatCast(pair[1].float), @floatCast(pair[0].float));
    }

    fn project(coord: math.Vec, projection: *const math.Mat, bounds: *const grid.Bounds) math.Vec {
        const point = lma.pipeline.transform.surfaceToPlane(Float, .init(coord), projection);
        return bounds.mapping(point);
    }
};

pub fn drawLine(shape: grid.Shape, canvas: []u8, a: math.Vec, b: math.Vec, color: u8) void {
    const delta = b - a;
    const count = 1 + cast.to(usize, math.vector.normInf(delta));
    const step = delta / math.vector.splat(cast.to(Float, count));
    for (0..count) |idx| {
        drawAt(shape, canvas, .init(a + step * math.vector.splat(cast.to(Float, idx))), color);
    }
}

pub fn drawAt(shape: grid.Shape, canvas: []u8, a: math.ElemVec, color: u8) void {
    const x = @round(a.x());
    const y = @round(a.y());
    if (x >= 0 and y >= 0 and x < cast.to(Float, shape.columns) and y < cast.to(Float, shape.rows)) {
        const idx = shape.ravel(cast.to(usize, y), cast.to(usize, x));
        canvas[idx] = color;
    }
}

test "map" {
    const shape: grid.Shape = comptime .init(240, 240);
    var canvas: [shape.size]u8 = @splat(0);
    for (0..shape.size) |i| {
        canvas[i] = lma.cast.as(u8, i % 240);
    }

    const rotation: math.Mat = blk: {
        const v = math.vector;
        var front = lma.pipeline.transform.surfaceToXYZ(Float, .init(math.vector.vec2(41.70, 1.75))).build();
        var side: math.Vec = v.cross2(v.unit(.z), front);
        var up: math.Vec = v.cross2(front, side);

        up /= v.splat(v.norm2(up));
        side /= v.splat(v.norm2(side));
        front /= v.splat(v.norm2(front));

        const rotation: math.ElemMat = .init(.{ side, up, front, v.zero });
        break :blk rotation.build();
    };

    const bounds: grid.Bounds = .scale(.fromGrid(shape), math.vector.vec2(300_000, 300_000));
    var buffer: [1024]u8 = undefined;
    const input = try std.Io.Dir.cwd().openFile(std.testing.io, "test/input_map.geojson", .{});
    var input_reader = input.reader(std.testing.io, &buffer);

    try map.loadAndDraw(std.testing.allocator, &bounds, 253, &canvas, &rotation, &input_reader.interface);

    const output = try std.Io.Dir.cwd().createFile(std.testing.io, "test/test_map.bmp", .{});
    var output_writer = output.writer(std.testing.io, &buffer);
    try lma.graphics.bitmap.fromBytes(shape, &canvas, &lma.graphics.palettes.marked_black2white, &output_writer.interface);
}
