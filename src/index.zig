
const std = @import("std");
const vec = @import("vec.zig");

pub const Vec = vec.Vec;
pub const MAGIC: u32 = 0x52494E48;
pub const VERSION: u32 = 3;

pub const Header = extern struct {
    magic: u32 = MAGIC,
    version: u32 = VERSION,
    n: u32,
    k: u32,
    dim: u32 = vec.DIM,
    lanes: u32 = vec.LANES,
    _reserved: [40]u8 = [_]u8{0} ** 40,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
}

inline fn align64(x: usize) usize {
    return (x + 63) & ~@as(usize, 63);
}

const SectionOffsets = struct {
    centroids: usize,
    bbox_min: usize,
    bbox_max: usize,
    cluster_off: usize,
    vectors: usize,
    labels: usize,
    orig: usize,
    total: usize,
};

fn layout(n: usize, k: usize) SectionOffsets {
    var o: usize = align64(@sizeOf(Header));
    const centroids = o;
    o = align64(o + k * @sizeOf(Vec));
    const bbox_min = o;
    o = align64(o + k * @sizeOf(Vec));
    const bbox_max = o;
    o = align64(o + k * @sizeOf(Vec));
    const cluster_off = o;
    o = align64(o + (k + 1) * @sizeOf(u32));
    const vectors = o;
    o = align64(o + n * @sizeOf(Vec));
    const labels = o;
    o = align64(o + n * @sizeOf(u8));
    const orig = o;
    o = align64(o + n * @sizeOf(u32));
    return .{
        .centroids = centroids,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .cluster_off = cluster_off,
        .vectors = vectors,
        .labels = labels,
        .orig = orig,
        .total = o,
    };
}

pub const Index = struct {
    n: usize,
    k: usize,
    centroids: []const Vec,
    bbox_min: []const Vec,
    bbox_max: []const Vec,
    cluster_off: []const u32,
    vectors: []const Vec,
    labels: []const u8,
    orig: []const u32,

    pub fn load(bytes: []align(8) const u8) !Index {
        if (bytes.len < @sizeOf(Header)) return error.IndexTooSmall;
        const hdr: *const Header = @ptrCast(bytes.ptr);
        if (hdr.magic != MAGIC) return error.BadMagic;
        if (hdr.version != VERSION) return error.BadVersion;
        if (hdr.dim != vec.DIM or hdr.lanes != vec.LANES) return error.DimMismatch;
        const n = hdr.n;
        const k = hdr.k;
        const o = layout(n, k);
        if (bytes.len < o.total) return error.IndexTruncated;
        return .{
            .n = n,
            .k = k,
            .centroids = sliceOf(Vec, bytes, o.centroids, k),
            .bbox_min = sliceOf(Vec, bytes, o.bbox_min, k),
            .bbox_max = sliceOf(Vec, bytes, o.bbox_max, k),
            .cluster_off = sliceOf(u32, bytes, o.cluster_off, k + 1),
            .vectors = sliceOf(Vec, bytes, o.vectors, n),
            .labels = sliceOf(u8, bytes, o.labels, n),
            .orig = sliceOf(u32, bytes, o.orig, n),
        };
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
    centroids: []const Vec,
    bbox_min: []const Vec,
    bbox_max: []const Vec,
    cluster_off: []const u32,
    vectors: []const Vec,
    labels: []const u8,
    orig: []const u32,
) !void {
    std.debug.assert(centroids.len == k);
    std.debug.assert(bbox_min.len == k and bbox_max.len == k);
    std.debug.assert(cluster_off.len == k + 1);
    std.debug.assert(vectors.len == n and labels.len == n and orig.len == n);

    const o = layout(n, k);
    const hdr = Header{ .n = @intCast(n), .k = @intCast(k) };

    var cur: usize = 0;
    cur = try emit(w, cur, o.centroids, std.mem.asBytes(&hdr));
    cur = try emit(w, cur, o.bbox_min, std.mem.sliceAsBytes(centroids));
    cur = try emit(w, cur, o.bbox_max, std.mem.sliceAsBytes(bbox_min));
    cur = try emit(w, cur, o.cluster_off, std.mem.sliceAsBytes(bbox_max));
    cur = try emit(w, cur, o.vectors, std.mem.sliceAsBytes(cluster_off));
    cur = try emit(w, cur, o.labels, std.mem.sliceAsBytes(vectors));
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

test "layout round-trips through load" {
    const n: usize = 3;
    const k: usize = 1;
    var centroids = [_]Vec{[_]i16{0} ** vec.LANES};
    var bmin = [_]Vec{[_]i16{1} ** vec.LANES};
    var bmax = [_]Vec{[_]i16{3} ** vec.LANES};
    var cluster_off = [_]u32{ 0, 3 };
    var vectors = [_]Vec{
        [_]i16{1} ++ [_]i16{0} ** (vec.LANES - 1),
        [_]i16{2} ++ [_]i16{0} ** (vec.LANES - 1),
        [_]i16{3} ++ [_]i16{0} ** (vec.LANES - 1),
    };
    var labels = [_]u8{ 1, 0, 1 };
    var orig = [_]u32{ 10, 11, 12 };

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try write(&buf.writer, n, k, &centroids, &bmin, &bmax, &cluster_off, &vectors, &labels, &orig);

    const bytes = buf.written();
    const aligned = try std.testing.allocator.alignedAlloc(u8, .@"8", bytes.len);
    defer std.testing.allocator.free(aligned);
    @memcpy(aligned, bytes);

    const idx = try Index.load(aligned);
    try std.testing.expectEqual(@as(usize, 3), idx.n);
    try std.testing.expectEqual(@as(i16, 2), idx.vectors[1][0]);
    try std.testing.expectEqual(@as(i16, 1), idx.bbox_min[0][0]);
    try std.testing.expectEqual(@as(i16, 3), idx.bbox_max[0][3]);
    try std.testing.expectEqual(@as(u8, 1), idx.labels[2]);
    try std.testing.expectEqual(@as(u32, 12), idx.orig[2]);
}
