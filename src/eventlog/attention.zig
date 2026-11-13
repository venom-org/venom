//! Attention and the inbox: the pure part.
//!
//! An agent that needs a human has one **attention kind**, ordered by
//! urgency: `approval`, `question`, `plan`, `failed`, `limit`, `review`.
//! The inbox is derived from the state, never stored on its own:
//!
//! - every pending request is an item of its kind (`approval`, `question`
//!   or `plan`), aged from when it was raised; its item id is the request
//!   id;
//! - a `failed` agent is a `failed` item, or `limit` when its last turn
//!   ended on a usage limit (`turn.ended {reason: limit}` or
//!   `failed.usage_limit`), aged from when it failed; a `limit` item
//!   carries the turn's `resets_at` when the harness said when the limit
//!   resets;
//! - a `settled`, unread agent is a `review` item, aged from when it
//!   settled. The item id of these three is the kind.
//!
//! - while a `handed_over` agent's harness TUI waits for the human
//!   (`attention.away`) it has one item of
//!   kind `approval`, `question` or `review`, item id `away`, marked `away`.
//!   It is answered in the harness's TUI, not here: the item only points at
//!   the split, and it goes when the agent is taken back or a newer report
//!   replaces it.
//!
//! Order: blocking kinds first (all but `review`), in the urgency order
//! above, then oldest first within a kind (ties: agent id, then item id).
//! Answering anywhere resolves the request in the log, so the item is gone
//! for every client; `agent.attention_cleared` says so on `venom events`.
//!
//! Commands decided here (the decider routes them):
//! - `away`: a report from the harness's TUI (`harness.hook`): see above.
//! - `snooze`: logs `attention.snoozed`; the item is left out of the inbox
//!   until `until`. A state item (`failed`, `limit`, `review`) that changes
//!   state after the snooze is a new item and shows again.
//! - `expire` (`attention.approval_timeout`): every live approval at least
//!   that old is answered `deny` with reason `timeout`, resolved `by:
//!   "timeout"`, through the same `harness.respond` effect as a human
//!   answer. Stale requests (their harness process is gone) block no running
//!   turn and are left alone.
const std = @import("std");
const ev = @import("events.zig");
const decider = @import("decider.zig");
const Event = ev.Event;
const Command = ev.Command;
const State = decider.State;
const Agent = decider.Agent;

pub const Kind = enum {
    approval,
    question,
    plan,
    failed,
    limit,
    review,

    /// Blocking kinds wait on a human; `review` does not.
    pub fn blocking(self: Kind) bool {
        return self != .review;
    }

    /// The shared attention level of the kind.
    pub fn level(self: Kind) []const u8 {
        return switch (self) {
            .approval, .question, .plan => "urgent",
            .failed, .limit => "warn",
            .review => "info",
        };
    }

    /// A request's kind. A harness kind venom does not know is shown as a
    /// question: it still needs a human, and a free-text answer fits it.
    pub fn ofRequest(kind: []const u8) Kind {
        const k = std.meta.stringToEnum(Kind, kind) orelse return .question;
        return switch (k) {
            .approval, .question, .plan => k,
            else => .question,
        };
    }
};

pub const Item = struct {
    agent: []const u8,
    kind: Kind,
    /// The request id, or the kind's name for a state item.
    item: []const u8,
    /// Set for request items.
    request: ?[]const u8 = null,
    reason: []const u8,
    /// When the item appeared, ms since the Unix epoch.
    since: i64,
    stale: bool = false,
    /// For approvals: the answers the harness accepts (empty: any).
    answers: []const []const u8 = &.{},
    /// For approvals: the narrowest grant "allow always" records.
    grant: ?[]const u8 = null,
    /// For approvals: a write outside the agent's scope.
    outside_scope: bool = false,
    /// For questions: what the harness offers, per question.
    options: []const ev.QuestionOptions = &.{},
    /// Set while snoozed.
    snoozed_until: ?i64 = null,
    /// For `limit`: when the limit resets (RFC 3339), if the harness said.
    resets_at: ?[]const u8 = null,
    /// Waiting in the harness's own TUI: answered there, not with the keys.
    away: bool = false,

    pub fn ageSeconds(self: Item, now: i64) u64 {
        return @intCast(@divTrunc(@max(0, now - self.since), std.time.ms_per_s));
    }

    /// Inbox order: kind (urgency), then oldest first.
    pub fn lessThan(_: void, l: Item, r: Item) bool {
        if (l.kind != r.kind) return @backingInt(l.kind) < @backingInt(r.kind);
        if (l.since != r.since) return l.since < r.since;
        const o = std.mem.order(u8, l.agent, r.agent);
        if (o != .eq) return o == .lt;
        return std.mem.order(u8, l.item, r.item) == .lt;
    }
};

pub const Failure = struct { kind: Kind, reason: []const u8, resets_at: ?[]const u8 = null };

/// Why a `failed` agent failed, from its last `turn.ended`.
pub fn failure(agent: *const Agent) Failure {
    var i = agent.transcript.items.len;
    while (i > 0) {
        i -= 1;
        const e = agent.transcript.items[i];
        if (e != .turn_ended) continue;
        const t = e.turn_ended;
        const code = t.error_code orelse "";
        if (std.mem.eql(u8, t.reason, "limit") or std.mem.eql(u8, code, "failed.usage_limit"))
            return .{ .kind = .limit, .reason = if (code.len > 0) code else "usage limit", .resets_at = t.resets_at };
        return .{ .kind = .failed, .reason = if (code.len > 0) code else t.reason };
    }
    return .{ .kind = .failed, .reason = "failed" };
}

pub const review_reason = "finished, unread";

/// The agent's state item (`failed`, `limit` or `review`), if any.
pub fn stateItem(id: []const u8, agent: *const Agent) ?Item {
    switch (agent.state) {
        .failed => {
            const f = failure(agent);
            return .{ .agent = id, .kind = f.kind, .item = @tagName(f.kind), .reason = f.reason, .since = agent.changed_at, .resets_at = f.resets_at };
        },
        .settled => if (agent.unread) return .{ .agent = id, .kind = .review, .item = "review", .reason = review_reason, .since = agent.changed_at },
        else => {},
    }
    return null;
}

/// The id of an `attention.away` item.
pub const away_item = "away";

/// The kinds a harness TUI reports, as `attention.away` carries them.
fn awayKind(kind: []const u8) ?Kind {
    const k = std.meta.stringToEnum(Kind, kind) orelse return null;
    return switch (k) {
        .approval, .question, .review => k,
        else => null,
    };
}

/// When item `item` of `agent` is snoozed until, if it is snoozed at all
/// (expired snoozes included: the caller compares with its clock).
fn snoozedUntil(agent: *const Agent, item: Item) ?i64 {
    for (agent.snoozes.items) |s| if (std.mem.eql(u8, s.item, item.item)) {
        // A state item that changed since is a new item.
        if (item.request == null and s.at < item.since) return null;
        return s.until;
    };
    return null;
}

/// Appends the items of one agent, unsorted, with `snoozed_until` set for
/// the snoozed ones whose snooze has not ended at `now`.
pub fn agentItems(a: std.mem.Allocator, id: []const u8, agent: *const Agent, now: i64, out: *std.ArrayList(Item)) !void {
    if (agent.state == .archived) return;
    for (agent.requests.items) |r| try out.append(a, .{
        .agent = id,
        .kind = .ofRequest(r.kind),
        .item = r.request,
        .request = r.request,
        .reason = r.reason,
        .since = r.at,
        .stale = r.stale,
        .answers = r.answers,
        .grant = r.grant,
        .outside_scope = r.outside_scope,
        .options = r.options orelse &.{},
    });
    if (stateItem(id, agent)) |s| try out.append(a, s);
    if (agent.away) |x| if (agent.state == .handed_over) if (awayKind(x.kind)) |kind| {
        try out.append(a, .{ .agent = id, .kind = kind, .item = away_item, .reason = x.reason, .since = x.at, .away = true });
    };
    for (out.items) |*it| if (std.mem.eql(u8, it.agent, id)) {
        if (snoozedUntil(agent, it.*)) |until| if (until > now) {
            it.snoozed_until = until;
        };
    };
}

/// The inbox at `now`, by kind, then oldest first. Snoozed items are left
/// out unless `snoozed` is set.
pub fn inbox(a: std.mem.Allocator, state: *const State, now: i64, snoozed: bool) ![]Item {
    var all: std.ArrayList(Item) = .empty;
    for (state.agents.keys(), state.agents.values()) |id, *agent| try agentItems(a, id, agent, now, &all);
    var kept: std.ArrayList(Item) = .empty;
    for (all.items) |it| if (snoozed or it.snoozed_until == null) try kept.append(a, it);
    std.mem.sort(Item, kept.items, {}, Item.lessThan);
    return kept.items;
}

/// One item of one agent, by item id; null when there is none.
pub fn find(a: std.mem.Allocator, state: *const State, id: []const u8, item: []const u8, now: i64) !?Item {
    const agent = state.agents.getPtr(id) orelse return null;
    var list: std.ArrayList(Item) = .empty;
    try agentItems(a, id, agent, now, &list);
    for (list.items) |it| if (std.mem.eql(u8, it.item, item)) return it;
    return null;
}

pub fn decide(state: *const State, cmd: Command, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (decider.Rejection || error{OutOfMemory})!void {
    switch (cmd) {
        .snooze => |s| {
            if (!state.agents.contains(s.agent)) return error.NotFound;
            _ = try find(a, state, s.agent, s.item, now) orelse return error.NotFound;
            if (s.until <= now) return error.InvalidCommand;
            try out.append(a, .{ .attention_snoozed = .{ .agent = s.agent, .item = s.item, .until = s.until, .at = now } });
        },
        .expire => |x| {
            const after = std.math.cast(i64, x.approval_timeout_ms) orelse return;
            for (state.agents.keys(), state.agents.values()) |id, *agent| {
                var expired: usize = 0;
                for (agent.requests.items) |r| {
                    if (r.stale or Kind.ofRequest(r.kind) != .approval or now - r.at < after) continue;
                    // Not every harness lists `deny`; one that lists none takes any.
                    try decider.respond(state, .{ .agent = id, .request = r.request, .decision = "deny", .reason = "timeout", .by = "timeout" }, null, a, out);
                    expired += 1;
                }
                // The last live request is answered: needs_you → running.
                if (expired > 0 and expired == agent.live() and agent.state == .needs_you)
                    try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = .needs_you, .to = .running, .at = now } });
            }
        },
        .away => |x| {
            const agent = state.agents.getPtr(x.agent) orelse return error.NotFound;
            if (agent.state != .handed_over) return error.InvalidTransition;
            if (x.transcript_ref) |t| if (agent.transcript_ref == null or !std.mem.eql(u8, agent.transcript_ref.?, t)) {
                var b = decider.tuiBinding(x.agent, agent);
                b.transcript_ref = t;
                try out.append(a, .{ .agent_binding = b });
            };
            const kind = x.kind orelse return;
            if (awayKind(kind) == null) return error.InvalidCommand;
            // Every report is news, however alike: a hook fires once per
            // prompt, so the same words are a new prompt, and it must show
            // even if the last one was snoozed.
            if (agent.away != null) try out.append(a, .{ .attention_away_cleared = .{ .agent = x.agent, .by = "harness" } });
            try out.append(a, .{ .attention_away = .{ .agent = x.agent, .kind = kind, .reason = x.reason, .at = now } });
        },
        else => unreachable,
    }
}

pub fn evolve(state: *State, event: Event) error{OutOfMemory}!void {
    const a = state.arena.allocator();
    const copy = try event.dupe(a);
    switch (copy) {
        .attention_away => |x| {
            const agent = state.agents.getPtr(x.agent) orelse return;
            agent.away = .{ .kind = x.kind, .reason = x.reason, .at = x.at };
            return;
        },
        .attention_away_cleared => |x| {
            const agent = state.agents.getPtr(x.agent) orelse return;
            agent.away = null;
            return;
        },
        else => {},
    }
    const s = copy.attention_snoozed;
    const agent = state.agents.getPtr(s.agent) orelse return;
    for (agent.snoozes.items) |*old| if (std.mem.eql(u8, old.item, s.item)) {
        old.* = .{ .item = s.item, .until = s.until, .at = s.at };
        return;
    };
    try agent.snoozes.append(a, .{ .item = s.item, .until = s.until, .at = s.at });
}

/// A change in an agent's inbox that one committed record makes, computed
/// from the state **before** that record is folded in. `catalog.publish`
/// turns it into `agent.attention` or `agent.attention_cleared`.
pub const Change = union(enum) {
    raise: struct { agent: []const u8, kind: Kind, reason: []const u8 },
    clear: struct { agent: []const u8, kind: Kind, by: []const u8 },
};

pub fn change(state: *const State, e: Event) ?Change {
    switch (e) {
        // Answered at once by a standing "allow always" or a one-shot
        // decision: nothing to raise.
        .request => |r| if (r.one_shot != null or @import("always.zig").autoAllow(state, r.agent, r) != null) return null else return .{ .raise = .{ .agent = r.agent, .kind = .ofRequest(r.kind), .reason = r.reason } },
        .request_reopened => |r| return .{ .raise = .{ .agent = r.agent, .kind = .ofRequest(r.kind), .reason = r.reason } },
        .request_resolved => |r| {
            if (r.grant != null or r.one_shot != null) return null;
            const agent = state.agents.getPtr(r.agent) orelse return null;
            const i = agent.pending(r.request) orelse return null;
            return .{ .clear = .{ .agent = r.agent, .kind = .ofRequest(agent.requests.items[i].kind), .by = r.by } };
        },
        .attention_away => |x| return .{ .raise = .{ .agent = x.agent, .kind = awayKind(x.kind) orelse .question, .reason = x.reason } },
        .attention_away_cleared => |x| {
            const agent = state.agents.getPtr(x.agent) orelse return null;
            const old = agent.away orelse return null;
            return .{ .clear = .{ .agent = x.agent, .kind = awayKind(old.kind) orelse .question, .by = x.by } };
        },
        .agent_opened => |o| return .{ .clear = .{ .agent = o.agent, .kind = .review, .by = "open" } },
        .agent_state_changed => |c| {
            const agent = state.agents.getPtr(c.agent) orelse return null;
            if (c.from == .failed) return .{ .clear = .{ .agent = c.agent, .kind = failure(agent).kind, .by = if (c.to == .running) "retry" else @tagName(c.to) } };
            if (c.from == .settled and agent.unread) return .{ .clear = .{ .agent = c.agent, .kind = .review, .by = switch (c.to) {
                .running => "send",
                .archived => "archive",
                .handed_over => "takeover",
                else => @tagName(c.to),
            } } };
            if (c.to == .failed) {
                // The turn's `turn.ended` precedes this record in its commit.
                const f = failure(agent);
                return .{ .raise = .{ .agent = c.agent, .kind = f.kind, .reason = f.reason } };
            }
            // Settled after a turn ran: unread, so up for review.
            if (c.to == .settled and (c.from == .running or c.from == .needs_you))
                return .{ .raise = .{ .agent = c.agent, .kind = .review, .reason = review_reason } };
            return null;
        },
        else => return null,
    }
}

const testing = std.testing;

fn record(state: *State, e: Event, now: i64, s: std.mem.Allocator) !void {
    _ = try decider.applyAt(state, .{ .record = e }, now, s);
}

test "attention: inbox order, blocking kinds first, oldest first within a kind" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    // a1 review (oldest of all), a2 question, a3 approval, a4 failed,
    // a5 limit, a6 plan, a7 approval (younger than a3).
    for ([_][]const u8{ "a1", "a2", "a3", "a4", "a5", "a6", "a7" }, 0..) |id, n| {
        _ = try decider.applyAt(&state, .{ .create = .{ .agent = id, .title = id, .harness = "fake", .workspace = "/w" } }, 0, s);
        try record(&state, .{ .turn_started = .{ .agent = id, .turn = "t1", .origin = "user" } }, @intCast(n), s);
    }
    try record(&state, .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } }, 10, s);
    try record(&state, .{ .request = .{ .agent = "a2", .request = "r1", .kind = "question", .reason = "keep varint framing?" } }, 20, s);
    try record(&state, .{ .request = .{ .agent = "a3", .request = "r1", .kind = "approval", .reason = "Bash zig build test" } }, 30, s);
    try record(&state, .{ .turn_ended = .{ .agent = "a4", .turn = "t1", .reason = "failed", .error_code = "failed.harness_exited" } }, 40, s);
    try record(&state, .{ .turn_ended = .{ .agent = "a5", .turn = "t1", .reason = "limit", .resets_at = "2026-11-07T15:00:00Z" } }, 50, s);
    try record(&state, .{ .request = .{ .agent = "a6", .request = "r1", .kind = "plan", .reason = "1. Add caps" } }, 60, s);
    try record(&state, .{ .request = .{ .agent = "a7", .request = "r1", .kind = "approval", .reason = "Edit proto.zig" } }, 70, s);

    const items = try inbox(s, &state, 100_000, false);
    const want = [_]struct { []const u8, Kind }{ .{ "a3", .approval }, .{ "a7", .approval }, .{ "a2", .question }, .{ "a6", .plan }, .{ "a4", .failed }, .{ "a5", .limit }, .{ "a1", .review } };
    try testing.expectEqual(want.len, items.len);
    for (want, items) |w, it| {
        try testing.expectEqualStrings(w[0], it.agent);
        try testing.expectEqual(w[1], it.kind);
    }
    try testing.expectEqualStrings("failed.harness_exited", items[4].reason);
    // A limit says when it resets.
    try testing.expectEqualStrings("2026-11-07T15:00:00Z", items[5].resets_at.?);
    try testing.expect(items[4].resets_at == null);
    try testing.expectEqual(@as(u64, 99), items[0].ageSeconds(100_000));
    try testing.expect(!items[6].kind.blocking());

    // Snooze a2's question: gone until it ends, then back.
    try testing.expectError(error.NotFound, decider.applyAt(&state, .{ .snooze = .{ .agent = "a2", .item = "r9", .until = 200_000 } }, 100_000, s));
    try testing.expectError(error.InvalidCommand, decider.applyAt(&state, .{ .snooze = .{ .agent = "a2", .item = "r1", .until = 100_000 } }, 100_000, s));
    _ = try decider.applyAt(&state, .{ .snooze = .{ .agent = "a2", .item = "r1", .until = 200_000 } }, 100_000, s);
    try testing.expectEqual(@as(usize, 6), (try inbox(s, &state, 150_000, false)).len);
    try testing.expectEqual(@as(usize, 7), (try inbox(s, &state, 150_000, true)).len);
    try testing.expectEqual(@as(usize, 7), (try inbox(s, &state, 200_000, false)).len);

    // A snoozed review that becomes a new review (another turn) shows again.
    // (a2's question is still snoozed at 150 s.)
    _ = try decider.applyAt(&state, .{ .snooze = .{ .agent = "a1", .item = "review", .until = 900_000 } }, 100_000, s);
    try testing.expectEqual(@as(usize, 5), (try inbox(s, &state, 150_000, false)).len);
    try record(&state, .{ .turn_started = .{ .agent = "a1", .turn = "t2", .origin = "user" } }, 110_000, s);
    try record(&state, .{ .turn_ended = .{ .agent = "a1", .turn = "t2", .reason = "completed" } }, 120_000, s);
    try testing.expectEqual(@as(usize, 6), (try inbox(s, &state, 150_000, false)).len);

    // Opening clears the review; answering clears the approval.
    _ = try decider.apply(&state, .{ .open = .{ .agent = "a1" } }, s);
    _ = try decider.apply(&state, .{ .answer = .{ .agent = "a3", .request = "r1", .decision = "allow_once" } }, s);
    try testing.expectEqual(@as(usize, 4), (try inbox(s, &state, 150_000, false)).len);
}

test "attention: an approval older than the timeout is denied with reason timeout" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try decider.applyAt(&state, .{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } }, 0, s);
    try record(&state, .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } }, 0, s);
    try record(&state, .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "rm -rf build", .answers = &.{ "allow_once", "deny" } } }, 1_000, s);
    try record(&state, .{ .request = .{ .agent = "a1", .request = "r2", .kind = "question", .reason = "which?" } }, 1_000, s);
    try record(&state, .{ .request = .{ .agent = "a1", .request = "r3", .kind = "approval", .reason = "zig build" } }, 5_000, s);

    // Nothing is old enough yet.
    try testing.expectEqual(@as(usize, 0), try decider.applyAt(&state, .{ .expire = .{ .approval_timeout_ms = 10_000 } }, 10_999, s));
    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&state, .{ .expire = .{ .approval_timeout_ms = 10_000 } }, 11_000, s, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("timeout", out.items[0].request_resolved.by);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"request\":\"r1\",\"decision\":\"deny\",\"reason\":\"timeout\",\"stale\":false}", out.items[1].effect_requested.payload);
    const c = change(&state, out.items[0]).?;
    try testing.expectEqualStrings("timeout", c.clear.by);
    try testing.expectEqual(Kind.approval, c.clear.kind);
    for (out.items) |e| try decider.evolve(&state, e);
    // The question never times out; the younger approval does later, and
    // with the question still open the agent stays needs_you.
    _ = try decider.applyAt(&state, .{ .expire = .{ .approval_timeout_ms = 10_000 } }, 15_000, s);
    const agent = state.agents.get("a1").?;
    try testing.expectEqual(@as(usize, 1), agent.requests.items.len);
    try testing.expectEqualStrings("r2", agent.requests.items[0].request);
    try testing.expectEqual(@import("agent.zig").State.needs_you, agent.state);
    try testing.expect(state.effects.contains("respond:a1:r3"));

    // When every live request times out, the agent runs again.
    try record(&state, .{ .request_resolved = .{ .agent = "a1", .request = "r2", .by = "harness" } }, 15_000, s);
    try record(&state, .{ .request = .{ .agent = "a1", .request = "r4", .kind = "approval", .reason = "a" } }, 16_000, s);
    try record(&state, .{ .request = .{ .agent = "a1", .request = "r5", .kind = "approval", .reason = "b" } }, 16_000, s);
    _ = try decider.applyAt(&state, .{ .expire = .{ .approval_timeout_ms = 10_000 } }, 26_000, s);
    try testing.expectEqual(@import("agent.zig").State.running, state.agents.get("a1").?.state);
}

test "attention: a handed-over agent's away item, replaced by newer reports, gone on take back" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try decider.applyAt(&state, .{ .create = .{ .agent = "a1", .title = "t", .harness = "claude-code", .workspace = "/w" } }, 0, s);
    // Only while handed over.
    try testing.expectError(error.InvalidTransition, decider.applyAt(&state, .{ .away = .{ .agent = "a1", .kind = "approval" } }, 1, s));
    try record(&state, .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } }, 1, s);
    try record(&state, .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } }, 2, s);
    _ = try decider.apply(&state, .{ .open = .{ .agent = "a1" } }, s);
    _ = try decider.applyAt(&state, .{ .takeover = .{ .agent = "a1", .pane = "tui:7" } }, 3, s);
    try testing.expectError(error.NotFound, decider.applyAt(&state, .{ .away = .{ .agent = "a9", .kind = "approval" } }, 4, s));
    try testing.expectError(error.InvalidCommand, decider.applyAt(&state, .{ .away = .{ .agent = "a1", .kind = "plan" } }, 4, s));

    // The root and the transcript survive each other's bindings.
    _ = try decider.apply(&state, .{ .takeover_split = .{ .agent = "a1", .root = .{ .pid = 8, .start = 9 } } }, s);
    _ = try decider.applyAt(&state, .{ .away = .{ .agent = "a1", .kind = "approval", .reason = "Bash wants git push", .transcript_ref = "/c/s1.jsonl" } }, 10, s);
    const x = state.agents.getPtr("a1").?;
    try testing.expectEqual(@as(i64, 8), x.pane_root.?.pid);
    try testing.expectEqualStrings("/c/s1.jsonl", x.transcript_ref.?);
    try testing.expectEqualStrings("tui:7", x.pane.?);
    var items = try inbox(s, &state, 11, false);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(Kind.approval, items[0].kind);
    try testing.expect(items[0].away);
    try testing.expectEqualStrings(away_item, items[0].item);
    try testing.expectEqual(@import("agent.zig").State.handed_over, x.state);

    // A new prompt in the same words shows again after a snooze.
    _ = try decider.applyAt(&state, .{ .snooze = .{ .agent = "a1", .item = away_item, .until = 1_000 } }, 11, s);
    try testing.expectEqual(@as(usize, 0), (try inbox(s, &state, 11, false)).len);
    try testing.expectEqual(@as(usize, 2), try decider.applyAt(&state, .{ .away = .{ .agent = "a1", .kind = "approval", .reason = "Bash wants git push", .transcript_ref = "/c/s1.jsonl" } }, 12, s));
    try testing.expectEqual(@as(usize, 1), (try inbox(s, &state, 12, false)).len);

    // A different report replaces it.
    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&state, .{ .away = .{ .agent = "a1", .kind = "review", .reason = "turn ended" } }, 13, s, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    const cleared = change(&state, out.items[0]).?;
    try testing.expectEqual(Kind.approval, cleared.clear.kind);
    try testing.expectEqualStrings("harness", cleared.clear.by);
    try testing.expectEqual(Kind.review, change(&state, out.items[1]).?.raise.kind);
    for (out.items) |e| try decider.evolve(&state, e);
    items = try inbox(s, &state, 14, false);
    try testing.expectEqual(Kind.review, items[0].kind);

    // A snoozed away item comes back when a newer report replaces it.
    _ = try decider.applyAt(&state, .{ .snooze = .{ .agent = "a1", .item = away_item, .until = 1_000 } }, 20, s);
    try testing.expectEqual(@as(usize, 0), (try inbox(s, &state, 21, false)).len);
    _ = try decider.applyAt(&state, .{ .away = .{ .agent = "a1", .kind = "question", .reason = "waiting" } }, 30, s);
    try testing.expectEqual(@as(usize, 1), (try inbox(s, &state, 31, false)).len);

    // Take back clears it (and says which kind went) with the state change.
    out = .empty;
    try decider.decide(&state, .{ .takeback = .{ .agent = "a1" } }, 40, s, &out);
    try testing.expectEqualStrings("takeback", change(&state, out.items[0]).?.clear.by);
    for (out.items) |e| try decider.evolve(&state, e);
    const y = state.agents.getPtr("a1").?;
    try testing.expect(y.away == null and y.pane_root == null and y.pane == null);
    try testing.expectEqualStrings("/c/s1.jsonl", y.transcript_ref.?);
    try testing.expectEqual(@as(usize, 0), (try inbox(s, &state, 41, false)).len);
}
