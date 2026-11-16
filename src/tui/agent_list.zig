//! The agent list: the left
//! column of the main view, across all workspaces.
//!
//! `build` turns the model into one flat list of rows for this frame: group
//! headers, agents, and the folded mode's summary lines. `View` holds the
//! cursor and draws them. venom-term's `GroupedList` has one row height for
//! the whole list; here a top-level agent takes two lines and a sub-agent or
//! a summary one.
//!
//! ```text
//!  ▾ Running  1
//!  ◆ rename proto.Frame        ▲ 1  9m
//!    claude · 3 repos · 3 sub · running
//!    ├⑂ ● venom-std                  4m
//!    ├⑂ ▲ venomx                     5m
//!    └⑂ ◆ venom-docs                 2m
//!  ▸ Archived  23
//! ```
//!
//! Rules this file settles:
//!
//! - A sub-agent is nested under its parent wherever the parent is, so the
//!   parent's state, workspace or repo picks the group. An agent whose parent
//!   is unknown or archived is listed on its own: nothing that can still need
//!   the human hides in the Archived line.
//! - `Archived` is flat, sub-agents too, in every mode.
//! - `N sub`, `N children` and the bubbled count cover all levels below an
//!   agent, as `children_needs_you` does in `agent.list`, without archived
//!   ones. Hidden mode drops `N sub`: only the bubbled count is left.
//! - An agent scoped to its whole workspace has no one repo, so `repo`
//!   grouping lists it under the workspace's name.
//! - The filter keeps a match's ancestors, so a sub-agent is seen in place. Its
//!   words must all match, in any of the harness, scope, issue and title.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const pane = @import("pane.zig");
const k = w.keys;
const Surface = term.Surface;
const Region = term.Region;
const model = @import("model.zig");
const Agent = model.Agent;
const State = model.State;
const App = @import("app.zig").App;
const stateRole = @import("app.zig").stateRole;

pub const archived_title = "Archived";

/// Urgency order: what needs the human first.
const urgency = [_]State{ .needs_you, .failed, .running, .queued, .handed_over, .settled, .archived };

const state_titles = [_][]const u8{ "Needs you", "Running", "Settled" };

/// Glyphs of the folded mode's summary, in this order (`●1 ◆1 ▲1`).
const summary_order = [_]State{ .settled, .queued, .handed_over, .running, .failed, .needs_you };

pub const Header = struct { title: []const u8, count: usize, folded: bool };

pub const AgentRow = struct {
    id: []const u8,
    /// The tree before the glyph, with `⑂` or `·`; empty at the top level.
    branch: []const u8 = "",
    glyph: []const u8,
    role: w.Role,
    title: []const u8,
    age: []const u8,
    /// Sub-agents below that need the human: `▲ N`.
    bubble: u32 = 0,
    bold: bool = false,
    /// Line 2: harness, scope, sub-agent count, activity. Sub-agents have one
    /// line.
    detail: ?[]const u8 = null,
};

/// The folded mode's `3 children · ●1 ◆1 ▲1`. The cursor passes over it.
pub const Summary = struct { branch: []const u8, spans: []const w.Span };

pub const Row = union(enum) {
    header: Header,
    agent: AgentRow,
    summary: Summary,

    fn height(self: Row) usize {
        return switch (self) {
            .agent => |a| if (a.detail != null) 2 else 1,
            .header, .summary => 1,
        };
    }
};

pub const Rows = struct {
    rows: []const Row,
    /// The top-level agents of folded groups.
    folded: []const []const u8,

    pub fn indexOf(self: Rows, id: []const u8) ?usize {
        for (self.rows, 0..) |row, i| if (row == .agent and std.mem.eql(u8, row.agent.id, id)) return i;
        return null;
    }

    pub fn inFoldedGroup(self: Rows, id: []const u8) bool {
        for (self.folded) |f| if (std.mem.eql(u8, f, id)) return true;
        return false;
    }

    /// `id` is listed in the group named `title`.
    pub fn inGroup(self: Rows, title: []const u8, id: []const u8) bool {
        var here = false;
        for (self.rows) |row| switch (row) {
            .header => |h| here = std.mem.eql(u8, h.title, title),
            .agent => |a| if (here and std.mem.eql(u8, a.id, id)) return true,
            .summary => {},
        };
        return false;
    }
};

/// The next value of a `g` or `t` cycle.
pub fn next(value: anytype) @TypeOf(value) {
    const names = std.meta.tags(@TypeOf(value));
    return names[(@backingInt(value) + 1) % names.len];
}

const Below = struct {
    total: u32 = 0,
    bubble: u32 = 0,
    states: std.enums.EnumArray(State, u32) = .initFill(0),
};

const Bucket = struct { title: []const u8, rank: usize, roots: std.ArrayList(u32) = .empty };

/// What one frame's build works from; all in the frame's arena.
const Builder = struct {
    app: *App,
    a: std.mem.Allocator,
    agents: []const Agent,
    children: []const std.ArrayList(u32),
    below: []const Below,
    /// It matches the filter, or something below it does.
    keep: []const bool,
    out: std.ArrayList(Row) = .empty,

    fn row(self: *Builder, i: u32, branch: []const u8, detail: ?[]const u8) !AgentRow {
        const ag = &self.agents[i];
        const shown = shownState(ag);
        return .{
            .id = ag.id,
            .branch = branch,
            .glyph = shown.glyph(),
            .role = stateRole(shown),
            .title = if (ag.title.len > 0) ag.title else ag.id,
            .age = try self.app.age(self.a, ag.changed_at),
            .bubble = self.below[i].bubble,
            .bold = ag.unread and ag.state == .settled,
            .detail = detail,
        };
    }

    fn top(self: *Builder, i: u32) !void {
        const ag = &self.agents[i];
        const a = self.a;
        const activity = if (ag.attention > 0 and ag.reason.len > 0) ag.reason else ag.state.label();
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "{s} · {s}", .{ ag.harness, try scopeText(a, ag) });
        const subs = self.below[i].total;
        if (subs > 0 and self.app.children != .hidden) try line.print(a, " · {d} sub", .{subs});
        try line.print(a, " · {s}", .{activity});
        try self.out.append(a, .{ .agent = try self.row(i, "", line.items) });
        switch (self.app.children) {
            .tree => try self.tree(i, "  "),
            .folded => if (subs > 0) try self.out.append(a, .{ .summary = try self.summary(i) }),
            .hidden => {},
        }
    }

    fn tree(self: *Builder, parent: u32, prefix: []const u8) !void {
        const a = self.a;
        var last: ?u32 = null;
        for (self.children[parent].items) |c| {
            if (self.keep[c]) last = c;
        }
        for (self.children[parent].items) |c| {
            if (!self.keep[c]) continue;
            const end = c == last.?;
            const branch = try std.fmt.allocPrint(a, "{s}{s}{s} ", .{ prefix, if (end) "└" else "├", mark(self.agents[c].native) });
            try self.out.append(a, .{ .agent = try self.row(c, branch, null) });
            try self.tree(c, try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, if (end) "  " else "│ " }));
        }
    }

    fn summary(self: *Builder, i: u32) !Summary {
        const a = self.a;
        const below = &self.below[i];
        var spans: std.ArrayList(w.Span) = .empty;
        try spans.append(a, .{ .text = try std.fmt.allocPrint(a, "{d} {s} ·", .{ below.total, if (below.total == 1) "child" else "children" }), .role = .muted });
        for (summary_order) |s| {
            const n = below.states.get(s);
            if (n == 0) continue;
            try spans.append(a, .{ .text = " ", .role = .muted });
            try spans.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}{d}", .{ s.glyph(), n }), .role = stateRole(s) });
        }
        const any_spawned = for (self.children[i].items) |c| {
            if (!self.agents[c].native) break true;
        } else false;
        return .{ .branch = try std.fmt.allocPrint(a, "  └{s} ", .{mark(!any_spawned)}), .spans = spans.items };
    }
};

fn mark(native: bool) []const u8 {
    return if (native) "·" else "⑂";
}

/// What an agent's row shows: handed over, with its harness's own TUI waiting
/// for the human, it needs you, though its state stays.
fn shownState(ag: *const Agent) State {
    return if (ag.away) .needs_you else ag.state;
}

/// The rows of this frame, allocated in `app.frame`.
pub fn build(app: *App) !Rows {
    const a = app.frame.allocator();
    const agents = app.model.agents.items;
    const n: u32 = @intCast(agents.len);

    var by_id: std.StringHashMapUnmanaged(u32) = .empty;
    try by_id.ensureTotalCapacity(a, n);
    for (agents, 0..) |*ag, i| by_id.putAssumeCapacity(ag.id, @intCast(i));

    const parent = try a.alloc(?u32, n);
    const children = try a.alloc(std.ArrayList(u32), n);
    @memset(children, .empty);
    for (agents, parent, 0..) |*ag, *slot, i| {
        slot.* = null;
        if (ag.parent.len == 0 or ag.state == .archived) continue;
        const p = by_id.get(ag.parent) orelse continue;
        if (p == i or agents[p].state == .archived) continue;
        slot.* = p;
        try children[p].append(a, @intCast(i));
    }

    // Every agent counts in all its ancestors, and keeps them in the filter.
    const below = try a.alloc(Below, n);
    @memset(below, .{});
    const keep = try a.alloc(bool, n);
    @memset(keep, false);
    const filter = app.filter_input.value();
    for (agents, 0..) |*ag, i| {
        const shown = shownState(ag);
        const matches = matchesFilter(ag, filter);
        keep[i] = keep[i] or matches;
        var up = parent[i];
        var steps = n;
        while (up) |p| {
            if (steps == 0) break;
            steps -= 1;
            below[p].total += 1;
            below[p].states.getPtr(shown).* += 1;
            if (shown.blocking()) below[p].bubble += 1;
            keep[p] = keep[p] or matches;
            up = parent[p];
        }
    }

    // Top-level agents into groups: most urgent first, then newest first.
    var buckets: std.ArrayList(Bucket) = .empty;
    for (urgency) |state| {
        var i = n;
        while (i > 0) {
            i -= 1;
            const ag = &agents[i];
            if (ag.state != state or parent[i] != null or !keep[i]) continue;
            const g = try groupOf(app, a, ag);
            const bucket = for (buckets.items) |*b| {
                if (std.mem.eql(u8, b.title, g.title)) break b;
            } else blk: {
                try buckets.append(a, .{ .title = g.title, .rank = g.rank });
                break :blk &buckets.items[buckets.items.len - 1];
            };
            try bucket.roots.append(a, i);
        }
    }
    std.mem.sort(Bucket, buckets.items, {}, struct {
        fn before(_: void, x: Bucket, y: Bucket) bool {
            if (x.rank != y.rank) return x.rank < y.rank;
            return std.mem.order(u8, x.title, y.title) == .lt;
        }
    }.before);

    var b: Builder = .{ .app = app, .a = a, .agents = agents, .children = children, .below = below, .keep = keep };
    var folded: std.ArrayList([]const u8) = .empty;
    for (buckets.items) |bucket| {
        const is_folded = app.groupFolded(bucket.title);
        try b.out.append(a, .{ .header = .{ .title = bucket.title, .count = bucket.roots.items.len, .folded = is_folded } });
        for (bucket.roots.items) |i| {
            if (is_folded) {
                try folded.append(a, agents[i].id);
            } else try b.top(i);
        }
    }
    return .{ .rows = b.out.items, .folded = folded.items };
}

const Group = struct { title: []const u8, rank: usize };

fn groupOf(app: *App, a: std.mem.Allocator, ag: *const Agent) !Group {
    // After every other group, in every mode.
    if (ag.state == .archived) return .{ .title = archived_title, .rank = state_titles.len };
    return switch (app.group_by) {
        .state => blk: {
            const rank: usize = switch (shownState(ag)) {
                .needs_you, .failed => 0,
                .queued, .running, .handed_over => 1,
                .settled, .archived => 2,
            };
            break :blk .{ .title = state_titles[rank], .rank = rank };
        },
        .workspace => .{ .title = try workspaceTitle(app, a, ag), .rank = 0 },
        .repo => .{ .title = try repoTitle(app, a, ag), .rank = 0 },
    };
}

fn workspaceTitle(app: *const App, a: std.mem.Allocator, ag: *const Agent) ![]const u8 {
    // Only until `agent.list` answers: a snapshot doesn't carry it.
    if (ag.workspace.len == 0) return "(workspace not known yet)";
    return app.shortPath(a, ag.workspace);
}

fn repoCount(ag: *const Agent) usize {
    if (ag.repos.len == 0) return 0;
    return std.mem.count(u8, ag.repos, ", ") + 1;
}

/// A repo called `.` is the workspace's own root.
fn repoName(ag: *const Agent) []const u8 {
    return if (std.mem.eql(u8, ag.repos, ".")) std.fs.path.basename(ag.workspace) else ag.repos;
}

/// The folder below the workspace the agent runs in, if any.
fn folderOf(ag: *const Agent) ?[]const u8 {
    const ws = ag.workspace;
    if (ag.cwd.len > ws.len + 1 and std.mem.startsWith(u8, ag.cwd, ws) and ag.cwd[ws.len] == '/') return ag.cwd[ws.len + 1 ..];
    return null;
}

fn repoTitle(app: *const App, a: std.mem.Allocator, ag: *const Agent) ![]const u8 {
    const repos = repoCount(ag);
    if (repos > 1) return std.fmt.allocPrint(a, "{s} (multi-repo)", .{try workspaceTitle(app, a, ag)});
    if (repos == 1) return repoName(ag);
    if (folderOf(ag)) |folder| return folder[0 .. std.mem.indexOfScalar(u8, folder, '/') orelse folder.len];
    return workspaceTitle(app, a, ag);
}

/// The row's scope: the repo, how many repos, or the folder it runs in.
fn scopeText(a: std.mem.Allocator, ag: *const Agent) ![]const u8 {
    const repos = repoCount(ag);
    if (repos > 1) return std.fmt.allocPrint(a, "{d} repos", .{repos});
    if (repos == 1) return repoName(ag);
    if (folderOf(ag)) |folder| return folder;
    return std.fs.path.basename(if (ag.cwd.len > 0) ag.cwd else ag.workspace);
}

fn matchesFilter(ag: *const Agent, filter: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, filter, " \t");
    while (words.next()) |raw| {
        // `#246` is how an issue is usually written; the agent keeps `246`.
        const word = if (raw.len > 1 and raw[0] == '#') raw[1..] else raw;
        const found = for ([_][]const u8{ ag.harness, ag.repos, folderOf(ag) orelse std.fs.path.basename(ag.workspace), ag.issue, ag.title }) |field| {
            if (std.ascii.findIgnoreCase(field, word) != null) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// The one-column gutter marks the cursor when the list is focused.
fn gutter(surface: *Surface, x: u16, y: u16, cursor: bool, fill: term.Style, theme: *const w.Theme) !void {
    try surface.put(x, y, if (cursor) .{ .text = "▌", .style = theme.style(.accent) } else .{ .style = fill });
}

pub const Action = union(enum) {
    moved,
    /// The header at this row was folded or unfolded.
    toggled: usize,
};

/// The list's cursor, on a row of the frame's `Rows`.
pub const View = struct {
    cursor: usize = 0,
    /// First row drawn.
    top: usize = 0,
    /// Height and region of the last draw, for page keys and the mouse.
    page: u16 = 10,
    area: Region = .{ .width = 0, .height = 0 },

    /// Moves by `delta` rows, past any the cursor can't rest on.
    fn moveBy(self: *View, rows: []const Row, delta: isize) void {
        if (rows.len == 0) return;
        const last: isize = @intCast(rows.len - 1);
        var i = std.math.clamp(@as(isize, @intCast(self.cursor)) + delta, 0, last);
        const step: isize = if (delta < 0) -1 else 1;
        while (i >= 0 and i <= last and rows[@intCast(i)] == .summary) i += step;
        // Off the end: the last row it can rest on. A header starts the list.
        if (i > last) {
            i = last;
            while (rows[@intCast(i)] == .summary) i -= 1;
        }
        self.cursor = @intCast(@max(i, 0));
    }

    /// ↑/k ↓/j, Home/End, PgUp/PgDn; space folds a header; ←/h folds or goes
    /// to the header, →/l unfolds. Null when the key isn't the list's.
    pub fn handleKey(self: *View, r: Rows, key: term.Input.Key) ?Action {
        const rows = r.rows;
        self.clamp(rows);
        const page: isize = @max(1, @divFloor(@as(isize, self.page), 2));
        if (k.named(key, .up) or k.char(key, 'k')) {
            self.moveBy(rows, -1);
        } else if (k.named(key, .down) or k.char(key, 'j')) {
            self.moveBy(rows, 1);
        } else if (k.named(key, .page_up)) {
            self.moveBy(rows, -page);
        } else if (k.named(key, .page_down)) {
            self.moveBy(rows, page);
        } else if (k.named(key, .home)) {
            self.moveBy(rows, -@as(isize, @intCast(rows.len)));
        } else if (k.named(key, .end)) {
            self.moveBy(rows, @intCast(rows.len));
        } else if (k.named(key, .left) or k.char(key, 'h')) {
            if (rows.len == 0) return null;
            if (rows[self.cursor] == .header) {
                if (rows[self.cursor].header.folded) return null;
                return .{ .toggled = self.cursor };
            }
            var i = self.cursor;
            while (i > 0 and rows[i] != .header) i -= 1;
            self.cursor = i;
        } else if (k.named(key, .right) or k.char(key, 'l')) {
            if (rows.len == 0 or rows[self.cursor] != .header or !rows[self.cursor].header.folded) return null;
            return .{ .toggled = self.cursor };
        } else return null;
        return .moved;
    }

    /// The wheel moves the cursor; a click selects a row and folds a header.
    pub fn handleMouse(self: *View, r: Rows, mouse: term.Input.Mouse) ?Action {
        const cell = w.layout.hit(self.area, mouse.x, mouse.y) orelse return null;
        if (mouse.action != .press) return null;
        const rows = r.rows;
        self.clamp(rows);
        switch (mouse.button) {
            .wheel_up => self.moveBy(rows, -1),
            .wheel_down => self.moveBy(rows, 1),
            .left => {
                var y: usize = 0;
                var i = self.top;
                while (i < rows.len) : (i += 1) {
                    y += rows[i].height();
                    if (cell.row < y) break;
                } else return null;
                if (rows[i] == .summary) return null;
                self.cursor = i;
                if (rows[i] == .header) return .{ .toggled = i };
            },
            else => return null,
        }
        return .moved;
    }

    fn clamp(self: *View, rows: []const Row) void {
        if (rows.len == 0) {
            self.cursor = 0;
            self.top = 0;
        } else if (self.cursor >= rows.len) self.cursor = rows.len - 1;
    }

    /// Keeps the cursor visible and the list bottom-aligned when it shrinks.
    fn scroll(self: *View, rows: []const Row, height: usize) void {
        if (rows.len == 0) return;
        if (self.top > self.cursor) self.top = self.cursor;
        while (self.top < self.cursor) {
            var used: usize = 0;
            for (rows[self.top .. self.cursor + 1]) |row| used += row.height();
            if (used <= height) break;
            self.top += 1;
        }
        while (self.top > 0) {
            var used: usize = 0;
            for (rows[self.top - 1 ..]) |row| used += row.height();
            if (used > height) break;
            self.top -= 1;
        }
    }

    pub fn draw(self: *View, surface: *Surface, region: Region, r: Rows, theme: *const w.Theme, focused: bool) !void {
        self.page = region.height;
        self.area = region;
        if (region.width == 0 or region.height == 0) return;
        const rows = r.rows;
        self.clamp(rows);
        self.scroll(rows, region.height);
        const blank = theme.style(.normal);
        const sel_style = theme.style(.selection);
        const bottom = region.y + region.height;
        var y = region.y;
        var i = self.top;
        while (i < rows.len and y < bottom) : (i += 1) {
            const on = i == self.cursor;
            const fill = if (on) w.theme.overlay(blank, sel_style) else blank;
            const opts: w.text.DrawOptions = .{ .overlay = if (on) sel_style else null, .ellipsis = true, .fill = fill };
            const mark_cursor = on and focused;
            const x = region.x + 1;
            const width = region.width -| 1;
            try gutter(surface, region.x, y, mark_cursor, fill, theme);
            switch (rows[i]) {
                .header => |h| {
                    // `▾ NEEDS YOU  2 ─────`: the label, its count and a
                    // hairline to the edge.
                    var count_buf: [24]u8 = undefined;
                    // State groups are labels, uppercase; a workspace or
                    // repo is a name and keeps its case.
                    var label_buf: [32]u8 = undefined;
                    const is_state = for (state_titles ++ [_][]const u8{archived_title}) |t| {
                        if (std.mem.eql(u8, t, h.title)) break true;
                    } else false;
                    const label = if (is_state and h.title.len <= label_buf.len) std.ascii.upperString(label_buf[0..h.title.len], h.title) else h.title;
                    var no_fill = opts;
                    no_fill.fill = null;
                    const used = try w.text.drawText(surface, x, y, width, if (h.folded) "▸ " else "▾ ", .muted, theme, no_fill);
                    try pane.groupHeader(surface, x + used, y, width -| used, label, std.fmt.bufPrint(&count_buf, "{d}", .{h.count}) catch "", theme, opts);
                },
                .summary => |s| {
                    var spans: [2 + summary_order.len * 2]w.Span = undefined;
                    spans[0] = .{ .text = s.branch, .role = .faint };
                    @memcpy(spans[1..][0..s.spans.len], s.spans);
                    _ = try w.text.drawSpans(surface, x, y, width, spans[0 .. 1 + s.spans.len], theme, opts);
                },
                .agent => |a| {
                    var bubble_buf: [24]u8 = undefined;
                    const bubble = if (a.bubble > 0) std.fmt.bufPrint(&bubble_buf, "▲ {d}", .{a.bubble}) catch "" else "";
                    const gap: []const u8 = if (bubble.len > 0 and a.age.len > 0) "  " else "";
                    const meta = [_]w.Span{
                        .{ .text = bubble, .role = .warn, .style = .{ .bold = true } },
                        .{ .text = gap, .role = .muted },
                        .{ .text = a.age, .role = .muted },
                    };
                    const meta_w: u16 = @intCast(@min(w.text.width(bubble) + w.text.width(gap) + w.text.width(a.age), width));
                    const title_w = width -| meta_w -| @as(u16, if (meta_w > 0) 1 else 0);
                    _ = try w.text.drawSpans(surface, x, y, title_w, &.{
                        .{ .text = a.branch, .role = .faint },
                        .{ .text = a.glyph, .role = a.role },
                        .{ .text = " " },
                        .{ .text = a.title, .style = .{ .bold = a.bold } },
                    }, theme, opts);
                    if (meta_w > 0) {
                        _ = try w.text.drawText(surface, x + title_w, y, width - title_w - meta_w, "", .normal, theme, .{ .fill = fill });
                        _ = try w.text.drawSpans(surface, x + width - meta_w, y, meta_w, &meta, theme, opts);
                    }
                    if (a.detail) |detail| if (y + 1 < bottom) {
                        y += 1;
                        try gutter(surface, region.x, y, mark_cursor, fill, theme);
                        _ = try w.text.drawSpans(surface, x, y, width, &.{
                            .{ .text = "  " },
                            .{ .text = detail, .role = .secondary },
                        }, theme, opts);
                    };
                },
            }
            y += 1;
        }
        if (y < bottom) try surface.clear(.{ .x = region.x, .y = y, .width = region.width, .height = bottom - y }, blank);
    }
};
