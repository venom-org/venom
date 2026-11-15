//! venom: the orchestrator daemon and its CLI in one binary.
//! The verb schema in `verbs.zon` plus venom-std's shared bundles (config,
//! events, grants, skill, doctor) generates the CLI, the MCP server
//! (`venom mcp`), the docs and the completions.
const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const cfg = @import("cfg");
const log = @import("log");
const supervisor = @import("supervisor");
const xdg = @import("xdg");
const Workspaces = @import("workspaces.zig").Workspaces;
const eventlog = @import("eventlog/root.zig");
const scope = @import("scope.zig");
const harnesses = @import("harnesses.zig");
const harness = @import("harness/root.zig");
const Principals = @import("principals.zig").Principals;
const tui = @import("tui/root.zig");
const escalation = @import("escalation.zig");
const permission_server = @import("permission_server.zig");
const agent_hook = @import("agent_hook.zig");
const lifecycle = @import("lifecycle.zig");
const Holds = @import("holds.zig").Holds;

pub const tool = "venom";

/// Typed config keys and their checks live in config.zig.
const ConfigStore = @import("config.zig").Store;
const validateConfig = @import("config.zig").validate;

pub const input = @import("verbs.zon");
const manifest = .{ .format = input.format, .tool = input.tool, .summary = input.summary, .verbs = input.verbs ++ .{eventlog.catalog.events_manifest} };
/// `scope.extend` adds `--workspace` / `--repo` to `config get|set`.
/// `agent view` (bare `venom`) is the TUI, a local command;
/// `agent permission-server` is Claude Code's permission prompt server;
/// `agent hook` is what its hooks run while handed over.
pub const App = cli.WithBootstrap(scope.extend(cfg.merge(cli.manifest.normalize(manifest))), cli.manifest.examples(manifest), .{ .local = tui.local_commands ++ permission_server.local_commands ++ agent_hook.local_commands, .serve_params = serve_params });

/// What `doctor` says with no daemon: agents never start venom, so the fix
/// only rechecks, and the message tells a human what to do.
pub const no_daemon: cli.runtime.NoDaemon = .{ .fix = "venom doctor --json", .message = "No daemon at the selected socket; a human runs `venom` in a terminal outside venomx; agents never start it" };

/// `serve`'s own parameters: who decides the daemon's lifetime. A bare
/// `venom` starts `serve --lifetime on-demand --origin interactive`.
pub const serve_params = .{ .{
    .name = "lifetime",
    .summary = "persistent (default) runs until a signal; on-demand stops 5 s after the last venom TUI quits, or 5 s after start if none holds it",
    .type = .{ .kind = .string, .choices = .{ "persistent", "on-demand" } },
    .default = "persistent",
}, .{
    .name = "origin",
    .summary = "Who started the daemon, set by the TUI's launcher; shown by doctor and tui.hold, never grants anything",
    .type = .{ .kind = .string, .choices = .{ "serve", "interactive" } },
    .default = "serve",
} };

/// The local commands' handler: the TUI, the permission prompt server and
/// the hook command.
pub const Locals = struct {
    view: *tui.Command,
    pub const commands = tui.Command.commands ++ .{ "agent.permission_server", "agent.hook" };
    pub fn call(self: *Locals, ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        if (std.mem.eql(u8, ctx.name, "agent.permission_server")) return permission_server.serve(self.view.gpa, ctx);
        if (std.mem.eql(u8, ctx.name, "agent.hook")) return agent_hook.serve(self.view.gpa, ctx);
        return self.view.call(ctx);
    }
};

/// The local handler for in-process `App.run` calls that never open the
/// TUI (tests): `App.run` requires one for the local commands.
var headless_view: tui.Command = .{ .gpa = std.heap.page_allocator, .io = undefined };
var headless_locals: Locals = .{ .view = &headless_view };
pub fn noView() @TypeOf(cli.Local.init(&headless_locals)) {
    return cli.Local.init(&headless_locals);
}

/// The agent verbs.
pub const Agents = @import("agents.zig").Agents;
/// The usage verbs.
pub const Usage = @import("usage.zig").Usage;
/// The context panel's verbs.
pub const ContextVerbs = @import("context.zig").Verbs;
/// The inbox verbs.
pub const Inbox = @import("inbox.zig").Inbox;

/// Product doctor check: persisted configuration validity.
const ConfigCheck = struct {
    config: *ConfigStore,
    pub fn run(self: *ConfigCheck, r: *cli.doctor.Report) anyerror!void {
        const fix = try r.command("{s} config check --json", r.tool);
        self.config.check() catch |err| {
            if (err == error.OutOfMemory) return err;
            const code = if (err == error.InvalidConfig) self.config.failure.code else @errorName(err);
            return r.add("config.valid", .fail, try r.print("configuration is invalid: {s} (key '{s}')", .{ code, self.config.failure.key() }), fix);
        };
        try r.add("config.valid", .ok, "configuration is valid", fix);
    }
};

/// Product doctor check: the latched lifetime and origin, the restart-only
/// startup settings (active against persisted) and the lifetime state.
pub const LifecycleCheck = struct {
    holds: *const Holds,
    config: *ConfigStore,
    /// The `daemon` settings this daemon started with.
    active: lifecycle.Settings,
    pub fn run(self: *LifecycleCheck, r: *cli.doctor.Report) anyerror!void {
        const fix = try r.command("{s} doctor --json", r.tool);
        const config_fix = try r.command("{s} config check --json", r.tool);
        const st = &self.holds.state;
        try r.add("daemon.lifetime", .ok, if (st.lifetime == .on_demand) try r.print("on-demand (latched from serve --lifetime; stops {d} ms after its last TUI quits)", .{lifecycle.wait_ms}) else "persistent (latched from serve --lifetime; TUIs coming and going never stop it)", fix);
        try r.add("daemon.origin", .ok, try r.print("origin {s} (serve --origin)", .{@tagName(st.origin)}), fix);
        const persisted_start = self.config.get(r.arena, "daemon.interactive_start") catch |err| if (err == error.OutOfMemory) return err else "invalid";
        const persisted_budget = self.config.get(r.arena, "daemon.startup_timeout_ms") catch |err| if (err == error.OutOfMemory) return err else "invalid";
        const active_start = if (self.active.interactive_start) "true" else "false";
        const active_budget = try r.print("{d}", .{self.active.startup_timeout_ms});
        const start_pending = !std.mem.eql(u8, std.mem.trim(u8, persisted_start, " \n"), active_start);
        try r.add("daemon.interactive_start", if (start_pending) .warn else .ok, try r.print("active {s}; persisted {s}{s}", .{ active_start, persisted_start, if (start_pending) "; restart required to apply" else "" }), config_fix);
        const budget_pending = !std.mem.eql(u8, std.mem.trim(u8, persisted_budget, " \n"), active_budget);
        try r.add("daemon.startup_deadline", if (budget_pending) .warn else .ok, try r.print("TUI startup budget {s} ms; persisted {s}{s}", .{ active_budget, persisted_budget, if (budget_pending) "; restart required to apply" else "" }), config_fix);
        const now = supervisor.monotonicMs();
        const clients = self.holds.count();
        const consistent = st.consistent(clients, now);
        const remaining = st.remainingMs(now);
        const message = switch (st.phase) {
            .awaiting_first_client => try r.print("state awaiting_first_client; {d} TUI clients; first-client grace remaining {d} ms", .{ clients, remaining }),
            .lingering => try r.print("state lingering; {d} TUI clients; linger remaining {d} ms", .{ clients, remaining }),
            else => try r.print("state {s}; {d} TUI clients", .{ st.phaseName(), clients }),
        };
        try r.add("daemon.lifecycle", if (consistent) .ok else .fail, message, fix);
    }
};

/// Product doctor check: event log retention and watermarks.
const EventsCheck = struct {
    events: *proto.events.Log,
    engine: *eventlog.Engine,
    pub fn run(self: *EventsCheck, r: *cli.doctor.Report) anyerror!void {
        const st = self.events.status();
        try r.add("events.log", .ok, try r.print("event log {s} retains seq {d}..{d} ({d} of {d} bytes)", .{ st.source, st.low, st.high, st.bytes, st.limits.bytes }), try r.command("{s} events --follow=false --json", r.tool));
        try r.add("events.durable", .ok, try r.print("durable log has {d} commits, {d} pending effects; snapshot commit {d}, log {d} bytes, replay {d} ms", .{ self.engine.store.commits, self.engine.state.pendingEffects(), self.engine.store.snapshot_commit, self.engine.store.size, self.engine.store.replay_ms }), try r.command("{s} doctor --json", r.tool));
    }
};

/// The hand-written part of `venom skill`.
pub const skill_notes =
    \\venom orchestrates existing coding agents (Claude Code, Codex, opencode,
    \\ACP agents); it never runs its own agent harness. Words: a workspace is a
    \\folder added to venom, holding 0..n repos (git roots found inside it); an
    \\agent is one run of a harness on a task, with turns; venom gives each agent
    \\its own worktree per repo. Agents, hooks and MCP never start venom: with no
    \\daemon running every call returns `unavailable.not_running`, and only a
    \\human starts it, by running `venom` in a terminal outside venomx. A daemon
    \\started that way is on-demand: it stops, and with it every running turn,
    \\your own included, shortly after the human quits the last venom TUI. Every verb
    \\is read-only unless a grant allows more; use named flags and `--json`.
    \\Add a folder with `venom workspace add --path=<abs>`; venom finds its repos
    \\(git roots, up to 4 levels down) and `venom workspace scan` finds them
    \\again. `venom agent spawn --cwd=<abs> --task=<text> [--harness=<h>]`
    \\starts an agent in place in that folder (`agents.default` picks the
    \\harness); `agent list|show` read them, `agent send --agent=<id>
    \\--text=<prompt>` starts the next turn, `agent stop` interrupts a running
    \\turn (the agent settles) and `agent archive` hides it, keeping its
    \\transcript. Watch `venom events --json` for `agent.state_changed`.
    \\`venom usage show --group=agent|workspace|harness --range=today|7d|30d`
    \\sums tokens, turns, tool calls and wall time (`usage export` as CSV).
    \\`venom agent context --agent=<id>` shows what fills its window and what its
    \\harness can do about it: `agent compact`, `agent fork [--task=<text>]`
    \\(returns a key at once; `agent.fork_ended` on events, or `forks` on `agent
    \\show`, says how it ended and names the new sub-agent) and `agent mcp-off`.
    \\`venom inbox list` shows what needs a human (approvals, questions, plans,
    \\failures, limits, then unread results), `inbox answer --agent=<id>
    \\--answer=<a>` answers a request and `inbox snooze` hides an item for 15m;
    \\`agent.attention` events report new items. Approvals take allow_once,
    \\allow_always (keeps the item's narrowest `grant`, e.g. exec:zig, for the
    \\workspace: later matching approvals are allowed without asking),
    \\allow_edited with `--args`, deny (with `--reason`) or cancel_turn;
    \\`inbox batch` answers marked approvals that share one grant;
    \\`always list|revoke` shows and drops kept grants.
    \\`venom harness list` shows each harness (found, version, signed in,
    \\protocol reachable) and `harness show --harness=<h>` one of them; `venom
    \\doctor` reports the same with a fix to run. venom never handles vendor
    \\credentials: sign in with the harness's own command, the `fix` it gives.
    \\Agents venom starts (claude-code, codex, an ACP agent) get venom's MCP server for
    \\their run, as server `venom`: each verb is a tool (`agent.spawn` is
    \\`agent_dspawn`, `agent.list` is `agent_dlist`), and calls run as that
    \\agent, with its own token (`VENOM_TOKEN`): by default an agent reads
    \\every agent and changes only itself and its sub-agents; spawning one
    \\needs a `spawn` grant on the workspace (the spawn's `grants`).
    \\claude-code agents also get server `venom-permissions` (`venom agent
    \\permission-server`), their `--permission-prompt-tool`: their approvals,
    \\questions and plans wait in `venom inbox` until answered. While
    \\claude-code or codex has an agent in its own TUI (`venom agent takeover`),
    \\its hooks (codex: `notify`, at each turn's end) run `venom agent hook`,
    \\which raises attention in the inbox; only a process inside the take-over
    \\split is accepted, so whoever runs the command reports it with `venom
    \\agent takeover-split` (for a venomx pane, venomx must confirm the
    \\process). Install
    \\this skill with `venom skill install --target=claude-code|codex`.
    \\An agent that calls `agent.spawn` makes a sub-agent: its own worktree,
    \\its parent's scope, harness, model, permission mode and grants unless
    \\narrowed, never more (`denied.delegation`, `denied.spawn_mode`,
    \\`denied.spawn_model`, `denied.spawn_isolation`). `agents.spawn.allow`
    \\and `agents.spawn.depth` (the top-level agent is depth 1) limit the
    \\tree (`denied.spawn_disabled`, `denied.spawn_depth`). At most
    \\`agents.max_concurrent` agents run at once; a spawn beyond that waits
    \\as `queued`, its task held, oldest first (a send to a settled agent is
    \\not held back). `agent wait [--agent=<id>] [--timeout-s=<n>]` returns
    \\once every agent below it has finished, `agent stop --tree=true` stops
    \\an agent and all below it, `agent promote --agent=<id>` makes a
    \\sub-agent top-level (people only). `agent list` reports `parent`, `issue`,
    \\`children_needs_you` and `children_failed` (all levels below). A prompt
    \\to a sub-agent from anyone but its parent is shown to the parent:
    \\`child_prompts` in `agent show`, and an `agent.child_prompted` event.
    \\A token an agent issues is still that agent for all of this. A parent
    \\that is stopping or has no turn running cannot spawn
    \\(`conflict.parent_stopped`), a child stays in its parent's scope
    \\(`denied.spawn_scope`) and on another harness runs in a mode it can
    \\enforce, codex children read-only (`denied.spawn_harness` if none).
    \\Only a person can allow or approve: an agent's `inbox answer` may deny,
    \\reject, cancel or answer a question (`denied.agent_approval` otherwise).
    \\Its side effects are its
    \\socket, status file, audit and daemon logs, its durable event log
    \\(events.log in its XDG state directory; it also keeps the workspaces),
    \\ZON configuration (change it
    \\with `venom config set`; `--workspace=<path>` or `--repo=<path>` reads or
    \\writes that folder's `.venom/workspace.zon` or `.venom/repo.zon`, the
    \\narrowest file winning per key) and installed skills. With a venomx daemon
    \\reachable and `ui.chrome` not `.own`, it posts a venomx notification for a
    \\blocking inbox item unanswered for `attention.notify_after`, and dismisses
    \\it once answered. It never starts venomx.
;

fn samePolicy(a: proto.grants.Policy, b: proto.grants.Policy) bool {
    if (a.max_token_ttl != b.max_token_ttl) return false;
    for ([_][]const proto.grants.Grant{ a.unknown, a.interactive }, [_][]const proto.grants.Grant{ b.unknown, b.interactive }) |left, right| {
        if (left.len != right.len) return false;
        for (left, right) |l, r| if (l.right != r.right or !std.mem.eql(u8, l.scope, r.scope)) return false;
    }
    return true;
}

/// The serving loop, run as a supervised thread: a failed poll is restarted
/// with backoff instead of taking the daemon down. Each turn waits on the
/// socket and the harness host's fds together, then services
/// both, the config watcher and the effect worker.
pub const ServeLoop = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *proto.Server,
    dispatcher: *proto.Dispatcher,
    events: *proto.events.Log,
    config: *ConfigStore,
    registry: *proto.grants.Registry,
    logger: *log.Logger,
    engine: *eventlog.Engine,
    harnesses: *harnesses.Runner,
    /// The agent verbs: the queue and the open `agent.wait` calls. Null: no
    /// agent verbs in this loop.
    agents: ?*Agents = null,
    /// `notify.post` for blocking items left unanswered; null in
    /// tests that have no venomx to talk to.
    escalation: ?*escalation.Escalation = null,
    /// The TUI holds and the daemon's lifetime. Null: always persistent.
    holds: ?*Holds = null,
    /// The combined poll set, reused across turns.
    fds: std.ArrayList(std.c.pollfd) = .empty,

    pub fn deinit(self: *ServeLoop) void {
        self.fds.deinit(self.gpa);
    }

    pub fn run(self: *ServeLoop, stop: *const supervisor.Stop) anyerror!void {
        // Initialization is complete: the first-client grace of an
        // on-demand daemon starts here.
        if (self.holds) |h| h.ready();
        while (!stop.requested() and !self.stopping()) try self.step(100);
        // On this thread: the harness processes it started get a
        // parent-death signal when it ends, so they are stopped cleanly first.
        try self.shutdown();
    }

    /// The clean shutdown, however the daemon got to stopping. Idempotent.
    /// A signal stops an on-demand daemon too: holds end with
    /// `unavailable.shutdown`, nothing starts from here on, connections are
    /// no longer accepted (a TUI starting meanwhile finds the lock held and
    /// waits), then running turns are interrupted and every harness reaped.
    fn shutdown(self: *ServeLoop) !void {
        if (self.holds) |h| try h.stop();
        self.harnesses.host.halted = true;
        self.dispatcher.cancelAll();
        self.server.shutdown();
        self.harnesses.host.shutdown() catch |err| {
            if (err == error.OutOfMemory) return err;
            self.logger.warn("harness shutdown failed", .{ .@"error" = err });
        };
        try self.events.tick();
    }

    /// The lifetime ended (the linger or the first-client grace ran out).
    pub fn stopping(self: *const ServeLoop) bool {
        const h = self.holds orelse return false;
        return h.state.stopping();
    }

    /// One reactor turn; waits at most `timeout_ms`.
    pub fn step(self: *ServeLoop, timeout_ms: i32) !void {
        try self.wait(timeout_ms);
        // Stopping committed in this turn: nothing more starts. The
        // shutdown in `serve` does the rest.
        if (self.stopping()) return;
        try self.harnesses.host.tick();
        // `harness.list|show` waiting for a discovery run.
        try self.harnesses.discovery.tick();
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
        self.config.watch(now_ms) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Report only the refinement code; never dump a secret value.
            self.logger.warn("config watcher: reload failed", .{ .code = self.config.failure.code });
        };
        const current = self.config.current();
        if (!samePolicy(self.registry.policy, current.grants)) try self.registry.setPolicy(current.grants);
        self.logger.setConfig(current.log);
        self.harnesses.configure(current.harness);
        // Settled agents are archived after agents.archive_after.
        _ = try self.engine.sweep(@import("config.zig").Duration.parseMs(current.agents.archive_after) catch std.math.maxInt(u64));
        // An unanswered approval is denied after attention.approval_timeout.
        if (current.attention.approval_timeout) |t| _ = try self.engine.expireApprovals(@import("config.zig").Duration.parseMs(t) catch std.math.maxInt(u64));
        // Queued agents start as slots free up; open waits end.
        if (self.agents) |ag| try ag.tick();
        // `harness.respond` effects go to the host's executor.
        _ = try self.engine.runEffects();
        // Escalation outside the terminal, after attention.notify_after.
        if (self.escalation) |e| {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const after = @import("config.zig").Duration.parseMs(current.attention.notify_after) catch std.math.maxInt(u64);
            try e.reconcile(try escalation.openItems(arena.allocator(), &self.engine.state, self.engine.options.clock.now(), after), current.ui.chrome != .own);
            try e.pump();
        }
        try self.events.tick();
    }

    /// Waits until a client or a harness process has something, or the
    /// host's next deadline (start timeout, restart backoff, kill
    /// escalation), then lets the server service its peers. The server
    /// keeps its own poll set, so with no harness work it simply polls.
    fn wait(self: *ServeLoop, timeout_ms: i32) !void {
        self.fds.clearRetainingCapacity();
        var timeout = try self.harnesses.host.pollSet(self.gpa, &self.fds, timeout_ms);
        if (self.fds.items.len == 0 and timeout == timeout_ms) return self.server.poll(timeout_ms);
        if (timeout > 0) {
            try self.fds.append(self.gpa, .{ .fd = self.server.fd, .events = std.c.POLL.IN, .revents = 0 });
            for (self.server.connections.items) |conn| {
                // Output to flush or buffered requests: the server has work now.
                if (conn.output.items.len > 0 or conn.consumed > 0) {
                    timeout = 0;
                    break;
                }
                if (!conn.closing) try self.fds.append(self.gpa, .{ .fd = conn.fd, .events = std.c.POLL.IN, .revents = 0 });
            }
            if (timeout > 0) _ = std.c.poll(self.fds.items.ptr, @intCast(self.fds.items.len), timeout);
        }
        try self.server.poll(0);
    }

    /// Runs the loop under the supervisor until `stopped` (set by the
    /// SIGTERM/SIGINT handler), then shuts down in order: cancel streaming
    /// calls, end harness processes (which still logs
    /// through the engine), then close the socket after flushing clients.
    pub fn serve(self: *ServeLoop, stopped: *const std.atomic.Value(bool), status_path: []const u8) !void {
        {
            // Called on the main thread, which forks nothing while this runs:
            // only orphans are its children then, so the reactor's leaders and
            // every `std.process.run` keep their statuses. A failed
            // serve thread ends the reaping until the next start: its restart
            // leaves zombies rather than risk a harness's status.
            var sup = supervisor.Supervisor.init(self.gpa, .{ .status_path = status_path, .logger = self.logger, .reap_orphans = true });
            defer sup.deinit();
            try sup.addThread("serve", supervisor.Task.init(self), .{});
            // The serve thread's own shutdown takes a harness grace and the
            // cleanup allowance.
            sup.run(stopped, .{ .grace_ms = self.harnesses.host.options.shutdown_grace_ms + lifecycle.cleanup_allowance_ms + 1000 });
        }
        // Done on the serve thread unless it failed.
        try self.shutdown();
        while (self.server.connections.items.len != 0) try self.server.poll(100);
    }
};

const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    stopped: *const std.atomic.Value(bool),
    pub fn serve(self: *Daemon, path: proto.SocketOptions, params: std.json.Value) anyerror!void {
        harness.process.ignoreSigpipe();
        const lifetime = lifecycle.Lifetime.parse(if (params.object.get("lifetime")) |v| v.string else "persistent");
        const origin = lifecycle.Origin.parse(if (params.object.get("origin")) |v| v.string else "serve");
        // Records go to $XDG_STATE_HOME/venom/venom/venom.log; stderr only
        // shows warnings and errors unless the `log` config says otherwise.
        var logger = log.Logger.init(.{ .source = tool, .stderr = self.stderr, .file = self.openLog() });
        defer logger.deinit();
        var events = try proto.events.Log.init(self.gpa, tool, .{}, null);
        defer events.deinit();
        const config_path = try cfg.configPath(self.gpa, tool, self.environ);
        defer self.gpa.free(config_path);
        const defaults_paths = try cfg.defaultsPaths(self.gpa, tool, self.environ);
        defer cfg.freePaths(self.gpa, defaults_paths);
        var config = try ConfigStore.init(self.gpa, .{ .io = self.io, .path = config_path, .defaults = defaults_paths, .validate = validateConfig, .events = &events });
        defer config.deinit();
        events.catalog = &eventlog.catalog.entries;
        // Opened once the server holds the socket lock (below), so a second
        // `serve` on the same socket still fails with its conflict.
        var engine: eventlog.Engine = undefined;
        logger.setConfig(config.current().log);
        var registry = try proto.grants.Registry.init(self.gpa, tool, config.current().grants);
        defer registry.deinit();
        // The TUI holds, and the lifetime they drive.
        var holds: Holds = .{ .gpa = self.gpa, .registry = &registry, .state = .{ .lifetime = lifetime, .origin = origin } };
        defer holds.deinit();

        // Durable through the event log; usable once `engine` is open.
        var workspaces: Workspaces = .{ .engine = &engine, .io = self.io };
        var workspace_add = workspaces.adder();
        var workspace_remove = workspaces.remover();
        var workspace_scan = workspaces.scanner();
        var workspaces_check = workspaces.check();
        // User → workspace → repo config files.
        var scoped_config: scope.Config = .{ .store = &config, .engine = &engine, .layers = .{ .gpa = self.gpa, .io = self.io, .user = config_path, .defaults = defaults_paths, .events = &events } };

        // The harness host, set up once the engine is open.
        var runner: harnesses.Runner = undefined;
        // Grants for venom's resources, and a principal per agent.
        var principals: Principals = .{ .gpa = self.gpa, .registry = &registry, .engine = &engine, .logger = &logger };
        defer principals.deinit();
        principals.install();
        var agents: Agents = .{ .environ = self.environ, .engine = &engine, .host = &runner.host, .io = self.io, .config = &config, .layers = &scoped_config.layers, .principals = &principals, .discovery = &runner.discovery };
        defer agents.deinit();
        var usage: Usage = .{ .engine = &engine };
        var context_verbs: ContextVerbs = .{ .agents = &agents };
        var inbox: Inbox = .{ .engine = &engine, .principals = &principals };
        var harness_verbs: harnesses.Verbs = .{ .runner = &runner };

        var events_check: EventsCheck = .{ .events = &events, .engine = &engine };
        var config_check: ConfigCheck = .{ .config = &config };
        var harness_check: harnesses.ExtraArgsCheck = .{ .config = &config };
        var approvals_check: harnesses.ApprovalsCheck = .{ .runner = &runner };
        var server_check: cli.doctor.ServerCheck = .{ .server = undefined };
        var leader_check: tui.host.LeaderCheck = .{ .config = &config, .ctx = &self.environ };
        var isolation_check: tui.host.IsolationCheck = .{ .ctx = &self.environ };
        var lifecycle_check: LifecycleCheck = .{ .holds = &holds, .config = &config, .active = config.current().daemon };
        const checks = [_]cli.doctor.Check{ .init("daemon", &lifecycle_check), .init("config", &config_check), .init("keys", &leader_check), .init("venomx", &isolation_check), .init("runtime", &server_check), .init("events", &events_check), .init("workspaces", &workspaces_check), .init("harness", &harness_check), .init("approvals", &approvals_check) };
        // The schema digest: advertised in hello and compared by doctor.
        const digest = try App.digest(self.gpa);
        var standard: cli.Standard(App) = .init(.{ .notes = skill_notes, .home = self.environ.getPosix("HOME"), .checks = &checks, .schema = &digest });
        // `doctor` waits for the harness probes off the reactor, so it
        // is venom's own, not `standard`'s.
        var doctor: harnesses.DoctorVerb = .{ .runner = &runner, .tool = tool, .checks = &checks, .schema = &digest };
        const standard_bindings = standard.bindings();
        const handlers = [_]proto.Binding{
            .{ .verb = "workspace.add", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &workspace_add) },
            .{ .verb = "workspace.list", .handler = proto.VerbHandler.init(&workspaces) },
            .{ .verb = "workspace.remove", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &workspace_remove) },
            .{ .verb = "workspace.scan", .handler = proto.VerbHandler.typed(Workspaces.ScanParams, &workspace_scan) },
            .{ .verb = "events", .handler = proto.VerbHandler.init(&events) },
            .{ .verb = "tui.hold", .handler = proto.VerbHandler.init(&holds) },
        } ++ agents.bindings() ++ usage.bindings() ++ context_verbs.bindings() ++ inbox.bindings() ++ harness_verbs.bindings() ++ scoped_config.bindings() ++ doctor.bindings() ++ standard_bindings[1..3].*;
        // While stopping, mutations fail `unavailable.shutdown`.
        var gated: [handlers.len]@import("holds.zig").Gated = undefined;
        const gated_handlers = @import("holds.zig").gate(handlers.len, handlers, &holds, &gated);
        var dispatcher = try proto.Dispatcher.init(self.gpa, &App.schema, &gated_handlers, .{}, null);
        defer dispatcher.deinit();
        var front: @import("holds.zig").Front = .{ .dispatcher = &dispatcher, .holds = &holds };
        var server = try proto.Server.init(self.gpa, .{
            .hello = .{ .identity = .{ .name = tool, .version = "0.0.0" }, .caps = &.{"cancel"}, .schema = &digest },
            .path = path,
            .registry = &registry,
            // A process that double-forks out
            // of an agent lands here, not at pid 1, and other daemons see it
            // is below venom. `ServeLoop.serve`'s supervisor reaps those orphans.
            .subreaper = true,
        }, front.handler());
        defer server.deinit();
        server_check.server = &server;
        // The durable log: rebuilt on start, then the start is logged.
        const log_path = try xdg.path(self.gpa, .state, tool, eventlog.file_name, .{ .environ = self.environ, .uid = std.c.getuid() });
        defer self.gpa.free(log_path);
        engine = try eventlog.Engine.open(self.gpa, log_path, .{ .events = &events });
        defer engine.deinit();
        if (engine.store.truncated != 0) logger.warn("event log: cut a torn last commit", .{ .bytes = engine.store.truncated });
        // The harness host: answers `harness.respond` effects
        // and is shut down before the engine closes (defers run in reverse).
        // venom's MCP server for claude-code and codex agents:
        // this binary, reaching this daemon's socket. Without a resolvable
        // executable the agents run without it.
        const self_exe: ?[:0]u8 = std.process.executablePathAlloc(self.io, self.gpa) catch |err| blk: {
            logger.warn("cannot resolve venom's executable; agents get no venom MCP server", .{ .@"error" = err });
            break :blk null;
        };
        defer if (self_exe) |p| self.gpa.free(p);
        const agent_mcp: ?harness.mcp.Server = if (self_exe) |p| .{ .command = p, .socket = server.path } else null;
        // Claude Code's permission prompts come back through
        // `harness.permission_prompt`; `agents.bindings()` ran above.
        try runner.initWith(self.gpa, &engine, config.current().harness, &.{}, &logger, agent_mcp, agents.replier());
        defer runner.deinit();
        runner.discovery.path_env = self.environ.getPosix("PATH");
        // Where Claude Code keeps session transcripts, for take-back's
        // catch-up: `CLAUDE_CONFIG_DIR`, else `~/.claude`.
        if (runner.claude_code) |*cc| {
            cc.logger = &logger;
            if (self.environ.getPosix("CLAUDE_CONFIG_DIR")) |d| {
                cc.config_dir = try cc.life.allocator().dupe(u8, d);
            } else if (self.environ.getPosix("HOME")) |h| {
                cc.config_dir = try std.fmt.allocPrint(cc.life.allocator(), "{s}/.claude", .{h});
            }
        }
        if (runner.codex) |*cx| cx.logger = &logger;
        runner.host.credentials = principals.credentials();
        // From the turn that commits stopping, nothing starts.
        holds.on_stopping = .{ .ctx = &runner.host, .run = struct {
            fn run(ctx: *anyopaque) void {
                const h: *harness.host.Host = @ptrCast(@alignCast(ctx));
                h.halted = true;
            }
        }.run };
        engine.options.executors = runner.executors();
        // A take-over's venomx pane outlives this daemon.
        // An agent stays handed over unless its pane is known to be gone.
        var live_panes: std.ArrayList([]const u8) = .empty;
        defer live_panes.deinit(self.gpa);
        for (engine.state.agents.keys(), engine.state.agents.values()) |id, agent| {
            if (agent.state != .handed_over) continue;
            const pane = agent.pane orelse continue;
            if (eventlog.agent.clientPanePid(pane) != null) continue;
            switch (@import("takeover_pane.zig").check(self.gpa, self.environ, id, pane)) {
                .gone => continue,
                .running => {},
                .unknown => |why| logger.warn("take-over pane unknown; agent stays handed over", .{ .agent = id, .pane = pane, .why = why }),
            }
            try live_panes.append(self.gpa, pane);
        }
        try engine.startWith(live_panes.items);
        const snapshot_parts = [_]proto.events.Snapshot{proto.events.Snapshot.init(&config)};
        var snapshots: eventlog.catalog.Snapshots = .{ .engine = &engine, .others = &snapshot_parts };
        events.snapshot = proto.events.Snapshot.init(&snapshots);
        logger.info("listening", .{ .socket = server.path, .pid = std.c.getpid() });
        // The status file sits next to the socket, so it follows --socket.
        const status_path = try xdg.siblingPath(self.gpa, server.path, "status.json");
        defer self.gpa.free(status_path);
        var escalator: escalation.Escalation = undefined;
        try escalator.init(self.gpa, self.environ, &logger);
        defer escalator.deinit();
        var loop: ServeLoop = .{ .gpa = self.gpa, .io = self.io, .server = &server, .dispatcher = &dispatcher, .events = &events, .config = &config, .registry = &registry, .logger = &logger, .engine = &engine, .harnesses = &runner, .agents = &agents, .escalation = &escalator, .holds = &holds };
        defer loop.deinit();
        try loop.serve(self.stopped, status_path);
        logger.info("stopped", .{});
    }
    fn openLog(self: *Daemon) ?std.c.fd_t {
        const file = xdg.path(self.gpa, .state, tool, tool ++ ".log", .{ .environ = self.environ, .uid = std.c.getuid() }) catch return null;
        defer self.gpa.free(file);
        return log.openFile(self.gpa, file) catch null;
    }
};

pub fn main(init: std.process.Init) !void {
    const stopped = supervisor.installSignalHandlers();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    var daemon: Daemon = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface, .stopped = stopped };
    var view: tui.Command = .{ .gpa = init.gpa, .io = init.io, .environ_map = init.environ_map, .stopped = stopped };
    var locals: Locals = .{ .view = &view };
    const status = try App.run(init.gpa, try tui.rewriteArgs(init.arena.allocator(), argv[1..]), .{
        .stdout = &out.interface,
        .stderr = &err.interface,
        .environ = init.minimal.environ,
        .bootstrap = cli.Bootstrap.initWithParams(&daemon),
        .local = cli.Local.init(&locals),
        .interrupted = stopped,
        .no_daemon = no_daemon,
    });
    // An on-demand daemon whose TUI already quit has nobody reading its
    // termination record: exit at once rather than return the error.
    out.interface.flush() catch std.process.exit(if (status != 0) status else 1);
    err.interface.flush() catch {};
    if (status != 0) std.process.exit(status);
}

test {
    _ = @import("workspaces.zig");
    _ = @import("config.zig");
    _ = @import("scope.zig");
    _ = @import("scope_tests.zig");
    _ = @import("tests.zig");
    _ = @import("eventlog/root.zig");
    _ = @import("harness/root.zig");
    _ = @import("harness/tests.zig");
    _ = @import("harnesses.zig");
    _ = @import("serve_tests.zig");
    _ = @import("agents.zig");
    _ = @import("agent_verbs_tests.zig");
    _ = @import("subagent_tests.zig");
    _ = @import("principals.zig");
    _ = @import("grants_tests.zig");
    _ = @import("usage.zig");
    _ = @import("usage_tests.zig");
    _ = @import("context.zig");
    _ = @import("context_tests.zig");
    _ = @import("inbox.zig");
    _ = @import("inbox_tests.zig");
    _ = @import("escalation.zig");
    _ = @import("escalation_venomx_tests.zig");
    _ = @import("tui/root.zig");
    _ = @import("approvals_tests.zig");
    _ = @import("mcp_tests.zig");
    _ = @import("permission_server.zig");
    _ = @import("agent_hook.zig");
    _ = @import("permissions.zig");
    _ = @import("permission_tests.zig");
    _ = @import("takeover_tests.zig");
    _ = @import("takeover_pane.zig");
    _ = @import("agent_scope_tests.zig");
    _ = @import("isolation.zig");
    _ = @import("isolation_tests.zig");
    _ = @import("harness_verbs_tests.zig");
    _ = @import("cleanup.zig");
    _ = @import("cleanup_tests.zig");
    _ = @import("safe_git.zig");
    _ = @import("safe_git_tests.zig");
    _ = @import("lifecycle.zig");
    _ = @import("holds_tests.zig");
}
