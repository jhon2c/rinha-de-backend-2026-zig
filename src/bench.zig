
const std = @import("std");
const vec = @import("vec.zig");
const index = @import("index.zig");
const knn = @import("knn.zig");
const json = @import("json.zig");

const Entry = struct { q: vec.Vec, expected_approved: bool };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    const idx_path = it.next() orelse "index.bin";
    const data_path = it.next() orelse "test-data.json";
    var sweep_arg: usize = 0;
    var do_brute = false;
    if (it.next()) |s| {
        if (std.mem.eql(u8, s, "--brute")) do_brute = true else sweep_arg = std.fmt.parseInt(usize, s, 10) catch 0;
    }
    if (it.next()) |s| {
        if (std.mem.eql(u8, s, "--brute")) do_brute = true;
    }

    var file = try std.Io.Dir.cwd().openFile(io, idx_path, .{});
    const st = try file.stat(io);
    const size: usize = @intCast(st.size);
    const page = std.heap.pageSize();
    const mapped = try std.posix.mmap(null, std.mem.alignForward(usize, size, page), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    file.close(io);
    var idx = try index.Index.load(mapped);
    try idx.buildClusterStats(gpa);
    std.debug.print("index: n={d} k={d}\n", .{ idx.n, idx.k });

    const data = try std.Io.Dir.cwd().readFileAlloc(io, data_path, gpa, .limited(1 << 31));
    defer gpa.free(data);

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(gpa);
    try parseTestData(data, &entries, gpa);
    const N = entries.items.len;
    std.debug.print("parsed {d} test entries\n\n", .{N});
    if (N == 0) return;

    if (do_brute) {
        var fp: usize = 0;
        var fn_: usize = 0;
        for (entries.items) |*e| {
            const top = knn.searchBrute(&idx, &e.q);
            const approved = knn.decide(&top).approved;
            if (approved != e.expected_approved) {
                if (approved) fn_ += 1 else fp += 1;
            }
        }
        std.debug.print("BRUTE vs official labels: FP={d} FN={d} mismatch={d}/{d} ({d:.3}%)\n\n", .{ fp, fn_, fp + fn_, N, 100.0 * @as(f64, @floatFromInt(fp + fn_)) / @as(f64, @floatFromInt(N)) });
    }

    const probes = if (sweep_arg != 0)
        &[_]usize{sweep_arg}
    else
        &[_]usize{ 1, 4, 8, 16, 32, 64, 128 };

    std.debug.print("int16 single-pass:\n{s:>7} {s:>6} {s:>6} {s:>6} {s:>6} {s:>10}\n", .{ "nprobe", "TP", "TN", "FP", "FN", "det_score" });
    for (probes) |np| {
        var tp: usize = 0;
        var tn: usize = 0;
        var fp: usize = 0;
        var fn_: usize = 0;
        for (entries.items) |*e| {
            const top = knn.search(&idx, &e.q, np);
            const approved = knn.decide(&top).approved;
            if (approved == e.expected_approved) {
                if (approved) tn += 1 else tp += 1;
            } else {
                if (approved) fn_ += 1 else fp += 1;
            }
        }
        const det = detectionScore(fp, fn_, 0, N);
        std.debug.print("{d:>7} {d:>6} {d:>6} {d:>6} {d:>6} {d:>10.1}\n", .{ np, tp, tn, fp, fn_, det });
    }

    const lat = try gpa.alloc(u64, N);
    defer gpa.free(lat);
    const sorted = try gpa.alloc(u64, N);
    defer gpa.free(sorted);

    std.debug.print("\nsearchExact (adaptive bbox branch-and-bound), seed x repair-block-budget sweep:\n{s:>7} {s:>9} {s:>6} {s:>6} {s:>6} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "seed", "budget", "FP", "FN", "mism", "det_score", "mean_us", "p50_us", "p99_us", "max_us" });
    const budgets = [_]usize{ std.math.maxInt(usize), 8192, 4096, 2048, 1024, 512 };
    for ([_]usize{ 2, 4, 8 }) |seed| {
        for (budgets) |budget| {
            knn.repair_block_budget = budget;
            var fp: usize = 0;
            var fn_: usize = 0;
            var total_ns: u64 = 0;
            for (entries.items, 0..) |*e, i| {
                const t0 = std.Io.Clock.now(.awake, io);
                const top = knn.searchExact(&idx, &e.q, seed);
                const t1 = std.Io.Clock.now(.awake, io);
                const ns: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);
                std.mem.doNotOptimizeAway(top.dist[0]);
                lat[i] = ns;
                total_ns += ns;
                const approved = knn.decide(&top).approved;
                if (approved != e.expected_approved) {
                    if (approved) fn_ += 1 else fp += 1;
                }
            }
            @memcpy(sorted, lat);
            std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
            const mean_us = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(N)) / 1000.0;
            const p50_us = @as(f64, @floatFromInt(sorted[N / 2])) / 1000.0;
            const p99_us = @as(f64, @floatFromInt(sorted[(N * 99) / 100])) / 1000.0;
            const max_us = @as(f64, @floatFromInt(sorted[N - 1])) / 1000.0;
            const blab: u64 = if (budget == std.math.maxInt(usize)) 0 else budget;
            std.debug.print("{d:>7} {d:>9} {d:>6} {d:>6} {d:>6} {d:>10.1} {d:>9.2} {d:>9.2} {d:>9.2} {d:>9.2}\n", .{ seed, blab, fp, fn_, fp + fn_, detectionScore(fp, fn_, 0, N), mean_us, p50_us, p99_us, max_us });
        }
    }
    knn.repair_block_budget = std.math.maxInt(usize);
}

fn detectionScore(fp: usize, fn_: usize, errs: usize, n: usize) f64 {
    const E: f64 = @floatFromInt(fp * 1 + fn_ * 3 + errs * 5);
    const failures: f64 = @floatFromInt(fp + fn_ + errs);
    const nf: f64 = @floatFromInt(n);
    if (failures / nf > 0.15) return -3000;
    const eps = @max(E / nf, 0.001);
    return 1000.0 * std.math.log10(1.0 / eps) - 300.0 * std.math.log10(1.0 + E);
}

fn parseTestData(data: []const u8, out: *std.ArrayList(Entry), gpa: std.mem.Allocator) !void {
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, data, p, "\"request\":")) |rk| {

        const obj_start = std.mem.indexOfScalarPos(u8, data, rk, '{') orelse break;
        var depth: usize = 0;
        var i = obj_start;
        var obj_end = obj_start;
        while (i < data.len) : (i += 1) {
            switch (data[i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        obj_end = i + 1;
                        break;
                    }
                },
                else => {},
            }
        }
        const req = data[obj_start..obj_end];

        const ek = std.mem.indexOfPos(u8, data, obj_end, "\"expected_approved\":") orelse break;
        const after = ek + "\"expected_approved\":".len;
        const approved = data[after] == 't';

        const q = json.parseToVector(req) catch {
            p = obj_end;
            continue;
        };
        try out.append(gpa, .{ .q = q, .expected_approved = approved });
        p = obj_end;
    }
}
