//! Own-mode splits: the split menu offers its
//! options by availability (take-over only for an adapter with resume),
//! an agent view and a worktree shell open side by side, and `leader v x` closes
//! them while the agent keeps running: no verb is sent, the daemon still
//! has it running, and the shell's process is gone. Also: an
//! agent view sends and answers approvals inline, a paste reaches a focused
//! shell's PTY, and a PTY read error closes the split (the child's clean
//! start is tested in pty.zig).
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const harnesses = @import("../harnesses.zig");
const App = @import("app.zig").App;
const KeyMode = @import("app.zig").KeyMode;
const Link = @import("link.zig").Link;
const view = @import("view.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;

const ctrl_w = "\x17";
/// `leader v x`, with the default leader.
const close_split = " vx";
/// ⌃], the default `ui.keys.leave_terminal`, as Kitty reports it.
const leave = "\x1b[93;5u";
const ctrl_enter = "\x1b[13;5u";

fn render(app: *App, surface: *term.Surface, a: std.mem.Allocator) ![]const u8 {
    try view.render(app, surface);
    return t.dump(a, surface);
}

fn has(screen: []const u8, text: []const u8) bool {
    return std.mem.indexOf(u8, screen, text) != null;
}

test "the theme owns the ground: defaults follow the chrome, and a shell's OSC 11 says so" {
    var app = App.init(ta);
    defer app.deinit();
    var surface = try term.Surface.init(ta, 80, 24);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);

    // Without truecolor the ground stays the terminal's own.
    try view.render(&app, &surface);
    try testing.expectEqual(term.Color.default, surface.defaults.bg);
    try testing.expectEqualDeep(term.Vt.QueryColors{}, app.shellColors());

    app.setTheme(.{ .mode = .truecolor });
    try view.render(&app, &surface);
    try testing.expectEqual(term.Color{ .rgb = term.theme.trve.void.rgb }, surface.defaults.bg);
    try testing.expectEqual(term.Color{ .rgb = term.theme.trve.bone.rgb }, surface.defaults.fg);

    app.setTheme(.{ .theme = &term.theme.bone, .mode = .truecolor });
    try view.render(&app, &surface);
    try testing.expectEqual(term.Color{ .rgb = term.theme.bone.void.rgb }, surface.defaults.bg);

    // A program in a split asks what it is drawn on, and hears the theme.
    app.setTheme(.{ .mode = .truecolor });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    const script = "stty raw -echo; printf '\\033]11;?\\033\\\\'; dd bs=1 count=23 of=reply.txt 2>/dev/null";
    const sh = try @import("split.zig").Shell.start(ta, .{ .shell = "/bin/sh", .args = &.{ "-c", script }, .cwd = buf[0..n], .env = &env, .agent = "a1", .colors = app.shellColors() }, .{ .cols = 80, .rows = 24 });
    defer sh.deinit();
    var waited: usize = 0;
    while (!sh.exited() and waited < 500) : (waited += 1) {
        _ = sh.pump() catch false;
        sh.flush() catch {};
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(sh.exited());
    const got = try tmp.dir.readFileAlloc(testing.io, "reply.txt", ta, .limited(1 << 16));
    defer ta.free(got);
    try testing.expectEqualStrings("\x1b]11;rgb:0000/0000/0000", got);
}

test "split menu: agent view by default, take over only with resume, `leader v x` closes without a verb" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    app.resumes = harnesses.resumesTui;
    try t.fixtureApp(&app, a);
    // Wide enough for three titled boxes side by side.
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);

    // a1 runs in claude-code, whose adapter resumes: three options.
    try testing.expectEqualStrings("a1", app.selected.items);
    _ = try app.feed("\\");
    var screen = try render(&app, &surface, a);
    if (!has(screen, "1  Agent view")) std.debug.print("menu:\n{s}\n", .{screen});
    try testing.expect(has(screen, "Split · venom-echo conformance"));
    try testing.expect(has(screen, "1  Agent view"));
    try testing.expect(has(screen, "2  Shell in worktree"));
    try testing.expect(has(screen, "A plain shell in venom-std/. The agent keeps running."));
    try testing.expect(has(screen, "3  Take over in claude-code"));
    try testing.expect(has(screen, "│  NORMAL"));
    // Esc leaves it; nothing was sent.
    _ = try app.feed("\x1b");
    try testing.expect(app.menu == null);

    // a2 runs in opencode, a4 in codex: no resume, so no take-over.
    _ = try app.feed("j");
    try testing.expectEqualStrings("a2", app.selected.items);
    _ = try app.feed(ctrl_enter);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "Split · libghostty-vt spike"));
    try testing.expect(!has(screen, "Take over"));
    try testing.expectEqual(@as(usize, 2), app.menu.?.opts.len);
    _ = try app.feed("q");
    _ = try t.sent(a, &app);

    // ⏎ picks the default: an agent view of a2, beside the main view,
    // with its own agent.show.
    _ = try app.feed("\\\r");
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    try testing.expectEqualStrings("agent.show(a2) ", try t.sent(a, &app));
    // Take-over of a1, which needs you (mid-turn), asks first;
    // esc cancels, and nothing opens.
    _ = try app.feed("\t\t"); // its box, then around to the list
    try testing.expectEqual(@import("app.zig").Area.list, app.area());
    _ = try app.feed("k\\3");
    try testing.expect(app.ask != null);
    _ = try app.feed("\x1b");
    try testing.expect(app.ask == null);
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "take over cancelled") != null);
    _ = try t.sent(a, &app);

    // A second agent view, on the left (h); a third split is refused.
    _ = try app.feed("\\h1");
    try testing.expectEqual(@as(usize, 2), app.splits.items.len);
    try testing.expect(app.splits.items[1].side == .left);
    _ = try t.sent(a, &app);
    screen = try render(&app, &surface, a);
    // Side by side: three transcript boxes on the top row, no inspector.
    var rows = std.mem.splitScalar(u8, screen, '\n');
    const top = rows.next().?;
    try testing.expect(has(top, "│ venom-echo conformance") and has(top, "│ libghostty-vt spike"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, top, "venom-echo conformance"));
    try testing.expect(!has(screen, "│ AGENT"));
    _ = try app.feed("\\1");
    try testing.expectEqual(@as(usize, 2), app.splits.items.len);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "close one with space v x") != null);

    // `leader v x` closes the focused split, then the last one; no verb is sent
    // (closing a split never stops the agent).
    try testing.expectEqual(@as(?usize, 1), app.focusedSplit());
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expectEqual(@import("app.zig").Area.transcript, app.area());
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(std.mem.indexOf(u8, app.message.items, "the agent keeps running") != null);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "│ AGENT")); // the inspector is back
    // In the input box ⌃w is text editing, not a close.
    _ = try app.feed("\\\r");
    _ = try t.sent(a, &app);
    _ = try app.feed("\t\t\t\t"); // split → its box → list → transcript → input
    try testing.expectEqual(@import("app.zig").Area.input, app.area());
    _ = try app.feed("two words" ++ ctrl_w);
    try testing.expectEqualStrings("two ", app.input.value());
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
}

/// `agent.state_changed` for `agent`, as the daemon publishes it.
fn changed(app: *App, a: std.mem.Allocator, seq: u32, agent: []const u8, from: []const u8, to: []const u8) !void {
    try t.feedJson(app, a, try std.fmt.allocPrint(a, "{{\"seq\":{d},\"ts\":\"2026-11-06T14:31:00.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.state_changed\",\"data\":{{\"agent\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\"}}}}", .{ seq, agent, from, to }));
}

/// The oldest pending `agent.takeover` request's id.
fn takeoverRequest(app: *App) ?i64 {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .takeover) {
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    };
    return lowest;
}

test "take over: mid-turn asks first; the harness TUI runs in a split, with a banner; its exit takes the agent back" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    app.resumes = harnesses.resumesTui;
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    app.env = &env;
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    try testing.expectEqualStrings("a1", app.selected.items);

    // a1 needs you: take over asks, "after this turn" by default.
    _ = try app.feed("\\3");
    var screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "Take over in claude-code · venom-echo conformance"));
    try testing.expect(has(screen, "1  After this turn"));
    try testing.expect(has(screen, "2  Interrupt now"));
    try testing.expect(has(screen, "3  Cancel"));
    try testing.expect(has(screen, "│  NORMAL"));
    _ = try app.feed("\r");
    try testing.expect(app.ask == null);
    try testing.expectEqualStrings("", try t.sent(a, &app));
    // Still running: it waits. Once the turn ends, the take-over is asked.
    try changed(&app, a, 41, "a1", "needs_you", "running");
    try testing.expect(takeoverRequest(&app) == null);
    try changed(&app, a, 42, "a1", "running", "settled");
    try testing.expect(std.mem.indexOf(u8, try t.sent(a, &app), "agent.takeover(a1)") != null);
    // The daemon refuses (say a turn started meanwhile): the message says so.
    try app.onResponse(takeoverRequest(&app).?, .{ .@"error" = .{ .code = "conflict.turn_running", .message = "", .data = null } });
    try testing.expect(std.mem.indexOf(u8, app.message.items, "take over: conflict.turn_running") != null);

    // a3 is running: "interrupt now" stops the turn, then takes over.
    try app.preselect("a3");
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    _ = try app.feed("\\32");
    try testing.expectEqualStrings("agent.stop(a3) ", try t.sent(a, &app));
    try changed(&app, a, 43, "a3", "running", "settled");
    try testing.expectEqualStrings("agent.takeover(a3) ", try t.sent(a, &app));
    // The command runs in a split ("/bin/sh" here, as the daemon names it).
    const result =
        \\{"agent":"a3","state":"handed_over","harness":"claude-code","argv":["sh","-c","read line; echo \"got $line in $PWD with $FAKE_CFG\"; read line"],"cwd":"/tmp","env":[{"name":"FAKE_CFG","value":"cfg-dir"}]}
    ;
    try app.onResponse(takeoverRequest(&app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) });
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(app.splits.items[0].kind == .take_over);
    // The turn's end opened it, with no key pressed: `\` goes there.
    try testing.expect(app.focusedSplit() == null);
    try changed(&app, a, 44, "a3", "settled", "handed_over");
    _ = try t.sent(a, &app);
    _ = try app.feed("\\");
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    // Keys go to the harness TUI.
    _ = try app.feed("hello\r");
    const deadline = @import("supervisor").monotonicMs() + 5_000;
    while (true) {
        _ = try app.pumpShells();
        screen = try render(&app, &surface, a);
        if (has(screen, "got hello in /tmp with cfg-dir")) break;
        if (@import("supervisor").monotonicMs() > deadline) {
            std.debug.print("screen:\n{s}\n", .{screen});
            return error.Timeout;
        }
    }
    try testing.expect(has(screen, "│ ⇄ claude-code"));
    try testing.expect(has(screen, "│  TERMINAL"));
    // The main view's banner replaces the input box.
    _ = try app.feed(leave); // ⌃] leaves the split
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "⇄ in claude-code"));
    try testing.expect(has(screen, "\\ focus split  ·  T take back"));
    _ = try app.feed("i");
    try testing.expectEqual(@import("app.zig").Area.input, app.area());
    _ = try app.feed("more\r");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(std.mem.indexOf(u8, app.message.items, "T takes it back") != null);
    _ = try app.feed("\x1b");
    // `\` focuses the split again; its exit takes the agent back.
    _ = try app.feed("\\");
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    const pid = app.splits.items[0].shell.?.pid();
    _ = try app.feed("bye\r");
    try waitExited(&app, 0);
    try testing.expectEqualStrings("agent.takeback(a3) ", try t.sent(a, &app));
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "taking a3 back from claude-code") != null);
    _ = try app.feed("\x1b");
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);

    // T takes back an agent handed over without a split here.
    try changed(&app, a, 45, "a3", "settled", "handed_over");
    _ = try app.feed("T");
    try testing.expectEqualStrings("agent.takeback(a3) ", try t.sent(a, &app));
    // ...and says so for one that is not.
    try app.preselect("a4");
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    _ = try app.feed("T");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(std.mem.indexOf(u8, app.message.items, "is not handed over") != null);
}

/// The oldest pending `agent.takeback` request's id.
fn takebackRequest(app: *App) ?i64 {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .takeback) {
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    };
    return lowest;
}

/// Opens a take-over split of `agent` running `sleep 30`, as the daemon's
/// answer would; returns the child's pid.
fn openSleeper(app: *App, a: std.mem.Allocator, agent: []const u8) !c.pid_t {
    try app.takeOver(agent, .right, true);
    // The split belongs to this client: `tui:<pid>`.
    const line = app.outbox.items[app.outbox.items.len - 1];
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, line), .{});
    try testing.expectEqualStrings("agent.takeover", v.object.get("verb").?.string);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "tui:{d}", .{c.getpid()}), v.object.get("params").?.object.get("pane").?.string);
    _ = try t.sent(a, app);
    const result = try std.fmt.allocPrint(a, "{{\"agent\":\"{s}\",\"state\":\"handed_over\",\"harness\":\"claude-code\",\"argv\":[\"sleep\",\"30\"],\"cwd\":\"/tmp\",\"env\":[]}}", .{agent});
    try app.onResponse(takeoverRequest(app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) });
    try testing.expect(app.takeoverSplit(agent) != null);
    _ = try t.sent(a, app); // the split's process, reported
    return app.splits.items[app.takeoverSplit(agent).?].shell.?.pid();
}

test "take over: a take-back from elsewhere closes the split; quitting ends the split and owes the take-back until the daemon answers" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    app.env = &env;
    try t.fixtureApp(&app, a);
    try changed(&app, a, 41, "a3", "running", "settled");
    _ = try t.sent(a, &app);

    // Taken back by another client (or the CLI): the split's harness TUI
    // ends here, and this client sends nothing.
    var pid = try openSleeper(&app, a, "a3");
    try changed(&app, a, 42, "a3", "settled", "handed_over");
    try testing.expect(app.takeoverSplit("a3") != null);
    try changed(&app, a, 43, "a3", "handed_over", "settled");
    try testing.expect(app.takeoverSplit("a3") == null);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(std.mem.indexOf(u8, app.message.items, "taken back elsewhere") != null);
    _ = try app.feed("\x1b");

    // Quitting: the split ends first, then the take-back is sent.
    pid = try openSleeper(&app, a, "a3");
    try changed(&app, a, 44, "a3", "settled", "handed_over");
    try app.releaseTakeovers();
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    try testing.expectEqualStrings("agent.takeback(a3) ", try t.sent(a, &app));
    try testing.expect(app.owesTakeback());
    // The connection drops before the answer: it is sent again on reconnect.
    try app.onDisconnected();
    try app.onConnected();
    try testing.expectEqualStrings("agent.takeback(a3) ", try t.sent(a, &app));
    try app.onResponse(takebackRequest(&app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"agent\":\"a3\",\"state\":\"settled\",\"imported\":0,\"catch_up\":\"\"}", .{}) });
    try testing.expect(!app.owesTakeback());
}

test "split from the inbox: \\ opens the menu for the item's agent" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a3","item":"r1","request":"r1","kind":"approval","reason":"Run zig build?","title":"theme module trve/bone","age_s":5}]}
    , .{}));
    app.openInbox();
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try app.feed("\\");
    try testing.expectEqual(@import("app.zig").Screen.main, app.screen);
    try testing.expectEqualStrings("a3", app.menu.?.agent);
    try testing.expectEqualStrings("a3", app.selected.items);
}

/// The agent's shell split shows `text`.
const ShellShows = struct {
    text: []const u8,
    pub fn check(self: ShellShows, app: *App, surface: *term.Surface) !bool {
        _ = try app.pumpShells();
        try view.render(app, surface);
        return t.Shows.check(.{ .text = self.text }, app, surface);
    }
};

/// The agent-view split has the agent's transcript.
const SplitLoaded = struct {
    pub fn check(_: SplitLoaded, app: *App, _: *term.Surface) !bool {
        if (app.splits.items.len == 0) return false;
        return app.splits.items[0].detail.records.items.len > 0;
    }
};

test "live: an agent view and a worktree shell open side by side; `leader v x` closes them and the agent keeps running" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
    try tmp.dir.createDirPath(testing.io, "work");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/marker.txt", .data = "inside-the-worktree\n" });
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
    var d: t.Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}) };
    defer d.deinit();
    try d.start();
    defer d.halt();

    var app = App.init(ta);
    defer app.deinit();
    app.shell_path = "/bin/sh";
    app.resumes = harnesses.resumesTui;
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    app.env = &env;
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 150, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try t.until(&app, &link, &surface, &d, "connect", t.Connected{});

    // A slow turn: the agent runs for the whole test.
    _ = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{work}), "--task=slow work", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "a1 running", t.InState{ .id = "a1", .state = .running });
    try t.until(&app, &link, &surface, &d, "a1's folder", struct {
        w: []const u8,
        pub fn check(self: @This(), ap: *App, _: *term.Surface) !bool {
            const ag = ap.model.find("a1") orelse return false;
            return std.mem.eql(u8, ag.cwd, self.w);
        }
    }{ .w = work });

    // The menu: the fake harness has no resume, so no take-over.
    _ = try app.feed("\\");
    try t.until(&app, &link, &surface, &d, "the split menu", t.Shows{ .text = "Split · slow work" });
    var screen = try t.dump(a, &surface);
    try testing.expect(has(screen, "Shell in worktree"));
    try testing.expect(!has(screen, "Take over"));

    // Agent view (⏎, the default), then from it a shell (\ 2).
    _ = try app.feed("\r");
    try t.until(&app, &link, &surface, &d, "the agent-view split's transcript", SplitLoaded{});
    _ = try app.feed("\\2");
    try testing.expectEqual(@as(usize, 2), app.splits.items.len);
    const shell = app.splits.items[1].shell.?;
    const pid = shell.pid();
    try testing.expectEqual(@as(?usize, 1), app.focusedSplit());

    // Keys go to the shell, which runs in the agent's folder.
    _ = try app.feed("cat marker.txt\r");
    try t.until(&app, &link, &surface, &d, "the shell's output", ShellShows{ .text = "inside-the-worktree" });
    _ = try app.feed("echo \"$VENOM_AGENT-$((40+2))\"\r");
    try t.until(&app, &link, &surface, &d, "the shell's environment", ShellShows{ .text = "a1-42" });

    // Side by side: the main view, the agent view and the shell share
    // the top row.
    screen = try t.dump(a, &surface);
    var rows = std.mem.splitScalar(u8, screen, '\n');
    const top = rows.next().?;
    try testing.expect(has(top, " AGENTS"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, top, "│ slow work"));
    try testing.expect(has(top, "│ Shell"));
    try testing.expect(has(screen, "│  TERMINAL"));

    // Out of Terminal mode, `leader v x` closes the shell split (the shell's process
    // goes), then `leader v x`
    // closes the agent view. The agent keeps running.
    _ = try app.feed(leave ++ close_split);
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try t.until(&app, &link, &surface, &d, "the main view alone", t.Shows{ .text = "split closed; the agent keeps running" });
    try testing.expectEqual(@import("model.zig").State.running, app.model.find("a1").?.state);
    const shown = try d.run(a, &.{ "agent", "show", "--agent=a1" });
    try testing.expectEqualStrings("running", shown.object.get("state").?.string);
}

test "a split's program never gets venom's venomx identity or credentials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    for ([_][]const u8{ "VENOMX_TOKEN", "VENOMX_PRINCIPAL", "VENOMX_PANE", "VENOMX_SOCKET" }) |name| try env.put(name, "secret");
    for ([_][]const u8{ "VENOM_TOKEN", "VENOM_PRINCIPAL", "VENOM_DESK_TOKEN" }) |name| try env.put(name, "secret");
    try env.put("KEEP", "kept");
    try env.put("PATH", "/usr/bin:/bin");
    const sh = try @import("split.zig").Shell.start(ta, .{ .shell = "/bin/sh", .args = &.{ "-c", "env > env.txt" }, .cwd = buf[0..n], .env = &env, .agent = "a1" }, .{ .cols = 80, .rows = 24 });
    defer sh.deinit();
    var waited: usize = 0;
    while (!sh.exited() and waited < 500) : (waited += 1) {
        _ = sh.pump() catch false;
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(sh.exited());
    const got = try tmp.dir.readFileAlloc(testing.io, "env.txt", ta, .limited(1 << 16));
    defer ta.free(got);
    try testing.expect(has(got, "KEEP=kept"));
    try testing.expect(!has(got, "VENOMX_"));
    try testing.expect(!has(got, "secret"));
}

test "attention while handed over: Needs you, the split marked, Focus split instead of the keys, gone on take back" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    app.resumes = harnesses.resumesTui;
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);

    // a3 is taken over; the split's process is reported to the daemon.
    try app.preselect("a3");
    try changed(&app, a, 50, "a3", "running", "settled");
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    _ = try app.feed("\\3");
    try testing.expectEqualStrings("agent.takeover(a3) ", try t.sent(a, &app));
    const result =
        \\{"agent":"a3","state":"handed_over","harness":"claude-code","argv":["sleep","30"],"cwd":"/tmp","env":[]}
    ;
    try app.onResponse(takeoverRequest(&app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) });
    try testing.expectEqualStrings("agent.takeover_split(a3) ", try t.sent(a, &app));
    const pid = app.splits.items[0].shell.?.pid();
    try testing.expect(pid > 0);
    try changed(&app, a, 51, "a3", "settled", "handed_over");
    _ = try app.feed(leave); // ⌃] leaves the split
    var screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "│ ⇄ claude-code"));
    var g = try app.buildRows();
    try testing.expect(!g.inGroup("Needs you", "a3"));

    // The hook's report arrives.
    try t.feedJson(&app, a, "{\"seq\":52,\"ts\":\"2026-11-06T14:31:00.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.attention\",\"data\":{\"agent\":\"a3\",\"kind\":\"approval\",\"reason\":\"Claude needs your permission to use Bash\",\"age_s\":0}}");
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a3","kind":"approval","age_s":3,"reason":"Claude needs your permission to use Bash","item":"away","title":"take me","stale":false,"away":true,"context":[]}]}
    , .{}));
    _ = try t.sent(a, &app);
    g = try app.buildRows();
    try testing.expectEqualStrings("Needs you", g.rows[0].header.title);
    try testing.expect(g.inGroup("Needs you", "a3"));
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "▲ ⇄ claude-code"));
    try testing.expect(has(screen, "needs you"));
    // Inline in the transcript too: Focus split, and y is no answer.
    try testing.expect(has(screen, "focus split"));
    try testing.expect(!has(screen, "y allow once"));

    // On the inbox screen: Focus split instead of the inbox keys.
    _ = try app.feed(" i");
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "Approve: Claude needs your permission"));
    try testing.expect(has(screen, "\\ focus split"));
    try testing.expect(!has(screen, "y allow once"));
    _ = try t.sent(a, &app);
    _ = try app.feed("yan1");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(app.prompt == null);
    // `\` goes to the split.
    _ = try app.feed("\\");
    try testing.expect(app.screen == .main);
    try testing.expect(app.menu == null);
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    _ = try app.feed("\x1b[93;5u");

    // Cleared and taken back: back to normal.
    try t.feedJson(&app, a, "{\"seq\":53,\"ts\":\"2026-11-06T14:31:00.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.attention_cleared\",\"data\":{\"agent\":\"a3\",\"by\":\"takeback\",\"kind\":\"approval\"}}");
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"items\":[]}", .{}));
    try changed(&app, a, 54, "a3", "handed_over", "settled");
    try testing.expect(!app.model.find("a3").?.away);
    try testing.expect(app.takeoverSplit("a3") == null);
    _ = try t.sent(a, &app);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
}

// ---- The agent view's input box and approvals, paste into a shell,
// ---- a read error, the child's clean start.

/// The oldest pending agent-view `agent.show`, answered with `json`.
fn answerSplitShow(app: *App, a: std.mem.Allocator, json: []const u8) !void {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .split_show) {
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    };
    try app.onResponse(lowest.?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) });
}

/// The only queued request's params, parsed; the outbox is left empty.
fn takeOne(app: *App, a: std.mem.Allocator, verb: []const u8) !std.json.ObjectMap {
    try testing.expectEqual(@as(usize, 1), app.outbox.items.len);
    const line = app.outbox.items[0];
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, line), .{});
    ta.free(line);
    app.outbox.clearRetainingCapacity();
    try testing.expectEqualStrings(verb, v.object.get("verb").?.string);
    return v.object.get("params").?.object;
}

fn lowestSend(app: *App) i64 {
    var it = app.pending.iterator();
    var lowest: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .send) {
        if (lowest == null or e.key_ptr.* < lowest.?) lowest = e.key_ptr.*;
    };
    return lowest.?;
}

test "agent view: its box sends to its agent with its capabilities; a refused prompt and a draft stay that agent's" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    try testing.expectEqualStrings("a1", app.selected.items);

    // An agent view of a3 (running), a1 selected in the main view. a3's
    // harness injects; the main view's detail knows nothing of that.
    try app.openMenu("a3");
    _ = try app.feed("\r");
    try testing.expectEqualStrings("agent.show(a3) ", try t.sent(a, &app));
    try answerSplitShow(&app, a,
        \\{"agent":"a3","title":"theme module trve/bone","harness":"claude-code","state":"running","turns":1,"requests":[],"transcript":[],"model":"opus 5.5","permission_mode":"ask","steer":"inject","interrupt":true,"context":{"used":124000,"window":200000},"context_warn_at":80}
    );
    var screen = try render(&app, &surface, a);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, screen, "┌ Input"));
    try testing.expect(has(screen, "ask mode  opus 5.5"));
    try testing.expect(has(screen, "Enter steers"));
    try testing.expect(has(screen, "⇥ input"));
    try testing.expect(has(screen, "│  NORMAL"));

    // ⇥ goes to its box; text is text there.
    _ = try app.feed("\t");
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "│  INPUT"));
    try testing.expect(has(screen, "⏎ steer   ⇧⏎ queue"));
    _ = try app.feed("q\\x");
    try testing.expectEqualStrings("q\\x", app.splits.items[0].input.?.value());
    try testing.expectEqualStrings("", app.input.value());
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    _ = try app.feed("\x7f\x7f\x7f");

    // ⏎ steers a3, by the split's own detail.
    _ = try app.feed("use bone\r");
    const params = try takeOne(&app, a, "agent.send");
    try testing.expectEqualStrings("a3", params.get("agent").?.string);
    try testing.expectEqualStrings("use bone", params.get("text").?.string);
    try testing.expectEqualStrings("steer", params.get("mode").?.string);
    try testing.expectEqualStrings("", app.splits.items[0].input.?.value());

    // Refused: the prompt returns to a3's box, in front of what came since.
    _ = try app.feed("and more");
    try app.onResponse(lowestSend(&app), .{ .@"error" = .{ .code = "conflict.turn_running", .message = "", .data = null } });
    try testing.expectEqualStrings("use bone and more", app.splits.items[0].input.?.value());
    try testing.expectEqualStrings("", app.input.value());
    try testing.expect(std.mem.indexOf(u8, app.message.items, "back in a3's box") != null);

    // A paste's line break does not send, its tab does not move the focus.
    _ = try app.feed("\x1b[200~ x\ry\tz\x1b[201~");
    try testing.expectEqualStrings("use bone and more x y z", app.splits.items[0].input.?.value());
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());

    // esc: back to its transcript, still in the split; `leader v x` there closes it,
    // and the text stays a3's draft, shown when its view opens again.
    _ = try app.feed("\x1b");
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    try testing.expect(!app.inFocusedBox());
    _ = try app.feed(close_split);
    try testing.expectEqualStrings("use bone and more x y z", app.drafts.get("a3").?);
    try testing.expectEqualStrings("", app.input.value());
    try app.openMenu("a3");
    _ = try app.feed("\r");
    _ = try t.sent(a, &app);
    try testing.expectEqualStrings("use bone and more x y z", app.splits.items[0].input.?.value());
    try testing.expect(app.drafts.get("a3") == null);

    // Selecting a3 in the main view: one draft, in the main box; the split
    // draws and edits the same one. Moving away, it stays with the split.
    _ = try app.feed("\x1b"); // from the transcript of the split: to the list
    try testing.expectEqual(@import("app.zig").Area.list, app.area());
    var tries: usize = 0;
    while (!std.mem.eql(u8, app.selected.items, "a3") and tries < 8) : (tries += 1) {
        _ = try render(&app, &surface, a);
        _ = try app.feed("j");
    }
    _ = try t.sent(a, &app);
    try testing.expectEqualStrings("a3", app.selected.items);
    try testing.expectEqualStrings("use bone and more x y z", app.input.value());
    try testing.expectEqualStrings("", app.splits.items[0].input.?.value());
    try testing.expect(app.boxOf("a3").? == &app.input);
    screen = try render(&app, &surface, a);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, screen, "use bone and more"));
    _ = try app.feed("\t\t\t\t"); // transcript, input, split, its box
    try testing.expect(app.inFocusedBox());
    try testing.expectEqual(@as(?usize, 0), app.focusedSplit());
    _ = try app.feed("!");
    try testing.expectEqualStrings("use bone and more x y z!", app.input.value());
    _ = try app.feed("\x1b"); // its transcript
    _ = try app.feed("\x1b"); // the list
    while (!std.mem.eql(u8, app.selected.items, "a1") and tries < 16) : (tries += 1) {
        _ = try render(&app, &surface, a);
        _ = try app.feed("k");
    }
    _ = try t.sent(a, &app);
    try testing.expectEqualStrings("a1", app.selected.items);
    try testing.expectEqualStrings("", app.input.value());
    try testing.expectEqualStrings("use bone and more x y z!", app.splits.items[0].input.?.value());

    // Handed over: the split's box is disabled like the main one. Text goes
    // nowhere, a pasted T does nothing, and T takes back its agent.
    try changed(&app, a, 41, "a3", "running", "settled");
    try changed(&app, a, 42, "a3", "settled", "handed_over");
    _ = try t.sent(a, &app);
    _ = try app.feed("\t\t\t\t");
    try testing.expect(app.inFocusedBox());
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "⇄ in claude-code"));
    _ = try app.feed("x\r");
    try testing.expectEqualStrings("use bone and more x y z!", app.splits.items[0].input.?.value());
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "a3 is in claude-code's own TUI") != null);
    _ = try app.feed("\x1b[200~T\x1b[201~");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    _ = try app.feed("T");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    _ = try app.feed("\x1b");
    _ = try app.feed("T");
    try testing.expectEqualStrings("agent.takeback(a3) ", try t.sent(a, &app));
}

test "agent view: answers its agent's approvals inline, by key and with a reason; a paste answers nothing" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a3","item":"r8","request":"r8","kind":"approval","reason":"Run zig build?","title":"theme module trve/bone","age_s":5,"grant":"exec:zig"},
        \\          {"agent":"a3","item":"r9","request":"r9","kind":"approval","reason":"Remove out?","title":"theme module trve/bone","age_s":3,"grant":"exec:rm"}]}
    , .{}));
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    try app.openMenu("a3");
    _ = try app.feed("\r");
    _ = try t.sent(a, &app);
    var screen = try render(&app, &surface, a);
    // The keys, in the split and in the status bar.
    try testing.expect(has(screen, "y allow once  a always"));
    try testing.expect(has(screen, "grant exec:zig"));

    // Pasted letters are not answers, nor quit, nor anything else.
    _ = try app.feed("\x1b[200~yq\x17\x1b[201~");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(!app.quit);
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);

    // In its box, y is text.
    _ = try app.feed("\ty");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    _ = try app.feed("\x7f\x1b");

    // y allows the agent's most urgent item.
    _ = try app.feed("y");
    var params = try takeOne(&app, a, "inbox.answer");
    try testing.expectEqualStrings("a3", params.get("agent").?.string);
    try testing.expectEqualStrings("r8", params.get("request").?.string);
    try testing.expectEqualStrings("allow_once", params.get("answer").?.string);
    screen = try render(&app, &surface, a);
    try testing.expect(has(screen, "grant exec:rm"));

    // r asks for the reason in the split's own box; the main box stays.
    _ = try app.feed("r");
    screen = try render(&app, &surface, a);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, screen, "┌ Deny with a reason"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, screen, "┌ Input"));
    try testing.expect(has(screen, "│  INPUT"));
    _ = try app.feed("too risky\r");
    params = try takeOne(&app, a, "inbox.answer");
    try testing.expectEqualStrings("r9", params.get("request").?.string);
    try testing.expectEqualStrings("deny", params.get("answer").?.string);
    try testing.expectEqualStrings("too risky", params.get("reason").?.string);
    screen = try render(&app, &surface, a);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, screen, "┌ Input"));

    // The main view's own inline attention is unchanged: a's item, from the
    // main transcript, answers in the main box.
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a1","item":"r1","request":"r1","kind":"approval","reason":"Run zig build?","title":"venom-echo conformance","age_s":5,"grant":"exec:zig"}]}
    , .{}));
    _ = try app.feed("\x1b"); // the list
    _ = try app.feed("\t"); // the main transcript
    try testing.expectEqual(@import("app.zig").Area.transcript, app.area());
    _ = try app.feed("r");
    screen = try render(&app, &surface, a);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, screen, "┌ Deny with a reason"));
    _ = try app.feed("\x1b");
}

/// Opens a shell split running `script` in `cwd`, focused.
fn openScript(app: *App, script: []const u8, cwd: []const u8) !*split.Shell {
    const sh = try split.Shell.start(ta, .{ .shell = "/bin/sh", .args = &.{ "-c", script }, .env = app.env, .cwd = cwd, .agent = "a3" }, .{ .cols = 80, .rows = 24 });
    var sp: split.Split = .{ .kind = .shell, .agent = try ta.dupe(u8, "a3"), .side = .right, .shell = sh };
    errdefer sp.deinit(ta);
    sp.cwd = try ta.dupe(u8, cwd);
    try app.addSplit(sp);
    return sh;
}

fn pumpUntilFile(app: *App, dir: std.Io.Dir, name: []const u8, a: std.mem.Allocator, want: []const u8) !void {
    const deadline = supervisor.monotonicMs() + 20_000;
    var got: []const u8 = "";
    while (supervisor.monotonicMs() < deadline) {
        _ = try app.pumpShells();
        got = dir.readFileAlloc(testing.io, name, a, .limited(1 << 22)) catch "";
        if (std.mem.eql(u8, got, want)) return;
    }
    std.debug.print("{s}: {d} bytes, wanted {d}\n", .{ name, got.len, want.len });
    return error.Timeout;
}

const supervisor = @import("supervisor");
const split = @import("split.zig");

/// An app with PATH, its env owned by the caller.
fn shellApp(app: *App, env: *std.process.Environ.Map, a: std.mem.Allocator) !void {
    try env.put("PATH", "/usr/bin:/bin");
    app.env = env;
    try t.fixtureApp(app, a);
}

test "paste: reaches a focused shell's PTY byte for byte, in the markers it asked for, across reads; ⌃w in it stays text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);

    const body = "hi\x17 q\r\nthere\x1b[A";
    const want = "\x1b[200~" ++ body ++ "\x1b[201~";
    // Raw, so the PTY keeps every byte; then it asks for bracketed paste.
    const sh = try openScript(&app, try std.fmt.allocPrint(a, "stty raw -echo; printf '\\033[?2004h'; head -c {d} > out; sleep 30", .{want.len}), dir);
    const deadline = supervisor.monotonicMs() + 10_000;
    while (!(try sh.vt.inputModes()).bracketed_paste) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }

    // Cut across reads, in the text and in the end marker: what could be the
    // marker's start is left for the next read, as `feed` promises.
    try testing.expectEqual(@as(usize, 15), try app.feed("\x1b[200~hi\x17 q\r\nth"));
    try testing.expect(app.shell_paste);
    const second = "ere\x1b[A\x1b[2";
    const used = try app.feed(second);
    try testing.expectEqual(second.len - 3, used);
    try testing.expectEqual(@as(usize, 6), try app.feed("\x1b[201~"));
    try testing.expect(!app.shell_paste);
    try testing.expect(!app.pasting);
    try pumpUntilFile(&app, tmp.dir, "out", a, want);
    // ⌃w in the paste was text; the split is there, and from Normal `leader v x` closes it.
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    _ = try app.feed(leave ++ close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
}

test "paste: a shell that did not ask for markers gets the text, line breaks as CR; a long paste to a slow echoing reader all arrives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);

    const script = "stty raw -echo; echo ready; head -c 5 > one; head -c 128000 | tee two; sleep 30";
    _ = try openScript(&app, script, dir);
    const deadline = supervisor.monotonicMs() + 10_000;
    while (true) {
        _ = try app.pumpShells();
        if (has(try render(&app, &surface, a), "ready")) break;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    // CRLF is one line break, even cut across two reads.
    _ = try app.feed("\x1b[200~a\nb\r");
    _ = try app.feed("\nc\x1b[201~");
    try pumpUntilFile(&app, tmp.dir, "one", a, "a\rb\rc");

    // tee writes it all back: with nobody draining the output it would stop
    // reading, and the paste would stop fitting.
    const long = try a.alloc(u8, 128000);
    @memset(long, 'x');
    _ = try app.feed(try std.mem.concat(a, u8, &.{ "\x1b[200~", long, "\x1b[201~" }));
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expectEqualStrings("", app.message.items);
    try pumpUntilFile(&app, tmp.dir, "two", a, long);
}

/// Answers the pending `agent.takeover` of `agent` with this command.
fn takeOverRunning(app: *App, a: std.mem.Allocator, agent: []const u8, script: []const u8, cwd: []const u8) !void {
    try app.takeOver(agent, .right, true);
    _ = try t.sent(a, app);
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{
        .agent = agent,
        .state = "handed_over",
        .harness = "claude-code",
        .argv = &[_][]const u8{ "sh", "-c", script },
        .cwd = cwd,
        .env = &[_]struct { name: []const u8, value: []const u8 }{.{ .name = "FAKE_CFG", .value = "cfg-dir" }},
    }, .{}, &out.writer);
    try app.onResponse(takeoverRequest(app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{}) });
}

fn expectCleanEnv(got: []const u8) !void {
    try testing.expect(!has(got, "VENOM_TOKEN="));
    try testing.expect(!has(got, "VENOMX_TOKEN="));
    try testing.expect(!has(got, "VENOM_DESK_PRINCIPAL="));
    try testing.expect(has(got, "VENOM_AGENT="));
    try testing.expect(has(got, "KEEP_ME=yes"));
}

test "neither a shell nor a take-over child gets venom's tokens" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try env.put("VENOM_TOKEN", "vnt1.venom.owner.secret");
    try env.put("VENOMX_TOKEN", "vnt1.venomx.owner.secret");
    try env.put("VENOM_DESK_PRINCIPAL", "g3");
    try env.put("KEEP_ME", "yes");
    try shellApp(&app, &env, a);

    _ = try openScript(&app, "env > shell.env; echo done > shell.done; sleep 30", dir);
    try pumpUntilFile(&app, tmp.dir, "shell.done", a, "done\n");
    try expectCleanEnv(try tmp.dir.readFileAlloc(testing.io, "shell.env", a, .limited(1 << 20)));
    _ = try app.feed(close_split);

    try changed(&app, a, 41, "a3", "running", "settled");
    _ = try t.sent(a, &app);
    try takeOverRunning(&app, a, "a3", "env > over.env; echo done > over.done; sleep 30", dir);
    try pumpUntilFile(&app, tmp.dir, "over.done", a, "done\n");
    const over = try tmp.dir.readFileAlloc(testing.io, "over.env", a, .limited(1 << 20));
    try expectCleanEnv(over);
    // What the daemon set for the take-over still arrives.
    try testing.expect(has(over, "FAKE_CFG=cfg-dir"));
}

test "paste: a shell that never reads does not freeze the TUI, and `leader v x` still closes it" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);
    // `yes` in the foreground: it never reads, and its output never stops.
    const sh = try openScript(&app, "exec yes", "/tmp");
    const pid = sh.pid();
    const long = try a.alloc(u8, 1024 * 1024);
    @memset(long, 'x');
    const started = supervisor.monotonicMs();
    _ = try app.feed(try std.mem.concat(a, u8, &.{ "\x1b[200~", long, "\x1b[201~" }));
    _ = try app.pumpShells();
    try testing.expect(sh.pending());
    try testing.expect(supervisor.monotonicMs() - started < 5_000);
    _ = try app.feed(leave ++ close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
}

test "paste: one the reader stalls on is cut with no hole, its end marker still goes, and the user is told" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);

    // Asks for markers, then reads nothing for a while, then everything.
    const sh = try openScript(&app, "stty raw -echo; printf '\\033[?2004h'; sleep 2; exec cat > out", dir);
    var deadline = supervisor.monotonicMs() + 10_000;
    while (!(try sh.vt.inputModes()).bracketed_paste) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    sh.paste_stall_ms = 100;
    // Text whose every position is different, so a hole would show.
    var text: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    while (text.items.len < 1024 * 1024) : (n += 1) try text.print(a, "{d},", .{n});
    const half = text.items.len / 2;
    _ = try app.feed(try std.mem.concat(a, u8, &.{ "\x1b[200~", text.items[0..half] }));
    deadline = supervisor.monotonicMs() + 10_000;
    while (!has(app.message.items, "paste cut")) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    try testing.expect(has(app.message.items, "the shell stopped reading"));
    const sent = sh.paste_sent;
    try testing.expect(sent > 0 and sent < half);
    sh.paste_stall_ms = 5_000;
    sh.stall_at = supervisor.monotonicMs() + 5_000;
    sh.give_up_at = sh.stall_at;
    // The rest of the paste goes nowhere; a key typed after it comes last.
    _ = try app.feed(try std.mem.concat(a, u8, &.{ text.items[half..], "\x1b[201~" }));
    try testing.expect(!app.shell_paste);
    _ = try app.feed("Z");
    const want = try std.mem.concat(a, u8, &.{ "\x1b[200~", text.items[0..sent], "\x1b[201~Z" });
    try pumpUntilFile(&app, tmp.dir, "out", a, want);
}

test "paste: the total deadline cuts one too" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);
    const sh = try openScript(&app, "exec sleep 30", "/tmp");
    const long = try a.alloc(u8, 1024 * 1024);
    @memset(long, 'x');
    sh.paste_total_ms = 50;
    _ = try app.feed(try std.mem.concat(a, u8, &.{ "\x1b[200~", long, "\x1b[201~" }));
    const deadline = supervisor.monotonicMs() + 10_000;
    while (!has(app.message.items, "paste cut")) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    try testing.expect(has(app.message.items, "it took too long"));
    // Unbracketed: nothing is owed, so nothing is left queued.
    try testing.expect(!sh.pending());
}

test "a pasted line break in an attention prompt does not submit it; the prompt stays until a real enter" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a3","item":"r8","request":"r8","kind":"approval","reason":"Run zig build?","title":"theme module trve/bone","age_s":5,"grant":"exec:zig"}]}
    , .{}));
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    try app.openMenu("a3");
    _ = try app.feed("\r");
    _ = try t.sent(a, &app);
    _ = try app.feed("e");
    try testing.expect(app.prompt != null);
    _ = try app.feed("\x1b[200~rm -rf out\rmore\x1b\x03\x1b[201~");
    try testing.expect(app.prompt != null);
    try testing.expect(!app.quit);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expectEqualStrings("rm -rf out more", app.answer_input.value());
    _ = try app.feed("\r");
    const params = try takeOne(&app, a, "inbox.answer");
    try testing.expectEqualStrings("allow_edited", params.get("answer").?.string);
}

test "the keys hint: another agent's split still says where to answer it" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a3","item":"r8","request":"r8","kind":"approval","reason":"Run zig build?","title":"theme module trve/bone","age_s":5}]}
    , .{}));
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    try app.openMenu("a3");
    _ = try app.feed("\r");
    // Focused there, the keys work there: no hint.
    try testing.expect(!has(try render(&app, &surface, a), "⇥ to answer here"));
    // With the main transcript of another agent focused, they don't.
    _ = try app.feed("\x1b");
    _ = try app.feed("\t");
    try testing.expectEqual(@import("app.zig").Area.transcript, app.area());
    try testing.expect(has(try render(&app, &surface, a), "⇥ to answer here"));
}

test "a child flooding queries without reading can't grow the reply queue past its cap" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);
    // Raw, so nothing echoes; each DSR makes the terminal answer on stdin.
    const sh = try openScript(&app, "stty raw -echo; while :; do printf '\\033[6n'; done", "/tmp");
    sh.out_max = 4096;
    const left = struct {
        fn of(s: *const split.Shell) usize {
            return s.out_q.items.len - s.out_head;
        }
    }.of;
    const deadline = supervisor.monotonicMs() + 20_000;
    while (left(sh) + 32 < sh.out_max) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    // At the cap it holds, and the TUI stays usable.
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) {
        _ = try app.pumpShells();
        try testing.expect(left(sh) <= sh.out_max);
    }
    _ = try app.feed(leave ++ close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
}

test "a paste while a menu is over the shell does not reach it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);
    _ = try openScript(&app, "sleep 30", dir);
    try app.openMenu("a3");
    _ = try app.feed("\x1b[200~");
    try testing.expect(!app.shell_paste);
    try testing.expect(app.pasting);
    _ = try app.feed("x\x17\r");
    try testing.expect(app.menu != null);
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    _ = try app.feed("\x1b[201~");
    try testing.expect(!app.pasting);
}

/// Makes reads of `fd` fail as a persistent error would: not EOF, and not EIO.
fn breakReads(fd: c_int) !void {
    const nul = c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    if (nul < 0) return error.OpenFailed;
    defer _ = c.close(nul);
    if (c.dup2(nul, fd) < 0) return error.Dup2Failed;
}

test "a PTY read error closes the split and ends its process; a take-over's also takes the agent back" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);

    const sh = try openScript(&app, "exec sleep 30", "/tmp");
    const pid = sh.pid();
    try breakReads(sh.pty.fd);
    try testing.expect(try app.pumpShells());
    try testing.expect(app.splits.items[0].exited);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    try testing.expectEqualStrings("shell: PtyRead; its split closed, the agent keeps running", app.message.items);
    try testing.expectEqualStrings("", try t.sent(a, &app));
    _ = try app.feed("\x1b");
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);

    try changed(&app, a, 41, "a3", "running", "settled");
    _ = try t.sent(a, &app);
    const over = try openSleeper(&app, a, "a3");
    try changed(&app, a, 42, "a3", "settled", "handed_over");
    _ = try t.sent(a, &app);
    try breakReads(app.splits.items[0].shell.?.pty.fd);
    _ = try app.pumpShells();
    try testing.expect(app.splits.items[0].exited);
    try testing.expect(c.kill(over, @fromBackingInt(@intCast(0))) != 0);
    try testing.expectEqualStrings("agent.takeback(a3) ", try t.sent(a, &app));
    // The read error is said, not only the take-back.
    try testing.expect(has(app.message.items, "PtyRead"));
    try testing.expect(has(app.message.items, "taking a3 back"));
}

test "a shell's exit says it exited, once; `leader v x` says the split closed" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    try shellApp(&app, &env, a);

    _ = try openScript(&app, "exit 0", "/tmp");
    try waitExited(&app, 0);
    try testing.expectEqualStrings("the shell exited; the agent keeps running", app.message.items);
    _ = try app.feed("\x1b");

    _ = try openScript(&app, "sleep 30", "/tmp");
    _ = try app.feed(leave ++ close_split);
    _ = try app.pumpShells();
    try testing.expectEqualStrings("split closed; the agent keeps running", app.message.items);
}

/// The agent's own `agent.show` has `text` in its transcript.
fn transcriptHas(v: std.json.Value, text: []const u8) bool {
    for (v.object.get("transcript").?.array.items) |r| {
        if (r.object.get("text")) |x| if (x == .string and has(x.string, text)) return true;
    }
    return false;
}

test "live: an agent-view split sends a prompt to its agent and answers its approval, with another agent selected" {
    const script =
        \\{"turns":[{"match":"build","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build"}},{"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build?","echo":true}},{"text":"built it"}]},
        \\          {"match":"","steps":[{"text":"Done."}]}]}
    ;
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
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}/work", .{dir});
    var d: t.Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}), .script = script };
    defer d.deinit();
    try d.start();
    defer d.halt();

    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try t.until(&app, &link, &surface, &d, "connect", t.Connected{});

    _ = try d.run(a, &.{ "agent", "spawn", cwd, "--task=first", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "a1 settled", t.InState{ .id = "a1", .state = .settled });
    _ = try d.run(a, &.{ "agent", "spawn", cwd, "--task=second", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "a2 settled", t.InState{ .id = "a2", .state = .settled });
    const before = try a.dupe(u8, app.selected.items);
    const other: []const u8 = if (std.mem.eql(u8, before, "a1")) "a2" else "a1";

    // The other agent's view, its box: the prompt goes to that agent.
    try app.openMenu(other);
    _ = try app.feed("\r");
    try t.until(&app, &link, &surface, &d, "the split's transcript", SplitLoaded{});
    _ = try app.feed("\trun the build\r");
    try t.until(&app, &link, &surface, &d, "the approval", t.InState{ .id = other, .state = .needs_you });
    try testing.expectEqualStrings(before, app.selected.items);

    // Answered from its transcript, with the keys shown there.
    _ = try app.feed("\x1b");
    try t.until(&app, &link, &surface, &d, "the approval's keys", t.Shows{ .text = "y allow once" });
    _ = try app.feed("y");
    try t.until(&app, &link, &surface, &d, "settled again", t.InState{ .id = other, .state = .settled });
    try t.until(&app, &link, &surface, &d, "the harness's answer", t.Shows{ .text = "built it" });
    const shown = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{other}) });
    try testing.expect(transcriptHas(shown, "built it"));
    const kept = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{before}) });
    try testing.expect(!transcriptHas(kept, "built it"));
}

test "modes: Terminal is a focused shell; every key is the program's but ui.keys.leave_terminal" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    _ = try openScript(&app, "stty raw -echo; dd bs=1 count=5 of=out 2>/dev/null; sleep 30", dir);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    try testing.expect(has(try render(&app, &surface, a), "│  TERMINAL"));

    // ⌃w, ⌃c, esc, q and i go to the program; nothing here acts on them.
    _ = try app.feed("\x17\x03\x1b");
    _ = try app.feed("qi");
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(!app.quit);
    try pumpUntilFile(&app, tmp.dir, "out", a, "\x17\x03\x1bqi");

    // The default key leaves, in either encoding. Focus is on the list.
    _ = try app.feed("\x1d");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    // Focusing the split again is Terminal again.
    app.focus.set(3);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    _ = try app.feed(leave);
    try testing.expectEqual(KeyMode.normal, app.keyMode());

    // A rebound key replaces it, in the hint and the help as well.
    try app.requestKeysConfig();
    try t.answerConfig(&app, a, .leave_terminal, "{\"content\":\"\\\"ctrl+g\\\"\"}");
    _ = try t.sent(a, &app);
    app.focus.set(3);
    const bar = try render(&app, &surface, a);
    try testing.expect(has(bar, "⌃g leaves"));
    _ = try app.feed(leave);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    _ = try app.feed("\x07");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    // ⌃γ on the G key leaves as well: a non-Latin layout has the same way out.
    app.focus.set(3);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    _ = try app.feed("\x1b[947::103;5u");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    _ = try app.feed("?");
    try testing.expect(has(try render(&app, &surface, a), "⌃g"));
    _ = try app.feed("x");

    // A value that is no chord changes nothing; a backslash survives ZON.
    try app.requestKeysConfig();
    try t.answerConfig(&app, a, .leave_terminal, "{\"content\":\"\\\"ctrl+\\\"\"}");
    try testing.expectEqualStrings("⌃g", app.leaveTerminalText());
    try app.requestKeysConfig();
    try t.answerConfig(&app, a, .leave_terminal, "{\"content\":\"\\\"ctrl+\\\\\\\\\\\"\"}");
    try testing.expectEqualStrings("⌃\\", app.leaveTerminalText());
    _ = try t.sent(a, &app);
}

test "modes: ⌃w reaches the program in Terminal, and from Normal `leader v x` closes the split just left" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    const first = try openScript(&app, "sleep 30", "/tmp");
    const first_pid = first.pid();
    const second = try openScript(&app, "sleep 30", "/tmp");
    const second_pid = second.pid();
    // Into the older shell; ⌃w is the program's there.
    app.focus.set(3);
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 2), app.splits.items.len);
    _ = try app.feed(leave);
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(c.kill(first_pid, @fromBackingInt(@intCast(0))) != 0);
    try testing.expect(c.kill(second_pid, @fromBackingInt(@intCast(0))) == 0);
    // Then the newest, as before.
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    _ = try t.sent(a, &app);
}

test "modes: a split's box is Input; an approval arriving there leaves y as text" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try render(&app, &surface, a);
    try app.openMenu("a3");
    _ = try app.feed("\r");
    _ = try t.sent(a, &app);
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    _ = try app.feed("i");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    _ = try app.feed("o");
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"items":[{"agent":"a3","item":"r9","request":"r9","kind":"approval","reason":"Run rm?","title":"slow work","age_s":5,"grant":"exec:rm"}]}
    , .{}));
    _ = try app.feed("y");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try testing.expectEqualStrings("oy", app.boxOf("a3").?.value());
    try testing.expect(!has(try t.sent(a, &app), "inbox.answer"));
    // esc is one step: the split's transcript, in Normal, the draft kept.
    _ = try app.feed("\x1b");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try testing.expectEqual(@import("app.zig").Area.split, app.area());
    try testing.expectEqualStrings("oy", app.boxOf("a3").?.value());
    app.boxOf("a3").?.clear();
    _ = try t.sent(a, &app);
}

fn modesApp(app: *App, env: *std.process.Environ.Map, a: std.mem.Allocator, surface: *term.Surface) !void {
    app.resumes = harnesses.resumesTui;
    try env.put("PATH", "/usr/bin:/bin");
    app.env = env;
    try t.fixtureApp(app, a);
    _ = try render(app, surface, a);
    _ = try t.sent(a, app);
}

const a1_approval =
    \\{"items":[{"agent":"a1","item":"r1","request":"r1","kind":"approval","reason":"Run zig build?","title":"x","age_s":5,"grant":"exec:zig"}]}
;

test "modes: an after-this-turn take-over opens behind Input; typed text stays in the draft" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    try app.preselect("a3");
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    // a3 is running: \ 3 asks, enter picks "after this turn". Then the user types.
    _ = try app.feed("\\3\r");
    _ = try app.feed("ihel");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    // Background: the turn ends and the daemon answers the take-over.
    try changed(&app, a, 42, "a3", "running", "settled");
    const result =
        \\{"agent":"a3","state":"handed_over","harness":"claude-code","argv":["sleep","30"],"cwd":"/tmp","env":[]}
    ;
    try app.onResponse(takeoverRequest(&app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) });
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try testing.expectEqual(@import("app.zig").Area.input, app.area());
    try testing.expect(has(app.message.items, "\\ focuses its split"));
    _ = try app.feed("lo");
    try testing.expectEqualStrings("hello", app.input.value());
    // From Normal, `\` goes to it once the model has the hand-over.
    try changed(&app, a, 43, "a3", "settled", "handed_over");
    _ = try app.feed("\x1b");
    _ = try app.feed("\\");
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    _ = try t.sent(a, &app);
}

test "modes: a take-over a key asked for doesn't take the focus if Input came first" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    try changed(&app, a, 41, "a3", "running", "settled");
    try app.takeOver("a3", .right, true);
    _ = try app.feed("i");
    const result =
        \\{"agent":"a3","state":"handed_over","harness":"claude-code","argv":["sleep","30"],"cwd":"/tmp","env":[]}
    ;
    try app.onResponse(takeoverRequest(&app).?, .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) });
    try testing.expectEqual(KeyMode.input, app.keyMode());
    _ = try t.sent(a, &app);
}

test "modes: taken back elsewhere while in Terminal: the split stays, typed y approves nothing, ⌃c doesn't quit" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a, a1_approval, .{}));
    try changed(&app, a, 41, "a3", "running", "settled");
    _ = try t.sent(a, &app);
    const pid = try openSleeper(&app, a, "a3");
    try changed(&app, a, 42, "a3", "settled", "handed_over");
    _ = try t.sent(a, &app);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    // Background: another client takes a3 back. The harness goes, the split stays.
    try changed(&app, a, 43, "a3", "handed_over", "settled");
    _ = try t.sent(a, &app);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(app.splits.items[0].exited);
    try testing.expect(app.takeoverSplit("a3") == null);
    try testing.expect(has(try render(&app, &surface, a), "[process exited]"));
    const bar = try render(&app, &surface, a);
    try testing.expect(has(bar, "│  TERMINAL"));
    _ = pid;
    _ = try app.feed("y");
    _ = try app.feed("\x03");
    _ = try app.feed("\x17\t");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(!app.quit);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    // Quitting from here owes no second take-back.
    try app.releaseTakeovers();
    try testing.expectEqualStrings("", try t.sent(a, &app));
    // Esc leaves, and only now do keys mean Normal's.
    _ = try app.feed("\x1b");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
}

test "modes: a shell's exit in Terminal: same, and ui.keys.leave_terminal leaves too" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(std.json.Value, a, a1_approval, .{}));
    _ = try t.sent(a, &app);
    _ = try openScript(&app, "exit 0", "/tmp");
    try waitExited(&app, 0);
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    try testing.expect(has(try render(&app, &surface, a), "[process exited]  esc or ⌃] leaves"));
    _ = try app.feed("y");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    _ = try app.feed("\x03");
    try testing.expect(!app.quit);
    _ = try app.feed(leave);
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);

    // One that isn't focused just closes.
    _ = try openScript(&app, "exit 0", "/tmp");
    _ = try app.feed(leave);
    const deadline = supervisor.monotonicMs() + 10_000;
    while (app.splits.items.len > 0) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
    try testing.expectEqual(KeyMode.normal, app.keyMode());

    // A click away from an exited split ends it as well.
    _ = try openScript(&app, "exit 0", "/tmp");
    try waitExited(&app, 0);
    app.focus.set(0);
    _ = try app.pumpShells();
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
}

/// Pumps until split `i`'s program is gone and the split marked so.
fn waitExited(app: *App, i: usize) !void {
    const deadline = supervisor.monotonicMs() + 10_000;
    while (!app.splits.items[i].exited) {
        _ = try app.pumpShells();
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
    }
}

test "modes: a box whose agent was handed over: typed T and \\ stay inert; esc first" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    try app.preselect("a3");
    _ = try render(&app, &surface, a);
    _ = try t.sent(a, &app);
    _ = try app.feed("i");
    _ = try app.feed("Wh");
    try changed(&app, a, 42, "a3", "running", "handed_over");
    _ = try t.sent(a, &app);
    try testing.expectEqual(KeyMode.input, app.keyMode());
    _ = try app.feed("at. The \\");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    try testing.expect(app.menu == null);
    try testing.expectEqualStrings("Wh", app.input.value());
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try testing.expect(has(try render(&app, &surface, a), "esc first, then T take back"));
    // Esc, and T is T.
    _ = try app.feed("\x1b");
    _ = try app.feed("T");
    try testing.expect(has(try t.sent(a, &app), "agent.takeback(a3)"));

    // With a split: typed T doesn't end the harness, nor \ jump to it.
    try changed(&app, a, 43, "a3", "handed_over", "settled");
    _ = try t.sent(a, &app);
    const pid = try openSleeper(&app, a, "a3");
    try changed(&app, a, 44, "a3", "settled", "handed_over");
    _ = try t.sent(a, &app);
    _ = try app.feed(leave);
    _ = try app.feed("i");
    _ = try app.feed("\\T");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try testing.expectEqual(@as(usize, 1), app.splits.items.len);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) == 0);
    try testing.expect(has(try render(&app, &surface, a), "esc first, then \\ focus split"));
    _ = try app.feed("\x1b");
    _ = try app.feed("\\");
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    _ = try app.feed(leave);
    _ = try app.feed("T");
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);
    try testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    _ = try t.sent(a, &app);
}

test "modes: fork_ended while typing leaves the selection and the draft alone" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    const ended = "{\"seq\":50,\"ts\":\"2026-11-06T14:31:00.000Z\",\"source\":\"venom/0e1\",\"type\":\"agent.fork_ended\",\"data\":{\"agent\":\"a1\",\"ok\":true,\"fork\":\"a3\"}}";
    app.context_panel.forking = try app.context_panel.gpa.dupe(u8, "a1");
    _ = try app.feed("ifor a1 ");
    try t.feedJson(&app, a, ended);
    try testing.expectEqualStrings("a1", app.selected.items);
    try testing.expectEqualStrings("for a1 ", app.input.value());
    try testing.expect(has(app.message.items, "forked to a3"));
    _ = try app.feed("\x03\x1b");
    _ = try t.sent(a, &app);
    // From Normal it still follows the fork.
    app.context_panel.forking = try app.context_panel.gpa.dupe(u8, "a1");
    _ = try app.feed("\x1b");
    try t.feedJson(&app, a, ended);
    try testing.expectEqualStrings("a3", app.selected.items);
    _ = try t.sent(a, &app);
}

test "modes: an agent leaving the list while typing doesn't move the box to another" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    _ = try app.feed("ihel");
    const sel = try a.dupe(u8, app.selected.items);
    const r = try app.buildRows();
    // As if it had left the rows: the walk gives way only outside the box.
    var gone = r;
    gone.rows = r.rows[0..0];
    try app.syncCursor(gone);
    try testing.expectEqualStrings(sel, app.selected.items);
    try testing.expectEqualStrings("hel", app.input.value());
    _ = try t.sent(a, &app);
}

test "modes: a spawn the model learns of while typing doesn't take the view" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    _ = try app.feed("ihel");
    app.follow = .{ .agent = try ta.dupe(u8, "a3"), .start = .show };
    try @import("new_agent.zig").followSpawn(&app);
    try testing.expectEqualStrings("a1", app.selected.items);
    try testing.expectEqual(KeyMode.input, app.keyMode());
    try testing.expectEqualStrings("hel", app.input.value());
    try testing.expect(has(app.message.items, "a3 started"));
    // The menu it might have asked for waits for a key too.
    app.follow = .{ .agent = try ta.dupe(u8, "a3"), .start = .split };
    try @import("new_agent.zig").followSpawn(&app);
    try testing.expect(app.menu == null);
    _ = try t.sent(a, &app);
}

test "modes: legacy ⌃] reaches the program when rebound; the dialog while starting is Normal" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    var env = std.process.Environ.Map.init(ta);
    defer env.deinit();
    var surface = try term.Surface.init(ta, 180, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try modesApp(&app, &env, a, &surface);
    // In the box a stray control byte is nothing.
    _ = try app.feed("i");
    _ = try app.feed("a\x1db");
    try testing.expectEqualStrings("ab", app.input.value());
    app.input.clear();
    _ = try app.feed("\x1b");
    try app.requestKeysConfig();
    try t.answerConfig(&app, a, .leave_terminal, "{\"content\":\"\\\"ctrl+g\\\"\"}");
    // A plain key is refused: it could never reach the program.
    try app.requestKeysConfig();
    try t.answerConfig(&app, a, .leave_terminal, "{\"content\":\"\\\"q\\\"\"}");
    try testing.expectEqualStrings("⌃g", app.leaveTerminalText());
    _ = try t.sent(a, &app);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    _ = try openScript(&app, "stty raw -echo; echo ready > ready; dd bs=1 count=1 of=out 2>/dev/null; sleep 30", dir);
    try pumpUntilFile(&app, tmp.dir, "ready", a, "ready\n");
    _ = try app.feed("\x1d");
    try testing.expectEqual(KeyMode.terminal, app.keyMode());
    try pumpUntilFile(&app, tmp.dir, "out", a, "\x1d");
    _ = try app.feed("\x07");
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    _ = try app.feed(close_split);
    try testing.expectEqual(@as(usize, 0), app.splits.items.len);

    // `leader v x` after opening a new split closes that one, not one left before it.
    _ = try openScript(&app, "sleep 30", "/tmp");
    const older = app.splits.items[0].shell.?.pid();
    _ = try app.feed("\x07");
    _ = try openScript(&app, "sleep 30", "/tmp");
    const newer = app.splits.items[1].shell.?.pid();
    app.focus.set(0);
    _ = try app.feed(close_split);
    try testing.expect(c.kill(newer, @fromBackingInt(@intCast(0))) != 0);
    try testing.expect(c.kill(older, @fromBackingInt(@intCast(0))) == 0);
    _ = try app.feed(close_split);

    // The dialog is Input until a spawn starts; then ⌃c quits, so Normal.
    _ = try app.feed("n");
    try testing.expectEqual(KeyMode.input, app.keyMode());
    app.dialog.?.starting = .show;
    try testing.expectEqual(KeyMode.normal, app.keyMode());
    app.dialog.?.starting = null;
    _ = try app.feed("\x1b");
    _ = try t.sent(a, &app);
}
