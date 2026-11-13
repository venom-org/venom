//! The leader tree: key tests over
//! the fixture, driven with key bytes as a terminal sends them.
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Screen = app_mod.Screen;
const KeyMode = app_mod.KeyMode;
const keys = @import("keys.zig");
const view = @import("view.zig");
const host_mod = @import("host.zig");
const config = @import("../config.zig");
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    surface: term.Surface,

    fn init(self: *Fixture) !void {
        self.arena = .init(ta);
        self.app = .init(ta);
        self.surface = try .init(ta, 120, 120);
        try t.fixtureApp(&self.app, self.a());
        try self.draw();
        _ = try self.sent();
    }

    fn deinit(self: *Fixture) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.app.deinit();
        self.arena.deinit();
    }

    fn a(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn sent(self: *Fixture) ![]const u8 {
        return t.sent(self.a(), &self.app);
    }

    fn draw(self: *Fixture) !void {
        try view.render(&self.app, &self.surface);
    }

    fn screen(self: *Fixture) ![]const u8 {
        try self.draw();
        return t.dump(self.a(), &self.surface);
    }

    fn feed(self: *Fixture, bytes: []const u8) !void {
        _ = try self.app.feed(bytes);
    }

    /// Answers the pending `config.get` of `which` with a ZON value.
    fn config(self: *Fixture, which: @FieldType(app_mod.Purpose, "config"), zon: []const u8) !void {
        var it = self.app.pending.iterator();
        const id = while (it.next()) |e| {
            if (e.value_ptr.* == .config and e.value_ptr.config == which) break e.key_ptr.*;
        } else return error.NoSuchRequest;
        var content: std.ArrayList(u8) = .empty;
        try content.print(self.a(), "{{\"content\":{f}}}", .{std.json.fmt(zon, .{})});
        try self.app.onResponse(id, .{ .ok = try std.json.parseFromSliceLeaky(Value, self.a(), content.items, .{}) });
    }

    /// Applies `ui.keys.leader = <text>` as the daemon's answer would.
    fn setLeader(self: *Fixture, text: []const u8) !void {
        try self.app.requestKeysConfig();
        const zon = try std.fmt.allocPrint(self.a(), "\"{s}\"", .{text});
        try self.config(.leader, zon);
        _ = try self.sent();
    }
};

fn has(screen: []const u8, text: []const u8) bool {
    return std.mem.indexOf(u8, screen, text) != null;
}

const approvals =
    \\{"items":[
    \\{"agent":"a1","kind":"approval","age_s":60,"reason":"Run?","item":"r1","request":"r1","title":"one","grant":"exec:zig"},
    \\{"agent":"a2","kind":"failed","age_s":50,"reason":"exit 1","item":"failed","title":"two"},
    \\{"agent":"a3","kind":"question","age_s":40,"reason":"Which?","item":"q1","request":"q1","title":"three"},
    \\{"agent":"a4","kind":"review","age_s":30,"reason":"unread","item":"review","title":"four"}]}
;

test "tree: each screen and action, from the list" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    const cases = [_]struct { keys: []const u8, screen: Screen }{
        .{ .keys = " i", .screen = .inbox },
        .{ .keys = " s", .screen = .settings },
        .{ .keys = " u", .screen = .usage },
        .{ .keys = " ww", .screen = .workspaces },
    };
    for (cases) |c| {
        try f.feed(c.keys);
        try testing.expectEqual(c.screen, app.screen);
        try testing.expect(!app.leader.pending());
        // esc goes back, from each one, and is the
        // only key that does.
        try f.feed("\x1b");
        try testing.expectEqual(Screen.main, app.screen);
        _ = try f.sent();
    }
    // New agents, with the workspace field for `N`.
    try f.feed(" an");
    try testing.expect(app.dialog != null);
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try f.feed("\x1b");
    try f.feed(" aN");
    try testing.expectEqual(@import("new_agent.zig").Field.workspace, app.dialog.?.field);
    try f.feed("\x1b");
    _ = try f.sent();
    // Verbs go to the agent under the cursor.
    try f.feed(" as");
    try testing.expectEqualStrings("agent.stop(a1) ", try f.sent());
    try f.feed(" ax");
    try testing.expectEqualStrings("agent.archive(a1) ", try f.sent());
    try f.feed(" af");
    try testing.expectEqualStrings("agent.fork(a1) ", try f.sent());
    // The context panel, closed by esc only.
    try f.feed(" ac");
    try testing.expectEqualStrings("a1", app.context_panel.agent.?);
    _ = try f.sent();
    try f.feed("\x15");
    try testing.expect(app.context_panel.agent != null);
    try f.feed("\x1b");
    try testing.expect(app.context_panel.agent == null);
    // The split menu, from the tree as from `\`.
    try f.feed(" vv");
    try testing.expect(app.menu != null);
    try f.feed("\x1b");
    // Back to the agents screen from elsewhere, on the list.
    try f.feed(" i");
    app.focus.set(@backingInt(app_mod.Area.transcript));
    try f.feed(" aa");
    try testing.expectEqual(Screen.main, app.screen);
    try testing.expectEqual(app_mod.Area.list, app.area());
    _ = try f.sent();
    // All keys, past the screen's height.
    try f.feed(" ?");
    try testing.expect(app.help and app.help_all);
    const all = try f.screen();
    try testing.expect(has(all, "All keys"));
    try f.feed("jjjjjjjj");
    try testing.expect(app.help and app.help_top > 0);
    try f.feed("x");
    try testing.expect(!app.help and !app.help_all);
    try testing.expectEqual(@as(u16, 0), app.help_top);
    // The workspaces rows.
    try f.feed(" wa");
    try testing.expectEqual(Screen.workspaces, app.screen);
    try testing.expect(app.panel.adding);
    try f.feed("\x1b");
    try f.feed("\x1b");
    _ = try f.sent();
    try f.feed(" wr");
    try testing.expect(has(app.message.items, "no workspace yet"));
    try f.feed("\x1b");
}

test "tree: the keys that moved do nothing bare any more" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try f.feed("I,uNw\x15\x17");
    try testing.expectEqual(Screen.main, app.screen);
    try testing.expect(app.dialog == null and app.context_panel.agent == null);
    try testing.expectEqualStrings("", try f.sent());
    // Back keys on those screens are esc only.
    try f.feed(" i");
    try f.feed("I");
    try testing.expectEqual(Screen.inbox, app.screen);
    try f.feed("\x1b");
    try f.feed(" ww");
    _ = try f.sent();
    try f.feed("w");
    try testing.expectEqual(Screen.workspaces, app.screen);
    try f.feed("\x1b");
    try f.feed(" u");
    _ = try f.sent();
    try f.feed("u");
    try testing.expectEqual(Screen.usage, app.screen);
    try f.feed("\x15");
    try testing.expect(app.context_panel.agent == null);
    try f.feed("\x1b");
}

test "leader: cancels, goes up a level, and swallows what it does not know" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    // An unbound key ends it and reaches nothing: `q` would have quit.
    try f.feed(" q");
    try testing.expect(!app.quit and !app.leader.pending());
    try f.feed(" aq");
    try testing.expect(!app.quit and !app.leader.pending());
    // esc cancels from any level, and does nothing else: the screen stays.
    try f.feed(" i");
    try f.feed(" a\x1b");
    try testing.expect(!app.leader.pending());
    try testing.expectEqual(Screen.inbox, app.screen);
    try f.feed("\x1b");
    // backspace goes up a level, and out from the root.
    try f.feed(" a\x7f");
    try testing.expect(app.leader.pending());
    try testing.expectEqual(@as(u8, 0), app.leader.seq.len);
    try f.feed("\x7f");
    try testing.expect(!app.leader.pending());
    // Its bar says so, and it is still Normal.
    try f.feed(" ");
    try testing.expect(has(try f.screen(), "NORMAL · LEADER"));
    // The leader twice is the switcher's; it never reaches a key.
    try f.feed(" ");
    try testing.expect(!app.leader.pending());
    try testing.expect(has(app.message.items, "switcher"));
    // A paste is not the next key.
    try f.feed(" \x1b[200~i\x1b[201~");
    try testing.expect(!app.leader.pending());
    try testing.expectEqual(Screen.main, app.screen);
}

test "leader: never in Input, in a filter, a dialog, a prompt or an overlay" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    // Input: text, and what looks like the tree stays text.
    try f.feed("i");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try f.feed(" i s");
    try testing.expectEqualStrings(" i s", app.input.value());
    try testing.expect(!app.leader.pending());
    // A background event changes nothing about that.
    try f.feed(" ");
    try t.answer(app, f.a(), "inbox.list", approvals);
    try f.feed("y");
    try testing.expectEqualStrings(" i s y", app.input.value());
    try f.feed("\x1b");
    app.input.clear();
    _ = try f.sent();
    // The filter.
    try f.feed("/a b");
    try testing.expectEqualStrings("a b", app.filter_input.value());
    try testing.expect(!app.leader.pending());
    try f.feed("\x03\x1b");
    // The new-agent dialog keeps space.
    try f.feed("n");
    try f.feed(" ");
    try testing.expect(app.dialog != null and !app.leader.pending());
    try f.feed("\x1b");
    _ = try f.sent();
    // The overlays that own their keys although `keyMode` says Normal.
    try f.feed("?");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try testing.expect(!app.leaderActive());
    try f.feed(" ");
    try testing.expect(!app.help and !app.leader.pending());
    try f.feed("\\");
    try testing.expect(app.menu != null);
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try f.feed(" ");
    try testing.expect(app.menu != null and !app.leader.pending());
    try f.feed("\x1b");
    try f.feed(" ac");
    _ = try f.sent();
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try f.feed(" ");
    try testing.expect(app.context_panel.agent != null and !app.leader.pending());
    try f.feed("\x1b");
    // `venom settings` is one view, with nowhere to go.
    app.settings.standalone = true;
    try app.openSettings();
    try f.feed(" ");
    try testing.expect(!app.leader.pending());
    app.settings.standalone = false;
    app.screen = .main;
    _ = try f.sent();
    // Leader mode doesn't outlive the view that allowed it.
    try f.feed(" ");
    app.help = true;
    app.syncLeader();
    try testing.expect(!app.leader.pending());
    app.help = false;
}

test "leader: settings with unsaved changes ask before the tree leaves them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try f.feed(" s");
    try app.settings.pending.append(ta, undefined);
    defer app.settings.pending.clearRetainingCapacity();
    try f.feed(" i");
    try testing.expectEqual(Screen.settings, app.screen);
    try testing.expect(has(app.message.items, "1 unsaved"));
    // Help is no leaving.
    try f.feed(" ?");
    try testing.expect(app.help);
    try f.feed("x");
    app.settings.pending.clearRetainingCapacity();
    _ = try f.sent();
}

test "leader: a changed leader moves the whole tree, and the old key is nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try f.setLeader("ctrl+x");
    try testing.expectEqualStrings("ctrl+x", app.leaderText());
    try f.feed("\x18i");
    try testing.expectEqual(Screen.inbox, app.screen);
    try f.feed("\x1b");
    // `space` is now no key at all in the list.
    try f.feed(" ");
    try testing.expect(!app.leader.pending());
    try f.feed("i");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try f.feed("\x1b");
    // Everything prints the leader that is configured.
    const hints = try f.screen();
    try testing.expect(has(hints, "ctrl+x more"));
    try f.feed("?");
    const help = try f.screen();
    try testing.expect(has(help, "ctrl+x a s"));
    try testing.expect(has(help, "ctrl+x v x"));
    try testing.expect(!has(help, "space a s"));
    try f.feed("x");
    // A plain key works too, and text still can't reach it.
    try f.setLeader(",");
    try f.feed(",i");
    try testing.expectEqual(Screen.inbox, app.screen);
    try f.feed("\x1b");
    try f.feed("i,i");
    try testing.expectEqualStrings(",i", app.input.value());
    try f.feed("\x1b");
    app.input.clear();
    // What can't be a leader changes nothing.
    for ([_][]const u8{ "escape", "backspace", "ctrl+" }) |bad| {
        try f.setLeader(bad);
        try testing.expectEqualStrings(",", app.leaderText());
    }
    try testing.expect(config.validLeader("space"));
    try testing.expect(!config.validLeader("escape"));
    _ = try f.sent();
}

test "leader: a non-Latin layout reaches it and the tree by the Latin key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try f.setLeader("ctrl+a");
    // ⌃α on the A key, as a Kitty host reports it, then ι on the I key.
    try f.feed("\x1b[945::97;5u");
    try testing.expect(app.leader.pending());
    try f.feed("\x1b[953::105u");
    try testing.expectEqual(Screen.inbox, app.screen);
    try f.feed("\x1b");
    // Another Greek key is no leader, and a leader of Greek's own needs its own key.
    try f.feed("\x1b[946::98;5u");
    try testing.expect(!app.leader.pending());
    try f.setLeader("ctrl+β");
    try f.feed("\x1b[945::97;5u");
    try testing.expect(!app.leader.pending());
    try f.feed("\x1b[946::98;5u");
    try testing.expect(app.leader.pending());
    try f.feed("\x1b");
    _ = try f.sent();
}

test "leader: legacy control bytes 0x1c-0x1f are their Ctrl keys" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_][2][]const u8{ .{ "ctrl+\\\\", "\x1c" }, .{ "ctrl+]", "\x1d" }, .{ "ctrl+^", "\x1e" }, .{ "ctrl+_", "\x1f" } }) |c| {
        try f.setLeader(c[0]);
        try f.feed(c[1]);
        try testing.expect(f.app.leader.pending());
        try f.feed("\x1b");
        try testing.expect(!f.app.leader.pending());
    }
}

test "popup: after the delay, level by level, with the tree's rows, and gone with leader mode" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try f.feed(" ");
    const start = app.now_ms;
    // Not yet, and the loop knows when.
    try testing.expect(!app.leader_timer.visible());
    try testing.expect(!has(try f.screen(), "venom ─"));
    try testing.expectEqual(@as(?i64, start + 200), app.leaderWake());
    // A key that knows the way never sees it.
    app.now_ms += 100;
    try f.feed("a");
    app.now_ms += 100;
    app.syncLeader();
    try testing.expect(!app.leader_timer.visible());
    app.now_ms += 100;
    app.syncLeader();
    try testing.expect(app.leader_timer.visible());
    try testing.expectEqual(@as(?i64, null), app.leaderWake());
    const agents = try f.screen();
    try testing.expect(has(agents, "venom › agents"));
    try testing.expect(has(agents, "stop its turn"));
    try testing.expect(has(agents, "new agent, pick the workspace"));
    // Up a level, at once.
    try f.feed("\x7f");
    const root = try f.screen();
    try testing.expect(app.leader_timer.visible());
    try testing.expect(has(root, "agents"));
    try testing.expect(has(root, "workspaces"));
    try testing.expect(has(root, "splits"));
    try testing.expect(has(root, "inbox"));
    try testing.expect(has(root, "all keys"));
    // The split rows, with both keys of a direction on one row.
    try f.feed("v");
    const splits = try f.screen();
    try testing.expect(has(splits, "venom › splits"));
    try testing.expect(has(splits, "h ←"));
    try testing.expect(has(splits, "split to the left"));
    try f.feed("\x1b");
    try testing.expect(!app.leader_timer.visible());
    try testing.expect(!has(try f.screen(), "venom › splits"));
}

test "popup: delay 0 is at once, and a timeout ends leader mode with no key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try app.requestKeysConfig();
    try f.config(.popup_delay_ms, "0");
    try f.config(.timeout_ms, "1000");
    _ = try f.sent();
    try f.feed(" ");
    try testing.expect(app.leader_timer.visible());
    const end = app.now_ms + 1000;
    try testing.expectEqual(@as(?i64, end), app.leaderWake());
    app.now_ms = end - 1;
    app.syncLeader();
    try testing.expect(app.leader.pending());
    app.now_ms = end;
    app.syncLeader();
    try testing.expect(!app.leader.pending() and !app.leader_timer.visible());
    try testing.expectEqual(@as(?i64, null), app.leaderWake());
}

test "host mode: the direction rows are absent, from the keys and the popup" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    var host = try host_mod.Host.init(ta, .{ .control = "p1", .exe = "/bin/venom", .socket = "/run/venom.sock" });
    defer host.deinit();
    app.host = &host;
    defer app.host = null;
    app.key_settings.popup_delay_ms = 0;
    try f.feed(" v");
    const splits = try f.screen();
    try testing.expect(has(splits, "close the split"));
    try testing.expect(!has(splits, "split to the left"));
    // Bound nowhere, so it cancels like any unbound key.
    try f.feed("h");
    try testing.expect(!app.leader.pending());
    try f.feed("?");
    const help = try f.screen();
    try testing.expect(has(help, "space v x"));
    try testing.expect(!has(help, "split to the left"));
    try f.feed("x");
}

test "own mode: the direction rows move between the list, the main view and splits" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try testing.expectEqual(app_mod.Area.list, app.area());
    try f.feed(" vh");
    try testing.expectEqual(app_mod.Area.list, app.area());
    try f.feed(" vl");
    try testing.expectEqual(app_mod.Area.transcript, app.area());
    // Arrows do the same.
    try f.feed(" v\x1b[D");
    try testing.expectEqual(app_mod.Area.list, app.area());
    try f.feed(" v\x1b[C");
    try testing.expectEqual(app_mod.Area.transcript, app.area());
    try f.feed(" vl");
    try testing.expectEqual(app_mod.Area.transcript, app.area());
    // Down is the box, which is Input, where the leader is not.
    try f.feed(" vj");
    try testing.expectEqual(app_mod.Area.input, app.area());
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try f.feed("\x1b");
    // Nothing to close.
    try f.feed(" vx");
    try testing.expect(has(app.message.items, "no split"));
}

test "bare keys: Kitty's reports of the tree's keys match too" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    // space, `a`, then `N` as Kitty reports it: `n` + shift, with the shifted key.
    try f.feed("\x1b[32u\x1b[97u\x1b[110:78;2u");
    try testing.expect(app.dialog != null);
    try f.feed("\x1b");
    _ = try f.sent();
}

test "!: goes to the next agent that needs you, past what doesn't block" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    try f.feed("!");
    try testing.expect(has(app.message.items, "nothing needs you"));
    try app.requestInbox();
    try t.answer(app, f.a(), "inbox.list", approvals);
    _ = try f.sent();
    try app.setSelected("a1");
    _ = try f.sent();
    try f.feed("!");
    try testing.expectEqualStrings("a2", app.selected.items);
    try testing.expectEqual(app_mod.Area.transcript, app.area());
    _ = try f.sent();
    try f.feed("!");
    try testing.expectEqualStrings("a3", app.selected.items);
    _ = try f.sent();
    // `a4` only wants a review: it wraps around.
    try f.feed("!");
    try testing.expectEqualStrings("a1", app.selected.items);
    _ = try f.sent();
    // On the inbox screen, the cursor.
    try f.feed(" i");
    try f.feed("!");
    try testing.expect(std.mem.startsWith(u8, app.inbox_cursor.items, "a2/"));
    // `m` marks there, and space is the leader.
    try f.feed("m");
    try testing.expectEqual(@as(usize, 1), app.marks.items.len);
    try f.feed(" \x1b");
    try testing.expectEqual(@as(usize, 1), app.marks.items.len);
    try f.feed("\x1b");
    _ = try f.sent();
}

test "d: the agent's diff in the pager; its answer never takes the keys of what came after" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const app = &f.app;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", f.a());
    const show = try std.fmt.allocPrint(f.a(), "{{\"agent\":\"a1\",\"cwd\":\"{s}\",\"checkouts\":[{{\"path\":\"{s}\"}}]}}", .{ dir, dir });
    const answerDiff = struct {
        fn run(ap: *App, ar: std.mem.Allocator, json: []const u8) !void {
            var it = ap.pending.iterator();
            const id = while (it.next()) |e| {
                if (e.value_ptr.* == .diff) break e.key_ptr.*;
            } else return error.NoDiffAsked;
            try ap.onResponse(id, .{ .ok = try std.json.parseFromSliceLeaky(Value, ar, json, .{}) });
        }
    }.run;
    try f.feed("d");
    try testing.expectEqualStrings("agent.show(a1) ", try f.sent());
    try answerDiff(app, f.a(), show);
    try testing.expect(app.pager != null);
    try testing.expect(has(app.pager.?.parts[0], dir));
    try testing.expect(has(try f.screen(), "Diff · a1"));
    try f.feed("\x1b");
    try testing.expect(app.pager == null);
    _ = try f.sent();
    // `leader d`, and text typed before the answer stays text.
    try f.feed(" d");
    try testing.expectEqualStrings("agent.show(a1) ", try f.sent());
    try f.feed("iy");
    try answerDiff(app, f.a(), show);
    try testing.expect(app.pager == null);
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try f.feed("n");
    try testing.expectEqualStrings("yn", app.input.value());
    try f.feed("\x1b");
    app.input.clear();
    // Not connected: says so.
    app.connected = false;
    try f.feed("d");
    try testing.expect(has(app.message.items, "not connected"));
}

test "space is the leader's: no bare row claims it but the dialog's" {
    for (keys.table) |b| {
        if (b.context == .settings) try testing.expect(!has(b.keys, "space"));
        if (b.context == .inbox) try testing.expect(!has(b.keys, "space"));
        if (b.context == .list) try testing.expect(!has(b.keys, "space"));
    }
}

test "doctor: warns only when the two leaders are the same chord" {
    try testing.expect(host_mod.leadersClash("ctrl+a", "ctrl+a"));
    try testing.expect(!host_mod.leadersClash("space", "ctrl+a"));
    try testing.expect(!host_mod.leadersClash("bad+", "ctrl+a"));

    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const cli = @import("cli");
    const write = struct {
        fn zon(d: std.Io.Dir, text: []const u8) !void {
            try d.writeFile(testing.io, .{ .sub_path = "config.zon", .data = text });
        }
    }.zon;
    const run = struct {
        fn go(ar: std.mem.Allocator, path: []const u8, venomx: ?[]const u8) !cli.doctor.Status {
            var store = try config.Store.init(ta, .{ .io = testing.io, .path = path, .validate = config.validate });
            defer store.deinit();
            const reader = struct {
                fn read(ctx: *const anyopaque, _: std.mem.Allocator) ?[]const u8 {
                    const v: *const ?[]const u8 = @ptrCast(@alignCast(ctx));
                    return v.*;
                }
            }.read;
            var check: host_mod.LeaderCheck = .{ .config = &store, .read = reader, .ctx = &venomx };
            var report: cli.doctor.Report = .{ .arena = ar, .tool = "venom" };
            try check.run(&report);
            try testing.expectEqualStrings("ui.keys.leader", report.results.items[0].id);
            return report.results.items[0].status;
        }
    }.go;
    const path = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    // Defaults: `space` against venomx's own.
    try testing.expectEqual(cli.doctor.Status.ok, try run(a, path, "ctrl+a"));
    try testing.expectEqual(cli.doctor.Status.ok, try run(a, path, null));
    try write(tmp.dir, ".{ .ui = .{ .keys = .{ .leader = \"ctrl+a\" } } }");
    try testing.expectEqual(cli.doctor.Status.warn, try run(a, path, "ctrl+a"));
    // venomx down, or never in the way.
    try testing.expectEqual(cli.doctor.Status.ok, try run(a, path, null));
    try write(tmp.dir, ".{ .ui = .{ .chrome = .own, .keys = .{ .leader = \"ctrl+a\" } } }");
    try testing.expectEqual(cli.doctor.Status.ok, try run(a, path, "ctrl+a"));
}

test "doctor: warns when venomx runs with grants.isolation off" {
    const cli = @import("cli");
    const run = struct {
        fn go(ar: std.mem.Allocator, mode: host_mod.Isolation) !cli.doctor.Status {
            const reader = struct {
                fn read(ctx: *const anyopaque, _: std.mem.Allocator) host_mod.Isolation {
                    const v: *const host_mod.Isolation = @ptrCast(@alignCast(ctx));
                    return v.*;
                }
            }.read;
            var check: host_mod.IsolationCheck = .{ .read = reader, .ctx = &mode };
            var report: cli.doctor.Report = .{ .arena = ar, .tool = "venom" };
            try check.run(&report);
            const got = report.results.items[0];
            try testing.expectEqualStrings("venomx.isolation", got.id);
            if (got.status == .warn) try testing.expect(std.mem.indexOf(u8, got.fix, "config set --key grants.isolation --value true") != null);
            return got.status;
        }
    }.go;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try testing.expectEqual(cli.doctor.Status.warn, try run(ar, .off));
    try testing.expectEqual(cli.doctor.Status.ok, try run(ar, .on));
    try testing.expectEqual(cli.doctor.Status.ok, try run(ar, .down));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ar, "{\"content\":\"false\",\"source\":\"builtin\",\"sources\":[]}", .{});
    try testing.expectEqual(host_mod.Isolation.off, host_mod.isolationOf(parsed));
    const on = try std.json.parseFromSliceLeaky(std.json.Value, ar, "{\"content\":\"true\",\"source\":\"user\",\"sources\":[]}", .{});
    try testing.expectEqual(host_mod.Isolation.on, host_mod.isolationOf(on));
}
