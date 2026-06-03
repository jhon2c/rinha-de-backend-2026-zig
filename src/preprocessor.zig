
const std = @import("std");
const vec = @import("vec.zig");
const index = @import("index.zig");

const Vec = vec.Vec;
const LANES = vec.LANES;

const DEFAULT_K: usize = 4096;
const DEFAULT_SAMPLE: usize = 200_000;
const DEFAULT_ITERS: usize = 15;
const SEED: u64 = 0x1234_5678_9abc_def0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    const input = it.next() orelse "references.json";
    const output = it.next() orelse "index.bin";
    var k: usize = DEFAULT_K;
    var sample_n: usize = DEFAULT_SAMPLE;
    var iters: usize = DEFAULT_ITERS;
    if (it.next()) |s| k = try std.fmt.parseInt(usize, s, 10);
    if (it.next()) |s| sample_n = try std.fmt.parseInt(usize, s, 10);
    if (it.next()) |s| iters = try std.fmt.parseInt(usize, s, 10);

    const nthreads = std.Thread.getCpuCount() catch 4;

    var stderr_buf: [256]u8 = undefined;
    const log = struct {
        fn p(comptime fmt: []const u8, args: anytype) void {
            std.debug.print(fmt, args);
        }
    }.p;
    _ = &stderr_buf;

    log("reading {s} ...\n", .{input});
    const data = try std.Io.Dir.cwd().readFileAlloc(io, input, gpa, .limited(1 << 32));
    defer gpa.free(data);

    var vecs = std.ArrayList(Vec).empty;
    defer vecs.deinit(gpa);
    var labels = std.ArrayList(u8).empty;
    defer labels.deinit(gpa);
    try vecs.ensureTotalCapacity(gpa, 3_000_000);
    try labels.ensureTotalCapacity(gpa, 3_000_000);

    parseRefs(data, &vecs, &labels, gpa) catch |e| {
        log("parse error: {}\n", .{e});
        return e;
    };
    const n = vecs.items.len;
    log("parsed {d} reference vectors\n", .{n});
    if (n == 0) return error.NoData;
    if (k > n) k = n;

    var prng = std.Random.DefaultPrng.init(SEED);
    const rng = prng.random();
    if (sample_n > n) sample_n = n;
    const sample = try gpa.alloc(Vec, sample_n);
    defer gpa.free(sample);
    for (sample) |*s| s.* = vecs.items[rng.intRangeLessThan(usize, 0, n)];

    const centroids = try gpa.alloc(Vec, k);
    defer gpa.free(centroids);
    log("k-means++ init (k={d}, sample={d}) ...\n", .{ k, sample_n });
    try kmeansPlusPlus(centroids, sample, rng, gpa);

    const sample_assign = try gpa.alloc(u32, sample_n);
    defer gpa.free(sample_assign);
    for (0..iters) |iter| {
        try parNearest(sample, centroids, sample_assign, nthreads, gpa);
        updateCentroids(centroids, sample, sample_assign);
        log("  lloyd iter {d}/{d}\n", .{ iter + 1, iters });
    }

    log("assigning all {d} vectors to {d} clusters ...\n", .{ n, k });
    const assign = try gpa.alloc(u32, n);
    defer gpa.free(assign);
    try parNearest(vecs.items, centroids, assign, nthreads, gpa);

    const cluster_off = try gpa.alloc(u32, k + 1);
    defer gpa.free(cluster_off);
    @memset(cluster_off, 0);
    for (assign) |c| cluster_off[c + 1] += 1;
    for (1..k + 1) |i| cluster_off[i] += cluster_off[i - 1];

    const out_vecs = try gpa.alloc(Vec, n);
    defer gpa.free(out_vecs);
    const out_lbl = try gpa.alloc(u8, n);
    defer gpa.free(out_lbl);
    const out_orig = try gpa.alloc(u32, n);
    defer gpa.free(out_orig);

    const pos = try gpa.alloc(u32, k);
    defer gpa.free(pos);
    for (0..k) |i| pos[i] = cluster_off[i];
    for (0..n) |i| {
        const c = assign[i];
        const p = pos[c];
        out_vecs[p] = vecs.items[i];
        out_lbl[p] = labels.items[i];
        out_orig[p] = @intCast(i);
        pos[c] += 1;
    }

    const bbox_min = try gpa.alloc(Vec, k);
    defer gpa.free(bbox_min);
    const bbox_max = try gpa.alloc(Vec, k);
    defer gpa.free(bbox_max);
    for (0..k) |c| {
        const lo = cluster_off[c];
        const hi = cluster_off[c + 1];
        var mn: Vec = [_]i16{0} ** LANES;
        var mx: Vec = [_]i16{0} ** LANES;
        if (hi > lo) {
            mn = out_vecs[lo];
            mx = out_vecs[lo];
            for (lo + 1..hi) |i| {
                for (0..LANES) |d| {
                    mn[d] = @min(mn[d], out_vecs[i][d]);
                    mx[d] = @max(mx[d], out_vecs[i][d]);
                }
            }
        }
        bbox_min[c] = mn;
        bbox_max[c] = mx;
    }

    var max_cluster: usize = 0;
    var empty: usize = 0;
    for (0..k) |c| {
        const sz = cluster_off[c + 1] - cluster_off[c];
        if (sz > max_cluster) max_cluster = sz;
        if (sz == 0) empty += 1;
    }
    log("clusters: max={d} empty={d} avg={d}\n", .{ max_cluster, empty, n / k });

    log("writing {s} ...\n", .{output});
    var file = try std.Io.Dir.cwd().createFile(io, output, .{});
    defer file.close(io);
    var wbuf: [1 << 20]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try index.write(&fw.interface, n, k, centroids, bbox_min, bbox_max, cluster_off, out_vecs, out_lbl, out_orig);
    try fw.interface.flush();
    log("done.\n", .{});
}

fn parseRefs(data: []const u8, vecs: *std.ArrayList(Vec), labels: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var p = std.mem.indexOfScalar(u8, data, '[') orelse return error.Malformed;
    while (true) {
        const vstart = std.mem.indexOfScalarPos(u8, data, p + 1, '[') orelse break;
        var q = vstart + 1;
        var v: Vec = [_]i16{0} ** LANES;
        for (0..vec.DIM) |d| {
            v[d] = parseFixed(data, &q);
            while (q < data.len and isWs(data[q])) q += 1;
            if (q < data.len and data[q] == ',') q += 1;
        }
        const lkey = std.mem.indexOfPos(u8, data, q, "\"label\"") orelse break;
        var lp = lkey + 7;
        while (lp < data.len and data[lp] != ':') lp += 1;
        lp += 1;
        while (lp < data.len and isWs(data[lp])) lp += 1;
        if (lp >= data.len or data[lp] != '"') break;
        lp += 1;
        const c = data[lp];
        try vecs.append(gpa, v);
        try labels.append(gpa, if (c == 'f') @as(u8, 1) else 0);
        p = lp;
    }
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn parseFixed(data: []const u8, q: *usize) i16 {
    var i = q.*;
    while (i < data.len and isWs(data[i])) i += 1;
    var neg = false;
    if (i < data.len and data[i] == '-') {
        neg = true;
        i += 1;
    }
    var intpart: i32 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1)
        intpart = intpart * 10 + (data[i] - '0');
    var frac: i32 = 0;
    var fdigits: u8 = 0;
    if (i < data.len and data[i] == '.') {
        i += 1;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            if (fdigits < 4) {
                frac = frac * 10 + (data[i] - '0');
                fdigits += 1;
            }
        }
    }
    while (fdigits < 4) : (fdigits += 1) frac *= 10;
    var val = intpart * 10000 + frac;
    if (neg) val = -val;
    q.* = i;
    return @intCast(val);
}

fn nearest(centroids: []const Vec, v: *const Vec) u32 {
    var best: u32 = 0;
    var bestd: i64 = std.math.maxInt(i64);
    for (centroids, 0..) |*c, ci| {
        const d = vec.sqdist(v, c);
        if (d < bestd) {
            bestd = d;
            best = @intCast(ci);
        }
    }
    return best;
}

fn kmeansPlusPlus(centroids: []Vec, sample: []const Vec, rng: std.Random, gpa: std.mem.Allocator) !void {
    const mind = try gpa.alloc(i64, sample.len);
    defer gpa.free(mind);
    @memset(mind, std.math.maxInt(i64));

    centroids[0] = sample[rng.intRangeLessThan(usize, 0, sample.len)];
    for (1..centroids.len) |c| {
        var total: f64 = 0;
        for (sample, 0..) |*s, idx| {
            const d = vec.sqdist(s, &centroids[c - 1]);
            if (d < mind[idx]) mind[idx] = d;
            total += @floatFromInt(mind[idx]);
        }
        if (total <= 0) {
            centroids[c] = sample[rng.intRangeLessThan(usize, 0, sample.len)];
            continue;
        }
        const target = rng.float(f64) * total;
        var acc: f64 = 0;
        var chosen: usize = sample.len - 1;
        for (sample, 0..) |_, idx| {
            acc += @floatFromInt(mind[idx]);
            if (acc >= target) {
                chosen = idx;
                break;
            }
        }
        centroids[c] = sample[chosen];
    }
}

fn updateCentroids(centroids: []Vec, sample: []const Vec, assign: []const u32) void {
    const k = centroids.len;
    var sum = std.heap.page_allocator.alloc([LANES]i64, k) catch unreachable;
    defer std.heap.page_allocator.free(sum);
    var cnt = std.heap.page_allocator.alloc(u64, k) catch unreachable;
    defer std.heap.page_allocator.free(cnt);
    for (sum) |*s| s.* = [_]i64{0} ** LANES;
    @memset(cnt, 0);

    for (sample, 0..) |*s, i| {
        const c = assign[i];
        cnt[c] += 1;
        for (0..LANES) |d| sum[c][d] += s[d];
    }
    for (0..k) |c| {
        if (cnt[c] == 0) continue;
        const cf: f64 = @floatFromInt(cnt[c]);
        for (0..LANES) |d| {
            const m = @round(@as(f64, @floatFromInt(sum[c][d])) / cf);
            centroids[c][d] = @intFromFloat(m);
        }
    }
}

const NearestCtx = struct {
    items: []const Vec,
    centroids: []const Vec,
    out: []u32,
    lo: usize,
    hi: usize,
};

fn nearestWorker(ctx: *const NearestCtx) void {
    var i = ctx.lo;
    while (i < ctx.hi) : (i += 1) ctx.out[i] = nearest(ctx.centroids, &ctx.items[i]);
}

fn parNearest(items: []const Vec, centroids: []const Vec, out: []u32, nthreads: usize, gpa: std.mem.Allocator) !void {
    const n = items.len;
    const t = @max(1, @min(nthreads, n));
    const ctxs = try gpa.alloc(NearestCtx, t);
    defer gpa.free(ctxs);
    const threads = try gpa.alloc(?std.Thread, t);
    defer gpa.free(threads);

    const chunk = (n + t - 1) / t;
    for (0..t) |ti| {
        const lo = ti * chunk;
        const hi = @min(lo + chunk, n);
        ctxs[ti] = .{ .items = items, .centroids = centroids, .out = out, .lo = lo, .hi = hi };
        threads[ti] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, nearestWorker, .{&ctxs[ti]}) catch blk: {
            nearestWorker(&ctxs[ti]);
            break :blk null;
        };
    }
    for (threads) |maybe| {
        if (maybe) |th| th.join();
    }
}
