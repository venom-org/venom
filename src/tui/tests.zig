//! Headless TUI tests: everything renders into a
//! venom-term Surface and is driven with key bytes; no test opens a TTY.
//!
//! - The main layout's snapshot against
//!   `testdata/main_view.txt`, from a fixed model.
//! - Keys turn into the right verb requests or local actions.
//! - Live: a real daemon (serve loop, engine, harness host with the fake
//!   harness only) on its own thread; the TUI renders from `events`,
//!   drives verbs with keys, and survives a daemon restart.
const std = @import("std");
const term = @import("venom-term");
const proto = @import("proto");
const log = @import("log");
const supervisor = @import("supervisor");
const build_options = @import("build_options");
const main = @import("../main.zig");
const config = @import("../config.zig");
const harnesses = @import("../harnesses.zig");
const eventlog = @import("../eventlog/root.zig");
const harness = @import("../harness/root.zig");
const Agents = @import("../agents.zig").Agents;
const Workspaces = @import("../workspaces.zig").Workspaces;
const Principals = @import("../principals.zig").Principals;
const cli = @import("cli");
const cfg = @import("cfg");
const scope = @import("../scope.zig");

/// venom's verbs plus `events` and the config verbs (the other shared
/// bundles are not served here).
const daemon_model = scope.extend(cfg.merge(cli.manifest.normalize(.{ .format = main.input.format, .tool = main.input.tool, .summary = main.input.summary, .verbs = main.input.verbs ++ .{eventlog.catalog.events_manifest} })));
const App = @import("app.zig").App;
const Link = @import("link.zig").Link;
const view = @import("view.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

/// All rows of `surface`, trailing blanks trimmed, one per line.
pub fn dump(a: std.mem.Allocator, surface: *const term.Surface) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..surface.height) |y| {
        const row = try term.widgets.text.rowText(a, surface, @intCast(y));
        try out.appendSlice(a, row);
        try out.append(a, '\n');
    }
    return out.items;
}

pub fn feedJson(app: *App, a: std.mem.Allocator, json: []const u8) !void {
    try app.onEvent(try std.json.parseFromSliceLeaky(Value, a, json, .{}));
}

/// The id and verb of each queued request, as `verb(agent)` strings.
pub fn sent(a: std.mem.Allocator, app: *App) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (app.outbox.items) |line| {
        const v = try std.json.parseFromSliceLeaky(Value, a, line, .{});
        const p = v.object.get("params").?.object;
        try out.print(a, "{s}({s}) ", .{ v.object.get("verb").?.string, if (p.get("agent")) |x| x.string else "" });
        ta.free(line);
    }
    app.outbox.clearRetainingCapacity();
    return out.items;
}

/// Answers the oldest pending request of `verb` with `ok` (any key
/// verb's: `agent.list`, `agent.show` and `inbox.list` are told apart).
pub fn answer(app: *App, a: std.mem.Allocator, verb: []const u8, ok: []const u8) !void {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| {
        const want: ?@typeInfo(@import("app.zig").Purpose).@"union".tag_type.? = if (std.mem.eql(u8, verb, "agent.list")) .list else if (std.mem.eql(u8, verb, "agent.show")) .show else if (std.mem.eql(u8, verb, "inbox.list")) .inbox else if (std.mem.eql(u8, verb, "agent.tool")) .tool else if (std.mem.eql(u8, verb, "config.get")) .config else null;
        if (want) |t| if (std.meta.activeTag(e.value_ptr.*) != t) continue;
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    }
    try app.onResponse(lowest.?, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, ok, .{}) });
}

/// Answers the oldest pending `config.get` of one setting.
pub fn answerConfig(app: *App, a: std.mem.Allocator, which: @FieldType(@import("app.zig").Purpose, "config"), ok: []const u8) !void {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| {
        if (e.value_ptr.* != .config or e.value_ptr.config != which) continue;
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    }
    try app.onResponse(lowest.?, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, ok, .{}) });
}

/// The main view's agents, as the daemon would send them.
pub const fixture_snapshot =
    \\{"seq":40,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"state.snapshot","data":{"reason":"initial","complete":true,"entities":[
    \\{"resource":"agent:a1","entity_type":"agent","content":"{\"agent\":\"a1\",\"title\":\"venom-echo conformance\",\"harness\":\"claude-code\",\"state\":\"needs_you\",\"unread\":false}"},
    \\{"resource":"agent:a1","entity_type":"attention","content":"{\"agent\":\"a1\",\"requests\":[{\"request\":\"r1\",\"kind\":\"approval\",\"reason\":\"approve: zig build test\",\"stale\":false}]}"},
    \\{"resource":"agent:a2","entity_type":"agent","content":"{\"agent\":\"a2\",\"title\":\"libghostty-vt spike\",\"harness\":\"opencode\",\"state\":\"failed\",\"unread\":false}"},
    \\{"resource":"agent:a3","entity_type":"agent","content":"{\"agent\":\"a3\",\"title\":\"theme module trve/bone\",\"harness\":\"claude-code\",\"state\":\"running\",\"unread\":false}"},
    \\{"resource":"agent:a4","entity_type":"agent","content":"{\"agent\":\"a4\",\"title\":\"cfg ZON schema verbs\",\"harness\":\"codex\",\"state\":\"settled\",\"unread\":true}"},
    \\{"resource":"agent:a5","entity_type":"agent","content":"{\"agent\":\"a5\",\"title\":\"old spike\",\"harness\":\"codex\",\"state\":\"archived\",\"unread\":false}"}]}}
;

pub const fixture_list =
    \\{"agents":[
    \\{"agent":"a1","title":"venom-echo conformance","harness":"claude-code","state":"needs_you","unread":false,"workspace":"/home/me/venom-org","cwd":"/home/me/venom-org/venom-std","created_at":1794061200000,"changed_at":1794061740000},
    \\{"agent":"a2","title":"libghostty-vt spike","harness":"opencode","state":"failed","unread":false,"workspace":"/home/me/venom-org","cwd":"/home/me/venom-org/venom-term","created_at":1794061200000,"changed_at":1794061080000},
    \\{"agent":"a3","title":"theme module trve/bone","harness":"claude-code","state":"running","unread":false,"workspace":"/home/me/venom-org","cwd":"/home/me/venom-org/venom-term","created_at":1794061200000,"changed_at":1794061620000},
    \\{"agent":"a4","title":"cfg ZON schema verbs","harness":"codex","state":"settled","unread":true,"workspace":"/home/me/venom-org","cwd":"/home/me/venom-org/venom-std","created_at":1794061200000,"changed_at":1794060480000},
    \\{"agent":"a5","title":"old spike","harness":"codex","state":"archived","unread":false,"workspace":"/home/me/scratch","cwd":"/home/me/scratch","created_at":1794000000000,"changed_at":1794000000000}]}
;

const fixture_show =
    \\{"agent":"a1","title":"venom-echo conformance","harness":"claude-code","state":"needs_you","unread":false,"workspace":"/home/me/venom-org","cwd":"/home/me/venom-org/venom-std","created_at":1794061200000,"changed_at":1794061740000,"turns":1,"open_turn":"t1","model":"opus 5.5","permission_mode":"ask","context":{"used":124000,"window":200000,"source":"estimate","at":1794061740000},"context_warn_at":80,"steer":"queue","interrupt":true,
    \\ "requests":[{"request":"r1","kind":"approval","reason":"Bash wants to run: zig build test -Dconformance","stale":false}],
    \\ "transcript":[{"type":"turn.started","turn":"t1"},{"type":"text","turn":"t1","text":"I'll read the contract test vectors first, then add a conformance build step."}]}
;

/// A model with those agents, rendered at 120×30.
pub fn fixtureApp(app: *App, a: std.mem.Allocator) !void {
    app.home = "/home/me";
    app.now_ms = 1794061800000; // 14:30, a minute after a1 asked
    try app.onConnected();
    try feedJson(app, a, fixture_snapshot);
    try answer(app, a, "agent.list", fixture_list);
    // Nothing selected yet: the first row (a1) is taken on the first draw.
    _ = try sent(a, app);
}

test "main view snapshot matches testdata/main_view.txt" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixtureApp(&app, a);
    // The bar's clock in UTC, whatever the machine's zone.
    app.utc_offset_override = 0;
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&app, &surface);
    try testing.expectEqualStrings("agent.show(a1) ", try sent(a, &app));
    try answer(&app, a, "agent.show", fixture_show);
    try view.render(&app, &surface);

    const got = try dump(a, &surface);
    const want = @embedFile("testdata/main_view.txt");
    if (!std.mem.eql(u8, want, got)) std.debug.print("main view:\n{s}\n", .{got});
    try testing.expectEqualStrings(want, got);

    // `▲ N need you` is warn and bold on the bar's ground while something
    // blocks; the needs-you glyph is warn, never colour alone.
    const bar_glyph = for (0..surface.width) |x| {
        const cell = surface.get(@intCast(x), 29).?;
        if (std.mem.eql(u8, cell.text, "▲")) break cell;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(app.chrome.theme.gold.ansi, bar_glyph.style.fg);
    try testing.expect(bar_glyph.style.bold and !bar_glyph.style.reverse);
    try testing.expectEqual(app.chrome.statusBar().bg, bar_glyph.style.bg);
    // The list's first agent: its glyph in warn, under the header, the
    // hairline, the filter row and the group's header.
    try testing.expectEqual(app.theme.warn.fg, surface.get(1, 4).?.style.fg);

    // At 80 columns the inspector goes; the status bar stays at the bottom.
    try surface.resize(80, 24);
    try view.render(&app, &surface);
    const small = try dump(a, &surface);
    var rows = std.mem.splitScalar(u8, small, '\n');
    var last: []const u8 = "";
    var n: usize = 0;
    while (rows.next()) |r| : (n += 1) if (n == 23) {
        last = r;
    };
    try testing.expect(std.mem.startsWith(u8, last, " venom ◤ ▸agents "));
    for ([_][]const u8{ " NORMAL ", "▲ 2 need you", "◆ 1 running" }) |part| try testing.expect(std.mem.indexOf(u8, last, part) != null);
    try testing.expect(std.mem.indexOf(u8, small, "│ AGENT") == null);
}

test "keys: every key is a verb request or a local action" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 100, 28);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&app, &surface);
    _ = try sent(a, &app);
    try answer(&app, a, "agent.show", fixture_show);

    // j moves to the next agent and fetches it; k comes back.
    _ = try app.feed("j");
    try testing.expectEqualStrings("a2", app.selected.items);
    try testing.expectEqualStrings("agent.show(a2) ", try sent(a, &app));
    _ = try app.feed("k");
    try testing.expectEqualStrings("a1", app.selected.items);
    // The stale answer for a2 is dropped; a1's show is queued after it.
    try answer(&app, a, "agent.show", fixture_show);
    try testing.expectEqualStrings("agent.show(a1) ", try sent(a, &app));
    try answer(&app, a, "agent.show", fixture_show);

    // S stops, x archives the selected agent.
    _ = try app.feed("S");
    try testing.expectEqualStrings("agent.stop(a1) ", try sent(a, &app));
    _ = try app.feed("x");
    try testing.expectEqualStrings("agent.archive(a1) ", try sent(a, &app));
    // A failed verb shows its code in the status bar.
    var it = app.pending.iterator();
    var stop_id: i64 = std.math.maxInt(i64);
    while (it.next()) |e| if (e.value_ptr.* == .action) {
        stop_id = @min(stop_id, e.key_ptr.*);
    };
    try app.onResponse(stop_id, .{ .@"error" = .{ .code = "conflict.agent_handed_over", .message = "", .data = null } });
    try view.render(&app, &surface);
    try testing.expect(std.mem.indexOf(u8, try dump(a, &surface), "agent stop: conflict.agent_handed_over") != null);

    // i focuses the input box (INPUT); typed keys are text, even `x`;
    // Enter sends the prompt with agent.send; Esc goes back.
    _ = try app.feed("i");
    _ = try app.feed("fix x");
    try testing.expectEqualStrings("", try sent(a, &app));
    try view.render(&app, &surface);
    const typing = try dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, typing, "› fix x") != null);
    try testing.expect(std.mem.indexOf(u8, typing, "│  INPUT") != null);
    _ = try app.feed("\r");
    const send_line = app.outbox.items[0];
    try testing.expect(std.mem.indexOf(u8, send_line, "\"text\":\"fix x\"") != null);
    try testing.expectEqualStrings("agent.send(a1) ", try sent(a, &app));
    _ = try app.feed("\x1b");
    try testing.expectEqual(@import("app.zig").Area.list, app.area());

    // Tab cycles areas; ? opens the help (drawn from the key table) and
    // any key closes it; `space i` opens the inbox.
    _ = try app.feed("\t");
    try testing.expectEqual(@import("app.zig").Area.transcript, app.area());
    _ = try app.feed("\x1b");
    _ = try app.feed("?");
    try view.render(&app, &surface);
    const help = try dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, help, "╭ Keys ") != null);
    try testing.expect(std.mem.indexOf(u8, help, "venom agent archive") != null);
    try testing.expect(std.mem.indexOf(u8, help, "│  NORMAL") != null);
    _ = try app.feed("x");
    try testing.expect(!app.help);
    try testing.expectEqualStrings("a1", app.selected.items);
    _ = try app.feed("jj");
    _ = try sent(a, &app);
    _ = try app.feed(" i"); // the inbox screen
    try testing.expectEqual(@import("app.zig").Screen.inbox, app.screen);
    try testing.expect(!app.quit);
    _ = try app.feed("q");
    try testing.expect(app.quit);
}

// ---- Live, against a real daemon ---------------------------------------

/// "ask" turns wait for an approval (the agent needs you); "slow" turns
/// run until interrupted; anything else answers at once.
const script =
    \\{"turns":[{"match":"ask","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build"}},{"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build?"}},{"text":"built"}]},
    \\          {"match":"slow","steps":[{"text":"working"},{"sleep_ms":20000}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

/// The daemon's process half: everything `venom serve` sets up, on its
/// own reactor thread. `start` again on the same directory is a restart:
/// the durable log is reopened and the events log gets a new epoch.
pub const Daemon = struct {
    dir: []const u8,
    socket: []const u8,
    /// The fake harness's script.
    script: []const u8 = script,
    /// `config.set` needs `admin`: only the settings tests hold it.
    config_admin: bool = false,
    exe: [std.fs.max_path_bytes:0]u8 = undefined,
    fake: harness.Fake = undefined,
    adapters: [1]harness.host.Registered = undefined,
    logger: log.Logger = undefined,
    events: proto.events.Log = undefined,
    store: config.Store = undefined,
    registry: proto.grants.Registry = undefined,
    engine: eventlog.Engine = undefined,
    runner: harnesses.Runner = undefined,
    harness_verbs: harnesses.Verbs = undefined,
    /// `tui.hold`: the TUI holds on every connect. Persistent here.
    holds: @import("../holds.zig").Holds = undefined,
    front: @import("../holds.zig").Front = undefined,
    agents: Agents = undefined,
    workspaces: Workspaces = undefined,
    scoped: scope.Config = undefined,
    principals: Principals = undefined,
    usage: main.Usage = undefined,
    context_verbs: main.ContextVerbs = undefined,
    inbox: main.Inbox = undefined,
    ws_add: Workspaces.Add = undefined,
    ws_remove: Workspaces.Remove = undefined,
    ws_scan: Workspaces.Scan = undefined,
    snapshots: eventlog.catalog.Snapshots = undefined,
    dispatcher: proto.Dispatcher = undefined,
    server: proto.Server = undefined,
    loop: main.ServeLoop = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    pids: std.ArrayList(c.pid_t) = .empty,
    paths: std.heap.ArenaAllocator = .init(ta),

    pub fn start(self: *Daemon) !void {
        const a = self.paths.allocator();
        self.stop = .init(false);
        const rel = try a.dupeSentinel(u8, build_options.fake_harness, 0);
        if (c.realpath(rel, &self.exe) == null) return error.FakeHarnessMissing;
        self.fake = .{ .exe = std.mem.sliceTo(&self.exe, 0), .script = self.script, .state_dir = self.dir };
        self.adapters = .{.{ .harness = harness.fake.name, .adapter = self.fake.adapter() }};
        self.logger = log.Logger.init(.{ .source = main.tool });
        self.events = try proto.events.Log.init(ta, main.tool, .{}, null);
        self.events.catalog = &eventlog.catalog.entries;
        // Vendor harnesses off (they are on by default): only the fake runs.
        self.store = try config.Store.init(ta, .{ .io = testing.io, .path = try std.fmt.allocPrint(a, "{s}/config.zon", .{self.dir}), .validate = config.validate, .events = &self.events });
        self.registry = try proto.grants.Registry.init(ta, main.tool, .{});
        // The TUI and the test's CLI calls run in this process, where the
        // owner token is refused: a principal rooted here gives
        // them `write` and `spawn`.
        const self_ref = (try proto.process.stat(c.getpid())).ref;
        const usual = [_]proto.grants.Grant{ .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
        const with_admin = usual ++ [_]proto.grants.Grant{.{ .right = .admin, .scope = "*" }};
        const issued = try self.registry.issueChild(.{ .principal = proto.grants.owner }, .{ .kind = .agent, .root = self_ref, .grants = if (self.config_admin) &with_admin else &usual, .label = "tui-test" }, proto.grants.nowSeconds());
        ta.free(issued.token);
        self.engine = try eventlog.Engine.open(ta, try std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, eventlog.file_name }), .{ .events = &self.events });
        try self.runner.init(ta, &self.engine, self.store.current().harness, &self.adapters, &self.logger);
        self.engine.options.executors = self.runner.executors();
        try self.engine.start();
        self.principals = .{ .gpa = ta, .registry = &self.registry, .engine = &self.engine };
        self.principals.install();
        self.runner.host.credentials = self.principals.credentials();
        self.snapshots = .{ .engine = &self.engine };
        self.events.snapshot = proto.events.Snapshot.init(&self.snapshots);
        self.agents = .{ .engine = &self.engine, .host = &self.runner.host, .io = testing.io, .config = &self.store, .principals = &self.principals };
        self.harness_verbs = .{ .runner = &self.runner };
        self.workspaces = .{ .engine = &self.engine, .io = testing.io };
        self.usage = .{ .engine = &self.engine };
        self.context_verbs = .{ .agents = &self.agents };
        self.inbox = .{ .engine = &self.engine, .principals = &self.principals };
        self.ws_add = self.workspaces.adder();
        self.ws_remove = self.workspaces.remover();
        self.ws_scan = self.workspaces.scanner();
        self.scoped = .{ .store = &self.store, .engine = &self.engine, .layers = .{ .gpa = ta, .io = testing.io, .user = self.store.path, .events = &self.events } };
        self.holds = .{ .gpa = ta, .registry = &self.registry };
        self.holds.ready();
        const handlers = [_]proto.Binding{
            .{ .verb = "events", .handler = proto.VerbHandler.init(&self.events) },
            .{ .verb = "tui.hold", .handler = proto.VerbHandler.init(&self.holds) },
            .{ .verb = "workspace.add", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.ws_add) },
            .{ .verb = "workspace.list", .handler = proto.VerbHandler.init(&self.workspaces) },
            .{ .verb = "workspace.remove", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.ws_remove) },
            .{ .verb = "workspace.scan", .handler = proto.VerbHandler.typed(Workspaces.ScanParams, &self.ws_scan) },
        } ++ self.agents.bindings() ++ self.usage.bindings() ++ self.context_verbs.bindings() ++ self.inbox.bindings() ++ self.harness_verbs.bindings() ++ self.scoped.bindings();
        self.dispatcher = try proto.Dispatcher.init(ta, &daemon_model, &handlers, .{}, null);
        self.server = try proto.Server.init(ta, .{
            .hello = .{ .identity = .{ .name = main.tool, .version = "0.0.0" }, .caps = &.{"cancel"} },
            .path = .{ .socket = self.socket },
            .registry = &self.registry,
        }, blk: {
            self.front = .{ .dispatcher = &self.dispatcher, .holds = &self.holds };
            break :blk self.front.handler();
        });
        self.loop = .{ .gpa = ta, .io = testing.io, .server = &self.server, .dispatcher = &self.dispatcher, .events = &self.events, .config = &self.store, .registry = &self.registry, .logger = &self.logger, .engine = &self.engine, .harnesses = &self.runner, .agents = &self.agents, .holds = &self.holds };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn serve(self: *Daemon) void {
        while (!self.stop.load(.acquire)) {
            self.loop.step(20) catch |err| {
                std.debug.print("serve loop failed: {s}\n", .{@errorName(err)});
                self.failed.store(true, .release);
                return;
            };
            for (self.runner.host.bindings.values()) |b| if (b.process) |p| {
                for (self.pids.items) |pid| {
                    if (pid == p.pid()) break;
                } else self.pids.append(ta, p.pid()) catch @panic("oom");
            };
        }
        self.dispatcher.cancelAll();
        self.runner.host.shutdown() catch |err| std.debug.print("harness shutdown failed: {s}\n", .{@errorName(err)});
        self.events.tick() catch {};
        self.server.shutdown();
        var n: usize = 0;
        while (self.server.connections.items.len != 0 and n < 50) : (n += 1) self.server.poll(20) catch break;
    }

    /// Stops the daemon process half (as SIGTERM would); the directory and
    /// its durable log stay for the next `start`.
    pub fn halt(self: *Daemon) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.loop.deinit();
        self.server.deinit();
        self.dispatcher.deinit();
        self.holds.deinit();
        self.runner.deinit();
        for (self.pids.items) |pid| {
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("a harness process outlived the daemon");
        }
        self.pids.clearRetainingCapacity();
        self.engine.deinit();
        self.principals.deinit();
        self.registry.deinit();
        self.store.deinit();
        self.events.deinit();
        self.logger.deinit();
    }

    pub fn deinit(self: *Daemon) void {
        self.pids.deinit(ta);
        self.paths.deinit();
    }

    /// `venom <args> --json` through the generated CLI, as a script would.
    pub fn run(self: *Daemon, a: std.mem.Allocator, args: []const []const u8) !Value {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, args);
        try argv.appendSlice(a, &.{ "--json", try std.fmt.allocPrint(a, "--socket={s}", .{self.socket}) });
        var out: std.Io.Writer.Allocating = .init(ta);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(ta);
        defer err.deinit();
        const status = try main.App.run(ta, argv.items, .{ .stdout = &out.writer, .stderr = &err.writer, .local = main.noView() });
        if (status != 0) std.debug.print("venom {s}: {s}{s}\n", .{ args[0], out.written(), err.written() });
        try testing.expectEqual(@as(u8, 0), status);
        return std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, std.mem.trim(u8, out.written(), " \n")), .{});
    }
};

/// Pumps the TUI (link, then a frame) until `pred` holds; 10 s at most.
pub fn until(app: *App, link: *Link, surface: *term.Surface, d: *Daemon, comptime what: []const u8, pred: anytype) !void {
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while (true) {
        if (d.failed.load(.acquire)) return error.ServeLoopFailed;
        try link.pump(app, 20);
        try view.render(app, surface);
        if (try pred.check(app, surface)) return;
        if (supervisor.monotonicMs() > deadline) {
            var arena = std.heap.ArenaAllocator.init(ta);
            defer arena.deinit();
            std.debug.print("timed out waiting for {s}; screen:\n{s}\n", .{ what, try dump(arena.allocator(), surface) });
            return error.Timeout;
        }
    }
}

/// The screen contains `text`.
pub const Shows = struct {
    text: []const u8,
    pub fn check(self: Shows, _: *App, surface: *term.Surface) !bool {
        var arena = std.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        return std.mem.indexOf(u8, try dump(arena.allocator(), surface), self.text) != null;
    }
};

pub const Connected = struct {
    pub fn check(_: Connected, app: *App, _: *term.Surface) !bool {
        return app.connected and app.model.cursor.items.len > 0;
    }
};

/// Connected and synced to a source other than `old` (a restart's epoch).
const NewEpoch = struct {
    old: []const u8,
    fn check(self: NewEpoch, app: *App, _: *term.Surface) !bool {
        return app.connected and app.model.source().len > 0 and !std.mem.eql(u8, app.model.source(), self.old);
    }
};

/// Agent `id` is in `state` in the TUI's model.
pub const InState = struct {
    id: []const u8,
    state: @import("model.zig").State,
    pub fn check(self: InState, app: *App, _: *term.Surface) !bool {
        const ag = app.model.find(self.id) orelse return false;
        return ag.state == self.state;
    }
};

test "live: the TUI renders from events against the fake harness, drives verbs with keys, and survives a daemon restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
    try tmp.dir.createDirPath(testing.io, "work");
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
    var d: Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}) };
    defer d.deinit();
    try d.start();
    var running = true;
    defer if (running) d.halt();

    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 100, 26);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);

    // An empty daemon: the initial snapshot has no agents.
    try until(&app, &link, &surface, &d, "connect", Connected{});
    try until(&app, &link, &surface, &d, "the empty list", Shows{ .text = "No agents yet." });

    // A script spawns an agent; it appears live, settles, and its
    // transcript (from agent.show) shows the fake harness's answer.
    const task = try std.fmt.allocPrint(a, "--cwd={s}", .{work});
    _ = try d.run(a, &.{ "agent", "spawn", task, "--task=say hello", "--harness=fake" });
    try until(&app, &link, &surface, &d, "a1 settled", InState{ .id = "a1", .state = .settled });
    try until(&app, &link, &surface, &d, "a1 transcript", Shows{ .text = "Done." });
    try testing.expect(std.mem.indexOf(u8, try dump(a, &surface), "● say hello") != null);

    // An agent that asks for approval: Needs you, and `▲ 1 need you`.
    _ = try d.run(a, &.{ "agent", "spawn", task, "--task=ask to build", "--harness=fake" });
    try until(&app, &link, &surface, &d, "a2 needs you", InState{ .id = "a2", .state = .needs_you });
    try until(&app, &link, &surface, &d, "the bar's count", Shows{ .text = "▲ 1 need you │ ◆ 0 running" });

    // Keys drive verbs. The selection stayed on a1 while a2 arrived above
    // it (Needs you comes first); k and j move between them.
    try testing.expectEqualStrings("a1", app.selected.items);
    _ = try app.feed("kk"); // over the Settled header
    try testing.expectEqualStrings("a2", app.selected.items);
    try until(&app, &link, &surface, &d, "a2's request", Shows{ .text = "▲ approval: Run zig build?" });
    _ = try app.feed("jj");
    try testing.expectEqualStrings("a1", app.selected.items);
    _ = try app.feed("iagain\r\x1b");
    try until(&app, &link, &surface, &d, "a1's second turn", Shows{ .text = "── turn t2" });
    try until(&app, &link, &surface, &d, "a1 settled again", InState{ .id = "a1", .state = .settled });

    // A slow turn, stopped with S.
    _ = try app.feed("islow work\r\x1b");
    try until(&app, &link, &surface, &d, "a1 running", InState{ .id = "a1", .state = .running });
    _ = try app.feed("S");
    try until(&app, &link, &surface, &d, "a1 stopped", InState{ .id = "a1", .state = .settled });

    // The daemon restarts. The TUI keeps its picture while it is gone…
    const old_source = try a.dupe(u8, app.model.source());
    d.halt();
    running = false;
    try until(&app, &link, &surface, &d, "offline", Shows{ .text = "daemon offline" });
    try testing.expect(std.mem.indexOf(u8, try dump(a, &surface), "say hello") != null);
    const connects = link.connects;
    try d.start();
    running = true;
    // …and on reconnect its old cursor is from another epoch, so a
    // `source_changed` snapshot rebuilds the list from the durable log.
    // The shutdown ended a2's waiting turn, so it
    // no longer needs you. The selection is kept.
    try until(&app, &link, &surface, &d, "the new epoch's snapshot", NewEpoch{ .old = old_source });
    try until(&app, &link, &surface, &d, "a2 settled after the restart", InState{ .id = "a2", .state = .settled });
    try until(&app, &link, &surface, &d, "the bar's count after the restart", Shows{ .text = " ▲ 0 need you" });
    try testing.expect(link.connects == connects + 1);
    try testing.expect(app.connected);
    try testing.expectEqualStrings("a1", app.selected.items);
    try until(&app, &link, &surface, &d, "a1's transcript again", Shows{ .text = "── turn t3" });
    try testing.expect(std.mem.indexOf(u8, try dump(a, &surface), "daemon offline") == null);

    // Still live after the restart: x archives a1 (it leaves the
    // Settled group for the folded Archived line).
    _ = try app.feed("x");
    try until(&app, &link, &surface, &d, "a1 archived", InState{ .id = "a1", .state = .archived });
}
