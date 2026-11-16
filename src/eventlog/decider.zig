//! The pure half of venom's event sourcing: `decide` turns a
//! command and the current state into events, `evolve` folds one event into
//! the state. Neither does I/O, reads a clock or calls out, so replaying a
//! log always rebuilds the same state, and both are tested without files.
//! The time is an argument (`now`, milliseconds since the Unix epoch).
//!
//! Agents follow the state machine in
//! `agent.zig`: an agent must be created before its turns, and every state
//! change is an `agent.state_changed` record decided together with the
//! record that caused it.
//!
//! Stop, archive, restart and creation:
//! - `stop` of a `running|needs_you` agent clears the turn's live requests
//!   (`request.resolved {by: "stop"}`, published as `agent.attention_cleared
//!   {by: "stop"}`), logs `agent.stop_requested` and puts a `harness.stop`
//!   effect in the outbox; the harness host interrupts the turn (or sends
//!   `cancel_turn` to a waiting request, or stops the process), and the
//!   resulting `turn.ended {interrupted}` settles the agent. `queued`
//!   settles at once without a turn. `settled|failed|archived`: nothing.
//!   `handed_over`: `HandedOver` (`conflict.agent_handed_over`).
//! - `archive` is a stop followed by `settled → archived`: two logged
//!   transitions. For a running turn the second one is decided together
//!   with the turn's end.
//! - `start` keeps a `handed_over` agent only if its take-over pane is in
//!   the start's live `panes`; otherwise it is `settled` again and a
//!   `harness.takeback` effect imports what ran meanwhile.
//! - `takeover` and `takeback`: a settled
//!   agent goes `handed_over` with a `tui` binding; taking it back settles
//!   it and queues the same `harness.takeback` effect as a restart.
//! - `stop` of a dispatched `queued` agent settles it and queues `harness.stop`
//!   without a turn: the host ends the process, and drops what it still says.
//! - `agent.created` is the first record of an agent, so it is published
//!   before any `agent.state_changed` for it.
//! - The queue: a `queued` agent with a `task`
//!   waits for a slot; `dispatch` logs that it got one. Its task stays in the
//!   state until its turn starts or it leaves the queue, and a daemon start
//!   puts dispatched agents back in line, so the task survives a restart.
const std = @import("std");
const ev = @import("events.zig");
const model = @import("agent.zig");
const AgentState = model.State;
const Event = ev.Event;
const Command = ev.Command;
const workspaces = @import("workspaces.zig");
const agent_scope = @import("agent_scope.zig");
const harness = @import("harness.zig");
const usage = @import("usage.zig");
const attention = @import("attention.zig");
const always = @import("always.zig");
const oneshot = @import("oneshot.zig");

pub const Request = struct {
    request: []const u8,
    kind: []const u8,
    reason: []const u8,
    call: ?[]const u8 = null,
    /// Answers the harness accepts; empty: any.
    answers: []const []const u8 = &.{},
    /// The harness process that asked is gone: a daemon start or a harness
    /// crash came since it was raised.
    stale: bool = false,
    /// When it was raised, ms since the Unix epoch.
    at: i64 = 0,
    /// The narrowest grant "allow always" records (`always.zig`).
    grant: ?[]const u8 = null,
    /// An edit outside the agent's scope (`agent_scope.zig`).
    outside_scope: bool = false,
    /// The tool call it belongs to, if known (`oneshot.zig`).
    tool: ?ev.RequestTool = null,
    /// `events.inputDigest` of the call's whole input, if the adapter has it.
    input_digest: ?[]const u8 = null,
    /// Per question, what the harness offers (`question` requests).
    options: ?[]const ev.QuestionOptions = null,
};

/// What a `handed_over` agent's harness TUI is waiting for.
pub const Away = struct { kind: []const u8, reason: []const u8, at: i64 };

/// A snoozed inbox item (`inbox.snooze`).
pub const Snooze = struct { item: []const u8, until: i64, at: i64 };

/// How many prompts to its sub-agents an agent keeps (the newest), and how
/// much of each. The harness got the whole prompt either way.
pub const child_prompts_max = 100;
pub const child_prompt_text_max = 4096;

/// A prompt to a spawned sub-agent the parent did not send.
pub const ChildPrompt = struct { child: []const u8, text: []const u8, at: i64 };

pub const Agent = struct {
    title: []const u8 = "",
    harness: []const u8 = "",
    workspace: []const u8 = "",
    repos: []const []const u8 = &.{},
    parent: ?[]const u8 = null,
    /// The linked issue's number (`--issue`).
    issue: ?[]const u8 = null,
    /// The harness's own id: an attribute only.
    harness_session: ?[]const u8 = null,
    /// The conversation a fork's first start copies, until a protocol
    /// binding says it started.
    fork_source: ?[]const u8 = null,
    /// The model the harness last reported (`session`).
    model: ?[]const u8 = null,
    /// Where the harness runs; null: the workspace root.
    cwd: ?[]const u8 = null,
    /// Its worktrees or copies; empty in place.
    worktrees: []const ev.Worktree = &.{},
    /// The worktrees are its parent's (a fork): cleaning it leaves them.
    borrowed: bool = false,
    /// The MCP servers its harness reported, latest report.
    mcp_servers: []const []const u8 = &.{},
    /// The MCP servers turned off for its harness's next processes.
    mcp_off: []const []const u8 = &.{},
    /// The forks of this agent that ended, oldest first.
    forks: std.ArrayList(ev.ForkEnded) = .empty,
    /// The held first prompt; null once it left the queue.
    task: ?[]const u8 = null,
    /// `task` was sent: the agent has a slot, its turn is about to start.
    dispatched: bool = false,
    /// venom's permission mode (`config.Mode`); null: the harness default.
    mode: ?[]const u8 = null,
    /// The model asked for at spawn; null: the harness's default.
    spawn_model: ?[]const u8 = null,
    /// The provider it was spawned with; null: none.
    provider: ?[]const u8 = null,
    /// The provider's config folder for the harness; null: its default.
    home: ?[]const u8 = null,
    /// The grants its principal is issued with.
    grants: ?[]const @import("proto").grants.Grant = null,
    /// Its principal was revoked: a restart must not issue it again.
    revoked: bool = false,
    /// Prompts its spawned sub-agents got from others, oldest first.
    child_prompts: std.ArrayList(ChildPrompt) = .empty,
    state: AgentState = .queued,
    /// A settled agent is unread until the user opens it.
    unread: bool = false,
    created_at: i64 = 0,
    /// When the agent entered its current state.
    changed_at: i64 = 0,
    /// Turn, text and turn-end records, oldest first.
    transcript: std.ArrayList(Event) = .empty,
    open_turn: ?[]const u8 = null,
    /// The turn a `stop`/`archive` is interrupting, until it ends.
    stopping: ?[]const u8 = null,
    /// Archive once `stopping` has ended (`archive` of a live agent).
    archive_on_stop: bool = false,
    /// The take-over split's venomx pane while `handed_over` (from the
    /// `tui` binding); null in own mode.
    pane: ?[]const u8 = null,
    /// The process running that split, once it was reported: only
    /// its descendants may report attention for the agent.
    pane_root: ?ev.PaneRoot = null,
    /// The session file a hook named while `handed_over`, for catch-up.
    transcript_ref: ?[]const u8 = null,
    /// The harness TUI waits for the human.
    away: ?Away = null,
    /// Pending requests (the agent's inbox items), oldest first.
    requests: std.ArrayList(Request) = .empty,
    /// Requests resolved so far, so that a late answer is told
    /// `conflict.request_resolved` rather than `not_found`.
    resolved: std.ArrayList([]const u8) = .empty,
    /// Open one-shot decisions, oldest first.
    decisions: std.ArrayList(oneshot.Decision) = .empty,
    /// Snoozed inbox items, one per item id.
    snoozes: std.ArrayList(Snooze) = .empty,
    /// How many turns, tool calls, requests and messages the agent has had.
    /// Harness bindings number venom's `t<n>`, `c<n>`, `r<n>` and `m<n>` ids
    /// from these, so ids never repeat
    /// across harness restarts or daemon restarts.
    turns: u32 = 0,
    calls: u32 = 0,
    raised: u32 = 0,
    messages: u32 = 0,

    pub fn pending(self: *const Agent, id: []const u8) ?usize {
        for (self.requests.items, 0..) |r, i| if (std.mem.eql(u8, r.request, id)) return i;
        return null;
    }

    /// Waiting for a concurrency slot, its task unsent.
    pub fn waiting(self: *const Agent) bool {
        return self.state == .queued and self.task != null and !self.dispatched;
    }

    /// Counts against `agents.max_concurrent`.
    pub fn holdsSlot(self: *const Agent) bool {
        return switch (self.state) {
            .running, .needs_you => true,
            .queued => self.dispatched,
            else => false,
        };
    }

    /// Pending requests whose harness process is still there.
    pub fn live(self: *const Agent) usize {
        var n: usize = 0;
        for (self.requests.items) |r| n += @intFromBool(!r.stale);
        return n;
    }
};

pub const Effect = struct {
    key: []const u8,
    kind: []const u8,
    payload: []const u8,
    done: bool = false,
    ok: bool = false,
    detail: []const u8 = "",
};

/// State rebuilt from the log. Everything lives in one arena: the log only
/// grows, and the state is dropped as a whole.
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    starts: u64 = 0,
    agents: std.StringArrayHashMapUnmanaged(Agent) = .empty,
    /// Outbox: every effect ever requested, by idempotency key, in order.
    effects: std.StringArrayHashMapUnmanaged(Effect) = .empty,
    /// Workspaces by path, in the order they were added.
    workspaces: std.StringArrayHashMapUnmanaged(workspaces.Workspace) = .empty,
    /// Per-turn usage accounting (`usage.zig`).
    usage: usage.Ledger = .{},
    /// Standing "allow always" decisions, oldest first.
    standing: std.ArrayList(always.Standing) = .empty,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .arena = .init(gpa) };
    }
    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    /// The number of effects that are requested and not completed.
    pub fn pendingEffects(self: *const State) usize {
        var n: usize = 0;
        for (self.effects.values()) |e| n += @intFromBool(!e.done);
        return n;
    }

    /// Canonical JSON of the whole state, for comparison and debugging.
    pub fn render(self: *const State, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
        try w.beginObject();
        try w.objectField("starts");
        try w.write(self.starts);
        try w.objectField("agents");
        try w.beginObject();
        for (self.agents.keys(), self.agents.values()) |id, agent| {
            try w.objectField(id);
            try w.beginObject();
            inline for (.{ "title", "harness", "workspace", "repos", "worktrees", "parent", "issue", "harness_session", "state", "unread", "created_at", "changed_at" }) |name| {
                try w.objectField(name);
                try w.write(@field(agent, name));
            }
            inline for (.{ "open_turn", "stopping", "archive_on_stop", "pane", "pane_root", "transcript_ref", "away", "task", "dispatched", "revoked", "mode", "spawn_model", "model", "fork_source" }) |name| {
                try w.objectField(name);
                try w.write(@field(agent, name));
            }
            try w.objectField("transcript");
            try w.beginArray();
            for (agent.transcript.items) |e| try e.write(&w);
            try w.endArray();
            try w.objectField("requests");
            try w.write(agent.requests.items);
            try w.objectField("snoozes");
            try w.write(agent.snoozes.items);
            try w.objectField("decisions");
            try w.write(agent.decisions.items);
            try w.objectField("child_prompts");
            try w.write(agent.child_prompts.items);
            try w.endObject();
        }
        try w.endObject();
        try w.objectField("effects");
        try w.write(self.effects.values());
        try w.objectField("workspaces");
        try w.write(self.workspaces.values());
        try w.objectField("standing");
        try w.write(self.standing.items);
        try w.endObject();
        return out.toOwnedSlice();
    }
};

pub const Rejection = error{
    /// The command names an agent, turn, request or effect that does not exist.
    NotFound,
    /// The command conflicts with the state (a turn already open, a
    /// duplicate request or effect key, an event outside its turn).
    Conflict,
    /// The command is not allowed through this entry point.
    InvalidCommand,
    /// The agent's state does not allow it.
    InvalidTransition,
    /// The agent is `handed_over`: the harness's own TUI owns it until
    /// take back.
    HandedOver,
    /// A turn runs (or is queued): take-over waits for it to end.
    TurnRunning,
};

/// The wire error code a rejection is reported with. Stable.
pub fn errorCode(err: Rejection) []const u8 {
    return switch (err) {
        error.NotFound => "not_found.agent",
        error.Conflict => "conflict",
        error.InvalidCommand => "invalid_params",
        error.InvalidTransition => model.invalid_transition_code,
        error.HandedOver => model.handed_over_code,
        error.TurnRunning => "conflict.turn_running",
    };
}

/// Appends the events `cmd` produces to `out` (allocated in `a`) at time
/// `now`. A rejected command returns its error; the caller drops `out`.
pub fn decide(state: *const State, cmd: Command, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    switch (cmd) {
        .start => |s| {
            try out.append(a, .{ .daemon_started = s });
            for (state.agents.keys(), state.agents.values()) |id, *agent| if (agent.open_turn) |turn| {
                const end: ev.TurnEnded = .{ .agent = id, .turn = turn, .reason = "failed", .error_code = "failed.daemon_restart" };
                // Pending requests stay, as stale inbox items.
                try endTurn(agent, end, false, now, a, out);
                try oneshot.undeliveredAt(state, id, turn, now, a, out);
            };
            // A take-over split that outlived the daemon keeps the agent;
            // anything else is taken back at once.
            for (state.agents.keys(), state.agents.values()) |id, agent| {
                if (agent.state != .handed_over) continue;
                if (agent.pane) |pane| if (contains(s.panes, pane)) continue;
                try takeBack(id, &agent, try std.fmt.allocPrint(a, "takeback:{s}:{d}", .{ id, state.starts + 1 }), now, a, out);
            }
            try oneshot.expireUnstarted(state, a, out);
        },
        .record => |e| try decideRecord(state, e, now, a, out),
        .create => |c| {
            if (c.agent.len == 0) return error.InvalidCommand;
            if (state.agents.contains(c.agent)) return error.Conflict;
            if (c.state != .queued) return error.InvalidCommand;
            var created = c;
            created.at = now;
            try out.append(a, .{ .agent_created = created });
        },
        .transition => |t| {
            const agent = state.agents.getPtr(t.agent) orelse return error.NotFound;
            if (!model.allowed(agent.state, t.to)) return error.InvalidTransition;
            if (!model.requestable(agent.state, t.to)) return error.InvalidCommand;
            try out.append(a, .{ .agent_state_changed = .{ .agent = t.agent, .from = agent.state, .to = t.to, .at = now } });
        },
        .takeover => |t| {
            const agent = state.agents.getPtr(t.agent) orelse return error.NotFound;
            switch (agent.state) {
                .settled => {},
                .handed_over => return error.HandedOver,
                .queued, .running, .needs_you => return error.TurnRunning,
                .failed, .archived => return error.InvalidTransition,
            }
            try out.append(a, .{ .agent_binding = .{ .agent = t.agent, .harness = agent.harness, .harness_session = agent.harness_session, .cwd = agent.cwd orelse agent.workspace, .mode = "tui", .pane = t.pane } });
            try out.append(a, .{ .agent_state_changed = .{ .agent = t.agent, .from = .settled, .to = .handed_over, .at = now } });
        },
        .takeback => |t| {
            const agent = state.agents.getPtr(t.agent) orelse return error.NotFound;
            switch (agent.state) {
                .handed_over => {},
                .settled => return,
                else => return error.InvalidTransition,
            }
            const key = try std.fmt.allocPrint(a, "takeback:{s}:@{d}", .{ t.agent, agent.changed_at });
            if (state.effects.contains(key)) return error.Conflict;
            try takeBack(t.agent, agent, key, now, a, out);
        },
        .fork => |f| {
            const agent = state.agents.getPtr(f.agent) orelse return error.NotFound;
            switch (agent.state) {
                .archived => return error.InvalidTransition,
                .handed_over => return error.HandedOver,
                .running, .needs_you => return error.TurnRunning,
                .queued, .settled, .failed => {},
            }
            const payload = try std.json.Stringify.valueAlloc(a, .{ .agent = f.agent, .through_turn = f.through_turn, .task = f.task }, .{ .emit_null_optional_fields = false });
            try out.append(a, .{ .effect_requested = .{ .key = try forkKey(state, f.agent, a), .kind = "harness.fork", .payload = payload } });
        },
        .mcp_off => |m| {
            const agent = state.agents.getPtr(m.agent) orelse return error.NotFound;
            switch (agent.state) {
                .archived => return error.InvalidTransition,
                .handed_over => return error.HandedOver,
                .running, .needs_you => return error.TurnRunning,
                .queued, .settled, .failed => {},
            }
            try out.append(a, .{ .agent_mcp_off = .{ .agent = m.agent, .servers = m.servers } });
        },
        .dispatch => |d| {
            const agent = state.agents.getPtr(d.agent) orelse return error.NotFound;
            if (!agent.waiting()) return error.InvalidTransition;
            try out.append(a, .{ .agent_dispatched = .{ .agent = d.agent } });
        },
        .revoked => |r| {
            const agent = state.agents.getPtr(r.agent) orelse return error.NotFound;
            if (!agent.revoked) try out.append(a, .{ .agent_revoked = .{ .agent = r.agent } });
        },
        .promote => |p| {
            const agent = state.agents.getPtr(p.agent) orelse return error.NotFound;
            if (agent.state == .archived) return error.InvalidTransition;
            const parent = agent.parent orelse return;
            try out.append(a, .{ .agent_promoted = .{ .agent = p.agent, .parent = parent, .at = now } });
        },
        .child_prompted => |p| {
            if (!state.agents.contains(p.parent)) return error.NotFound;
            var end = @min(p.text.len, child_prompt_text_max);
            while (end > 0 and end < p.text.len and (p.text[end] & 0xC0) == 0x80) end -= 1;
            try out.append(a, .{ .child_prompted = .{ .agent = p.parent, .child = p.child, .text = p.text[0..end], .at = now } });
        },
        .stop => |st| try stop(state, st.agent, false, now, a, out),
        .archive => |ar| try stop(state, ar.agent, true, now, a, out),
        .open => |o| {
            const agent = state.agents.getPtr(o.agent) orelse return error.NotFound;
            if (agent.unread) try out.append(a, .{ .agent_opened = .{ .agent = o.agent } });
        },
        .sweep => |sw| {
            const after: i64 = std.math.cast(i64, sw.archive_after_ms) orelse return;
            for (state.agents.keys(), state.agents.values()) |id, agent| {
                if (agent.state != .settled) continue;
                if (now - agent.changed_at < after) continue;
                try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = .settled, .to = .archived, .at = now } });
            }
        },
        .answer => |ans| {
            const agent = state.agents.getPtr(ans.agent) orelse return error.NotFound;
            const i = agent.pending(ans.request) orelse return error.NotFound;
            const asked = agent.requests.items[i];
            if (asked.answers.len > 0) for (asked.answers) |allowed_answer| {
                if (std.mem.eql(u8, allowed_answer, ans.decision)) break;
            } else return error.InvalidCommand;
            if (std.mem.eql(u8, ans.decision, "allow_always") and std.mem.eql(u8, asked.kind, "approval"))
                try always.record(state, agent, ans.agent, asked, now, a, out);
            if (asked.stale) {
                try oneshot.record(state, agent, ans.agent, asked, ans, now, a, out);
                try respond(state, ans, asked, a, out);
            } else {
                try out.append(a, .{ .request_resolved = .{ .agent = ans.agent, .request = ans.request, .by = ans.by, .grant = ans.grant, .one_shot = ans.one_shot } });
                // The payload keeps the request and its turn: a delivery the
                // harness crash beat becomes a one-shot decision.
                try queueRespond(state, ans, null, .{ .turn = agent.open_turn, .request = asked }, a, out);
            }
            try resumeAfter(agent, ans.agent, agent.requests.items[i], now, a, out);
        },
        .expire, .snooze, .away => try attention.decide(state, cmd, now, a, out),
        .takeover_pane => |t| {
            const agent = state.agents.getPtr(t.agent) orelse return error.NotFound;
            if (agent.state != .handed_over) return error.InvalidTransition;
            var b = tuiBinding(t.agent, agent);
            b.pane = t.pane;
            try out.append(a, .{ .agent_binding = b });
        },
        .takeover_split => |t| {
            const agent = state.agents.getPtr(t.agent) orelse return error.NotFound;
            if (agent.state != .handed_over) return error.InvalidTransition;
            var b = tuiBinding(t.agent, agent);
            b.root = t.root;
            try out.append(a, .{ .agent_binding = b });
        },
        .revoke_always => try always.decide(state, cmd, now, a, out),
        .complete => |c| {
            const effect = state.effects.getPtr(c.key) orelse return error.NotFound;
            if (effect.done) return;
            try out.append(a, .{ .effect_completed = c });
            if (!c.ok) try oneshot.resumeFailed(state, effect, a, out);
            if (!c.ok) try oneshot.deliveryFailed(state, effect, c.detail, now, a, out);
            if (std.mem.eql(u8, effect.kind, "harness.fork")) try forkEnded(state, effect, c, now, a, out);
        },
        .workspace_add, .workspace_scan, .workspace_remove => try workspaces.decide(state, cmd, a, out),
    }
}

/// A fork's effect ended: on success its conversation becomes a new
/// agent, under the source, in the source's folder and scope, with the
/// source's mode, model and grants. Either way `agent.fork_ended` says so,
/// which is how a client learns the result: `effect.*` stay unpublished.
fn forkEnded(state: *const State, effect: *const Effect, c: anytype, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    const Payload = struct { agent: []const u8, task: ?[]const u8 = null };
    const p = std.json.parseFromSliceLeaky(Payload, a, effect.payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommand,
    };
    const source = state.agents.getPtr(p.agent) orelse return error.NotFound;
    if (!c.ok) return out.append(a, .{ .agent_fork_ended = .{ .agent = p.agent, .key = c.key, .ok = false, .code = c.detail } });
    // Archived meanwhile: its worktree may be gone, so nothing can run there.
    if (source.state == .archived) return out.append(a, .{ .agent_fork_ended = .{ .agent = p.agent, .key = c.key, .ok = false, .code = model.invalid_transition_code } });
    const id = try nextAgentId(state, a);
    var grants: ?[]const @import("proto").grants.Grant = null;
    if (source.grants) |gs| {
        // What a sub-agent inherits: its parent's scope on itself is its own.
        const own = try std.fmt.allocPrint(a, "agent:{s}", .{p.agent});
        const list = try a.dupe(@import("proto").grants.Grant, gs);
        for (list) |*g| if (std.mem.eql(u8, g.scope, own)) {
            g.scope = try std.fmt.allocPrint(a, "agent:{s}", .{id});
        };
        grants = list;
    }
    try out.append(a, .{
        .agent_created = .{
            .agent = id,
            .title = try std.fmt.allocPrint(a, "fork of {s}", .{source.title}),
            .harness = source.harness,
            .workspace = source.workspace,
            .repos = source.repos,
            .parent = p.agent,
            .issue = source.issue,
            .harness_session = c.detail,
            // A source that never started has no conversation of its own yet:
            // what it would copy is what this one copies.
            .fork_source = source.fork_source orelse source.harness_session,
            .cwd = source.cwd,
            .worktrees = source.worktrees,
            .borrowed = source.worktrees.len > 0,
            .task = p.task,
            // No task: nothing will dispatch it. Idle, like an agent between turns,
            // so `agent.wait` counts it as finished; a send starts it.
            .state = if (p.task == null) .settled else .queued,
            .mode = source.mode,
            .spawn_model = source.spawn_model orelse source.model,
            .provider = source.provider,
            .home = source.home,
            .grants = grants,
            .at = now,
        },
    });
    try out.append(a, .{ .agent_fork_ended = .{ .agent = p.agent, .key = c.key, .ok = true, .fork = id } });
}

/// The next free `a<n>` id. Agents are never removed from the log, so the
/// count only grows.
pub fn nextAgentId(state: *const State, a: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var n = state.agents.count() + 1;
    while (true) : (n += 1) {
        const id = try std.fmt.allocPrint(a, "a{d}", .{n});
        if (!state.agents.contains(id)) return id;
    }
}

/// Resolves an answered request and queues its `harness.respond` effect.
/// The payload carries the answer: `decision`, and `reason` and
/// `args_json` when given (left out when null). `stale` is the answered
/// request when its harness process is gone: the executor then has nothing to
/// deliver to, and (`resume`) reattaches and sends the resume prompt. The
/// payload keeps the request (`stale_request`): the prompt quotes it, and a
/// failed resume brings it back. It may be answered
/// again after that, so its later effects get their own keys.
pub fn respond(state: *const State, ans: @FieldType(Command, "answer"), stale: ?Request, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    try out.append(a, .{ .request_resolved = .{ .agent = ans.agent, .request = ans.request, .by = ans.by, .grant = ans.grant, .one_shot = ans.one_shot } });
    try queueRespond(state, ans, stale, null, a, out);
}

/// A live request a human answered, as a `harness.respond` payload keeps it
/// (`asked`, with the `turn` it was asked in): if the harness process is gone
/// before the answer is delivered, `oneshot.deliveryFailed` turns it into a
/// one-shot decision.
pub const Live = struct { turn: ?[]const u8, request: Request };

/// Queues the `harness.respond` effect of `ans` (see `respond`), without
/// resolving the request.
pub fn queueRespond(state: *const State, ans: @FieldType(Command, "answer"), stale: ?Request, live: ?Live, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    const key = try respondKey(state, ans.agent, ans.request, stale != null, a);
    if (state.effects.contains(key)) return error.Conflict;
    const payload = try std.json.Stringify.valueAlloc(a, .{
        .agent = ans.agent,
        .request = ans.request,
        .decision = ans.decision,
        .reason = ans.reason,
        .args_json = ans.args_json,
        .stale = stale != null,
        .@"resume" = if (stale != null) oneshot.resumes(ans.decision) else null,
        .stale_request = stale,
        .turn = if (live) |l| l.turn else null,
        .asked = if (live) |l| l.request else null,
    }, .{ .emit_null_optional_fields = false });
    try out.append(a, .{ .effect_requested = .{ .key = key, .kind = "harness.respond", .payload = payload } });
}

/// The idempotency key of an answer's effect. A stale request can be answered
/// again after a failed resume: each answer is its own effect.
pub fn respondKey(state: *const State, agent: []const u8, request: []const u8, stale: bool, a: std.mem.Allocator) ![]const u8 {
    const first = try std.fmt.allocPrint(a, "respond:{s}:{s}", .{ agent, request });
    if (!stale or !state.effects.contains(first)) return first;
    var n: u32 = 2;
    while (true) : (n += 1) {
        const key = try std.fmt.allocPrint(a, "{s}:{d}", .{ first, n });
        if (!state.effects.contains(key)) return key;
    }
}

/// The idempotency key the next `fork` of `agent` gets: an agent forks any
/// number of times.
pub fn forkKey(state: *const State, agent: []const u8, a: std.mem.Allocator) ![]const u8 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        const key = try std.fmt.allocPrint(a, "fork:{s}:{d}", .{ agent, n });
        if (!state.effects.contains(key)) return key;
    }
}

fn decideRecord(state: *const State, e: Event, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    switch (e) {
        // Agent records come from their own commands, so that their
        // checks and timestamps cannot be skipped.
        .agent_mcp_off, .agent_fork_ended, .daemon_started, .effect_requested, .effect_completed, .agent_created, .agent_state_changed, .agent_opened, .agent_stop_requested, .attention_snoozed, .attention_away, .attention_away_cleared, .always_granted, .always_revoked, .decision_recorded, .decision_closed, .request_reopened, .agent_dispatched, .agent_revoked, .agent_promoted, .child_prompted, .workspace_added, .workspace_scanned, .workspace_removed => return error.InvalidCommand,
        .tool_started => |t| {
            var copy = t;
            copy.at = now;
            try harness.decide(state, .{ .tool_started = copy }, a, out);
        },
        .tool_ended, .usage, .agent_binding => try harness.decide(state, e, a, out),
        // Not turn-scoped: the latest size wins.
        .context => |c| {
            if (!state.agents.contains(c.agent)) return error.NotFound;
            var copy = c;
            copy.at = now;
            try out.append(a, .{ .context = copy });
        },
        // Not turn-scoped: the latest report wins.
        .mcp_servers => |m| {
            if (!state.agents.contains(m.agent)) return error.NotFound;
            try out.append(a, e);
        },
        // Per harness and account: the latest wins.
        .plan_windows => |p| {
            if (p.harness.len == 0) return error.InvalidCommand;
            var copy = p;
            copy.at = now;
            try out.append(a, .{ .plan_windows = copy });
        },
        .turn_started => |t| {
            const agent = state.agents.getPtr(t.agent) orelse return error.NotFound;
            // queued (first prompt), settled (new prompt), failed (retry).
            if (!model.allowed(agent.state, .running)) return error.InvalidTransition;
            if (agent.open_turn != null) return error.Conflict;
            for (agent.transcript.items) |old| if (old == .turn_started and std.mem.eql(u8, old.turn_started.turn, t.turn)) return error.Conflict;
            try out.append(a, e);
            try out.append(a, .{ .agent_state_changed = .{ .agent = t.agent, .from = agent.state, .to = .running, .at = now } });
        },
        .text => |t| {
            try openTurn(state, t.agent, t.turn);
            try out.append(a, e);
        },
        .turn_prompt => |t| {
            try openTurn(state, t.agent, t.turn);
            try out.append(a, e);
        },
        .request => |r| {
            const agent = state.agents.getPtr(r.agent) orelse return error.NotFound;
            if (agent.open_turn == null) return error.Conflict;
            if (agent.pending(r.request) != null) return error.Conflict;
            var raised = r;
            raised.at = now;
            const approval = std.mem.eql(u8, r.kind, "approval");
            // A write outside the scope is always asked: no
            // grant, so no standing "always" answers it or is recorded. An
            // adapter may already know (a patch's other paths).
            raised.outside_scope = approval and (r.outside_scope or try agent_scope.outsideCall(a, agent, r.call));
            raised.grant = if (approval and !raised.outside_scope) try always.narrowest(a, agent, r.call) else null;
            raised.tool = oneshot.toolOf(agent, r.call);
            // The call a stale request's answer decided.
            if (try oneshot.matching(a, agent, raised)) |d| {
                raised.one_shot = d.request;
                try out.append(a, .{ .request = raised });
                try out.append(a, .{ .decision_closed = .{ .agent = r.agent, .request = d.request, .by = "consumed" } });
                return respond(state, .{ .agent = r.agent, .request = r.request, .decision = d.decision, .reason = d.reason, .args_json = d.args_json, .one_shot = d.request }, null, a, out);
            }
            try out.append(a, .{ .request = raised });
            // A standing "allow always" answers it at once.
            // Not for `plan`: there, every write waits for a person.
            const planning = if (agent.mode) |m| std.mem.eql(u8, m, "plan") else false;
            if (!planning) if (always.autoAllow(state, r.agent, raised)) |grant|
                return respond(state, .{ .agent = r.agent, .request = r.request, .decision = "allow_once", .grant = grant }, null, a, out);
            if (agent.state == .running) try out.append(a, .{ .agent_state_changed = .{ .agent = r.agent, .from = .running, .to = .needs_you, .at = now } });
        },
        .request_resolved => |r| {
            const agent = state.agents.getPtr(r.agent) orelse return error.NotFound;
            const i = agent.pending(r.request) orelse return error.NotFound;
            try out.append(a, e);
            try resumeAfter(agent, r.agent, agent.requests.items[i], now, a, out);
        },
        .turn_ended => |t| {
            try openTurn(state, t.agent, t.turn);
            // A crash keeps them, as stale inbox items.
            try endTurn(state.agents.getPtr(t.agent).?, t, !oneshot.processGone(t), now, a, out);
            if (oneshot.processGone(t)) try oneshot.undeliveredAt(state, t.agent, t.turn, now, a, out);
        },
    }
}

/// `stop` and `archive`.
fn stop(state: *const State, id: []const u8, archive: bool, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    const agent = state.agents.getPtr(id) orelse return error.NotFound;
    switch (agent.state) {
        .handed_over => return error.HandedOver,
        .archived => {},
        .settled, .failed => if (archive) {
            try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = agent.state, .to = .archived, .at = now } });
        },
        // Leaves the queue without a turn; not unread.
        .queued => {
            try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = .queued, .to = .settled, .at = now } });
            if (archive) try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = .settled, .to = .archived, .at = now } });
            // Its task was sent, its turn not started: the harness is still
            // coming up, and must not start the turn behind the stop.
            if (agent.dispatched) try out.append(a, .{ .effect_requested = .{ .key = try std.fmt.allocPrint(a, "stop:{s}:dispatched", .{id}), .kind = "harness.stop", .payload = try std.json.Stringify.valueAlloc(a, .{ .agent = id }, .{}) } });
        },
        .running, .needs_you => {
            const turn = agent.open_turn orelse return error.Conflict;
            if (agent.stopping) |s| if (std.mem.eql(u8, s, turn)) {
                // Already being interrupted: only an archive adds anything.
                if (archive and !agent.archive_on_stop) try out.append(a, .{ .agent_stop_requested = .{ .agent = id, .turn = turn, .archive = true } });
                return;
            };
            for (agent.requests.items) |r| if (!r.stale) {
                try out.append(a, .{ .request_resolved = .{ .agent = id, .request = r.request, .by = "stop" } });
            };
            try out.append(a, .{ .agent_stop_requested = .{ .agent = id, .turn = turn, .archive = archive } });
            const key = try std.fmt.allocPrint(a, "stop:{s}:{s}", .{ id, turn });
            if (state.effects.contains(key)) return error.Conflict;
            try out.append(a, .{ .effect_requested = .{ .key = key, .kind = "harness.stop", .payload = try std.json.Stringify.valueAlloc(a, .{ .agent = id, .turn = turn }, .{}) } });
        },
    }
}

/// The `tui` binding a `handed_over` agent has now, to log again with one
/// member changed.
pub fn tuiBinding(id: []const u8, agent: *const Agent) ev.AgentBinding {
    return .{ .agent = id, .harness = agent.harness, .harness_session = agent.harness_session, .cwd = agent.cwd orelse agent.workspace, .mode = "tui", .pane = agent.pane, .root = agent.pane_root, .transcript_ref = agent.transcript_ref };
}

/// `handed_over → settled`, and the `harness.takeback` effect that imports
/// what the harness's own TUI ran since the agent was handed over.
fn takeBack(id: []const u8, agent: *const Agent, key: []const u8, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    if (agent.away != null) try out.append(a, .{ .attention_away_cleared = .{ .agent = id, .by = "takeback" } });
    try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = .handed_over, .to = .settled, .at = now } });
    const payload = try std.json.Stringify.valueAlloc(a, .{ .agent = id, .since = agent.changed_at }, .{});
    try out.append(a, .{ .effect_requested = .{ .key = key, .kind = "harness.takeback", .payload = payload } });
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// `needs_you → running` once the last live request is resolved.
pub fn resumeAfter(agent: *const Agent, id: []const u8, resolved: Request, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (agent.state != .needs_you or resolved.stale or agent.live() != 1) return;
    try out.append(a, .{ .agent_state_changed = .{ .agent = id, .from = .needs_you, .to = .running, .at = now } });
}

/// Closes a turn: its live requests first,
/// then `turn.ended`, then the state: an interrupted turn of a `needs_you`
/// agent settles it directly (the stop edge); otherwise `needs_you →
/// running` if it was blocked, and `running → settled` (completed,
/// interrupted) or `running → failed` (failed, limit, anything else).
/// If an `archive` is waiting for this turn, `→ archived` follows.
fn endTurn(agent: *const Agent, t: ev.TurnEnded, close_requests: bool, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) !void {
    if (close_requests) for (agent.requests.items) |r| if (!r.stale) {
        try out.append(a, .{ .request_resolved = .{ .agent = t.agent, .request = r.request, .by = "turn_end" } });
    };
    try oneshot.expire(agent, t.agent, t.turn, a, out);
    try out.append(a, .{ .turn_ended = t });
    const interrupted = std.mem.eql(u8, t.reason, "interrupted");
    var from = agent.state;
    if (from == .needs_you and !interrupted) {
        try out.append(a, .{ .agent_state_changed = .{ .agent = t.agent, .from = .needs_you, .to = .running, .at = now } });
        from = .running;
    }
    if (from != .running and from != .needs_you) return;
    const ok = interrupted or std.mem.eql(u8, t.reason, "completed");
    const to: AgentState = if (ok) .settled else .failed;
    try out.append(a, .{ .agent_state_changed = .{ .agent = t.agent, .from = from, .to = to, .at = now } });
    const archive = if (agent.stopping) |s| agent.archive_on_stop and std.mem.eql(u8, s, t.turn) else false;
    if (archive) try out.append(a, .{ .agent_state_changed = .{ .agent = t.agent, .from = to, .to = .archived, .at = now } });
}

fn openTurn(state: *const State, agent_id: []const u8, turn: []const u8) Rejection!void {
    const agent = state.agents.getPtr(agent_id) orelse return error.NotFound;
    const open = agent.open_turn orelse return error.Conflict;
    if (!std.mem.eql(u8, open, turn)) return error.Conflict;
}

/// Folds one committed event into `state`. Only fails on allocation.
pub fn evolve(state: *State, event: Event) error{OutOfMemory}!void {
    const a = state.arena.allocator();
    try state.usage.evolve(a, event);
    switch (event) {
        .daemon_started => {
            state.starts += 1;
            for (state.agents.values()) |*agent| {
                for (agent.requests.items) |*r| r.stale = true;
                // The process that had the task is gone: back in line.
                if (agent.state == .queued) agent.dispatched = false;
            }
        },
        .turn_started, .turn_prompt, .text, .turn_ended => {
            const copy = try event.dupe(a);
            const id = switch (copy) {
                inline .turn_started, .turn_prompt, .text, .turn_ended => |p| p.agent,
                else => unreachable,
            };
            const agent = try getOrPutAgent(state, id);
            try agent.transcript.append(a, copy);
            switch (copy) {
                .turn_started => |t| {
                    agent.open_turn = t.turn;
                    agent.turns += 1;
                    oneshot.arm(agent, t.turn);
                },
                .text => agent.messages += 1,
                .turn_ended => |t| {
                    if (oneshot.processGone(t)) for (agent.requests.items) |*r| {
                        r.stale = true;
                    };
                    agent.open_turn = null;
                    agent.stopping = null;
                    agent.archive_on_stop = false;
                },
                else => {},
            }
        },
        .request => |r| {
            const agent = try getOrPutAgent(state, r.agent);
            const copy = (try event.dupe(a)).request;
            try agent.requests.append(a, .{ .request = copy.request, .kind = copy.kind, .reason = copy.reason, .call = copy.call, .answers = copy.answers, .at = copy.at, .grant = copy.grant, .outside_scope = copy.outside_scope, .tool = copy.tool, .input_digest = copy.input_digest, .options = copy.options });
            agent.raised += 1;
        },
        .request_resolved => |r| if (state.agents.getPtr(r.agent)) |agent| {
            if (agent.pending(r.request)) |i| {
                _ = agent.requests.orderedRemove(i);
                try agent.resolved.append(a, try a.dupe(u8, r.request));
            }
        },
        .attention_snoozed, .attention_away, .attention_away_cleared => try attention.evolve(state, event),
        .always_granted, .always_revoked => try always.evolve(state, event),
        .decision_recorded, .decision_closed, .request_reopened => try oneshot.evolve(state, event),
        .effect_requested => |e| {
            const copy = (try event.dupe(a)).effect_requested;
            try state.effects.put(a, copy.key, .{ .key = copy.key, .kind = copy.kind, .payload = copy.payload });
            _ = e;
        },
        .effect_completed => |c| if (state.effects.getPtr(c.key)) |effect| {
            effect.done = true;
            effect.ok = c.ok;
            effect.detail = try a.dupe(u8, c.detail);
        },
        .agent_created => {
            const c = (try event.dupe(a)).agent_created;
            const agent = try getOrPutAgent(state, c.agent);
            agent.* = .{ .title = c.title, .harness = c.harness, .workspace = c.workspace, .repos = c.repos, .parent = c.parent, .issue = c.issue, .harness_session = c.harness_session, .fork_source = c.fork_source, .cwd = c.cwd, .worktrees = c.worktrees, .borrowed = c.borrowed, .task = c.task, .mode = c.mode, .spawn_model = c.spawn_model, .provider = c.provider, .home = c.home, .grants = c.grants, .state = c.state, .created_at = c.at, .changed_at = c.at };
        },
        .agent_dispatched => |d| if (state.agents.getPtr(d.agent)) |agent| {
            agent.dispatched = true;
        },
        .mcp_servers => if (state.agents.getPtr(event.mcp_servers.agent)) |agent| {
            agent.mcp_servers = (try event.dupe(a)).mcp_servers.servers;
        },
        .agent_mcp_off => if (state.agents.getPtr(event.agent_mcp_off.agent)) |agent| {
            var off: std.ArrayList([]const u8) = .empty;
            try off.appendSlice(a, agent.mcp_off);
            for ((try event.dupe(a)).agent_mcp_off.servers) |s| if (!contains(off.items, s)) try off.append(a, s);
            agent.mcp_off = off.items;
        },
        .agent_fork_ended => if (state.agents.getPtr(event.agent_fork_ended.agent)) |agent| {
            try agent.forks.append(a, (try event.dupe(a)).agent_fork_ended);
        },
        .agent_revoked => |r| if (state.agents.getPtr(r.agent)) |agent| {
            agent.revoked = true;
        },
        .agent_promoted => |p| if (state.agents.getPtr(p.agent)) |agent| {
            agent.parent = null;
        },
        .child_prompted => |p| if (state.agents.getPtr(p.agent)) |agent| {
            if (agent.child_prompts.items.len >= child_prompts_max) _ = agent.child_prompts.orderedRemove(0);
            try agent.child_prompts.append(a, .{ .child = try a.dupe(u8, p.child), .text = try a.dupe(u8, p.text), .at = p.at });
        },
        .agent_stop_requested => |r| if (state.agents.getPtr(r.agent)) |agent| {
            agent.stopping = try a.dupe(u8, r.turn);
            agent.archive_on_stop = r.archive;
        },
        .agent_state_changed => |c| {
            const agent = try getOrPutAgent(state, c.agent);
            // A settled agent is unread until opened; coming back from the
            // harness's own TUI, the user has just seen it.
            // Leaving the queue on `stop` ran no turn: nothing to read.
            if (c.to == .settled) agent.unread = c.from == .running or c.from == .needs_you;
            if (c.to != .settled) agent.unread = false;
            if (c.from == .handed_over) {
                agent.pane = null;
                agent.pane_root = null;
            }
            // Out of the queue: a stop drops the held task unsent, a turn
            // has it already.
            if (c.from == .queued) {
                agent.task = null;
                agent.dispatched = false;
            }
            agent.state = c.to;
            agent.changed_at = c.at;
        },
        .agent_opened => |o| if (state.agents.getPtr(o.agent)) |agent| {
            agent.unread = false;
        },
        .workspace_added, .workspace_scanned, .workspace_removed => try workspaces.evolve(state, event),
        .tool_started, .tool_ended, .usage, .agent_binding => try harness.evolve(state, event),
        // Folded into the usage ledger above.
        .context, .plan_windows => {},
    }
}

fn getOrPutAgent(state: *State, id: []const u8) !*Agent {
    const a = state.arena.allocator();
    const slot = try state.agents.getOrPut(a, id);
    if (!slot.found_existing) {
        slot.key_ptr.* = try a.dupe(u8, id);
        slot.value_ptr.* = .{};
    }
    return slot.value_ptr;
}

/// Decides and folds in one step, without a log, at time 0. Test helper
/// and the reference for what `Engine.submit` does around its commit.
pub fn apply(state: *State, cmd: Command, scratch: std.mem.Allocator) !usize {
    return applyAt(state, cmd, 0, scratch);
}

pub fn applyAt(state: *State, cmd: Command, now: i64, scratch: std.mem.Allocator) !usize {
    var out: std.ArrayList(Event) = .empty;
    try decide(state, cmd, now, scratch, &out);
    for (out.items) |e| try evolve(state, e);
    return out.items.len;
}

const testing = std.testing;

fn create(state: *State, id: []const u8, s: std.mem.Allocator) !void {
    _ = try apply(state, .{ .create = .{ .agent = id, .title = "task", .harness = "claude-code", .workspace = "/w" } }, s);
}

test "decider: a turn with a request, an answer and its outbox effect" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    try testing.expectError(error.NotFound, apply(&state, .{ .record = .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m", .text = "x" } } }, s));
    try testing.expectError(error.NotFound, apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s));
    try create(&state, "a1", s);
    try testing.expectError(error.Conflict, apply(&state, .{ .create = .{ .agent = "a1", .title = "again", .harness = "codex", .workspace = "/w" } }, s));
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    // running → running is not a transition.
    try testing.expectError(error.InvalidTransition, apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t2", .origin = "user" } } }, s));
    try testing.expectError(error.Conflict, apply(&state, .{ .record = .{ .text = .{ .agent = "a1", .turn = "t9", .message = "m", .text = "x" } } }, s));
    _ = try apply(&state, .{ .record = .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m1", .text = "hello" } } }, s);
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "run zig build?" } } }, s);
    try testing.expectError(error.Conflict, apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "again" } } }, s));
    try testing.expectError(error.InvalidCommand, apply(&state, .{ .record = .{ .effect_completed = .{ .key = "k", .ok = true } } }, s));

    try testing.expectEqual(@as(usize, 3), try apply(&state, .{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow" } }, s));
    try testing.expectEqual(@as(usize, 0), state.agents.get("a1").?.requests.items.len);
    try testing.expectEqual(@as(usize, 1), state.pendingEffects());
    const effect = state.effects.get("respond:a1:r1").?;
    try testing.expectEqualStrings("harness.respond", effect.kind);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"request\":\"r1\",\"decision\":\"allow\",\"stale\":false,\"turn\":\"t1\",\"asked\":{\"request\":\"r1\",\"kind\":\"approval\",\"reason\":\"run zig build?\",\"answers\":[],\"stale\":false,\"at\":0,\"outside_scope\":false}}", effect.payload);
    try testing.expectError(error.NotFound, apply(&state, .{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow" } }, s));

    try testing.expectEqual(@as(usize, 1), try apply(&state, .{ .complete = .{ .key = "respond:a1:r1", .ok = true } }, s));
    // At-least-once delivery: a second completion is a no-op.
    try testing.expectEqual(@as(usize, 0), try apply(&state, .{ .complete = .{ .key = "respond:a1:r1", .ok = false } }, s));
    try testing.expect(state.effects.get("respond:a1:r1").?.ok);
    try testing.expectError(error.NotFound, apply(&state, .{ .complete = .{ .key = "nope", .ok = true } }, s));
}

test "decider: turn.ended closes the turn's requests first" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try create(&state, "a1", s);
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "question", .reason = "?" } } }, s);
    var out: std.ArrayList(Event) = .empty;
    try decide(&state, .{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } } }, 0, s, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("turn_end", out.items[0].request_resolved.by);
    try testing.expect(out.items[1] == .turn_ended);
    // needs_you → running → settled: only diagram edges.
    try testing.expectEqual(AgentState.needs_you, out.items[2].agent_state_changed.from);
    try testing.expectEqual(AgentState.settled, out.items[3].agent_state_changed.to);
    for (out.items) |e| try evolve(&state, e);
    try testing.expect(state.agents.get("a1").?.open_turn == null);
    try testing.expect(state.agents.get("a1").?.unread);
    try testing.expectError(error.Conflict, apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s));
}

test "decider: a start fails open turns and keeps requests as stale" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try apply(&state, .{ .start = .{} }, s);
    try create(&state, "a1", s);
    try create(&state, "a2", s);
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "rm -rf build?" } } }, s);
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a2", .turn = "t1", .origin = "user" } } }, s);
    _ = try apply(&state, .{ .record = .{ .turn_ended = .{ .agent = "a2", .turn = "t1", .reason = "completed" } } }, s);

    var out: std.ArrayList(Event) = .empty;
    try decide(&state, .{ .start = .{} }, 0, s, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expect(out.items[0] == .daemon_started);
    try testing.expectEqualStrings("a1", out.items[1].turn_ended.agent);
    try testing.expectEqualStrings("failed.daemon_restart", out.items[1].turn_ended.error_code.?);
    try testing.expectEqual(AgentState.failed, out.items[3].agent_state_changed.to);
    for (out.items) |e| try evolve(&state, e);
    const a1 = state.agents.get("a1").?;
    try testing.expectEqual(AgentState.failed, a1.state);
    try testing.expectEqual(AgentState.settled, state.agents.get("a2").?.state);
    try testing.expect(a1.open_turn == null);
    try testing.expectEqual(@as(usize, 1), a1.requests.items.len);
    try testing.expect(a1.requests.items[0].stale);
    try testing.expectEqual(@as(u64, 2), state.starts);
    // A stale request can still be answered.
    _ = try apply(&state, .{ .answer = .{ .agent = "a1", .request = "r1", .decision = "deny" } }, s);
    try testing.expect(std.mem.indexOf(u8, state.effects.get("respond:a1:r1").?.payload, "\"stale\":true") != null);
}

test "decider: a held task waits, is dispatched once, goes back in line on a start, and a stop drops it; promote cuts the parent link" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try apply(&state, .{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w", .task = "do it" } }, s);
    _ = try apply(&state, .{ .create = .{ .agent = "a2", .title = "t", .harness = "fake", .workspace = "/w", .parent = "a1", .task = "too" } }, s);
    try testing.expect(state.agents.getPtr("a1").?.waiting());
    try testing.expect(!state.agents.getPtr("a1").?.holdsSlot());

    _ = try apply(&state, .{ .dispatch = .{ .agent = "a1" } }, s);
    try testing.expect(state.agents.getPtr("a1").?.holdsSlot());
    try testing.expectError(error.InvalidTransition, apply(&state, .{ .dispatch = .{ .agent = "a1" } }, s));
    try testing.expectError(error.NotFound, apply(&state, .{ .dispatch = .{ .agent = "a9" } }, s));

    // The process that had the task died with the daemon.
    _ = try apply(&state, .{ .start = .{} }, s);
    try testing.expect(state.agents.getPtr("a1").?.waiting());
    try testing.expectEqualStrings("do it", state.agents.getPtr("a1").?.task.?);

    // A turn takes the task; a stop drops it.
    _ = try apply(&state, .{ .dispatch = .{ .agent = "a1" } }, s);
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    try testing.expect(state.agents.getPtr("a1").?.task == null);
    _ = try apply(&state, .{ .stop = .{ .agent = "a2" } }, s);
    try testing.expect(state.agents.getPtr("a2").?.task == null);
    try testing.expectError(error.InvalidTransition, apply(&state, .{ .dispatch = .{ .agent = "a2" } }, s));

    try testing.expectEqual(@as(usize, 1), try apply(&state, .{ .promote = .{ .agent = "a2" } }, s));
    try testing.expect(state.agents.getPtr("a2").?.parent == null);
    try testing.expectEqual(@as(usize, 0), try apply(&state, .{ .promote = .{ .agent = "a2" } }, s));
    _ = try apply(&state, .{ .archive = .{ .agent = "a2" } }, s);
    try testing.expectError(error.InvalidTransition, apply(&state, .{ .promote = .{ .agent = "a2" } }, s));
}

test "decider: child prompts are capped, in number and in length" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try create(&state, "a1", s);
    for (0..child_prompts_max + 5) |i| _ = try apply(&state, .{ .child_prompted = .{ .parent = "a1", .child = try std.fmt.allocPrint(s, "c{d}", .{i}), .text = "hi" } }, s);
    const list = state.agents.getPtr("a1").?.child_prompts.items;
    try testing.expectEqual(@as(usize, child_prompts_max), list.len);
    try testing.expectEqualStrings("c5", list[0].child);
    const long = try s.alloc(u8, child_prompt_text_max + 1);
    for (long, 0..) |*b, i| b.* = if (i % 2 == 0) 0xC3 else 0xA9;
    _ = try apply(&state, .{ .child_prompted = .{ .parent = "a1", .child = "c", .text = long } }, s);
    const kept = state.agents.getPtr("a1").?.child_prompts.items[child_prompts_max - 1].text;
    try testing.expect(kept.len <= child_prompt_text_max and std.unicode.utf8ValidateSlice(kept));
}
