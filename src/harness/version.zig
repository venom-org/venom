//! The harness's own version:
//! `<exe> --version`. Read-only: it starts no model turn.
//!
//! It never runs on the reactor thread: a `Detector` runs it once on a
//! short-lived thread of its own (started when the daemon registers the
//! adapter), and `probe` reports whatever it found so far, null until it
//! lands, without waiting. `doctor` asks afresh (`discovery.zig`).
//!
//! The command runs as a harness process (`process.zig`: its own process
//! group, no stdin, the test guard) and is given `timeout_ms` to
//! print its version; it is killed after that. Output is parsed tolerantly:
//! the first word that starts with a digit and has a dot (`2.1.319
//! (Claude Code)`, `codex-cli 0.167.0`).
//!
//! The outcome tells a harness that is not installed (`missing`: the exec
//! failed, exit 127 before any output) from one that runs but prints no
//! version or does not finish in time (`unreadable`).
const std = @import("std");
const builtin = @import("builtin");
const supervisor = @import("supervisor");
const guard = @import("guard.zig");
const process = @import("process.zig");
const Process = process.Process;
const c = std.c;

pub const default_timeout_ms: u32 = 5_000;

/// What `<exe> --version` gave.
pub const Detection = union(enum) {
    /// The version it printed.
    found: []const u8,
    /// Not installed: it could not be executed (not on `PATH`, not
    /// executable), or a test build refused a real vendor CLI.
    missing,
    /// It ran but printed no version, or did not finish in time.
    unreadable,
};

/// Runs `detect` once on its own thread. Must not move once started.
pub const Detector = struct {
    gpa: std.mem.Allocator,
    /// Borrowed: must outlive the detector.
    exe: []const u8,
    timeout_ms: u32 = default_timeout_ms,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Set by `deinit`: a hung `--version` is killed at once.
    cancel: std.atomic.Value(bool) = .init(false),
    buf: [64]u8 = undefined,
    len: usize = 0,
    /// Valid once `done`.
    outcome: std.meta.Tag(Detection) = .unreadable,

    /// Starts the thread; if it cannot start, the version stays unknown.
    pub fn start(self: *Detector) void {
        if (self.thread != null or self.done.load(.acquire)) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.done.store(true, .release);
            return;
        };
    }

    /// The version, once found; null while detecting or if none. Never blocks.
    pub fn get(self: *const Detector) ?[]const u8 {
        if (!self.done.load(.acquire) or self.len == 0) return null;
        return self.buf[0..self.len];
    }

    /// Waits for the thread (at most about `timeout_ms`), then `get`.
    pub fn wait(self: *Detector) ?[]const u8 {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        return self.get();
    }

    /// Waits like `wait`, and says why there is no version, if there is none.
    pub fn waitResult(self: *Detector) Detection {
        if (self.wait()) |v| return .{ .found = v };
        return if (self.outcome == .missing) .missing else .unreadable;
    }

    pub fn deinit(self: *Detector) void {
        self.cancel.store(true, .release);
        _ = self.wait();
    }

    fn run(self: *Detector) void {
        var mem: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&mem);
        const got = detectCancellable(self.gpa, fba.allocator(), self.exe, self.timeout_ms, &self.cancel) catch Detection.unreadable;
        self.outcome = std.meta.activeTag(got);
        if (got == .found) {
            const n = @min(got.found.len, self.buf.len);
            @memcpy(self.buf[0..n], got.found[0..n]);
            self.len = n;
        }
        self.done.store(true, .release);
    }
};

/// Runs `exe --version` and returns the version it printed (in `out`), or
/// null when it cannot be run, prints none, or does not finish in time.
/// In a test build a vendor CLI outside the test roots is never run.
pub fn detect(gpa: std.mem.Allocator, out: std.mem.Allocator, exe: []const u8, timeout_ms: u32) !?[]const u8 {
    const got = try detectCancellable(gpa, out, exe, timeout_ms, null);
    return if (got == .found) got.found else null;
}

/// `detect` that also gives up (within ~100 ms) once `cancel` is set.
pub fn detectCancellable(gpa: std.mem.Allocator, out: std.mem.Allocator, exe: []const u8, timeout_ms: u32, cancel: ?*const std.atomic.Value(bool)) !Detection {
    if (builtin.is_test and !guard.spawnAllowed(exe, guard.optedIn)) return .missing;
    var leaders: supervisor.Leaders = .init(gpa, .{});
    // Kills the group if it is still alive (a hung `--version`).
    defer leaders.deinit();
    var p = Process.spawn(gpa, &leaders, .{ .argv = &.{ exe, "--version" } }) catch return .unreadable;
    defer p.deinit();
    p.closeInput();
    const deadline = supervisor.monotonicMs() + timeout_ms;
    var found: ?[]const u8 = null;
    while (found == null) {
        const open = p.pump() catch break;
        while (p.nextLine()) |line| if (parse(line)) |v| {
            found = try out.dupe(u8, v);
            break;
        };
        if (!open) break;
        if (cancel) |flag| if (flag.load(.acquire)) break;
        const left = deadline - supervisor.monotonicMs();
        if (left <= 0) break;
        var fds = [_]c.pollfd{
            .{ .fd = p.stdout, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = p.stderr, .events = c.POLL.IN, .revents = 0 },
        };
        _ = c.poll(&fds, fds.len, @intCast(@min(left, 100)));
    }
    try stop(&p, &leaders);
    if (found) |v| return .{ .found = v };
    // Exit 127 is a failed exec (`process.zig`): the harness is not there.
    const st = p.leader.status orelse return .unreadable;
    const exit = process.exitOf(st);
    return if (exit == .code and exit.code == 127) .missing else .unreadable;
}

/// Ends a short-lived harness command and anything it left in its group, then
/// reaps it, so no zombie is left behind. The kill comes first: until the
/// leader is reaped its pid is pinned, so the group is still this command's,
/// even when the leader itself has exited.
pub fn stop(p: *Process, leaders: *supervisor.Leaders) !void {
    if (p.leader.phase != .exited) _ = c.kill(-p.leader.pid, .KILL);
    _ = leaders.terminate(p.leader, .{ .deadline = leaders.now() }) catch {};
    const reap_deadline = supervisor.monotonicMs() + supervisor.leaders.kill_wait_ms;
    while (p.leader.phase != .exited and supervisor.monotonicMs() < reap_deadline) {
        try leaders.tick();
        if (p.leader.phase == .exited) break;
        var fds = [_]c.pollfd{.{ .fd = p.leader.pollFd() orelse -1, .events = c.POLL.IN, .revents = 0 }};
        _ = c.poll(&fds, 1, 20);
    }
}

/// The first word of `line` that looks like a version: it starts with a
/// digit and has a dot. A leading `v` is dropped.
pub fn parse(line: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, line, " \t()/,");
    while (words.next()) |w0| {
        const w = if (w0.len > 1 and (w0[0] == 'v' or w0[0] == 'V')) w0[1..] else w0;
        if (w.len > 0 and std.ascii.isDigit(w[0]) and std.mem.indexOfScalar(u8, w, '.') != null) return w;
    }
    return null;
}

/// Compares dotted versions numerically (`2.1.40 < 2.1.319`); a missing
/// part is 0 and a part's non-digit suffix (`1-beta`) is ignored.
pub fn order(a: []const u8, b: []const u8) std.math.Order {
    var x = std.mem.splitScalar(u8, a, '.');
    var y = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null and q == null) return .eq;
        const o = std.math.order(number(p orelse "0"), number(q orelse "0"));
        if (o != .eq) return o;
    }
}

fn number(part: []const u8) u64 {
    var end: usize = 0;
    while (end < part.len and std.ascii.isDigit(part[end])) end += 1;
    return std.fmt.parseInt(u64, part[0..end], 10) catch 0;
}

const testing = std.testing;

test "version: parse and order" {
    try testing.expectEqualStrings("2.1.319", parse("2.1.319 (Claude Code)").?);
    try testing.expectEqualStrings("0.167.0", parse("codex-cli 0.167.0").?);
    try testing.expectEqualStrings("1.2.3", parse("tool v1.2.3").?);
    try testing.expect(parse("no version here") == null);
    try testing.expect(parse("") == null);
    try testing.expectEqual(std.math.Order.lt, order("2.1.40", "2.1.319"));
    try testing.expectEqual(std.math.Order.eq, order("2.1", "2.1.0"));
    try testing.expectEqual(std.math.Order.gt, order("0.168.0", "0.167.9"));
    try testing.expectEqual(std.math.Order.lt, order("1.0.0-beta", "1.0.1"));
}

test "version: detect runs <exe> --version, and never a real vendor CLI in a test" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "claude", .data = "#!/bin/sh\necho '2.1.400 (Claude Code)'\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hang", .data = "#!/bin/sh\nexec sleep 30\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mute", .data = "#!/bin/sh\nexit 0\n" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "claude", "hang", "mute" }) |name| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        if (c.chmod(path, 0o755) != 0) return error.ChmodFailed;
    }
    try testing.expectEqualStrings("2.1.400", (try detect(testing.allocator, a, try std.fmt.allocPrint(a, "{s}/claude", .{dir}), 5_000)).?);
    try testing.expect((try detect(testing.allocator, a, try std.fmt.allocPrint(a, "{s}/mute", .{dir}), 5_000)) == null);
    try testing.expect((try detect(testing.allocator, a, try std.fmt.allocPrint(a, "{s}/missing", .{dir}), 5_000)) == null);
    // Not installed and installed-but-unreadable are told apart.
    try testing.expect((try detectCancellable(testing.allocator, a, try std.fmt.allocPrint(a, "{s}/missing", .{dir}), 5_000, null)) == .missing);
    try testing.expect((try detectCancellable(testing.allocator, a, "venom-no-such-harness", 5_000, null)) == .missing);
    try testing.expect((try detectCancellable(testing.allocator, a, try std.fmt.allocPrint(a, "{s}/mute", .{dir}), 5_000, null)) == .unreadable);
    const t0 = supervisor.monotonicMs();
    try testing.expect((try detect(testing.allocator, a, try std.fmt.allocPrint(a, "{s}/hang", .{dir}), 200)) == null);
    try testing.expect(supervisor.monotonicMs() - t0 < 5_000);
    // The real CLIs on PATH are refused silently.
    if (!guard.optedIn(guard.claude)) try testing.expect((try detect(testing.allocator, a, "claude", 1_000)) == null);

    // A Detector never blocks its caller, even while `--version` hangs.
    var hang: Detector = .{ .gpa = testing.allocator, .exe = try std.fmt.allocPrint(a, "{s}/hang", .{dir}), .timeout_ms = 300 };
    const t1 = supervisor.monotonicMs();
    hang.start();
    try testing.expect(hang.get() == null);
    try testing.expect(supervisor.monotonicMs() - t1 < 100);
    try testing.expect(hang.wait() == null);
    try testing.expect(hang.waitResult() == .unreadable);
    hang.deinit();
    // deinit does not wait out the timeout.
    var slow: Detector = .{ .gpa = testing.allocator, .exe = hang.exe, .timeout_ms = 30_000 };
    slow.start();
    const t2 = supervisor.monotonicMs();
    slow.deinit();
    try testing.expect(supervisor.monotonicMs() - t2 < 2_000);
    var ok: Detector = .{ .gpa = testing.allocator, .exe = try std.fmt.allocPrint(a, "{s}/claude", .{dir}) };
    ok.start();
    defer ok.deinit();
    try testing.expectEqualStrings("2.1.400", ok.wait().?);
    try testing.expectEqualStrings("2.1.400", ok.get().?);
}
