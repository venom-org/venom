//! The harness host: the plumbing every adapter shares.
//!
//! It keeps one **binding** per agent (the agent, its
//! adapter, its conversation and at most one harness process), runs the
//! processes, decodes their output through the adapter, and logs the
//! normalized events through the engine, which derives agent state from
//! them. Adapters never touch agent state or processes.
//!
//! Supervision (venom-std `supervisor`): processes are adopted by
//! `supervisor.Leaders` (pinned waits, group termination with escalation)
//! and restarted with `supervisor.Policy` backoff:
//!
//! - An unexpected exit ends the open turn as `failed` with
//!   `failed.harness_exited` (a send that never started a turn gets one
//!   first), so the agent shows `failed`.
//! - A failed exit (non-zero code, signal) is restarted after the policy's
//!   delay, through `start` with the binding's `harness_session` (that is,
//!   `reattach`). The restart sends nothing: venom never retries a turn on
//!   its own, so quota spend stays a human decision;
//!   `retry` (`R` in the TUI) sends `resume_prompt`.
//! - After `max_failures` consecutive failures the binding gives up until
//!   the next explicit `send` or `retry`, which also resets the count. A
//!   binary that cannot be executed (exit 127 before `session`) gives up at
//!   once with `unavailable.harness_not_found`.
//! - A clean exit 0 is not restarted; the next `send` reattaches.
//! - No `session` within `start_timeout_ms` terminates the process
//!   (`timeout.harness_start`), which then counts as a failure.
//!
//! `shutdown`: interrupts running turns, waits up to
//! `shutdown_grace_ms` for their `turn.ended`, then terminates every
//! process group (SIGTERM, SIGKILL after the grace period). A turn still
//! open then is logged `interrupted` with `daemon_shutdown`.
//!
//! Stop and take back: the decider puts
//! `harness.stop` and `harness.takeback` effects in the outbox, and the
//! host runs them (idempotent per key):
//!
//! - `harness.stop {agent, turn}`: requests the harness is still waiting on
//!   get `cancel_turn`, which ends the turn; with none, the adapter's
//!   `interrupt` (or, without that capability, `stop`: the process group
//!   ends and the turn is logged `interrupted`). If no process runs the
//!   turn any more, the host logs `turn.ended {interrupted}` itself, so the
//!   agent always settles.
//! - `harness.takeback {agent, since}`: binds the agent again and, if the
//!   adapter can `catch_up`, imports the turns that ran in the harness's
//!   own TUI since `since` (through the conversation, so they get venom's
//!   ids). The next `send` reattaches.
//!
//! `fork` never holds the reactor: it logs the
//! decider's `harness.fork` effect and returns its key. The effect worker runs
//! the executor once per reactor turn, each run one non-waiting step of the
//! adapter, and it stays pending (`error.Retry`) while the harness has not
//! answered. So verbs, other effects and approval expiry go on meanwhile. The
//! completion is the result: `detail` is the new conversation's id, or the
//! error code with `ok = false`. An agent runs one fork at a time, oldest
//! first. An idle agent gets a process for the fork, ended when the fork is
//! over and not restarted, unless a `send` came meanwhile: it then serves that
//! turn. While that process ends, `send` is `conflict.turn_running`, since it
//! would be written to a process that no longer reads. A daemon that stops
//! mid-fork leaves the effect pending, and the next one forks again; at worst
//! the harness keeps a copy nobody uses.
//!
//! Take-over (`takeover`): releases a settled agent's protocol
//! process, waits for it to exit, and returns the adapter's resume command.
//!
//! The queue: `dispatchQueued` starts the
//! oldest waiting agents while fewer than `agents.max_concurrent` hold a
//! slot. A task that cannot be sent fails the agent, with a turn, so it shows
//! up in the inbox; nothing waits for a slot forever.
//!
//! Answers: the decider resolves an answered request and queues a
//! `harness.respond` effect in the same commit; `executor()` runs it. It is
//! idempotent per key. The payload's answer reaches the adapter
//! whole: `decision`, plus `reason` (deny reason, reject feedback) and
//! `args_json` (edited args, question picks) when given. A request
//! whose process is gone is not delivered (`durable_requests = false`; detail
//! `failed.harness_exited` if the decider did not know yet). The decider then
//! handles the answer like one to a stale request, below.
//!
//! Stale requests: the decider records a
//! one-shot decision (`eventlog/oneshot.zig`) and marks the effect `resume`.
//! The executor then reattaches and sends `resume_prompt`, with a deny's
//! reason or a reject's feedback added. If a turn runs already, only that note
//! is sent, as a steer or a queued message, as the harness allows. When the
//! harness asks for the call again the decider answers it from the decision,
//! so the answer reaches the adapter like any other. A resume that fails
//! completes with `ok = false`, and the decider closes the decision and brings
//! the request back. `cancel_turn` has no turn to end: it completes with
//! `ok = false` and detail `stale`.
//!
//! Everything runs on the daemon's reactor thread, like the engine. The
//! engine must outlive the host.
const std = @import("std");
const supervisor = @import("supervisor");
const log = @import("log");
const eventlog = @import("../eventlog/root.zig");
const contract = @import("contract.zig");
const Process = @import("process.zig").Process;
const process = @import("process.zig");
const c = std.c;

pub const Options = struct {
    policy: supervisor.Policy = .{ .initial_ms = 1_000, .max_ms = 60_000, .reset_after_ms = 60_000, .max_failures = 5 },
    /// `harness.shutdown_grace` (default `"5s"`).
    shutdown_grace_ms: u32 = 5_000,
    /// `harness.start_timeout` (default `"30s"`).
    start_timeout_ms: u32 = 30_000,
    /// `harness.resume_prompt`.
    resume_prompt: []const u8 = "Continue from where you stopped.",
    /// `harness.body_max`: bytes of tool output or diff adapters
    /// keep inline per call (default 256 KiB).
    body_max: u32 = 262_144,
    logger: ?*log.Logger = null,
    /// Told every restart delay as it is scheduled, on the reactor thread.
    /// `Binding` only holds the current backoff, which a short delay can pass
    /// between two looks at it.
    on_backoff: ?OnBackoff = null,
};

pub const OnBackoff = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, delay_ms: u32) void,
};

pub const Registered = struct { harness: []const u8, adapter: contract.Adapter };

/// Per-process caller credentials. Before a
/// harness process starts, `token` mints its token (gpa-owned; the host puts
/// it into the process's environment as `VENOM_TOKEN`, then zeroes and
/// frees it; never argv, never a log); `bind` ties it to the started pid;
/// `release` revokes it once the process is gone or failed to start.
pub const Credentials = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        token: *const fn (ptr: *anyopaque, agent: []const u8) anyerror!?[]u8,
        bind: *const fn (ptr: *anyopaque, agent: []const u8, pid: c.pid_t) void,
        release: *const fn (ptr: *anyopaque, agent: []const u8) void,
    };

    pub fn init(impl: anytype) Credentials {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .token = token, .bind = bind, .release = release };
            fn token(ptr: *anyopaque, agent: []const u8) anyerror!?[]u8 {
                return @as(*T, @ptrCast(@alignCast(ptr))).token(agent);
            }
            fn bind(ptr: *anyopaque, agent: []const u8, pid: c.pid_t) void {
                @as(*T, @ptrCast(@alignCast(ptr))).bind(agent, pid);
            }
            fn release(ptr: *anyopaque, agent: []const u8) void {
                @as(*T, @ptrCast(@alignCast(ptr))).release(agent);
            }
        }.vt };
    }
};

/// The environment variables a harness process gets from `Credentials`;
/// an adapter's own values for them are dropped.
pub const token_env = "VENOM_TOKEN";
pub const principal_env = "VENOM_PRINCIPAL";

pub const Status = enum {
    /// No process; the next send starts one.
    idle,
    running,
    /// Waiting to restart after a failed exit.
    backoff,
    /// Too many failures, or the binary is missing; waits for a send.
    gave_up,
    /// `stop`, `release` or `shutdown` asked it to exit.
    stopping,
};

pub const Binding = struct {
    host: *Host,
    adapter: contract.Adapter,
    descriptor: contract.Descriptor,
    conv: contract.Conversation,
    process: ?Process = null,
    status: Status = .idle,
    /// Consecutive failures; drives the backoff.
    failures: u32 = 0,
    restarts: u32 = 0,
    started_ms: i64 = 0,
    next_ms: i64 = 0,
    last_exit: ?process.Exit = null,
    /// The error code of the last unexpected exit.
    last_error: ?[]const u8 = null,
    got_session: bool = false,
    timed_out: bool = false,
    stop_detail: []const u8 = "stopped",
    /// The agent settled before its turn started (a stop of a dispatched
    /// `queued` agent): nothing this process still says is logged, so a late
    /// turn is neither a state change nor a slot.
    discard: bool = false,
    /// `harness.respond` keys already delivered (idempotency).
    answered: std.StringHashMapUnmanaged(void) = .empty,
    /// The fork under way (`harness.fork`).
    fork: ?Fork = null,
    /// A process told to end between turns (a fork started it, or `mcpOff`
    /// needs a new one) has not exited.
    fork_ending: bool = false,

    const Fork = struct {
        /// The effect's key; gpa-owned.
        key: []u8,
        /// The process it asks; null until it has one.
        pid: ?c.pid_t,
        /// That process was started for this fork, so it ends with it.
        ours: bool = false,
    };

    fn channel(self: *Binding) contract.Channel {
        return .{ .ptr = self, .vtable = &.{ .write = write, .signal = signal, .close_input = closeInput } };
    }
    fn write(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        const p = if (self.process) |*p| p else return error.HarnessExited;
        try p.write(bytes);
    }
    fn signal(ptr: *anyopaque, sig: std.posix.SIG) anyerror!void {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        const p = if (self.process) |*p| p else return error.HarnessExited;
        try p.signal(sig);
    }
    fn closeInput(ptr: *anyopaque) void {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        if (self.process) |*p| p.closeInput();
    }

    pub fn running(self: *const Binding) bool {
        return self.process != null;
    }
};

/// venom's mode (`config.Mode`) as the harness's own, if it has that mode.
/// `ask` is the harness default: nothing to pass.
fn permissionMode(mode: ?[]const u8, known: []const []const u8) ?[]const u8 {
    const m = mode orelse return null;
    if (std.mem.eql(u8, m, "ask")) return null;
    const own = contract.modeName(m) orelse return null;
    for (known) |k| if (std.mem.eql(u8, k, own)) return own;
    return null;
}

/// `env` without the adapter's credential variables, plus the token and
/// its principal ID (`vnt1.venom.<principal>.<secret>`) when there is one.
fn credentialEnv(a: std.mem.Allocator, env: []const contract.EnvVar, token: ?[]const u8) ![]const contract.EnvVar {
    var out: std.ArrayList(contract.EnvVar) = .empty;
    for (env) |e| if (!std.mem.eql(u8, e.name, token_env) and !std.mem.eql(u8, e.name, principal_env)) try out.append(a, e);
    if (token) |t| {
        var parts = std.mem.splitScalar(u8, t, '.');
        _ = parts.next();
        _ = parts.next();
        try out.append(a, .{ .name = token_env, .value = t });
        try out.append(a, .{ .name = principal_env, .value = parts.next() orelse "" });
    }
    return out.items;
}

pub const SlotRelease = struct {
    ctx: *anyopaque,
    released: *const fn (ctx: *anyopaque, agent: []const u8) bool,
};

/// What a queued agent's start waits for before its harness process is made
/// (the sign-in check).
pub const StartGate = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, agent: []const u8) Verdict,

    pub const Verdict = enum {
        /// Start it.
        go,
        /// Not yet: the answer is being asked for. The queue waits.
        wait,
        /// The harness has no usable sign-in: the agent fails unstarted.
        signed_out,
    };
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    engine: *eventlog.Engine,
    adapters: []const Registered,
    options: Options,
    leaders: supervisor.Leaders,
    bindings: std.StringArrayHashMapUnmanaged(*Binding) = .empty,
    executors: [4]eventlog.Executor = undefined,
    stop_effect: Effect(.stop) = .{},
    takeback_effect: Effect(.takeback) = .{},
    fork_effect: Effect(.fork) = .{},
    /// The id the last finished fork reported, until the next one; gpa-owned.
    fork_detail: ?[]u8 = null,
    shut: bool = false,
    /// Asks whether an agent gives up its concurrency slot for now (an open
    /// `agent.wait`). Null: none does.
    slot_released: ?SlotRelease = null,
    /// Asked before a queued agent is dispatched. Null: none is held back.
    start_gate: ?StartGate = null,
    /// Per-process tokens for the harnesses; none when null.
    credentials: ?Credentials = null,
    /// The end of each open tool call's live output (`tool.updated`),
    /// keyed `agent/call`; not durable.
    tails: std.StringHashMapUnmanaged(std.ArrayList(u8)) = .empty,

    /// Bytes of live output kept per open tool call.
    const tail_max = 4096;

    pub fn init(gpa: std.mem.Allocator, engine: *eventlog.Engine, adapters: []const Registered, options: Options) Host {
        return .{ .gpa = gpa, .engine = engine, .adapters = adapters, .options = options, .leaders = .init(gpa, .{}) };
    }

    /// Shuts down (if not done yet) and frees everything. Every child is
    /// gone afterwards: `Leaders.deinit` kills any group still alive.
    pub fn deinit(self: *Host) void {
        self.shutdown() catch |err| self.warn("harness shutdown failed", .{ .@"error" = err });
        for (self.bindings.values()) |b| {
            if (b.process) |*p| p.deinit();
            var it = b.answered.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            b.answered.deinit(self.gpa);
            if (b.fork) |f| self.gpa.free(f.key);
            b.conv.deinit();
            self.gpa.destroy(b);
        }
        self.bindings.deinit(self.gpa);
        if (self.fork_detail) |d| self.gpa.free(d);
        var tails = self.tails.iterator();
        while (tails.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.tails.deinit(self.gpa);
        self.leaders.deinit();
    }

    /// The `harness.respond`, `harness.stop`, `harness.takeback` and
    /// `harness.fork` executors; install them in the engine's options. The returned slice
    /// lives as long as the host, which must not move afterwards.
    pub fn executor(self: *Host) []const eventlog.Executor {
        self.stop_effect.host = self;
        self.takeback_effect.host = self;
        self.fork_effect.host = self;
        self.executors = .{
            eventlog.Executor.init("harness.respond", self),
            eventlog.Executor.init("harness.stop", &self.stop_effect),
            eventlog.Executor.init("harness.takeback", &self.takeback_effect),
            eventlog.Executor.init("harness.fork", &self.fork_effect),
        };
        return &self.executors;
    }

    pub fn binding(self: *Host, agent: []const u8) ?*Binding {
        return self.bindings.get(agent);
    }

    // ------------------------------------------------------------ verbs

    /// Whether a `send` to `agent` would start its harness process: it has
    /// none (never started, exited, or crashed). That is a `reattach` when the
    /// agent already has a conversation.
    pub fn startsProcess(self: *const Host, agent: []const u8) bool {
        const b = self.bindings.get(agent) orelse return true;
        return b.process == null;
    }

    /// The checks `send` makes before it starts anything: the agent's state,
    /// the mode against the harness's capabilities, a fork's end. A caller
    /// that holds a send (sign-in) runs them first, so a send that could
    /// never be made is answered at once.
    pub fn checkSend(self: *Host, agent: []const u8, mode: contract.SendMode) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        switch (st.state) {
            .archived => return error.InvalidTransition,
            .handed_over => return error.HandedOver,
            else => {},
        }
        const b = try self.bind(agent);
        const busy = b.conv.inTurn() or b.conv.sending or st.state == .running or st.state == .needs_you;
        try contract.checkSend(b.descriptor.caps, mode, busy);
        if (b.fork_ending) return error.TurnRunning;
    }

    /// `send`: starts the agent's harness process if it
    /// has none (also after a crash, resetting the failure count: this is an
    /// explicit human action), then writes the message.
    pub fn send(self: *Host, agent: []const u8, text: []const u8, mode: contract.SendMode) !void {
        try self.checkSend(agent, mode);
        const b = try self.bind(agent);
        // The process a fork started now serves this turn.
        if (b.fork) |*f| f.ours = false;
        // A sign-in answer can go stale between the check that let
        // this send through and the start here: the harness then reports its
        // own failure, as for any sign-in lost mid-turn.
        try self.ensureProcess(b);
        b.adapter.send(&b.conv, text, mode) catch |err| switch (err) {
            // The process is already gone: its exit, still to be reaped,
            // fails this send's turn.
            error.HarnessExited => {},
            else => return err,
        };
        try b.conv.promptSent(text, mode);
        if (!b.conv.inTurn()) b.conv.sending = true;
    }

    /// Whether `agent` counts against `agents.max_concurrent`: it holds a
    /// slot and has not given it up while it waits for its children.
    fn counts(self: *const Host, id: []const u8, x: *const eventlog.decider.Agent) bool {
        if (!x.holdsSlot()) return false;
        const r = self.slot_released orelse return true;
        return !r.released(r.ctx, id);
    }

    /// Whether `agent` may have a slot now: fewer than `max` are held and no
    /// older agent is waiting.
    pub fn slotFree(self: *const Host, agent: []const u8, max: usize) bool {
        var live: usize = 0;
        var first: ?[]const u8 = null;
        for (self.engine.state.agents.keys(), self.engine.state.agents.values()) |id, *x| {
            if (self.counts(id, x)) live += 1;
            if (first == null and x.waiting()) first = id;
        }
        const oldest = first orelse return false;
        return live < max and std.mem.eql(u8, oldest, agent);
    }

    /// Logs that the waiting `agent` got a slot, then sends its held task.
    pub fn dispatch(self: *Host, agent: []const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        const task = st.task orelse return error.InvalidTransition;
        _ = try self.engine.submit(.{ .dispatch = .{ .agent = agent } });
        try self.send(agent, task, .turn);
    }

    /// Starts the oldest waiting agents while slots are free (reactor turn,
    /// and after a restart: the tasks are in the log).
    pub fn dispatchQueued(self: *Host, max: usize) !void {
        if (self.shut) return;
        const state = &self.engine.state;
        var live: usize = 0;
        for (state.agents.keys(), state.agents.values()) |id, *x| live += @intFromBool(self.counts(id, x));
        var i: usize = 0;
        while (i < state.agents.count() and live < max) : (i += 1) {
            if (!state.agents.values()[i].waiting()) continue;
            const id = state.agents.keys()[i];
            if (self.start_gate) |g| switch (g.check(g.ctx, id)) {
                .go => {},
                // Oldest first: the ones behind it wait as well.
                .wait => break,
                .signed_out => {
                    // Not started: it leaves the queue as a failed turn that
                    // never sent its task.
                    _ = try self.engine.submit(.{ .dispatch = .{ .agent = id } });
                    try self.failDispatch(id, "unavailable.harness_not_signed_in");
                    continue;
                },
            };
            live += 1;
            self.dispatch(id) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.warn("cannot start a queued agent", .{ .agent = id, .@"error" = err });
                try self.failDispatch(id, if (contract.failure(err)) |f| f.code else "failed.harness_exited");
            };
        }
    }

    /// A dispatched task never reached the harness: the agent fails, with a
    /// turn, as a send that never started one does.
    fn failDispatch(self: *Host, agent: []const u8, code: []const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return;
        return self.failStart(agent, st.task, code);
    }

    /// A prompt that never reached the harness (`prompt`, when there is one):
    /// the agent fails with a turn that carries `code`.
    fn failStart(self: *Host, agent: []const u8, prompt: ?[]const u8, code: []const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return;
        if (self.bindings.get(agent)) |b| {
            if (prompt) |task| try b.conv.promptSent(task, .turn);
            b.conv.sending = true;
            return b.conv.abandon(code);
        }
        var buf: [32]u8 = undefined;
        const turn = try std.fmt.bufPrint(&buf, "t{d}", .{st.turns + 1});
        try self.submit(.{ .record = .{ .turn_started = .{ .agent = agent, .turn = turn, .origin = "user" } } });
        if (prompt) |task| try self.submit(.{ .record = .{ .turn_prompt = .{ .agent = agent, .turn = turn, .text = task } } });
        try self.submit(.{ .record = .{ .turn_ended = .{ .agent = agent, .turn = turn, .reason = "failed", .error_code = code } } });
    }

    /// A send is on its way to the agent's harness, or its turn runs there,
    /// and nothing has asked the process to end.
    pub fn working(self: *const Host, agent: []const u8) bool {
        const b = self.bindings.get(agent) orelse return false;
        return b.status != .stopping and (b.conv.inTurn() or b.conv.sending);
    }

    /// The mode harness `name` can hold an agent to that must not exceed
    /// `mode` (`contract.enforceableMode`). Null: it can't, or no adapter.
    /// May run the harness's `--version` (a probe). The result is a static
    /// mode name or `mode`.
    pub fn enforceableMode(self: *Host, name: []const u8, mode: []const u8) ?[]const u8 {
        for (self.adapters) |r| if (std.mem.eql(u8, r.harness, name)) {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const d = r.adapter.probe(arena.allocator()) catch return null;
            return contract.enforceableMode(d.caps.permission_modes, mode);
        };
        return null;
    }

    /// Retry a failed agent (`R` in the TUI): reattach
    /// if needed and send `resume_prompt`.
    pub fn retry(self: *Host, agent: []const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        if (st.state != .failed) return error.InvalidTransition;
        try self.send(agent, self.options.resume_prompt, .turn);
    }

    pub fn interrupt(self: *Host, agent: []const u8) !void {
        const b = self.bindings.get(agent) orelse return error.NotFound;
        if (!b.descriptor.caps.interrupt) return error.UnsupportedCapability;
        if (!b.conv.inTurn() or b.process == null) return;
        try b.adapter.interrupt(&b.conv);
    }

    /// `release`: stop driving between turns. The process
    /// exits on its own; returns the resume record.
    pub fn release(self: *Host, agent: []const u8) !contract.Resume {
        const b = self.bindings.get(agent) orelse return error.NotFound;
        if (!b.descriptor.caps.release) return error.UnsupportedCapability;
        if (b.conv.inTurn() or b.conv.sending) return error.TurnRunning;
        const session = b.conv.harness_session orelse return error.HarnessSessionNotFound;
        if (b.process != null) {
            try b.adapter.release(&b.conv);
            b.status = .stopping;
            b.stop_detail = "released";
        }
        const fork_source = if (self.engine.state.agents.getPtr(agent)) |st| st.fork_source else null;
        return .{ .harness = b.conv.harness, .harness_session = session, .fork_source = fork_source, .cwd = b.conv.cwd, .last_turn = b.conv.last_turn };
    }

    /// Take-over: stops
    /// driving a settled agent and returns the command that opens its
    /// conversation in the harness's own TUI. The protocol process is
    /// released (`release`, else stopped) and has exited when this returns,
    /// so the TUI is the only client of the conversation. The caller logs
    /// the `takeover` command. Mid-turn: `TurnRunning`.
    pub fn takeover(self: *Host, a: std.mem.Allocator, agent: []const u8, hooks: bool) !contract.Spawn {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        switch (st.state) {
            .settled => {},
            .handed_over => return error.HandedOver,
            .queued, .running, .needs_you => return error.TurnRunning,
            .failed, .archived => return error.InvalidTransition,
        }
        const b = try self.bind(agent);
        if (!b.descriptor.caps.resume_tui) return error.UnsupportedCapability;
        // A fork that has not started: take-back must be able to see the copy
        // the command makes. Refused before anything
        // changes; the adapter checks `fork_at` too.
        if (st.fork_source != null and b.descriptor.caps.catch_up == .none) return error.UnsupportedCapability;
        if (b.conv.inTurn() or b.conv.sending) return error.TurnRunning;
        const session = b.conv.harness_session orelse return error.HarnessSessionNotFound;
        if (b.process != null) {
            if (b.descriptor.caps.release) {
                try b.adapter.release(&b.conv);
                b.status = .stopping;
                b.stop_detail = "released";
            } else self.terminate(b, "released");
            try self.awaitExit(b);
        }
        // Nothing restarts it while the harness's TUI has the conversation.
        b.status = .idle;
        return b.adapter.resumeCommand(a, .{ .agent = agent, .hooks = hooks, .harness = b.conv.harness, .harness_session = session, .fork_source = st.fork_source, .cwd = b.conv.cwd, .last_turn = b.conv.last_turn, .transcript_ref = st.transcript_ref });
    }

    /// Waits for `b`'s process to exit (a release), terminating it after
    /// the shutdown grace period. Bounded.
    fn awaitExit(self: *Host, b: *Binding) !void {
        var deadline = supervisor.monotonicMs() + self.options.shutdown_grace_ms;
        while (b.process != null and supervisor.monotonicMs() < deadline) try self.poll(10);
        if (b.process == null) return;
        self.terminate(b, "released");
        deadline = supervisor.monotonicMs() + self.options.shutdown_grace_ms + supervisor.leaders.kill_wait_ms + 1_000;
        while (b.process != null and supervisor.monotonicMs() < deadline) try self.poll(10);
        if (b.process != null) return error.HarnessExited;
    }

    /// `stop`: ends the process group; a running turn is logged
    /// `interrupted` once the process is gone.
    pub fn stop(self: *Host, agent: []const u8) !void {
        const b = self.bindings.get(agent) orelse return;
        self.terminate(b, "stopped");
        if (b.status == .backoff or b.status == .gave_up) b.status = .idle;
    }

    /// Ends an archived agent's idle process and waits for it (bounded), so
    /// nothing runs in its worktree when that is removed.
    pub fn retire(self: *Host, agent: []const u8) !void {
        const b = self.bindings.get(agent) orelse return;
        if (b.process == null) return;
        self.terminate(b, "stopped");
        try self.awaitExit(b);
        b.status = .idle;
    }

    /// `fork` between turns, through venom's turn `through_turn`
    /// (`fork = at_turn`) or the latest one. Refused at once when it cannot
    /// run; otherwise returns the key of the `harness.fork` effect (in `a`),
    /// whose completion is the result (see the top of this file). Never waits.
    /// `error.NotFound`: no such agent, or the turn is unknown or has no
    /// harness id (it never started in the harness, or was logged before ids
    /// were kept).
    pub fn fork(self: *Host, a: std.mem.Allocator, agent: []const u8, through_turn: ?[]const u8) ![]const u8 {
        return self.forkWith(a, agent, through_turn, null);
    }

    /// `fork` whose new agent starts on `task` (`agent.fork`).
    pub fn forkWith(self: *Host, a: std.mem.Allocator, agent: []const u8, through_turn: ?[]const u8, task: ?[]const u8) ![]const u8 {
        try self.checkFork(agent, through_turn);
        const key = try eventlog.decider.forkKey(&self.engine.state, agent, a);
        _ = try self.engine.submit(.{ .fork = .{ .agent = agent, .through_turn = through_turn, .task = task } });
        return key;
    }

    /// What `agent`'s adapter declares, without running the harness. Null: no
    /// adapter for it in this build.
    pub fn capsOf(self: *const Host, agent: []const u8) ?contract.Caps {
        if (self.bindings.get(agent)) |b| return b.descriptor.caps;
        const st = self.engine.state.agents.getPtr(agent) orelse return null;
        for (self.adapters) |r| if (std.mem.eql(u8, r.harness, st.harness)) return r.adapter.caps();
        return null;
    }

    /// `compact`, between turns: a turn the harness runs on itself.
    pub fn compact(self: *Host, agent: []const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        switch (st.state) {
            .archived => return error.InvalidTransition,
            .handed_over => return error.HandedOver,
            .running, .needs_you => return error.TurnRunning,
            .queued, .settled, .failed => {},
        }
        const b = try self.bind(agent);
        if (!b.descriptor.caps.compact) return error.UnsupportedCapability;
        if (b.conv.inTurn() or b.conv.sending or b.fork_ending or b.fork != null) return error.TurnRunning;
        if (b.conv.harness_session == null) return error.HarnessSessionNotFound;
        try self.ensureProcess(b);
        b.adapter.compact(&b.conv) catch |err| switch (err) {
            // Gone already: its exit, still to be reaped, fails this turn.
            error.HarnessExited => {},
            else => return err,
        };
        if (!b.conv.inTurn()) b.conv.sending = true;
    }

    /// Turns MCP servers off for `agent`: logged, so every later
    /// process starts without them, and a live process is told to end, without
    /// waiting. The next `send` starts one.
    pub fn mcpOff(self: *Host, agent: []const u8, servers: []const []const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        if (st.state == .archived) return error.InvalidTransition;
        const b = try self.bind(agent);
        if (!b.descriptor.caps.mcp_off) return error.UnsupportedCapability;
        if (b.conv.inTurn() or b.conv.sending or b.fork_ending or b.fork != null) return error.TurnRunning;
        _ = try self.engine.submit(.{ .mcp_off = .{ .agent = agent, .servers = servers } });
        if (b.process != null) {
            self.terminate(b, "stopped");
            b.fork_ending = true;
        }
        if (b.status == .backoff or b.status == .gave_up) b.status = .idle;
    }

    /// What `fork` needs of the agent, when asked and when it starts.
    fn checkFork(self: *Host, agent: []const u8, through_turn: ?[]const u8) !void {
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        switch (st.state) {
            // Its worktree may be gone (`retire`).
            .archived => return error.InvalidTransition,
            .handed_over => return error.HandedOver,
            else => {},
        }
        const b = try self.bind(agent);
        const level = b.descriptor.caps.fork;
        if (level == .none or (through_turn != null and level != .at_turn)) return error.UnsupportedCapability;
        if (b.conv.inTurn() or b.conv.sending) return error.TurnRunning;
        // Nothing to copy, whichever harness it is; no process starts for it.
        if (b.conv.harness_session == null) return error.HarnessSessionNotFound;
        if (through_turn) |t| _ = try harnessTurn(st, t);
    }

    /// The `harness.fork` executor: one step per run, `error.Retry` until the
    /// harness has answered.
    pub fn runFork(self: *Host, key: []const u8, payload: []const u8) !eventlog.Executor.Outcome {
        // The next daemon runs it again: nothing may start now.
        if (self.shut) return error.Retry;
        const P = struct { agent: []const u8, through_turn: ?[]const u8 = null };
        const parsed = try std.json.parseFromSlice(P, self.gpa, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const req = parsed.value;
        return self.forkStep(key, req.agent, req.through_turn) catch |err| switch (err) {
            error.Retry, error.OutOfMemory => |e| return e,
            // The decider knew the agent, and agents stay.
            error.NotFound => .{ .ok = false, .detail = "not_found.turn" },
            error.InvalidTransition => .{ .ok = false, .detail = eventlog.decider.errorCode(error.InvalidTransition) },
            else => |e| {
                if (contract.failure(e)) |f| return .{ .ok = false, .detail = f.code };
                return e;
            },
        };
    }

    fn forkStep(self: *Host, key: []const u8, agent: []const u8, through_turn: ?[]const u8) !eventlog.Executor.Outcome {
        const b = try self.bind(agent);
        if (b.fork) |f| {
            if (!std.mem.eql(u8, f.key, key)) return error.Retry;
        } else {
            if (b.fork_ending) return error.Retry;
            try self.checkFork(agent, through_turn);
            b.fork = .{ .key = try self.gpa.dupe(u8, key), .pid = if (b.process) |*p| p.pid() else null };
        }
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const step = self.askFork(arena.allocator(), b, if (through_turn) |t| try harnessTurn(st, t) else null) catch |err| {
            self.endFork(b);
            return err;
        };
        const id = switch (step) {
            .pending => return error.Retry,
            .done => |id| id,
        };
        self.endFork(b);
        const detail = try self.gpa.dupe(u8, id);
        if (self.fork_detail) |d| self.gpa.free(d);
        self.fork_detail = detail;
        return .{ .detail = detail };
    }

    /// One call of the adapter, with a process if it wants one.
    fn askFork(self: *Host, a: std.mem.Allocator, b: *Binding, harness_turn: ?[]const u8) !contract.ForkStep {
        const f = &b.fork.?;
        // The process it asked is gone, and a later one never heard of it.
        if (f.pid) |pid| if (b.process == null or b.process.?.pid() != pid) return error.HarnessExited;
        return b.adapter.fork(a, &b.conv, harness_turn) catch |err| {
            if (err != error.HarnessExited or f.pid != null) return err;
            try self.ensureProcess(b);
            f.pid = b.process.?.pid();
            f.ours = true;
            return b.adapter.fork(a, &b.conv, harness_turn);
        };
    }

    /// The fork is over. A process started for it is told to end, without
    /// waiting; one that crashed is not restarted.
    fn endFork(self: *Host, b: *Binding) void {
        const f = b.fork.?;
        b.fork = null;
        defer self.gpa.free(f.key);
        if (!f.ours) return;
        if (b.process != null) {
            self.terminate(b, "stopped");
            b.fork_ending = true;
        }
        if (b.status == .backoff or b.status == .gave_up) b.status = .idle;
    }

    fn harnessTurn(st: *const eventlog.decider.Agent, turn: []const u8) ![]const u8 {
        for (st.transcript.items) |e| if (e == .turn_started and std.mem.eql(u8, e.turn_started.turn, turn))
            return e.turn_started.harness_turn orelse error.NotFound;
        return error.NotFound;
    }

    // ----------------------------------------------------- reactor turn

    /// One reactor turn: waits up to `timeout_ms` for harness output or
    /// exits, decodes and logs what arrived, reaps exits and restarts due
    /// processes. Never blocks longer than `timeout_ms`.
    pub fn poll(self: *Host, timeout_ms: i32) !void {
        var fds: std.ArrayList(c.pollfd) = .empty;
        defer fds.deinit(self.gpa);
        const timeout = try self.pollSet(self.gpa, &fds, timeout_ms);
        if (fds.items.len > 0 or timeout > 0) _ = c.poll(fds.items.ptr, @intCast(fds.items.len), timeout);
        try self.tick();
    }

    /// Appends the fds the host waits on (harness output, process exits) to
    /// `fds` and returns how long a reactor may wait at most (<= `timeout_ms`)
    /// before calling `tick`: a daemon folds these into its own poll set.
    pub fn pollSet(self: *Host, a: std.mem.Allocator, fds: *std.ArrayList(c.pollfd), timeout_ms: i32) !i32 {
        const now = supervisor.monotonicMs();
        var timeout: i64 = @max(0, timeout_ms);
        for (self.bindings.values()) |b| {
            if (b.process) |*p| {
                if (p.stdout >= 0) try fds.append(a, .{ .fd = p.stdout, .events = c.POLL.IN, .revents = 0 });
                if (p.stderr >= 0) try fds.append(a, .{ .fd = p.stderr, .events = c.POLL.IN, .revents = 0 });
                if (p.leader.pollFd()) |fd| try fds.append(a, .{ .fd = fd, .events = c.POLL.IN, .revents = 0 });
                if (!b.got_session) timeout = @min(timeout, @max(0, b.started_ms + self.options.start_timeout_ms - now));
            } else if (b.status == .backoff) timeout = @min(timeout, @max(0, b.next_ms - now));
        }
        timeout = @min(timeout, self.leaders.timeoutMs(@intCast(timeout)));
        return @intCast(@max(0, timeout));
    }

    /// The non-waiting half of `poll`.
    pub fn tick(self: *Host) !void {
        for (self.bindings.values()) |b| if (b.process != null) try self.drain(b);
        try self.leaders.tick();
        while (self.leaders.nextEvent()) |e| switch (e) {
            .exited => |l| for (self.bindings.values()) |b| {
                if (b.process) |*p| if (p.leader == l) {
                    try self.exited(b);
                    break;
                };
            },
            .done => {},
        };
        const now = supervisor.monotonicMs();
        for (self.bindings.values()) |b| {
            if (self.shut) break;
            if (b.status == .backoff and now >= b.next_ms) {
                b.restarts += 1;
                self.spawn(b) catch |err| {
                    self.warn("harness restart failed", .{ .agent = b.conv.agent, .@"error" = err });
                    self.failed(b, now);
                };
            } else if (b.process != null and b.status == .running and !b.got_session and now - b.started_ms >= self.options.start_timeout_ms) {
                b.timed_out = true;
                self.warn("harness did not start in time", .{ .agent = b.conv.agent, .timeout_ms = self.options.start_timeout_ms });
                _ = self.leaders.terminate(b.process.?.leader, .{ .deadline = self.leaders.now() + self.options.shutdown_grace_ms }) catch {};
            }
        }
    }

    /// Clean shutdown. Idempotent.
    pub fn shutdown(self: *Host) !void {
        if (self.shut) return;
        self.shut = true;
        const grace = self.options.shutdown_grace_ms;
        for (self.bindings.values()) |b| if (b.process != null and b.conv.inTurn() and b.descriptor.caps.interrupt) {
            b.adapter.interrupt(&b.conv) catch {};
        };
        var deadline = supervisor.monotonicMs() + grace;
        while (self.anyTurnRunning() and supervisor.monotonicMs() < deadline) try self.poll(10);
        for (self.bindings.values()) |b| {
            self.terminate(b, "daemon_shutdown");
            if (b.status != .stopping) b.status = .idle;
        }
        deadline = supervisor.monotonicMs() + grace + supervisor.leaders.kill_wait_ms + 1_000;
        while (self.anyProcess() and supervisor.monotonicMs() < deadline) try self.poll(10);
    }

    fn anyTurnRunning(self: *Host) bool {
        for (self.bindings.values()) |b| if (b.process != null and b.conv.inTurn()) return true;
        return false;
    }
    fn anyProcess(self: *Host) bool {
        for (self.bindings.values()) |b| if (b.process != null) return true;
        return false;
    }

    // --------------------------------------------------------- internals

    fn bind(self: *Host, agent: []const u8) !*Binding {
        if (self.bindings.get(agent)) |b| return b;
        const st = self.engine.state.agents.getPtr(agent) orelse return error.NotFound;
        const reg = for (self.adapters) |r| {
            if (std.mem.eql(u8, r.harness, st.harness)) break r;
        } else return error.HarnessNotFound;
        const b = try self.gpa.create(Binding);
        errdefer self.gpa.destroy(b);
        b.* = .{ .host = self, .adapter = reg.adapter, .descriptor = undefined, .conv = undefined };
        try b.conv.init(self.gpa, agent, st.harness, st.cwd orelse st.workspace, .{ .turns = st.turns, .calls = st.calls, .raised = st.raised, .messages = st.messages }, .{ .ptr = self, .emit = emit });
        errdefer b.conv.deinit();
        if (st.harness_session) |s| b.conv.harness_session = try b.conv.life.allocator().dupe(u8, s);
        b.conv.body_max = self.options.body_max;
        b.descriptor = try reg.adapter.probe(b.conv.life.allocator());
        if (!b.descriptor.valid()) return error.UnsupportedHarnessVersion;
        try self.bindings.put(self.gpa, b.conv.agent, b);
        return b;
    }

    fn ensureProcess(self: *Host, b: *Binding) !void {
        if (b.process != null) return;
        if (self.shut) return error.ShuttingDown;
        b.failures = 0;
        try self.spawn(b);
    }

    fn spawn(self: *Host, b: *Binding) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const st = self.engine.state.agents.getPtr(b.conv.agent) orelse return error.NotFound;
        const sa = arena.allocator();
        var spec = try b.adapter.start(sa, .{
            .agent = b.conv.agent,
            .cwd = b.conv.cwd,
            .harness_session = b.conv.harness_session,
            .fork_source = st.fork_source,
            .transcript_ref = st.transcript_ref,
            .model = st.spawn_model,
            .permission_mode = permissionMode(st.mode, b.descriptor.caps.permission_modes),
            .writable = try eventlog.agent_scope.writableOf(sa, st),
            .read_only = try eventlog.agent_scope.readOnlyOf(sa, &self.engine.state, st),
            .mcp_off = st.mcp_off,
        });
        var token: ?[]u8 = null;
        defer if (token) |t| {
            std.crypto.secureZero(u8, t);
            self.gpa.free(t);
        };
        if (self.credentials) |cr| token = try cr.vtable.token(cr.ptr, b.conv.agent);
        spec.env = try credentialEnv(arena.allocator(), spec.env, token);
        b.process = Process.spawn(self.gpa, &self.leaders, spec) catch |err| {
            if (self.credentials) |cr| if (token != null) cr.vtable.release(cr.ptr, b.conv.agent);
            return err;
        };
        if (self.credentials) |cr| if (token != null) cr.vtable.bind(cr.ptr, b.conv.agent, b.process.?.pid());
        b.status = .running;
        // `harness.body_max` is a live key: each process gets the current one.
        b.conv.body_max = self.options.body_max;
        b.started_ms = supervisor.monotonicMs();
        b.got_session = false;
        b.timed_out = false;
        b.conv.channel = b.channel();
        // A handshake the adapter needs before `session`.
        // A failed write means the process is already gone: its exit is reaped.
        if (spec.input) |bytes| b.process.?.write(bytes) catch |err| self.warn("cannot write harness handshake", .{ .agent = b.conv.agent, .@"error" = err });
        self.info("harness started", .{ .agent = b.conv.agent, .harness = b.conv.harness, .pid = b.process.?.pid(), .restarts = b.restarts });
        // The binding is durable before the first byte of output.
        if (spec.harness_session) |s| if (b.conv.harness_session == null) {
            b.conv.harness_session = try b.conv.life.allocator().dupe(u8, s);
            try self.submit(.{ .record = .{ .agent_binding = .{ .agent = b.conv.agent, .harness = b.conv.harness, .harness_session = s, .cwd = b.conv.cwd } } });
        };
    }

    fn terminate(self: *Host, b: *Binding, detail: []const u8) void {
        const p = if (b.process) |*p| p else return;
        b.status = .stopping;
        b.stop_detail = detail;
        p.closeInput();
        _ = self.leaders.terminate(p.leader, .{ .deadline = self.leaders.now() + self.options.shutdown_grace_ms }) catch |err|
            self.warn("cannot terminate harness", .{ .agent = b.conv.agent, .@"error" = err });
    }

    fn drain(self: *Host, b: *Binding) !void {
        const p = &b.process.?;
        _ = p.pump() catch |err| switch (err) {
            error.HarnessProtocol => {
                self.warn("harness line too long; stopping it", .{ .agent = b.conv.agent });
                try self.lost(b, "failed.harness_protocol");
                return;
            },
            else => return err,
        };
        while (b.process) |*live| {
            const line = live.nextLine() orelse break;
            b.adapter.decode(&b.conv, line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A single bad line is logged and skipped.
                else => self.warn("skipped harness line", .{ .agent = b.conv.agent, .@"error" = err }),
            };
        }
    }

    /// The adapter lost track of the turn: fail it and stop the process.
    fn lost(self: *Host, b: *Binding, code: []const u8) !void {
        try b.conv.abandon(code);
        self.terminate(b, code);
    }

    fn exited(self: *Host, b: *Binding) !void {
        var p = &b.process.?;
        // Output written before the exit is still in the pipes.
        while (true) {
            const open = p.pump() catch false;
            while (p.nextLine()) |line| b.adapter.decode(&b.conv, line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => self.warn("skipped harness line", .{ .agent = b.conv.agent, .@"error" = err }),
            };
            if (!open) break;
        }
        const exit: process.Exit = if (p.leader.status) |s| process.exitOf(s) else .{ .code = 255 };
        b.last_exit = exit;
        const expected = b.status == .stopping;
        const tail = try self.gpa.dupe(u8, p.stderrTail());
        defer self.gpa.free(tail);
        self.leaders.release(p.leader) catch {};
        p.deinit();
        b.process = null;
        if (self.credentials) |cr| cr.vtable.release(cr.ptr, b.conv.agent);
        b.conv.channel = null;
        b.fork_ending = false;
        const now = supervisor.monotonicMs();
        if (expected) {
            if (b.conv.inTurn()) try b.conv.turnEnded("interrupted", b.stop_detail);
            b.conv.sending = false;
            b.conv.dropPrompts();
            b.status = .idle;
            if (b.discard) {
                // The next send starts a new conversation: whether this one
                // got far enough to resume is unknown, and none of it is logged.
                b.discard = false;
                b.conv.harness_session = null;
            }
            return;
        }
        const missing = !b.got_session and exit == .code and exit.code == 127;
        const code = if (missing) "unavailable.harness_not_found" else if (b.timed_out) "timeout.harness_start" else "failed.harness_exited";
        b.last_error = code;
        switch (exit) {
            .code => |n| self.warn("harness exited", .{ .agent = b.conv.agent, .code = n, .stderr_tail = tail }),
            .signal => |n| self.warn("harness killed", .{ .agent = b.conv.agent, .signal = n, .stderr_tail = tail }),
        }
        try b.conv.abandon(code);
        if (missing) {
            b.status = .gave_up;
        } else if (exit.ok()) {
            b.status = .idle;
        } else self.failed(b, now);
    }

    /// One more consecutive failure: back off, or give up.
    fn failed(self: *Host, b: *Binding, now: i64) void {
        const policy = self.options.policy;
        if (now - b.started_ms >= policy.reset_after_ms) b.failures = 0;
        b.failures += 1;
        if (policy.max_failures) |max| if (b.failures > max) {
            b.status = .gave_up;
            self.warn("harness failed too often; giving up until the next send", .{ .agent = b.conv.agent, .failures = b.failures });
            return;
        };
        const delay_ms = policy.delay(b.failures);
        b.next_ms = now + delay_ms;
        b.status = .backoff;
        if (self.options.on_backoff) |hook| hook.call(hook.ptr, delay_ms);
    }

    /// The sink: logs a normalized event for `conv`'s agent.
    fn emit(ptr: *anyopaque, conv: *contract.Conversation, event: contract.Normalized) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const agent = conv.agent;
        if (self.bindings.get(agent)) |b| if (b.discard) {
            if (event == .session) b.got_session = true;
            return;
        };
        switch (event) {
            .session => if (self.bindings.get(agent)) |b| {
                b.got_session = true;
                // An ACP agent declares its capabilities only once
                // it runs, and another version can declare others.
                if (b.adapter.probe(conv.life.allocator())) |d| {
                    if (d.valid()) b.descriptor = d;
                } else |err| self.warn("cannot read the harness's capabilities again", .{ .agent = agent, .@"error" = err });
            },
            // Deltas only go to live views: the last
            // bytes are kept for `agent.show` (the live tail).
            .tool_updated => |t| try self.appendTail(agent, t.call, t.body_delta),
            .tool_ended => |t| self.dropTail(agent, t.call),
            else => {},
        }
        const record = recordOf(conv, event) orelse return;
        try self.submit(.{ .record = record });
    }

    /// The live tail of an open tool call of `agent`, if it has output.
    pub fn toolTail(self: *const Host, agent: []const u8, call: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ agent, call }) catch return null;
        const tail = self.tails.getPtr(key) orelse return null;
        return tail.items;
    }

    /// One open call's live output (`agent.show`'s `tails`).
    pub const OpenTail = struct { call: []const u8, tail: []const u8 };

    /// The live tails of `agent`'s open calls, by call id. They change with
    /// no event and no new record, so a refresh reads them here.
    pub fn openTails(self: *const Host, a: std.mem.Allocator, agent: []const u8) ![]const OpenTail {
        var out: std.ArrayList(OpenTail) = .empty;
        var it = self.tails.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (key.len <= agent.len or !std.mem.startsWith(u8, key, agent) or key[agent.len] != '/') continue;
            try out.append(a, .{ .call = key[agent.len + 1 ..], .tail = e.value_ptr.items });
        }
        std.mem.sort(OpenTail, out.items, {}, struct {
            fn less(_: void, l: OpenTail, r: OpenTail) bool {
                return std.mem.lessThan(u8, l.call, r.call);
            }
        }.less);
        return out.items;
    }

    fn appendTail(self: *Host, agent: []const u8, call: []const u8, delta: []const u8) !void {
        const key = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ agent, call });
        const entry = self.tails.getOrPut(self.gpa, key) catch |err| {
            self.gpa.free(key);
            return err;
        };
        if (entry.found_existing) self.gpa.free(key) else entry.value_ptr.* = .empty;
        const tail = entry.value_ptr;
        try tail.appendSlice(self.gpa, delta);
        if (tail.items.len > tail_max) {
            // Keep the end, cut at a UTF-8 boundary.
            var from = tail.items.len - tail_max;
            while (from < tail.items.len and (tail.items[from] & 0xC0) == 0x80) from += 1;
            tail.replaceRangeAssumeCapacity(0, from, &.{});
        }
    }

    fn dropTail(self: *Host, agent: []const u8, call: []const u8) void {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ agent, call }) catch return;
        const kv = self.tails.fetchRemove(key) orelse return;
        self.gpa.free(kv.key);
        var tail = kv.value;
        tail.deinit(self.gpa);
    }

    /// The log record of a harness event; null for what only live views
    /// see (text and tool deltas).
    pub fn recordOf(conv: *const contract.Conversation, event: contract.Normalized) ?eventlog.Event {
        const agent = conv.agent;
        return switch (event) {
            .session => |s| .{ .agent_binding = .{ .agent = agent, .harness = conv.harness, .harness_session = s.harness_session, .cwd = s.cwd orelse conv.cwd, .harness_version = s.harness_version, .model = s.model } },
            .turn_started => |t| .{ .turn_started = .{ .agent = agent, .turn = t.turn, .origin = t.origin, .harness_turn = t.harness_turn } },
            .prompt => |t| .{ .turn_prompt = .{ .agent = agent, .turn = t.turn, .text = t.text } },
            .text => |t| if (t.final) .{ .text = .{ .agent = agent, .turn = t.turn, .message = t.message, .text = t.text } } else null,
            .tool_updated => null,
            .tool_started => |t| .{ .tool_started = .{ .agent = agent, .turn = t.turn, .call = t.call, .kind = t.kind, .name = t.name, .title = t.title, .status = t.status, .parent_call = t.parent_call, .harness_ref = t.harness_ref, .args = t.args, .raw_input = t.raw_input } },
            .tool_ended => |t| .{ .tool_ended = .{ .agent = agent, .turn = t.turn, .call = t.call, .status = t.status, .kind = t.kind, .name = t.name, .title = t.title, .exit = t.exit, .duration_ms = t.duration_ms, .body = t.body } },
            .request => |r| .{ .request = .{ .agent = agent, .request = r.request, .kind = r.kind, .reason = r.reason, .call = r.call, .answers = r.answers, .input_digest = r.input_digest, .outside_scope = r.outside_scope orelse false, .options = r.options } },
            // venom's own answers were resolved in the decider already.
            .request_resolved => |r| if (std.mem.eql(u8, r.by, "venom")) null else .{ .request_resolved = .{ .agent = agent, .request = r.request, .by = r.by } },
            .usage => |u| .{ .usage = .{ .agent = agent, .turn = u.turn, .model = u.model, .tokens_in = u.tokens_in, .tokens_out = u.tokens_out, .cache_read = u.cache_read, .cache_write = u.cache_write, .includes_subagents = u.includes_subagents, .source = u.source } },
            .context => |x| .{ .context = .{ .agent = agent, .used = x.used, .window = x.window, .source = x.source, .system = x.system, .tools = x.tools } },
            .mcp_servers => |m| .{ .mcp_servers = .{ .agent = agent, .servers = m.servers } },
            .plan_windows => |p| .{ .plan_windows = .{ .harness = conv.harness, .account = p.account, .billing = p.billing, .windows = p.windows, .source = p.source } },
            .turn_ended => |t| .{ .turn_ended = .{ .agent = agent, .turn = t.turn, .reason = t.reason, .error_code = t.error_code, .resets_at = t.resets_at } },
        };
    }

    fn submit(self: *Host, cmd: eventlog.Command) !void {
        _ = self.engine.submit(cmd) catch |err| switch (err) {
            error.NotFound, error.Conflict, error.InvalidCommand, error.InvalidTransition => {
                // The harness said something the agent's state rejects: log
                // and skip it rather than lose the rest of the stream.
                self.warn("harness event rejected", .{ .record = @tagName(std.meta.activeTag(cmd.record)), .code = eventlog.decider.errorCode(@errorCast(err)) });
                return;
            },
            else => return err,
        };
    }

    /// The `harness.respond` executor (idempotent per key).
    pub fn run(self: *Host, key: []const u8, payload: []const u8) !eventlog.Executor.Outcome {
        const P = RespondPayload;
        const parsed = try std.json.parseFromSlice(P, self.gpa, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const req = parsed.value;
        if (req.stale and req.@"resume") return self.resumeStale(key, req);
        const b = self.bindings.get(req.agent) orelse return .{ .ok = false, .detail = if (req.stale) "stale" else "failed.harness_exited" };
        if (b.answered.contains(key)) return .{};
        if (req.stale) return .{ .ok = false, .detail = "stale" };
        const pending = b.conv.pending(req.request) orelse return .{ .ok = false, .detail = "conflict.request_resolved" };
        if (b.process == null) return .{ .ok = false, .detail = "failed.harness_exited" };
        b.adapter.respond(&b.conv, pending, .{ .answer = req.decision, .reason = req.reason, .args_json = req.args_json }) catch |err| {
            if (contract.failure(err)) |f| return .{ .ok = false, .detail = f.code };
            return err;
        };
        b.conv.answered(req.request);
        try b.answered.ensureUnusedCapacity(self.gpa, 1);
        b.answered.putAssumeCapacity(try self.gpa.dupe(u8, key), {});
        return .{};
    }

    /// The stale half of `harness.respond`: reattach
    /// and resume. Idempotent per key within a daemon's life; a daemon that
    /// dies before logging the completion runs it again, at worst sending a
    /// failed agent one more resume prompt.
    fn resumeStale(self: *Host, key: []const u8, req: RespondPayload) !eventlog.Executor.Outcome {
        const b = self.bind(req.agent) catch |err| switch (err) {
            error.NotFound => return .{ .ok = false, .detail = "not_found.agent" },
            error.HarnessNotFound => return .{ .ok = false, .detail = "unavailable.harness_not_found" },
            else => return err,
        };
        if (b.answered.contains(key)) return .{};
        const st = self.engine.state.agents.getPtr(req.agent) orelse return .{ .ok = false, .detail = "not_found.agent" };
        var detail: []const u8 = "";
        if (st.open_turn != null or b.conv.inTurn() or b.conv.sending) {
            // That turn is the next one: the decision applies to it, and
            // the model hears the reason even if it does not ask again.
            detail = "in_turn";
            if (try saidNo(self.gpa, req)) |note| {
                defer self.gpa.free(note);
                if (!self.tellRunningTurn(b, req.agent, note)) detail = "in_turn_undelivered";
            }
        } else {
            const note = try saidNo(self.gpa, req);
            defer if (note) |n| self.gpa.free(n);
            const prompt = if (note) |n| try std.fmt.allocPrint(self.gpa, "{s}\n\n{s}", .{ self.options.resume_prompt, n }) else try self.gpa.dupe(u8, self.options.resume_prompt);
            defer self.gpa.free(prompt);
            // A reattach is checked like a queued start: the answer
            // is asked for off the reactor, and the effect stays pending
            // (`Retry`) until it lands.
            if (self.startsProcess(req.agent)) if (self.start_gate) |g| switch (g.check(g.ctx, req.agent)) {
                .go => {},
                .wait => return error.Retry,
                .signed_out => {
                    try self.failStart(req.agent, prompt, "unavailable.harness_not_signed_in");
                    return .{ .ok = false, .detail = "unavailable.harness_not_signed_in" };
                },
            };
            self.send(req.agent, prompt, .turn) catch |err| {
                if (contract.failure(err)) |f| return .{ .ok = false, .detail = f.code };
                return err;
            };
        }
        try b.answered.ensureUnusedCapacity(self.gpa, 1);
        b.answered.putAssumeCapacity(try self.gpa.dupe(u8, key), {});
        return .{ .detail = detail };
    }

    /// Sends `note` to a running turn: a steer where the harness takes one, a
    /// queued message where it queues. False when it cannot be delivered.
    fn tellRunningTurn(self: *Host, b: *Binding, agent: []const u8, note: []const u8) bool {
        if (b.process == null) return false;
        const mode: contract.SendMode = switch (b.descriptor.caps.steer) {
            .inject => .steer,
            .queue => .turn,
            .none => return false,
        };
        self.send(agent, note, mode) catch |err| {
            self.warn("cannot tell the running turn why a stale request was refused", .{ .agent = agent, .@"error" = err });
            return false;
        };
        return true;
    }

    /// The `harness.stop` executor (idempotent per key).
    pub fn runStop(self: *Host, key: []const u8, payload: []const u8) !eventlog.Executor.Outcome {
        const P = struct { agent: []const u8, turn: ?[]const u8 = null };
        const parsed = try std.json.parseFromSlice(P, self.gpa, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const req = parsed.value;
        const st = self.engine.state.agents.getPtr(req.agent) orelse return .{ .ok = false, .detail = "not_found.agent" };
        const stop_turn = req.turn orelse {
            // No turn yet: the agent has settled; end the process coming up.
            const b = self.bindings.get(req.agent) orelse return .{ .detail = "no_process" };
            if (b.process == null) return .{ .detail = "no_process" };
            b.discard = true;
            self.terminate(b, "stopped");
            return .{};
        };
        const open = st.open_turn orelse return .{ .detail = "turn_ended" };
        if (!std.mem.eql(u8, open, stop_turn)) return .{ .detail = "turn_ended" };
        const b = self.bindings.get(req.agent);
        if (b == null or b.?.process == null or !b.?.conv.inTurn()) {
            // Nothing runs this turn any more: end it here, so it settles.
            try self.submit(.{ .record = .{ .turn_ended = .{ .agent = req.agent, .turn = stop_turn, .reason = "interrupted" } } });
            return .{ .detail = "no_process" };
        }
        const bind_ = b.?;
        if (bind_.answered.contains(key)) return .{};
        // `cancel_turn` where the harness still waits (it ends the turn).
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const waiting = try arena.allocator().dupe(contract.Pending, bind_.conv.open_requests.items);
        var cancelled = false;
        for (waiting) |p| {
            bind_.adapter.respond(&bind_.conv, p, .{ .answer = "cancel_turn" }) catch |err| {
                self.warn("cannot cancel a request on stop", .{ .agent = req.agent, .request = p.request, .@"error" = err });
                continue;
            };
            bind_.conv.answered(p.request);
            cancelled = true;
        }
        if (!cancelled) {
            if (bind_.descriptor.caps.interrupt) {
                bind_.adapter.interrupt(&bind_.conv) catch |err| {
                    self.warn("interrupt failed; stopping the harness", .{ .agent = req.agent, .@"error" = err });
                    self.terminate(bind_, "stopped");
                };
            } else self.terminate(bind_, "stopped");
        }
        try bind_.answered.ensureUnusedCapacity(self.gpa, 1);
        bind_.answered.putAssumeCapacity(try self.gpa.dupe(u8, key), {});
        return .{};
    }

    /// The `harness.takeback` executor (idempotent per key).
    pub fn runTakeback(self: *Host, key: []const u8, payload: []const u8) !eventlog.Executor.Outcome {
        const P = struct { agent: []const u8, since: ?i64 = null };
        const parsed = try std.json.parseFromSlice(P, self.gpa, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const id = parsed.value.agent;
        const b = self.bind(id) catch |err| switch (err) {
            error.NotFound => return .{ .ok = false, .detail = "not_found.agent" },
            error.HarnessNotFound => return .{ .ok = false, .detail = "unavailable.harness_not_found" },
            else => return err,
        };
        if (b.answered.contains(key)) return .{};
        var detail: []const u8 = "no_catch_up";
        // A take-over pane that outlived the daemon is gone now; the
        // process it replaced exited before the hand-over.
        if (b.descriptor.caps.catch_up != .none and !b.conv.inTurn() and b.process == null) if (b.conv.harness_session) |session| {
            // The imported turns are logged through the conversation's sink,
            // with venom's ids, like turns the protocol process ran.
            _ = b.adapter.catchUp(&b.conv, .{ .harness = b.conv.harness, .harness_session = session, .fork_source = self.engine.state.agents.getPtr(id).?.fork_source, .cwd = b.conv.cwd, .last_turn = lastTurn(self.engine.state.agents.getPtr(id).?), .harness_last_turn = lastHarnessTurn(self.engine.state.agents.getPtr(id).?), .transcript_ref = self.engine.state.agents.getPtr(id).?.transcript_ref, .since_ms = parsed.value.since }) catch |err| {
                // An unstarted fork whose take-over never made the copy has
                // nothing to import, and that is not a failure.
                // `fork_source` stays: the next start makes the copy.
                if (err == error.NoConversation) {
                    try b.answered.ensureUnusedCapacity(self.gpa, 1);
                    b.answered.putAssumeCapacity(try self.gpa.dupe(u8, key), {});
                    return .{ .detail = "" };
                }
                // A turn cut off mid-import still ends, so the agent settles.
                if (b.conv.inTurn()) b.conv.turnEnded("interrupted", "failed.harness_catch_up") catch {};
                if (contract.failure(err)) |f| return .{ .ok = false, .detail = f.code };
                if (err == error.OutOfMemory) return err;
                self.warn("catch-up failed", .{ .agent = id, .@"error" = err });
                return .{ .ok = false, .detail = "failed.harness_catch_up" };
            };
            detail = "";
            // The transcript was there: if the take-over's command forked an
            // unstarted fork, the copy exists now and `fork_source` has done
            // its job. Without it (the pane never ran) the next start forks
            // again.
            const st = self.engine.state.agents.getPtr(id).?;
            if (st.fork_source != null) try self.submit(.{ .record = .{ .agent_binding = .{ .agent = id, .harness = b.conv.harness, .harness_session = session, .cwd = b.conv.cwd } } });
        };
        try b.answered.ensureUnusedCapacity(self.gpa, 1);
        b.answered.putAssumeCapacity(try self.gpa.dupe(u8, key), {});
        return .{ .detail = detail };
    }

    fn lastTurn(agent: *const eventlog.decider.Agent) ?[]const u8 {
        var i = agent.transcript.items.len;
        while (i > 0) {
            i -= 1;
            if (agent.transcript.items[i] == .turn_started) return agent.transcript.items[i].turn_started.turn;
        }
        return null;
    }

    /// The harness's id of the latest turn that has one (a turn that never
    /// started in the harness has none). A catch-up turn the daemon's
    /// restart cut off does not count: the next catch-up imports it whole.
    fn lastHarnessTurn(agent: *const eventlog.decider.Agent) ?[]const u8 {
        var known: ?[]const u8 = null;
        var cut: ?struct { turn: []const u8, before: ?[]const u8 } = null;
        for (agent.transcript.items) |e| switch (e) {
            .turn_started => |t| if (t.harness_turn) |h| {
                cut = if (std.mem.eql(u8, t.origin, "catch_up")) .{ .turn = t.turn, .before = known } else null;
                known = h;
            },
            .turn_ended => |t| if (cut) |pend| if (std.mem.eql(u8, pend.turn, t.turn)) {
                if (t.error_code) |code| if (std.mem.eql(u8, code, "failed.daemon_restart")) {
                    known = pend.before;
                };
                cut = null;
            },
            else => {},
        };
        return known;
    }

    fn warn(self: *Host, msg: []const u8, fields: anytype) void {
        if (self.options.logger) |l| l.warn(msg, fields);
    }
    fn info(self: *Host, msg: []const u8, fields: anytype) void {
        if (self.options.logger) |l| l.info(msg, fields);
    }
};

const RespondPayload = struct {
    agent: []const u8,
    request: []const u8,
    decision: []const u8,
    reason: ?[]const u8 = null,
    args_json: ?[]const u8 = null,
    stale: bool = false,
    @"resume": bool = false,
    stale_request: ?struct { reason: []const u8 = "" } = null,
};

/// Why a deny or a reject said no, if it said: the model must not simply ask
/// for the same thing again. Gpa-owned.
fn saidNo(gpa: std.mem.Allocator, req: RespondPayload) !?[]u8 {
    const reason = req.reason orelse return null;
    const asked = if (req.stale_request) |r| r.reason else "";
    if (std.mem.eql(u8, req.decision, "deny")) return try std.fmt.allocPrint(gpa, "This request was denied: {s}\nReason: {s}", .{ asked, reason });
    if (std.mem.eql(u8, req.decision, "reject")) return try std.fmt.allocPrint(gpa, "This plan was rejected: {s}\nFeedback: {s}", .{ asked, reason });
    return null;
}

const EffectKind = enum { stop, takeback, fork };

/// One outbox executor bound to the host (the engine dispatches by kind).
fn Effect(comptime kind: EffectKind) type {
    return struct {
        host: *Host = undefined,
        pub fn run(self: *@This(), key: []const u8, payload: []const u8) !eventlog.Executor.Outcome {
            return switch (kind) {
                .stop => self.host.runStop(key, payload),
                .takeback => self.host.runTakeback(key, payload),
                .fork => self.host.runFork(key, payload),
            };
        }
    };
}

test "tool tails: the end of the output, per call, until the call ends" {
    const ta = std.testing.allocator;
    var h = Host.init(ta, undefined, &.{}, .{});
    defer h.leaders.deinit();
    defer h.tails.deinit(ta);
    try h.appendTail("a1", "c1", "one\n");
    try h.appendTail("a1", "c1", "two\n");
    try h.appendTail("a2", "c1", "other\n");
    try std.testing.expectEqualStrings("one\ntwo\n", h.toolTail("a1", "c1").?);
    try std.testing.expect(h.toolTail("a1", "c9") == null);
    // By agent; `a1` is not `a10`.
    try h.appendTail("a10", "c2", "not mine\n");
    var open_arena: std.heap.ArenaAllocator = .init(ta);
    defer open_arena.deinit();
    const open = try h.openTails(open_arena.allocator(), "a1");
    try std.testing.expectEqual(@as(usize, 1), open.len);
    try std.testing.expectEqualStrings("c1", open[0].call);
    try std.testing.expectEqualStrings("one\ntwo\n", open[0].tail);
    h.dropTail("a10", "c2");
    // Only the end is kept, cut at a UTF-8 boundary.
    for (0..4000) |_| try h.appendTail("a1", "c1", "é");
    const tail = h.toolTail("a1", "c1").?;
    try std.testing.expect(tail.len <= Host.tail_max and tail.len > Host.tail_max - 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail));
    h.dropTail("a1", "c1");
    h.dropTail("a2", "c1");
    try std.testing.expect(h.toolTail("a1", "c1") == null);
}
