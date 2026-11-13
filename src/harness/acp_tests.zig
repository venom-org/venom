//! The ACP adapter driving real agents through the host and the durable event
//! log, against a fake ACP agent
//! (`testdata/acp_agent.py`) that replays hand-written JSON-RPC traces. Every
//! test ends with no child process left.
const std = @import("std");
const eventlog = @import("../eventlog/root.zig");
const harness = @import("root.zig");
const acp = @import("acp.zig");
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
    acp: acp.Acp,
    adapters: [1]harness.host.Registered,
    host: Host,
    pids: std.ArrayList(c.pid_t) = .empty,

    fn init(self: *Fixture, trace: []const u8) !void {
        return self.initScoped(trace, &.{});
    }

    /// `repos`: the agent's scope, in a workspace of `a` and `c`.
    fn initScoped(self: *Fixture, trace: []const u8, repos: []const []const u8) !void {
        self.pids = .empty;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "acp_agent.py", .data = @embedFile("testdata/acp_agent.py") });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "acp.trace", .data = trace });
        self.script = try std.fmt.allocPrint(testing.allocator, "{s}/acp_agent.py", .{self.dir});
        errdefer testing.allocator.free(self.script);
        self.trace = try std.fmt.allocPrint(testing.allocator, "{s}/acp.trace", .{self.dir});
        errdefer testing.allocator.free(self.trace);
        self.log_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/events.log", .{self.dir}, 0);
        errdefer testing.allocator.free(self.log_path);
        self.argv = .{ "python3", self.script, self.trace, self.dir, self.dir };
        try self.boot();
        if (repos.len > 0) _ = try self.engine.submit(.{ .workspace_add = .{ .path = self.dir, .repos = &.{ "a", "c" } } });
        _ = try self.engine.submit(.{ .create = .{ .agent = "a1", .title = "Run the tests", .harness = acp.name, .workspace = self.dir, .repos = repos } });
    }

    /// A daemon start: a new engine replaying the log, a new adapter and host.
    fn boot(self: *Fixture) !void {
        self.engine = try Engine.open(testing.allocator, self.log_path, .{});
        errdefer self.engine.deinit();
        self.acp = .init(testing.allocator, &self.argv);
        self.adapters = .{.{ .harness = acp.name, .adapter = self.acp.adapter() }};
        self.host = Host.init(testing.allocator, &self.engine, &self.adapters, .{ .shutdown_grace_ms = 500, .policy = .{ .initial_ms = 60_000, .max_ms = 60_000, .reset_after_ms = 60_000, .max_failures = 5 } });
        self.engine.options.executors = self.host.executor();
        try self.engine.start();
    }

    /// A daemon stop, with no process left.
    fn halt(self: *Fixture) void {
        self.host.deinit();
        for (self.pids.items) |pid| {
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("an agent process outlived the host");
        }
        self.pids.clearRetainingCapacity();
        self.acp.deinit();
        self.engine.deinit();
    }

    fn restart(self: *Fixture) !void {
        self.halt();
        try self.boot();
    }

    fn deinit(self: *Fixture) void {
        self.halt();
        self.pids.deinit(testing.allocator);
        testing.allocator.free(self.log_path);
        testing.allocator.free(self.trace);
        testing.allocator.free(self.script);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn agent(self: *Fixture) eventlog.decider.Agent {
        return self.engine.state.agents.get("a1").?;
    }
    fn binding(self: *Fixture) *harness.host.Binding {
        return self.host.binding("a1").?;
    }

    /// One reactor turn.
    fn step(self: *Fixture) !void {
        try self.host.poll(5);
        _ = try self.engine.runEffects();
        const b = self.host.binding("a1") orelse return;
        const p = b.process orelse return;
        for (self.pids.items) |pid| if (pid == p.pid()) return;
        try self.pids.append(testing.allocator, p.pid());
    }

    /// Runs reactor turns until `done` or 10 s.
    fn until(self: *Fixture, comptime done: fn (*Fixture) bool) !void {
        const deadline = now() + 10_000;
        while (!done(self)) {
            if (now() > deadline) return self.timedOut();
            try self.step();
        }
    }

    fn timedOut(self: *Fixture) error{Timeout} {
        if (self.host.binding("a1")) |b| if (b.process) |*p| std.debug.print("fake agent stderr: {s}\n", .{p.stderrTail()});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const got = std.fmt.allocPrintSentinel(arena.allocator(), "{s}/received.0.jsonl", .{self.dir}, 0) catch return error.Timeout;
        if (readFile(arena.allocator(), got)) |bytes| std.debug.print("venom wrote:\n{s}\n", .{bytes}) else |_| {}
        return error.Timeout;
    }

    fn openGate(self: *Fixture, name: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }

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

    /// The `data` of every logged event of type `t`.
    fn all(self: *Fixture, a: std.mem.Allocator, t: []const u8) ![]const std.json.ObjectMap {
        var out: std.ArrayList(std.json.ObjectMap) = .empty;
        for (try self.records(a)) |e| if (std.mem.eql(u8, e.object.get("type").?.string, t)) try out.append(a, e.object.get("data").?.object);
        return out.items;
    }

    fn lastEnded(self: *Fixture) eventlog.events.TurnEnded {
        const t = self.agent().transcript.items;
        var i = t.len;
        while (i > 0) {
            i -= 1;
            if (t[i] == .turn_ended) return t[i].turn_ended;
        }
        @panic("no turn ended");
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

fn inTurn(fx: *Fixture) bool {
    const b = fx.host.binding("a1") orelse return false;
    return b.conv.inTurn();
}

fn gone(fx: *Fixture) bool {
    const b = fx.host.binding("a1") orelse return false;
    return !b.running();
}

fn hasPython() bool {
    const r = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "python3", "-c", "" } }) catch return false;
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

// A handshake: what `initialize` answers decides the rest.
const hello = "> {\"method\":\"initialize\",\"id\":0,\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false},\"clientInfo\":{\"name\":\"venom\"}}}\n";
const answer_loads = "< {\"id\":0,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true},\"agentInfo\":{\"name\":\"fake\",\"version\":\"1.2.3\"},\"authMethods\":[]}}\n";
const answer_bare = "< {\"id\":0,\"result\":{\"protocolVersion\":1}}\n";
const new_session = "> {\"method\":\"session/new\",\"id\":1,\"params\":{\"cwd\":\"$CWD\",\"mcpServers\":[]}}\n< {\"id\":1,\"result\":{\"sessionId\":\"sess_1\"}}\n";
const open_loads = hello ++ answer_loads ++ new_session;

fn update(comptime body: []const u8) []const u8 {
    return "< {\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess_1\",\"update\":" ++ body ++ "}}\n";
}
fn ended(comptime stop: []const u8) []const u8 {
    return "< {\"id\":2,\"result\":{\"stopReason\":\"" ++ stop ++ "\"}}\n";
}
fn prompt(comptime text: []const u8) []const u8 {
    return "> {\"method\":\"session/prompt\",\"id\":2,\"params\":{\"sessionId\":\"sess_1\",\"prompt\":[{\"type\":\"text\",\"text\":\"" ++ text ++ "\"}]}}\n";
}
const options = "[{\"optionId\":\"once\",\"name\":\"Allow\",\"kind\":\"allow_once\"},{\"optionId\":\"always\",\"name\":\"Always\",\"kind\":\"allow_always\"},{\"optionId\":\"no\",\"name\":\"Reject\",\"kind\":\"reject_once\"},{\"optionId\":\"never\",\"name\":\"Never\",\"kind\":\"reject_always\"}]";
fn asks(comptime id: []const u8, comptime call: []const u8) []const u8 {
    return "< {\"id\":" ++ id ++ ",\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"sess_1\",\"toolCall\":" ++ call ++ ",\"options\":" ++ options ++ "}}\n";
}
fn picks(comptime id: []const u8, comptime option: []const u8) []const u8 {
    return "> {\"id\":" ++ id ++ ",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"" ++ option ++ "\"}}}\n";
}

test "acp: start, send, text, a tool call and a plan; capabilities come from initialize" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("Run the tests") ++
        update("{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[]}") ++
        update("{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hmm\"}}") ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"I'll run \"}}") ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"them.\"}}") ++
        update("{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"Run\",\"priority\":\"high\",\"status\":\"in_progress\"},{\"content\":\"Fix\",\"priority\":\"low\",\"status\":\"pending\"}]}") ++
        update("{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"Run\",\"priority\":\"high\",\"status\":\"in_progress\"},{\"content\":\"Fix\",\"priority\":\"low\",\"status\":\"pending\"}]}") ++
        update("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"Run the tests\",\"kind\":\"execute\",\"status\":\"pending\"}") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"rawInput\":{\"command\":\"zig build test\"}}") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"in_progress\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"12 \"}}]}") ++
        "? gate tail\n" ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"12 passed\"}}]}") ++
        update("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t2\",\"title\":\"Edit it\",\"kind\":\"edit\",\"status\":\"completed\",\"locations\":[{\"path\":\"$CWD/x.zig\"}],\"content\":[{\"type\":\"diff\",\"path\":\"$CWD/x.zig\",\"oldText\":\"a\",\"newText\":\"b\"}]}") ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":\"m1\",\"content\":{\"type\":\"text\",\"text\":\"First.\"}}") ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":\"m2\",\"content\":{\"type\":\"text\",\"text\":\"Second.\"}}") ++
        update("{\"sessionUpdate\":\"usage_update\",\"used\":1200,\"size\":200000}") ++
        update("{\"sessionUpdate\":\"some_future_update\"}") ++
        "! raw this is not json\n" ++
        ended("end_turn"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Most restrictive until the agent has said.
    try testing.expect(!fx.acp.caps().release);
    try fx.host.send("a1", "Run the tests", .turn);
    try testing.expect(!fx.binding().descriptor.caps.release);
    try testing.expectError(error.UnsupportedCapability, fx.host.send("a1", "steer", .steer));
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            const tail = x.host.toolTail("a1", "c1") orelse return false;
            return std.mem.eql(u8, tail, "12 ");
        }
    }.f);
    try testing.expectEqualStrings("sess_1", fx.agent().harness_session.?);
    const d = fx.binding().descriptor;
    try testing.expect(d.valid());
    try testing.expect(d.caps.release);
    try testing.expect(d.caps.interrupt);
    try testing.expect(!d.caps.resume_tui);
    try testing.expectEqual(harness.contract.Steer.queue, d.caps.steer);
    try testing.expectEqualStrings("1.2.3", d.harness_version.?);
    try fx.openGate("tail");
    try fx.until(isState(.settled));

    try expectStrings(&.{ "agent.binding", "turn.started", "turn.prompt", "text", "text", "tool.started", "tool.ended", "tool.started", "tool.ended", "text", "context", "text", "turn.ended" }, try fx.types(a));
    const texts = try fx.all(a, "text");
    try testing.expectEqualStrings("I'll run them.", texts[0].get("text").?.string);
    try testing.expectEqualStrings("Plan:\n[~] Run\n[ ] Fix", texts[1].get("text").?.string);
    try testing.expectEqualStrings("First.", texts[2].get("text").?.string);
    try testing.expectEqualStrings("Second.", texts[3].get("text").?.string);
    try testing.expectEqualStrings("Run the tests", (try fx.all(a, "turn.prompt"))[0].get("text").?.string);
    const started = try fx.all(a, "tool.started");
    try testing.expectEqualStrings("exec", started[0].get("kind").?.string);
    try testing.expectEqualStrings("zig build test", started[0].get("title").?.string);
    try testing.expectEqualStrings("zig build test", started[0].get("args").?.object.get("command").?.string);
    try testing.expectEqualStrings("execute", started[0].get("name").?.string);
    try testing.expectEqualStrings("t1", started[0].get("harness_ref").?.string);
    try testing.expectEqualStrings("edit", started[1].get("kind").?.string);
    const toolEnds = try fx.all(a, "tool.ended");
    try testing.expectEqualStrings("ok", toolEnds[0].get("status").?.string);
    try testing.expectEqualStrings("12 passed", toolEnds[0].get("body").?.object.get("text").?.string);
    try testing.expect(std.mem.indexOf(u8, toolEnds[1].get("body").?.object.get("text").?.string, "-a\n+b\n") != null);
    const context = (try fx.all(a, "context"))[0];
    try testing.expectEqual(@as(i64, 1200), context.get("used").?.integer);
    try testing.expectEqualStrings("exact", context.get("source").?.string);
    try testing.expectEqualStrings("completed", fx.lastEnded().reason);
    try testing.expect(fx.binding().running());
}

test "acp: a send during a turn waits for the next one; a second prompt follows the first's end" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("one") ++ "? gate go\n" ++ ended("end_turn") ++ prompt("two") ++ ended("end_turn"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.host.send("a1", "one", .turn);
    try fx.until(inTurn);
    try fx.host.send("a1", "two", .turn);
    try fx.openGate("go");
    const deadline = now() + 10_000;
    while (fx.agent().turns < 2 or fx.agent().state != .settled) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    const prompts = try fx.all(a, "turn.prompt");
    try testing.expectEqual(@as(usize, 2), prompts.len);
    try testing.expectEqualStrings("t1", prompts[0].get("turn").?.string);
    try testing.expectEqualStrings("one", prompts[0].get("text").?.string);
    try testing.expectEqualStrings("t2", prompts[1].get("turn").?.string);
    try testing.expectEqualStrings("two", prompts[1].get("text").?.string);
}

test "acp: approve, always, reject, and a request that says more than its logged call" {
    if (!hasPython()) return error.SkipZigTest;
    const call = "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"";
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("go") ++
        // allow_once.
        update(call ++ "t1\",\"title\":\"Build\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"ls -l\"}}") ++
        asks("50", "{\"toolCallId\":\"t1\"}") ++ picks("50", "once") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\"}") ++
        // allow_always selects the agent's allow_once: the grant is venom's.
        update(call ++ "t2\",\"title\":\"Build\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"zig build\"}}") ++
        asks("51", "{\"toolCallId\":\"t2\"}") ++ picks("51", "once") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t2\",\"status\":\"completed\"}") ++
        // The standing grant answers this one, with no attention.
        update(call ++ "t3\",\"title\":\"Build\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"zig build test\"}}") ++
        asks("52", "{\"toolCallId\":\"t3\"}") ++ picks("52", "once") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t3\",\"status\":\"completed\"}") ++
        // Logged as a call the grant covers, asked as another: a person decides.
        update(call ++ "t4\",\"title\":\"Build\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"zig version\"}}") ++
        asks("53", "{\"toolCallId\":\"t4\",\"rawInput\":{\"command\":\"rm -rf /\"}}") ++ picks("53", "no") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t4\",\"status\":\"failed\"}") ++
        // A call that can't be named can be allowed once, not always.
        asks("54", "{\"toolCallId\":\"t5\",\"title\":\"Do a thing\",\"kind\":\"other\"}") ++ picks("54", "once") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t5\",\"status\":\"completed\"}") ++
        ended("end_turn"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    try testing.expectEqualStrings("c1", fx.agent().requests.items[0].call.?);
    try testing.expect(fx.agent().requests.items[0].input_digest != null);
    try expectStrings(&.{ "allow_once", "allow_always", "deny", "cancel_turn" }, fx.agent().requests.items[0].answers);
    // ACP can't change a call on approval.
    try testing.expectError(error.InvalidCommand, fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_edited" } }));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });

    const waitFor = struct {
        fn f(x: *Fixture, id: []const u8) !void {
            const deadline = now() + 10_000;
            while (true) {
                for (x.agent().requests.items) |r| if (std.mem.eql(u8, r.request, id)) return;
                if (now() > deadline) return x.timedOut();
                try x.step();
            }
        }
    }.f;
    try waitFor(&fx, "r2");
    try testing.expectEqualStrings("exec:zig", fx.agent().requests.items[0].grant.?);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "allow_always" } });

    // r3 is answered from the grant; r4 is not, though it logged as `zig`.
    try waitFor(&fx, "r4");
    const r4 = fx.agent().requests.items[0];
    try testing.expect(r4.call == null);
    try testing.expect(r4.grant == null);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r4", .decision = "deny", .reason = "no" } });

    try waitFor(&fx, "r5");
    try expectStrings(&.{ "allow_once", "deny", "cancel_turn" }, fx.agent().requests.items[0].answers);
    try testing.expectError(error.InvalidCommand, fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r5", .decision = "allow_always" } }));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r5", .decision = "allow_once" } });
    try fx.until(isState(.settled));

    const toolEnds = try fx.all(a, "tool.ended");
    try testing.expectEqualStrings("ok", toolEnds[2].get("status").?.string);
    try testing.expectEqualStrings("declined", toolEnds[3].get("status").?.string);
    const started = try fx.all(a, "tool.started");
    try testing.expect(std.mem.endsWith(u8, started[4].get("title").?.string, "\u{2026}"));
    try testing.expectEqualStrings("completed", fx.lastEnded().reason);
    try testing.expectEqual(@as(usize, 1), (try fx.all(a, "always.granted")).len);
}

test "acp: an agent offering only allow_always, and one with no reject option" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("go") ++
        "< {\"id\":50,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"sess_1\",\"toolCall\":{\"toolCallId\":\"t1\",\"title\":\"x\",\"kind\":\"other\"},\"options\":[{\"optionId\":\"forever\",\"name\":\"Yes\",\"kind\":\"allow_always\"}]}}\n" ++
        picks("50", "forever") ++
        "< {\"id\":51,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"sess_1\",\"toolCall\":{\"toolCallId\":\"t2\",\"title\":\"y\",\"kind\":\"other\"},\"options\":[{\"optionId\":\"forever\",\"name\":\"Yes\",\"kind\":\"allow_always\"}]}}\n" ++
        // Deny with nothing to select: the turn is cancelled, the call never runs.
        "> {\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_1\"}}\n" ++
        "> {\"id\":51,\"result\":{\"outcome\":{\"outcome\":\"cancelled\"}}}\n" ++
        ended("cancelled"));
    defer fx.deinit();
    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    try expectStrings(&.{ "allow_always", "deny", "cancel_turn" }, fx.agent().requests.items[0].answers);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_always" } });
    const deadline = now() + 10_000;
    while (fx.agent().raised < 2 or fx.agent().state != .needs_you) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "deny" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", fx.lastEnded().reason);
}

test "acp: interrupt cancels the turn and answers pending requests; the conversation goes on" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("one") ++
        update("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"x\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"make\"}}") ++
        asks("50", "{\"toolCallId\":\"t1\"}") ++
        "> {\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_1\"}}\n" ++
        "> {\"id\":50,\"result\":{\"outcome\":{\"outcome\":\"cancelled\"}}}\n" ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Stopped.\"}}") ++
        ended("cancelled") ++ prompt("two") ++ ended("end_turn"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.needs_you));
    try fx.host.interrupt("a1");
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", fx.lastEnded().reason);
    try testing.expectEqualStrings("interrupted", (try fx.all(a, "tool.ended"))[0].get("status").?.string);
    try testing.expectEqualStrings("Stopped.", (try fx.all(a, "text"))[0].get("text").?.string);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);

    try fx.host.send("a1", "two", .turn);
    const deadline = now() + 10_000;
    while (fx.agent().turns < 2 or fx.agent().state != .settled) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    try testing.expectEqualStrings("completed", fx.lastEnded().reason);
}

test "acp: stop, with and without a pending request; a process ending ends the turn" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("one") ++
        "> {\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_1\"}}\n" ++ ended("cancelled") ++
        prompt("two") ++
        update("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"x\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"make\"}}") ++
        asks("50", "{\"toolCallId\":\"t1\"}") ++
        "> {\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_1\"}}\n" ++
        "> {\"id\":50,\"result\":{\"outcome\":{\"outcome\":\"cancelled\"}}}\n" ++
        ended("cancelled") ++ prompt("three") ++ "! exit 3\n");
    defer fx.deinit();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.running));
    _ = try fx.engine.submit(.{ .stop = .{ .agent = "a1" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", fx.lastEnded().reason);

    try fx.host.send("a1", "two", .turn);
    try fx.until(isState(.needs_you));
    _ = try fx.engine.submit(.{ .stop = .{ .agent = "a1" } });
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("interrupted", fx.lastEnded().reason);

    try fx.host.send("a1", "three", .turn);
    try fx.until(isState(.failed));
    try testing.expectEqualStrings("failed.harness_exited", fx.lastEnded().error_code.?);
}

test "acp: reattach after a daemon restart: session/load, its replay dropped" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("one") ++ ended("end_turn") ++
        "=== process\n" ++ hello ++ answer_loads ++
        "> {\"method\":\"session/load\",\"id\":1,\"params\":{\"sessionId\":\"sess_1\",\"cwd\":\"$CWD\",\"mcpServers\":[]}}\n" ++
        update("{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"one\"}}") ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"An old answer.\"}}") ++
        update("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"x\",\"kind\":\"read\",\"status\":\"completed\"}") ++
        update("{\"sessionUpdate\":\"usage_update\",\"used\":1,\"size\":2}") ++
        "< {\"id\":1,\"result\":{}}\n" ++
        prompt("two") ++
        update("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"New.\"}}") ++
        ended("end_turn"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));

    try fx.restart();
    try testing.expectEqualStrings("sess_1", fx.agent().harness_session.?);
    try fx.host.send("a1", "two", .turn);
    const deadline = now() + 10_000;
    while (fx.agent().turns < 2 or fx.agent().state != .settled) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    try testing.expectEqualStrings("t2", fx.lastEnded().turn);
    try expectStrings(&.{ "agent.binding", "turn.started", "turn.prompt", "turn.ended", "agent.binding", "turn.started", "turn.prompt", "text", "turn.ended" }, try fx.types(a));
    try testing.expectEqualStrings("New.", (try fx.all(a, "text"))[0].get("text").?.string);
    try testing.expectEqualStrings("sess_1", (try fx.all(a, "agent.binding"))[1].get("harness_session").?.string);
}

test "acp: reattach prefers session/resume, and a load the agent refuses is not_found" {
    if (!hasPython()) return error.SkipZigTest;
    const resumes = "< {\"id\":0,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true,\"sessionCapabilities\":{\"resume\":{}}}}}\n";
    var fx: Fixture = undefined;
    try fx.init(comptime hello ++ resumes ++ new_session ++ prompt("one") ++ ended("end_turn") ++
        "=== process\n" ++ hello ++ resumes ++
        "> {\"method\":\"session/resume\",\"id\":1,\"params\":{\"sessionId\":\"sess_1\",\"cwd\":\"$CWD\"}}\n" ++
        "< {\"id\":1,\"error\":{\"code\":-32002,\"message\":\"no such session\"}}\n");
    defer fx.deinit();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
    try testing.expect(fx.binding().descriptor.caps.release);
    _ = try fx.host.release("a1");
    try fx.until(gone);
    try fx.host.send("a1", "two", .turn);
    try fx.until(isState(.failed));
    try testing.expectEqualStrings("not_found.harness_session", fx.lastEnded().error_code.?);
}

test "acp: without loadSession the conversation lasts as long as its process, and is never replaced" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime hello ++ answer_bare ++ new_session ++ prompt("one") ++ ended("end_turn") ++
        "=== process\n" ++ hello ++ answer_bare ++
        "=== process\n" ++ hello ++ answer_bare);
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
    try testing.expect(!fx.binding().descriptor.caps.release);
    try testing.expectError(error.UnsupportedCapability, fx.host.release("a1"));

    try fx.restart();
    try fx.host.send("a1", "two", .turn);
    try fx.until(isState(.failed));
    try testing.expectEqualStrings("unsupported.harness_capability", fx.lastEnded().error_code.?);
    // The prompt is kept, the session id too: no `session/new` was sent.
    try testing.expectEqualStrings("two", (try fx.all(a, "turn.prompt"))[1].get("text").?.string);
    try testing.expectEqualStrings("sess_1", fx.agent().harness_session.?);
    try fx.until(gone);
    // A retry fails the same way, and nothing restarts on its own.
    try testing.expectEqualStrings("idle", @tagName(fx.binding().status));
    try fx.host.retry("a1");
    const deadline = now() + 10_000;
    while (fx.agent().turns < 3 or fx.agent().state != .failed) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    try testing.expectEqualStrings("unsupported.harness_capability", fx.lastEnded().error_code.?);
}

test "acp: a stale approval after a crash: reattach, and the re-asked call is answered from the decision" {
    if (!hasPython()) return error.SkipZigTest;
    const call = "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"x\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"make\"}}";
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("one") ++ update(call) ++ asks("50", "{\"toolCallId\":\"t1\"}") ++ "! exit 3\n" ++
        "=== process\n" ++ hello ++ answer_loads ++
        "> {\"method\":\"session/load\",\"id\":1,\"params\":{\"sessionId\":\"sess_1\"}}\n< {\"id\":1,\"result\":{}}\n" ++
        prompt("Continue from where you stopped.") ++ update(call) ++ asks("51", "{\"toolCallId\":\"t1\"}") ++ picks("51", "once") ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\"}") ++ ended("end_turn"));
    defer fx.deinit();
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.failed));
    try testing.expect(fx.agent().requests.items[0].stale);
    try fx.restart();
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    const deadline = now() + 10_000;
    while (fx.agent().turns < 2 or fx.agent().state != .settled) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    try testing.expectEqualStrings("completed", fx.lastEnded().reason);
}

test "acp: stop reasons and errors end the turn as the mapping says" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("a") ++ ended("max_tokens") ++ prompt("b") ++ ended("max_turn_requests") ++ prompt("c") ++ ended("refusal") ++ prompt("d") ++ ended("a_new_reason") ++
        prompt("e") ++ "< {\"id\":2,\"error\":{\"code\":-32603,\"message\":\"boom\"}}\n" ++
        prompt("f") ++ "< {\"id\":2,\"error\":{\"code\":-32000,\"message\":\"auth_required\"}}\n");
    defer fx.deinit();
    const Want = struct { text: []const u8, reason: []const u8, code: ?[]const u8 };
    for ([_]Want{
        .{ .text = "a", .reason = "failed", .code = "failed.harness_turn" },
        .{ .text = "b", .reason = "failed", .code = "failed.harness_turn" },
        .{ .text = "c", .reason = "failed", .code = "failed.harness_turn" },
        .{ .text = "d", .reason = "completed", .code = null },
        .{ .text = "e", .reason = "failed", .code = "failed.harness_turn" },
        .{ .text = "f", .reason = "failed", .code = "unavailable.harness_not_signed_in" },
    }, 1..) |w, n| {
        try fx.host.send("a1", w.text, .turn);
        const deadline = now() + 10_000;
        while (fx.agent().turns < n or fx.agent().open_turn != null) {
            if (now() > deadline) return fx.timedOut();
            try fx.step();
        }
        const end = fx.lastEnded();
        try testing.expectEqualStrings(w.reason, end.reason);
        if (w.code) |code| try testing.expectEqualStrings(code, end.error_code.?) else try testing.expect(end.error_code == null);
    }
}

test "acp: a protocol version venom does not speak, and an agent that wants a sign-in" {
    if (!hasPython()) return error.SkipZigTest;
    {
        var fx: Fixture = undefined;
        try fx.init(comptime hello ++ "< {\"id\":0,\"result\":{\"protocolVersion\":2}}\n");
        defer fx.deinit();
        try fx.host.send("a1", "one", .turn);
        try fx.until(isState(.failed));
        try testing.expectEqualStrings("unsupported.harness_version", fx.lastEnded().error_code.?);
    }
    {
        var fx: Fixture = undefined;
        try fx.init(comptime hello ++ answer_loads ++ "> {\"method\":\"session/new\",\"id\":1}\n< {\"id\":1,\"error\":{\"code\":-32000,\"message\":\"auth_required\"}}\n");
        defer fx.deinit();
        try fx.host.send("a1", "one", .turn);
        try fx.until(isState(.failed));
        try testing.expectEqualStrings("unavailable.harness_not_signed_in", fx.lastEnded().error_code.?);
    }
}

test "acp: what venom does not serve gets an error, a withdrawn request closes, and it never answers for a person" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime open_loads ++ prompt("go") ++
        "< {\"id\":40,\"method\":\"fs/read_text_file\",\"params\":{\"sessionId\":\"sess_1\",\"path\":\"/etc/passwd\"}}\n" ++
        "> {\"id\":40,\"error\":{\"code\":-32601}}\n" ++
        "< {\"id\":\"str-41\",\"method\":\"terminal/create\",\"params\":{\"sessionId\":\"sess_1\",\"command\":\"ls\"}}\n" ++
        "> {\"id\":\"str-41\",\"error\":{\"code\":-32601}}\n" ++
        asks("\"str-50\"", "{\"toolCallId\":\"t1\",\"title\":\"x\",\"kind\":\"other\"}") ++
        "? gate withdraw\n" ++
        "< {\"method\":\"$/cancel_request\",\"params\":{\"requestId\":\"str-50\"}}\n" ++
        "> {\"id\":\"str-50\",\"error\":{\"code\":-32800}}\n" ++
        update("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"failed\"}") ++
        ended("end_turn"));
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    try fx.openGate("withdraw");
    try fx.until(isState(.settled));
    try testing.expectEqualStrings("harness", (try fx.all(a, "request.resolved"))[0].get("by").?.string);
    try testing.expectEqualStrings("error", (try fx.all(a, "tool.ended"))[0].get("status").?.string);
}

test "acp: no call holds the reactor while the agent says nothing" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    // It reads each line and answers only when the test lets it.
    try fx.init(comptime hello ++ "? gate init\n" ++ answer_loads ++
        "> {\"method\":\"session/new\",\"id\":1}\n? gate new\n< {\"id\":1,\"result\":{\"sessionId\":\"sess_1\"}}\n" ++
        prompt("one") ++ "? gate prompt\n" ++ ended("end_turn"));
    defer fx.deinit();
    const quick = struct {
        /// Reactor turns for a while, none of which may wait on the agent.
        fn turns(x: *Fixture) !void {
            const end = now() + 150;
            while (now() < end) {
                const before = now();
                try x.step();
                try testing.expect(now() - before < 100);
            }
        }
    }.turns;
    var before = now();
    try fx.host.send("a1", "one", .turn);
    try testing.expect(now() - before < 100);
    try quick(&fx);
    // Verbs go on meanwhile.
    _ = try fx.engine.submit(.{ .create = .{ .agent = "a2", .title = "other", .harness = acp.name, .workspace = fx.dir } });
    try testing.expect(!fx.binding().got_session);
    try fx.openGate("init");
    try quick(&fx);
    try testing.expect(!fx.binding().got_session);
    try fx.openGate("new");
    try fx.until(inTurn);
    try testing.expectEqual(AgentState.running, fx.agent().state);
    // An interrupt and a queued send write and return; nothing waits for the
    // turn's end.
    before = now();
    try fx.host.send("a1", "later", .turn);
    try testing.expect(now() - before < 100);
    try quick(&fx);
    try testing.expectEqual(AgentState.running, fx.agent().state);
    // The queued message has no line in the trace: end before it is sent.
    fx.binding().conv.dropPrompts();
    const queue = &fx.acp.states.get("a1").?.queue;
    for (queue.items) |t| testing.allocator.free(t);
    queue.clearRetainingCapacity();
    try fx.openGate("prompt");
    try fx.until(isState(.settled));
}

test "acp: venom's MCP server is offered in session/new, over stdio" {
    if (!hasPython()) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(comptime hello ++ answer_loads ++
        "> {\"method\":\"session/new\",\"id\":1,\"params\":{\"cwd\":\"$CWD\",\"mcpServers\":[{\"name\":\"venom\",\"command\":\"/usr/bin/venom\",\"args\":[\"mcp\"],\"env\":[{\"name\":\"VENOM_SOCKET\",\"value\":\"/run/v.sock\"}]}]}}\n" ++
        "< {\"id\":1,\"result\":{\"sessionId\":\"sess_1\"}}\n" ++ prompt("one") ++ ended("end_turn"));
    defer fx.deinit();
    fx.acp.mcp = .{ .command = "/usr/bin/venom", .socket = "/run/v.sock" };
    try fx.host.send("a1", "one", .turn);
    try fx.until(isState(.settled));
}

test "acp: scope: an approval naming a path outside is stamped; folders outside the cwd go in additionalDirectories" {
    if (!hasPython()) return error.SkipZigTest;
    const dirs = "< {\"id\":0,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"sessionCapabilities\":{\"additionalDirectories\":{}}}}}\n";
    var fx: Fixture = undefined;
    try fx.initScoped(comptime hello ++ dirs ++ new_session ++ prompt("go") ++
        asks("50", "{\"toolCallId\":\"t1\",\"title\":\"Edit\",\"kind\":\"edit\",\"locations\":[{\"path\":\"$CWD/a/x\"},{\"path\":\"$CWD/c/y\"}]}") ++ picks("50", "no") ++
        asks("51", "{\"toolCallId\":\"t2\",\"title\":\"Edit\",\"kind\":\"edit\",\"locations\":[{\"path\":\"$CWD/a/x\"}]}") ++ picks("51", "once") ++
        ended("end_turn"), &.{"a"});
    defer fx.deinit();
    try fx.host.send("a1", "go", .turn);
    try fx.until(isState(.needs_you));
    const r1 = fx.agent().requests.items[0];
    try testing.expect(r1.outside_scope);
    try testing.expect(r1.grant == null);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "deny" } });
    const deadline = now() + 10_000;
    while (fx.agent().raised < 2) {
        if (now() > deadline) return fx.timedOut();
        try fx.step();
    }
    const r2 = fx.agent().requests.items[0];
    try testing.expect(!r2.outside_scope);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "allow_once" } });
    try fx.until(isState(.settled));
}

test "acp: the descriptor is valid before any process, and an agent's own command runs with extra_args" {
    var x = try acp.Acp.initCommand(testing.allocator, "/opt/agent", &.{ "--acp", "--quiet" });
    defer x.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try x.probe(arena.allocator());
    try testing.expect(d.valid());
    try testing.expectEqualStrings("acp", d.harness);
    try testing.expect(d.harness_version == null);
    try testing.expect(!d.caps.release);
    try testing.expect(!d.caps.resume_tui);
    try testing.expectEqual(@as(usize, 0), d.caps.permission_modes.len);
    const spec = try x.start(arena.allocator(), .{ .agent = "a1", .cwd = "/w" });
    try expectStrings(&.{ "/opt/agent", "--acp", "--quiet" }, spec.argv);
    try testing.expect(spec.harness_session == null);
    try testing.expect(std.mem.indexOf(u8, spec.input.?, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec.input.?, "\"protocolVersion\":1") != null);
}
