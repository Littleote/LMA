const std = @import("std");

pub const dat_file = @import("data/dat_file.zig");
pub const segmented = @import("data/segmented.zig");
pub const Segmented = segmented.Segmented;
pub const types = @import("data/types.zig");

pub const ToA = Segmented(types.ToA);
pub const Points = Segmented(types.Point);
pub const Clusters = Segmented(types.Clustered);
pub const Stations = @import("data/Stations.zig");

comptime {
    std.testing.refAllDecls(@This());
}
