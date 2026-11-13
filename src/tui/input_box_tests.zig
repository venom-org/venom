//! The input box: snapshots of the meter below and
//! above `ui.context.warn_at` and of the disabled state, the send keys, and
//! a prompt reaching the fake harness through a real daemon.
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const harnesses = @import("../harnesses.zig");
const App = @import("app.zig").App;
const KeyMode = @import("app.zig").KeyMode;
const keys = @import("keys.zig");
const Link = @import("link.zig").Link;
const input_box = @import("input_box.zig");
const model = @import("model.zig");
const view = @import("view.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const shift_enter = "\x1b[13;2u";
const alt_enter = "\x1b\r";

/// agent.show's answer for a1 with these extra fields.
fn showOf(a: std.mem.Allocator, state: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"agent":"a1","title":"venom-echo conformance","harness":"claude-code","state":"{s}","unread":false,"workspace":"/home/me/venom-org","cwd":"/home/me/venom-org/venom-std","created_at":1794061200000,"changed_at":1794061740000,"turns":1,"requests":[],"transcript":[],"permission_mode":"ask","context_warn_at":80{s}}}
    , .{ state, extra });
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init(self: *Fixture) !void {
        self.arena = .init(ta);
        self.app = App.init(ta);
        try t.fixtureApp(&self.app, self.a());
        // Selects a1, the first row, as the first draw does.
        var surface = try term.Surface.init(ta, 100, 28);
        var discard: std.Io.Writer.Discarding = .init(&.{});
        defer surface.deinit(&discard.writer);
        try view.render(&self.app, &surface);
        _ = try t.sent(self.a(), &self.app);
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.arena.deinit();
    }

    fn a(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Answers the pending agent.show, as for a1 in `state`.
    fn show(self: *Fixture, state: []const u8, extra: []const u8) !void {
        try t.answer(&self.app, self.a(), "agent.show", try showOf(self.a(), state, extra));
    }

    /// Draws just the box, at 72×4, and returns its rows.
    fn box(self: *Fixture, surface: *term.Surface) ![]const u8 {
        const sel = self.app.model.find(self.app.selected.items);
        try input_box.draw(&self.app, surface, self.a(), .{ .width = surface.width, .height = surface.height }, sel, &self.app.model.detail);
        return t.dump(self.a(), surface);
    }

    fn outbox(self: *Fixture) ![]const Value {
        var out: std.ArrayList(Value) = .empty;
        for (self.app.outbox.items) |line| {
            try out.append(self.a(), try std.json.parseFromSliceLeaky(Value, self.a(), try self.a().dupe(u8, line), .{}));
            ta.free(line);
        }
        self.app.outbox.clearRetainingCapacity();
        return out.items;
    }
};

fn surfaceBox() !term.Surface {
    return term.Surface.init(ta, 72, input_box.height);
}

fn expectSnapshot(comptime name: []const u8, got: []const u8) !void {
    const want = @embedFile("testdata/" ++ name);
    if (!std.mem.eql(u8, want, got)) std.debug.print("{s}:\n{s}\n", .{ name, got });
    try testing.expectEqualStrings(want, got);
}

/// The first cell of the meter's row showing `glyph`.
fn findCell(surface: *const term.Surface, y: u16, glyph: []const u8) ?u16 {
    var x: u16 = 0;
    while (x < surface.width) : (x += 1) {
        const cell = surface.get(x, y) orelse continue;
        if (std.mem.eql(u8, cell.text, glyph)) return x;
    }
    return null;
}

test "snapshot: meter below warn_at shows mode, model and 62%, not gold" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try surfaceBox();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try t.answer(&f.app, f.a(), "agent.show", try showOf(f.a(), "settled",
        \\,"model":"opus 5.5","context":{"used":124000,"window":200000,"source":"estimate","at":1}
    ));
    try expectSnapshot("input_box_below.txt", try f.box(&surface));
    const on = surface.get(findCell(&surface, 2, "▰").?, 2).?;
    try testing.expectEqual(f.app.theme.secondary.fg, on.style.fg);
    try testing.expect(!std.meta.eql(on.style.fg, f.app.chrome.text(f.app.chrome.theme.gold).fg));
}

test "snapshot: meter above warn_at turns gold, cells and counts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try surfaceBox();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try f.show("settled",
        \\,"model":"opus 5.5","context":{"used":170000,"window":200000,"source":"estimate","at":1}
    );
    try expectSnapshot("input_box_above.txt", try f.box(&surface));
    const gold = f.app.chrome.text(f.app.chrome.theme.gold).fg;
    try testing.expectEqual(gold, surface.get(findCell(&surface, 2, "▰").?, 2).?.style.fg);
    // The counts too; the empty cells stay faint.
    try testing.expectEqual(gold, surface.get(findCell(&surface, 2, "8").?, 2).?.style.fg);
    try testing.expectEqual(f.app.theme.faint.fg, surface.get(findCell(&surface, 2, "▱").?, 2).?.style.fg);
}

test "meter: warn_at comes from the daemon; exactly at it is not above it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try surfaceBox();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    const gold = f.app.chrome.text(f.app.chrome.theme.gold).fg;

    try f.show("settled",
        \\,"context":{"used":160000,"window":200000,"source":"exact","at":1}
    );
    _ = try f.box(&surface);
    try testing.expect(!std.meta.eql(surface.get(findCell(&surface, 2, "▰").?, 2).?.style.fg, gold));

    // agent.show carries the config; 62% is above a warn_at of 50.
    try f.app.model.applyShow(try std.json.parseFromSliceLeaky(Value, f.a(),
        \\{"agent":"a1","context_warn_at":50,"context":{"used":124000,"window":200000,"source":"exact","at":1}}
    , .{}));
    _ = try f.box(&surface);
    try testing.expectEqual(gold, surface.get(findCell(&surface, 2, "▰").?, 2).?.style.fg);
}

test "footer: before anything is reported, and short of room" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try surfaceBox();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try f.show("settled", "");
    const empty = try f.box(&surface);
    try testing.expect(std.mem.indexOf(u8, empty, "ask mode") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "context ▱▱▱▱▱▱▱▱▱▱ —") != null);

    try f.app.model.applyShow(try std.json.parseFromSliceLeaky(Value, f.a(),
        \\{"agent":"a1","permission_mode":"accept_edits","model":"opus 5.5","context":{"used":124000,"window":200000,"source":"exact","at":1}}
    , .{}));
    try testing.expect(std.mem.indexOf(u8, try f.box(&surface), "accept edits mode  opus 5.5") != null);

    // Its label goes first, then the left side, the cells, the counts.
    const widths = [_]struct { u16, []const u8, ?[]const u8 }{
        .{ 72, "context ▰▰▰▰▰▰▱▱▱▱ 62% · 124k / 200k", null },
        .{ 40, " accep…  ▰▰▰▰▰▰▱▱▱▱ 62% · 124k / 200k", "context" },
        .{ 32, "▰▰▰▰▰▰▱▱▱▱ 62% · 124k / 200k", "accep" },
        .{ 22, "62% · 124k / 200k", "▰" },
        .{ 8, "62%", "·" },
    };
    for (widths) |row| {
        var narrow = try term.Surface.init(ta, row[0], input_box.height);
        defer narrow.deinit(&discard.writer);
        const screen = try f.box(&narrow);
        try testing.expect(std.mem.indexOf(u8, screen, row[1]) != null);
        if (row[2]) |gone| try testing.expect(std.mem.indexOf(u8, screen, gone) == null);
    }
}

test "snapshot: disabled with a banner while handed over; text goes nowhere; T takes back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try surfaceBox();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    f.app.model.find("a1").?.state = .handed_over;
    try f.show("handed_over", "");
    try expectSnapshot("input_box_disabled.txt", try f.box(&surface));

    // `i` still focuses it, but keys are not text and nothing is sent.
    _ = try f.app.feed("i");
    try testing.expectEqual(@import("app.zig").Area.input, f.app.area());
    _ = try f.app.feed("hello\r");
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "own TUI") != null);
    // A paste is dropped, whatever letters it holds: no take-back, no
    // split menu, no help, no quit, no focus change.
    _ = try f.app.feed("\x1b[200~Tests failed \\ q ? x S\t\r\x1b[201~");
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    try testing.expect(!f.app.quit and !f.app.help and f.app.menu == null);
    try testing.expectEqual(@import("app.zig").Area.input, f.app.area());
    // Typed, the letters that aren't the banner's keys do nothing either.
    _ = try f.app.feed("qx?Sest failed");
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    try testing.expect(!f.app.quit and !f.app.help and f.app.menu == null);
    try testing.expectEqual(@import("app.zig").Area.input, f.app.area());
    try testing.expectEqualStrings("esc first, then T take back  \\ split", f.app.inputHint());

    // Nor do T and \\: esc and tab leave, then they work.
    _ = try f.app.feed("T\\");
    try testing.expect(f.app.menu == null);
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    _ = try f.app.feed("\x1b");
    _ = try f.app.feed("\\");
    try testing.expect(f.app.menu != null);
    _ = try f.app.feed("\x1b");
    try testing.expect(f.app.menu == null);
    try testing.expectEqual(@import("app.zig").Area.list, f.app.area());
    _ = try f.app.feed("i\t");
    try testing.expectEqual(@import("app.zig").Area.list, f.app.area());
    _ = try f.app.feed("T");
    const out = try f.outbox();
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("agent.takeback", out[0].object.get("verb").?.string);
    // The box has the focus, so ⌃c is Input's: only from Normal does it quit.
    _ = try f.app.feed("i");
    _ = try f.app.feed("\x03");
    try testing.expect(!f.app.quit);
    _ = try f.app.feed("\x1b");
    _ = try f.app.feed("\x03");
    try testing.expect(f.app.quit);
}

/// The id of the pending send.
fn pendingSend(app: *App) i64 {
    var it = app.pending.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .send) return e.key_ptr.*;
    unreachable;
}

const refused: @import("proto").Response.Body = .{ .@"error" = .{ .code = "conflict.turn_running", .message = "", .data = null } };

test "drafts: the box's text stays with its agent across a switch" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.app.feed("ifor a1\x1b");
    _ = try f.app.feed("j");
    try testing.expectEqualStrings("a2", f.app.selected.items);
    try testing.expectEqualStrings("", f.app.input.value());
    _ = try f.app.feed("k");
    try testing.expectEqualStrings("a1", f.app.selected.items);
    try testing.expectEqualStrings("for a1", f.app.input.value());
    _ = try t.sent(f.a(), &f.app);
}

test "a refused send returns to its own agent, in front of what was written since" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    // Same agent, typed since: nothing is lost.
    _ = try f.app.feed("ifirst\r");
    const first = pendingSend(&f.app);
    _ = try t.sent(f.a(), &f.app);
    _ = try f.app.feed("second");
    try f.app.onResponse(first, refused);
    try testing.expectEqualStrings("first second", f.app.input.value());
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "conflict.turn_running") != null);
    f.app.input.clear();

    // Refused after a switch: not in a2's box, so enter can't send it to a2.
    _ = try f.app.feed("for a1\r\x1b");
    const id = pendingSend(&f.app);
    _ = try t.sent(f.a(), &f.app);
    _ = try f.app.feed("j");
    try testing.expectEqualStrings("a2", f.app.selected.items);
    try f.app.onResponse(id, refused);
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "a1's box") != null);
    _ = try f.app.feed("r\r");
    try testing.expect(std.mem.indexOf(u8, try t.sent(f.a(), &f.app), "agent.send") == null);
    _ = try f.app.feed("\x1b");
    // Back on a1 it is there.
    _ = try f.app.feed("k");
    try testing.expectEqualStrings("for a1", f.app.input.value());
    _ = try t.sent(f.a(), &f.app);
}

test "a lost connection returns unanswered prompts to their agents, oldest first" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.app.feed("ione\r");
    _ = try f.app.feed("two\r");
    _ = try f.app.feed("three");
    try f.app.onDisconnected();
    try testing.expectEqualStrings("one two three", f.app.input.value());
    try testing.expect(f.app.pending.count() == 0 and f.app.outbox.items.len == 0);

    // One on another agent waits in that agent's draft.
    try f.app.onConnected();
    f.app.input.clear();
    _ = try f.app.feed("for a1\r\x1b");
    _ = try f.app.feed("j");
    try f.app.onDisconnected();
    try testing.expectEqualStrings("", f.app.input.value());
    _ = try f.app.feed("k");
    try testing.expectEqualStrings("for a1", f.app.input.value());
}

test "send keys pick the mode by state and capability; a refusal or failure keeps the text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const expectSend = struct {
        fn run(x: *Fixture, mode: []const u8, text: []const u8) !void {
            const out = try x.outbox();
            try testing.expectEqual(@as(usize, 1), out.len);
            try testing.expectEqualStrings("agent.send", out[0].object.get("verb").?.string);
            const p = out[0].object.get("params").?.object;
            try testing.expectEqualStrings(mode, p.get("mode").?.string);
            try testing.expectEqualStrings(text, p.get("text").?.string);
            try testing.expectEqualStrings("a1", p.get("agent").?.string);
            try testing.expectEqualStrings("", x.app.input.value());
        }
    }.run;

    // Between turns: every key is a turn.
    f.app.model.find("a1").?.state = .settled;
    try f.show("settled",
        \\,"steer":"inject","interrupt":true
    );
    _ = try f.app.feed("i");
    try testing.expectEqualStrings("⏎ send  esc back  ⌃c clear", f.app.inputHint());
    _ = try f.app.feed("one\r");
    try expectSend(&f, "turn", "one");
    _ = try f.app.feed("two" ++ alt_enter);
    try expectSend(&f, "turn", "two");

    // Mid-turn on a harness that injects: ⏎ steers, ⇧⏎ queues, ⌥⏎ interrupts.
    f.app.model.find("a1").?.state = .running;
    try testing.expectEqualStrings("⏎ steer  ⇧⏎ queue  ⌥⏎ interrupt and send  esc back", f.app.inputHint());
    _ = try f.app.feed("only proto\r");
    try expectSend(&f, "steer", "only proto");
    _ = try f.app.feed("later" ++ shift_enter);
    try expectSend(&f, "turn", "later");
    _ = try f.app.feed("now" ++ alt_enter);
    try expectSend(&f, "interrupt_then_send", "now");

    // Needs you counts as mid-turn.
    f.app.model.find("a1").?.state = .needs_you;
    _ = try f.app.feed("instead\r");
    try expectSend(&f, "steer", "instead");

    // The placeholder says what ⏎ does.
    var surface = try surfaceBox();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try testing.expect(std.mem.indexOf(u8, try f.box(&surface), "Enter steers, ⇧⏎ queues") != null);

    // A harness that can neither queue nor interrupt: refused here.
    try f.app.model.applyShow(try std.json.parseFromSliceLeaky(Value, f.a(),
        \\{"agent":"a1","steer":"none","interrupt":false}
    , .{}));
    _ = try f.app.feed("keep me\r");
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    try testing.expectEqualStrings("keep me", f.app.input.value());
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "between turns") != null);
    _ = try f.app.feed(alt_enter);
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "cannot interrupt") != null);
    f.app.input.clear();

    // A send the daemon refuses comes back into the box, with its code.
    f.app.model.find("a1").?.state = .settled;
    _ = try f.app.feed("again\r");
    try expectSend(&f, "turn", "again");
    var it = f.app.pending.iterator();
    var id: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .send) {
        id = e.key_ptr.*;
    };
    try f.app.onResponse(id.?, .{ .@"error" = .{ .code = "conflict.turn_running", .message = "", .data = null } });
    try testing.expectEqualStrings("again", f.app.input.value());
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "agent send: conflict.turn_running") != null);
}

test "paste: a pasted line break is text, it does not send" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.app.feed("i");
    _ = try f.app.feed("\x1b[200~first\rsecond\tthird\x1b[201~");
    try testing.expectEqualStrings("first second third", f.app.input.value());
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
    try testing.expectEqual(@import("app.zig").Area.input, f.app.area());
    // After the paste, enter sends again.
    _ = try f.app.feed("\r");
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expectEqual(@as(usize, 1), f.app.outbox.items.len);
    _ = try t.sent(f.a(), &f.app);
}

/// A prompt the fake harness matches, so its answer proves it arrived.
const script =
    \\{"turns":[{"match":"ping","steps":[{"context":{"used":170000,"window":200000}},{"text":"pong from the harness"}]},
    \\          {"match":"after","steps":[{"text":"ran after the interrupt"}]},
    \\          {"match":"slow","steps":[{"text":"working"},{"sleep_ms":20000}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

const ContextIs = struct {
    used: u64,
    pub fn check(self: ContextIs, app: *App, _: *term.Surface) !bool {
        const got = app.model.detail.context orelse return false;
        return got.used == self.used;
    }
};

const SteerKnown = struct {
    pub fn check(_: SteerKnown, app: *App, _: *term.Surface) !bool {
        return app.model.detail.steer != .unknown and app.model.detail.model.len > 0;
    }
};

test "live: a prompt typed in the box reaches the fake harness; the footer and meter follow; ⌥⏎ interrupts and sends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    // warn_at from the daemon's config: 85% is below 90, not gold.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig(".agents = .{ .mode = .plan }, .ui = .{ .context = .{ .warn_at = 90 } }") });
    try tmp.dir.createDirPath(testing.io, "work");
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
    var d: t.Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}), .script = script };
    defer d.deinit();
    try d.start();
    defer d.halt();

    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 100, 26);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);

    try t.until(&app, &link, &surface, &d, "connect", t.Connected{});
    _ = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{work}), "--task=say hello", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "a1 settled", t.InState{ .id = "a1", .state = .settled });
    try t.until(&app, &link, &surface, &d, "its transcript", t.Shows{ .text = "Done." });

    // The box's footer comes from agent.show: config's mode, the fake's
    // model, and its adapter's capabilities once it is bound.
    try t.until(&app, &link, &surface, &d, "capabilities", SteerKnown{});
    try t.until(&app, &link, &surface, &d, "the footer", t.Shows{ .text = "plan mode  fake-model" });
    try testing.expectEqual(model.Steer.queue, app.model.detail.steer);
    try testing.expectEqual(@as(?bool, true), app.model.detail.interrupt);
    try testing.expectEqual(@as(u8, 90), app.model.detail.warn_at);

    // Typed in the box, sent with ⏎: the harness's answer proves it arrived.
    _ = try app.feed("iping the harness\r");
    try t.until(&app, &link, &surface, &d, "the harness's answer", t.Shows{ .text = "pong from the harness" });
    try t.until(&app, &link, &surface, &d, "the meter", ContextIs{ .used = 170000 });
    try t.until(&app, &link, &surface, &d, "the meter's text", t.Shows{ .text = "85% · 170k / 200k" });
    try testing.expect(!input_box.meter(170000, 200000, app.model.detail.warn_at).?.hot);
    try t.until(&app, &link, &surface, &d, "a1 settled again", t.InState{ .id = "a1", .state = .settled });

    // agent.show as a script sees it.
    const shown = (try d.run(a, &.{ "agent", "show", "--agent=a1" })).object;
    try testing.expectEqualStrings("fake-model", shown.get("model").?.string);
    try testing.expectEqualStrings("plan", shown.get("permission_mode").?.string);
    try testing.expectEqualStrings("queue", shown.get("steer").?.string);
    try testing.expect(shown.get("interrupt").?.bool);
    try testing.expectEqual(@as(i64, 90), shown.get("context_warn_at").?.integer);
    try testing.expectEqual(@as(i64, 170000), shown.get("context").?.object.get("used").?.integer);

    // A slow turn, then ⌥⏎: it is interrupted and the new prompt runs.
    _ = try app.feed("slow work\r");
    try t.until(&app, &link, &surface, &d, "a1 running", t.InState{ .id = "a1", .state = .running });
    _ = try app.feed("after the interrupt" ++ alt_enter);
    try t.until(&app, &link, &surface, &d, "the new prompt's answer", t.Shows{ .text = "ran after the interrupt" });
    try t.until(&app, &link, &surface, &d, "a1 settled at last", t.InState{ .id = "a1", .state = .settled });
    try testing.expectEqualStrings("", app.input.value());
    // The slow turn ended interrupted, and the new prompt's turn came after it.
    const after = (try d.run(a, &.{ "agent", "show", "--agent=a1" })).object.get("transcript").?.array.items;
    var interrupted_at: ?usize = null;
    var answered_at: ?usize = null;
    for (after, 0..) |r, i| {
        const o = r.object;
        if (std.mem.eql(u8, o.get("type").?.string, "turn.ended") and std.mem.eql(u8, o.get("reason").?.string, "interrupted")) interrupted_at = i;
        if (o.get("text")) |x| if (std.mem.eql(u8, x.string, "ran after the interrupt")) {
            answered_at = i;
        };
    }
    try testing.expect(interrupted_at.? < answered_at.?);
}

test "modes: i and esc go in and out of Input, back where they came from, and the draft stays" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const Area = @import("app.zig").Area;
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());
    try testing.expectEqualStrings("NORMAL", KeyMode.normal.label());
    try testing.expectEqualStrings("\x1b[0 q", KeyMode.normal.cursorSequence());
    // `r` is no longer the way in.
    _ = try f.app.feed("r");
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());

    // From the list, and back to it.
    _ = try f.app.feed("i");
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    try testing.expectEqualStrings("INPUT", KeyMode.input.label());
    try testing.expectEqualStrings("\x1b[6 q", KeyMode.input.cursorSequence());
    _ = try f.app.feed("draft");
    _ = try f.app.feed("\x1b");
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());
    try testing.expectEqual(Area.list, f.app.area());
    try testing.expectEqualStrings("draft", f.app.input.value());

    // From the transcript, and back to it.
    _ = try f.app.feed("\t");
    try testing.expectEqual(Area.transcript, f.app.area());
    _ = try f.app.feed("i");
    try testing.expectEqual(Area.input, f.app.area());
    _ = try f.app.feed("!\x1b");
    try testing.expectEqual(Area.transcript, f.app.area());
    try testing.expectEqualStrings("draft!", f.app.input.value());

    // Tab reaches the box too, and esc returns the way it came.
    _ = try f.app.feed("\t");
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    _ = try f.app.feed("\x1b");
    try testing.expectEqual(Area.transcript, f.app.area());
    _ = try f.app.feed("\x1b");
    try testing.expectEqual(Area.list, f.app.area());
    f.app.input.clear();

    // The filter and the new-agent dialog are Input as well.
    _ = try f.app.feed("/");
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    _ = try f.app.feed("q\x03");
    try testing.expect(!f.app.quit and f.app.filtering);
    try testing.expectEqualStrings("", f.app.filter_input.value());
    _ = try f.app.feed("\x1b");
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());
    _ = try f.app.feed("n");
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    _ = try f.app.feed("\x03");
    try testing.expect(!f.app.quit and f.app.dialog != null);
    _ = try f.app.feed("\x1b");
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());
    _ = try t.sent(f.a(), &f.app);
}

test "modes: the status bar names the mode" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try term.Surface.init(ta, 100, 28);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try t.dump(f.a(), &surface), "│ NORMAL") != null);
    _ = try f.app.feed("i");
    try view.render(&f.app, &surface);
    const typing = try t.dump(f.a(), &surface);
    try testing.expect(std.mem.indexOf(u8, typing, "│ INPUT") != null);
    try testing.expect(std.mem.indexOf(u8, typing, "╭ Input ") != null);
    try testing.expect(std.mem.indexOf(u8, typing, "Reply") == null);
    _ = try t.sent(f.a(), &f.app);
}

fn mentionsReply(text: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= text.len) : (i += 1) if (std.ascii.eqlIgnoreCase(text[i..][0..5], "reply")) return true;
    return false;
}

test "modes: no Reply is left in the keys or their help" {
    for (keys.table) |b| {
        try testing.expect(!mentionsReply(b.label));
        try testing.expect(!mentionsReply(b.keys));
    }
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var surface = try term.Surface.init(ta, 100, 90);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try f.app.feed("?");
    try view.render(&f.app, &surface);
    const help = try t.dump(f.a(), &surface);
    try testing.expect(std.mem.indexOf(u8, help, "input: write to the selected agent") != null);
    try testing.expect(!mentionsReply(help));
    _ = try t.sent(f.a(), &f.app);
}

test "modes: no \"reply\" and no old key in a message or label in the sources" {
    const sources = [_][]const u8{ @embedFile("app.zig"), @embedFile("view.zig"), @embedFile("keys.zig"), @embedFile("input_box.zig"), @embedFile("context_panel.zig"), @embedFile("inbox_view.zig"), @embedFile("new_agent.zig"), @embedFile("settings.zig"), @embedFile("settings_view.zig"), @embedFile("split.zig"), @embedFile("fan_out.zig"), @embedFile("usage_view.zig"), @embedFile("workspaces.zig"), @embedFile("agent_list.zig") };
    for (sources) |src| {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//")) continue;
            // Inside a string on a code line.
            var parts = std.mem.splitScalar(u8, line, '"');
            var inside = false;
            while (parts.next()) |part| : (inside = !inside) {
                if (inside and (mentionsReply(part) or std.mem.indexOf(u8, part, " r there") != null)) {
                    std.debug.print("still says it: {s}\n", .{line});
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "modes: an approval arriving while typing leaves the mode alone, and y stays text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.app.feed("i");
    _ = try f.app.feed("ok");
    try f.show("running", "");
    _ = try t.sent(f.a(), &f.app);
    // The approval lands: an inbox item, the agent's state and its request.
    try f.app.inbox.apply(try std.json.parseFromSliceLeaky(Value, f.a(),
        \\{"items":[{"agent":"a1","item":"r1","request":"r1","kind":"approval","reason":"Run zig build?","title":"venom-echo conformance","age_s":5,"grant":"exec:zig"}]}
    , .{}));
    f.app.model.find("a1").?.state = .needs_you;
    try testing.expect(f.app.itemOf("a1") != null);
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    // Every approval key is text here: y, a, e, n and r.
    _ = try f.app.feed("yaenr");
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    try testing.expectEqualStrings("okyaenr", f.app.input.value());
    try testing.expect(f.app.prompt == null);
    const sent = try f.outbox();
    for (sent) |line| try testing.expect(!std.mem.eql(u8, line.object.get("verb").?.string, "inbox.answer"));

    // Out in Normal, on the transcript, the same `y` answers it.
    _ = try f.app.feed("\x1b");
    _ = try f.app.feed("\t");
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());
    try testing.expectEqual(@import("app.zig").Area.transcript, f.app.area());
    _ = try f.app.feed("y");
    try testing.expectEqualStrings("okyaenr", f.app.input.value());
    var answered = false;
    for (try f.outbox()) |line| answered = answered or std.mem.eql(u8, line.object.get("verb").?.string, "inbox.answer");
    try testing.expect(answered);
}

test "modes: ⌃c clears the draft in Input and quits in Normal; ⌃u and ⌃w edit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.app.feed("i");
    _ = try f.app.feed("two words");
    _ = try f.app.feed("\x17"); // ⌃w: a word
    try testing.expectEqualStrings("two ", f.app.input.value());
    _ = try f.app.feed("\x15"); // ⌃u: to the start, and no context panel
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expect(f.app.context_panel.agent == null);
    _ = try f.app.feed("again");
    _ = try f.app.feed("\x03");
    try testing.expectEqualStrings("", f.app.input.value());
    try testing.expect(!f.app.quit);
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    // On an empty draft too: Input never quits.
    _ = try f.app.feed("\x03");
    try testing.expect(!f.app.quit);
    // A send stays in Input.
    _ = try f.app.feed("hello\r");
    try testing.expectEqual(KeyMode.input, f.app.keyMode());
    _ = try f.app.feed("\x1b");
    try testing.expectEqual(KeyMode.normal, f.app.keyMode());
    _ = try f.app.feed("\x03");
    try testing.expect(f.app.quit);
    _ = try f.outbox();
}
