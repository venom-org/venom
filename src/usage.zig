//! The usage verbs: `usage.show` and
//! `usage.export`, read-only views over the per-turn ledger the decider
//! folds from the log (`eventlog/usage.zig`). No cost and no quota here.
//!
//! - **Groupings:** `agent` (one row per agent, with its tree total and its
//!   latest context), `workspace` and `harness` (one row per value, summing
//!   the agents in it).
//! - **Ranges:** `today`, `7d`, `30d`: calendar days in UTC, today
//!   included (`7d` starts at 00:00 UTC six days ago). A turn counts in a
//!   range when it *started* in it; a running turn counts its wall time up
//!   to now.
//! - **Tree total** (agent grouping): the agent's own numbers plus its
//!   children's tree totals, each limited to the range. Children are not
//!   added when the agent's own usage records said they already include
//!   native sub-agents (`includes_subagents`).
//!   Workspace and harness rows and the `total` sum agents' own numbers
//!   only, so nothing is counted twice.
//! - **Rows** are listed when they have at least one turn in the range (for
//!   an agent: its own or in its tree). Agent rows keep creation order;
//!   workspace and harness rows are sorted by key.
//!
//! **CSV** (`usage.export`): RFC 4180, CRLF line ends, one header line,
//! then one line per row of `usage.show` for the same group and range:
//!
//!     range,since,until,group,key,agents,turns,tool_calls,tokens_in,tokens_out,cache_read,cache_write,wall_ms
//!
//! `since` and `until` are milliseconds since the Unix epoch; `key` is the
//! agent id, workspace path or harness id. Fields with a comma, quote or
//! line break are quoted. The verb returns the text in `csv` (`venom usage
//! export --json | jq -r .csv > usage.csv`); the daemon writes no file.
const std = @import("std");
const proto = @import("proto");
const eventlog = @import("eventlog/root.zig");
const ledger = eventlog.usage;
const Engine = eventlog.Engine;
const State = eventlog.State;

pub const Group = enum { agent, workspace, harness };
pub const Range = enum { today, @"7d", @"30d" };

pub const csv_header = [_][]const u8{ "range", "since", "until", "group", "key", "agents", "turns", "tool_calls", "tokens_in", "tokens_out", "cache_read", "cache_write", "wall_ms" };

const day_ms: i64 = std.time.ms_per_day;

/// Start of `range` at `now`: midnight UTC, `n - 1` days back.
pub fn since(range: Range, now: i64) i64 {
    const midnight = now - @mod(now, day_ms);
    const days: i64 = switch (range) {
        .today => 1,
        .@"7d" => 7,
        .@"30d" => 30,
    };
    return midnight - (days - 1) * day_ms;
}

pub const Totals = struct {
    turns: u64 = 0,
    tool_calls: u64 = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    wall_ms: u64 = 0,

    pub fn add(self: *Totals, o: Totals) void {
        inline for (comptime std.meta.fieldNames(Totals)) |name| @field(self, name) +|= @field(o, name);
    }

    fn addTurn(self: *Totals, t: ledger.Turn, now: i64) void {
        self.add(.{ .turns = 1, .tool_calls = t.tool_calls, .tokens_in = t.tokens.tokens_in, .tokens_out = t.tokens.tokens_out, .cache_read = t.tokens.cache_read, .cache_write = t.tokens.cache_write, .wall_ms = t.wallMs(now) });
    }
};

pub const Context = struct { used: u64, window: u64, source: []const u8, at: i64 };

pub const Row = struct {
    key: []const u8,
    agents: u64,
    turns: u64,
    tool_calls: u64,
    tokens_in: u64,
    tokens_out: u64,
    cache_read: u64,
    cache_write: u64,
    wall_ms: u64,
    // Agent grouping only.
    title: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    tree: ?Totals = null,
    context: ?Context = null,

    fn of(key: []const u8, agents: u64, t: Totals) Row {
        return .{ .key = key, .agents = agents, .turns = t.turns, .tool_calls = t.tool_calls, .tokens_in = t.tokens_in, .tokens_out = t.tokens_out, .cache_read = t.cache_read, .cache_write = t.cache_write, .wall_ms = t.wall_ms };
    }
};

pub const Report = struct {
    group: Group,
    range: Range,
    since: i64,
    until: i64,
    rows: []const Row,
    total: Totals,
};

/// The `usage.show` result for `group` and `range` at `now`. Allocated in `a`.
pub fn report(a: std.mem.Allocator, state: *const State, group: Group, range: Range, now: i64) !Report {
    const from = since(range, now);
    const agents = state.agents;
    // Each agent's own numbers in the range, indexed like `state.agents`.
    const own = try a.alloc(Totals, agents.count());
    @memset(own, .{});
    var total: Totals = .{};
    for (state.usage.turns.items) |t| {
        const start = t.started_at orelse continue;
        if (start < from or start > now) continue;
        const i = agents.getIndex(t.agent) orelse continue;
        own[i].addTurn(t, now);
        total.addTurn(t, now);
    }

    var rows: std.ArrayList(Row) = .empty;
    switch (group) {
        .agent => for (agents.keys(), agents.values(), 0..) |id, x, i| {
            const tree = treeTotal(state, own, i, agents.count());
            if (tree.turns == 0) continue;
            var row: Row = .of(id, 1, own[i]);
            row.title = x.title;
            row.harness = x.harness;
            row.workspace = x.workspace;
            row.parent = x.parent;
            row.tree = tree;
            if (state.usage.agents.get(id)) |u| if (u.context) |c| {
                row.context = .{ .used = c.used, .window = c.window, .source = c.source, .at = c.at };
            };
            try rows.append(a, row);
        },
        .workspace, .harness => {
            var by: std.StringArrayHashMapUnmanaged(struct { agents: u64 = 0, totals: Totals = .{} }) = .empty;
            for (agents.values(), own) |x, t| {
                if (t.turns == 0) continue;
                const slot = try by.getOrPut(a, if (group == .workspace) x.workspace else x.harness);
                if (!slot.found_existing) slot.value_ptr.* = .{};
                slot.value_ptr.agents += 1;
                slot.value_ptr.totals.add(t);
            }
            const Ctx = struct {
                keys: []const []const u8,
                pub fn lessThan(c: @This(), l: usize, r: usize) bool {
                    return std.mem.lessThan(u8, c.keys[l], c.keys[r]);
                }
            };
            by.sort(Ctx{ .keys = by.keys() });
            for (by.keys(), by.values()) |k, v| try rows.append(a, .of(k, v.agents, v.totals));
        },
    }
    return .{ .group = group, .range = range, .since = from, .until = now, .rows = rows.items, .total = total };
}

/// Own numbers plus the children's tree totals, unless this agent's
/// records already include its sub-agents. `depth` bounds a parent cycle
/// (the log does not forbid one).
fn treeTotal(state: *const State, own: []const Totals, i: usize, depth: usize) Totals {
    var t = own[i];
    if (depth == 0) return t;
    const id = state.agents.keys()[i];
    if (state.usage.agents.get(id)) |u| if (u.includes_subagents) return t;
    for (state.agents.values(), 0..) |x, j| {
        const p = x.parent orelse continue;
        if (j != i and std.mem.eql(u8, p, id)) t.add(treeTotal(state, own, j, depth - 1));
    }
    return t;
}

/// The CSV form of `r` (see the header comment).
pub fn csv(a: std.mem.Allocator, r: Report) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (csv_header, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(h);
    }
    try w.writeAll("\r\n");
    for (r.rows) |row| {
        try w.print("{s},{d},{d},{s},", .{ @tagName(r.range), r.since, r.until, @tagName(r.group) });
        try field(w, row.key);
        try w.print(",{d},{d},{d},{d},{d},{d},{d},{d}\r\n", .{ row.agents, row.turns, row.tool_calls, row.tokens_in, row.tokens_out, row.cache_read, row.cache_write, row.wall_ms });
    }
    return out.written();
}

fn field(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, ",\"\r\n") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

pub const Params = struct { group: []const u8 = "agent", range: []const u8 = "today" };

fn parse(p: Params) struct { Group, Range } {
    // The schema allows only these values.
    return .{ std.meta.stringToEnum(Group, p.group).?, std.meta.stringToEnum(Range, p.range).? };
}

pub const Usage = struct {
    engine: *Engine,
    show_: Show = undefined,
    export_: Export = undefined,

    /// The two bindings. `self` must not move afterwards.
    pub fn bindings(self: *Usage) [2]proto.Binding {
        self.show_ = .{ .usage = self };
        self.export_ = .{ .usage = self };
        return .{
            .{ .verb = "usage.show", .handler = proto.VerbHandler.typed(Params, &self.show_) },
            .{ .verb = "usage.export", .handler = proto.VerbHandler.typed(Params, &self.export_) },
        };
    }

    fn build(self: *Usage, a: std.mem.Allocator, p: Params) !Report {
        const g, const r = parse(p);
        return report(a, &self.engine.state, g, r, self.engine.options.clock.now());
    }
};

/// `usage.show` (read).
pub const Show = struct {
    usage: *Usage,
    pub fn call(self: *Show, c: *proto.Call, p: Params) anyerror!void {
        try c.ok(try self.usage.build(c.arena(), p));
    }
};

/// `usage.export` (read).
pub const Export = struct {
    usage: *Usage,
    pub fn call(self: *Export, c: *proto.Call, p: Params) anyerror!void {
        const a = c.arena();
        const r = try self.usage.build(a, p);
        try c.ok(.{ .group = r.group, .range = r.range, .since = r.since, .until = r.until, .header = csv_header, .rows = r.rows.len, .csv = try csv(a, r) });
    }
};

const testing = std.testing;
const decider = eventlog.decider;

/// One turn of `agent` from `start` to `end` with `tokens_in`/`out` and
/// `calls` tool calls.
fn turn(state: *State, s: std.mem.Allocator, agent: []const u8, id: []const u8, start: i64, end: ?i64, in: u64, out: u64, calls: u32, subagents: bool) !void {
    _ = try decider.applyAt(state, .{ .record = .{ .turn_started = .{ .agent = agent, .turn = id, .origin = "user" } } }, start, s);
    for (0..calls) |k| {
        const call = try std.fmt.allocPrint(s, "{s}-{s}-c{d}", .{ agent, id, k });
        _ = try decider.applyAt(state, .{ .record = .{ .tool_started = .{ .agent = agent, .turn = id, .call = call, .kind = "exec", .name = "Bash" } } }, start, s);
    }
    _ = try decider.applyAt(state, .{ .record = .{ .usage = .{ .agent = agent, .turn = id, .tokens_in = in, .tokens_out = out, .cache_read = in * 10, .cache_write = 1, .includes_subagents = subagents } } }, start, s);
    if (end) |e| _ = try decider.applyAt(state, .{ .record = .{ .turn_ended = .{ .agent = agent, .turn = id, .reason = "completed" } } }, e, s);
}

fn create(state: *State, s: std.mem.Allocator, id: []const u8, harness: []const u8, workspace: []const u8, parent: ?[]const u8) !void {
    _ = try decider.apply(state, .{ .create = .{ .agent = id, .title = id, .harness = harness, .workspace = workspace, .parent = parent } }, s);
}

test "usage: per-agent and tree totals add up, by range and grouping" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    const now: i64 = 1_794_000_000_000 + 12 * std.time.ms_per_hour; // mid-day
    const today = since(.today, now);
    try testing.expectEqual(@as(i64, 0), @mod(today, day_ms));
    try testing.expectEqual(today - 6 * day_ms, since(.@"7d", now));
    try testing.expectEqual(today - 29 * day_ms, since(.@"30d", now));

    // a1 (root, fake, /w) ← a2 (child, codex, /w) ← a3 (grandchild, fake, /v);
    // a4 (root, includes its sub-agents) ← a5.
    try create(&state, s, "a1", "fake", "/w", null);
    try create(&state, s, "a2", "codex", "/w", "a1");
    try create(&state, s, "a3", "fake", "/v", "a2");
    try create(&state, s, "a4", "fake", "/v", null);
    try create(&state, s, "a5", "fake", "/v", "a4");
    try turn(&state, s, "a1", "t1", today + 1000, today + 3000, 10, 1, 2, false); // today
    try turn(&state, s, "a1", "t2", today - 3 * day_ms, today - 3 * day_ms + 500, 100, 2, 0, false); // 7d
    try turn(&state, s, "a2", "t1", today + 5000, today + 6000, 20, 3, 1, false);
    try turn(&state, s, "a3", "t1", today - 20 * day_ms, today - 20 * day_ms + 10, 1000, 4, 0, false); // 30d
    try turn(&state, s, "a3", "t2", now - 100, null, 7, 0, 1, false); // still running
    try turn(&state, s, "a4", "t1", today + 10, today + 20, 5, 5, 0, true);
    try turn(&state, s, "a5", "t1", today + 30, today + 40, 6, 6, 0, false);
    try turn(&state, s, "a1", "t3", today - 40 * day_ms, today - 40 * day_ms + 1, 9999, 0, 0, false); // too old

    var r = try report(s, &state, .agent, .today, now);
    try testing.expectEqual(@as(usize, 5), r.rows.len);
    const a1 = r.rows[0];
    try testing.expectEqualStrings("a1", a1.key);
    try testing.expectEqual(@as(u64, 1), a1.turns);
    try testing.expectEqual(@as(u64, 2), a1.tool_calls);
    try testing.expectEqual(@as(u64, 10), a1.tokens_in);
    try testing.expectEqual(@as(u64, 100), a1.cache_read);
    try testing.expectEqual(@as(u64, 2000), a1.wall_ms);
    // a1's tree: a1 + a2 + a3 (a3's running turn only, today).
    try testing.expectEqual(@as(u64, 3), a1.tree.?.turns);
    try testing.expectEqual(@as(u64, 10 + 20 + 7), a1.tree.?.tokens_in);
    try testing.expectEqual(@as(u64, 4), a1.tree.?.tool_calls);
    try testing.expectEqual(@as(u64, 2000 + 1000 + 100), a1.tree.?.wall_ms);
    try testing.expectEqualStrings("a1", r.rows[1].parent.?);
    // a4 says its numbers include sub-agents: a5 is not added again.
    try testing.expectEqualStrings("a4", r.rows[3].key);
    try testing.expectEqual(r.rows[3].tokens_in, r.rows[3].tree.?.tokens_in);
    try testing.expect(r.rows[0].context == null);
    // The total is the sum of the agents' own numbers.
    var sum: Totals = .{};
    for (r.rows) |row| sum.add(.{ .turns = row.turns, .tool_calls = row.tool_calls, .tokens_in = row.tokens_in, .tokens_out = row.tokens_out, .cache_read = row.cache_read, .cache_write = row.cache_write, .wall_ms = row.wall_ms });
    try testing.expectEqual(sum, r.total);
    try testing.expectEqual(@as(u64, 10 + 20 + 7 + 5 + 6), r.total.tokens_in);

    r = try report(s, &state, .agent, .@"7d", now);
    try testing.expectEqual(@as(u64, 110), r.rows[0].tokens_in);
    try testing.expectEqual(@as(u64, 2), r.rows[0].turns);
    r = try report(s, &state, .agent, .@"30d", now);
    try testing.expectEqual(@as(u64, 110 + 20 + 1007), r.rows[0].tree.?.tokens_in);
    try testing.expectEqual(@as(u64, 110 + 20 + 1007 + 5 + 6), r.total.tokens_in);

    r = try report(s, &state, .workspace, .@"30d", now);
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    try testing.expectEqualStrings("/v", r.rows[0].key);
    try testing.expectEqual(@as(u64, 3), r.rows[0].agents);
    try testing.expectEqual(@as(u64, 1007 + 5 + 6), r.rows[0].tokens_in);
    try testing.expectEqualStrings("/w", r.rows[1].key);
    try testing.expectEqual(@as(u64, 130), r.rows[1].tokens_in);
    try testing.expect(r.rows[1].tree == null);

    r = try report(s, &state, .harness, .today, now);
    try testing.expectEqual(@as(usize, 2), r.rows.len);
    try testing.expectEqualStrings("codex", r.rows[0].key);
    try testing.expectEqual(@as(u64, 20), r.rows[0].tokens_in);
    try testing.expectEqualStrings("fake", r.rows[1].key);
    try testing.expectEqual(@as(u64, 4), r.rows[1].agents);
    try testing.expectEqual(@as(u64, 10 + 7 + 5 + 6), r.rows[1].tokens_in);
    try testing.expectEqual(r.total.tokens_in, r.rows[0].tokens_in + r.rows[1].tokens_in);
}

test "usage: CSV export has the documented header and quotes keys" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    try create(&state, s, "a1", "fake", "/w,\"x\"", null);
    try turn(&state, s, "a1", "t1", 1000, 1500, 3, 4, 1, false);
    const r = try report(s, &state, .workspace, .today, 2000);
    const text = try csv(s, r);
    try testing.expectEqualStrings(
        "range,since,until,group,key,agents,turns,tool_calls,tokens_in,tokens_out,cache_read,cache_write,wall_ms\r\n" ++
            "today,0,2000,workspace,\"/w,\"\"x\"\"\",1,1,1,3,4,30,1,500\r\n",
        text,
    );
}
