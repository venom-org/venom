//! Spawned sub-agents and the concurrency queue. The queue
//! tests drive the fake harness through the CLI. The tree
//! tests use `testdata/fake_mcp_harness.py` as the parent: the real
//! claude-code adapter runs it, and each prompt is a JSON plan of calls it
//! makes over the real `venom mcp`, as that agent, with its own token.
const std = @import("std");
const build_options = @import("build_options");
const proto = @import("proto");
const verbs = @import("agent_verbs_tests.zig");
const harness = @import("harness/root.zig");
const harnesses = @import("harnesses.zig");
const supervisor = @import("supervisor");
const term = @import("venom-term");
const tui = @import("tui/root.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;
const Daemon = verbs.Daemon;

fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
fn int(v: Value, key: []const u8) i64 {
    return v.object.get(key).?.integer;
}

fn flag(a: std.mem.Allocator, name: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "--{s}={s}", .{ name, value });
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

fn show(d: *Daemon, a: std.mem.Allocator, id: []const u8) !Value {
    const r = try d.run(a, &.{ "agent", "show", try flag(a, "agent", id) });
    try testing.expectEqual(@as(u8, 0), r.status);
    return r.json;
}

/// The agent is still `queued` and no turn of it ran.
fn expectHeld(d: *Daemon, a: std.mem.Allocator, id: []const u8) !void {
    const s = try show(d, a, id);
    try testing.expectEqualStrings("queued", str(s, "state"));
    try testing.expectEqual(@as(i64, 0), int(s, "turns"));
}

fn spawnFake(d: *Daemon, a: std.mem.Allocator, task: []const u8) ![]const u8 {
    const r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", task), "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    return str(r.json, "agent");
}

const script =
    \\{"turns":[{"match":"slow","steps":[{"text":"working"},{"sleep_ms":20000}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

test "max_concurrent = 1: a second spawn waits queued until the first settles, then runs; a stop drops its task; send is refused" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script, .config = harnesses.testConfig(".agents = .{ .max_concurrent = 1 }") });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try spawnFake(&d, a, "slow one");
    _ = try d.waitState(a, first, "running");
    const second = try spawnFake(&d, a, "second");
    const third = try spawnFake(&d, a, "third");
    sleepMs(200);
    try expectHeld(&d, a, second);
    try expectHeld(&d, a, third);

    // A prompt cannot jump the queue.
    var r = try d.run(a, &.{ "agent", "send", try flag(a, "agent", second), "--text=hi" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.agent_queued", r.json.object.get("error").?.object.get("code").?.string);

    // Stopping a queued agent never sends its task: it settles, turn-less.
    r = try d.run(a, &.{ "agent", "stop", try flag(a, "agent", second) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", str(r.json, "state"));

    // The slot frees: the oldest still waiting runs, and only that one.
    _ = try d.run(a, &.{ "agent", "stop", try flag(a, "agent", first) });
    _ = try d.waitState(a, first, "settled");
    const shown = try d.waitState(a, third, "settled");
    try testing.expectEqual(@as(i64, 1), int(shown, "turns"));
    const dropped = try show(&d, a, second);
    try testing.expectEqual(@as(i64, 0), int(dropped, "turns"));
    try testing.expect(!dropped.object.get("unread").?.bool);

    // An explicit prompt is not held back, also with the limit reached.
    const fourth = try spawnFake(&d, a, "slow two");
    _ = try d.waitState(a, fourth, "running");
    r = try d.run(a, &.{ "agent", "send", try flag(a, "agent", third), "--text=again" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const again = try d.waitState(a, third, "settled");
    _ = again;
    _ = try d.run(a, &.{ "agent", "stop", try flag(a, "agent", fourth) });
    _ = try d.waitState(a, fourth, "settled");
}

test "max_concurrent = 1: a held task survives a daemon restart and starts on the next start; a dropped one does not" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script, .config = harnesses.testConfig(".agents = .{ .max_concurrent = 1 }") });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try spawnFake(&d, a, "slow one");
    _ = try d.waitState(a, first, "running");
    const dropped = try spawnFake(&d, a, "dropped");
    const held = try spawnFake(&d, a, "held");
    _ = try d.run(a, &.{ "agent", "stop", try flag(a, "agent", dropped) });
    try expectHeld(&d, a, held);

    try d.restart();

    const shown = try d.waitState(a, held, "settled");
    try testing.expectEqual(@as(i64, 1), int(shown, "turns"));
    const t = shown.object.get("transcript").?.array.items;
    try testing.expectEqualStrings("turn.prompt", str(t[1], "type"));
    try testing.expectEqualStrings("Done.", str(t[2], "text"));
    try testing.expectEqual(@as(i64, 0), int(try show(&d, a, dropped), "turns"));
    // The clean shutdown interrupted the first turn.
    try testing.expectEqualStrings("settled", str(try show(&d, a, first), "state"));
}

/// The fake claude-code and codex harnesses and a daemon around them.
const Tree = struct {
    d: Daemon,
    cc: harness.ClaudeCode,
    cx: harness.Codex,
    tmp: testing.TmpDir,
    a: std.mem.Allocator,
    out: []const u8,
    /// `init` with flags for the fake claude-code.
    const Options = struct { config: []const u8, flags: []const []const u8 = &.{} };

    fn init(self: *Tree, a: std.mem.Allocator, options: Options) !void {
        self.a = a;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        const script_path = try std.fmt.allocPrint(a, "{s}/fake_mcp_harness.py", .{dir});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "fake_mcp_harness.py", .data = @embedFile("testdata/fake_mcp_harness.py"), .flags = .{ .permissions = .executable_file } });
        self.out = try std.fmt.allocPrint(a, "{s}/out", .{dir});
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (c.realpath(try a.dupeSentinel(u8, build_options.venom_exe, 0), &buf) == null) return error.FileNotFound;
        const venom = try a.dupe(u8, std.mem.sliceTo(&buf, 0));
        self.cc = try .init(ta, .{ .exe = script_path, .extra_args = try std.mem.concat(a, []const u8, &.{ &.{ "--fake-mode", "claude-calls", "--fake-out", self.out }, options.flags }) });
        errdefer self.cc.deinit();
        self.cx = .init(ta);
        errdefer self.cx.deinit();
        self.cx.argv = try a.dupe([]const u8, &.{ "python3", script_path, "--fake-mode", "codex", "--fake-out", try std.fmt.allocPrint(a, "{s}.codex", .{self.out}) });
        try self.d.initWith(.{ .config = options.config, .extra = &.{
            .{ .harness = harness.claude_code.name, .adapter = self.cc.adapter() },
            .{ .harness = harness.codex.name, .adapter = self.cx.adapter() },
        } });
        const server: harness.mcp.Server = .{ .command = venom, .socket = self.d.socket };
        self.cc.mcp = server;
        self.cx.mcp = server;
    }

    fn deinit(self: *Tree) void {
        self.d.deinit();
        self.cc.deinit();
        self.cx.deinit();
        self.tmp.cleanup();
    }

    /// The results of the plan `id`, once the harness wrote them.
    fn results(self: *Tree, id: []const u8) ![]const Value {
        const a = self.a;
        const deadline = supervisor.monotonicMs() + 20 * std.time.ms_per_s;
        while (true) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, self.out, a, .limited(1 << 22)) catch "";
            var it = std.mem.splitScalar(u8, bytes, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                const v = try std.json.parseFromSliceLeaky(Value, a, line, .{});
                const got = v.object.get("id").?;
                if (got == .string and std.mem.eql(u8, got.string, id)) return v.object.get("results").?.array.items;
            }
            if (self.d.failed.load(.acquire)) return error.ServeLoopFailed;
            if (supervisor.monotonicMs() > deadline) {
                std.debug.print("no results for plan {s}: {s}\n", .{ id, bytes });
                return error.Timeout;
            }
            sleepMs(20);
        }
    }

    /// A file a plan can hold on; `release` creates it.
    fn holdPath(self: *Tree, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}.{s}", .{ self.out, name });
    }
    fn release(self: *Tree, path: []const u8) !void {
        _ = self;
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "" });
    }
    /// Waits for the harness to create `path`.
    fn waitFile(self: *Tree, path: []const u8) !void {
        const deadline = supervisor.monotonicMs() + 20 * std.time.ms_per_s;
        while (true) {
            if (std.Io.Dir.cwd().access(testing.io, path, .{})) |_| return else |_| {}
            if (self.d.failed.load(.acquire)) return error.ServeLoopFailed;
            if (supervisor.monotonicMs() > deadline) return error.Timeout;
            sleepMs(20);
        }
    }

    fn plan(self: *Tree, value: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.a, value, .{ .emit_null_optional_fields = false });
    }
};

const Call = struct { tool: []const u8, args: SpawnArgs = .{} };
const Grant = struct { right: []const u8, scope: []const u8 };
const SpawnArgs = struct {
    task: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    grants: ?[]const Grant = null,
    mode: ?[]const u8 = null,
    model: ?[]const u8 = null,
    isolation: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    repos: ?[]const []const u8 = null,
};
const Plan = struct { id: []const u8, calls: []const Call = &.{}, hold: ?[]const u8 = null, fail: bool = false, then: ?[]const Call = null, after_end: ?[]const Call = null };

fn spawnCall(args: SpawnArgs) Call {
    return .{ .tool = "agent_dspawn", .args = args };
}

/// The successful result in an MCP tool result.
fn okResult(v: Value) !Value {
    return verbs.mcpResult(v);
}

/// The error code in an MCP tool result.
fn errCode(a: std.mem.Allocator, v: Value) ![]const u8 {
    try testing.expect(v.object.get("isError").?.bool);
    const text = v.object.get("content").?.array.items[0].object.get("text").?.string;
    const parsed = try std.json.parseFromSliceLeaky(Value, a, text, .{});
    return parsed.object.get("error").?.object.get("code").?.string;
}

fn hasPython() bool {
    const r = std.process.run(ta, testing.io, .{ .argv = &.{ "python3", "-c", "" } }) catch return false;
    ta.free(r.stdout);
    ta.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

fn listed(d: *Daemon, a: std.mem.Allocator, id: []const u8) !Value {
    const r = try d.run(a, &.{ "agent", "list" });
    for (r.json.object.get("agents").?.array.items) |x| if (std.mem.eql(u8, str(x, "agent"), id)) return x;
    return error.NotListed;
}

test "sub-agents: 2 children over MCP, a third queued until a slot frees, depth and delegation denied, bubbling, prompt seen, wait, promote, stop tree" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .max_concurrent = 3 }") });
    defer t.deinit();
    const d = &t.d;

    const hold_parent = try t.holdPath("parent");
    const hold_a2 = try t.holdPath("a2");
    const hold_a3 = try t.holdPath("a3");
    const task_a2 = try t.plan(Plan{ .id = "a2", .calls = &.{spawnCall(.{ .task = "{}" })}, .hold = hold_a2 });
    const task_a3 = try t.plan(Plan{ .id = "a3", .hold = hold_a3 });
    const task_a4 = try t.plan(Plan{ .id = "a4", .fail = true });
    const task_a1 = try t.plan(Plan{ .id = "a1", .calls = &.{
        spawnCall(.{ .task = task_a2 }),
        spawnCall(.{ .task = task_a3 }),
        spawnCall(.{ .task = task_a4 }),
        spawnCall(.{ .task = "{}", .grants = &.{.{ .right = "admin", .scope = "*" }} }),
    }, .hold = hold_parent });

    // The parent may spawn: `write` and `spawn` on its workspace.
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{d.work});
    var r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", task_a1), "--harness=claude-code", try flag(a, "grants", try t.plan(&[_]Grant{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } })) });
    if (r.status != 0) std.debug.print("spawn: {f}\n", .{std.json.fmt(r.json, .{})});
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("a1", str(r.json, "agent"));
    try testing.expect(r.json.object.get("parent") == null);

    const parent_calls = try t.results("a1");
    try testing.expectEqual(@as(usize, 4), parent_calls.len);
    for (parent_calls[0..3], [_][]const u8{ "a2", "a3", "a4" }) |call, id| {
        const child = try okResult(call);
        try testing.expectEqualStrings(id, str(child, "agent"));
        try testing.expectEqualStrings("a1", str(child, "parent"));
        // Inherited, not agents.default (claude-code is what the fake runs).
        try testing.expectEqualStrings("claude-code", str(child, "harness"));
        try testing.expectEqualStrings(d.work, str(child, "workspace"));
    }
    // More grants than the parent: denied, nothing created.
    try testing.expectEqualStrings("denied.delegation", try errCode(a, parent_calls[3]));

    // A grandchild beyond depth 2 is denied, though the grants allow it.
    const child_calls = try t.results("a2");
    try testing.expectEqualStrings("denied.spawn_depth", try errCode(a, child_calls[0]));

    // Parent and 2 children run; the third stays queued until a slot frees.
    _ = try d.waitState(a, "a2", "running");
    _ = try d.waitState(a, "a3", "running");
    sleepMs(200);
    try expectHeld(d, a, "a4");
    r = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(usize, 4), r.json.object.get("agents").?.array.items.len);
    try testing.expectEqualStrings("a1", str(try listed(d, a, "a2"), "parent"));

    // Not all finished: a check, without waiting.
    r = try d.run(a, &.{ "agent", "wait", "--agent=a1", "--timeout-s=0" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expect(!r.json.object.get("done").?.bool);
    try testing.expectEqual(@as(usize, 3), r.json.object.get("children").?.array.items.len);

    try t.release(hold_a3);
    _ = try d.waitState(a, "a3", "settled");
    // a4 got the slot, and fails: that bubbles to its parent.
    _ = try d.waitState(a, "a4", "failed");
    const p1 = try listed(d, a, "a1");
    try testing.expectEqual(@as(i64, 1), int(p1, "children_failed"));
    try testing.expectEqual(@as(i64, 0), int(p1, "children_needs_you"));
    try testing.expectEqual(@as(i64, 0), int(try listed(d, a, "a2"), "children_failed"));

    // A human prompts a child: the parent sees it. That child's own harness
    // cannot promote itself.
    const hold_again = try t.holdPath("again");
    const prompt = try t.plan(Plan{ .id = "again", .calls = &.{.{ .tool = "agent_dpromote", .args = .{ .agent = "a3" } }}, .hold = hold_again });
    r = try d.run(a, &.{ "agent", "send", "--agent=a3", try flag(a, "text", prompt) });
    try testing.expectEqual(@as(u8, 0), r.status);
    const seen = (try show(d, a, "a1")).object.get("child_prompts").?.array.items;
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqualStrings("a3", str(seen[0], "child"));
    try testing.expectEqualStrings(prompt, str(seen[0], "text"));
    try testing.expectEqualStrings("denied.promote", try errCode(a, (try t.results("again"))[0]));

    // Promote: top-level, out of its parent's tree, still running.
    r = try d.run(a, &.{ "agent", "promote", "--agent=a3" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expect(r.json.object.get("promoted").?.bool);
    r = try d.run(a, &.{ "agent", "promote", "--agent=a3" });
    try testing.expect(!r.json.object.get("promoted").?.bool);
    try testing.expect((try listed(d, a, "a3")).object.get("parent") == null);

    // Waiting for the children holds the call until the last one finishes.
    const Releaser = struct {
        fn run(path: []const u8) void {
            sleepMs(300);
            std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "" }) catch @panic("release");
        }
    };
    const th = try std.Thread.spawn(.{}, Releaser.run, .{hold_a2});
    r = try d.run(a, &.{ "agent", "wait", "--agent=a1", "--timeout-s=20" });
    th.join();
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expect(r.json.object.get("done").?.bool);
    const below = r.json.object.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 2), below.len);
    try testing.expectEqualStrings("settled", str(below[0], "state"));
    try testing.expectEqualStrings("failed", str(below[1], "state"));

    // Stop the tree: the parent and a child in a new turn stop; the promoted
    // agent's turn keeps running.
    const hold_never = try t.holdPath("never");
    r = try d.run(a, &.{ "agent", "send", "--agent=a2", try flag(a, "text", try t.plan(Plan{ .id = "second", .hold = hold_never })) });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "running");
    r = try d.run(a, &.{ "agent", "stop", "--agent=a1", "--tree=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 2), r.json.object.get("children").?.array.items.len);
    _ = try d.waitState(a, "a1", "settled");
    _ = try d.waitState(a, "a2", "settled");
    try testing.expectEqualStrings("running", str(try show(d, a, "a3"), "state"));

    // Archiving the former parent revokes what is below it, not a promoted
    // agent: its harness still calls venom as itself.
    try t.release(hold_again);
    _ = try d.waitState(a, "a3", "settled");
    _ = try d.run(a, &.{ "agent", "archive", "--agent=a1" });
    r = try d.run(a, &.{ "agent", "send", "--agent=a3", try flag(a, "text", try t.plan(Plan{ .id = "after", .calls = &.{.{ .tool = "agent_dwait", .args = .{ .agent = "a3" } }} })) });
    try testing.expectEqual(@as(u8, 0), r.status);
    const after = try okResult((try t.results("after"))[0]);
    try testing.expect(after.object.get("done").?.bool);
    _ = try d.waitState(a, "a3", "settled");
    // a3 and a2 were prompted before; a promoted agent is no longer its child.
    try testing.expectEqual(@as(usize, 2), (try show(d, a, "a1")).object.get("child_prompts").?.array.items.len);
}

/// Pumps a TUI on `d` until `pred` holds, 20 s at most.
fn pumpUntil(app: *tui.App, link: *tui.Link, surface: *term.Surface, d: *Daemon, what: []const u8, pred: anytype) !void {
    const deadline = supervisor.monotonicMs() + 20 * std.time.ms_per_s;
    while (true) {
        if (d.failed.load(.acquire)) return error.ServeLoopFailed;
        try link.pump(app, 20);
        app.now_ms = tui.link_now();
        try tui.view.render(app, surface);
        if (pred.check(app)) return;
        if (supervisor.monotonicMs() > deadline) {
            std.debug.print("timed out waiting for {s}: {s}\n", .{ what, app.message.items });
            return error.Timeout;
        }
    }
}

const InState = struct {
    id: []const u8,
    state: tui.model.State,
    fn check(self: InState, app: *tui.App) bool {
        const x = app.model.find(self.id) orelse return false;
        return x.state == self.state;
    }
};
const Linked = struct {
    fn check(_: Linked, app: *tui.App) bool {
        return app.connected;
    }
};
const Said = struct {
    text: []const u8,
    fn check(self: Said, app: *tui.App) bool {
        return std.mem.indexOf(u8, app.message.items, self.text) != null;
    }
};
const CardsOf = struct {
    id: []const u8,
    n: usize,
    fn check(self: CardsOf, app: *tui.App) bool {
        return (tui.fan_out.block(app, self.id) catch return false).cards.len == self.n;
    }
};
const TopLevel = struct {
    id: []const u8,
    fn check(self: TopLevel, app: *tui.App) bool {
        const x = app.model.find(self.id) orelse return false;
        return x.parent.len == 0;
    }
};

test "fan-out keys against the fake harness: the block fills, P promotes, w waits for all, K stops the tree" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig("") });
    defer t.deinit();
    const d = &t.d;

    var app = tui.App.init(ta);
    defer app.deinit();
    var link: tui.Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 100, 40);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try pumpUntil(&app, &link, &surface, d, "connect", Linked{});

    const hold_parent = try t.holdPath("parent");
    const hold_a2 = try t.holdPath("a2");
    const hold_a3 = try t.holdPath("a3");
    const hold_a4 = try t.holdPath("a4");
    const task_a2 = try t.plan(Plan{ .id = "a2", .hold = hold_a2 });
    const task_a3 = try t.plan(Plan{ .id = "a3", .hold = hold_a3 });
    const task_a4 = try t.plan(Plan{ .id = "a4", .hold = hold_a4 });
    const task_a1 = try t.plan(Plan{ .id = "a1", .calls = &.{ spawnCall(.{ .task = task_a2 }), spawnCall(.{ .task = task_a3 }), spawnCall(.{ .task = task_a4 }) }, .hold = hold_parent });
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{d.work});
    const r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", task_a1), "--harness=claude-code", try flag(a, "grants", try t.plan(&[_]Grant{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } })) });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try t.results("a1");
    _ = try d.waitState(a, "a2", "running");
    _ = try d.waitState(a, "a3", "running");
    _ = try d.waitState(a, "a4", "running");

    try app.setSelected("a1");
    try pumpUntil(&app, &link, &surface, d, "the block", CardsOf{ .id = "a1", .n = 3 });
    app.focus.set(1);

    // ]: into a child, [: back.
    _ = try app.feed("]");
    try testing.expectEqualStrings("a2", app.selected.items);
    _ = try app.feed("[");
    try testing.expectEqualStrings("a1", app.selected.items);

    // P on the last card: a4 leaves the tree. It is finished off by hand.
    try pumpUntil(&app, &link, &surface, d, "the block again", CardsOf{ .id = "a1", .n = 3 });
    _ = try app.feed("kP");
    try pumpUntil(&app, &link, &surface, d, "a4 top-level", TopLevel{ .id = "a4" });
    try pumpUntil(&app, &link, &surface, d, "two cards", CardsOf{ .id = "a1", .n = 2 });
    try testing.expect((try listed(d, a, "a4")).object.get("parent") == null);
    try t.release(hold_a4);

    // w: the call stays open until the children finish.
    _ = try app.feed("w");
    try testing.expectEqualStrings("a1", app.fan.waiting.?);
    try t.release(hold_a2);
    try t.release(hold_a3);
    try pumpUntil(&app, &link, &surface, d, "a2 settled", InState{ .id = "a2", .state = .settled });
    try pumpUntil(&app, &link, &surface, d, "the wait's answer", Said{ .text = "all of a1's sub-agents have finished" });
    try testing.expect(app.fan.waiting == null);

    // K: a child in a new turn and the parent both stop.
    const again = try d.run(a, &.{ "agent", "send", "--agent=a2", try flag(a, "text", try t.plan(Plan{ .id = "second", .hold = try t.holdPath("never") })) });
    try testing.expectEqual(@as(u8, 0), again.status);
    try pumpUntil(&app, &link, &surface, d, "a2 running", InState{ .id = "a2", .state = .running });
    _ = try app.feed("K");
    try pumpUntil(&app, &link, &surface, d, "a2 stopped", InState{ .id = "a2", .state = .settled });
    try pumpUntil(&app, &link, &surface, d, "a1 stopped", InState{ .id = "a1", .state = .settled });
    try testing.expectEqualStrings("settled", str(try show(d, a, "a2"), "state"));
    try testing.expectEqualStrings("settled", str(try show(d, a, "a1"), "state"));
}

test "sub-agents: a child gets its own worktree, its parent's scope, mode and model, and cannot widen them; spawn.allow and spawn.depth" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const git = std.process.run(a, testing.io, .{ .argv = &.{ "git", "--version" } }) catch return error.SkipZigTest;
    if (!git.term.success()) return error.SkipZigTest;
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .spawn = .{ .depth = 3 } }") });
    defer t.deinit();
    const d = &t.d;

    // `work/{repo,other}`: real repos; `work` is the workspace.
    for ([_][]const u8{ "repo", "other" }) |name| for ([_][]const []const u8{ &.{ "init", "-q", "-b", "main" }, &.{ "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "--allow-empty", "-m", "init" } }) |args| {
        const repo = try std.fmt.allocPrint(a, "{s}/{s}", .{ d.work, name });
        try std.Io.Dir.cwd().createDirPath(testing.io, repo);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "git", "-C", repo });
        try argv.appendSlice(a, args);
        const g = try std.process.run(a, testing.io, .{ .argv = argv.items });
        try testing.expect(g.term.success());
    };
    var r = try d.run(a, &.{ "workspace", "add", try flag(a, "path", d.work) });
    try testing.expectEqual(@as(u8, 0), r.status);

    const hold = try t.holdPath("parent");
    const hold_child = try t.holdPath("child");
    const child = try t.plan(Plan{ .id = "child", .calls = &.{spawnCall(.{ .task = try t.plan(Plan{ .id = "grandchild" }) })}, .hold = hold_child });
    const parent = try t.plan(Plan{ .id = "parent", .calls = &.{
        spawnCall(.{ .task = child }),
        spawnCall(.{ .task = "{}", .mode = "accept_edits" }),
        spawnCall(.{ .task = "{}", .model = "other" }),
        spawnCall(.{ .task = "{}", .isolation = "in_place" }),
        spawnCall(.{ .task = "{}", .workspace = d.work, .repos = &.{"other"} }),
        spawnCall(.{ .task = "{}", .workspace = d.work }),
    }, .hold = hold });
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{d.work});
    r = try d.run(a, &.{
        "agent",              "spawn",                     try flag(a, "workspace", d.work),
        "--repos=[\"repo\"]", "--harness=claude-code",     "--isolation=worktree",
        "--mode=plan",        try flag(a, "task", parent), try flag(a, "grants", try t.plan(&[_]Grant{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } })),
    });
    if (r.status != 0) std.debug.print("spawn: {f}\n", .{std.json.fmt(r.json, .{})});
    try testing.expectEqual(@as(u8, 0), r.status);

    const calls = try t.results("parent");
    const made = try okResult(calls[0]);
    try testing.expectEqualStrings("a2", str(made, "agent"));
    try testing.expectEqualStrings("worktree", str(made, "isolation"));
    try testing.expectEqualStrings("repo", made.object.get("repos").?.array.items[0].string);
    const worktree = try std.fmt.allocPrint(a, "{s}/repo-a2", .{d.work});
    try testing.expectEqualStrings(worktree, str(made, "cwd"));
    try testing.expectEqualStrings("denied.spawn_mode", try errCode(a, calls[1]));
    try testing.expectEqualStrings("denied.spawn_model", try errCode(a, calls[2]));
    try testing.expectEqualStrings("denied.spawn_isolation", try errCode(a, calls[3]));
    // Repos beyond the parent's, and the whole workspace: never more.
    try testing.expectEqualStrings("denied.spawn_scope", try errCode(a, calls[4]));
    try testing.expectEqualStrings("denied.spawn_scope", try errCode(a, calls[5]));

    // Depth 3 here: the grandchild is allowed and is a child of a2.
    const grand = try okResult((try t.results("child"))[0]);
    try testing.expectEqualStrings("a2", str(grand, "parent"));
    _ = try d.waitState(a, str(grand, "agent"), "settled");

    // Inherited: the mode as given to the parent, the model it reported.
    const shown = try show(d, a, "a2");
    try testing.expectEqualStrings("plan", str(shown, "permission_mode"));
    try testing.expectEqualStrings("fake", str(shown, "model"));
    const argvs = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}.argvs", .{t.out}), a, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, argvs, '\n');
    _ = lines.next(); // the parent's
    const child_argv = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, child_argv, "\"--permission-mode\", \"plan\"") != null);
    try testing.expect(std.mem.indexOf(u8, child_argv, "\"--model\", \"fake\"") != null);

    try t.release(hold_child);
    try t.release(hold);
    _ = try d.waitState(a, "a1", "settled");
    _ = try d.waitState(a, "a2", "settled");
}

test "sub-agents: agents.spawn.allow = false denies an agent's spawn, not a person's" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .spawn = .{ .allow = false } }") });
    defer t.deinit();
    const d = &t.d;
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{d.work});
    const task = try t.plan(Plan{ .id = "p", .calls = &.{spawnCall(.{ .task = "{}" })} });
    const r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", task), "--harness=claude-code", try flag(a, "grants", try t.plan(&[_]Grant{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } })) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("denied.spawn_disabled", try errCode(a, (try t.results("p"))[0]));
    _ = try d.waitState(a, "a1", "settled");
}

fn spawnGrants(t: *Tree, a: std.mem.Allocator, extra: []const []const u8, task: []const u8) !Daemon.Out {
    const d = &t.d;
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{d.work});
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", task), "--harness=claude-code", try flag(a, "grants", try t.plan(&[_]Grant{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } })) });
    try args.appendSlice(a, extra);
    return d.run(a, args.items);
}

test "sub-agents on another harness: codex runs a child of an ask or plan parent read-only, and leaves a top-level agent alone" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig("") });
    defer t.deinit();
    const d = &t.d;
    const threads = try std.fmt.allocPrint(a, "{s}.codex.threads", .{t.out});

    // Top-level: its own default.
    var r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), "--task=x", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");

    const task = try t.plan(Plan{ .id = "p", .calls = &.{spawnCall(.{ .task = "x", .harness = "codex" })} });
    r = try spawnGrants(&t, a, &.{}, task);
    try testing.expectEqual(@as(u8, 0), r.status);
    const child = try okResult((try t.results("p"))[0]);
    try testing.expectEqualStrings("codex", str(child, "harness"));
    const id = str(child, "agent");
    _ = try d.waitState(a, id, "settled");
    // `ask` on codex would still edit unasked, so the child is held to plan.
    try testing.expectEqualStrings("plan", str(try show(d, a, id), "permission_mode"));

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, threads, a, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const top = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    try testing.expectEqualStrings("workspace-write", str(top, "sandbox"));
    const sub = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    try testing.expectEqualStrings("read-only", str(sub, "sandbox"));
    try testing.expectEqualStrings("on-request", str(sub, "approvalPolicy"));
}

test "restart: a queued child gets exactly its logged grants back, not the default profile" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .max_concurrent = 2 }") });
    defer t.deinit();
    const d = &t.d;
    const never = try t.holdPath("never");
    const narrow = try t.plan(Plan{ .id = "narrow", .calls = &.{ .{ .tool = "agent_dlist" }, spawnCall(.{ .task = "{}" }) } });
    const task = try t.plan(Plan{ .id = "p", .calls = &.{
        spawnCall(.{ .task = try t.plan(Plan{ .id = "c", .hold = never }) }),
        spawnCall(.{ .task = narrow, .grants = &.{.{ .right = "read", .scope = "agent:a3" }} }),
    }, .hold = never });
    const r = try spawnGrants(&t, a, &.{}, task);
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try t.results("p");
    _ = try d.waitState(a, "a2", "running");
    try expectHeld(d, a, "a3");

    try d.restart();

    const calls = try t.results("narrow");
    const seen = (try okResult(calls[0])).object.get("agents").?.array.items;
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqualStrings("a3", str(seen[0], "agent"));
    try testing.expectEqualStrings("denied.write", try errCode(a, calls[1]));
    _ = try d.waitState(a, "a3", "settled");
}

test "fail closed: a child whose grants cannot be restored does not start, live or after a restart" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .max_concurrent = 2 }") });
    defer t.deinit();
    const d = &t.d;
    const never = try t.holdPath("never");
    const release_parent = try t.holdPath("parent");

    // a1 blocks one slot and a2, the parent, the other. a3 is older in the
    // queue than a2's child a4, so archiving a2 gives a3 the slot.
    var r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", try t.plan(Plan{ .id = "a1", .hold = never })), "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try spawnGrants(&t, a, &.{}, try t.plan(Plan{ .id = "a2", .hold = release_parent, .then = &.{spawnCall(.{ .task = try t.plan(Plan{ .id = "a4" }) })} }));
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try t.results("a2");
    r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", try t.plan(Plan{ .id = "a3", .hold = never })), "--harness=claude-code" });
    try testing.expectEqualStrings("a3", str(r.json, "agent"));
    try t.release(release_parent);
    try testing.expectEqualStrings("a4", str(try okResult((try t.results("a2:then"))[0]), "agent"));
    _ = try d.run(a, &.{ "agent", "archive", "--agent=a2" });
    _ = try d.waitState(a, "a2", "archived");
    _ = try d.waitState(a, "a3", "running");
    try expectHeld(d, a, "a4");

    try d.restart();

    // Its parent is archived: failed, and no harness ever ran its plan.
    const shown = try d.waitState(a, "a4", "failed");
    const trail = shown.object.get("transcript").?.array.items;
    try testing.expectEqualStrings("unavailable.agent_grants", str(trail[trail.len - 1], "error_code"));
    try testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(testing.io, t.out, a, .limited(1 << 20)), "{\"id\": \"a4\"") == null);
}

test "stop: a stopping or settled parent may not spawn" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig("") });
    defer t.deinit();
    const d = &t.d;
    const never = try t.holdPath("never");

    // The spawn comes in after the stop, before the interrupted turn ends.
    var r = try spawnGrants(&t, a, &.{}, try t.plan(Plan{ .id = "s", .hold = never, .then = &.{spawnCall(.{ .task = "{}" })} }));
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try t.results("s");
    _ = try d.waitState(a, "a1", "running");
    r = try d.run(a, &.{ "agent", "stop", "--agent=a1", "--tree=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("conflict.parent_stopped", try errCode(a, (try t.results("s:then"))[0]));
    _ = try d.waitState(a, "a1", "settled");

    // And after its turn has ended.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", try flag(a, "text", try t.plan(Plan{ .id = "e", .after_end = &.{spawnCall(.{ .task = "{}" })} })) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("conflict.parent_stopped", try errCode(a, (try t.results("e:end"))[0]));
    r = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(usize, 1), r.json.object.get("agents").?.array.items.len);
}

test "stop: a dispatched child's harness is ended, and a late turn is neither logged nor a slot" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    // Held before it reads its prompt, and it runs its task even after SIGTERM.
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .max_concurrent = 1 }"), .flags = &.{ "--fake-start-hold", "--fake-ignore-term" } });
    defer t.deinit();
    const d = &t.d;

    var r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", try t.plan(Plan{ .id = "late" })), "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("queued", str(r.json, "state"));
    // Past its SIGTERM handler, not yet past its start hold.
    try t.waitFile(try t.holdPath("argvs"));
    r = try d.run(a, &.{ "agent", "stop", "--agent=a1" });
    try testing.expectEqualStrings("settled", str(r.json, "state"));

    // The slot is free at once: the next agent starts and is not overtaken.
    r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", try t.plan(Plan{ .id = "next" })), "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);

    try t.release(try t.holdPath("start"));
    _ = try t.results("late");
    _ = try t.results("next");
    _ = try d.waitState(a, "a2", "settled");
    sleepMs(300);
    const stopped = try show(d, a, "a1");
    try testing.expectEqualStrings("settled", str(stopped, "state"));
    try testing.expectEqual(@as(i64, 0), int(stopped, "turns"));
    try testing.expect(!stopped.object.get("unread").?.bool);

    // The process is gone; a new prompt starts a new one.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", try flag(a, "text", try t.plan(Plan{ .id = "again" })) });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try t.results("again");
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while (int(try show(d, a, "a1"), "turns") != 1) {
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(20);
    }
    _ = try d.waitState(a, "a1", "settled");
}

test "agents.mode: recorded at spawn, passed to the harness, and a later config change does not rewrite it" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script, .config = harnesses.testConfig(".agents = .{ .mode = .plan }") });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try spawnFake(&d, a, "one");
    _ = try d.waitState(a, first, "settled");
    try testing.expectEqualStrings("plan", str(try show(&d, a, first), "permission_mode"));
    const modes = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/modes", .{d.dir}), a, .limited(4096));
    try testing.expectEqualStrings("fake-a1 plan\n", modes);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.zon", .{d.dir}), .data = harnesses.testConfig(".agents = .{ .mode = .accept_edits }") });
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    var latest: []const u8 = "";
    while (true) {
        latest = try spawnFake(&d, a, "next");
        _ = try d.waitState(a, latest, "settled");
        if (std.mem.eql(u8, str(try show(&d, a, latest), "permission_mode"), "accept_edits")) break;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(100);
    }
    try testing.expectEqualStrings("plan", str(try show(&d, a, first), "permission_mode"));
}

test "restart: a revoked agent stays revoked; its grants do not come back" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try spawnFake(&d, a, "one");
    _ = try d.waitState(a, first, "settled");
    const other = try spawnFake(&d, a, "two");
    _ = try d.waitState(a, other, "settled");
    var buf: [24]u8 = undefined;
    const name = proto.grants.name(d.principals.principalOf(first).?, &buf);
    var r = try d.run(a, &.{ "grant", "revoke", try flag(a, "principal", name) });
    if (r.status != 0) std.debug.print("revoke: {f}\n", .{std.json.fmt(r.json, .{})});
    try testing.expectEqual(@as(u8, 0), r.status);
    sleepMs(200);

    try d.restart();

    r = try d.run(a, &.{ "agent", "send", try flag(a, "agent", first), "--text=more" });
    try testing.expectEqual(@as(u8, 6), r.status);
    try testing.expectEqualStrings("unavailable.agent_grants", r.json.object.get("error").?.object.get("code").?.string);
    // The agent not revoked still works.
    r = try d.run(a, &.{ "agent", "send", try flag(a, "agent", other), "--text=more" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, other, "settled");
}

test "max_concurrent = 1: a parent in agent.wait gives up its slot, so its queued child runs and the wait is answered" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tree = undefined;
    try t.init(a, .{ .config = harnesses.testConfig(".agents = .{ .max_concurrent = 1 }") });
    defer t.deinit();
    const d = &t.d;

    const task_child = try t.plan(Plan{ .id = "child" });
    const task_parent = try t.plan(Plan{ .id = "parent", .calls = &.{
        spawnCall(.{ .task = task_child }),
        .{ .tool = "agent_dwait", .args = .{ .agent = "a1" } },
    } });
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{d.work});
    const r = try d.run(a, &.{ "agent", "spawn", try flag(a, "cwd", d.work), try flag(a, "task", task_parent), "--harness=claude-code", try flag(a, "grants", try t.plan(&[_]Grant{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } })) });
    try testing.expectEqual(@as(u8, 0), r.status);

    // The child ran to settled while the parent waited, well before timeout_s.
    const calls = try t.results("parent");
    try testing.expectEqual(@as(usize, 2), calls.len);
    const waited = try okResult(calls[1]);
    try testing.expect(waited.object.get("done").?.bool);
    const below = waited.object.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 1), below.len);
    try testing.expectEqualStrings("settled", str(below[0], "state"));
    _ = try d.waitState(a, "a1", "settled");
}
