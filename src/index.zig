
const std = @import("std");
const vec = @import("vec.zig");

pub const Vec = vec.Vec;
pub const Block = vec.Block;
pub const MAGIC: u32 = 0x52494E48;
pub const VERSION: u32 = 4;

pub const Header = extern struct {
    magic: u32 = MAGIC,
    version: u32 = VERSION,
    n: u32,
    k: u32,
    dim: u32 = vec.DIM,
    lanes: u32 = vec.LANES,
    n_pad: u32,
    _reserved: [36]u8 = [_]u8{0} ** 36,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
}

inline fn align64(x: usize) usize {
    return (x + 63) & ~@as(usize, 63);
}

const SectionOffsets = struct {
    centroids: usize,
    centroid_blocks: usize,
    bbox_min: usize,
    bbox_max: usize,
    block_off: usize,
    vector_blocks: usize,
    labels: usize,
    orig: usize,
    total: usize,
};

fn layout(n_pad: usize, k: usize) SectionOffsets {
    std.debug.assert(k % vec.BLOCK == 0);
    std.debug.assert(n_pad % vec.BLOCK == 0);
    var o: usize = align64(@sizeOf(Header));
    const centroids = o;
    o = align64(o + k * @sizeOf(Vec));
    const centroid_blocks = o;
    o = align64(o + (k / vec.BLOCK) * @sizeOf(Block));
    const bbox_min = o;
    o = align64(o + k * @sizeOf(Vec));
    const bbox_max = o;
    o = align64(o + k * @sizeOf(Vec));
    const block_off = o;
    o = align64(o + (k + 1) * @sizeOf(u32));
    const vector_blocks = o;
    o = align64(o + (n_pad / vec.BLOCK) * @sizeOf(Block));
    const labels = o;
    o = align64(o + n_pad * @sizeOf(u8));
    const orig = o;
    o = align64(o + n_pad * @sizeOf(u32));
    return .{
        .centroids = centroids,
        .centroid_blocks = centroid_blocks,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .block_off = block_off,
        .vector_blocks = vector_blocks,
        .labels = labels,
        .orig = orig,
        .total = o,
    };
}

pub const Index = struct {
    n: usize,
    k: usize,
    n_pad: usize,
    centroids: []const Vec,
    centroid_blocks: []const Block,
    bbox_min: []const Vec,
    bbox_max: []const Vec,
    block_off: []const u32,
    vector_blocks: []const Block,
    labels: []const u8,
    orig: []const u32,

    cluster_frauds: []const u32 = &.{},
    cluster_size: []const u32 = &.{},

    pub fn load(bytes: []align(8) const u8) !Index {
        if (bytes.len < @sizeOf(Header)) return error.IndexTooSmall;
        const hdr: *const Header = @ptrCast(bytes.ptr);
        if (hdr.magic != MAGIC) return error.BadMagic;
        if (hdr.version != VERSION) return error.BadVersion;
        if (hdr.dim != vec.DIM or hdr.lanes != vec.LANES) return error.DimMismatch;
        const n = hdr.n;
        const k = hdr.k;
        const n_pad = hdr.n_pad;
        const o = layout(n_pad, k);
        if (bytes.len < o.total) return error.IndexTruncated;
        return .{
            .n = n,
            .k = k,
            .n_pad = n_pad,
            .centroids = sliceOf(Vec, bytes, o.centroids, k),
            .centroid_blocks = sliceOf(Block, bytes, o.centroid_blocks, k / vec.BLOCK),
            .bbox_min = sliceOf(Vec, bytes, o.bbox_min, k),
            .bbox_max = sliceOf(Vec, bytes, o.bbox_max, k),
            .block_off = sliceOf(u32, bytes, o.block_off, k + 1),
            .vector_blocks = sliceOf(Block, bytes, o.vector_blocks, n_pad / vec.BLOCK),
            .labels = sliceOf(u8, bytes, o.labels, n_pad),
            .orig = sliceOf(u32, bytes, o.orig, n_pad),
        };
    }

    pub fn buildClusterStats(self: *Index, gpa: std.mem.Allocator) !void {
        const frauds = try gpa.alloc(u32, self.k);
        const sizes = try gpa.alloc(u32, self.k);
        for (0..self.k) |c| {
            var f: u32 = 0;
            var s: u32 = 0;
            var i: usize = @as(usize, self.block_off[c]) * vec.BLOCK;
            const end: usize = @as(usize, self.block_off[c + 1]) * vec.BLOCK;
            while (i < end) : (i += 1) {
                if (self.orig[i] == 0xFFFFFFFF) continue;
                s += 1;
                f += self.labels[i];
            }
            frauds[c] = f;
            sizes[c] = s;
        }
        self.cluster_frauds = frauds;
        self.cluster_size = sizes;
    }
};

fn sliceOf(comptime T: type, bytes: []const u8, off: usize, count: usize) []const T {
    const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr + off));
    return ptr[0..count];
}

pub fn write(
    w: *std.Io.Writer,
    n: usize,
    k: usize,
    n_pad: usize,
    centroids: []const Vec,
    centroid_blocks: []const Block,
    bbox_min: []const Vec,
    bbox_max: []const Vec,
    block_off: []const u32,
    vector_blocks: []const Block,
    labels: []const u8,
    orig: []const u32,
) !void {
    std.debug.assert(centroids.len == k);
    std.debug.assert(centroid_blocks.len == k / vec.BLOCK);
    std.debug.assert(bbox_min.len == k and bbox_max.len == k);
    std.debug.assert(block_off.len == k + 1);
    std.debug.assert(vector_blocks.len == n_pad / vec.BLOCK);
    std.debug.assert(labels.len == n_pad and orig.len == n_pad);

    const o = layout(n_pad, k);
    const hdr = Header{ .n = @intCast(n), .k = @intCast(k), .n_pad = @intCast(n_pad) };

    var cur: usize = 0;
    cur = try emit(w, cur, o.centroids, std.mem.asBytes(&hdr));
    cur = try emit(w, cur, o.centroid_blocks, std.mem.sliceAsBytes(centroids));
    cur = try emit(w, cur, o.bbox_min, std.mem.sliceAsBytes(centroid_blocks));
    cur = try emit(w, cur, o.bbox_max, std.mem.sliceAsBytes(bbox_min));
    cur = try emit(w, cur, o.block_off, std.mem.sliceAsBytes(bbox_max));
    cur = try emit(w, cur, o.vector_blocks, std.mem.sliceAsBytes(block_off));
    cur = try emit(w, cur, o.labels, std.mem.sliceAsBytes(vector_blocks));
    cur = try emit(w, cur, o.orig, labels);
    cur = try emit(w, cur, o.total, std.mem.sliceAsBytes(orig));
    std.debug.assert(cur == o.total);
}

fn emit(w: *std.Io.Writer, cur: usize, next: usize, bytes: []const u8) !usize {
    try w.writeAll(bytes);
    var pad = next - (cur + bytes.len);
    const zeros = [_]u8{0} ** 64;
    while (pad > 0) {
        const chunk = @min(pad, zeros.len);
        try w.writeAll(zeros[0..chunk]);
        pad -= chunk;
    }
    return next;
}

pub const SoA = struct {
    n_pad: usize,
    centroid_blocks: []Block,
    block_off: []u32,
    vector_blocks: []Block,
    labels: []u8,
    orig: []u32,

    pub fn deinit(self: *SoA, gpa: std.mem.Allocator) void {
        gpa.free(self.centroid_blocks);
        gpa.free(self.block_off);
        gpa.free(self.vector_blocks);
        gpa.free(self.labels);
        gpa.free(self.orig);
    }
};

pub const SENTINEL_VEC: Vec = blk: {
    var v: Vec = [_]i16{0} ** vec.LANES;
    for (0..vec.DIM) |d| v[d] = 16384;
    break :blk v;
};

pub fn buildSoA(
    gpa: std.mem.Allocator,
    k: usize,
    centroids: []const Vec,
    cluster_off: []const u32,
    vectors: []const Vec,
    labels_in: []const u8,
    orig_in: []const u32,
) !SoA {
    std.debug.assert(k % vec.BLOCK == 0);
    const block_off = try gpa.alloc(u32, k + 1);
    block_off[0] = 0;
    for (0..k) |c| {
        const sz = cluster_off[c + 1] - cluster_off[c];
        const blocks = (sz + vec.BLOCK - 1) / vec.BLOCK;
        block_off[c + 1] = block_off[c] + @as(u32, @intCast(blocks));
    }
    const nblocks = block_off[k];
    const n_pad = @as(usize, nblocks) * vec.BLOCK;

    const vector_blocks = try gpa.alloc(Block, nblocks);
    const out_lbl = try gpa.alloc(u8, n_pad);
    const out_orig = try gpa.alloc(u32, n_pad);

    for (0..k) |c| {
        const lo = cluster_off[c];
        const hi = cluster_off[c + 1];
        const bstart = block_off[c];
        var group: [vec.BLOCK]Vec = undefined;
        var bi: usize = 0;
        var fill: usize = 0;
        var src: usize = lo;
        while (src < hi or fill != 0) {
            if (src < hi) {
                const padpos = @as(usize, bstart + bi) * vec.BLOCK + fill;
                group[fill] = vectors[src];
                out_lbl[padpos] = labels_in[src];
                out_orig[padpos] = orig_in[src];
                src += 1;
                fill += 1;
            } else {
                const padpos = @as(usize, bstart + bi) * vec.BLOCK + fill;
                group[fill] = SENTINEL_VEC;
                out_lbl[padpos] = 0;
                out_orig[padpos] = 0xFFFFFFFF;
                fill += 1;
            }
            if (fill == vec.BLOCK) {
                vector_blocks[bstart + bi] = vec.packBlock(&group);
                bi += 1;
                fill = 0;
            }
        }
    }

    const centroid_blocks = try gpa.alloc(Block, k / vec.BLOCK);
    for (0..k / vec.BLOCK) |b| {
        var group: [vec.BLOCK]Vec = undefined;
        for (0..vec.BLOCK) |j| group[j] = centroids[b * vec.BLOCK + j];
        centroid_blocks[b] = vec.packBlock(&group);
    }

    return .{
        .n_pad = n_pad,
        .centroid_blocks = centroid_blocks,
        .block_off = block_off,
        .vector_blocks = vector_blocks,
        .labels = out_lbl,
        .orig = out_orig,
    };
}

test "layout round-trips through load" {
    const gpa = std.testing.allocator;
    const k: usize = 8;
    var centroids: [8]Vec = undefined;
    var bmin: [8]Vec = undefined;
    var bmax: [8]Vec = undefined;
    for (0..8) |i| {
        centroids[i] = [_]i16{@intCast(i)} ++ [_]i16{0} ** (vec.LANES - 1);
        bmin[i] = [_]i16{1} ** vec.LANES;
        bmax[i] = [_]i16{3} ** vec.LANES;
    }
    var cluster_off = [_]u32{ 0, 3, 3, 3, 3, 3, 3, 3, 3 };
    var vectors = [_]Vec{
        [_]i16{1} ++ [_]i16{0} ** (vec.LANES - 1),
        [_]i16{2} ++ [_]i16{0} ** (vec.LANES - 1),
        [_]i16{3} ++ [_]i16{0} ** (vec.LANES - 1),
    };
    var labels = [_]u8{ 1, 0, 1 };
    var orig = [_]u32{ 10, 11, 12 };

    var soa = try buildSoA(gpa, k, &centroids, &cluster_off, &vectors, &labels, &orig);
    defer soa.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try write(&buf.writer, 3, k, soa.n_pad, &centroids, soa.centroid_blocks, &bmin, &bmax, soa.block_off, soa.vector_blocks, soa.labels, soa.orig);

    const bytes = buf.written();
    const aligned = try gpa.alignedAlloc(u8, .@"8", bytes.len);
    defer gpa.free(aligned);
    @memcpy(aligned, bytes);

    const idx = try Index.load(aligned);
    try std.testing.expectEqual(@as(usize, 3), idx.n);
    try std.testing.expectEqual(@as(usize, 8), idx.n_pad);
    try std.testing.expectEqual(@as(u32, 0), idx.block_off[0]);
    try std.testing.expectEqual(@as(u32, 1), idx.block_off[1]);
    const v0 = vec.unpackLane(&idx.vector_blocks[0], 0);
    try std.testing.expectEqual(@as(i16, 1), v0[0]);
    try std.testing.expectEqual(@as(u8, 1), idx.labels[0]);
    try std.testing.expectEqual(@as(u32, 10), idx.orig[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), idx.orig[3]);
}
