const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const lma = @import("lma");

const Args = @import("Args.zig");
const Float = @import("main.zig").Float;

const Generator = @This();

const zlm = lma.pipeline.zlm(Float);

fn DataInstance(T: type) type {
    return struct {
        data: T,
        iterator: T.Iterator,
    };
}

const Data = union(Args.Stage) {
    clusters: DataInstance(lma.data.Clusters),
    points: DataInstance(lma.data.Points),

    pub fn next(self: *Data, rotation: *const zlm.Mat3) !?[]zlm.Vec2 {
        const generator: *Generator = @fieldParentPtr("data", self);
        switch (self.*) {
            inline else => |*data, tag| {
                const items = data.iterator.next() orelse return null;
                generator.array.items.len = 0;
                try generator.array.ensureTotalCapacity(generator.gpa, items.len);
                for (items) |item| {
                    if (tag != .clusters or !item.cluster.isNoise()) {
                        generator.array.appendAssumeCapacity(lma.pipeline.transform.surfaceToPlane(Float, item, rotation));
                    }
                }
                generator.epoch = data.iterator.epoch;
                return generator.array.items;
            },
        }
    }

    pub fn unload(self: *Data) void {
        switch (self.*) {
            inline else => |*data| {
                data.data.deinit();
            },
        }
        self.* = undefined;
    }

    pub fn load(self: *Data, r: *Reader) !void {
        const generator: *Generator = @fieldParentPtr("data", self);
        const until: lma.data.segmented.IteratorMode = if (generator.current_file >= generator.files.items.len) .until(generator.end) else .all;
        switch (generator.format.stage) {
            .clusters => {
                self.* = .{ .clusters = undefined };
                self.clusters.data = .init(generator.gpa);
                errdefer self.clusters.data.deinit();
                switch (generator.format.file) {
                    .bin => {
                        try self.clusters.data.fromBin(r);
                    },
                    .csv => {
                        try self.clusters.data.fromCsv(r, null);
                    },
                    .dat => {
                        @panic("Unsupported");
                    },
                }
                self.clusters.iterator = self.clusters.data.epochIterator(generator.epoch, until);
            },
            .points => {
                self.* = .{ .points = undefined };
                self.points.data = .init(generator.gpa);
                errdefer self.points.data.deinit();
                switch (generator.format.file) {
                    .bin => {
                        try self.points.data.fromBin(r);
                    },
                    .csv => {
                        try self.points.data.fromCsv(r, null);
                    },
                    .dat => {
                        _ = try lma.data.dat_file.parseOutput(&self.points.data, null, r);
                    },
                }
                self.points.iterator = self.points.data.epochIterator(generator.epoch, until);
            },
        }
    }
};

format: Args.Format,
data: Data,
epoch: usize = 0,
end: usize = 86400,
current_file: usize = 0,
path: []const u8,
files: std.ArrayList([]const u8),
file_buffer: []u8,

gpa: Allocator,
io: std.Io,
array: std.ArrayList(zlm.Vec2),

pub fn init(gpa: Allocator, io: std.Io, input: []const u8, format: Args.Format) !*Generator {
    var path: []const u8 = undefined;
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |file| {
            gpa.free(file);
        }
        files.deinit(gpa);
    }

    if (format.file == .dat and format.stage == .clusters) {
        path = ".";
        try files.append(gpa, try gpa.dupe(u8, input));
    } else {
        path = input;
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            try files.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    const fileOrder = struct {
        pub fn fileOrder(_: void, a: []const u8, b: []const u8) bool {
            const len = @min(a.len, b.len);
            for (0..len) |i| {
                if (a[i] != b[i]) {
                    return a[i] < b[i];
                }
            }
            return a.len < b.len;
        }
    }.fileOrder;
    std.sort.insertion([]const u8, files.items, {}, fileOrder);

    const out = try gpa.create(Generator);
    out.* = .{
        .format = format,
        .data = undefined,
        .path = path,
        .files = files,
        .file_buffer = try gpa.alloc(u8, 1024),
        .gpa = gpa,
        .io = io,
        .array = .empty,
    };
    errdefer gpa.free(out.file_buffer);
    if (out.files.items.len == 0) return error.NoFileFound;
    try out.load();
    return out;
}

pub fn deinit(self: *Generator) void {
    for (self.files.items) |file| {
        self.gpa.free(file);
    }
    self.files.deinit(self.gpa);
    self.data.unload();
    self.gpa.free(self.file_buffer);
    self.array.deinit(self.gpa);
    self.* = undefined;
}

fn load(self: *Generator) !void {
    std.debug.assert(self.current_file < self.files.items.len);
    var dir = try std.Io.Dir.cwd().openDir(self.io, self.path, .{});
    defer dir.close(self.io);
    const file = try dir.openFile(self.io, self.files.items[self.current_file], .{ .mode = .read_only });
    defer file.close(self.io);
    var file_reader = file.reader(self.io, self.file_buffer);
    self.current_file += 1;
    try self.data.load(&file_reader.interface);
}

pub fn next(self: *Generator, rotation: *const zlm.Mat3) !?[]zlm.Vec2 {
    var out: ?[]zlm.Vec2 = try self.data.next(rotation);
    while (out == null) {
        if (self.current_file >= self.files.items.len) return null;
        self.data.unload();
        try self.load();
        out = try self.data.next(rotation);
    }
    return out;
}
