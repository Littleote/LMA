const std = @import("std");

pub const dat_file = @import("data/dat_file.zig");
pub const segmented = @import("data/segmented.zig");

const types = @import("data/types.zig");
pub const Signal = types.Signal;
pub const Point = types.Point;
pub const Clustered = types.Clustered;
pub const Station = @import("data/Station.zig");

comptime {
    std.testing.refAllDecls(@This());
}
