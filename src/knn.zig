
const std = @import("std");
const vec = @import("vec.zig");
const index = @import("index.zig");

pub const Vec = vec.Vec;
pub const Index = index.Index;
pub const Top5 = vec.Top5;
const Block = vec.Block;
const PAIRS = vec.PAIRS;
const I32x8 = vec.I32x8;

pub const MAX_NPROBE: usize = 256;
pub const MAX_K: usize = 16384;
pub const MAX_SEED: usize = 64;
pub const REPAIR_CAND_LIMIT: usize = 2048;

pub const CONFIDENT_DIST: i64 = 1400 * 1400;

pub const DEFAULT_REPAIR_BLOCK_BUDGET: usize = 4096;
pub var repair_block_budget: usize = DEFAULT_REPAIR_BLOCK_BUDGET;

const PREFETCH_AHEAD: usize = 2;
const PREFETCH_OPTS = std.builtin.PrefetchOptions{ .rw = .read, .locality = 1, .cache = .data };

const Cand = struct { lb: i64, c: u32 };

const SENTINEL_ORIG: u32 = 0xFFFFFFFF;

inline fn scanBlocks(idx: *const Index, q: *const Vec, qp: *const [PAIRS]I32x8, bstart: u32, bend: u32, top: *Top5) void {
    var b: usize = bstart;
    while (b < bend) : (b += 1) {
        if (b + PREFETCH_AHEAD < bend) @prefetch(&idx.vector_blocks[b + PREFETCH_AHEAD], PREFETCH_OPTS);
        const d8 = vec.dist8(&idx.vector_blocks[b], qp);
        var mask = vec.candMask(d8, top.dist[vec.K - 1]);
        if (mask == 0) continue;
        const base = b * vec.BLOCK;
        while (mask != 0) {
            const lane: usize = @ctz(mask);
            mask &= mask - 1;
            const o = idx.orig[base + lane];
            if (o == SENTINEL_ORIG) continue;
            const exact = vec.sqdist(q, &vec.unpackLane(&idx.vector_blocks[b], lane));
            const worst = top.dist[vec.K - 1];
            if (exact < worst or (exact == worst and o < top.idx[vec.K - 1])) {
                top.consider(exact, o, idx.labels[base + lane]);
            }
        }
    }
}

inline fn insertSeed(pd: []i64, pc: []u32, nsel: usize, d: i64, ci: u32) void {
    if (d >= pd[nsel - 1]) return;
    var j: usize = nsel - 1;
    while (j > 0 and pd[j - 1] > d) : (j -= 1) {
        pd[j] = pd[j - 1];
        pc[j] = pc[j - 1];
    }
    pd[j] = d;
    pc[j] = ci;
}

inline fn selectClusters(idx: *const Index, q: *const Vec, qp: *const [PAIRS]I32x8, nsel: usize, pd: []i64, pc: []u32, cdist2: ?[]i32) void {
    for (0..nsel) |i| pd[i] = std.math.maxInt(i64);
    const nblocks = idx.k / vec.BLOCK;
    var b: usize = 0;
    while (b < nblocks) : (b += 1) {
        if (b + PREFETCH_AHEAD < nblocks) @prefetch(&idx.centroid_blocks[b + PREFETCH_AHEAD], PREFETCH_OPTS);
        const d8 = vec.dist8(&idx.centroid_blocks[b], qp);
        const base = b * vec.BLOCK;
        if (cdist2) |cd| {
            const arr: [vec.BLOCK]i32 = d8;
            for (0..vec.BLOCK) |lane| cd[base + lane] = arr[lane];
        }
        var mask = vec.candMask(d8, pd[nsel - 1]);
        if (mask == 0) continue;
        while (mask != 0) {
            const lane: usize = @ctz(mask);
            mask &= mask - 1;
            const ci = base + lane;
            const exact = vec.sqdist(q, &idx.centroids[ci]);
            insertSeed(pd, pc, nsel, exact, @intCast(ci));
        }
    }
}

pub fn searchExact(idx: *const Index, q: *const Vec, seed: usize) Top5 {
    const nseed = @min(seed, @min(MAX_SEED, idx.k));
    const qp = vec.packQueryPairs(q);

    const have_radius = idx.cluster_radius.len == idx.k;
    var cdist2: [MAX_K]i32 = undefined;

    var pd: [MAX_SEED]i64 = undefined;
    var pc: [MAX_SEED]u32 = undefined;
    selectClusters(idx, q, &qp, nseed, &pd, &pc, if (have_radius) cdist2[0..idx.k] else null);

    var top = Top5{};
    var scanned = std.mem.zeroes([MAX_K / 64]u64);
    for (0..nseed) |i| {
        const c = pc[i];
        scanBlocks(idx, q, &qp, idx.block_off[c], idx.block_off[c + 1], &top);
        scanned[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
    }

    const fc = top.fraudCount();
    if ((fc == 0 or fc == vec.K) and top.worst() <= CONFIDENT_DIST) return top;

    const have_stats = idx.cluster_frauds.len == idx.k;
    const sqrt_worst: f64 = if (have_radius) @sqrt(@as(f64, @floatFromInt(top.worst()))) else 0;
    var cand: [REPAIR_CAND_LIMIT]Cand = undefined;
    var ncand: usize = 0;
    var all_legit = true;
    var all_fraud = true;
    for (0..idx.k) |c| {
        if ((scanned[c >> 6] >> @intCast(c & 63)) & 1 != 0) continue;
        if (idx.block_off[c + 1] == idx.block_off[c]) continue;
        if (have_radius) {
            const cd = cdist2[c];
            if (cd >= 0) {
                const t = sqrt_worst + @as(f64, @floatFromInt(idx.cluster_radius[c]));
                if (@as(f64, @floatFromInt(cd)) >= t * t) continue;
            }
        }
        const lb = bboxLowerBound(q, &idx.bbox_min[c], &idx.bbox_max[c]);
        if (lb >= top.worst()) continue;
        if (have_stats) {
            if (idx.cluster_frauds[c] != 0) all_legit = false;
            if (idx.cluster_frauds[c] != idx.cluster_size[c]) all_fraud = false;
        }
        if (ncand < REPAIR_CAND_LIMIT) {
            cand[ncand] = .{ .lb = lb, .c = @intCast(c) };
            ncand += 1;
        }
    }
    if (have_stats and ncand != 0) {
        if (fc <= 2 and all_legit) return top;
        if (fc >= 3 and all_fraud) return top;
    }
    std.sort.pdq(Cand, cand[0..ncand], {}, candLess);
    var budget: usize = repair_block_budget;
    for (cand[0..ncand]) |cd| {
        if (cd.lb >= top.worst()) break;
        const c0 = idx.block_off[cd.c];
        const c1 = idx.block_off[cd.c + 1];
        scanBlocks(idx, q, &qp, c0, c1, &top);
        const nb: usize = c1 - c0;
        if (nb >= budget) break;
        budget -= nb;
    }
    return top;
}

fn candLess(_: void, a: Cand, b: Cand) bool {
    return a.lb < b.lb;
}

inline fn bboxLowerBound(q: *const Vec, mn: *const Vec, mx: *const Vec) i64 {
    const vq: @Vector(vec.LANES, i16) = q.*;
    const vmn: @Vector(vec.LANES, i16) = mn.*;
    const vmx: @Vector(vec.LANES, i16) = mx.*;
    const zero: @Vector(vec.LANES, i16) = @splat(0);
    const below = @max(vmn -% vq, zero);
    const above = @max(vq -% vmx, zero);
    const d: @Vector(vec.LANES, i16) = below +% above;
    return vec.sqsum16(d);
}

pub fn search(idx: *const Index, q: *const Vec, nprobe_in: usize) Top5 {
    const nprobe = @min(nprobe_in, @min(MAX_NPROBE, idx.k));
    const qp = vec.packQueryPairs(q);
    var pd: [MAX_NPROBE]i64 = undefined;
    var pc: [MAX_NPROBE]u32 = undefined;
    selectClusters(idx, q, &qp, nprobe, &pd, &pc, null);
    var top = Top5{};
    for (0..nprobe) |i| {
        if (pd[i] == std.math.maxInt(i64)) break;
        const c = pc[i];
        scanBlocks(idx, q, &qp, idx.block_off[c], idx.block_off[c + 1], &top);
    }
    return top;
}

pub fn searchBrute(idx: *const Index, q: *const Vec) Top5 {
    var top = Top5{};
    const qp = vec.packQueryPairs(q);
    scanBlocks(idx, q, &qp, 0, @intCast(idx.n_pad / vec.BLOCK), &top);
    return top;
}

pub fn decide(top: *const Top5) struct { approved: bool, fraud_score: f32 } {
    const frauds = top.fraudCount();
    const score: f32 = @as(f32, @floatFromInt(frauds)) / @as(f32, vec.K);
    return .{ .approved = score < 0.6, .fraud_score = score };
}

test "searchExact equals brute on a tiny index" {
    const gpa = std.testing.allocator;
    const k: usize = 8;
    var centroids: [8]Vec = undefined;
    for (0..8) |i| {
        centroids[i] = [_]i16{0} ** vec.LANES;
        centroids[i][0] = @intCast(i * 1500);
    }
    var bmin: [8]Vec = undefined;
    var bmax: [8]Vec = undefined;

    var vectors = [_]Vec{
        mk(.{0}), mk(.{100}), mk(.{200}),
        mk(.{9000}), mk(.{9500}), mk(.{10000}),
    };
    var labels = [_]u8{ 0, 0, 1, 1, 1, 1 };
    var orig = [_]u32{ 0, 1, 2, 3, 4, 5 };
    var cluster_off = [_]u32{ 0, 3, 6, 6, 6, 6, 6, 6, 6 };

    for (0..8) |c| {
        bmin[c] = mk(.{0});
        bmax[c] = mk(.{0});
    }
    bmin[0] = mk(.{0});
    bmax[0] = mk(.{200});
    bmin[1] = mk(.{9000});
    bmax[1] = mk(.{10000});

    var soa = try index.buildSoA(gpa, k, &centroids, &cluster_off, &vectors, &labels, &orig);
    defer soa.deinit(gpa);

    const idx = Index{
        .n = 6,
        .k = k,
        .n_pad = soa.n_pad,
        .centroids = &centroids,
        .centroid_blocks = soa.centroid_blocks,
        .bbox_min = &bmin,
        .bbox_max = &bmax,
        .block_off = soa.block_off,
        .vector_blocks = soa.vector_blocks,
        .labels = soa.labels,
        .orig = soa.orig,
    };

    for ([_]Vec{ mk(.{150}), mk(.{9001}), mk(.{5000}), mk(.{0}), mk(.{10000}) }) |query| {
        const a = searchExact(&idx, &query, 2);
        const b = searchBrute(&idx, &query);
        try std.testing.expectEqualSlices(u32, &b.idx, &a.idx);
        try std.testing.expectEqualSlices(i64, &b.dist, &a.dist);
    }
}

fn mk(comptime first: anytype) Vec {
    var v: Vec = [_]i16{0} ** vec.LANES;
    v[0] = first[0];
    return v;
}
