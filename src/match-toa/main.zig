const std = @import("std");
const lma = @import("lma");

const nargs = @import("nargs");

const root = nargs.groups.any("match", .{
    .weight_mode = nargs.params.param("weights", nargs.types.options(Weights), .single, .{ .short = .auto, .default = .decibels }),
    // .station_pair = nargs.params.param("stations", nargs.types.string, .array(2), .{ .short = .auto }),
});

pub const Weights = enum {
    /// Indicator using the mili-watts from the lightinings.
    /// Very noisy, as any misidentified strong lightning has a huge impact.
    power,
    /// Indicator using the decibels with the noise level (-75 dBm) set to zero.
    decibels,
    /// Indicator using a non-parametric rescaling of the power to the range [0, 1].
    cumulative,
    /// Constant value set for all observations
    constant,

    inline fn binning(dBm: f16) usize {
        return @intFromFloat(@trunc(std.math.clamp(dBm + 90, 0, 119)));
    }

    pub fn calculate(method: Weights, slice: []const lma.data.types.ToA, weights: []lma.pipeline.float) void {
        switch (method) {
            .power => {
                const factor = @log2(10.0) / 10.0;
                // Upscale power by 100_000 to make the mean order of magnitude around 1
                for (slice, weights) |toa, *w| w.* = @exp2(16.5 + factor * lma.common.as(lma.pipeline.float, toa.dBm));
            },
            .decibels => {
                // Downscale decibels by 50 to make the mean of the vales around 1
                for (slice, weights) |toa, *w| w.* = (lma.common.as(lma.pipeline.float, toa.dBm) + 75.0) / 50.0;
            },
            .cumulative => {
                var bins: [120]lma.pipeline.float = @splat(0);
                // Set the total to 2 to make the mean of the vales around 1
                const inc = 2.0 / lma.common.cast(lma.pipeline.float, slice.len);
                for (slice) |toa| bins[binning(toa.dBm)] += inc;
                for (1..120) |idx| bins[idx] += bins[idx - 1];
                for (slice, weights) |toa, *w| w.* = bins[binning(toa.dBm)];
            },
            .constant => {
                @memset(weights, 1);
            },
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = allocator.deinit();
    const gpa = allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    _ = root;

    var buffer: [1024]u8 = undefined;
    const weight_mode: Weights = .decibels;

    var stations: lma.data.Stations = .init(gpa);
    defer stations.deinit();
    {
        const file = try std.Io.Dir.cwd().openFile(io, "data/ToA/stations/stations.bin", .{});
        defer file.close(io);
        var file_reader = file.reader(io, &buffer);
        try stations.fromBin(&file_reader.interface);
    }

    const signals = try gpa.alloc(lma.data.ToA, stations.stations.items.len);
    for (signals) |*signal| signal.* = .init(gpa);
    defer {
        for (signals) |*signal| signal.deinit();
        gpa.free(signals);
    }

    const slices = try gpa.alloc([]const lma.data.types.ToA, stations.stations.items.len);
    @memset(slices, &.{});
    defer gpa.free(slices);

    const weights = try gpa.alloc(std.ArrayList(lma.pipeline.float), stations.stations.items.len);
    @memset(weights, .empty);
    defer {
        for (weights) |*weight| weight.deinit(gpa);
        gpa.free(weights);
    }

    const divide = 10;
    const divisions = try gpa.alloc([divide + 1]u32, stations.stations.items.len);
    defer gpa.free(divisions);

    const files = try std.Io.Dir.cwd().openDir(io, "data/ToA/250712/bin", .{ .iterate = true });
    defer files.close(io);
    var it = files.iterate();
    while (try it.next(io)) |entry| {
        var split = std.mem.splitScalar(u8, entry.name, '_');
        // CODE_GROUP_NAME_DATE_TIME
        _, _, const name = .{ split.next().?, split.next().?, split.next().? };

        const file = try files.openFile(io, entry.name, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &buffer);

        for (stations.stations.items, 0..) |info, idx| {
            if (std.mem.eql(u8, info.name.?, name)) {
                try signals[idx].fromBin(&file_reader.interface);
            }
        }
    }

    for (0..10 * 60) |t| {
        for (signals, slices, weights, divisions) |signal, *slice, *weight, *division| {
            slice.* = signal.valuesAt(signal.epochIndex(12 * 60 * 60 + t, .exact));
            weight.items.len = 0;
            try weight.ensureTotalCapacity(gpa, slice.len);
            weight.items.len = slice.len;
            weight_mode.calculate(slice.*, weight.items);
            lma.pipeline.match.divide(slice.*, division);
        }

        for (0..divide) |division| {
            for (0..stations.stations.items.len) |a| {
                const div_a = divisions[a][division..];
                for (a + 1..stations.stations.items.len) |b| {
                    const div_b = divisions[b][division..];
                    var corr: [255]lma.pipeline.float = undefined;
                    var scaled: [255]lma.pipeline.float = undefined;
                    lma.pipeline.match.correlation(
                        slices[a][div_a[0]..div_a[1]],
                        weights[a].items[div_a[0]..div_a[1]],
                        slices[b][div_b[0]..div_b[1]],
                        weights[b].items[div_b[0]..div_b[1]],
                        &corr,
                        .fromStep(0.000_008_000),
                    );
                    lma.pipeline.match.quantile_scale(&corr, &scaled);
                    // for (scaled, 0..) |p, i_offset| {
                    //     const i = lma.common.delta(usize, 128, i_offset) catch unreachable;
                    //     if (p > 3) std.debug.print("[{d: >2}]-[{d: >2}], {d: >4} -> {d}\n", .{ a, b, i, p });
                    // }
                }
            }
        }
    }
}
