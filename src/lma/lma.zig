const std = @import("std");
const root = @import("root");

const common = @import("common.zig");
pub const cast = common.cast;
pub const index = common.index;
pub const nano = common.nano;
pub const constants = common.constants;
pub const sort = common.sort;
pub const data = @import("data.zig");
pub const pipeline = @import("pipeline.zig");
pub const graphics = @import("graphics.zig");
pub const math = @import("math").math;
pub const grid = @import("grid.zig");

pub const log = struct {
    pub const scopes = struct {
        pub const global: @EnumLiteral() = .@"LMA default";
        pub const file_rw: @EnumLiteral() = .@"LMA file read/write";
        pub const signal_file: @EnumLiteral() = .@"LMA signal file";
        pub const station_file: @EnumLiteral() = .@"LMA station file";
    };

    pub const hierarchy = struct {
        fn scope_or_default(comptime child: @EnumLiteral(), parent: @EnumLiteral()) @EnumLiteral() {
            inline for (std.options.log_scope_levels) |scope|
                if (scope.scope == child) return child;
            return parent;
        }

        pub const global = scopes.global;
        pub const file_rw: @EnumLiteral() = scope_or_default(scopes.file_rw, global);
        pub const signal_file: @EnumLiteral() = scope_or_default(scopes.signal_file, file_rw);
        pub const station_file: @EnumLiteral() = scope_or_default(scopes.station_file, file_rw);
    };
};

comptime {
    std.testing.refAllDecls(@This());
}
