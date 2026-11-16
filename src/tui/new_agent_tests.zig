//! The workspaces panel and the new-agent dialog: the
//! preview matches `venom agent spawn --dry-run` for the chosen options, and
//! `⏎`, `⇧⏎` and `⌃⏎` behave as the start keys say, with the fake harness.
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const harnesses = @import("../harnesses.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Link = @import("link.zig").Link;
const view = @import("view.zig");
const new_agent = @import("new_agent.zig");
const c = std.c;
const testing = std.testing;
const new_agent_workspaces = @import("workspaces.zig");
const ta = testing.allocator;
const Value = std.json.Value;

const shift_enter = "\x1b[13;2u";
const ctrl_enter = "\x1b[13;5u";

const workspace_list =
    \\{"workspaces":[
    \\{"path":"/home/me/venom-org","repos":[{"name":"venom-docs","path":"/home/me/venom-org/venom-docs","branch":"main","dirty":false,"worktrees":2,"issue":null},{"name":"venom-std","path":"/home/me/venom-org/venom-std","branch":"246-hello-caps","dirty":true,"worktrees":0,"issue":"246"},{"name":"venomx","path":"/home/me/venom-org/venomx"}]},
    \\{"path":"/home/me/scratch","repos":[]}]}
;

const dry_run_ok =
    \\{"agent":"a9","state":"queued","harness":"claude-code","title":"x","workspace":"/home/me/venom-org","repos":["venom-docs","venom-std"],"cwd":"/home/me/venom-org","worktrees":["venom-docs-246","venom-std-246"],"isolation":"worktree","permission_mode":"accept_edits",
    \\"checkouts":[{"repo":"venom-docs","path":"/home/me/venom-org/venom-docs-246","branch":"246-hello-caps","new_branch":true},{"repo":"venom-std","path":"/home/me/venom-org/venom-std-246","branch":"246-hello-caps","new_branch":false}],"dry_run":true}
;

/// The queued requests' verbs and whether each is a dry run; the outbox is
/// emptied.
fn drain(a: std.mem.Allocator, app: *App) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    for (app.outbox.items) |line| {
        try out.append(a, try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{}));
        ta.free(line);
    }
    app.outbox.clearRetainingCapacity();
    return out.items;
}

fn verbOf(v: Value) []const u8 {
    return v.object.get("verb").?.string;
}

/// The one queued `verb` request's params.
fn only(reqs: []const Value, verb: []const u8) !std.json.ObjectMap {
    var found: ?std.json.ObjectMap = null;
    for (reqs) |r| if (std.mem.eql(u8, verbOf(r), verb)) {
        try testing.expect(found == null);
        found = r.object.get("params").?.object;
    };
    return found orelse error.TestExpectedRequest;
}

/// Answers the oldest pending request of this purpose.
fn respond(app: *App, a: std.mem.Allocator, tag: std.meta.Tag(app_mod.Purpose), ok: []const u8) !void {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| {
        if (e.value_ptr.* != tag) continue;
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    }
    try app.onResponse(lowest orelse return error.TestNoPending, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, ok, .{}) });
}

fn failWith(app: *App, tag: std.meta.Tag(app_mod.Purpose), code: []const u8, message: []const u8) !void {
    var it = app.pending.iterator();
    while (it.next()) |e| if (e.value_ptr.* == tag) {
        const id = e.key_ptr.*;
        return app.onResponse(id, .{ .@"error" = .{ .code = code, .message = message, .data = null } });
    };
    return error.TestNoPending;
}

fn has(screen: []const u8, text: []const u8) bool {
    return std.mem.indexOf(u8, screen, text) != null;
}

fn render(app: *App, surface: *term.Surface, a: std.mem.Allocator) ![]const u8 {
    try view.render(app, surface);
    return t.dump(a, surface);
}

test "panel: lists workspaces and repos; + adds, R rescans, and a paste does neither" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try drain(a, &app);

    _ = try app.feed(" ww");
    try testing.expectEqual(app_mod.Screen.workspaces, app.screen);
    _ = try only(try drain(a, &app), "workspace.list");
    try respond(&app, a, .workspaces, workspace_list);
    var screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "WORKSPACES"));
    try testing.expect(has(screen, "venom-org"));
    try testing.expect(has(screen, "3 repos"));
    try testing.expect(has(screen, "plain folder"));
    try testing.expect(has(screen, "venom-docs"));
    try testing.expect(has(screen, "│  NORMAL"));
    // The repo facts: Branch (with clean or dirty), Worktrees and Issue; a
    // repo the daemon said nothing about shows `-`.
    try testing.expect(has(screen, "Branch"));
    try testing.expect(has(screen, "Worktrees"));
    try testing.expect(has(screen, "main · clean"));
    try testing.expect(has(screen, "246-hello-caps · dirty"));
    try testing.expect(has(screen, "#246"));
    try testing.expectEqual(@as(?u64, 2), app.panel.items[0].repos[0].worktrees);
    try testing.expect(app.panel.items[0].repos[2].branch == null);

    // A paste is not a command: no rescan, no box, no quit, no dialog.
    _ = try app.feed("\x1b[200~R+nNq w\r\x1b[201~");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(!app.panel.adding and !app.quit and app.dialog == null);
    try testing.expectEqual(app_mod.Screen.workspaces, app.screen);

    // R rescans the workspace under the cursor, then refetches the list.
    _ = try app.feed("jR");
    var p = try only(try drain(a, &app), "workspace.scan");
    try testing.expectEqualStrings("/home/me/scratch", p.get("path").?.string);
    try respond(&app, a, .workspace_scan,
        \\{"workspaces":[{"path":"/home/me/scratch","repos":[],"changed":false,"missing":false}]}
    );
    try testing.expect(has(app.message.items, "scratch: 0 repos, no change"));
    _ = try only(try drain(a, &app), "workspace.list");
    try respond(&app, a, .workspaces, workspace_list);
    try testing.expectEqualStrings("/home/me/scratch", app.panel.current().?.path);

    // +: a pasted line break is text in the box, it does not add.
    _ = try app.feed("+");
    try testing.expect(app.panel.adding);
    _ = try app.feed("\x1b[200~~/new\r\x1b[201~");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(app.panel.adding);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "Add a folder"));
    // Enter adds it: `~` expanded, the paste's trailing space gone.
    _ = try app.feed("\r");
    p = try only(try drain(a, &app), "workspace.add");
    try testing.expectEqualStrings("/home/me/new", p.get("path").?.string);
    try testing.expect(!app.panel.adding);
    // Refused: the box comes back with what was typed.
    try failWith(&app, .workspace_add, "not_found.workspace_path", "the folder does not exist");
    try testing.expect(app.panel.adding);
    try testing.expectEqualStrings("~/new ", app.panel.path_input.value());
    try testing.expect(has(app.message.items, "not_found.workspace_path"));
    _ = try app.feed("\r");
    _ = try drain(a, &app);
    try respond(&app, a, .workspace_add,
        \\{"path":"/home/me/new","added":true,"repos":[{"name":".","path":"/home/me/new"}]}
    );
    try testing.expect(has(app.message.items, "added new: 1 repo"));
    _ = try only(try drain(a, &app), "workspace.list");
    // The cursor goes to the folder just added.
    try respond(&app, a, .workspaces,
        \\{"workspaces":[{"path":"/home/me/scratch","repos":[]},{"path":"/home/me/new","repos":[{"name":".","path":"/home/me/new"}]}]}
    );
    try testing.expectEqualStrings("/home/me/new", app.panel.current().?.path);
    // A repo named ".": the folder's own name is what is shown.
    try testing.expectEqualStrings("new", app.panel.current().?.repos[0].label());

    // esc goes back, and `w` is not text there.
    _ = try app.feed("\x1b");
    try testing.expectEqual(app_mod.Screen.main, app.screen);
}

test "dialog: the options are the request; repos are never sent empty" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try drain(a, &app);

    // `n` on the list: new agent here (a1's workspace is not in this list,
    // so the first one). Nothing is previewed until the list is in.
    _ = try app.feed("n");
    try testing.expect(app.dialog != null);
    try testing.expectEqual(new_agent.Field.task, app.dialog.?.field);
    const reqs = try drain(a, &app);
    _ = try only(reqs, "workspace.list");
    _ = try only(reqs, "harness.list");
    try respond(&app, a, .harnesses,
        \\{"harnesses":[{"harness":"claude-code","enabled":true,"found":true},{"harness":"codex","enabled":true,"found":true},{"harness":"off","enabled":false,"found":false}]}
    );
    try respond(&app, a, .workspaces, workspace_list);
    try testing.expectEqualStrings("/home/me/venom-org", app.dialog.?.workspace.items);
    // The whole workspace, and the folder's defaults: all left out.
    var p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("dry_run").?.bool);
    try testing.expectEqualStrings("/home/me/venom-org", p.get("workspace").?.string);
    for ([_][]const u8{ "repos", "isolation", "harness", "issue", "branch" }) |name| try testing.expect(p.get(name) == null);
    try respond(&app, a, .preview, dry_run_ok);

    // The harness.list keeps only enabled harnesses.
    try testing.expectEqual(@as(usize, 2), app.panel.harnesses.len);
    var screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "New agent"));
    try testing.expect(has(screen, "in venom-org"));
    try testing.expect(has(screen, "Will create"));
    try testing.expect(has(screen, "+ ~/venom-org/venom-docs-246/   branch 246-hello-caps"));
    try testing.expect(has(screen, "+ ~/venom-org/venom-std-246/    branch 246-hello-caps (existing)"));
    try testing.expect(has(screen, "◉ claude-code"));
    try testing.expect(has(screen, "◉ Worktree per repo"));
    try testing.expect(has(screen, "│  INPUT"));

    // Typing in the task does not ask again; it is text, q and all.
    _ = try app.feed("quit q\\ n");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expectEqualStrings("quit q\\ n", app.dialog.?.task.value());
    try testing.expect(!app.quit and app.menu == null);

    // Tab goes through the fields in order, with no Repos while whole.
    const d = &app.dialog.?;
    const order = [_]new_agent.Field{ .workspace, .scope, .isolation, .harness, .mode, .model, .issue, .branch, .task };
    for (order) |f| {
        _ = try app.feed("\t");
        try testing.expectEqual(f, d.field);
    }
    _ = try app.feed("\x1b[Z");
    try testing.expectEqual(new_agent.Field.branch, d.field);

    // Scope: pick repos. None picked: no dry run, and it cannot start (an
    // empty `repos` would mean the whole workspace).
    d.field = .scope;
    _ = try app.feed("l");
    try testing.expectEqual(new_agent.Scope.pick, d.scope);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "Pick at least one repo"));
    _ = try app.feed("\r");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expectEqual(new_agent.Field.repos, d.field);
    try testing.expect(has(d.failure.items, "pick at least one repo"));

    // Picked out of order, sent in the workspace's.
    _ = try app.feed("l ");
    _ = try drain(a, &app);
    try respond(&app, a, .preview, dry_run_ok);
    _ = try app.feed("h ");
    p = try only(try drain(a, &app), "agent.spawn");
    const repos = p.get("repos").?.array.items;
    try testing.expectEqual(@as(usize, 2), repos.len);
    try testing.expectEqualStrings("venom-docs", repos[0].string);
    try testing.expectEqualStrings("venom-std", repos[1].string);
    // Asked while one is in flight: only the last options' answer shows.
    _ = try app.feed("l");
    _ = try app.feed(" ");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try respond(&app, a, .preview, dry_run_ok);
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqual(@as(usize, 1), p.get("repos").?.array.items.len);
    try testing.expectEqualStrings("venom-docs", p.get("repos").?.array.items[0].string);
    try failWith(&app, .preview, "conflict.worktree_exists", "the worktree folder already exists");
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "conflict.worktree_exists: the worktree folder already exists"));

    // Scope: one repo: the cursor is the choice.
    d.field = .scope;
    _ = try app.feed("l");
    try testing.expectEqual(new_agent.Scope.one, d.scope);
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqualStrings("venom-std", p.get("repos").?.array.items[0].string);
    try respond(&app, a, .preview, dry_run_ok);
    d.field = .repos;
    _ = try app.feed("l");
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqualStrings("venomx", p.get("repos").?.array.items[0].string);
    try respond(&app, a, .preview, dry_run_ok);

    // Isolation, harness, issue and branch reach the request.
    d.field = .isolation;
    _ = try app.feed("l");
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqualStrings("in_place", p.get("isolation").?.string);
    try respond(&app, a, .preview, dry_run_ok);
    d.field = .harness;
    _ = try app.feed("l");
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqualStrings("codex", p.get("harness").?.string);
    try respond(&app, a, .preview, dry_run_ok);
    d.field = .issue;
    _ = try app.feed("C");
    _ = try drain(a, &app);
    try respond(&app, a, .preview, dry_run_ok);

    // A paste on an option field does nothing; in a text field it is text.
    d.field = .harness;
    _ = try app.feed("\x1b[200~lh\r\t\x1b[201~");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(d.starting == null);
    try testing.expectEqualStrings("codex", d.harness.items);
    try testing.expectEqual(new_agent.Field.harness, d.field);
    d.field = .task;
    d.task.clear();
    _ = try app.feed("\x1b[200~one\rtwo\tthree\nfour\x1b[201~");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(d.starting == null);
    try testing.expectEqualStrings("one two three four", d.task.value());
    try testing.expectEqual(new_agent.Field.task, d.field);

    // A plain folder: nothing to scope.
    d.field = .workspace;
    _ = try app.feed("l");
    try testing.expectEqualStrings("/home/me/scratch", d.workspace.items);
    try testing.expectEqual(new_agent.Scope.whole, d.scope);
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("repos") == null);
    // in_place was chosen above; a plain folder sends and shows no choice.
    try testing.expect(p.get("isolation") == null);
    try respond(&app, a, .preview,
        \\{"agent":"a9","state":"queued","harness":"codex","title":"x","workspace":"/home/me/scratch","repos":[],"cwd":"/home/me/scratch","worktrees":[],"isolation":"in_place","checkouts":[],"dry_run":true}
    );
    d.field = .scope;
    _ = try app.feed("l");
    try testing.expectEqual(new_agent.Scope.whole, d.scope);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "nothing: the agent runs in place in ~/scratch"));
    try testing.expect(has(screen, "A plain folder"));
    // Whatever was chosen elsewhere, its isolation chip says in place, and
    // cannot be moved.
    d.isolation = .copy;
    d.field = .isolation;
    _ = try app.feed("l");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "◉ In place"));
    try testing.expect(has(screen, "○ Sandbox copy"));
    try testing.expect(!has(screen, "--isolation"));

    // esc leaves; a late answer for it is dropped.
    _ = try app.feed("\x1b");
    try testing.expect(app.dialog == null);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
}

test "dialog: mode and model are sent, shown in the command, and ctrl-c returns a choice to the default" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .workspaces, workspace_list);
    var p = try only(try drain(a, &app), "agent.spawn");
    // Nothing chosen: both left out, and the chip shows the daemon's mode.
    try testing.expect(p.get("mode") == null and p.get("model") == null);
    try respond(&app, a, .preview, dry_run_ok);
    const d = &app.dialog.?;
    var screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "◉ Accept edits"));
    try testing.expect(!has(screen, "--mode="));

    d.field = .mode;
    _ = try app.feed("l");
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqualStrings("plan", p.get("mode").?.string);
    try respond(&app, a, .preview, dry_run_ok);
    d.field = .model;
    _ = try app.feed(" opus ");
    // The first keystroke asked; the rest wait for its answer, then one more.
    _ = try only(try drain(a, &app), "agent.spawn");
    try respond(&app, a, .preview, dry_run_ok);
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expectEqualStrings("opus", p.get("model").?.string);
    try testing.expect(p.get("dry_run").?.bool);
    try respond(&app, a, .preview, dry_run_ok);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "--mode=plan --model=opus"));

    // Starting sends the same two, without dry_run.
    d.field = .task;
    _ = try app.feed("do it\r");
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("dry_run") == null);
    try testing.expectEqualStrings("plan", p.get("mode").?.string);
    try testing.expectEqualStrings("opus", p.get("model").?.string);
}

test "dialog: a failed start keeps the text; the connection going is said" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    const d = &app.dialog.?;

    // No task yet: refused here.
    _ = try app.feed("\r");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(has(d.failure.items, "write a task first"));

    _ = try app.feed("do it");
    _ = try app.feed("\r");
    var p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("dry_run") == null);
    try testing.expectEqualStrings("do it", p.get("task").?.string);
    try testing.expect(d.starting == .show);
    // While it is on its way, keys wait, and nothing is sent twice.
    _ = try app.feed("\r\x1bzz");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(app.dialog != null);
    try testing.expectEqualStrings("do it", d.task.value());

    try failWith(&app, .spawn, "conflict.worktree_exists", "the worktree folder already exists");
    try testing.expect(d.starting == null);
    try testing.expect(has(d.failure.items, "conflict.worktree_exists"));
    try testing.expectEqualStrings("do it", d.task.value());

    _ = try app.feed(shift_enter);
    _ = try drain(a, &app);
    try app.onDisconnected();
    try testing.expect(d.starting == null);
    try testing.expect(has(d.failure.items, "the daemon went away"));
    try testing.expect(app.dialog != null);
    // Back: the dialog asks again.
    try app.onConnected();
    _ = try only(try drain(a, &app), "workspace.list");
}

test "dialog: preview and spawn errors show the fix on its own row" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    const d = &app.dialog.?;

    const code = "unavailable.harness_not_signed_in";
    const message = "the harness is not signed in; run its sign-in command";
    const fix = "/tmp/venom-fixtures/bin/codex login";
    const cases = [_]struct { data: ?[]const u8, fix: bool }{
        .{ .data = "{\"fix\":\"/tmp/venom-fixtures/bin/codex login\"}", .fix = true },
        .{ .data = null, .fix = false },
        .{ .data = "null", .fix = false },
        .{ .data = "42", .fix = false },
        .{ .data = "{}", .fix = false },
        .{ .data = "{\"fix\":42}", .fix = false },
    };
    for ([_]u16{ 80, 120 }) |width| {
        var surface = try term.Surface.init(ta, width, 30);
        var discard: std.Io.Writer.Discarding = .init(&.{});
        defer surface.deinit(&discard.writer);
        for (cases) |case| {
            const body: @import("proto").Response.Body = .{ .@"error" = .{
                .code = code,
                .message = message,
                .data = if (case.data) |json| try std.json.parseFromSliceLeaky(Value, a, json, .{}) else null,
            } };
            d.preview_id = 123;
            d.preview_again = false;
            d.failure.clearRetainingCapacity();
            try new_agent.onPreview(&app, 123, body);
            try testing.expectEqualStrings(message, d.shown.failed.message);
            try testing.expectEqual(case.fix, has(try render(&app, &surface, a), "run: " ++ fix));

            d.shown = .{ .note = "" };
            d.starting = .show;
            try new_agent.onSpawned(&app, .show, body);
            try testing.expect(d.starting == null);
            try testing.expectEqual(case.fix, std.mem.indexOfScalar(u8, d.failure.items, '\n') != null);
            try testing.expectEqual(case.fix, has(try render(&app, &surface, a), "run: " ++ fix));
        }
    }
}

test "dialog: the preview's fix outlives the response it came in" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    const d = &app.dialog.?;

    // Outside $HOME, so shortPath hands the path back as it is. The host
    // frees the response right after onPreview, as here.
    const fix = "/usr/bin/codex login";
    var data = try std.json.parseFromSlice(Value, ta, "{\"fix\":\"" ++ fix ++ "\"}", .{});
    const body: @import("proto").Response.Body = .{ .@"error" = .{
        .code = "unavailable.harness_not_signed_in",
        .message = "the harness is not signed in; run its sign-in command",
        .data = data.value,
    } };
    d.preview_id = 7;
    d.preview_again = false;
    try new_agent.onPreview(&app, 7, body);
    data.deinit();

    var surface = try term.Surface.init(ta, 80, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try testing.expectEqualStrings(fix, d.shown.failed.fix);
    try testing.expect(has(try render(&app, &surface, a), "run: " ++ fix));
}

test "dialog: a dry run that no longer applies cannot replace what is on show" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    const d = &app.dialog.?;

    // Pick repos with none picked, while the dry run is on its way.
    d.field = .scope;
    _ = try app.feed("l");
    try testing.expectEqual(new_agent.Scope.pick, d.scope);
    try testing.expectEqual(new_agent.Shown.note, std.meta.activeTag(d.shown));
    try respond(&app, a, .preview, dry_run_ok);
    try testing.expectEqual(new_agent.Shown.note, std.meta.activeTag(d.shown));
    try testing.expect(has(d.shown.note, "Pick at least one repo"));

    // And a new dry run does not wait for an abandoned one.
    d.field = .repos;
    _ = try app.feed(" ");
    _ = try only(try drain(a, &app), "agent.spawn");
    // Unpicking it, with that one on its way: its late answer is dropped too.
    _ = try app.feed(" ");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try respond(&app, a, .preview, dry_run_ok);
    try testing.expectEqual(new_agent.Shown.note, std.meta.activeTag(d.shown));
}

test "dialog: another client's agent.created refreshes the preview; rows that do not fit are counted" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 100, 19);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    try respond(&app, a, .preview, dry_run_ok);

    try t.feedJson(&app, a,
        \\{"seq":50,"ts":"2026-11-06T14:31:00.000Z","source":"venom/0e1","type":"agent.created","data":{"agent":"a77","title":"elsewhere","harness":"fake","workspace":"/w","repos":[],"state":"queued"}}
    );
    var saw = false;
    for (try drain(a, &app)) |r| {
        if (!std.mem.eql(u8, verbOf(r), "agent.spawn")) continue;
        saw = true;
        try testing.expect(r.object.get("params").?.object.get("dry_run").?.bool);
    }
    try testing.expect(saw);

    // A short screen: 17 rows hold the fields, a sentence and "Will create",
    // the command and the keys, but not all 8 checkouts.
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(a, "{\"harness\":\"fake\",\"isolation\":\"worktree\",\"cwd\":\"/w\",\"checkouts\":[");
    for (0..8) |i| try many.print(a, "{s}{{\"path\":\"/w/r{d}-a1\",\"branch\":\"venom/a1\",\"new_branch\":true}}", .{ if (i > 0) "," else "", i });
    try many.appendSlice(a, "]}");
    try respond(&app, a, .preview, many.items);
    var screen = try render(&app, &surface, a);
    if (!has(screen, " more")) std.debug.print("{s}\n", .{screen});
    try testing.expect(has(screen, "+ /w/r0-a1/"));
    try testing.expect(has(screen, "more"));
    try testing.expect(!has(screen, "+ /w/r7-a1/"));
    // A failure always gets its row, and the keys theirs.
    _ = try app.feed("\r");
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "write a task first"));
    try testing.expect(has(screen, "esc Cancel"));
}

fn gitOk(a: std.mem.Allocator, repo: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com" });
    try argv.appendSlice(a, args);
    const r = try std.process.run(a, testing.io, .{ .argv = argv.items });
    if (!r.term.success()) {
        std.debug.print("git {s}: {s}\n", .{ args[0], r.stderr });
        return error.GitFailed;
    }
}

fn hasGit(a: std.mem.Allocator) bool {
    const r = std.process.run(a, testing.io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    return r.term.success();
}

const Live = struct {
    tmp: testing.TmpDir,
    d: t.Daemon,
    work: []const u8,
    app: App,
    link: Link,
    surface: term.Surface,

    fn init(self: *Live, a: std.mem.Allocator) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
        const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
        if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
        self.work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
        for ([_][]const u8{ "a", "b", "c" }) |name| {
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.work, name });
            try std.Io.Dir.cwd().createDirPath(testing.io, path);
            try gitOk(a, path, &.{ "init", "-q", "-b", "main" });
            try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/README", .{path}), .data = name });
            try gitOk(a, path, &.{ "add", "README" });
            try gitOk(a, path, &.{ "commit", "-q", "-m", "init" });
        }
        self.d = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}) };
        try self.d.start();
        _ = try self.d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}", .{self.work}) });
        self.app = App.init(ta);
        self.app.extra_harnesses = &.{"fake"};
        // Short paths, so the screen has them whole.
        self.app.home = dir;
        self.link = .{ .gpa = ta, .path = .{ .socket = self.d.socket } };
        self.surface = try term.Surface.init(ta, 130, 34);
        try t.until(&self.app, &self.link, &self.surface, &self.d, "connect", t.Connected{});
    }

    fn deinit(self: *Live) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.link.deinit();
        self.app.deinit();
        self.d.halt();
        self.d.deinit();
        self.tmp.cleanup();
    }

    fn until(self: *Live, comptime what: []const u8, pred: anytype) !void {
        try t.until(&self.app, &self.link, &self.surface, &self.d, what, pred);
    }

    /// Opens the dialog in the workspace, on the fake harness.
    fn openDialog(self: *Live) !*new_agent.Dialog {
        _ = try self.app.feed("n");
        try self.until("the dialog's workspace", HasWorkspace{});
        try self.until("the first preview", Settled{});
        const d = &self.app.dialog.?;
        try testing.expectEqual(new_agent.Shown.failed, std.meta.activeTag(d.shown));
        d.field = .harness;
        _ = try self.app.feed("l");
        try testing.expectEqualStrings("fake", d.harness.items);
        try self.until("the fake's preview", Settled{});
        d.field = .task;
        return d;
    }
};

const HasWorkspace = struct {
    pub fn check(_: HasWorkspace, app: *App, _: *term.Surface) !bool {
        return app.dialog != null and app.dialog.?.workspace.items.len > 0;
    }
};

/// No dry run is on its way: what the dialog shows is for its options.
const Settled = struct {
    pub fn check(_: Settled, app: *App, _: *term.Surface) !bool {
        const d = &(app.dialog orelse return false);
        return d.preview_id == null and !d.preview_again;
    }
};

const MenuOpen = struct {
    pub fn check(_: MenuOpen, app: *App, _: *term.Surface) !bool {
        return app.menu != null;
    }
};

const Selected = struct {
    id: []const u8,
    pub fn check(self: Selected, app: *App, _: *term.Surface) !bool {
        return std.mem.eql(u8, app.selected.items, self.id) and app.dialog == null;
    }
};

const InModel = struct {
    id: []const u8,
    pub fn check(self: InModel, app: *App, _: *term.Surface) !bool {
        return app.dialog == null and app.model.find(self.id) != null;
    }
};

/// The dialog's preview against `venom agent spawn <its args> --dry-run`.
fn expectPreviewMatches(l: *Live, a: std.mem.Allocator, extra: []const []const u8) !void {
    const app = &l.app;
    const d = &app.dialog.?;
    try l.until("the preview", Settled{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, extra);
    try argv.appendSlice(a, &.{ "--task=work on it", "--dry-run=true" });
    const cli = try l.d.run(a, argv.items);
    try testing.expect(cli.object.get("dry_run").?.bool);
    if (d.shown != .plan) std.debug.print("preview: {any}\n", .{d.shown});
    const got = d.shown.plan;
    const want = try new_agent.Plan.parse(a, cli);
    try testing.expectEqualStrings(want.isolation, got.isolation);
    try testing.expectEqualStrings(want.harness, got.harness);
    try testing.expectEqualStrings(want.permission_mode, got.permission_mode);
    try testing.expect(want.permission_mode.len > 0);
    try testing.expectEqualStrings(want.cwd, got.cwd);
    try testing.expectEqual(want.checkouts.len, got.checkouts.len);
    for (want.checkouts, got.checkouts) |x, y| {
        try testing.expectEqualStrings(x.path, y.path);
        try testing.expect(x.new_branch == y.new_branch);
        if (x.branch) |b| try testing.expectEqualStrings(b, y.branch.?) else try testing.expect(y.branch == null);
    }
    // And on the screen, line for line.
    const screen = try t.dump(a, &l.surface);
    for (try want.lines(a, l.app.home)) |line| {
        if (!has(screen, line)) std.debug.print("missing {s} from:\n{s}\n", .{ line, screen });
        try testing.expect(has(screen, line));
    }
    // The command the dialog shows is that same dry run.
    const own = try d.args(a, app.panel.find(d.workspace.items));
    var own_argv: std.ArrayList([]const u8) = .empty;
    try own_argv.appendSlice(a, own);
    try own_argv.appendSlice(a, &.{ "--task=work on it", "--dry-run=true" });
    const again = try new_agent.Plan.parse(a, try l.d.run(a, own_argv.items));
    try testing.expectEqual(want.checkouts.len, again.checkouts.len);
    for (want.checkouts, again.checkouts) |x, y| try testing.expectEqualStrings(x.path, y.path);
}

test "live: the preview matches agent spawn --dry-run for the chosen options" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var l: Live = undefined;
    try l.init(a);
    defer l.deinit();
    const d = try l.openDialog();
    const ws = try std.fmt.allocPrint(a, "--workspace={s}", .{l.work});
    const base = [_][]const u8{ "agent", "spawn", ws, "--harness=fake" };

    // The whole workspace: a worktree per repo, on venom/<next agent>.
    try expectPreviewMatches(&l, a, &base);
    try testing.expectEqual(@as(usize, 3), d.shown.plan.checkouts.len);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/a-a1", .{l.work}), d.shown.plan.checkouts[0].path);
    try testing.expectEqualStrings("venom/a1", d.shown.plan.checkouts[0].branch.?);

    // Pick repos a and c.
    d.field = .scope;
    _ = try l.app.feed("l");
    d.field = .repos;
    _ = try l.app.feed(" ll ");
    try expectPreviewMatches(&l, a, &(base ++ .{"--repos=[\"a\",\"c\"]"}));
    try testing.expectEqual(@as(usize, 2), d.shown.plan.checkouts.len);

    // One repo: b.
    d.field = .scope;
    _ = try l.app.feed("l");
    d.field = .repos;
    _ = try l.app.feed("h");
    try testing.expectEqual(new_agent.Scope.one, d.scope);
    try expectPreviewMatches(&l, a, &(base ++ .{"--repos=[\"b\"]"}));
    try testing.expectEqual(@as(usize, 1), d.shown.plan.checkouts.len);

    // An issue and its branch name the worktree.
    d.field = .issue;
    _ = try l.app.feed("246");
    d.field = .branch;
    _ = try l.app.feed("246-hello-caps");
    try expectPreviewMatches(&l, a, &(base ++ [_][]const u8{ "--repos=[\"b\"]", "--issue=246", "--branch=246-hello-caps" }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/b-246", .{l.work}), d.shown.plan.checkouts[0].path);
    try testing.expectEqualStrings("246-hello-caps", d.shown.plan.checkouts[0].branch.?);

    // Copy, then in place, with the same issue.
    d.field = .isolation;
    _ = try l.app.feed("h");
    try expectPreviewMatches(&l, a, &(base ++ [_][]const u8{ "--repos=[\"b\"]", "--issue=246", "--branch=246-hello-caps", "--isolation=copy" }));
    try testing.expectEqual(@as(?[]const u8, null), d.shown.plan.checkouts[0].branch);
    _ = try l.app.feed("h");
    try expectPreviewMatches(&l, a, &(base ++ [_][]const u8{ "--repos=[\"b\"]", "--issue=246", "--branch=246-hello-caps", "--isolation=in_place" }));
    try testing.expectEqual(@as(usize, 0), d.shown.plan.checkouts.len);

    // Mode and model: sent, shown in the command, and the same dry run. The
    // chip shows the daemon's default until one is chosen; ⌃c goes back to it.
    const picked = [_][]const u8{ "--repos=[\"b\"]", "--issue=246", "--branch=246-hello-caps", "--isolation=in_place" };
    d.field = .mode;
    try expectPreviewMatches(&l, a, &(base ++ picked));
    try testing.expectEqual(@as(?new_agent.Mode, null), d.mode);
    try testing.expectEqualStrings("ask", d.shown.plan.permission_mode);
    _ = try l.app.feed("l");
    try testing.expectEqual(@as(?new_agent.Mode, .accept_edits), d.mode);
    try expectPreviewMatches(&l, a, &(base ++ picked ++ [_][]const u8{"--mode=accept_edits"}));
    try testing.expectEqualStrings("accept_edits", d.shown.plan.permission_mode);
    _ = try l.app.feed("l");
    try expectPreviewMatches(&l, a, &(base ++ picked ++ [_][]const u8{"--mode=plan"}));
    try testing.expectEqualStrings("plan", d.shown.plan.permission_mode);
    d.field = .model;
    _ = try l.app.feed("opus");
    try expectPreviewMatches(&l, a, &(base ++ picked ++ [_][]const u8{ "--mode=plan", "--model=opus" }));
    try testing.expect(has(try new_agent.commandLine(a, d, l.app.panel.find(d.workspace.items)), "--model=opus"));
    _ = try l.app.feed("\x03");
    d.field = .mode;
    _ = try l.app.feed("\x03");
    try testing.expectEqual(@as(?new_agent.Mode, null), d.mode);
    try expectPreviewMatches(&l, a, &(base ++ picked));
    try testing.expectEqualStrings("ask", d.shown.plan.permission_mode);

    // Where it starts is the plan's: one checkout moves it there.
    d.field = .isolation;
    _ = try l.app.feed("ll");
    try l.until("the worktree preview", Settled{});
    try l.until("the real start", t.Shows{ .text = "The agent starts at ~/work/b-246 and" });

    // A preview changes nothing on disk, in git or in the agent list.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, try std.fmt.allocPrint(a, "{s}/a-a1", .{l.work}), .{}));
    const listed = try l.d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(usize, 0), listed.object.get("agents").?.array.items.len);

    // The daemon's refusal is the preview: a bad issue id.
    d.field = .issue;
    _ = try l.app.feed("!");
    try l.until("the refused preview", Settled{});
    try testing.expectEqual(new_agent.Shown.failed, std.meta.activeTag(d.shown));
    try testing.expectEqualStrings("invalid_params.issue", d.shown.failed.code);
}

test "live: a branch git would refuse fails the dry run as it fails the spawn" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var l: Live = undefined;
    try l.init(a);
    defer l.deinit();
    const d = try l.openDialog();
    try gitOk(a, try std.fmt.allocPrint(a, "{s}/a", .{l.work}), &.{ "branch", "foo" });
    try gitOk(a, try std.fmt.allocPrint(a, "{s}/a", .{l.work}), &.{ "branch", "dir/sub" });
    const cases = [_]struct { branch: []const u8, code: []const u8 }{
        .{ .branch = "HEAD", .code = "invalid_params.branch" },
        .{ .branch = "@", .code = "invalid_params.branch" },
        .{ .branch = "refs/heads/z", .code = "invalid_params.branch" },
        .{ .branch = "foo/bar", .code = "unavailable.git" },
        .{ .branch = "dir", .code = "unavailable.git" },
    };
    for (cases) |case| {
        d.field = .branch;
        d.branch.clear();
        _ = try l.app.feed(case.branch);
        try l.until("the refused preview", Settled{});
        try testing.expectEqual(new_agent.Shown.failed, std.meta.activeTag(d.shown));
        try testing.expectEqualStrings(case.code, d.shown.failed.code);
    }
    // Nothing was left behind, and a branch beside them is fine.
    d.branch.clear();
    _ = try l.app.feed("foo2/bar");
    try l.until("the good preview", Settled{});
    try testing.expectEqual(new_agent.Shown.plan, std.meta.activeTag(d.shown));
}

test "live: an agent another client started moves the previewed id" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var l: Live = undefined;
    try l.init(a);
    defer l.deinit();
    _ = try l.openDialog();
    try l.until("a1's preview", t.Shows{ .text = "~/work/a-a1/" });
    _ = try l.d.run(a, &.{ "agent", "spawn", "--task=elsewhere", "--harness=fake", "--isolation=in_place", try std.fmt.allocPrint(a, "--workspace={s}", .{l.work}) });
    try l.until("a2's preview", t.Shows{ .text = "~/work/a-a2/" });
}

test "live: ⏎ shows the agent, ⇧⏎ leaves it in the list, ⌃⏎ opens its split menu" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var l: Live = undefined;
    try l.init(a);
    defer l.deinit();
    const app = &l.app;

    // ⏎: started, selected and shown in the main view, focus on it.
    var d = try l.openDialog();
    _ = try app.feed("first");
    _ = try app.feed("\r");
    try l.until("a1 in the main view", Selected{ .id = "a1" });
    try testing.expectEqual(app_mod.Area.transcript, app.area());
    try testing.expectEqual(app_mod.Screen.main, app.screen);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try l.until("a1 settled", t.InState{ .id = "a1", .state = .settled });
    try l.until("a1's transcript", t.Shows{ .text = "Done." });
    // Its worktrees were made, as previewed.
    _ = try std.Io.Dir.cwd().statFile(testing.io, try std.fmt.allocPrint(a, "{s}/a-a1/README", .{l.work}), .{});

    // ⇧⏎: started; no view, no change of selection; it is in the list.
    _ = try app.feed("\x1b"); // back to the list
    try testing.expectEqual(app_mod.Area.list, app.area());
    d = try l.openDialog();
    // "here": the selected agent's workspace.
    try testing.expectEqualStrings(l.work, d.workspace.items);
    _ = try app.feed("second");
    _ = try app.feed(shift_enter);
    try l.until("a2 in the list", InModel{ .id = "a2" });
    try l.until("a2 on the screen", t.Shows{ .text = "second" });
    try testing.expectEqualStrings("a1", app.selected.items);
    try testing.expectEqual(app_mod.Area.list, app.area());
    try testing.expect(app.menu == null);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try testing.expect(has(app.message.items, "a2 runs in the background"));
    try l.until("a2 settled", t.InState{ .id = "a2", .state = .settled });

    // ⌃⏎: started; the split menu opens for it, and the selection stays.
    d = try l.openDialog();
    _ = try app.feed("third");
    _ = try app.feed(ctrl_enter);
    try l.until("a3's split menu", MenuOpen{});
    try testing.expectEqualStrings("a3", app.menu.?.agent);
    try testing.expectEqualStrings("a1", app.selected.items);
    try l.until("a3's menu on screen", t.Shows{ .text = "Split · third" });
    // ⏎ takes the default: an agent view of a3 beside the main view.
    _ = try app.feed("\r");
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expectEqualStrings("a3", app.splits.items[0].agent);
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    try l.until("a3 settled", t.InState{ .id = "a3", .state = .settled });

    // Cancelling the menu leaves an agent running, in the list.
    _ = try app.feed(" vx"); // closes the split
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    _ = try app.feed("\x1b");
    d = try l.openDialog();
    _ = try app.feed("fourth");
    _ = try app.feed(ctrl_enter);
    try l.until("a4's split menu", MenuOpen{});
    _ = try app.feed("\x1b");
    try testing.expect(app.menu == null);
    try testing.expect(app.model.find("a4") != null);
    try testing.expectEqualStrings("a1", app.selected.items);

    // The panel sees the agents; `n` from it opens the dialog there.
    _ = try app.feed(" ww");
    try testing.expectEqual(app_mod.Screen.workspaces, app.screen);
    try l.until("the panel", t.Shows{ .text = "4 agents" });
}

test "panel: facts that are missing or the wrong type are shown as -, and branchText" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var panel = new_agent_workspaces.Panel.init(ta);
    defer panel.deinit(ta);
    const parsed = try std.json.parseFromSliceLeaky(Value, a,
        \\{"workspaces":[{"path":"/w","repos":[
        \\{"name":"none","path":"/w/none"},
        \\{"name":"bad","path":"/w/bad","branch":7,"dirty":"yes","worktrees":-1,"issue":3},
        \\{"name":"det","path":"/w/det","dirty":true,"worktrees":2},
        \\{"name":"ok","path":"/w/ok","branch":"main","dirty":false,"worktrees":0,"issue":null}]}]}
    , .{});
    try panel.apply(ta, parsed);
    const repos = panel.items[0].repos;
    for (repos[0..2]) |r| {
        try testing.expect(r.branch == null and r.dirty == null and r.worktrees == null and r.issue == null);
        try testing.expectEqualStrings("-", try r.branchText(a));
    }
    try testing.expectEqualStrings("detached · dirty", try repos[2].branchText(a));
    try testing.expectEqual(@as(?u64, 2), repos[2].worktrees);
    try testing.expectEqualStrings("main · clean", try repos[3].branchText(a));
    try testing.expectEqual(@as(?u64, 0), repos[3].worktrees);
    const only_branch: new_agent_workspaces.Repo = .{ .name = "x", .path = "/x", .branch = "main" };
    try testing.expectEqualStrings("main", try only_branch.branchText(a));
}

test "dialog: harness.list is asked again on reconnect while it is open; ctrl-c drops isolation and harness from the request" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try app.feed("n");
    _ = try drain(a, &app);
    try respond(&app, a, .harnesses,
        \\{"harnesses":[{"harness":"claude-code","enabled":true,"found":true},{"harness":"codex","enabled":true,"found":true}]}
    );
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    try respond(&app, a, .preview, dry_run_ok);

    // The link drops and comes back with the dialog open.
    try app.onDisconnected();
    try app.onConnected();
    const reqs = try drain(a, &app);
    _ = try only(reqs, "harness.list");
    _ = try only(reqs, "workspace.list");
    try respond(&app, a, .harnesses,
        \\{"harnesses":[{"harness":"claude-code","enabled":true,"found":true},{"harness":"codex","enabled":true,"found":true}]}
    );
    try respond(&app, a, .workspaces, workspace_list);
    _ = try drain(a, &app);
    try respond(&app, a, .preview, dry_run_ok);

    // Choose an isolation and a harness, then ⌃c each.
    const d = &app.dialog.?;
    d.field = .isolation;
    _ = try app.feed("l");
    try respond(&app, a, .preview, dry_run_ok);
    _ = try drain(a, &app);
    d.field = .harness;
    _ = try app.feed("l");
    var p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("isolation") != null and p.get("harness") != null);
    try respond(&app, a, .preview, dry_run_ok);
    _ = try app.feed("\x03");
    try testing.expect(d.harness.items.len == 0);
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("harness") == null and p.get("isolation") != null);
    try respond(&app, a, .preview, dry_run_ok);
    d.field = .isolation;
    _ = try app.feed("\x03");
    try testing.expect(d.isolation == null);
    p = try only(try drain(a, &app), "agent.spawn");
    try testing.expect(p.get("harness") == null and p.get("isolation") == null);
}
