//! One-shot decisions for stale requests:
//! the pure part.
//!
//! A request is **stale** when the harness process that asked is gone: a
//! daemon start (`daemon.started`) or a harness crash (`turn.ended` with
//! `failed.harness_exited`; `processGone`). The call did not run, the
//! request stays in the inbox, and no v1 adapter can deliver an answer to a
//! new process (`durable_requests = false`).
//!
//! Answering it records a **one-shot decision** (`decision.recorded`) keyed
//! by `(kind, normalized args, cwd)` and queues the usual `harness.respond`
//! effect with `resume: true`, whose executor reattaches and sends
//! `harness.resume_prompt` (`Host.resumeStale`). `cancel_turn` records
//! nothing and resumes nothing: there is no turn left to cancel.
//!
//! The decision belongs to the agent's next turn (`turn`: set when that turn
//! starts, or at once if one is already open):
//!
//! - when the harness asks for the matching call in that turn, the new
//!   request is answered in the commit that logs it, through the same
//!   `harness.respond` effect as a human answer, and the decision is closed
//!   (`decision.closed {by: consumed}`). No attention is raised, as for
//!   "allow always"; `request.one_shot` and `request.resolved.one_shot` name the
//!   stale request that decided it;
//! - when that turn ends first, the decision is closed (`decision.closed
//!   {by: expired}`), in the commit of the `turn.ended`.
//!
//! **A decision applies only to the exact input the human approved.** The
//! key is the call's tool kind and name and the digest of its whole input
//! (`input_digest`, `events.inputDigest`, from the adapter). The human saw
//! that input: the plan, the questions, the edit, the MCP arguments. When the
//! adapter does not have the input there is no key: the answer still resumes
//! the agent, and the call is asked again. So is a call whose input differs in
//! any way, including a description the model reworded.
//!
//! Each decision answers one request. Two stale requests with one key that
//! were answered alike answer two re-asks. Answered differently, venom cannot
//! tell which is which, so the call is asked again. A harness that no longer
//! offers the decided answer for the new request is asked as usual.
//!
//! A resume that fails (`Host.resumeStale`, an effect that completes with
//! `ok = false`) closes the decision (`by: resume_failed`) and brings the
//! request back (`request.reopened`). A daemon start closes a decision whose
//! resume was sent but whose turn never began, so it cannot approve some much
//! later turn.
//!
//! **An answer the crash beat**. A live request answered just
//! before its harness process dies is resolved, but its `harness.respond`
//! finds the process gone (`failed.harness_exited`, or
//! `conflict.request_resolved` once the dead turn dropped its requests;
//! `undelivered`). It is handled like a stale answer: a one-shot decision
//! and a resume, with the request kept in the effect's payload (`asked`, and
//! its `turn`). This happens once that turn has ended with the process gone
//! (`gone`: `failed.harness_exited` or a daemon restart), whichever comes
//! last: the failed delivery (`deliveryFailed`) or the `turn.ended`
//! (`undeliveredAt`). A turn that ends any other way keeps the old
//! behavior: the answer is dropped. The human is not asked twice.
const std = @import("std");
const ev = @import("events.zig");
const decider = @import("decider.zig");
const always = @import("always.zig");
const Event = ev.Event;
const Agent = decider.Agent;
const State = decider.State;

pub const Decision = struct {
    /// The stale request that was answered.
    request: []const u8,
    kind: []const u8,
    key: []const u8,
    cwd: []const u8,
    decision: []const u8,
    reason: ?[]const u8 = null,
    args_json: ?[]const u8 = null,
    at: i64 = 0,
    /// The answer's `harness.respond` effect.
    effect: []const u8 = "",
    /// The turn it applies to; null until the agent's next turn starts.
    turn: ?[]const u8 = null,
};

/// The failure code of a turn whose harness process went away with
/// requests pending: they stay, as stale inbox items.
pub const process_gone_code = "failed.harness_exited";

pub fn processGone(t: ev.TurnEnded) bool {
    const code = t.error_code orelse return false;
    return std.mem.eql(u8, code, process_gone_code);
}

/// A turn whose harness process went away: a crash or a daemon restart.
pub fn gone(t: ev.TurnEnded) bool {
    const code = t.error_code orelse return false;
    return processGone(t) or std.mem.eql(u8, code, "failed.daemon_restart");
}

/// The `harness.respond` details of an answer whose process was gone.
pub fn undelivered(detail: []const u8) bool {
    return std.mem.eql(u8, detail, process_gone_code) or std.mem.eql(u8, detail, "conflict.request_resolved");
}

/// What a live answer's `harness.respond` payload keeps (`decider.Live`).
const LivePayload = struct {
    agent: []const u8,
    request: []const u8,
    decision: []const u8,
    reason: ?[]const u8 = null,
    args_json: ?[]const u8 = null,
    stale: bool = false,
    turn: ?[]const u8 = null,
    asked: ?decider.Request = null,
};

fn livePayload(a: std.mem.Allocator, effect: *const decider.Effect) !?LivePayload {
    if (!std.mem.eql(u8, effect.kind, "harness.respond")) return null;
    // Cheap: only a live answer's payload has the request it answered.
    if (std.mem.indexOf(u8, effect.payload, "\"asked\":") == null) return null;
    const p = std.json.parseFromSliceLeaky(LivePayload, a, effect.payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (p.stale or p.turn == null or p.asked == null) return null;
    return p;
}

/// How `turn` of `agent` ended, if it did.
fn endOf(agent: *const Agent, turn: []const u8) ?ev.TurnEnded {
    var i = agent.transcript.items.len;
    while (i > 0) {
        i -= 1;
        const e = agent.transcript.items[i];
        if (e == .turn_ended and std.mem.eql(u8, e.turn_ended.turn, turn)) return e.turn_ended;
    }
    return null;
}

/// A failed `harness.respond` effect (`effect`, `detail`): if it was a live
/// answer whose turn already ended with the process gone, the answer becomes
/// a one-shot decision and a resume (`lost`). While that turn is still open
/// its `turn.ended` decides (`undeliveredAt`).
pub fn deliveryFailed(state: *const State, effect: *const decider.Effect, detail: []const u8, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (!undelivered(detail)) return;
    const p = try livePayload(a, effect) orelse return;
    const agent = state.agents.getPtr(p.agent) orelse return;
    const end = endOf(agent, p.turn.?) orelse return;
    if (!gone(end)) return;
    try lost(state, agent, p, now, a, out);
}

/// `turn` of agent `id` is ending with its process gone: the answers given in
/// it whose delivery already failed become one-shot decisions (`lost`). Call
/// it after the `turn.ended`, so the decisions wait for the next turn.
pub fn undeliveredAt(state: *const State, id: []const u8, turn: []const u8, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    const agent = state.agents.getPtr(id) orelse return;
    for (state.effects.values()) |*effect| {
        if (!effect.done or effect.ok or !undelivered(effect.detail)) continue;
        const p = try livePayload(a, effect) orelse continue;
        if (!std.mem.eql(u8, p.agent, id) or !std.mem.eql(u8, p.turn.?, turn)) continue;
        try lost(state, agent, p, now, a, out);
    }
}

/// The answer `p` never reached the harness: as if it answered the request
/// once stale (`record`, then a resuming `harness.respond`). `cancel_turn`
/// has nothing left to cancel or resume.
fn lost(state: *const State, agent: *const Agent, p: LivePayload, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (!resumes(p.decision)) return;
    var asked = p.asked.?;
    asked.stale = true;
    const ans: @FieldType(ev.Command, "answer") = .{ .agent = p.agent, .request = p.request, .decision = p.decision, .reason = p.reason, .args_json = p.args_json };
    try record(state, agent, p.agent, asked, ans, now, a, out);
    decider.queueRespond(state, ans, asked, null, a, out) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
}

/// What the `request` record keeps of the tool call `call`, if it is known.
pub fn toolOf(agent: *const Agent, call: ?[]const u8) ?ev.RequestTool {
    const id = call orelse return null;
    var i = agent.transcript.items.len;
    while (i > 0) {
        i -= 1;
        const e = agent.transcript.items[i];
        if (e == .tool_started and std.mem.eql(u8, e.tool_started.call, id)) {
            const t = e.tool_started;
            return .{ .kind = t.kind, .name = t.name, .title = t.title, .args = t.args };
        }
    }
    return null;
}

/// The normalized args of a request, as canonical JSON in `a`. Null when its
/// whole input is not known.
pub fn key(a: std.mem.Allocator, tool: ?ev.RequestTool, input_digest: ?[]const u8) !?[]const u8 {
    const digest = input_digest orelse return null;
    const t = tool orelse return try std.json.Stringify.valueAlloc(a, .{ .input = digest }, .{});
    return try std.json.Stringify.valueAlloc(a, .{ .kind = t.kind, .name = t.name, .input = digest }, .{});
}

pub fn cwdOf(agent: *const Agent) []const u8 {
    return agent.cwd orelse agent.workspace;
}

/// The `decision.recorded` an answer to the stale request `asked` adds.
pub fn record(state: *const State, agent: *const Agent, id: []const u8, asked: decider.Request, ans: @FieldType(ev.Command, "answer"), now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (!resumes(ans.decision)) return;
    const k = try key(a, asked.tool, asked.input_digest) orelse return;
    const effect = try decider.respondKey(state, id, asked.request, true, a);
    try out.append(a, .{ .decision_recorded = .{ .agent = id, .request = asked.request, .kind = asked.kind, .key = k, .cwd = cwdOf(agent), .decision = ans.decision, .reason = ans.reason, .args_json = ans.args_json, .at = now, .effect = effect } });
}

/// Whether answering a stale request with `decision` resumes the agent.
pub fn resumes(decision: []const u8) bool {
    return !std.mem.eql(u8, decision, "cancel_turn");
}

/// The open decision that answers new request `r` of `agent`, if any: the
/// oldest match. Matches that were answered differently are ambiguous: none.
pub fn matching(a: std.mem.Allocator, agent: *const Agent, r: ev.Request) !?*const Decision {
    const open = agent.open_turn orelse return null;
    if (agent.decisions.items.len == 0) return null;
    const k = try key(a, r.tool, r.input_digest) orelse return null;
    var found: ?*const Decision = null;
    for (agent.decisions.items) |*d| {
        const turn = d.turn orelse continue;
        if (!std.mem.eql(u8, turn, open)) continue;
        if (!std.mem.eql(u8, d.kind, r.kind) or !std.mem.eql(u8, d.key, k) or !std.mem.eql(u8, d.cwd, cwdOf(agent))) continue;
        if (found) |first| {
            if (!sameAnswer(first, d)) return null;
        } else found = d;
    }
    const d = found orelse return null;
    if (r.answers.len > 0) for (r.answers) |x| {
        if (std.mem.eql(u8, x, d.decision)) break;
    } else return null;
    return d;
}

fn sameAnswer(l: *const Decision, r: *const Decision) bool {
    return std.mem.eql(u8, l.decision, r.decision) and optEql(l.reason, r.reason) and optEql(l.args_json, r.args_json);
}

fn optEql(l: ?[]const u8, r: ?[]const u8) bool {
    if (l == null or r == null) return l == null and r == null;
    return std.mem.eql(u8, l.?, r.?);
}

/// A failed `harness.respond` effect (`effect`): if it was a stale request's
/// resume, closes its decision and brings the request back.
pub fn resumeFailed(state: *const State, effect: *const decider.Effect, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (!std.mem.eql(u8, effect.kind, "harness.respond")) return;
    const P = struct { agent: []const u8, @"resume": bool = false, stale_request: ?decider.Request = null };
    const p = std.json.parseFromSliceLeaky(P, a, effect.payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (!p.@"resume") return;
    const r = p.stale_request orelse return;
    const agent = state.agents.getPtr(p.agent) orelse return;
    for (agent.decisions.items) |d| if (std.mem.eql(u8, d.effect, effect.key)) {
        try out.append(a, .{ .decision_closed = .{ .agent = p.agent, .request = d.request, .by = "resume_failed" } });
    };
    try out.append(a, .{ .request_reopened = .{ .agent = p.agent, .request = r.request, .kind = r.kind, .reason = r.reason, .call = r.call, .answers = r.answers, .at = r.at, .grant = r.grant, .outside_scope = r.outside_scope, .tool = r.tool, .input_digest = r.input_digest, .options = r.options } });
}

/// At a daemon start: a decision waiting for a turn whose resume already ran
/// will not get that turn. One whose effect is still pending will: it runs
/// again after this start.
pub fn expireUnstarted(state: *const State, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    for (state.agents.keys(), state.agents.values()) |id, *agent| for (agent.decisions.items) |d| {
        if (d.turn != null) continue;
        const effect = state.effects.get(d.effect);
        if (effect == null or effect.?.done) try out.append(a, .{ .decision_closed = .{ .agent = id, .request = d.request, .by = "expired" } });
    };
}

/// Closes the decisions of `turn`, which is ending.
pub fn expire(agent: *const Agent, id: []const u8, turn: []const u8, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    for (agent.decisions.items) |d| {
        const t = d.turn orelse continue;
        if (std.mem.eql(u8, t, turn)) try out.append(a, .{ .decision_closed = .{ .agent = id, .request = d.request, .by = "expired" } });
    }
}

/// The decisions waiting for the agent's next turn apply to `turn` (owned
/// by the state).
pub fn arm(agent: *Agent, turn: []const u8) void {
    for (agent.decisions.items) |*d| if (d.turn == null) {
        d.turn = turn;
    };
}

pub fn evolve(state: *State, event: Event) error{OutOfMemory}!void {
    const a = state.arena.allocator();
    switch (event) {
        .decision_recorded => {
            const d = (try event.dupe(a)).decision_recorded;
            const agent = state.agents.getPtr(d.agent) orelse return;
            try agent.decisions.append(a, .{ .request = d.request, .kind = d.kind, .key = d.key, .cwd = d.cwd, .decision = d.decision, .reason = d.reason, .args_json = d.args_json, .at = d.at, .effect = d.effect, .turn = agent.open_turn });
        },
        .request_reopened => {
            const r = (try event.dupe(a)).request_reopened;
            const agent = state.agents.getPtr(r.agent) orelse return;
            if (agent.pending(r.request) != null) return;
            try agent.requests.append(a, .{ .request = r.request, .kind = r.kind, .reason = r.reason, .call = r.call, .answers = r.answers, .stale = true, .at = r.at, .grant = r.grant, .outside_scope = r.outside_scope, .tool = r.tool, .input_digest = r.input_digest, .options = r.options });
            for (agent.resolved.items, 0..) |id, i| if (std.mem.eql(u8, id, r.request)) {
                _ = agent.resolved.orderedRemove(i);
                break;
            };
        },
        .decision_closed => |c| if (state.agents.getPtr(c.agent)) |agent| {
            for (agent.decisions.items, 0..) |d, i| if (std.mem.eql(u8, d.request, c.request)) {
                _ = agent.decisions.orderedRemove(i);
                return;
            };
        },
        else => unreachable,
    }
}

const testing = std.testing;
const AgentState = @import("agent.zig").State;

const Fx = struct {
    state: State,
    scratch: std.heap.ArenaAllocator,

    fn init() Fx {
        return .{ .state = State.init(testing.allocator), .scratch = .init(testing.allocator) };
    }
    fn deinit(self: *Fx) void {
        self.scratch.deinit();
        self.state.deinit();
    }
    fn s(self: *Fx) std.mem.Allocator {
        return self.scratch.allocator();
    }
    fn apply(self: *Fx, cmd: ev.Command) !void {
        _ = try decider.apply(&self.state, cmd, self.s());
    }
    fn agent(self: *Fx) *Agent {
        return self.state.agents.getPtr("a1").?;
    }
    fn turn(self: *Fx, id: []const u8) !void {
        try self.apply(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = id, .origin = "user" } } });
    }
    fn call(self: *Fx, turn_id: []const u8, id: []const u8, kind: []const u8, name: []const u8) !void {
        try self.apply(.{ .record = .{ .tool_started = .{ .agent = "a1", .turn = turn_id, .call = id, .kind = kind, .name = name, .title = "", .args = .{} } } });
    }
    fn askAs(self: *Fx, id: []const u8, kind: []const u8, call_id: []const u8, input: ?[]const u8) !void {
        const digest = if (input) |i| try ev.inputDigest(self.s(), i) else null;
        try self.apply(.{ .record = .{ .request = .{ .agent = "a1", .request = id, .kind = kind, .reason = "run it?", .call = call_id, .input_digest = digest } } });
    }
    fn ask(self: *Fx, id: []const u8, call_id: []const u8, input: ?[]const u8) !void {
        return self.askAs(id, "approval", call_id, input);
    }
    fn created(self: *Fx) !void {
        try self.apply(.{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } });
    }
    fn gone(self: *Fx, turn_id: []const u8) !void {
        try self.apply(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = turn_id, .reason = "failed", .error_code = process_gone_code } } });
    }
    /// a1 asked for a Bash call with `input` as r1 in t1, then its harness
    /// process died.
    fn crashed(self: *Fx, input: ?[]const u8) !void {
        try self.created();
        try self.turn("t1");
        try self.call("t1", "c1", "exec", "Bash");
        try self.ask("r1", "c1", input);
        try self.gone("t1");
    }
};

const make = "{\"command\":\"make\"}";

test "one-shot: a harness crash keeps the pending request as stale, with its tool and input" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed(make);
    try testing.expectEqual(AgentState.failed, fx.agent().state);
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
    const r = fx.agent().requests.items[0];
    try testing.expect(r.stale);
    try testing.expectEqualStrings("Bash", r.tool.?.name);
    try testing.expectEqualStrings((try ev.inputDigest(fx.s(), make)), r.input_digest.?);
    try testing.expectEqual(@as(usize, 0), fx.agent().live());
}

test "one-shot: any other failed turn still closes its requests" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.created();
    try fx.turn("t1");
    try fx.call("t1", "c1", "exec", "Bash");
    try fx.ask("r1", "c1", make);
    try fx.apply(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "failed", .error_code = "failed.harness_turn" } } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
}

test "one-shot: the same call in the next turn is answered and consumes the decision" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed("{\"command\":\"make\",\"timeout\":5}");
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);
    const effect = fx.state.effects.get("respond:a1:r1").?;
    try testing.expect(std.mem.indexOf(u8, effect.payload, "\"resume\":true") != null);

    try fx.turn("t2");
    try testing.expectEqualStrings("t2", fx.agent().decisions.items[0].turn.?);
    try fx.call("t2", "c2", "exec", "Bash");
    // The order of the keys is not a different call.
    const digest = try ev.inputDigest(fx.s(), "{ \"timeout\": 5, \"command\": \"make\" }");
    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&fx.state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r2", .kind = "approval", .reason = "again?", .call = "c2", .input_digest = digest } } }, 0, fx.s(), &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("r1", out.items[0].request.one_shot.?);
    try testing.expectEqualStrings("consumed", out.items[1].decision_closed.by);
    try testing.expectEqualStrings("venom", out.items[2].request_resolved.by);
    try testing.expectEqualStrings("r1", out.items[2].request_resolved.one_shot.?);
    try testing.expectEqualStrings("harness.respond", out.items[3].effect_requested.kind);
    for (out.items) |e| try decider.evolve(&fx.state, e);
    try testing.expectEqual(AgentState.running, fx.agent().state);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"request\":\"r2\",\"decision\":\"allow_once\",\"stale\":false}", fx.state.effects.get("respond:a1:r2").?.payload);

    // One shot: the same call asked again goes to a human.
    try fx.call("t2", "c3", "exec", "Bash");
    try fx.ask("r3", "c3", "{\"command\":\"make\",\"timeout\":5}");
    try testing.expectEqual(AgentState.needs_you, fx.agent().state);
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
}

test "one-shot: only the exact input the human approved is answered, for every kind of call" {
    const Case = struct { kind: []const u8, tool_kind: []const u8, name: []const u8, same: []const u8, changed: []const u8 };
    const cases = [_]Case{
        // Claude Code `ExitPlanMode`: no title, no args, only the plan.
        .{ .kind = "plan", .tool_kind = "plan", .name = "ExitPlanMode", .same = "{\"plan\":\"plan A\"}", .changed = "{\"plan\":\"plan B\"}" },
        // The picks must not go to a different question.
        .{ .kind = "question", .tool_kind = "question", .name = "AskUserQuestion", .same = "{\"questions\":[{\"question\":\"Keep varint?\"}]}", .changed = "{\"questions\":[{\"question\":\"Drop auth?\"}]}" },
        // Same server, same tool, another target.
        .{ .kind = "approval", .tool_kind = "mcp", .name = "mcp__gh__delete_repo", .same = "{\"repo\":\"x\"}", .changed = "{\"repo\":\"y\"}" },
        // A tool venom has no args for.
        .{ .kind = "approval", .tool_kind = "other", .name = "Frobnicate", .same = "{\"level\":1}", .changed = "{\"level\":2}" },
        // A sub-agent's prompt.
        .{ .kind = "approval", .tool_kind = "agent", .name = "Task", .same = "{\"description\":\"d\",\"prompt\":\"read\"}", .changed = "{\"description\":\"d\",\"prompt\":\"rm -rf\"}" },
        // Same path, another change.
        .{ .kind = "approval", .tool_kind = "edit", .name = "Edit", .same = "{\"file_path\":\"/w/a\",\"old_string\":\"x\",\"new_string\":\"y\"}", .changed = "{\"file_path\":\"/w/a\",\"old_string\":\"x\",\"new_string\":\"z\"}" },
        // Same path, a full rewrite.
        .{ .kind = "approval", .tool_kind = "edit", .name = "Write", .same = "{\"file_path\":\"/w/a\",\"content\":\"one\"}", .changed = "{\"file_path\":\"/w/a\",\"content\":\"two\"}" },
        // A Codex patch that also touches another file.
        .{ .kind = "approval", .tool_kind = "edit", .name = "fileChange", .same = "{\"changes\":[{\"path\":\"a\",\"diff\":\"+1\"}]}", .changed = "{\"changes\":[{\"path\":\"a\",\"diff\":\"+1\"},{\"path\":\"b\",\"diff\":\"+2\"}]}" },
    };
    for (cases) |case| for ([_]bool{ true, false }) |same| {
        var fx = Fx.init();
        defer fx.deinit();
        try fx.created();
        try fx.turn("t1");
        try fx.call("t1", "c1", case.tool_kind, case.name);
        try fx.askAs("r1", case.kind, "c1", case.same);
        try fx.gone("t1");
        try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
        try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);
        try fx.turn("t2");
        try fx.call("t2", "c2", case.tool_kind, case.name);
        try fx.askAs("r2", case.kind, "c2", if (same) case.same else case.changed);
        try testing.expectEqual(!same, fx.agent().requests.items.len == 1);
        try testing.expectEqual(if (same) AgentState.running else AgentState.needs_you, fx.agent().state);
        try testing.expectEqual(@as(usize, if (same) 0 else 1), fx.agent().decisions.items.len);
    };
}

test "one-shot: an unknown input has no key; another tool, a later turn or an unoffered answer is asked" {
    // Input unknown: resumed, but nothing can be answered for it.
    var unknown = Fx.init();
    defer unknown.deinit();
    try unknown.crashed(null);
    try unknown.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(@as(usize, 0), unknown.agent().decisions.items.len);
    try testing.expect(std.mem.indexOf(u8, unknown.state.effects.get("respond:a1:r1").?.payload, "\"resume\":true") != null);

    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed(make);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.turn("t2");
    // The same input to another tool, and a re-ask with no input.
    try fx.call("t2", "c2", "exec", "Sh");
    try fx.ask("r2", "c2", make);
    try fx.call("t2", "c3", "exec", "Bash");
    try fx.ask("r3", "c3", null);
    // A harness that does not offer the decided answer.
    try fx.call("t2", "c4", "exec", "Bash");
    try fx.apply(.{ .record = .{ .request = .{ .agent = "a1", .request = "r4", .kind = "approval", .reason = "x", .call = "c4", .answers = &.{"deny"}, .input_digest = try ev.inputDigest(fx.s(), make) } } });
    try testing.expectEqual(@as(usize, 3), fx.agent().requests.items.len);
    try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);

    // Expiry: not consumed by the end of that turn, in that commit.
    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&fx.state, .{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t2", .reason = "completed" } } }, 0, fx.s(), &out);
    var expired = false;
    for (out.items) |e| if (e == .decision_closed) {
        try testing.expectEqualStrings("expired", e.decision_closed.by);
        expired = true;
    };
    try testing.expect(expired);
    for (out.items) |e| try decider.evolve(&fx.state, e);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);

    try fx.turn("t3");
    try fx.call("t3", "c5", "exec", "Bash");
    try fx.ask("r5", "c5", make);
    try testing.expectEqual(AgentState.needs_you, fx.agent().state);
}

/// a1 with stale r1 and r2, both for `make`.
fn twoStale(fx: *Fx) !void {
    try fx.created();
    try fx.turn("t1");
    try fx.call("t1", "c1", "exec", "Bash");
    try fx.ask("r1", "c1", make);
    try fx.call("t1", "c2", "exec", "Bash");
    try fx.ask("r2", "c2", make);
    try fx.gone("t1");
}

test "one-shot: matching is one-to-one: two alike answers answer two re-asks, a third is asked" {
    var fx = Fx.init();
    defer fx.deinit();
    try twoStale(&fx);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "allow_once" } });
    try fx.turn("t2");
    try fx.call("t2", "c3", "exec", "Bash");
    try fx.ask("r3", "c3", make);
    try testing.expectEqualStrings("r2", fx.agent().decisions.items[0].request);
    try fx.call("t2", "c4", "exec", "Bash");
    try fx.ask("r4", "c4", make);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try fx.call("t2", "c5", "exec", "Bash");
    try fx.ask("r5", "c5", make);
    try testing.expectEqual(AgentState.needs_you, fx.agent().state);
}

test "one-shot: two answers that differ for one key are ambiguous: the call is asked" {
    var fx = Fx.init();
    defer fx.deinit();
    try twoStale(&fx);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "deny", .reason = "no" } });
    try fx.turn("t2");
    try fx.call("t2", "c3", "exec", "Bash");
    try fx.ask("r3", "c3", make);
    try testing.expectEqual(AgentState.needs_you, fx.agent().state);
    try testing.expectEqual(@as(usize, 2), fx.agent().decisions.items.len);
}

test "one-shot: a failed resume closes the decision and brings the request back, and it can be answered again" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed(make);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&fx.state, .{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = "unavailable.harness_not_found" } }, 0, fx.s(), &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("resume_failed", out.items[1].decision_closed.by);
    try testing.expectEqualStrings("r1", out.items[2].request_reopened.request);
    for (out.items) |e| try decider.evolve(&fx.state, e);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
    const back = fx.agent().requests.items[0];
    try testing.expect(back.stale);
    try testing.expectEqualStrings("Bash", back.tool.?.name);
    try testing.expectEqual(@as(usize, 0), fx.agent().resolved.items.len);

    // Nothing is left to approve a later turn.
    try fx.apply(.{ .start = .{} });
    try fx.apply(.{ .start = .{} });
    try fx.turn("t2");
    try fx.call("t2", "c2", "exec", "Bash");
    try fx.ask("r2", "c2", make);
    try testing.expectEqual(AgentState.needs_you, fx.agent().state);
    try fx.apply(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t2", .reason = "completed" } } });

    // Answered again: a new effect and a new decision.
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expect(fx.state.effects.contains("respond:a1:r1:2"));
    try testing.expectEqualStrings("respond:a1:r1:2", fx.agent().decisions.items[0].effect);
}

test "one-shot: a question's options survive a stale request and a reopen" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.created();
    try fx.turn("t1");
    try fx.call("t1", "c1", "question", "AskUserQuestion");
    const input = "{\"questions\":[]}";
    const labels: []const []const u8 = &.{ "Keep varint", "Fixed u32" };
    const opts: []const ev.QuestionOptions = &.{.{ .id = "q1", .question = "Which?", .labels = labels }};
    try fx.apply(.{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "question", .reason = "Which?", .call = "c1", .input_digest = try ev.inputDigest(fx.s(), input), .options = opts } } });
    try testing.expectEqualStrings("Fixed u32", fx.agent().requests.items[0].options.?[0].labels[1]);
    try fx.gone("t1");
    // Stale after the crash, the options still there.
    try testing.expect(fx.agent().requests.items[0].stale);
    try testing.expectEqualStrings("q1", fx.agent().requests.items[0].options.?[0].id);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "Fixed u32" } });
    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&fx.state, .{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = "unavailable.harness_not_found" } }, 0, fx.s(), &out);
    try testing.expectEqualStrings("Keep varint", out.items[2].request_reopened.options.?[0].labels[0]);
    for (out.items) |e| try decider.evolve(&fx.state, e);
    try testing.expectEqualStrings("Fixed u32", fx.agent().requests.items[0].options.?[0].labels[1]);
}

test "one-shot: a start closes a decision whose resume ran but whose turn never began, not one still pending" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed(make);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.apply(.{ .start = .{} });
    try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);
    try fx.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = true } });
    try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);
    try fx.apply(.{ .start = .{} });
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
}

test "one-shot: a failed stop or a cancel_turn brings nothing back" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed(make);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "cancel_turn" } });
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expect(std.mem.indexOf(u8, fx.state.effects.get("respond:a1:r1").?.payload, "\"resume\":false") != null);
    try fx.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = "stale" } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
}

test "one-shot: answered during a running turn it applies to that turn" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.crashed(make);
    try fx.turn("t2");
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "deny", .reason = "no" } });
    try testing.expectEqualStrings("t2", fx.agent().decisions.items[0].turn.?);
    try fx.call("t2", "c2", "exec", "Bash");
    try fx.ask("r2", "c2", make);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expectEqual(AgentState.running, fx.agent().state);
    const answer = fx.state.effects.get("respond:a1:r2").?;
    try testing.expect(std.mem.indexOf(u8, answer.payload, "\"decision\":\"deny\",\"reason\":\"no\"") != null);
}

/// a1 asked for a Bash call with `make` as r1 in t1, and a human answered
/// it while it was live: the answer's effect is queued, not yet run.
fn answeredLive(fx: *Fx, decision: []const u8) !void {
    try fx.created();
    try fx.turn("t1");
    try fx.call("t1", "c1", "exec", "Bash");
    try fx.ask("r1", "c1", make);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = decision, .reason = if (std.mem.eql(u8, decision, "deny")) "no" else null } });
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
}

/// The re-asked call in the resumed turn t2 is answered from the decision.
fn reaskedAnswered(fx: *Fx) !void {
    try testing.expectEqual(@as(usize, 1), fx.agent().decisions.items.len);
    try testing.expect(fx.agent().decisions.items[0].turn == null);
    const resume_effect = fx.state.effects.get("respond:a1:r1:2").?;
    try testing.expect(std.mem.indexOf(u8, resume_effect.payload, "\"stale\":true,\"resume\":true") != null);
    try fx.turn("t2");
    try fx.call("t2", "c2", "exec", "Bash");
    try fx.ask("r2", "c2", make);
    try testing.expectEqual(AgentState.running, fx.agent().state);
    try testing.expectEqual(@as(usize, 0), fx.agent().requests.items.len);
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expect(fx.state.effects.contains("respond:a1:r2"));
}

test "one-shot: an answer whose delivery failed after the crash becomes a one-shot decision" {
    for ([_][]const u8{ process_gone_code, "conflict.request_resolved" }) |detail| {
        var fx = Fx.init();
        defer fx.deinit();
        try answeredLive(&fx, "allow_once");
        try fx.gone("t1");
        try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
        try fx.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = detail } });
        try reaskedAnswered(&fx);
    }
}

test "one-shot: an answer whose delivery failed before the crash's turn.ended becomes a one-shot decision" {
    var fx = Fx.init();
    defer fx.deinit();
    try answeredLive(&fx, "deny");
    // The write found the process dying; its exit is not reaped yet.
    try fx.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = process_gone_code } });
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expect(!fx.state.effects.contains("respond:a1:r1:2"));
    try fx.gone("t1");
    try testing.expectEqualStrings("deny", fx.agent().decisions.items[0].decision);
    try reaskedAnswered(&fx);
    try testing.expect(std.mem.indexOf(u8, fx.state.effects.get("respond:a1:r2").?.payload, "\"decision\":\"deny\",\"reason\":\"no\"") != null);
}

test "one-shot: an answer pending at a daemon restart that cannot be delivered becomes a one-shot decision" {
    var fx = Fx.init();
    defer fx.deinit();
    try answeredLive(&fx, "allow_once");
    try fx.apply(.{ .start = .{} });
    try fx.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = process_gone_code } });
    try reaskedAnswered(&fx);
}

test "one-shot: a failed delivery is dropped as before for another turn end, another failure or a cancel_turn" {
    // The turn ended some other way: the process may still run.
    var other = Fx.init();
    defer other.deinit();
    try answeredLive(&other, "allow_once");
    try other.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = "conflict.request_resolved" } });
    try other.apply(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } } });
    try testing.expectEqual(@as(usize, 0), other.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 1), other.state.effects.count());

    // A failure that does not say the process was gone.
    var failure = Fx.init();
    defer failure.deinit();
    try answeredLive(&failure, "allow_once");
    try failure.gone("t1");
    try failure.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = "failed.harness_protocol" } });
    try testing.expectEqual(@as(usize, 0), failure.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 1), failure.state.effects.count());

    // Delivered: nothing to do.
    var delivered = Fx.init();
    defer delivered.deinit();
    try answeredLive(&delivered, "allow_once");
    try delivered.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = true } });
    try delivered.gone("t1");
    try testing.expectEqual(@as(usize, 1), delivered.state.effects.count());

    // `cancel_turn`: the turn it would end is over.
    var cancel = Fx.init();
    defer cancel.deinit();
    try answeredLive(&cancel, "cancel_turn");
    try cancel.gone("t1");
    try cancel.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = process_gone_code } });
    try testing.expectEqual(@as(usize, 0), cancel.agent().decisions.items.len);
    try testing.expectEqual(@as(usize, 1), cancel.state.effects.count());
}

test "one-shot: an undelivered answer with no input still resumes, and a failed resume brings the request back" {
    var fx = Fx.init();
    defer fx.deinit();
    try fx.created();
    try fx.turn("t1");
    try fx.call("t1", "c1", "exec", "Bash");
    try fx.ask("r1", "c1", null);
    try fx.apply(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.gone("t1");
    try fx.apply(.{ .complete = .{ .key = "respond:a1:r1", .ok = false, .detail = process_gone_code } });
    try testing.expectEqual(@as(usize, 0), fx.agent().decisions.items.len);
    try testing.expect(fx.state.effects.contains("respond:a1:r1:2"));
    try fx.apply(.{ .complete = .{ .key = "respond:a1:r1:2", .ok = false, .detail = "unavailable.harness_not_found" } });
    try testing.expectEqual(@as(usize, 1), fx.agent().requests.items.len);
    try testing.expect(fx.agent().requests.items[0].stale);
    try testing.expectEqualStrings("Bash", fx.agent().requests.items[0].tool.?.name);
}

test "one-shot: the digest and the key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = ev.inputDigest;
    try testing.expectEqualStrings(try d(a, "{\"a\":1,\"b\":{\"c\":2,\"d\":[1,2]}}"), try d(a, " { \"b\": {\"d\":[1, 2], \"c\":2}, \"a\":1 } "));
    // Array order and number text are the call.
    try testing.expect(!std.mem.eql(u8, try d(a, "[1,2]"), try d(a, "[2,1]")));
    try testing.expect(!std.mem.eql(u8, try d(a, "{\"a\":1.00000000000000001}"), try d(a, "{\"a\":1.0}")));
    // Not JSON: byte for byte.
    try testing.expect(!std.mem.eql(u8, try d(a, "make "), try d(a, "make")));
    try testing.expect((try key(a, .{ .kind = "exec", .name = "Bash" }, null)) == null);
    try testing.expect((try key(a, null, null)) == null);
    try testing.expectEqualStrings("{\"kind\":\"exec\",\"name\":\"Bash\",\"input\":\"ab\"}", (try key(a, .{ .kind = "exec", .name = "Bash", .title = "ignored" }, "ab")).?);
    try testing.expectEqualStrings("{\"input\":\"ab\"}", (try key(a, null, "ab")).?);
}
