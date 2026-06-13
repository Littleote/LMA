const std = @import("std");
const lma = @import("../lma.zig");
const Candidate = lma.pipeline.match.Candidate;

const force_probe = false;

pub const Probe = struct {
    data: *ProbeData,
    current_epoch: u64 = 0,
    signals: []const []const lma.data.types.Signal = &.{},
    out: [lma.constants.network.max_network]Candidate = undefined,

    pub fn has(self: *Probe, reference: Candidate) bool {
        return self.data.map.contains(self.key(reference));
    }

    pub fn get(self: *Probe, reference: Candidate, candidates: []const Candidate) ?[]Candidate {
        const value = self.data.map.get(self.key(reference)) orelse return null;
        if (self.data.flags.items[value.probe_id].valid) return null;
        const entries = self.data.getEntries(value);
        if (entries.len < 5) return null;
        var idx: usize = 0;

        for (entries) |entry| {
            self.out[idx] = for (candidates) |candidate| {
                if (entry.station == candidate.station and entry.subindex == candidate.index)
                    break candidate;
            } else if (force_probe)
                .{ .station = entry.station, .index = entry.subindex, .nanosecond = self.signals[entry.station][entry.subindex].nanosecond, .mask = .unset }
            else
                continue;
            idx += 1;
        }

        if (idx < 5) return null;
        self.data.flags.items[value.probe_id].probed = true;
        return self.out[0..idx];
    }

    pub fn mark(self: *const Probe, reference: Candidate, comptime field: enum { valid, found }) void {
        const value = self.data.map.get(self.key(reference)) orelse return;
        @field(self.data.flags.items[value.probe_id], @tagName(field)) = true;
    }

    inline fn key(self: *const Probe, signal: Candidate) Key {
        return .{ .epoch = self.current_epoch, .subindex = signal.index, .station = signal.station };
    }
};

pub const ProbeData = struct {
    allocator: std.mem.Allocator,
    map: std.hash_map.AutoHashMapUnmanaged(Key, Value),
    entries: std.ArrayList(Entry),
    flags: std.ArrayList(Flags),

    pub fn init(gpa: std.mem.Allocator) ProbeData {
        return .{ .allocator = gpa, .map = .empty, .entries = .empty, .flags = .empty };
    }

    pub fn deinit(self: *ProbeData) void {
        self.map.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        {
            var valid: u32 = 0;
            var probed: u32 = 0;
            var found: u32 = 0;
            var valid_not_found: u32 = 0;
            var probed_and_found: u32 = 0;
            for (self.flags.items) |flags| {
                probed += if (flags.probed) 1 else 0;
                valid += if (flags.valid) 1 else 0;
                valid_not_found += if (flags.valid and !flags.found) 1 else 0;
                found += if (flags.found) 1 else 0;
                probed_and_found += if (flags.found and flags.probed) 1 else 0;
            }
            std.log.info("Probes tested: {d}/{d}", .{ probed, self.flags.items.len });
            std.log.info("Valid probes: {d}/{d}", .{ valid, probed });
            std.log.info("Required probe: {d}/{d}", .{ valid_not_found, valid });
            std.log.info("Redundant probes: {d}/{d}", .{ probed_and_found, probed });
            std.log.info("Total redundant probes: {d}/{d}", .{ found, self.flags.items.len });
        }
        self.flags.deinit(self.allocator);
    }

    pub const ParseError = error{ ReadFailed, OutOfMemory, InvalidHeader, InvalidValue, BadFile, UnsupportedVersion };

    pub fn fromDat(self: *ProbeData, r: *std.Io.Reader) ParseError!void {
        self.innerFromDat(r) catch |err| return switch (err) {
            else => |new_err| new_err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerFromDat(self: *ProbeData, r: *std.Io.Reader) (error{StreamTooLong} || ParseError)!void {
        var probe_id: u32 = 0;
        while (try r.takeDelimiter('\n')) |line| {
            defer probe_id += 1;
            const epoch_str, const entries = std.mem.cutScalar(u8, line, ':') orelse return error.BadFile;
            const epoch = std.fmt.parseInt(u64, epoch_str, 10) catch return error.InvalidValue;
            const entry_count: u32 = @intCast(std.mem.countScalar(u8, entries, ';') + 1);
            const start: u32 = @intCast(self.entries.items.len);
            var n: u32 = 0;
            var iter = std.mem.splitScalar(u8, entries, ';');
            try self.map.ensureUnusedCapacity(self.allocator, entry_count);
            try self.entries.ensureUnusedCapacity(self.allocator, entry_count);
            while (iter.next()) |entry_str| {
                defer n += 1;
                const station_str, const subindex_str = std.mem.cutScalar(u8, entry_str, ',') orelse return error.BadFile;
                const station = (std.fmt.parseInt(u8, station_str, 10) catch return error.InvalidValue) - 1;
                const subindex = std.fmt.parseInt(u16, subindex_str, 10) catch return error.InvalidValue;
                self.map.putAssumeCapacity(
                    .{ .epoch = epoch, .subindex = subindex, .station = station },
                    .{ .subslice = .init(start + n, entry_count - n), .probe_id = probe_id },
                );
                self.entries.appendAssumeCapacity(.{ .subindex = subindex, .station = station });
            }
        }
        try self.flags.appendNTimes(self.allocator, .{}, probe_id);
    }

    pub fn getEntries(self: *const ProbeData, value: Value) []const Entry {
        return value.subslice.getConst(Entry, self.entries.items);
    }
};

const Key = extern struct {
    epoch: u64,
    subindex: u16,
    station: u8,
};

const Value = extern struct {
    subslice: lma.index.SubSlice,
    probe_id: u32,
};

const Entry = struct {
    subindex: u16,
    station: u8,
};

const Flags = packed struct(u8) {
    probed: bool = false,
    valid: bool = false,
    found: bool = false,
    padding: u5 = 0,
};
