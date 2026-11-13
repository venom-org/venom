//! The TUI's picture of the daemon: agents and the selected
//! agent's detail, built only from what the verbs and `venom events` say.
//! Pure data, no I/O, so it is tested by feeding it JSON.
//!
//! Sources, in the order the client sees them:
//!
//! - `state.snapshot`: staged chunk by chunk and
//!   swapped in on `complete`. Its `agent` entities (`agent`, `title`,
//!   `harness`, `state`, `unread`) and `attention` entities (`requests`)
//!   replace the whole agent set, so a daemon restart (a new epoch, so a
//!   `source_changed` snapshot) rebuilds it from the durable state.
//! - `agent.list`: fills what the snapshot lacks (workspace, cwd, times, the
//!   parent and the linked issue).
//! - Live events: `agent.created`, `agent.promoted`, `agent.state_changed`,
//!   `agent.attention`, `agent.attention_cleared`; `agent.text`, `agent.turn_*` and
//!   `agent.tool_call` only mark an agent's detail stale.
//! - `agent.show` (with `tools`; a page at a time): the
//!   selected agent's transcript,
//!   tool calls and pending requests.
//!
//! The cursor (`<source>:<seq>`) is saved only after an item is applied,
//! and log events at or below the last applied seq of the same source are
//! dropped (delivery is at least once across reconnects).
const std = @import("std");
const Value = std.json.Value;

pub const State = enum {
    queued,
    running,
    needs_you,
    failed,
    settled,
    handed_over,
    archived,

    /// The state glyphs.
    pub fn glyph(self: State) []const u8 {
        return switch (self) {
            .queued, .archived => "○",
            .running => "◆",
            .needs_you => "▲",
            .failed => "✕",
            .settled => "●",
            .handed_over => "⇄",
        };
    }

    /// Human label, e.g. for the centre title's badge.
    pub fn label(self: State) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .needs_you => "needs you",
            .failed => "failed",
            .settled => "settled",
            .handed_over => "handed over",
            .archived => "archived",
        };
    }

    /// Blocking states count towards `▲ N need you` (approval, question,
    /// plan, failed and limit block).
    pub fn blocking(self: State) bool {
        return self == .needs_you or self == .failed;
    }
};

pub const Agent = struct {
    id: []u8,
    title: []u8,
    harness: []u8,
    workspace: []u8,
    cwd: []u8,
    /// The scope's repos, comma-joined; empty for the whole workspace
    /// (the row's second line).
    repos: []u8 = &.{},
    /// The parent agent's id; empty for a top-level agent.
    parent: []u8 = &.{},
    /// The harness's own sub-agent, not one venom spawned.
    /// The daemon reports it.
    native: bool = false,
    /// The linked issue's number; empty when there is none.
    issue: []u8 = &.{},
    state: State,
    unread: bool,
    created_at: i64 = 0,
    changed_at: i64 = 0,
    /// Pending requests (inbox items) and the oldest one's reason.
    attention: u32 = 0,
    reason: []u8,
    /// Handed over, and the harness's own TUI waits for the human:
    /// shown in "Needs you", though its state stays.
    away: bool = false,
    /// Reports from the harness's TUI so far: each is a new prompt, even in the
    /// same words as the last.
    away_reports: u32 = 0,

    fn deinit(self: *Agent, gpa: std.mem.Allocator) void {
        for ([_][]u8{ self.id, self.title, self.harness, self.workspace, self.cwd, self.reason, self.repos, self.parent, self.issue }) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// One tool call of `agent.show`: its `tool.started` and `tool.ended`
/// records merged. Every `[]u8` is owned.
pub const Tool = struct {
    call: []u8 = &.{},
    parent_call: []u8 = &.{},
    kind: []u8 = &.{},
    name: []u8 = &.{},
    title: []u8 = &.{},
    status: []u8 = &.{},
    /// When it started, ms since the Unix epoch; 0 when not known.
    at: i64 = 0,
    exit: ?i64 = null,
    duration_ms: ?u64 = null,
    /// `args`, by kind.
    path: []u8 = &.{},
    command: []u8 = &.{},
    query: []u8 = &.{},
    url: []u8 = &.{},
    server: []u8 = &.{},
    tool: []u8 = &.{},
    child_ref: []u8 = &.{},
    added: ?u64 = null,
    removed: ?u64 = null,
    /// The start of the output or diff, as much as `agent.show` carries.
    body: []u8 = &.{},
    /// `body` is cut; `bytes` is the whole size.
    truncated: bool = false,
    bytes: u64 = 0,
    /// The end of an open call's live output.
    tail: []u8 = &.{},

    pub fn ended(self: *const Tool) bool {
        return !(self.status.len == 0 or std.mem.eql(u8, self.status, "pending") or std.mem.eql(u8, self.status, "running") or std.mem.eql(u8, self.status, "awaiting_approval"));
    }

    /// A non-zero exit or a tool error.
    pub fn failed(self: *const Tool) bool {
        if (!self.ended()) return false;
        if (self.exit) |e| if (e != 0) return true;
        return std.mem.eql(u8, self.status, "error");
    }

    fn deinit(self: *Tool, gpa: std.mem.Allocator) void {
        inline for (.{ "call", "parent_call", "kind", "name", "title", "status", "path", "command", "query", "url", "server", "tool", "child_ref", "body", "tail" }) |name| gpa.free(@field(self, name));
    }

    fn set(gpa: std.mem.Allocator, slot: *[]u8, value: ?[]const u8) !void {
        const v = value orelse return;
        const copy = try gpa.dupe(u8, v);
        gpa.free(slot.*);
        slot.* = copy;
    }

    /// Fills the members a `tool.started` record has.
    fn started(self: *Tool, gpa: std.mem.Allocator, r: std.json.ObjectMap) !void {
        inline for (.{ "call", "parent_call", "kind", "name", "title", "status", "tail" }) |name| try set(gpa, &@field(self, name), str(r.get(name)));
        self.at = int(r.get("at")) orelse 0;
        const args = r.get("args") orelse return;
        if (args != .object) return;
        inline for (.{ "path", "command", "query", "url", "server", "tool", "child_ref" }) |name| try set(gpa, &@field(self, name), str(args.object.get(name)));
        if (int(args.object.get("added"))) |v| self.added = @intCast(@max(v, 0));
        if (int(args.object.get("removed"))) |v| self.removed = @intCast(@max(v, 0));
    }

    /// Fills the members a `tool.ended` record has.
    fn end(self: *Tool, gpa: std.mem.Allocator, r: std.json.ObjectMap) !void {
        try set(gpa, &self.status, str(r.get("status")));
        self.exit = int(r.get("exit"));
        if (int(r.get("duration_ms"))) |v| self.duration_ms = @intCast(@max(v, 0));
        const body = r.get("body") orelse return;
        if (body != .object) return;
        try set(gpa, &self.body, str(body.object.get("text")));
        self.truncated = if (body.object.get("truncated")) |t| t == .bool and t.bool else false;
        self.bytes = if (int(body.object.get("bytes"))) |v| @intCast(@max(v, 0)) else self.body.len;
    }
};

/// `before` past any transcript's end: its tail, paged like the rest.
pub const show_tail: u64 = (1 << 53) - 1;

/// The transcript part of an `agent.show` request; the other one is left out.
pub const ShowPage = struct { since: ?u64 = null, before: ?u64 = null };

/// One transcript record of `agent.show`.
pub const Record = struct {
    kind: enum { turn_started, prompt, text, turn_ended, tool },
    turn: []u8,
    /// The prompt, message text, or the end reason.
    text: []u8,
    /// `kind == .tool`: the call.
    tool: Tool = .{},
};

pub const Request = struct { kind: []u8, reason: []u8, stale: bool, call: []u8 = &.{} };

/// `agent.show`'s `steer`; unknown until the harness has been probed.
pub const Steer = enum { unknown, none, queue, inject };

/// The context size the harness last reported.
pub const Context = struct { used: u64, window: u64 };

fn freeRecords(gpa: std.mem.Allocator, records: []const Record) void {
    for (records) |r| {
        gpa.free(r.turn);
        gpa.free(r.text);
        var tool = r.tool;
        tool.deinit(gpa);
    }
}

/// The selected agent as `agent.show` has returned it so far.
pub const Detail = struct {
    agent: []u8 = &.{},
    turns: i64 = 0,
    records: std.ArrayList(Record) = .empty,
    requests: std.ArrayList(Request) = .empty,
    // The input box's footer and send keys.
    /// The model the harness reported; empty until it does.
    model: []u8 = &.{},
    permission_mode: []u8 = &.{},
    context: ?Context = null,
    /// `ui.context.warn_at`, as the daemon has it.
    warn_at: u8 = 80,
    steer: Steer = .unknown,
    interrupt: ?bool = null,
    /// Bumped on every change, for the transcript's wrap cache.
    revision: u32 = 0,
    /// Events arrived for this agent since the last `agent.show`.
    stale: bool = false,
    /// `records` is a window of the transcript: positions `start` up
    /// to `end` of `total`. A refresh asks for what follows `end`, scrolling
    /// back for what precedes `start`.
    windowed: bool = false,
    start: u64 = 0,
    end: u64 = 0,
    total: u64 = 0,
    /// `tool.ended` records whose `tool.started` is older than `start`; each
    /// closes its call when the page with it arrives.
    orphans: std.ArrayList(Tool) = .empty,
    /// Records put in front of `records` since the last draw, which keeps the
    /// lines on screen in place (`transcript.keepPlace`).
    prepended: usize = 0,
    /// `Home`: keep reading older pages, at the top, until the very start.
    to_start: bool = false,
    /// Asking for older records failed: not again until a read succeeds.
    older_failed: bool = false,

    /// What to pass to `agent.show` for the next page, older or newer.
    pub fn nextPage(self: *const Detail, older: bool) ShowPage {
        if (!self.windowed) return .{ .before = show_tail };
        return if (older) .{ .before = self.start } else .{ .since = self.end };
    }

    /// Older records exist, and may be asked for.
    pub fn hasOlder(self: *const Detail) bool {
        return self.windowed and self.start > 0 and !self.older_failed;
    }

    /// More of the transcript follows what was read.
    pub fn behind(self: *const Detail) bool {
        return self.windowed and self.end < self.total;
    }

    pub fn deinit(self: *Detail, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.records.deinit(gpa);
        self.requests.deinit(gpa);
        self.orphans.deinit(gpa);
        gpa.free(self.agent);
        self.* = undefined;
    }

    pub fn clear(self: *Detail, gpa: std.mem.Allocator) void {
        freeRecords(gpa, self.records.items);
        self.records.clearRetainingCapacity();
        for (self.orphans.items) |*t| t.deinit(gpa);
        self.orphans.clearRetainingCapacity();
        self.windowed = false;
        self.start = 0;
        self.end = 0;
        self.total = 0;
        self.prepended = 0;
        self.to_start = false;
        self.older_failed = false;
        self.clearHead(gpa);
    }

    /// Everything but the transcript: an `agent.show` has all of it anew.
    fn clearHead(self: *Detail, gpa: std.mem.Allocator) void {
        for (self.requests.items) |r| {
            gpa.free(r.kind);
            gpa.free(r.reason);
            gpa.free(r.call);
        }
        self.requests.clearRetainingCapacity();
        gpa.free(self.model);
        gpa.free(self.permission_mode);
        self.model = &.{};
        self.permission_mode = &.{};
        self.context = null;
        self.steer = .unknown;
        self.interrupt = null;
    }
};

/// What applying an item changed, so the client knows what to fetch.
pub const Change = packed struct {
    /// The agent set or a row changed.
    agents: bool = false,
    /// A snapshot completed: refetch `agent.list` and the selected agent.
    resync: bool = false,
    /// Events for this agent's detail arrived (see `Model.touched`).
    detail: bool = false,
};

pub const Model = struct {
    gpa: std.mem.Allocator,
    /// In creation order; the list shows newest first.
    agents: std.ArrayList(Agent) = .empty,
    /// The last applied cursor, `<source>:<seq>`; empty before the first.
    cursor: std.ArrayList(u8) = .empty,
    /// The agent of the last event with `Change.detail`.
    touched: std.ArrayList(u8) = .empty,
    detail: Detail = .{},
    /// A snapshot being staged.
    staging: ?std.ArrayList(Agent) = null,

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Model) void {
        freeAgents(self.gpa, &self.agents);
        if (self.staging) |*s| freeAgents(self.gpa, s);
        self.cursor.deinit(self.gpa);
        self.touched.deinit(self.gpa);
        self.detail.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeAgents(gpa: std.mem.Allocator, list: *std.ArrayList(Agent)) void {
        for (list.items) |*a| a.deinit(gpa);
        list.deinit(gpa);
    }

    pub fn find(self: *const Model, id: []const u8) ?*Agent {
        for (self.agents.items) |*a| if (std.mem.eql(u8, a.id, id)) return a;
        return null;
    }

    pub fn count(self: *const Model, pred: fn (State) bool) usize {
        var n: usize = 0;
        for (self.agents.items) |a| n += @intFromBool(pred(a.state));
        return n;
    }

    /// The source part of the cursor.
    pub fn source(self: *const Model) []const u8 {
        const c = self.cursor.items;
        return c[0 .. std.mem.lastIndexOfScalar(u8, c, ':') orelse 0];
    }

    fn lastSeq(self: *const Model) ?u64 {
        const c = self.cursor.items;
        const colon = std.mem.lastIndexOfScalar(u8, c, ':') orelse return null;
        return std.fmt.parseInt(u64, c[colon + 1 ..], 10) catch null;
    }

    fn setCursor(self: *Model, src: []const u8, seq: u64) !void {
        self.cursor.clearRetainingCapacity();
        try self.cursor.print(self.gpa, "{s}:{d}", .{ src, seq });
    }

    /// Applies one `events` item (the envelope).
    pub fn applyItem(self: *Model, item: Value) !Change {
        if (item != .object) return .{};
        const o = item.object;
        const typ = str(o.get("type")) orelse return .{};
        const src = str(o.get("source")) orelse return .{};
        const seq: u64 = if (o.get("seq")) |s| (if (s == .integer and s.integer >= 0) @intCast(s.integer) else return .{}) else return .{};
        const data = o.get("data") orelse return .{};
        if (data != .object) return .{};
        if (std.mem.eql(u8, typ, "state.snapshot")) return self.applySnapshot(src, seq, data);
        if (std.mem.eql(u8, typ, "stream.checkpoint")) {
            // A watermark: keep it only within the source we are synced to.
            if (self.staging == null and std.mem.eql(u8, self.source(), src)) try self.setCursor(src, seq);
            return .{};
        }
        // At least once: skip what this source already delivered.
        if (std.mem.eql(u8, self.source(), src)) {
            if (self.lastSeq()) |last| if (seq <= last) return .{};
        }
        const change = try self.applyEvent(typ, data.object, o.get("ts"));
        try self.setCursor(src, seq);
        return change;
    }

    fn applySnapshot(self: *Model, src: []const u8, seq: u64, data: Value) !Change {
        if (self.staging == null) self.staging = .empty;
        const staging = &self.staging.?;
        if (data.object.get("entities")) |entities| if (entities == .array) for (entities.array.items) |e| {
            if (e != .object) continue;
            const typ = str(e.object.get("entity_type")) orelse continue;
            const content = str(e.object.get("content")) orelse continue;
            const parsed = std.json.parseFromSlice(Value, self.gpa, content, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const c = parsed.value.object;
            const id = str(c.get("agent")) orelse continue;
            if (std.mem.eql(u8, typ, "agent")) {
                const state = parseState(str(c.get("state"))) orelse continue;
                const prev = self.find(id);
                var a = try newAgent(self.gpa, id, str(c.get("title")) orelse "", str(c.get("harness")) orelse "", if (prev) |p| p.workspace else "", state);
                a.unread = if (c.get("unread")) |u| u == .bool and u.bool else false;
                if (prev) |p| {
                    try replace(self.gpa, &a.cwd, p.cwd);
                    try replace(self.gpa, &a.repos, p.repos);
                    try replace(self.gpa, &a.parent, p.parent);
                    try replace(self.gpa, &a.issue, p.issue);
                    a.native = p.native;
                    a.created_at = p.created_at;
                    a.changed_at = if (p.state == state) p.changed_at else 0;
                }
                // Attention may have come first.
                const seen = for (staging.items) |*s| {
                    if (std.mem.eql(u8, s.id, id)) break s;
                } else null;
                if (seen) |s| {
                    a.attention = s.attention;
                    a.away = s.away;
                    std.mem.swap([]u8, &a.reason, &s.reason);
                    s.deinit(self.gpa);
                    s.* = a;
                } else {
                    errdefer a.deinit(self.gpa);
                    try staging.append(self.gpa, a);
                }
            } else if (std.mem.eql(u8, typ, "attention")) {
                const reqs = c.get("requests") orelse continue;
                if (reqs != .array) continue;
                const target = for (staging.items) |*s| {
                    if (std.mem.eql(u8, s.id, id)) break s;
                } else blk: {
                    try staging.append(self.gpa, try newAgent(self.gpa, id, "", "", "", .needs_you));
                    break :blk &staging.items[staging.items.len - 1];
                };
                target.attention = @intCast(reqs.array.items.len);
                for (reqs.array.items) |r| if (r == .object) {
                    target.away = target.away or std.mem.eql(u8, str(r.object.get("request")) orelse "", "away") and !std.mem.eql(u8, str(r.object.get("kind")) orelse "", "review");
                };
                if (reqs.array.items.len > 0) if (reqs.array.items[0] == .object) {
                    try replace(self.gpa, &target.reason, str(reqs.array.items[0].object.get("reason")) orelse "");
                };
            }
        };
        const complete = if (data.object.get("complete")) |c| c == .bool and c.bool else false;
        if (!complete) return .{};
        freeAgents(self.gpa, &self.agents);
        self.agents = staging.*;
        self.staging = null;
        try self.setCursor(src, seq);
        return .{ .agents = true, .resync = true };
    }

    fn applyEvent(self: *Model, typ: []const u8, d: std.json.ObjectMap, ts: ?Value) !Change {
        const id = str(d.get("agent")) orelse return .{};
        const when = if (str(ts)) |t| parseTs(t) orelse 0 else 0;
        if (std.mem.eql(u8, typ, "agent.created")) {
            if (self.find(id) != null) return .{};
            const state = parseState(str(d.get("state"))) orelse .queued;
            var a = try newAgent(self.gpa, id, str(d.get("title")) orelse "", str(d.get("harness")) orelse "", str(d.get("workspace")) orelse "", state);
            a.created_at = when;
            a.changed_at = when;
            errdefer a.deinit(self.gpa);
            try setRepos(self.gpa, &a, d.get("repos"));
            try setLinks(self.gpa, &a, d);
            try self.agents.append(self.gpa, a);
            return .{ .agents = true };
        }
        const a = self.find(id) orelse return .{};
        if (std.mem.eql(u8, typ, "agent.promoted")) {
            try replace(self.gpa, &a.parent, "");
            return self.markDetail(id, .{ .agents = true });
        }
        if (std.mem.eql(u8, typ, "agent.state_changed")) {
            const to = parseState(str(d.get("to"))) orelse return .{};
            if (a.state == to) return .{};
            a.state = to;
            a.changed_at = when;
            if (to != .handed_over) a.away = false;
            if (to == .settled) a.unread = true;
            return self.markDetail(id, .{ .agents = true });
        }
        if (std.mem.eql(u8, typ, "agent.attention")) {
            if (a.attention == 0) try replace(self.gpa, &a.reason, str(d.get("reason")) orelse "");
            a.attention += 1;
            // Only an away item arrives for a handed-over agent; a turn
            // that ended there is up for review, it blocks nothing.
            if (a.state == .handed_over) {
                a.away = !std.mem.eql(u8, str(d.get("kind")) orelse "", "review");
                a.away_reports +%= 1;
            }
            return self.markDetail(id, .{ .agents = true });
        }
        if (std.mem.eql(u8, typ, "agent.attention_cleared")) {
            a.attention -|= 1;
            if (a.attention == 0) try replace(self.gpa, &a.reason, "");
            a.away = false;
            return self.markDetail(id, .{ .agents = true });
        }
        if (std.mem.startsWith(u8, typ, "agent.")) return self.markDetail(id, .{});
        return .{};
    }

    fn markDetail(self: *Model, id: []const u8, change: Change) !Change {
        var out = change;
        if (std.mem.eql(u8, self.detail.agent, id)) {
            self.detail.stale = true;
            out.detail = true;
            self.touched.clearRetainingCapacity();
            try self.touched.appendSlice(self.gpa, id);
        }
        return out;
    }

    /// Merges an `agent.list` result: fills workspace, cwd and times.
    pub fn applyList(self: *Model, ok: Value) !void {
        if (ok != .object) return;
        const list = ok.object.get("agents") orelse return;
        if (list != .array) return;
        for (list.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            const a = self.find(str(o.get("agent")) orelse continue) orelse continue;
            try replace(self.gpa, &a.workspace, str(o.get("workspace")) orelse a.workspace);
            try replace(self.gpa, &a.cwd, str(o.get("cwd")) orelse a.cwd);
            try setRepos(self.gpa, a, o.get("repos"));
            try setLinks(self.gpa, a, o);
            if (int(o.get("created_at"))) |v| a.created_at = v;
            if (int(o.get("changed_at"))) |v| a.changed_at = v;
        }
    }

    /// Replaces the detail with an `agent.show` result.
    pub fn applyShow(self: *Model, ok: Value) !void {
        return self.fillDetail(&self.detail, ok);
    }

    /// Updates `detail` (the main view's, or an agent-view split's)
    /// with an `agent.show` result; the agent's row follows it. Records next
    /// to what `detail` has join it; others replace it.
    pub fn fillDetail(self: *Model, detail: *Detail, ok: Value) !void {
        if (ok != .object) return;
        const o = ok.object;
        const id = str(o.get("agent")) orelse return;
        const page: ?struct { start: u64, end: u64, total: u64 } = blk: {
            const start = int(o.get("transcript_start")) orelse break :blk null;
            const end = int(o.get("transcript_end")) orelse break :blk null;
            const total = int(o.get("transcript_total")) orelse break :blk null;
            if (start < 0 or end < start or total < end) break :blk null;
            break :blk .{ .start = @intCast(start), .end = @intCast(end), .total = @intCast(total) };
        };
        const join: enum { replace, append, prepend, same } = blk: {
            const w = page orelse break :blk .replace;
            if (!detail.windowed or !std.mem.eql(u8, detail.agent, id) or w.total < detail.end) break :blk .replace;
            if (w.start == detail.end) break :blk .append;
            if (w.end == detail.start) break :blk .prepend;
            if (w.start >= detail.start and w.end <= detail.end) break :blk .same;
            break :blk .replace;
        };
        if (join == .replace) detail.clear(self.gpa) else detail.clearHead(self.gpa);
        if (page) |w| {
            detail.windowed = true;
            detail.total = w.total;
            if (join == .replace or join == .append) detail.end = w.end;
            if (join == .replace or join == .prepend) detail.start = w.start;
        }
        detail.older_failed = false;
        try replace(self.gpa, &detail.agent, id);
        detail.turns = int(o.get("turns")) orelse 0;
        detail.stale = false;
        detail.revision +%= 1;
        try replace(self.gpa, &detail.model, str(o.get("model")) orelse "");
        try replace(self.gpa, &detail.permission_mode, str(o.get("permission_mode")) orelse "");
        if (o.get("context")) |c| if (c == .object) {
            const used = int(c.object.get("used")) orelse 0;
            const window = int(c.object.get("window")) orelse 0;
            if (used >= 0 and window > 0) detail.context = .{ .used = @intCast(used), .window = @intCast(window) };
        };
        if (int(o.get("context_warn_at"))) |v| if (v >= 0 and v <= 100) {
            detail.warn_at = @intCast(v);
        };
        detail.steer = std.meta.stringToEnum(Steer, str(o.get("steer")) orelse "unknown") orelse .unknown;
        detail.interrupt = if (o.get("interrupt")) |v| (if (v == .bool) v.bool else null) else null;
        if (o.get("transcript")) |t| if (t == .array) switch (join) {
            .replace, .append => try self.addRecords(&detail.records, &detail.orphans, t.array.items),
            .prepend => try self.addOlder(detail, t.array.items),
            .same => {},
        };
        if (o.get("tails")) |ts| if (ts == .array) for (ts.array.items) |r| {
            if (r != .object) continue;
            const call = str(r.object.get("call")) orelse continue;
            var i = detail.records.items.len;
            while (i > 0) {
                i -= 1;
                const rec = &detail.records.items[i];
                if (rec.kind != .tool or !std.mem.eql(u8, rec.tool.call, call)) continue;
                try Tool.set(self.gpa, &rec.tool.tail, str(r.object.get("tail")));
                break;
            }
        };
        if (o.get("requests")) |rs| if (rs == .array) for (rs.array.items) |r| {
            if (r != .object) continue;
            const kind = try self.gpa.dupe(u8, str(r.object.get("kind")) orelse "");
            errdefer self.gpa.free(kind);
            const reason = try self.gpa.dupe(u8, str(r.object.get("reason")) orelse "");
            errdefer self.gpa.free(reason);
            const call = try self.gpa.dupe(u8, str(r.object.get("call")) orelse "");
            errdefer self.gpa.free(call);
            try detail.requests.append(self.gpa, .{ .kind = kind, .reason = reason, .stale = if (r.object.get("stale")) |s| s == .bool and s.bool else false, .call = call });
        };
        // The row follows what `agent.show` says.
        if (self.find(id)) |a| {
            if (parseState(str(o.get("state")))) |s| a.state = s;
            try replace(self.gpa, &a.workspace, str(o.get("workspace")) orelse a.workspace);
            try replace(self.gpa, &a.cwd, str(o.get("cwd")) orelse a.cwd);
            if (int(o.get("changed_at"))) |v| a.changed_at = v;
            if (o.get("unread")) |u| if (u == .bool) {
                a.unread = u.bool;
            };
        }
    }

    /// Adds transcript records to the end of `records`.
    fn addRecords(self: *Model, records: *std.ArrayList(Record), orphans: *std.ArrayList(Tool), items: []const Value) !void {
        for (items) |r| {
            if (r != .object) continue;
            const typ = str(r.object.get("type")) orelse continue;
            if (std.mem.eql(u8, typ, "tool.ended")) {
                // Closes its call, wherever the call started.
                const id_ = str(r.object.get("call")) orelse continue;
                var i = records.items.len;
                const found = while (i > 0) {
                    i -= 1;
                    const rec = &records.items[i];
                    if (rec.kind != .tool or !std.mem.eql(u8, rec.tool.call, id_)) continue;
                    try rec.tool.end(self.gpa, r.object);
                    break true;
                } else false;
                if (!found) {
                    // Its call is in a page not read yet.
                    var t: Tool = .{};
                    errdefer t.deinit(self.gpa);
                    try Tool.set(self.gpa, &t.call, id_);
                    try t.end(self.gpa, r.object);
                    try orphans.append(self.gpa, t);
                }
                continue;
            }
            if (std.mem.eql(u8, typ, "tool.started")) {
                const turn = try self.gpa.dupe(u8, str(r.object.get("turn")) orelse "");
                errdefer self.gpa.free(turn);
                try records.append(self.gpa, .{ .kind = .tool, .turn = turn, .text = &.{} });
                try records.items[records.items.len - 1].tool.started(self.gpa, r.object);
                continue;
            }
            const kind: @FieldType(Record, "kind") = if (std.mem.eql(u8, typ, "turn.started")) .turn_started else if (std.mem.eql(u8, typ, "turn.prompt")) .prompt else if (std.mem.eql(u8, typ, "text")) .text else if (std.mem.eql(u8, typ, "turn.ended")) .turn_ended else continue;
            // A daemon restart ends a turn with no `tool.ended` for its open
            // calls: they are over all the same.
            if (kind == .turn_ended) {
                const ended_turn = str(r.object.get("turn")) orelse "";
                for (records.items) |*rec| if (rec.kind == .tool and !rec.tool.ended() and std.mem.eql(u8, rec.turn, ended_turn)) {
                    try Tool.set(self.gpa, &rec.tool.status, "interrupted");
                };
            }
            const body = if (kind == .turn_ended) str(r.object.get("reason")) orelse "" else str(r.object.get("text")) orelse "";
            const turn = try self.gpa.dupe(u8, str(r.object.get("turn")) orelse "");
            errdefer self.gpa.free(turn);
            const text = try self.gpa.dupe(u8, body);
            errdefer self.gpa.free(text);
            try records.append(self.gpa, .{ .kind = kind, .turn = turn, .text = text });
        }
    }

    /// Puts an older page in front of `detail.records`: what the newer records
    /// already said about its calls applies now that the calls are here.
    fn addOlder(self: *Model, detail: *Detail, items: []const Value) !void {
        var older: std.ArrayList(Record) = .empty;
        defer older.deinit(self.gpa);
        errdefer freeRecords(self.gpa, older.items);
        const known = detail.orphans.items.len;
        try self.addRecords(&older, &detail.orphans, items);
        var n = known;
        while (n > 0) {
            n -= 1;
            const orphan = &detail.orphans.items[n];
            for (older.items) |*rec| {
                if (rec.kind != .tool or !std.mem.eql(u8, rec.tool.call, orphan.call)) continue;
                std.mem.swap([]u8, &rec.tool.status, &orphan.status);
                std.mem.swap([]u8, &rec.tool.body, &orphan.body);
                rec.tool.exit = orphan.exit;
                rec.tool.duration_ms = orphan.duration_ms;
                rec.tool.truncated = orphan.truncated;
                rec.tool.bytes = orphan.bytes;
                orphan.deinit(self.gpa);
                _ = detail.orphans.orderedRemove(n);
                break;
            }
        }
        for (older.items) |*rec| {
            if (rec.kind != .tool or rec.tool.ended()) continue;
            for (detail.records.items) |*later| {
                if (later.kind != .turn_ended or !std.mem.eql(u8, later.turn, rec.turn)) continue;
                try Tool.set(self.gpa, &rec.tool.status, "interrupted");
                break;
            }
        }
        try detail.records.insertSlice(self.gpa, 0, older.items);
        detail.prepended += older.items.len;
    }

    /// Points the detail at another agent; its content is fetched next.
    pub fn select(self: *Model, id: []const u8) !void {
        if (std.mem.eql(u8, self.detail.agent, id)) return;
        self.detail.clear(self.gpa);
        try replace(self.gpa, &self.detail.agent, id);
        self.detail.turns = 0;
        self.detail.stale = true;
        self.detail.revision +%= 1;
    }
};

fn newAgent(gpa: std.mem.Allocator, id: []const u8, title: []const u8, harness: []const u8, workspace: []const u8, state: State) !Agent {
    var parts: [6][]u8 = undefined;
    var n: usize = 0;
    errdefer for (parts[0..n]) |p| gpa.free(p);
    for ([_][]const u8{ id, title, harness, workspace, workspace, "" }) |s| {
        parts[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return .{ .id = parts[0], .title = parts[1], .harness = parts[2], .workspace = parts[3], .cwd = parts[4], .reason = parts[5], .state = state, .unread = false };
}

/// Sets `a.repos` from a JSON array of repo names (left alone if absent).
fn setRepos(gpa: std.mem.Allocator, a: *Agent, v: ?Value) !void {
    const list = v orelse return;
    if (list != .array) return;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (list.array.items) |r| if (r == .string) {
        if (joined.items.len > 0) try joined.appendSlice(gpa, ", ");
        try joined.appendSlice(gpa, r.string);
    };
    try replace(gpa, &a.repos, joined.items);
}

/// Sets `parent`, `native` and `issue` from an `agent.list` row or an
/// `agent.created` event; a member that is absent leaves its field alone, an
/// explicit `null` clears it.
fn setLinks(gpa: std.mem.Allocator, a: *Agent, o: std.json.ObjectMap) !void {
    if (o.get("parent")) |v| try replace(gpa, &a.parent, str(v) orelse "");
    if (o.get("issue")) |v| try replace(gpa, &a.issue, str(v) orelse "");
    if (o.get("native")) |v| {
        a.native = v == .bool and v.bool;
    }
}

fn replace(gpa: std.mem.Allocator, slot: *[]u8, value: []const u8) !void {
    if (std.mem.eql(u8, slot.*, value)) return;
    const copy = try gpa.dupe(u8, value);
    gpa.free(slot.*);
    slot.* = copy;
}

pub fn parseState(s: ?[]const u8) ?State {
    return std.meta.stringToEnum(State, s orelse return null);
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: ?Value) ?i64 {
    const x = v orelse return null;
    return if (x == .integer) x.integer else null;
}

/// RFC 3339 UTC with milliseconds (`2026-11-06T12:05:00.000Z`) to ms since the Unix epoch.
pub fn parseTs(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    var ms: i64 = 0;
    if (s[19] == '.' and s.len >= 23) ms = std.fmt.parseInt(i64, s[20..23], 10) catch return null;
    // Days from civil (Howard Hinnant).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi) * 60_000 + sec * 1000 + ms;
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, json, .{});
}

test "parseTs: RFC 3339 milliseconds" {
    try testing.expectEqual(@as(?i64, 0), parseTs("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1794000000000), parseTs("2026-11-06T21:20:00.000Z"));
    try testing.expect(parseTs("nope") == null);
}

test "model: snapshot, events, dedup by seq, and a new epoch's snapshot replaces everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Model.init(testing.allocator);
    defer m.deinit();

    // A snapshot in two chunks: nothing changes until `complete`.
    var c = try m.applyItem(try parse(a,
        \\{"seq":4,"ts":"2026-11-06T12:00:00.000Z","source":"venom/e1","type":"state.snapshot","data":{"reason":"initial","complete":false,"entities":[
        \\{"resource":"agent:a1","entity_type":"attention","content":"{\"agent\":\"a1\",\"requests\":[{\"request\":\"r1\",\"kind\":\"approval\",\"reason\":\"Run zig build?\",\"stale\":false}]}"}]}}
    ));
    try testing.expect(!c.agents and m.agents.items.len == 0 and m.cursor.items.len == 0);
    c = try m.applyItem(try parse(a,
        \\{"seq":4,"ts":"2026-11-06T12:00:00.000Z","source":"venom/e1","type":"state.snapshot","data":{"reason":"initial","complete":true,"entities":[
        \\{"resource":"agent:a1","entity_type":"agent","content":"{\"agent\":\"a1\",\"title\":\"echo\",\"harness\":\"fake\",\"state\":\"needs_you\",\"unread\":false}"},
        \\{"resource":"agent:a2","entity_type":"agent","content":"{\"agent\":\"a2\",\"title\":\"docs\",\"harness\":\"fake\",\"state\":\"settled\",\"unread\":true}"}]}}
    ));
    try testing.expect(c.agents and c.resync);
    try testing.expectEqual(@as(usize, 2), m.agents.items.len);
    try testing.expectEqualStrings("venom/e1:4", m.cursor.items);
    const a1 = m.find("a1").?;
    try testing.expectEqual(State.needs_you, a1.state);
    try testing.expectEqual(@as(u32, 1), a1.attention);
    try testing.expectEqualStrings("Run zig build?", a1.reason);
    try testing.expectEqualStrings("echo", a1.title);

    // Live events; a duplicate (seq 5 again) is dropped.
    try m.select("a1");
    _ = try m.applyItem(try parse(a,
        \\{"seq":5,"ts":"2026-11-06T12:00:01.000Z","source":"venom/e1","type":"agent.created","data":{"agent":"a3","title":"new","harness":"fake","workspace":"/w","repos":[],"state":"queued"}}
    ));
    c = try m.applyItem(try parse(a,
        \\{"seq":5,"ts":"2026-11-06T12:00:01.000Z","source":"venom/e1","type":"agent.created","data":{"agent":"a3","title":"new","harness":"fake","workspace":"/w","repos":[],"state":"queued"}}
    ));
    try testing.expect(!c.agents);
    try testing.expectEqual(@as(usize, 3), m.agents.items.len);
    c = try m.applyItem(try parse(a,
        \\{"seq":6,"ts":"2026-11-06T12:00:02.000Z","source":"venom/e1","type":"agent.attention_cleared","data":{"agent":"a1","by":"answer"}}
    ));
    try testing.expect(c.detail and c.agents);
    try testing.expectEqualStrings("a1", m.touched.items);
    c = try m.applyItem(try parse(a,
        \\{"seq":7,"ts":"2026-11-06T12:00:03.000Z","source":"venom/e1","type":"agent.state_changed","data":{"agent":"a1","from":"needs_you","to":"running"}}
    ));
    try testing.expectEqual(State.running, m.find("a1").?.state);
    try testing.expectEqual(@as(u32, 0), m.find("a1").?.attention);
    _ = try m.applyItem(try parse(a,
        \\{"seq":9,"ts":"2026-11-06T12:00:04.000Z","source":"venom/e1","type":"stream.checkpoint","data":{}}
    ));
    try testing.expectEqualStrings("venom/e1:9", m.cursor.items);

    // agent.show fills the detail.
    try m.applyShow(try parse(a,
        \\{"agent":"a1","title":"echo","harness":"fake","state":"settled","unread":true,"workspace":"/w","cwd":"/w","created_at":1,"changed_at":2,"turns":1,"requests":[],
        \\ "transcript":[{"type":"turn.started","turn":"t1"},{"type":"text","turn":"t1","text":"Done."},{"type":"turn.ended","turn":"t1","reason":"completed"}]}
    ));
    try testing.expectEqual(@as(usize, 3), m.detail.records.items.len);
    try testing.expectEqualStrings("Done.", m.detail.records.items[1].text);
    try testing.expectEqual(State.settled, m.find("a1").?.state);

    // A restart: a new source, a snapshot without a3 replaces the set.
    _ = try m.applyItem(try parse(a,
        \\{"seq":2,"ts":"2026-11-06T12:10:00.000Z","source":"venom/e2","type":"state.snapshot","data":{"reason":"source_changed","complete":true,"entities":[
        \\{"resource":"agent:a1","entity_type":"agent","content":"{\"agent\":\"a1\",\"title\":\"echo\",\"harness\":\"fake\",\"state\":\"failed\",\"unread\":false}"}]}}
    ));
    try testing.expectEqual(@as(usize, 1), m.agents.items.len);
    try testing.expectEqual(State.failed, m.find("a1").?.state);
    try testing.expectEqualStrings("/w", m.find("a1").?.workspace);
    try testing.expectEqualStrings("venom/e2:2", m.cursor.items);
}
