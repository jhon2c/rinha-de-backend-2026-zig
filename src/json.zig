
const std = @import("std");
const vec = @import("vec.zig");

pub const ParseError = error{Malformed};

pub fn parseToVector(body: []const u8) ParseError!vec.Vec {
    var cur: usize = 0;

    const amount = try num(body, &cur, "\"amount\":");
    const installments = try num(body, &cur, "\"installments\":");
    const req_ts = try str(body, &cur, "\"requested_at\":");
    const avg_amount = try num(body, &cur, "\"avg_amount\":");
    const tx_count = try num(body, &cur, "\"tx_count_24h\":");

    cur = try afterKey(body, cur, "\"known_merchants\":");
    const known = try arraySlice(body, &cur);

    const merch_id = try str(body, &cur, "\"id\":");
    const mcc = try str(body, &cur, "\"mcc\":");
    const merch_avg = try num(body, &cur, "\"avg_amount\":");

    const is_online = try boolean(body, &cur, "\"is_online\":");
    const card_present = try boolean(body, &cur, "\"card_present\":");
    const km_home = try num(body, &cur, "\"km_from_home\":");

    cur = try afterKey(body, cur, "\"last_transaction\":");
    var has_last = false;
    var minutes: f64 = 0;
    var last_km: f64 = 0;
    if (cur < body.len and body[cur] != 'n') {
        const last_ts = try str(body, &cur, "\"timestamp\":");
        last_km = try num(body, &cur, "\"km_from_current\":");
        const dt = vec.tsToEpoch(req_ts) - vec.tsToEpoch(last_ts);
        minutes = @as(f64, @floatFromInt(dt)) / 60.0;
        has_last = true;
    }

    if (req_ts.len < 19) return error.Malformed;
    const year: i32 = @intCast(parseUint(req_ts[0..4]));
    const month: u8 = @intCast(parseUint(req_ts[5..7]));
    const day: u8 = @intCast(parseUint(req_ts[8..10]));
    const hour: u8 = @intCast(parseUint(req_ts[11..13]));

    var idbuf: [64]u8 = undefined;
    const unknown_merchant = blk: {
        if (merch_id.len + 2 > idbuf.len) break :blk true;
        idbuf[0] = '"';
        @memcpy(idbuf[1 .. 1 + merch_id.len], merch_id);
        idbuf[1 + merch_id.len] = '"';
        const needle = idbuf[0 .. merch_id.len + 2];
        break :blk std.mem.indexOf(u8, known, needle) == null;
    };

    return vec.buildVector(.{
        .amount = amount,
        .installments = installments,
        .hour = hour,
        .dow = vec.dayOfWeek(year, month, day),
        .has_last = has_last,
        .minutes = minutes,
        .last_km = last_km,
        .km_home = km_home,
        .tx_count_24h = tx_count,
        .is_online = is_online,
        .card_present = card_present,
        .unknown_merchant = unknown_merchant,
        .mcc_risk = vec.mccRisk(mcc),
        .avg_amount = avg_amount,
        .merch_avg = merch_avg,
    });
}

fn afterKey(body: []const u8, from: usize, key: []const u8) ParseError!usize {
    const idx = std.mem.indexOfPos(u8, body, from, key) orelse return error.Malformed;
    return idx + key.len;
}

fn num(body: []const u8, cur: *usize, key: []const u8) ParseError!f64 {
    var i = try afterKey(body, cur.*, key);
    const start = i;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            ',', '}', ']' => break,
            else => {},
        }
    }
    cur.* = i;
    return std.fmt.parseFloat(f64, body[start..i]) catch return error.Malformed;
}

fn str(body: []const u8, cur: *usize, key: []const u8) ParseError![]const u8 {
    var i = try afterKey(body, cur.*, key);
    if (i >= body.len or body[i] != '"') return error.Malformed;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return error.Malformed;
    cur.* = i + 1;
    return body[start..i];
}

fn boolean(body: []const u8, cur: *usize, key: []const u8) ParseError!bool {
    const i = try afterKey(body, cur.*, key);
    if (i >= body.len) return error.Malformed;
    const v = body[i] == 't';
    cur.* = i + (if (v) @as(usize, 4) else 5);
    return v;
}

fn arraySlice(body: []const u8, cur: *usize) ParseError![]const u8 {
    var i = cur.*;
    if (i >= body.len or body[i] != '[') return error.Malformed;
    const start = i;
    while (i < body.len and body[i] != ']') : (i += 1) {}
    if (i >= body.len) return error.Malformed;
    cur.* = i + 1;
    return body[start .. i + 1];
}

fn parseUint(s: []const u8) u64 {
    var v: u64 = 0;
    for (s) |c| v = v * 10 + (c - '0');
    return v;
}

test "parse legit example payload" {
    const body =
        \\{"id":"tx-1329056812","transaction":{"amount":41.12,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":82.24,"tx_count_24h":3,"known_merchants":["MERC-003","MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5411","avg_amount":60.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.2331036248},"last_transaction":null}
    ;
    const v = try parseToVector(body);
    try std.testing.expectEqual(@as(i16, 41), v[0]);
    try std.testing.expectEqual(@as(i16, 1667), v[1]);
    try std.testing.expectEqual(@as(i16, 500), v[2]);
    try std.testing.expectEqual(vec.SENTINEL, v[5]);
    try std.testing.expectEqual(@as(i16, 0), v[11]);
    try std.testing.expectEqual(@as(i16, 1500), v[12]);
}

test "parse with last_transaction + unknown merchant" {
    const body =
        \\{"id":"tx-1","transaction":{"amount":384.88,"installments":3,"requested_at":"2026-03-11T20:23:35Z"},"customer":{"avg_amount":769.76,"tx_count_24h":3,"known_merchants":["MERC-009","MERC-001"]},"merchant":{"id":"MERC-077","mcc":"7995","avg_amount":298.95},"terminal":{"is_online":true,"card_present":false,"km_from_home":13.71},"last_transaction":{"timestamp":"2026-03-11T14:58:35Z","km_from_current":18.86}}
    ;
    const v = try parseToVector(body);
    try std.testing.expectEqual(@as(i16, 10000), v[9]);
    try std.testing.expectEqual(@as(i16, 0), v[10]);
    try std.testing.expectEqual(@as(i16, 10000), v[11]);
    try std.testing.expectEqual(@as(i16, 8500), v[12]);

    try std.testing.expectEqual(@as(i16, 2257), v[5]);
}
