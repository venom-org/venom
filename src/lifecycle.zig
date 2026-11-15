//! The daemon's lifetime: the restart-only `daemon` settings, the latched
//! lifetime state an on-demand daemon follows (it stops 5 s after its last
//! TUI quits), and the TUI's launcher that starts a missing daemon detached.
//!
//! Whoever starts the daemon decides its lifetime. `venom serve` is
//! persistent unless `--lifetime on-demand` says otherwise; a bare `venom` in
//! a terminal starts `serve --lifetime on-demand --origin interactive`. No
//! verb, hook or MCP call ever starts a daemon.
const std = @import("std");
const c = std.c;
const cfg = @import("cfg");
const proto = @import("proto");

/// The `daemon` config section. Every key is restart-only, and the TUI reads
/// them only after its first connect found no daemon.
pub const Settings = struct {
    /// Whether a bare `venom` may start a missing daemon.
    interactive_start: bool = true,
    /// The TUI's whole connect, launch and readiness budget.
    startup_timeout_ms: u32 = 5000,
    pub fn check(self: Settings) error{Invalid}!void {
        if (self.startup_timeout_ms < 100 or self.startup_timeout_ms > 60_000) return error.Invalid;
    }
};
pub const policies = [_]cfg.FieldPolicy{
    .{ .key = "daemon.interactive_start", .restart = true },
    .{ .key = "daemon.startup_timeout_ms", .restart = true },
};

/// `serve --origin`: who started the daemon. Shown by doctor and `tui.hold`;
/// it grants nothing.
pub const Origin = enum {
    serve,
    interactive,
    pub fn parse(value: []const u8) Origin {
        return std.meta.stringToEnum(Origin, value) orelse .serve;
    }
};

/// `serve --lifetime`, latched at start.
pub const Lifetime = enum {
    persistent,
    on_demand,
    pub fn parse(value: []const u8) Lifetime {
        return if (std.mem.eql(u8, value, "on-demand")) .on_demand else .persistent;
    }
    pub fn name(self: Lifetime) []const u8 {
        return switch (self) {
            .persistent => "persistent",
            .on_demand => "on-demand",
        };
    }
};

pub const Phase = enum { initializing, awaiting_first_client, active, lingering, stopping };

/// The first-client grace and the linger after the last TUI: fixed, not
/// configurable.
pub const wait_ms: i64 = 5000;
/// What a stopping daemon's cleanup may take after the harness grace: then
/// every child left gets SIGKILL and is reaped.
pub const cleanup_allowance_ms: u32 = 2000;

/// Latched at serve, and changed only in the reactor, so a hold and the
/// linger's expiry resolve in the order they commit. `stopping` is
/// irreversible. A persistent daemon is `active` from readiness on and
/// ignores holds.
pub const State = struct {
    lifetime: Lifetime = .persistent,
    origin: Origin = .serve,
    phase: Phase = .initializing,
    deadline_ms: i64 = 0,

    /// Readiness: the reactor is about to dispatch its first request.
    pub fn ready(self: *State, now_ms: i64) void {
        if (self.phase != .initializing) return;
        if (self.lifetime == .persistent) {
            self.phase = .active;
            return;
        }
        self.phase = .awaiting_first_client;
        self.deadline_ms = now_ms + wait_ms;
    }
    pub fn stopping(self: *const State) bool {
        return self.phase == .stopping;
    }
    /// A counted hold committed.
    pub fn held(self: *State) void {
        if (self.phase == .awaiting_first_client or self.phase == .lingering) self.phase = .active;
    }
    /// `holds` counted holds are left after one ended.
    pub fn released(self: *State, holds: usize, now_ms: i64) void {
        if (self.lifetime != .on_demand or self.phase != .active or holds != 0) return;
        self.phase = .lingering;
        self.deadline_ms = now_ms + wait_ms;
    }
    /// The grace or the linger ran out with no hold: stop. Nothing else
    /// (CLI verbs, agents, `events`, MCP, probes) extends either wait.
    pub fn tick(self: *State, now_ms: i64) void {
        if ((self.phase == .awaiting_first_client or self.phase == .lingering) and now_ms >= self.deadline_ms) self.phase = .stopping;
    }
    /// SIGINT or SIGTERM, in any state.
    pub fn stop(self: *State) void {
        self.phase = .stopping;
    }
    pub fn remainingMs(self: *const State, now_ms: i64) i64 {
        return switch (self.phase) {
            .awaiting_first_client, .lingering => @max(0, self.deadline_ms - now_ms),
            else => 0,
        };
    }
    /// Doctor: the state agrees with the counted holds and the clock.
    pub fn consistent(self: *const State, holds: usize, now_ms: i64) bool {
        return switch (self.phase) {
            .initializing => false,
            .awaiting_first_client, .lingering => self.lifetime == .on_demand and holds == 0 and now_ms < self.deadline_ms + 1000,
            .active => self.lifetime == .persistent or holds > 0,
            .stopping => true,
        };
    }
    /// The phase as `tui.hold` items and doctor name it.
    pub fn phaseName(self: *const State) []const u8 {
        return switch (self.phase) {
            .initializing, .awaiting_first_client => "awaiting_first_client",
            .active => "active",
            .lingering => "lingering",
            .stopping => "stopping",
        };
    }
};

// ---------------------------------------------------------------- launcher

/// Config locations must be absent or regular files: a FIFO or device would
/// make the bounded read block.
pub fn regularOrMissing(a: std.mem.Allocator, path: []const u8) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const st = proto.os.statAt(c.AT.FDCWD, z, 0) catch |err| return if (err == error.FileNotFound) {} else error.NotRegular;
    if (st.mode & c.S.IFMT != c.S.IFREG) return error.NotRegular;
}

/// The variables that mark a process inside a managed tree. Any of them,
/// even empty, keeps the TUI from starting a daemon.
pub const context_markers = [_][]const u8{ "VENOM_PRINCIPAL", "VENOM_AGENT", "VENOMX_PANE", "VENOMX_PRINCIPAL" };

/// The first managed-context variable present in `environ`, if any.
pub fn contextMarker(environ: std.process.Environ) ?[]const u8 {
    for (context_markers) |name| if (environ.getPosix(name) != null) return name;
    return null;
}

/// The path of a manager's marker that matches a process above this one, in
/// the directory of `socket`, or null. A daemon started there would stay
/// below that manager and refuse this caller its owner file. A missing
/// directory holds no marker and is not created.
pub fn managerMarker(a: std.mem.Allocator, socket: []const u8) !?[]const u8 {
    const dir = proto.os.runtimeDir(a, socket, false) catch |err| return if (err == error.NotRunning) null else err;
    defer proto.os.close(dir);
    const chain = proto.process.walk(c.getpid(), 0);
    if (chain.len < 2) return null;
    for (chain.refs[1..chain.len]) |ref| {
        // One process at a time, so that the denial can name the match.
        var one: proto.process.Chain = .{ .len = 2 };
        one.refs[0] = chain.refs[0];
        one.refs[1] = ref;
        if (!proto.managers.below(dir, one)) continue;
        return try std.fmt.allocPrint(a, "{s}/manager-{d}-{d}", .{ std.fs.path.dirname(socket) orelse ".", ref.pid, ref.start });
    }
    return null;
}

/// The refusal below a manager, naming its marker.
pub fn managerDenial(a: std.mem.Allocator, marker: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "venom is not running, and can't be started below a process manager: a manager's marker matches a process above this one ({s}); start `venom` in a terminal outside venomx. In a plain terminal the marker was forged, and deleting the file ends this", .{marker});
}

/// Whether some process holds the socket's lock (`<socket stem>.lock`)
/// right now: a daemon is starting, running or stopping there. Read from
/// /proc/locks, so the check never takes the lock itself. False when it
/// can't tell.
pub fn lockHeld(a: std.mem.Allocator, socket: []const u8) bool {
    const path = @import("xdg").lockPath(a, socket) catch return false;
    defer a.free(path);
    var st: std.os.linux.Statx = undefined;
    if (c.statx(c.AT.FDCWD, path, 0, .{ .INO = true }, &st) < 0) return false;
    const fd = c.open("/proc/locks", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var buf: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return locksHold(buf[0..len], st.ino);
}

/// Whether a /proc/locks listing has a FLOCK on inode `ino`. A line reads
/// `1: FLOCK  ADVISORY  WRITE 1234 00:1a:5678 0 EOF`; the device:inode
/// field is the sixth.
pub fn locksHold(listing: []const u8, ino: u64) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        var i: usize = 0;
        var flock = false;
        while (fields.next()) |f| : (i += 1) {
            // A blocked waiter's line has `->` after the number.
            if (std.mem.eql(u8, f, "->")) return false;
            if (i == 1) flock = std.mem.eql(u8, f, "FLOCK");
            if (i == 5) {
                if (!flock) break;
                const colon = std.mem.lastIndexOfScalar(u8, f, ':') orelse break;
                const got = std.fmt.parseInt(u64, f[colon + 1 ..], 10) catch break;
                if (got == ino) return true;
                break;
            }
        }
    }
    return false;
}

/// Starts `serve --lifetime on-demand --origin interactive` for the TUI and
/// watches the candidate through its diagnostics pipe. The daemon is not
/// this process's child: a double fork leaves it with no parent in the TUI's
/// chain, in its own session, so neither the TUI's exit nor a SIGHUP to its
/// terminal reaches it.
pub const Launcher = struct {
    gpa: std.mem.Allocator,
    /// Read end of the candidate's stdout: serve's single termination record
    /// (`{}` or the error wrapper). Its stdin and stderr are the null device.
    record: c.fd_t = -1,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    launched: bool = false,
    outcome: enum { running, lost_race, failed, exited } = .running,
    /// The candidate's error code, once it failed.
    failure: []const u8 = "",

    pub fn deinit(self: *Launcher) void {
        if (self.record >= 0) _ = c.close(self.record);
        self.record = -1;
    }

    /// The child's environment: the caller's, minus every credential and
    /// managed-context variable. The socket goes only on the command line.
    pub fn childEnv(a: std.mem.Allocator, environ: std.process.Environ) ![:null]?[*:0]const u8 {
        var envs: std.ArrayList(?[*:0]const u8) = .empty;
        for (environ.block.view().slice) |entry| {
            const bytes = std.mem.span(entry);
            const key = bytes[0 .. std.mem.indexOfScalar(u8, bytes, '=') orelse continue];
            if (dropped(key)) continue;
            try envs.append(a, entry);
        }
        const envp = try a.allocSentinel(?[*:0]const u8, envs.items.len, null);
        @memcpy(envp, envs.items);
        return envp;
    }
    fn dropped(key: []const u8) bool {
        if (std.mem.endsWith(u8, key, "_TOKEN")) return true;
        for ([_][]const u8{ "VENOM_PRINCIPAL", "VENOM_AGENT", "VENOM_SOCKET", "VENOMX_PRINCIPAL", "VENOMX_PANE" }) |name| if (std.mem.eql(u8, key, name)) return true;
        return false;
    }

    /// `$HOME` when it is an absolute directory, else `/`.
    pub fn workDir(a: std.mem.Allocator, environ: std.process.Environ) ![:0]const u8 {
        const home = environ.getPosix("HOME") orelse return "/";
        if (!std.fs.path.isAbsolute(home)) return "/";
        const z = try a.dupeSentinel(u8, home, 0);
        const st = proto.os.statAt(c.AT.FDCWD, z, 0) catch return "/";
        if (st.mode & c.S.IFMT != c.S.IFDIR) return "/";
        return z;
    }

    /// Forks the candidate on the absolute `socket`. Every allocation comes
    /// before the fork; the child execs this very binary, never a PATH lookup
    /// or a shell.
    pub fn launch(self: *Launcher, a: std.mem.Allocator, socket: []const u8, environ: std.process.Environ) !void {
        const sock_arg = try std.fmt.allocPrintSentinel(a, "--socket={s}", .{socket}, 0);
        const argv = [_:null]?[*:0]const u8{ "venom", "serve", "--lifetime=on-demand", "--origin=interactive", sock_arg.ptr, "--json" };
        const envp = try childEnv(a, environ);
        const cwd = try workDir(a, environ);
        var fds: [2]c.fd_t = undefined;
        if (c.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) return error.StartupFailed;
        errdefer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (devnull < 0) return error.StartupFailed;
        defer _ = c.close(devnull);
        const pid = c.fork();
        if (pid < 0) return error.StartupFailed;
        if (pid == 0) {
            // The intermediate: a new session, then the daemon, then exit at
            // once so the daemon is reparented away from the TUI.
            _ = c.setsid();
            const daemon = c.fork();
            if (daemon != 0) c._exit(if (daemon < 0) 127 else 0);
            if (c.dup2(devnull, 0) < 0 or c.dup2(fds[1], 1) < 0 or c.dup2(devnull, 2) < 0) c._exit(127);
            // The record pipe is blocking for the daemon's single final write.
            _ = c.fcntl(1, c.F.SETFL, @as(c_int, 0));
            if (c.chdir(cwd) != 0) _ = c.chdir("/");
            _ = execve("/proc/self/exe", &argv, envp.ptr);
            c._exit(127);
        }
        var status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0 and c.errno(-1) == .INTR) {}
        self.record = fds[0];
        self.launched = true;
        const s: u32 = @bitCast(status);
        if (!c.W.IFEXITED(s) or c.W.EXITSTATUS(s) != 0) {
            self.outcome = .failed;
            return error.StartupFailed;
        }
    }

    /// Reads what the candidate wrote. True once it has failed: a candidate
    /// that lost the race to another daemon is not a failure, its winner is
    /// used.
    pub fn failed(self: *Launcher) bool {
        if (self.outcome == .failed) return true;
        if (self.outcome != .running or self.record < 0) return false;
        const eof = self.drain();
        if (!eof) return false;
        const record = self.buf[0..self.len];
        if (std.mem.indexOf(u8, record, "\"conflict.already_running\"") != null) {
            self.outcome = .lost_race;
            return false;
        }
        if (std.mem.startsWith(u8, std.mem.trim(u8, record, " \n"), "{}")) {
            self.outcome = .exited;
            return false;
        }
        self.outcome = .failed;
        self.failure = codeOf(record);
        return true;
    }

    /// Drains the pipe; true at end of file (the candidate has exited).
    fn drain(self: *Launcher) bool {
        while (true) {
            var scratch: [512]u8 = undefined;
            const n = c.read(self.record, &scratch, scratch.len);
            if (n == 0) return true;
            if (n < 0) return false;
            const take = @min(@as(usize, @intCast(n)), self.buf.len - self.len);
            @memcpy(self.buf[self.len..][0..take], scratch[0..take]);
            self.len += take;
        }
    }

    /// The candidate's error code, bounded, and only a known one: never its
    /// environment or a credential.
    fn codeOf(record: []const u8) []const u8 {
        const key = "\"code\":\"";
        const at = std.mem.indexOf(u8, record, key) orelse return "no termination record";
        const rest = record[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "no termination record";
        const code = rest[0..end];
        if (code.len > 64 or !proto.errors.knownCode(code)) return "unknown error";
        return code;
    }
};
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

test "lifecycle: on-demand phases follow commit order" {
    const t = std.testing;
    var s: State = .{ .lifetime = .on_demand, .origin = .interactive };
    s.ready(1000);
    try t.expectEqual(Phase.awaiting_first_client, s.phase);
    try t.expectEqual(@as(i64, 5000), s.remainingMs(1000));
    s.tick(5999);
    try t.expect(!s.stopping());
    s.held();
    try t.expectEqual(Phase.active, s.phase);
    s.tick(100_000);
    try t.expectEqual(Phase.active, s.phase);
    s.released(1, 100_000);
    try t.expectEqual(Phase.active, s.phase);
    s.released(0, 100_000);
    try t.expectEqual(Phase.lingering, s.phase);
    try t.expectEqualStrings("lingering", s.phaseName());
    s.tick(104_999);
    try t.expectEqual(Phase.lingering, s.phase);
    // A hold within the linger keeps the daemon.
    s.held();
    try t.expectEqual(Phase.active, s.phase);
    s.released(0, 110_000);
    s.tick(115_000);
    try t.expect(s.stopping());
    // Stopping is irreversible.
    s.held();
    try t.expect(s.stopping());
}
test "lifecycle: the first-client grace stops a daemon nobody held" {
    var s: State = .{ .lifetime = .on_demand };
    s.ready(0);
    s.tick(wait_ms - 1);
    try std.testing.expect(!s.stopping());
    s.tick(wait_ms);
    try std.testing.expect(s.stopping());
    try std.testing.expect(s.consistent(0, wait_ms));
}
test "lifecycle: persistent never stops on holds" {
    var s: State = .{};
    s.ready(0);
    s.held();
    s.released(0, 0);
    s.tick(1_000_000);
    try std.testing.expectEqual(Phase.active, s.phase);
    try std.testing.expect(s.consistent(0, 0));
    s.stop();
    try std.testing.expect(s.stopping());
}
test "lifecycle: doctor finds an inconsistent state" {
    var s: State = .{ .lifetime = .on_demand };
    s.ready(0);
    s.held();
    try std.testing.expect(!s.consistent(0, 0));
    try std.testing.expect(s.consistent(1, 0));
    s.released(0, 0);
    try std.testing.expect(!s.consistent(0, 10_000));
}
test "lifecycle: settings validation" {
    try (Settings{}).check();
    try (Settings{ .startup_timeout_ms = 100 }).check();
    try (Settings{ .startup_timeout_ms = 60_000 }).check();
    try std.testing.expectError(error.Invalid, (Settings{ .startup_timeout_ms = 99 }).check());
    try std.testing.expectError(error.Invalid, (Settings{ .startup_timeout_ms = 60_001 }).check());
    try std.testing.expectEqual(Origin.interactive, Origin.parse("interactive"));
    try std.testing.expectEqual(Origin.serve, Origin.parse("bogus"));
    try std.testing.expectEqual(Lifetime.on_demand, Lifetime.parse("on-demand"));
}
test "lifecycle: /proc/locks lines" {
    const listing =
        \\1: POSIX  ADVISORY  WRITE 99 00:1a:77 0 EOF
        \\2: FLOCK  ADVISORY  WRITE 1234 00:1a:5678 0 EOF
        \\2: -> FLOCK  ADVISORY  WRITE 1240 00:1a:9999 0 EOF
        \\
    ;
    try std.testing.expect(locksHold(listing, 5678));
    try std.testing.expect(!locksHold(listing, 77));
    try std.testing.expect(!locksHold(listing, 9999));
}
test "lifecycle: the child environment drops credentials and markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = [_:null]?[*:0]const u8{ "HOME=/home/u", "VENOM_TOKEN=x", "VENOMX_TOKEN=y", "GH_TOKEN=z", "VENOM_AGENT=a1", "VENOMX_PANE=p1", "VENOM_SOCKET=/s", "VENOMX_SOCKET=/vx", "XDG_STATE_HOME=/st", "VENOM_PRINCIPAL=", "VENOMX_PRINCIPAL=p" };
    const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
    const env = try Launcher.childEnv(a, environ);
    var kept: std.ArrayList([]const u8) = .empty;
    for (env) |e| try kept.append(a, std.mem.span(e.?));
    try std.testing.expectEqual(@as(usize, 3), kept.items.len);
    try std.testing.expectEqualStrings("HOME=/home/u", kept.items[0]);
    try std.testing.expectEqualStrings("VENOMX_SOCKET=/vx", kept.items[1]);
    try std.testing.expectEqualStrings("XDG_STATE_HOME=/st", kept.items[2]);
    try std.testing.expectEqualStrings("VENOM_PRINCIPAL", contextMarker(environ).?);
}
test "lifecycle: a missing marker directory holds no marker and is not created" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/venom", .{tmp.sub_path}, 0);
    defer a.free(missing);
    const socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{missing});
    defer a.free(socket);
    try std.testing.expectEqual(@as(?[]const u8, null), try managerMarker(a, socket));
    try std.testing.expectError(error.FileNotFound, proto.os.statAt(c.AT.FDCWD, missing, 0));
}
