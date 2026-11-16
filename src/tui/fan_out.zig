//! Agents that spawn agents, in the TUI:
//! the fan-out block in a parent's transcript, moving between a parent and its
//! children, and the block's actions.
//!
//! ```text
//! ⑂ Fan-out: 3 agents                               ▲ 1  ◆ 1  ● 1
//! ▾ ⑂ venom-std   claude-code                      ● settled · 4m
//!     last: Bash  zig build test
//!     result: PR #31 opened
//! ▾ ⑂ venomx      codex                          ▲ needs you · 5m
//!     last: Edit  src/host/pane.zig
//!     ▲ approve: write outside the worktree
//! ] open child  \ split view  w wait for all  K stop all  P promote
//! ```
//!
//! - **The block** sits at the tail of the transcript, above the agent's
//!   inline attention: it is live, so it stays where a following view looks.
//!   Each card is a row, so `j` `k` focus it and `⏎` folds it.
//! - **State** comes from the model. Last activity and result are not in
//!   `agent.list`, so each child shown has its `agent.show` read, at most once
//!   a second per child, while events say it changed.
//! - **`[` and `]`** move the main view. In a split they act on the split's
//!   agent, and the main view goes there. A child the list doesn't show (folded
//!   or hidden, `t`) stays selected: the list's cursor rests on its nearest
//!   listed ancestor until it is moved (`pinned`).
//! - **Native children** get no card actions that write: `P` says why, and the
//!   input box says "Message the parent to steer it". When the daemon doesn't
//!   report them, a sub-agent row of the harness's own opens its calls in
//!   the pager.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const model = @import("model.zig");
const transcript = @import("transcript.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Agent = model.Agent;

/// One child, as the block draws it. Text lives as long as the block's arena.
pub const Card = struct {
    agent: []const u8,
    /// The row's id: `card:<agent>`, so it can't meet a tool call's id.
    key: []const u8,
    title: []const u8,
    harness: []const u8,
    native: bool,
    state: model.State,
    age: []const u8 = "",
    /// Its last tool call, or its last words if it made none.
    activity: []const u8 = "",
    /// What it came to: its last words, or what it waits for or failed on.
    result: []const u8 = "",
    /// Agents further down that need you or failed.
    below: u32 = 0,
};

/// What a transcript shows of an agent's children.
pub const Block = struct {
    cards: []const Card = &.{},
    /// `agent.wait` is open for this agent.
    waiting: bool = false,

    /// What the block's look depends on, for the transcript's build key.
    pub fn hash(self: Block) u64 {
        var h: std.hash.Wyhash = .init(self.cards.len);
        h.update(&.{@intFromBool(self.waiting)});
        for (self.cards) |c| {
            for ([_][]const u8{ c.agent, c.title, c.harness, c.age, c.activity, c.result }) |s| {
                h.update(s);
                h.update(&.{0});
            }
            h.update(std.mem.asBytes(&c.below));
            h.update(&.{ @intFromBool(c.native), @backingInt(c.state) });
        }
        return h.final();
    }

    /// A copy whose text lives in `a` (the transcript's arena).
    fn copy(self: Block, a: std.mem.Allocator) ![]const Card {
        const out = try a.alloc(Card, self.cards.len);
        for (self.cards, out) |c, *o| {
            o.* = c;
            inline for (.{ "agent", "key", "title", "harness", "age", "activity", "result" }) |name| @field(o, name) = try a.dupe(u8, @field(c, name));
        }
        return out;
    }
};

const Summary = struct {
    activity: []u8 = &.{},
    result: []u8 = &.{},
    /// How its last turn ended.
    ended: []u8 = &.{},
    /// Events came since it was last read.
    stale: bool = true,
    inflight: bool = false,
    asked_at: i64 = 0,

    fn deinit(self: *Summary, gpa: std.mem.Allocator) void {
        gpa.free(self.activity);
        gpa.free(self.result);
        gpa.free(self.ended);
    }
};

/// The App's part of this: what was read of the children, and where it came
/// from.
pub const State = struct {
    summaries: std.StringHashMapUnmanaged(Summary) = .empty,
    /// The agent `w`'s `agent.wait` is open for; owned.
    waiting: ?[]u8 = null,
    /// The child `[` last left, which `]` goes back to.
    came_from: std.ArrayList(u8) = .empty,
    /// The selected agent was reached by `[` or `]`, and may not be listed.
    pinned: bool = false,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        var it = self.summaries.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        self.summaries.deinit(gpa);
        if (self.waiting) |x| gpa.free(x);
        self.came_from.deinit(gpa);
    }

    /// An event for `agent`: what was read of it is out of date.
    pub fn touch(self: *State, agent: []const u8) void {
        if (self.summaries.getPtr(agent)) |s| s.stale = true;
    }

    pub fn touchAll(self: *State) void {
        var it = self.summaries.valueIterator();
        while (it.next()) |s| s.stale = true;
    }

    /// The connection went, and its answers with it.
    pub fn onDisconnected(self: *State, gpa: std.mem.Allocator) void {
        var it = self.summaries.valueIterator();
        while (it.next()) |s| {
            s.inflight = false;
            s.stale = true;
        }
        if (self.waiting) |x| gpa.free(x);
        self.waiting = null;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The children of `agent` the block shows: the list's rule, no archived ones.
fn children(app: *const App, a: std.mem.Allocator, agent: []const u8) ![]const *const Agent {
    var out: std.ArrayList(*const Agent) = .empty;
    if (agent.len == 0) return out.items;
    for (app.model.agents.items) |*x| {
        if (x.state != .archived and eql(x.parent, agent)) try out.append(a, x);
    }
    return out.items;
}

/// Whether `id` sits somewhere below `ancestor`.
fn isBelow(app: *const App, id: []const u8, ancestor: []const u8) bool {
    var steps = app.model.agents.items.len;
    var at = id;
    while (steps > 0) : (steps -= 1) {
        const x = app.model.find(at) orelse return false;
        if (x.parent.len == 0) return false;
        if (eql(x.parent, ancestor)) return true;
        at = x.parent;
    }
    return false;
}

fn blockingBelow(app: *const App, agent: []const u8) u32 {
    var n: u32 = 0;
    for (app.model.agents.items) |*x| {
        if (x.state.blocking() and isBelow(app, x.id, agent)) n += 1;
    }
    return n;
}

/// The block for `agent`, allocated in `app.frame`.
pub fn block(app: *App, agent: []const u8) !Block {
    const a = app.frame.allocator();
    const kids = try children(app, a, agent);
    if (kids.len == 0) return .{};
    const cards = try a.alloc(Card, kids.len);
    for (kids, cards) |x, *c| c.* = try cardOf(app, a, x);
    return .{ .cards = cards, .waiting = if (app.fan.waiting) |id| eql(id, agent) else false };
}

fn cardOf(app: *App, a: std.mem.Allocator, x: *const Agent) !Card {
    const state: model.State = if (x.away) .needs_you else x.state;
    const summary: Summary = app.fan.summaries.get(x.id) orelse .{};
    const reason = try transcript.oneLine(a, x.reason);
    const result: []const u8 = switch (state) {
        .needs_you => reason,
        .failed => if (reason.len > 0) reason else summary.ended,
        .running, .queued => "",
        .settled, .handed_over, .archived => summary.result,
    };
    return .{
        .agent = x.id,
        .key = try std.fmt.allocPrint(a, "card:{s}", .{x.id}),
        .title = try transcript.oneLine(a, if (x.title.len > 0) x.title else x.id),
        .harness = x.harness,
        .native = x.native,
        .state = state,
        .age = if (x.changed_at > 0) try app.age(a, x.changed_at) else "",
        .activity = summary.activity,
        .result = result,
        .below = blockingBelow(app, x.id),
    };
}

/// Once a frame, for each agent on screen: reads the children that changed.
pub fn fetch(app: *App, agent: []const u8) !void {
    if (!app.connected) return;
    const gpa = app.gpa;
    for (try children(app, app.frame.allocator(), agent)) |x| {
        const slot = try app.fan.summaries.getOrPut(gpa, x.id);
        if (!slot.found_existing) {
            slot.key_ptr.* = gpa.dupe(u8, x.id) catch |err| {
                app.fan.summaries.removeByPtr(slot.key_ptr);
                return err;
            };
            slot.value_ptr.* = .{};
        }
        const s = slot.value_ptr;
        if (s.inflight or !s.stale) continue;
        if (s.asked_at != 0 and app.now_ms - s.asked_at < 1000) continue;
        const id = try gpa.dupe(u8, x.id);
        errdefer gpa.free(id);
        try app.request(.{ .card_show = id }, "agent.show", .{ .agent = x.id, .tools = true });
        s.inflight = true;
        s.stale = false;
        s.asked_at = app.now_ms;
    }
}

/// A child's `agent.show`: its last tool call and its last words.
pub fn onShow(app: *App, agent: []const u8, body: @import("proto").Response.Body) !void {
    const s = app.fan.summaries.getPtr(agent) orelse return;
    s.inflight = false;
    if (body != .ok) return;
    const gpa = app.gpa;
    var d: model.Detail = .{};
    defer d.deinit(gpa);
    try app.model.fillDetail(&d, body.ok);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var activity: []const u8 = "";
    var result: []const u8 = "";
    var ended: []const u8 = "";
    var i = d.records.items.len;
    while (i > 0) {
        i -= 1;
        const r = &d.records.items[i];
        switch (r.kind) {
            .tool => if (activity.len == 0) {
                activity = try std.fmt.allocPrint(a, "{s}  {s}", .{ r.tool.name, try transcript.titleOf(a, &r.tool) });
            },
            .text => if (result.len == 0) {
                result = try transcript.oneLine(a, r.text);
            },
            .turn_ended => if (ended.len == 0) {
                ended = try std.fmt.allocPrint(a, "turn {s}", .{r.text});
            },
            .turn_started, .prompt => {},
        }
    }
    if (activity.len == 0) activity = result;
    inline for (.{ "activity", "result", "ended" }, .{ activity, result, ended }) |name, value| {
        const copy = try gpa.dupe(u8, value);
        gpa.free(@field(s, name));
        @field(s, name) = copy;
    }
}

// ---- Rows --------------------------------------------------------------

/// `rows` and, when `b` has cards, the block's: a header, the cards, the keys.
pub fn appendRows(a: std.mem.Allocator, rows: []transcript.Row, b: Block) ![]transcript.Row {
    if (b.cards.len == 0) return rows;
    const cards = try b.copy(a);
    const out = try a.alloc(transcript.Row, rows.len + cards.len + 2);
    @memcpy(out[0..rows.len], rows);
    out[rows.len] = .{ .kind = .fan_header };
    for (cards, out[rows.len + 1 ..][0..cards.len]) |*c, *row| row.* = .{ .kind = .card, .card = c };
    out[out.len - 1] = .{ .kind = .fan_keys };
    return out;
}

const state_order = [_]model.State{ .needs_you, .failed, .running, .queued, .handed_over, .settled };

/// `⑂ Fan-out: 3 agents`, then how many are in each state, glyph first.
pub fn headerSpans(a: std.mem.Allocator, b: Block, width: usize) ![]const w.Span {
    var out: std.ArrayList(w.Span) = .empty;
    var spawned: usize = 0;
    for (b.cards) |c| spawned += @intFromBool(!c.native);
    const n = b.cards.len;
    const title = if (spawned > 0)
        try std.fmt.allocPrint(a, "⑂ Fan-out: {d} {s}", .{ n, if (n == 1) "agent" else "agents" })
    else
        try std.fmt.allocPrint(a, "· Native {s}: {d}", .{ if (n == 1) "sub-agent" else "sub-agents", n });
    try out.append(a, .{ .text = title, .style = .{ .bold = true } });
    var counts: std.ArrayList(w.Span) = .empty;
    var used: usize = 0;
    for (state_order) |s| {
        var count: usize = 0;
        for (b.cards) |c| count += @intFromBool(c.state == s);
        if (count == 0) continue;
        const text = try std.fmt.allocPrint(a, "  {s} {d}", .{ s.glyph(), count });
        try counts.append(a, .{ .text = text, .role = app_mod.stateRole(s) });
        used += w.text.width(text);
    }
    const left = w.text.width(title);
    if (left + used <= width) {
        try out.append(a, .{ .text = try spaces(a, width - left - used) });
        try out.appendSlice(a, counts.items);
    }
    return out.items;
}

fn spaces(a: std.mem.Allocator, n: usize) ![]const u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

/// The block's actions, with the keys that do them.
pub fn keySpans(a: std.mem.Allocator, b: Block) ![]const w.Span {
    var spawned = false;
    for (b.cards) |c| spawned = spawned or !c.native;
    var out: std.ArrayList(w.Span) = .empty;
    try out.append(a, .{ .text = "] open child  \\ split view  ", .role = .secondary });
    if (b.waiting) {
        try out.append(a, .{ .text = "◐ waiting for all", .role = .info });
        try out.append(a, .{ .text = "  ", .role = .secondary });
    } else try out.append(a, .{ .text = "w wait for all  ", .role = .secondary });
    try out.append(a, .{ .text = if (spawned) "K stop all  P promote" else "K stop all", .role = .secondary });
    return out.items;
}

/// One card: who and in what state, then its last activity and its result.
pub fn cardSpans(a: std.mem.Allocator, c: *const Card, width: usize) ![]const w.Span {
    var out: std.ArrayList(w.Span) = .empty;
    const label = c.state.label();
    const meta = if (c.age.len > 0)
        try std.fmt.allocPrint(a, "{s} {s} · {s}", .{ c.state.glyph(), label, c.age })
    else
        try std.fmt.allocPrint(a, "{s} {s}", .{ c.state.glyph(), label });
    const who = try std.fmt.allocPrint(a, "{s} {s}", .{ if (c.native) "·" else "⑂", c.title });
    var about: std.ArrayList(u8) = .empty;
    try about.appendSlice(a, c.harness);
    if (c.native) try about.appendSlice(a, " · native");
    if (c.below > 0) try about.print(a, " · ▲ {d} below", .{c.below});
    try transcript.line(a, &out, who, about.items, .{ .text = meta, .role = app_mod.stateRole(c.state) }, width, true);
    const room = width -| 2;
    if (c.activity.len > 0) {
        try out.append(a, .{ .text = "\n  " });
        try out.append(a, .{ .text = try transcript.fit(a, try std.fmt.allocPrint(a, "last: {s}", .{c.activity}), room), .role = .secondary });
    }
    if (c.result.len > 0) {
        const text = switch (c.state) {
            .needs_you, .failed => try std.fmt.allocPrint(a, "{s} {s}", .{ c.state.glyph(), c.result }),
            else => try std.fmt.allocPrint(a, "result: {s}", .{c.result}),
        };
        const role: w.Role = switch (c.state) {
            .needs_you => .warn,
            .failed => .err,
            else => .muted,
        };
        try out.append(a, .{ .text = "\n  " });
        try out.append(a, .{ .text = try transcript.fit(a, text, room), .role = role });
    }
    return out.items;
}

// ---- The header's breadcrumb -----------------------------------------------

/// `rename proto.Frame › venomx`: the agent's title after its ancestors'.
/// Short of `max` cells the oldest ancestors go, never the agent itself.
pub fn breadcrumb(app: *const App, a: std.mem.Allocator, x: *const Agent, max: usize) ![]const u8 {
    const own = if (x.title.len > 0) x.title else x.id;
    if (x.parent.len == 0) return own;
    var chain: std.ArrayList([]const u8) = .empty;
    try chain.append(a, own);
    var steps = app.model.agents.items.len;
    var at = x.parent;
    while (steps > 0 and at.len > 0) : (steps -= 1) {
        const up = app.model.find(at) orelse break;
        try chain.append(a, if (up.title.len > 0) up.title else up.id);
        at = up.parent;
    }
    var from = chain.items.len;
    while (true) {
        var out: std.ArrayList(u8) = .empty;
        if (from < chain.items.len) try out.appendSlice(a, "… › ");
        var i = from;
        while (i > 0) {
            i -= 1;
            try out.appendSlice(a, chain.items[i]);
            if (i > 0) try out.appendSlice(a, " › ");
        }
        if (from <= 1 or w.text.width(out.items) <= max) return out.items;
        from -= 1;
    }
}

// ---- Keys ------------------------------------------------------------------

/// The card under the transcript cursor where the focus is, if any; in
/// `app.frame`.
pub fn focusedCard(app: *App) !?[]const u8 {
    if (app.inFocusedBox() or (app.area() != .transcript and app.focusedSplit() == null)) return null;
    const f = app.focusedRows();
    try app.refreshRows(f.rows, f.detail, f.agent);
    const row = f.rows.selectedRow() orelse return null;
    const c = row.card orelse return null;
    return try app.frame.allocator().dupe(u8, c.agent);
}

/// The child `]` goes to when no card has the cursor: the one `[` came from,
/// else the first that needs you, else the first.
fn defaultChild(app: *App, kids: []const *const Agent) []const u8 {
    for (kids) |x| if (eql(x.id, app.fan.came_from.items)) return x.id;
    for (kids) |x| if (x.state.blocking() or x.away) return x.id;
    return kids[0].id;
}

/// `]`.
pub fn intoChild(app: *App) !void {
    const f = app.focusedRows();
    if (f.agent.len == 0) return app.say("no agent selected", .{});
    try app.refreshRows(f.rows, f.detail, f.agent);
    const a = app.frame.allocator();
    if (f.rows.selectedRow()) |row| {
        if (row.card) |c| return go(app, try a.dupe(u8, c.agent));
        if (row.kind == .agent) return openNative(app, row, f.agent);
    }
    const kids = try children(app, a, f.agent);
    if (kids.len > 0) return go(app, try a.dupe(u8, defaultChild(app, kids)));
    var i = f.rows.rows.len;
    while (i > 0) {
        i -= 1;
        if (f.rows.rows[i].kind != .agent) continue;
        try f.rows.select(app.gpa, i);
        return openNative(app, &f.rows.rows[i], f.agent);
    }
    app.say("no sub-agent to open", .{});
}

/// A harness's own sub-agent row: its agent once the daemon reports one,
/// until then its calls in the pager.
fn openNative(app: *App, row: *const transcript.Row, parent: []const u8) !void {
    const ref = row.calls[0].child_ref;
    if (ref.len > 0) if (app.model.find(ref)) |x| if (eql(x.parent, parent)) {
        return go(app, try app.frame.allocator().dupe(u8, x.id));
    };
    try app.openPager(.body);
}

/// `[`.
pub fn toParent(app: *App) !void {
    const f = app.focusedRows();
    const x = app.model.find(f.agent) orelse return app.say("no agent selected", .{});
    if (x.parent.len == 0) return app.say("{s} is a top-level agent", .{x.id});
    const up = app.model.find(x.parent) orelse return app.say("{s}'s parent is not known here", .{x.id});
    const a = app.frame.allocator();
    const parent = try a.dupe(u8, up.id);
    app.fan.came_from.clearRetainingCapacity();
    try app.fan.came_from.appendSlice(app.gpa, x.id);
    try go(app, parent);
}

/// The main view goes to `id`, whether or not the list shows it.
fn go(app: *App, id: []const u8) !void {
    app.on_header = false;
    app.fan.pinned = true;
    try app.setSelected(id);
    if (app.host) |h| return h.openAgent(id);
    app.focus.set(@backingInt(app_mod.Area.transcript));
    app.scroll.follow();
}

/// While pinned, the list's cursor rests on the agent or its nearest listed
/// ancestor, and the selection stays. False when it isn't pinned (any more).
pub fn keepPinned(app: *App, rows: @import("agent_list.zig").Rows) bool {
    if (!app.fan.pinned) return false;
    const selected = app.selected.items;
    if (rows.indexOf(selected) != null) {
        app.fan.pinned = false;
        return false;
    }
    if (app.model.find(selected) == null) {
        app.fan.pinned = false;
        return false;
    }
    if (rows.inFoldedGroup(selected)) return true;
    var steps = app.model.agents.items.len;
    var at = selected;
    while (steps > 0) : (steps -= 1) {
        const x = app.model.find(at) orelse break;
        if (x.parent.len == 0) break;
        if (rows.indexOf(x.parent)) |i| {
            app.list.cursor = i;
            return true;
        }
        if (rows.inFoldedGroup(x.parent)) return true;
        at = x.parent;
    }
    app.fan.pinned = false;
    return false;
}

/// `P`: the focused card's agent, else the selected agent if it is a child.
pub fn promote(app: *App) !void {
    const f = app.focusedRows();
    const card = try focusedCard(app);
    const id = card orelse f.agent;
    const x = app.model.find(id) orelse return app.say("no agent selected", .{});
    if (x.parent.len == 0) {
        if (card == null and (try children(app, app.frame.allocator(), id)).len > 0) return app.say("promote: pick a child's card with j k first", .{});
        return app.say("{s} is a top-level agent already", .{id});
    }
    if (x.native) return app.say("{s} belongs to its harness and can't be promoted. Message the parent to steer it", .{id});
    if (!app.connected) return app.say("agent.promote: the daemon is not connected", .{});
    try app.request(.{ .action = try app.gpa.dupe(u8, "agent promote") }, "agent.promote", .{ .agent = id });
    app.say("promoting {s} to top level", .{id});
}

/// `w`: holds an `agent.wait` open and says how it ended.
pub fn waitAll(app: *App) !void {
    const f = app.focusedRows();
    if (f.agent.len == 0) return app.say("no agent selected", .{});
    if ((try children(app, app.frame.allocator(), f.agent)).len == 0) return app.say("{s} has no sub-agents to wait for", .{f.agent});
    if (!app.connected) return app.say("agent.wait: the daemon is not connected", .{});
    if (app.fan.waiting) |id| return app.say("already waiting for {s}'s sub-agents", .{id});
    const owned = try app.gpa.dupe(u8, f.agent);
    errdefer app.gpa.free(owned);
    const purpose = try app.gpa.dupe(u8, f.agent);
    errdefer app.gpa.free(purpose);
    try app.request(.{ .fan_wait = purpose }, "agent.wait", .{ .agent = f.agent });
    app.fan.waiting = owned;
}

/// `agent.wait` answered.
pub fn onWait(app: *App, agent: []const u8, body: @import("proto").Response.Body) void {
    if (app.fan.waiting) |id| app.gpa.free(id);
    app.fan.waiting = null;
    switch (body) {
        .ok => |ok| {
            const done = if (ok == .object) if (ok.object.get("done")) |d| d == .bool and d.bool else false else false;
            if (done) app.say("all of {s}'s sub-agents have finished", .{agent}) else app.say("{s}'s sub-agents are still going; the wait timed out", .{agent});
        },
        .@"error" => |e| app.say("agent wait: {s}", .{e.code}),
        else => {},
    }
}

/// `K`: `agent.stop --tree`.
pub fn stopAll(app: *App) !void {
    const f = app.focusedRows();
    if (f.agent.len == 0) return app.say("no agent selected", .{});
    if (!app.connected) return app.say("agent.stop: the daemon is not connected", .{});
    try app.request(.stop_tree, "agent.stop", .{ .agent = f.agent, .tree = true });
    app.say("stopping {s} and every agent below it", .{f.agent});
}

/// `agent.stop --tree` answered: one handed over stays as it is, and is named.
pub fn onStopTree(app: *App, body: @import("proto").Response.Body) void {
    switch (body) {
        .ok => |ok| {
            if (ok != .object) return;
            const list = ok.object.get("children") orelse return;
            if (list != .array) return;
            var left: usize = 0;
            for (list.array.items) |x| {
                if (x != .object) continue;
                const s = x.object.get("state") orelse continue;
                if (s == .string and eql(s.string, "handed_over")) left += 1;
            }
            if (left > 0) app.say("stopped; {d} left as it is, in its harness's own TUI", .{left});
        },
        .@"error" => |e| app.say("agent stop: {s}", .{e.code}),
        else => {},
    }
}
