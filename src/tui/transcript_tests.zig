//! The transcript's snapshots: each density, each
//! always-open rule and each grouping, from recorded claude-code and codex
//! streams (`testdata/transcript/*.jsonl`). The lines go through the real
//! adapter, the host's event mapping, the decider and `agent.show`'s
//! records, as they do in the daemon; only the process is left out.
//!
//! The recordings are real runs, in a throwaway repo with a harmless prompt,
//! of Claude Code 2.1.319 (`claude -p --output-format stream-json --verbose`)
//! and codex-cli 0.167.0 (`codex app-server`). They are scrubbed: paths, ids
//! and account data are replaced or dropped, as are lines the adapters
//! ignore. A `# in flight` line starts a second run, cut short by dropping
//! results: a call still running, and a call waiting for approval (Claude
//! Code's prompt comes over MCP, so the test makes that call).
const std = @import("std");
const term = @import("venom-term");
const eventlog = @import("../eventlog/root.zig");
const harness = @import("../harness/root.zig");
const agents = @import("../agents.zig");
const transcript = @import("transcript.zig");
const model = @import("model.zig");
const tests = @import("tests.zig");
const App = @import("app.zig").App;
const view = @import("view.zig");
const testing = std.testing;
const ta = testing.allocator;
const contract = harness.contract;
const Value = std.json.Value;
const Density = transcript.Density;

/// Claude Code calls are timed by the adapter's clock; recordings get this.
const claude_duration_ms = 1200;
/// When the recording starts; each event takes a second.
const t0: i64 = 1794061200000;

/// A daemon's worth of state: what the host submits lands in the decider.
const Replay = struct {
    state: eventlog.State,
    arena: std.heap.ArenaAllocator,
    now: i64 = t0,
    conv: contract.Conversation = undefined,
    /// Live tails, as the host keeps them.
    tails: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn init(self: *Replay, name: []const u8) !void {
        self.* = .{ .state = .init(ta), .arena = .init(ta) };
        _ = try self.apply(.{ .create = .{ .agent = "a1", .title = "rename proto.Frame", .harness = name, .workspace = "/w" } });
        _ = try self.apply(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = name, .harness_session = "s1" } } });
        try self.conv.init(ta, "a1", name, "/w", .{}, .{ .ptr = self, .emit = emit });
    }

    fn deinit(self: *Replay) void {
        self.conv.deinit();
        self.state.deinit();
        self.arena.deinit();
    }

    fn apply(self: *Replay, cmd: eventlog.Command) !usize {
        self.now += 1000;
        return eventlog.decider.applyAt(&self.state, cmd, self.now, self.arena.allocator());
    }

    fn emit(ptr: *anyopaque, conv: *contract.Conversation, event: contract.Normalized) anyerror!void {
        const self: *Replay = @ptrCast(@alignCast(ptr));
        if (event == .tool_updated) {
            const a = self.arena.allocator();
            try self.tails.put(a, try a.dupe(u8, event.tool_updated.call), try a.dupe(u8, event.tool_updated.body_delta));
        }
        var record = harness.host.Host.recordOf(conv, event) orelse return;
        if (record == .agent_binding) return;
        if (record == .tool_ended and std.mem.eql(u8, conv.harness, harness.claude_code.name)) record.tool_ended.duration_ms = claude_duration_ms;
        _ = try self.apply(.{ .record = record });
    }

    /// `agent.show`'s answer, as JSON, into a `Detail`.
    fn show(self: *Replay, a: std.mem.Allocator, m: *model.Model, d: *model.Detail) !void {
        const x = self.state.agents.getPtr("a1").?;
        const records = try a.dupe(agents.ShowRecord, try agents.transcriptRecords(a, "a1", x, null, true));
        for (records) |*r| if (r.call) |c| if (self.tails.get(c)) |t| if (std.mem.eql(u8, r.type, "tool.started")) {
            r.tail = t;
        };
        const Req = struct { request: []const u8, kind: []const u8, reason: []const u8, stale: bool, call: ?[]const u8 };
        var requests: std.ArrayList(Req) = .empty;
        for (x.requests.items) |r| try requests.append(a, .{ .request = r.request, .kind = r.kind, .reason = r.reason, .stale = r.stale, .call = r.call });
        const json = try std.json.Stringify.valueAlloc(a, .{ .agent = "a1", .turns = x.turns, .requests = requests.items, .transcript = records }, .{ .emit_null_optional_fields = false });
        try m.fillDetail(d, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    }
};

const NullChannel = struct {
    fn channel() contract.Channel {
        return .{ .ptr = undefined, .vtable = &.{ .write = write, .signal = signal, .close_input = closeInput } };
    }
    fn write(_: *anyopaque, _: []const u8) anyerror!void {}
    fn signal(_: *anyopaque, _: std.posix.SIG) anyerror!void {}
    fn closeInput(_: *anyopaque) void {}
};

const NullReplier = struct {
    fn replier() harness.claude_code.Replier {
        return .{ .ptr = undefined, .reply = reply };
    }
    fn reply(_: *anyopaque, _: []const u8, _: []const u8, _: u64, _: []const u8) anyerror!void {}
};

fn section(recording: []const u8, in_flight: bool) []const u8 {
    const mark = "# in flight\n";
    const at = std.mem.indexOf(u8, recording, mark).?;
    return if (in_flight) recording[at + mark.len ..] else recording[0..at];
}

fn feedLines(adapter: anytype, conv: *contract.Conversation, lines: []const u8) !void {
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| if (line.len > 0) try adapter.decode(conv, line);
}

const Fixture = struct {
    harness: enum { claude, codex },
    replay: Replay = undefined,
    claude: harness.ClaudeCode = undefined,
    codex: harness.Codex = undefined,

    fn init(self: *Fixture) !void {
        switch (self.harness) {
            .claude => {
                try self.replay.init(harness.claude_code.name);
                self.claude = try .init(ta, .{ .mcp = .{}, .replier = NullReplier.replier() });
                self.replay.conv.channel = NullChannel.channel();
                try self.claude.send(&self.replay.conv, "Rename proto.Frame", .turn);
                try self.replay.conv.promptSent("Rename proto.Frame", .turn);
                self.replay.conv.sending = true;
                try feedLines(&self.claude, &self.replay.conv, section(@embedFile("testdata/transcript/claude.jsonl"), false));
            },
            .codex => {
                try self.replay.init(harness.codex.name);
                self.codex = .init(ta);
                self.replay.conv.channel = NullChannel.channel();
                try self.replay.conv.promptSent("Rename proto.Frame", .turn);
                try feedLines(&self.codex, &self.replay.conv, section(@embedFile("testdata/transcript/codex.jsonl"), false));
            },
        }
    }

    /// The second turn: left running, with a call waiting for approval.
    fn inFlight(self: *Fixture) !void {
        switch (self.harness) {
            .claude => {
                try self.claude.send(&self.replay.conv, "Try again", .turn);
                try self.replay.conv.promptSent("Try again", .turn);
                self.replay.conv.sending = true;
                try feedLines(&self.claude, &self.replay.conv, section(@embedFile("testdata/transcript/claude.jsonl"), true));
                try self.claude.permissionPrompt(&self.replay.conv, .{ .tool_name = "Write", .input_json = "{\"file_path\":\"/w/new.txt\",\"content\":\"one\\ntwo\\n\"}", .tool_use_id = "toolu_11" });
            },
            .codex => {
                try self.replay.conv.promptSent("Try again", .turn);
                try feedLines(&self.codex, &self.replay.conv, section(@embedFile("testdata/transcript/codex.jsonl"), true));
            },
        }
    }

    fn deinit(self: *Fixture) void {
        switch (self.harness) {
            .claude => self.claude.deinit(),
            .codex => self.codex.deinit(),
        }
        self.replay.deinit();
    }
};

/// The transcript at 78 columns, all of it.
fn snapshot(a: std.mem.Allocator, f: *Fixture, o: transcript.Options) ![]const u8 {
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    try f.replay.show(a, &m, &d);
    var v: transcript.View = .{};
    defer v.deinit(ta);
    var scroll: term.widgets.ScrollView = .{};
    defer scroll.deinit(ta);
    const blocks = try v.build(ta, &d, o, 78);
    var surface = try term.Surface.init(ta, 78, 90);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    const theme: term.widgets.Theme = .default;
    scroll.top = 0;
    try scroll.draw(ta, &surface, .{ .width = 78, .height = 90 }, blocks, &theme, false);
    const out = try tests.dump(a, &surface);
    return std.fmt.allocPrint(a, "{s}\n", .{std.mem.trimEnd(u8, out, "\n")});
}

fn expectSnapshot(comptime name: []const u8, got: []const u8) !void {
    const want = @embedFile("testdata/transcript/" ++ name ++ ".txt");
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("=== {s}\n{s}=== end\n", .{ name, got });
        return error.TestExpectedEqual;
    }
}

fn densities(comptime name: []const u8, which: @FieldType(Fixture, "harness")) !void {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{ .harness = which };
    try f.init();
    defer f.deinit();
    const now = f.replay.now + 1000;
    try expectSnapshot(name ++ "_compact", try snapshot(a, &f, .{ .density = .compact, .now_ms = now }));
    try expectSnapshot(name ++ "_normal", try snapshot(a, &f, .{ .density = .normal, .now_ms = now }));
    try expectSnapshot(name ++ "_verbose", try snapshot(a, &f, .{ .density = .verbose, .now_ms = now }));
}

fn alwaysOpen(comptime name: []const u8, which: @FieldType(Fixture, "harness")) !void {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{ .harness = which };
    try f.init();
    defer f.deinit();
    try f.inFlight();
    // Compact: only the always-open rules open anything.
    try expectSnapshot(name ++ "_inflight", try snapshot(a, &f, .{ .density = .compact, .now_ms = f.replay.now + 14_000 }));
    // Before the threshold the running call stays closed.
    const early = try snapshot(a, &f, .{ .density = .compact, .now_ms = f.replay.now + 1, .open_running_after_ms = 3_600_000 });
    // (Only the waiting call is open, so one "▾" after the failed call's.)
    try testing.expect(std.mem.indexOf(u8, early, "▸ ") != null);
    try testing.expect(std.mem.indexOf(u8, early, "no output yet") == null and std.mem.indexOf(u8, early, "    slept") == null);
}

test "snapshots: each density and each grouping, claude-code" {
    try densities("claude", .claude);
}

test "snapshots: each density and each grouping, codex" {
    try densities("codex", .codex);
}

test "snapshots: each always-open rule, claude-code" {
    try alwaysOpen("claude", .claude);
}

test "snapshots: each always-open rule, codex" {
    try alwaysOpen("codex", .codex);
}

// ---- Keys, through the app ----------------------------------------------

const show_json =
    \\{"agent":"a1","title":"venom-echo conformance","harness":"claude-code","state":"running","unread":false,"workspace":"/w","cwd":"/w","created_at":1,"changed_at":2,"turns":1,"open_turn":"t1","requests":[],
    \\ "transcript":[{"type":"turn.started","turn":"t1"},
    \\ {"type":"tool.started","turn":"t1","call":"c1","kind":"edit","name":"Edit","title":"a.zig","status":"pending","at":1794061790000,"args":{"path":"a.zig","added":2,"removed":1}},
    \\ {"type":"tool.ended","turn":"t1","call":"c1","status":"ok","body":{"text":"-old\n+new\n+more","truncated":true,"bytes":90000}},
    \\ {"type":"tool.started","turn":"t1","call":"c2","kind":"exec","name":"Bash","title":"zig build","status":"pending","at":1794061790000,"args":{"command":"zig build","cwd":"/w"}},
    \\ {"type":"tool.ended","turn":"t1","call":"c2","status":"ok","exit":0,"duration_ms":4200,"body":{"text":"built","truncated":false,"bytes":5}}]}
;

const Keys = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    surface: term.Surface,
    discard: std.Io.Writer.Discarding,

    fn init(self: *Keys) !void {
        self.arena = .init(ta);
        self.app = App.init(ta);
        const a = self.arena.allocator();
        self.surface = try term.Surface.init(ta, 120, 30);
        self.discard = .init(&.{});
        try tests.fixtureApp(&self.app, a);
        try view.render(&self.app, &self.surface);
        try testing.expectEqualStrings("agent.show(a1) ", try tests.sent(a, &self.app));
        try tests.answer(&self.app, a, "agent.show", show_json);
        try view.render(&self.app, &self.surface);
        // ⏎ on the list focuses the transcript.
        _ = try self.app.feed("\t");
        try view.render(&self.app, &self.surface);
    }
    fn deinit(self: *Keys) void {
        self.surface.deinit(&self.discard.writer);
        self.app.deinit();
        self.arena.deinit();
    }
    fn press(self: *Keys, keys: []const u8) ![]const u8 {
        _ = try self.app.feed(keys);
        try view.render(&self.app, &self.surface);
        return tests.dump(self.arena.allocator(), &self.surface);
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// What `J` shows for `call`: `agent.tool`'s answer, through the pager.
fn rawPager(a: std.mem.Allocator, f: *Fixture, call: []const u8) ![]const u8 {
    const x = f.replay.state.agents.getPtr("a1").?;
    const record = agents.toolRecord("a1", x, call, null).?;
    const json = try std.json.Stringify.valueAlloc(a, record, .{ .emit_null_optional_fields = false });
    var pager: transcript.Pager = .{ .mode = .raw, .title = try ta.dupe(u8, "t"), .id = 1, .parts = try ta.alloc([]u8, 1) };
    pager.parts[0] = try ta.dupe(u8, "");
    defer pager.deinit(ta);
    try pager.fill(ta, 0, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    const blocks = try pager.blocks(ta);
    return a.dupe(u8, blocks[0].spans[0].text);
}

test "J: the raw input of a recorded claude-code call" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{ .harness = .claude };
    try f.init();
    defer f.deinit();
    const raw = try rawPager(a, &f, "c2");
    // venom's normalized args stay, and the harness's input is there as JSON:
    // `Grep`'s `output_mode` and `-n` have no normalized member.
    try testing.expect(contains(raw, "\"args\": {"));
    try testing.expect(contains(raw, "\"raw_input\": {\n    \"pattern\": \"greeting\",\n    \"path\": \"/w\",\n    \"output_mode\": \"content\",\n    \"-n\": true\n  }"));
}

test "J: the raw input of a recorded codex item, without its output" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{ .harness = .codex };
    try f.init();
    defer f.deinit();
    const raw = try rawPager(a, &f, "c1");
    try testing.expect(contains(raw, "\"raw_input\": {\n    \"type\": \"commandExecution\",\n    \"id\": \"item_2\",\n    \"command\": \"/bin/sh -lc 'cat demo.zig'\""));
    try testing.expect(contains(raw, "\"commandActions\": ["));

    // An item seen only when it completes keeps its input, and the output
    // stays the call's body.
    try f.codex.decode(&f.replay.conv, "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"thr_1\",\"turn\":{\"id\":\"turn_9\"}}}");
    try f.codex.decode(&f.replay.conv, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thr_1\",\"item\":{\"type\":\"commandExecution\",\"id\":\"item_late\",\"command\":\"pwd\",\"status\":\"completed\",\"aggregatedOutput\":\"/w-out\\n\",\"exitCode\":0}}}");
    const x = f.replay.state.agents.getPtr("a1").?;
    var late: ?eventlog.events.ToolStarted = null;
    for (x.transcript.items) |e| if (e == .tool_started and std.mem.eql(u8, e.tool_started.harness_ref.?, "item_late")) {
        late = e.tool_started;
    };
    try testing.expectEqualStrings("{\"type\":\"commandExecution\",\"id\":\"item_late\",\"command\":\"pwd\",\"status\":\"completed\",\"exitCode\":0}", late.?.raw_input.?.text);
    const whole = try rawPager(a, &f, late.?.call);
    try testing.expect(contains(whole, "/w-out"));
}

test "J: raw input past harness.body_max is cut and says so; a call from an older log has none" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fixture = .{ .harness = .claude };
    try f.init();
    defer f.deinit();
    f.replay.conv.body_max = 16;
    try f.claude.send(&f.replay.conv, "Again", .turn);
    f.replay.conv.sending = true;
    try f.claude.decode(&f.replay.conv, "{\"type\":\"assistant\",\"session_id\":\"s1\",\"parent_tool_use_id\":null,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_cut\",\"name\":\"Bash\",\"input\":{\"command\":\"echo é and more than sixteen bytes\"}}]}}");
    const x = f.replay.state.agents.getPtr("a1").?;
    const started = x.transcript.items[x.transcript.items.len - 1].tool_started;
    const kept = started.raw_input.?;
    try testing.expect(kept.truncated and kept.text.len <= 16 and std.unicode.utf8ValidateSlice(kept.text));
    try testing.expectEqual(@as(u64, 49), kept.bytes);
    const raw = try rawPager(a, &f, started.call);
    try testing.expect(contains(raw, "\"truncated\": true") and contains(raw, "\"bytes\": 49"));

    // An older record: it loads, and `J` shows what there is.
    const old = try eventlog.Event.parse(a, try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"tool.started\",\"data\":{\"agent\":\"a1\",\"turn\":\"t2\",\"call\":\"c99\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"ls\"}}", .{}));
    try testing.expect(old.tool_started.raw_input == null);
    _ = try f.replay.apply(.{ .record = old });
    const none = try rawPager(a, &f, "c99");
    try testing.expect(contains(none, "\"name\": \"Bash\"") and !contains(none, "raw_input"));
}

test "agent.tool: a call whose turn ended with no tool.ended is interrupted, not running" {
    var r: Replay = undefined;
    try r.init("fake");
    defer r.deinit();
    _ = try r.apply(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } });
    _ = try r.apply(.{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash" } } });
    const x = r.state.agents.getPtr("a1").?;
    try testing.expectEqualStrings("running", agents.toolRecord("a1", x, "c1", null).?.status);
    // What a daemon restart logs.
    _ = try r.apply(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "failed", .error_code = "failed.daemon_restart" } } });
    try testing.expectEqualStrings("interrupted", agents.toolRecord("a1", x, "c1", null).?.status);
    try testing.expect(agents.toolRecord("a1", x, "c9", null) == null);
}

test "prompts: a steered prompt shows in its turn, a queued one starts the next; older logs have none" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Replay = undefined;
    try r.init("fake");
    defer r.deinit();
    r.conv.channel = NullChannel.channel();
    try r.conv.promptSent("first", .turn);
    try r.conv.promptSent("queued", .turn);
    try r.conv.turnStarted(null, "user");
    try r.conv.promptSent("steered", .steer);
    try r.conv.turnEnded("completed", null);
    try r.conv.turnStarted(null, "harness");
    try r.conv.turnEnded("completed", null);
    // Nothing waits: a turn the harness started on its own has no prompt.
    try r.conv.turnStarted(null, "harness");
    try r.conv.turnEnded("completed", null);
    // What a process took with it is not the next turn's.
    try r.conv.promptSent("lost", .turn);
    try r.conv.promptSent("lost too", .turn);
    r.conv.sending = true;
    try r.conv.abandon("failed.harness_exited");
    try r.conv.promptSent("after", .turn);
    try r.conv.turnStarted(null, "catch_up");
    try r.conv.prompt("from the harness");
    try r.conv.turnEnded("completed", null);
    try r.conv.turnStarted(null, "user");
    try r.conv.turnEnded("completed", null);
    const x = r.state.agents.getPtr("a1").?;
    var got: std.ArrayList(u8) = .empty;
    for (try agents.transcriptRecords(a, "a1", x, null, false)) |rec| if (std.mem.eql(u8, rec.type, "turn.prompt")) try got.print(a, "{s}:{s} ", .{ rec.turn, rec.text.? });
    try testing.expectEqualStrings("t1:first t1:steered t2:queued t4:lost t5:from the harness t6:after ", got.items);

    // A record from before prompts were logged: a turn with no prompt loads and draws.
    const old = try eventlog.Event.parse(a, try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"turn.started\",\"data\":{\"agent\":\"a1\",\"turn\":\"t7\",\"origin\":\"user\"}}", .{}));
    _ = try r.apply(.{ .record = old });
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    try r.show(a, &m, &d);
    var v: transcript.View = .{};
    defer v.deinit(ta);
    _ = try v.build(ta, &d, .{}, 78);
    try testing.expectEqualStrings("t7", d.records.items[d.records.items.len - 1].turn);
}

test "prompts: agent.show cuts a long one, within the bodies' budget" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Replay = undefined;
    try r.init("fake");
    defer r.deinit();
    const big = try a.alloc(u8, agents.show_body_max + 1);
    @memset(big, 'x');
    big[agents.show_body_max - 1] = 0xC3;
    big[agents.show_body_max] = 0xA9;
    const n = agents.show_bodies_max / agents.show_body_max + 2;
    for (0..n) |_| {
        try r.conv.promptSent(big, .turn);
        try r.conv.turnStarted(null, "user");
        try r.conv.turnEnded("completed", null);
    }
    const x = r.state.agents.getPtr("a1").?;
    var total: usize = 0;
    var last: []const u8 = "";
    for (try agents.transcriptRecords(a, "a1", x, null, false)) |rec| if (std.mem.eql(u8, rec.type, "turn.prompt")) {
        total += rec.text.?.len;
        last = rec.text.?;
        try testing.expect(std.unicode.utf8ValidateSlice(rec.text.?));
    };
    // The newest is whole up to the limit, ending in the mark; the log keeps it all.
    try testing.expect(std.mem.endsWith(u8, last, "…") and last.len == agents.show_body_max - 1 + "…".len);
    try testing.expect(total <= agents.show_bodies_max + n * "…".len);
    for (x.transcript.items) |e| if (e == .turn_prompt) try testing.expectEqual(big.len, e.turn_prompt.text.len);
}

test "keys: v cycles the density; ⏎ toggles the selected row; E and C act on all" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    // Normal: the edit's diff is open, the Bash output is not.
    var s = try k.press("");
    try testing.expect(contains(s, "▾ Edit") and contains(s, "+new") and contains(s, "▸ Bash") and !contains(s, "built"));
    // v: verbose opens everything; compact closes everything.
    s = try k.press("v");
    try testing.expect(k.app.density == .verbose and contains(s, "▾ Bash") and contains(s, "built"));
    s = try k.press("v");
    try testing.expect(k.app.density == .compact and contains(s, "▸ Edit") and !contains(s, "+new"));
    s = try k.press("v");
    try testing.expect(k.app.density == .normal);
    // k selects the last row (the tail, on screen); ⏎ opens it.
    s = try k.press("k");
    try testing.expectEqualStrings("c2", k.app.rows.selected);
    s = try k.press("\r");
    try testing.expect(contains(s, "▾ Bash") and contains(s, "built"));
    s = try k.press("\r");
    try testing.expect(contains(s, "▸ Bash") and !contains(s, "built"));
    // C closes all, E opens all.
    s = try k.press("C");
    try testing.expect(contains(s, "▸ Edit") and contains(s, "▸ Bash"));
    s = try k.press("E");
    try testing.expect(contains(s, "▾ Edit") and contains(s, "▾ Bash") and contains(s, "built"));
}

test "keys: p and J open the pager from agent.tool, whole; esc closes it" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    _ = try k.press("k");
    _ = try k.press("k");
    try testing.expectEqualStrings("c1", k.app.rows.selected);
    // The cut note says how to see the rest.
    var s = try k.press("");
    try testing.expect(contains(s, "cut at 15 of 90000 bytes"));
    s = try k.press("p");
    try testing.expectEqualStrings("agent.tool(a1) ", try tests.sent(a, &k.app));
    try testing.expect(contains(s, "Edit · a.zig") and contains(s, "j k scroll"));
    try tests.answer(&k.app, a, "agent.tool", "{\"agent\":\"a1\",\"call\":\"c1\",\"name\":\"Edit\",\"title\":\"a.zig\",\"body\":{\"text\":\"the whole\\nbody\",\"truncated\":false,\"bytes\":14}}");
    s = try k.press("");
    try testing.expect(contains(s, "the whole") and contains(s, "body"));
    s = try k.press("\x1b");
    try testing.expect(k.app.pager == null and !contains(s, "j k scroll"));

    s = try k.press("J");
    try testing.expectEqualStrings("agent.tool(a1) ", try tests.sent(a, &k.app));
    try testing.expect(contains(s, "raw JSON"));
    try tests.answer(&k.app, a, "agent.tool", "{\"agent\":\"a1\",\"call\":\"c1\",\"kind\":\"edit\"}");
    s = try k.press("");
    try testing.expect(contains(s, "\"kind\": \"edit\""));
    // A late answer of a closed pager goes nowhere.
    s = try k.press("q");
    try testing.expect(k.app.pager == null and !k.app.quit);
    s = try k.press("p");
    _ = try tests.sent(a, &k.app);
    s = try k.press("\x1b");
    try tests.answer(&k.app, a, "agent.tool", "{\"name\":\"late\"}");
}

test "settings: ui.transcript.density and open_running_after come from config.get" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    try k.app.requestTranscriptConfig();
    try testing.expectEqualStrings("config.get() config.get() ", try tests.sent(a, &k.app));
    try tests.answer(&k.app, a, "config.get", "{\"content\":\".verbose\",\"source\":\"user\"}");
    try tests.answer(&k.app, a, "config.get", "{\"content\":\"\\\"500ms\\\"\",\"source\":\"user\"}");
    try testing.expectEqual(Density.verbose, k.app.density);
    try testing.expectEqual(@as(u64, 500), k.app.open_running_after_ms);
}

test "choices are per agent: the same call id on another agent starts over" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    const tool = "\"requests\":[],\"transcript\":[{\"type\":\"tool.started\",\"turn\":\"t\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"x\",\"status\":\"ok\"}]}";
    try m.fillDetail(&d, try std.json.parseFromSliceLeaky(Value, a, "{\"agent\":\"a1\"," ++ tool, .{}));
    var v: transcript.View = .{};
    defer v.deinit(ta);
    _ = try v.build(ta, &d, .{ .density = .compact }, 60);
    try v.select(ta, 0);
    try v.choose(ta, 0, true, d.requests.items, .{});
    try testing.expect(!(try v.build(ta, &d, .{ .density = .compact }, 60))[0].collapsed);
    try m.fillDetail(&d, try std.json.parseFromSliceLeaky(Value, a, "{\"agent\":\"a2\"," ++ tool, .{}));
    try testing.expect((try v.build(ta, &d, .{ .density = .compact }, 60))[0].collapsed);
    try testing.expect(v.selectedRow() == null);
}

test "tick: an open running call's tail is asked for once a second" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    try k.app.tick();
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    const running =
        \\{"agent":"a1","title":"t","harness":"codex","state":"running","unread":false,"workspace":"/w","cwd":"/w","created_at":1,"changed_at":2,"turns":1,"requests":[],
        \\ "transcript":[{"type":"turn.started","turn":"t1"},{"type":"tool.started","turn":"t1","call":"c1","kind":"exec","name":"commandExecution","title":"sleep 100","status":"running","at":1794061790000,"tail":"line 1\n"}]}
    ;
    try k.app.requestShow();
    _ = try tests.sent(a, &k.app);
    try tests.answer(&k.app, a, "agent.show", running);
    // 10 s old, past the 5 s default: it shows open, with its tail.
    const s = try k.press("");
    try testing.expect(contains(s, "▾ commandExecution") and contains(s, "line 1") and contains(s, "◐ 0:10"));
    try k.app.tick();
    try testing.expectEqualStrings("agent.show(a1) ", try tests.sent(a, &k.app));
    try k.app.tick();
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
}

test "grouping: a failed read stays out of Explored, and a turn starts edits over" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    const rec = struct {
        fn tool(comptime call: []const u8, comptime kind: []const u8, comptime path: []const u8, comptime status: []const u8) []const u8 {
            return "{\"type\":\"tool.started\",\"turn\":\"t\",\"call\":\"" ++ call ++ "\",\"kind\":\"" ++ kind ++ "\",\"name\":\"N\",\"title\":\"" ++ path ++ "\",\"status\":\"pending\",\"args\":{\"path\":\"" ++ path ++ "\"}},{\"type\":\"tool.ended\",\"turn\":\"t\",\"call\":\"" ++ call ++ "\",\"status\":\"" ++ status ++ "\"},";
        }
    }.tool;
    const json = comptime "{\"agent\":\"a1\",\"turns\":2,\"requests\":[],\"transcript\":[" ++ rec("c1", "read", "a", "ok") ++ rec("c2", "read", "b", "error") ++ rec("c3", "read", "c", "ok") ++ rec("c4", "search", "d", "ok") ++ rec("c5", "edit", "e", "ok") ++ rec("c6", "exec", "f", "ok") ++ rec("c7", "edit", "e", "ok") ++ "{\"type\":\"turn.started\",\"turn\":\"t2\"}," ++ rec("c8", "edit", "e", "ok") ++ "{\"type\":\"text\",\"turn\":\"t2\",\"text\":\"x\"}]}";
    try m.fillDetail(&d, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    const got = try transcript.rows(a, d.records.items, d.requests.items, .{});
    var kinds: std.ArrayList(u8) = .empty;
    for (got) |r| try kinds.print(a, "{s}{d} ", .{ @tagName(r.kind), r.calls.len });
    try testing.expectEqualStrings("call1 call1 explored2 edits2 call1 turn_started0 call1 text0 ", kinds.items);
}

test "a row collapsed by hand opens again when it comes to need approval" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    const base = "{\"type\":\"tool.started\",\"turn\":\"t\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"x\",\"status\":\"pending\"}";
    try m.fillDetail(&d, try std.json.parseFromSliceLeaky(Value, a, "{\"agent\":\"a1\",\"requests\":[],\"transcript\":[" ++ base ++ "]}", .{}));
    var v: transcript.View = .{};
    defer v.deinit(ta);
    var blocks = try v.build(ta, &d, .{ .density = .compact }, 60);
    try testing.expect(blocks[0].collapsed);
    try v.choose(ta, 0, false, d.requests.items, .{});
    blocks = try v.build(ta, &d, .{ .density = .compact }, 60);
    try testing.expect(blocks[0].collapsed);
    try m.fillDetail(&d, try std.json.parseFromSliceLeaky(Value, a, "{\"agent\":\"a1\",\"requests\":[{\"kind\":\"approval\",\"reason\":\"Run x?\",\"stale\":false,\"call\":\"c1\"}],\"transcript\":[" ++ base ++ "]}", .{}));
    blocks = try v.build(ta, &d, .{ .density = .compact }, 60);
    try testing.expect(!blocks[0].collapsed);
}

// ---- PR review -------------------------------------------------------------

test "claude-code: an Edit's row shows the diff from structuredPatch, not its prose" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    var f: Fixture = .{ .harness = .claude };
    try f.init();
    defer f.deinit();
    const s = try snapshot(arena.allocator(), &f, .{ .density = .normal, .now_ms = f.replay.now + 1000 });
    try testing.expect(contains(s, "-pub const greeting = \"hello\";") and contains(s, "+pub const greeting = \"hi\";"));
    try testing.expect(!contains(s, "has been updated"));
    // Claude Code reports no exit code for Bash: none is made up.
    try testing.expect(contains(s, "error · 1.2s") and !contains(s, "exit "));
}

test "paste: no key context runs a pasted letter as a command" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    const paste = "\x1b[200~vpJECyanrsx?qiSRT\\\t\r\x1b[201~";
    // Transcript.
    const density = k.app.density;
    _ = try k.press(paste);
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    try testing.expect(k.app.density == density and k.app.pager == null and !k.app.help and !k.app.quit and k.app.menu == null);
    try testing.expectEqual(@import("app.zig").Area.transcript, k.app.area());
    // Agent list.
    k.app.focus.set(0);
    _ = try k.press(paste);
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    try testing.expect(!k.app.quit and k.app.screen == .main and k.app.menu == null);
    try testing.expectEqual(@import("app.zig").Area.list, k.app.area());
    // Inbox screen.
    k.app.openInbox();
    _ = try k.press(paste);
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    try testing.expect(k.app.screen == .inbox and !k.app.quit);
    k.app.screen = .main;
    // Split menu.
    _ = try k.press("\\");
    try testing.expect(k.app.menu != null);
    _ = try k.press("\x1b[200~1\r\x1b[201~");
    try testing.expect(k.app.menu != null and k.app.splits.items.len == 0);
    _ = try k.press("\x1b");
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    // The pager and the help stay as they are.
    k.app.help = true;
    _ = try k.press("\x1b[200~x\x1b[201~");
    try testing.expect(k.app.help);
    k.app.help = false;
    // Take-over question.
    k.app.ask = .{ .agent = try ta.dupe(u8, "a1"), .side = .right };
    _ = try k.press("\x1b[200~1\r\x1b[201~");
    try testing.expect(k.app.ask != null);
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    _ = try k.press("\x1b");
    // After the paste keys act again.
    k.app.focus.set(1);
    _ = try k.press("v");
    try testing.expect(k.app.density != density);
}

test "paste: into an attention prompt it is text, and a line break does not submit" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    k.app.prompt = .{ .mode = .deny_reason, .key = try ta.dupe(u8, "a1/r1"), .advance = false };
    _ = try k.press("\x1b[200~not\rnow y\x1b[201~");
    try testing.expectEqualStrings("not now y", k.app.answer_input.value());
    try testing.expect(k.app.prompt != null);
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
}

test "rows: a turn that ended with no tool.ended closes its calls, and the polling stops" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    const open =
        \\{"type":"turn.started","turn":"t1"},{"type":"tool.started","turn":"t1","call":"c1","kind":"exec","name":"Bash","title":"sleep 100","status":"running","at":1794061790000}
    ;
    const head = "{\"agent\":\"a1\",\"title\":\"t\",\"harness\":\"fake\",\"state\":\"failed\",\"unread\":false,\"workspace\":\"/w\",\"cwd\":\"/w\",\"created_at\":1,\"changed_at\":2,\"turns\":1,\"requests\":[],\"transcript\":[";
    try k.app.requestShow();
    _ = try tests.sent(a, &k.app);
    try tests.answer(&k.app, a, "agent.show", head ++ open ++ "]}");
    try k.app.tick();
    try testing.expectEqualStrings("agent.show(a1) ", try tests.sent(a, &k.app));
    // The daemon restarted: the turn is over, with no tool.ended.
    try tests.answer(&k.app, a, "agent.show", head ++ open ++ ",{\"type\":\"turn.ended\",\"turn\":\"t1\",\"reason\":\"failed\",\"error_code\":\"failed.daemon_restart\"}]}");
    const s = try k.press("");
    try testing.expect(contains(s, "interrupted") and !contains(s, "◐"));
    k.app.now_ms += 5000;
    try k.app.tick();
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
}

test "rows: select another agent, then p, in one read: the old rows are not used" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    k.app.focus.set(0);
    // j moves the list (a new agent is selected and its detail cleared); tab
    // focuses the transcript; p comes before any draw.
    _ = try k.app.feed("jj\tp");
    try testing.expect(!std.mem.eql(u8, k.app.selected.items, "a1"));
    try testing.expect(k.app.pager == null);
    _ = try k.app.feed("Jv");
    try testing.expect(k.app.pager == null);
}

test "rows: a body past agent.show's budget says so, and an open row fetches it whole" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    const json =
        \\{"agent":"a1","title":"t","harness":"fake","state":"failed","unread":false,"workspace":"/w","cwd":"/w","created_at":1,"changed_at":2,"turns":1,"requests":[],
        \\ "transcript":[{"type":"turn.started","turn":"t1"},{"type":"tool.started","turn":"t1","call":"c1","kind":"exec","name":"Bash","title":"make","status":"pending"},
        \\ {"type":"tool.ended","turn":"t1","call":"c1","status":"error","exit":2,"body":{"text":"","truncated":true,"bytes":9000}}]}
    ;
    try k.app.requestShow();
    _ = try tests.sent(a, &k.app);
    try tests.answer(&k.app, a, "agent.show", json);
    var s = try k.press("");
    try testing.expect(contains(s, "9000 bytes of output"));
    try testing.expectEqualStrings("agent.tool(a1) ", try tests.sent(a, &k.app));
    // Asked once only.
    s = try k.press("");
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    var it = k.app.pending.iterator();
    const id = while (it.next()) |e| {
        if (e.value_ptr.* == .full_body) break e.key_ptr.*;
    } else unreachable;
    try k.app.onResponse(id, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, "{\"body\":{\"text\":\"the real error\",\"truncated\":false,\"bytes\":14}}", .{}) });
    s = try k.press("");
    try testing.expect(contains(s, "the real error") and !contains(s, "9000 bytes"));
    // Still whole after the next refresh.
    try k.app.requestShow();
    _ = try tests.sent(a, &k.app);
    try tests.answer(&k.app, a, "agent.show", json);
    s = try k.press("");
    try testing.expect(contains(s, "the real error"));
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
}

test "rows: verbose asks for bodies agent.show cut; normal's first lines do not" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    _ = try k.press("");
    try testing.expectEqualStrings("", try tests.sent(a, &k.app));
    _ = try k.press("v");
    try testing.expect(k.app.density == .verbose);
    try testing.expectEqualStrings("agent.tool(a1) ", try tests.sent(a, &k.app));
}

test "rows: a sub-agent's failed call opens its row and shows, even when old" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    const child = struct {
        fn at(comptime id: []const u8, comptime status: []const u8, comptime body: []const u8) []const u8 {
            return ",{\"type\":\"tool.started\",\"turn\":\"t\",\"call\":\"" ++ id ++ "\",\"parent_call\":\"p\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"" ++ id ++ "\",\"status\":\"pending\"},{\"type\":\"tool.ended\",\"turn\":\"t\",\"call\":\"" ++ id ++ "\",\"status\":\"" ++ status ++ "\",\"body\":{\"text\":\"" ++ body ++ "\",\"truncated\":false,\"bytes\":3}}";
        }
    }.at;
    const json = comptime "{\"agent\":\"a1\",\"requests\":[],\"transcript\":[{\"type\":\"tool.started\",\"turn\":\"t\",\"call\":\"p\",\"kind\":\"agent\",\"name\":\"Agent\",\"title\":\"sub\",\"status\":\"pending\"},{\"type\":\"tool.ended\",\"turn\":\"t\",\"call\":\"p\",\"status\":\"ok\"}" ++ child("c1", "error", "boom") ++ child("c2", "ok", "fine") ++ child("c3", "ok", "fine") ++ child("c4", "ok", "fine") ++ child("c5", "ok", "fine") ++ child("c6", "ok", "fine") ++ child("c7", "ok", "fine") ++ child("c8", "ok", "fine") ++ "]}";
    try m.fillDetail(&d, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    var v: transcript.View = .{};
    defer v.deinit(ta);
    const blocks = try v.build(ta, &d, .{ .density = .compact }, 70);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expect(!blocks[0].collapsed);
    var text: std.ArrayList(u8) = .empty;
    for (blocks[0].spans) |s| try text.appendSlice(a, s.text);
    try testing.expect(contains(text.items, "boom") and contains(text.items, "✕ 1 failed · 8 calls"));
    try testing.expect(contains(text.items, "… 1 earlier calls"));
}

// ---- The wrap cache --------------------------------------------------------

/// `agent.show`'s answer with `texts` text records, then `rest` (JSON records,
/// each with a comma in front).
fn showTexts(a: std.mem.Allocator, texts: usize, rest: []const u8) !Value {
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(a, "{\"agent\":\"a1\",\"turns\":1,\"requests\":[],\"transcript\":[{\"type\":\"turn.started\",\"turn\":\"t1\"}");
    for (0..texts) |i| try json.print(a, ",{{\"type\":\"text\",\"turn\":\"t1\",\"text\":\"line {d}\"}}", .{i});
    try json.appendSlice(a, rest);
    try json.appendSlice(a, "]}");
    return std.json.parseFromSliceLeaky(Value, a, json.items, .{});
}

test "wrap cache: a new record on a 10000-block transcript re-wraps only its block, through the app" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const a = k.arena.allocator();
    const scroll = &k.app.scroll;
    const d = &k.app.model.detail;
    // `agent.show` replaces every record: the text moves, the content doesn't.
    try k.app.model.fillDetail(d, try showTexts(a, 9_999, ""));
    try view.render(&k.app, &k.surface);
    try testing.expectEqual(@as(usize, 10_000), scroll.entries.items.len);

    var wraps = scroll.wraps;
    try k.app.model.fillDetail(d, try showTexts(a, 10_000, ""));
    try view.render(&k.app, &k.surface);
    try testing.expectEqual(wraps + 1, scroll.wraps);
    try testing.expect(contains(try tests.dump(a, &k.surface), "line 9999"));

    // A frame with no change neither wraps nor scans.
    wraps = scroll.wraps;
    const scans = scroll.scans;
    try view.render(&k.app, &k.surface);
    try view.render(&k.app, &k.surface);
    try testing.expectEqual(wraps, scroll.wraps);
    try testing.expectEqual(scans, scroll.scans);
}

test "wrap cache: only the blocks a change touched re-wrap" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    var v: transcript.View = .{};
    defer v.deinit(ta);
    var scroll: term.widgets.ScrollView = .{};
    defer scroll.deinit(ta);
    const read = ",{\"type\":\"tool.started\",\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"read\",\"name\":\"Read\",\"title\":\"a\",\"status\":\"pending\",\"at\":1000}";
    const read2 = ",{\"type\":\"tool.started\",\"turn\":\"t1\",\"call\":\"c2\",\"kind\":\"read\",\"name\":\"Read\",\"title\":\"b\",\"status\":\"pending\",\"at\":1000}";
    var o: transcript.Options = .{ .now_ms = 1000, .open_running_after_ms = 1_000_000 };

    try m.fillDetail(&d, try showTexts(a, 10_000, read));
    try scroll.layout(ta, try v.build(ta, &d, o, 80), 80);
    try testing.expectEqual(@as(u64, 10_002), scroll.wraps);

    // A running call's clock ticks: its row changes, nothing else.
    o.now_ms = 2000;
    try scroll.layout(ta, try v.build(ta, &d, o, 80), 80);
    try testing.expectEqual(@as(u64, 10_003), scroll.wraps);

    // A read merges into the row before it: no new row, and that row changes.
    try m.fillDetail(&d, try showTexts(a, 10_000, read ++ read2));
    const merged = try v.build(ta, &d, o, 80);
    try testing.expectEqual(@as(usize, 10_002), merged.len);
    try scroll.layout(ta, merged, 80);
    try testing.expectEqual(@as(u64, 10_004), scroll.wraps);

    // New bytes of the same length, in the middle: that block alone, with a
    // new revision, so it can't pass for the old one even at the same address.
    const before = merged[5000 + 1].revision;
    const untouched = merged[5000 + 2];
    const again = try showTexts(a, 10_000, read ++ read2);
    again.object.get("transcript").?.array.items[5001].object.getPtr("text").?.string = "LINE 5000";
    try m.fillDetail(&d, again);
    const edited = try v.build(ta, &d, o, 80);
    try testing.expect(edited[5001].revision != before);
    try testing.expectEqualStrings("LINE 5000", edited[5001].spans[0].text);
    try testing.expectEqual(untouched.revision, edited[5002].revision);
    try testing.expectEqual(untouched.spans.ptr, edited[5002].spans.ptr);
    try scroll.layout(ta, edited, 80);
    try testing.expectEqual(@as(u64, 10_005), scroll.wraps);

    // Fewer records: the rest go, and what stays isn't wrapped again.
    try m.fillDetail(&d, try showTexts(a, 100, ""));
    try scroll.layout(ta, try v.build(ta, &d, o, 80), 80);
    try testing.expectEqual(@as(u64, 10_005), scroll.wraps);
    try testing.expectEqual(@as(usize, 101), v.kept.items.len);
}

test "wrap cache: toggles and E C draw right and promise nothing they changed" {
    var k: Keys = undefined;
    try k.init();
    defer k.deinit();
    const scroll = &k.app.scroll;
    // Each frame after a change scans again, then doesn't; a broken promise
    // would panic here.
    for ([_][]const u8{ "k", "\r", "\r", "C", "E", "v", "v", "v" }) |key| {
        _ = try k.press(key);
        const scans = scroll.scans;
        _ = try k.press("");
        try testing.expectEqual(scans, scroll.scans);
    }
    // A toggle right after a frame that promised still shows.
    var s = try k.press("C");
    try testing.expect(contains(s, "▸ Bash") and !contains(s, "built"));
    s = try k.press("\r");
    try testing.expect(contains(s, "▾ Bash") and contains(s, "built"));
}

test "skipUnchanged: no promise unless the scroll view last laid out these blocks" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    var v: transcript.View = .{};
    defer v.deinit(ta);
    var scroll: term.widgets.ScrollView = .{};
    defer scroll.deinit(ta);
    var surface = try term.Surface.init(ta, 40, 5);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    const theme: term.widgets.Theme = .default;
    const region: term.Region = .{ .width = 40, .height = 5 };
    const draw = struct {
        fn f(s: *term.widgets.ScrollView, view_: *transcript.View, sf: *term.Surface, r: term.Region, blocks: []const term.widgets.Block, t: *const term.widgets.Theme) !void {
            transcript.skipUnchanged(s, view_, blocks, r);
            try s.draw(ta, sf, r, blocks, t, false);
        }
    }.f;
    try m.fillDetail(&d, try showTexts(a, 4, ""));
    const blocks = try v.build(ta, &d, .{}, 40);

    // The first draw has nothing to promise, the second does.
    try draw(&scroll, &v, &surface, region, blocks, &theme);
    try testing.expectEqual(@as(u64, 5), scroll.scans);
    try draw(&scroll, &v, &surface, region, try v.build(ta, &d, .{}, 40), &theme);
    try testing.expectEqual(@as(u64, 5), scroll.scans);

    // Blocks after the view's are still looked at.
    var more: std.ArrayList(term.widgets.Block) = .empty;
    try more.appendSlice(a, blocks);
    try more.append(a, .{ .spans = &.{.{ .text = "▲ request" }} });
    try draw(&scroll, &v, &surface, region, more.items, &theme);
    try testing.expectEqual(@as(u64, 6), scroll.scans);
    try draw(&scroll, &v, &surface, region, blocks, &theme);

    // "No agents yet", then the same rows again: the rows were replaced.
    // As many blocks as there were rows, so only their spans tell them apart.
    const none = try a.alloc(term.widgets.Block, blocks.len);
    @memset(none, .{ .spans = &.{.{ .text = "No agents yet." }} });
    try draw(&scroll, &v, &surface, region, none, &theme);
    const scans = scroll.scans;
    try draw(&scroll, &v, &surface, region, blocks, &theme);
    try testing.expectEqual(scans + blocks.len, scroll.scans);

    // A rebuild with no room lays nothing out, so the next draw can't promise.
    d.revision +%= 1;
    d.records.items[1].text[0] = 'L';
    const rebuilt = try v.build(ta, &d, .{}, 40);
    try draw(&scroll, &v, &surface, .{ .width = 40, .height = 0 }, rebuilt, &theme);
    try draw(&scroll, &v, &surface, region, rebuilt, &theme);
    try testing.expectEqualStrings("Line 0", rebuilt[1].spans[0].text);
    // A real draw again, and the promise is back.
    const settled = scroll.scans;
    try draw(&scroll, &v, &surface, region, rebuilt, &theme);
    try testing.expectEqual(settled, scroll.scans);
}

test "wrap cache: a build that runs out of memory is whole again on the next one" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var m = model.Model.init(ta);
    defer m.deinit();
    var d: model.Detail = .{};
    defer d.deinit(ta);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try m.fillDetail(&d, try showTexts(a, 3, ""));
        var v: transcript.View = .{};
        defer v.deinit(ta);
        // The arena takes this allocator, so only `keep` will fail below.
        _ = try v.build(ta, &d, .{}, 40);
        try m.fillDetail(&d, try showTexts(a, 6, ""));
        d.records.items[1].text[0] = 'L';
        var failing: testing.FailingAllocator = .init(ta, .{ .fail_index = fail_index });
        const failed = if (v.build(failing.allocator(), &d, .{}, 40)) |_| false else |_| true;
        const blocks = try v.build(ta, &d, .{}, 40);
        try testing.expectEqual(@as(usize, 7), blocks.len);
        try testing.expectEqualStrings("Line 0", blocks[1].spans[0].text);
        try testing.expectEqualStrings("line 5", blocks[6].spans[0].text);
        if (!failed) break;
    }
    try testing.expect(fail_index > 0);
}
