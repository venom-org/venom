//! The inbox verbs: `inbox.list`, `inbox.answer`, `inbox.snooze`. The inbox itself
//! is derived from the event log's state (`eventlog/attention.zig`), so
//! every client sees the same items, and an answer from any of them (CLI,
//! MCP, TUI) clears the item for all.
//!
//! - `list` (read): every item, blocking kinds first in urgency order
//!   (`approval`, `question`, `plan`, `failed`, `limit`), then `review`;
//!   oldest first within a kind. Each item carries the agent, kind, reason,
//!   age and the last turns of context (`context_turns` turns, each text
//!   cut to `context_max` bytes). Snoozed items only with `snoozed=true`.
//!   An `away` item waits in the harness's own TUI:
//!   it is answered there, so `answer` has no request for it.
//! - `answer` (write): answers a pending request (`approval`, `question`,
//!   `plan`) with an answer. `request` defaults to the
//!   agent's oldest pending request. The answer is resolved in the log and
//!   the `harness.respond` effect runs at once; its payload keeps `reason`
//!   and `args_json` for the adapter (deny reason, reject feedback, edited
//!   args, question picks). Approvals take `allow_once`, `allow_always`,
//!   `allow_edited` (needs `args`), `deny`, `cancel_turn`, limited to what
//!   the harness listed; plans `approve`, `reject`, `cancel_turn`; a
//!   question takes the reply text (an option label or free text) and,
//!   optionally, `args` with the picks per question (`{"q1":["Keep varint"]}`).
//! - `snooze` (write): hides one item for `duration` (default `"15m"`).
//!   `item` is a request id or `failed`, `limit`, `review`; it defaults to
//!   the agent's most urgent item.
//! - `batch` (write, `Y` / `N` on marked items): answers
//!   several approvals with one of `allow_once`, `allow_always`, `deny`
//!   (and one `reason`). Every item must be a pending approval and all must
//!   request the same grant; otherwise nothing is answered
//!   (`invalid_params.batch`).
//!
//! The inbox's approval keys map onto `answer`: `y` allow_once,
//! `a` allow_always, `e` allow_edited with `args` (the edited arguments),
//! `n` deny, `r` deny with `reason`. Plans: `y` approve, `n` reject with
//! `reason` as the feedback. Questions: the option label or text, with
//! `args` for the picks.
//!
//! "Allow always" (`eventlog/always.zig`): each approval shows its
//! narrowest grant (`grant`, e.g. `exec:zig`); `allow_always` records it for
//! the agent's workspace, and later approvals that need the same grant in
//! that workspace are allowed without asking, also after a restart. An
//! approval without a grant (no known tool call) can only be allowed once.
//! - `always.list` (read): the standing grants of the workspaces the caller
//!   may read, optionally of one `workspace`.
//! - `always.revoke` (write on the workspace): drops one (`not_found.grant`
//!   if there is none).
//!
//! Grants: `batch` checks each item like `answer`
//! (`write` on the agent, the self-approval rule). Recording an "always"
//! grant also needs `write` on the agent's workspace and is never allowed to
//! an agent's principal, whose own later requests the grant would answer
//! (`denied.self_approval`). These standing tool grants are not
//! caller grants: they say which harness tool calls venom allows without
//! asking, not which verbs a caller may use.
//!
//! Error codes (exit codes in parentheses): `not_found.agent` (3),
//! `not_found.request` (3), `not_found.item` (3), `conflict.request_resolved`
//! (5, already answered, here or by the harness), `invalid_params.answer`
//! (2), `invalid_params.duration` (2), `invalid_params.batch` (2),
//! `not_found.grant` (3).
//!
//! Grants: `list` shows only agents the caller may read;
//! `answer` and `snooze` need `write` on the agent, checked before the
//! lookup; and `answer` is never granted to the agent being answered or its
//! descendants (`denied.self_approval`).
const std = @import("std");
const proto = @import("proto");
const config = @import("config.zig");
const eventlog = @import("eventlog/root.zig");
const attention = eventlog.attention;
const Engine = eventlog.Engine;
const Agent = eventlog.decider.Agent;
const Principals = @import("principals.zig").Principals;
const readable = @import("principals.zig").readable;

/// Turns of context per item.
pub const context_turns = 2;
/// Bytes kept of each context text (cut on a UTF-8 boundary).
pub const context_max = 400;
pub const default_snooze = "15m";

pub const Inbox = struct {
    engine: *Engine,
    /// Per-agent caller identity for the self-approval rule.
    principals: ?*const Principals = null,

    list_: List = undefined,
    answer_: Answer = undefined,
    snooze_: Snooze = undefined,
    batch_: Batch = undefined,
    always_list_: AlwaysList = undefined,
    always_revoke_: AlwaysRevoke = undefined,

    /// The inbox and "allow always" bindings. `self` must not move
    /// afterwards.
    pub fn bindings(self: *Inbox) [6]proto.Binding {
        self.list_ = .{ .inbox = self };
        self.answer_ = .{ .inbox = self };
        self.snooze_ = .{ .inbox = self };
        self.batch_ = .{ .inbox = self };
        self.always_list_ = .{ .inbox = self };
        self.always_revoke_ = .{ .inbox = self };
        return .{
            .{ .verb = "inbox.list", .handler = proto.VerbHandler.typed(List.Params, &self.list_) },
            .{ .verb = "inbox.answer", .handler = proto.VerbHandler.typed(Answer.Params, &self.answer_) },
            .{ .verb = "inbox.snooze", .handler = proto.VerbHandler.typed(Snooze.Params, &self.snooze_) },
            .{ .verb = "inbox.batch", .handler = proto.VerbHandler.typed(Batch.Params, &self.batch_) },
            .{ .verb = "always.list", .handler = proto.VerbHandler.typed(AlwaysList.Params, &self.always_list_) },
            .{ .verb = "always.revoke", .handler = proto.VerbHandler.typed(AlwaysRevoke.Params, &self.always_revoke_) },
        };
    }

    fn state(self: *const Inbox) *const eventlog.State {
        return &self.engine.state;
    }

    fn now(self: *const Inbox) i64 {
        return self.engine.options.clock.now();
    }
};

/// Recording a standing grant (`allow_always`) on top of the answer's own
/// check: `write` on the agent's workspace, since the grant answers every
/// agent there, and never by an agent's principal, since it would answer
/// that agent's own later requests too (the
/// self-approval rule, `denied.self_approval`). false: the call has failed.
fn authorizeAlways(ib: *Inbox, c: *proto.Call, workspace: []const u8) !bool {
    if (!try c.authorize(.write, .{ .kind = "workspace", .id = workspace })) return false;
    const pr = ib.principals orelse return true;
    if (pr.agentOf(c.conn.identity.principal) == null) return true;
    try c.fail("denied.self_approval", "an agent cannot record an allow-always grant: it would answer its own requests", .{ .right = "write", .resource = try std.fmt.allocPrint(c.arena(), "workspace:{s}", .{workspace}) });
    return false;
}

fn notFound(c: *proto.Call, id: []const u8) !void {
    return c.fail("not_found.agent", "no such agent; see agent list", .{ .agent = id });
}

const Context = struct { turn: []const u8, text: []const u8 };

/// The text of the agent's last `context_turns` turns, oldest first.
fn context(a: std.mem.Allocator, agent: *const Agent) ![]const Context {
    const items = agent.transcript.items;
    var first: usize = items.len;
    var turns: usize = 0;
    while (first > 0 and turns < context_turns) {
        first -= 1;
        if (items[first] == .turn_started) turns += 1;
    }
    var out: std.ArrayList(Context) = .empty;
    for (items[first..]) |e| if (e == .text) try out.append(a, .{ .turn = e.text.turn, .text = cut(e.text.text, context_max) });
    return out.items;
}

fn cut(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// One inbox item as `inbox.list` shows it. The first four members are
/// agent, kind, age and reason.
const Shown = struct {
    agent: []const u8,
    kind: []const u8,
    age_s: u64,
    reason: []const u8,
    item: []const u8,
    request: ?[]const u8,
    blocking: bool,
    level: []const u8,
    title: []const u8,
    state: []const u8,
    stale: bool,
    answers: []const []const u8,
    grant: ?[]const u8,
    outside_scope: bool,
    options: []const eventlog.events.QuestionOptions,
    snoozed_until: ?i64,
    resets_at: ?[]const u8,
    away: bool,
    context: []const Context,
};

/// `inbox.list` (read).
pub const List = struct {
    inbox: *Inbox,
    pub const Params = struct { snoozed: bool = false };

    pub fn call(self: *List, c: *proto.Call, p: Params) anyerror!void {
        const a = c.arena();
        const st = self.inbox.state();
        const now = self.inbox.now();
        const items = try attention.inbox(a, st, now, p.snoozed);
        const shown = try a.alloc(Shown, items.len);
        var n: usize = 0;
        for (items) |it| {
            if (!readable(c, .{ .kind = "agent", .id = it.agent })) continue;
            const agent = st.agents.getPtr(it.agent).?;
            const out = &shown[n];
            n += 1;
            out.* = .{
                .agent = it.agent,
                .kind = @tagName(it.kind),
                .age_s = it.ageSeconds(now),
                .reason = it.reason,
                .item = it.item,
                .request = it.request,
                .blocking = it.kind.blocking(),
                .level = it.kind.level(),
                .title = agent.title,
                .state = @tagName(agent.state),
                .stale = it.stale,
                .answers = it.answers,
                .grant = it.grant,
                .outside_scope = it.outside_scope,
                .options = it.options,
                .snoozed_until = it.snoozed_until,
                .resets_at = it.resets_at,
                .away = it.away,
                .context = try context(a, agent),
            };
        }
        try c.ok(.{ .items = shown[0..n] });
    }
};

const approval_answers = [_][]const u8{ "allow_once", "allow_always", "allow_edited", "deny", "cancel_turn" };
const plan_answers = [_][]const u8{ "approve", "reject", "cancel_turn" };

/// What an agent may answer: no
/// allow, no plan approval. Only a person can let another agent do more; an
/// agent may refuse, or cancel the turn. The request stays pending otherwise.
/// A token an agent issued, or a call below its harness, counts as the agent.
/// Questions carry no permission, so an agent may answer them.
fn agentMayAnswer(kind: attention.Kind, answer: []const u8) bool {
    return switch (kind) {
        .approval => std.mem.eql(u8, answer, "deny") or std.mem.eql(u8, answer, "cancel_turn"),
        .plan => std.mem.eql(u8, answer, "reject") or std.mem.eql(u8, answer, "cancel_turn"),
        else => true,
    };
}

fn callerIsAgent(ib: *const Inbox, c: *const proto.Call) bool {
    const pr = ib.principals orelse return false;
    return pr.callerAgent(c.conn.identity) != null;
}

fn oneOf(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// Why `picks` (`{"q1":["label"]}`) is not an answer to a question asked with
/// `options`, or null. Fail closed: a question the harness takes a typed
/// answer for (`free_text`) accepts any one string; any other takes one of
/// its kept labels, and one with no kept label (cut by the bounds, or asked
/// without options) cannot be answered here at all. A label left out
/// (`labels_omitted`) is not accepted either. Only a harness that listed no
/// options at all (none stored) is taken at its word. An id that is not
/// stored is refused.
fn badPick(options: []const eventlog.events.QuestionOptions, picks: std.json.ObjectMap) ?[]const u8 {
    if (options.len == 0) return null;
    var it = picks.iterator();
    while (it.next()) |e| {
        const q = for (options) |o| {
            if (std.mem.eql(u8, o.id, e.key_ptr.*)) break o;
        } else return "no such question id";
        switch (e.value_ptr.*) {
            .string => |l| if (badLabel(q, l)) |why| return why,
            .array => |list| {
                if (list.items.len == 0) return "a label or a list of labels";
                for (list.items) |x| {
                    if (x != .string) return "a label or a list of labels";
                    if (badLabel(q, x.string)) |why| return why;
                }
            },
            else => return "a label or a list of labels",
        }
    }
    return null;
}

const in_harness = "this question cannot be answered here (its options were cut); answer it in the harness, or cancel the turn";

/// Why `l` cannot answer `q`, or null.
fn badLabel(q: eventlog.events.QuestionOptions, l: []const u8) ?[]const u8 {
    if (q.free_text) return null;
    if (q.labels.len == 0) return in_harness;
    if (!oneOf(q.labels, l)) return "not an option of that question";
    return null;
}

/// Why a plain `answer` (no `args`) cannot answer every question: it reaches
/// each of them, so every question must take it (see `badPick`).
fn badPlain(options: []const eventlog.events.QuestionOptions, answer: []const u8) ?[]const u8 {
    for (options) |q| if (badLabel(q, answer)) |why| return why;
    return null;
}

/// `inbox.answer` (write).
pub const Answer = struct {
    inbox: *Inbox,
    pub const Params = struct {
        agent: []const u8,
        answer: []const u8,
        request: ?[]const u8 = null,
        reason: ?[]const u8 = null,
        args: ?[]const u8 = null,
    };

    pub fn call(self: *Answer, c: *proto.Call, p: Params) anyerror!void {
        const ib = self.inbox;
        if (ib.principals) |pr| {
            if (!try pr.authorizeAnswer(c, p.agent)) return;
        } else if (!try c.authorize(.write, .{ .kind = "agent", .id = p.agent })) return;
        const agent = ib.state().agents.getPtr(p.agent) orelse return notFound(c, p.agent);
        const id = p.request orelse (if (agent.requests.items.len > 0) agent.requests.items[0].request else return c.fail("not_found.request", "the agent has no pending request", .{ .agent = p.agent }));
        const i = agent.pending(id) orelse {
            if (oneOf(agent.resolved.items, id)) return c.fail("conflict.request_resolved", "the request was already answered or withdrawn", .{ .agent = p.agent, .request = id });
            return c.fail("not_found.request", "no such pending request; see inbox list", .{ .agent = p.agent, .request = id });
        };
        const asked = agent.requests.items[i];
        const kind = attention.Kind.ofRequest(asked.kind);
        const ok = switch (kind) {
            .approval => oneOf(&approval_answers, p.answer) and (asked.answers.len == 0 or oneOf(asked.answers, p.answer)) and
                (!std.mem.eql(u8, p.answer, "allow_edited") or p.args != null),
            .plan => oneOf(&plan_answers, p.answer),
            else => std.mem.trim(u8, p.answer, " \t\r\n").len > 0,
        };
        if (!ok) {
            const choices: []const []const u8 = switch (kind) {
                .approval => if (asked.answers.len > 0) asked.answers else &approval_answers,
                .plan => &plan_answers,
                else => &.{},
            };
            return c.fail("invalid_params.answer", "this answer does not fit the request", .{ .param = "answer", .kind = @tagName(kind), .answers = choices });
        }
        if (callerIsAgent(ib, c) and !agentMayAnswer(kind, p.answer))
            return c.fail("denied.agent_approval", "only a person can allow this; an agent may deny it or cancel the turn. It stays pending", .{ .agent = p.agent, .request = id, .answer = p.answer });
        if (kind == .question and p.args == null) if (badPlain(asked.options orelse &.{}, p.answer)) |why|
            return c.fail("invalid_params.answer", "a question's answer is one of the options it was asked with", .{ .param = "answer", .why = why });
        if (p.args) |args| {
            const v = std.json.parseFromSliceLeaky(std.json.Value, c.arena(), args, .{}) catch return c.fail("invalid_params.answer", "args must be a JSON object", .{ .param = "args" });
            if (v != .object) return c.fail("invalid_params.answer", "args must be a JSON object", .{ .param = "args" });
            if (kind == .question) if (badPick(asked.options orelse &.{}, v.object)) |why|
                return c.fail("invalid_params.answer", "a question's args pick one of the options it was asked with, by question id", .{ .param = "args", .why = why });
        }
        if (kind == .approval and std.mem.eql(u8, p.answer, "allow_always")) {
            if (asked.grant == null)
                return c.fail("invalid_params.answer", "this approval has no grant to keep (no tool call, or a command that was cut short); allow it once", .{ .param = "answer", .answers = &[_][]const u8{ "allow_once", "deny" } });
            if (!try authorizeAlways(ib, c, agent.workspace)) return;
        }
        // The id must outlive the state change below.
        const request = try c.arena().dupe(u8, id);
        _ = ib.engine.submit(.{ .answer = .{ .agent = p.agent, .request = request, .decision = p.answer, .reason = p.reason, .args_json = p.args } }) catch |err| switch (err) {
            error.Conflict => return c.fail("conflict.request_resolved", "the request was already answered", .{ .agent = p.agent, .request = request }),
            error.InvalidCommand => return c.fail("invalid_params.answer", "this answer does not fit the request", .{ .param = "answer" }),
            error.NotFound => return c.fail("not_found.request", "no such pending request; see inbox list", .{ .agent = p.agent, .request = request }),
            else => return err,
        };
        // Deliver now, so the harness hears it in this reactor turn.
        _ = try ib.engine.runEffects();
        try c.ok(.{ .agent = p.agent, .request = request, .answer = p.answer, .state = @tagName(ib.state().agents.getPtr(p.agent).?.state) });
    }
};

/// `inbox.snooze` (write).
pub const Snooze = struct {
    inbox: *Inbox,
    pub const Params = struct { agent: []const u8, item: ?[]const u8 = null, duration: []const u8 = default_snooze };

    pub fn call(self: *Snooze, c: *proto.Call, p: Params) anyerror!void {
        const ib = self.inbox;
        const a = c.arena();
        if (!try c.authorize(.write, .{ .kind = "agent", .id = p.agent })) return;
        const agent = ib.state().agents.getPtr(p.agent) orelse return notFound(c, p.agent);
        const ms = config.Duration.parseMs(p.duration) catch return c.fail("invalid_params.duration", "a duration such as \"15m\" or \"2h\"", .{ .param = "duration", .value = p.duration });
        const now = ib.now();
        const item: []const u8 = p.item orelse blk: {
            var list: std.ArrayList(attention.Item) = .empty;
            try attention.agentItems(a, p.agent, agent, now, &list);
            if (list.items.len == 0) return c.fail("not_found.item", "the agent has nothing in the inbox", .{ .agent = p.agent });
            std.mem.sort(attention.Item, list.items, {}, attention.Item.lessThan);
            break :blk try a.dupe(u8, list.items[0].item);
        };
        const until = std.math.add(i64, now, std.math.cast(i64, ms) orelse std.math.maxInt(i64)) catch std.math.maxInt(i64);
        _ = ib.engine.submit(.{ .snooze = .{ .agent = p.agent, .item = item, .until = until } }) catch |err| switch (err) {
            error.NotFound => return c.fail("not_found.item", "no such inbox item for this agent; see inbox list", .{ .agent = p.agent, .item = item }),
            else => return err,
        };
        try c.ok(.{ .agent = p.agent, .item = item, .until = until });
    }
};

/// `inbox.batch` (write): `Y` / `N` on marked approvals.
pub const Batch = struct {
    inbox: *Inbox,
    pub const Item = struct { agent: []const u8, request: []const u8 };
    pub const Params = struct {
        items: []const Item,
        answer: []const u8,
        reason: ?[]const u8 = null,
    };
    const answers = [_][]const u8{ "allow_once", "allow_always", "deny" };
    const Answered = struct { agent: []const u8, request: []const u8, state: []const u8 };

    pub fn call(self: *Batch, c: *proto.Call, p: Params) anyerror!void {
        const ib = self.inbox;
        const a = c.arena();
        if (!oneOf(&answers, p.answer)) return c.fail("invalid_params.answer", "a batch answer is allow_once, allow_always or deny", .{ .param = "answer", .answers = &answers });
        if (p.items.len == 0) return c.fail("invalid_params.batch", "mark at least one approval", .{ .param = "items" });
        if (callerIsAgent(ib, c) and !agentMayAnswer(.approval, p.answer))
            return c.fail("denied.agent_approval", "only a person can allow this; an agent may deny it or cancel the turn. They stay pending", .{ .answer = p.answer });
        // Check everything first: a batch is answered whole or not at all.
        var grant: ?[]const u8 = null;
        var grants: std.ArrayList([]const u8) = .empty;
        for (p.items, 0..) |it, n| {
            for (p.items[0..n]) |prev| if (std.mem.eql(u8, prev.agent, it.agent) and std.mem.eql(u8, prev.request, it.request))
                return c.fail("invalid_params.batch", "an approval is marked twice", .{ .param = "items", .agent = it.agent, .request = it.request });
            if (ib.principals) |pr| {
                if (!try pr.authorizeAnswer(c, it.agent)) return;
            } else if (!try c.authorize(.write, .{ .kind = "agent", .id = it.agent })) return;
            const agent = ib.state().agents.getPtr(it.agent) orelse return notFound(c, it.agent);
            if (std.mem.eql(u8, p.answer, "allow_always") and !try authorizeAlways(ib, c, agent.workspace)) return;
            const i = agent.pending(it.request) orelse {
                if (oneOf(agent.resolved.items, it.request)) return c.fail("conflict.request_resolved", "the request was already answered or withdrawn", .{ .agent = it.agent, .request = it.request });
                return c.fail("not_found.request", "no such pending request; see inbox list", .{ .agent = it.agent, .request = it.request });
            };
            const asked = agent.requests.items[i];
            if (attention.Kind.ofRequest(asked.kind) != .approval) return c.fail("invalid_params.batch", "only approvals can be answered in a batch", .{ .param = "items", .agent = it.agent, .request = it.request, .kind = asked.kind });
            if (asked.answers.len > 0 and !oneOf(asked.answers, p.answer)) return c.fail("invalid_params.answer", "this answer does not fit the request", .{ .param = "answer", .agent = it.agent, .request = it.request, .answers = asked.answers });
            const g = asked.grant orelse "";
            if (!oneOf(grants.items, g)) try grants.append(a, try a.dupe(u8, g));
            if (n == 0) grant = asked.grant;
        }
        if (grants.items.len > 1 or grant == null) return c.fail("invalid_params.batch", "a batch needs approvals that request the same grant", .{ .param = "items", .grants = grants.items });
        const answered = try a.alloc(Answered, p.items.len);
        for (p.items, answered) |it, *out| {
            const request = try a.dupe(u8, it.request);
            _ = ib.engine.submit(.{ .answer = .{ .agent = it.agent, .request = request, .decision = p.answer, .reason = p.reason } }) catch |err| switch (err) {
                error.Conflict => return c.fail("conflict.request_resolved", "the request was already answered", .{ .agent = it.agent, .request = request }),
                error.InvalidCommand => return c.fail("invalid_params.answer", "this answer does not fit the request", .{ .param = "answer" }),
                error.NotFound => return c.fail("not_found.request", "no such pending request; see inbox list", .{ .agent = it.agent, .request = request }),
                else => return err,
            };
            out.* = .{ .agent = it.agent, .request = request, .state = "" };
        }
        _ = try ib.engine.runEffects();
        for (answered) |*out| out.state = @tagName(ib.state().agents.getPtr(out.agent).?.state);
        try c.ok(.{ .answer = p.answer, .grant = try a.dupe(u8, grant.?), .answered = answered });
    }
};

/// `always.list` (read): the standing "allow always" grants.
pub const AlwaysList = struct {
    inbox: *Inbox,
    pub const Params = struct { workspace: ?[]const u8 = null };

    pub fn call(self: *AlwaysList, c: *proto.Call, p: Params) anyerror!void {
        var out: std.ArrayList(eventlog.always.Standing) = .empty;
        for (self.inbox.state().standing.items) |s| {
            if (p.workspace) |w| if (!std.mem.eql(u8, w, s.workspace)) continue;
            if (!readable(c, .{ .kind = "workspace", .id = s.workspace })) continue;
            try out.append(c.arena(), s);
        }
        try c.ok(.{ .grants = out.items });
    }
};

/// `always.revoke` (write): drops one standing grant.
pub const AlwaysRevoke = struct {
    inbox: *Inbox,
    pub const Params = struct { workspace: []const u8, grant: []const u8 };

    pub fn call(self: *AlwaysRevoke, c: *proto.Call, p: Params) anyerror!void {
        if (!try c.authorize(.write, .{ .kind = "workspace", .id = p.workspace })) return;
        _ = self.inbox.engine.submit(.{ .revoke_always = .{ .workspace = p.workspace, .grant = p.grant } }) catch |err| switch (err) {
            error.NotFound => return c.fail("not_found.grant", "no such standing grant; see always list", .{ .workspace = p.workspace, .grant = p.grant }),
            else => return err,
        };
        try c.ok(.{ .workspace = p.workspace, .grant = p.grant });
    }
};

const testing = std.testing;

test "inbox: context keeps the last turns' text, cut on a UTF-8 boundary" {
    try testing.expectEqualStrings("ab", cut("ab", 4));
    try testing.expectEqualStrings("a", cut("a\xc3\xa9", 2));
}

test "badPlain: fail closed, a plain answer must fit every question" {
    const E = eventlog.events.QuestionOptions;
    const strict_q: E = .{ .id = "q1", .labels = &.{ "Yes", "No" } };
    const free_q: E = .{ .id = "q2", .labels = &.{"a"}, .free_text = true };
    const cut_q: E = .{ .id = "q3", .labels = &.{"a"}, .labels_omitted = true };
    const bare_q: E = .{ .id = "q4", .labels_omitted = true };
    const bare_free: E = .{ .id = "q5", .labels_omitted = true, .free_text = true };
    try testing.expect(badPlain(&.{strict_q}, "Maybe") != null);
    try testing.expect(badPlain(&.{strict_q}, "Yes") == null);
    try testing.expect(badPlain(&.{ strict_q, free_q, bare_free }, "No") == null);
    try testing.expect(badPlain(&.{ strict_q, free_q }, "typed") != null);
    try testing.expect(badPlain(&.{ free_q, bare_free }, "typed") == null);
    // Labels left out do not relax the rule.
    try testing.expect(badPlain(&.{cut_q}, "a") == null);
    try testing.expect(badPlain(&.{cut_q}, "the omitted label") != null);
    // A bare non-free_text question (also the marker for questions past the
    // eighth) refuses every plain answer.
    try testing.expect(badPlain(&.{ free_q, bare_q }, "typed") != null);
    try testing.expect(badPlain(&.{}, "typed") == null);
}

test "badPick: labels_omitted still takes only kept labels; bare and past-the-bound questions refuse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const E = eventlog.events.QuestionOptions;
    const opts = [_]E{
        .{ .id = "q1", .labels = &.{"Yes"}, .labels_omitted = true },
        .{ .id = "q2", .labels_omitted = true },
        .{ .id = "q3", .labels_omitted = true, .free_text = true },
    };
    const J = std.json.parseFromSliceLeaky;
    const ok = try J(std.json.Value, a, "{\"q1\":[\"Yes\"],\"q3\":[\"typed\"]}", .{});
    try testing.expect(badPick(&opts, ok.object) == null);
    for ([_][]const u8{
        "{\"q1\":[\"an omitted label\"]}",
        "{\"q2\":[\"anything\"]}",
        "{\"q2\":\"anything\"}",
        "{\"q9\":[\"x\"]}",
    }) |src| {
        const v = try J(std.json.Value, a, src, .{});
        try testing.expect(badPick(&opts, v.object) != null);
    }
}
