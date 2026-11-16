//! The workspaces panel,
//! opened with `leader w w`:
//!
//! ```text
//! ╭ Workspaces ───────── 3 ╮╭ venom-org ──────────── R rescan ╮
//! │ ■ venom-org        ▲3  ││ Repo        Agents  Path        │
//! │   ~/venom-org · 8 rep… ││ venom-docs  ▲1 ●1   ~/venom-or… │
//! │ ■ scratch        idle  ││ venom-std   none    ~/venom-or… │
//! │ + add folder           ││                                 │
//! ╰────────────────────────╯╰─────────────────────────────────╯
//! ```
//!
//! A workspace is a folder path; its repos are found on add and on rescan,
//! never configured. Everything here is the daemon's `workspace.*` verbs: `+`
//! is `workspace.add`, `R` is `workspace.scan`, and the list is the last
//! `workspace.list`. `n` and `N` open the new-agent dialog (new_agent.zig),
//! which picks its workspace and repos from this same list.
//!
//! The list is fetched when the panel or the dialog opens and after a verb
//! here changes it; venom's events do not carry workspace changes yet.
//! Pasted text is never a command: outside the add-folder box a
//! paste does nothing.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const pane = @import("pane.zig");
const Surface = term.Surface;
const Region = term.Region;
const Value = std.json.Value;
const App = @import("app.zig").App;
const keys = @import("keys.zig");
const model = @import("model.zig");
const config = @import("../config.zig");
const providers_mod = @import("providers.zig");
const new_agent = @import("new_agent.zig");
const Body = @import("proto").Response.Body;

pub const Repo = struct {
    /// Relative to the workspace; "." when the workspace is itself a repo.
    name: []const u8,
    path: []const u8,
    /// From `workspace.list`; null: the daemon did not say.
    branch: ?[]const u8 = null,
    dirty: ?bool = null,
    worktrees: ?u64 = null,
    issue: ?[]const u8 = null,

    /// `main · clean`; `-` when git did not say.
    pub fn branchText(self: Repo, a: std.mem.Allocator) ![]const u8 {
        const b = self.branch orelse (if (self.dirty == null) return "-" else "detached");
        const state = if (self.dirty) |d| (if (d) "dirty" else "clean") else return b;
        return std.fmt.allocPrint(a, "{s} · {s}", .{ b, state });
    }

    /// What the user calls it: "." is the workspace's own folder.
    pub fn label(self: Repo) []const u8 {
        return if (std.mem.eql(u8, self.name, ".")) std.fs.path.basename(self.path) else self.name;
    }
};

pub const Workspace = struct {
    path: []const u8,
    repos: []const Repo = &.{},

    pub fn name(self: Workspace) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

/// The last `workspace.list` and `harness.list`, and the panel's cursor.
pub const Panel = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Workspace = &.{},
    loaded: bool = false,
    cursor: usize = 0,
    inflight: bool = false,
    again: bool = false,
    /// The add-folder box is open.
    adding: bool = false,
    path_input: w.TextInput,
    /// Where the cursor goes on the next list (the folder just added).
    goto: std.ArrayList(u8) = .empty,
    /// Enabled harnesses, from `harness.list`.
    harness_arena: std.heap.ArenaAllocator,
    harnesses: []const []const u8 = &.{},
    harness_inflight: bool = false,
    /// The providers, from `config.get`, for the new-agent dialog.
    provider_arena: std.heap.ArenaAllocator,
    providers: []const config.Provider = &.{},

    pub fn init(gpa: std.mem.Allocator) Panel {
        return .{
            .arena = .init(gpa),
            .harness_arena = .init(gpa),
            .provider_arena = .init(gpa),
            .path_input = .init(gpa, .{ .prompt = "› ", .placeholder = "Folder to add, like ~/venom-org; enter adds it" }),
        };
    }

    pub fn deinit(self: *Panel, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        self.harness_arena.deinit();
        self.provider_arena.deinit();
        self.path_input.deinit();
        self.goto.deinit(gpa);
        self.* = undefined;
    }

    /// Replaces the list with a `workspace.list` result.
    pub fn apply(self: *Panel, gpa: std.mem.Allocator, ok: Value) !void {
        var next = std.heap.ArenaAllocator.init(gpa);
        errdefer next.deinit();
        const a = next.allocator();
        var out: std.ArrayList(Workspace) = .empty;
        for (array(ok, "workspaces")) |v| {
            const path = text(v, "path") orelse continue;
            var repos: std.ArrayList(Repo) = .empty;
            for (array(v, "repos")) |r| {
                const n = text(r, "name") orelse continue;
                const p = text(r, "path") orelse continue;
                const dirty = if (r == .object) r.object.get("dirty") else null;
                const wt = if (r == .object) r.object.get("worktrees") else null;
                const br = text(r, "branch");
                const is = text(r, "issue");
                try repos.append(a, .{
                    .name = try a.dupe(u8, n),
                    .path = try a.dupe(u8, p),
                    .branch = if (br) |x| try a.dupe(u8, x) else null,
                    .dirty = if (dirty != null and dirty.? == .bool) dirty.?.bool else null,
                    .worktrees = if (wt != null and wt.? == .integer and wt.?.integer >= 0) @intCast(wt.?.integer) else null,
                    .issue = if (is) |x| try a.dupe(u8, x) else null,
                });
            }
            try out.append(a, .{ .path = try a.dupe(u8, path), .repos = repos.items });
        }
        const items = out.items;
        // The cursor stays on its workspace when the list moves under it.
        const was = if (self.current()) |c| try a.dupe(u8, c.path) else "";
        self.arena.deinit();
        self.arena = next;
        self.items = items;
        self.loaded = true;
        const want = if (self.goto.items.len > 0) self.goto.items else was;
        for (items, 0..) |x, i| if (std.mem.eql(u8, x.path, want)) {
            self.cursor = i;
        };
        self.goto.clearRetainingCapacity();
        self.cursor = @min(self.cursor, items.len -| 1);
    }

    /// Keeps the enabled harnesses of a `harness.list` result.
    pub fn applyHarnesses(self: *Panel, gpa: std.mem.Allocator, ok: Value) !void {
        var next = std.heap.ArenaAllocator.init(gpa);
        errdefer next.deinit();
        const a = next.allocator();
        var out: std.ArrayList([]const u8) = .empty;
        for (array(ok, "harnesses")) |v| {
            const on = if (v == .object) v.object.get("enabled") else null;
            if (on == null or on.? != .bool or !on.?.bool) continue;
            try out.append(a, try a.dupe(u8, text(v, "harness") orelse continue));
        }
        const names = out.items;
        self.harness_arena.deinit();
        self.harness_arena = next;
        self.harnesses = names;
    }

    /// Keeps the providers of a `config.get` result (key `providers`).
    pub fn applyProviders(self: *Panel, gpa: std.mem.Allocator, ok: Value) !void {
        var next = std.heap.ArenaAllocator.init(gpa);
        errdefer next.deinit();
        const content = text(ok, "content") orelse return;
        const list = providers_mod.parse(next.allocator(), content);
        self.provider_arena.deinit();
        self.provider_arena = next;
        self.providers = list;
    }

    pub fn find(self: *const Panel, path: []const u8) ?*const Workspace {
        for (self.items) |*x| if (std.mem.eql(u8, x.path, path)) return x;
        return null;
    }

    pub fn current(self: *const Panel) ?*const Workspace {
        return if (self.cursor < self.items.len) &self.items[self.cursor] else null;
    }
};

fn array(v: Value, name: []const u8) []const Value {
    if (v != .object) return &.{};
    const x = v.object.get(name) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn text(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(name) orelse return null;
    return if (x == .string) x.string else null;
}

// ---- Requests --------------------------------------------------------------

/// Refetches the list; one request at a time, coalesced.
pub fn requestList(app: *App) !void {
    if (!app.connected) return;
    const p = &app.panel;
    if (p.inflight) {
        p.again = true;
        return;
    }
    p.inflight = true;
    try app.request(.workspaces, "workspace.list", struct {}{});
}

/// `harness.list` answers when discovery has run: nothing waits for it.
pub fn requestHarnesses(app: *App) !void {
    if (!app.connected or app.panel.harness_inflight) return;
    app.panel.harness_inflight = true;
    try app.request(.harnesses, "harness.list", struct {}{});
    try app.request(.providers, "config.get", .{ .key = "providers" });
}

pub fn onProviders(app: *App, body: Body) !void {
    if (body == .ok) try app.panel.applyProviders(app.gpa, body.ok);
}

pub fn open(app: *App) !void {
    app.screen = .workspaces;
    app.message.clearRetainingCapacity();
    try requestList(app);
}

pub fn onList(app: *App, body: Body) !void {
    const p = &app.panel;
    p.inflight = false;
    if (body == .ok) {
        try p.apply(app.gpa, body.ok);
        try new_agent.onWorkspaces(app);
    } else if (body == .@"error") app.say("workspace list: {s}", .{body.@"error".code});
    if (p.again) {
        p.again = false;
        try requestList(app);
    }
}

pub fn onHarnesses(app: *App, body: Body) !void {
    app.panel.harness_inflight = false;
    if (body == .ok) try app.panel.applyHarnesses(app.gpa, body.ok);
}

pub fn onAdded(app: *App, body: Body) !void {
    const p = &app.panel;
    if (body == .@"error") {
        // The box comes back with what was typed.
        p.adding = true;
        return app.say("workspace add: {s}: {s}", .{ body.@"error".code, body.@"error".message });
    }
    if (body != .ok) return;
    p.path_input.clear();
    const path = text(body.ok, "path") orelse "";
    p.goto.clearRetainingCapacity();
    try p.goto.appendSlice(app.gpa, path);
    const n = array(body.ok, "repos").len;
    const added = if (body.ok == .object) if (body.ok.object.get("added")) |v| v == .bool and v.bool else true else true;
    app.say("{s} {s}: {d} repo{s}", .{ if (added) "added" else "already added", std.fs.path.basename(path), n, if (n == 1) "" else "s" });
    try requestList(app);
}

pub fn onScanned(app: *App, body: Body) !void {
    if (body == .@"error") return app.say("workspace scan: {s}", .{body.@"error".code});
    if (body != .ok) return;
    for (array(body.ok, "workspaces")) |v| {
        const path = text(v, "path") orelse continue;
        const name = std.fs.path.basename(path);
        const n = array(v, "repos").len;
        const flag = struct {
            fn of(x: Value, f: []const u8) bool {
                const y = if (x == .object) x.object.get(f) else null;
                return y != null and y.? == .bool and y.?.bool;
            }
        }.of;
        if (flag(v, "missing")) {
            app.say("{s}: the folder is missing; its last repos are kept", .{name});
        } else app.say("{s}: {d} repo{s}{s}", .{ name, n, if (n == 1) "" else "s", if (flag(v, "changed")) ", changed" else ", no change" });
    }
    try requestList(app);
}

// ---- Keys ------------------------------------------------------------------

/// What was typed as an absolute path: `~` is `$HOME`, and a trailing `/`
/// goes, since the daemon takes normalized paths. Anything else is the
/// daemon's to refuse.
pub fn expandPath(a: std.mem.Allocator, typed: []const u8, home: []const u8) ![]const u8 {
    var p = std.mem.trim(u8, typed, " \t\r\n");
    if (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (home.len > 0 and (std.mem.eql(u8, p, "~") or std.mem.startsWith(u8, p, "~/"))) return std.fmt.allocPrint(a, "{s}{s}", .{ home, p[1..] });
    return p;
}

pub fn key(app: *App, k: term.Input.Key) !void {
    const kk = w.keys;
    const p = &app.panel;
    if (!kk.pressed(k)) return;
    if (p.adding) return addKey(app, k);
    // Reached from `App.pastedKey` too: outside the box a paste does nothing.
    if (app.pasting) return;
    if (keys.matchWorkspaces(k)) |action| switch (action) {
        .verb => |verb| if (std.mem.eql(u8, verb, "workspace.scan")) return rescan(app) else {
            p.adding = true;
            return;
        },
        else => return app.run(action, k),
    };
    if (p.items.len == 0) return;
    if (kk.char(k, 'j') or kk.named(k, .down)) p.cursor = @min(p.cursor + 1, p.items.len - 1);
    if (kk.char(k, 'k') or kk.named(k, .up)) p.cursor -|= 1;
}

fn addKey(app: *App, k: term.Input.Key) !void {
    const kk = w.keys;
    const p = &app.panel;
    if (app.pasting) {
        // A pasted line break must not add, nor a pasted tab do anything.
        if (keys.pastedBreak(k)) return p.path_input.insert(" ");
        _ = try p.path_input.handleKey(k);
        return;
    }
    if (kk.ctrl(k, 'c')) return p.path_input.clear();
    if (kk.named(k, .escape)) {
        p.adding = false;
        return;
    }
    if (!kk.named(k, .enter)) {
        _ = try p.path_input.handleKey(k);
        return;
    }
    if (!app.connected) return app.say("workspace add: the daemon is not connected", .{});
    const path = try expandPath(app.frame.allocator(), p.path_input.value(), app.home);
    if (path.len == 0) return app.say("write a folder first, or esc", .{});
    p.adding = false;
    try app.request(.workspace_add, "workspace.add", .{ .path = path });
}

pub fn rescan(app: *App) !void {
    if (!app.connected) return app.say("workspace scan: the daemon is not connected", .{});
    const c = app.panel.current() orelse return app.say("no workspace yet: + adds a folder", .{});
    try app.request(.workspace_scan, "workspace.scan", .{ .path = c.path });
}

// ---- Drawing ---------------------------------------------------------------

fn isRepoOf(ag: *const model.Agent, repo: []const u8) bool {
    if (ag.repos.len == 0) return true; // the whole workspace
    var it = std.mem.splitScalar(u8, ag.repos, ',');
    while (it.next()) |r| if (std.mem.eql(u8, std.mem.trim(u8, r, " "), repo)) return true;
    return false;
}

/// `▲1 ◆2 ●3` for the live agents in `path` (in `repo`, if named): each
/// glyph is a state, so nothing is told by colour alone.
fn agentCounts(app: *const App, a: std.mem.Allocator, path: []const u8, repo: ?[]const u8) ![]const u8 {
    var blocking: usize = 0;
    var running: usize = 0;
    var other: usize = 0;
    for (app.model.agents.items) |*ag| {
        if (ag.state == .archived or !std.mem.eql(u8, ag.workspace, path)) continue;
        if (repo) |r| if (!isRepoOf(ag, r)) continue;
        if (ag.state.blocking()) {
            blocking += 1;
        } else if (ag.state == .running) {
            running += 1;
        } else other += 1;
    }
    if (blocking + running + other == 0) return if (repo == null) "idle" else "none";
    var out: std.ArrayList(u8) = .empty;
    if (blocking > 0) try out.print(a, "▲{d} ", .{blocking});
    if (running > 0) try out.print(a, "◆{d} ", .{running});
    if (other > 0) try out.print(a, "●{d} ", .{other});
    return std.mem.trimEnd(u8, out.items, " ");
}

fn liveAgents(app: *const App, path: []const u8) usize {
    var n: usize = 0;
    for (app.model.agents.items) |ag| {
        if (ag.state != .archived and std.mem.eql(u8, ag.workspace, path)) n += 1;
    }
    return n;
}

pub fn render(app: *App, surface: *Surface, main: Region) !void {
    const a = app.frame.allocator();
    const theme = &app.theme;
    const p = &app.panel;
    const side_w: u16 = std.math.clamp(main.width * 35 / 100, @min(28, main.width), 44);
    const cols = w.layout.sideBySide(main, .{ .fixed = side_w });

    // The workspaces, two rows each, then the add-folder row.
    const left = try pane.draw(surface, cols[0], theme, .{ .rule_right = true, .title = "WORKSPACES", .badge = try std.fmt.allocPrint(a, "{d}", .{p.items.len}), .focused = !p.adding });
    if (!p.loaded) {
        _ = try w.text.drawText(surface, left.x + 1, left.y, left.width -| 2, "loading…", .faint, theme, .{});
    }
    const rows_fit: usize = @max(left.height / 2, 1);
    const top = (p.cursor + 1) -| rows_fit;
    var y = left.y;
    for (p.items[@min(top, p.items.len)..], top..) |*ws, i| {
        if (y + 1 >= left.y + left.height) break;
        const on = i == p.cursor;
        const counts = try agentCounts(app, a, ws.path, null);
        const counts_w: u16 = @intCast(w.text.width(counts));
        _ = try w.text.drawText(surface, left.x + 1, y, 2, "■", if (on) .normal else .faint, theme, .{});
        _ = try w.text.drawText(surface, left.x + 3, y, left.width -| (counts_w + 5), ws.name(), .normal, theme, .{ .ellipsis = true, .overlay = .{ .bold = on, .reverse = on } });
        _ = try w.text.drawText(surface, left.x + left.width -| (counts_w + 1), y, counts_w, counts, .muted, theme, .{});
        const n = ws.repos.len;
        const ags = liveAgents(app, ws.path);
        const repos_text = if (n == 0) "plain folder" else try std.fmt.allocPrint(a, "{d} repo{s}", .{ n, if (n == 1) "" else "s" });
        const sub = try std.fmt.allocPrint(a, "{s} · {s} · {d} agent{s}", .{ try app.shortPath(a, ws.path), repos_text, ags, if (ags == 1) "" else "s" });
        _ = try w.text.drawText(surface, left.x + 3, y + 1, left.width -| 4, sub, .muted, theme, .{ .ellipsis = true });
        y += 2;
    }
    if (p.loaded and y < left.y + left.height) {
        _ = try w.text.drawText(surface, left.x + 1, y, left.width -| 2, if (p.items.len == 0) "+ add a folder: any folder, git or not" else "+ add folder", .secondary, theme, .{ .ellipsis = true });
    }

    // Its repos, and the add-folder box under them while it is open.
    const parts = if (p.adding) w.layout.stacked(cols[1], .{ .fixed = 3 }) else [2]Region{ cols[1], .{ .width = 0, .height = 0 } };
    const ws = p.current();
    const right = try pane.draw(surface, parts[0], theme, .{ .title = if (ws) |c| c.name() else "No workspace", .badge = if (ws) |c| tail(try app.shortPath(a, c.path), parts[0].width -| 16) else "" });
    if (ws) |c| try reposTable(app, surface, a, right, c);
    if (p.adding) {
        const box = try w.box.draw(surface, parts[1], theme, .{ .border = .single, .title = "Add a folder", .badge = "esc cancels", .focused = true });
        try p.path_input.draw(surface, box, theme, true);
    }
}

fn reposTable(app: *App, surface: *Surface, a: std.mem.Allocator, r: Region, ws: *const Workspace) !void {
    const theme = &app.theme;
    if (r.height == 0) return;
    if (ws.repos.len == 0) {
        _ = try w.text.drawText(surface, r.x + 1, r.y, r.width -| 2, "A plain folder: no git repos here, so agents run in place. R finds them again.", .muted, theme, .{ .ellipsis = true });
        return;
    }
    // Repo, Branch, Agents, Worktrees and Issue size to their content; Path
    // takes what is left, and a column that does not fit is dropped from the
    // right, so the first columns stay.
    var name_w: usize = 4;
    var branch_w: usize = 6;
    for (ws.repos) |repo| {
        name_w = @max(name_w, w.text.width(repo.label()));
        branch_w = @max(branch_w, w.text.width(try repo.branchText(a)));
    }
    const heads = [_][]const u8{ "Repo", "Branch", "Agents", "Worktrees", "Issue", "Path" };
    const widths = [_]u16{ @intCast(@min(name_w, r.width / 3)), @intCast(@min(branch_w, 24)), 10, 9, 6, 0 };
    var xs: [6]u16 = undefined;
    var x = r.x + 1;
    for (widths, &xs) |cw, *slot| {
        slot.* = x;
        x += cw + 2;
    }
    const end = r.x + r.width;
    for (heads, widths, xs) |h, cw, cx| {
        if (cx >= end) break;
        _ = try w.text.drawText(surface, cx, r.y, if (cw == 0) end - cx else @min(cw, end - cx), h, .muted, theme, .{ .overlay = .{ .bold = true } });
    }
    for (ws.repos, 0..) |repo, i| {
        if (i + 1 >= r.height) break;
        const y = r.y + 1 + @as(u16, @intCast(i));
        const cells = [_][]const u8{
            repo.label(),
            try repo.branchText(a),
            try agentCounts(app, a, ws.path, repo.name),
            if (repo.worktrees) |n| try std.fmt.allocPrint(a, "{d}", .{n}) else "-",
            if (repo.issue) |n| try std.fmt.allocPrint(a, "#{s}", .{n}) else "-",
            try app.shortPath(a, repo.path),
        };
        for (cells, widths, xs, 0..) |cell, cw, cx, col| {
            if (cx >= end) break;
            const role: w.Role = switch (col) {
                0 => .normal,
                1 => if (repo.dirty orelse false) .warn else .secondary,
                2 => .secondary,
                else => .muted,
            };
            _ = try w.text.drawText(surface, cx, y, if (cw == 0) end - cx else @min(cw, end - cx), cell, role, theme, .{ .ellipsis = true });
        }
    }
}

/// The last `max` columns of a path, with its front cut at a `/`.
fn tail(path: []const u8, max: usize) []const u8 {
    if (w.text.width(path) <= max) return path;
    var start = path.len -| max;
    while (start < path.len and (path[start] & 0xC0) == 0x80) start += 1;
    if (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| start = slash;
    return path[start..];
}

test "expandPath: home, trailing slash, spaces from a paste" {
    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/home/me", try expandPath(a, "~", "/home/me"));
    try std.testing.expectEqualStrings("/home/me/venom-org", try expandPath(a, " ~/venom-org/ ", "/home/me"));
    try std.testing.expectEqualStrings("/srv/x", try expandPath(a, "/srv/x/", ""));
    try std.testing.expectEqualStrings("/", try expandPath(a, "/", "/home/me"));
    try std.testing.expectEqualStrings("~nope", try expandPath(a, "~nope", "/home/me"));
}
