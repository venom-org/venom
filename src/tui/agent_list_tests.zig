//! Snapshot tests of the agent list:
//! each grouping, each children mode, bubbling in hidden mode and the filter,
//! drawn from a model fed the way the daemon feeds it.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const App = @import("app.zig").App;
const agent_list = @import("agent_list.zig");
const t = @import("tests.zig");
const view = @import("view.zig");
const testing = std.testing;
const ta = testing.allocator;

/// A fan-out with a grandchild that failed, an agent with a
/// native sub-agent, one in a folder with no repos, an unread settled one.
const snapshot =
    \\{"seq":40,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"state.snapshot","data":{"reason":"initial","complete":true,"entities":[
    \\{"resource":"agent:a1","entity_type":"agent","content":"{\"agent\":\"a1\",\"title\":\"venom-echo conformance\",\"harness\":\"claude\",\"state\":\"needs_you\",\"unread\":false}"},
    \\{"resource":"agent:a1","entity_type":"attention","content":"{\"agent\":\"a1\",\"requests\":[{\"request\":\"r1\",\"kind\":\"approval\",\"reason\":\"approve: zig build test\",\"stale\":false}]}"},
    \\{"resource":"agent:n1","entity_type":"agent","content":"{\"agent\":\"n1\",\"title\":\"explore-vectors\",\"harness\":\"claude\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:p1","entity_type":"agent","content":"{\"agent\":\"p1\",\"title\":\"rename proto.Frame\",\"harness\":\"claude\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:c1","entity_type":"agent","content":"{\"agent\":\"c1\",\"title\":\"venom-std\",\"harness\":\"claude\",\"state\":\"settled\",\"unread\":false}"},
    \\{"resource":"agent:c2","entity_type":"agent","content":"{\"agent\":\"c2\",\"title\":\"venomx\",\"harness\":\"codex\",\"state\":\"needs_you\",\"unread\":false}"},
    \\{"resource":"agent:c3","entity_type":"agent","content":"{\"agent\":\"c3\",\"title\":\"venom-docs\",\"harness\":\"claude\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:g1","entity_type":"agent","content":"{\"agent\":\"g1\",\"title\":\"refactor\",\"harness\":\"claude\",\"state\":\"failed\",\"unread\":false}"},
    \\{"resource":"agent:s1","entity_type":"agent","content":"{\"agent\":\"s1\",\"title\":\"sort warnings\",\"harness\":\"codex\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:d1","entity_type":"agent","content":"{\"agent\":\"d1\",\"title\":\"cfg schema verbs\",\"harness\":\"codex\",\"state\":\"settled\",\"unread\":true}"},
    \\{"resource":"agent:o1","entity_type":"agent","content":"{\"agent\":\"o1\",\"title\":\"old spike\",\"harness\":\"codex\",\"state\":\"archived\",\"unread\":false}"}]}}
;

fn listed(comptime id: []const u8, comptime rest: []const u8) []const u8 {
    return "{\"agent\":\"" ++ id ++ "\",\"created_at\":1794061200000,\"changed_at\":1794061740000," ++ rest ++ "}";
}

const org = "\"workspace\":\"/home/me/venom-org\",\"cwd\":\"/home/me/venom-org\",";

const list = "{\"agents\":[" ++
    listed("a1", org ++ "\"repos\":[\"venom-std\"],\"parent\":null,\"issue\":\"216\"") ++ "," ++
    listed("n1", org ++ "\"repos\":[\"venom-std\"],\"parent\":\"a1\",\"native\":true") ++ "," ++
    listed("p1", org ++ "\"repos\":[\"venom-std\",\"venomx\",\"venom-docs\"],\"parent\":null") ++ "," ++
    listed("c1", org ++ "\"repos\":[\"venom-std\"],\"parent\":\"p1\"") ++ "," ++
    listed("c2", org ++ "\"repos\":[\"venomx\"],\"parent\":\"p1\",\"issue\":\"244\"") ++ "," ++
    listed("c3", org ++ "\"repos\":[\"venom-docs\"],\"parent\":\"p1\"") ++ "," ++
    listed("g1", org ++ "\"repos\":[\"venom-docs\"],\"parent\":\"c3\"") ++ "," ++
    listed("s1", "\"workspace\":\"/home/me/scratch\",\"cwd\":\"/home/me/scratch\",\"repos\":[],\"parent\":null") ++ "," ++
    listed("d1", org ++ "\"repos\":[\"venom-std\"],\"parent\":null") ++ "," ++
    listed("o1", "\"workspace\":\"/home/me/scratch\",\"cwd\":\"/home/me/scratch\",\"repos\":[],\"parent\":null") ++ "]}";

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    surface: term.Surface,

    fn init(self: *Fixture) !void {
        self.arena = .init(ta);
        self.app = App.init(ta);
        self.surface = try term.Surface.init(ta, 43, 22);
        const a = self.arena.allocator();
        self.app.home = "/home/me";
        self.app.now_ms = 1794061800000;
        try self.app.onConnected();
        try t.feedJson(&self.app, a, snapshot);
        try t.answer(&self.app, a, "agent.list", list);
    }

    fn deinit(self: *Fixture) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.app.deinit();
        self.arena.deinit();
    }

    /// The list alone, as the main view draws it (rows, not the box).
    fn draw(self: *Fixture) ![]const u8 {
        const a = self.arena.allocator();
        _ = self.app.frame.reset(.retain_capacity);
        const r = try self.app.buildRows();
        try self.app.syncCursor(r);
        try self.surface.clear(.{ .width = self.surface.width, .height = self.surface.height }, self.app.theme.style(.normal));
        try self.app.list.draw(&self.surface, .{ .width = self.surface.width, .height = self.surface.height }, r, &self.app.theme, false);
        _ = try t.sent(a, &self.app);
        return std.mem.trimEnd(u8, try t.dump(a, &self.surface), "\n");
    }

    fn feed(self: *Fixture, bytes: []const u8) !void {
        _ = try self.app.feed(bytes);
    }
};

test "group by state: Needs you, Running, Settled, then one folded Archived line" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectEqualStrings(
        \\ ▾ NEEDS YOU  1 ───────────────────────────
        \\ ▲ venom-echo conformance                1m
        \\   claude · venom-std · 1 sub · approve: z…
        \\   └· ◆ explore-vectors                  1m
        \\ ▾ RUNNING  2 ─────────────────────────────
        \\ ◆ sort warnings                         1m
        \\   codex · scratch · running
        \\ ◆ rename proto.Frame               ▲ 2  1m
        \\   claude · 3 repos · 4 sub · running
        \\   ├⑂ ● venom-std                        1m
        \\   ├⑂ ▲ venomx                           1m
        \\   └⑂ ◆ venom-docs                  ▲ 1  1m
        \\     └⑂ ✕ refactor                       1m
        \\ ▾ SETTLED  1 ─────────────────────────────
        \\ ● cfg schema verbs                      1m
        \\   codex · venom-std · settled
        \\ ▸ ARCHIVED  1 ────────────────────────────
    , try f.draw());
}

test "group by workspace, then repo: g cycles and rows stay sorted by urgency" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("g");
    try testing.expectEqualStrings("group by: workspace", f.app.message.items);
    try testing.expectEqualStrings(
        \\ ▾ ~/scratch  1 ───────────────────────────
        \\ ◆ sort warnings                         1m
        \\   codex · scratch · running
        \\ ▾ ~/venom-org  3 ─────────────────────────
        \\ ▲ venom-echo conformance                1m
        \\   claude · venom-std · 1 sub · approve: z…
        \\   └· ◆ explore-vectors                  1m
        \\ ◆ rename proto.Frame               ▲ 2  1m
        \\   claude · 3 repos · 4 sub · running
        \\   ├⑂ ● venom-std                        1m
        \\   ├⑂ ▲ venomx                           1m
        \\   └⑂ ◆ venom-docs                  ▲ 1  1m
        \\     └⑂ ✕ refactor                       1m
        \\ ● cfg schema verbs                      1m
        \\   codex · venom-std · settled
        \\ ▸ ARCHIVED  1 ────────────────────────────
    , try f.draw());
    try f.feed("g");
    try testing.expectEqualStrings(
        \\ ▾ venom-std  2 ───────────────────────────
        \\ ▲ venom-echo conformance                1m
        \\   claude · venom-std · 1 sub · approve: z…
        \\   └· ◆ explore-vectors                  1m
        \\ ● cfg schema verbs                      1m
        \\   codex · venom-std · settled
        \\ ▾ ~/scratch  1 ───────────────────────────
        \\ ◆ sort warnings                         1m
        \\   codex · scratch · running
        \\ ▾ ~/venom-org (multi-repo)  1 ────────────
        \\ ◆ rename proto.Frame               ▲ 2  1m
        \\   claude · 3 repos · 4 sub · running
        \\   ├⑂ ● venom-std                        1m
        \\   ├⑂ ▲ venomx                           1m
        \\   └⑂ ◆ venom-docs                  ▲ 1  1m
        \\     └⑂ ✕ refactor                       1m
        \\ ▸ ARCHIVED  1 ────────────────────────────
    , try f.draw());
    try f.feed("g");
    try testing.expectEqual(.state, f.app.group_by);
}

test "children folded: one summary line, the count covers all levels" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("t");
    try testing.expectEqualStrings("sub-agents: folded", f.app.message.items);
    try testing.expectEqualStrings(
        \\ ▾ NEEDS YOU  1 ───────────────────────────
        \\ ▲ venom-echo conformance                1m
        \\   claude · venom-std · 1 sub · approve: z…
        \\   └· 1 child · ◆1
        \\ ▾ RUNNING  2 ─────────────────────────────
        \\ ◆ sort warnings                         1m
        \\   codex · scratch · running
        \\ ◆ rename proto.Frame               ▲ 2  1m
        \\   claude · 3 repos · 4 sub · running
        \\   └⑂ 4 children · ●1 ◆1 ✕1 ▲1
        \\ ▾ SETTLED  1 ─────────────────────────────
        \\ ● cfg schema verbs                      1m
        \\   codex · venom-std · settled
        \\ ▸ ARCHIVED  1 ────────────────────────────
    , try f.draw());
}

test "children hidden: the bubbled count is the only trace, and only while one needs the human" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.feed("tt");
    try testing.expectEqualStrings(
        \\ ▾ NEEDS YOU  1 ───────────────────────────
        \\ ▲ venom-echo conformance                1m
        \\   claude · venom-std · approve: zig build…
        \\ ▾ RUNNING  2 ─────────────────────────────
        \\ ◆ sort warnings                         1m
        \\   codex · scratch · running
        \\ ◆ rename proto.Frame               ▲ 2  1m
        \\   claude · 3 repos · running
        \\ ▾ SETTLED  1 ─────────────────────────────
        \\ ● cfg schema verbs                      1m
        \\   codex · venom-std · settled
        \\ ▸ ARCHIVED  1 ────────────────────────────
    , try f.draw());
    // Bubbling reaches every ancestor; answered, the trace goes.
    try t.feedJson(&f.app, a, "{\"seq\":41,\"ts\":\"2026-11-06T14:31:00.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.state_changed\",\"data\":{\"agent\":\"c2\",\"from\":\"needs_you\",\"to\":\"running\"}}");
    try t.feedJson(&f.app, a, "{\"seq\":42,\"ts\":\"2026-11-06T14:31:01.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.state_changed\",\"data\":{\"agent\":\"g1\",\"from\":\"failed\",\"to\":\"running\"}}");
    const screen = try f.draw();
    try testing.expect(std.mem.indexOf(u8, screen, "◆ rename proto.Frame                    1m") != null);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, screen, "▲ 1") + std.mem.count(u8, screen, "▲ 2"));
}

test "filter: / narrows on title, harness, repo and issue; ancestors stay; esc clears" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.draw();

    // A title: the sub-agent, in place under its parent.
    try f.feed("/refac");
    try testing.expect(f.app.filtering);
    try testing.expectEqualStrings(
        \\ ▾ RUNNING  1 ─────────────────────────────
        \\ ◆ rename proto.Frame               ▲ 2  1m
        \\   claude · 3 repos · 4 sub · running
        \\   └⑂ ◆ venom-docs                  ▲ 1  1m
        \\     └⑂ ✕ refactor                       1m
    , try f.draw());
    // The selection left the list: the first row takes it.
    try testing.expectEqualStrings("p1", f.app.selected.items);

    // Keys are text while it is open: `g` didn't regroup.
    f.app.filter_input.clear();
    try f.feed("codex g");
    try testing.expectEqual(.state, f.app.group_by);
    f.app.filter_input.clear();

    // A harness, in any case, with an issue's `#` and a second word.
    try f.feed("CODEX #244");
    const by_issue = try f.draw();
    try testing.expect(std.mem.indexOf(u8, by_issue, "▲ venomx") != null);
    try testing.expect(std.mem.indexOf(u8, by_issue, "sort warnings") == null);

    // A repo; ⏎ keeps the filter and gives the keys back.
    f.app.filter_input.clear();
    try f.feed("scratch\r");
    try testing.expect(!f.app.filtering);
    try testing.expectEqualStrings(
        \\ ▾ RUNNING  1 ─────────────────────────────
        \\ ◆ sort warnings                         1m
        \\   codex · scratch · running
        \\ ▸ ARCHIVED  1 ────────────────────────────
    , try f.draw());
    try f.feed("g");
    try testing.expectEqual(.workspace, f.app.group_by);

    // Nothing matches; esc keeps the filter, and esc on the list clears it.
    f.app.filter_input.clear();
    try f.feed("/nope");
    try testing.expectEqualStrings("", try f.draw());
    try f.feed("\x1b");
    try testing.expect(!f.app.filtering);
    try testing.expectEqualStrings("nope", f.app.filter_input.value());
    try f.feed("\x1b");
    try testing.expectEqualStrings("", f.app.filter_input.value());
    try testing.expect(std.mem.indexOf(u8, try f.draw(), "sort warnings") != null);
}

test "main view shows the filter line, the no-match line and INPUT in the bar" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var surface = try term.Surface.init(ta, 100, 24);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&f.app, &surface);
    try f.feed("/nope");
    try view.render(&f.app, &surface);
    const screen = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, screen, "\n / nope") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "No agent matches.") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "│  INPUT") != null);
    // A paste can't close it or send anything.
    try f.feed("\x1b[200~a\rb\x1b[201~");
    try testing.expect(f.app.filtering);
    try testing.expectEqualStrings("nopea b", f.app.filter_input.value());
}

test "selection: j skips a summary line; a hidden child gives way to its parent" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.draw();
    try testing.expectEqualStrings("a1", f.app.selected.items);
    // Tree: j goes into the sub-agent.
    try f.feed("j");
    try testing.expectEqualStrings("n1", f.app.selected.items);
    // Folded: the sub-agent left the list, its parent takes over.
    try f.feed("t");
    _ = try f.draw();
    try testing.expectEqualStrings("a1", f.app.selected.items);
    // j passes the summary line, onto the next header.
    try f.feed("j");
    try testing.expect(f.app.on_header);
    try testing.expectEqualStrings("a1", f.app.selected.items);
    try f.feed("j");
    try testing.expectEqualStrings("s1", f.app.selected.items);
    // Hidden: the same from a grandchild, up through every level.
    try f.feed("t");
    try f.app.setSelected("g1");
    _ = try f.draw();
    try testing.expectEqualStrings("p1", f.app.selected.items);
}

test "End stops before a summary line that ends the list" {
    const rows = [_]agent_list.Row{
        .{ .header = .{ .title = "Running", .count = 1, .folded = false } },
        .{ .agent = .{ .id = "p1", .glyph = "◆", .role = .info, .title = "p", .age = "" } },
        .{ .summary = .{ .branch = "", .spans = &.{} } },
    };
    var v: agent_list.View = .{};
    const r: agent_list.Rows = .{ .rows = &rows, .folded = &.{} };
    try testing.expectEqual(agent_list.Action.moved, v.handleKey(r, w.keys.testNamed(.end)).?);
    try testing.expectEqual(@as(usize, 1), v.cursor);
    _ = v.handleKey(r, w.keys.testKey('j', .{}));
    try testing.expectEqual(@as(usize, 1), v.cursor);
    _ = v.handleKey(r, w.keys.testKey('k', .{}));
    try testing.expectEqual(@as(usize, 0), v.cursor);
}

test "folds: per group, kept across regrouping; Archived starts folded and opens with ⏎" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.draw();
    try f.feed("\x1b[F"); // End: the Archived header
    try testing.expect(f.app.on_header);
    try f.feed("\r");
    try testing.expect(std.mem.indexOf(u8, try f.draw(), "○ old spike") != null);
    try f.feed("g");
    try testing.expect(std.mem.indexOf(u8, try f.draw(), "○ old spike") != null);
    // ← from an item goes to its header, ← again folds it; the fold stays.
    try f.feed("gg");
    _ = try f.draw();
    try f.feed("\x1b[H"); // Home: Needs you
    try f.feed("j");
    try f.feed("h");
    try testing.expect(f.app.on_header);
    try f.feed("h");
    try testing.expect(std.mem.indexOf(u8, try f.draw(), "▸ NEEDS YOU  1") != null);
    try f.feed("l");
    try testing.expect(std.mem.indexOf(u8, try f.draw(), "▾ NEEDS YOU  1") != null);
}

test "the model keeps parent links: agent.created, agent.promoted and a new snapshot" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectEqualStrings("c3", f.app.model.find("g1").?.parent);
    try testing.expectEqualStrings("244", f.app.model.find("c2").?.issue);
    try testing.expect(f.app.model.find("n1").?.native);

    try t.feedJson(&f.app, a, "{\"seq\":41,\"ts\":\"2026-11-06T14:31:00.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.created\",\"data\":{\"agent\":\"c4\",\"title\":\"new child\",\"harness\":\"claude\",\"workspace\":\"/home/me/venom-org\",\"repos\":[\"venomx\"],\"parent\":\"p1\",\"issue\":\"9\",\"state\":\"queued\"}}");
    try testing.expectEqualStrings("p1", f.app.model.find("c4").?.parent);
    try testing.expectEqualStrings("9", f.app.model.find("c4").?.issue);
    try testing.expect(std.mem.indexOf(u8, try f.draw(), "⑂ ○ new child") != null);

    // Promoted: top-level, under its own group.
    try t.feedJson(&f.app, a, "{\"seq\":42,\"ts\":\"2026-11-06T14:31:01.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.promoted\",\"data\":{\"agent\":\"c4\",\"parent\":\"p1\"}}");
    try testing.expectEqualStrings("", f.app.model.find("c4").?.parent);
    const screen = try f.draw();
    try testing.expect(std.mem.indexOf(u8, screen, " ○ new child") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "⑂ ○ new child") == null);

    // A restart's snapshot says nothing of links: they stay until agent.list.
    try t.feedJson(&f.app, a, "{\"seq\":2,\"ts\":\"2026-11-06T14:40:00.000Z\",\"source\":\"venom/0e2\",\"type\":\"state.snapshot\",\"data\":{\"reason\":\"source_changed\",\"complete\":true,\"entities\":[{\"resource\":\"agent:g1\",\"entity_type\":\"agent\",\"content\":\"{\\\"agent\\\":\\\"g1\\\",\\\"title\\\":\\\"refactor\\\",\\\"harness\\\":\\\"claude\\\",\\\"state\\\":\\\"failed\\\",\\\"unread\\\":false}\"}]}}");
    try testing.expectEqualStrings("c3", f.app.model.find("g1").?.parent);
}

test "ui.group_by and ui.children come from config.get" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.draw();
    try f.app.requestListConfig();
    try testing.expectEqualStrings("config.get() config.get() ", try t.sent(a, &f.app));
    try t.answer(&f.app, a, "config.get", "{\"content\":\".repo\",\"source\":\"user\"}");
    try t.answer(&f.app, a, "config.get", "{\"content\":\".hidden\",\"source\":\"user\"}");
    try testing.expectEqual(.repo, f.app.group_by);
    try testing.expectEqual(.hidden, f.app.children);
}

test "a child's state is never colour alone; unread settled rows are bold" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const screen = try f.draw();
    // Glyphs, not fills: every state has its own.
    for ([_][]const u8{ "▲ venomx", "◆ venom-docs", "✕ refactor", "● venom-std" }) |want| try testing.expect(std.mem.indexOf(u8, screen, want) != null);
    // "cfg schema verbs" is on row 14; "sort warnings" on row 5 isn't bold.
    try testing.expect(f.surface.get(4, 14).?.style.bold);
    try testing.expect(!f.surface.get(4, 5).?.style.bold);
}

test "quit: asks only when it would stop an on-demand daemon's work, naming running and queued apart" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const press = struct {
        fn key(app: *App, bytes: []const u8) !void {
            _ = try app.feed(bytes);
        }
    }.key;
    // No hold item yet, or a persistent daemon: quit does not ask.
    try std.testing.expect(!f.app.quitNeedsConfirm());
    f.app.onHold(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"lifetime\":\"persistent\",\"origin\":\"serve\",\"phase\":\"active\",\"clients\":1,\"others\":0}", .{}));
    try std.testing.expect(!f.app.quitNeedsConfirm());
    // Another TUI holds an on-demand daemon: it outlives this quit.
    f.app.onHold(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"lifetime\":\"on-demand\",\"origin\":\"interactive\",\"phase\":\"active\",\"clients\":2,\"others\":1}", .{}));
    try std.testing.expect(!f.app.quitNeedsConfirm());
    // The last one, with agents running and waiting on the human.
    f.app.onHold(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"lifetime\":\"on-demand\",\"origin\":\"interactive\",\"phase\":\"active\",\"clients\":1,\"others\":0}", .{}));
    try std.testing.expect(f.app.quitNeedsConfirm());
    try std.testing.expectEqualStrings("Quit venom? 6 agents are running. Quitting stops them; each keeps its work and continues when you send to it again.", try f.app.quitPromptText(a));
    f.app.quit = true;
    try std.testing.expect(!f.app.confirmQuit());
    try std.testing.expect(f.app.quit_prompt and !f.app.quit);
    // ⏎ quits.
    try press(&f.app, "\r");
    try std.testing.expect(f.app.quit and f.app.confirmQuit());
}
