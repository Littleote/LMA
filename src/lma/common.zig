const std = @import("std");

/// Cast a numerical variable to a different precision (or signedness)
/// Caller guarantees the cast is valid
pub inline fn as(T: type, value: anytype) T {
    const input_type = comptime std.meta.activeTag(@typeInfo(@TypeOf(value)));
    const output_type = comptime std.meta.activeTag(@typeInfo(T));
    if (input_type != output_type) {
        @compileError("Unable to change from " ++ @tagName(input_type) ++ " to " ++ @tagName(output_type));
    }
    return switch (input_type) {
        .int => @intCast(value),
        .float => @floatCast(value),
        .optional => if (value) |inner| as(@typeInfo(T).optional.child, inner) else null,
        else => @compileError("Unable to change variable of type " ++ @tagName(input_type)),
    };
}

/// Cast a numerical variable to the specified type
/// Caller guarantees the cast is valid
/// To cast float to int, the caller must ensure it's an exact integer
pub inline fn cast(T: type, value: anytype) T {
    const input_type = comptime std.meta.activeTag(@typeInfo(@TypeOf(value)));
    const output_type = comptime std.meta.activeTag(@typeInfo(T));
    return switch (input_type) {
        .int => switch (output_type) {
            .int => @intCast(value),
            .float => @floatFromInt(value),
            .@"enum" => @enumFromInt(value),
            else => @compileError("Unable to cast from " ++ @tagName(input_type) ++ " to " ++ @tagName(output_type)),
        },
        .float => switch (output_type) {
            .int => @intFromFloat(value),
            .float => @floatCast(value),
            else => @compileError("Unable to cast from " ++ @tagName(input_type) ++ " to " ++ @tagName(output_type)),
        },
        .@"enum" => switch (output_type) {
            .int => @intFromEnum(value),
            else => @compileError("Unable to change from " ++ @tagName(input_type) ++ " to " ++ @tagName(output_type)),
        },
        .optional => if (value) |inner| cast(@typeInfo(T).optional.child, inner) else null,
        else => @compileError("Unable to cast variable of type " ++ @tagName(input_type)),
    };
}

fn Signed(T: type) type {
    return @Int(
        .signed,
        @typeInfo(T).int.bits,
    );
}

/// Apply a signed offset to an unsigned variable
/// Detects both overflow and underflow
///
/// If no overflow protection is needed, use '+%' and bitCast directly
pub fn offset(T: type, a: T, b: Signed(T)) error{Overflow}!T {
    const mask: T = comptime 1 << (@bitSizeOf(T) - 1);
    const out = a +% @as(T, @bitCast(b));
    if ((a ^ @as(T, @bitCast(b))) & (a ^ out) & mask != 0) return error.Overflow;
    return out;
}

/// Calculate the signed offset between two unsigned variables
/// Detects both overflow and underflow
///
/// If noroverflow protection is needed, use '-%' and bitCast directly
pub fn delta(T: type, a: T, b: T) error{Overflow}!Signed(T) {
    const mask: T = comptime 1 << (@bitSizeOf(T) - 1);
    const out = a -% @as(T, @bitCast(b));
    if ((a >= b) == (out & mask != 0)) return error.Overflow;
    return @bitCast(out);
}

test offset {
    try std.testing.expect(12300 == try offset(u32, 12345, -45));
    try std.testing.expect(0 == try offset(u8, 34, -34));
    try std.testing.expect(255 == try offset(u8, 153, 102));
    try std.testing.expect(0 == try offset(u5, 12, -12));
    try std.testing.expect(7 == try offset(u3, 5, 2));

    try std.testing.expectError(error.Overflow, offset(u8, 7, -8));
    try std.testing.expectError(error.Overflow, offset(u8, 213, 107));
    try std.testing.expectError(error.Overflow, offset(u2, 0, -2));
    try std.testing.expectError(error.Overflow, offset(u7, 97, 48));
}

test delta {
    try std.testing.expect(-45 == try delta(u32, 12300, 12345));
    try std.testing.expect(34 == try delta(u8, 34, 0));
    try std.testing.expect(-102 == try delta(u8, 153, 255));
    try std.testing.expect(0 == try delta(u8, 32, 32));
    try std.testing.expect(-128 == try delta(u8, 0, 128));
    try std.testing.expect(127 == try delta(u8, 255, 128));
    try std.testing.expect(0 == try delta(u9, 321, 321));
    try std.testing.expect(2 == try delta(u5, 12, 10));
    try std.testing.expect(-3 == try delta(u3, 4, 7));

    try std.testing.expectError(error.Overflow, delta(u8, 138, 10));
    try std.testing.expectError(error.Overflow, delta(u8, 12, 223));
    try std.testing.expectError(error.Overflow, delta(u2, 0, 3));
    try std.testing.expectError(error.Overflow, delta(u7, 97, 13));
}
