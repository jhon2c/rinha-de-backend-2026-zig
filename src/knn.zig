
const std = @import("std");
const vec = @import("vec.zig");
const index = @import("index.zig");

pub const Vec = vec.Vec;
pub const Index = index.Index;
pub const Top5 = vec.Top5;

pub const MAX_NPROBE: usize = 256;
pub const MAX_K: usize = 16384;
pub const MAX_SEED: usize = 64;
pub const REPAIR_CAND_LIMIT: usize = 512;

pub const CONFIDENT_DIST: i64 = 1400 * 1400;

const Cand = struct { lb: i64, c: u32 };

pub fn searchExact(idx: *const Index, q: *const Vec, seed: usize) Top5 {
    const nseed = @min(seed, @min(MAX_SEED, idx.k));

    var pd: [MAX_SEED]i64 = undefined;
    var pc: [MAX_SEED]u32 = undefined;
    for (0..nseed) |i| pd[i] = std.math.maxInt(i64);
    for (idx.centroids, 0..) |*c, ci| {
        const d = vec.sqdist_early(q, c, pd[nseed - 1]) orelse continue;
        if (d >= pd[nseed - 1]) continue;
        var j: usize = nseed - 1;
        while (j > 0 and pd[j - 1] > d) : (j -= 1) {
            pd[j] = pd[j - 1];
            pc[j] = pc[j - 1];
        }
        pd[j] = d;
        pc[j] = @intCast(ci);
    }

    var top = Top5{};
    var scanned = std.mem.zeroes([MAX_K / 64]u64);
    for (0..nseed) |i| {
        const c = pc[i];
        scanRange(idx, q, idx.cluster_off[c], idx.cluster_off[c + 1], &top);
        scanned[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
    }

    const fc = top.fraudCount();
    if ((fc == 0 or fc == vec.K) and top.worst() <= CONFIDENT_DIST) return top;

    var cand: [REPAIR_CAND_LIMIT]Cand = undefined;
    var ncand: usize = 0;
    for (0..idx.k) |c| {
        if ((scanned[c >> 6] >> @intCast(c & 63)) & 1 != 0) continue;
        if (idx.cluster_off[c + 1] == idx.cluster_off[c]) continue;
        const lb = bboxLowerBound(q, &idx.bbox_min[c], &idx.bbox_max[c], top.worst()) orelse continue;
        if (lb >= top.worst()) continue;
        if (ncand < REPAIR_CAND_LIMIT) {
            cand[ncand] = .{ .lb = lb, .c = @intCast(c) };
            ncand += 1;
        }
    }
    std.sort.pdq(Cand, cand[0..ncand], {}, candLess);
    for (cand[0..ncand]) |cd| {
        if (cd.lb >= top.worst()) break;
        scanRange(idx, q, idx.cluster_off[cd.c], idx.cluster_off[cd.c + 1], &top);
    }
    return top;
}

fn candLess(_: void, a: Cand, b: Cand) bool {
    return a.lb < b.lb;
}

/// Returns null if first-half bbox lb alone ≥ threshold (cluster can be skipped).
inline fn bboxLowerBound(q: *const Vec, mn: *const Vec, mx: *const Vec, threshold: i64) ?i64 {
    const vq: @Vector(vec.LANES, i16) = q.*;
    const vmn: @Vector(vec.LANES, i16) = mn.*;
    const vmx: @Vector(vec.LANES, i16) = mx.*;
    const zero: @Vector(vec.LANES, i16) = @splat(0);
    const below = @max(vmn -% vq, zero);
    const above = @max(vq -% vmx, zero);
    const d: @Vector(vec.LANES, i16) = below +% above;
    return vec.sqdist_early_d(&d, threshold);
}

pub fn search(idx: *const Index, q: *const Vec, nprobe_in: usize) Top5 {
    const nprobe = @min(nprobe_in, @min(MAX_NPROBE, idx.k));
    var pd: [MAX_NPROBE]i64 = undefined;
    var pc: [MAX_NPROBE]u32 = undefined;
    for (0..nprobe) |i| pd[i] = std.math.maxInt(i64);
    for (idx.centroids, 0..) |*c, ci| {
        const d = vec.sqdist(q, c);
        if (d >= pd[nprobe - 1]) continue;
        var j: usize = nprobe - 1;
        while (j > 0 and pd[j - 1] > d) : (j -= 1) {
            pd[j] = pd[j - 1];
            pc[j] = pc[j - 1];
        }
        pd[j] = d;
        pc[j] = @intCast(ci);
    }
    var top = Top5{};
    for (0..nprobe) |i| {
        if (pd[i] == std.math.maxInt(i64)) break;
        const c = pc[i];
        scanRange(idx, q, idx.cluster_off[c], idx.cluster_off[c + 1], &top);
    }
    return top;
}

pub fn searchBrute(idx: *const Index, q: *const Vec) Top5 {
    var top = Top5{};
    scanRange(idx, q, 0, @intCast(idx.n), &top);
    return top;
}

inline fn scanRange(idx: *const Index, q: *const Vec, start: u32, end: u32, top: *Top5) void {
    var i: usize = start;
    while (i < end) : (i += 1) {
        const worst = top.dist[vec.K - 1];
        const d = vec.sqdist_early(&idx.vectors[i], q, worst) orelse continue;
        if (d < worst or (d == worst and idx.orig[i] < top.idx[vec.K - 1])) {
            top.consider(d, idx.orig[i], idx.labels[i]);
        }
    }
}

pub fn decide(top: *const Top5) struct { approved: bool, fraud_score: f32 } {
    const frauds = top.fraudCount();
    const score: f32 = @as(f32, @floatFromInt(frauds)) / @as(f32, vec.K);
    return .{ .approved = score < 0.6, .fraud_score = score };
}

test "searchExact equals brute force on a tiny index" {
    const n: usize = 6;
    const k: usize = 2;
    var centroids = [_]Vec{ mk(.{0}), mk(.{10000}) };
    var bmin = [_]Vec{ mk(.{0}), mk(.{9000}) };
    var bmax = [_]Vec{ mk(.{200}), mk(.{10000}) };
    var coff = [_]u32{ 0, 3, 6 };
    var vectors = [_]Vec{
        mk(.{0}), mk(.{100}), mk(.{200}),
        mk(.{9000}), mk(.{9500}), mk(.{10000}),
    };
    var labels = [_]u8{ 0, 0, 1, 1, 1, 1 };
    var orig = [_]u32{ 0, 1, 2, 3, 4, 5 };

    const idx = Index{
        .n = n, .k = k,
        .centroids = &centroids, .bbox_min = &bmin, .bbox_max = &bmax,
        .cluster_off = &coff, .vectors = &vectors, .labels = &labels, .orig = &orig,
    };

    for ([_]Vec{ mk(.{150}), mk(.{9001}), mk(.{5000}) }) |q| {
        const a = searchExact(&idx, &q, 1);
        const b = searchBrute(&idx, &q);
        try std.testing.expectEqualSlices(u32, &b.idx, &a.idx);
    }
}

fn mk(comptime first: anytype) Vec {
    var v: Vec = [_]i16{0} ** vec.LANES;
    v[0] = first[0];
    return v;
}
