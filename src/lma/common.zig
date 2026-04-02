const std = @import("std");

/// Index and size for a subset of a slice
pub const SubSlice = extern struct {
    start: u32,
    size: u32,

    pub fn end(self: SubSlice) u32 {
        return self.start + self.size;
    }

    pub fn init(start: u32, size: u32) SubSlice {
        return .{ .start = start, .size = size };
    }

    pub fn initRange(from: u32, to: u32) SubSlice {
        return .{ .start = from, .size = to - from };
    }

    pub fn get(self: SubSlice, slice: anytype) @TypeOf(slice) {
        return slice[self.start..][0..self.size];
    }

    pub fn getReference(self: SubSlice, T: type, slice: []T) []T {
        return slice[self.start..][0..self.size];
    }

    pub fn getConst(self: SubSlice, T: type, slice: []const T) []const T {
        return slice[self.start..][0..self.size];
    }
};

/// Nanoseconds fraction (modulus 1 second) is compressed with fixed point 30.2
pub const nano = struct {
    /// Ratio between a fixed point 30.2ns value and a floating point 1s value
    pub const ratio = 4 * 1_000_000_000;

    pub inline fn toNano(second: anytype) u32 {
        std.debug.assert(std.math.isFinite(second));
        return @intFromFloat(@round(second * ratio));
    }

    pub inline fn fromNano(Float: type, nanosecond: anytype) Float {
        return @as(Float, @floatFromInt(nanosecond)) / ratio;
    }
};

/// Cast helper functions
pub const cast = struct {
    /// Cast a numerical variable to a different precision (or signedness).
    /// Caller guarantees the cast is valid.
    pub inline fn as(T: type, value: anytype) T {
        const input_type = comptime std.meta.activeTag(@typeInfo(@TypeOf(value)));
        const output_type = comptime std.meta.activeTag(@typeInfo(T));
        if (input_type != output_type) {
            @compileError("Unable to cast \"" ++ @typeName(@TypeOf(value)) ++ "\" as \"" ++ @typeName(T) ++ "\"");
        }
        return switch (input_type) {
            .int => @intCast(value),
            .float => @floatCast(value),
            .optional => if (value) |inner| as(@typeInfo(T).optional.child, inner) else null,
            else => @compileError("Unsupported type \"" ++ @tagName(input_type) ++ "\""),
        };
    }

    /// Cast a numerical variable to the specified type.
    /// Caller guarantees the cast is valid.
    /// To cast float to int, the caller must ensure it's an exact integer.
    pub inline fn to(T: type, value: anytype) T {
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
            else => @compileError("Unsupported type \"" ++ @tagName(input_type) ++ "\""),
        };
    }
};

pub const indexing = struct {
    fn Signed(T: type) type {
        if (T == usize) return isize;
        return @Int(
            .signed,
            @typeInfo(T).int.bits,
        );
    }

    /// Apply a signed offset to an unsigned variable
    /// Both overflow and underflow are checked illegal behaviour
    ///
    /// If overflow protection is needed, use 'offsetWithOverflow' instead
    pub fn offset(T: type, a: T, b: Signed(T)) T {
        const Int = @Int(.signed, @typeInfo(T).int.bits + 1);
        return @intCast(cast.as(Int, a) + cast.as(Int, b));
    }

    /// Apply a signed offset to an unsigned variable
    /// Detects both overflow and underflow
    ///
    /// If no overflow protection is needed, use 'offset' or '+%' and bitCast directly
    pub fn offsetWithOverflow(T: type, a: T, b: Signed(T)) error{Overflow}!T {
        const mask: T = comptime 1 << (@bitSizeOf(T) - 1);
        const out = a +% @as(T, @bitCast(b));
        if ((a ^ @as(T, @bitCast(b))) & (a ^ out) & mask != 0) return error.Overflow;
        return out;
    }

    /// Calculate the signed offset between two unsigned variables
    /// Both overflow and underflow are checked illegal behaviour
    ///
    /// If overflow protection is needed, use 'deltaWithOverflow' instead
    pub fn delta(T: type, a: T, b: T) Signed(T) {
        const Int = @Int(.signed, @typeInfo(T).int.bits + 1);
        return @intCast(cast.as(Int, a) - cast.as(Int, b));
    }

    /// Calculate the signed offset between two unsigned variables
    /// Detects both overflow and underflow
    ///
    /// If no overflow protection is needed, use 'delta' or '-%' and bitCast directly
    pub fn deltaWithOverflow(T: type, a: T, b: T) error{Overflow}!Signed(T) {
        const mask: T = comptime 1 << (@bitSizeOf(T) - 1);
        const out = a -% @as(T, @bitCast(b));
        if ((a >= b) == (out & mask != 0)) return error.Overflow;
        return @bitCast(out);
    }

    test offset {
        try std.testing.expect(12300 == offset(u32, 12345, -45));
        try std.testing.expect(0 == offset(u8, 34, -34));
        try std.testing.expect(255 == offset(u8, 153, 102));
        try std.testing.expect(0 == offset(u5, 12, -12));
        try std.testing.expect(7 == offset(u3, 5, 2));
    }

    test offsetWithOverflow {
        try std.testing.expect(12300 == try offsetWithOverflow(u32, 12345, -45));
        try std.testing.expect(0 == try offsetWithOverflow(u8, 34, -34));
        try std.testing.expect(255 == try offsetWithOverflow(u8, 153, 102));
        try std.testing.expect(0 == try offsetWithOverflow(u5, 12, -12));
        try std.testing.expect(7 == try offsetWithOverflow(u3, 5, 2));

        try std.testing.expectError(error.Overflow, offsetWithOverflow(u8, 7, -8));
        try std.testing.expectError(error.Overflow, offsetWithOverflow(u8, 213, 107));
        try std.testing.expectError(error.Overflow, offsetWithOverflow(u2, 0, -2));
        try std.testing.expectError(error.Overflow, offsetWithOverflow(u7, 97, 48));
    }

    test delta {
        try std.testing.expect(-45 == delta(u32, 12300, 12345));
        try std.testing.expect(34 == delta(u8, 34, 0));
        try std.testing.expect(-102 == delta(u8, 153, 255));
        try std.testing.expect(0 == delta(u8, 32, 32));
        try std.testing.expect(-128 == delta(u8, 0, 128));
        try std.testing.expect(127 == delta(u8, 255, 128));
        try std.testing.expect(0 == delta(u9, 321, 321));
        try std.testing.expect(2 == delta(u5, 12, 10));
        try std.testing.expect(-3 == delta(u3, 4, 7));
    }

    test deltaWithOverflow {
        try std.testing.expect(-45 == try deltaWithOverflow(u32, 12300, 12345));
        try std.testing.expect(34 == try deltaWithOverflow(u8, 34, 0));
        try std.testing.expect(-102 == try deltaWithOverflow(u8, 153, 255));
        try std.testing.expect(0 == try deltaWithOverflow(u8, 32, 32));
        try std.testing.expect(-128 == try deltaWithOverflow(u8, 0, 128));
        try std.testing.expect(127 == try deltaWithOverflow(u8, 255, 128));
        try std.testing.expect(0 == try deltaWithOverflow(u9, 321, 321));
        try std.testing.expect(2 == try deltaWithOverflow(u5, 12, 10));
        try std.testing.expect(-3 == try deltaWithOverflow(u3, 4, 7));

        try std.testing.expectError(error.Overflow, deltaWithOverflow(u8, 138, 10));
        try std.testing.expectError(error.Overflow, deltaWithOverflow(u8, 12, 223));
        try std.testing.expectError(error.Overflow, deltaWithOverflow(u2, 0, 3));
        try std.testing.expectError(error.Overflow, deltaWithOverflow(u7, 97, 13));
    }
};

/// Constant definitions
pub const constants = struct {
    /// Speed of light in a vacuum.
    pub const c = 299_792_458.0;

    /// Refractive index of radio and VHF through different medium
    pub const refractive_index = struct {
        const epsilon: comptime_float = std.math.floatEps(f128);

        pub const vacuum = 1;

        pub fn airAt(height: comptime_float) comptime_float {
            const refractivity_0 = 315.0;
            const height_0 = 7_350.0;
            const refractivity = refractivity_0 * @exp(-height / height_0);
            return 1.0 + 0.000_001 * refractivity;
        }

        fn timeAirUpTo(height: comptime_float) comptime_float {
            if (@abs(height) < epsilon) return airAt(height);
            const refractivity_0 = 315.0;
            const height_0 = 7_350.0;
            return height_0 * @log(airAt(height) / (1.0 + 0.000_001 * refractivity_0)) + height;
        }

        pub fn airUpTo(height: comptime_float) comptime_float {
            if (@abs(height) < epsilon) return airAt(height);
            const time = timeAirUpTo(height);
            return height / time;
        }

        pub fn airRange(from: comptime_float, to: comptime_float) comptime_float {
            std.debug.assert(from <= to);
            if (@abs(to - from) < epsilon) return airAt(from);
            const time = timeAirUpTo(to) - timeAirUpTo(from);
            return (to - from) / time;
        }

        test "Air at surface" {
            try std.testing.expectEqual(airAt(0.0), 1.000_315);
            try std.testing.expectEqual(airUpTo(0.0), 1.000_315);
            try std.testing.expectEqual(airRange(0.0, 0.0), 1.000_315);
        }
    };

    /// Earth minor and major axis
    pub const earth = struct {
        pub const semimajor = 6_378_137.0;
        pub const semiminor = 6_356_752.314_245;
    };

    comptime {
        std.testing.refAllDecls(@This());
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
