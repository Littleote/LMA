const std = @import("std");

const lma = @import("../lma.zig");
const Toa = lma.data.types.Toa;
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

inline fn space_time(space: Vec, time: Float) Vec {
    return space + math.vector.vec4(0, 0, 0, time);
}

pub const Counts = struct {
    buffer_set: usize = 0,
    buffer_source: usize = 0,
    solve_linear: usize = 0,
    solve_lm: usize = 0,
    out_initial: usize = 0,
    out_refined: usize = 0,
    out_solutions: usize = 0,

    pub fn add(self: *Counts, other: *const Counts) void {
        inline for (@typeInfo(Counts).@"struct".fields) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

pub const Config = struct {
    beam_search: ?match.BeamSearch.Options = null,
    depth_first_search: ?match.DepthFirstSearch.Options = null,
    max_distance: Float = 200_000,
};

pub const Source = struct {
    point: Vec,
    time: Float,

    /// Compute the power as dBW at source from a buffer.
    fn dBW(self: *const Source, signals: []const []const Toa, buffer: *const Buffer) Float {
        var total: f32 = 0;
        for (buffer.entries[0..buffer.len]) |entry| {
            const dbm: f32 = @floatCast(signals[entry.station][entry.index].dBm);
            const area = math.vector.norm2Square(entry.point - self.point);
            const log_surface = 10.0 * @log10(4.0 * std.math.pi * area);
            total += dbm + lma.cast.as(f32, log_surface);
        }
        // Subtract 30 to convert from dBm to dBW
        return (total / buffer.len) - 30.0;
    }

    fn isFinite(self: *const Source) bool {
        return std.math.isFinite(self.time);
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

    pub fn toPoint(self: *const Source, solver: *const ToaSolver, buffer: *const Buffer) lma.data.types.Point {
        const chi_sq = toa_problem.sqError(buffer.data[0..buffer.len], self.toVec()) / xyz_rms_squared / lma.cast.to(Float, buffer.len - 4);
        const xyz = self.point + buffer.ref_point;
        const t = (self.time + buffer.ref_time) / c;
        const gps = lma.pipeline.transform.xyzToGPS(f64, .init(xyz)).cast(f32);
        const nano = lma.nano.toNano(t);
        if (nano == std.math.maxInt(u32)) {
            std.debug.print("{any}\n", .{self});
            for (buffer.entries[0..buffer.len]) |entry| {
                std.debug.print("{any}\n", .{entry});
            }
            @panic("Bad time");
        }
        var mask: u32 = 0;
        for (buffer.entries[0..buffer.len]) |entry| {
            mask |= @as(u32, 1) << @intCast(entry.station);
        }

        return .{
            .nanosecond = nano,
            .latitude = gps.x(),
            .longitude = gps.y(),
            .altitude = gps.z(),
            .station_mask = mask,
            .measure_error = @floatCast(chi_sq),
            .dBW = @floatCast(self.dBW(solver.signals, buffer)),
        };
    }
};

const Buffer = struct {
    const Entry = struct {
        point: Vec,
        time: Float,
        err: Float = std.math.inf(Float),
        index: u16,
        station: u8,
        mask: match.Signal.MaskBit,
    };

    len: u8,
    keys: [max_network]?u8,
    entries: [max_network]Entry,
    data: [max_network]Vec,

    ref_point: Vec,
    ref_time: Float,

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

stations: []const Vec,
signals: []const []const Toa = &.{},
counts: Counts = .{},
memory: []Source,
search_buffer: []MatchFloat,
config: Config,

pub fn init(stations: []const Vec, memory_buffer: []Source, search_buffer: []MatchFloat, config: Config) ToaSolver {
    @memset(memory_buffer, .{ .point = math.vector.zero, .time = -std.math.inf(Float) });
    return .{
        .stations = stations,
        .memory = memory_buffer,
        .search_buffer = search_buffer,
        .config = config,
    };
}

inline fn fromNano(nanosecond: lma.nano.Nano) Float {
    return lma.nano.fromNano(Float, nanosecond);
}

const c = lma.constants.c / lma.constants.refractive_index.airRange(1_000, 8_000);

const xyz_rms = (0.000_000_040 * c);
const xyz_rms_squared = xyz_rms * xyz_rms;

pub fn solve(self: *ToaSolver, initial: match.Signal, candidates: []const match.Signal, skip: []u32, options: *const match.Matching.Correlation) ?lma.data.types.Point {
    if (self.config.beam_search) |*config| {
        var iter: match.BeamSearch = .init(initial, candidates, self.search_buffer, options, config);

        while (iter.next()) |set| {
            if (self.solveSet(set, candidates, skip)) |point| return point;
        }
    }

    for (self.memory) |prev_source| {
        if (self.solveFromPoint(initial, &prev_source, candidates, skip)) |point| return point;
    }

    if (self.config.depth_first_search) |*config| {
        var iter: match.DepthFirstSearch = .init(initial, candidates, self.search_buffer, options, config);

        while (iter.next()) |set| {
            if (self.solveSet(set, candidates, skip)) |point| return point;
        }
    }
    return null;
}

fn initialSolution(self: *ToaSolver, buffer: *Buffer) ?Source {
    if (buffer.len < 5) return null;

    self.counts.solve_linear += 1;
    var source = solveLinear(buffer);

    // Assert the solution is reasonable
    {
        if (length(source.point) > self.config.max_distance) return null;
        const max_error = bufferError(buffer, &source);
        if (max_error > 1_000) return null;
    }

    // Enforce constraints
    const trans = lma.pipeline.transform;
    var gps = trans.xyzToGPS(f64, .init(source.point + buffer.ref_point));
    gps.refAt(.z).* = @abs(gps.z());
    source = .{
        .point = trans.gpsToXYZ(Float, gps).build() - buffer.ref_point,
        .time = -@abs(source.time),
    };

    // Clean solution
    self.counts.solve_lm += 1;
    source = solveGN(buffer, &source, .{ .common = .{ .max_iterations = 5 } }) catch return null;
    // Assert the solution is reasonable
    {
        if (length(source.point) > self.config.max_distance) return null;
        if (source.time > 0) return null;
        const max_error = bufferError(buffer, &source);
        if (max_error > 500) return null;
    }

    self.counts.out_initial += 1;
    return source;
}

fn refinedSolution(self: *ToaSolver, buffer: *Buffer, input: *const Source) ?Source {
    if (buffer.len < 5) return null;

    // Solve quadratic optimization with L-M
    self.counts.solve_lm += 1;
    const source = solveGN(buffer, input, .{ .common = .{ .max_iterations = 100 } }) catch return null;

    // Assert the solution is reasonable
    {
        if (length(source.point) > self.config.max_distance) return null;
        if (source.time > 0) return null;
        const max_error = bufferError(buffer, &source);
        if (max_error > 150) return null;
    }

    self.counts.out_refined += 1;
    return source;
}

fn validateSolution(self: *ToaSolver, buffer: *Buffer, source: *const Source) bool {
    const chi_sq = toa_problem.sqError(buffer.data[0..buffer.len], source.toVec()) / xyz_rms_squared / lma.cast.to(Float, buffer.len - 4);
    const t = (source.time + buffer.ref_time) / c;

    if (t <= 0) return false;
    if (chi_sq > 5) return false;

    _ = self;
    return true;
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

/// Fill a buffer with the set of signals.
///
/// Overrides previous signals from matching stations.
fn bufferFromSet(self: *const ToaSolver, buffer: *Buffer, signals: []const match.Signal) void {
    for (signals) |signal| {
        _ = buffer.append(&.{
            .point = self.stations[signal.station] - buffer.ref_point,
            .time = c * fromNano(signal.nanosecond) - buffer.ref_time,
            .index = signal.index,
            .station = signal.station,
            .mask = signal.mask,
        });
    }
}

/// Fill a buffer with candidates that would give a low error for the given source.
///
/// Overrides previous signals from matching stations that had higher errors
fn bufferFromSource(self: *const ToaSolver, buffer: *Buffer, source: *const Source, candidates: []const match.Signal, threshold: Float) void {
    for (candidates) |signal| {
        const point = self.stations[signal.station] - buffer.ref_point;
        const time = c * fromNano(signal.nanosecond) - buffer.ref_time;
        const err = @abs(source.time + length(point - source.point) - time);
        if (err > threshold) continue;
        if (buffer.keys[signal.station]) |key| {
            if (err > buffer.entries[key].err) continue;
        }
        _ = buffer.append(&.{
            .point = point,
            .time = time,
            .err = err,
            .index = signal.index,
            .station = signal.station,
            .mask = signal.mask,
        });
    }
}

/// Compute the err field of a buffer for a given source and return the greatest error.
///
/// Overrides previous values of errors
fn bufferError(buffer: *Buffer, source: *const Source) Float {
    var max_error: Float = 0;
    for (buffer.entries[0..buffer.len]) |*entry| {
        const delta = length(entry.point - source.point);
        const delta_t = entry.time - source.time;
        entry.err = @abs(delta - delta_t);
        max_error = @max(max_error, entry.err);
    }
    return max_error;
}

/// Solve the TOA problem using a linear approximation and refines the solution with Levenberg-Marquardt
///
/// **NOTE**: the first element of buffer is expected to be the reference point
pub fn solveLinear(buffer: *Buffer) Source {
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
    if (!std.math.isFinite(arr.t())) {
        std.debug.print("{any}\n{any}\n", .{ coef[0..equations], bias[0..equations] });
        @panic("bad linear output");
    }
    return .{
        .point = vec3(arr.x(), arr.y(), arr.z()),
        .time = arr.t(),
    };
}

pub fn solveLM(buffer: *Buffer, input: *const Source, options: least_squares.lm.LMOptions) error{NonFinite}!Source {
    const input_vec: Vec = .{ input.point.x, input.point.y, input.point.z, input.time };

    // Solve quadratic optimization with L-M
    const arr: [4]Float = least_squares.lm.solve(buffer.data[0..buffer.len], input_vec, options);
    // std.debug.assert(std.math.isFinite(arr[3]));

    const out: Source = .{
        .point = vec3(arr.x(), arr.y(), arr.z()),
        .time = arr.t(),
    };
    return if (out.isFinite()) out else error.NonFinite;
}

pub fn solveGN(buffer: *Buffer, input: *const Source, options: least_squares.gn.GNOptions) error{NonFinite}!Source {
    const input_vec: Vec = space_time(input.point, input.time);

    // Solve quadratic optimization with L-M
    const arr: math.ElemVec = .init(least_squares.gn.solve(buffer.data[0..buffer.len], input_vec, options));

    const out: Source = .{
        .point = vec3(arr.x(), arr.y(), arr.z()),
        .time = arr.t(),
    };
    return if (out.isFinite()) out else error.NonFinite;
}

pub fn solveFromPoint(self: *ToaSolver, reference: match.Signal, base_source: *const Source, candidates: []const match.Signal, skip: []u32) ?lma.data.types.Point {
    var buffer: Buffer = .at(self.stations[reference.station], c * fromNano(reference.nanosecond));
    const base_point = base_source.point;
    buffer.clear();
    _ = buffer.append(&.{
        .point = math.vector.zero,
        .time = 0,
        .index = reference.index,
        .station = reference.station,
        .mask = reference.mask,
    });

    const xyz = base_point - buffer.ref_point;
    self.counts.buffer_source += 1;
    self.bufferFromSource(&buffer, &.{ .point = xyz, .time = -length(xyz) }, candidates, 1_000);
    const initial = self.initialSolution(&buffer) orelse return null;
    const source = self.refinedSolution(&buffer, &initial) orelse return null;
    if (!self.validateSolution(&buffer, &source)) return null;

    for (buffer.entries[0..buffer.len]) |entry| {
        if (entry.err < 100 and entry.mask.is_set)
            skip[entry.station] |= @as(match.Signal.Mask, 1) << entry.mask.bit;
    }

    self.counts.out_solutions += 1;
    self.addSource(&.{ .point = source.point + buffer.ref_point, .time = source.time + buffer.ref_time });
    return source.toPoint(self, &buffer);
}

pub fn solveSet(self: *ToaSolver, matched: []const match.Signal, candidates: []const match.Signal, skip: []u32) ?lma.data.types.Point {
    var buffer: Buffer = .at(self.stations[matched[0].station], c * fromNano(matched[0].nanosecond));
    self.counts.buffer_set += 1;
    self.bufferFromSet(&buffer, matched);

    const initial = self.initialSolution(&buffer) orelse return null;
    self.bufferFromSource(&buffer, &initial, candidates, 1_000);
    const source = self.refinedSolution(&buffer, &initial) orelse return null;

    if (!self.validateSolution(&buffer, &source)) return null;
    const xyz = source.point + buffer.ref_point;

    for (buffer.entries[0..buffer.len]) |entry| {
        if (entry.err < 100 and entry.mask.is_set)
            skip[entry.station] |= @as(match.Signal.Mask, 1) << entry.mask.bit;
    }
    self.counts.out_solutions += 1;
    self.addSource(&.{ .point = xyz, .time = source.time + buffer.ref_time });
    return source.toPoint(self, &buffer);
}

const toa_problem = struct {
    pub fn sqError(data: []const Vec, source: Vec) Float {
        const space: Vec = .{ 1, 1, 1, 0 };
        const time: Vec = .{ 0, 0, 0, 1 };

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

    inline fn system(data: []const Vec, source: Vec) struct { Mat, Vec } {
        const space: Vec = .{ 1, 1, 1, 0 };
        const time: Vec = .{ 0, 0, 0, 1 };

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

    fn lineGrad(data: []const Vec, source: Vec, dir: Vec) struct { Float, Float } {
        const space: Vec = .{ 1, 1, 1, 0 };
        const time: Vec = .{ 0, 0, 0, 1 };

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
    pub const LSOptions = struct {
        pub const Termination = enum {
            unknown,
            bad_input,
            max_iterations,
            min_gradient,
            min_improvement,
        };

        max_iterations: usize = 1_000,
        min_gradient: Float = std.math.floatEpsAt(Float, 1),
        min_improvement: Float = std.math.floatEpsAt(Float, 1),
        termination: ?*Termination = null,

        pub fn setTermination(self: *const LSOptions, reason: Termination) void {
            if (self.termination) |termination| termination.* = reason;
        }
    };

    pub const lm = levenberg_marquardt;
    pub const levenberg_marquardt = struct {
        pub const LMOptions = struct {
            common: LSOptions,
            min_rho: Float = 0.1,
            max_delta: Float = 100,
        };

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

        /// Give an approximate solution to the ToA problem by solving the argument minimization problem
        ///
        /// NOTE: Expects time to be transformed into spatial distance (multiplied by the speed of light constant)
        pub fn solve(data: []const Vec, initial_guess: Vec, opt: LMOptions) Vec {
            var termination: LSOptions.Termination = .unknown;
            defer opt.common.setTermination(termination);
            var delta: Float = 1;
            var lambda: Float = 1;
            const leeway = 0.1;

            var source: Vec = initial_guess;
            var err = toa_problem.sqError(data, initial_guess);
            for (0..opt.common.max_iterations) |_| {
                const mat: Mat, const bias: Vec = toa_problem.system(data, source);
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

                const new_err = toa_problem.sqError(data, source + grad);

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

                if (@reduce(.And, @abs(source * @as(Vec, @splat(opt.common.min_gradient))) >= @abs(grad)))
                    termination = .min_gradient;
                if (err * opt.common.min_improvement >= expected_improvement)
                    termination = .min_improvement;

                if (rho > opt.min_rho) {
                    source += grad;
                    err = new_err;
                }

                if (termination != .unknown) break;
            } else termination = .max_iterations;
            return source;
        }
    };

    pub const gn = gauss_newton;
    pub const gauss_newton = struct {
        pub const GNOptions = struct {
            common: LSOptions,
            c1: Float = 0.001,
            c2: Float = 0.9,
        };

        pub fn solve(data: []const Vec, initial_guess: Vec, opt: GNOptions) Vec {
            var termination: LSOptions.Termination = .unknown;
            defer opt.common.setTermination(termination);
            var source: Vec = initial_guess;
            var err = toa_problem.sqError(data, initial_guess);
            for (0..opt.common.max_iterations) |_| {
                const mat: Mat, const bias: Vec = toa_problem.system(data, source);
                const grad: Vec = math.matrix.block.solve(&mat, bias);
                const base_grad = -@reduce(.Add, grad * bias);

                var low: Float = 0;
                var high: Float = 0;
                var alpha: Float = 1;
                var iter: usize = 0;
                const new_err = blk: while (iter < 10) : (iter += 1) {
                    const new_err, const line_grad = toa_problem.lineGrad(data, source + grad * @as(Vec, @splat(alpha)), grad);
                    if (new_err > err + opt.c1 * alpha * base_grad or -line_grad < opt.c2 * base_grad) {
                        high = alpha;
                        alpha = (high + low) / 2;
                    } else if (line_grad < opt.c2 * base_grad) {
                        low = alpha;
                        if (high == 0) alpha *= 2 else alpha = (high + low) / 2;
                    } else break :blk new_err;
                } else toa_problem.sqError(data, source + grad * @as(Vec, @splat(alpha)));

                const scaled_grad = grad * @as(Vec, @splat(alpha));

                if (@reduce(.And, @abs(source * @as(Vec, @splat(opt.common.min_gradient))) >= @abs(scaled_grad)))
                    termination = .min_gradient;
                if (err * opt.common.min_improvement >= err - new_err)
                    termination = .min_improvement;

                source += scaled_grad;
                err = new_err;

                if (termination != .unknown) break;
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
                    .{ .common = .{ .max_iterations = 10, .min_gradient = 1e-15, .min_improvement = 1e-15 } },
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
                    .{ .common = .{ .max_iterations = 50, .min_gradient = 1e-15, .min_improvement = 1e-15 } },
                );

                const expected: Vec = .{ 3.0740512386798056, 6.753612727431825, 0.1813436176620304, 3.2173814008469277 };
                const expected_err = toa_problem.sqError(&data, expected);
                const tolerance_err: Float = 1e-14;
                const actual_err = toa_problem.sqError(&data, actual);
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
