//! One harness process: a child of the venom daemon
//! with pipes on stdin, stdout and stderr, in its own process group, with a
//! parent-death signal so it never outlives a crashed daemon.
//!
//! The process is adopted by venom-std's `supervisor.Leaders` right after
//! the fork: it is the only code that waits for it, so its group is pinned
//! until it is reaped and termination (SIGTERM, then SIGKILL after the
//! grace period) never signals a recycled pid. Restart with backoff is the
//! host's job (`host.zig`), with `supervisor.Policy`.
//!
//! venom-std's `Supervisor.addProcess` is not used for harnesses: its
//! process workers inherit the daemon's stdio, and a harness needs pipes.
const std = @import("std");
const builtin = @import("builtin");
const supervisor = @import("supervisor");
const contract = @import("contract.zig");
const c = std.c;
const guard = @import("guard.zig");
const linux = std.os.linux;

/// At most this much of stderr is kept for `failed.harness_exited`.
pub const stderr_tail_max = 4096;
/// A harness line longer than this is a protocol error.
pub const line_max = 16 * 1024 * 1024;

pub const Exit = union(enum) {
    code: u8,
    signal: u32,

    pub fn ok(self: Exit) bool {
        return self == .code and self.code == 0;
    }
};

pub const Process = struct {
    gpa: std.mem.Allocator,
    leader: *supervisor.Leader,
    stdin: c.fd_t,
    stdout: c.fd_t,
    stderr: c.fd_t,
    out: std.ArrayList(u8) = .empty,
    /// Consumed prefix of `out`.
    out_head: usize = 0,
    tail: [stderr_tail_max]u8 = undefined,
    tail_len: usize = 0,

    pub fn pid(self: *const Process) c.pid_t {
        return self.leader.pid;
    }

    /// Forks and execs `spec` in a new process group. Everything the child
    /// needs is allocated before the fork, so the child only makes
    /// async-signal-safe calls. Exit status 127 means exec failed, 126 that
    /// the cwd could not be entered.
    pub fn spawn(gpa: std.mem.Allocator, leaders: *supervisor.Leaders, spec: contract.Spawn) !Process {
        if (spec.argv.len == 0) return error.EmptyArgv;
        // Tests never exec a real claude or codex.
        try guard.checkSpawn(spec.argv[0]);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const argv = try a.allocSentinel(?[*:0]const u8, spec.argv.len, null);
        for (spec.argv, 0..) |arg, i| argv[i] = try a.dupeSentinel(u8, arg, 0);
        const envp = try environment(a, spec.env);
        // The copies may hold a token: wipe them with the arena.
        defer for (envp[envp.len - spec.env.len ..]) |e| std.crypto.secureZero(u8, @constCast(std.mem.span(e.?)));
        const cwd: ?[*:0]const u8 = if (spec.cwd) |d| try a.dupeSentinel(u8, d, 0) else null;

        var in: [2]c.fd_t = undefined;
        var out: [2]c.fd_t = undefined;
        var err: [2]c.fd_t = undefined;
        try pipe(&in);
        errdefer closeBoth(in);
        try pipe(&out);
        errdefer closeBoth(out);
        try pipe(&err);
        errdefer closeBoth(err);

        const parent = c.getpid();
        const child = fork();
        if (child < 0) return error.ForkFailed;
        if (child == 0) {
            _ = c.setpgid(0, 0);
            if (builtin.os.tag == .linux) {
                _ = c.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @as(c_ulong, @intCast(@backingInt(std.posix.SIG.TERM))));
                // The daemon died between fork and prctl.
                if (c.getppid() != parent) c._exit(1);
            }
            _ = c.dup2(in[0], 0);
            _ = c.dup2(out[1], 1);
            _ = c.dup2(err[1], 2);
            // Dispositions set to "ignore" survive exec; handlers do not.
            const dfl: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
            _ = c.sigaction(.TERM, &dfl, null);
            _ = c.sigaction(.INT, &dfl, null);
            _ = c.sigaction(.PIPE, &dfl, null);
            const empty = std.mem.zeroes(c.sigset_t);
            _ = sigprocmask(c.SIG.SETMASK, &empty, null);
            if (cwd) |d| if (c.chdir(d) != 0) c._exit(126);
            _ = execvpe(argv[0].?, argv.ptr, envp.ptr);
            c._exit(127);
        }
        // Also here, so a signal to the group cannot race the child's setpgid.
        _ = c.setpgid(child, child);
        _ = c.close(in[0]);
        _ = c.close(out[1]);
        _ = c.close(err[1]);
        errdefer {
            _ = c.close(in[1]);
            _ = c.close(out[0]);
            _ = c.close(err[0]);
        }
        try nonblocking(out[0]);
        try nonblocking(err[0]);
        const leader = leaders.adopt(child) catch |e| {
            _ = c.kill(-child, .KILL);
            var status: c_int = 0;
            _ = c.waitpid(child, &status, 0);
            return e;
        };
        return .{ .gpa = gpa, .leader = leader, .stdin = in[1], .stdout = out[0], .stderr = err[0] };
    }

    /// Closes the pipes and frees buffers. The process itself is the
    /// `Leaders`' (terminate it first); release the leader once it exited.
    pub fn deinit(self: *Process) void {
        self.closeInput();
        if (self.stdout >= 0) _ = c.close(self.stdout);
        if (self.stderr >= 0) _ = c.close(self.stderr);
        self.stdout = -1;
        self.stderr = -1;
        self.out.deinit(self.gpa);
    }

    /// Writes all of `bytes` to the harness's stdin. A harness that is gone
    /// is `error.HarnessExited` (the daemon ignores SIGPIPE).
    pub fn write(self: *Process, bytes: []const u8) !void {
        if (self.stdin < 0) return error.HarnessExited;
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(self.stdin, rest.ptr, rest.len);
            if (n < 0) switch (c.errno(n)) {
                .INTR => continue,
                .PIPE => return error.HarnessExited,
                else => return error.WriteFailed,
            };
            rest = rest[@intCast(n)..];
        }
    }

    pub fn closeInput(self: *Process) void {
        if (self.stdin >= 0) _ = c.close(self.stdin);
        self.stdin = -1;
    }

    /// Signals the process group while the leader is pinned (not reaped).
    pub fn signal(self: *Process, sig: std.posix.SIG) !void {
        if (self.leader.phase == .exited) return error.HarnessExited;
        if (c.kill(-self.leader.pid, sig) != 0) return error.HarnessExited;
    }

    /// Reads what stdout and stderr have, without blocking. Returns false
    /// once both are at end of file.
    pub fn pump(self: *Process) !bool {
        if (self.stdout >= 0) {
            var buf: [16 * 1024]u8 = undefined;
            while (true) {
                const n = c.read(self.stdout, &buf, buf.len);
                if (n < 0) switch (c.errno(n)) {
                    .INTR => continue,
                    .AGAIN => break,
                    else => return error.ReadFailed,
                };
                if (n == 0) {
                    _ = c.close(self.stdout);
                    self.stdout = -1;
                    break;
                }
                if (self.out.items.len - self.out_head + @as(usize, @intCast(n)) > line_max) return error.HarnessProtocol;
                try self.out.appendSlice(self.gpa, buf[0..@intCast(n)]);
            }
        }
        if (self.stderr >= 0) {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = c.read(self.stderr, &buf, buf.len);
                if (n < 0) switch (c.errno(n)) {
                    .INTR => continue,
                    .AGAIN => break,
                    else => return error.ReadFailed,
                };
                if (n == 0) {
                    _ = c.close(self.stderr);
                    self.stderr = -1;
                    break;
                }
                self.keepTail(buf[0..@intCast(n)]);
            }
        }
        return self.stdout >= 0 or self.stderr >= 0;
    }

    /// The next complete stdout line (without its newline), valid until the
    /// next `pump` or `nextLine`. At end of file a last unterminated line is
    /// returned too.
    pub fn nextLine(self: *Process) ?[]const u8 {
        const rest = self.out.items[self.out_head..];
        if (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            self.out_head += i + 1;
            return std.mem.trimEnd(u8, rest[0..i], "\r");
        }
        if (self.stdout < 0 and rest.len > 0) {
            self.out_head += rest.len;
            return rest;
        }
        // Compact before the next read.
        if (self.out_head > 0) {
            std.mem.copyForwards(u8, self.out.items, rest);
            self.out.shrinkRetainingCapacity(rest.len);
            self.out_head = 0;
        }
        return null;
    }

    pub fn stderrTail(self: *const Process) []const u8 {
        return self.tail[0..self.tail_len];
    }

    fn keepTail(self: *Process, bytes: []const u8) void {
        if (bytes.len >= self.tail.len) {
            @memcpy(&self.tail, bytes[bytes.len - self.tail.len ..]);
            self.tail_len = self.tail.len;
            return;
        }
        const keep = @min(self.tail_len, self.tail.len - bytes.len);
        std.mem.copyForwards(u8, self.tail[0..keep], self.tail[self.tail_len - keep .. self.tail_len]);
        @memcpy(self.tail[keep .. keep + bytes.len], bytes);
        self.tail_len = keep + bytes.len;
    }
};

/// A write to a harness that is gone then fails with `error.HarnessExited`
/// instead of ending this process. Children get the default back at spawn.
pub fn ignoreSigpipe() void {
    const ignore: c.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
    _ = c.sigaction(.PIPE, &ignore, null);
}

pub fn exitOf(status: supervisor.leaders.Status) Exit {
    return switch (status) {
        .code => |code| .{ .code = code },
        .signal => |s| .{ .signal = s.number },
    };
}

/// venom's environment with `extra` added or replaced, null-terminated.
/// Credentials venom itself was started with (`VENOM*_TOKEN`, and the
/// informational `VENOM*_PRINCIPAL`) are never inherited:
/// a harness gets its own, through `extra`.
fn environment(a: std.mem.Allocator, extra: []const contract.EnvVar) ![:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    outer: while (c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        if (inheritedCredential(s)) continue;
        for (extra) |e| if (s.len > e.name.len and s[e.name.len] == '=' and std.mem.startsWith(u8, s, e.name)) continue :outer;
        try list.append(a, entry);
    }
    for (extra) |e| try list.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ e.name, e.value }, 0));
    return list.toOwnedSliceSentinel(a, null);
}

/// `VENOM_TOKEN=…`, `VENOMX_TOKEN=…`, `VENOM_DESK_PRINCIPAL=…` and the like.
pub fn inheritedCredential(entry: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    return credentialName(entry[0..eq]);
}

pub fn credentialName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "VENOM") and (std.mem.endsWith(u8, name, "_TOKEN") or std.mem.endsWith(u8, name, "_PRINCIPAL"));
}

fn pipe(fds: *[2]c.fd_t) !void {
    if (c.pipe2(fds, .{ .CLOEXEC = true }) != 0) return error.SystemResources;
}

fn closeBoth(fds: [2]c.fd_t) void {
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
}

fn nonblocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.SystemResources;
    if (c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) < 0) return error.SystemResources;
}

extern "c" fn fork() c.pid_t;
extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn sigprocmask(how: c_int, set: ?*const c.sigset_t, old: ?*c.sigset_t) c_int;

const testing = std.testing;

test "process: lines, stderr tail, env, cwd and exit status" {
    var leaders = supervisor.Leaders.init(testing.allocator, .{});
    defer leaders.deinit();
    var p = try Process.spawn(testing.allocator, &leaders, .{
        .argv = &.{ "sh", "-c", "read x; echo \"got $x in $(pwd) $VENOM_T\"; printf 'partial'; echo oops >&2; exit 3" },
        .cwd = "/",
        .env = &.{.{ .name = "VENOM_T", .value = "yes" }},
    });
    defer p.deinit();
    try p.write("hello\n");
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| testing.allocator.free(l);
        lines.deinit(testing.allocator);
    }
    var status: ?supervisor.leaders.Status = null;
    const deadline = supervisor.monotonicMs() + 5000;
    while (status == null) {
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        _ = try p.pump();
        while (p.nextLine()) |l| try lines.append(testing.allocator, try testing.allocator.dupe(u8, l));
        try leaders.tick();
        while (leaders.nextEvent()) |e| switch (e) {
            .exited => |l| status = l.status,
            .done => {},
        };
        var fds = [_]c.pollfd{.{ .fd = p.leader.pollFd() orelse -1, .events = c.POLL.IN }};
        _ = c.poll(&fds, 1, 10);
    }
    while (try p.pump()) {}
    while (p.nextLine()) |l| try lines.append(testing.allocator, try testing.allocator.dupe(u8, l));
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqualStrings("got hello in / yes", lines.items[0]);
    try testing.expectEqualStrings("partial", lines.items[1]);
    try testing.expectEqualStrings("oops\n", p.stderrTail());
    try testing.expectEqual(Exit{ .code = 3 }, exitOf(status.?));
    try leaders.release(p.leader);
}

test "process: a missing binary exits 127 and the tail keeps the last 4 KiB" {
    var leaders = supervisor.Leaders.init(testing.allocator, .{});
    defer leaders.deinit();
    var p = try Process.spawn(testing.allocator, &leaders, .{ .argv = &.{"venom-no-such-harness-binary"} });
    defer p.deinit();
    const big: [5000]u8 = @splat('x');
    p.keepTail(&big);
    p.keepTail("end");
    try testing.expectEqual(@as(usize, stderr_tail_max), p.stderrTail().len);
    try testing.expect(std.mem.endsWith(u8, p.stderrTail(), "xend"));
    const deadline = supervisor.monotonicMs() + 5000;
    while (p.leader.phase != .exited) {
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        try leaders.tick();
        _ = c.poll(@as([*]c.pollfd, undefined), 0, 5);
    }
    try testing.expectEqual(Exit{ .code = 127 }, exitOf(p.leader.status.?));
    while (leaders.nextEvent()) |_| {}
    try leaders.release(p.leader);
}

test "process: a test cannot exec a real claude or codex" {
    var leaders = supervisor.Leaders.init(testing.allocator, .{});
    defer leaders.deinit();
    guard.quiet = true;
    defer guard.quiet = false;
    for (guard.vendors) |v| {
        if (guard.optedIn(v)) continue;
        try testing.expectError(error.RealHarnessInTest, Process.spawn(testing.allocator, &leaders, .{ .argv = &.{ v.exe, "--version" } }));
        const abs = try std.fmt.allocPrint(testing.allocator, "/usr/bin/{s}", .{v.exe});
        defer testing.allocator.free(abs);
        try testing.expectError(error.RealHarnessInTest, Process.spawn(testing.allocator, &leaders, .{ .argv = &.{abs} }));
    }
}
