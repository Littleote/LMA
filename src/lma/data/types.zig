const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const lma = @import("../lma.zig");
const segmented = lma.data.segmented;
const cast = lma.cast;
const dat_file = lma.data.dat_file;

const ParseError = error{InvalidValue};
const ParseConfig = union {
    float_opt: void,
    int_opt: struct { base: u8, has_base: bool },

    pub const float: ParseConfig = .{ .float_opt = {} };
    pub const decimal: ParseConfig = .{ .int_opt = .{ .base = 10, .has_base = false } };
    pub fn intBase(base: u8, has_base: bool) ParseConfig {
        return .{ .int_opt = .{ .base = base, .has_base = has_base } };
    }
};

inline fn parse(T: type, s: ?[]const u8, comptime config: ParseConfig) ParseError!T {
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, s orelse return error.InvalidValue) catch error.InvalidValue,
        .int => std.fmt.parseInt(T, (s orelse return error.InvalidValue)[if (config.int_opt.has_base) 2 else 0..], config.int_opt.base) catch error.InvalidValue,
        else => unreachable,
    };
}

/// Time of arrival data from the LMA stations
pub const Signal = extern struct {
    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: lma.nano.Nano,
    /// Decibels detected with base of 1mW/m²
    dBm: f16,

    padding: u16 = 0,

    pub const List = segmented.Segmented(@This());

    // CSV elements
    pub const csv = segmented.csv(@This(), .{
        .scope = lma.log.hierarchy.signal_file,
        .columns = &.{ "Time", "Decibel-miliwatt" },
        .read = readCsv,
        .write = writeCsv,

        .testing = testing,
    });

    fn writeCsv(self: Signal, w: *Writer, epoch: u64, del: u8) Writer.Error!void {
        try w.print("{1d:.10}{0c}{2d:.3}\n", .{
            del,
            cast.to(f64, epoch) + lma.nano.fromNano(f64, self.nanosecond),
            self.dBm,
        });
    }

    fn readCsv(self: *Signal, line: []const u8, del: u8) ParseError!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const time = std.math.modf(try parse(f64, iterator.next(), .float));
        const epoch: usize = @trunc(time.ipart);
        const nano: u32 = lma.nano.toNano(time.fpart);
        const decibels = try parse(f16, iterator.next(), .float);
        self.* = .{
            .nanosecond = nano,
            .dBm = decibels,
        };
        return epoch;
    }

    // Testing elements
    const testing: segmented.TestConfig(@This()) = .{
        .dummy = dummyValue,
        .eql = eql,
        .approxEql = approxEql,
    };

    pub fn eql(first: Signal, second: Signal) bool {
        return first.nanosecond == second.nanosecond and first.dBm == second.dBm;
    }

    pub fn approxEql(first: Signal, second: Signal) bool {
        return first.nanosecond == second.nanosecond and std.math.approxEqAbs(f16, first.dBm, second.dBm, 1e-1);
    }

    fn dummyValue(rand: std.Random) Signal {
        return .{
            .nanosecond = rand.uintLessThan(u32, lma.nano.ratio),
            .dBm = @floatCast(200 * rand.float(f32) - 110),
        };
    }

    // Binary format elements
    pub const bin = segmented.bin(@This(), .{
        .tag = "signal",
    });

    // Dat format elements
    pub const dat = struct {
        pub const read = dat_file.SignalParser.read;
    };

    pub fn decimate(list: *List, window: lma.nano.Nano) void {
        var start: u32 = 0;
        for (list.headers.items) |*header| {
            var size: u32 = 0;
            var current_window: u32 = 0;
            var best_idx: usize = header.start;
            var best_dBm: f16 = -std.math.inf(f16);
            for (header.get(list.array.items), header.start..) |signal, idx| {
                const new_window = signal.nanosecond / window;
                if (new_window != current_window) {
                    if (best_idx < idx) {
                        list.array.items[start + size] = list.array.items[best_idx];
                        size += 1;
                    }
                    current_window = new_window;

                    best_idx = idx;
                    best_dBm = signal.dBm;
                } else if (signal.dBm > best_dBm) {
                    best_idx = idx;
                    best_dBm = signal.dBm;
                }
            }
            if (best_idx < header.end()) {
                list.array.items[start + size] = list.array.items[best_idx];
                size += 1;
            }
            header.* = .init(start, size);
            start += size;
        }
    }

    fn initArray(comptime nanosecond: []const lma.nano.Nano, comptime dBm: [nanosecond.len]f16) [nanosecond.len]Signal {
        var out: [nanosecond.len]Signal = undefined;
        for (0..nanosecond.len) |idx| {
            out[idx] = .{ .nanosecond = nanosecond[idx], .dBm = dBm[idx] };
        }
        return out;
    }

    test decimate {
        const Nano = lma.nano.Nano;
        var list: List = .init(std.testing.allocator);
        defer list.deinit();
        list.start_epoch = 100;
        try list.headers.appendSlice(list.allocator, &.{ .init(0, 13), .init(13, 0), .init(13, 10) });
        try list.array.appendSlice(list.allocator, &comptime initArray(
            &[_]Nano{ 1, 2, 3, 7, 8, 9 } ++
                &[_]Nano{ 10, 12, 18, 19 } ++
                &[_]Nano{ 35, 39 } ++
                &[_]Nano{40} ++
                &[_]Nano{ 1, 2, 3, 7, 8, 9 } ++
                &[_]Nano{ 10, 12, 18, 19 },
            .{ 1, 2, 3, 7, 8, 9 } ++
                .{ 10, 8, 2, 1 } ++
                .{ 5, 9 } ++
                .{10} ++
                .{ 1, 2, 3, 7, 8, 9 } ++
                .{ 10, 8, 2, 1 },
        ));

        var expected: List = .init(std.testing.allocator);
        defer expected.deinit();
        expected.start_epoch = 100;
        try expected.headers.appendSlice(expected.allocator, &.{ .init(0, 4), .init(4, 0), .init(4, 2) });
        try expected.array.appendSlice(expected.allocator, &comptime initArray(
            &[_]Nano{ 9, 10, 39, 40 } ++
                &[_]Nano{ 9, 10 },
            .{ 9, 10, 9, 10 } ++
                .{ 9, 10 },
        ));

        decimate(&list, 10);

        try std.testing.expect(expected.start_epoch == list.start_epoch);
        try std.testing.expectEqualSlices(segmented.Header, expected.headers.items, list.headers.items);
        for (expected.headers.items, list.headers.items) |e_header, l_header| {
            errdefer std.debug.print("While comparing header {any}\n", .{e_header});
            for (e_header.get(expected.array.items), l_header.get(list.array.items), 0..) |baseline, decimated, idx| {
                errdefer std.debug.print("Expected {any} but found {any} at position {d}\n", .{ baseline, decimated, idx });
                try std.testing.expect(testing.eql(baseline, decimated));
            }
        }
    }

    comptime {
        std.testing.refAllDecls(@This());
    }
};

/// Points indicating the sources of VHF radiation the LMA system captured
pub const Point = extern struct {
    pub const mask_size: comptime_int = @typeInfo(@FieldType(Point, "station_mask")).int.bits;

    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: lma.nano.Nano,

    /// Latitude of the point using WGS84
    latitude: f32,
    /// Longitude of the point using WGS84
    longitude: f32,
    /// Altitude of the point using WGS84
    altitude: f32,

    /// Bitmask indicating which stations where used for this point
    station_mask: u32,
    /// Quality of the fit, lower values indicating a better fit
    measure_error: f16,

    /// Decibels detected with base of 1mW
    dBW: f16,

    /// Number of stations that participated into locating the point
    pub fn station_count(self: *const Point) u8 {
        return @intCast(@popCount(self.station_mask));
    }

    pub fn gps(self: *const Point) lma.math(f32).ElemVec {
        return .{ .elems = .{ self.latitude, self.longitude, self.altitude, 0 } };
    }

    pub const List = segmented.Segmented(@This());

    // CSV elements
    pub const csv = segmented.csv(@This(), .{
        .scope = lma.log.hierarchy.points_file,
        .columns = &.{ "Time", "Latitude", "Longitude", "Altitude", "Decibel-watt", "Station mask", "Fitness" },
        .read = readCsv,
        .write = writeCsv,

        .testing = testing,
    });

    fn writeCsv(self: Point, w: *Writer, epoch: u64, del: u8) Writer.Error!void {
        try w.print("{1d:.10}{0c}{2d:.8}{0c}{3d:.8}{0c}{4d:.3}{0c}{5d:.3}{0c}0x{6x:0>8}{0c}{7d:.2}\n", .{
            del,
            cast.to(f64, epoch) + lma.nano.fromNano(f64, self.nanosecond),
            self.latitude,
            self.longitude,
            self.altitude,
            self.dBW,
            self.station_mask,
            self.measure_error,
        });
    }

    fn readCsv(self: *Point, line: []const u8, del: u8) ParseError!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const time = std.math.modf(try parse(f64, iterator.next(), .float));
        const epoch: usize = @trunc(time.ipart);
        const nano: u32 = lma.nano.toNano(time.fpart);
        const lat = try parse(f32, iterator.next(), .float);
        const lon = try parse(f32, iterator.next(), .float);
        const alt = try parse(f32, iterator.next(), .float);
        const decibels = try parse(f16, iterator.next(), .float);
        const mask = try parse(u32, iterator.next(), .intBase(16, true));
        const fit = try parse(f16, iterator.next(), .float);
        self.* = .{
            .nanosecond = nano,
            .latitude = lat,
            .longitude = lon,
            .altitude = alt,
            .dBW = decibels,
            .station_mask = mask,
            .measure_error = fit,
        };
        return epoch;
    }

    // Testing elements
    const testing: segmented.TestConfig(@This()) = .{
        .dummy = dummyValue,
        .eql = eql,
        .approxEql = approxEql,
    };

    pub fn eql(first: Point, second: Point) bool {
        return std.meta.eql(first, second);
    }

    pub fn approxEql(first: Point, second: Point) bool {
        return
        // zig fmt: off
            // time
            (first.nanosecond == second.nanosecond) and
            // coordinates
            (
                std.math.approxEqAbs(f32, first.latitude, second.latitude, 1e-6) and
                std.math.approxEqAbs(f32, first.longitude, second.longitude, 1e-6) and
                std.math.approxEqAbs(f32, first.altitude, second.altitude, 1e-3)
            ) and
            // mask
            (first.station_mask == second.station_mask) and
            // fitness
            std.math.approxEqAbs(f16, first.measure_error, second.measure_error, 1e-2) and
            // decibels
            std.math.approxEqAbs(f16, first.dBW, second.dBW, 1e-2);
        // zig fmt: on
    }

    pub fn earlier(_: void, first: Point, second: Point) bool {
        return first.nanosecond < second.nanosecond;
    }

    fn dummyValue(rand: std.Random) Point {
        return .{
            .nanosecond = rand.uintLessThan(u32, lma.nano.ratio),
            .latitude = rand.float(f32) * 180 - 90,
            .longitude = rand.float(f32) * 360 - 180,
            .altitude = rand.float(f32) * 20_000 - 1_000,
            .station_mask = rand.int(u32),
            .measure_error = @floatCast(rand.floatExp(f32)),
            .dBW = @floatCast(200 * rand.float(f32) - 110),
        };
    }

    // Binary format elements
    pub const bin = segmented.bin(@This(), .{
        .tag = "point",
    });

    // Dat format elements
    pub const dat = struct {
        pub const read = dat_file.output.read;
        pub const write = dat_file.output.write;
    };

    pub const smooth = smoothing.apply;

    pub const smoothing = struct {
        pub const Config = struct {
            span: usize,
            max_time: f32,
            max_gamma: f32,
            max_pow: f32,
            min_pow_w: f32,

            pub const default: Config = .{
                .span = 100,
                .max_time = 10.0 / @as(comptime_float, std.time.ms_per_s),
                .max_gamma = 1_000.0 / lma.constants.earth.semimajor,
                .max_pow = 10.0,
                .min_pow_w = 0.1,
            };
        };

        const Entry = struct {
            time: f32,
            alpha: f32,
            beta: f32,
            alt: f32,
            dbw: f32,
            index: u32,
            new_alt: f32,
        };

        pub fn apply(list: *List, gpa: std.mem.Allocator, config: Config) error{OutOfMemory}!void {
            if (list.headers.items.len == 0) return;
            const idx0 = list.headers.items[0].start;

            const min_window = config.span * 2 + 1;
            const window_size = min_window;
            const window_half = window_size >> 1;

            var window: std.Deque(Entry) = try .initCapacity(gpa, window_size);
            std.debug.assert(window.buffer.len == window_size);
            defer window.deinit(gpa);

            for (0..window_size) |_| {
                window.pushBackAssumeCapacity(.{
                    .time = -2 * config.max_time,
                    .alpha = 0,
                    .beta = 0,
                    .alt = 0,
                    .dbw = 0,
                    .index = idx0,
                    .new_alt = std.math.nan(f32),
                });
            }

            for (list.headers.items) |header| {
                std.debug.assert(window.len == window_size);
                for (window.buffer) |*value| value.time -= 1;
                for (header.start..header.end()) |idx| {
                    const entry = window.popFront() orelse unreachable;
                    const point = list.array.items[idx];
                    window.pushBackAssumeCapacity(.{
                        .time = lma.nano.fromNano(f32, point.nanosecond),
                        .alpha = point.latitude * std.math.rad_per_deg,
                        .beta = point.longitude * std.math.rad_per_deg,
                        .alt = point.altitude,
                        .dbw = @floatCast(point.dBW),
                        .index = @intCast(idx),
                        .new_alt = std.math.nan(f32),
                    });

                    std.debug.assert(window.len == window_size);
                    const ref = window.atPtr(window_half);
                    ref.new_alt = calculate(ref, window.buffer, config);
                    list.array.items[entry.index].altitude = entry.new_alt;
                }
            }

            for (0..window_size) |_| {
                const entry = window.popFront() orelse unreachable;
                window.pushBackAssumeCapacity(.{
                    .time = 1.0 + 2 * config.max_time,
                    .alpha = 0,
                    .beta = 0,
                    .alt = 0,
                    .dbw = 0,
                    .index = std.math.maxInt(u32),
                    .new_alt = std.math.nan(f32),
                });

                std.debug.assert(window.len == window_size);
                const ref = window.atPtr(window_half);
                ref.new_alt = calculate(ref, window.buffer, config);
                list.array.items[entry.index].altitude = entry.new_alt;
            }
        }

        inline fn calculate(ref: *const Entry, entries: []const Entry, config: Config) f32 {
            var w1: f32 = 0;
            var wx: f32 = 0;
            var wx2: f32 = 0;
            var wy: f32 = 0;
            var wxy: f32 = 0;

            const ref_cos_beta = @cos(ref.beta);
            for (entries) |entry| {
                const x = entry.time - ref.time;
                const y = entry.alt - ref.alt;
                const gamma = std.math.hypot(
                    (entry.alpha - ref.alpha) * ref_cos_beta,
                    entry.beta - ref.beta,
                );
                const pow = entry.dbw - ref.dbw;
                const w = @max(0, 1 - @abs(x) / config.max_time) *
                    @max(0, 1 - gamma / config.max_gamma) *
                    @max(config.min_pow_w, 1 - @abs(pow) / config.max_pow);

                w1 += w;
                wx += w * x;
                wx2 += w * x * x;
                wy += w * y;
                wxy += w * x * y;
            }

            return ref.alt + if (wx2 < 1e-12) 0 else (wx2 * wy - wx * wxy) / (wx2 * w1 - wx * wx);
        }
    };

    comptime {
        std.testing.refAllDecls(@This());
    }
};

/// Points indicating the sources of VHF radiation the LMA system captured
/// The points are classified as either noise with a 0
/// or as part of a lightning with a given id assigned to them
pub const Clustered = extern struct {
    pub const Cluster = enum(u32) {
        noise = 0,
        _,

        pub fn cluster(value: u32) Cluster {
            std.debug.assert(value != Cluster.noise.value);
            return @fromBackingInt(value);
        }

        pub fn isNoise(self: Cluster) bool {
            return self == .noise;
        }

        pub fn id(self: Cluster) ?u32 {
            return if (self.isNoise()) null else @backingInt(self);
        }
    };

    /// Nanoseconds since the start of the second
    /// Value expressed with fixed point 30.2
    nanosecond: lma.nano.Nano,

    /// Latitude of the point using WGS84
    latitude: f32,
    /// Longitude of the point using WGS84
    longitude: f32,
    /// Altitude of the point using WGS84
    altitude: f32,

    /// Cluster assigned to the data point
    cluster: Cluster,

    /// Decibels detected with base of 1mW
    dBW: f16,

    pub fn gps(self: *const Clustered) lma.math(f32).ElemVec {
        return .{ .elems = .{ self.latitude, self.longitude, self.altitude, 0 } };
    }

    pub const List = segmented.Segmented(@This());

    // CSV elements
    pub const csv = segmented.csv(@This(), .{
        .columns = &.{ "Time", "Latitude", "Longitude", "Altitude", "Cluster", "Decibel-watt" },
        .read = readCsv,
        .write = writeCsv,

        .testing = testing,
    });

    pub fn writeCsv(self: Clustered, w: *Writer, epoch: u64, del: u8) Writer.Error!void {
        try w.print("{1d:.10}{0c}{2d:.8}{0c}{3d:.8}{0c}{4d:.3}{0c}{5d}{0c}{6d:.3}\n", .{
            del,
            cast.to(f64, epoch) + lma.nano.fromNano(f64, self.nanosecond),
            self.latitude,
            self.longitude,
            self.altitude,
            @backingInt(self.cluster),
            self.dBW,
        });
    }

    pub fn readCsv(self: *Clustered, line: []const u8, del: u8) ParseError!usize {
        var iterator = std.mem.tokenizeScalar(u8, line, del);
        const time = std.math.modf(try parse(f64, iterator.next(), .float));
        const epoch: usize = @trunc(time.ipart);
        const nano: u32 = lma.nano.toNano(time.fpart);
        const lat = try parse(f32, iterator.next(), .float);
        const lon = try parse(f32, iterator.next(), .float);
        const alt = try parse(f32, iterator.next(), .float);
        _ = iterator.next();
        const decibels = try parse(f16, iterator.next(), .float);
        self.* = .{
            .nanosecond = nano,
            .latitude = lat,
            .longitude = lon,
            .altitude = alt,
            .cluster = .noise,
            .dBW = decibels,
        };
        return epoch;
    }

    // Testing elements
    const testing: segmented.TestConfig(@This()) = .{
        .dummy = dummyValue,
        .eql = eql,
        .approxEql = approxEql,
    };

    pub fn eql(a: Clustered, b: Clustered) bool {
        return std.meta.eql(a, b);
    }

    pub fn approxEql(first: Clustered, second: Clustered) bool {
        return
        // zig fmt: off
            // time
            (first.nanosecond == second.nanosecond) and
            // coordinates
            (
                std.math.approxEqAbs(f32, first.latitude, second.latitude, 1e-6) and
                std.math.approxEqAbs(f32, first.longitude, second.longitude, 1e-6) and
                std.math.approxEqAbs(f32, first.altitude, second.altitude, 1e-3)
            ) and
            // cluster
            (first.cluster == second.cluster) and
            // decibels
            std.math.approxEqAbs(f16, first.dBW, second.dBW, 1e-2);
        // zig fmt: on
    }

    pub fn dummyValue(rand: std.Random) Clustered {
        return .{
            .nanosecond = rand.uintLessThan(u32, lma.nano.ratio),
            .latitude = rand.float(f32) * 180 - 90,
            .longitude = rand.float(f32) * 360 - 180,
            .altitude = rand.float(f32) * 20_000 - 1_000,
            .cluster = .noise,
            .dBW = @floatCast(200 * rand.float(f32) - 110),
        };
    }

    // Binary format elements
    pub const bin = segmented.bin(@This(), .{
        .tag = "cluster",
    });

    comptime {
        std.testing.refAllDecls(@This());
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
