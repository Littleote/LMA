const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lma = @import("lma");
const Grid = lma.pipeline.Grid;
const cast = lma.cast;

const Float = @import("main.zig").Float;

const zlm = lma.pipeline.zlm(Float);

pub fn load(gpa: Allocator, context: *const Context, canvas: []u8, r: *Reader) !void {
    var writer_buffer: Writer.Allocating = .init(gpa);
    defer writer_buffer.deinit();
    _ = try r.streamRemaining(&writer_buffer.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, writer_buffer.written(), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("features").?.array.items) |region| {
        for (region.object.get("geometry").?.object.get("coordinates").?.array.items) |subregion| {
            for (subregion.array.items) |polygon| {
                var old: zlm.Vec2 = undefined;
                var new = context.transform(parsePair(polygon.array.items[0]));
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
    rotation: zlm.Mat3,
    bounds: Grid.Bounds(Float),
    color: u8,

    pub fn transform(self: *const Context, coord: zlm.Vec2) zlm.Vec2 {
        const point = lma.pipeline.transform.surfaceToPlane(Float, coord, &self.rotation);
        return point.sub(self.bounds.origin).div(self.bounds.step);
    }
};

fn parsePair(value: std.json.Value) zlm.Vec2 {
    const pair = value.array.items[0..2];
    return .new(@floatCast(pair[1].float), @floatCast(pair[0].float));
}

fn drawLine(context: *const Context, canvas: []u8, a: zlm.Vec2, b: zlm.Vec2) void {
    const delta = b.sub(a);
    const count = 1 + cast.to(usize, @round(@max(@abs(delta.x), @abs(delta.y))));
    const step = delta.scale(1 / cast.to(Float, count));
    for (0..count) |idx| {
        drawAt(context, canvas, a.add(step.scale(cast.to(Float, idx))));
    }
}

fn drawAt(context: *const Context, canvas: []u8, a: zlm.Vec2) void {
    const x = @round(a.x);
    const y = @round(a.y);
    if (x >= 0 and y >= 0 and x < cast.to(Float, context.bounds.grid.columns) and y < cast.to(Float, context.bounds.grid.rows)) {
        const idx = context.bounds.grid.ravel(cast.to(usize, y), cast.to(usize, x));
        canvas[idx] = context.color;
    }
}
