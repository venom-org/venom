//! Fan-out block and sub-agent navigation: a parent's block with children
//! in mixed states, `[` `]` and the
//! breadcrumb, and the keys' verbs. `subagent_tests.zig` runs wait, stop and
//! promote against a daemon.
const std = @import("std");
const term = @import("venom-term");
const App = @import("app.zig").App;
const fan_out = @import("fan_out.zig");
const t = @import("tests.zig");
const view = @import("view.zig");
const testing = std.testing;
const ta = testing.allocator;

const snapshot =
    \\{"seq":40,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"state.snapshot","data":{"reason":"initial","complete":true,"entities":[
    \\{"resource":"agent:p1","entity_type":"agent","content":"{\"agent\":\"p1\",\"title\":\"rename proto.Frame\",\"harness\":\"claude-code\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:c1","entity_type":"agent","content":"{\"agent\":\"c1\",\"title\":\"venom-std\",\"harness\":\"claude-code\",\"state\":\"settled\",\"unread\":false}"},
    \\{"resource":"agent:c2","entity_type":"agent","content":"{\"agent\":\"c2\",\"title\":\"venomx\",\"harness\":\"codex\",\"state\":\"needs_you\",\"unread\":false}"},
    \\{"resource":"agent:c2","entity_type":"attention","content":"{\"agent\":\"c2\",\"requests\":[{\"request\":\"r1\",\"kind\":\"approval\",\"reason\":\"write outside the worktree\",\"stale\":false}]}"},
    \\{"resource":"agent:c3","entity_type":"agent","content":"{\"agent\":\"c3\",\"title\":\"venom-docs\",\"harness\":\"claude-code\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:c4","entity_type":"agent","content":"{\"agent\":\"c4\",\"title\":\"venom-term\",\"harness\":\"claude-code\",\"state\":\"failed\",\"unread\":false}"},
    \\{"resource":"agent:n1","entity_type":"agent","content":"{\"agent\":\"n1\",\"title\":\"explore-vectors\",\"harness\":\"claude-code\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:g1","entity_type":"agent","content":"{\"agent\":\"g1\",\"title\":\"refactor\",\"harness\":\"claude-code\",\"state\":\"failed\",\"unread\":false}"}]}}
;

fn listed(comptime id: []const u8, comptime rest: []const u8) []const u8 {
    return "{\"agent\":\"" ++ id ++ "\",\"workspace\":\"/w\",\"cwd\":\"/w\",\"created_at\":1794061200000,\"changed_at\":1794061740000," ++ rest ++ "}";
}

const list = "{\"agents\":[" ++
    listed("p1", "\"parent\":null") ++ "," ++
    listed("c1", "\"parent\":\"p1\"") ++ "," ++
    listed("c2", "\"parent\":\"p1\"") ++ "," ++
    listed("c3", "\"parent\":\"p1\"") ++ "," ++
    listed("c4", "\"parent\":\"p1\"") ++ "," ++
    listed("n1", "\"parent\":\"p1\",\"native\":true") ++ "," ++
    listed("g1", "\"parent\":\"c3\"") ++ "]}";

fn shown(comptime id: []const u8, comptime records: []const u8) []const u8 {
    return "{\"agent\":\"" ++ id ++ "\",\"turns\":1,\"requests\":[],\"transcript\":[" ++ records ++ "]}";
}

const tool = "{\"type\":\"tool.started\",\"turn\":\"t1\",\"call\":\"x\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build test\",\"status\":\"running\"}";

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    surface: term.Surface,

    fn init(self: *Fixture) !void {
        self.arena = .init(ta);
        self.app = App.init(ta);
        self.surface = try term.Surface.init(ta, 80, 30);
        const a = self.arena.allocator();
        self.app.now_ms = 1794061800000;
        try self.app.onConnected();
        try t.feedJson(&self.app, a, snapshot);
        try t.answer(&self.app, a, "agent.list", list);
        try self.app.preselect("p1");
        self.app.focus.set(1);
    }

    fn deinit(self: *Fixture) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.app.deinit();
        self.arena.deinit();
    }

    /// Answers `agent.show` for each child read so far.
    fn answerCards(self: *Fixture) !void {
        const a = self.arena.allocator();
        while (true) {
            var it = self.app.pending.iterator();
            const entry = while (it.next()) |e| {
                if (e.value_ptr.* == .card_show) break e;
            } else return;
            const id = entry.value_ptr.card_show;
            const json: []const u8 = if (std.mem.eql(u8, id, "c1"))
                shown("c1", tool ++ ",{\"type\":\"text\",\"turn\":\"t1\",\"text\":\"PR #31 opened\\ntests pass\"},{\"type\":\"turn.ended\",\"turn\":\"t1\",\"reason\":\"completed\"}")
            else if (std.mem.eql(u8, id, "c4"))
                shown("c4", "{\"type\":\"turn.ended\",\"turn\":\"t1\",\"reason\":\"failed\"}")
            else if (std.mem.eql(u8, id, "c2") or std.mem.eql(u8, id, "c3"))
                shown("c3", tool)
            else
                shown("n1", "");
            const key = entry.key_ptr.*;
            try self.app.onResponse(key, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) });
        }
    }

    fn draw(self: *Fixture) ![]const u8 {
        const a = self.arena.allocator();
        try view.render(&self.app, &self.surface);
        try self.answerCards();
        try view.render(&self.app, &self.surface);
        _ = try t.sent(a, &self.app);
        return std.mem.trimEnd(u8, try t.dump(a, &self.surface), "\n");
    }
};

/// The transcript's column of a drawn screen, without its right border.
fn column(a: std.mem.Allocator, screen: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, "│╭") != null) break;
        const start = std.mem.indexOf(u8, l, "││") orelse continue;
        const body = std.mem.trimEnd(u8, l[start + "││".len ..], " │");
        try out.appendSlice(a, body);
        try out.append(a, '\n');
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "fan-out block: one card per child in mixed states, with last activity and result" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectEqualStrings(
        \\ ⑂ Fan-out: 5 agents               ▲ 1  ✕ 1  ◆ 2  ● 1
        \\ ▾ ⑂ venom-std claude-code             ● settled · 1m
        \\     last: Bash  zig build test
        \\     result: PR #31 opened …
        \\ ▾ ⑂ venomx  codex                   ▲ needs you · 1m
        \\     last: Bash  zig build test
        \\     ▲ write outside the worktree
        \\ ▾ ⑂ venom-docs claude-code · ▲ 1 be…  ◆ running · 1m
        \\     last: Bash  zig build test
        \\ ▾ ⑂ venom-term claude-code             ✕ failed · 1m
        \\     ✕ turn failed
        \\ ▾ · explore-vectors claude-code · n…  ◆ running · 1m
        \\   ] open child  \ split view  w wait for all  K stop
        \\   all  P promote
    , try column(a, try f.draw()));
}

test "fan-out block: a card's first line is all compact shows; ⏎ folds a card; an agent with no children has no block" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.draw();
    // k lands on the last card, from the tail.
    _ = try f.app.feed("k\r");
    var screen = try f.draw();
    try testing.expect(contains(screen, "▸ · explore-vectors"));
    _ = try f.app.feed("v"); // verbose
    _ = try f.app.feed("vv"); // back to normal: choices start over
    _ = try f.draw();
    f.app.density = .compact;
    f.app.rows.reset(ta);
    screen = try f.draw();
    try testing.expect(contains(screen, "▸ ⑂ venom-std"));
    try testing.expect(!contains(screen, "result: PR #31"));
    try testing.expect(contains(screen, "● settled"));
    // A leaf: no block.
    try f.app.setSelected("c1");
    _ = try t.sent(a, &f.app);
    screen = try f.draw();
    try testing.expect(!contains(screen, "Fan-out"));
}

test "[ and ]: ] goes to the child that needs you, the header's breadcrumb follows, [ comes back and ] returns" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.draw();
    _ = try f.app.feed("]");
    try testing.expectEqualStrings("c2", f.app.selected.items);
    try testing.expect(contains(try f.draw(), "╭ rename proto.Frame › venomx ─"));

    // A leaf has no child to go to, and the row says so.
    _ = try f.app.feed("]");
    try testing.expectEqualStrings("c2", f.app.selected.items);
    try testing.expectEqualStrings("no sub-agent to open", f.app.message.items);

    _ = try f.app.feed("[");
    try testing.expectEqualStrings("p1", f.app.selected.items);
    try testing.expect(contains(try f.draw(), "╭ rename proto.Frame ─"));
    _ = try f.app.feed("[");
    try testing.expectEqualStrings("p1", f.app.selected.items);
    try testing.expectEqualStrings("p1 is a top-level agent", f.app.message.items);

    // Back into the child it came from, via a card when one has the cursor.
    _ = try f.draw();
    _ = try f.app.feed("kk");
    _ = try f.app.feed("]");
    try testing.expectEqualStrings("c4", f.app.selected.items);
    _ = try f.app.feed("[");
    _ = try f.draw();
    _ = try f.app.feed("]");
    try testing.expectEqualStrings("c4", f.app.selected.items);

    // A grandchild: two steps in the breadcrumb, older ones go first when narrow.
    try f.app.setSelected("g1");
    try testing.expect(contains(try f.draw(), "╭ … › venom-docs › refactor ─"));
    try testing.expectEqualStrings("rename proto.Frame › venom-docs › refactor", try fan_out.breadcrumb(&f.app, a, f.app.model.find("g1").?, 60));
    try testing.expectEqualStrings("… › venom-docs › refactor", try fan_out.breadcrumb(&f.app, a, f.app.model.find("g1").?, 30));
    try testing.expectEqualStrings("… › refactor", try fan_out.breadcrumb(&f.app, a, f.app.model.find("g1").?, 5));
}

test "[ and ]: a child the list hides stays selected, with the cursor on its parent, until the cursor moves" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.draw();
    f.app.children = .hidden;
    _ = try f.draw();
    _ = try f.app.feed("]");
    try testing.expectEqualStrings("c2", f.app.selected.items);
    const screen = try f.draw();
    try testing.expectEqualStrings("c2", f.app.selected.items);
    try testing.expect(contains(screen, "› venomx"));
    // The list moves on: the pin is gone, and the selection goes with the cursor.
    f.app.focus.set(0);
    _ = try f.app.feed("j");
    try testing.expect(!f.app.fan.pinned);
    try testing.expectEqualStrings("p1", f.app.selected.items);
}

test "w, K, P call their verbs, on the parent or the focused card; \\ opens the card's child" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.draw();

    // K: the tree.
    _ = try f.app.feed("K");
    try testing.expect(contains(f.app.outbox.items[0], "\"tree\":true"));
    try testing.expectEqualStrings("agent.stop(p1) ", try t.sent(a, &f.app));

    // w: agent.wait, held, shown in the block; a second w doesn't ask again.
    _ = try f.app.feed("w");
    try testing.expectEqualStrings("agent.wait(p1) ", try t.sent(a, &f.app));
    _ = try f.app.feed("w");
    try testing.expectEqualStrings("", try t.sent(a, &f.app));
    try testing.expectEqualStrings("already waiting for p1's sub-agents", f.app.message.items);
    try testing.expect(contains(try f.draw(), "◐ waiting for all"));
    var it = f.app.pending.iterator();
    const wait_id = while (it.next()) |e| {
        if (e.value_ptr.* == .fan_wait) break e.key_ptr.*;
    } else return error.NotPending;
    try f.app.onResponse(wait_id, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"agent\":\"p1\",\"done\":false,\"children\":[]}", .{}) });
    try testing.expectEqualStrings("p1's sub-agents are still going; the wait timed out", f.app.message.items);
    try testing.expect(contains(try f.draw(), "w wait for all"));

    // P: no card has the cursor, and a top-level agent isn't promoted.
    _ = try f.app.feed("P");
    try testing.expectEqualStrings("", try t.sent(a, &f.app));
    try testing.expectEqualStrings("promote: pick a child's card with j k first", f.app.message.items);

    // On the native card: refused here.
    _ = try f.app.feed("kP");
    try testing.expectEqualStrings("", try t.sent(a, &f.app));
    try testing.expect(contains(f.app.message.items, "Message the parent to steer it"));

    // On a spawned card: the verb, for the child.
    _ = try f.app.feed("kP");
    try testing.expectEqualStrings("agent.promote(c4) ", try t.sent(a, &f.app));

    // `\`: the split menu of the card's child.
    _ = try f.app.feed("\\");
    try testing.expectEqualStrings("c4", f.app.menu.?.agent);
    _ = try f.app.feed("\x1b");

    // The promoted child leaves the block; `agent.promoted` is all it takes.
    try t.feedJson(&f.app, a,
        \\{"seq":41,"ts":"2026-11-06T14:31:00.000Z","source":"venom/0e1","type":"agent.promoted","data":{"agent":"c4","parent":"p1"}}
    );
    try testing.expect(contains(try f.draw(), "Fan-out: 4 agents"));

    // An agent with no children has nothing to wait for.
    try f.app.setSelected("c1");
    _ = try t.sent(a, &f.app);
    _ = try f.app.feed("w");
    try testing.expectEqualStrings("", try t.sent(a, &f.app));
    try testing.expectEqualStrings("c1 has no sub-agents to wait for", f.app.message.items);
}

test "a native child shows the steer message instead of an input box, and takes no text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.app.setSelected("n1");
    _ = try t.sent(a, &f.app);
    const screen = try f.draw();
    try testing.expect(contains(screen, "╭ Owned by claude-code "));
    try testing.expect(contains(screen, "Message the parent to steer it."));
    try testing.expect(!contains(screen, "╭ Input "));
    f.app.focus.set(2);
    _ = try f.app.feed("hi\r");
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expectEqualStrings("", try t.sent(a, &f.app));
    try testing.expect(contains(f.app.message.items, "Message the parent to steer it"));
    // A paste can't get in either.
    _ = try f.app.feed("\x1b[200~pasted\x1b[201~");
    try testing.expectEqualStrings("", f.app.input.value());
    // `[` still leads out.
    _ = try f.app.feed("[");
    try testing.expectEqualStrings("p1", f.app.selected.items);

    // A spawned child between turns says who sees a prompt.
    try f.app.setSelected("c1");
    try testing.expect(contains(try f.draw(), "Prompt venom-std directly. The parent sees it."));
}

test "a harness's own sub-agent row: ] opens its calls in the pager while the daemon reports no agent for it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.app.setSelected("c1");
    _ = try t.sent(a, &f.app);
    try t.answer(&f.app, a, "agent.show",
        \\{"agent":"c1","turns":1,"requests":[],"transcript":[
        \\{"type":"tool.started","turn":"t1","call":"s1","kind":"agent","name":"Agent","title":"Read notes","status":"running","args":{"child_ref":"x9"}},
        \\{"type":"tool.started","turn":"t1","call":"s2","parent_call":"s1","kind":"read","name":"Read","title":"notes.txt","status":"running"}]}
    );
    const screen = try f.draw();
    try testing.expect(contains(screen, "] to open"));
    _ = try f.app.feed("]");
    try testing.expectEqualStrings("c1", f.app.selected.items);
    try testing.expect(f.app.pager != null);
    try testing.expectEqual(@as(usize, 2), f.app.pager.?.parts.len);
    _ = try t.sent(a, &f.app);
}
