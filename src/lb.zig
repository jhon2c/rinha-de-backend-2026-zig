
const std = @import("std");
const linux = std.os.linux;
const fdpass = @import("fdpass.zig");

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
        const c = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(c) != .SUCCESS) continue;
        const cfd: i32 = @intCast(c);
        setNoDelay(cfd);

        var sent = false;
        for (0..nback) |off| {
            const b = bfd[(rr + off) % nback];
            if (fdpass.sendFd(b, cfd)) |_| {
                sent = true;
                break;
            } else |_| {}
        }
        rr = (rr + 1) % nback;
        _ = linux.close(cfd);
        if (!sent) {}
    }
}

fn tcpListen(port: u16) !i32 {
    const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(s) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(s);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return error.Bind;
    if (linux.errno(linux.listen(fd, 4096)) != .SUCCESS) return error.Listen;
    return fd;
}

fn setNoDelay(fd: i32) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, 1, @ptrCast(&one), 4);
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
