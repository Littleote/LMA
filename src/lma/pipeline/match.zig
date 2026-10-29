const std = @import("std");

const lma = @import("../lma.zig");
const Signal = lma.data.Signal;
const SubSlice = lma.index.SubSlice;
const Nano = lma.nano.Nano;

pub const probing = @import("match/probing.zig");
pub const search = @import("match/search.zig");
pub const correlation = @import("match/correlation.zig");

pub const Float = f32;
pub const TimeSpan = SubSlice;

/// Data corresponding to a VHF signal from reported by a station
pub const Candidate = struct {
    pub const Mask = u32;
    pub const Bit = std.math.Log2Int(Mask);

    pub const MaybeBit = packed struct(u8) {
        is_set: bool,
        _: @Int(.unsigned, padding_bits) = 0,
        mask_bit: Bit,

        const padding_bits = 8 - 1 - @typeInfo(Bit).int.bits;

        pub fn set(bit: Bit) MaybeBit {
            return .{ .is_set = true, .mask_bit = bit };
        }

        pub const unset: MaybeBit = .{ .is_set = false, .mask_bit = 0 };

        /// Get the bit position or null if mask is unset
        pub inline fn getBit(self: MaybeBit) ?Bit {
            return if (self.is_set) self.mask_bit else null;
        }

        /// Extract the bit corresponding to this bit mask
        pub inline fn isSet(self: MaybeBit, mask: Mask) bool {
            return (mask >> (self.getBit() orelse return false)) & 1 == 1;
        }

        /// Return a mask with only this bit mask set or none set (i.e. zero) if mask is unset
        pub inline fn getMask(self: MaybeBit) Mask {
            return @as(Mask, 1) << (self.getBit() orelse return 0);
        }

        test getBit {
            try std.testing.expect(MaybeBit.unset.getBit() == null);
            try std.testing.expect(MaybeBit.set(0).getBit().? == 0);
            try std.testing.expect(MaybeBit.set(3).getBit().? == 3);
            try std.testing.expect(MaybeBit.set(31).getBit().? == 31);
        }

        test isSet {
            const maskA: Mask = 0xAAAA_AAAA;
            const maskB: Mask = 0x5555_5555;
            try std.testing.expect(!MaybeBit.unset.isSet(maskA));
            try std.testing.expect(!MaybeBit.unset.isSet(maskB));
            try std.testing.expect(!MaybeBit.set(0).isSet(maskA));
            try std.testing.expect(MaybeBit.set(0).isSet(maskB));
            try std.testing.expect(MaybeBit.set(3).isSet(maskA));
            try std.testing.expect(!MaybeBit.set(3).isSet(maskB));
        }

        test getMask {
            try std.testing.expect(MaybeBit.unset.getMask() == 0b00000000_00000000_00000000_00000000);
            try std.testing.expect(MaybeBit.set(0).getMask() == 0b00000000_00000000_00000000_00000001);
            try std.testing.expect(MaybeBit.set(3).getMask() == 0b00000000_00000000_00000000_00001000);
            try std.testing.expect(MaybeBit.set(31).getMask() == 0b10000000_00000000_00000000_00000000);
        }
    };

    /// Event time since start of the second with fixed precision 30.2 ns.
    nanosecond: Nano,
    /// Index of the event in the signal data relative to the start of the second.
    index: u32,
    /// Event power in decibel-milliwatts.
    dBm: f16,
    /// Index of the station that generated the event.
    station: u8,
    /// Bit in the mask to indicate that this event has already been matched.
    mask: MaybeBit,
};

/// Predicate for signal time comparison.
fn signalBefore(time: u32, signal: Signal) bool {
    return signal.nanosecond < time;
}

/// Find the index of the first event at or after the requested time.
pub fn findTime(slice: []const Signal, time: Nano) u32 {
    return @intCast(std.sort.partitionPoint(Signal, slice, time, signalBefore));
}

/// Find the sub-slice corresponding the given time span.
pub fn getSpan(slice: []const Signal, span: TimeSpan) SubSlice {
    const start = findTime(slice, span.start);
    return .init(start, findTime(slice[start..], span.end()));
}

test findTime {
    var buffer: [16]Signal = getSignals(16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    try std.testing.expect(findTime(&buffer, 0) == 0);
    try std.testing.expect(findTime(&buffer, std.math.maxInt(u32)) == 16);
    try std.testing.expect(findTime(&buffer, buffer[12].nanosecond) == 12);
    try std.testing.expect(findTime(&buffer, buffer[3].nanosecond + 5) == 4);
    try std.testing.expect(findTime(&buffer, buffer[9].nanosecond - 5) == 9);
}

test getSpan {
    var sequence: [16]Signal = getSignals(1, &.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 });

    try std.testing.expectEqual(SubSlice.initRange(3, 7), getSpan(&sequence, .initRange(7, 11)));
    try std.testing.expectEqual(SubSlice.initRange(0, 1), getSpan(&sequence, .initRange(1, 5)));
    try std.testing.expectEqual(SubSlice.initRange(13, 16), getSpan(&sequence, .initRange(17, 23)));
}

inline fn getSignals(scale: u32, comptime times: []const u32) [times.len]Signal {
    var out: [times.len]Signal = undefined;
    for (times, &out) |nano, *signal| {
        signal.* = .{
            .nanosecond = scale * nano,
            .dBm = 0.0,
        };
    }
    return out;
}

comptime {
    _ = Candidate;
    _ = Candidate.MaybeBit;

    _ = probing;
    _ = search;
    _ = correlation;
}
