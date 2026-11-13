//! A nonblocking PTY child for own-mode shell splits ("Shell in
//! worktree"). The same shape as venomx's own PTY
//! code: argv, environment and cwd are built before `forkpty`, and the
//! child only makes async-signal-safe calls, so it is safe to fork from a
//! process with other threads (the tests run a daemon on one).
//!
//! The child starts clean: every signal at its default disposition
//! and unblocked (an "ignore" survives exec, and Zig ignores SIGPIPE at
//! startup), and no fd above stderr, so it never holds the daemon link or
//! anything else of venom's, CLOEXEC or not.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

extern "c" fn forkpty(*c_int, ?[*]u8, ?*const std.posix.termios, ?*const std.posix.winsize) c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn sigprocmask(how: c_int, noalias set: ?*const c.sigset_t, noalias oset: ?*c.sigset_t) c_int;

/// Above every signal number of the platforms venom builds for.
const signal_end = 65;
/// With no `close_range`, fds are closed one by one up to the limit, however
/// absurdly high that limit is set.
const close_cap = 65536;

/// The highest fd the child might have to close, read before the fork.
fn fdLimit() c_int {
    var lim: c.rlimit = undefined;
    if (c.getrlimit(.NOFILE, &lim) != 0) return close_cap;
    return @intCast(@min(lim.cur, close_cap));
}

/// In the child, between fork and exec: only async-signal-safe calls.
fn cleanChild(fd_limit: c_int) void {
    const dfl: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
    var sig: u32 = 1;
    // SIGKILL, SIGSTOP and libc's reserved signals refuse; that is fine.
    while (sig < signal_end) : (sig += 1) _ = c.sigaction(@fromBackingInt(@intCast(sig)), &dfl, null);
    const empty = std.mem.zeroes(c.sigset_t);
    _ = sigprocmask(c.SIG.SETMASK, &empty, null);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        if (linux.errno(linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false })) == .SUCCESS) return;
    }
    var fd: c_int = 3;
    while (fd < fd_limit) : (fd += 1) _ = c.close(fd);
}

pub const Size = struct { cols: u16, rows: u16 };

/// What the child runs. `path` is absolute (no PATH search in the child).
pub const Launch = struct {
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    env: [*:null]const ?[*:0]const u8,
    cwd: [*:0]const u8,
};

pub const Pty = struct {
    fd: c_int,
    pid: c.pid_t,
    reaped: bool = false,
    eof: bool = false,
    status: u32 = 0,

    /// Starts the child. A failed `chdir` or `execve` exits it with 127,
    /// which the caller sees as an early exit.
    pub fn spawn(launch: Launch, size: Size) !Pty {
        const ws: std.posix.winsize = .{ .col = size.cols, .row = size.rows, .xpixel = 0, .ypixel = 0 };
        var fd: c_int = -1;
        const fd_limit = fdLimit();
        const pid = forkpty(&fd, null, null, &ws);
        if (pid < 0) return error.ForkPty;
        if (pid == 0) {
            cleanChild(fd_limit);
            if (chdir(launch.cwd) != 0) c._exit(126);
            _ = execve(launch.path, launch.argv, launch.env);
            c._exit(127);
        }
        var self: Pty = .{ .fd = fd, .pid = pid };
        errdefer self.deinit();
        const flags = c.fcntl(fd, c.F.GETFL);
        const nb: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
        if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nb) < 0 or c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SystemResources;
        return self;
    }

    /// Closes the master and ends the child's session: SIGHUP to its
    /// process group (forkpty made it a session leader), then SIGKILL if
    /// it is still there after a short grace. Bounded.
    pub fn deinit(self: *Pty) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.reaped) return;
        _ = c.kill(-self.pid, .HUP);
        _ = c.kill(self.pid, .HUP);
        if (self.reapUntil(nowMs() + 300)) return;
        _ = c.kill(-self.pid, .KILL);
        _ = c.kill(self.pid, .KILL);
        _ = self.reapUntil(nowMs() + 300);
    }

    pub fn reapUntil(self: *Pty, deadline: i64) bool {
        while (true) {
            if (self.tryReap()) return true;
            if (nowMs() >= deadline) return false;
            const pause: c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
            _ = c.nanosleep(&pause, null);
        }
    }

    fn tryReap(self: *Pty) bool {
        if (self.reaped) return true;
        var status: c_int = 0;
        const n = c.waitpid(self.pid, &status, c.W.NOHANG);
        if (n == self.pid or (n < 0 and c.errno(n) == .CHILD)) {
            self.reaped = true;
            self.status = @bitCast(status);
            return true;
        }
        return false;
    }

    pub fn resize(self: Pty, size: Size) void {
        const ws: std.posix.winsize = .{ .col = size.cols, .row = size.rows, .xpixel = 0, .ypixel = 0 };
        _ = c.ioctl(self.fd, @as(c_int, @bitCast(@as(u32, @intCast(std.posix.T.IOCSWINSZ)))), @intFromPtr(&ws));
    }

    /// Reads what is there; 0 when nothing is (or at EOF, see `eof`).
    pub fn read(self: *Pty, buf: []u8) !usize {
        if (self.eof) return 0;
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);
        if (n < 0) switch (c.errno(n)) {
            .AGAIN, .INTR => return 0,
            .IO => {}, // Linux masters report EIO once the slave side closed.
            else => return error.PtyRead,
        };
        self.eof = true;
        return 0;
    }

    /// Writes all of `bytes`, waiting briefly when the master is full.
    pub fn writeAll(self: Pty, bytes: []const u8) !void {
        var done: usize = 0;
        var tries: usize = 0;
        while (done < bytes.len) {
            const n = c.write(self.fd, bytes[done..].ptr, bytes.len - done);
            if (n > 0) {
                done += @intCast(n);
                continue;
            }
            switch (c.errno(n)) {
                .AGAIN, .INTR => {
                    tries += 1;
                    if (tries > 200) return error.PtyFull;
                    const pause: c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                    _ = c.nanosleep(&pause, null);
                },
                else => return error.PtyWrite,
            }
        }
    }

    /// Writes what fits now; 0 when the master is full.
    pub fn writeSome(self: Pty, bytes: []const u8) !usize {
        const n = c.write(self.fd, bytes.ptr, bytes.len);
        if (n > 0) return @intCast(n);
        return switch (c.errno(n)) {
            .AGAIN, .INTR => 0,
            else => error.PtyWrite,
        };
    }

    /// True once the child is gone and its output is drained.
    pub fn exited(self: *Pty) bool {
        return self.eof and self.tryReap();
    }
};

pub fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const testing = std.testing;

test "the child gets default signal dispositions, no blocked signals and no venom fds" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // What a TUI process may hold: an fd without CLOEXEC, an ignored signal
    // and a blocked one.
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    const ign: c.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
    var old_usr1: c.Sigaction = undefined;
    try testing.expectEqual(@as(c_int, 0), c.sigaction(.USR1, &ign, &old_usr1));
    defer _ = c.sigaction(.USR1, &old_usr1, null);
    var pipe_was: c.Sigaction = undefined;
    try testing.expectEqual(@as(c_int, 0), c.sigaction(.PIPE, &ign, &pipe_was));
    defer _ = c.sigaction(.PIPE, &pipe_was, null);
    var old_mask: c.sigset_t = undefined;
    var block = std.mem.zeroes(c.sigset_t);
    _ = c.sigaddset(&block, .USR2);
    try testing.expectEqual(@as(c_int, 0), sigprocmask(c.SIG.BLOCK, &block, &old_mask));
    defer _ = sigprocmask(c.SIG.SETMASK, &old_mask, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = try std.fmt.allocPrintSentinel(a, "stty -echo -onlcr; grep -E '^Sig(Ign|Blk):' /proc/self/status; ls /proc/$$/fd | tr '\\n' ' '; echo; test -e /proc/$$/fd/{d} && echo leaked || echo clean", .{fds[1]}, 0);
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    var p = try Pty.spawn(.{ .path = "/bin/sh", .argv = &argv, .env = &env, .cwd = "/" }, .{ .cols = 200, .rows = 24 });
    defer p.deinit();
    var out: std.ArrayList(u8) = .empty;
    const deadline = nowMs() + 10_000;
    var buf: [4096]u8 = undefined;
    while (!p.eof) {
        const n = try p.read(&buf);
        try out.appendSlice(a, buf[0..n]);
        if (nowMs() > deadline) return error.Timeout;
    }
    errdefer std.debug.print("child said:\n{s}\n", .{out.items});
    // Read by grep, not the shell: a shell ignores and blocks things itself.
    try testing.expect(std.mem.indexOf(u8, out.items, "SigIgn:\t0000000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "SigBlk:\t0000000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "clean") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "leaked") == null);
    // Only stdio is left in the shell.
    try testing.expect(std.mem.indexOf(u8, out.items, "0 1 2 \n") != null);
}
