//! Escalation: against a real venomx daemon, with the decider's
//! clock injected, a blocking item left unanswered past `notify_after` shows
//! pane attention and one notification, and `inbox.answer` clears them.
//!
//! `zig build test-host` runs this with `VENOM_TEST_VENOMX` set; `zig build
//! test` has no venomx and skips it. The real serve loop and the real `Host`
//! drive a real venomx here, but this test's `Host` is on an owner connection:
//! `scripts/host_demo.py` is what runs them with a control pane's own rights.
const std = @import("std");
const proto = @import("proto");
const supervisor = @import("supervisor");
const eventlog = @import("eventlog/root.zig");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const Escalation = @import("escalation.zig").Escalation;
const host_mod = @import("tui/host.zig");
const App = @import("tui/app.zig").App;
const harnesses = @import("harnesses.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const script =
    \\{"turns":[{"match":"","steps":[{"ask":{"id":"p1","kind":"approval","reason":"Run zig build?"}},{"text":"built"}]}]}
;

const hello: proto.HelloOptions = .{ .identity = .{ .name = "venom-test", .version = "0.0.0" }, .caps = &.{} };

/// Real time plus what the test has moved it by.
const TestClock = struct {
    offset_ms: std.atomic.Value(i64) = .init(0),

    fn now(ptr: ?*anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ptr.?));
        return (eventlog.engine.Clock{}).now() + self.offset_ms.load(.acquire);
    }
    fn clock(self: *TestClock) eventlog.engine.Clock {
        return .{ .ptr = self, .nowFn = now };
    }
};

fn sleepMs(ms: u64) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = c.nanosleep(&ts, null);
}

/// A venomx daemon of its own, in a runtime directory short enough for a
/// unix socket path.
const Venomx = struct {
    pid: c.pid_t,
    root: [:0]const u8,
    environ: std.process.Environ,

    fn start(a: std.mem.Allocator, exe: []const u8) !Venomx {
        const root = try std.fmt.allocPrintSentinel(a, "/tmp/vxe{d}", .{c.getpid()}, 0);
        if (c.mkdir(root, 0o700) != 0) return error.MkdirFailed;
        const entries = [_][:0]const u8{
            try std.fmt.allocPrintSentinel(a, "XDG_RUNTIME_DIR={s}", .{root}, 0),
            try std.fmt.allocPrintSentinel(a, "XDG_STATE_HOME={s}/state", .{root}, 0),
            try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{root}, 0),
            try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0),
            "PATH=/usr/bin:/bin",
        };
        const envp = try a.allocSentinel(?[*:0]const u8, entries.len, null);
        for (entries, 0..) |e, i| envp[i] = e;
        const path = try a.dupeSentinel(u8, exe, 0);
        const argv = [_:null]?[*:0]const u8{ path, "serve" };
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Not this test's pipes: its panes would keep them open, and the
            // build runner waits for them.
            const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR });
            for ([_]c.fd_t{ 0, 1, 2 }) |fd| _ = c.dup2(null_fd, fd);
            _ = c.execve(path, &argv, envp);
            c._exit(127);
        }
        return .{ .pid = pid, .root = root, .environ = .{ .block = .{ .slice = envp } } };
    }

    fn stop(self: *Venomx, a: std.mem.Allocator) void {
        _ = c.kill(self.pid, .TERM);
        var status: c_int = 0;
        var waited = false;
        for (0..200) |_| {
            if (c.waitpid(self.pid, &status, c.W.NOHANG) != 0) {
                waited = true;
                break;
            }
            sleepMs(25);
        }
        if (!waited) {
            _ = c.kill(self.pid, .KILL);
            _ = c.waitpid(self.pid, &status, 0);
        }
        var argv = [_:null]?[*:0]const u8{ "rm", "-rf", self.root };
        _ = a;
        const rm = c.fork();
        if (rm == 0) {
            _ = c.execve("/bin/rm", &argv, @ptrCast(&[_:null]?[*:0]const u8{}));
            c._exit(127);
        }
        if (rm > 0) _ = c.waitpid(rm, &status, 0);
    }

    /// An owner connection, as a process outside venomx may have.
    fn owner(self: *Venomx, a: std.mem.Allocator) !proto.Client {
        const env = try host_mod.ownerEnviron(a, self.environ, "VENOMX_TOKEN");
        const deadline = std.time.ms_per_s * 15;
        var waited: u64 = 0;
        while (true) : (waited += 50) {
            if (proto.Client.init(ta, .{ .tool = "venomx", .path = .{ .environ = env }, .hello = hello })) |client_value| {
                var client = client_value;
                errdefer client.deinit();
                var turns: usize = 0;
                while (!try client.pollHello(100)) {
                    turns += 1;
                    if (turns > 100) return error.Timeout;
                }
                return client;
            } else |err| {
                if (waited > deadline) return err;
            }
            sleepMs(50);
        }
    }
};

var next_call: i64 = 1000;

fn call(a: std.mem.Allocator, client: *proto.Client, verb: []const u8, params: anytype) !Value {
    const id = next_call;
    next_call += 1;
    try client.request(id, verb, params);
    var turns: usize = 0;
    while (turns < 100) : (turns += 1) {
        const msg = try client.receive(100) orelse continue;
        if (msg != .ndjson) return error.InvalidResponse;
        const r = try proto.Response.parse(a, msg.ndjson);
        const rid = r.id orelse continue;
        if (rid != .integer or rid.integer != id or !r.final()) continue;
        if (r.body == .@"error") std.debug.print("{s}: {s}\n", .{ verb, r.body.@"error".code });
        return if (r.body == .ok) r.body.ok else error.VerbFailed;
    }
    return error.Timeout;
}

const Tag = struct { key: []const u8, value: []const u8 };

test "escalation against a real venomx: pane attention, one notification past notify_after, all cleared after inbox.answer" {
    const exe = std.mem.span(c.getenv("VENOM_TEST_VENOMX") orelse return error.SkipZigTest);
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    var vx = try Venomx.start(a, exe);
    defer vx.stop(a);
    var owner = try vx.owner(a);
    defer owner.deinit();

    var test_clock: TestClock = .{};
    var escalation: Escalation = undefined;
    try escalation.init(ta, vx.environ, null);
    defer escalation.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script, .clock = test_clock.clock(), .escalation = &escalation, .config = harnesses.testConfig("") });
    defer d.deinit();

    const spawned = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=approve", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), spawned.status);
    const agent = spawned.json.object.get("agent").?.string;
    _ = try d.waitState(a, agent, "needs_you");

    // A control pane and that agent's pane.
    const session = (try call(a, &owner, "session.create", .{ .name = "venom", .on_empty = "remove" })).object.get("session").?.string;
    const control = (try call(a, &owner, "window.create", .{
        .session = session,
        .name = "venom",
        .argv = &[_][]const u8{ "/bin/sleep", "120" },
        .cols = 100,
        .rows = 30,
        .tags = &[_]Tag{.{ .key = "role", .value = "control" }},
    })).object.get("pane").?.string;
    const pane = (try call(a, &owner, "pane.split", .{
        .pane = control,
        .axis = "cols",
        .argv = &[_][]const u8{ "/bin/sleep", "120" },
        .tags = &[_]Tag{ .{ .key = "role", .value = "agent" }, .{ .key = "group", .value = agent } },
    })).object.get("pane").?.string;

    var app = App.init(ta);
    defer app.deinit();
    var host = try host_mod.Host.init(ta, .{ .control = control, .exe = "/bin/false", .socket = d.socket });
    defer host.deinit();
    host.client = try vx.owner(a);
    app.host = &host;
    try host.begin();

    const Look = struct {
        fn attention(x: std.mem.Allocator, o: *proto.Client, id: []const u8) ![]const u8 {
            const listed = try call(x, o, "pane.list", struct {}{});
            for (listed.object.get("panes").?.array.items) |p| {
                if (std.mem.eql(u8, p.object.get("pane").?.string, id)) return p.object.get("attention").?.string;
            }
            return error.NoSuchPane;
        }
        fn notifications(x: std.mem.Allocator, o: *proto.Client) ![]Value {
            return (try call(x, o, "notify.list", struct {}{})).object.get("notifications").?.array.items;
        }
    };
    const Drive = struct {
        d: *Daemon,
        app: *App,
        host: *host_mod.Host,
        /// One TUI turn: the inbox as `venom inbox list` has it, then venomx.
        fn turn(self: @This(), x: std.mem.Allocator) !void {
            const listed = try self.d.run(x, &.{ "inbox", "list" });
            try testing.expectEqual(@as(u8, 0), listed.status);
            try self.app.inbox.apply(listed.json);
            try testing.expect(try self.host.pump(self.app));
            sleepMs(20);
        }
    };
    const drive: Drive = .{ .d = &d, .app = &app, .host = &host };

    // Unanswered, and not yet for long: attention at once, no notification.
    const attention_by = supervisor.monotonicMs() + 15_000;
    while (!std.mem.eql(u8, try Look.attention(a, &owner, pane), "urgent")) {
        if (supervisor.monotonicMs() > attention_by) return error.NoAttention;
        try drive.turn(a);
    }
    test_clock.offset_ms.store(119 * std.time.ms_per_s, .release);
    for (0..10) |_| try drive.turn(a);
    try testing.expectEqual(@as(usize, 0), (try Look.notifications(a, &owner)).len);

    // Past notify_after (2m, the default): one notification, and it stays one.
    test_clock.offset_ms.store(121 * std.time.ms_per_s, .release);
    const posted_by = supervisor.monotonicMs() + 15_000;
    while ((try Look.notifications(a, &owner)).len == 0) {
        if (supervisor.monotonicMs() > posted_by) return error.NoNotification;
        try drive.turn(a);
    }
    for (0..15) |_| try drive.turn(a);
    const posted = try Look.notifications(a, &owner);
    try testing.expectEqual(@as(usize, 1), posted.len);
    try testing.expectEqualStrings("urgent", posted[0].object.get("level").?.string);
    try testing.expectEqualStrings("venom", posted[0].object.get("namespace").?.string);
    try testing.expect(std.mem.indexOf(u8, posted[0].object.get("text").?.string, "Run zig build?") != null);
    try testing.expectEqualStrings("urgent", try Look.attention(a, &owner, pane));

    // Answered: the notification and the urgent mark go.
    const answered = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{agent}), "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), answered.status);
    const cleared_by = supervisor.monotonicMs() + 15_000;
    while ((try Look.notifications(a, &owner)).len != 0 or std.mem.eql(u8, try Look.attention(a, &owner, pane), "urgent")) {
        if (supervisor.monotonicMs() > cleared_by) return error.NotCleared;
        try drive.turn(a);
    }
    // The settled agent's unread review is `info`, not
    // blocking: archiving it leaves nothing at all on the pane.
    _ = try d.waitState(a, agent, "settled");
    const archived = try d.run(a, &.{ "agent", "archive", try std.fmt.allocPrint(a, "--agent={s}", .{agent}) });
    try testing.expectEqual(@as(u8, 0), archived.status);
    const none_by = supervisor.monotonicMs() + 15_000;
    while (!std.mem.eql(u8, try Look.attention(a, &owner, pane), "none")) {
        if (supervisor.monotonicMs() > none_by) return error.NotCleared;
        try drive.turn(a);
    }
    try testing.expectEqual(@as(usize, 0), (try Look.notifications(a, &owner)).len);
    try testing.expect(!escalation.wantsLink());
}
