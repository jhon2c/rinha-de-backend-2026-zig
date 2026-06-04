const std = @import("std");
const linux = std.os.linux;
const fdpass = @import("fdpass.zig");

const TCP_NODELAY = 1;
const TCP_QUICKACK = 12;
const ACCEPT_BATCH: usize = 64;
const TCP_DEFER_ACCEPT_SECS: u32 = 1;

pub fn main(init: std.process.Init) !void {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    const port = try std.fmt.parseInt(u16, it.next() orelse "9999", 10);

    var paths: [32][:0]const u8 = undefined;
    var nback: usize = 0;
    while (it.next()) |p| {
        if (nback >= paths.len) break;
        paths[nback] = p;
        nback += 1;
    }
    if (nback == 0) return error.NoBackends;

    ignoreSigpipe();

    var bfd: [32]i32 = undefined;
    for (0..nback) |i| {
        var tries: usize = 0;
        bfd[i] = while (tries < 600) : (tries += 1) {
            if (fdpass.connectUnixSeqpacket(paths[i])) |fd| break fd;
            sleepMs(100);
        } else return error.BackendUnavailable;
    }

    const lfd = try tcpListen(port);
    var rr: usize = 0;
    while (true) {
        var accepted: usize = 0;
        while (accepted < ACCEPT_BATCH) : (accepted += 1) {
            const c = linux.accept4(lfd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(c) != .SUCCESS) break;
            const cfd: i32 = @intCast(c);
            setFastSocket(cfd);

            var buf: [fdpass.MAX_PREFIX]u8 = undefined;
            const len = readReadyPrefix(cfd, &buf) orelse {
                _ = linux.close(cfd);
                continue;
            };
            const preferred = rr;
            rr = (rr + 1) % nback;
            if (!sendToBackend(bfd[0..nback], preferred, cfd, buf[0..len])) {
                _ = sendToBackendBlocking(bfd[0..nback], preferred, cfd, buf[0..len]);
            }
            _ = linux.close(cfd);
        }
        if (accepted == 0) waitRead(lfd);
    }
}

fn readReadyPrefix(fd: i32, buf: []u8) ?usize {
    var len: usize = 0;
    while (len < buf.len) {
        const r = linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (linux.errno(r)) {
            .SUCCESS => {
                if (r == 0) return null;
                len += r;
                continue;
            },
            .AGAIN => break,
            .INTR => continue,
            else => return null,
        }
    }
    return len;
}

fn sendToBackend(bfd: []const i32, preferred: usize, fd: i32, prefix: []const u8) bool {
    const flags = linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL;
    for (0..bfd.len) |off| {
        const b = bfd[(preferred + off) % bfd.len];
        if (fdpass.sendFdWithBytesFlags(b, fd, prefix, flags)) |_| return true else |_| {}
    }
    return false;
}

fn sendToBackendBlocking(bfd: []const i32, preferred: usize, fd: i32, prefix: []const u8) bool {
    for (0..bfd.len) |off| {
        const b = bfd[(preferred + off) % bfd.len];
        if (fdpass.sendFdWithBytes(b, fd, prefix)) |_| return true else |_| {}
    }
    return false;
}

fn tcpListen(port: u16) !i32 {
    const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(s) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(s);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.DEFER_ACCEPT, @ptrCast(&TCP_DEFER_ACCEPT_SECS), 4);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return error.Bind;
    if (linux.errno(linux.listen(fd, 65535)) != .SUCCESS) return error.Listen;
    return fd;
}

fn setFastSocket(fd: i32) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, TCP_NODELAY, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, TCP_QUICKACK, @ptrCast(&one), 4);
}

fn waitRead(fd: i32) void {
    var pfds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const r = linux.poll(pfds[0..].ptr, pfds.len, -1);
        switch (linux.errno(r)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn ignoreSigpipe() void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler.handler = linux.SIG.IGN;
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

fn sleepMs(ms: u64) void {
    var ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, &ts);
}
