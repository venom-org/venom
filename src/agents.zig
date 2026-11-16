//! The agent verbs:
//! `agent.spawn|list|show|send|stop|archive|wait|promote`. An agent is scoped to the
//! whole workspace, a set of its repos or one repo
//! (`eventlog/agent_scope.zig`) and isolated from them by a worktree per repo
//! in scope, a copy, or not at all (`isolation.zig`). An issue
//! link only names folders; the issue itself is not synced.
//!
//! The verbs are a thin layer over the event log and the harness host:
//!
//! - `spawn` validates the folder, picks the harness (`agents.default` in
//!   effect for the folder, when none is named), logs
//!   `agent.created` (`queued`, with its task) and, when a slot is free,
//!   sends the task through the host, which starts the harness process;
//!   `turn.started` then moves the agent to `running`. With no free slot
//!   (`agents.max_concurrent`) the task is held and `tick` starts
//!   the oldest waiting agent as slots free up; a daemon restart keeps the
//!   line, since the task is in the log. A send to a settled or failed
//!   agent is not held back: it is an explicit prompt, and a send to a
//!   waiting agent is `conflict.agent_queued`. Only the first prompt waits.
//!   The result is the state when the call returns, for example
//!   (`{"agent":"a12","state":"queued",...}`). If the harness
//!   cannot be started the agent is stopped again (`queued → settled`, the
//!   task unsent) and the error names it in `data.agent`.
//! - `send` goes to the host (`send` and its modes).
//! - `stop` and `archive` are the decider's `stop` / `archive` commands:
//!   a running turn is interrupted through a `harness.stop`
//!   effect, so the result may still say `running`; `agent.state_changed`
//!   on `venom events` reports when it settles (or is archived).
//! - `archive --clean` and `clean` remove an archived agent's worktrees and
//!   branches, keeping and reporting any that hold work found nowhere else;
//!   `clean --merged` does so only for merged PRs (`cleanup.zig`).
//! - `takeover_split` and `harness.hook`: attention while handed
//!   over; see those verbs.
//! - `takeover` and `takeback` hand a settled
//!   agent's conversation to its harness's own TUI and take it back,
//!   importing the turns and usage that ran there.
//!
//! Sub-agents: an agent's harness that calls
//! `spawn` over venom's MCP server, or anything with a token that agent
//! issued (`Principals.callerAgent`), makes a child with a parent link. Only
//! a parent with work in hand may (`conflict.parent_stopped`), so nothing
//! appears behind a stop. Its scope stays within the parent's
//! (`denied.spawn_scope`). A child on another harness must be held to the
//! parent's mode: on a harness without that mode it runs in `plan`, and a
//! harness with neither refuses it (`denied.spawn_harness`). It gets
//! its own worktree (`isolation` defaults to `worktree`, and `in_place` under
//! an isolated parent is `denied.spawn_isolation`), and its parent's scope
//! (when it names none), harness, model, permission mode and grants, never
//! more: `denied.delegation`, `denied.spawn_model`, `denied.spawn_mode`
//! (`bypass_permissions` is wider than `auto`, then `accept_edits`, then
//! `ask`, then `plan`).
//! `agents.spawn.allow` (`denied.spawn_disabled`) and `agents.spawn.depth`
//! (`denied.spawn_depth`; the top-level agent is depth 1) limit the tree.
//! `stop --tree` stops an agent and everything below it, parents first so
//! nothing new is spawned behind the stop. `wait` holds its call until
//! everything below the agent has finished. An agent with an open `wait` gives
//! up its concurrency slot, so its queued children can run; it takes one back
//! (possibly over the limit, as a send does) once the wait ends. `promote` is for
//! people only: an agent promoting itself or a child would escape the depth
//! limit (`denied.promote`). `send` by anyone but the parent logs
//! `agent.child_prompted`, which `agent.show` of the parent lists; venom does
//! not put it into the parent's running conversation.
//!
//! Error codes are stable (exit codes in parentheses):
//! `not_found.agent` (3) for an unknown agent; `conflict.invalid_transition`
//! (5) for a send to an archived agent; `conflict.agent_handed_over` (5) for
//! stop or archive of a `handed_over` agent; `conflict.handed_over`,
//! `conflict.turn_running`, `unsupported.*` and `unavailable.*` from the
//! adapter.
//!
//! Grants (the table is in principals.zig):
//! reads need `read` on the agent (`agent.list` filters), `send`, `stop`
//! and `archive` need `write` on it, and `spawn` needs `write` and `spawn`
//! on the workspace. A spawn issues the agent its own principal, attenuated
//! from the caller's (`grants` param, `denied.delegation` beyond them);
//! an agent that spawns gets a sub-agent. Archiving revokes the principal.
//!
//! Everything runs on the daemon's reactor thread, like the engine.
const std = @import("std");
const proto = @import("proto");
const supervisor = @import("supervisor");
const config = @import("config.zig");
const scope = @import("scope.zig");
const harnesses = @import("harnesses.zig");
const isolation = @import("isolation.zig");
const cleanup = @import("cleanup.zig");
const takeover_pane = @import("takeover_pane.zig");
const eventlog = @import("eventlog/root.zig");
const harness = @import("harness/root.zig");
const rules = eventlog.workspaces;
const agent_scope = eventlog.agent_scope;
const Engine = eventlog.Engine;
const Agent = eventlog.decider.Agent;
const Principals = @import("principals.zig").Principals;
const readable = @import("principals.zig").readable;
const Permissions = @import("permissions.zig").Permissions;

/// Titles taken from the task are cut to this many bytes (on a UTF-8
/// boundary).
pub const title_max = 72;

pub const Agents = struct {
    engine: *Engine,
    host: *harness.Host,
    io: std.Io,
    /// The daemon's user-level config, for `agents.default` outside any
    /// workspace.
    config: *config.Store,
    /// Workspace and repo files above it. Null: user config only.
    layers: ?*const scope.Layers = null,
    /// Agent principals. Null: no principals are issued.
    principals: ?*Principals = null,
    /// The `gh` program for merged-PR detection; tests stub it.
    gh: []const u8 = "gh",
    gh_timeout_ms: i64 = 15_000,
    /// A clean call stops starting on worktrees after this long.
    clean_budget_ms: i64 = 60_000,

    spawn_: Spawn = undefined,
    list_: List = undefined,
    show_: Show = undefined,
    tool_: ToolCall = undefined,
    send_: Send = undefined,
    stop_: Stop = undefined,
    archive_: Archive = undefined,
    clean_: Clean = undefined,
    takeover_: Takeover = undefined,
    takeback_: Takeback = undefined,
    takeover_split_: TakeoverSplit = undefined,
    takeover_pane_: TakeoverPane = undefined,
    /// To ask venomx whether a take-over's pane still runs (takeover_pane.zig).
    environ: ?std.process.Environ = null,
    hook_: Hook = undefined,
    wait_: Wait = undefined,
    promote_: Promote = undefined,
    /// `harness.permission_prompt` (permissions.zig).
    permissions_: Permissions = undefined,
    /// Open `agent.wait` calls, oldest first.
    waits: std.ArrayList(OpenWait) = .empty,
    /// Learned from the first `agent.wait` or held spawn: the owner of its
    /// tickets.
    dispatcher: ?*proto.Dispatcher = null,
    /// Asks a vendor harness whether it is signed in, off the reactor.
    /// Null: spawns are not checked.
    discovery: ?*harnesses.Discovery = null,
    /// `agent.spawn` calls held until their harness answers, oldest first.
    held_spawns: std.ArrayList(HeldSpawn) = .empty,
    /// `agent.send` calls that would start the harness again (`reattach`),
    /// held the same way.
    held_sends: std.ArrayList(HeldSend) = .empty,
    /// The sign-in answers that landed this reactor turn, by target. The
    /// held calls and the queue's start gate all read them: a question is
    /// answered once, for everyone who waited on it.
    answers: [harnesses.known.len]?harness.discovery.SignIn = @splat(null),

    const OpenWait = struct { ticket: proto.Ticket, agent: []u8, caller: ?[]u8, deadline_ms: i64 };
    /// `params` lives in the call's arena, as long as the call.
    const HeldSpawn = struct { ticket: proto.Ticket, params: Spawn.Params, target: usize };
    const HeldSend = struct { ticket: proto.Ticket, params: Send.Params, target: usize };

    fn freeWait(self: *Agents, w: OpenWait) void {
        self.engine.gpa.free(w.agent);
        if (w.caller) |x| self.engine.gpa.free(x);
    }

    /// An agent with an open `agent.wait` call gives up its concurrency slot
    /// so its queued children can run; it counts again once the wait ends.
    fn slotReleased(ctx: *anyopaque, id: []const u8) bool {
        const self: *Agents = @ptrCast(@alignCast(ctx));
        for (self.waits.items) |w| if (w.caller) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }

    pub fn deinit(self: *Agents) void {
        self.held_spawns.deinit(self.engine.gpa);
        self.held_sends.deinit(self.engine.gpa);
        if (self.waits.capacity == 0) return;
        for (self.waits.items) |w| self.freeWait(w);
        self.waits.deinit(self.engine.gpa);
    }

    /// The fifteen bindings. `self` must not move afterwards.
    pub fn bindings(self: *Agents) [16]proto.Binding {
        self.spawn_ = .{ .agents = self };
        self.list_ = .{ .agents = self };
        self.show_ = .{ .agents = self };
        self.tool_ = .{ .agents = self };
        self.send_ = .{ .agents = self };
        self.stop_ = .{ .agents = self };
        self.archive_ = .{ .agents = self };
        self.clean_ = .{ .agents = self };
        self.takeover_ = .{ .agents = self };
        self.takeback_ = .{ .agents = self };
        self.takeover_split_ = .{ .agents = self };
        self.takeover_pane_ = .{ .agents = self };
        self.hook_ = .{ .agents = self };
        self.wait_ = .{ .agents = self };
        self.promote_ = .{ .agents = self };
        self.host.slot_released = .{ .ctx = self, .released = slotReleased };
        self.host.start_gate = .{ .ctx = self, .check = startGate };
        self.permissions_ = .{ .host = self.host, .principals = self.principals };
        return .{
            .{ .verb = "agent.spawn", .handler = proto.VerbHandler.typed(Spawn.Params, &self.spawn_) },
            .{ .verb = "agent.list", .handler = proto.VerbHandler.typed(List.Params, &self.list_) },
            .{ .verb = "agent.show", .handler = proto.VerbHandler.typed(Show.Params, &self.show_) },
            .{ .verb = "agent.tool", .handler = proto.VerbHandler.typed(ToolCall.Params, &self.tool_) },
            .{ .verb = "agent.send", .handler = proto.VerbHandler.typed(Send.Params, &self.send_) },
            .{ .verb = "agent.stop", .handler = proto.VerbHandler.typed(Stop.Params, &self.stop_) },
            .{ .verb = "agent.archive", .handler = proto.VerbHandler.typed(Archive.Params, &self.archive_) },
            .{ .verb = "agent.clean", .handler = proto.VerbHandler.typed(Clean.Params, &self.clean_) },
            .{ .verb = "agent.takeover", .handler = proto.VerbHandler.typed(Takeover.Params, &self.takeover_) },
            .{ .verb = "agent.takeback", .handler = proto.VerbHandler.typed(Takeback.Params, &self.takeback_) },
            .{ .verb = "agent.takeover_pane", .handler = proto.VerbHandler.typed(TakeoverPane.Params, &self.takeover_pane_) },
            .{ .verb = "agent.takeover_split", .handler = proto.VerbHandler.typed(TakeoverSplit.Params, &self.takeover_split_) },
            .{ .verb = "harness.hook", .handler = proto.VerbHandler.typed(Hook.Params, &self.hook_) },
            .{ .verb = "agent.wait", .handler = proto.VerbHandler.typed(Wait.Params, &self.wait_) },
            .{ .verb = "agent.promote", .handler = proto.VerbHandler.typed(AgentParams, &self.promote_) },
            self.permissions_.binding(),
        };
    }

    /// The replier the claude-code adapter answers permission prompts
    /// through. Valid once `bindings` ran; `self` must not move.
    pub fn replier(self: *Agents) harness.claude_code.Replier {
        return self.permissions_.replier();
    }

    /// One reactor turn: starts queued agents as slots free up and ends the
    /// `agent.wait` calls whose children finished or whose time ran out.
    pub fn tick(self: *Agents) !void {
        if (self.principals) |pr| try pr.recordRevoked();
        if (self.discovery) |asked| for (&self.answers, 0..) |*answer, i| {
            answer.* = asked.takeSignIn(i);
        };
        try self.host.dispatchQueued(self.config.current().agents.max_concurrent);
        const d = self.dispatcher orelse return;
        try self.resumeSpawns(d);
        try self.resumeSends(d);
        const now = supervisor.monotonicMs();
        var i: usize = 0;
        while (i < self.waits.items.len) {
            const w = self.waits.items[i];
            const open = d.get(w.ticket);
            if (open) |c| {
                // This runs every turn: not in the call's arena, which lives on.
                var scratch: std.heap.ArenaAllocator = .init(self.engine.gpa);
                defer scratch.deinit();
                const ended = try finishedBelow(scratch.allocator(), self.state(), w.agent);
                if (!ended and now < w.deadline_ms) {
                    i += 1;
                    continue;
                }
                try Wait.reply(self, c, w.agent, ended);
            }
            self.freeWait(w);
            _ = self.waits.orderedRemove(i);
        }
    }

    /// Ends or continues the held spawns whose harness has answered. A call
    /// that went away while held is dropped: nothing was made for it.
    fn resumeSpawns(self: *Agents, d: *proto.Dispatcher) !void {
        if (self.held_spawns.items.len == 0) return;
        const asked = self.discovery orelse return;
        // Continuing a spawn can hold it again, so walk a list of its own.
        var held = self.held_spawns;
        self.held_spawns = .empty;
        defer held.deinit(self.engine.gpa);
        for (held.items) |w| {
            const answer = self.answers[w.target] orelse {
                try self.held_spawns.append(self.engine.gpa, w);
                continue;
            };
            const c = d.get(w.ticket) orelse continue;
            self.spawn_.resumeHeld(c, w, answer, asked) catch |err| {
                // What the dispatcher does for an error from a handler.
                if (d.get(w.ticket)) |open| open.fail("internal", @errorName(err), .{ .verb = "agent.spawn" }) catch {};
                if (err == error.OutOfMemory) return err;
            };
        }
    }

    /// Like `resumeSpawns`, for the held sends. The send goes through all its
    /// checks again, as the agent may have changed meanwhile.
    fn resumeSends(self: *Agents, d: *proto.Dispatcher) !void {
        if (self.held_sends.items.len == 0) return;
        const asked = self.discovery orelse return;
        var held = self.held_sends;
        self.held_sends = .empty;
        defer held.deinit(self.engine.gpa);
        for (held.items) |w| {
            const answer = self.answers[w.target] orelse {
                try self.held_sends.append(self.engine.gpa, w);
                continue;
            };
            const c = d.get(w.ticket) orelse continue;
            self.send_.resumeHeld(c, w, answer, asked) catch |err| {
                if (d.get(w.ticket)) |open| open.fail("internal", @errorName(err), .{ .verb = "agent.send" }) catch {};
                if (err == error.OutOfMemory) return err;
            };
        }
    }

    /// The queue's check before a waiting agent's harness is started: its
    /// sign-in, asked off the reactor (the queue waits for the answer).
    fn startGate(ctx: *anyopaque, id: []const u8) harness.host.StartGate.Verdict {
        const self: *Agents = @ptrCast(@alignCast(ctx));
        const asked = self.discovery orelse return .go;
        const x = self.get(id) orelse return .go;
        const target = asked.signInTarget(x.harness) orelse return .go;
        if (self.answers[target]) |answer| return if (answer.signed_in == false) .signed_out else .go;
        asked.askSignIn(target);
        return .wait;
    }

    fn state(self: *const Agents) *const eventlog.State {
        return &self.engine.state;
    }

    fn get(self: *const Agents, id: []const u8) ?*const Agent {
        return self.state().agents.getPtr(id);
    }

    /// The next free `a<n>` id. Agents are never removed from the log, so
    /// the count only grows.
    fn nextId(self: *const Agents, a: std.mem.Allocator) ![]const u8 {
        return eventlog.decider.nextAgentId(self.state(), a);
    }

    fn cleaner(self: *const Agents, a: std.mem.Allocator) cleanup.Cleaner {
        return .{ .a = a, .io = self.io, .gh = self.gh, .gh_timeout_ms = self.gh_timeout_ms, .deadline_ms = supervisor.monotonicMs() + self.clean_budget_ms };
    }

    /// One entry per worktree or copy of `id`. A worktree is only touched
    /// once the agent and its sub-agents are archived and no process of
    /// theirs is left.
    fn cleanAgent(self: *Agents, cl: *cleanup.Cleaner, a: std.mem.Allocator, id: []const u8, mode: cleanup.Mode, out: *std.ArrayList(cleanup.Entry)) !void {
        const x = self.get(id) orelse return;
        var active = x.state != .archived or activeDescendant(self.state(), id);
        if (!active) active = !self.retireTree(a, id);
        // Looked up again: retiring ran the host's poll.
        const y = self.get(id) orelse return;
        // A fork's are its parent's, cleaned with it.
        if (y.borrowed) return;
        for (y.worktrees) |w| try out.append(a, if (active) cleanup.Cleaner.active(id, w) else try cl.clean(id, y.workspace, w, mode));
    }

    /// Ends the idle processes of `id` and its descendants. False if one
    /// would not go.
    fn retireTree(self: *Agents, a: std.mem.Allocator, id: []const u8) bool {
        var ids: std.ArrayList([]const u8) = .empty;
        ids.append(a, id) catch return false;
        var i: usize = 0;
        const all = self.state().agents;
        while (i < ids.items.len) : (i += 1) {
            for (all.keys(), all.values()) |k, *x| {
                const parent = x.parent orelse continue;
                if (std.mem.eql(u8, parent, ids.items[i])) ids.append(a, a.dupe(u8, k) catch return false) catch return false;
            }
        }
        for (ids.items) |k| self.host.retire(k) catch return false;
        return true;
    }

    fn registered(self: *const Agents, name: []const u8) bool {
        for (self.host.adapters) |r| if (std.mem.eql(u8, r.harness, name)) return true;
        return false;
    }
};

pub const AgentParams = struct { agent: []const u8 };

/// One agent as `agent.list` shows it (and `agent.show` starts with).
const Summary = struct {
    agent: []const u8,
    title: []const u8,
    harness: []const u8,
    state: []const u8,
    unread: bool,
    workspace: []const u8,
    /// The scope: empty for the whole workspace.
    repos: []const []const u8,
    cwd: []const u8,
    created_at: i64,
    changed_at: i64,
    parent: ?[]const u8,
    issue: ?[]const u8,
    children_needs_you: u32 = 0,
    children_failed: u32 = 0,

    fn of(id: []const u8, x: *const Agent) Summary {
        return .{ .parent = x.parent, .issue = x.issue, .agent = id, .title = x.title, .harness = x.harness, .state = @tagName(x.state), .unread = x.unread, .workspace = x.workspace, .repos = x.repos, .cwd = x.cwd orelse x.workspace, .created_at = x.created_at, .changed_at = x.changed_at };
    }
};

/// Per ancestor, the descendants in `needs_you` and `failed` the caller may
/// read, bubbled up the tree. Keys are agent IDs.
const Bubbles = std.StringHashMapUnmanaged(struct { needs_you: u32 = 0, failed: u32 = 0 });

fn bubbles(c: *proto.Call, state: *const eventlog.State) !Bubbles {
    const a = c.arena();
    var out: Bubbles = .empty;
    for (state.agents.keys(), state.agents.values()) |id, *x| {
        if (x.state != .needs_you and x.state != .failed) continue;
        if (!readable(c, agentResource(id))) continue;
        var up = x.parent;
        while (up) |p| {
            const slot = try out.getOrPutValue(a, p, .{});
            if (x.state == .needs_you) slot.value_ptr.needs_you += 1 else slot.value_ptr.failed += 1;
            up = (state.agents.getPtr(p) orelse break).parent;
        }
    }
    return out;
}

/// The agents below `root` (all levels), parents first.
fn below(a: std.mem.Allocator, state: *const eventlog.State, root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, root);
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        for (state.agents.keys(), state.agents.values()) |id, *x| {
            if (x.parent) |p| if (std.mem.eql(u8, p, out.items[i])) try out.append(a, id);
        }
    }
    return out.items[1..];
}

fn finishedBelow(a: std.mem.Allocator, state: *const eventlog.State, root: []const u8) !bool {
    for (try below(a, state, root)) |id| switch (state.agents.getPtr(id).?.state) {
        .settled, .failed, .archived => {},
        else => return false,
    };
    return true;
}

const ChildState = struct { agent: []const u8, state: []const u8 };

fn childStates(a: std.mem.Allocator, state: *const eventlog.State, root: []const u8) ![]const ChildState {
    const ids = try below(a, state, root);
    const out = try a.alloc(ChildState, ids.len);
    for (ids, out) |id, *o| o.* = .{ .agent = id, .state = @tagName(state.agents.getPtr(id).?.state) };
    return out;
}

/// Tree depth of `x`, counting a top-level agent as 1.
fn depthOf(state: *const eventlog.State, x: *const Agent) u32 {
    var depth: u32 = 1;
    var up = x.parent;
    while (up) |p| : (depth += 1) up = (state.agents.getPtr(p) orelse break).parent;
    return depth;
}

/// Whether the parent has work in hand: a turn that isn't being stopped, or
/// a send on its way (its `turn.started` may not be read yet).
/// The limits on an agent that makes an agent: `caller` is the agent asking,
/// and must be at work. `depth` is the new agent's. False: the call has failed.
fn withinSpawnLimits(ag: *const Agents, c: *proto.Call, defaults: Defaults, caller: []const u8, x: *const Agent, depth: u32) !bool {
    if (!defaults.spawn_allow) {
        try c.fail("denied.spawn_disabled", "agents.spawn.allow is off: agents may not spawn agents here", .{ .parent = caller });
        return false;
    }
    if (depth > defaults.spawn_depth) {
        try c.fail("denied.spawn_depth", "the sub-agent would be deeper than agents.spawn.depth", .{ .parent = caller, .depth = depth, .limit = defaults.spawn_depth });
        return false;
    }
    if (!parentAtWork(ag, caller, x)) {
        try c.fail("conflict.parent_stopped", "the parent is stopping or has no turn running: it may not spawn now", .{ .parent = caller, .state = @tagName(x.state) });
        return false;
    }
    return true;
}

/// `agent.fork`'s check when an agent asks: a fork grows a tree as a
/// spawn does. The new agent sits under `source`, so `source` sets its depth and
/// the config in effect. At work must be the caller: `source` is between turns
/// by definition, and may be its settled child. People pass.
pub fn forkAllowed(ag: *Agents, c: *proto.Call, source: *const Agent) !bool {
    const pr = ag.principals orelse return true;
    const caller = pr.callerAgent(c.conn.identity) orelse return true;
    const x = ag.get(caller) orelse return true;
    const a = c.arena();
    const cwd = source.cwd orelse source.workspace;
    const repo: ?[]const u8 = if (source.repos.len == 1) try agent_scope.repoPath(a, source.workspace, source.repos[0]) else null;
    const defaults = try scopedDefaults(ag, c, rules.owner(ag.state(), source.workspace), cwd, repo) orelse return false;
    return withinSpawnLimits(ag, c, defaults, caller, x, depthOf(ag.state(), source) + 1);
}

fn parentAtWork(ag: *const Agents, id: []const u8, x: *const Agent) bool {
    if (x.stopping != null) return false;
    return switch (x.state) {
        .running, .needs_you => true,
        else => ag.host.working(id),
    };
}

/// Whether a child's scope stays within parent `x`'s: a whole-workspace
/// parent's folder, or repos it has in scope.
fn withinScope(a: std.mem.Allocator, x: *const Agent, workspace: []const u8, repos: []const []const u8) !bool {
    if (x.repos.len == 0) return rules.within(x.workspace, workspace);
    if (!std.mem.eql(u8, x.workspace, workspace) or repos.len == 0) return false;
    for (repos) |r| {
        const path = try agent_scope.repoPath(a, workspace, r);
        for (x.repos) |own| {
            if (rules.within(try agent_scope.repoPath(a, workspace, own), path)) break;
        } else return false;
    }
    return true;
}

/// How much a mode allows without asking: a child may only narrow it.
fn modeWidth(m: config.Mode) u8 {
    return switch (m) {
        .plan => 0,
        .ask => 1,
        .accept_edits => 2,
        .auto => 3,
        .bypass_permissions => 4,
    };
}

pub fn agentResource(id: []const u8) proto.grants.Resource {
    return .{ .kind = "agent", .id = id };
}

pub fn notFound(c: *proto.Call, id: []const u8) !void {
    return c.fail("not_found.agent", "no such agent; see agent list", .{ .agent = id });
}

/// Reports a host (adapter) error; anything else is returned.
pub fn hostFailure(c: *proto.Call, err: anyerror, id: []const u8, x: ?*const Agent) !void {
    switch (err) {
        error.NotFound => return notFound(c, id),
        error.InvalidTransition => return c.fail("conflict.invalid_transition", "the agent's state does not allow this", .{ .agent = id, .state = if (x) |v| @tagName(v.state) else "" }),
        error.ShuttingDown => return c.fail("unavailable.shutting_down", "the daemon is shutting down", .{ .agent = id }),
        else => {},
    }
    const f = harness.contract.failure(err) orelse return err;
    return c.fail(f.code, @errorName(err), .{ .agent = id });
}

/// The refusal of a harness with no usable sign-in:
/// `data.fix` is its own sign-in command.
fn notSignedIn(c: *proto.Call, asked: *harnesses.Discovery, target: usize) !void {
    return c.fail("unavailable.harness_not_signed_in", "the harness is not signed in; run its sign-in command", .{
        .param = "harness",
        .harness = asked.targets[target].known.name,
        .fix = try asked.signInFix(c.arena(), target),
    });
}

/// `agent.spawn` (write).
///
/// Scope: `workspace` and `repos` name the whole
/// workspace, a set of its repos, or one repo (`agent_scope.resolve`); the
/// agent belongs to the closest workspace holding the scope root and starts
/// at that workspace's root unless `cwd` names a folder inside it. With
/// `cwd` alone the scope is the whole workspace holding it (in place).
///
/// Isolation: `isolation`, else `agents.isolation`
/// in effect for the folder. `worktree` and `copy` make one checkout per
/// repo in scope (every repo of the workspace for a whole-workspace scope)
/// named by `issue` or the agent id, all checked before any is made; a
/// scope with no repos (a repo-less workspace, or a folder in none) runs
/// in place. A single checkout becomes the agent's cwd (a `cwd` inside a
/// repo moves into its checkout); with several the agent starts at the
/// workspace root, where they sit. The checkouts are writable to the
/// agent and the repos they came from read-only. `dry_run` returns the
/// same result without making or starting anything (`agent` is the id the
/// next spawn would get; grants are not checked).
///
/// Sign-in: a vendor harness that reports no usable
/// sign-in is refused with `unavailable.harness_not_signed_in`, `data.fix`
/// being its own sign-in command, a dry run included. Its status command can
/// take seconds, so it never runs on the reactor: once every other check has
/// passed the call is held, `Discovery.askSignIn` asks on a thread, and
/// `Agents.tick` picks the call up from the answer. It then goes through all
/// the checks again, since the log and the config may have moved meanwhile.
/// Nothing is made before that. Only a "no" refuses: when the harness cannot
/// tell, the spawn goes on and the harness reports its own failure.
pub const Spawn = struct {
    agents: *Agents,
    pub const Params = struct { task: []const u8, cwd: ?[]const u8 = null, workspace: ?[]const u8 = null, repos: ?[]const []const u8 = null, harness: ?[]const u8 = null, provider: ?[]const u8 = null, mode: ?[]const u8 = null, model: ?[]const u8 = null, title: ?[]const u8 = null, grants: ?[]const proto.grants.Grant = null, isolation: ?[]const u8 = null, issue: ?[]const u8 = null, branch: ?[]const u8 = null, dry_run: bool = false };

    pub fn call(self: *Spawn, c: *proto.Call, p: Params) anyerror!void {
        return self.run(c, p, null);
    }

    fn resumeHeld(self: *Spawn, c: *proto.Call, w: Agents.HeldSpawn, answer: harness.discovery.SignIn, asked: *harnesses.Discovery) !void {
        if (answer.signed_in == false) return notSignedIn(c, asked, w.target);
        return self.run(c, w.params, w.target);
    }

    /// `checked`: the sign-in target that has already answered for this call.
    fn run(self: *Spawn, c: *proto.Call, p: Params, checked: ?usize) anyerror!void {
        const ag = self.agents;
        const a = c.arena();
        if (std.mem.trim(u8, p.task, " \t\r\n").len == 0) return c.fail("invalid_params.task", "the task is empty", .{ .param = "task" });
        const issue: ?[]const u8 = if (p.issue) |i| try isolation.issueSuffix(a, i) orelse return c.fail("invalid_params.issue", "an issue is a number: 246, #246 or owner/repo#246", .{ .param = "issue", .issue = i }) else null;
        if (p.cwd) |cwd| if (!rules.validPath(cwd)) return c.fail("invalid_params.cwd", "cwd must be absolute and normalized", .{ .param = "cwd", .path = cwd });
        if (p.workspace) |w| if (!rules.validPath(w)) return c.fail("invalid_params.workspace", "workspace must be absolute and normalized", .{ .param = "workspace", .path = w });
        // An agent's harness that spawns makes a sub-agent.
        const parent: ?[]const u8 = if (ag.principals) |pr| if (pr.callerAgent(c.conn.identity)) |x| try a.dupe(u8, x) else null else null;
        const parent_agent: ?Agent = if (parent) |x| (if (ag.get(x)) |v| v.* else null) else null;
        const base = p.workspace orelse p.cwd orelse if (parent_agent) |x| x.workspace else return c.fail("invalid_params.workspace", "name a workspace or a cwd", .{ .param = "workspace" });
        // A sub-agent naming no scope gets its parent's.
        const repos = p.repos orelse if (parent_agent != null and p.workspace == null and p.cwd == null) parent_agent.?.repos else &.{};
        // The scope, from the log alone; authorized before the folder is
        // looked at.
        const resolved: agent_scope.Resolved = if (p.workspace == null and repos.len == 0) blk: {
            const owner = rules.owner(ag.state(), base);
            break :blk .{ .workspace = if (owner) |w| try a.dupe(u8, w.path) else base, .repos = &.{} };
        } else blk: {
            var why: agent_scope.Failure = undefined;
            break :blk try agent_scope.resolve(a, ag.state(), base, repos, &why) orelse return switch (why) {
                .no_workspace => c.fail("not_found.workspace", "no workspace holds these repos; see workspace add", .{ .param = "workspace", .path = base }),
                .not_a_scope => c.fail("invalid_params.workspace", "the folder is inside a workspace but holds none of its repos", .{ .param = "workspace", .path = base }),
                .invalid_repo => |r| c.fail("invalid_params.repos", "a repo must be relative to the workspace and normalized", .{ .param = "repos", .repo = r }),
                .unknown_repo => |r| c.fail("not_found.repo", "the workspace has no such repo; see workspace scan", .{ .param = "repos", .repo = r }),
            };
        };
        const workspace = resolved.workspace;
        const cwd = p.cwd orelse workspace;
        if (!rules.within(workspace, cwd)) return c.fail("invalid_params.cwd", "cwd must be inside the agent's workspace", .{ .param = "cwd", .path = cwd, .workspace = workspace });
        const ws: proto.grants.Resource = .{ .kind = "workspace", .id = workspace };
        if (!try c.authorize(.write, ws)) return;
        if (!try c.authorize(.spawn, ws)) return;
        const param = if (p.cwd != null) "cwd" else "workspace";
        var dir = std.Io.Dir.openDirAbsolute(ag.io, cwd, .{}) catch |err| switch (err) {
            error.FileNotFound => return c.fail(if (p.cwd != null) "not_found.cwd" else "not_found.workspace", "the folder does not exist", .{ .param = param, .path = cwd }),
            error.NotDir => return c.fail(if (p.cwd != null) "invalid_params.cwd" else "invalid_params.workspace", "not a directory", .{ .param = param, .path = cwd }),
            else => return c.fail(if (p.cwd != null) "invalid_params.cwd" else "invalid_params.workspace", "the folder cannot be opened", .{ .param = param, .path = cwd, .reason = @errorName(err) }),
        };
        dir.close(ag.io);

        const owner = rules.owner(ag.state(), workspace);
        const layer_repo: ?[]const u8 = if (resolved.repos.len == 1) try agent_scope.repoPath(a, workspace, resolved.repos[0]) else null;
        const defaults = try scopedDefaults(ag, c, owner, cwd, layer_repo) orelse return;
        if (parent_agent) |x| {
            if (!try withinSpawnLimits(ag, c, defaults, parent.?, &x, depthOf(ag.state(), &x) + 1)) return;
            if (!try withinScope(a, &x, workspace, resolved.repos)) return c.fail("denied.spawn_scope", "a sub-agent's scope must stay within its parent's", .{ .param = "repos", .parent = parent.? });
        }
        // The provider: named, else the parent's (when no harness is named),
        // else `agents.provider` (when no harness is named either).
        const providers = ag.config.current().providers;
        var provider: ?config.Provider = null;
        var home: ?[]const u8 = null;
        if (p.provider) |name| {
            provider = config.findProvider(providers, name) orelse return c.fail("not_found.provider", "no provider has this name; see providers in config", .{ .param = "provider", .provider = name });
        } else if (p.harness == null) {
            if (parent_agent) |x| {
                if (x.provider) |name| if (config.findProvider(providers, name)) |found| {
                    provider = found;
                };
            } else if (ag.config.current().agents.provider) |name| {
                // A default that names no provider (renamed or removed) falls
                // back to `agents.default`.
                provider = config.findProvider(providers, name);
            }
        }
        var provider_harness: ?[]const u8 = null;
        if (provider) |pv| {
            for (harnesses.known) |k| if (k.id == pv.harness) {
                provider_harness = k.name;
            };
            if (p.harness) |h| if (!std.mem.eql(u8, h, provider_harness.?))
                return c.fail("invalid_params.provider", "the harness is not the provider's", .{ .param = "harness", .provider = pv.name, .harness = h });
            const user_home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.sliceTo(h, 0) else null;
            home = try pv.resolvedHome(a, user_home);
            if (pv.home != null and home == null) return c.fail("invalid_params.provider", "the provider's config folder cannot be resolved", .{ .param = "provider", .provider = pv.name });
        }
        // A sub-agent of the same harness with no provider of its own keeps its parent's login.
        if (provider == null and p.provider == null) if (parent_agent) |x| {
            if (p.harness == null or std.mem.eql(u8, p.harness.?, x.harness)) home = x.home;
        };
        const harness_name = p.harness orelse provider_harness orelse if (parent_agent) |x| x.harness else defaults.harness;
        if (!ag.registered(harness_name))
            return c.fail("unavailable.harness_not_found", "no adapter for this harness in this build, or it is disabled", .{ .param = "harness", .harness = harness_name });

        // A child's mode and model: its parent's, never more.
        const requested_mode: ?config.Mode = if (p.mode) |m| std.meta.stringToEnum(config.Mode, m).? else null;
        var mode_name: []const u8 = @tagName(requested_mode orelse (if (provider) |pv| pv.mode else null) orelse defaults.mode);
        var model = p.model orelse if (provider) |pv| pv.model else null;
        if (parent_agent) |x| {
            const inherited = if (x.mode) |m| std.meta.stringToEnum(config.Mode, m) orelse .ask else config.Mode.ask;
            if (requested_mode) |m| if (modeWidth(m) > modeWidth(inherited)) return c.fail("denied.spawn_mode", "the mode is wider than the parent's", .{ .param = "mode", .parent_mode = @tagName(inherited) });
            mode_name = @tagName(requested_mode orelse inherited);
            const same = std.mem.eql(u8, x.harness, harness_name);
            // Another harness must hold the child to this mode, or narrower.
            if (!same) mode_name = ag.host.enforceableMode(harness_name, mode_name) orelse
                return c.fail("denied.spawn_harness", "this harness cannot hold a sub-agent to its parent's mode", .{ .param = "harness", .harness = harness_name, .mode = mode_name });
            const parent_model: ?[]const u8 = if (same) x.spawn_model orelse x.model else null;
            if (p.model) |m| if (parent_model == null or !std.mem.eql(u8, m, parent_model.?)) return c.fail("denied.spawn_model", "the model is not the parent's", .{ .param = "model" });
            model = parent_model;
        }

        // Off the reactor: held here, and `Agents.tick` comes back (above).
        // The check asks the harness's default login; a provider with a
        // config folder of its own reports its own failure instead.
        if (home == null) if (ag.discovery) |asked| if (asked.signInTarget(harness_name)) |target| if (checked != target) {
            try ag.held_spawns.append(ag.engine.gpa, .{ .ticket = c.ticket, .params = p, .target = target });
            ag.dispatcher = c.dispatcher;
            asked.askSignIn(target);
            return;
        };

        const id = try ag.nextId(a);
        const title = if (p.title) |t| (if (t.len > 0) t else titleOf(p.task)) else titleOf(p.task);

        // Isolation: everything checked before anything is made.
        var mode: config.Isolation = if (p.isolation) |m| std.meta.stringToEnum(config.Isolation, m).? else if (parent_agent != null) .worktree else defaults.isolation;
        if (parent_agent) |x| if (mode == .in_place and x.worktrees.len > 0 and p.isolation != null)
            return c.fail("denied.spawn_isolation", "a sub-agent of an isolated parent cannot run in place", .{ .param = "isolation" });
        const in_scope: []const []const u8 = if (resolved.repos.len > 0) resolved.repos else if (owner) |w| (if (std.mem.eql(u8, w.path, workspace)) w.repos else &.{}) else &.{};
        if (in_scope.len == 0) mode = .in_place;
        var why: isolation.Failure = undefined;
        const planned = try isolation.plan(a, ag.io, .{ .mode = mode, .agent = id, .workspace = workspace, .repos = in_scope, .issue = issue, .branch = p.branch }, &why) orelse return isolationFailure(c, why);
        const run_cwd = try isolation.mapCwd(a, workspace, planned, cwd);
        const names = try a.alloc([]const u8, planned.len);
        const checkouts = try a.alloc(Checkout, planned.len);
        for (planned, names, checkouts) |x, *n, *o| {
            n.* = x.name;
            o.* = .{ .repo = x.repo, .path = x.path, .branch = x.branch, .new_branch = x.new_branch };
        }
        const provider_name: ?[]const u8 = if (provider) |pv| pv.name else if (p.harness == null and p.provider == null) (if (parent_agent) |x| x.provider else null) else null;
        if (p.dry_run) return c.ok(.{ .agent = id, .state = "queued", .harness = harness_name, .title = title, .workspace = workspace, .repos = resolved.repos, .cwd = run_cwd, .worktrees = names, .isolation = @tagName(mode), .checkouts = checkouts, .parent = parent, .permission_mode = mode_name, .model = model, .provider = provider_name, .dry_run = true });

        var issued_grants: ?[]const proto.grants.Grant = null;
        if (ag.principals) |pr| {
            const contained: proto.grants.Resource = if (parent) |x| agentResource(x) else ws;
            _ = pr.issue(c.conn.identity, id, contained, p.grants) catch |err| switch (err) {
                error.Delegation => return c.fail("denied.delegation", "the requested grants exceed the caller's", .{ .param = "grants" }),
                error.InvalidScope => return c.fail("invalid_params.grant_scope", "a grant scope is malformed", .{ .param = "grants" }),
                error.Denied => return c.fail("denied.spawn", "caller lacks the required grant", .{ .right = "spawn", .resource = try std.fmt.allocPrint(a, "workspace:{s}", .{workspace}) }),
                else => return err,
            };
            issued_grants = pr.grantsOf(id);
        }
        if (!try isolation.create(a, ag.io, id, planned, &why)) {
            if (ag.principals) |pr| pr.forget(id);
            return isolationFailure(c, why);
        }
        _ = ag.engine.submit(.{ .create = .{
            .agent = id,
            .title = title,
            .harness = harness_name,
            .workspace = workspace,
            .repos = resolved.repos,
            .cwd = if (std.mem.eql(u8, workspace, run_cwd)) null else run_cwd,
            .worktrees = try isolation.records(a, planned),
            .parent = parent,
            .issue = issue,
            .task = p.task,
            .mode = mode_name,
            .spawn_model = model,
            .provider = provider_name,
            .home = home,
            .grants = issued_grants,
        } }) catch |err| {
            if (ag.principals) |pr| pr.forget(id);
            isolation.remove(a, ag.io, planned);
            return err;
        };
        // No free slot: the task waits in the log, and `tick` starts it.
        if (ag.host.slotFree(id, ag.config.current().agents.max_concurrent)) ag.host.dispatch(id) catch |err| {
            // Not started: leave the queue with the task unsent (as a
            // stop of a queued agent does), so nothing waits for a slot forever.
            _ = ag.engine.submit(.{ .stop = .{ .agent = id } }) catch |e| if (e == error.OutOfMemory) return e;
            return hostFailure(c, err, id, ag.get(id));
        };
        const x = ag.get(id).?;
        try c.ok(.{ .agent = id, .state = @tagName(x.state), .harness = harness_name, .title = title, .workspace = workspace, .repos = resolved.repos, .cwd = run_cwd, .worktrees = names, .isolation = @tagName(mode), .checkouts = checkouts, .parent = parent, .permission_mode = mode_name, .model = model, .provider = provider_name });
    }
};

/// One worktree or copy in the spawn result.
const Checkout = struct { repo: []const u8, path: []const u8, branch: ?[]const u8, new_branch: bool };

fn isolationFailure(c: *proto.Call, why: isolation.Failure) !void {
    return switch (why) {
        .exists => |x| c.fail("conflict.worktree_exists", "the worktree folder already exists; pass another --issue or remove it", .{ .repo = x.repo, .path = x.path }),
        .branch_exists => |x| c.fail("conflict.branch_exists", "the agent's branch already exists in the repo", .{ .repo = x.repo, .branch = x.branch }),
        .checked_out => |x| c.fail("conflict.branch_checked_out", "the branch is checked out in another worktree", .{ .repo = x.repo, .branch = x.branch, .path = x.path }),
        .invalid_branch => |b| c.fail("invalid_params.branch", "not a valid git branch name", .{ .param = "branch", .branch = b }),
        .linked_copy => |r| c.fail("unsupported.copy_linked_worktree", "a repo that is a linked worktree cannot be copied; use worktree isolation", .{ .param = "isolation", .repo = r }),
        .git => |x| c.fail("unavailable.git", "the worktree or copy cannot be made", .{ .repo = x.repo, .reason = x.reason }),
    };
}

const Defaults = struct { harness: []const u8, isolation: config.Isolation, mode: config.Mode, spawn_allow: bool, spawn_depth: u8 };

/// The `agents.*` keys a spawn reads, in effect for `cwd`: the
/// closest workspace's file and the file of the repo `cwd` is in, above
/// the user file. Null when the call has already failed.
fn scopedDefaults(ag: *Agents, c: *proto.Call, owner: ?*const rules.Workspace, cwd: []const u8, scope_repo: ?[]const u8) !?Defaults {
    const a = c.arena();
    const user = ag.config.current().agents;
    const effective = blk: {
        const w = owner orelse break :blk user;
        const layers = ag.layers orelse break :blk user;
        const where: scope.Scope = .{ .workspace = w.path, .repo = scope_repo orelse try repoOf(a, w, cwd) };
        var store = layers.open(a, where) catch |err| switch (err) {
            error.InvalidConfig => {
                const bad = try layers.failing(a, where);
                try c.fail("invalid_params.config_value", "a config file in this folder's scope is invalid", .{ .param = "harness", .source = bad.name, .path = bad.path });
                return null;
            },
            else => return err,
        };
        defer store.deinit();
        // Only the scalars are read, after the store is gone.
        break :blk store.current().agents;
    };
    for (harnesses.known) |k| if (k.id == effective.default) return .{ .harness = k.name, .isolation = effective.isolation, .mode = effective.mode, .spawn_allow = effective.spawn.allow, .spawn_depth = effective.spawn.depth };
    unreachable; // every config.Harness has a `known` entry
}

/// The repo of workspace `w` that holds `cwd` (the deepest one), if any.
fn repoOf(a: std.mem.Allocator, w: *const rules.Workspace, cwd: []const u8) !?[]const u8 {
    var best: ?[]const u8 = null;
    for (w.repos) |name| {
        const path = if (std.mem.eql(u8, name, ".")) w.path else if (std.mem.eql(u8, w.path, "/")) try std.fmt.allocPrint(a, "/{s}", .{name}) else try std.fmt.allocPrint(a, "{s}/{s}", .{ w.path, name });
        if (!rules.within(path, cwd)) continue;
        if (best == null or path.len > best.?.len) best = path;
    }
    return best;
}

/// The first non-empty line of `task`, cut to `title_max` bytes.
pub fn titleOf(task: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, task, "\r\n");
    const line = std.mem.trim(u8, it.next() orelse "", " \t");
    if (line.len <= title_max) return line;
    var end: usize = title_max;
    while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
    return line[0..end];
}

/// `agent.list` (read): newest first; archived agents only when asked.
pub const List = struct {
    agents: *Agents,
    pub const Params = struct { archived: bool = false };

    pub fn call(self: *List, c: *proto.Call, p: Params) anyerror!void {
        const all = self.agents.state().agents;
        var items: std.ArrayList(Summary) = .empty;
        const counts = try bubbles(c, self.agents.state());
        var i = all.count();
        while (i > 0) {
            i -= 1;
            const x = &all.values()[i];
            if (x.state == .archived and !p.archived) continue;
            if (!readable(c, agentResource(all.keys()[i]))) continue;
            var s: Summary = .of(all.keys()[i], x);
            if (counts.get(s.agent)) |n| {
                s.children_needs_you = n.needs_you;
                s.children_failed = n.failed;
            }
            try items.append(c.arena(), s);
        }
        try c.ok(.{ .agents = items.items });
    }
};

/// `agent.show` (read). With `tools` (the TUI's transcript) the
/// transcript also carries the tool calls. The answer always fits the
/// connection's `max_frame`: it carries the transcript's newest
/// records that fit, and `since` and `before` page through the rest.
pub const Show = struct {
    agents: *Agents,

    pub const Params = struct { agent: []const u8, tools: bool = false, since: ?u64 = null, before: ?u64 = null };
    pub const Request = struct { request: []const u8, kind: []const u8, reason: []const u8, stale: bool, outside_scope: bool, call: ?[]const u8 = null, options: []const eventlog.events.QuestionOptions = &.{} };
    pub const ChildPrompt = @typeInfo(@FieldType(Agent, "child_prompts").Slice).pointer.child;

    /// The answer. The `null`s are left out of it.
    pub const Result = struct {
        agent: []const u8,
        title: []const u8,
        harness: []const u8,
        state: []const u8,
        unread: bool,
        workspace: []const u8,
        repos: []const []const u8,
        cwd: []const u8,
        created_at: i64,
        changed_at: i64,
        parent: ?[]const u8,
        children_needs_you: u32,
        children_failed: u32,
        child_prompts: ?[]const ChildPrompt,
        turns: u32,
        open_turn: ?[]const u8,
        model: ?[]const u8,
        permission_mode: []const u8,
        context: ?eventlog.usage.Context,
        context_warn_at: u8,
        steer: ?[]const u8,
        interrupt: ?bool,
        forks: ?[]const ForkState,
        requests: []const Request,
        requests_omitted: usize = 0,
        tails: ?[]const harness.Host.OpenTail,
        transcript_start: usize = 0,
        transcript_end: usize = 0,
        transcript_total: usize = 0,
        transcript: []const ShowRecord = &.{},
    };

    pub fn call(self: *Show, c: *proto.Call, p: Params) anyerror!void {
        const a = c.arena();
        if (!try c.authorize(.read, agentResource(p.agent))) return;
        const x = self.agents.get(p.agent) orelse return notFound(c, p.agent);
        if (p.since != null and p.before != null) return c.fail("invalid_params.since", "give since or before, not both", .{ .param = "since" });
        const where: ShowWhere = if (p.since) |n| .{ .since = n } else if (p.before) |n| .{ .before = n } else .tail;
        // The frame, less the `{"id":…,"ok":…}` around the result, and room
        // for the positions, which are measured below as 0.
        const room = @as(usize, c.conn.max_frame) -| (c.id_json.len + 96);
        const s: Summary = .of(p.agent, x);
        const ui = self.agents.config.current();
        // Only a bound agent's adapter has been probed; a probe runs the
        // harness's `--version`, so `agent.show` never starts one.
        const caps: ?harness.contract.Caps = if (self.agents.host.binding(p.agent)) |b| b.descriptor.caps else null;
        const context: ?eventlog.usage.Context = if (self.agents.state().usage.agents.get(p.agent)) |u| u.context else null;
        const counts = (try bubbles(c, self.agents.state())).get(p.agent);
        const shown_requests = try fitRequests(a, x, room / 4);
        var out: Result = .{
            .agent = s.agent,
            .title = s.title,
            .harness = s.harness,
            .state = s.state,
            .unread = s.unread,
            .workspace = s.workspace,
            .repos = s.repos,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .changed_at = s.changed_at,
            .parent = s.parent,
            .children_needs_you = if (counts) |n| n.needs_you else 0,
            .children_failed = if (counts) |n| n.failed else 0,
            // A paged read asks for the transcript: it leaves these out, so
            // that a refresh does not carry them again.
            .child_prompts = if (where == .tail) try fitChildPrompts(a, x.child_prompts.items, room / 4) else null,
            .turns = x.turns,
            .open_turn = x.open_turn,
            .model = x.model orelse x.spawn_model,
            // What this agent runs with, not today's config. An
            // agent logged before modes were recorded runs the harness default.
            .permission_mode = x.mode orelse @tagName(config.Mode.ask),
            .context = context,
            .context_warn_at = ui.ui.context.warn_at,
            // Like `child_prompts`: a paged read asks for the transcript.
            .forks = if (where == .tail) try forkList(a, self.agents.state(), p.agent, x) else null,
            .steer = if (caps) |k| @tagName(k.steer) else null,
            .interrupt = if (caps) |k| k.interrupt else null,
            .requests = shown_requests,
            .requests_omitted = requestsOmitted(x, shown_requests),
            .tails = if (where != .tail and p.tools) fitTails(try self.agents.host.openTails(a, p.agent), room / 4) else null,
        };
        const window = try transcriptWindow(a, p.agent, x, if (p.tools) self.agents.host else null, p.tools, where, room -| encodedLen(out));
        out.transcript_start = window.start;
        out.transcript_end = window.end;
        out.transcript_total = window.total;
        out.transcript = window.records;
        if (self.agents.discovery) |asked| if (asked.signInTarget(x.harness)) |t| {
            // A queued start that found the harness signed out has no call
            // to carry `data.fix`: it is added to the record of its turn.
            var records: ?[]ShowRecord = null;
            for (window.records, 0..) |r, i| {
                const code = r.error_code orelse continue;
                if (!std.mem.eql(u8, code, "unavailable.harness_not_signed_in")) continue;
                if (records == null) records = try a.dupe(ShowRecord, window.records);
                records.?[i].fix = try asked.signInFix(a, t);
            }
            if (records) |m| out.transcript = m;
        };
        try c.ok(out);
    }
};

/// The bytes `value` takes in a response.
fn encodedLen(value: anytype) usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &counter.writer) catch return std.math.maxInt(usize);
    return @intCast(counter.fullCount());
}

/// The start of `text` that takes at most `max` bytes inside a JSON string,
/// on a UTF-8 boundary. An escape takes up to six bytes for one.
fn jsonCut(text: []const u8, max: usize) []const u8 {
    var used: usize = 0;
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        used += if (c == '"' or c == '\\') @as(usize, 2) else if (c < 0x20 or c == 0x7f) @as(usize, 6) else 1;
        if (used > max) break;
    }
    if (end == text.len) return text;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// `text` in at most `max` JSON bytes; a cut one ends in `…`.
fn jsonCutMarked(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    const kept = jsonCut(text, max);
    if (kept.len == text.len) return text;
    return std.mem.concat(a, u8, &.{ jsonCut(text, max -| "…".len), "…" });
}

/// The pending requests that fit in `room`, oldest first. Every pending
/// request is listed, so a big one never hides a later approval: one that
/// does not fit loses its options, then has its reason cut, and in the end
/// is only its id, kind and call. `requestsOmitted` counts those; `inbox.list`
/// has them whole.
pub fn fitRequests(a: std.mem.Allocator, x: *const Agent, room: usize) ![]const Show.Request {
    var out: std.ArrayList(Show.Request) = .empty;
    var left = room;
    for (x.requests.items) |r| {
        var one: Show.Request = .{ .request = r.request, .kind = r.kind, .reason = r.reason, .stale = r.stale, .outside_scope = r.outside_scope, .call = r.call, .options = r.options orelse &.{} };
        var n = encodedLen(one) + 1;
        if (n > left) {
            one.options = &.{};
            n = encodedLen(one) + 1;
        }
        if (n > left) {
            one.reason = "";
            const bare = encodedLen(one) + 1;
            if (bare < left) {
                one.reason = try jsonCutMarked(a, r.reason, left - bare);
                n = encodedLen(one) + 1;
            } else n = bare;
        }
        try out.append(a, one);
        left -|= n;
    }
    return out.items;
}

/// How many of `x`'s pending requests `shown` (from `fitRequests`) lists
/// without their whole reason or their options.
pub fn requestsOmitted(x: *const Agent, shown: []const Show.Request) usize {
    var n: usize = 0;
    for (x.requests.items, shown) |r, one| {
        const options = if (r.options) |o| o.len else 0;
        if (!std.mem.eql(u8, r.reason, one.reason) or options != one.options.len) n += 1;
    }
    return n;
}

/// `agent.show`'s `forks`: one per `agent.fork`, for a client that
/// does not follow `events`. Running ones have no result yet.
const ForkState = struct { key: []const u8, state: []const u8, fork: ?[]const u8 = null, code: ?[]const u8 = null };

fn forkList(a: std.mem.Allocator, state: *const eventlog.State, id: []const u8, x: *const Agent) ![]const ForkState {
    var out: std.ArrayList(ForkState) = .empty;
    for (x.forks.items) |f| try out.append(a, .{ .key = f.key, .state = if (f.ok) "ok" else "failed", .fork = f.fork, .code = f.code });
    const prefix = try std.fmt.allocPrint(a, "fork:{s}:", .{id});
    for (state.effects.keys(), state.effects.values()) |key, e| {
        if (!e.done and std.mem.startsWith(u8, key, prefix)) try out.append(a, .{ .key = key, .state = "running" });
    }
    return out.items;
}

/// The newest of `prompts` that fit in `room`, oldest first; the oldest one
/// kept may have its text cut.
pub fn fitChildPrompts(a: std.mem.Allocator, prompts: []const Show.ChildPrompt, room: usize) ![]const Show.ChildPrompt {
    var kept = prompts.len;
    var left = room;
    var cut: ?Show.ChildPrompt = null;
    while (kept > 0) {
        var one = prompts[kept - 1];
        const n = encodedLen(one) + 1;
        if (n > left) {
            one.text = "";
            const bare = encodedLen(one) + 1;
            if (bare < left) {
                one.text = try jsonCutMarked(a, prompts[kept - 1].text, left - bare);
                cut = one;
            }
            break;
        }
        left -= n;
        kept -= 1;
    }
    const whole = prompts[kept..];
    const c = cut orelse return whole;
    const out = try a.alloc(Show.ChildPrompt, whole.len + 1);
    out[0] = c;
    @memcpy(out[1..], whole);
    return out;
}

/// The open calls' live tails that fit in `room`.
fn fitTails(tails: []const harness.Host.OpenTail, room: usize) []const harness.Host.OpenTail {
    var left = room;
    for (tails, 0..) |t, i| {
        const n = encodedLen(t) + 1;
        if (n > left) return tails[0..i];
        left -= n;
    }
    return tails;
}

/// One `agent.show` transcript record.
pub const ShowRecord = struct {
    type: []const u8,
    turn: []const u8,
    text: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    /// With `unavailable.harness_not_signed_in`: the harness's own sign-in
    /// command (the `data.fix` of the error).
    fix: ?[]const u8 = null,
    call: ?[]const u8 = null,
    parent_call: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?[]const u8 = null,
    at: ?i64 = null,
    args: ?eventlog.events.ToolArgs = null,
    tail: ?[]const u8 = null,
    exit: ?i64 = null,
    duration_ms: ?u64 = null,
    body: ?eventlog.events.ToolBody = null,
};

/// Body and prompt text one `agent.show` carries, per record and in all
/// (newest first), besides `max_frame` (1 MiB). `agent.tool` returns a whole
/// body.
pub const show_body_max = 8 * 1024;
pub const show_bodies_max = 256 * 1024;

/// Which part of the transcript `agent.show` is asked for. A position counts
/// the agent's transcript log (`Agent.transcript`), which only grows: it stays
/// valid, also across a daemon restart.
pub const ShowWhere = union(enum) {
    /// The newest records that fit. A body or prompt past `show_bodies_max`
    /// is left out, so that the record itself still comes along.
    tail,
    /// From this position on, oldest first, as far as fits.
    since: u64,
    /// The newest records before this position that fit; past the end means
    /// the transcript's tail.
    before: u64,
};

/// Records, and the positions they cover: `start` up to, not including, `end`.
/// `total` is the transcript's whole length.
pub const ShowWindow = struct { records: []const ShowRecord, start: usize, end: usize, total: usize };

/// The cut start of `text`, on a UTF-8 boundary.
fn cutBody(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// A failed call's error is usually at the end: its first and last bytes.
fn keepEnds(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    const mark = "\n… cut …\n";
    if (max <= mark.len + 2) return cutBody(text, max);
    const head = cutBody(text, (max - mark.len) / 2);
    var from = text.len - (max - mark.len - (max - mark.len) / 2);
    while (from < text.len and (text[from] & 0xC0) == 0x80) from += 1;
    return std.mem.concat(a, u8, &.{ head, mark, text[from..] });
}

/// `agent.show`'s transcript records, however many there are; `tools` adds
/// the tool calls.
pub fn transcriptRecords(a: std.mem.Allocator, id: []const u8, x: *const Agent, host: ?*const harness.Host, tools: bool) ![]const ShowRecord {
    return (try transcriptWindow(a, id, x, host, tools, .tail, std.math.maxInt(usize))).records;
}

/// The bytes of body or prompt text event `e` would carry.
fn bodyLen(e: eventlog.Event, tools: bool) usize {
    return switch (e) {
        .turn_prompt => |t| t.text.len,
        .tool_ended => |t| if (tools) if (t.body) |b| b.text.len else 0 else 0,
        else => 0,
    };
}

/// The part of the transcript `where` asks for that takes at most `room`
/// bytes. Pure over the agent's state, and the host's live tails when given
/// one (a paged read has them in `tails` instead); the cost is the size of the
/// window, not of the transcript. At least one position is covered if there is
/// one: a record too big for `room` comes cut.
pub fn transcriptWindow(a: std.mem.Allocator, id: []const u8, x: *const Agent, host: ?*const harness.Host, tools: bool, where: ShowWhere, room: usize) !ShowWindow {
    const events = x.transcript.items;
    const paged = where != .tail;
    const forward = where == .since;
    const from: usize = switch (where) {
        .tail => events.len,
        .since, .before => |n| @intCast(@min(n, events.len)),
    };
    var i = from;
    var left = room;
    var bodies: usize = show_bodies_max;
    var out: std.ArrayList(ShowRecord) = .empty;
    while (if (forward) i < events.len else i > 0) {
        const n = if (forward) i else i - 1;
        const wanted = @min(bodyLen(events[n], tools), show_body_max);
        const allowed = @min(wanted, bodies);
        // The next page has the room for this body.
        if (paged and allowed < wanted and out.items.len > 0) break;
        if (try showRecord(a, id, events[n], if (paged) null else host, tools, allowed)) |whole| {
            var r = whole;
            var size = encodedLen(r) + 1;
            if (size > left) {
                if (out.items.len > 0) break;
                r = try shrinkRecord(a, r, left -| 1);
                size = @min(encodedLen(r) + 1, left);
            }
            try out.append(a, r);
            left -= size;
            bodies -= allowed;
        }
        if (forward) i += 1 else i -= 1;
    }
    if (!forward) std.mem.reverse(ShowRecord, out.items);
    return .{ .records = out.items, .start = if (forward) from else i, .end = if (forward) i else from, .total = events.len };
}

/// Event `e` as a record, with `allowed` bytes of its body or prompt; null
/// when it is not part of this view.
fn showRecord(a: std.mem.Allocator, id: []const u8, e: eventlog.Event, host: ?*const harness.Host, tools: bool, allowed: usize) !?ShowRecord {
    return switch (e) {
        .turn_started => |t| .{ .type = "turn.started", .turn = t.turn },
        .turn_prompt => |t| .{ .type = "turn.prompt", .turn = t.turn, .text = if (allowed == t.text.len) t.text else try std.mem.concat(a, u8, &.{ cutBody(t.text, allowed), "…" }) },
        .text => |t| .{ .type = "text", .turn = t.turn, .text = t.text },
        .turn_ended => |t| .{ .type = "turn.ended", .turn = t.turn, .reason = t.reason, .error_code = t.error_code },
        .tool_started => |t| if (!tools) null else .{
            .type = "tool.started",
            .turn = t.turn,
            .call = t.call,
            .parent_call = t.parent_call,
            .kind = t.kind,
            .name = t.name,
            .title = t.title,
            .status = t.status,
            .at = t.at,
            .args = t.args,
            .tail = if (host) |h| h.toolTail(id, t.call) else null,
        },
        .tool_ended => |t| if (!tools) null else .{
            .type = "tool.ended",
            .turn = t.turn,
            .call = t.call,
            .status = t.status,
            .exit = t.exit,
            .duration_ms = t.duration_ms,
            .body = if (t.body) |b| blk: {
                const failed = std.mem.eql(u8, t.status, "error") or (t.exit != null and t.exit.? != 0);
                const text = if (failed) try keepEnds(a, b.text, allowed) else cutBody(b.text, allowed);
                break :blk .{ .text = text, .truncated = b.truncated or text.len < b.text.len or text.ptr != b.text.ptr, .bytes = if (b.bytes > 0) b.bytes else b.text.len };
            } else null,
        },
        // Usage shares the transcript; it is not part of this view.
        else => null,
    };
}

/// `r` in at most `room` bytes: its long strings share what its short ones
/// leave. Only a record alone too big for a whole response comes to this.
fn shrinkRecord(a: std.mem.Allocator, r: ShowRecord, room: usize) !ShowRecord {
    var bare = r;
    var count: usize = 0;
    const blank = struct {
        fn one(s: *?[]const u8, n: *usize) void {
            if (s.*) |v| if (v.len > 0) {
                n.* += 1;
                s.* = "";
            };
        }
    }.one;
    blank(&bare.text, &count);
    blank(&bare.title, &count);
    blank(&bare.tail, &count);
    if (bare.args) |*g| {
        blank(&g.command, &count);
        blank(&g.cwd, &count);
        blank(&g.path, &count);
        blank(&g.query, &count);
        blank(&g.url, &count);
    }
    if (bare.body) |*b| if (b.text.len > 0) {
        count += 1;
        b.text = "";
        b.truncated = true;
    };
    if (count == 0) return r;
    const each = (room -| encodedLen(bare)) / count;
    const put = struct {
        fn one(alloc: std.mem.Allocator, to: *?[]const u8, s: ?[]const u8, max: usize) !void {
            if (to.*) |v| if (v.len == 0) if (s) |t| if (t.len > 0) {
                to.* = try jsonCutMarked(alloc, t, max);
            };
        }
    }.one;
    try put(a, &bare.text, r.text, each);
    try put(a, &bare.title, r.title, each);
    try put(a, &bare.tail, r.tail, each);
    if (bare.args) |*g| {
        try put(a, &g.command, r.args.?.command, each);
        try put(a, &g.cwd, r.args.?.cwd, each);
        try put(a, &g.path, r.args.?.path, each);
        try put(a, &g.query, r.args.?.query, each);
        try put(a, &g.url, r.args.?.url, each);
    }
    if (bare.body) |*b| b.text = jsonCut(r.body.?.text, each);
    return bare;
}

/// `agent.tool`'s answer: one tool call whole. Pure over the agent's state,
/// plus the live tail. Null: the agent has no such call.
pub const ToolRecord = struct {
    agent: []const u8,
    call: []const u8,
    turn: []const u8,
    parent_call: ?[]const u8,
    harness_ref: ?[]const u8,
    kind: []const u8,
    name: []const u8,
    title: []const u8,
    args: ?eventlog.events.ToolArgs,
    raw_input: ?eventlog.events.ToolBody,
    at: i64,
    status: []const u8,
    exit: ?i64,
    duration_ms: ?u64,
    body: ?eventlog.events.ToolBody,
    tail: ?[]const u8,
};

pub fn toolRecord(id: []const u8, x: *const Agent, call: []const u8, tail: ?[]const u8) ?ToolRecord {
    var started: ?eventlog.events.ToolStarted = null;
    var ended: ?eventlog.events.ToolEnded = null;
    var turn_over = false;
    for (x.transcript.items) |e| switch (e) {
        // A daemon restart ends a turn with no `tool.ended`.
        .turn_ended => |t| if (started != null and std.mem.eql(u8, t.turn, started.?.turn)) {
            turn_over = true;
        },
        .tool_started => |t| if (std.mem.eql(u8, t.call, call)) {
            started = t;
        },
        .tool_ended => |t| if (std.mem.eql(u8, t.call, call)) {
            ended = t;
        },
        else => {},
    };
    const t = started orelse return null;
    return .{
        .agent = id,
        .call = t.call,
        .turn = t.turn,
        .parent_call = t.parent_call,
        .harness_ref = t.harness_ref,
        .kind = t.kind,
        .name = t.name,
        .title = t.title,
        .args = t.args,
        .raw_input = t.raw_input,
        .at = t.at,
        .status = if (ended) |d| d.status else if (turn_over) "interrupted" else t.status,
        .exit = if (ended) |d| d.exit else null,
        .duration_ms = if (ended) |d| d.duration_ms else null,
        .body = if (ended) |d| d.body else null,
        .tail = tail,
    };
}

/// `agent.tool` (read): one tool call whole, for the TUI's pager and raw
/// JSON (the TUI's `p`, `J`).
pub const ToolCall = struct {
    agents: *Agents,

    pub const Params = struct { agent: []const u8, call: []const u8 };

    pub fn call(self: *ToolCall, c: *proto.Call, p: Params) anyerror!void {
        if (!try c.authorize(.read, agentResource(p.agent))) return;
        const x = self.agents.get(p.agent) orelse return notFound(c, p.agent);
        const r = toolRecord(p.agent, x, p.call, self.agents.host.toolTail(p.agent, p.call)) orelse return c.fail("not_found.call", "the agent has no such tool call", .{ .agent = p.agent, .call = p.call });
        try c.ok(r);
    }
};

/// `agent.send` (write).
pub const Send = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, text: []const u8, mode: []const u8 = "turn" };

    pub fn call(self: *Send, c: *proto.Call, p: Params) anyerror!void {
        return self.run(c, p, null);
    }

    fn resumeHeld(self: *Send, c: *proto.Call, w: Agents.HeldSend, answer: harness.discovery.SignIn, asked: *harnesses.Discovery) !void {
        if (answer.signed_in == false) return notSignedIn(c, asked, w.target);
        return self.run(c, w.params, w.target);
    }

    /// Sign-in: a send that starts the harness
    /// again is checked like a spawn, held while `Discovery.askSignIn` asks
    /// on a thread. `checked`: the target that has already answered.
    fn run(self: *Send, c: *proto.Call, p: Params, checked: ?usize) anyerror!void {
        const ag = self.agents;
        if (!try c.authorize(.write, agentResource(p.agent))) return;
        const target = ag.get(p.agent) orelse return notFound(c, p.agent);
        if (std.mem.trim(u8, p.text, " \t\r\n").len == 0) return c.fail("invalid_params.text", "the prompt is empty", .{ .param = "text" });
        if (target.waiting()) return c.fail("conflict.agent_queued", "the agent waits for a concurrency slot with its task held; stop it to prompt it", .{ .agent = p.agent });
        // The schema allows only these three.
        const mode = std.meta.stringToEnum(harness.contract.SendMode, p.mode).?;
        if (ag.discovery != null) ag.host.checkSend(p.agent, mode) catch |err| return hostFailure(c, err, p.agent, ag.get(p.agent));
        if (ag.discovery) |asked| if (target.state != .archived and target.state != .handed_over and ag.host.startsProcess(p.agent))
            if (asked.signInTarget(target.harness)) |t| if (checked != t) {
                try ag.held_sends.append(ag.engine.gpa, .{ .ticket = c.ticket, .params = p, .target = t });
                ag.dispatcher = c.dispatcher;
                asked.askSignIn(t);
                return;
            };
        ag.host.send(p.agent, p.text, mode) catch |err| return hostFailure(c, err, p.agent, ag.get(p.agent));
        // The parent sees what anyone else tells its child.
        if (ag.get(p.agent).?.parent) |parent| {
            const sender = if (ag.principals) |pr| pr.callerAgent(c.conn.identity) else null;
            if (sender == null or !std.mem.eql(u8, sender.?, parent)) _ = try ag.engine.submit(.{ .child_prompted = .{ .parent = parent, .child = p.agent, .text = p.text } });
        }
        try c.ok(.{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state) });
    }
};

/// `agent.stop` and `agent.archive` (write): the decider's commands.
/// The effect that interrupts a running turn is
/// run at once, so the harness hears of it in this reactor turn. False when
/// the call has already failed.
fn halt(ag: *Agents, c: *proto.Call, id: []const u8, archive: bool) !bool {
    if (!try c.authorize(.write, agentResource(id))) return false;
    const cmd: eventlog.Command = if (archive) .{ .archive = .{ .agent = id } } else .{ .stop = .{ .agent = id } };
    _ = ag.engine.submit(cmd) catch |err| switch (err) {
        error.NotFound => {
            try notFound(c, id);
            return false;
        },
        error.HandedOver => {
            try c.fail("conflict.agent_handed_over", "the harness's own TUI owns the turn; take it back first", .{ .agent = id });
            return false;
        },
        error.InvalidTransition, error.Conflict, error.InvalidCommand => {
            const code = eventlog.decider.errorCode(@errorCast(err));
            try c.fail(code, "the agent's state does not allow this", .{ .agent = id, .state = @tagName(ag.get(id).?.state) });
            return false;
        },
        else => return err,
    };
    _ = try ag.engine.runEffects();
    // An archived agent's principal (and its
    // processes' and sub-agents') is revoked.
    if (archive) if (ag.principals) |pr| pr.archived(id);
    return true;
}

pub const Stop = struct {
    agents: *Agents,
    /// `tree` is only in `agent.stop`'s schema.
    pub const Params = struct { agent: []const u8, tree: bool = false };

    pub fn call(self: *Stop, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        if (!try halt(ag, c, p.agent, false)) return;
        // Parents first; `write` on the root covers what is below it. One
        // the harness's own TUI has stays, and shows in the result.
        if (p.tree) {
            for (try below(c.arena(), ag.state(), p.agent)) |id| {
                _ = ag.engine.submit(.{ .stop = .{ .agent = id } }) catch |err| switch (err) {
                    error.HandedOver, error.InvalidTransition, error.Conflict => continue,
                    else => return err,
                };
            }
            _ = try ag.engine.runEffects();
        }
        const children: ?[]const ChildState = if (p.tree) try childStates(c.arena(), ag.state(), p.agent) else null;
        try c.ok(.{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state), .children = children });
    }
};

/// `agent.wait` (read): the call stays open until everything below the
/// agent has finished, or `timeout_s` runs out. `Agents.tick` ends it.
pub const Wait = struct {
    agents: *Agents,
    pub const Params = struct { agent: ?[]const u8 = null, timeout_s: u32 = 600 };

    pub fn call(self: *Wait, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        const caller = if (ag.principals) |pr| pr.callerAgent(c.conn.identity) else null;
        const id = p.agent orelse caller orelse return c.fail("invalid_params.agent", "the caller is not an agent: name one", .{ .param = "agent" });
        if (!try c.authorize(.read, agentResource(id))) return;
        if (ag.get(id) == null) return notFound(c, id);
        const ended = try finishedBelow(c.arena(), ag.state(), id);
        if (ended or p.timeout_s == 0) return reply(ag, c, id, ended);
        ag.dispatcher = c.dispatcher;
        const owned = try ag.engine.gpa.dupe(u8, id);
        errdefer ag.engine.gpa.free(owned);
        const who: ?[]u8 = if (caller) |x| try ag.engine.gpa.dupe(u8, x) else null;
        errdefer if (who) |x| ag.engine.gpa.free(x);
        try ag.waits.append(ag.engine.gpa, .{ .ticket = c.ticket, .agent = owned, .caller = who, .deadline_ms = supervisor.monotonicMs() + @as(i64, p.timeout_s) * std.time.ms_per_s });
    }

    fn reply(ag: *Agents, c: *proto.Call, id: []const u8, done: bool) !void {
        try c.ok(.{ .agent = id, .done = done, .children = try childStates(c.arena(), ag.state(), id) });
    }
};

/// `agent.promote` (write; the TUI's key `P`): the sub-agent becomes
/// top-level and leaves its parent's tree (grants and revocation included).
/// A top-level agent is a no-op. Not for agents: see the file comment.
pub const Promote = struct {
    agents: *Agents,

    pub fn call(self: *Promote, c: *proto.Call, p: AgentParams) anyerror!void {
        const ag = self.agents;
        if (!try c.authorize(.write, agentResource(p.agent))) return;
        if (ag.principals) |pr| if (pr.callerAgent(c.conn.identity)) |_|
            return c.fail("denied.promote", "an agent cannot promote: it would escape agents.spawn.depth", .{ .agent = p.agent });
        // Archiving revoked everything below it, for good: a promoted agent
        // would have no grants left to run with.
        const x = ag.get(p.agent) orelse return notFound(c, p.agent);
        var up = x.parent;
        while (up) |id| {
            const above = ag.get(id) orelse break;
            if (above.state == .archived) return c.fail("conflict.parent_archived", "its parent is archived, which revoked its grants; it cannot be promoted", .{ .agent = p.agent, .parent = id });
            up = above.parent;
        }
        if (x.parent != null) if (ag.principals) |pr| if (pr.dead(p.agent))
            return c.fail("conflict.parent_archived", "its grants were revoked; it cannot be promoted", .{ .agent = p.agent });
        const n = ag.engine.submit(.{ .promote = .{ .agent = p.agent } }) catch |err| switch (err) {
            error.NotFound => return notFound(c, p.agent),
            error.InvalidTransition => return c.fail("conflict.invalid_transition", "the agent is archived", .{ .agent = p.agent }),
            else => return err,
        };
        if (n > 0) if (ag.principals) |pr| pr.promoted(p.agent);
        try c.ok(.{ .agent = p.agent, .promoted = n > 0 });
    }
};

/// `agent.archive` (write). `clean` also removes the worktrees and branches;
/// an agent whose running turn is still being interrupted is not
/// archived yet, so its worktrees are reported `agent_active`.
pub const Archive = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, clean: bool = false };

    pub fn call(self: *Archive, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        if (!try halt(ag, c, p.agent, true)) return;
        const state = @tagName(ag.get(p.agent).?.state);
        if (!p.clean) return c.ok(.{ .agent = p.agent, .state = state });
        var cleaner = ag.cleaner(c.arena());
        var entries: std.ArrayList(cleanup.Entry) = .empty;
        try ag.cleanAgent(&cleaner, c.arena(), p.agent, .explicit, &entries);
        try c.ok(.{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state), .worktrees = entries.items });
    }
};

/// `agent.clean` (write): removes archived agents'
/// worktrees and branches, `cleanup.zig` deciding each one. One agent by
/// name, or with `merged` and no agent every archived agent the caller may
/// write. Only archived agents: nothing can send one a turn, so nothing
/// needs the folder again. What is kept is a result, not an error.
pub const Clean = struct {
    agents: *Agents,
    pub const Params = struct { agent: ?[]const u8 = null, merged: bool = false };

    pub fn call(self: *Clean, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        const a = c.arena();
        const mode: cleanup.Mode = if (p.merged) .merged else .explicit;
        var cleaner = ag.cleaner(a);
        var entries: std.ArrayList(cleanup.Entry) = .empty;
        if (p.agent) |id| {
            if (!try c.authorize(.write, agentResource(id))) return;
            const x = ag.get(id) orelse return notFound(c, id);
            if (x.state != .archived)
                return c.fail("conflict.agent_not_archived", "archive the agent first, or use agent archive --clean", .{ .agent = id, .state = @tagName(x.state) });
            try ag.cleanAgent(&cleaner, a, id, mode, &entries);
        } else {
            if (!p.merged) return c.fail("invalid_params.agent", "name an agent, or pass --merged", .{ .param = "agent" });
            // Copied first: retiring a process runs the host's poll.
            var ids: std.ArrayList([]const u8) = .empty;
            const all = ag.state().agents;
            for (all.keys(), all.values()) |id, *x| {
                if (x.state != .archived or x.worktrees.len == 0) continue;
                if (!writable(c, agentResource(id))) continue;
                try ids.append(a, try a.dupe(u8, id));
            }
            for (ids.items) |id| try ag.cleanAgent(&cleaner, a, id, mode, &entries);
            // Long gone worktrees are not news to a sweep.
            var kept: usize = 0;
            for (entries.items) |e| {
                if (std.mem.eql(u8, e.outcome, "gone") and !e.branch_deleted and e.reason == null) continue;
                entries.items[kept] = e;
                kept += 1;
            }
            entries.items.len = kept;
        }
        try c.ok(.{ .worktrees = entries.items });
    }
};

fn writable(c: *const proto.Call, r: proto.grants.Resource) bool {
    const reg = c.conn.registry orelse return true;
    return reg.allows(c.conn.identity, .write, r, proto.grants.nowSeconds());
}

/// True while a descendant of `id` is not archived: it may run in the
/// worktree of its parent.
pub fn activeDescendant(state: *const eventlog.State, id: []const u8) bool {
    for (state.agents.values()) |*x| {
        if (x.state == .archived) continue;
        var parent = x.parent;
        var depth: usize = 0;
        while (parent) |up| : (depth += 1) {
            if (std.mem.eql(u8, up, id)) return true;
            if (depth > state.agents.count()) break;
            parent = if (state.agents.getPtr(up)) |u| u.parent else null;
        }
    }
    return false;
}

/// `agent.takeover` (write): the
/// host releases the agent's protocol process and hands back the
/// harness's resume command; the decider logs the `tui` binding and
/// `settled → handed_over`. The caller runs the command (the TUI in a
/// split, venomx in `pane`), and calls `agent.takeback` once it exits.
pub const Takeover = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, pane: ?[]const u8 = null };

    pub fn call(self: *Takeover, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        const a = c.arena();
        if (!try c.authorize(.write, agentResource(p.agent))) return;
        // The command runs the harness outside venom's mode and grants, and
        // a handed-over agent is out of reach of a stop: for people only.
        if (ag.principals) |pr| if (pr.actsForAgent(c.conn.identity))
            return c.fail("denied.agent_caller", "only a person can take an agent over", .{ .agent = p.agent });
        const x = ag.get(p.agent) orelse return notFound(c, p.agent);
        const harness_name = x.harness;
        // Hooks only for a split that can be reported (`TakeoverSplit`): this
        // TUI's own, or the venomx pane a TUI is about to open and name.
        const reports = if (p.pane) |pane|
            eventlog.agent.clientPanePid(pane) == c.conn.identity.peer_pid or std.mem.eql(u8, pane, eventlog.agent.pending_venomx_pane)
        else
            false;
        const hooks = reports;
        const spawn = ag.host.takeover(a, p.agent, hooks) catch |err| switch (err) {
            error.InvalidTransition => return c.fail("conflict.invalid_transition", "only a settled agent can be taken over", .{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state) }),
            error.TurnRunning => return c.fail("conflict.turn_running", "a turn runs; take over after it ends, or stop it first", .{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state) }),
            else => return hostFailure(c, err, p.agent, ag.get(p.agent)),
        };
        _ = ag.engine.submit(.{ .takeover = .{ .agent = p.agent, .pane = p.pane } }) catch |err| switch (err) {
            error.NotFound => return notFound(c, p.agent),
            error.HandedOver => return c.fail("conflict.handed_over", "the harness's own TUI has the agent already", .{ .agent = p.agent }),
            error.TurnRunning => return c.fail("conflict.turn_running", "a turn runs; take over after it ends, or stop it first", .{ .agent = p.agent }),
            error.InvalidTransition, error.Conflict, error.InvalidCommand => {
                const code = eventlog.decider.errorCode(@errorCast(err));
                return c.fail(code, "the agent's state does not allow this", .{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state) });
            },
            else => return err,
        };
        const Env = struct { name: []const u8, value: []const u8 };
        const env = try a.alloc(Env, spawn.env.len);
        for (spawn.env, env) |e, *o| o.* = .{ .name = e.name, .value = e.value };
        try c.ok(.{
            .agent = p.agent,
            .state = @tagName(ag.get(p.agent).?.state),
            .harness = harness_name,
            .argv = spawn.argv,
            .cwd = spawn.cwd orelse x.cwd orelse x.workspace,
            .env = env,
            .split = p.pane,
        });
    }
};

/// `agent.takeback` (write): `handed_over → settled`, then the
/// `harness.takeback` effect runs at once, importing the turns and usage
/// the harness's own TUI ran (`imported`). A settled agent is a no-op.
///
/// One writer per conversation: when the take-over split belongs to a
/// venom TUI client that still runs (pane `tui:<pid>`), only that client
/// may take the agent back, since it ends its harness TUI first. Anyone
/// else gets `conflict.owned_by_client` unless `force` (which may lose
/// lines the other client is still writing).
pub const Takeback = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, force: bool = false };

    pub fn call(self: *Takeback, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        if (!try c.authorize(.write, agentResource(p.agent))) return;
        const x0 = ag.get(p.agent) orelse return notFound(c, p.agent);
        const before = x0.turns;
        if (!p.force and x0.state == .handed_over) if (eventlog.agent.owningClient(x0.pane)) |owner| {
            // The caller's process (0 when unknown) must be the owner.
            if (c.conn.identity.peer_pid != owner)
                return c.fail("conflict.owned_by_client", try std.fmt.allocPrint(c.arena(), "venom TUI pid {d} runs this agent's take-over split; quit the harness there, or pass --force=true (may lose lines that client is still writing)", .{owner}), .{ .agent = p.agent, .pid = owner });
        };
        // One writer again: never while its venomx pane may run the harness.
        if (!p.force and x0.state == .handed_over) if (x0.pane) |pane| if (eventlog.agent.clientPanePid(pane) == null) {
            const a = c.arena();
            switch (takeover_pane.check(ag.engine.gpa, ag.environ, p.agent, pane)) {
                .gone => {},
                .running => return c.fail("conflict.takeover_pane_running", try std.fmt.allocPrint(a, "its harness still runs in pane {s}; quit it there, or pass --force=true (may lose lines it is still writing)", .{pane}), .{ .agent = p.agent, .pane = pane }),
                .unknown => |why| return c.fail("unavailable.takeover_pane", try std.fmt.allocPrint(a, "cannot tell whether its harness still runs in pane {s}: {s}; pass --force=true once it has ended", .{ pane, why }), .{ .agent = p.agent, .pane = pane }),
            }
        };
        const key_count = ag.engine.state.effects.count();
        _ = ag.engine.submit(.{ .takeback = .{ .agent = p.agent } }) catch |err| switch (err) {
            error.NotFound => return notFound(c, p.agent),
            error.InvalidTransition, error.Conflict, error.InvalidCommand => {
                const code = eventlog.decider.errorCode(@errorCast(err));
                return c.fail(code, "the agent is not handed over", .{ .agent = p.agent, .state = @tagName(ag.get(p.agent).?.state) });
            },
            else => return err,
        };
        _ = try ag.engine.runEffects();
        // The effect this call queued, if any (a settled agent queues none).
        var catch_up: []const u8 = "";
        if (ag.engine.state.effects.count() > key_count) {
            const e = ag.engine.state.effects.values()[ag.engine.state.effects.count() - 1];
            if ((e.done and !e.ok) or std.mem.eql(u8, e.detail, "no_catch_up")) catch_up = e.detail;
        }
        const x = ag.get(p.agent).?;
        try c.ok(.{ .agent = p.agent, .state = @tagName(x.state), .imported = x.turns - before, .catch_up = catch_up });
    }
};

/// `agent.takeover_pane` (write): which venomx pane runs the take-over
/// a TUI asked for with `--pane=venomx`. Once only, and by a person's client:
/// the ID is what later says whether the agent may be taken back.
pub const TakeoverPane = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, pane: []const u8 };

    pub fn call(self: *TakeoverPane, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        if (!try c.authorize(.write, agentResource(p.agent))) return;
        if (ag.principals) |pr| if (pr.actsForAgent(c.conn.identity))
            return c.fail("denied.agent_caller", "only the human's venom TUI can report a take-over pane", .{ .agent = p.agent });
        const valid = p.pane.len >= 2 and p.pane[0] == 'p' and for (p.pane[1..]) |ch| {
            if (!std.ascii.isDigit(ch)) break false;
        } else true;
        if (!valid) return c.fail("invalid_params.pane", "not a venomx pane ID", .{ .param = "pane" });
        const x = ag.get(p.agent) orelse return notFound(c, p.agent);
        if (x.state != .handed_over) return c.fail("conflict.not_handed_over", "the agent is not handed over", .{ .agent = p.agent, .state = @tagName(x.state) });
        if (x.pane == null or !std.mem.eql(u8, x.pane.?, eventlog.agent.pending_venomx_pane))
            return c.fail("conflict.takeover_pane_set", "this take-over's pane is already known", .{ .agent = p.agent });
        _ = try ag.engine.submit(.{ .takeover_pane = .{ .agent = p.agent, .pane = p.pane } });
        try c.ok(.{ .agent = p.agent, .pane = p.pane });
    }
};

/// `agent.takeover_split` (write): which process runs the
/// take-over split. `agent.takeover` answers before the command can start, so
/// the client says once it has. Only that process's descendants may then report
/// attention (`harness.hook`), which keeps out a shell split beside it.
///
/// The process decides who can raise attention, so the pid is checked, not taken
/// on the caller's word. No caller acting for an agent, and not init.
/// - A venom TUI's own split (pane `tui:<pid>`): the caller is that TUI, and
///   the process its own child.
/// - A venomx pane: venomx runs it, so the process is venomx's child and no
///   client's. venomx is asked (`takeover_pane.prove`), on this daemon's own
///   connection: the pane the take-over recorded, tagged as this agent's
///   take-over, must be running exactly this `(pid, start)`, as venomx's child.
///   If venomx can't say, nothing is recorded: no hook is accepted, which costs
///   attention and nothing else. If the pane has ended, nor is anything recorded.
///
/// The boundary: the tags keep out read-only splits. A
/// venom `write` caller who can create panes can stage one, tags and all, as it
/// already could through `tui:<self>`. That gains it nothing but a way to raise
/// attention, which stays an untrusted hint. venomx's socket is trusted at
/// same-UID level.
/// A plain `agent.takeover` has no split venom can check, and gets no hooks.
pub const TakeoverSplit = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, pid: i64 };

    pub fn call(self: *TakeoverSplit, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        if (!try c.authorize(.write, agentResource(p.agent))) return;
        if (ag.principals) |pr| if (pr.actsForAgent(c.conn.identity))
            return c.fail("denied.agent_caller", "only the human's venom TUI can report a take-over split", .{ .agent = p.agent });
        const x = ag.get(p.agent) orelse return notFound(c, p.agent);
        if (x.state != .handed_over) return c.fail("conflict.not_handed_over", "the agent is not handed over", .{ .agent = p.agent, .state = @tagName(x.state) });
        const pane = x.pane orelse return notCheckable(c, p.agent);
        const pid = std.math.cast(std.c.pid_t, p.pid) orelse return badPid(c, p.pid);
        if (pid <= 1) return badPid(c, p.pid);
        const root: proto.process.Ref = if (eventlog.agent.clientPanePid(pane)) |client| blk: {
            if (c.conn.identity.peer_pid != client)
                return c.fail("conflict.owned_by_client", "another venom TUI runs this agent's take-over split", .{ .agent = p.agent, .pid = client });
            const st = proto.process.stat(pid) catch return badPid(c, p.pid);
            if (st.parent != client) return badPid(c, p.pid);
            break :blk st.ref;
        } else blk: {
            // Not named yet: there is no pane to ask about.
            if (std.mem.eql(u8, pane, eventlog.agent.pending_venomx_pane)) return notCheckable(c, p.agent);
            switch (takeover_pane.prove(ag.engine.gpa, ag.environ, p.agent, pane, pid)) {
                .root => |r| break :blk r,
                .gone => return c.fail("conflict.takeover_pane_gone", "its venomx pane has ended", .{ .agent = p.agent, .pane = pane }),
                .refused => return badPid(c, p.pid),
                .unknown => |why| return c.fail("unavailable.takeover_pane", try std.fmt.allocPrint(c.arena(), "cannot check the process of pane {s}: {s}; hooks from it will be refused", .{ pane, why }), .{ .agent = p.agent, .pane = pane }),
            }
        };
        _ = try ag.engine.submit(.{ .takeover_split = .{ .agent = p.agent, .root = .{ .pid = root.pid, .start = root.start } } });
        try c.ok(.{ .agent = p.agent, .pid = p.pid });
    }

    fn notCheckable(c: *proto.Call, agent: []const u8) !void {
        return c.fail("conflict.not_client_split", "this take-over has no split whose process can be checked", .{ .agent = agent });
    }

    fn badPid(c: *proto.Call, pid: i64) !void {
        return c.fail("invalid_params.pid", "no such process, or not this take-over's split", .{ .param = "pid", .value = pid });
    }
};

/// `harness.hook` (read), what
/// `venom agent hook` forwards. The caller carries no token: it is whoever
/// the process ancestry walk says it is, and `read` is all it gets. The
/// pane check is what lets it report: the process running the agent's
/// take-over split, matched on `(pid, starttime)`, must be on the caller's
/// chain. Nothing outside the split can raise attention for the agent, least
/// of all a harness in protocol mode. Inside it anything can, the model's
/// Bash included: this attention is a hint for the human, never trusted.
pub const Hook = struct {
    agents: *Agents,
    pub const Params = struct { agent: []const u8, input: []const u8 };

    pub fn call(self: *Hook, c: *proto.Call, p: Params) anyerror!void {
        const ag = self.agents;
        const a = c.arena();
        if (!try c.authorize(.read, agentResource(p.agent))) return;
        // A split's processes are the human's. An agent, or a token or process
        // of one, raises no attention for another.
        if (ag.principals) |pr| if (pr.actsForAgent(c.conn.identity))
            return c.fail("denied.agent_caller", "an agent cannot report hooks", .{ .agent = p.agent });
        const x = ag.get(p.agent) orelse return notFound(c, p.agent);
        if (x.state != .handed_over) return c.fail("conflict.not_handed_over", "the agent is not handed over", .{ .agent = p.agent, .state = @tagName(x.state) });
        const chain = c.conn.identity.chain;
        const inside = if (x.pane_root) |r| !chain.failed and chain.contains(.{ .pid = @intCast(r.pid), .start = r.start }) else false;
        if (!inside) {
            var buf: [24]u8 = undefined;
            return c.fail("denied.outside_pane", "only a process inside the agent's take-over split can report for it", .{ .agent = p.agent, .principal = proto.grants.name(c.conn.identity.principal, &buf) });
        }
        const parsed = if (std.mem.eql(u8, x.harness, harness.claude_code.name))
            harness.claude_code.parseHook(a, p.input)
        else if (std.mem.eql(u8, x.harness, harness.codex.name))
            harness.codex.parseNotify(a, p.input, x.harness_session orelse "")
        else
            return c.fail("unsupported.harness_capability", "this harness reports no hooks", .{ .agent = p.agent, .harness = x.harness });
        const report = parsed catch return c.fail("invalid_params.input", "input is not the hook's JSON", .{ .param = "input" });
        const session = x.harness_session orelse "";
        const transcript = if (report.transcript) |t| (if (harness.claude_code.isTranscriptOf(t, session)) t else null) else null;
        const kind: ?[]const u8 = if (report.kind) |k| @tagName(k) else null;
        _ = ag.engine.submit(.{ .away = .{ .agent = p.agent, .kind = kind, .reason = report.reason, .transcript_ref = transcript } }) catch |err| switch (err) {
            error.NotFound => return notFound(c, p.agent),
            error.InvalidTransition => return c.fail("conflict.not_handed_over", "the agent is not handed over", .{ .agent = p.agent }),
            else => return err,
        };
        try c.ok(.{ .agent = p.agent, .kind = kind orelse "" });
    }
};

const testing = std.testing;

test "titleOf: first non-empty line, cut on a UTF-8 boundary" {
    try testing.expectEqualStrings("Add a hello verb", titleOf("\n  Add a hello verb  \nwith tests"));
    try testing.expectEqualStrings("", titleOf("   "));
    var buf: [80]u8 = undefined; // 40 two-byte characters
    for (0..40) |i| @memcpy(buf[2 * i ..][0..2], "\xc3\xa9");
    const long: []const u8 = &buf;
    const t = titleOf(long);
    try testing.expect(t.len <= title_max and t.len % 2 == 0);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}
