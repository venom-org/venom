//! Headless settings tests: the screen renders into a
//! venom-term Surface and is driven with key bytes; no test opens a TTY.
//!
//! - The settings screen's snapshot against `testdata/settings_view.txt`.
//! - Keys build the pending diff and the command; nothing is sent before ⌃s.
//! - Live, against a real daemon's config verbs: each section round-trips a
//!   change through `config set`; the effective config afterwards is what the
//!   diff predicted, the file holds it, and the command shown, run through the
//!   real CLI, writes the same bytes; invalid values name the failing key; the
//!   layer picker reads and writes the workspace and repo files.
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const App = @import("app.zig").App;
const Link = @import("link.zig").Link;
const view = @import("view.zig");
const settings = @import("settings.zig");
const zon_text = @import("zon_text.zig");
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const save = "\x13"; // ⌃s
const clear_line = "\x15"; // ⌃u

/// `config.get` at the defaults, as the daemon renders it (one layer set).
const fixture_get =
    \\{"content":".{ .grants = .{ .unknown = .{.{.right=.read,.scope=\"*\"}}, .max_token_ttl = 86400, }, .log = .{ .level = .info, }, .agents = .{ .default = .claude_code, .mode = .ask, .isolation = .worktree, .max_concurrent = 4, .spawn = .{ .allow = true, .depth = 2, }, .archive_after = \"3d\", }, .attention = .{ .bell = true, .notify_after = \"2m\", .approval_timeout = null, }, .ui = .{ .children = .tree, }, }","source":"user",
    \\ "sources":[{"key":"agents.default","source":"builtin"},{"key":"agents.mode","source":"builtin"},{"key":"agents.isolation","source":"builtin"},{"key":"agents.max_concurrent","source":"user"},{"key":"agents.spawn.allow","source":"builtin"},{"key":"agents.spawn.depth","source":"builtin"},{"key":"agents.archive_after","source":"builtin"}]}
;

const fixture_workspaces =
    \\{"workspaces":[{"path":"/home/me/venom-org","repos":[{"name":"venom","path":"/home/me/venom-org/venom"}]}]}
;

const fixture_harnesses =
    \\{"harnesses":[{"harness":"claude-code","enabled":true,"found":true,"version":"2.4.1","signed_in":true,"sign_in_detail":"Max plan"},
    \\{"harness":"codex","enabled":true,"found":true,"version":"0.71.0","signed_in":false,"fix":"codex login"}]}
;

fn answer(app: *App, a: std.mem.Allocator, purpose: std.meta.Tag(settings.Request), ok: []const u8) !void {
    var it = app.pending.iterator();
    var found: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .settings and std.meta.activeTag(e.value_ptr.settings) == purpose) {
        if (found == null or e.key_ptr.* > found.?) found = e.key_ptr.*;
    };
    try app.onResponse(found.?, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, ok, .{}) });
}

fn fixture(app: *App, a: std.mem.Allocator) !void {
    app.home = "/home/me";
    app.settings.user_path = "/home/me/.config/venom/config.zon";
    try app.onConnected();
    try app.openSettings();
    try answer(app, a, .workspaces, fixture_workspaces);
    try answer(app, a, .harnesses, fixture_harnesses);
    try answer(app, a, .get, fixture_get);
    _ = try t.sent(a, app);
    // The screen opens on Providers; these tests start one section below,
    // on General, and move from there.
    app.settings.section = 1;
}

fn verbsSent(a: std.mem.Allocator, app: *App) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (app.outbox.items) |line| {
        const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{});
        try out.print(a, "{s} ", .{v.object.get("verb").?.string});
        ta.free(line);
    }
    app.outbox.clearRetainingCapacity();
    return out.items;
}

fn diffText(a: std.mem.Allocator, app: *App) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (try app.settings.pendingDiff(a)) |l| if (l.kind == .add or l.kind == .del) {
        try out.print(a, "{s}{s}\n", .{ if (l.kind == .add) "+" else "-", std.mem.trim(u8, l.text, " ") });
    };
    return out.items;
}

test "settings screen snapshot matches testdata/settings_view.txt" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    var surface = try term.Surface.init(ta, 140, 32);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    // Agents, on Max concurrent agents, edited from 4 to 6.
    _ = try app.feed("jjljjj\r" ++ clear_line ++ "6\r");
    try view.render(&app, &surface);
    const got = try t.dump(a, &surface);
    try testing.expectEqualStrings(@embedFile("testdata/settings_view.txt"), got);
    // Narrow: the preview goes under the rows.
    try surface.resize(90, 30);
    try view.render(&app, &surface);
    const narrow = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, narrow, ".max_concurrent = 6,") != null);
    try testing.expect(std.mem.indexOf(u8, narrow, "venom config set --key=agents.max_concurrent --value=6") != null);
    // Its keys in the help, and only there.
    _ = try app.feed("?");
    try view.render(&app, &surface);
    const help = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, help, "save and reload") != null);
    try testing.expect(std.mem.indexOf(u8, help, "stop the agent's turn") == null);
}

test "the Integrations section shows found, version and sign-in, and the harness's own sign-in command" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    app.settings.section = settings.integrations_section;
    const rows = try app.settings.rows(a);
    const n = rows.len;
    try testing.expectEqualStrings("claude-code  2.4.1 · signed in", rows[n - 2].info.title);
    try testing.expectEqualStrings("Max plan", rows[n - 2].info.detail);
    try testing.expectEqualStrings("codex  0.71.0 · not signed in", rows[n - 1].info.title);
    try testing.expectEqualStrings("codex login", rows[n - 1].info.detail);
    // A line to read: enter and h l on it change nothing.
    _ = try app.feed("l");
    for (0..n) |_| _ = try app.feed("j");
    _ = try app.feed("\rhl");
    try testing.expectEqual(@as(usize, 0), app.settings.pending.items.len);
}

test "h l step a choice and a toggle, and go between panes on anything else" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("jjl"); // Agents, its first row: a choice
    try testing.expect(s.focus == .rows);
    _ = try app.feed("l");
    try testing.expectEqual(@as(usize, 1), s.pending.items.len);
    try testing.expect(s.focus == .rows);
    _ = try app.feed("\x1b[D"); // ← steps it back, so nothing is left pending
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    _ = try app.feed("jjj"); // a number
    _ = try app.feed("l");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expect(s.focus == .preview);
    _ = try app.feed("h");
    try testing.expect(s.focus == .rows);
    // Space is the leader's, and edits nothing.
    _ = try app.feed(" ");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expect(app.leader.pending());
}

test "keys build the pending diff and the command; nothing is sent before ⌃s" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;

    // A toggle: ⏎ flips it, and flipping back leaves nothing pending.
    _ = try app.feed("jjl"); // Agents, the rows
    _ = try app.feed("jjjj\r"); // Allow agents to spawn agents
    try testing.expectEqualStrings("-.allow = true,\n+.allow = false,\n", try diffText(a, &app));
    try testing.expectEqualStrings("venom config set --key=agents.spawn.allow --value=false", try s.command(a, s.pending.items[0]));
    _ = try app.feed("\r");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expectEqual(@as(usize, 0), (try s.pendingDiff(a)).len);

    // A choice: enter steps through the type's names and wraps.
    _ = try app.feed("kkkk\r");
    try testing.expectEqualStrings(".codex", s.value("agents.default").?);
    _ = try app.feed("\r");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);

    // A duration: typed bare, quoted for ZON and for the shell.
    _ = try app.feed("jjjjjjj\r" ++ clear_line ++ "5d\r");
    try testing.expectEqualStrings("agents.archive_after", s.pending.items[0].key);
    try testing.expectEqualStrings("\"5d\"", s.pending.items[0].value);
    try testing.expectEqualStrings("venom config set --key=agents.archive_after --value='\"5d\"'", try s.command(a, s.pending.items[0]));
    // Esc leaves a prompt without changing anything; u undoes.
    _ = try app.feed("\r" ++ clear_line ++ "9d\x1b");
    try testing.expectEqualStrings("\"5d\"", s.pending.items[0].value);
    _ = try app.feed("u");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expectEqualStrings("", try verbsSent(a, &app));

    // ⌃s sends each change in order, then reloads.
    _ = try app.feed("kkkkkk\r");
    try testing.expectEqualStrings("agents.mode", s.pending.items[0].key);
    _ = try app.feed("j\r");
    try testing.expectEqualStrings("agents.mode", s.pending.items[0].key);
    try testing.expectEqualStrings("agents.isolation", s.pending.items[1].key);
    _ = try app.feed(save);
    try testing.expectEqualStrings("config.set ", try verbsSent(a, &app));
    try answer(&app, a, .set, "{\"changed\":true,\"restart_required\":false}");
    try testing.expectEqualStrings("config.set ", try verbsSent(a, &app));
    try answer(&app, a, .set, "{\"changed\":true,\"restart_required\":false}");
    try testing.expectEqualStrings("config.reload ", try verbsSent(a, &app));
    try answer(&app, a, .reload, "{\"changed\":true,\"restart_required\":false}");
    try testing.expectEqualStrings("provider.list config.get ", try verbsSent(a, &app));
    try testing.expect(!s.applying);
    try testing.expectEqualStrings("saved and reloaded", app.message.items);

    // Layers: S walks user → workspace → repo, and each `config.get` asks for it.
    _ = try app.feed("S");
    try testing.expectEqualStrings("workspace", s.currentLayer().name());
    try testing.expectEqualStrings("/home/me/venom-org/.venom/workspace.zon", s.filePath());
    try testing.expect(std.mem.indexOf(u8, app.outbox.items[0], "\"workspace\":\"/home/me/venom-org\"") != null);
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get); // the layer's own
    _ = try app.feed("S");
    try testing.expectEqualStrings("repo", s.currentLayer().name());
    try testing.expectEqualStrings("/home/me/venom-org/venom/.venom/repo.zon", s.filePath());
    try testing.expect(std.mem.indexOf(u8, app.outbox.items[0], "\"repo\":\"venom\"") != null);
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get);
    // A user-only key stays out of a narrower file; the command names the layer.
    _ = try app.feed("j\r");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expect(s.editing == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "agents.max_concurrent is user-only") != null);
    _ = try app.feed("k\r");
    try testing.expectEqualStrings("venom config set --key=agents.isolation --value=.in_place --workspace=/home/me/venom-org --repo=venom", try s.command(a, s.pending.items[0]));
    // The layer can't change under unsaved changes.
    _ = try app.feed("S");
    try testing.expectEqualStrings("repo", s.currentLayer().name());
    try testing.expect(std.mem.indexOf(u8, app.message.items, "1 unsaved") != null);

    // Leaving with unsaved changes asks once, then drops them.
    _ = try app.feed("\x1b");
    try testing.expectEqual(@import("app.zig").Screen.settings, app.screen);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "again drops") != null);
    _ = try app.feed("\x1b");
    try testing.expectEqual(@import("app.zig").Screen.main, app.screen);
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);

    // `space s` opens it from the agent list; standalone (`venom settings`), esc
    // leaves the TUI.
    _ = try app.feed(" s");
    try testing.expectEqual(@import("app.zig").Screen.settings, app.screen);
    _ = try verbsSent(a, &app);
    s.standalone = true;
    _ = try app.feed("\x1b");
    try testing.expect(app.quit);
}

test "the unsaved warning survives a popup's narrow bar" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    _ = try app.feed("jjl\r");
    _ = try app.feed("\x1b");
    var discard: std.Io.Writer.Discarding = .init(&.{});
    // `venom.settings` in a 100-column terminal: whole, the workspace gives way.
    var wide = try term.Surface.init(ta, 78, 22);
    defer wide.deinit(&discard.writer);
    try view.render(&app, &wide);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &wide), "1 unsaved: again drops, ⌃s saves") != null);
    // In an 80-column one the end goes, not what the next esc will do.
    var narrow = try term.Surface.init(ta, 62, 22);
    defer narrow.deinit(&discard.writer);
    try view.render(&app, &narrow);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &narrow), "1 unsaved: again drops") != null);
}

test "a refused set stops the rest, shows the failing key and keeps the value pending" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    var surface = try term.Surface.init(ta, 140, 32);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try app.feed("jjljjj\r" ++ clear_line ++ "0\rj\r");
    try testing.expectEqual(@as(usize, 2), s.pending.items.len);
    _ = try app.feed(save);
    _ = try verbsSent(a, &app);
    var it = app.pending.iterator();
    var id: i64 = 0;
    while (it.next()) |e| if (e.value_ptr.* == .settings and e.value_ptr.settings == .set) {
        id = e.key_ptr.*;
    };
    const data = try std.json.parseFromSliceLeaky(Value, a, "{\"param\":\"value\",\"key\":\"agents.max_concurrent\"}", .{});
    try app.onResponse(id, .{ .@"error" = .{ .code = "invalid_params.config_value", .message = "", .data = data } });
    try testing.expectEqualStrings("agents.max_concurrent", s.failure.?.key);
    try testing.expectEqual(@as(usize, 2), s.pending.items.len);
    try testing.expect(!s.applying);
    // The values reload (what went before it is in the file); the failure stays.
    try testing.expectEqualStrings("config.get ", try verbsSent(a, &app));
    try answer(&app, a, .get, fixture_get);
    try view.render(&app, &surface);
    const screen = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, screen, "✕ agents.max_concurrent") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "invalid_params.config_value") != null);
    // Undoing the newest keeps the failing one pending; the next ⌃s tries it.
    _ = try app.feed("u");
    try testing.expectEqual(@as(usize, 1), s.pending.items.len);
    try testing.expect(s.failure == null);
}

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

fn errorBody(a: std.mem.Allocator, code: []const u8, key: []const u8) !@import("proto").Response.Body {
    const json = try std.fmt.allocPrint(a, "{{\"param\":\"value\",\"key\":\"{s}\"}}", .{key});
    return .{ .@"error" = .{ .code = code, .message = "", .data = try std.json.parseFromSliceLeaky(Value, a, json, .{}) } };
}

fn newest(app: *App, purpose: std.meta.Tag(settings.Request)) i64 {
    var it = app.pending.iterator();
    var found: i64 = 0;
    while (it.next()) |e| if (e.value_ptr.* == .settings and std.meta.activeTag(e.value_ptr.settings) == purpose) {
        found = @max(found, e.key_ptr.*);
    };
    return found;
}

test "a comment typed in a value is not part of it: preview, command and request" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("jjljjj\r" ++ clear_line ++ "5 // why\r");
    try testing.expectEqualStrings("5", s.pending.items[0].value);
    try testing.expectEqualStrings("-.max_concurrent = 4,\n+.max_concurrent = 5,\n", try diffText(a, &app));
    try testing.expectEqualStrings("venom config set --key=agents.max_concurrent --value=5", try s.command(a, s.pending.items[0]));
}

test "a paste is text for a prompt and nothing else" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("jjl"); // Agents, the rows
    // Outside a prompt it does nothing: no toggle, no save, no quit, no move.
    _ = try app.feed(paste_start ++ " \r\x13qSuj\x03" ++ paste_end);
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expectEqual(@as(usize, 0), s.row);
    try testing.expect(!app.quit);
    try testing.expectEqualStrings("", try verbsSent(a, &app));
    // With the help open too.
    _ = try app.feed("?" ++ paste_start ++ "q" ++ paste_end);
    try testing.expect(app.help and !app.quit);
    _ = try app.feed("x");
    // In a prompt it is text: a line break does not submit, and `q` after it
    // is a letter.
    _ = try app.feed("jjj\r" ++ clear_line ++ paste_start ++ "9\rq\x13" ++ paste_end);
    try testing.expect(s.editing != null);
    try testing.expectEqualStrings("9 q", s.input.value());
    try testing.expect(!app.quit);
    try testing.expectEqualStrings("", try verbsSent(a, &app));
    // After the paste, keys are keys again.
    _ = try app.feed("\x1b");
    try testing.expect(s.editing == null);
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "nothing can be edited during a save, so nothing is lost" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("jjljjj\r" ++ clear_line ++ "6\r");
    _ = try app.feed(save);
    try testing.expect(s.applying);
    _ = try verbsSent(a, &app);
    // Edit, undo, prompt, layer and leaving all wait.
    _ = try app.feed("\r");
    try testing.expect(s.editing == null);
    _ = try app.feed("j\rku");
    try testing.expectEqual(@as(usize, 1), s.pending.items.len);
    try testing.expectEqualStrings("6", s.pending.items[0].value);
    _ = try app.feed("S\x1b");
    try testing.expectEqualStrings("user", s.currentLayer().name());
    try testing.expectEqual(@import("app.zig").Screen.settings, app.screen);
    try answer(&app, a, .set, "{\"changed\":true,\"restart_required\":false}");
    try testing.expectEqualStrings("config.reload ", try verbsSent(a, &app));
    try answer(&app, a, .reload, "{\"changed\":true,\"restart_required\":false}");
    try testing.expect(!s.applying);
    // And editable again.
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get);
    _ = try app.feed("\r");
    try testing.expect(s.editing != null);
}

test "the Raw prompt keeps its own key when config.get replaces the sources" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    s.section = settings.raw_section;
    s.focus = .rows;
    _ = try app.feed("jjj\r"); // agents.max_concurrent
    try testing.expectEqualStrings("agents.max_concurrent", s.editing.?.key);
    try s.refresh(&app);
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get);
    try testing.expectEqualStrings("agents.max_concurrent", s.editing.?.key);
    _ = try app.feed(clear_line ++ "9\r");
    try testing.expectEqualStrings("agents.max_concurrent", s.pending.items[0].key);
}

test "a pending edit never changes layer: its layer gone, it is dropped, visibly" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("S");
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get);
    _ = try app.feed("jjlj\r"); // agents.mode, in the workspace file
    try testing.expectEqualStrings(".accept_edits", s.pending.items[0].value);

    // Reconnected, the workspace is still there, at another index: it stays.
    try app.onDisconnected();
    try app.onConnected();
    _ = try verbsSent(a, &app);
    try answer(&app, a, .workspaces, "{\"workspaces\":[{\"path\":\"/other\",\"repos\":[]},{\"path\":\"/home/me/venom-org\",\"repos\":[]}]}");
    try testing.expectEqualStrings("/home/me/venom-org", s.currentLayer().workspace.?);
    try testing.expectEqual(@as(usize, 1), s.pending.items.len);
    try testing.expect(std.mem.indexOf(u8, s.command(a, s.pending.items[0]) catch "", "--workspace=/home/me/venom-org") != null);

    // Now it is gone: the edit goes with it, the user layer's values load,
    // and the old layer's answer can't land on them.
    try s.refresh(&app);
    _ = try verbsSent(a, &app);
    const stale = newest(&app, .get);
    try answer(&app, a, .workspaces, "{\"workspaces\":[]}");
    try testing.expectEqualStrings("user", s.currentLayer().name());
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try testing.expect(s.effective == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "workspace layer is gone: 1 unsaved change dropped") != null);
    try testing.expect(newest(&app, .get) != stale);
    try app.onResponse(stale, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, fixture_get, .{}) });
    try testing.expect(s.effective == null);
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get);
    try testing.expect(s.effective != null);
}

test "a partial save reloads what went through and keeps the refusal on screen" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("jjljjjj\r"); // agents.spawn.allow, saved
    _ = try app.feed("kk\r"); // agents.isolation, refused
    _ = try app.feed(save);
    _ = try verbsSent(a, &app);
    try answer(&app, a, .set, "{\"changed\":true,\"restart_required\":false}");
    _ = try verbsSent(a, &app);
    try app.onResponse(newest(&app, .set), try errorBody(a, "invalid_params.config_value", "agents.isolation"));
    // The daemon reloads A; nothing else goes out before it answers.
    try testing.expect(s.applying);
    try testing.expectEqualStrings("config.reload ", try verbsSent(a, &app));
    try answer(&app, a, .reload, "{\"changed\":true,\"restart_required\":false}");
    try testing.expect(!s.applying);
    try testing.expectEqualStrings("provider.list config.get ", try verbsSent(a, &app));
    try testing.expectEqualStrings("agents.isolation", s.failure.?.key);
    try testing.expectEqual(@as(usize, 1), s.pending.items.len);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "1 saved before it and reloaded") != null);
    try answer(&app, a, .get, fixture_get);
    try testing.expectEqualStrings("agents.isolation", s.failure.?.key);
}

test "a failed reload stays on screen after the next config.get" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    const s = &app.settings;
    _ = try app.feed("jjl\r");
    _ = try app.feed(save);
    _ = try verbsSent(a, &app);
    try answer(&app, a, .set, "{\"changed\":true,\"restart_required\":false}");
    _ = try verbsSent(a, &app);
    try app.onResponse(newest(&app, .reload), try errorBody(a, "invalid_params.config_value", "harness.body_max"));
    _ = try verbsSent(a, &app);
    try answer(&app, a, .get, fixture_get);
    try testing.expectEqualStrings("harness.body_max", s.failure.?.key);
    try testing.expectEqual(@FieldType(settings.Failure, "kind").reload, s.failure.?.kind);
}

test "⌃c and q with unsaved changes ask first, from the help and a prompt too" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    _ = try app.feed("jjl\r");
    try testing.expectEqual(@as(usize, 1), app.settings.pending.items.len);
    _ = try app.feed("\x03");
    try testing.expect(!app.quit);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "again drops") != null);
    _ = try app.feed("j"); // any other key disarms it
    _ = try app.feed("?\x03");
    try testing.expect(!app.quit and !app.help);
    _ = try app.feed("jj\r"); // a prompt
    try testing.expect(app.settings.editing != null);
    _ = try app.feed("k"); // text
    _ = try app.feed("\x1b");
    _ = try app.feed("k"); // disarmed
    _ = try app.feed("\r\x03");
    try testing.expect(!app.quit);
    try testing.expect(app.settings.editing == null);
    _ = try app.feed("\x03");
    try testing.expect(app.quit);
}

test "at 80x24 the preview scrolls to the second change, the command and the checks" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    var surface = try term.Surface.init(ta, 80, 24);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try app.feed("jjl\rjjjj\r"); // agents.default and agents.spawn.allow
    try testing.expectEqual(@as(usize, 2), app.settings.pending.items.len);
    try view.render(&app, &surface);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), " more: ") != null);
    // Scrolling through, every line is seen; whole, not cut.
    _ = try app.feed("\t");
    try testing.expectEqual(settings.Focus.preview, app.settings.focus);
    var seen: std.ArrayList(u8) = .empty;
    for (0..60) |_| {
        try view.render(&app, &surface);
        try seen.appendSlice(a, try t.dump(a, &surface));
        _ = try app.feed("j");
    }
    for ([_][]const u8{ ".default = .codex,", ".allow = false,", "--key=agents.default", "--key=agents.spawn.allow", "--value=false", "● config valid", "⌃s save and reload", "↑ top" }) |want| {
        if (std.mem.indexOf(u8, seen.items, want) == null) std.debug.print("never shown: {s}\n", .{want});
        try testing.expect(std.mem.indexOf(u8, seen.items, want) != null);
    }
    // Page keys work from any pane, and it stops at the top.
    _ = try app.feed("\t\x1b[5~\x1b[5~\x1b[5~\x1b[5~\x1b[5~");
    try view.render(&app, &surface);
    try testing.expectEqual(@as(usize, 0), app.settings.preview_top);
}

const Applied = struct {
    pub fn check(_: Applied, app: *App, _: *term.Surface) !bool {
        return !app.settings.applying and app.pending.count() == 0 and app.outbox.items.len == 0;
    }
};

const Failed = struct {
    key: []const u8,
    pub fn check(self: Failed, app: *App, _: *term.Surface) !bool {
        const f = app.settings.failure orelse return false;
        return !app.settings.applying and std.mem.eql(u8, f.key, self.key);
    }
};

/// One section's change: `keys` from the top of the section's rows.
const Case = struct {
    section: usize,
    key: []const u8,
    keys: []const u8,
    want: []const u8,
};

/// Every section with a config key behind it. (Keys is read-only: checked
/// below. Raw config's cursor is found, not counted.)
const cases = [_]Case{
    .{ .section = 1, .key = "log.level", .keys = "\r", .want = ".debug" },
    .{ .section = 2, .key = "ui.group_by", .keys = "\r", .want = ".workspace" },
    .{ .section = 3, .key = "agents.max_concurrent", .keys = "jjj\r" ++ clear_line ++ "4\r", .want = "4" },
    .{ .section = 4, .key = "harness.start_timeout", .keys = "j\r" ++ clear_line ++ "45s\r", .want = "\"45s\"" },
    .{ .section = 5, .key = "grants.max_token_ttl", .keys = "jjj\r" ++ clear_line ++ "3600\r", .want = "3600" },
    .{ .section = 6, .key = "agents.isolation", .keys = "\r", .want = ".in_place" },
    .{ .section = 7, .key = "attention.approval_timeout", .keys = "jj\r" ++ clear_line ++ "10m\r", .want = "\"10m\"" },
    .{ .section = 8, .key = "ui.transcript.density", .keys = "\r", .want = ".verbose" },
    .{ .section = 9, .key = "ui.context.warn_at", .keys = "\r" ++ clear_line ++ "90\r", .want = "90" },
    .{ .section = 10, .key = "ui.chrome", .keys = "\r", .want = ".own" },
    .{ .section = 12, .key = "harness.codex.enabled", .keys = "jjjjj\r", .want = "true" },
};

const Live = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    dir: []const u8,
    d: t.Daemon,
    app: App,
    link: Link,
    surface: term.Surface,

    fn init(self: *Live) !void {
        self.arena = .init(ta);
        const a = self.arena.allocator();
        self.tmp = testing.tmpDir(.{});
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        try self.tmp.dir.createDirPath(testing.io, "work/repo/.git");
        const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{self.dir}, 0);
        if (std.c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = ".{ .harness = .{ .claude_code = .{ .enabled = false }, .codex = .{ .enabled = false } } }" });
        self.d = .{ .dir = self.dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}), .config_admin = true };
        try self.d.start();
        self.app = App.init(ta);
        self.app.settings.user_path = try std.fmt.allocPrint(a, "{s}/config.zon", .{self.dir});
        self.link = .{ .gpa = ta, .path = .{ .socket = self.d.socket } };
        self.surface = try term.Surface.init(ta, 140, 32);
    }

    fn deinit(self: *Live) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.link.deinit();
        self.app.deinit();
        self.d.halt();
        self.d.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn until(self: *Live, comptime what: []const u8, pred: anytype) !void {
        return t.until(&self.app, &self.link, &self.surface, &self.d, what, pred);
    }

    fn read(self: *Live, sub: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub, self.arena.allocator(), .limited(1 << 20));
    }

    fn gotoSection(self: *Live, section: usize) !void {
        const s = &self.app.settings;
        s.focus = .sections;
        for (0..settings.sections.len) |_| _ = try self.app.feed("k");
        for (0..section) |_| _ = try self.app.feed("j");
        _ = try self.app.feed("l");
    }

    /// Saves what is pending, then checks that the config in effect is what
    /// the diff predicted, and that `config get` agrees on `key`.
    fn saveAndCheck(self: *Live, key: []const u8, want: []const u8) !void {
        const a = self.arena.allocator();
        const predicted = try a.dupe(u8, try self.app.settings.after(a));
        _ = try self.app.feed(save);
        try self.until("the change saved", Applied{});
        try testing.expect(self.app.settings.failure == null);
        try testing.expectEqual(@as(usize, 0), self.app.settings.pending.items.len);
        try testing.expectEqualStrings(predicted, self.app.settings.effective.?);
        const l = self.app.settings.currentLayer();
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "config", "get", try std.fmt.allocPrint(a, "--key={s}", .{key}) });
        if (l.workspace) |w| try args.append(a, try std.fmt.allocPrint(a, "--workspace={s}", .{w}));
        if (l.repo) |r| try args.append(a, try std.fmt.allocPrint(a, "--repo={s}", .{r}));
        const got = try self.d.run(a, args.items);
        try testing.expectEqualStrings(want, got.object.get("content").?.string);
    }
};

test "live: each section round-trips a change through config set; diff and command match what is applied" {
    var live: Live = undefined;
    try live.init();
    defer live.deinit();
    const a = live.arena.allocator();
    const app = &live.app;
    const s = &app.settings;
    try live.until("connect", t.Connected{});
    try app.openSettings();
    try live.until("the values", t.Shows{ .text = "● config valid" });

    for (cases) |case| {
        try live.gotoSection(case.section);
        _ = try app.feed(case.keys);
        try testing.expectEqual(@as(usize, 1), s.pending.items.len);
        try testing.expectEqualStrings(case.key, s.pending.items[0].key);
        try testing.expectEqualStrings(case.want, s.pending.items[0].value);
        // The screen shows the diff's new line and the whole command.
        const dot = std.mem.lastIndexOfScalar(u8, case.key, '.').?;
        const plus = try std.fmt.allocPrint(a, ".{s} = {s},", .{ case.key[dot + 1 ..], case.want });
        try live.until("the diff", t.Shows{ .text = plus });
        try live.until("the key in the command", t.Shows{ .text = "venom config set" });
        // Applied: the prediction, the file and `config get` agree.
        try live.saveAndCheck(case.key, case.want);
        const file = try zon_text.normalize(a, try live.read("config.zon"));
        const leaf = try std.fmt.allocPrint(a, ".{s}={s}", .{ case.key[dot + 1 ..], case.want });
        if (std.mem.indexOf(u8, file, leaf) == null) std.debug.print("{s} not in {s}\n", .{ leaf, file });
        try testing.expect(std.mem.indexOf(u8, file, leaf) != null);
    }

    // Raw config: every value, here harness.body_max, found by its row.
    try live.gotoSection(settings.raw_section);
    const rows = try s.rows(a);
    const at = for (rows, 0..) |r, i| {
        if (r == .field and std.mem.eql(u8, r.field.key, "harness.body_max")) break i;
    } else return error.NoRow;
    for (0..at) |_| _ = try app.feed("j");
    _ = try app.feed("\r" ++ clear_line ++ "1000\r");
    try live.saveAndCheck("harness.body_max", "1000");
    // A restart-only key says so.
    try live.gotoSection(settings.integrations_section);
    _ = try app.feed("jj\r");
    try testing.expectEqualStrings("harness.claude_code.enabled", s.pending.items[0].key);
    try live.saveAndCheck("harness.claude_code.enabled", "true");
    try testing.expect(s.restart_required);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "restart the daemon") != null);

    // Past its one config key, Keys is read-only: reading it changes nothing.
    try live.gotoSection(settings.keys_section);
    _ = try app.feed("jjjj\r");
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try live.until("the bindings", t.Shows{ .text = "no config keys for them" });

    // The command shown, run as it is through the real CLI, writes what the
    // screen then writes: the same bytes, nothing left to change.
    try live.gotoSection(7);
    _ = try app.feed("j\r" ++ clear_line ++ "5m\r");
    const p = s.pending.items[0];
    const argv = try s.argv(a, .{ .key = try a.dupe(u8, p.key), .value = try a.dupe(u8, p.value) });
    try testing.expectEqualStrings("venom config set --key=attention.notify_after --value='\"5m\"'", try s.command(a, p));
    const set = try live.d.run(a, argv[1..]);
    try testing.expect(set.object.get("changed").?.bool);
    const by_cli = try live.read("config.zon");
    try live.saveAndCheck("attention.notify_after", "\"5m\"");
    try testing.expectEqualStrings(by_cli, try live.read("config.zon"));

    // Invalid values show the failing key, for a bad number, a bad duration
    // and a value of the wrong type; the file stays as it was.
    const before = try live.read("config.zon");
    const bad = [_]struct { section: usize, keys: []const u8, key: []const u8 }{
        .{ .section = 3, .keys = "jjj\r" ++ clear_line ++ "0\r", .key = "agents.max_concurrent" },
        .{ .section = 7, .keys = "j\r" ++ clear_line ++ "5w\r", .key = "attention.notify_after" },
        .{ .section = 3, .keys = "jjj\r" ++ clear_line ++ "\"six\"\r", .key = "agents.max_concurrent" },
        .{ .section = 9, .keys = "\r" ++ clear_line ++ "101\r", .key = "ui.context.warn_at" },
        .{ .section = 3, .keys = "jjj\r" ++ clear_line ++ "1 6\r", .key = "agents.max_concurrent" },
    };
    for (bad) |case| {
        try live.gotoSection(case.section);
        _ = try app.feed(case.keys);
        _ = try app.feed(save);
        try live.until("the failing key", Failed{ .key = case.key });
        try live.until("it on the screen", t.Shows{ .text = try std.fmt.allocPrint(a, "✕ {s}", .{case.key}) });
        try testing.expect(std.mem.indexOf(u8, app.message.items, case.key) != null);
        try testing.expectEqual(@as(usize, 1), s.pending.items.len);
        try testing.expectEqualStrings(before, try live.read("config.zon"));
        _ = try app.feed("u");
        try live.until("the failure gone", t.Shows{ .text = "● config valid" });
    }
}

test "live: the layer picker reads and writes the workspace and repo files" {
    var live: Live = undefined;
    try live.init();
    defer live.deinit();
    const a = live.arena.allocator();
    const app = &live.app;
    const s = &app.settings;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{live.dir});
    try live.until("connect", t.Connected{});
    _ = try live.d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}", .{work}) });
    try app.openSettings();
    try live.until("the values", t.Shows{ .text = "● config valid" });
    const user = try live.read("config.zon");
    while (s.layers.items.len < 3) try live.until("the layers", LayersAtLeast{ .n = 3 });

    // The workspace file: agents.mode, and only that file.
    _ = try app.feed("S");
    try testing.expectEqualStrings("workspace", s.currentLayer().name());
    try live.until("the workspace's values", t.Shows{ .text = "● config valid" });
    try live.gotoSection(settings.agents_section);
    _ = try app.feed("j\r");
    try testing.expectEqualStrings(".accept_edits", s.pending.items[0].value);
    try live.saveAndCheck("agents.mode", ".accept_edits");
    try testing.expect(std.mem.indexOf(u8, try live.read("work/.venom/workspace.zon"), "accept_edits") != null);
    try testing.expectEqualStrings(user, try live.read("config.zon"));
    try testing.expectEqualStrings("workspace", s.sourceOf("agents.mode"));

    // The repo file, over it: its value wins there, and the command shown
    // writes the same file.
    _ = try app.feed("S");
    try testing.expectEqualStrings("repo", s.currentLayer().name());
    try live.until("the repo's values", ValueIs{ .key = "agents.mode", .want = ".accept_edits" });
    _ = try app.feed("\r");
    try testing.expectEqualStrings(".plan", s.pending.items[0].value);
    const p = s.pending.items[0];
    const argv = try s.argv(a, .{ .key = try a.dupe(u8, p.key), .value = try a.dupe(u8, p.value) });
    try testing.expectEqualStrings("repo", s.currentLayer().repo.?);
    _ = try live.d.run(a, argv[1..]);
    const by_cli = try live.read("work/repo/.venom/repo.zon");
    try live.saveAndCheck("agents.mode", ".plan");
    try testing.expectEqualStrings(by_cli, try live.read("work/repo/.venom/repo.zon"));
    try testing.expectEqualStrings("repo", s.sourceOf("agents.mode"));
    try testing.expect(std.mem.indexOf(u8, try live.read("work/.venom/workspace.zon"), "accept_edits") != null);

    // Back to the user layer, its own value again.
    _ = try app.feed("S");
    try testing.expectEqualStrings("user", s.currentLayer().name());
    try live.until("the user's values", ValueIs{ .key = "agents.mode", .want = ".ask" });
}

const LayersAtLeast = struct {
    n: usize,
    pub fn check(self: LayersAtLeast, app: *App, _: *term.Surface) !bool {
        return app.settings.layers.items.len >= self.n;
    }
};

const ValueIs = struct {
    key: []const u8,
    want: []const u8,
    pub fn check(self: ValueIs, app: *App, _: *term.Surface) !bool {
        const v = app.settings.value(self.key) orelse return false;
        return std.mem.eql(u8, v, self.want);
    }
};
