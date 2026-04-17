const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("lma");
const Grid = lma.pipeline.Grid;
const cast = lma.cast;

const Float = @import("main.zig").Float;

const math = lma.pipeline.math(Float);

pub fn load(gpa: Allocator, context: *const Context, canvas: []u8, r: *Reader) !void {
    var writer_buffer: Writer.Allocating = .init(gpa);
    defer writer_buffer.deinit();
    _ = try r.streamRemaining(&writer_buffer.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, writer_buffer.written(), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("features").?.array.items) |region| {
        for (region.object.get("geometry").?.object.get("coordinates").?.array.items) |subregion| {
            for (subregion.array.items) |polygon| {
                var old: math.Vec = math.vector.zero;
                var new: math.Vec = context.transform(parsePair(polygon.array.items[0]));
                for (1..polygon.array.items.len) |idx| {
                    old = new;
                    new = context.transform(parsePair(polygon.array.items[idx]));
                    drawLine(context, canvas, old, new);
                }
            }
        }
    }
}

pub const Context = struct {
    rotation: math.Mat,
    bounds: Grid.Bounds(Float),
    color: u8,

    pub fn transform(self: *const Context, coord: math.Vec) math.Vec {
        const point = lma.pipeline.transform.surfaceToPlane(Float, .init(coord), &self.rotation);
        return (point - self.bounds.origin) / self.bounds.step;
    }
};

fn parsePair(value: std.json.Value) math.Vec {
    const pair = value.array.items[0..2];
    return math.vector.vec2(@floatCast(pair[1].float), @floatCast(pair[0].float));
}

fn drawLine(context: *const Context, canvas: []u8, a: math.Vec, b: math.Vec) void {
    const delta = b - a;
    const count = 1 + cast.to(usize, math.vector.normInf(delta));
    const step = delta / math.vector.splat(cast.to(Float, count));
    for (0..count) |idx| {
        drawAt(context, canvas, .init(a + step * math.vector.splat(cast.to(Float, idx))));
    }
}

fn drawAt(context: *const Context, canvas: []u8, a: math.ElemVec) void {
    const x = @round(a.x());
    const y = @round(a.y());
    if (x >= 0 and y >= 0 and x < cast.to(Float, context.bounds.grid.columns) and y < cast.to(Float, context.bounds.grid.rows)) {
        const idx = context.bounds.grid.ravel(cast.to(usize, y), cast.to(usize, x));
        canvas[idx] = context.color;
    }
}
