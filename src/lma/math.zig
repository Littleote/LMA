const std = @import("std");

pub inline fn as(T: type, value: anytype) T {
    const input_type = comptime std.meta.activeTag(@typeInfo(@TypeOf(value)));
    const output_type = comptime std.meta.activeTag(@typeInfo(T));
    if (input_type != output_type) {
        @compileError("Unable to change from " ++ @tagName(input_type) ++ " to " ++ @tagName(output_type));
    } else if (input_type != .int and input_type != .float) {
        @compileError("Unable to change variable of type " ++ @tagName(input_type));
    }
    return switch (input_type) {
        .int => @intCast(value),
        .float => @floatCast(value),
        else => unreachable,
    };
}

pub inline fn cast(T: type, value: anytype) T {
    const input_type = comptime std.meta.activeTag(@typeInfo(@TypeOf(value)));
    const output_type = comptime std.meta.activeTag(@typeInfo(T));
    return switch (input_type) {
        .int => switch (output_type) {
            .int => @intCast(value),
            .float => @floatFromInt(value),
            .@"enum" => @enumFromInt(value),
            else => unreachable,
        },
        .float => switch (output_type) {
            .int => @intFromFloat(value),
            .float => @floatCast(value),
            else => unreachable,
        },
        .@"enum" => switch (output_type) {
            .int => @intFromEnum(value),
        },
        else => unreachable,
    };
}

fn Signed(T: type) type {
    return @Int(
        .signed,
        @typeInfo(T).int.bits,
    );
}

pub fn offset(T: type, a: T, b: Signed(T)) (error{Overflow}!T) {
    const mask: T = comptime 1 << (@bitSizeOf(T) - 1);
    const out = a +% @as(T, @bitCast(b));
    if ((a ^ @as(T, @bitCast(b))) & (a ^ out) & mask != 0) return error.Overflow;
    return out;
}

pub fn delta(T: type, a: T, b: T) (error{Overflow}!Signed(T)) {
    const mask: T = comptime 1 << (@bitSizeOf(T) - 1);
    const out = a -% @as(T, @bitCast(b));
    if ((a >= b) == (out & mask == 0)) return error.Overflow;
    return out;
}
