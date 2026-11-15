//! The agent verbs: spawn → send → stop → archive
//! round-trips with the fake harness through the generated CLI (`--json`)
//! and the MCP server (`venom mcp`), with stable exit codes for unknown
//! agents and illegal state changes.
//!
//! The daemon side is the real serve loop (socket, dispatcher, engine,
//! harness host) on its own thread, the only thread that touches the
//! engine; the test thread is the client, as `venom agent …` and `venom
//! mcp` would be. Leak-checked; every harness pid is gone at the end.
const std = @import("std");
const proto = @import("proto");
const log = @import("log");
const cli = @import("cli");
const build_options = @import("build_options");
const main = @import("main.zig");
const config = @import("config.zig");
const harnesses = @import("harnesses.zig");
const eventlog = @import("eventlog/root.zig");
const harness = @import("harness/root.zig");
const Workspaces = @import("workspaces.zig").Workspaces;
const agents_mod = @import("agents.zig");
const Agents = agents_mod.Agents;
const Principals = @import("principals.zig").Principals;
const Usage = @import("usage.zig").Usage;
const ContextVerbs = @import("context.zig").Verbs;
const Inbox = @import("inbox.zig").Inbox;
const supervisor = @import("supervisor");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

/// venom's verbs plus `events` (the inbox tests read the published events).
/// `tui.hold` is not under test here (holds_tests.zig has it).
const HoldStub = struct {
    pub fn call(_: *HoldStub, call_: *proto.Call) anyerror!void {
        return call_.ok(struct {}{});
    }
};
const model = cli.manifest.normalize(.{ .format = main.input.format, .tool = main.input.tool, .summary = main.input.summary, .verbs = main.input.verbs ++ .{eventlog.catalog.events_manifest} });

/// "slow" turns run until interrupted; anything else answers at once.
const script =
    \\{"turns":[{"match":"slow","steps":[{"text":"working"},{"sleep_ms":20000}]},
    \\          {"match":"","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"ls","input":{"command":"ls","timeout":5}}},
    \\                               {"tool_end":{"id":"tu1","status":"ok","exit":0}},
    \\                               {"usage":{"in":10,"out":5,"cache_read":100,"cache_write":7}},{"text":"Done."}]}]}
;

/// Vendor harnesses off: only the fake may ever run in these tests
/// (a shared helper; kept here for `inbox_tests.zig`).
pub const vendors_off = harnesses.test_vendors_off;

/// Shared with `inbox_tests.zig`.
pub const Daemon = struct {
    tmp: testing.TmpDir,
    dir: []u8,
    work: []u8,
    socket: []u8,
    arena: std.heap.ArenaAllocator,
    exe: [std.fs.max_path_bytes:0]u8,
    fake: harness.Fake,
    /// The fake, then `Options.extra`.
    adapters: [4]harness.host.Registered,
    n_adapters: usize,
    logger: log.Logger,
    events: proto.events.Log,
    store: config.Store,
    registry: proto.grants.Registry,
    engine: eventlog.Engine,
    runner: harnesses.Runner,
    harness_verbs: harnesses.Verbs,
    hold_stub: HoldStub = .{},
    workspaces: Workspaces,
    ws_add: Workspaces.Add,
    ws_remove: Workspaces.Remove,
    ws_scan: Workspaces.Scan,
    agents: Agents,
    principals: Principals,
    usage: Usage,
    context_verbs: ContextVerbs,
    inbox: Inbox,
    dispatcher: proto.Dispatcher,
    server: proto.Server,
    loop: main.ServeLoop,
    stop: std.atomic.Value(bool),
    failed: std.atomic.Value(bool),
    thread: std.Thread,
    /// `pause` stopped the reactor thread.
    paused: bool,
    /// `onReactor`'s job, taken by the reactor thread.
    job: std.atomic.Value(?*Job),
    pids: std.ArrayList(c.pid_t),
    options: Options,
    pub const Options = struct {
        script: []const u8 = script,
        /// The user config file; it must keep `vendors_off`.
        config: []const u8 = harnesses.testConfig(""),
        /// More adapters, registered after the fake (the MCP tests register
        /// claude-code and codex adapters pointed at fake scripts).
        extra: []const harness.host.Registered = &.{},
        gh_timeout_ms: i64 = 10_000,
        clean_budget_ms: i64 = 120_000,
        /// The decider's clock, and what the serve loop escalates with.
        clock: eventlog.engine.Clock = .{},
        escalation: ?*@import("escalation.zig").Escalation = null,
        /// Treats codex as enabled for sign-in only, at this fake exe,
        /// with a status command allowed this long. `extra` gives it an adapter.
        sign_in_exe: ?[]const u8 = null,
        sign_in_timeout_ms: u32 = 60_000,
    };

    pub fn init(self: *Daemon) !void {
        return self.initWith(.{});
    }

    pub fn initWith(self: *Daemon, options: Options) !void {
        self.job = .init(null);
        self.pids = .empty;
        self.paused = false;
        self.stop = .init(false);
        self.failed = .init(false);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = .init(ta);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        try self.tmp.dir.createDirPath(testing.io, "work/sub");
        self.work = try std.fmt.allocPrint(a, "{s}/work", .{self.dir});
        const rel = try a.dupeSentinel(u8, build_options.fake_harness, 0);
        if (c.realpath(rel, &self.exe) == null) return error.FakeHarnessMissing;
        self.fake = .{ .exe = std.mem.sliceTo(&self.exe, 0), .script = options.script, .state_dir = self.dir };
        if (options.extra.len >= self.adapters.len) return error.TooManyAdapters;
        self.adapters[0] = .{ .harness = harness.fake.name, .adapter = self.fake.adapter() };
        @memcpy(self.adapters[1..][0..options.extra.len], options.extra);
        self.n_adapters = 1 + options.extra.len;
        // Vendor harnesses off: only the fake may ever run here, and the
        // default harness (claude-code) has no adapter in this daemon.
        if (std.mem.indexOf(u8, options.config, vendors_off) == null) return error.VendorHarnessesEnabled;
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = options.config });
        const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{self.dir}, 0);
        if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
        self.socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir});
        self.options = options;
        try self.boot();
    }

    /// Stops the daemon and starts it again on the same state directory
    /// (event log, config, socket), as a daemon restart would.
    pub fn restart(self: *Daemon) !void {
        self.halt();
        self.stop.store(false, .release);
        self.failed.store(false, .release);
        try self.boot();
    }

    fn boot(self: *Daemon) !void {
        const a = self.arena.allocator();
        self.logger = log.Logger.init(.{ .source = main.tool });
        errdefer self.logger.deinit();
        self.events = try proto.events.Log.init(ta, main.tool, .{}, null);
        errdefer self.events.deinit();
        self.events.catalog = &eventlog.catalog.entries;
        self.store = try config.Store.init(ta, .{ .io = testing.io, .path = try std.fmt.allocPrint(a, "{s}/config.zon", .{self.dir}), .validate = config.validate, .events = &self.events });
        errdefer self.store.deinit();
        self.registry = try proto.grants.Registry.init(ta, main.tool, .{});
        errdefer self.registry.deinit();
        // The clients run in the daemon's own process, where the owner token
        // is refused. A principal rooted at this process, as an
        // agent's would be, gives them `write` and `spawn`.
        const self_ref = (try proto.process.stat(c.getpid())).ref;
        const issued = try self.registry.issueChild(.{ .principal = proto.grants.owner }, .{ .kind = .agent, .root = self_ref, .grants = &.{ .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" } }, .label = "test" }, proto.grants.nowSeconds());
        ta.free(issued.token);
        self.engine = try eventlog.Engine.open(ta, try std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, eventlog.file_name }), .{ .events = &self.events, .clock = self.options.clock });
        errdefer self.engine.deinit();
        try self.runner.init(ta, &self.engine, self.store.current().harness, self.adapters[0..self.n_adapters], &self.logger);
        errdefer self.runner.deinit();
        if (self.options.sign_in_exe) |exe| for (&self.runner.discovery.targets) |*t| if (t.known.id == .codex) {
            t.enabled = true;
            t.exe = exe;
            self.runner.discovery.command_timeout_ms = self.options.sign_in_timeout_ms;
        };
        self.engine.options.executors = self.runner.executors();
        try self.engine.start();
        self.principals = .{ .gpa = ta, .registry = &self.registry, .engine = &self.engine };
        errdefer self.principals.deinit();
        self.principals.install();
        self.runner.host.credentials = self.principals.credentials();

        self.workspaces = .{ .engine = &self.engine, .io = testing.io };
        self.ws_add = self.workspaces.adder();
        self.ws_remove = self.workspaces.remover();
        self.ws_scan = self.workspaces.scanner();
        self.agents = .{ .engine = &self.engine, .host = &self.runner.host, .io = testing.io, .config = &self.store, .principals = &self.principals, .gh = try std.fmt.allocPrint(a, "{s}/gh", .{self.dir}), .gh_timeout_ms = self.options.gh_timeout_ms, .clean_budget_ms = self.options.clean_budget_ms, .discovery = &self.runner.discovery };
        self.usage = .{ .engine = &self.engine };
        self.context_verbs = .{ .agents = &self.agents };
        self.inbox = .{ .engine = &self.engine, .principals = &self.principals };
        self.harness_verbs = .{ .runner = &self.runner };
        const handlers = [_]proto.Binding{
            .{ .verb = "workspace.add", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.ws_add) },
            .{ .verb = "workspace.list", .handler = proto.VerbHandler.init(&self.workspaces) },
            .{ .verb = "workspace.remove", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.ws_remove) },
            .{ .verb = "workspace.scan", .handler = proto.VerbHandler.typed(Workspaces.ScanParams, &self.ws_scan) },
            .{ .verb = "events", .handler = proto.VerbHandler.init(&self.events) },
            .{ .verb = "tui.hold", .handler = proto.VerbHandler.init(&self.hold_stub) },
        } ++ self.agents.bindings() ++ self.usage.bindings() ++ self.context_verbs.bindings() ++ self.inbox.bindings() ++ self.harness_verbs.bindings();
        self.dispatcher = try proto.Dispatcher.init(ta, &model, &handlers, .{}, null);
        errdefer self.dispatcher.deinit();
        self.server = try proto.Server.init(ta, .{
            .hello = .{ .identity = .{ .name = main.tool, .version = "0.0.0" }, .caps = &.{"cancel"} },
            .path = .{ .socket = self.socket },
            .registry = &self.registry,
        }, self.dispatcher.handler());
        errdefer self.server.deinit();
        self.loop = .{ .gpa = ta, .io = testing.io, .server = &self.server, .dispatcher = &self.dispatcher, .events = &self.events, .config = &self.store, .registry = &self.registry, .logger = &self.logger, .engine = &self.engine, .harnesses = &self.runner, .agents = &self.agents, .escalation = self.options.escalation };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// The reactor thread: the only one that touches the engine and host.
    fn serve(self: *Daemon) void {
        while (!self.stop.load(.acquire)) {
            self.loop.step(20) catch |err| {
                std.debug.print("serve loop failed: {s}\n", .{@errorName(err)});
                self.failed.store(true, .release);
                return;
            };
            if (self.job.swap(null, .acq_rel)) |job| {
                job.result = job.run(job, self);
                job.done.store(true, .release);
            }
            for (self.runner.host.bindings.values()) |b| if (b.process) |p| {
                for (self.pids.items) |pid| {
                    if (pid == p.pid()) break;
                } else self.pids.append(ta, p.pid()) catch @panic("oom");
            };
        }
        // What `ServeLoop.serve` does after the supervisor returns.
        self.dispatcher.cancelAll();
        self.runner.host.shutdown() catch |err| std.debug.print("harness shutdown failed: {s}\n", .{@errorName(err)});
    }

    /// What only the reactor thread may do, for what no verb does yet.
    pub const Job = struct {
        run: *const fn (*Job, *Daemon) anyerror!void,
        done: std.atomic.Value(bool) = .init(false),
        result: anyerror!void = {},
    };

    /// Runs `job` between two reactor turns and waits for it.
    pub fn onReactor(self: *Daemon, job: *Job) !void {
        self.job.store(job, .release);
        while (!job.done.load(.acquire)) {
            if (self.failed.load(.acquire)) return error.ServeLoopFailed;
            var ts: c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
        }
        return job.result;
    }

    /// Stops the reactor thread only, so the test may read the engine's
    /// state directly; `deinit` frees everything as usual.
    pub fn pause(self: *Daemon) void {
        if (self.paused) return;
        self.paused = true;
        self.stop.store(true, .release);
        self.thread.join();
    }

    pub fn deinit(self: *Daemon) void {
        self.halt();
        self.pids.deinit(ta);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Stops the serve loop and frees everything `boot` made; every harness
    /// process is gone afterwards.
    fn halt(self: *Daemon) void {
        self.pause();
        self.paused = false;
        self.loop.deinit();
        self.agents.deinit();
        self.server.deinit();
        self.dispatcher.deinit();
        self.runner.deinit();
        for (self.pids.items) |pid| {
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("a harness process outlived the daemon");
        }
        self.engine.deinit();
        self.principals.deinit();
        self.registry.deinit();
        self.store.deinit();
        self.events.deinit();
        self.logger.deinit();
    }

    pub const Out = struct { status: u8, json: Value };

    /// `venom <args> --json --socket=…` through the generated CLI. The
    /// result (or error) line is parsed into `a`.
    pub fn run(self: *Daemon, a: std.mem.Allocator, args: []const []const u8) !Out {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, args);
        try argv.appendSlice(a, &.{ "--json", try std.fmt.allocPrint(a, "--socket={s}", .{self.socket}) });
        var out: std.Io.Writer.Allocating = .init(ta);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(ta);
        defer err.deinit();
        const status = try main.App.run(ta, argv.items, .{ .stdout = &out.writer, .stderr = &err.writer, .local = main.noView() });
        const text = if (out.written().len > 0) out.written() else err.written();
        const line = std.mem.trim(u8, text, " \n");
        const json = std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{}) catch {
            std.debug.print("not JSON: {s} / {s}\n", .{ out.written(), err.written() });
            return error.TestUnexpectedResult;
        };
        return .{ .status = status, .json = json };
    }

    /// Polls `agent show` until the agent is in `want` (10 s at most).
    pub fn waitState(self: *Daemon, a: std.mem.Allocator, agent: []const u8, want: []const u8) !Value {
        const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
        const flag = try std.fmt.allocPrint(a, "--agent={s}", .{agent});
        while (true) {
            if (self.failed.load(.acquire)) return error.ServeLoopFailed;
            const r = try self.run(a, &.{ "agent", "show", flag });
            try testing.expectEqual(@as(u8, 0), r.status);
            if (std.mem.eql(u8, r.json.object.get("state").?.string, want)) return r.json;
            if (supervisor.monotonicMs() > deadline) {
                std.debug.print("agent {s} is {s}, want {s}\n", .{ agent, r.json.object.get("state").?.string, want });
                return error.Timeout;
            }
            var ts: c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
        }
    }
};

fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
fn errorCode(v: Value) []const u8 {
    return v.object.get("error").?.object.get("code").?.string;
}

test "agent verbs: spawn → send → stop → archive through the CLI with --json and stable exit codes" {
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});

    // Spawn: queued when the call returns (the documented shape), then the
    // fake answers the task and the agent settles, unread.
    var r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=Say hello\nand more", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("a1", str(r.json, "agent"));
    try testing.expectEqualStrings("queued", str(r.json, "state"));
    try testing.expectEqualStrings("Say hello", str(r.json, "title"));
    try testing.expectEqualStrings("fake", str(r.json, "harness"));
    try testing.expectEqualStrings(d.work, str(r.json, "workspace"));
    try testing.expectEqualStrings(d.work, str(r.json, "cwd"));
    try testing.expectEqual(@as(usize, 0), r.json.object.get("worktrees").?.array.items.len);
    var shown = try d.waitState(a, "a1", "settled");
    try testing.expect(shown.object.get("unread").?.bool);
    try testing.expectEqual(@as(i64, 1), shown.object.get("turns").?.integer);
    const t = shown.object.get("transcript").?.array.items;
    try testing.expectEqualStrings("turn.started", str(t[0], "type"));
    try testing.expectEqualStrings("Done.", str(t[t.len - 2], "text"));
    try testing.expectEqualStrings("completed", str(t[t.len - 1], "reason"));

    // List: newest first.
    r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}/sub", .{d.work}), "--task=second", "--harness=fake", "--title=Two" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("a2", str(r.json, "agent"));
    _ = try d.waitState(a, "a2", "settled");
    r = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const listed = r.json.object.get("agents").?.array.items;
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("a2", str(listed[0], "agent"));
    try testing.expectEqualStrings("Two", str(listed[0], "title"));
    try testing.expectEqualStrings("a1", str(listed[1], "agent"));

    // Send a slow turn, then stop it: interrupted, settled.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=slow work" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "running");
    r = try d.run(a, &.{ "agent", "stop", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    shown = try d.waitState(a, "a1", "settled");
    const t2 = shown.object.get("transcript").?.array.items;
    try testing.expectEqualStrings("interrupted", str(t2[t2.len - 1], "reason"));
    // Stopping a settled agent is a no-op success.
    r = try d.run(a, &.{ "agent", "stop", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", str(r.json, "state"));

    // Archive: hidden from the list unless asked; transcript kept.
    r = try d.run(a, &.{ "agent", "archive", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("archived", str(r.json, "state"));
    r = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(usize, 1), r.json.object.get("agents").?.array.items.len);
    r = try d.run(a, &.{ "agent", "list", "--archived=true" });
    try testing.expectEqual(@as(usize, 2), r.json.object.get("agents").?.array.items.len);
    shown = try d.waitState(a, "a1", "archived");
    try testing.expectEqual(@as(i64, 2), shown.object.get("turns").?.integer);

    // Illegal state change: exit 5.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=again" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.invalid_transition", errorCode(r.json));
    // Archiving an archived agent is a no-op success.
    r = try d.run(a, &.{ "agent", "archive", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);

    // Unknown agent: exit 3 for every verb that names one.
    for ([_][]const []const u8{
        &.{ "agent", "show", "--agent=a99" },
        &.{ "agent", "send", "--agent=a99", "--text=hi" },
        &.{ "agent", "stop", "--agent=a99" },
        &.{ "agent", "archive", "--agent=a99" },
    }) |args| {
        r = try d.run(a, args);
        try testing.expectEqual(@as(u8, 3), r.status);
        try testing.expectEqualStrings("not_found.agent", errorCode(r.json));
    }

    // Spawn errors: bad folder (2 / 3), harness without an adapter (6). The
    // default harness (agents.default = claude_code) is disabled in this test.
    r = try d.run(a, &.{ "agent", "spawn", "--cwd=relative/dir", "--task=x", "--harness=fake" });
    try testing.expectEqual(@as(u8, 2), r.status);
    try testing.expectEqualStrings("invalid_params.cwd", errorCode(r.json));
    r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}/missing", .{d.work}), "--task=x", "--harness=fake" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.cwd", errorCode(r.json));
    r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=x" });
    try testing.expectEqual(@as(u8, 6), r.status);
    try testing.expectEqualStrings("unavailable.harness_not_found", errorCode(r.json));
    r = try d.run(a, &.{ "agent", "spawn", cwd, "--task= ", "--harness=fake" });
    try testing.expectEqual(@as(u8, 2), r.status);
    // None of the failed spawns created an agent.
    r = try d.run(a, &.{ "agent", "list", "--archived=true" });
    try testing.expectEqual(@as(usize, 2), r.json.object.get("agents").?.array.items.len);
}

test "agent show --tools and agent tool: the calls, with their bodies; plain show has none" {
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});
    var r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=Say hello", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const plain = try d.waitState(a, "a1", "settled");
    for (plain.object.get("transcript").?.array.items) |item| try testing.expect(!std.mem.startsWith(u8, str(item, "type"), "tool."));
    // The prompt is in the transcript.
    try testing.expectEqualStrings("turn.prompt", str(plain.object.get("transcript").?.array.items[1], "type"));
    try testing.expectEqualStrings("Say hello", str(plain.object.get("transcript").?.array.items[1], "text"));

    r = try d.run(a, &.{ "agent", "show", "--agent=a1", "--tools=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    var started: ?Value = null;
    var ended: ?Value = null;
    for (r.json.object.get("transcript").?.array.items) |item| {
        if (std.mem.eql(u8, str(item, "type"), "tool.started")) started = item;
        if (std.mem.eql(u8, str(item, "type"), "tool.ended")) ended = item;
    }
    try testing.expectEqualStrings("c1", str(started.?, "call"));
    try testing.expectEqualStrings("exec", str(started.?, "kind"));
    try testing.expectEqualStrings("Bash", str(started.?, "name"));
    try testing.expectEqualStrings("ls", str(started.?, "title"));
    try testing.expect(started.?.object.get("at").?.integer > 0);
    try testing.expectEqualStrings("ok", str(ended.?, "status"));
    try testing.expectEqual(@as(i64, 0), ended.?.object.get("exit").?.integer);

    r = try d.run(a, &.{ "agent", "tool", "--agent=a1", "--call=c1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("ok", str(r.json, "status"));
    try testing.expectEqualStrings("ls", str(r.json, "title"));
    try testing.expectEqualStrings("t1", str(r.json, "turn"));
    // The harness's own input, for `J`.
    const raw = r.json.object.get("raw_input").?;
    try testing.expectEqualStrings("{\"command\":\"ls\",\"timeout\":5}", str(raw, "text"));
    try testing.expect(!raw.object.get("truncated").?.bool);

    r = try d.run(a, &.{ "agent", "tool", "--agent=a1", "--call=c9" });
    try testing.expect(r.status != 0);
    r = try d.run(a, &.{ "agent", "tool", "--agent=a9", "--call=c1" });
    try testing.expect(r.status != 0);
}

test "transcript records: bodies are cut per call and in all, newest first, on a UTF-8 boundary" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var x: eventlog.decider.Agent = undefined;
    x.transcript = .empty;
    const big = try a.alloc(u8, agents_mod.show_body_max + 1);
    @memset(big, 'x');
    big[agents_mod.show_body_max - 1] = 0xC3;
    big[agents_mod.show_body_max] = 0xA9;
    const n = agents_mod.show_bodies_max / agents_mod.show_body_max + 2;
    for (0..n) |i| {
        const call = try std.fmt.allocPrint(a, "c{d}", .{i});
        try x.transcript.append(a, .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = call, .kind = "exec", .name = "Bash" } });
        try x.transcript.append(a, .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = call, .status = "ok", .body = .{ .text = big, .bytes = big.len } } });
    }
    const plain = try agents_mod.transcriptRecords(a, "a1", &x, null, false);
    try testing.expectEqual(@as(usize, 0), plain.len);
    const records = try agents_mod.transcriptRecords(a, "a1", &x, null, true);
    var total: usize = 0;
    for (records) |r| if (r.body) |b| {
        total += b.text.len;
        try testing.expect(b.truncated and b.bytes == big.len);
        try testing.expect(std.unicode.utf8ValidateSlice(b.text));
    };
    try testing.expect(total <= agents_mod.show_bodies_max);
    // The newest keeps its text; the oldest has run out of budget.
    try testing.expectEqual(agents_mod.show_body_max - 1, records[records.len - 1].body.?.text.len);
    try testing.expectEqual(@as(usize, 0), records[1].body.?.text.len);
}

test "transcript records: a failed call's long body keeps its head and its tail" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var x: eventlog.decider.Agent = undefined;
    x.transcript = .empty;
    const big = try a.alloc(u8, agents_mod.show_body_max * 3);
    @memset(big, 'x');
    @memcpy(big[0..5], "start");
    @memcpy(big[big.len - 5 ..], "error");
    try x.transcript.append(a, .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash" } });
    try x.transcript.append(a, .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .status = "error", .exit = 2, .body = .{ .text = big, .bytes = big.len } } });
    try x.transcript.append(a, .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c2", .kind = "exec", .name = "Bash" } });
    try x.transcript.append(a, .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c2", .status = "ok", .body = .{ .text = big, .bytes = big.len } } });
    const records = try agents_mod.transcriptRecords(a, "a1", &x, null, true);
    const failed = records[1].body.?;
    try testing.expect(std.mem.startsWith(u8, failed.text, "start") and std.mem.endsWith(u8, failed.text, "error"));
    try testing.expect(failed.truncated and failed.text.len <= agents_mod.show_body_max);
    const ok = records[3].body.?;
    try testing.expect(std.mem.startsWith(u8, ok.text, "start") and !std.mem.endsWith(u8, ok.text, "error"));
}

/// A response's size of `value`, as the proto layer encodes it.
fn jsonLen(a: std.mem.Allocator, value: anytype) !usize {
    return (try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false })).len;
}

test "transcript window: the pages cover every record once, each fits its room, whatever the text escapes to" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var x: eventlog.decider.Agent = undefined;
    x.transcript = .empty;
    // Control characters take six bytes each in JSON: the source's size says
    // little about the response's.
    const escapes = try a.alloc(u8, 16 * 1024);
    @memset(escapes, 0x01);
    const plain = try a.alloc(u8, 16 * 1024);
    @memset(plain, 'x');
    const n = 200;
    for (0..n) |i| {
        const t = try std.fmt.allocPrint(a, "t{d}", .{i});
        try x.transcript.append(a, .{ .text = .{ .agent = "a1", .turn = t, .message = "m", .text = if (i % 2 == 0) escapes else plain } });
        // Usage shares the transcript and is no record: its position still counts.
        try x.transcript.append(a, .{ .usage = .{ .agent = "a1", .turn = t } });
    }
    const total = x.transcript.items.len;
    const room = 128 * 1024;

    // Back from the tail, by `before`.
    var seen: usize = 0;
    var at: u64 = std.math.maxInt(u53);
    var pages: usize = 0;
    var last_turn: ?usize = null;
    while (at > 0) : (pages += 1) {
        const w = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .before = at }, room);
        try testing.expect(try jsonLen(a, w.records) <= room);
        try testing.expect(w.records.len > 0);
        try testing.expectEqual(total, w.total);
        try testing.expect(w.end == @min(at, total));
        // Newest page first, each record once and whole.
        for (0..w.records.len) |k| {
            const r = w.records[w.records.len - 1 - k];
            const turn = try std.fmt.parseInt(usize, r.turn[1..], 10);
            if (last_turn) |l| try testing.expectEqual(l - 1, turn) else try testing.expectEqual(@as(usize, n - 1), turn);
            last_turn = turn;
            try testing.expectEqual(escapes.len, r.text.?.len);
            seen += 1;
        }
        at = w.start;
    }
    try testing.expectEqual(@as(usize, n), seen);
    try testing.expect(pages > 5);

    // Forward from the start, by `since`, ending where it says.
    seen = 0;
    var from: u64 = 0;
    while (from < total) {
        const w = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .since = from }, room);
        try testing.expect(try jsonLen(a, w.records) <= room);
        try testing.expectEqual(from, w.start);
        try testing.expect(w.end > w.start);
        for (w.records) |r| {
            try testing.expectEqual(seen, try std.fmt.parseInt(usize, r.turn[1..], 10));
            seen += 1;
        }
        from = w.end;
    }
    try testing.expectEqual(@as(usize, n), seen);

    // Nothing new, and a position past the end, are empty answers.
    const none = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .since = total }, room);
    try testing.expectEqual(@as(usize, 0), none.records.len);
    try testing.expectEqual(total, none.start);
    const past = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .since = total + 5 }, room);
    try testing.expectEqual(total, past.end);

    // No parameters: the tail that fits, with the position it starts from.
    const tail = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .tail, room);
    try testing.expect(try jsonLen(a, tail.records) <= room);
    try testing.expect(tail.start > 0 and tail.end == total);
    try testing.expect(tail.records.len > 0);
}

test "transcript window: a page ends where the body budget does; the plain tail leaves those bodies out" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var x: eventlog.decider.Agent = undefined;
    x.transcript = .empty;
    const big = try a.alloc(u8, agents_mod.show_body_max);
    @memset(big, 'x');
    const n = 2 * agents_mod.show_bodies_max / agents_mod.show_body_max;
    for (0..n) |i| {
        const call = try std.fmt.allocPrint(a, "c{d}", .{i});
        try x.transcript.append(a, .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = call, .kind = "exec", .name = "Bash" } });
        try x.transcript.append(a, .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = call, .status = "ok", .body = .{ .text = big, .bytes = big.len } } });
    }
    const paged = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .before = x.transcript.items.len }, 1024 * 1024);
    try testing.expect(paged.start > 0);
    for (paged.records) |r| if (r.body) |b| try testing.expectEqual(big.len, b.text.len);
    const plain = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .tail, 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), plain.start);
    try testing.expectEqual(@as(usize, 0), plain.records[1].body.?.text.len);
    try testing.expect(plain.records[1].body.?.truncated);
}

test "transcript window: a record too big for a response comes cut, so the reader still moves on" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var x: eventlog.decider.Agent = undefined;
    x.transcript = .empty;
    const huge = try a.alloc(u8, 3 * 1024 * 1024);
    @memset(huge, '"');
    const room = 64 * 1024;
    try x.transcript.append(a, .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m", .text = "before" } });
    try x.transcript.append(a, .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m", .text = huge } });
    try x.transcript.append(a, .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = huge, .args = .{ .command = huge } } });
    try x.transcript.append(a, .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m", .text = "after" } });

    const first = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .since = 0 }, room);
    // Stops before a record it could carry whole on another page.
    try testing.expectEqual(@as(usize, 1), first.end);
    const cut = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .since = 1 }, room);
    try testing.expectEqual(@as(usize, 2), cut.end);
    try testing.expect(try jsonLen(a, cut.records) <= room);
    try testing.expect(std.mem.endsWith(u8, cut.records[0].text.?, "…"));
    try testing.expect(cut.records[0].text.?.len > 1024);
    const tool = try agents_mod.transcriptWindow(a, "a1", &x, null, true, .{ .since = 2 }, room);
    try testing.expectEqual(@as(usize, 3), tool.end);
    try testing.expect(try jsonLen(a, tool.records) <= room);
    try testing.expectEqualStrings("c1", tool.records[0].call.?);
    try testing.expect(tool.records[0].title.?.len < huge.len and tool.records[0].args.?.command.?.len < huge.len);
}

test "agent show: what surrounds the transcript fits too: requests and child prompts are cut to their room" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, 64 * 1024);
    @memset(big, '\n');
    const room = 128 * 1024;
    var prompts: [100]agents_mod.Show.ChildPrompt = undefined;
    for (&prompts, 0..) |*p, i| p.* = .{ .child = try std.fmt.allocPrint(a, "c{d}", .{i}), .text = big, .at = @intCast(i) };
    const kept = try agents_mod.fitChildPrompts(a, &prompts, room);
    try testing.expect(try jsonLen(a, kept) <= room);
    try testing.expect(kept.len > 0 and kept.len < prompts.len);
    // The newest, oldest first.
    try testing.expectEqualStrings("c99", kept[kept.len - 1].child);
    try testing.expectEqual(prompts.len, (try agents_mod.fitChildPrompts(a, prompts[0..0], room)).len + prompts.len);

    var x: eventlog.decider.Agent = undefined;
    x.requests = .empty;
    for (0..20) |i| try x.requests.append(a, .{ .request = try std.fmt.allocPrint(a, "r{d}", .{i}), .kind = "question", .reason = big });
    const requests = try agents_mod.fitRequests(a, &x, room);
    // Every request is listed (a big one never hides a later one); those
    // past the room are bare, a few hundred bytes each over it at most.
    try testing.expectEqual(@as(usize, 20), requests.len);
    try testing.expect(try jsonLen(a, requests) <= room + 20 * 200);
    try testing.expectEqualStrings("r0", requests[0].request);
    try testing.expect(std.mem.endsWith(u8, requests[0].reason, "…"));
    try testing.expectEqualStrings("", requests[19].reason);
    try testing.expectEqual(@as(usize, 20), agents_mod.requestsOmitted(&x, requests));
}

test "agent show: a request too big for its room loses its options, then its reason, but is never left out" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const labels = try a.alloc([]const u8, 16);
    const long = try a.alloc(u8, 200);
    @memset(long, 'x');
    @memset(labels, long);
    const opts: []const eventlog.events.QuestionOptions = &.{.{ .id = "q1", .question = "Q?", .labels = labels }};
    var x: eventlog.decider.Agent = undefined;
    x.requests = .empty;
    try x.requests.append(a, .{ .request = "r1", .kind = "question", .reason = "Q?", .options = opts });
    try x.requests.append(a, .{ .request = "r2", .kind = "approval", .reason = "Bash ls", .call = "c9" });
    // Room for r2 and the bare r1, not for r1's options.
    const requests = try agents_mod.fitRequests(a, &x, 1000);
    try testing.expectEqual(@as(usize, 2), requests.len);
    try testing.expectEqual(@as(usize, 0), requests[0].options.len);
    try testing.expectEqualStrings("Q?", requests[0].reason);
    try testing.expectEqualStrings("r2", requests[1].request);
    try testing.expectEqual(@as(usize, 1), agents_mod.requestsOmitted(&x, requests));
    // With room, the options stay and nothing is omitted.
    const roomy = try agents_mod.fitRequests(a, &x, 64 * 1024);
    try testing.expectEqual(@as(usize, 1), roomy[0].options.len);
    try testing.expectEqual(@as(usize, 0), agents_mod.requestsOmitted(&x, roomy));
    // Room for nothing: every request is still there, as its id, kind and
    // call, so an approval behind a big question is not hidden.
    const none = try agents_mod.fitRequests(a, &x, 0);
    try testing.expectEqual(@as(usize, 2), none.len);
    try testing.expectEqualStrings("r2", none[1].request);
    try testing.expectEqualStrings("c9", none[1].call.?);
    try testing.expectEqualStrings("", none[1].reason);
    try testing.expectEqual(@as(usize, 2), agents_mod.requestsOmitted(&x, none));
}

test "agent show --since and --before: only that part of the transcript; both is refused" {
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Say hello", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const all = try d.waitState(a, "a1", "settled");
    const total = all.object.get("transcript_total").?.integer;
    try testing.expectEqual(@as(i64, 0), all.object.get("transcript_start").?.integer);
    try testing.expectEqual(total, all.object.get("transcript_end").?.integer);
    try testing.expect(total >= 2);
    // The plain read has what it always had.
    try testing.expect(all.object.get("child_prompts") != null);

    r = try d.run(a, &.{ "agent", "show", "--agent=a1", "--tools=true", try std.fmt.allocPrint(a, "--since={d}", .{total}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 0), r.json.object.get("transcript").?.array.items.len);
    try testing.expectEqual(total, r.json.object.get("transcript_start").?.integer);
    // A paged read leaves out what a refresh would only repeat.
    try testing.expect(r.json.object.get("child_prompts") == null);
    try testing.expectEqual(@as(usize, 0), r.json.object.get("tails").?.array.items.len);

    r = try d.run(a, &.{ "agent", "show", "--agent=a1", "--before=1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(i64, 0), r.json.object.get("transcript_start").?.integer);
    try testing.expectEqual(@as(i64, 1), r.json.object.get("transcript_end").?.integer);
    try testing.expectEqualStrings("turn.started", str(r.json.object.get("transcript").?.array.items[0], "type"));

    r = try d.run(a, &.{ "agent", "show", "--agent=a1", "--since=1", "--before=1" });
    try testing.expect(r.status != 0);
    const refused = try std.json.Stringify.valueAlloc(a, r.json, .{});
    try testing.expect(std.mem.indexOf(u8, refused, "invalid_params.since") != null);
}

test "agent verbs: archive of a running agent stops it first; a workspace owns agents spawned inside it" {
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}", .{d.work}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    const sub = try std.fmt.allocPrint(a, "{s}/sub", .{d.work});
    r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{sub}), "--task=slow start", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings(d.work, str(r.json, "workspace"));
    try testing.expectEqualStrings(sub, str(r.json, "cwd"));
    const shown = try d.waitState(a, "a1", "running");
    try testing.expectEqualStrings(sub, str(shown, "cwd"));
    r = try d.run(a, &.{ "agent", "archive", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    // Two logged transitions: running → settled → archived.
    _ = try d.waitState(a, "a1", "archived");
}

/// Runs `venom mcp` (the generated MCP adapter) on `input` until EOF.
fn mcpSession(d: *Daemon, a: std.mem.Allocator, input: []const u8) ![]Value {
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try testing.expectEqual(@as(isize, @intCast(input.len)), c.write(fds[1], input.ptr, input.len));
    _ = c.close(fds[1]);
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(ta);
    defer err.deinit();
    const status = try main.App.run(ta, &.{ "mcp", try std.fmt.allocPrint(a, "--socket={s}", .{d.socket}) }, .{ .stdout = &out.writer, .stderr = &err.writer, .stdin = fds[0], .local = main.noView() });
    try testing.expectEqual(@as(u8, 0), status);
    var list: std.ArrayList(Value) = .empty;
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| if (line.len > 0) try list.append(a, try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{}));
    return list.items;
}

/// One `tools/call`; returns the response for id 2.
pub fn mcpCall(d: *Daemon, a: std.mem.Allocator, tool: []const u8, arguments: anytype) !Value {
    const call = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 2, .method = "tools/call", .params = .{ .name = tool, .arguments = arguments } }, .{});
    const input = try std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"2025-06-18","capabilities":{{}},"clientInfo":{{"name":"t","version":"0"}}}}}}
        \\{{"jsonrpc":"2.0","method":"notifications/initialized"}}
        \\{s}
        \\
    , .{call});
    for (try mcpSession(d, a, input)) |v| {
        const id = v.object.get("id") orelse continue;
        if (id == .integer and id.integer == 2) return v.object.get("result").?;
    }
    return error.NoResponse;
}

pub fn mcpResult(v: Value) !Value {
    if (v.object.get("isError")) |e| if (e.bool) {
        std.debug.print("tool error: {s}\n", .{v.object.get("content").?.array.items[0].object.get("text").?.string});
        return error.TestUnexpectedResult;
    };
    return v.object.get("structuredContent").?.object.get("result").?;
}

fn mcpError(a: std.mem.Allocator, v: Value) ![]const u8 {
    try testing.expect(v.object.get("isError").?.bool);
    const text = v.object.get("content").?.array.items[0].object.get("text").?.string;
    return errorCode(try std.json.parseFromSliceLeaky(Value, a, text, .{}));
}

test "agent verbs: spawn → send → stop → archive through the MCP server" {
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try mcpResult(try mcpCall(&d, a, "agent_dspawn", .{ .cwd = d.work, .task = "hello", .harness = "fake" }));
    try testing.expectEqualStrings("a1", str(r, "agent"));
    try testing.expectEqualStrings("queued", str(r, "state"));
    _ = try d.waitState(a, "a1", "settled");
    r = try mcpResult(try mcpCall(&d, a, "agent_dsend", .{ .agent = "a1", .text = "slow one" }));
    try testing.expectEqualStrings("a1", str(r, "agent"));
    _ = try d.waitState(a, "a1", "running");
    _ = try mcpResult(try mcpCall(&d, a, "agent_dstop", .{ .agent = "a1" }));
    _ = try d.waitState(a, "a1", "settled");
    r = try mcpResult(try mcpCall(&d, a, "agent_darchive", .{ .agent = "a1" }));
    try testing.expectEqualStrings("archived", str(r, "state"));
    r = try mcpResult(try mcpCall(&d, a, "agent_dlist", .{ .archived = true }));
    try testing.expectEqual(@as(usize, 1), r.object.get("agents").?.array.items.len);
    r = try mcpResult(try mcpCall(&d, a, "agent_dshow", .{ .agent = "a1" }));
    try testing.expectEqualStrings("archived", str(r, "state"));

    try testing.expectEqualStrings("not_found.agent", try mcpError(a, try mcpCall(&d, a, "agent_dshow", .{ .agent = "a9" })));
    try testing.expectEqualStrings("conflict.invalid_transition", try mcpError(a, try mcpCall(&d, a, "agent_dsend", .{ .agent = "a1", .text = "again" })));
}

/// What `onReactor` reports of an agent's fork.
const ForkProbe = struct {
    job: Daemon.Job = .{ .run = run },
    agent: []const u8,
    /// Set: read that effect (none: only the binding); else ask for a fork
    /// and put its key here.
    key: ?[]const u8 = null,
    arena: std.mem.Allocator,
    other: ?[]const u8 = null,
    done: bool = false,
    ok: bool = false,
    detail: []const u8 = "",
    other_done: bool = false,
    process: bool = false,
    status: harness.host.Status = .idle,

    fn run(job: *Daemon.Job, d: *Daemon) anyerror!void {
        const self: *ForkProbe = @alignCast(@fieldParentPtr("job", job));
        const host = &d.runner.host;
        const key = self.key orelse {
            self.key = try host.fork(self.arena, self.agent, null);
            return;
        };
        if (d.engine.state.effects.get(key)) |effect| {
            self.done = effect.done;
            self.ok = effect.ok;
            self.detail = try self.arena.dupe(u8, effect.detail);
        }
        if (self.other) |o| self.other_done = d.engine.state.effects.get(o).?.done;
        const b = host.binding(self.agent).?;
        self.process = b.running();
        self.status = b.status;
    }
};

fn probeFork(d: *Daemon, a: std.mem.Allocator, agent: []const u8, key: ?[]const u8, other: ?[]const u8) !ForkProbe {
    var p: ForkProbe = .{ .agent = agent, .key = key, .arena = a, .other = other };
    try d.onReactor(&p.job);
    return p;
}

/// A file the fake app-server appends what it reads to, until it holds `text`.
fn waitFile(d: *Daemon, a: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while (std.mem.indexOf(u8, std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20)) catch "", text) == null) {
        if (d.failed.load(.acquire)) return error.ServeLoopFailed;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        var ts: c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
}

/// A daemon with a Codex adapter on the fake app-server replaying `trace`.
const CodexDaemon = struct {
    d: Daemon,
    cx: harness.codex.Codex,
    tmp: testing.TmpDir,
    dir: []const u8,

    fn init(self: *CodexDaemon, a: std.mem.Allocator, trace: []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "server.py", .data = @embedFile("harness/testdata/codex_app_server.py") });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "trace", .data = trace });
        self.cx = .init(ta);
        errdefer self.cx.deinit();
        self.cx.argv = try a.dupe([]const u8, &.{ "python3", try std.fmt.allocPrint(a, "{s}/server.py", .{self.dir}), try std.fmt.allocPrint(a, "{s}/trace", .{self.dir}), self.dir, self.dir });
        try self.d.initWith(.{ .extra = &.{.{ .harness = harness.codex.name, .adapter = self.cx.adapter() }} });
    }

    fn deinit(self: *CodexDaemon) void {
        self.d.deinit();
        self.cx.deinit();
        self.tmp.cleanup();
    }

    fn received(self: *CodexDaemon, a: std.mem.Allocator, n: u32) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}/received.{d}.jsonl", .{ self.dir, n });
    }
};

const release_job = struct {
    fn run(_: *Daemon.Job, d: *Daemon) anyerror!void {
        _ = try d.runner.host.release("a1");
    }
};

/// Spawns `a1` on Codex; it runs its task, and its process is released.
fn idleCodexAgent(t: *CodexDaemon, a: std.mem.Allocator) !void {
    const r = try t.d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{t.d.work}), "--task=one", "--harness=codex" });
    if (r.status != 0) std.debug.print("spawn failed: {f}\n", .{std.json.fmt(r.json, .{})});
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try t.d.waitState(a, "a1", "settled");
    var job: Daemon.Job = .{ .run = release_job.run };
    try t.d.onReactor(&job);
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while ((try probeFork(&t.d, a, "a1", "", null)).process) {
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
}

const codex_first_process =
    \\> {"method":"initialize","id":0}
    \\< {"id":0,"result":{"userAgent":"codex_cli_rs/0.167.0"}}
    \\> {"method":"initialized"}
    \\> {"method":"thread/start","id":1}
    \\< {"id":1,"result":{"thread":{"id":"thr_f"},"model":"gpt-5.5-codex"}}
    \\> {"method":"account/read","id":90}
    \\> {"method":"account/rateLimits/read","id":91}
    \\> {"method":"turn/start","id":2}
    \\< {"method":"turn/started","params":{"threadId":"thr_f","turn":{"id":"turn_a","status":"inProgress","items":[]}}}
    \\< {"method":"turn/completed","params":{"threadId":"thr_f","turn":{"id":"turn_a","status":"completed","error":null,"items":[]}}}
    \\
;
const codex_fork_process =
    \\=== process
    \\> {"method":"initialize","id":0}
    \\< {"id":0,"result":{"userAgent":"codex_cli_rs/0.167.0"}}
    \\> {"method":"initialized"}
    \\> {"method":"thread/resume","id":1,"params":{"threadId":"thr_f"}}
    \\< {"id":1,"result":{"thread":{"id":"thr_f"},"model":"gpt-5.5-codex"}}
    \\> {"method":"account/read","id":90}
    \\> {"method":"account/rateLimits/read","id":91}
    \\> {"method":"thread/fork","id":2,"params":{"threadId":"thr_f"}}
    \\
;

test "fork: client verbs and outbox effects go on during a fork the harness does not answer" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: CodexDaemon = undefined;
    try t.init(a, codex_first_process ++ codex_fork_process ++
        \\? gate answer
        \\< {"id":2,"result":{"thread":{"id":"thr_new"}}}
        \\> {"method":"thread/unsubscribe","id":3,"params":{"threadId":"thr_new"}}
    );
    defer t.deinit();
    const d = &t.d;
    try idleCodexAgent(&t, a);

    // A second agent, whose stop is a `harness.stop` effect.
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=slow work", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "running");

    // The fork reaches the harness, which holds its answer until the gate opens.
    const key = (try probeFork(d, a, "a1", null, null)).key.?;
    try waitFile(d, a, try t.received(a, 1), "thread/fork");
    var p = try probeFork(d, a, "a1", key, null);
    try testing.expect(!p.done and p.process);

    // A client verb answers, and its effect runs and completes, meanwhile:
    // the reactor would not get to either if the fork held it.
    r = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 2), r.json.object.get("agents").?.array.items.len);
    r = try d.run(a, &.{ "agent", "stop", "--agent=a2" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "settled");
    p = try probeFork(d, a, "a1", key, "stop:a2:t1");
    try testing.expect(p.other_done);
    try testing.expect(!p.done and p.process);

    // The answer completes the effect, and the process started for this idle
    // agent is ended afterwards, not restarted.
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "answer", .data = "" });
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while (true) {
        p = try probeFork(d, a, "a1", key, null);
        if (p.done and !p.process) break;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    try testing.expect(p.ok);
    try testing.expectEqualStrings("thr_new", p.detail);
    try testing.expectEqual(harness.host.Status.idle, p.status);
    const shown = try d.waitState(a, "a1", "settled");
    try testing.expectEqual(@as(i64, 1), shown.object.get("turns").?.integer);
}

test "fork: a daemon that stops mid-fork forks again after the restart" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: CodexDaemon = undefined;
    // The first fork's process never answers; the restart's does.
    try t.init(a, codex_first_process ++ codex_fork_process ++ codex_fork_process ++
        \\< {"id":2,"result":{"thread":{"id":"thr_again"}}}
        \\> {"method":"thread/unsubscribe","id":3,"params":{"threadId":"thr_again"}}
    );
    defer t.deinit();
    const d = &t.d;
    try idleCodexAgent(&t, a);
    const key = (try probeFork(d, a, "a1", null, null)).key.?;
    try waitFile(d, a, try t.received(a, 1), "thread/fork");

    try d.restart();
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    var p: ForkProbe = undefined;
    while (true) {
        p = try probeFork(d, a, "a1", key, null);
        if (p.done and !p.process) break;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    try testing.expect(p.ok);
    try testing.expectEqualStrings("thr_again", p.detail);
}
