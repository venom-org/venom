//! The fake harness driving real agents through the host and the durable
//! event log: every test starts real child processes
//! and ends with none left (`Host.deinit` terminates and reaps them; the
//! tests check the pids are gone). Leak-checked with `std.testing.allocator`.
const std = @import("std");
const build_options = @import("build_options");
const eventlog = @import("../eventlog/root.zig");
const harness = @import("root.zig");
const Host = harness.Host;
const Fake = harness.Fake;
const Engine = eventlog.Engine;
const AgentState = eventlog.agent.State;
const c = std.c;
const testing = std.testing;

const approval_script =
    \\{"turns":[{"match":"","steps":[
    \\  {"text":"I'll run the tests."},
    \\  {"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build test"}},
    \\  {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build test?","input":"zig build test"}},
    \\  {"tool_end":{"id":"tu1","status":"ok","exit":0,"ms":12}},
    \\  {"usage":{"in":10,"out":5,"cache_read":3}},
    \\  {"text":"All tests pass."}]}]}
;

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    log_path: [:0]u8,
    engine: Engine,
    exe: [std.fs.max_path_bytes:0]u8,
    fake: Fake,
    adapters: [1]harness.host.Registered,
    host: Host,
    pids: std.ArrayList(c.pid_t) = .empty,

    fn init(self: *Fixture, script: []const u8, options: harness.host.Options) !void {
        self.pids = .empty;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.dir);
        self.log_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/events.log", .{self.dir}, 0);
        errdefer testing.allocator.free(self.log_path);
        self.engine = try Engine.open(testing.allocator, self.log_path, .{});
        errdefer self.engine.deinit();
        // The build passes a path relative to the build root; harnesses run
        // in the agent's workspace.
        const rel = try testing.allocator.dupeSentinel(u8, build_options.fake_harness, 0);
        defer testing.allocator.free(rel);
        if (c.realpath(rel, &self.exe) == null) return error.FakeHarnessMissing;
        self.fake = .{ .exe = std.mem.sliceTo(&self.exe, 0), .script = script, .state_dir = self.dir };
        self.adapters = .{.{ .harness = harness.fake.name, .adapter = self.fake.adapter() }};
        self.host = Host.init(testing.allocator, &self.engine, &self.adapters, options);
        self.engine.options.executors = self.host.executor();
        try self.engine.start();
        _ = try self.engine.submit(.{ .create = .{ .agent = "a1", .title = "Run the tests", .harness = harness.fake.name, .workspace = self.dir } });
    }

    /// Shuts the host down and checks every harness process it started is
    /// gone, then frees everything.
    fn deinit(self: *Fixture) void {
        self.host.deinit();
        for (self.pids.items) |pid| {
            // Reaped and gone: not even a zombie of ours is left.
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("a harness process outlived the host");
        }
        self.pids.deinit(testing.allocator);
        self.engine.deinit();
        testing.allocator.free(self.log_path);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn agent(self: *Fixture) eventlog.decider.Agent {
        return self.engine.state.agents.get("a1").?;
    }
    fn binding(self: *Fixture) *harness.host.Binding {
        return self.host.binding("a1").?;
    }

    /// Runs reactor turns (and the effect worker) until `done` or 10 s.
    fn until(self: *Fixture, comptime done: fn (*Fixture) bool) !void {
        const deadline = std.time.ms_per_s * 10 + now();
        while (!done(self)) {
            if (now() > deadline) return error.Timeout;
            try self.host.poll(5);
            _ = try self.engine.runEffects();
            self.notePid();
        }
    }

    fn notePid(self: *Fixture) void {
        const b = self.host.binding("a1") orelse return;
        const p = b.process orelse return;
        for (self.pids.items) |pid| if (pid == p.pid()) return;
        self.pids.append(testing.allocator, p.pid()) catch @panic("oom");
    }

    /// `from>to` of every `agent.state_changed` in the durable log.
    fn transitions(self: *Fixture, a: std.mem.Allocator) ![]const []const u8 {
        return self.records(a, "agent.state_changed");
    }

    /// The `type`s (or, for `kind`, the `from>to` pairs) of the log.
    fn records(self: *Fixture, a: std.mem.Allocator, only: ?[]const u8) ![]const []const u8 {
        const bytes = try readFile(a, self.log_path);
        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
            for (v.object.get("events").?.array.items) |e| {
                const t = e.object.get("type").?.string;
                if (only) |o| {
                    if (!std.mem.eql(u8, t, o)) continue;
                    const d = e.object.get("data").?.object;
                    try out.append(a, try std.fmt.allocPrint(a, "{s}>{s}", .{ d.get("from").?.string, d.get("to").?.string }));
                } else try out.append(a, t);
            }
        }
        return out.items;
    }
};

fn now() i64 {
    return @import("supervisor").monotonicMs();
}

fn readFile(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(a, buf[0..@intCast(n)]);
    }
    return list.items;
}

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} items, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn isState(comptime s: AgentState) fn (*Fixture) bool {
    return struct {
        fn f(fx: *Fixture) bool {
            return fx.agent().state == s;
        }
    }.f;
}

fn harnessUp(fx: *Fixture) bool {
    const b = fx.host.binding("a1") orelse return false;
    return b.status == .running and b.got_session;
}

/// Keeps every restart delay the host schedules, however fast they pass.
const DelayRecorder = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(u32) = .empty,

    fn hook(self: *DelayRecorder) harness.host.OnBackoff {
        return .{ .ptr = self, .call = record };
    }
    fn record(ptr: *anyopaque, delay_ms: u32) void {
        const self: *DelayRecorder = @ptrCast(@alignCast(ptr));
        self.list.append(self.a, delay_ms) catch @panic("oom");
    }
};

test "fake harness: queued → running → needs_you → running → settled with the expected events" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{});
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(AgentState.queued, fx.agent().state);
    try fx.host.send("a1", "Run the tests", .turn);
    try fx.until(isState(.needs_you));
    const req = fx.agent().requests.items[0];
    try testing.expectEqualStrings("r1", req.request);
    try testing.expectEqualStrings("c1", req.call.?);
    try testing.expectEqualStrings("Run zig build test?", req.reason);
    try testing.expectEqualStrings("fake-a1", fx.agent().harness_session.?);
    // Only the answers the harness offers are accepted.
    try testing.expectError(error.InvalidCommand, fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "approve" } }));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(AgentState.running, fx.agent().state);
    try fx.until(isState(.settled));
    try testing.expect(fx.agent().unread);
    const effect = fx.engine.state.effects.get("respond:a1:r1").?;
    try testing.expect(effect.done and effect.ok);

    try expectStrings(&.{ "queued>running", "running>needs_you", "needs_you>running", "running>settled" }, try fx.transitions(a));
    var types: std.ArrayList([]const u8) = .empty;
    for (try fx.records(a, null)) |t| {
        if (std.mem.eql(u8, t, "agent.state_changed") or std.mem.startsWith(u8, t, "effect.") or std.mem.eql(u8, t, "daemon.started") or std.mem.eql(u8, t, "agent.created")) continue;
        try types.append(a, t);
    }
    try expectStrings(&.{ "agent.binding", "agent.binding", "turn.started", "turn.prompt", "text", "tool.started", "request", "request.resolved", "tool.ended", "usage", "text", "turn.ended" }, types.items);

    const transcript = fx.agent().transcript.items;
    const ended = transcript[transcript.len - 1].turn_ended;
    try testing.expectEqualStrings("t1", ended.turn);
    try testing.expectEqualStrings("completed", ended.reason);
    for (transcript) |e| switch (e) {
        .tool_ended => |t| {
            try testing.expectEqualStrings("c1", t.call);
            try testing.expectEqualStrings("Bash", t.name);
            try testing.expectEqual(@as(?i64, 0), t.exit);
            try testing.expectEqual(@as(?u64, 12), t.duration_ms);
        },
        .usage => |u| {
            try testing.expectEqual(@as(u64, 10), u.tokens_in);
            try testing.expectEqual(@as(u64, 3), u.cache_read);
        },
        else => {},
    };
    // The process stays up between turns, ready for the next prompt.
    try testing.expect(fx.binding().running());
}

test "fake harness: a crash fails the agent, the process restarts with backoff, retry runs it again" {
    const script =
        \\{"turns":[{"match":"crash","steps":[{"text":"working"},{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"make"}},{"crash":3}]},
        \\          {"match":"","steps":[{"text":"resumed"}]}],
        \\ "crash_on_resume":2}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var delays: DelayRecorder = .{ .a = a };
    var fx: Fixture = undefined;
    try fx.init(script, .{
        .policy = .{ .initial_ms = 20, .max_ms = 1_000, .reset_after_ms = 60_000, .max_failures = 5 },
        .on_backoff = delays.hook(),
    });
    defer fx.deinit();

    try fx.host.send("a1", "please crash", .turn);
    try fx.until(isState(.failed));
    const transcript = fx.agent().transcript.items;
    const ended = transcript[transcript.len - 1].turn_ended;
    try testing.expectEqualStrings("failed", ended.reason);
    try testing.expectEqualStrings("failed.harness_exited", ended.error_code.?);
    // The open call was closed before the turn ended.
    try testing.expectEqualStrings("interrupted", transcript[transcript.len - 2].tool_ended.status);
    try testing.expectEqual(@as(u8, 3), fx.binding().last_exit.?.code);

    // Restarts back off 20, 40, 80 ms: the first two resumes crash too.
    try fx.until(harnessUp);
    try testing.expectEqualSlices(u32, &.{ 20, 40, 80 }, delays.list.items);
    try testing.expectEqual(@as(u32, 3), fx.binding().restarts);
    // Restarting sends nothing: the agent stays failed until a retry.
    try testing.expectEqual(AgentState.failed, fx.agent().state);
    try testing.expectEqual(@as(u32, 1), fx.agent().turns);

    try fx.host.retry("a1");
    try fx.until(isState(.settled));
    try expectStrings(&.{ "queued>running", "running>failed", "failed>running", "running>settled" }, try fx.transitions(a));
    const t2 = fx.agent().transcript.items;
    var started: ?eventlog.events.TurnStarted = null;
    for (t2) |e| if (e == .turn_started) {
        started = e.turn_started;
    };
    try testing.expectEqualStrings("t2", started.?.turn);
    try testing.expectEqualStrings("resumed", t2[t2.len - 2].text.text);
    try testing.expectEqualStrings("m2", t2[t2.len - 2].text.message);
    try testing.expectError(error.InvalidTransition, fx.host.retry("a1"));
}

test "fake harness: too many failures give up until the next send; a missing binary gives up at once" {
    const script =
        \\{"turns":[{"match":"","steps":[{"crash":9}]}],"crash_on_resume":100}
    ;
    var fx: Fixture = undefined;
    try fx.init(script, .{ .policy = .{ .initial_ms = 1, .max_ms = 4, .max_failures = 2 } });
    defer fx.deinit();
    try fx.host.send("a1", "go", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            const b = x.host.binding("a1") orelse return false;
            return b.status == .gave_up;
        }
    }.f);
    try testing.expectEqual(AgentState.failed, fx.agent().state);
    try testing.expectEqual(@as(u32, 3), fx.binding().failures);
    try testing.expectEqual(@as(u32, 2), fx.binding().restarts);

    // A second agent whose harness binary does not exist.
    var missing: Fake = .{ .exe = "venom-no-such-fake-harness" };
    const adapters = [_]harness.host.Registered{.{ .harness = "missing", .adapter = missing.adapter() }};
    var host2 = Host.init(testing.allocator, &fx.engine, &adapters, .{});
    defer host2.deinit();
    _ = try fx.engine.submit(.{ .create = .{ .agent = "a2", .title = "t", .harness = "missing", .workspace = fx.dir } });
    try host2.send("a2", "hello", .turn);
    const deadline = now() + 10_000;
    while (host2.binding("a2").?.status != .gave_up) {
        if (now() > deadline) return error.Timeout;
        try host2.poll(5);
    }
    const a2 = fx.engine.state.agents.get("a2").?;
    try testing.expectEqual(AgentState.failed, a2.state);
    try testing.expectEqualStrings("unavailable.harness_not_found", a2.transcript.items[a2.transcript.items.len - 1].turn_ended.error_code.?);
    try testing.expectError(error.HarnessNotFound, host2.send("a1", "x", .turn));
}

test "fake harness: SIGINT interrupts a turn, a message sent mid-turn is queued, shutdown interrupts" {
    const script =
        \\{"turns":[{"match":"long","steps":[{"text":"thinking"},{"sleep_ms":20000}]},
        \\          {"match":"","steps":[{"text":"next"}]}]}
    ;
    var fx: Fixture = undefined;
    try fx.init(script, .{});
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "a long task", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().messages == 1;
        }
    }.f);
    // steer = queue: accepted mid-turn, it starts the next turn.
    try fx.host.send("a1", "then this", .turn);
    try testing.expectError(error.UnsupportedCapability, fx.host.send("a1", "steer", .steer));
    try fx.host.interrupt("a1");
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().state == .settled and x.agent().turns == 2;
        }
    }.f);
    var reasons: std.ArrayList([]const u8) = .empty;
    for (fx.agent().transcript.items) |e| if (e == .turn_ended) try reasons.append(a, e.turn_ended.reason);
    try expectStrings(&.{ "interrupted", "completed" }, reasons.items);
    try expectStrings(&.{ "queued>running", "running>settled", "settled>running", "running>settled" }, try fx.transitions(a));

    // A turn still running at shutdown is interrupted.
    try fx.host.send("a1", "another long one", .turn);
    try fx.until(isState(.running));
    try fx.host.shutdown();
    try testing.expect(!fx.binding().running());
    try testing.expectEqual(AgentState.settled, fx.agent().state);
    const t = fx.agent().transcript.items;
    try testing.expectEqualStrings("interrupted", t[t.len - 1].turn_ended.reason);
    try testing.expectError(error.ShuttingDown, fx.host.send("a1", "late", .turn));
}

test "fake harness: release, fork, stop, and answers for gone processes" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{});
    defer fx.deinit();
    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    try testing.expectError(error.TurnRunning, fx.host.release("a1"));
    try testing.expectError(error.TurnRunning, fx.host.fork(testing.allocator, "a1", null));
    // The process dies while the request is pending: the turn fails, and an
    // answer has nothing to reach.
    fx.host.stop("a1") catch unreachable;
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return !x.binding().running();
        }
    }.f);
    try testing.expectEqual(AgentState.settled, fx.agent().state);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);

    try fx.host.send("a1", "again", .turn);
    try fx.until(isState(.needs_you));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "deny" } });
    try fx.until(isState(.settled));
    var declined = false;
    for (fx.agent().transcript.items) |e| if (e == .tool_ended and std.mem.eql(u8, e.tool_ended.status, "declined")) {
        declined = true;
    };
    try testing.expect(declined);
    // Delivering the same answer again is a no-op.
    try testing.expectEqual(eventlog.Executor.Outcome{}, try fx.host.run("respond:a1:r2", "{\"agent\":\"a1\",\"request\":\"r2\",\"decision\":\"deny\",\"stale\":false}"));
    try testing.expectEqualStrings("stale", (try fx.host.run("respond:a1:r9", "{\"agent\":\"a1\",\"request\":\"r9\",\"decision\":\"deny\",\"stale\":true}")).detail);
    try testing.expectEqualStrings("conflict.request_resolved", (try fx.host.run("respond:a1:r8", "{\"agent\":\"a1\",\"request\":\"r8\",\"decision\":\"deny\"}")).detail);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The answer is the effect's completion; the fake has it at the first run.
    const key = try fx.host.fork(arena.allocator(), "a1", null);
    try testing.expectEqualStrings("fork:a1:1", key);
    try testing.expect(!fx.engine.state.effects.get(key).?.done);
    _ = try fx.engine.runEffects();
    const forked = fx.engine.state.effects.get(key).?;
    try testing.expect(forked.done and forked.ok);
    try testing.expectEqualStrings("fake-a1-fork2", forked.detail);
    // fork = head has no fork through a named turn.
    try testing.expectError(error.UnsupportedCapability, fx.host.fork(arena.allocator(), "a1", "t1"));
    const record = try fx.host.release("a1");
    try testing.expectEqualStrings("fake-a1", record.harness_session);
    try testing.expectEqualStrings("t2", record.last_turn.?);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.binding().status == .idle;
        }
    }.f);
    // The next send reattaches with --resume.
    try fx.host.send("a1", "third", .turn);
    try fx.until(isState(.needs_you));
    try testing.expectEqualStrings("t3", fx.agent().open_turn.?);
}

const long_script =
    \\{"turns":[{"match":"long","steps":[{"text":"thinking"},{"sleep_ms":20000}]},
    \\          {"match":"","steps":[{"text":"next"}]}]}
;

fn lastReason(fx: *Fixture) []const u8 {
    const t = fx.agent().transcript.items;
    var i = t.len;
    while (i > 0) {
        i -= 1;
        if (t[i] == .turn_ended) return t[i].turn_ended.reason;
    }
    return "";
}

test "fake harness: agent.stop interrupts a running turn through the outbox; agent.archive of a running agent archives it" {
    var fx: Fixture = undefined;
    try fx.init(long_script, .{});
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "a long task", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().messages == 1;
        }
    }.f);
    _ = try fx.engine.submit(.{ .stop = .{ .agent = "a1" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", lastReason(&fx));
    const effect = fx.engine.state.effects.get("stop:a1:t1").?;
    try testing.expect(effect.done and effect.ok);
    try testing.expect(fx.binding().running()); // interrupted, not killed
    // Delivering the same stop again changes nothing.
    try testing.expectEqualStrings("turn_ended", (try fx.host.runStop("stop:a1:t1", "{\"agent\":\"a1\",\"turn\":\"t1\"}")).detail);

    try fx.host.send("a1", "another long one", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().messages == 2;
        }
    }.f);
    _ = try fx.engine.submit(.{ .archive = .{ .agent = "a1" } });
    try fx.until(isState(.archived));
    try expectStrings(&.{ "queued>running", "running>settled", "settled>running", "running>settled", "settled>archived" }, try fx.transitions(a));
}

test "fake harness: agent.stop of a needs_you agent clears its inbox by stop and sends cancel_turn" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{});
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    _ = try fx.engine.submit(.{ .stop = .{ .agent = "a1" } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", lastReason(&fx));
    try testing.expect(fx.binding().running());
    try testing.expectEqual(@as(usize, 0), fx.binding().conv.open_requests.items.len);
    try expectStrings(&.{ "queued>running", "running>needs_you", "needs_you>settled" }, try fx.transitions(a));
    const log = try readFile(a, fx.log_path);
    try testing.expect(std.mem.indexOf(u8, log, "\"type\":\"request.resolved\",\"data\":{\"agent\":\"a1\",\"request\":\"r1\",\"by\":\"stop\"}") != null);
    // The tool call the request belonged to was closed with the turn.
    for (fx.agent().transcript.items) |e| if (e == .tool_ended) try testing.expectEqualStrings("interrupted", e.tool_ended.status);
}

test "fake harness: a stop with no harness process still settles the agent; take back after a restart" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{});
    defer fx.deinit();

    // A turn no process runs any more: the stop effect ends it itself.
    _ = try fx.engine.submit(.{ .create = .{ .agent = "a2", .title = "orphan", .harness = harness.fake.name, .workspace = fx.dir } });
    _ = try fx.engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a2", .turn = "t1", .origin = "user" } } });
    _ = try fx.engine.submit(.{ .stop = .{ .agent = "a2" } });
    try testing.expectEqual(@as(usize, 1), try fx.engine.runEffects());
    const a2 = fx.engine.state.agents.get("a2").?;
    try testing.expectEqual(AgentState.settled, a2.state);
    try testing.expectEqualStrings("no_process", fx.engine.state.effects.get("stop:a2:t1").?.detail);

    // a1: queued → settled → handed_over (own mode: no pane), then a
    // restart takes it back; the fake has no catch_up.
    _ = try fx.engine.submit(.{ .stop = .{ .agent = "a1" } });
    _ = try fx.engine.submit(.{ .transition = .{ .agent = "a1", .to = .handed_over } });
    _ = try fx.engine.submit(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = harness.fake.name, .harness_session = "fake-a1", .mode = "tui" } } });
    try fx.engine.startWith(&.{"p7"});
    try testing.expectEqual(AgentState.settled, fx.agent().state);
    try testing.expectEqual(@as(usize, 1), try fx.engine.runEffects());
    const effect = fx.engine.state.effects.get("takeback:a1:2").?;
    try testing.expect(effect.done and effect.ok);
    try testing.expectEqualStrings("no_catch_up", effect.detail);
    // The next send reattaches the recorded conversation.
    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    fx.notePid();
}

test "take-over: a restart keeps an agent whose TUI client's split still runs, and takes back one whose client is gone" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{});
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a1 is handed over to a split of this process (a live TUI client),
    // a3 to one of a client that is gone.
    const live = try std.fmt.allocPrint(a, "tui:{d}", .{std.c.getpid()});
    _ = try fx.engine.submit(.{ .create = .{ .agent = "a3", .title = "gone", .harness = harness.fake.name, .workspace = fx.dir } });
    for ([_][]const u8{ "a1", "a3" }, [_][]const u8{ live, "tui:2147483600" }) |id, pane| {
        _ = try fx.engine.submit(.{ .stop = .{ .agent = id } });
        _ = try fx.engine.submit(.{ .record = .{ .agent_binding = .{ .agent = id, .harness = harness.fake.name, .harness_session = "s", .mode = "tui", .pane = pane } } });
        _ = try fx.engine.submit(.{ .transition = .{ .agent = id, .to = .handed_over } });
    }
    try testing.expectEqualStrings(live, fx.agent().pane.?);
    try fx.engine.start();
    try testing.expectEqual(AgentState.handed_over, fx.agent().state);
    try testing.expectEqual(AgentState.settled, fx.engine.state.agents.get("a3").?.state);
    try testing.expectEqual(@as(usize, 1), fx.engine.state.effects.count());
    _ = try fx.engine.runEffects();
}

// ---- stale requests ----

const retry_policy: @import("supervisor").Policy = .{ .initial_ms = 5, .max_ms = 20, .reset_after_ms = 60_000, .max_failures = 5 };

/// Kills the harness that holds a pending approval, as a crash would, and
/// waits for the agent to fail with the request kept.
fn crashWithPending(fx: *Fixture) !void {
    try fx.until(isState(.needs_you));
    fx.notePid();
    try testing.expectEqual(@as(c_int, 0), c.kill(fx.binding().process.?.pid(), .KILL));
    try fx.until(isState(.failed));
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
    try testing.expect(fx.agent().requests.items[0].stale);
}

fn logHas(fx: *Fixture, a: std.mem.Allocator, needle: []const u8) !bool {
    return std.mem.indexOf(u8, try readFile(a, fx.log_path), needle) != null;
}

test "stale request: answered allow_once after a crash, the agent resumes and the re-asked call needs no attention" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{ .policy = retry_policy });
    defer fx.deinit();
    var events = try @import("proto").events.Log.init(testing.allocator, "venom", .{}, null);
    defer {
        // The host's shutdown may still log, and `fx.deinit` runs after this.
        fx.host.shutdown() catch {};
        fx.engine.options.events = null;
        events.deinit();
    }
    events.catalog = &eventlog.catalog.entries;
    fx.engine.options.events = &events;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Run the tests", .turn);
    try crashWithPending(&fx);
    try testing.expectEqualStrings("zig build test", fx.agent().requests.items[0].tool.?.title);
    const before = events.high;

    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.until(isState(.settled));

    // Reattached with --resume, in the same conversation; the call ran.
    try testing.expectEqualStrings("fake-a1", fx.agent().harness_session.?);
    try expectStrings(&.{ "queued>running", "running>needs_you", "needs_you>running", "running>failed", "failed>running", "running>settled" }, try fx.transitions(a));
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expectEqualStrings("completed", lastReason(&fx));
    const first = fx.engine.state.effects.get("respond:a1:r1").?;
    try testing.expect(first.done and first.ok);
    const second = fx.engine.state.effects.get("respond:a1:r2").?;
    try testing.expect(second.done and second.ok);
    try testing.expect(try logHas(&fx, a, "\"type\":\"decision.closed\",\"data\":{\"agent\":\"a1\",\"request\":\"r1\",\"by\":\"consumed\"}"));
    try testing.expect(try logHas(&fx, a, "\"request\":\"r2\",\"by\":\"venom\",\"one_shot\":\"r1\""));
    var ended_ok = false;
    for (fx.agent().transcript.items) |e| if (e == .tool_ended and std.mem.eql(u8, e.tool_ended.call, "c2")) {
        ended_ok = std.mem.eql(u8, e.tool_ended.status, "ok");
    };
    try testing.expect(ended_ok);

    // No new attention for r2; the turn's `review` is the only one raised.
    var raised: usize = 0;
    var cleared: usize = 0;
    for (events.entries.items) |e| {
        if (e.seq <= before or std.mem.indexOf(u8, e.bytes, "\"approval\"") == null) continue;
        raised += @intFromBool(std.mem.eql(u8, e.type, "agent.attention"));
        cleared += @intFromBool(std.mem.eql(u8, e.type, "agent.attention_cleared"));
    }
    try testing.expectEqual(@as(usize, 0), raised);
    try testing.expectEqual(@as(usize, 1), cleared); // r1, by the answer
}

/// Waits until `pid` has died (a zombie nobody reaped yet), without running
/// the host, so the decider does not know.
fn waitDead(pid: c.pid_t) !void {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0);
    const deadline = std.time.ms_per_s * 10 + now();
    while (now() < deadline) {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const stat = readFile(arena.allocator(), path) catch return;
        // `pid (comm) S ...`: the state follows the last ')'.
        const i = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.BadStat;
        if (stat.len > i + 2 and stat[i + 2] == 'Z') return;
        _ = c.sched_yield();
    }
    return error.Timeout;
}

test "lost answer: an answer committed just before a crash becomes a one-shot decision; the re-asked call needs no attention" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{ .policy = retry_policy });
    defer fx.deinit();
    var events = try @import("proto").events.Log.init(testing.allocator, "venom", .{}, null);
    defer {
        // The host's shutdown may still log, and `fx.deinit` runs after this.
        fx.host.shutdown() catch {};
        fx.engine.options.events = null;
        events.deinit();
    }
    events.catalog = &eventlog.catalog.entries;
    fx.engine.options.events = &events;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Run the tests", .turn);
    try fx.until(isState(.needs_you));
    fx.notePid();
    const pid = fx.binding().process.?.pid();
    try testing.expectEqual(@as(c_int, 0), c.kill(pid, .KILL));
    try waitDead(pid);
    // Answered while the decider still sees the request live.
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    const before = events.high;
    try fx.until(isState(.settled));

    // The delivery failed, the agent failed, then resumed on its own.
    const first = fx.engine.state.effects.get("respond:a1:r1").?;
    try testing.expect(first.done and !first.ok);
    try testing.expect(eventlog.oneshot.undelivered(first.detail));
    const resumed = fx.engine.state.effects.get("respond:a1:r1:2").?;
    try testing.expect(resumed.done and resumed.ok);
    try expectStrings(&.{ "queued>running", "running>needs_you", "needs_you>running", "running>failed", "failed>running", "running>settled" }, try fx.transitions(a));
    try testing.expectEqualStrings("fake-a1", fx.agent().harness_session.?);
    try testing.expectEqualStrings("completed", lastReason(&fx));
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    // The re-asked call was answered from the decision, and it ran.
    try testing.expect(try logHas(&fx, a, "\"type\":\"decision.closed\",\"data\":{\"agent\":\"a1\",\"request\":\"r1\",\"by\":\"consumed\"}"));
    try testing.expect(try logHas(&fx, a, "\"request\":\"r2\",\"by\":\"venom\",\"one_shot\":\"r1\""));
    const second = fx.engine.state.effects.get("respond:a1:r2").?;
    try testing.expect(second.done and second.ok);
    var ended_ok = false;
    for (fx.agent().transcript.items) |e| if (e == .tool_ended and std.mem.eql(u8, e.tool_ended.call, "c2")) {
        ended_ok = std.mem.eql(u8, e.tool_ended.status, "ok");
    };
    try testing.expect(ended_ok);

    // Nobody was asked again.
    for (events.entries.items) |e| {
        if (e.seq <= before or std.mem.indexOf(u8, e.bytes, "\"approval\"") == null) continue;
        try testing.expect(!std.mem.eql(u8, e.type, "agent.attention"));
    }
}

test "stale request: a deny's reason reaches the resume prompt and the re-asked call" {
    // The second turn runs only if the reason is in the message; `echo`
    // shows what the re-asked call was answered.
    const script =
        \\{"turns":[{"match":"use the wasm target","steps":[
        \\    {"tool":{"id":"tu2","name":"Bash","kind":"exec","title":"zig build test"}},
        \\    {"ask":{"id":"p2","kind":"approval","call":"tu2","reason":"Run zig build test?","input":"zig build test","echo":true}},
        \\    {"tool_end":{"id":"tu2","status":"ok"}}]},
        \\  {"match":"","steps":[
        \\    {"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build test"}},
        \\    {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build test?","input":"zig build test"}}]}]}
    ;
    var fx: Fixture = undefined;
    try fx.init(script, .{ .policy = retry_policy, .resume_prompt = "Go on." });
    defer fx.deinit();
    try fx.host.send("a1", "Run the tests", .turn);
    try crashWithPending(&fx);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "deny", .reason = "use the wasm target" } });
    try fx.until(isState(.settled));
    var echoed: ?[]const u8 = null;
    var declined = false;
    for (fx.agent().transcript.items) |e| switch (e) {
        .text => |t| echoed = t.text,
        .tool_ended => |t| declined = declined or std.mem.eql(u8, t.status, "declined"),
        else => {},
    };
    try testing.expectEqualStrings("answer=deny reason=use the wasm target args=", echoed.?);
    try testing.expect(declined);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
}

test "stale request: a decision not consumed by the next turn expires, and the call is asked again" {
    const script =
        \\{"turns":[{"match":"Continue","steps":[{"text":"changed my mind"}]},
        \\  {"match":"","steps":[
        \\    {"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build test"}},
        \\    {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build test?","input":"zig build test"}}]}]}
    ;
    var fx: Fixture = undefined;
    try fx.init(script, .{ .policy = retry_policy });
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try fx.host.send("a1", "Run the tests", .turn);
    try crashWithPending(&fx);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);
    try fx.until(isState(.settled));
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expect(try logHas(&fx, arena.allocator(), "\"type\":\"decision.closed\",\"data\":{\"agent\":\"a1\",\"request\":\"r1\",\"by\":\"expired\"}"));
    try fx.host.send("a1", "try again", .turn);
    try fx.until(isState(.needs_you));
    try testing.expectEqualStrings("r2", fx.agent().requests.items[0].request);
}

test "stale request: after a daemon restart a fresh host reattaches; cancel_turn does not resume" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{ .policy = retry_policy });
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const digest = try eventlog.events.inputDigest(arena.allocator(), "zig build test");
    // Nothing is running: as a new daemon finds the log.
    for ([_][]const u8{ "a1", "a2" }) |id| {
        if (!std.mem.eql(u8, id, "a1")) _ = try fx.engine.submit(.{ .create = .{ .agent = id, .title = "t", .harness = harness.fake.name, .workspace = fx.dir } });
        _ = try fx.engine.submit(.{ .record = .{ .turn_started = .{ .agent = id, .turn = "t1", .origin = "user" } } });
        _ = try fx.engine.submit(.{ .record = .{ .tool_started = .{ .agent = id, .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build test" } } });
        _ = try fx.engine.submit(.{ .record = .{ .request = .{ .agent = id, .request = "r1", .kind = "approval", .reason = "Run?", .call = "c1", .input_digest = digest } } });
    }
    try fx.engine.start();
    try testing.expect(fx.agent().requests.items[0].stale);

    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a2", .request = "r1", .decision = "cancel_turn" } });
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("fake-a1", fx.agent().harness_session.?);
    const a2 = fx.engine.state.agents.get("a2").?;
    try testing.expectEqual(AgentState.failed, a2.state);
    try testing.expect(fx.host.binding("a2") == null);
    const cancelled = fx.engine.state.effects.get("respond:a2:r1").?;
    try testing.expect(cancelled.done and !cancelled.ok);
    try testing.expectEqualStrings("stale", cancelled.detail);
}

test "stale request: a resume that fails closes the decision and brings the request back" {
    var fx: Fixture = undefined;
    try fx.init(approval_script, .{ .policy = retry_policy });
    defer fx.deinit();
    var events = try @import("proto").events.Log.init(testing.allocator, "venom", .{}, null);
    defer {
        // The host's shutdown may still log, and `fx.deinit` runs after this.
        fx.host.shutdown() catch {};
        fx.engine.options.events = null;
        events.deinit();
    }
    events.catalog = &eventlog.catalog.entries;
    fx.engine.options.events = &events;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const digest = try eventlog.events.inputDigest(arena.allocator(), "zig build test");
    // Its harness is not registered with this daemon any more.
    _ = try fx.engine.submit(.{ .create = .{ .agent = "a2", .title = "t", .harness = "gone", .workspace = fx.dir } });
    _ = try fx.engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a2", .turn = "t1", .origin = "user" } } });
    _ = try fx.engine.submit(.{ .record = .{ .tool_started = .{ .agent = "a2", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build test" } } });
    _ = try fx.engine.submit(.{ .record = .{ .request = .{ .agent = "a2", .request = "r1", .kind = "approval", .reason = "Run?", .call = "c1", .input_digest = digest } } });
    try fx.engine.start();
    const a2 = fx.engine.state.agents.getPtr("a2").?;
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a2", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(@as(usize, 1), a2.decisions.items.len);
    try testing.expectEqual(@as(usize, 0), a2.requests.items.len);
    const high = events.high;
    _ = try fx.engine.runEffects();

    const effect = fx.engine.state.effects.get("respond:a2:r1").?;
    try testing.expect(effect.done and !effect.ok);
    try testing.expectEqualStrings("unavailable.harness_not_found", effect.detail);
    try testing.expectEqual(@as(usize, 0), a2.decisions.items.len);
    try testing.expectEqual(@as(usize, 1), a2.requests.items.len);
    try testing.expect(a2.requests.items[0].stale);
    var raised = false;
    for (events.entries.items) |e| raised = raised or (e.seq > high and std.mem.eql(u8, e.type, "agent.attention"));
    try testing.expect(raised);

    // A handed-over agent's resume fails the same way.
    _ = try fx.engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } });
    _ = try fx.engine.submit(.{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build test" } } });
    _ = try fx.engine.submit(.{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "Run?", .call = "c1", .input_digest = digest } } });
    _ = try fx.engine.submit(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "failed", .error_code = eventlog.oneshot.process_gone_code } } });
    _ = try fx.engine.submit(.{ .transition = .{ .agent = "a1", .to = .archived } });
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    _ = try fx.engine.runEffects();
    try testing.expect(!fx.engine.state.effects.get("respond:a1:r1").?.ok);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
}

test "stale request: a deny answered during a running turn reaches the model without a re-ask" {
    const script =
        \\{"turns":[{"match":"use the wasm target","steps":[{"text":"heard it"}]},
        \\  {"match":"Continue","steps":[{"sleep_ms":200}]},
        \\  {"match":"","steps":[
        \\    {"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build test"}},
        \\    {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build test?","input":"zig build test"}}]}]}
    ;
    var fx: Fixture = undefined;
    try fx.init(script, .{ .policy = retry_policy });
    defer fx.deinit();
    try fx.host.send("a1", "Run the tests", .turn);
    try crashWithPending(&fx);
    try fx.host.retry("a1");
    try fx.until(isState(.running));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "deny", .reason = "use the wasm target" } });
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            for (x.agent().transcript.items) |e| if (e == .text and std.mem.eql(u8, e.text.text, "heard it")) return true;
            return false;
        }
    }.f);
    try testing.expectEqualStrings("in_turn", fx.engine.state.effects.get("respond:a1:r1").?.detail);
}

test "stale request: reject feedback reaches the prompt as feedback on a rejected plan" {
    const script =
        \\{"turns":[{"match":"This plan was rejected: Plan A\nFeedback: split step 2","steps":[{"text":"replanning"}]},
        \\  {"match":"","steps":[
        \\    {"tool":{"id":"tu1","name":"ExitPlanMode","kind":"plan","title":""}},
        \\    {"ask":{"id":"p1","kind":"plan","call":"tu1","reason":"Plan A","input":"{\"plan\":\"Plan A\"}"}}]}]}
    ;
    var fx: Fixture = undefined;
    try fx.init(script, .{ .policy = retry_policy });
    defer fx.deinit();
    try fx.host.send("a1", "Plan it", .turn);
    try crashWithPending(&fx);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "reject", .reason = "split step 2" } });
    try fx.until(isState(.settled));
    const t = fx.agent().transcript.items;
    try testing.expectEqualStrings("replanning", t[t.len - 2].text.text);
}
