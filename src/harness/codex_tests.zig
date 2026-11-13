//! The Codex adapter driving real agents through the host and the durable
//! event log, against a fake `codex app-server`
//! (`testdata/codex_app_server.py`) that replays hand-written JSON-RPC
//! traces: no Codex binary, no sign-in, no quota. Every test ends with no
//! child process left.
//!
//! The e2e test against the real `codex` runs only when
//! `VENOM_CODEX_E2E=1` is set (it spends a real turn of the user's quota),
//! and is skipped when `codex` is absent or not signed in.
const std = @import("std");
const eventlog = @import("../eventlog/root.zig");
const harness = @import("root.zig");
const codex = @import("codex.zig");
const Host = harness.Host;
const Engine = eventlog.Engine;
const AgentState = eventlog.agent.State;
const c = std.c;
const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    log_path: [:0]u8,
    script: []u8,
    trace: []u8,
    argv: [5][]const u8,
    engine: Engine,
    codex: codex.Codex,
    adapters: [1]harness.host.Registered,
    host: Host,
    pids: std.ArrayList(c.pid_t) = .empty,

    fn init(self: *Fixture, trace: []const u8) !void {
        return self.initAgent(trace, &.{}, null);
    }

    /// `mode`: the agent's permission mode.
    fn initMode(self: *Fixture, trace: []const u8, mode: []const u8) !void {
        return self.initAgent(trace, &.{}, mode);
    }

    /// `repos`: the agent's scope, in a workspace of `a` and `c`.
    fn initScoped(self: *Fixture, trace: []const u8, repos: []const []const u8) !void {
        return self.initAgent(trace, repos, null);
    }

    fn initAgent(self: *Fixture, trace: []const u8, repos: []const []const u8, mode: ?[]const u8) !void {
        self.pids = .empty;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "codex_app_server.py", .data = @embedFile("testdata/codex_app_server.py") });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "codex.trace", .data = trace });
        self.script = try std.fmt.allocPrint(testing.allocator, "{s}/codex_app_server.py", .{self.dir});
        errdefer testing.allocator.free(self.script);
        self.trace = try std.fmt.allocPrint(testing.allocator, "{s}/codex.trace", .{self.dir});
        errdefer testing.allocator.free(self.trace);
        self.log_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/events.log", .{self.dir}, 0);
        errdefer testing.allocator.free(self.log_path);
        self.engine = try Engine.open(testing.allocator, self.log_path, .{});
        errdefer self.engine.deinit();
        self.argv = .{ "python3", self.script, self.trace, self.dir, self.dir };
        self.codex = .init(testing.allocator);
        self.codex.argv = &self.argv;
        self.adapters = .{.{ .harness = codex.name, .adapter = self.codex.adapter() }};
        self.host = Host.init(testing.allocator, &self.engine, &self.adapters, .{ .shutdown_grace_ms = 2_000 });
        self.engine.options.executors = self.host.executor();
        try self.engine.start();
        if (repos.len > 0) _ = try self.engine.submit(.{ .workspace_add = .{ .path = self.dir, .repos = &.{ "a", "c" } } });
        _ = try self.engine.submit(.{ .create = .{ .agent = "a1", .title = "Run the tests", .harness = codex.name, .workspace = self.dir, .repos = repos, .mode = mode } });
    }

    fn deinit(self: *Fixture) void {
        self.host.deinit();
        for (self.pids.items) |pid| {
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("a harness process outlived the host");
        }
        self.pids.deinit(testing.allocator);
        self.codex.deinit();
        self.engine.deinit();
        testing.allocator.free(self.log_path);
        testing.allocator.free(self.trace);
        testing.allocator.free(self.script);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn dirPath(self: *Fixture, a: std.mem.Allocator, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.dir, name }, 0);
    }

    fn agent(self: *Fixture) eventlog.decider.Agent {
        return self.engine.state.agents.get("a1").?;
    }
    fn binding(self: *Fixture) *harness.host.Binding {
        return self.host.binding("a1").?;
    }

    /// Runs reactor turns (and the effect worker) until `done` or 10 s.
    fn until(self: *Fixture, comptime done: fn (*Fixture) bool) !void {
        const deadline = now() + 10_000;
        while (!done(self)) {
            if (now() > deadline) {
                if (self.host.binding("a1")) |b| if (b.process) |*p| std.debug.print("fake app-server stderr: {s}\n", .{p.stderrTail()});
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();
                const got = std.fmt.allocPrintSentinel(arena.allocator(), "{s}/received.0.jsonl", .{self.dir}, 0) catch return error.Timeout;
                if (readFile(arena.allocator(), got)) |bytes| std.debug.print("venom wrote:\n{s}\n", .{bytes}) else |_| {}
                return error.Timeout;
            }
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

    /// Asks for a fork and runs reactor turns until its effect completes.
    fn fork(self: *Fixture, a: std.mem.Allocator, through_turn: ?[]const u8) !eventlog.decider.Effect {
        return self.forkDone(try self.host.fork(a, "a1", through_turn));
    }

    fn forkDone(self: *Fixture, key: []const u8) !eventlog.decider.Effect {
        const deadline = now() + 10_000;
        while (true) {
            const effect = self.engine.state.effects.get(key).?;
            if (effect.done) return effect;
            if (now() > deadline) return error.Timeout;
            try self.host.poll(5);
            _ = try self.engine.runEffects();
            self.notePid();
        }
    }

    /// Runs reactor turns until process `n` has read `text`.
    fn untilReceived(self: *Fixture, a: std.mem.Allocator, n: u32, text: []const u8) !void {
        const path = try self.dirPath(a, try std.fmt.allocPrint(a, "received.{d}.jsonl", .{n}));
        const deadline = now() + 10_000;
        while (std.mem.indexOf(u8, readFile(a, path) catch "", text) == null) {
            if (now() > deadline) return error.Timeout;
            try self.host.poll(5);
            _ = try self.engine.runEffects();
            self.notePid();
        }
    }

    fn openGate(self: *Fixture, name: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }

    /// Releases the agent's process and waits until it is gone.
    fn releaseIdle(self: *Fixture) !void {
        _ = try self.host.release("a1");
        try self.until(gone);
    }

    fn gone(self: *Fixture) bool {
        return !self.binding().running() and self.binding().status == .idle;
    }

    /// The durable log's events as `type` or, for `with`, `type:data.<with>`.
    fn records(self: *Fixture, a: std.mem.Allocator) ![]const std.json.Value {
        const bytes = try readFile(a, self.log_path);
        var out: std.ArrayList(std.json.Value) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
            for (v.object.get("events").?.array.items) |e| try out.append(a, e);
        }
        return out.items;
    }

    /// The agent's harness-facing events, without state changes and effects.
    fn types(self: *Fixture, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.records(a)) |e| {
            const t = e.object.get("type").?.string;
            if (std.mem.eql(u8, t, "agent.state_changed") or std.mem.startsWith(u8, t, "effect.") or std.mem.eql(u8, t, "daemon.started") or std.mem.eql(u8, t, "agent.created")) continue;
            try out.append(a, t);
        }
        return out.items;
    }

    fn transitions(self: *Fixture, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.records(a)) |e| {
            if (!std.mem.eql(u8, e.object.get("type").?.string, "agent.state_changed")) continue;
            const d = e.object.get("data").?.object;
            try out.append(a, try std.fmt.allocPrint(a, "{s}>{s}", .{ d.get("from").?.string, d.get("to").?.string }));
        }
        return out.items;
    }

    /// The `data` of the first logged event of type `t`.
    fn first(self: *Fixture, a: std.mem.Allocator, t: []const u8) !std.json.ObjectMap {
        for (try self.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, t)) return e.object.get("data").?.object;
        return error.NotLogged;
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

fn turnStarted(fx: *Fixture) bool {
    const b = fx.host.binding("a1") orelse return false;
    return b.conv.harness_turn != null;
}

fn lastEnded(fx: *Fixture) eventlog.events.TurnEnded {
    const t = fx.agent().transcript.items;
    var i = t.len;
    while (i > 0) {
        i -= 1;
        if (t[i] == .turn_ended) return t[i].turn_ended;
    }
    @panic("no turn ended");
}

fn hasPython() bool {
    const r = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "python3", "-c", "" } }) catch return false;
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

test "codex: sample trace: steer, exec approval, tool call, usage, settled" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_approval.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Run the proto tests and fix what fails.", .turn);
    try fx.until(turnStarted);
    try testing.expectEqualStrings("thr_123", fx.agent().harness_session.?);
    try fx.host.send("a1", "Only the proto module, not the whole tree.", .steer);
    try fx.until(isState(.needs_you));
    const req = fx.agent().requests.items[0];
    try testing.expectEqualStrings("r1", req.request);
    try testing.expectEqualStrings("c1", req.call.?);
    try testing.expectEqualStrings("Run zig build test -Dmodule=proto", req.reason);
    try testing.expect(req.input_digest != null);
    // Codex cannot change a command on approval.
    try testing.expectError(error.InvalidCommand, fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_edited" } }));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_always" } });
    try fx.until(isState(.settled));
    try testing.expect(fx.engine.state.effects.get("respond:a1:r1").?.ok);
    // The update comes after the turn's end.
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            const plan = x.engine.state.usage.plans.get("codex") orelse return false;
            return plan.windows.len > 0 and plan.windows[0].used_pct == 31;
        }
    }.f);

    try expectStrings(&.{ "queued>running", "running>needs_you", "needs_you>running", "running>settled" }, try fx.transitions(a));
    // allow_always also keeps the grant in venom's store.
    try expectStrings(&.{ "agent.binding", "plan_windows", "turn.started", "turn.prompt", "turn.prompt", "tool.started", "request", "always.granted", "request.resolved", "tool.ended", "text", "usage", "context", "turn.ended", "plan_windows" }, try fx.types(a));
    // The context estimate: the last call's input tokens over the window.
    const context = try fx.first(a, "context");
    try testing.expectEqual(@as(i64, 8800), context.get("used").?.integer);
    try testing.expectEqual(@as(i64, 272000), context.get("window").?.integer);
    try testing.expectEqualStrings("estimate", context.get("source").?.string);
    try testing.expectEqual(@as(u64, 8800), fx.engine.state.usage.agents.get("a1").?.context.?.used);

    const binding = try fx.first(a, "agent.binding");
    try testing.expectEqualStrings("thr_123", binding.get("harness_session").?.string);
    try testing.expectEqualStrings("gpt-5.5-codex", binding.get("model").?.string);
    try testing.expectEqualStrings("0.167.0", binding.get("harness_version").?.string);
    const started = try fx.first(a, "tool.started");
    try testing.expectEqualStrings("exec", started.get("kind").?.string);
    try testing.expectEqualStrings("commandExecution", started.get("name").?.string);
    try testing.expectEqualStrings("zig build test -Dmodule=proto", started.get("title").?.string);
    try testing.expectEqualStrings("item_7", started.get("harness_ref").?.string);
    // Tool args and body.
    const args = started.get("args").?.object;
    try testing.expectEqualStrings("zig build test -Dmodule=proto", args.get("command").?.string);
    try testing.expectEqualStrings(fx.dir, args.get("cwd").?.string);
    const ended = try fx.first(a, "tool.ended");
    const body = ended.get("body").?.object;
    try testing.expectEqualStrings("All 112 tests passed.\n", body.get("text").?.string);
    try testing.expect(!body.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, 22), body.get("bytes").?.integer);
    try testing.expectEqualStrings("ok", ended.get("status").?.string);
    try testing.expectEqual(@as(i64, 0), ended.get("exit").?.integer);
    try testing.expectEqual(@as(i64, 4210), ended.get("duration_ms").?.integer);
    // tokens_in is uncached input: 43458 - 40210.
    const usage = try fx.first(a, "usage");
    try testing.expectEqualStrings("gpt-5.5-codex", usage.get("model").?.string);
    try testing.expectEqual(@as(i64, 3248), usage.get("tokens_in").?.integer);
    try testing.expectEqual(@as(i64, 812), usage.get("tokens_out").?.integer);
    try testing.expectEqual(@as(i64, 40210), usage.get("cache_read").?.integer);
    try testing.expectEqualStrings("All proto tests pass.", (try fx.first(a, "text")).get("text").?.string);
    const plan = try fx.first(a, "plan_windows");
    try testing.expectEqualStrings("chatgpt", plan.get("account").?.string);
    try testing.expectEqualStrings("subscription", plan.get("billing").?.string);
    try testing.expectEqualStrings("7d", plan.get("windows").?.array.items[1].object.get("label").?.string);
    const end = lastEnded(&fx);
    try testing.expectEqualStrings("t1", end.turn);
    try testing.expectEqualStrings("completed", end.reason);
    try testing.expect(fx.binding().running());
}

test "codex: usage limit fails with limit, a rejected turn/start fails, interrupt, release and thread/resume" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_limit_resume.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A reached usage limit: `failed`, with the `limit` reason and code.
    try fx.host.send("a1", "first", .turn);
    try fx.until(isState(.failed));
    try testing.expectEqualStrings("limit", lastEnded(&fx).reason);
    try testing.expectEqualStrings("failed.usage_limit", lastEnded(&fx).error_code.?);
    // When the exhausted window resets, also in the inbox.
    try testing.expectEqualStrings("2026-11-07T15:00:00Z", lastEnded(&fx).resets_at.?);
    try testing.expectEqualStrings("2026-11-07T15:00:00Z", eventlog.attention.stateItem("a1", fx.engine.state.agents.getPtr("a1").?).?.resets_at.?);
    try testing.expectEqual(@as(i64, 100), (try fx.first(a, "usage")).get("tokens_in").?.integer);

    // The harness rejects turn/start: the turn is logged as failed.
    try fx.host.send("a1", "second", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().turns == 2 and x.agent().state == .failed;
        }
    }.f);
    try testing.expectEqualStrings("failed.harness_turn", lastEnded(&fx).error_code.?);

    // Interrupt: turn/interrupt, and the open call is closed as interrupted.
    try fx.host.send("a1", "long", .turn);
    try fx.until(turnStarted);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.binding().conv.open_calls.items.len == 1;
        }
    }.f);
    try fx.host.interrupt("a1");
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", lastEnded(&fx).reason);

    // Release between turns: the process exits; the thread stays.
    const record = try fx.host.release("a1");
    try testing.expectEqualStrings("thr_9", record.harness_session);
    try testing.expectEqualStrings("t3", record.last_turn.?);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.binding().status == .idle;
        }
    }.f);

    // The next send reattaches with thread/resume; usage re-bases on the
    // first report (total - last), so history is not counted again.
    try fx.host.send("a1", "again", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().turns == 4 and x.agent().state == .settled;
        }
    }.f);
    var usages: std.ArrayList(std.json.ObjectMap) = .empty;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "usage")) try usages.append(a, e.object.get("data").?.object);
    const last = usages.items[usages.items.len - 1];
    try testing.expectEqualStrings("t4", last.get("turn").?.string);
    try testing.expectEqual(@as(i64, 200), last.get("tokens_in").?.integer);
    try testing.expectEqual(@as(i64, 100), last.get("cache_read").?.integer);
    try testing.expectEqual(@as(i64, 20), last.get("tokens_out").?.integer);
    var interrupted = false;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "tool.ended")) {
        interrupted = std.mem.eql(u8, e.object.get("data").?.object.get("status").?.string, "interrupted");
    };
    try testing.expect(interrupted);
    try expectStrings(&.{ "queued>running", "running>failed", "failed>running", "running>failed", "failed>running", "running>settled", "settled>running", "running>settled" }, try fx.transitions(a));
}

test "codex: a denied patch is declined; a request the harness withdraws resolves by harness" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_patch_withdrawn.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Edit the proto", .turn);
    try fx.until(isState(.needs_you));
    try testing.expectEqualStrings("Edit src/proto.zig", fx.agent().requests.items[0].reason);
    // The patch's item identifies the call.
    try testing.expect(fx.agent().requests.items[0].input_digest != null);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "deny" } });
    try fx.until(isState(.settled));

    var statuses: std.ArrayList([]const u8) = .empty;
    var by: std.ArrayList([]const u8) = .empty;
    for (try fx.records(a)) |e| {
        const t = e.object.get("type").?.string;
        const d = e.object.get("data").?.object;
        if (std.mem.eql(u8, t, "tool.ended")) try statuses.append(a, d.get("status").?.string);
        if (std.mem.eql(u8, t, "request.resolved")) try by.append(a, d.get("by").?.string);
    }
    try expectStrings(&.{ "declined", "declined" }, statuses.items);
    // Edit args and the diff as body.
    const args = (try fx.first(a, "tool.started")).get("args").?.object;
    try testing.expectEqualStrings("src/proto.zig", args.get("path").?.string);
    try testing.expectEqualStrings("modify", args.get("change").?.string);
    try testing.expectEqualStrings("@@", (try fx.first(a, "tool.ended")).get("body").?.object.get("text").?.string);
    try testing.expectEqualStrings("harness", by.items[by.items.len - 1]);
    try testing.expectEqualStrings("edit", (try fx.first(a, "tool.started")).get("kind").?.string);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
}

test "codex: item/tool/requestUserInput is a question with options by position, answered by label under codex's ids" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_question.trace"));
    defer fx.deinit();
    try fx.host.send("a1", "Ask me", .turn);
    try fx.until(isState(.needs_you));
    const req = fx.agent().requests.items[0];
    try testing.expectEqualStrings("question", req.kind);
    try testing.expectEqualStrings("Keep varint framing?", req.reason);
    const opts = req.options.?;
    try testing.expectEqual(@as(usize, 2), opts.len);
    try testing.expectEqualStrings("q1", opts[0].id);
    try testing.expectEqualStrings("Fixed u32", opts[0].labels[1]);
    try testing.expectEqualStrings("q2", opts[1].id);
    try testing.expectEqualStrings("Byte order?", opts[1].question);
    try testing.expectEqualStrings("B", opts[1].labels[1]);
    // The trace checks the reply: codex's ids, the picked labels.
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "Fixed u32, B", .args_json = "{\"q1\":[\"Fixed u32\"],\"q2\":[\"B\"]}" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("completed", lastEnded(&fx).reason);
}

test "codex: a question with no options (null or missing) takes a typed answer, plain or by question id" {
    if (!hasPython()) return error.SkipZigTest;
    const Case = struct { trace: []const u8, decision: []const u8, args: ?[]const u8 };
    const cases = [_]Case{
        .{ .trace = @embedFile("testdata/codex_question_typed_plain.trace"), .decision = "because", .args = null },
        .{ .trace = @embedFile("testdata/codex_question_typed_args.trace"), .decision = "one, two", .args = "{\"q1\":[\"one\"],\"q2\":[\"two\"]}" },
    };
    for (cases) |case| {
        var fx: Fixture = undefined;
        try fx.init(case.trace);
        defer fx.deinit();
        try fx.host.send("a1", "Ask me", .turn);
        try fx.until(isState(.needs_you));
        const opts = fx.agent().requests.items[0].options.?;
        try testing.expectEqual(@as(usize, 2), opts.len);
        for (opts) |o| try testing.expect(o.free_text and o.labels.len == 0);
        _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = case.decision, .args_json = case.args } });
        try fx.until(isState(.settled));
        try testing.expectEqualStrings("completed", lastEnded(&fx).reason);
    }
}

fn pendingIs(comptime id: []const u8) fn (*Fixture) bool {
    return struct {
        fn f(fx: *Fixture) bool {
            const reqs = fx.agent().requests.items;
            return reqs.len == 1 and std.mem.eql(u8, reqs[0].request, id);
        }
    }.f;
}

/// Answers every request of `codex_always.trace` allow_always, and returns
/// what venom wrote: the trace checks each decision is a plain accept.
fn allowAlways(fx: *Fixture, a: std.mem.Allocator) ![]const u8 {
    try fx.host.send("a1", "Check, build, clean, status, edit", .turn);
    inline for (.{ "r1", "r2", "r3", "r4", "r5" }) |r| {
        try fx.until(pendingIs(r));
        _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = r, .decision = "allow_always" } });
    }
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("completed", lastEnded(fx).reason);

    // venom keeps its own narrowed grants.
    var grants: std.ArrayList([]const u8) = .empty;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "always.granted")) try grants.append(a, e.object.get("data").?.object.get("grant").?.string);
    try expectStrings(&.{ "exec:bash scripts/check.sh", "exec:zig", "exec:rm -rf zig-out", "exec:git status", "edit:src/proto.zig" }, grants.items);

    const sent = try readFile(a, try fx.dirPath(a, "received.0.jsonl"));
    try testing.expect(std.mem.indexOf(u8, sent, "acceptForSession") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "acceptWithExecpolicyAmendment") == null);
    return sent;
}

test "codex: allow always stays in venom's grants; no rule goes to codex" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_always.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try allowAlways(&fx, arena.allocator());
}

test "codex: in plan mode too, no rule goes to codex, which could pass later commands" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.initMode(@embedFile("testdata/codex_always.trace"), "plan");
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sent = try allowAlways(&fx, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, sent, "\"sandbox\":\"read-only\"") != null);
}

test "codex: a scoped agent runs under a permission profile; in-scope patches do not ask, others do, by every path" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.initScoped(@embedFile("testdata/codex_scope.trace"), &.{"a"});
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Edit", .turn);
    inline for (.{ "r1", "r2" }) |r| {
        try fx.until(pendingIs(r));
        const req = fx.agent().requests.items[0];
        try testing.expect(req.outside_scope);
        try testing.expect(req.grant == null);
        _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = r, .decision = "deny" } });
    }
    // An in-scope command: venom keeps the grant, codex gets no rule (the
    // trace checks the plain accept).
    try fx.until(pendingIs("r3"));
    try testing.expect(!fx.agent().requests.items[0].outside_scope);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r3", .decision = "allow_always" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("completed", lastEnded(&fx).reason);

    // Only these: fc_1, in scope, raised nothing.
    var raised: usize = 0;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "request")) {
        raised += 1;
    };
    try testing.expectEqual(@as(usize, 3), raised);
    // The profile replaces the sandbox mode.
    const sent = try readFile(a, try fx.dirPath(a, "received.0.jsonl"));
    try testing.expect(std.mem.indexOf(u8, sent, "\"sandbox\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "read-only") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "acceptWithExecpolicyAmendment") == null);

    // Scoped resume: the profile again (the trace's second process).
    _ = try fx.host.release("a1");
    try fx.until(isReleased);
    try fx.host.send("a1", "More", .turn);
    try fx.until(turnStartedTwice);
    const resumed = try readFile(a, try fx.dirPath(a, "received.1.jsonl"));
    try testing.expect(std.mem.indexOf(u8, resumed, "\"sandbox\"") == null);
}

fn isReleased(fx: *Fixture) bool {
    return fx.binding().status == .idle;
}

fn turnStartedTwice(fx: *Fixture) bool {
    return fx.agent().turns == 2 and fx.agent().state == .settled;
}

test "codex: a scoped thread whose profile is not active does not run" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.initScoped(@embedFile("testdata/codex_scope_no_profile.trace"), &.{"a"});
    defer fx.deinit();

    try fx.host.send("a1", "Edit", .turn);
    try fx.until(isState(.failed));
    try testing.expectEqualStrings("unsupported.harness_version", lastEnded(&fx).error_code.?);
}

// Opt-in: spends one real Codex turn. `VENOM_CODEX_E2E=1 zig build test`.
test "codex: take-over: the descriptor offers it; resume_command and notify; only a turn's end raises attention" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx = try codex.Codex.initCommand(testing.allocator, "/opt/codex", &.{ "-c", "model=\"o3\"" });
    defer cx.deinit();
    const caps = cx.caps();
    try testing.expect(caps.resume_tui and caps.release);
    try testing.expectEqual(harness.contract.CatchUp.api, caps.catch_up);
    try testing.expectEqual(harness.contract.AttentionAway.turn_end, caps.attention_away);

    // A plain take-over: no notify, and `extra_args` belong to the app-server.
    const plain = try cx.resume_command(a, .{ .agent = "a1", .harness = codex.name, .harness_session = "thr", .cwd = "/w" });
    try testing.expectEqual(@as(usize, 3), plain.argv.len);
    try testing.expectEqualStrings("/opt/codex", plain.argv[0]);
    try testing.expectEqualStrings("resume", plain.argv[1]);
    try testing.expectEqualStrings("thr", plain.argv[2]);
    try testing.expectEqualStrings("/w", plain.cwd.?);

    cx.mcp = .{ .command = "/usr/bin/venom", .socket = "/run/v.sock" };
    const hooked = try cx.resume_command(a, .{ .agent = "a1", .hooks = true, .harness = codex.name, .harness_session = "thr", .cwd = "/w" });
    try testing.expectEqualStrings("notify=[\"/usr/bin/venom\",\"agent\",\"hook\",\"--agent\",\"a1\",\"--input\"]", hooked.argv[4]);
    try testing.expectEqualStrings("VENOM_SOCKET", hooked.env[1].name);
    for (hooked.env) |e| try testing.expect(!std.mem.eql(u8, e.name, "VENOM_TOKEN"));

    const end = try codex.parseNotify(a, "{\"type\":\"agent-turn-complete\",\"thread-id\":\"thr\",\"turn-id\":\"t\"}", "thr");
    try testing.expectEqualStrings("review", @tagName(end.kind.?));
    // Codex's own background thread (the task's title) reports as well.
    try testing.expect((try codex.parseNotify(a, "{\"type\":\"agent-turn-complete\",\"thread-id\":\"title\"}", "thr")).kind == null);
    try testing.expect((try codex.parseNotify(a, "{\"type\":\"something-new\",\"thread-id\":\"thr\"}", "thr")).kind == null);
    try testing.expectError(error.InvalidHook, codex.parseNotify(a, "not json", "thr"));
}

test "codex: descriptor declares fork at_turn, context estimate and stable plan windows" {
    var cx = codex.Codex.init(testing.allocator);
    defer cx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const caps = (try cx.probe(arena.allocator())).caps;
    try testing.expectEqual(harness.contract.ForkLevel.at_turn, caps.fork);
    try testing.expectEqual(harness.contract.Context.estimate, caps.usage.context);
    try testing.expectEqual(harness.contract.PlanWindows.stable, caps.usage.plan_windows);
}

test "codex: plan windows, capped tool bodies and thread/fork over a fake app-server" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_fork_plan.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fx.host.options.body_max = 8;

    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
    try fx.host.send("a1", "two", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().turns == 2 and x.agent().state == .settled;
        }
    }.f);

    // Plan windows: the read, then the sparse update merged into it; the
    // other bucket's update changed nothing, so it logged nothing.
    var plans: std.ArrayList(std.json.ObjectMap) = .empty;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "plan_windows")) try plans.append(a, e.object.get("data").?.object);
    try testing.expectEqual(@as(usize, 2), plans.items.len);
    const first = plans.items[0];
    try testing.expectEqualStrings("codex", first.get("harness").?.string);
    try testing.expectEqualStrings("chatgpt", first.get("account").?.string);
    try testing.expectEqualStrings("subscription", first.get("billing").?.string);
    try testing.expectEqualStrings("stable", first.get("source").?.string);
    try testing.expectEqual(@as(i64, 31), first.get("windows").?.array.items[0].object.get("used_pct").?.integer);
    const merged = fx.engine.state.usage.plans.get("codex").?;
    try testing.expectEqual(@as(usize, 2), merged.windows.len);
    try testing.expectEqualStrings("primary", merged.windows[0].id);
    try testing.expectEqualStrings("5h", merged.windows[0].label);
    try testing.expectEqual(@as(u32, 40), merged.windows[0].used_pct);
    try testing.expectEqualStrings("2026-11-07T15:00:00Z", merged.windows[0].resets_at.?);
    try testing.expectEqualStrings("7d", merged.windows[1].label);
    try testing.expectEqual(@as(u32, 12), merged.windows[1].used_pct);
    try testing.expectEqualStrings("2026-11-12T09:00:00Z", merged.windows[1].resets_at.?);
    // The account's email never reaches the log.
    try testing.expect(std.mem.indexOf(u8, try readFile(a, fx.log_path), "someone@example.com") == null);

    // The context estimate still holds, and both bodies are capped at body_max.
    try testing.expectEqualStrings("estimate", (try fx.first(a, "context")).get("source").?.string);
    var bodies: std.ArrayList(std.json.ObjectMap) = .empty;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "tool.ended")) try bodies.append(a, e.object.get("data").?.object.get("body").?.object);
    try testing.expectEqual(@as(usize, 2), bodies.items.len);
    try testing.expectEqualStrings("01234567", bodies.items[0].get("text").?.string);
    try testing.expect(bodies.items[0].get("truncated").?.bool);
    try testing.expectEqual(@as(i64, 16), bodies.items[0].get("bytes").?.integer);
    try testing.expectEqualStrings("+one\n+tw", bodies.items[1].get("text").?.string);
    try testing.expectEqual(@as(i64, 10), bodies.items[1].get("bytes").?.integer);

    // Fork through t1 uses the harness's id for it, durable in the log.
    try testing.expectEqualStrings("turn_a", (try fx.first(a, "turn.started")).get("harness_turn").?.string);
    try expectForked("thr_at", try fx.fork(a, "t1"));
    try testing.expectError(error.NotFound, fx.host.fork(a, "a1", "t9"));
    // The new thread's events are not this agent's.
    try testing.expectEqual(@as(u32, 2), fx.agent().turns);
    try testing.expect(!fx.binding().conv.inTurn());
    // From the head; refused by the harness.
    try expectForked("thr_head", try fx.fork(a, null));
    try expectForkFailed("conflict.harness_fork_refused", try fx.fork(a, null));
    // A refused fork leaves the source agent alone.
    try testing.expectEqual(AgentState.settled, fx.agent().state);
    // No answer in time; the late answer does not leak into the next fork.
    fx.codex.fork_timeout_ms = 200;
    try expectForkFailed("timeout.harness_request", try fx.fork(a, null));
    try testing.expectEqual(AgentState.settled, fx.agent().state);
    fx.codex.fork_timeout_ms = 10_000;
    try expectForked("thr_ok", try fx.fork(a, null));

    const got = try readFile(a, try fx.dirPath(a, "received.0.jsonl"));
    var lines = std.mem.splitScalar(u8, got, '\n');
    var forks: u32 = 0;
    while (lines.next()) |line| if (std.mem.indexOf(u8, line, "thread/fork") != null) {
        forks += 1;
        // Only the first names a turn.
        try testing.expectEqual(forks == 1, std.mem.indexOf(u8, line, "lastTurnId") != null);
    };
    try testing.expectEqual(@as(u32, 5), forks);

    // An idle agent: the host starts a process, which re-opens the thread
    // before the fork. The same windows log nothing new.
    try fx.releaseIdle();
    try expectForked("thr_idle", try fx.fork(a, null));
    // The process started for the fork ends, and is not waited for.
    try fx.until(Fixture.gone);
    // One that crashes is not restarted.
    try expectForkFailed("failed.harness_exited", try fx.fork(a, null));
    try testing.expectEqual(harness.host.Status.idle, fx.binding().status);
    try fx.host.poll(5);
    try testing.expect(!fx.binding().running());
    var count: usize = 0;
    for (try fx.records(a)) |e| {
        if (std.mem.eql(u8, e.object.get("type").?.string, "plan_windows")) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("thr_f", fx.agent().harness_session.?);

    // An archived agent's worktree may be gone: no fork, and no process.
    _ = try fx.engine.submit(.{ .archive = .{ .agent = "a1" } });
    try fx.until(isState(.archived));
    try testing.expectError(error.InvalidTransition, fx.host.fork(a, "a1", null));
    try testing.expect(!fx.binding().running());
    try fx.host.retire("a1");
}

fn expectForked(thread: []const u8, effect: eventlog.decider.Effect) !void {
    try testing.expectEqualStrings(thread, effect.detail);
    try testing.expect(effect.ok);
}

fn expectForkFailed(code: []const u8, effect: eventlog.decider.Effect) !void {
    try testing.expectEqualStrings(code, effect.detail);
    try testing.expect(!effect.ok);
}

/// A settled agent's first process: `thr_f`, which has run one turn.
const one_turn =
    \\> {"method":"initialize","id":0}
    \\< {"id":0,"result":{"userAgent":"codex_cli_rs/0.167.0"}}
    \\> {"method":"initialized"}
    \\> {"method":"thread/start","id":1}
    \\< {"id":1,"result":{"thread":{"id":"thr_f"},"model":"gpt-5.5-codex"}}
    \\> {"method":"account/read","id":90}
    \\> {"method":"account/rateLimits/read","id":91}
    \\> {"method":"turn/start","id":2}
    \\< {"method":"turn/started","params":{"threadId":"thr_f","turn":{"id":"turn_a","status":"inProgress","items":[]}}}
    \\< {"method":"turn/completed","params":{"threadId":"thr_f","turn":{"id":"turn_a","status":"completed","error":null,"items":[]}}}
    \\
;

/// How the process started for an idle agent opens its thread.
const reopen =
    \\=== process
    \\> {"method":"initialize","id":0}
    \\< {"id":0,"result":{"userAgent":"codex_cli_rs/0.167.0"}}
    \\> {"method":"initialized"}
    \\> {"method":"thread/resume","id":1,"params":{"threadId":"thr_f"}}
    \\
;
const reopened =
    \\< {"id":1,"result":{"thread":{"id":"thr_f"},"model":"gpt-5.5-codex"}}
    \\> {"method":"account/read","id":90}
    \\> {"method":"account/rateLimits/read","id":91}
    \\
;

fn idleFixture(fx: *Fixture, comptime rest: []const u8) !void {
    try fx.init(one_turn ++ reopen ++ reopened ++ rest);
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
    try fx.releaseIdle();
}

test "codex: a fork the harness has not answered does not wait; its process ends afterwards" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try idleFixture(&fx,
        \\> {"method":"thread/fork","id":2,"params":{"threadId":"thr_f"}}
        \\? gate answer
        \\< {"id":2,"result":{"thread":{"id":"thr_new"}}}
        \\> {"method":"thread/unsubscribe","id":3,"params":{"threadId":"thr_new"}}
    );
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Back at once, with no process yet: the effect worker starts it.
    const key = try fx.host.fork(a, "a1", null);
    try testing.expect(!fx.binding().running());
    try fx.untilReceived(a, 1, "thread/fork");

    // Each run of the effect returns at once while there is no answer.
    const started = now();
    for (0..5) |_| {
        _ = try fx.engine.runEffects();
        try testing.expect(!fx.engine.state.effects.get(key).?.done);
    }
    try testing.expect(now() - started < 1_000);
    try testing.expect(fx.binding().running());
    // A second fork of the same agent is accepted and waits its turn.
    const next = try fx.host.fork(a, "a1", null);
    try testing.expectEqualStrings("fork:a1:2", next);

    try fx.openGate("answer");
    try expectForked("thr_new", try fx.forkDone(key));
    // While the process ends, a send would not reach it, and is refused.
    try testing.expect(fx.binding().running());
    try testing.expectEqual(harness.host.Status.stopping, fx.binding().status);
    try testing.expectError(error.TurnRunning, fx.host.send("a1", "too soon", .turn));
    // The next fork waits for it to go, then starts its own (none here: the
    // trace has no third process, so it never answers).
    fx.codex.fork_timeout_ms = 200;
    try expectForkFailed("timeout.harness_request", try fx.forkDone(next));
    try fx.until(Fixture.gone);
    try testing.expectEqual(@as(u32, 1), fx.agent().turns);
    try testing.expectEqual(AgentState.settled, fx.agent().state);
}

test "codex: a send during a fork keeps the process for its turn" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try idleFixture(&fx,
        \\> {"method":"thread/fork","id":2,"params":{"threadId":"thr_f"}}
        \\> {"method":"turn/start","id":3,"params":{"threadId":"thr_f"}}
        \\< {"method":"turn/started","params":{"threadId":"thr_f","turn":{"id":"turn_b","status":"inProgress","items":[]}}}
        \\< {"method":"turn/completed","params":{"threadId":"thr_f","turn":{"id":"turn_b","status":"completed","error":null,"items":[]}}}
        \\< {"id":2,"result":{"thread":{"id":"thr_new"}}}
        \\> {"method":"thread/unsubscribe","id":4,"params":{"threadId":"thr_new"}}
    );
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key = try fx.host.fork(a, "a1", null);
    try fx.untilReceived(a, 1, "thread/fork");
    try fx.host.send("a1", "two", .turn);
    try expectForked("thr_new", try fx.forkDone(key));
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().turns == 2 and x.agent().state == .settled;
        }
    }.f);
    try testing.expect(fx.binding().running());
    try testing.expectEqual(harness.host.Status.running, fx.binding().status);
}

test "codex: a send while the fork's process opens the thread goes first" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(one_turn ++ reopen ++
        \\? gate opened
        \\
    ++ reopened ++
        \\> {"method":"turn/start","id":2,"params":{"threadId":"thr_f"}}
        \\< {"method":"turn/started","params":{"threadId":"thr_f","turn":{"id":"turn_b","status":"inProgress","items":[]}}}
        \\< {"method":"turn/completed","params":{"threadId":"thr_f","turn":{"id":"turn_b","status":"completed","error":null,"items":[]}}}
    );
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
    try fx.releaseIdle();

    const key = try fx.host.fork(a, "a1", null);
    try fx.untilReceived(a, 1, "thread/resume");
    try fx.host.send("a1", "two", .turn);
    try fx.openGate("opened");
    try expectForkFailed("conflict.turn_running", try fx.forkDone(key));
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().turns == 2 and x.agent().state == .settled;
        }
    }.f);
    try testing.expect(fx.binding().running());
}

test "codex: a fork that is never answered times out and still ends its process" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try idleFixture(&fx,
        \\> {"method":"thread/fork","id":2,"params":{"threadId":"thr_f"}}
    );
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    fx.codex.fork_timeout_ms = 200;
    try expectForkFailed("timeout.harness_request", try fx.fork(arena.allocator(), null));
    try fx.until(Fixture.gone);
    try testing.expectEqual(AgentState.settled, fx.agent().state);
}

test "codex: an API key logs its billing with no windows" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(
        \\> {"method":"initialize","id":0}
        \\< {"id":0,"result":{"userAgent":"codex_cli_rs/0.167.0"}}
        \\> {"method":"initialized"}
        \\> {"method":"thread/start","id":1}
        \\< {"id":1,"result":{"thread":{"id":"thr_k"},"model":"gpt-5.5-codex"}}
        \\> {"method":"account/read","id":90}
        \\< {"id":90,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}
        \\> {"method":"account/rateLimits/read","id":91}
        \\< {"id":91,"error":{"code":-32600,"message":"rate limits need a ChatGPT sign-in"}}
        \\> {"method":"turn/start","id":2}
        \\< {"method":"turn/started","params":{"threadId":"thr_k","turn":{"id":"turn_a","status":"inProgress","items":[]}}}
        \\< {"method":"turn/completed","params":{"threadId":"thr_k","turn":{"id":"turn_a","status":"completed","error":null,"items":[]}}}
    );
    defer fx.deinit();
    try fx.host.send("a1", "go", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.engine.state.usage.plans.contains("codex") and x.agent().turns == 1 and x.agent().state == .settled;
        }
    }.f);
    const plan = fx.engine.state.usage.plans.get("codex").?;
    try testing.expectEqualStrings("apiKey", plan.account);
    try testing.expectEqualStrings("api_key", plan.billing);
    try testing.expectEqual(@as(usize, 0), plan.windows.len);
}

test "codex: a replayed usage total re-bases, before the first turn or inside it" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_resume_replay.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = [_][2]i64{ .{ 1000, 50 }, .{ 100, 10 }, .{ 40, 5 }, .{ 30, 3 } };
    for (want, 1..) |_, n| {
        try fx.host.send("a1", "go", .turn);
        const deadline = now() + 10_000;
        while (fx.agent().turns != n or fx.agent().state != .settled) {
            if (now() > deadline) return error.Timeout;
            try fx.host.poll(5);
            _ = try fx.engine.runEffects();
            fx.notePid();
        }
        if (n == want.len) break;
        _ = try fx.host.release("a1");
        try fx.until(struct {
            fn f(x: *Fixture) bool {
                return x.binding().status == .idle;
            }
        }.f);
    }
    var got: std.ArrayList(std.json.ObjectMap) = .empty;
    for (try fx.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, "usage")) try got.append(a, e.object.get("data").?.object);
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqual(w[0], g.get("tokens_in").?.integer);
        try testing.expectEqual(w[1], g.get("tokens_out").?.integer);
    }
}

test "codex: fork needs a conversation" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_fork_plan.trace"));
    defer fx.deinit();
    // Nothing was sent yet: there is no thread to copy, and no process starts.
    try testing.expectError(error.HarnessSessionNotFound, fx.host.fork(testing.allocator, "a1", null));
    try testing.expect(!fx.binding().running());
    try testing.expectError(error.NotFound, fx.host.fork(testing.allocator, "nobody", null));
}

test "codex e2e: spawn, a turn with an exec approval, settled (real codex, opt-in)" {
    const flag = c.getenv("VENOM_CODEX_E2E") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.sliceTo(flag, 0), "1")) return error.SkipZigTest;
    const status = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "codex", "login", "status" } }) catch return error.SkipZigTest;
    testing.allocator.free(status.stdout);
    testing.allocator.free(status.stderr);
    if (status.term != .exited or status.term.exited != 0) return error.SkipZigTest;

    var fx: Fixture = undefined;
    try fx.init("");
    defer fx.deinit();
    fx.codex.argv = &.{ "codex", "app-server" };
    // `untrusted`: every command that is not known-safe asks first.
    fx.codex.approval_policy = "untrusted";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Run exactly this shell command and nothing else: touch venom-e2e.txt. Then reply done.", .turn);
    const deadline = now() + 180_000;
    var answered: usize = 0;
    while (fx.agent().state != .settled and fx.agent().state != .failed) {
        if (now() > deadline) return error.Timeout;
        try fx.host.poll(20);
        _ = try fx.engine.runEffects();
        fx.notePid();
        const reqs = fx.agent().requests.items;
        if (fx.agent().state == .needs_you and reqs.len > answered) {
            _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = reqs[reqs.len - 1].request, .decision = "allow_once" } });
            answered += 1;
        }
    }
    try testing.expectEqual(AgentState.settled, fx.agent().state);
    try testing.expect(answered >= 1);
    try testing.expect(fx.agent().harness_session != null);
    const types = try fx.types(a);
    var tool = false;
    var usage = false;
    for (types) |t| {
        if (std.mem.eql(u8, t, "tool.ended")) tool = true;
        if (std.mem.eql(u8, t, "usage")) usage = true;
    }
    try testing.expect(tool and usage);
}

test "codex: an approval's input is the whole item, so a changed patch or command is another call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: std.mem.Allocator, text: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, text, .{});
        }
    }.f;
    const input = struct {
        fn f(al: std.mem.Allocator, item: []const u8, params: []const u8) ![]const u8 {
            const whole = try harness.codex.itemInput(al, try parse(al, item));
            return eventlog.events.inputDigest(al, (try harness.codex.approvalInput(al, whole, try parse(al, params))).?);
        }
    }.f;
    const one = "{\"type\":\"fileChange\",\"id\":\"i1\",\"changes\":[{\"path\":\"a\",\"diff\":\"+1\"}]}";
    const params = "{\"itemId\":\"i1\",\"threadId\":\"x\"}";
    const base = try input(a, one, params);
    // Ids are not the call.
    try testing.expectEqualStrings(base, try input(a, "{\"type\":\"fileChange\",\"id\":\"i9\",\"status\":\"x\",\"changes\":[{\"path\":\"a\",\"diff\":\"+1\"}]}", "{\"itemId\":\"i9\",\"threadId\":\"y\"}"));
    // Another diff, another file beyond the first, more write access.
    try testing.expect(!std.mem.eql(u8, base, try input(a, "{\"type\":\"fileChange\",\"id\":\"i1\",\"changes\":[{\"path\":\"a\",\"diff\":\"+2\"}]}", params)));
    try testing.expect(!std.mem.eql(u8, base, try input(a, "{\"type\":\"fileChange\",\"id\":\"i1\",\"changes\":[{\"path\":\"a\",\"diff\":\"+1\"},{\"path\":\"b\",\"diff\":\"+1\"}]}", params)));
    try testing.expect(!std.mem.eql(u8, base, try input(a, one, "{\"itemId\":\"i1\",\"grantRoot\":\"/\"}")));
    // Commands: the text and where it runs.
    const cmd = try input(a, "{\"type\":\"commandExecution\",\"id\":\"i1\",\"command\":\"make\",\"cwd\":\"/w\"}", params);
    try testing.expect(!std.mem.eql(u8, cmd, try input(a, "{\"type\":\"commandExecution\",\"id\":\"i1\",\"command\":\"make\",\"cwd\":\"/x\"}", params)));
    // Not known: no input, so never auto-answered.
    try testing.expect((try harness.codex.itemInput(a, try parse(a, "{\"type\":\"fileChange\",\"id\":\"i1\"}"))) == null);
    try testing.expect((try harness.codex.itemInput(a, try parse(a, "{\"type\":\"fileChange\",\"id\":\"i1\",\"changes\":[]}"))) == null);
    try testing.expect((try harness.codex.itemInput(a, try parse(a, "{\"type\":\"mcpToolCall\",\"id\":\"i1\"}"))) == null);
    try testing.expect((try harness.codex.approvalInput(a, null, try parse(a, params))) == null);
}

test "codex: compact runs through thread/compact/start, once the thread is open" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_compact.trace"));
    defer fx.deinit();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
    try testing.expectEqual(@as(u32, 1), fx.agent().turns);
    try fx.host.compact("a1");
    try fx.until(struct {
        fn done(f: *Fixture) bool {
            return f.agent().turns == 2 and f.agent().state == .settled;
        }
    }.done);
    // Codex has no `mcp_off` yet: the panel does not offer it, and the host refuses.
    try testing.expect(!fx.host.capsOf("a1").?.mcp_off);
    try testing.expect(fx.host.capsOf("a1").?.compact);
    try testing.expectError(error.UnsupportedCapability, fx.host.mcpOff("a1", &.{"docs"}));
}

test "codex: tool items and approvals in several turns of one process" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_two_turns.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.needs_you));
    const first = try a.dupe(u8, fx.agent().requests.items[0].input_digest.?);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.until(isState(.settled));

    // The same command in a later turn, under another item id, is the same call.
    try fx.host.send("a1", "two", .turn);
    try fx.until(isState(.needs_you));
    try testing.expectEqualStrings(first, fx.agent().requests.items[0].input_digest.?);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "allow_once" } });
    try fx.until(isState(.settled));

    // An item of an earlier turn is forgotten: no input, so no key.
    try fx.host.send("a1", "three", .turn);
    try fx.until(isState(.needs_you));
    try testing.expect(fx.agent().requests.items[0].input_digest == null);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r3", .decision = "deny" } });
    try fx.until(isState(.settled));
    try testing.expectEqual(@as(u32, 3), fx.agent().turns);
}

test "codex: a crash with an approval pending, answered, resumes and answers the re-asked command" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(@embedFile("testdata/codex_stale_resume.trace"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.failed));
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
    try testing.expect(fx.agent().requests.items[0].stale);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("completed", lastEnded(&fx).reason);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    // No needs_you in the second turn: the trace checks codex got `accept`.
    try expectStrings(&.{ "queued>running", "running>needs_you", "needs_you>running", "running>failed", "failed>running", "running>settled" }, try fx.transitions(a));
}
