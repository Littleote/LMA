// pub const ToA = @import("data/ToA.zig");
pub const Stations = @import("data/Stations.zig");
// pub const Points = @import("data/Points.zig");
// pub const Clusters = @import("data/Clusters.zig");

pub const dat_file = @import("data/dat_file.zig");
// pub const segmented = @import("data/segmented.zig");
pub const packets = @import("data/packets.zig");
pub const Packets = packets.Packets;
pub const types = @import("data/types.zig");

pub const ToA = Packets(types.ToA);
pub const Points = Packets(types.Point);
pub const Clusters = Packets(types.Clustered);

comptime {
    _ = &Packets;
    _ = &ToA;
    _ = &Points;
    _ = &Clusters;
    // std.testing.refAllDecls(@This());
}
