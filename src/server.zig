const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

const vec = @import("vec.zig");
const index = @import("index.zig");
const knn = @import("knn.zig");
const json = @import("json.zig");
const fdpass = @import("fdpass.zig");

const TCP_NODELAY = 1;
const TCP_QUICKACK = 12;

const EPIOCSPARAMS: u32 = 0x400c8a01;
const EpollParams = extern struct {
    busy_poll_usecs: u64,
    busy_poll_budget: u16,
    prefer_busy_poll: u8,
    pad: u8 = 0,
};

var g_index: index.Index = undefined;
var g_seed: usize = 12;
var g_busy_us: u32 = 50;
var g_epoll_timeout_us: i64 = 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    const idx_path = it.next() orelse "index.bin";
    const listen = it.next() orelse "8080";
    if (it.next()) |s| g_seed = try std.fmt.parseInt(usize, s, 10);
    var workers: usize = 96;
    if (it.next()) |s| workers = try std.fmt.parseInt(usize, s, 10);
    if (it.next()) |s| g_busy_us = try std.fmt.parseInt(u32, s, 10);
    if (it.next()) |s| g_epoll_timeout_us = try std.fmt.parseInt(i64, s, 10);

    var file = try std.Io.Dir.cwd().openFile(io, idx_path, .{});
    const st = try file.stat(io);
    const size: usize = @intCast(st.size);
    const page = std.heap.pageSize();
    const mapped = try posix.mmap(
        null,
        std.mem.alignForward(usize, size, page),
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    file.close(io);
    g_index = try index.Index.load(mapped);
    try g_index.buildClusterStats(gpa);
    warmIndex();
    _ = linux.mlockall(.{ .CURRENT = true, .FUTURE = true });
    warmupQueries(io, 900);

    ignoreSigpipe();

    if (listen.len > 0 and listen[0] == '/') {
        std.debug.print("server: n={d} k={d} seed={d} mode=epoll ctrl={s}\n", .{ g_index.n, g_index.k, g_seed, listen });
        try runEpoll(gpa, listen);
    } else {
        const port = try std.fmt.parseInt(u16, listen, 10);
        std.debug.print("server: n={d} k={d} seed={d} mode=tcp port={d} workers={d}\n", .{ g_index.n, g_index.k, g_seed, port, workers });
        const lfd = try listenSocket(port);
        const MAX_WORKERS = 512;
        var threads: [MAX_WORKERS]std.Thread = undefined;
        const total = @max(1, @min(workers, MAX_WORKERS));
        for (0..total - 1) |i| {
            threads[i] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, worker, .{lfd}) catch break;
        }
        worker(lfd);
    }
}

fn ignoreSigpipe() void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler.handler = linux.SIG.IGN;
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

const CONN_CAP: usize = 512;
const MAX_FD: usize = 65536;
const CONN_BUF: usize = 16 * 1024;
const EPOLL_EVENTS: usize = 1024;

const Conn = struct { buf: [CONN_BUF]u8 = undefined, len: usize = 0, fd: i32 = -1 };

var g_conns: []Conn = undefined;
var g_fd_slot: [MAX_FD]i32 = undefined;
var g_is_ctrl: [MAX_FD]bool = undefined;
var g_free: [CONN_CAP]u16 = undefined;
var g_nfree: usize = 0;
var g_ep: i32 = -1;

fn runEpoll(gpa: std.mem.Allocator, ctrl_path: [:0]const u8) !void {
    g_conns = try gpa.alloc(Conn, CONN_CAP);
    for (0..MAX_FD) |i| {
        g_fd_slot[i] = -1;
        g_is_ctrl[i] = false;
    }
    for (0..CONN_CAP) |i| g_free[CONN_CAP - 1 - i] = @intCast(i);
    g_nfree = CONN_CAP;

    const ufd = try fdpass.listenUnixSeqpacket(ctrl_path, true);
    const ep_u = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(ep_u) != .SUCCESS) return error.Epoll;
    g_ep = @intCast(ep_u);
    if (g_busy_us > 0) {
        var epp = EpollParams{ .busy_poll_usecs = g_busy_us, .busy_poll_budget = 8, .prefer_busy_poll = 1 };
        _ = linux.ioctl(g_ep, EPIOCSPARAMS, @intFromPtr(&epp));
    }
    epollAdd(ufd, linux.EPOLL.IN);

    var events: [EPOLL_EVENTS]linux.epoll_event = undefined;
    const ts = linux.timespec{ .sec = @divTrunc(g_epoll_timeout_us, 1_000_000), .nsec = @mod(g_epoll_timeout_us, 1_000_000) * 1000 };
    while (true) {
        const n_u = linux.syscall6(.epoll_pwait2, @as(usize, @bitCast(@as(isize, g_ep))), @intFromPtr(&events), events.len, @intFromPtr(&ts), 0, 8);
        if (linux.errno(n_u) != .SUCCESS) continue;
        const n: usize = @intCast(n_u);
        for (events[0..n]) |ev| {
            const fd = ev.data.fd;
            if (fd == ufd) {
                acceptCtrl(ufd);
            } else if (fd >= 0 and @as(usize, @intCast(fd)) < MAX_FD and g_is_ctrl[@intCast(fd)]) {
                drainCtrl(fd);
            } else {
                handleClient(fd);
            }
        }
    }
}

fn epollAdd(fd: i32, mask: u32) void {
    var ev = linux.epoll_event{ .events = mask, .data = .{ .fd = fd } };
    _ = linux.epoll_ctl(g_ep, linux.EPOLL.CTL_ADD, fd, &ev);
}

fn epollDel(fd: i32) void {
    _ = linux.epoll_ctl(g_ep, linux.EPOLL.CTL_DEL, fd, null);
}

fn acceptCtrl(ufd: i32) void {
    while (true) {
        const c = linux.accept4(ufd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        if (linux.errno(c) != .SUCCESS) return;
        const cfd: i32 = @intCast(c);
        if (@as(usize, @intCast(cfd)) >= MAX_FD) {
            _ = linux.close(cfd);
            continue;
        }
        g_is_ctrl[@intCast(cfd)] = true;
        epollAdd(cfd, linux.EPOLL.IN);
    }
}

fn drainCtrl(ctrl_fd: i32) void {
    var prefix: [fdpass.MAX_PREFIX]u8 = undefined;
    while (true) {
        switch (fdpass.recvFdWithBytes(ctrl_fd, &prefix)) {
            .again => return,
            .closed => {
                epollDel(ctrl_fd);
                _ = linux.close(ctrl_fd);
                g_is_ctrl[@intCast(ctrl_fd)] = false;
                return;
            },
            .msg => |msg| openClient(msg.fd, prefix[0..msg.len]),
        }
    }
}

fn openClient(fd: i32, prefix: []const u8) void {
    if (fd < 0 or @as(usize, @intCast(fd)) >= MAX_FD or g_nfree == 0) {
        _ = linux.close(fd);
        return;
    }
    setNonBlock(fd);
    g_nfree -= 1;
    const slot = g_free[g_nfree];
    g_conns[slot] = .{ .fd = fd, .len = 0 };
    if (prefix.len > 0) {
        const n = @min(prefix.len, g_conns[slot].buf.len);
        @memcpy(g_conns[slot].buf[0..n], prefix[0..n]);
        g_conns[slot].len = n;
    }
    g_fd_slot[@intCast(fd)] = slot;
    epollAdd(fd, linux.EPOLL.IN);
    if (prefix.len > 0) handleClient(fd);
}

fn closeClient(fd: i32) void {
    epollDel(fd);
    _ = linux.close(fd);
    const slot = g_fd_slot[@intCast(fd)];
    if (slot >= 0) {
        g_free[g_nfree] = @intCast(slot);
        g_nfree += 1;
        g_fd_slot[@intCast(fd)] = -1;
    }
}

fn handleClient(fd: i32) void {
    if (fd < 0 or @as(usize, @intCast(fd)) >= MAX_FD) return;
    const slot = g_fd_slot[@intCast(fd)];
    if (slot < 0) return;
    const conn = &g_conns[@intCast(slot)];

    if (conn.len < conn.buf.len) {
        read_once: while (true) {
            const r = linux.read(fd, conn.buf[conn.len..].ptr, conn.buf.len - conn.len);
            switch (linux.errno(r)) {
                .SUCCESS => {
                    if (r == 0) return closeClient(fd);
                    conn.len += r;
                    break :read_once;
                },
                .AGAIN => break :read_once,
                .INTR => continue,
                else => return closeClient(fd),
            }
        }
    }

    var off: usize = 0;
    while (true) {
        const view = conn.buf[off..conn.len];
        const he = headerEnd(view) orelse break;
        const req = parseHead(view[0..he]);
        var body_len: usize = 0;
        if (req.is_post) body_len = contentLength(view[0..he]) orelse 0;
        const total = he + body_len;
        if (view.len < total) break;

        const resp = route(req, view[he..total]);
        if (!writeAllFd(fd, resp)) return closeClient(fd);
        off += total;
        if (!req.keep_alive) return closeClient(fd);
    }

    if (off > 0) {
        const rem = conn.len - off;
        if (rem > 0) std.mem.copyForwards(u8, conn.buf[0..rem], conn.buf[off..conn.len]);
        conn.len = rem;
    } else if (conn.len == conn.buf.len) {
        return closeClient(fd);
    }
}

fn writeAllFd(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data.ptr + off, data.len - off);
        switch (linux.errno(w)) {
            .SUCCESS => off += w,
            .AGAIN, .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn setNonBlock(fd: i32) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, TCP_NODELAY, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, TCP_QUICKACK, @ptrCast(&one), 4);

    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(fl)) | linux.SOCK.NONBLOCK);
}

fn warmupQueries(io: std.Io, ms: i64) void {
    const t0 = std.Io.Clock.now(.awake, io);
    const limit_ns: i128 = @as(i128, ms) * 1_000_000;
    var rng: u64 = 0x9E3779B97F4A7C15;
    var n: usize = 0;
    while (true) {
        n += 1;
        if (n & 255 == 0) {
            const now = std.Io.Clock.now(.awake, io);
            if (now.nanoseconds - t0.nanoseconds > limit_ns) break;
        }
        var qv: vec.Vec = undefined;
        for (0..vec.LANES) |i| {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            qv[i] = @intCast((rng >> 16) % 10001);
        }
        const top = knn.searchExact(&g_index, &qv, g_seed);
        std.mem.doNotOptimizeAway(top.dist[0]);
    }
}

fn warmIndex() void {
    var sum: usize = 0;
    touch(std.mem.sliceAsBytes(g_index.centroids), &sum);
    touch(std.mem.sliceAsBytes(g_index.centroid_blocks), &sum);
    touch(std.mem.sliceAsBytes(g_index.bbox_min), &sum);
    touch(std.mem.sliceAsBytes(g_index.bbox_max), &sum);
    touch(std.mem.sliceAsBytes(g_index.block_off), &sum);
    touch(std.mem.sliceAsBytes(g_index.vector_blocks), &sum);
    touch(g_index.labels, &sum);
    touch(std.mem.sliceAsBytes(g_index.orig), &sum);
    std.mem.doNotOptimizeAway(sum);
}

fn touch(bytes: []const u8, sum: *usize) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 4096) sum.* +%= bytes[i];
}

fn listenSocket(port: u16) !i32 {
    const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(s) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(s);

    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);

    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return error.Bind;
    if (linux.errno(linux.listen(fd, 1024)) != .SUCCESS) return error.Listen;
    return fd;
}

fn worker(lfd: i32) void {
    while (true) {
        const c = linux.accept4(lfd, null, null, 0);
        if (linux.errno(c) != .SUCCESS) continue;
        const cfd: i32 = @intCast(c);
        const one: u32 = 1;
        _ = linux.setsockopt(cfd, linux.IPPROTO.TCP, TCP_NODELAY, @ptrCast(&one), 4);
        _ = linux.setsockopt(cfd, linux.IPPROTO.TCP, TCP_QUICKACK, @ptrCast(&one), 4);
        handleConn(cfd);
        _ = linux.close(cfd);
    }
}

fn readSome(fd: i32, buf: []u8) usize {
    while (true) {
        const r = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(r)) {
            .SUCCESS => return r,
            .INTR => continue,
            else => return 0,
        }
    }
}

fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data.ptr + off, data.len - off);
        switch (linux.errno(w)) {
            .SUCCESS => off += w,
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

const Req = struct { is_post: bool, target_ok: bool, keep_alive: bool };

fn handleConn(cfd: i32) void {
    var buf: [16 * 1024]u8 = undefined;
    var len: usize = 0;

    while (true) {
        var he = headerEnd(buf[0..len]);
        while (he == null) {
            if (len == buf.len) return;
            const r = readSome(cfd, buf[len..]);
            if (r == 0) return;
            len += r;
            he = headerEnd(buf[0..len]);
        }
        const head_len = he.?;
        const head = buf[0..head_len];

        const req = parseHead(head);
        var body_len: usize = 0;
        if (req.is_post) body_len = contentLength(head) orelse 0;
        const total = head_len + body_len;

        while (len < total) {
            if (len == buf.len) return;
            const r = readSome(cfd, buf[len..]);
            if (r == 0) return;
            len += r;
        }

        const resp = route(req, buf[head_len..total]);
        if (!writeAll(cfd, resp)) return;

        const leftover = len - total;
        if (leftover > 0) std.mem.copyForwards(u8, buf[0..leftover], buf[total..len]);
        len = leftover;

        if (!req.keep_alive) return;
    }
}

fn route(req: Req, body: []const u8) []const u8 {
    if (req.is_post and req.target_ok) {
        const q = json.parseToVector(body) catch return responses[0];
        const top = knn.searchExact(&g_index, &q, g_seed);
        return responses[top.fraudCount()];
    }
    if (!req.is_post and req.target_ok) return ready_response;

    return responses[0];
}

fn headerEnd(b: []const u8) ?usize {
    if (b.len < 4) return null;
    return if (std.mem.indexOf(u8, b, "\r\n\r\n")) |i| i + 4 else null;
}

fn parseHead(head: []const u8) Req {
    const line_end = std.mem.indexOfScalar(u8, head, '\r') orelse head.len;
    const line = head[0..line_end];
    const is_post = std.mem.startsWith(u8, line, "POST");

    const target_ok = true;

    const keep_alive = !containsCi(head, "connection: close");
    return .{ .is_post = is_post, .target_ok = target_ok, .keep_alive = keep_alive };
}

fn contentLength(head: []const u8) ?usize {
    const pos = indexOfCi(head, "content-length:") orelse return null;
    var i = pos + "content-length:".len;
    while (i < head.len and (head[i] == ' ' or head[i] == '\t')) i += 1;
    var v: usize = 0;
    var any = false;
    while (i < head.len and head[i] >= '0' and head[i] <= '9') : (i += 1) {
        v = v * 10 + (head[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn indexOfCi(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (lower(hay[i + j]) != needle[j]) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}

fn containsCi(hay: []const u8, needle: []const u8) bool {
    return indexOfCi(hay, needle) != null;
}

fn envU16(_: []const u8, default: u16) u16 {
    return default;
}

fn envUsize(_: []const u8, default: usize) usize {
    return default;
}

const responses = blk: {
    var arr: [6][]const u8 = undefined;
    const scores = [_][]const u8{ "0.0", "0.2", "0.4", "0.6", "0.8", "1.0" };
    for (0..6) |n| {
        const score = scores[n];
        const approved = if (n < 3) "true" else "false";
        const body = "{\"approved\":" ++ approved ++ ",\"fraud_score\":" ++ score ++ "}";
        arr[n] = std.fmt.comptimePrint(
            "HTTP/1.1 200 OK\r\ncontent-type:application/json\r\ncontent-length:{d}\r\n\r\n{s}",
            .{ body.len, body },
        );
    }
    break :blk arr;
};

const ready_response = "HTTP/1.1 200 OK\r\ncontent-length:0\r\n\r\n";
