//! The usage screen (`leader u`):
//!
//! ```text
//! ╭ Usage ─────────────────────────── today · by agent ╮
//! │ 1 today  2 7d  3 30d     g agent  workspace  harness
//! │ All agents  in 612k  out 188k  cache 1.6M / 44k  9 turns  12 tools  4m
//! │
//! │ Agent                 Harness   In  Out  Cache r/w  Context  Turns …
//! │▌rename proto.Frame    claude   201k  58k  640k / 44k   41%      9
//! │   └ tree: + 3 sub-agents       301k  90k …
//! ╰────────────────────────────────────────────────────╯
//! ```
//!
//! A client of `usage.show` and `usage.export`: the daemon does the sums.
//! Quota cards are not drawn yet; they show nothing rather than a guess.
//! The tokens-per-hour chart is not drawn.
//! `e` asks for the CSV and writes it next to where the TUI runs; the daemon
//! writes no file.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const pane = @import("pane.zig");
const k = term.widgets.keys;
const Surface = term.Surface;
const Region = term.Region;
const Value = std.json.Value;
const App = @import("app.zig").App;
const keys = @import("keys.zig");
const input_box = @import("input_box.zig");
const proto = @import("proto");

pub const Group = enum { agent, workspace, harness };
pub const Range = enum { today, @"7d", @"30d" };
pub const Request = enum { show, export_csv };

pub const Totals = struct { turns: u64 = 0, tool_calls: u64 = 0, tokens_in: u64 = 0, tokens_out: u64 = 0, cache_read: u64 = 0, cache_write: u64 = 0, wall_ms: u64 = 0 };

pub const Row = struct {
    key: []const u8,
    agents: u64 = 0,
    own: Totals = .{},
    title: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    tree: ?Totals = null,
    /// Percent of the window, when known.
    context: ?u64 = null,
};

pub const Usage = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    group: Group = .agent,
    range: Range = .today,
    rows: []const Row = &.{},
    total: Totals = .{},
    loaded: bool = false,
    cursor: usize = 0,
    /// The first row on screen.
    top: usize = 0,
    inflight: bool = false,
    again: bool = false,
    /// Where `e` writes; the TUI's folder by default.
    export_dir: []const u8 = ".",

    pub fn init(gpa: std.mem.Allocator) Usage {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Usage) void {
        self.arena.deinit();
    }

    /// The agent under the cursor, on the agent grouping.
    pub fn currentAgent(self: *const Usage) ?[]const u8 {
        if (self.group != .agent or self.cursor >= self.rows.len) return null;
        return self.rows[self.cursor].key;
    }

    /// Takes a `usage.show` result.
    pub fn apply(self: *Usage, ok: Value) !void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.loaded = true;
        self.rows = &.{};
        self.total = .{};
        if (ok != .object) return;
        if (ok.object.get("total")) |t| self.total = totals(t);
        const list = ok.object.get("rows") orelse return;
        if (list != .array) return;
        const rows = try a.alloc(Row, list.array.items.len);
        for (list.array.items, rows) |v, *r| {
            r.* = .{ .key = try a.dupe(u8, str(v, "key") orelse ""), .agents = int(v, "agents"), .own = totals(v) };
            r.title = try dupeOpt(a, str(v, "title"));
            r.harness = try dupeOpt(a, str(v, "harness"));
            r.parent = try dupeOpt(a, str(v, "parent"));
            if (v.object.get("tree")) |t| r.tree = totals(t);
            if (v.object.get("context")) |c| if (int(c, "window") > 0) {
                r.context = (int(c, "used") * 100 + int(c, "window") / 2) / int(c, "window");
            };
        }
        self.rows = rows;
        self.cursor = @min(self.cursor, rows.len -| 1);
    }
};

fn dupeOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

fn str(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(name) orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: Value, name: []const u8) u64 {
    if (v != .object) return 0;
    const x = v.object.get(name) orelse return 0;
    return if (x == .integer and x.integer > 0) @intCast(x.integer) else 0;
}

fn totals(v: Value) Totals {
    var t: Totals = .{};
    inline for (comptime std.meta.fieldNames(Totals)) |name| @field(t, name) = int(v, name);
    return t;
}

// ---- Requests and keys ------------------------------------------------

/// `usage.show` for the current group and range; one at a time.
pub fn request(app: *App) !void {
    if (!app.connected) return;
    const u = &app.usage;
    if (u.inflight) {
        u.again = true;
        return;
    }
    u.inflight = true;
    try app.request(.{ .usage = .show }, "usage.show", .{ .group = @tagName(u.group), .range = @tagName(u.range) });
}

pub fn open(app: *App) !void {
    app.screen = .usage;
    try request(app);
}

/// A response to one of this screen's requests.
pub fn onResponse(app: *App, which: Request, body: proto.Response.Body) !void {
    switch (which) {
        .show => {
            app.usage.inflight = false;
            if (body == .ok) try app.usage.apply(body.ok) else if (body == .@"error") app.say("usage show: {s}", .{body.@"error".code});
            if (app.usage.again) {
                app.usage.again = false;
                try request(app);
            }
        },
        .export_csv => {
            if (body == .@"error") return app.say("usage export: {s}", .{body.@"error".code});
            if (body == .ok) try writeCsv(app, body.ok);
        },
    }
}

fn writeCsv(app: *App, ok: Value) !void {
    const text = str(ok, "csv") orelse return app.say("usage export: no csv in the answer", .{});
    const io = app.io orelse return app.say("usage export: nowhere to write here", .{});
    const u = &app.usage;
    const a = app.frame.allocator();
    const name = try std.fmt.allocPrint(a, "{s}/venom-usage-{s}-{s}.csv", .{ u.export_dir, @tagName(u.group), @tagName(u.range) });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = text }) catch |err|
        return app.say("usage export: cannot write {s}: {s}", .{ name, @errorName(err) });
    app.say("wrote {s} ({d} rows)", .{ name, int(ok, "rows") });
}

pub fn key(app: *App, input: term.Input.Key) !void {
    if (!k.pressed(input)) return;
    const u = &app.usage;
    if (k.ctrl(input, 'c') or k.char(input, 'q')) {
        app.quit = true;
    } else if (k.named(input, .escape)) {
        if (app.single_view) app.quit = true else app.screen = .main;
    } else if (k.char(input, '?')) {
        app.help = true;
    } else if (k.char(input, '1')) {
        try setRange(app, .today);
    } else if (k.char(input, '2')) {
        try setRange(app, .@"7d");
    } else if (k.char(input, '3')) {
        try setRange(app, .@"30d");
    } else if (k.char(input, 'g')) {
        u.group = switch (u.group) {
            .workspace => .agent,
            .agent => .harness,
            .harness => .workspace,
        };
        u.cursor = 0;
        u.top = 0;
        try request(app);
    } else if (k.char(input, 'e')) {
        try app.request(.{ .usage = .export_csv }, "usage.export", .{ .group = @tagName(u.group), .range = @tagName(u.range) });
    } else if (k.named(input, .enter)) {
        if (u.currentAgent()) |id| {
            if (app.single_view) return app.say("{s}", .{@import("app.zig").single_view_open});
            const copy = try app.frame.allocator().dupe(u8, id);
            app.screen = .main;
            try app.setSelected(copy);
        }
    } else if (k.char(input, 'j') or k.named(input, .down)) {
        if (u.cursor + 1 < u.rows.len) u.cursor += 1;
    } else if (k.char(input, 'k') or k.named(input, .up)) {
        u.cursor -|= 1;
    }
}

fn setRange(app: *App, range: Range) !void {
    app.usage.range = range;
    try request(app);
}

// ---- Drawing ----------------------------------------------------------

/// Numeric columns, right-aligned. The key column takes what is left.
const Col = struct { title: []const u8, width: u16 };
const agent_cols = [_]Col{ .{ .title = "Harness", .width = 12 }, .{ .title = "In", .width = 7 }, .{ .title = "Out", .width = 7 }, .{ .title = "Cache r/w", .width = 15 }, .{ .title = "Context", .width = 8 }, .{ .title = "Turns", .width = 6 }, .{ .title = "Tools", .width = 6 }, .{ .title = "Wall", .width = 8 } };
const group_cols = [_]Col{ .{ .title = "Agents", .width = 7 }, .{ .title = "In", .width = 7 }, .{ .title = "Out", .width = 7 }, .{ .title = "Cache r/w", .width = 15 }, .{ .title = "Turns", .width = 6 }, .{ .title = "Tools", .width = 6 }, .{ .title = "Wall", .width = 8 } };

/// `950ms`, `12s`, `4m 05s`, `2h 10m`.
pub fn wall(a: std.mem.Allocator, ms: u64) ![]const u8 {
    if (ms < 1000) return std.fmt.allocPrint(a, "{d}ms", .{ms});
    const s = ms / 1000;
    if (s < 60) return std.fmt.allocPrint(a, "{d}s", .{s});
    if (s < 3600) return std.fmt.allocPrint(a, "{d}m {d:0>2}s", .{ s / 60, s % 60 });
    return std.fmt.allocPrint(a, "{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 });
}

fn cache(a: std.mem.Allocator, t: Totals) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} / {s}", .{ try input_box.tokens(a, t.cache_read), try input_box.tokens(a, t.cache_write) });
}

/// Draws `cells` right-aligned in `cols`, ending at `right`.
fn drawCells(surface: *Surface, app: *App, y: u16, right: u16, cols: []const Col, cells: []const []const u8, role: w.Role) !void {
    var x = right;
    var i = cols.len;
    while (i > 0) {
        i -= 1;
        const width = cols[i].width;
        x -|= width;
        const text = cells[i];
        const used: u16 = @intCast(@min(w.text.width(text), width));
        _ = try w.text.drawText(surface, x + width - used, y, used, text, role, &app.theme, .{ .ellipsis = true });
    }
}

fn agentCells(a: std.mem.Allocator, r: Row, t: Totals) ![]const []const u8 {
    const ctx = if (r.context) |p| try std.fmt.allocPrint(a, "{d}%", .{p}) else "—";
    return a.dupe([]const u8, &.{ r.harness orelse "", try input_box.tokens(a, t.tokens_in), try input_box.tokens(a, t.tokens_out), try cache(a, t), ctx, try std.fmt.allocPrint(a, "{d}", .{t.turns}), try std.fmt.allocPrint(a, "{d}", .{t.tool_calls}), try wall(a, t.wall_ms) });
}

fn groupCells(a: std.mem.Allocator, r: Row) ![]const []const u8 {
    const t = r.own;
    return a.dupe([]const u8, &.{ try std.fmt.allocPrint(a, "{d}", .{r.agents}), try input_box.tokens(a, t.tokens_in), try input_box.tokens(a, t.tokens_out), try cache(a, t), try std.fmt.allocPrint(a, "{d}", .{t.turns}), try std.fmt.allocPrint(a, "{d}", .{t.tool_calls}), try wall(a, t.wall_ms) });
}

fn choice(surface: *Surface, app: *App, x: u16, y: u16, right: u16, label: []const u8, on: bool) !u16 {
    if (x >= right) return x;
    return x + try w.text.drawSpans(surface, x, y, right - x, &.{.{ .text = label, .role = if (on) .normal else .muted, .style = .{ .bold = on } }}, &app.theme, .{}) + 2;
}

/// The tree total differs from the row's own numbers: it has sub-agents.
fn treeLine(r: Row) ?Totals {
    const t = r.tree orelse return null;
    return if (std.meta.eql(t, r.own)) null else t;
}

pub fn render(app: *App, surface: *Surface, main: Region) !void {
    const a = app.frame.allocator();
    const u = &app.usage;
    const theme = &app.theme;
    const badge = try std.fmt.allocPrint(a, "{s} · by {s}", .{ @tagName(u.range), @tagName(u.group) });
    const inner = try pane.draw(surface, main, theme, .{ .title = "USAGE", .badge = badge, .focused = app.context_panel.agent == null });
    if (inner.height == 0 or inner.width < 4) return;
    const left = inner.x + 1;
    const right = inner.x + inner.width -| 1;
    var y = inner.y;

    // The switches: range, then group.
    var x = try choice(surface, app, left, y, right, "1 today", u.range == .today);
    x = try choice(surface, app, x, y, right, "2 7d", u.range == .@"7d");
    x = try choice(surface, app, x, y, right, "3 30d", u.range == .@"30d");
    x = try choice(surface, app, x + 2, y, right, "g workspace", u.group == .workspace);
    x = try choice(surface, app, x, y, right, "agent", u.group == .agent);
    _ = try choice(surface, app, x, y, right, "harness", u.group == .harness);
    y += 1;
    if (y >= inner.y + inner.height) return;

    const t = u.total;
    const summary = try std.fmt.allocPrint(a, "All agents  in {s}  out {s}  cache {s}  {d} turns  {d} tools  {s}", .{ try input_box.tokens(a, t.tokens_in), try input_box.tokens(a, t.tokens_out), try cache(a, t), t.turns, t.tool_calls, try wall(a, t.wall_ms) });
    _ = try w.text.drawText(surface, left, y, right - left, summary, .secondary, theme, .{ .ellipsis = true });
    y += 2;
    if (y >= inner.y + inner.height) return;

    if (u.rows.len == 0) {
        _ = try w.text.drawText(surface, left, y, right - left, if (u.loaded) "No turns in this range." else "loading…", .faint, theme, .{});
        return;
    }
    const cols: []const Col = if (u.group == .agent) &agent_cols else &group_cols;
    var cols_w: u16 = 0;
    for (cols) |c| cols_w += c.width;
    const name_w = (right - left) -| cols_w -| 1;
    const heading: []const u8 = switch (u.group) {
        .agent => "Agent",
        .workspace => "Workspace",
        .harness => "Harness",
    };
    _ = try w.text.drawSpans(surface, left, y, name_w, &.{.{ .text = heading, .role = .muted, .style = .{ .bold = true } }}, theme, .{});
    var titles: std.ArrayList([]const u8) = .empty;
    for (cols) |c| try titles.append(a, c.title);
    try drawCells(surface, app, y, right, cols, titles.items, .muted);
    y += 1;

    // Keep the cursor's row on screen; a tree line counts as a row's second.
    const bottom = inner.y + inner.height;
    const room: usize = bottom -| y;
    if (u.cursor < u.top) u.top = u.cursor;
    while (u.top < u.cursor) {
        var used: usize = 0;
        for (u.rows[u.top .. u.cursor + 1]) |r| used += 1 + @as(usize, @intFromBool(treeLine(r) != null));
        if (used <= room) break;
        u.top += 1;
    }
    for (u.rows[u.top..], u.top..) |r, i| {
        if (y >= bottom) break;
        const here = i == u.cursor;
        if (here) _ = try w.text.drawText(surface, inner.x, y, 1, "▌", .accent, theme, .{});
        const name = if (r.title) |s| (if (s.len > 0) s else r.key) else try app.shortPath(a, r.key);
        const indent: u16 = if (r.parent != null) 2 else 0;
        _ = try w.text.drawText(surface, left + indent, y, name_w -| indent, name, if (here) .normal else .secondary, theme, .{ .ellipsis = true });
        try drawCells(surface, app, y, right, cols, if (u.group == .agent) try agentCells(a, r, r.own) else try groupCells(a, r), .secondary);
        y += 1;
        if (treeLine(r)) |tree| {
            if (y >= bottom) break;
            _ = try w.text.drawText(surface, left + indent + 1, y, name_w -| indent -| 1, "└ with its sub-agents", .muted, theme, .{ .ellipsis = true });
            var row = r;
            row.harness = "";
            row.context = null;
            const cells = try agentCells(a, row, tree);
            // No context for a tree: it is per agent.
            const copy = try a.dupe([]const u8, cells);
            copy[4] = "";
            try drawCells(surface, app, y, right, cols, copy, .muted);
            y += 1;
        }
    }
}

pub fn hint(app: *const App) []const u8 {
    return if (app.usage.group == .agent and !app.single_view) "1 2 3 range  g group  ⏎ open  e csv  esc back" else "1 2 3 range  g group  e csv  esc back";
}
