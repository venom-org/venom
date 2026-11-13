//! `venom serve`'s harness wiring, with the fake
//! harness as a real child process: the serve loop answers queued
//! `harness.respond` effects through the host, waits on harness output and
//! the socket together, and the stop path (what SIGTERM sets) shuts every
//! harness process down cleanly. Leak-checked; every test checks the
//! harness pids are gone.
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
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;

const model = @import("cli").manifest.normalize(main.input);

const approval_then_long =
    \\{"turns":[{"match":"long","steps":[{"text":"thinking"},{"sleep_ms":20000}]},
    \\          {"match":"","steps":[
    \\  {"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build test"}},
    \\  {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build test?"}},
    \\  {"tool_end":{"id":"tu1","status":"ok","exit":0,"ms":12}},
    \\  {"text":"All tests pass."}]}]}
;

/// Answers every product verb; they are not under test here.
const Stub = struct {
    pub fn call(_: *Stub, call_: *proto.Call) anyerror!void {
        try call_.ok(.{});
    }
};

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    arena: std.heap.ArenaAllocator,
    exe: [std.fs.max_path_bytes:0]u8,
    fake: harness.Fake,
    adapters: [1]harness.host.Registered,
    logger: log.Logger,
    events: proto.events.Log,
    store: config.Store,
    registry: proto.grants.Registry,
    engine: eventlog.Engine,
    runner: harnesses.Runner,
    dispatcher: proto.Dispatcher,
    server: proto.Server,
    loop: main.ServeLoop,
    pids: std.ArrayList(c.pid_t),
    stub: Stub,

    /// Built in the order `Daemon.serve` builds the same parts.
    fn init(self: *Fixture, script: []const u8) !void {
        self.pids = .empty;
        self.stub = .{};
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", ta);
        errdefer ta.free(self.dir);
        self.arena = .init(ta);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const rel = try a.dupeSentinel(u8, build_options.fake_harness, 0);
        if (c.realpath(rel, &self.exe) == null) return error.FakeHarnessMissing;
        self.fake = .{ .exe = std.mem.sliceTo(&self.exe, 0), .script = script, .state_dir = self.dir };
        self.adapters = .{.{ .harness = harness.fake.name, .adapter = self.fake.adapter() }};
        self.logger = log.Logger.init(.{ .source = main.tool });
        errdefer self.logger.deinit();
        self.events = try proto.events.Log.init(ta, main.tool, .{}, null);
        errdefer self.events.deinit();
        self.events.catalog = &eventlog.catalog.entries;
        // Vendor harnesses off: only the fake may run here.
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
        self.store = try config.Store.init(ta, .{ .io = testing.io, .path = try std.fmt.allocPrint(a, "{s}/config.zon", .{self.dir}), .validate = config.validate, .events = &self.events });
        errdefer self.store.deinit();
        self.registry = try proto.grants.Registry.init(ta, main.tool, .{});
        errdefer self.registry.deinit();
        self.engine = try eventlog.Engine.open(ta, try std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, eventlog.file_name }), .{ .events = &self.events });
        errdefer self.engine.deinit();
        try self.runner.init(ta, &self.engine, self.store.current().harness, &self.adapters, &self.logger);
        errdefer self.runner.deinit();
        self.engine.options.executors = self.runner.executors();
        try self.engine.start();
        // The product verbs are not under test here; one stub serves them.
        var bindings: [model.verbs.len]proto.Binding = undefined;
        inline for (model.verbs, &bindings) |v, *b| b.* = .{ .verb = v.name, .handler = proto.VerbHandler.init(&self.stub) };
        self.dispatcher = try proto.Dispatcher.init(ta, &model, &bindings, .{}, null);
        errdefer self.dispatcher.deinit();
        // The socket's directory must be private (0700).
        const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{self.dir}, 0);
        if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
        self.server = try proto.Server.init(ta, .{
            .hello = .{ .identity = .{ .name = main.tool, .version = "0.0.0" } },
            .path = .{ .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}) },
            .registry = &self.registry,
        }, self.dispatcher.handler());
        errdefer self.server.deinit();
        self.loop = .{ .gpa = ta, .io = testing.io, .server = &self.server, .dispatcher = &self.dispatcher, .events = &self.events, .config = &self.store, .registry = &self.registry, .logger = &self.logger, .engine = &self.engine, .harnesses = &self.runner };
        _ = try self.engine.submit(.{ .create = .{ .agent = "a1", .title = "Run the tests", .harness = harness.fake.name, .workspace = self.dir } });
    }

    fn deinit(self: *Fixture) void {
        self.loop.deinit();
        self.server.deinit();
        self.dispatcher.deinit();
        self.runner.deinit();
        for (self.pids.items) |pid| {
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("a harness process outlived venom serve");
        }
        self.pids.deinit(ta);
        self.engine.deinit();
        self.registry.deinit();
        self.store.deinit();
        self.events.deinit();
        self.logger.deinit();
        self.arena.deinit();
        ta.free(self.dir);
        self.tmp.cleanup();
    }

    fn agent(self: *Fixture) eventlog.decider.Agent {
        return self.engine.state.agents.get("a1").?;
    }

    /// Serve-loop turns until `done` or 10 s.
    fn until(self: *Fixture, comptime done: fn (*Fixture) bool) !void {
        const deadline = std.time.ms_per_s * 10 + @import("supervisor").monotonicMs();
        while (!done(self)) {
            if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
            try self.loop.step(50);
            self.notePid();
        }
    }
    fn notePid(self: *Fixture) void {
        const b = self.runner.host.binding("a1") orelse return;
        const p = b.process orelse return;
        for (self.pids.items) |pid| if (pid == p.pid()) return;
        self.pids.append(ta, p.pid()) catch @panic("oom");
    }
};

fn isState(comptime s: eventlog.agent.State) fn (*Fixture) bool {
    return struct {
        fn f(fx: *Fixture) bool {
            return fx.agent().state == s;
        }
    }.f;
}

test "venom serve: the serve loop answers harness.respond through the host and SIGTERM ends harness processes" {
    var fx: Fixture = undefined;
    try fx.init(approval_then_long);
    defer fx.deinit();

    // A turn that asks for approval: the answer is queued as an effect in the
    // same commit, and the serve loop's effect worker delivers it.
    try fx.runner.host.send("a1", "Run the tests", .turn);
    try fx.until(isState(.needs_you));
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try testing.expect(!fx.engine.state.effects.get("respond:a1:r1").?.done);
    try fx.until(isState(.settled));
    const effect = fx.engine.state.effects.get("respond:a1:r1").?;
    try testing.expect(effect.done and effect.ok);

    // A turn still running when the daemon is told to stop.
    try fx.runner.host.send("a1", "a long task", .turn);
    try fx.until(struct {
        fn f(x: *Fixture) bool {
            return x.agent().state == .running and x.agent().messages == 2;
        }
    }.f);
    const pid = fx.runner.host.binding("a1").?.process.?.pid();
    // What the SIGTERM handler does: set the flag `ServeLoop.serve` watches.
    var stopped: std.atomic.Value(bool) = .init(true);
    const started = @import("supervisor").monotonicMs();
    try fx.loop.serve(&stopped, try std.fmt.allocPrint(fx.arena.allocator(), "{s}/status.json", .{fx.dir}));
    // Interrupted within the grace period, not killed after it.
    try testing.expect(@import("supervisor").monotonicMs() - started < 5_000);
    try testing.expect(!fx.runner.host.binding("a1").?.running());
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    try testing.expectEqual(eventlog.agent.State.settled, fx.agent().state);
    const t = fx.agent().transcript.items;
    try testing.expectEqualStrings("interrupted", t[t.len - 1].turn_ended.reason);
    try testing.expectError(error.ShuttingDown, fx.runner.host.send("a1", "late", .turn));
}

test "venom serve: live harness.* keys reach the host; adapter keys wait for a restart" {
    var fx: Fixture = undefined;
    try fx.init("{}");
    defer fx.deinit();
    try testing.expectEqual(@as(u32, 5_000), fx.runner.host.options.shutdown_grace_ms);
    _ = try fx.store.set("harness.shutdown_grace", "\"2s\"");
    _ = try fx.store.set("harness.start_timeout", "\"1m\"");
    _ = try fx.store.set("harness.resume_prompt", "\"Go on.\"");
    _ = try fx.store.reload();
    try fx.loop.step(0);
    try testing.expectEqual(@as(u32, 2_000), fx.runner.host.options.shutdown_grace_ms);
    try testing.expectEqual(@as(u32, 60_000), fx.runner.host.options.start_timeout_ms);
    try testing.expectEqualStrings("Go on.", fx.runner.host.options.resume_prompt);
    // The supervision policy is not a config key and survives a reload.
    try testing.expectEqual(@as(?u32, 5), fx.runner.host.options.policy.max_failures);
}

test "venom doctor: harness.<h>.extra_args warns when it repeats an adapter flag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    // The known table's flags are filled in by each adapter; use the fake's.
    const table = [_]harnesses.Known{
        .{ .id = .claude_code, .name = "claude-code", .flags = &.{ "--session", "--script" } },
        .{ .id = .codex, .name = "codex", .flags = &.{"--session"} },
    };
    // Adapter keys are read at start, so the file is there first.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = ".{ .harness = .{ .claude_code = .{ .extra_args = .{ \"--verbose\", \"--script=x\" } }, .codex = .{ .extra_args = .{\"--verbose\"} } } }" });
    var store = try config.Store.init(ta, .{ .io = testing.io, .path = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir}), .validate = config.validate });
    defer store.deinit();
    var check: harnesses.ExtraArgsCheck = .{ .config = &store, .known = &table };
    var report: cli.doctor.Report = .{ .arena = a, .tool = main.tool };
    try check.run(&report);
    try testing.expectEqual(@as(usize, 2), report.results.items.len);
    const cc = report.results.items[0];
    try testing.expectEqualStrings("harness.claude_code.extra_args", cc.id);
    try testing.expectEqual(cli.doctor.Status.warn, cc.status);
    try testing.expect(std.mem.indexOf(u8, cc.message, "--script=x") != null);
    const cx = report.results.items[1];
    try testing.expectEqualStrings("harness.codex.extra_args", cx.id);
    try testing.expectEqual(cli.doctor.Status.ok, cx.status);
}
