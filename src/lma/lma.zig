const std = @import("std");
const root = @import("root");

pub const common = @import("common.zig");
pub const data = @import("data.zig");
pub const pipeline = @import("pipeline.zig");

pub const constants = struct {
    /// Nanoseconds fraction (modulus 1 second) is compressed with fixed point 30.2
    pub const nano = struct {
        /// Ratio between a fixed 30.2ns value and a floating 1s value
        pub const ratio = 4 * 1_000_000_000;

        pub inline fn toNano(second: anytype) u32 {
            return @intFromFloat(@round(second * ratio));
        }

        pub inline fn fromNano(Float: type, nanosecond: anytype) Float {
            return @as(Float, @floatFromInt(nanosecond)) / ratio;
        }
    };

    /// Speed of light in a vacuum.
    pub const c = 299_792_458.0;

    /// Maximum number of stations expected
    pub const max_stations = if (@hasDecl(root, "lma_options")) root.lma_options.max_stations else data.types.Point.mask_size;

    /// Earth minor and major axis
    pub const earth = struct {
        pub const semimajor = 6_378_137.0;
        pub const semiminor = 6_356_752.314_245;
    };
};

comptime {
    std.testing.refAllDecls(@This());
}
