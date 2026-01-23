const std = @import("std");

pub const grid = @import("pipeline/grid.zig");
pub const holes = @import("pipeline/holes.zig");
pub const image = @import("pipeline/image.zig");
pub const match = @import("pipeline/match.zig");
/// Transform between coordinate systems
///
/// `surface` i.e. geodetic polar coordinates without height:
/// Latitude and longitude without height in WGS84 expressed in degrees.
/// Input may be either a 2D vector with 'x' latitude and 'y' longitude
/// or a struct with the fileds 'latitude' and 'longitude'.
/// Outputs are limited to a 2D vector
///
/// `gps` i.e. geodetic polar coordinates (with height):
/// Latitude, longitude and height in WGS84 expressed in degrees.
/// Input may be either a 3D vector with 'x' latitude, 'y' longitude and 'z' altitude
/// or a struct with the fileds 'latitude', 'longitude' and 'altitude'.
/// Outputs are limited to a 3D vector
///
/// `xyz` i.e. geocentric cartesian coordinates:
/// X represents (00ºN, 00ºE)
/// Y represents (00ºN, 90ºE)
/// Z represents (90ºN, 00ºE)
pub const transform = @import("pipeline/transform.zig");

pub const float = f32;
pub const constants = struct {
    pub const c = 299_792_458.0;
    pub const earth = struct {
        pub const semimajor = 6_378_137.0;
        pub const semiminor = 6_356_752.314_245;
    };
};

comptime {
    std.testing.refAllDecls(@This());
}
