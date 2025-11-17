const std = @import("std");

pub const data = @import("data.zig");
pub const pipeline = @import("pipeline.zig");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
