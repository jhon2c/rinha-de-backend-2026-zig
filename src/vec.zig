
const std = @import("std");
const builtin = @import("builtin");

pub const DIM: usize = 14;
pub const LANES: usize = 16;
pub const K: usize = 5;
pub const SCALE: f64 = 10000.0;
pub const SENTINEL: i16 = -10000;

pub const MAX_AMOUNT: f64 = 10000;
pub const MAX_INSTALLMENTS: f64 = 12;
pub const AMOUNT_VS_AVG_RATIO: f64 = 10;
pub const MAX_MINUTES: f64 = 1440;
pub const MAX_KM: f64 = 1000;
pub const MAX_TX_COUNT_24H: f64 = 20;
pub const MAX_MERCHANT_AVG: f64 = 10000;

pub const Vec = [LANES]i16;

pub const Fields = struct {
    amount: f64,
    installments: f64,
    hour: u8,
    dow: u8,
    has_last: bool,
    minutes: f64,
    last_km: f64,
    km_home: f64,
    tx_count_24h: f64,
    is_online: bool,
    card_present: bool,
    unknown_merchant: bool,
    mcc_risk: f64,
    avg_amount: f64,
    merch_avg: f64,
};

fn clamp01(v: f64) f64 {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}

fn q(v: f64) i16 {
    return @intFromFloat(@round(clamp01(v) * SCALE));
}

pub fn buildVector(f: Fields) Vec {
    var out: Vec = [_]i16{0} ** LANES;
    out[0] = q(f.amount / MAX_AMOUNT);
    out[1] = q(f.installments / MAX_INSTALLMENTS);
    out[2] = q((f.amount / f.avg_amount) / AMOUNT_VS_AVG_RATIO);
    out[3] = q(@as(f64, @floatFromInt(f.hour)) / 23.0);
    out[4] = q(@as(f64, @floatFromInt(f.dow)) / 6.0);
    if (f.has_last) {
        out[5] = q(f.minutes / MAX_MINUTES);
        out[6] = q(f.last_km / MAX_KM);
    } else {
        out[5] = SENTINEL;
        out[6] = SENTINEL;
    }
    out[7] = q(f.km_home / MAX_KM);
    out[8] = q(f.tx_count_24h / MAX_TX_COUNT_24H);
    out[9] = if (f.is_online) SCALE_I else 0;
    out[10] = if (f.card_present) SCALE_I else 0;
    out[11] = if (f.unknown_merchant) SCALE_I else 0;
    out[12] = q(f.mcc_risk);
    out[13] = q(f.merch_avg / MAX_MERCHANT_AVG);
    return out;
}

const SCALE_I: i16 = 10000;

pub fn mccRisk(code: []const u8) f64 {
    const table = [_]struct { c: []const u8, r: f64 }{
        .{ .c = "5411", .r = 0.15 }, .{ .c = "5812", .r = 0.30 },
        .{ .c = "5912", .r = 0.20 }, .{ .c = "5944", .r = 0.45 },
        .{ .c = "7801", .r = 0.80 }, .{ .c = "7802", .r = 0.75 },
        .{ .c = "7995", .r = 0.85 }, .{ .c = "4511", .r = 0.35 },
        .{ .c = "5311", .r = 0.25 }, .{ .c = "5999", .r = 0.50 },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.c, code)) return e.r;
    }
    return 0.5;
}

pub fn dayOfWeek(year: i32, month: u8, day: u8) u8 {
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y = year;
    if (month < 3) y -= 1;
    const m: usize = @intCast(month - 1);
    const dow = @mod(y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + t[m] + @as(i32, day), 7);
    return @intCast(@mod(dow + 6, 7));
}

pub fn tsToEpoch(s: []const u8) i64 {

    const y = parseInt(s[0..4]);
    const mo = parseInt(s[5..7]);
    const d = parseInt(s[8..10]);
    const h = parseInt(s[11..13]);
    const mi = parseInt(s[14..16]);
    const se = parseInt(s[17..19]);
    return daysFromCivil(y, @intCast(mo), @intCast(d)) * 86400 +
        @as(i64, h) * 3600 + @as(i64, mi) * 60 + @as(i64, se);
}

fn parseInt(s: []const u8) i64 {
    var v: i64 = 0;
    for (s) |c| v = v * 10 + (c - '0');
    return v;
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divTrunc((153 * (if (m > 2) m - 3 else m + 9) + 2), 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub inline fn sqsum16(d: @Vector(LANES, i16)) i64 {
    if (comptime use_asm) {
        const prod: @Vector(8, i32) = asm ("vpmaddwd %[in], %[in], %[out]"
            : [out] "=x" (-> @Vector(8, i32)),
            : [in] "x" (d),
        );
        return @reduce(.Add, @as(@Vector(8, i64), prod));
    }
    const w: @Vector(LANES, i32) = d;
    const sq: @Vector(LANES, i32) = w * w;
    return @reduce(.Add, @as(@Vector(LANES, i64), sq));
}

pub inline fn sqdist(a: *const Vec, b: *const Vec) i64 {
    const va: @Vector(LANES, i16) = a.*;
    const vb: @Vector(LANES, i16) = b.*;
    return sqsum16(va -% vb);
}

pub const BLOCK: usize = 8;
pub const PAIRS: usize = 7;
pub const I32x8 = @Vector(BLOCK, i32);
pub const I16x16 = @Vector(2 * BLOCK, i16);

pub const Block = extern struct {
    pair: [PAIRS]I32x8,
};

comptime {
    std.debug.assert(@sizeOf(Block) == PAIRS * @sizeOf(I32x8));
}

const has_avx2 = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
const use_asm = has_avx2 and builtin.mode != .Debug;

pub inline fn packQueryPairs(query: *const Vec) [PAIRS]I32x8 {
    var qp: [PAIRS]I32x8 = undefined;
    inline for (0..PAIRS) |p| {
        const lo: u32 = @as(u16, @bitCast(query[2 * p]));
        const hi: u32 = @as(u16, @bitCast(query[2 * p + 1]));
        const word: i32 = @bitCast(lo | (hi << 16));
        qp[p] = @splat(word);
    }
    return qp;
}

pub inline fn dist8(block: *const Block, qp: *const [PAIRS]I32x8) I32x8 {
    if (comptime use_asm) {
        var acc: I32x8 = @splat(0);
        inline for (0..PAIRS) |p| {
            const diff: I16x16 = @as(I16x16, @bitCast(block.pair[p])) -% @as(I16x16, @bitCast(qp[p]));
            const prod: I32x8 = asm ("vpmaddwd %[in], %[in], %[out]"
                : [out] "=x" (-> I32x8),
                : [in] "x" (diff),
            );
            acc +%= prod;
        }
        return acc;
    }
    return dist8Scalar(block, qp);
}

fn dist8Scalar(block: *const Block, qp: *const [PAIRS]I32x8) I32x8 {
    var out: [BLOCK]i32 = [_]i32{0} ** BLOCK;
    inline for (0..PAIRS) |p| {
        const vb: I16x16 = @bitCast(block.pair[p]);
        const qb: I16x16 = @bitCast(qp[p]);
        const d: [2 * BLOCK]i16 = vb -% qb;
        for (0..BLOCK) |j| {
            const dlo: i32 = d[2 * j];
            const dhi: i32 = d[2 * j + 1];
            out[j] +%= dlo *% dlo +% dhi *% dhi;
        }
    }
    return out;
}

pub inline fn unpackLane(block: *const Block, j: usize) Vec {
    var v: Vec = [_]i16{0} ** LANES;
    inline for (0..PAIRS) |p| {
        const lanes: [BLOCK]i32 = block.pair[p];
        const word: u32 = @bitCast(lanes[j]);
        v[2 * p] = @bitCast(@as(u16, @truncate(word)));
        v[2 * p + 1] = @bitCast(@as(u16, @truncate(word >> 16)));
    }
    return v;
}

pub fn packBlock(vecs: *const [BLOCK]Vec) Block {
    var b: Block = undefined;
    inline for (0..PAIRS) |p| {
        var lane: [BLOCK]i32 = undefined;
        for (0..BLOCK) |j| {
            const lo: u32 = @as(u16, @bitCast(vecs[j][2 * p]));
            const hi: u32 = @as(u16, @bitCast(vecs[j][2 * p + 1]));
            lane[j] = @bitCast(lo | (hi << 16));
        }
        b.pair[p] = lane;
    }
    return b;
}

pub inline fn candMask(d: I32x8, worst: i64) u8 {
    const w: i32 = if (worst > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(worst);
    const wv: I32x8 = @splat(w);
    const zero: I32x8 = @splat(0);
    const le: @Vector(BLOCK, bool) = d <= wv;
    const ov: @Vector(BLOCK, bool) = d < zero;
    return @as(u8, @bitCast(le)) | @as(u8, @bitCast(ov));
}

pub const Top5 = struct {
    dist: [K]i64 = [_]i64{std.math.maxInt(i64)} ** K,
    idx: [K]u32 = [_]u32{std.math.maxInt(u32)} ** K,
    label: [K]u8 = [_]u8{0} ** K,
    count: usize = 0,

    pub inline fn worst(self: *const Top5) i64 {
        return self.dist[K - 1];
    }

    pub inline fn consider(self: *Top5, dist: i64, orig: u32, lbl: u8) void {

        if (dist > self.dist[K - 1]) return;
        if (dist == self.dist[K - 1] and orig >= self.idx[K - 1]) return;
        var j: usize = K - 1;
        while (j > 0) {
            const pd = self.dist[j - 1];
            if (pd < dist or (pd == dist and self.idx[j - 1] <= orig)) break;
            self.dist[j] = pd;
            self.idx[j] = self.idx[j - 1];
            self.label[j] = self.label[j - 1];
            j -= 1;
        }
        self.dist[j] = dist;
        self.idx[j] = orig;
        self.label[j] = lbl;
        if (self.count < K) self.count += 1;
    }

    pub fn fraudCount(self: *const Top5) u8 {
        var n: u8 = 0;
        for (0..K) |i| n += self.label[i];
        return n;
    }
};

test "sqdist + Top5 tie-break by lower index" {
    var a: Vec = [_]i16{0} ** LANES;
    var b: Vec = [_]i16{0} ** LANES;
    a[0] = 10000;
    b[0] = 9997;
    try std.testing.expectEqual(@as(i64, 9), sqdist(&a, &b));

    var top = Top5{};

    top.consider(100, 7, 1);
    top.consider(100, 3, 0);
    top.consider(50, 9, 1);
    try std.testing.expectEqual(@as(i64, 50), top.dist[0]);
    try std.testing.expectEqual(@as(u32, 9), top.idx[0]);
    try std.testing.expectEqual(@as(i64, 100), top.dist[1]);
    try std.testing.expectEqual(@as(u32, 3), top.idx[1]);
    try std.testing.expectEqual(@as(u32, 7), top.idx[2]);
    try std.testing.expectEqual(@as(u8, 2), top.fraudCount());
}

test "pack/unpack round-trips and dist8 matches sqdist (mod 2^32)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var vecs: [BLOCK]Vec = undefined;
    for (0..BLOCK) |j| {
        for (0..LANES) |d| {
            vecs[j][d] = if (d < DIM) @intCast(rng.intRangeAtMost(i32, -10000, 10000)) else 0;
        }
    }
    const blk = packBlock(&vecs);
    for (0..BLOCK) |j| {
        try std.testing.expectEqual(vecs[j], unpackLane(&blk, j));
    }

    var qv: Vec = [_]i16{0} ** LANES;
    for (0..DIM) |d| qv[d] = @intCast(rng.intRangeAtMost(i32, -10000, 10000));
    const qp = packQueryPairs(&qv);
    const d8: [BLOCK]i32 = dist8(&blk, &qp);
    for (0..BLOCK) |j| {
        const exact = sqdist(&qv, &vecs[j]);
        try std.testing.expectEqual(@as(i32, @truncate(exact)), d8[j]);
    }

    const worst = sqdist(&qv, &vecs[0]);
    const mask = candMask(d8, worst);
    try std.testing.expect((mask & 1) != 0);
}

test "dayOfWeek matches generator" {

    try std.testing.expectEqual(@as(u8, 2), dayOfWeek(2026, 3, 11));
}

test "tsToEpoch diff in minutes" {
    const a = tsToEpoch("2026-03-11T20:23:35Z");
    const b = tsToEpoch("2026-03-11T14:58:35Z");
    try std.testing.expectEqual(@as(i64, 325 * 60), a - b);
}

test "quantize legit example vector" {

    const v = buildVector(.{
        .amount = 41.12,
        .installments = 2,
        .hour = 18,
        .dow = 2,
        .has_last = false,
        .minutes = 0,
        .last_km = 0,
        .km_home = 29.23,
        .tx_count_24h = 3,
        .is_online = false,
        .card_present = true,
        .unknown_merchant = false,
        .mcc_risk = 0.15,
        .avg_amount = 82.24,
        .merch_avg = 60.25,
    });
    try std.testing.expectEqual(@as(i16, 41), v[0]);
    try std.testing.expectEqual(@as(i16, 1667), v[1]);
    try std.testing.expectEqual(@as(i16, 500), v[2]);
    try std.testing.expectEqual(@as(i16, 7826), v[3]);
    try std.testing.expectEqual(@as(i16, 3333), v[4]);
    try std.testing.expectEqual(SENTINEL, v[5]);
    try std.testing.expectEqual(SENTINEL, v[6]);
    try std.testing.expectEqual(@as(i16, 292), v[7]);
    try std.testing.expectEqual(@as(i16, 1500), v[8]);
    try std.testing.expectEqual(@as(i16, 0), v[9]);
    try std.testing.expectEqual(@as(i16, 10000), v[10]);
    try std.testing.expectEqual(@as(i16, 0), v[11]);
    try std.testing.expectEqual(@as(i16, 1500), v[12]);
    try std.testing.expectEqual(@as(i16, 60), v[13]);
}
