const std = @import("std");
const lma = @import("../../lma.zig");
const Candidate = lma.pipeline.match.Candidate;
const Signal = lma.data.Signal;

pub const View = struct {
    list: *const List,
    epoch: u64,

    pub fn get(self: View, reference: Candidate) ?Info {
        return self.list.map.get(.fromCandidate(self.epoch, reference));
    }

    pub fn candidates(self: View, info: Info, reference: []const []const Signal, buffer: []Candidate) usize {
        const entries = info.emissions.getConst(SignalId, self.list.signal_ids.items);
        for (entries, buffer[0..entries.len]) |entry, *out| {
            const ref = reference[entry.station][entry.index];
            out.* = .{
                .nanosecond = ref.nanosecond,
                .index = entry.index,
                .dBm = ref.dBm,
                .station = entry.station,
                .mask = .unset,
            };
        }
        return entries.len;
    }

    pub fn append(self: View, entries: []const SignalId) error{OutOfMemory}!u32 {
        try self.list.map.ensureUnusedCapacity(self.list.allocator, entries.len);
        try self.list.signal_ids.ensureUnusedCapacity(self.list.allocator, entries.len);

        const info: Info = .{
            .epoch = self.epoch,
            .emissions = .init(@intCast(self.list.signal_ids.items.len), entries.len),
            .probe_id = self.list.next_id(),
        };
        try self.list.signal_ids.appendSliceAssumeCapacity(self.list.allocator, entries);
        for (entries) |entry| {
            try self.list.map.putAssumeCapacity(.{.fromSignalId(self.epoch, entry)}, info);
        }
    }
};

pub const dat = struct {
    pub fn read(list: *List, r: *std.Io.Reader) lma.data.ParseError!void {
        innerRead(list, r) catch |e| return switch (e) {
            else => |err| err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerRead(list: *List, r: *std.Io.Reader) (error{StreamTooLong} || lma.data.ParseError)!void {
        var probe_id: u32 = 0;
        while (try r.takeDelimiter('\n')) |line| {
            defer probe_id += 1;
            const epoch_str, const entries = std.mem.cutScalar(u8, line, ':') orelse return error.BadFile;
            const epoch = std.fmt.parseInt(u64, epoch_str, 10) catch return error.InvalidValue;
            const entry_count: u32 = @intCast(std.mem.countScalar(u8, entries, ';') + 1);
            const start: u32 = @intCast(list.signal_ids.items.len);
            var n: u8 = 0;
            var iter = std.mem.splitScalar(u8, entries, ';');
            try list.signal_ids.ensureUnusedCapacity(list.allocator, 1);
            try list.map.ensureUnusedCapacity(list.allocator, entry_count);
            try list.signal_ids.ensureUnusedCapacity(list.allocator, entry_count);
            while (iter.next()) |entry_str| {
                defer n += 1;
                const station_str, const index_str = std.mem.cutScalar(u8, entry_str, ',') orelse return error.BadFile;
                const station = (std.fmt.parseInt(u8, station_str, 10) catch return error.InvalidValue) - 1;
                const index = std.fmt.parseInt(u16, index_str, 10) catch return error.InvalidValue;
                list.map.putAssumeCapacity(
                    .{ .epoch = epoch, .index = index, .station = station },
                    .{ .epoch = epoch, .emissions = .init(start, entry_count), .probe_id = probe_id },
                );
                list.signal_ids.appendAssumeCapacity(.{ .index = index, .station = station, .offset = n });
            }
        }
    }
};

pub const List = struct {
    allocator: std.mem.Allocator,
    map: std.hash_map.AutoHashMapUnmanaged(Key, Info),
    signal_ids: std.ArrayList(SignalId),
    range: struct { start: u64, end: u64 },

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .allocator = gpa, .map = .empty, .signal_ids = .empty, .range = .{ .start = 0, .end = 86400 } };
    }

    pub fn deinit(self: *List) void {
        self.map.deinit(self.allocator);
        self.signal_ids.deinit(self.allocator);
    }
};

pub const Key = extern struct {
    epoch: u64,
    index: u32,
    station: u8,

    fn fromCandidate(epoch: u64, candidate: Candidate) Key {
        return .{ .epoch = epoch, .index = candidate.index, .station = candidate.station };
    }

    fn signalId(self: Key) SignalId {
        return .{ .index = self.index, .station = self.station };
    }
};

pub const Info = struct {
    epoch: u64,
    probe_id: u32,
    emissions: lma.index.SubSlice,
};

pub const SignalId = struct {
    index: u32,
    station: u8,
    offset: u8,
};
