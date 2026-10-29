const std = @import("std");
const lma = @import("../../lma.zig");
const Candidate = lma.pipeline.match.Candidate;
const Signal = lma.data.Signal;

pub const View = struct {
    list: *const List,
    epoch: u64,

    pub fn get(self: View, reference: Candidate) ?Entry {
        return self.list.map.get(.fromCandidate(self.epoch, reference));
    }

    pub fn buildCandidates(self: View, info: Entry, signals: []const []const Signal, buffer: []Candidate) usize {
        const entries = info.emissions.getConst(SignalId, self.list.signal_ids.items);
        for (entries, buffer[0..entries.len]) |entry, *out| {
            const signal = signals[entry.station][entry.index];
            out.* = .{
                .nanosecond = signal.nanosecond,
                .index = entry.index,
                .dBm = signal.dBm,
                .station = entry.station,
                .mask = .unset,
            };
        }
        return entries.len;
    }

    pub fn append(self: View, signal_ids: []const SignalId) error{OutOfMemory}!u32 {
        try self.list.map.ensureUnusedCapacity(self.list.allocator, signal_ids.len);
        try self.list.entries.ensureUnusedCapacity(self.list.allocator, 1);
        try self.list.signal_ids.ensureUnusedCapacity(self.list.allocator, signal_ids.len);

        const entry: Entry = .{
            .epoch = self.epoch,
            .entry_idx = @intCast(self.list.entries.items.len),
            .emissions = .init(@intCast(self.list.signal_ids.items.len), signal_ids.len),
        };

        self.list.entries.appendAssumeCapacity(entry);
        self.list.signal_ids.appendSliceAssumeCapacity(self.list.allocator, signal_ids);
        for (signal_ids) |signal_id| {
            self.list.map.putAssumeCapacity(.{.fromSignalId(self.epoch, signal_id)}, entry.entry_idx);
        }
    }
};

pub const dat = struct {
    pub fn read(list: *List, r: *std.Io.Reader) lma.data.ParseError!void {
        std.debug.assert(list.map.size == 0);
        std.debug.assert(list.entries.items.len == 0);
        std.debug.assert(list.signal_ids.items.len == 0);

        innerRead(list, r) catch |e| return switch (e) {
            else => |err| err,
            error.StreamTooLong => error.BadFile,
        };
    }

    fn innerRead(list: *List, r: *std.Io.Reader) (error{StreamTooLong} || lma.data.ParseError)!void {
        var epoch_start: u64 = std.math.maxInt(u64);
        var epoch_end: u64 = std.math.minInt(u64);

        var entry_idx: u32 = 0;
        while (try r.takeDelimiter('\n')) |line| {
            defer entry_idx += 1;

            const epoch_str, const entries = std.mem.cutScalar(u8, line, ':') orelse return error.BadFile;
            const epoch = std.fmt.parseInt(u64, epoch_str, 10) catch return error.InvalidValue;
            epoch_start = @min(epoch_start, epoch);
            epoch_end = @max(epoch_start, epoch);

            const start: u32 = @intCast(list.signal_ids.items.len);
            const entry_count: u32 = @intCast(std.mem.countScalar(u8, entries, ';') + 1);
            var iter = std.mem.splitScalar(u8, entries, ';');

            try list.map.ensureUnusedCapacity(list.allocator, entry_count);
            try list.entries.ensureUnusedCapacity(list.allocator, 1);
            try list.signal_ids.ensureUnusedCapacity(list.allocator, entry_count);

            var n: u8 = 0;
            list.entries.appendAssumeCapacity(.{ .epoch = epoch, .entry_idx = entry_idx, .emissions = .init(start, entry_count) });
            while (iter.next()) |entry_str| {
                defer n += 1;

                const station_str, const index_str = std.mem.cutScalar(u8, entry_str, ',') orelse return error.BadFile;
                const station = (std.fmt.parseInt(u8, station_str, 10) catch return error.InvalidValue) - 1;
                const index = std.fmt.parseInt(u16, index_str, 10) catch return error.InvalidValue;

                list.map.putAssumeCapacity(.{ .epoch = epoch, .index = index, .station = station }, entry_idx);
                list.signal_ids.appendAssumeCapacity(.{ .index = index, .station = station, .offset = n });
            }
        }
        if (epoch_start <= epoch_end) {
            list.range = .{ .start = epoch_start, .end = epoch_end };
        }
    }

    pub fn write(list: *List, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (list.entries.items) |entry| {
            try w.print("{d}", .{entry.epoch});
            for (entry.emissions.getConst(SignalId, list.signal_ids)) |signal_id| {
                const sep = if (signal_id.offset == 0) ':' else ';';
                try w.print("{c}{d},{d}", .{ sep, signal_id.station, signal_id.index });
            }
            try w.writeByte('\n');
        }
    }
};

pub const List = struct {
    allocator: std.mem.Allocator,
    map: std.hash_map.AutoHashMapUnmanaged(Key, u32),
    entries: std.ArrayList(Entry),
    signal_ids: std.ArrayList(SignalId),
    range: ?struct { start: u64, end: u64 },

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .allocator = gpa, .map = .empty, .entries = .empty, .signal_ids = .empty, .range = null };
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

    fn fromSignalId(epoch: u64, signal_id: SignalId) Key {
        return .{ .epoch = epoch, .index = signal_id.index, .station = signal_id.station };
    }
};

pub const Entry = struct {
    epoch: u64,
    entry_idx: u32,
    emissions: lma.index.SubSlice,
};

pub const SignalId = struct {
    index: u32,
    station: u8,
    offset: u8,
};
