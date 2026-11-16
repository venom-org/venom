//! The daemon's harness host: which adapters `venom serve`
//! registers, how the `harness.*` config keys
//! map onto `harness.host.Options`, the reactor hooks the serve
//! loop calls, and the `doctor` check for `harness.<h>.extra_args`.
//!
//! `harness.<h>.enabled|path|extra_args` are read once, when the host is
//! built (they are restart keys in config.zig). `shutdown_grace`,
//! `start_timeout`, `body_max` and `resume_prompt` apply live through
//! `configure`. Everything runs on the reactor thread, like the engine.
//!
//! The vendor adapters run `<harness> --version` once, on a thread of their
//! own started here, so the reactor never waits for it: `probe`
//! reports null until it lands.
//!
//! `Discovery` answers `doctor`'s `harness.<h>.found|version|
//! signed_in|protocol` and `harness.list|show`: it asks each enabled harness
//! on threads of its own (`harness/discovery.zig`). `harness.list|show` wait
//! for it without blocking the reactor, and so does `doctor` (`DoctorVerb`):
//! venom-std's checks are synchronous, so venom binds its own
//! `doctor` that runs the other checks at once and adds this one's results
//! from `Discovery.tick`.
//! `agent.spawn` asks it for the sign-in state alone, on a thread too
//! (`askSignIn`), and holds its call meanwhile.
const std = @import("std");
const cli = @import("cli");
const log = @import("log");
const proto = @import("proto");
const config = @import("config.zig");
const eventlog = @import("eventlog/root.zig");
const harness = @import("harness/root.zig");
const Host = harness.Host;
const Registered = harness.host.Registered;
const discovery = harness.discovery;

/// The harnesses venom ships an adapter for, by config id. `name` is the
/// harness id agents carry; `flags` are the flags the
/// adapter itself passes, which `extra_args` must not repeat. Each
/// adapter adds its entry and flags here.
/// `resume_tui` mirrors the adapter's `probe` capability:
/// the TUI offers "Take over in <harness>" only for these;
/// a test keeps the two in step.
pub const Known = struct { id: config.Harness, name: []const u8, flags: []const []const u8, resume_tui: bool = false };
pub const known = [_]Known{
    .{ .id = .claude_code, .name = harness.claude_code.name, .flags = &harness.claude_code.flags, .resume_tui = true },
    // codex runs `codex app-server` with no flags of its own (cwd, approval
    // policy and sandbox go through `thread/start`), so `extra_args` such as
    // `-c key=value` follow `app-server` unchecked.
    .{ .id = .codex, .name = harness.codex.name, .flags = &.{}, .resume_tui = true },
};

/// Whether the harness named `name` provides a take-over command.
pub fn resumesTui(name: []const u8) bool {
    for (known) |k| if (std.mem.eql(u8, k.name, name)) return k.resume_tui;
    return false;
}

/// `harness.*` onto the host's options. Values were checked by
/// `config.validate`; the fallbacks only guard a hand-built `Harnesses`.
pub fn hostOptions(h: config.Harnesses, logger: ?*log.Logger) harness.host.Options {
    return .{
        .shutdown_grace_ms = durationMs(h.shutdown_grace, 5_000),
        .start_timeout_ms = durationMs(h.start_timeout, 30_000),
        .resume_prompt = h.resume_prompt,
        .body_max = h.body_max,
        .logger = logger,
    };
}

fn durationMs(text: []const u8, fallback: u32) u32 {
    const ms = config.Duration.parseMs(text) catch return fallback;
    return std.math.cast(u32, ms) orelse fallback;
}

/// The first argument of `extra` that repeats one of the adapter's own
/// `flags`, as `--flag` or `--flag=value`.
pub fn repeatedFlag(extra: []const []const u8, flags: []const []const u8) ?[]const u8 {
    for (extra) |arg| {
        const name = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[0..eq] else arg;
        for (flags) |f| if (std.mem.eql(u8, name, f)) return arg;
    }
    return null;
}

/// For tests: `harness.*` with both vendor harnesses off, as
/// ZON for a test's `config.zon` and as settings for a hand-built
/// `Runner`. Every test daemon and `Runner` starts from these; the guard
/// in `Runner.init` fails a test that does not.
pub const test_vendors_off = ".harness = .{ .claude_code = .{ .enabled = false }, .codex = .{ .enabled = false } }";
pub const test_settings: config.Harnesses = .{ .claude_code = .{ .enabled = false }, .codex = .{ .enabled = false } };

/// A test `config.zon`: the vendor harnesses off, then `rest` (more
/// fields, or empty).
pub fn testConfig(comptime rest: []const u8) []const u8 {
    return if (rest.len == 0) ".{ " ++ test_vendors_off ++ " }" else ".{ " ++ test_vendors_off ++ ", " ++ rest ++ " }";
}

/// How long `<harness> --version` may take.
pub const version_timeout_ms: u32 = harness.version.default_timeout_ms;

/// The host as the daemon runs it.
pub const Runner = struct {
    host: Host,
    /// What the host was given; it borrows this slice, so it never grows
    /// after `init`.
    registered: std.ArrayList(Registered) = .empty,
    gpa: std.mem.Allocator,
    /// The claude-code adapter, when enabled. The runner must not
    /// move after `init`: `registered` points at it.
    claude_code: ?harness.ClaudeCode = null,
    /// The codex adapter, when enabled; same rule.
    codex: ?harness.Codex = null,
    /// The ACP agent, when `harness.acp` is on. It is not in
    /// `known`: it has no vendor to discover, so `harness.list`, `doctor` and
    /// the new-agent dialog don't show it yet.
    acp: ?harness.Acp = null,
    /// A copy of venom's MCP server for agents, which both
    /// adapters borrow.
    mcp: ?harness.mcp.Server = null,
    mcp_arena: ?std.heap.ArenaAllocator = null,
    /// What `doctor` and `harness.list|show` report.
    discovery: Discovery = undefined,
    /// `provider.list`'s sign-in checks.
    providers: ProviderList = undefined,

    /// Registers the enabled harnesses that have an adapter in this build,
    /// plus `extra` (tests register the fake harness this way). `engine`
    /// may still be unopened: the host only keeps the pointer, and the
    /// engine must outlive the runner.
    pub fn init(self: *Runner, gpa: std.mem.Allocator, engine: *eventlog.Engine, settings: config.Harnesses, extra: []const Registered, logger: ?*log.Logger) !void {
        return self.initWith(gpa, engine, settings, extra, logger, null, null);
    }

    /// `init`, and `mcp` is the MCP server the claude-code and codex
    /// agents get for their runs (the daemon passes its own
    /// executable and socket). It is copied. With `mcp`, `replier` gives
    /// claude-code agents the permission prompt server and its
    /// `--permission-prompt-tool`: their approvals, questions and
    /// plans reach venom's inbox.
    pub fn initWith(self: *Runner, gpa: std.mem.Allocator, engine: *eventlog.Engine, settings: config.Harnesses, extra: []const Registered, logger: ?*log.Logger, mcp: ?harness.mcp.Server, replier: ?harness.claude_code.Replier) !void {
        self.* = .{ .gpa = gpa, .host = undefined };
        errdefer self.registered.deinit(gpa);
        errdefer if (self.mcp_arena) |*m| m.deinit();
        if (mcp) |m| {
            self.mcp_arena = .init(gpa);
            const a = self.mcp_arena.?.allocator();
            const args = try a.alloc([]const u8, m.args.len);
            for (args, m.args) |*d, arg| d.* = try a.dupe(u8, arg);
            self.mcp = .{ .command = try a.dupe(u8, m.command), .args = args, .socket = if (m.socket) |s| try a.dupe(u8, s) else null };
        }
        errdefer if (self.claude_code) |*cc| cc.deinit();
        errdefer if (self.codex) |*cx| cx.deinit();
        errdefer if (self.acp) |*x| x.deinit();
        for (known) |k| {
            const e = settings.entry(k.id);
            if (!e.enabled) continue;
            // Tests never register a real claude or codex: start
            // from `testConfig`, or point `path` at a fake in the temp dir.
            switch (k.id) {
                .claude_code => try harness.guard.check(harness.guard.claude, e.path orelse "claude"),
                .codex => try harness.guard.check(harness.guard.codex, e.path orelse "codex"),
            }
            switch (k.id) {
                .claude_code => {
                    // venom's MCP server for the agent and, with
                    // a replier, the permission prompt server.
                    // Without either, probe declares no requests and
                    // Claude Code runs without venom's approvals.
                    self.claude_code = try .init(gpa, .{ .exe = e.path orelse "claude", .extra_args = e.extra_args, .mcp = self.mcp, .replier = if (self.mcp != null) replier else null });
                    try self.registered.append(gpa, .{ .harness = k.name, .adapter = self.claude_code.?.adapter() });
                },
                .codex => {
                    self.codex = try .initCommand(gpa, e.path orelse "codex", e.extra_args);
                    self.codex.?.mcp = self.mcp;
                    try self.registered.append(gpa, .{ .harness = k.name, .adapter = self.codex.?.adapter() });
                },
            }
        }
        // `path` is checked by `config.validate`.
        if (settings.acp.enabled) if (settings.acp.path) |exe| {
            self.acp = try .initCommand(gpa, exe, settings.acp.extra_args);
            self.acp.?.mcp = self.mcp;
            try self.registered.append(gpa, .{ .harness = harness.acp.name, .adapter = self.acp.?.adapter() });
        };
        try self.registered.appendSlice(gpa, extra);
        self.host = Host.init(gpa, engine, self.registered.items, hostOptions(settings, logger));
        self.discovery = try .init(gpa, settings, if (self.claude_code) |*cc| cc.exe else null, if (self.codex) |*cx| cx.argv else null);
        self.providers = .{ .gpa = gpa, .discovery = &self.discovery };
        // In place now: the detectors point into `self`.
        if (self.claude_code) |*cc| cc.startVersionDetect(version_timeout_ms);
        if (self.codex) |*cx| cx.startVersionDetect(version_timeout_ms);
    }

    /// Shuts the host down if `shutdown` did not run, then frees it. No
    /// harness process outlives this.
    pub fn deinit(self: *Runner) void {
        self.providers.deinit();
        self.discovery.deinit();
        self.host.deinit();
        if (self.claude_code) |*cc| cc.deinit();
        if (self.codex) |*cx| cx.deinit();
        if (self.acp) |*x| x.deinit();
        self.registered.deinit(self.gpa);
        if (self.mcp_arena) |*m| m.deinit();
    }

    /// The engine's executors (`harness.respond`).
    pub fn executors(self: *Runner) []const eventlog.Executor {
        return self.host.executor();
    }

    /// Applies the live `harness.*` keys.
    pub fn configure(self: *Runner, settings: config.Harnesses) void {
        const logger = self.host.options.logger;
        const policy = self.host.options.policy;
        self.host.options = hostOptions(settings, logger);
        self.host.options.policy = policy;
    }
};

/// `doctor`: `harness.<h>.extra_args` must not repeat an adapter flag.
/// A repeat is a warning: the harness
/// may still accept it, but the adapter's value is no longer the only one.
pub const ExtraArgsCheck = struct {
    config: *config.Store,
    known: []const Known = &known,
    pub fn run(self: *ExtraArgsCheck, r: *cli.doctor.Report) anyerror!void {
        const settings = self.config.current().harness;
        for (self.known) |k| {
            const id = try r.print("harness.{s}.extra_args", .{@tagName(k.id)});
            const fix = try r.print("{s} config get --key=harness.{s}.extra_args --json", .{ r.tool, @tagName(k.id) });
            const e = settings.entry(k.id);
            if (repeatedFlag(e.extra_args, k.flags)) |arg| {
                try r.add(id, .warn, try r.print("harness.{s}.extra_args repeats the adapter's own flag '{s}'; remove it", .{ @tagName(k.id), arg }), fix);
            } else {
                try r.add(id, .ok, try r.print("{d} extra arguments for {s}", .{ e.extra_args.len, k.name }), fix);
            }
        }
    }
};

/// `doctor`: `harness.claude-code.approvals`.
/// ok when claude-code agents get venom's permission prompt
/// server and `--permission-prompt-tool`, so their approvals, questions and
/// plans reach the inbox; `warn` when claude-code is enabled without it
/// (its agents then run with Claude Code's own print-mode rule: anything
/// that would prompt is denied). Read-only: it starts nothing.
pub const ApprovalsCheck = struct {
    runner: *Runner,
    pub fn run(self: *ApprovalsCheck, r: *cli.doctor.Report) anyerror!void {
        const id = "harness.claude-code.approvals";
        const fix = try r.command("{s} doctor --json", r.tool);
        const cc = if (self.runner.claude_code) |*x| x else return r.add(id, .ok, "claude-code is disabled", fix);
        const m = cc.mcp orelse return r.add(id, .warn, "claude-code agents get no venom MCP server (venom's executable could not be resolved), so nothing can answer their permission prompts", fix);
        if (cc.replier == null) return r.add(id, .warn, "claude-code agents get no permission prompt tool, so nothing can answer their permission prompts", fix);
        try r.add(id, .ok, try r.print("claude-code approvals reach the inbox: --permission-prompt-tool {s} ({s} {s} {s})", .{ harness.claude_code.prompt_tool, m.command, harness.mcp.permissions_args[0], harness.mcp.permissions_args[1] }), fix);
    }
};

/// Asks each harness what `doctor` and `harness.list|show` report. One run
/// at a time, on one thread per enabled harness; callers that arrive during a
/// run share it. Everything but the worker threads runs on the reactor
/// thread. Must not move once a run started.
pub const Discovery = struct {
    pub const Target = struct {
        known: Known,
        vendor: discovery.Vendor,
        enabled: bool,
        /// `harness.<h>.path`, else the vendor's executable name.
        exe: []const u8,
        /// `app-server` and `extra_args` for codex.
        protocol_args: []const []const u8,
    };

    const Slot = struct {
        facts: discovery.Facts = .{},
        arena: std.heap.ArenaAllocator,
        thread: ?std.Thread = null,
    };

    /// One sign-in question from `agent.spawn`. `answer` is read once `done`.
    const SignInRun = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        answer: discovery.SignIn = .{},
    };

    /// A `harness.list` (no `only`), `harness.show` or `doctor` waiting for
    /// the run.
    const Waiter = struct { ticket: proto.Ticket, only: ?usize, doctor: ?*DoctorRun = null };

    gpa: std.mem.Allocator,
    /// The `PATH` to search, the daemon's own; null: this process's.
    path_env: ?[]const u8 = null,
    /// Holds `targets`' strings.
    life: std.heap.ArenaAllocator,
    targets: [known.len]Target,
    slots: [known.len]Slot,
    sign_ins: [known.len]SignInRun = @splat(.{}),
    running: bool = false,
    remaining: std.atomic.Value(usize) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    waiting: std.ArrayList(Waiter) = .empty,
    dispatcher: ?*proto.Dispatcher = null,
    command_timeout_ms: u32 = discovery.command_timeout_ms,
    budget_ms: u32 = discovery.budget_ms,

    /// `claude_exe` and `codex_argv` are the adapters' own, when enabled.
    pub fn init(gpa: std.mem.Allocator, settings: config.Harnesses, claude_exe: ?[]const u8, codex_argv: ?[]const []const u8) !Discovery {
        var self: Discovery = .{ .gpa = gpa, .life = .init(gpa), .targets = undefined, .slots = undefined };
        errdefer self.life.deinit();
        const a = self.life.allocator();
        for (known, &self.targets, &self.slots) |k, *t, *slot| {
            slot.* = .{ .arena = .init(gpa) };
            const e = settings.entry(k.id);
            const vendor = switch (k.id) {
                .claude_code => discovery.claude,
                .codex => discovery.codex,
            };
            t.* = .{ .known = k, .vendor = vendor, .enabled = e.enabled, .exe = try a.dupe(u8, e.path orelse vendor.exe), .protocol_args = &.{} };
            switch (k.id) {
                .claude_code => if (claude_exe) |exe| {
                    t.exe = exe;
                },
                .codex => if (codex_argv) |argv| if (argv.len > 0) {
                    t.exe = argv[0];
                    t.protocol_args = argv[1..];
                },
            }
        }
        return self;
    }

    pub fn deinit(self: *Discovery) void {
        self.cancel.store(true, .release);
        self.join();
        for (&self.sign_ins) |*run| if (run.thread) |thread| thread.join();
        self.waiting.deinit(self.gpa);
        for (&self.slots) |*slot| slot.arena.deinit();
        self.life.deinit();
    }

    /// Starts a run unless one is going.
    pub fn start(self: *Discovery) void {
        if (self.running) return;
        self.running = true;
        var enabled: usize = 0;
        for (self.targets) |t| {
            if (t.enabled) enabled += 1;
        }
        self.remaining.store(enabled, .release);
        for (&self.targets, &self.slots) |*t, *slot| {
            _ = slot.arena.reset(.retain_capacity);
            slot.facts = .{};
            if (!t.enabled) {
                // Off: whether it is there, with nothing run.
                slot.facts.path = discovery.resolve(slot.arena.allocator(), t.exe, self.pathEnv()) catch null;
                continue;
            }
            slot.thread = std.Thread.spawn(.{}, work, .{ self, t, slot }) catch blk: {
                _ = self.remaining.fetchSub(1, .acq_rel);
                break :blk null;
            };
        }
    }

    pub fn pathEnv(self: *const Discovery) ?[]const u8 {
        if (self.path_env) |p| return p;
        return if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else null;
    }

    fn work(self: *Discovery, t: *const Target, slot: *Slot) void {
        defer _ = self.remaining.fetchSub(1, .acq_rel);
        slot.facts = discovery.discover(self.gpa, slot.arena.allocator(), t.vendor, .{
            .exe = t.exe,
            .protocol_args = t.protocol_args,
            .path_env = self.pathEnv(),
            .command_timeout_ms = self.command_timeout_ms,
            .budget_ms = self.budget_ms,
            .cancel = &self.cancel,
        }) catch .{};
    }

    /// Waits for the run. `facts` is then the run's until the next `start`.
    pub fn join(self: *Discovery) void {
        for (&self.slots) |*slot| if (slot.thread) |thread| {
            thread.join();
            slot.thread = null;
        };
        self.running = false;
    }

    /// The target whose sign-in `agent.spawn` must check for harness `name`:
    /// an enabled vendor harness. Null for anything else, such as the fake.
    pub fn signInTarget(self: *const Discovery, name: []const u8) ?usize {
        for (self.targets, 0..) |t, i| {
            if (t.enabled and std.mem.eql(u8, t.known.name, name)) return i;
        }
        return null;
    }

    /// Asks target `i` for its sign-in state on a thread of its own, unless a
    /// question is still going: callers that arrive meanwhile share it. An
    /// answer nobody took is stale, so it is dropped and asked again.
    pub fn askSignIn(self: *Discovery, i: usize) void {
        const run = &self.sign_ins[i];
        if (run.thread) |thread| {
            if (!run.done.load(.acquire)) return;
            thread.join();
            run.thread = null;
        }
        run.done.store(false, .release);
        run.answer = .{};
        run.thread = std.Thread.spawn(.{}, workSignIn, .{ self, i }) catch {
            // Not asked: "could not tell", which does not refuse the spawn.
            run.done.store(true, .release);
            return;
        };
    }

    fn workSignIn(self: *Discovery, i: usize) void {
        const run = &self.sign_ins[i];
        defer run.done.store(true, .release);
        const t = &self.targets[i];
        run.answer = discovery.signIn(self.gpa, t.vendor, .{
            .exe = t.exe,
            .path_env = self.pathEnv(),
            .command_timeout_ms = self.command_timeout_ms,
            .cancel = &self.cancel,
        }) catch .{};
    }

    /// The answer of target `i`'s finished question, once; null while there
    /// is none. Never waits: the thread has ended or is about to.
    pub fn takeSignIn(self: *Discovery, i: usize) ?discovery.SignIn {
        const run = &self.sign_ins[i];
        if (!run.done.load(.acquire)) return null;
        if (run.thread) |thread| thread.join();
        run.thread = null;
        run.done.store(false, .release);
        return run.answer;
    }

    /// The command that signs target `i` in: the harness's own.
    pub fn signInFix(self: *const Discovery, a: std.mem.Allocator, i: usize) ![]const u8 {
        const t = self.targets[i];
        return ownCommand(a, t.exe, t.vendor.sign_in);
    }

    /// The reactor's turn: answers the waiting calls once a run ended.
    pub fn tick(self: *Discovery) !void {
        if (self.waiting.items.len == 0) return;
        if (self.running) {
            if (self.remaining.load(.acquire) != 0) return;
            self.join();
        }
        const d = self.dispatcher orelse return;
        for (self.waiting.items) |w| {
            // Gone: cancelled, or its client went away.
            const c = d.get(w.ticket) orelse continue;
            const a = c.arena();
            if (w.doctor) |run| {
                run.verb.finish(c, &run.report) catch |err| if (err == error.OutOfMemory) return err;
            } else if (w.only) |i| {
                c.ok(try self.detail(a, i)) catch |err| if (err == error.OutOfMemory) return err;
            } else {
                var entries: [known.len]Entry = undefined;
                for (&entries, 0..) |*e, i| e.* = try self.entry(a, i);
                c.ok(.{ .harnesses = entries[0..] }) catch |err| if (err == error.OutOfMemory) return err;
            }
        }
        self.waiting.clearRetainingCapacity();
    }

    fn enqueue(self: *Discovery, c: *proto.Call, only: ?usize) !void {
        self.dispatcher = c.dispatcher;
        try self.waiting.append(self.gpa, .{ .ticket = c.ticket, .only = only });
        self.start();
    }

    fn enqueueDoctor(self: *Discovery, c: *proto.Call, run: *DoctorRun) !void {
        self.dispatcher = c.dispatcher;
        try self.waiting.append(self.gpa, .{ .ticket = c.ticket, .only = null, .doctor = run });
        self.start();
    }

    /// One harness in `harness.list`. Absent (null) means not known: it is
    /// off, not found, or did not answer.
    pub const Entry = struct {
        harness: []const u8,
        enabled: bool,
        found: bool,
        path: ?[]const u8 = null,
        version: ?[]const u8 = null,
        signed_in: ?bool = null,
        /// A plan or method word, never an identity.
        sign_in_detail: ?[]const u8 = null,
        protocol: ?bool = null,
        /// The command to run next: install, or the harness's own sign-in.
        fix: ?[]const u8 = null,
    };

    /// `harness.show`: an `Entry` and the adapter's versions.
    pub const Detail = struct {
        harness: []const u8,
        enabled: bool,
        found: bool,
        path: ?[]const u8 = null,
        version: ?[]const u8 = null,
        signed_in: ?bool = null,
        sign_in_detail: ?[]const u8 = null,
        protocol: ?bool = null,
        protocol_problem: ?[]const u8 = null,
        fix: ?[]const u8 = null,
        min_version: ?[]const u8 = null,
        tested_version: []const u8,
    };

    fn entry(self: *Discovery, a: std.mem.Allocator, i: usize) !Entry {
        const t = self.targets[i];
        const f = self.slots[i].facts;
        return .{
            .harness = t.known.name,
            .enabled = t.enabled,
            .found = f.found(),
            .path = if (f.path) |p| try a.dupe(u8, p) else null,
            .version = if (f.version == .found) try a.dupe(u8, f.version.found) else null,
            .signed_in = f.sign_in.signed_in,
            .sign_in_detail = f.sign_in.detail,
            .protocol = switch (f.protocol) {
                .not_checked => null,
                .ok => true,
                .failed => false,
            },
            .fix = if (!f.found())
                t.vendor.install
            else if (t.enabled and f.sign_in.signed_in == false)
                try ownCommand(a, t.exe, t.vendor.sign_in)
            else
                null,
        };
    }

    fn detail(self: *Discovery, a: std.mem.Allocator, i: usize) !Detail {
        const e = try self.entry(a, i);
        const f = self.slots[i].facts;
        const minimum: ?[]const u8, const tested: []const u8 = switch (self.targets[i].known.id) {
            .claude_code => .{ harness.claude_code.min_version, harness.claude_code.tested_version },
            .codex => .{ harness.codex.min_version, harness.codex.tested_version },
        };
        return .{
            .harness = e.harness,
            .enabled = e.enabled,
            .found = e.found,
            .path = e.path,
            .version = e.version,
            .signed_in = e.signed_in,
            .sign_in_detail = e.sign_in_detail,
            .protocol = e.protocol,
            .protocol_problem = if (f.protocol == .failed) f.protocol.failed else null,
            .fix = e.fix,
            .min_version = minimum,
            .tested_version = tested,
        };
    }
};

/// The sign-in checks behind `provider.list`: one thread per provider runs
/// its harness's status command with the provider's config folder in the
/// environment. Calls that arrive during a run share it. Runs on the
/// reactor, like `Discovery`; `tick` answers.
pub const ProviderList = struct {
    gpa: std.mem.Allocator,
    discovery: *Discovery,
    run: ?*Run = null,
    waiting: std.ArrayList(proto.Ticket) = .empty,
    dispatcher: ?*proto.Dispatcher = null,

    /// One provider in `provider.list`. Absent (null) means not known.
    pub const Entry = struct {
        name: []const u8,
        harness: []const u8,
        /// The config folder as configured; absent: the default login.
        home: ?[]const u8 = null,
        model: ?[]const u8 = null,
        mode: ?[]const u8 = null,
        /// It is `agents.provider`.
        default: bool = false,
        /// Its harness is enabled (`harness.<h>.enabled`).
        available: bool = false,
        signed_in: ?bool = null,
        /// The plan or sign-in method, never an identity.
        plan: ?[]const u8 = null,
        /// Its own sign-in command, for its config folder.
        sign_in: []const u8,
    };

    const Run = struct {
        arena: std.heap.ArenaAllocator,
        entries: []Entry,
        /// Resolved config folders, parallel to `entries`.
        homes: []?[]const u8,
        threads: []?std.Thread,
        remaining: std.atomic.Value(usize) = .init(0),
    };

    pub fn deinit(self: *ProviderList) void {
        if (self.run) |r| self.finish(r);
        self.waiting.deinit(self.gpa);
    }

    fn finish(self: *ProviderList, r: *Run) void {
        for (r.threads) |t| if (t) |thread| thread.join();
        r.arena.deinit();
        self.gpa.destroy(r);
        self.run = null;
    }

    pub fn enqueue(self: *ProviderList, c: *proto.Call, list: []const config.Provider, default: ?[]const u8) !void {
        self.dispatcher = c.dispatcher;
        try self.waiting.append(self.gpa, c.ticket);
        if (self.run != null) return;
        const r = try self.gpa.create(Run);
        r.* = .{ .arena = .init(self.gpa), .entries = &.{}, .homes = &.{}, .threads = &.{} };
        self.run = r;
        errdefer self.finish(r);
        const a = r.arena.allocator();
        r.entries = try a.alloc(Entry, list.len);
        r.homes = try a.alloc(?[]const u8, list.len);
        r.threads = try a.alloc(?std.Thread, list.len);
        @memset(r.threads, null);
        const user_home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.sliceTo(h, 0) else null;
        for (list, r.entries, r.homes) |p, *e, *home| {
            const t = self.target(p.harness);
            e.* = .{
                .name = try a.dupe(u8, p.name),
                .harness = t.known.name,
                .home = if (p.home) |h| try a.dupe(u8, h) else null,
                .model = if (p.model) |m| try a.dupe(u8, m) else null,
                .mode = if (p.mode) |m| @tagName(m) else null,
                .default = if (default) |d| std.mem.eql(u8, d, p.name) else false,
                .available = t.enabled,
                .sign_in = try providerSignIn(a, p, t),
            };
            home.* = try p.resolvedHome(a, user_home);
        }
        r.remaining.store(list.len, .release);
        for (r.entries, 0..) |e, i| {
            if (!e.available) {
                _ = r.remaining.fetchSub(1, .acq_rel);
                continue;
            }
            r.threads[i] = std.Thread.spawn(.{}, work, .{ self, r, i }) catch blk: {
                _ = r.remaining.fetchSub(1, .acq_rel);
                break :blk null;
            };
        }
    }

    fn target(self: *const ProviderList, h: config.Harness) *const Discovery.Target {
        for (&self.discovery.targets) |*t| if (t.known.id == h) return t;
        unreachable; // every config.Harness has a `known` entry
    }

    fn work(self: *ProviderList, r: *Run, i: usize) void {
        defer _ = r.remaining.fetchSub(1, .acq_rel);
        const e = &r.entries[i];
        const t = self.target(for (known) |k| {
            if (std.mem.eql(u8, k.name, e.harness)) break k.id;
        } else unreachable);
        var env_buf: [1]harness.contract.EnvVar = undefined;
        var env: []const harness.contract.EnvVar = &.{};
        if (r.homes[i]) |h| {
            env_buf[0] = .{ .name = config.Provider.homeEnv(t.known.id), .value = h };
            env = &env_buf;
        }
        const got = discovery.signIn(self.gpa, t.vendor, .{
            .exe = t.exe,
            .path_env = self.discovery.pathEnv(),
            .command_timeout_ms = self.discovery.command_timeout_ms,
            .cancel = &self.discovery.cancel,
            .env = env,
        }) catch return;
        e.signed_in = got.signed_in;
        e.plan = got.detail;
    }

    pub fn tick(self: *ProviderList) !void {
        const r = self.run orelse return;
        if (r.remaining.load(.acquire) != 0) return;
        defer self.finish(r);
        const d = self.dispatcher orelse return;
        for (r.threads) |*t| if (t.*) |thread| {
            thread.join();
            t.* = null;
        };
        for (self.waiting.items) |ticket| {
            const c = d.get(ticket) orelse continue;
            c.ok(.{ .providers = r.entries }) catch |err| if (err == error.OutOfMemory) return err;
        }
        self.waiting.clearRetainingCapacity();
    }
};

/// A provider's sign-in command: its harness's own, with the config folder
/// in front when it has one (`CLAUDE_CONFIG_DIR=~/.claude_personal claude auth login`).
fn providerSignIn(a: std.mem.Allocator, p: config.Provider, t: *const Discovery.Target) ![]const u8 {
    const cmd = try ownCommand(a, t.exe, t.vendor.sign_in);
    const home = p.home orelse return cmd;
    return std.fmt.allocPrint(a, "{s}={s} {s}", .{ config.Provider.homeEnv(p.harness), home, cmd });
}

/// `<exe> <args...>`, with `exe` quoted for the shell if it needs it.
fn ownCommand(a: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]const u8 {
    var r: cli.doctor.Report = .{ .arena = a, .tool = "" };
    var line = try r.command("{s}", exe);
    for (args) |arg| line = try std.fmt.allocPrint(a, "{s} {s}", .{ line, arg });
    return line;
}

/// `harness.list` and `harness.show` (read): they wait for a discovery run
/// off the reactor, and answer from `Discovery.tick`.
pub const Verbs = struct {
    runner: *Runner,
    /// For `provider.list`; without it the list is empty.
    config: ?*config.Store = null,
    show_: Show = undefined,
    providers_: Providers = undefined,

    pub fn bindings(self: *Verbs) [3]proto.Binding {
        self.show_ = .{ .runner = self.runner };
        self.providers_ = .{ .runner = self.runner, .config = self.config };
        return .{
            .{ .verb = "harness.list", .handler = proto.VerbHandler.init(self) },
            .{ .verb = "harness.show", .handler = proto.VerbHandler.typed(Show.Params, &self.show_) },
            .{ .verb = "provider.list", .handler = proto.VerbHandler.init(&self.providers_) },
        };
    }

    /// `provider.list` (read): the providers, each with its harness's
    /// sign-in state for its own config folder, asked off the reactor.
    pub const Providers = struct {
        runner: *Runner,
        config: ?*config.Store,
        pub fn call(self: *Providers, c: *proto.Call) anyerror!void {
            const cur = if (self.config) |st| st.current() else return c.ok(.{ .providers = &[_]u8{} });
            try self.runner.providers.enqueue(c, cur.providers, cur.agents.provider);
        }
    };

    pub fn call(self: *Verbs, c: *proto.Call) anyerror!void {
        try self.runner.discovery.enqueue(c, null);
    }

    pub const Show = struct {
        runner: *Runner,
        pub const Params = struct { harness: []const u8 };
        pub fn call(self: *Show, c: *proto.Call, p: Params) anyerror!void {
            for (known, 0..) |k, i| {
                if (std.mem.eql(u8, k.name, p.harness)) return self.runner.discovery.enqueue(c, i);
            }
            return c.fail("not_found.harness", "no harness with this id", .{ .harness = p.harness });
        }
    };
};

/// A `doctor` call between its synchronous checks and the discovery run. It
/// lives in the call's arena.
const DoctorRun = struct { verb: *DoctorVerb, report: cli.doctor.Report };

/// `doctor` (read), in place of venom-std's: the same report, but the
/// discovery checks wait for their run off the reactor. A hung
/// harness holds this call for at most `discovery.budget_ms`, and nothing
/// else. `checks` are venom-std's synchronous ones, without `DiscoveryCheck`,
/// which runs last either way, so the order of the results is unchanged.
pub const DoctorVerb = struct {
    runner: *Runner,
    tool: []const u8,
    checks: []const cli.doctor.Check,
    /// The digest this daemon advertises in `hello.schema`.
    schema: ?[]const u8 = null,

    pub fn bindings(self: *DoctorVerb) [1]proto.Binding {
        return .{.{ .verb = "doctor", .handler = proto.VerbHandler.init(self) }};
    }

    pub fn call(self: *DoctorVerb, c: *proto.Call) anyerror!void {
        const run = try c.arena().create(DoctorRun);
        run.* = .{ .verb = self, .report = .{ .arena = c.arena(), .tool = self.tool } };
        const report = &run.report;
        if (c.params.object.get("client_schema")) |v| report.client_schema = v.string;
        for (self.checks) |check| check.vtable.run(check.ptr, report) catch |err| {
            if (err == error.OutOfMemory) return err;
            try report.add(check.id, .fail, try report.print("check could not run: {s}", .{@errorName(err)}), try report.command("{s} doctor --json", self.tool));
        };
        try self.runner.discovery.enqueueDoctor(c, run);
    }

    /// The discovery run ended: its checks, then what venom-std's `doctor`
    /// ends with (`cli.doctor.Doctor.call`), and the answer.
    fn finish(self: *DoctorVerb, c: *proto.Call, report: *cli.doctor.Report) anyerror!void {
        try DiscoveryCheck.add(report, &self.runner.discovery);
        if (c.conn.identity.below_manager) try report.add("grants.below_manager", .warn, "a manager's marker matches a process above this caller, so the owner token is refused here. Expected in a pane or a split; in a plain terminal, a marker was forged", "ls -l \"${XDG_RUNTIME_DIR:-/tmp}/venom\" | grep manager-");
        if (c.conn.registry) |reg| try cli.doctor.processPrincipals(report, reg, c.conn.identity, self.tool);
        try cli.doctor.schemaCheck(report, self.schema);
        try c.ok(.{ .status = report.status(), .checks = report.results.items });
    }
};

/// `doctor`: `harness.<h>.found|version|signed_in|protocol`
/// for each enabled vendor harness, from one discovery
/// run. `DoctorVerb` adds them once the run ended; `run` waits for it, at
/// most `discovery.budget_ms`, for callers that may block. Read-only: it starts
/// no model turn. A harness that is not on `PATH` fails `found` and its other
/// checks say "not checked". Sign-in `fail`s with the harness's own sign-in
/// command as its fix; `warn` when its status command cannot tell.
pub const DiscoveryCheck = struct {
    runner: *Runner,
    pub fn run(self: *DiscoveryCheck, r: *cli.doctor.Report) anyerror!void {
        const d = &self.runner.discovery;
        d.start();
        d.join();
        try add(r, d);
    }

    /// The results of the run that ended.
    fn add(r: *cli.doctor.Report, d: *const Discovery) !void {
        for (d.targets, d.slots) |t, slot| {
            if (!t.enabled) continue;
            try found(r, t, slot.facts);
            try version(r, t, slot.facts);
            try signedIn(r, t, slot.facts);
            try protocol(r, t, slot.facts);
        }
    }

    fn found(r: *cli.doctor.Report, t: Discovery.Target, f: discovery.Facts) !void {
        const id = try r.print("harness.{s}.found", .{t.known.name});
        const path = f.path orelse return r.add(id, .fail, try r.print("{s} not found on PATH; install it, or turn it off: VENOM_TOKEN=@owner {s} config set --key=harness.{s}.enabled --value=false, then restart {s} serve", .{ t.exe, r.tool, @tagName(t.known.id), r.tool }), t.vendor.install);
        const fix = try r.command("{s} doctor --json", r.tool);
        if (f.version == .found) return r.add(id, .ok, try r.print("{s} {s} at {s}", .{ t.vendor.exe, f.version.found, path }), fix);
        try r.add(id, .ok, try r.print("{s} at {s}", .{ t.vendor.exe, path }), fix);
    }

    fn version(r: *cli.doctor.Report, t: Discovery.Target, f: discovery.Facts) !void {
        const id = try r.print("harness.{s}.version", .{t.known.name});
        const name = t.known.name;
        const update = t.vendor.update;
        const v = switch (f.version) {
            .found => |v| v,
            // `found` reports it.
            .missing => return r.add(id, .ok, try r.print("{s} not found on PATH; version not checked", .{t.exe}), try r.command("{s} --version", t.exe)),
            .unreadable => return r.add(id, .warn, try r.print("could not read the version from '{s} --version'", .{t.exe}), try r.command("{s} --version", t.exe)),
        };
        const minimum: ?[]const u8, const tested: []const u8 = switch (t.known.id) {
            .claude_code => .{ harness.claude_code.min_version, harness.claude_code.tested_version },
            .codex => .{ harness.codex.min_version, harness.codex.tested_version },
        };
        const ver = harness.version;
        if (minimum) |m| if (ver.order(v, m) == .lt) return r.add(id, .fail, try r.print("{s} {s} is older than {s}, the oldest venom supports", .{ name, v, m }), update);
        switch (ver.order(v, tested)) {
            .lt => try r.add(id, .warn, try r.print("{s} {s} is older than {s}, the version venom was tested with", .{ name, v, tested }), update),
            .gt => try r.add(id, .warn, try r.print("{s} {s} is newer than {s}, the version venom was tested with", .{ name, v, tested }), update),
            .eq => try r.add(id, .ok, try r.print("{s} {s}", .{ name, v }), update),
        }
    }

    fn signedIn(r: *cli.doctor.Report, t: Discovery.Target, f: discovery.Facts) !void {
        const id = try r.print("harness.{s}.signed_in", .{t.known.name});
        const status = try ownCommand(r.arena, t.exe, t.vendor.status);
        if (!f.found()) return r.add(id, .ok, try r.print("{s} not found on PATH; sign-in not checked", .{t.exe}), status);
        const yes = f.sign_in.signed_in orelse return r.add(id, .warn, try r.print("could not read the sign-in state from '{s}'", .{status}), status);
        if (!yes) return r.add(id, .fail, try r.print("{s} is not signed in", .{t.known.name}), try ownCommand(r.arena, t.exe, t.vendor.sign_in));
        if (f.sign_in.detail) |d| return r.add(id, .ok, try r.print("Signed in ({s})", .{d}), status);
        try r.add(id, .ok, "Signed in", status);
    }

    fn protocol(r: *cli.doctor.Report, t: Discovery.Target, f: discovery.Facts) !void {
        const id = try r.print("harness.{s}.protocol", .{t.known.name});
        const fix = try r.print("{s} harness show --harness={s} --json", .{ r.tool, t.known.name });
        switch (f.protocol) {
            .not_checked => try r.add(id, .ok, try r.print("{s} not started; protocol not checked", .{t.exe}), fix),
            .ok => try r.add(id, .ok, try r.print("{s} protocol reachable", .{t.known.name}), fix),
            .failed => |problem| try r.add(id, .fail, try r.print("{s} protocol not reachable: {s}", .{ t.known.name, problem }), fix),
        }
    }
};

const testing = std.testing;

/// Vendor exe paths inside a test temp dir, so the vendor guard lets the
/// adapters register (nothing here starts them).
const FakePaths = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    claude: []u8,
    codex: []u8,
    fn init() !FakePaths {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(dir);
        const claude = try std.fmt.allocPrint(testing.allocator, "{s}/claude", .{dir});
        errdefer testing.allocator.free(claude);
        return .{ .tmp = tmp, .dir = dir, .claude = claude, .codex = try std.fmt.allocPrint(testing.allocator, "{s}/codex", .{dir}) };
    }
    fn settings(self: *const FakePaths) config.Harnesses {
        return .{ .claude_code = .{ .path = self.claude }, .codex = .{ .path = self.codex } };
    }
    fn deinit(self: *FakePaths) void {
        testing.allocator.free(self.codex);
        testing.allocator.free(self.claude);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
};

test "vendor guard: a Runner on default config fails instead of registering the real claude or codex" {
    // The deliberately unguarded test: default `harness.*`, both vendors on.
    if (harness.guard.optedIn(harness.guard.claude) or harness.guard.optedIn(harness.guard.codex)) return error.SkipZigTest;
    harness.guard.quiet = true;
    defer harness.guard.quiet = false;
    var engine: eventlog.Engine = undefined;
    var r: Runner = undefined;
    try testing.expectError(error.RealHarnessInTest, r.init(testing.allocator, &engine, .{}, &.{}, null));
    // codex alone on, at a real path: refused too.
    try testing.expectError(error.RealHarnessInTest, r.init(testing.allocator, &engine, .{ .claude_code = .{ .enabled = false }, .codex = .{ .path = "/usr/bin/codex" } }, &.{}, null));
    // The helper's settings register nothing but `extra`.
    try r.init(testing.allocator, &engine, test_settings, &.{}, null);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.registered.items.len);
    try testing.expectEqualStrings(".{ " ++ test_vendors_off ++ " }", testConfig(""));
    try testing.expectEqualStrings(".{ " ++ test_vendors_off ++ ", .ui = .{} }", testConfig(".ui = .{}"));
}

test "hostOptions maps the harness.* keys" {
    const o = hostOptions(.{ .shutdown_grace = "2s", .start_timeout = "1m", .body_max = 1024, .resume_prompt = "Go on." }, null);
    try testing.expectEqual(@as(u32, 2_000), o.shutdown_grace_ms);
    try testing.expectEqual(@as(u32, 60_000), o.start_timeout_ms);
    try testing.expectEqual(@as(u32, 1024), o.body_max);
    try testing.expectEqualStrings("Go on.", o.resume_prompt);
    const d = hostOptions(.{}, null);
    const want: harness.host.Options = .{};
    try testing.expectEqual(want.shutdown_grace_ms, d.shutdown_grace_ms);
    try testing.expectEqual(want.start_timeout_ms, d.start_timeout_ms);
    try testing.expectEqual(want.body_max, d.body_max);
    try testing.expectEqualStrings(want.resume_prompt, d.resume_prompt);
}

test "repeatedFlag finds --flag and --flag=value repeats only" {
    const flags = [_][]const u8{ "--session", "--script" };
    try testing.expectEqual(@as(?[]const u8, null), repeatedFlag(&.{ "--verbose", "--sessions", "-s" }, &flags));
    try testing.expectEqualStrings("--script", repeatedFlag(&.{ "--verbose", "--script" }, &flags).?);
    try testing.expectEqualStrings("--session=x", repeatedFlag(&.{"--session=x"}, &flags).?);
    try testing.expectEqual(@as(?[]const u8, null), repeatedFlag(&.{}, &flags));
}

test "Runner registers the ACP agent only when harness.acp is on" {
    var engine: eventlog.Engine = undefined;
    var off: Runner = undefined;
    try off.init(testing.allocator, &engine, test_settings, &.{}, null);
    defer off.deinit();
    try testing.expect(off.acp == null);
    try testing.expectEqual(@as(usize, 0), off.registered.items.len);

    var on: Runner = undefined;
    var settings = test_settings;
    settings.acp = .{ .enabled = true, .path = "/opt/agent", .extra_args = &.{"--acp"} };
    try on.init(testing.allocator, &engine, settings, &.{}, null);
    defer on.deinit();
    try testing.expectEqual(@as(usize, 1), on.registered.items.len);
    try testing.expectEqualStrings(harness.acp.name, on.registered.items[0].harness);
    try testing.expectEqualStrings("--acp", on.acp.?.argv[1]);
}

test "Runner registers the codex adapter with harness.codex.path and extra_args" {
    // The host only keeps the engine pointer; nothing here reaches it.
    var engine: eventlog.Engine = undefined;
    var fx = try FakePaths.init();
    defer fx.deinit();
    var r: Runner = undefined;
    try r.init(testing.allocator, &engine, .{ .claude_code = .{ .enabled = false }, .codex = .{ .path = fx.codex, .extra_args = &.{ "-c", "model=\"o3\"" } } }, &.{}, null);
    defer r.deinit();
    var found = false;
    for (r.registered.items) |reg| if (std.mem.eql(u8, reg.harness, "codex")) {
        found = true;
    };
    try testing.expect(found);
    const argv = r.codex.?.argv;
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings(fx.codex, argv[0]);
    try testing.expectEqualStrings("app-server", argv[1]);
    try testing.expectEqualStrings("model=\"o3\"", argv[3]);

    var off: Runner = undefined;
    try off.init(testing.allocator, &engine, test_settings, &.{}, null);
    defer off.deinit();
    try testing.expect(off.codex == null);
}

test "Runner gives both vendor adapters a copy of venom's MCP server" {
    var engine: eventlog.Engine = undefined;
    var fx = try FakePaths.init();
    defer fx.deinit();
    const both = fx.settings();
    var command = "/usr/bin/venom".*;
    var r: Runner = undefined;
    try r.initWith(testing.allocator, &engine, both, &.{}, null, .{ .command = &command, .socket = "/run/v.sock" }, null);
    defer r.deinit();
    command[0] = 'X';
    try testing.expectEqualStrings("/usr/bin/venom", r.claude_code.?.mcp.?.command);
    try testing.expectEqualStrings("/run/v.sock", r.claude_code.?.mcp.?.socket.?);
    try testing.expectEqualStrings("/usr/bin/venom", r.codex.?.mcp.?.command);
    // No replier: no approvals path through the MCP server.
    try testing.expect(r.claude_code.?.replier == null);

    // With a replier, claude-code agents get the permission
    // prompt tool; without the MCP server the replier is not used.
    const Nop = struct {
        fn reply(_: *anyopaque, _: []const u8, _: []const u8, _: u64, _: []const u8) anyerror!void {}
    };
    var token: u8 = 0;
    const replier: harness.claude_code.Replier = .{ .ptr = &token, .reply = Nop.reply };
    var with: Runner = undefined;
    try with.initWith(testing.allocator, &engine, both, &.{}, null, .{ .command = "/usr/bin/venom" }, replier);
    defer with.deinit();
    try testing.expect(with.claude_code.?.replier != null);
    try testing.expect((try with.claude_code.?.probe(testing.allocator)).caps.requests.approval != null);
    var bare: Runner = undefined;
    try bare.initWith(testing.allocator, &engine, both, &.{}, null, null, replier);
    defer bare.deinit();
    try testing.expect(bare.claude_code.?.replier == null);

    var none: Runner = undefined;
    try none.init(testing.allocator, &engine, both, &.{}, null);
    defer none.deinit();
    try testing.expect(none.claude_code.?.mcp == null and none.codex.?.mcp == null);
}

test "Known.resume_tui matches each adapter's probe (the split menu's take-over)" {
    var cc = try harness.claude_code.ClaudeCode.init(testing.allocator, .{});
    defer cc.deinit();
    var cx = harness.codex.Codex.init(testing.allocator);
    defer cx.deinit();
    const probed = [_]contract_caps{
        .{ .name = harness.claude_code.name, .resume_tui = (try cc.probe(testing.allocator)).caps.resume_tui },
        .{ .name = harness.codex.name, .resume_tui = (try cx.probe(testing.allocator)).caps.resume_tui },
    };
    for (probed) |p| try testing.expectEqual(p.resume_tui, resumesTui(p.name));
    try testing.expect(resumesTui(harness.claude_code.name));
    try testing.expect(!resumesTui("fake"));
}
const contract_caps = struct { name: []const u8, resume_tui: bool };

test "doctor harness.<h>.version: tested ok, newer or older warn, below the minimum fail" {
    var engine: eventlog.Engine = undefined;
    // "" is not installed; "?" runs but prints no version.
    const Case = struct { claude: []const u8, codex: []const u8, want: [2]cli.doctor.Status };
    for ([_]Case{
        .{ .claude = harness.claude_code.tested_version, .codex = harness.codex.tested_version, .want = .{ .ok, .ok } },
        // Newer than tested; below codex's minimum (permission profiles).
        .{ .claude = "9.0.0", .codex = "0.100.0", .want = .{ .warn, .fail } },
        // Above the minimum but below tested; below the minimum.
        .{ .claude = "2.1.300", .codex = "0.168.0", .want = .{ .warn, .warn } },
        .{ .claude = "2.1.100", .codex = harness.codex.tested_version, .want = .{ .fail, .ok } },
        // Not installed: ok, not checked; installed but unreadable: warn.
        .{ .claude = "", .codex = "?", .want = .{ .ok, .warn } },
    }) |case| {
        var fx = try FakePaths.init();
        defer fx.deinit();
        try fakeVersion(&fx, "claude", "{s} (Claude Code)", case.claude);
        try fakeVersion(&fx, "codex", "codex-cli {s}", case.codex);
        var r: Runner = undefined;
        try r.init(testing.allocator, &engine, fx.settings(), &.{}, null);
        defer r.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "venom" };
        // `codex` here exits at once: see `doctorResults`.
        harness.process.ignoreSigpipe();
        var check: DiscoveryCheck = .{ .runner = &r };
        try check.run(&report);
        // found, version, signed_in, protocol, per harness.
        const got = report.results.items;
        try testing.expectEqual(@as(usize, 8), got.len);
        try testing.expectEqualStrings("harness.claude-code.version", got[1].id);
        try testing.expectEqualStrings("harness.codex.version", got[5].id);
        try testing.expectEqual(case.want[0], got[1].status);
        try testing.expectEqual(case.want[1], got[5].status);
        if (std.mem.eql(u8, case.claude, "")) try testing.expect(std.mem.indexOf(u8, got[1].message, "not found on PATH") != null);
        // Once detected, probe reports the same version.
        _ = r.claude_code.?.waitVersion();
        _ = r.codex.?.waitVersion();
        if (case.claude.len > 0 and std.ascii.isDigit(case.claude[0])) try testing.expectEqualStrings(case.claude, (try r.claude_code.?.probe(arena.allocator())).harness_version.?);
        if (case.codex.len > 0 and std.ascii.isDigit(case.codex[0])) try testing.expectEqualStrings(case.codex, (try r.codex.?.probe(arena.allocator())).harness_version.?);
    }
}

test "probe never waits for <harness> --version, even while it hangs" {
    var engine: eventlog.Engine = undefined;
    var fx = try FakePaths.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "claude", .data = "#!/bin/sh\nexec sleep 30\n" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = "#!/bin/sh\nexec sleep 30\n" });
    try makeExecutable(&fx);
    var r: Runner = undefined;
    try r.init(testing.allocator, &engine, fx.settings(), &.{}, null);
    // Runner.deinit waits for the detectors (they give up at the timeout).
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t0 = @import("supervisor").monotonicMs();
    const cc = try r.claude_code.?.probe(arena.allocator());
    const cx = try r.codex.?.probe(arena.allocator());
    try testing.expect(@import("supervisor").monotonicMs() - t0 < 100);
    try testing.expect(cc.harness_version == null and cx.harness_version == null);
    try testing.expect(cc.valid() and cx.valid());
}

/// The doctor results for a Runner on fakes from `src/testdata/harness-bin`,
/// found through a temp PATH (`harness.<h>.path` left unset is what a user
/// has; the guard wants a path here, and `path_env` decides the lookup).
fn doctorResults(r: *Runner, a: std.mem.Allocator) ![]const cli.doctor.Result {
    // These fakes can exit before the handshake is written, and the test
    // runner, unlike `venom serve`, does not ignore SIGPIPE.
    harness.process.ignoreSigpipe();
    const report = try a.create(cli.doctor.Report);
    report.* = .{ .arena = a, .tool = "venom" };
    var discovery_check: DiscoveryCheck = .{ .runner = r };
    try discovery_check.run(report);
    return report.results.items;
}

fn result(results: []const cli.doctor.Result, id: []const u8) cli.doctor.Result {
    for (results) |res| if (std.mem.eql(u8, res.id, id)) return res;
    std.debug.panic("no doctor result {s}", .{id});
}

test "doctor reports found, version, signed_in and protocol per harness, with runnable fixes" {
    var engine: eventlog.Engine = undefined;
    var fx = try FakePaths.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "claude", .data = @embedFile("testdata/harness-bin/claude") });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = @embedFile("testdata/harness-bin/codex") });
    try makeExecutable(&fx);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r: Runner = undefined;
    try r.init(testing.allocator, &engine, fx.settings(), &.{}, null);
    defer r.deinit();
    r.discovery.path_env = "/nonexistent";

    var got = try doctorResults(&r, a);
    try testing.expectEqual(@as(usize, 8), got.len);
    for (got) |res| try testing.expectEqual(cli.doctor.Status.ok, res.status);
    try testing.expectEqualStrings("Signed in (max)", result(got, "harness.claude-code.signed_in").message);
    try testing.expectEqualStrings("Signed in (API key)", result(got, "harness.codex.signed_in").message);
    try testing.expectEqualStrings("venom harness show --harness=codex --json", result(got, "harness.codex.protocol").fix);
    for (got) |res| {
        try testing.expect(std.mem.indexOf(u8, res.message, "fake-secret") == null);
        try testing.expect(std.mem.indexOf(u8, res.fix, "fake-secret") == null);
    }

    // Signed out: the fix is the harness's own sign-in command.
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "claude", .data = "#!/bin/sh\necho '{\"loggedIn\":false}'\nexit 1\n" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = "#!/bin/sh\necho 'Not logged in' >&2\nexit 1\n" });
    got = try doctorResults(&r, a);
    const cc = result(got, "harness.claude-code.signed_in");
    try testing.expectEqual(cli.doctor.Status.fail, cc.status);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} auth login", .{fx.claude}), cc.fix);
    const cx = result(got, "harness.codex.signed_in");
    try testing.expectEqual(cli.doctor.Status.fail, cx.status);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} login", .{fx.codex}), cx.fix);
    try testing.expectEqual(cli.doctor.Status.fail, result(got, "harness.codex.protocol").status);

    // Gone: `found` fails with the install command; the rest are not checked.
    try fx.tmp.dir.deleteFile(testing.io, "codex");
    got = try doctorResults(&r, a);
    const gone = result(got, "harness.codex.found");
    try testing.expectEqual(cli.doctor.Status.fail, gone.status);
    try testing.expectEqualStrings(discovery.codex.install, gone.fix);
    try testing.expectEqual(cli.doctor.Status.ok, result(got, "harness.codex.signed_in").status);
    try testing.expectEqual(cli.doctor.Status.ok, result(got, "harness.codex.protocol").status);
}

test "discovery: a harness that is off is looked up, never run, and has no doctor checks" {
    var engine: eventlog.Engine = undefined;
    var fx = try FakePaths.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "claude", .data = "#!/bin/sh\nexit 7\n" });
    try chmodExecutable(fx.claude);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r: Runner = undefined;
    try r.init(testing.allocator, &engine, test_settings, &.{}, null);
    defer r.deinit();
    r.discovery.path_env = fx.dir;
    try testing.expectEqual(@as(usize, 0), (try doctorResults(&r, arena.allocator())).len);
    const off = try r.discovery.entry(arena.allocator(), 0);
    try testing.expect(!off.enabled and off.found);
    try testing.expectEqualStrings(fx.claude, off.path.?);
    try testing.expect(off.version == null and off.signed_in == null and off.protocol == null and off.fix == null);
    const missing = try r.discovery.entry(arena.allocator(), 1);
    try testing.expect(!missing.enabled and !missing.found);
    try testing.expectEqualStrings(discovery.codex.install, missing.fix.?);
}

/// Writes `<name>` printing `fmt` with `v`: none when `v` is "" (not
/// installed), a script that prints nothing when it is "?".
fn fakeVersion(fx: *FakePaths, name: []const u8, comptime fmt: []const u8, v: []const u8) !void {
    if (v.len == 0) return;
    var buf: [128]u8 = undefined;
    const body = if (std.mem.eql(u8, v, "?")) "#!/bin/sh\nexit 0\n" else try std.fmt.bufPrint(&buf, "#!/bin/sh\necho '" ++ fmt ++ "'\n", .{v});
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = body });
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ fx.dir, name }, 0);
    defer testing.allocator.free(path);
    if (std.c.chmod(path, 0o755) != 0) return error.ChmodFailed;
}

fn makeExecutable(fx: *FakePaths) !void {
    for ([_][]const u8{ fx.claude, fx.codex }) |p| try chmodExecutable(p);
}

fn chmodExecutable(path: []const u8) !void {
    const z = try testing.allocator.dupeSentinel(u8, path, 0);
    defer testing.allocator.free(z);
    if (std.c.chmod(z, 0o755) != 0) return error.ChmodFailed;
}
