const std = @import("std");

pub const dat_file = @import("data/dat_file.zig");
pub const packets = @import("data/packets.zig");
pub const Packets = packets.Packets;
pub const types = @import("data/types.zig");

pub const ToA = Packets(types.ToA);
pub const Points = Packets(types.Point);
pub const Clusters = Packets(types.Clustered);
pub const Stations = @import("data/Stations.zig");

comptime {
    std.testing.refAllDecls(@This());
}
