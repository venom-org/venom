//! Usage accounting, the pure fold. The ledger is rebuilt
//! from the log like the rest of the
//! state; the `usage.show|export` verbs that read it are in `../usage.zig`.
//!
//! The unit is the **turn**, as in t3code's provider turns: each turn row
//! keeps its agent, its start and end times, its token counts (the sum of
//! its `usage` records, which are already per-turn deltas)
//! and its tool calls. Everything else is a sum over rows:
//!
//! - **tokens** in, out, cache read, cache write: the turn's `usage` records;
//! - **turns**: one per `turn.started`;
//! - **tool calls**: one per `tool.started`;
//! - **wall time**: from the turn's start to its end. The times are the
//!   `at` of the `agent.state_changed` records the decider commits with
//!   `turn.started` (`→ running`) and `turn.ended` (`running|needs_you →
//!   settled|failed`), so the turn records themselves need no clock. Time
//!   spent in `needs_you` counts: the turn is open. A turn ended by a
//!   daemon restart ends at the restart.
//!
//! A row belongs to a time range by its start time.
//!
//! **Context** is a per-agent "latest value", not a
//! sum: `Agent.context` holds the last `{used, window, source, at}` the
//! adapter reported, from the `context` record.
//!
//! **Plan windows** are a per-harness "latest value":
//! `Ledger.plans` holds the last `plan_windows` record of each harness.
//! `usage.show --by harness` will show them.
const std = @import("std");
const ev = @import("events.zig");
const Event = ev.Event;
const AgentState = @import("agent.zig").State;

pub const Tokens = struct {
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    pub fn add(self: *Tokens, o: Tokens) void {
        self.tokens_in +|= o.tokens_in;
        self.tokens_out +|= o.tokens_out;
        self.cache_read +|= o.cache_read;
        self.cache_write +|= o.cache_write;
    }
};

pub const Turn = struct {
    agent: []const u8,
    turn: []const u8,
    /// Milliseconds since the Unix epoch; null until the agent's
    /// `→ running` change is folded in.
    started_at: ?i64 = null,
    /// Null while the turn runs.
    ended_at: ?i64 = null,
    /// `turn.ended` was seen (an end without a state change has no time).
    closed: bool = false,
    tokens: Tokens = .{},
    tool_calls: u32 = 0,

    /// Wall time at `now`: an open turn counts up to `now`.
    pub fn wallMs(self: Turn, now: i64) u64 {
        const start = self.started_at orelse return 0;
        const end = self.ended_at orelse if (self.closed) start else now;
        return if (end > start) @intCast(end - start) else 0;
    }
};

/// `context {used, window, source}`, plus when.
pub const Context = struct { used: u64, window: u64, source: []const u8 = "exact", at: i64 = 0, system: ?u64 = null, tools: ?u64 = null };

pub const Agent = struct {
    /// Index in `Ledger.turns` of the open turn.
    open: ?usize = null,
    /// The turn whose `turn.ended` waits for the state change that times it.
    ending: ?usize = null,
    /// Some `usage` record said native sub-agent usage is inside its
    /// numbers: tree totals then do not add this agent's children again.
    includes_subagents: bool = false,
    /// Latest context size and window; null until an adapter reports one.
    context: ?Context = null,
};

/// Lives in the decider's state arena: rows are only ever appended.
pub const Ledger = struct {
    turns: std.ArrayList(Turn) = .empty,
    agents: std.StringArrayHashMapUnmanaged(Agent) = .empty,
    /// The latest `plan_windows` per harness.
    plans: std.StringArrayHashMapUnmanaged(ev.PlanWindows) = .empty,

    fn agent(self: *Ledger, a: std.mem.Allocator, id: []const u8) !struct { key: []const u8, value: *Agent } {
        const slot = try self.agents.getOrPut(a, id);
        if (!slot.found_existing) {
            slot.key_ptr.* = try a.dupe(u8, id);
            slot.value_ptr.* = .{};
        }
        return .{ .key = slot.key_ptr.*, .value = slot.value_ptr };
    }

    fn openRow(self: *Ledger, id: []const u8, turn: []const u8) ?*Turn {
        const x = self.agents.getPtr(id) orelse return null;
        const i = x.open orelse return null;
        const row = &self.turns.items[i];
        return if (std.mem.eql(u8, row.turn, turn)) row else null;
    }

    /// Folds one committed event in; every other record is ignored.
    pub fn evolve(self: *Ledger, a: std.mem.Allocator, event: Event) error{OutOfMemory}!void {
        switch (event) {
            .turn_started => |t| {
                const x = try self.agent(a, t.agent);
                try self.turns.append(a, .{ .agent = x.key, .turn = try a.dupe(u8, t.turn) });
                x.value.open = self.turns.items.len - 1;
            },
            .turn_ended => |t| if (self.openRow(t.agent, t.turn)) |row| {
                row.closed = true;
                const x = self.agents.getPtr(t.agent).?;
                x.ending = x.open;
                x.open = null;
            },
            .agent_state_changed => |c| if (self.agents.getPtr(c.agent)) |x| {
                if (c.to == .running) if (x.open) |i| {
                    const row = &self.turns.items[i];
                    if (row.started_at == null) row.started_at = c.at;
                };
                if (live(c.from) and !live(c.to)) if (x.ending) |i| {
                    self.turns.items[i].ended_at = c.at;
                    x.ending = null;
                };
            },
            .usage => |u| if (self.openRow(u.agent, u.turn)) |row| {
                row.tokens.add(.{ .tokens_in = u.tokens_in, .tokens_out = u.tokens_out, .cache_read = u.cache_read, .cache_write = u.cache_write });
                if (u.includes_subagents) self.agents.getPtr(u.agent).?.includes_subagents = true;
            },
            .tool_started => |t| if (self.openRow(t.agent, t.turn)) |row| {
                row.tool_calls += 1;
            },
            .context => |c| try self.setContext(a, c.agent, .{ .used = c.used, .window = c.window, .source = c.source, .at = c.at, .system = c.system, .tools = c.tools }),
            .plan_windows => {
                const copy = (try event.dupe(a)).plan_windows;
                try self.plans.put(a, copy.harness, copy);
            },
            else => {},
        }
    }

    /// The latest context report for `id`.
    pub fn setContext(self: *Ledger, a: std.mem.Allocator, id: []const u8, c: Context) !void {
        const x = try self.agent(a, id);
        x.value.context = .{ .used = c.used, .window = c.window, .source = try a.dupe(u8, c.source), .at = c.at, .system = c.system, .tools = c.tools };
    }
};

fn live(s: AgentState) bool {
    return s == .running or s == .needs_you;
}

const testing = std.testing;
const decider = @import("decider.zig");

test "usage ledger: the latest plan windows per harness win" {
    var state = decider.State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try testing.expectError(error.InvalidCommand, decider.applyAt(&state, .{ .record = .{ .plan_windows = .{ .harness = "" } } }, 1, s));
    _ = try decider.applyAt(&state, .{ .record = .{ .plan_windows = .{ .harness = "codex", .windows = &.{.{ .id = "primary", .label = "5h", .used_pct = 31 }} } } }, 1000, s);
    _ = try decider.applyAt(&state, .{ .record = .{ .plan_windows = .{ .harness = "codex", .account = "chatgpt", .billing = "subscription", .windows = &.{.{ .id = "primary", .label = "5h", .used_pct = 40 }} } } }, 2000, s);
    try testing.expectEqual(@as(usize, 1), state.usage.plans.count());
    const plan = state.usage.plans.get("codex").?;
    try testing.expectEqual(@as(i64, 2000), plan.at);
    try testing.expectEqualStrings("subscription", plan.billing);
    try testing.expectEqual(@as(u32, 40), plan.windows[0].used_pct);
}

test "usage ledger: turns are timed by their state changes and sum their records" {
    var state = decider.State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const at = decider.applyAt;
    _ = try at(&state, .{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } }, 1000, s);
    _ = try at(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, 2000, s);
    _ = try at(&state, .{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash" } } }, 2100, s);
    _ = try at(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "?" } } }, 2200, s);
    _ = try at(&state, .{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow" } }, 2500, s);
    _ = try at(&state, .{ .record = .{ .usage = .{ .agent = "a1", .turn = "t1", .tokens_in = 10, .tokens_out = 5, .cache_read = 100 } } }, 2600, s);
    _ = try at(&state, .{ .record = .{ .usage = .{ .agent = "a1", .turn = "t1", .model = "other", .tokens_in = 1, .cache_write = 7 } } }, 2700, s);
    _ = try at(&state, .{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } } }, 3000, s);
    _ = try at(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t2", .origin = "user" } } }, 5000, s);

    const rows = state.usage.turns.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(?i64, 2000), rows[0].started_at);
    try testing.expectEqual(@as(?i64, 3000), rows[0].ended_at);
    try testing.expectEqual(@as(u64, 1000), rows[0].wallMs(99_999));
    try testing.expectEqual(Tokens{ .tokens_in = 11, .tokens_out = 5, .cache_read = 100, .cache_write = 7 }, rows[0].tokens);
    try testing.expectEqual(@as(u32, 1), rows[0].tool_calls);
    // The open turn counts up to now.
    try testing.expectEqual(@as(u64, 500), rows[1].wallMs(5500));
    // A restart ends it at the restart.
    _ = try at(&state, .{ .start = .{} }, 8000, s);
    try testing.expectEqual(@as(?i64, 8000), state.usage.turns.items[1].ended_at);
    try testing.expectEqual(@as(u64, 3000), state.usage.turns.items[1].wallMs(99_999));
    try testing.expect(state.usage.agents.get("a1").?.context == null);
    try state.usage.setContext(state.arena.allocator(), "a1", .{ .used = 124_000, .window = 200_000, .at = 9 });
    try testing.expectEqual(@as(u64, 200_000), state.usage.agents.get("a1").?.context.?.window);
}
