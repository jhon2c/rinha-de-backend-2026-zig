
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const CMSG_DATA_OFF: usize = 16;
const CMSG_LEN_FD: usize = CMSG_DATA_OFF + @sizeOf(i32);
const CMSG_SPACE: usize = 24;

pub const MAX_PREFIX: usize = 16 * 1024;

pub fn sendFd(sock: i32, fd: i32) !void {
    var dummy = [_]u8{'X'};
    var iov = posix.iovec_const{ .base = &dummy, .len = 1 };
    var cbuf: [CMSG_SPACE]u8 align(8) = undefined;
    const cmsg: *linux.cmsghdr = @ptrCast(@alignCast(&cbuf));
    cmsg.len = CMSG_LEN_FD;
    cmsg.level = linux.SOL.SOCKET;
    cmsg.type = linux.SCM.RIGHTS;
    @memcpy(cbuf[CMSG_DATA_OFF .. CMSG_DATA_OFF + 4], std.mem.asBytes(&fd));

    var msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &cbuf,
        .controllen = CMSG_LEN_FD,
        .flags = 0,
    };
    while (true) {
        const r = linux.sendmsg(sock, &msg, 0);
        switch (linux.errno(r)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SendFd,
        }
    }
}

pub fn sendFdWithBytes(sock: i32, fd: i32, bytes: []const u8) !void {
    const payload = bytes[0..@min(bytes.len, MAX_PREFIX)];
    var len: u16 = @intCast(payload.len);
    var iov = [_]posix.iovec_const{
        .{ .base = @ptrCast(&len), .len = @sizeOf(u16) },
        .{ .base = payload.ptr, .len = payload.len },
    };
    var cbuf: [CMSG_SPACE]u8 align(8) = undefined;
    const cmsg: *linux.cmsghdr = @ptrCast(@alignCast(&cbuf));
    cmsg.len = CMSG_LEN_FD;
    cmsg.level = linux.SOL.SOCKET;
    cmsg.type = linux.SCM.RIGHTS;
    @memcpy(cbuf[CMSG_DATA_OFF .. CMSG_DATA_OFF + 4], std.mem.asBytes(&fd));

    var msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = iov.len,
        .control = &cbuf,
        .controllen = CMSG_LEN_FD,
        .flags = 0,
    };
    while (true) {
        const r = linux.sendmsg(sock, &msg, 0);
        switch (linux.errno(r)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SendFd,
        }
    }
}

pub const RecvResult = union(enum) {
    fd: i32,
    again,
    closed,
};

pub const RecvBytesResult = union(enum) {
    msg: struct { fd: i32, len: usize },
    again,
    closed,
};

pub fn recvFd(sock: i32) RecvResult {
    var dummy: [1]u8 = undefined;
    var iov = posix.iovec{ .base = &dummy, .len = 1 };
    var cbuf: [CMSG_SPACE]u8 align(8) = undefined;
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &cbuf,
        .controllen = CMSG_SPACE,
        .flags = 0,
    };
    const r = linux.recvmsg(sock, &msg, 0);
    switch (linux.errno(r)) {
        .SUCCESS => {},
        .AGAIN => return .again,
        .INTR => return .again,
        else => return .closed,
    }
    if (r == 0) return .closed;
    const cmsg: *const linux.cmsghdr = @ptrCast(@alignCast(&cbuf));
    if (msg.controllen < CMSG_LEN_FD or cmsg.level != linux.SOL.SOCKET or cmsg.type != linux.SCM.RIGHTS)
        return .again;
    var fd: i32 = undefined;
    @memcpy(std.mem.asBytes(&fd), cbuf[CMSG_DATA_OFF .. CMSG_DATA_OFF + 4]);
    return .{ .fd = fd };
}

pub fn recvFdWithBytes(sock: i32, out: []u8) RecvBytesResult {
    var len: u16 = 0;
    var iov = [_]posix.iovec{
        .{ .base = @ptrCast(&len), .len = @sizeOf(u16) },
        .{ .base = out.ptr, .len = @min(out.len, MAX_PREFIX) },
    };
    var cbuf: [CMSG_SPACE]u8 align(8) = undefined;
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = iov.len,
        .control = &cbuf,
        .controllen = CMSG_SPACE,
        .flags = 0,
    };
    const r = linux.recvmsg(sock, &msg, 0);
    switch (linux.errno(r)) {
        .SUCCESS => {},
        .AGAIN => return .again,
        .INTR => return .again,
        else => return .closed,
    }
    if (r == 0) return .closed;
    if (r < @sizeOf(u16)) return .closed;
    const n: usize = len;
    if (n > out.len or n > MAX_PREFIX or r != @sizeOf(u16) + n) return .closed;

    const cmsg: *const linux.cmsghdr = @ptrCast(@alignCast(&cbuf));
    if (msg.controllen < CMSG_LEN_FD or cmsg.level != linux.SOL.SOCKET or cmsg.type != linux.SCM.RIGHTS)
        return .again;
    var fd: i32 = undefined;
    @memcpy(std.mem.asBytes(&fd), cbuf[CMSG_DATA_OFF .. CMSG_DATA_OFF + 4]);
    return .{ .msg = .{ .fd = fd, .len = n } };
}

pub fn connectUnixSeqpacket(path: [:0]const u8) ?i32 {
    const s = linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(s) != .SUCCESS) return null;
    const fd: i32 = @intCast(s);
    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) {
        _ = linux.close(fd);
        return null;
    }
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

pub fn listenUnixSeqpacket(path: [:0]const u8, nonblock: bool) !i32 {
    var flags: u32 = linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC;
    if (nonblock) flags |= linux.SOCK.NONBLOCK;
    const s = linux.socket(linux.AF.UNIX, flags, 0);
    if (linux.errno(s) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(s);
    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = linux.unlink(path.ptr);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS)
        return error.Bind;
    if (linux.errno(linux.listen(fd, 64)) != .SUCCESS) return error.Listen;
    return fd;
}
