const std = @import("std");

const lma = @import("../lma.zig");
const Signal = lma.data.Signal;
const Point = lma.data.Point;
const match = lma.pipeline.match;

pub const Float = f64;
pub const MatchFloat = match.Float;
const math = lma.math(Float);
const Vec = math.Vec;
const Mat = math.Mat;
const ToaSolver = @This();

const length = math.vector.norm2;
const vec3 = math.vector.vec3;
const splat = math.vector.splat;

const max_network = lma.constants.network.max_network;
const min_consensus = lma.constants.network.min_consensus;
const early_exit = false;
const preference: enum { max_stations, min_chi_sq } = .min_chi_sq;

pub const Config = struct {
    beam_search: ?match.search.BeamSearch.Options = null,
    depth_first_search: ?match.search.DepthFirstSearch.Options = null,
    probe: ?*match.probing.Probe = null,
    max_distance: Float = 250_000,
};

pub fn init(stations: []const Vec, memory_buffer: []Source, search_buffer: []MatchFloat, config: Config) ToaSolver {
    @memset(memory_buffer, .{ .point = math.vector.zero, .time = -std.math.inf(Float) });
    return .{
        .stations = stations,
        .memory = memory_buffer,
        .search_buffer = search_buffer,
        .config = config,
    };
}

stations: []const Vec,
buffer: Buffer = .empty,
signals: []const []const Signal = &.{},
masking: []match.Candidate.Mask = &.{},
memory: []Source,
search_buffer: []MatchFloat,
statistics: Statistics = .{},
config: Config,

inline fn fromNano(nanosecond: lma.nano.Nano) Float {
    return lma.nano.fromNano(Float, nanosecond);
}

inline fn space_time(space: Vec, time: Float) Vec {
    return space + math.vector.vec4(0, 0, 0, time);
}

pub const c = lma.constants.c / lma.constants.refractive_index.airRange(1_000, 8_000);
pub const rms = 0.000_000_070;
pub const max_chi_sq = 1.5;

pub fn solve(self: *ToaSolver, reference: match.Candidate, candidates: []const match.Candidate, masking: []match.Candidate.Mask, options: *const match.Correlation) ?Point {
    self.masking = masking;
    self.buffer = .at(self.stations[reference.station], c * fromNano(reference.nanosecond));

    var probe_found = false;
    defer if (probe_found) self.config.probe.?.mark(reference, .found);

    if (self.config.probe) |probe| skip: {
        probe_found = probe.has(reference);
        const set = probe.get(reference, candidates) orelse break :skip;
        if (self.solveSet(set, candidates)) |_|
            probe.mark(reference, .valid);
    }

    if (self.config.beam_search) |*config| {
        var iter: match.search.BeamSearch = .init(reference, candidates, self.search_buffer, options, config);

        while (iter.next()) |set| {
            if (self.solveSet(set, candidates)) |source|
                return self.sourceToPoint(&source) orelse if (early_exit) null else continue;
        }
    }

    for (self.memory) |prev_source| {
        if (self.solveFromPoint(reference, &prev_source, candidates)) |source|
            return self.sourceToPoint(&source) orelse if (early_exit) null else continue;
    }

    if (self.config.depth_first_search) |*config| {
        var iter: match.search.DepthFirstSearch = .init(reference, candidates, self.search_buffer, options, config);

        while (iter.next()) |set| {
            if (self.solveSet(set, candidates)) |source|
                return self.sourceToPoint(&source) orelse if (early_exit) null else continue;
        }
    }
    probe_found = false;
    return null;
}

pub fn solveFromPoint(self: *ToaSolver, reference: match.Candidate, base_source: *const Source, candidates: []const match.Candidate) ?Source {
    self.buffer.clear();
    _ = self.buffer.append(&.{
        .point = math.vector.zero,
        .time = 0,
        // .index = reference.index,
        .dBm = reference.dBm,
        .station = reference.station,
        .mask = reference.mask,
    });

    const xyz = base_source.point - self.buffer.ref_point;
    self.statistics.counts.buffer_source += 1;
    self.bufferFromSource(&.{ .point = xyz, .time = -length(xyz) }, candidates, 500);
    if (self.buffer.len < min_consensus) return null;

    const initial: Source = .{ .point = xyz, .time = -length(xyz) };
    self.bufferFromSource(&initial, candidates, 2_000);
    return self.refinedSolution(&initial) orelse return null;
}

pub fn solveSet(self: *ToaSolver, matched: []const match.Candidate, candidates: []const match.Candidate) ?Source {
    self.buffer.clear();
    self.statistics.counts.buffer_set += 1;
    self.bufferFromSet(matched);

    const initial = self.initialSolution() orelse return null;
    self.bufferFromSource(&initial, candidates, 2_000);
    return self.refinedSolution(&initial) orelse return null;
}

fn initialSolution(self: *ToaSolver) ?Source {
    if (self.buffer.len < min_consensus) return null;

    self.statistics.counts.solve_linear += 1;
    var source = solveLinear(&self.buffer);

    // Assert the solution is reasonable
    {
        if (length(source.point) > self.config.max_distance) return null;
        const key_max = bufferError(&self.buffer, &source);
        if (self.buffer.entries[key_max].err > 1_000)
            return null;
    }

    // Enforce constraints
    const trans = lma.pipeline.transform;
    var gps = trans.xyzToGPS(f64, .init(source.point + self.buffer.ref_point));
    gps.refAt(.z).* = @abs(gps.z());
    source = .{
        .point = trans.gpsToXYZ(Float, gps).build() - self.buffer.ref_point,
        .time = -@abs(source.time),
    };

    // Clean solution
    self.statistics.counts.solve_quadratic += 1;
    source = solveLeastSquares(&self.buffer, &source, .{ .termination = .{ .max_iterations = 5 } });
    // Assert the solution is reasonable
    {
        if (length(source.point) > self.config.max_distance) return null;
        if (source.time > 0) return null;
        const key_max = bufferError(&self.buffer, &source);
        if (self.buffer.entries[key_max].err > 500)
            return null;

        const max_error = bufferError(&self.buffer, &source);
        if (max_error > 500) return null;
    }

    self.statistics.counts.out_initial += 1;
    return source;
}

fn refinedSolution(self: *ToaSolver, input: *const Source) ?Source {
    var source: Source = undefined;
    var chi_sq: Float = undefined;
    var worst_station: u8 = undefined;
    while (self.buffer.len >= min_consensus) {

        // Solve quadratic optimization with L-M
        self.statistics.counts.solve_quadratic += 1;
        source = solveLeastSquares(&self.buffer, input, .{ .termination = .{ .max_iterations = 100 } });

        // Assert the solution is reasonable
        {
            if (length(source.point) > self.config.max_distance) return null;
            if (source.time > 0) return null;
            worst_station = self.buffer.entries[bufferError(&self.buffer, &source)].station;
            chi_sq = source.chiSquared(&self.buffer);
            if (chi_sq > max_chi_sq) {
                self.buffer.remove(worst_station);
                continue;
            } else break;
        }
    } else return null;

    switch (preference) {
        .max_stations => {},
        .min_chi_sq => {
            while (self.buffer.len > min_consensus) {

                // Solve quadratic optimization with L-M
                const new_source = blk: {
                    self.buffer.swapLast(worst_station);
                    self.buffer.len -= 1;
                    defer self.buffer.len += 1;

                    self.statistics.counts.solve_quadratic += 1;
                    break :blk solveLeastSquares(&self.buffer, input, .{ .termination = .{ .max_iterations = 100 } });
                };

                // Assert the solution is reasonable
                {
                    if (length(new_source.point) > self.config.max_distance) break;
                    if (new_source.time > 0) break;
                    const new_worst_station = self.buffer.entries[bufferError(&self.buffer, &new_source)].station;
                    const new_chi_sq = new_source.chiSquared(&self.buffer);
                    if (chi_sq > new_chi_sq) {
                        self.buffer.remove(worst_station);
                        chi_sq = new_chi_sq;
                        worst_station = new_worst_station;
                        continue;
                    } else break;
                }
            }
        },
    }
    self.statistics.counts.out_refined += 1;
    return source;
}

/// Solve the TOA problem using a linear approximation and refines the solution with a quadratic optimization method
///
/// **NOTE**: the first element of buffer is expected to be the reference point
fn solveLinear(buffer: *Buffer) Source {
    if (!@reduce(.And, buffer.data[0] == splat(0))) @panic("bad linear input");
    const equations = buffer.len - 1;
    var bias: [max_network]Float = undefined;
    var coef: [max_network]Vec = undefined;
    for (buffer.entries[1..buffer.len], 0..) |entry, idx| {
        const delta = entry.point;
        const delta_t = entry.time;
        bias[idx] = math.vector.sum(delta * delta) - delta_t * delta_t;
        coef[idx] = math.vector.splat(2) * space_time(delta, -delta_t);
    }

    // Solve linear system
    const arr: math.ElemVec = .init(math.matrix.solveSystem(coef[0..equations], bias[0..equations], math.matrix.gaussian.solve));

    return .{
        .point = vec3(arr.x(), arr.y(), arr.z()),
        .time = arr.t(),
    };
}

const ls = least_squares.gauss_newton;
fn solveLeastSquares(buffer: *Buffer, input: *const Source, options: ls.Options) Source {
    const input_vec: Vec = space_time(input.point, input.time);

    // Solve quadratic optimization with L-M
    const arr: math.ElemVec = .init(ls.solve(buffer.data[0..buffer.len], input_vec, options));

    return .{
        .point = vec3(arr.x(), arr.y(), arr.z()),
        .time = arr.t(),
    };
}

pub fn sourceToPoint(self: *ToaSolver, source: *const Source) ?Point {
    const chi_squared = source.chiSquared(&self.buffer);
    if (chi_squared > max_chi_sq) return null;
    const t = (source.time + self.buffer.ref_time) / c;
    if (t < 0.0) return null;
    const xyz = source.point + self.buffer.ref_point;
    const gps = lma.pipeline.transform.xyzToGPS(f64, .init(xyz)).cast(f32);
    if (gps.z() < -1_000.0 or 20_000 < gps.z()) return null;
    const nano = lma.nano.toNano(t);

    self.timing(source);
    self.statistics.counts.out_solutions += 1;
    self.addSource(&.{ .point = source.point + self.buffer.ref_point, .time = source.time + self.buffer.ref_time });

    var mask: u32 = 0;
    for (self.buffer.entries[0..self.buffer.len]) |entry| {
        mask |= @as(u32, 1) << @intCast(entry.station);
        self.masking[entry.station] |= entry.mask.getMask();
    }

    return .{
        .nanosecond = nano,
        .latitude = gps.x(),
        .longitude = gps.y(),
        .altitude = gps.z(),
        .station_mask = mask,
        .measure_error = @floatCast(chi_squared),
        .dBW = @floatCast(source.dBW(&self.buffer)),
    };
}

fn addSource(self: *ToaSolver, source: *const Source) void {
    if (self.memory.len <= 1) {
        if (self.memory.len == 1)
            self.memory[0] = source.*;
        return;
    }
    var old: usize = 0;
    var near: usize = 0;
    var t: Float = self.memory[old].time;
    var dist: Float = length(self.memory[old].point - source.point);
    for (1..self.memory.len) |idx| {
        if (self.memory[idx].time < t) {
            old = idx;
            t = self.memory[old].time;
        }
        const new_dist = length(self.memory[idx].point - source.point);
        if (new_dist < dist) {
            near = idx;
            dist = new_dist;
        }
    }
    if (dist < 500) {
        self.memory[near] = source.*;
    } else {
        self.memory[old] = source.*;
    }
}

fn timing(self: *ToaSolver, source: *const Source) void {
    const denominator = lma.cast.to(Float, self.buffer.len - 4);
    for (self.buffer.entries[0..self.buffer.len]) |entry| {
        const delta = length(source.point - entry.point);
        const err = source.time - entry.time + delta;
        const station = &self.statistics.stations[entry.station];
        station.timing_error += err / denominator;
        station.timing_weight += 1 / denominator;
        station.solutions += 1;
    }
}

pub const Source = struct {
    point: Vec,
    time: Float,

    /// Compute the power as dBW at source from a given buffer.
    pub fn dBW(self: *const Source, buffer: *const Buffer) Float {
        var total: f32 = 0;
        for (buffer.entries[0..buffer.len]) |entry| {
            const dbm: f32 = @floatCast(entry.dBm);
            const area = math.vector.norm2Square(entry.point - self.point);
            const log_surface = 10.0 * @log10(4.0 * std.math.pi * area);
            total += dbm + lma.cast.as(f32, log_surface);
        }
        // Subtract 30 to convert from dBm to dBW
        return (total / buffer.len) - 30.0;
    }

    pub fn toVec(self: *const Source) Vec {
        return space_time(self.point, self.time);
    }

    pub fn fromVec(vec: math.Vec) Source {
        return .{
            .point = math.mask.apply(math.mask.until(3), vec, math.vector.zero),
            .time = math.ElemVec.init(vec).t(),
        };
    }

    pub fn chiSquared(self: *const Source, buffer: *const Buffer) Float {
        const xyz_rms = (rms * c);
        const xyz_rms_squared = xyz_rms * xyz_rms;
        return toa.squareError(buffer.data[0..buffer.len], self.toVec()) / xyz_rms_squared / lma.cast.to(Float, buffer.len - 4);
    }
};

pub const Statistics = struct {
    pub const Counts = struct {
        buffer_set: u32 = 0,
        buffer_source: u32 = 0,
        solve_linear: u32 = 0,
        solve_quadratic: u32 = 0,
        out_initial: u32 = 0,
        out_refined: u32 = 0,
        out_solutions: u32 = 0,
    };

    pub const Station = struct {
        timing_error: f128 = 0,
        timing_weight: f128 = 0,
        solutions: u32 = 0,

        pub fn calibration(self: Station) f32 {
            const constant = -2.0 / c;
            const out: f32 = @floatCast(constant * (self.timing_error / self.timing_weight));

            return if (std.math.isFinite(out)) out else 0;
        }

        pub fn add(self: *Station, other: Station) void {
            inline for (comptime std.meta.fieldNames(Station)) |name| {
                @field(self, name) += @field(other, name);
            }
        }
    };

    counts: Counts = .{},
    stations: [max_network]Station = @splat(.{}),

    pub fn add(self: *Statistics, other: *const Statistics) void {
        inline for (comptime std.meta.fieldNames(Counts)) |name| {
            @field(self.counts, name) += @field(other.counts, name);
        }
        for (&self.stations, other.stations) |*lhs, rhs| {
            lhs.add(rhs);
        }
    }

    pub fn format(self: *const Statistics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        inline for (comptime std.meta.fieldNames(Counts)) |name| {
            try w.print("Variable {s} = {d}\n", .{ name, @field(self.counts, name) });
        }
        {
            try w.print("Station {s: >2}: {s: >12.2} {s: >9}\n", .{ "ID", "Calibration", "Solutions" });
            for (self.stations, 1..) |station, idx| {
                try w.print("Station {d: >2}: {d: >12.2} {d: >9}\n", .{
                    idx, station.calibration() * std.time.ns_per_s, station.solutions,
                });
            }
        }
    }
};

const Buffer = struct {
    const Entry = struct {
        point: Vec,
        time: Float,
        err: Float = std.math.inf(Float),
        // index: u16,
        dBm: f16,
        station: u8,
        mask: match.Candidate.MaybeBit,
    };

    len: u8,
    keys: [max_network]?u8,
    entries: [max_network]Entry,
    data: [max_network]Vec,

    ref_point: Vec,
    ref_time: Float,

    pub const empty: Buffer = .at(math.vector.zero, 0);

    pub fn at(ref_point: Vec, ref_time: Float) Buffer {
        return .{
            .len = 0,
            .keys = @splat(null),
            .entries = undefined,
            .data = undefined,
            .ref_point = ref_point,
            .ref_time = ref_time,
        };
    }

    pub fn clear(self: *Buffer) void {
        self.len = 0;
        self.keys = @splat(null);
    }

    pub fn append(self: *Buffer, obj: *const Entry) u8 {
        const key: u8 = @intCast(if (self.keys[obj.station]) |idx| idx else blk: {
            const key = self.len;
            self.len += 1;
            break :blk key;
        });

        self.entries[key] = obj.*;
        self.data[key] = space_time(obj.point, obj.time);
        self.keys[obj.station] = key;
        return key;
    }

    pub fn swapLast(self: *Buffer, station: u8) void {
        if (self.keys[station]) |key| {
            const last_key = self.len - 1;
            if (key == last_key) return;

            const last_entry = self.entries[last_key];
            self.entries[last_key] = self.entries[key];
            self.entries[key] = last_entry;

            const last_data = self.data[last_key];
            self.data[last_key] = self.data[key];
            self.data[key] = last_data;

            self.keys[station] = last_key;
            self.keys[last_entry.station] = key;
        }
    }

    pub fn remove(self: *Buffer, station: u8) void {
        if (self.keys[station]) |new_key| {
            self.keys[station] = null;
            self.len -= 1;
            const old_key = self.len;

            if (old_key == new_key) return;

            self.entries[new_key] = self.entries[old_key];
            self.data[new_key] = self.data[old_key];
            self.keys[self.entries[new_key].station] = new_key;
        }
    }
};

/// Fill a buffer with the set of signals.
///
/// Overrides previous signals from matching stations.
fn bufferFromSet(self: *ToaSolver, signals: []const match.Candidate) void {
    for (signals) |signal| {
        _ = self.buffer.append(&.{
            .point = self.stations[signal.station] - self.buffer.ref_point,
            .time = c * fromNano(signal.nanosecond) - self.buffer.ref_time,
            // .index = signal.index,
            .dBm = signal.dBm,
            .station = signal.station,
            .mask = signal.mask,
        });
    }
}

/// Fill a buffer with candidates that would give a low error for the given source.
///
/// Overrides previous signals from matching stations that had higher errors
fn bufferFromSource(self: *ToaSolver, source: *const Source, candidates: []const match.Candidate, threshold: Float) void {
    for (candidates) |signal| {
        const point = self.stations[signal.station] - self.buffer.ref_point;
        const time = c * fromNano(signal.nanosecond) - self.buffer.ref_time;
        const err = @abs(source.time + length(point - source.point) - time);
        if (err > threshold) continue;
        if (self.buffer.keys[signal.station]) |key| {
            if (err > self.buffer.entries[key].err) continue;
        }
        _ = self.buffer.append(&.{
            .point = point,
            .time = time,
            .err = err,
            // .index = signal.index,
            .dBm = signal.dBm,
            .station = signal.station,
            .mask = signal.mask,
        });
    }
}

/// Compute the err field of a buffer for a given source and return the greatest error.
///
/// Overrides previous values of errors
fn bufferError(buffer: *Buffer, source: *const Source) u8 {
    var key_max: u8 = 0;
    var max_error: Float = 0;
    for (buffer.entries[0..buffer.len], 0..) |*entry, key| {
        const delta = length(entry.point - source.point);
        const delta_t = entry.time - source.time;
        entry.err = @abs(delta - delta_t);
        if (max_error > entry.err) {
            max_error = entry.err;
            key_max = @intCast(key);
        }
    }
    return key_max;
}

const toa = struct {
    const space: Vec = .{ 1, 1, 1, 0 };
    const time: Vec = .{ 0, 0, 0, 1 };

    pub fn squareError(data: []const Vec, source: Vec) Float {
        var err: Float = 0;
        for (data) |signal_i| {
            const delta = source - signal_i;
            const space_delta = delta * space;
            const time_delta = @reduce(.Add, delta * time);
            const dist = @sqrt(@reduce(.Add, space_delta * delta));

            const err_i = time_delta + dist;
            err += err_i * err_i;
        }
        return err;
    }

    pub inline fn system(data: []const Vec, source: Vec) struct { Mat, Vec } {
        var mat: Mat = @splat(@splat(0));
        var bias: Vec = @splat(0);
        for (data) |signal_i| {
            const delta = source - signal_i;
            const space_delta = delta * space;
            const time_delta = @reduce(.Add, delta * time);
            const dist = @sqrt(@reduce(.Add, space_delta * delta));

            const err_i = time_delta + dist;
            const jac = space_delta / @as(Vec, @splat(dist)) + time;
            const jac_arr: [4]Float = jac;

            for (jac_arr, 0..) |elem, r| mat[r] += jac * @as(Vec, @splat(elem));
            bias -= jac * @as(Vec, @splat(err_i));
        }
        return .{ mat, bias };
    }

    fn lineGradient(data: []const Vec, source: Vec, dir: Vec) struct { Float, Float } {
        var err: Float = 0;
        var grad: Float = 0;
        for (data) |signal_i| {
            const delta = source - signal_i;
            const space_delta = delta * space;
            const time_delta = @reduce(.Add, delta * time);
            const dist = @sqrt(@reduce(.Add, space_delta * delta));

            const err_i = time_delta + dist;
            const jac = space_delta / @as(Vec, @splat(dist)) + time;

            err += err_i * err_i;
            grad += @reduce(.Add, dir * jac) * err_i;
        }
        return .{ err, grad };
    }
};

pub const least_squares = struct {
    pub const Termination = struct {
        pub const Reason = enum {
            none,
            bad_input,
            max_iterations,
            min_gradient,
            min_improvement,
            degenerated,
        };

        max_iterations: usize = 1_000,
        min_gradient: Float = std.math.floatEpsAt(Float, 1),
        min_improvement: Float = std.math.floatEpsAt(Float, 1),
        termination: ?*Reason = null,

        pub fn setTermination(self: *const Termination, reason: Reason) void {
            if (self.termination) |termination| termination.* = reason;
        }
    };

    pub const levenberg_marquardt = struct {
        pub const Options = struct {
            termination: Termination,
            min_rho: Float = 0.1,
            max_delta: Float = 100,
        };

        /// Give an approximate solution to the Toa problem by solving the argument minimization problem
        ///
        /// NOTE: Expects time to be transformed into spatial distance (multiplied by the speed of light constant)
        pub fn solve(data: []const Vec, initial_guess: Vec, opt: Options) Vec {
            var termination: Termination.Reason = .none;
            defer opt.termination.setTermination(termination);
            var delta: Float = 1;
            var lambda: Float = 1;
            const leeway = 0.1;

            var source: Vec = initial_guess;
            var err = toa.squareError(data, initial_guess);
            for (0..opt.termination.max_iterations) |_| {
                const mat: Mat, const bias: Vec = toa.system(data, source);
                const diag = diagonal(&mat);

                var grad = math.matrix.gaussian.solve(&mat, bias);
                const outside: Float = blk: {
                    const scaled_grad = diag * grad;
                    break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad)) - delta;
                };
                const in_border = outside > -leeway * delta;
                if (outside > leeway * delta) {
                    grad = gradient(&mat, bias, lambda);
                    var norm: Float = blk: {
                        const scaled_grad = diag * grad;
                        break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad));
                    };
                    var iter: usize = 0;
                    var lambda_low: Float = 0;
                    while (iter < 10 and norm - delta > leeway * delta) : (iter += 1) {
                        lambda_low = lambda;
                        lambda *= 2;
                        grad = gradient(&mat, bias, lambda);
                        norm = blk: {
                            const scaled_grad = diag * grad;
                            break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad));
                        };
                    }
                    var lambda_high: Float = lambda;
                    while (iter < 10 and @abs(norm - delta) > leeway * delta) : (iter += 1) {
                        lambda = (lambda_low + lambda_high) / 2;
                        grad = gradient(&mat, bias, lambda);
                        norm = blk: {
                            const scaled_grad = diag * grad;
                            break :blk @sqrt(@reduce(.Add, scaled_grad * scaled_grad));
                        };
                        if (norm < delta) {
                            lambda_high = lambda;
                        } else {
                            lambda_low = lambda;
                        }
                    }
                }

                const new_err = toa.squareError(data, source + grad);

                const mat_x_grad: Vec = .{
                    @reduce(.Add, mat[0] * grad),
                    @reduce(.Add, mat[1] * grad),
                    @reduce(.Add, mat[2] * grad),
                    @reduce(.Add, mat[3] * grad),
                };
                const expected_improvement = @reduce(.Add, bias * grad) - @reduce(.Add, grad * mat_x_grad) / 2;
                const rho = (err - new_err) / expected_improvement;
                if (rho < 0.25) {
                    delta /= 4;
                } else if (rho > 0.75 and in_border) {
                    delta = @min(2 * delta, opt.max_delta);
                }

                if (@reduce(.And, @abs(source * @as(Vec, @splat(opt.termination.min_gradient))) >= @abs(grad)))
                    termination = .min_gradient;
                if (err * opt.termination.min_improvement >= expected_improvement)
                    termination = .min_improvement;

                if (rho > opt.min_rho) {
                    source += grad;
                    err = new_err;
                }

                if (termination != .none) break;
            } else termination = .max_iterations;
            return source;
        }

        fn gradient(mat: *const Mat, bias: Vec, lambda: Float) Vec {
            var damp_mat: Mat = undefined;
            const damping: Vec = .{ 1 + lambda, 1, 1, 1 };
            inline for (0..4) |r| damp_mat[r] = mat[r] * std.simd.rotateElementsRight(damping, r);
            return math.matrix.gaussian.solve(&damp_mat, bias);
        }

        fn diagonal(mat: *const Mat) Vec {
            var diag: math.ElemVec = undefined;
            for (0..4) |r| {
                const row: math.ElemVec = .init(mat[r]);
                diag.elems[r] = std.math.clamp(row.elems[r], 1e-8, 1e8);
            }
            return diag.build();
        }
    };

    pub const gauss_newton = struct {
        pub const Options = struct {
            termination: Termination,
            c1: Float = 0.001,
            c2: Float = 0.9,
        };

        /// Give an approximate solution to the Toa problem by solving the argument minimization problem
        ///
        /// NOTE: Expects time to be transformed into spatial distance (multiplied by the speed of light constant)
        pub fn solve(data: []const Vec, initial_guess: Vec, opt: Options) Vec {
            var termination: Termination.Reason = .none;
            defer opt.termination.setTermination(termination);
            var source: Vec = initial_guess;
            var err = toa.squareError(data, initial_guess);
            for (0..opt.termination.max_iterations) |_| {
                const mat: Mat, const bias: Vec = toa.system(data, source);
                const grad: Vec = math.matrix.block.solve(&mat, bias);
                const base_grad = -@reduce(.Add, grad * bias);

                var low: Float = 0;
                var high: Float = 0;
                var alpha: Float = 1;
                var iter: usize = 0;
                const new_err = blk: while (iter < 10) : (iter += 1) {
                    const new_err, const line_grad = toa.lineGradient(data, source + grad * @as(Vec, @splat(alpha)), grad);
                    if (new_err > err + opt.c1 * alpha * base_grad or -line_grad < opt.c2 * base_grad) {
                        high = alpha;
                        alpha = (high + low) / 2;
                    } else if (line_grad < opt.c2 * base_grad) {
                        low = alpha;
                        if (high == 0) alpha *= 2 else alpha = (high + low) / 2;
                    } else break :blk new_err;
                } else toa.squareError(data, source + grad * @as(Vec, @splat(alpha)));

                const scaled_grad = grad * @as(Vec, @splat(alpha));

                if (@reduce(.And, @abs(source * @as(Vec, @splat(opt.termination.min_gradient))) >= @abs(scaled_grad)))
                    termination = .min_gradient;
                if (err * opt.termination.min_improvement >= err - new_err)
                    termination = .min_improvement;

                // Do NOT update the results if the results are degenerate (±inf or NaN)
                if (!std.math.isFinite(new_err)) {
                    termination = .degenerated;
                    break;
                }

                source += scaled_grad;
                err = new_err;

                if (termination != .none) break;
            } else termination = .max_iterations;
            return source;
        }
    };

    pub fn test_cases(Method: type) type {
        return struct {
            test "solve exact" {
                const expected: Vec = .{ 1, 2, 3, 1 };
                const tolerance: Float = 1e-14;
                const actual = Method.solve(
                    &.{
                        .{ 0, 0, 0, 1 + @sqrt(14.0) },
                        .{ 1, 0, 0, 1 + @sqrt(13.0) },
                        .{ 0, 1, 0, 1 + @sqrt(11.0) },
                        .{ 0, 0, 1, 1 + @sqrt(9.0) },
                    },
                    .{ 2, 2, 2, 1 },
                    .{ .termination = .{ .max_iterations = 10, .min_gradient = 1e-15, .min_improvement = 1e-15 } },
                );
                if (!(@reduce(.Max, @abs(actual - expected)) < tolerance)) {
                    const expect_array: math.ElemVec = .init(expected);
                    const actual_array: math.ElemVec = .init(actual);
                    try std.testing.expectEqualSlices(Float, &expect_array.elems, &actual_array.elems);
                }
            }

            test "solve with noise" {
                const source: Vec = vec3(3, 7, 0);
                const time: Float = 3;

                const stations: [8]Vec = .{
                    vec3(0, 0, 0),
                    vec3(8, 0, 0),
                    vec3(0, 4, 0),
                    vec3(0, 0, 3),
                    vec3(0, 1, 1),
                    vec3(1, 0, 9),
                    vec3(5, 6, 0),
                    vec3(6, 3, 4),
                };
                const noise: [8]Float = .{ 0.1, -0.1, 0.0, -0.2, 0.2, 0.0, 0.1, -0.1 };
                const data: [8]Vec = blk: {
                    var buf: [8]Vec = undefined;
                    for (stations, noise, &buf) |station, offset, *signal_i| {
                        signal_i.* = math.vector.extend(3, station, 1, .{time + math.vector.norm2(station - source) + offset});
                    }
                    break :blk buf;
                };

                const actual = Method.solve(
                    &data,
                    .{ 5, 5, 5, 5 + time },
                    .{ .termination = .{ .max_iterations = 50, .min_gradient = 1e-15, .min_improvement = 1e-15 } },
                );

                const expected: Vec = .{ 3.0740512386798056, 6.753612727431825, 0.1813436176620304, 3.2173814008469277 };
                const expected_err = toa.squareError(&data, expected);
                const tolerance_err: Float = 1e-14;
                const actual_err = toa.squareError(&data, actual);
                try std.testing.expect(expected_err <= actual_err);
                try std.testing.expectApproxEqRel(expected_err, actual_err, tolerance_err);

                const tolerance: Float = 1e-8;
                if (!(@reduce(.Max, @abs(actual - expected) / expected) < tolerance)) {
                    const expect_arr: math.ElemVec = .init(expected);
                    const actual_arr: math.ElemVec = .init(actual);
                    std.debug.print("Error of {e} above tolerance {e}\n", .{ @reduce(.Max, @abs(actual - expected)), tolerance });
                    try std.testing.expectEqualSlices(Float, &expect_arr.elems, &actual_arr.elems);
                }
            }
        };
    }

    comptime {
        _ = test_cases(levenberg_marquardt);
        _ = test_cases(gauss_newton);
    }
};

comptime {
    std.testing.refAllDecls(least_squares);
}
