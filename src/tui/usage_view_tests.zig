//! The usage screen and the context panel: snapshots of
//! each grouping and range, from what the daemon's own `usage.show` computes
//! over a fixed log, and of the context panel; their keys; and, live, the
//! panel's actions reaching the fake harness.
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const App = @import("app.zig").App;
const Link = @import("link.zig").Link;
const Screen = @import("app.zig").Screen;
const view = @import("view.zig");
const usage = @import("../usage.zig");
const eventlog = @import("../eventlog/root.zig");
const decider = eventlog.decider;
const harnesses = @import("../harnesses.zig");
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const now: i64 = 1_794_000_000_000 + 12 * std.time.ms_per_hour;

const ctrl_u = "\x15";
const open_panel = " ac";

fn turn(state: *eventlog.State, s: std.mem.Allocator, agent: []const u8, id: []const u8, start: i64, end: i64, in: u64, out: u64, calls: u32) !void {
    _ = try decider.applyAt(state, .{ .record = .{ .turn_started = .{ .agent = agent, .turn = id, .origin = "user" } } }, start, s);
    for (0..calls) |n| {
        _ = try decider.applyAt(state, .{ .record = .{ .tool_started = .{ .agent = agent, .turn = id, .call = try std.fmt.allocPrint(s, "{s}-{s}-c{d}", .{ agent, id, n }), .kind = "exec", .name = "Bash" } } }, start, s);
    }
    _ = try decider.applyAt(state, .{ .record = .{ .usage = .{ .agent = agent, .turn = id, .tokens_in = in, .tokens_out = out, .cache_read = in * 10, .cache_write = out / 2 } } }, start, s);
    _ = try decider.applyAt(state, .{ .record = .{ .turn_ended = .{ .agent = agent, .turn = id, .reason = "completed" } } }, end, s);
}

/// A tree in one workspace, another harness in another; turns in each range.
fn fixture(state: *eventlog.State, s: std.mem.Allocator) !void {
    const today = usage.since(.today, now);
    const day = std.time.ms_per_day;
    _ = try decider.apply(state, .{ .create = .{ .agent = "a1", .title = "rename proto.Frame", .harness = "claude-code", .workspace = "/work/venom" } }, s);
    _ = try decider.apply(state, .{ .create = .{ .agent = "a2", .title = "update the callers", .harness = "claude-code", .workspace = "/work/venom", .parent = "a1" } }, s);
    _ = try decider.apply(state, .{ .create = .{ .agent = "a3", .title = "cfg ZON schema verbs", .harness = "codex", .workspace = "/work/std" } }, s);
    try turn(state, s, "a1", "t1", today + 1000, today + 91_000, 201_000, 58_000, 12);
    try turn(state, s, "a2", "t1", today + 2000, today + 12_000, 40_000, 9_000, 3);
    try turn(state, s, "a1", "t2", today - 3 * day, today - 3 * day + 250_000, 98_000, 26_000, 4);
    try turn(state, s, "a3", "t1", today - 5 * day, today - 5 * day + 8_000_000, 1_200_000, 300_000, 40);
    try turn(state, s, "a3", "t2", today - 20 * day, today - 20 * day + 900, 500, 40, 1);
    _ = try decider.applyAt(state, .{ .record = .{ .context = .{ .agent = "a1", .used = 124_000, .window = 200_000 } } }, today + 91_000, s);
}

/// Answers the pending `usage.show` with the daemon's own report.
fn answerShow(app: *App, state: *const eventlog.State, a: std.mem.Allocator, group: usage.Group, range: usage.Range) !void {
    const r = try usage.report(a, state, group, range, now);
    const json = try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false });
    try t.answer(app, a, "usage.show", json);
}

fn expectSnapshot(comptime name: []const u8, got: []const u8) !void {
    const want = @embedFile("testdata/" ++ name);
    if (!std.mem.eql(u8, want, got)) std.debug.print("{s}:\n{s}\n", .{ name, got });
    try testing.expectEqualStrings(want, got);
}

fn expectView(comptime group: usage.Group, comptime range: usage.Range, app: *App, state: *const eventlog.State, a: std.mem.Allocator, surface: *term.Surface) !void {
    const sent = try t.sent(a, app);
    try testing.expectEqualStrings("usage.show() ", sent);
    try answerShow(app, state, a, group, range);
    try view.render(app, surface);
    try expectSnapshot("usage_" ++ @tagName(group) ++ "_" ++ @tagName(range) ++ ".txt", try t.dump(a, surface));
}

test "usage screen snapshots: each grouping and range" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var state = eventlog.State.init(ta);
    defer state.deinit();
    try fixture(&state, a);
    var app = App.init(ta);
    defer app.deinit();
    app.connected = true;
    var surface = try term.Surface.init(ta, 110, 14);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);

    _ = try app.feed(" u");
    try testing.expectEqual(Screen.usage, app.screen);
    try view.render(&app, &surface);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), "loading…") != null);
    // `g` goes agent → harness → workspace; 1 2 3 are the ranges.
    try expectView(.agent, .today, &app, &state, a, &surface);
    _ = try app.feed("2");
    try expectView(.agent, .@"7d", &app, &state, a, &surface);
    _ = try app.feed("3");
    try expectView(.agent, .@"30d", &app, &state, a, &surface);
    _ = try app.feed("g");
    try expectView(.harness, .@"30d", &app, &state, a, &surface);
    _ = try app.feed("2");
    try expectView(.harness, .@"7d", &app, &state, a, &surface);
    _ = try app.feed("1");
    try expectView(.harness, .today, &app, &state, a, &surface);
    _ = try app.feed("g");
    try expectView(.workspace, .today, &app, &state, a, &surface);
    _ = try app.feed("2");
    try expectView(.workspace, .@"7d", &app, &state, a, &surface);
    _ = try app.feed("3");
    try expectView(.workspace, .@"30d", &app, &state, a, &surface);
    // Esc goes back.
    _ = try app.feed("\x1b");
    try testing.expectEqual(Screen.main, app.screen);
}

test "usage screen: the request names the group and range; ⏎ opens the agent; e writes the CSV" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var state = eventlog.State.init(ta);
    defer state.deinit();
    try fixture(&state, a);
    var app = App.init(ta);
    defer app.deinit();
    app.connected = true;
    app.io = testing.io;
    app.usage.export_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    _ = try app.feed(" u");
    const first = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, app.outbox.items[0]), .{});
    try testing.expectEqualStrings("agent", first.object.get("params").?.object.get("group").?.string);
    try testing.expectEqualStrings("today", first.object.get("params").?.object.get("range").?.string);
    _ = try t.sent(a, &app);
    try answerShow(&app, &state, a, .agent, .today);

    _ = try app.feed("e");
    const asked = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, app.outbox.items[0]), .{});
    try testing.expectEqualStrings("usage.export", asked.object.get("verb").?.string);
    _ = try t.sent(a, &app);
    const r = try usage.report(a, &state, .agent, .today, now);
    const csv = try usage.csv(a, r);
    try t.answer(&app, a, "usage.export", try std.json.Stringify.valueAlloc(a, .{ .rows = r.rows.len, .csv = csv }, .{}));
    const name = try std.fmt.allocPrint(a, "{s}/venom-usage-agent-today.csv", .{app.usage.export_dir});
    try testing.expectEqualStrings(csv, try std.Io.Dir.cwd().readFileAlloc(testing.io, name, a, .limited(1 << 20)));
    try testing.expect(std.mem.startsWith(u8, app.message.items, "wrote "));

    // j to the sub-agent, ⏎ opens it in the main view.
    _ = try app.feed("j\r");
    try testing.expectEqual(Screen.main, app.screen);
    try testing.expectEqualStrings("a2", app.selected.items);
    _ = try t.sent(a, &app);
}

const context_all =
    \\{"agent":"a1","title":"venom-echo conformance","harness":"claude-code","used":124000,"window":200000,"source":"estimate","warn_at":80,
    \\ "fills":[{"kind":"system","tokens":12000},{"kind":"tools","tokens":18000},{"kind":"messages","tokens":61000},{"kind":"files","tokens":33000}],
    \\ "largest":[{"call":"c4","kind":"read","name":"Read","title":"spec/vectors/all.json","tokens":14000},{"call":"c2","kind":"exec","name":"Bash","title":"zig build","tokens":9000}],
    \\ "mcp":{"servers":["linear","docs","figma"],"unused":["linear","docs"],"off":["figma"]},"actions":{"compact":true,"fork":true,"mcp_off":true}}
;
/// A harness that supports none of them and has not told its size.
const context_none =
    \\{"agent":"a2","title":"libghostty-vt spike","harness":"opencode","warn_at":80,"fills":[],"largest":[],
    \\ "mcp":{"servers":[],"unused":[],"off":[]},"actions":{"compact":false,"fork":false,"mcp_off":false}}
;
/// The usual case: the transcript's parts and the rest; compact and fork only.
const context_hot =
    \\{"agent":"a3","title":"cfg ZON schema verbs","harness":"codex","used":176000,"window":200000,"source":"exact","warn_at":80,
    \\ "fills":[{"kind":"fixed","tokens":31000},{"kind":"messages","tokens":100000},{"kind":"files","tokens":45000}],"largest":[],
    \\ "mcp":{"servers":[],"unused":[],"off":[]},"actions":{"compact":true,"fork":true,"mcp_off":false}}
;

const Panel = struct {
    app: App,
    surface: term.Surface,

    fn init(self: *Panel, a: std.mem.Allocator, agent: []const u8) !void {
        self.app = App.init(ta);
        self.app.connected = true;
        try self.app.selected.appendSlice(ta, agent);
        self.surface = try term.Surface.init(ta, 80, 24);
        _ = try self.app.feed(open_panel);
        _ = try t.sent(a, &self.app);
    }
    fn deinit(self: *Panel) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.app.deinit();
    }
};

test "the usage and inbox popups: esc closes them, nothing opens an agent or the tree" {
    for ([_]Screen{ .usage, .inbox }) |screen| {
        var arena = std.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        const a = arena.allocator();
        var state = eventlog.State.init(ta);
        defer state.deinit();
        var app = App.init(ta);
        defer app.deinit();
        app.connected = true;
        if (screen == .usage) {
            try fixture(&state, a);
            try @import("usage_view.zig").open(&app);
            try answerShow(&app, &state, a, .agent, .today);
            // The footer doesn't offer it, and pressing it stays here.
            try testing.expect(std.mem.indexOf(u8, @import("usage_view.zig").hint(&app), "open") != null);
            app.setSingleView();
            try testing.expect(std.mem.indexOf(u8, @import("usage_view.zig").hint(&app), "open") == null);
            _ = try app.feed("\r");
            try testing.expectEqual(Screen.usage, app.screen);
            try testing.expectEqualStrings(@import("app.zig").single_view_open, app.message.items);
        } else {
            try @import("inbox_tests.zig").fixture(&app, a);
            // ⌃⏎ has an agent to open the menu for.
            try app.setSelected("a1");
            app.openInbox();
            app.setSingleView();
            var surface = try term.Surface.init(ta, 120, 30);
            var discard: std.Io.Writer.Discarding = .init(&.{});
            defer surface.deinit(&discard.writer);
            // Every item: `\\`, ⌃⏎, `o` and `R` stay here, and no hint offers them.
            for (0..8) |_| {
                for ([_][]const u8{ "\\", "\x1b[13;5u", "o", "R" }) |press| {
                    _ = try app.feed(press);
                    try testing.expectEqual(Screen.inbox, app.screen);
                    try testing.expect(app.menu == null);
                }
                try view.render(&app, &surface);
                const screen_text = try t.dump(a, &surface);
                for ([_][]const u8{ "o open", "\\ split", "R retry", "focus split" }) |hint| {
                    try testing.expect(std.mem.indexOf(u8, screen_text, hint) == null);
                }
                _ = try app.feed("j");
            }
            // The help doesn't offer them either.
            _ = try app.feed("?");
            try view.render(&app, &surface);
            try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), "open in split") == null);
            _ = try app.feed("\x1b");
            try testing.expect(!app.quit);
        }
        try testing.expect(!app.leaderActive());
        _ = try app.feed(" ");
        _ = try app.feed("a");
        try testing.expectEqual(screen, app.screen);
        try testing.expect(!app.quit);
        _ = try app.feed("\x1b");
        try testing.expect(app.quit);
    }
}

test "context panel snapshots: all actions, none, and hot with no MCP action" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ .{ "a1", context_all, "context_all.txt" }, .{ "a2", context_none, "context_none.txt" }, .{ "a3", context_hot, "context_hot.txt" } }) |c| {
        var p: Panel = undefined;
        try p.init(a, c[0]);
        defer p.deinit();
        try t.answer(&p.app, a, "agent.context", c[1]);
        try view.render(&p.app, &p.surface);
        try expectSnapshot(c[2], try t.dump(a, &p.surface));
    }
}

test "context panel: ⌃u from the input box and the list; keys send their verbs only when offered" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var p: Panel = undefined;
        try p.init(a, "a2");
        defer p.deinit();
        try t.answer(&p.app, a, "agent.context", context_none);
        _ = try p.app.feed("cfm");
        try testing.expectEqualStrings("", try t.sent(a, &p.app));
        try testing.expect(p.app.context_panel.agent != null);
        // ⌃u does not close it; esc does.
        _ = try p.app.feed(ctrl_u);
        try testing.expect(p.app.context_panel.agent != null);
        _ = try p.app.feed("\x1b");
        try testing.expect(p.app.context_panel.agent == null);
        // In the input box ⌃u edits the text.
        _ = try p.app.feed("i");
        _ = try p.app.feed(ctrl_u);
        try testing.expect(p.app.context_panel.agent == null);
    }
    {
        var p: Panel = undefined;
        try p.init(a, "a1");
        defer p.deinit();
        try t.answer(&p.app, a, "agent.context", context_all);
        _ = try p.app.feed("m");
        try testing.expectEqualStrings("agent.mcp_off(a1) ", try t.sent(a, &p.app));
        try testing.expect(p.app.context_panel.agent != null);
        _ = try p.app.feed("c");
        try testing.expectEqualStrings("agent.compact(a1) ", try t.sent(a, &p.app));
        try testing.expect(p.app.context_panel.agent == null);
    }
    {
        var p: Panel = undefined;
        try p.init(a, "a1");
        defer p.deinit();
        try t.answer(&p.app, a, "agent.context", context_all);
        _ = try p.app.feed("f");
        const asked = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, p.app.outbox.items[0]), .{});
        try testing.expect(asked.object.get("params").?.object.get("task") != null);
        try testing.expectEqualStrings("agent.fork(a1) ", try t.sent(a, &p.app));
        // The event may overtake the response. A failure is said, and stays here.
        try t.feedJson(&p.app, a,
            \\{"seq":41,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"agent.fork_ended","resource":"agent:a1","data":{"agent":"a1","key":"fork:a1:1","ok":false,"code":"conflict.harness_fork_refused"}}
        );
        try testing.expectEqualStrings("fork failed: conflict.harness_fork_refused", p.app.message.items);
        try testing.expectEqualStrings("a1", p.app.selected.items);
        // A fork someone else asked for moves nobody.
        try t.feedJson(&p.app, a,
            \\{"seq":42,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"agent.fork_ended","resource":"agent:a1","data":{"agent":"a1","key":"fork:a1:2","ok":true,"fork":"a9"}}
        );
        try testing.expectEqualStrings("a1", p.app.selected.items);
    }
    {
        var p: Panel = undefined;
        try p.init(a, "a1");
        defer p.deinit();
        try t.answer(&p.app, a, "agent.context", context_all);
        _ = try p.app.feed("f");
        _ = try t.sent(a, &p.app);
        try t.feedJson(&p.app, a,
            \\{"seq":41,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"agent.fork_ended","resource":"agent:a1","data":{"agent":"a1","key":"fork:a1:1","ok":true,"fork":"a2"}}
        );
        try testing.expectEqualStrings("a2", p.app.selected.items);
        try testing.expectEqualStrings("forked to a2", p.app.message.items);
        _ = try t.sent(a, &p.app);
    }
}

const live_script =
    \\{"mcp_servers":["docs"],"compact_context":{"used":9000,"window":200000},
    \\ "turns":[{"match":"Summarize","steps":[{"text":"Where it stands."}]},
    \\          {"match":"","steps":[{"usage":{"in":1000,"out":50}},{"context":{"used":120000,"window":200000}},{"text":"Done."}]}]}
;

test "live: the panel's actions reach the fake harness; a fork moves here when it ends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
    try tmp.dir.createDirPath(testing.io, "work");
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (std.c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
    var d: t.Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}), .script = live_script };
    defer d.deinit();
    try d.start();
    defer d.halt();
    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 100, 26);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try t.until(&app, &link, &surface, &d, "connect", t.Connected{});

    _ = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{work}), "--task=look around", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "a1 settled", t.InState{ .id = "a1", .state = .settled });

    // The panel, with what the daemon says.
    _ = try app.feed(open_panel);
    try t.until(&app, &link, &surface, &d, "the panel", t.Shows{ .text = "Compact now" });
    try t.until(&app, &link, &surface, &d, "the MCP action", t.Shows{ .text = "hasn't used: docs" });
    // Compact: the harness runs it, and the turn lands in the transcript.
    _ = try app.feed("c");
    try t.until(&app, &link, &surface, &d, "the compaction", t.Shows{ .text = "compacted" });
    try t.until(&app, &link, &surface, &d, "a1 settled again", t.InState{ .id = "a1", .state = .settled });
    const compacts = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/compacts", .{dir}), a, .limited(1 << 16));
    try testing.expect(std.mem.indexOf(u8, compacts, "fake-a1") != null);

    // Fork: this client moves to the new agent when the effect ends.
    _ = try app.feed(open_panel);
    try t.until(&app, &link, &surface, &d, "the panel again", t.Shows{ .text = "Fork to a fresh agent" });
    _ = try app.feed("f");
    try t.until(&app, &link, &surface, &d, "a2 settled", t.InState{ .id = "a2", .state = .settled });
    try t.until(&app, &link, &surface, &d, "its summary", t.Shows{ .text = "Where it stands." });
    try testing.expectEqualStrings("a2", app.selected.items);

    // The usage screen sees both, from the daemon.
    _ = try app.feed(" u");
    try t.until(&app, &link, &surface, &d, "the usage screen", t.Shows{ .text = "fork of look around" });
    _ = try app.feed("\x1b");
}
