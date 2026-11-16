//! Headless inbox tests: the inbox screen renders
//! into a venom-term Surface and is driven with key bytes; no test opens a
//! TTY, and the live test runs the fake harness only.
//!
//! - The inbox screen's snapshot against
//!   `testdata/inbox_view.txt`, from a fixed model.
//! - Every kind's keys turn into the right `inbox.*` / `agent.*` request
//!   (or a local action), answering moves to the next item, a failed
//!   answer brings the item back, a batch with mixed grants is refused
//!   before anything is sent, and the same keys work inline in the
//!   transcript.
//! - Live: a real daemon with the fake harness; approvals (batch, edited),
//!   a question, a plan, a failure and a review are answered from the
//!   inbox screen, one more approval inline, and the harness hears each.
const std = @import("std");
const term = @import("venom-term");
const t = @import("tests.zig");
const App = @import("app.zig").App;
const Link = @import("link.zig").Link;
const view = @import("view.zig");
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

/// The inbox screen's items, as `inbox.list` would send them (oldest first within
/// a kind, blocking kinds first).
pub const fixture_inbox =
    \\{"items":[
    \\{"agent":"a1","kind":"approval","age_s":60,"reason":"Bash wants to run: zig build test -Dconformance","item":"r1","request":"r1","blocking":true,"level":"urgent","title":"venom-echo conformance","state":"needs_you","stale":false,"answers":[],"grant":"exec:zig",
    \\ "context":[{"turn":"t1","text":"I'll read the contract test vectors first, then add a conformance build step."}]},
    \\{"agent":"a6","kind":"approval","age_s":50,"reason":"Bash wants to run: zig build","item":"r2","request":"r2","blocking":true,"level":"urgent","title":"proto fuzzing","state":"needs_you","stale":false,"answers":[],"grant":"exec:zig","context":[]},
    \\{"agent":"a7","kind":"approval","age_s":40,"reason":"Bash wants to run: rm -rf zig-out","item":"r3","request":"r3","blocking":true,"level":"urgent","title":"clean build dir","state":"needs_you","stale":false,"answers":[],"grant":"exec:rm","context":[]},
    \\{"agent":"a8","kind":"question","age_s":240,"reason":"Which framing should proto v2 specify?","item":"q1","request":"q1","blocking":true,"level":"urgent","title":"proto v2 framing review","state":"needs_you","stale":false,"answers":[],
    \\ "options":[{"id":"q1","question":"Which framing should proto v2 specify?","labels":["u32 length prefix","LEB128 varint","Keep both, negotiated"]}],
    \\ "context":[{"turn":"t1","text":"The doc says frames are length-prefixed with a u32; venom-std decodes LEB128 varints."}]},
    \\{"agent":"a9","kind":"plan","age_s":30,"reason":"split proto.Frame into frame and codec","item":"p1","request":"p1","blocking":true,"level":"urgent","title":"proto split","state":"needs_you","stale":true,"answers":[],"context":[]},
    \\{"agent":"a2","kind":"failed","age_s":720,"reason":"zig build exited 1","item":"failed","blocking":true,"level":"warn","title":"libghostty-vt spike","state":"failed","stale":false,"answers":[],"context":[]},
    \\{"agent":"a10","kind":"limit","age_s":300,"reason":"usage limit hit","item":"limit","blocking":true,"level":"warn","title":"docs pass","state":"failed","stale":false,"answers":[],"context":[]},
    \\{"agent":"a4","kind":"review","age_s":1320,"reason":"finished, unread","item":"review","blocking":false,"level":"info","title":"cfg ZON schema verbs","state":"settled","stale":false,"answers":[],"context":[]}]}
;

const two_questions =
    \\{"items":[{"agent":"a8","kind":"question","age_s":5,"reason":"Two things","item":"r1","request":"r1","blocking":true,"level":"urgent","title":"two","state":"needs_you","stale":false,"answers":[],
    \\ "options":[{"id":"q1","question":"Framing?","labels":["Keep varint","Fixed u32"]},{"id":"q2","question":"Order?","labels":["big","little","mixed"]}],"context":[]}]}
;

test "inbox keys: a request with two questions collects one pick per question and sends them together" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try t.answer(&app, a, "inbox.list", two_questions);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try app.feed(" i");
    try view.render(&app, &surface);
    var dump = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, dump, "1 Keep varint") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "· big") != null);

    // The first digit picks for q1 and waits; the screen shows the pick and q2's keys.
    _ = try app.feed("2");
    try testing.expect((try take(a, &app)) == null);
    try view.render(&app, &surface);
    dump = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, dump, "✓ Fixed u32") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "3 mixed") != null);
    // A digit past q2's options is refused, nothing sent.
    _ = try app.feed("4");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "no option 4") != null);
    // The last pick sends both, by question id.
    _ = try app.feed("3");
    const s = (try take(a, &app)).?;
    try testing.expectEqualStrings("inbox.answer", s.verb);
    try testing.expectEqualStrings("Fixed u32, mixed", param(s, "answer"));
    try testing.expectEqualStrings("{\"q1\":[\"Fixed u32\"],\"q2\":[\"mixed\"]}", param(s, "args"));
    try testing.expectEqual(@as(usize, 0), app.picks.n);
}

test "inbox keys: a digit on a question the daemon marked unanswerable here says so and sends nothing" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    // q1 has labels; q9 is the daemon's marker for questions past the eighth.
    const marker = try std.mem.replaceOwned(u8, a, two_questions, "{\"id\":\"q2\",\"question\":\"Order?\",\"labels\":[\"big\",\"little\",\"mixed\"]}", "{\"id\":\"q9\",\"question\":\"\",\"labels\":[],\"free_text\":false,\"labels_omitted\":true}");
    try testing.expect(marker.len != two_questions.len);
    try t.answer(&app, a, "inbox.list", marker);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try app.feed(" i");
    try view.render(&app, &surface);
    _ = try app.feed("1");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "cannot be answered here") != null);
    try testing.expectEqual(@as(usize, 0), app.picks.n);
}

test "inbox keys: a digit is refused when the options changed since they were drawn" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try t.answer(&app, a, "inbox.list", two_questions);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try app.feed(" i");
    try view.render(&app, &surface);
    // A refresh swaps q1's options before the next frame.
    try app.inbox.apply(try std.json.parseFromSliceLeaky(Value, a, try std.mem.replaceOwned(u8, a, two_questions, "Keep varint", "Rewrite it"), .{}));
    _ = try app.feed("1");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "options changed") != null);
    try view.render(&app, &surface);
    _ = try app.feed("1");
    try testing.expectEqual(@as(usize, 1), app.picks.n);
}

test "inbox keys: a digit is not sent as text when the options vanished, the item was replaced or nothing was drawn" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    try t.answer(&app, a, "inbox.list", two_questions);
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    _ = try app.feed(" i");
    // Nothing drawn for the item yet.
    app.drawn = null;
    _ = try app.feed("1");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "not drawn") != null);
    try view.render(&app, &surface);

    // The options vanish (a refresh without them): "1" is not an answer "1".
    const bare = try std.mem.replaceOwned(u8, a, two_questions, "\"options\":[{\"id\":\"q1\",\"question\":\"Framing?\",\"labels\":[\"Keep varint\",\"Fixed u32\"]},{\"id\":\"q2\",\"question\":\"Order?\",\"labels\":[\"big\",\"little\",\"mixed\"]}],", "");
    try testing.expect(bare.len < two_questions.len);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(Value, a, bare, .{}));
    _ = try app.feed("1");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "options changed") != null);

    // Another request in its place (same agent, new item id).
    try view.render(&app, &surface);
    try app.inbox.apply(try std.json.parseFromSliceLeaky(Value, a, try std.mem.replaceOwned(u8, a, two_questions, "\"item\":\"r1\",\"request\":\"r1\"", "\"item\":\"r2\",\"request\":\"r2\""), .{}));
    _ = try app.feed("1");
    try testing.expect((try take(a, &app)) == null);
}

const Sent = struct { verb: []const u8, params: std.json.ObjectMap };

/// The one queued request (none: null), parsed into `a`.
fn take(a: std.mem.Allocator, app: *App) !?Sent {
    if (app.outbox.items.len == 0) return null;
    try testing.expectEqual(@as(usize, 1), app.outbox.items.len);
    const line = app.outbox.items[0];
    defer ta.free(line);
    app.outbox.clearRetainingCapacity();
    const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{});
    return .{ .verb = v.object.get("verb").?.string, .params = v.object.get("params").?.object };
}

fn param(s: Sent, name: []const u8) []const u8 {
    const v = s.params.get(name) orelse return "";
    return if (v == .string) v.string else "";
}

/// Expects one `inbox.answer` for `agent` with `answer` (and `reason`).
fn expectAnswer(a: std.mem.Allocator, app: *App, agent: []const u8, request: []const u8, answer: []const u8, reason: ?[]const u8) !void {
    const s = (try take(a, app)) orelse return error.NothingSent;
    try testing.expectEqualStrings("inbox.answer", s.verb);
    try testing.expectEqualStrings(agent, param(s, "agent"));
    try testing.expectEqualStrings(request, param(s, "request"));
    try testing.expectEqualStrings(answer, param(s, "answer"));
    if (reason) |r| try testing.expectEqualStrings(r, param(s, "reason")) else try testing.expect(s.params.get("reason") == null);
}

/// Answers the newest attention action with `err` (null: ok).
fn respond(app: *App, a: std.mem.Allocator, err: ?[]const u8) !void {
    var it = app.pending.iterator();
    var newest: ?i64 = null;
    while (it.next()) |e| if (e.value_ptr.* == .answer and (newest == null or e.key_ptr.* > newest.?)) {
        newest = e.key_ptr.*;
    };
    if (err) |code| {
        try app.onResponse(newest.?, .{ .@"error" = .{ .code = code, .message = "", .data = null } });
    } else try app.onResponse(newest.?, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, "{}", .{}) });
    // The refresh an answer asks for is not wanted here.
    for (app.outbox.items) |line| ta.free(line);
    app.outbox.clearRetainingCapacity();
}

fn cursorIs(app: *App, key: []const u8) !void {
    try testing.expectEqualStrings(key, app.inbox_cursor.items);
}

pub fn fixture(app: *App, a: std.mem.Allocator) !void {
    try t.fixtureApp(app, a);
    try t.answer(app, a, "inbox.list", fixture_inbox);
}

test "inbox screen snapshot matches testdata/inbox_view.txt" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    // The bar's clock in UTC, whatever the machine's zone.
    app.utc_offset_override = 0;
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&app, &surface);
    _ = try t.sent(a, &app);
    _ = try app.feed(" i");
    try testing.expectEqual(@import("app.zig").Screen.inbox, app.screen);
    _ = try app.feed("jjj"); // the question, under the cursor
    try view.render(&app, &surface);
    const got = try t.dump(a, &surface);
    const want = @embedFile("testdata/inbox_view.txt");
    if (!std.mem.eql(u8, want, got)) std.debug.print("inbox view:\n{s}\n", .{got});
    try testing.expectEqualStrings(want, got);
    try testing.expectEqualStrings("", try t.sent(a, &app));

    // The help shows the inbox's own keys.
    _ = try app.feed("?");
    try view.render(&app, &surface);
    const help = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, help, "allow always (narrowest grant)") != null);
    try testing.expect(std.mem.indexOf(u8, help, "venom inbox batch") != null);
    try testing.expect(std.mem.indexOf(u8, help, "stop the agent's turn") == null);
    _ = try app.feed("x");
    // Esc goes back; `i` there comes again.
    _ = try app.feed("\x1b");
    try testing.expectEqual(@import("app.zig").Screen.main, app.screen);
}

test "inbox keys: every kind's actions, answer-and-advance, refused mixed batch, inline in the transcript" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try fixture(&app, a);
    var surface = try term.Surface.init(ta, 100, 28);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&app, &surface);
    _ = try t.sent(a, &app);
    _ = try app.feed(" i");
    try view.render(&app, &surface);
    try cursorIs(&app, "a1/r1");

    // Batch: a1 and a6 share exec:zig, a7 wants exec:rm. Mixed is refused
    // in the UI, with nothing sent.
    _ = try app.feed("mjmjm");
    try cursorIs(&app, "a7/r3");
    try testing.expectEqual(@as(usize, 3), app.marks.items.len);
    _ = try app.feed("Y");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "different grants") != null);
    try view.render(&app, &surface);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, try t.dump(a, &surface), "◉ Approve: "));
    // Unmark a7; Y allows a1 and a6 once in one inbox.batch.
    _ = try app.feed("mY");
    const b = (try take(a, &app)).?;
    try testing.expectEqualStrings("inbox.batch", b.verb);
    try testing.expectEqualStrings("allow_once", param(b, "answer"));
    const items = b.params.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a1", items[0].object.get("agent").?.string);
    try testing.expectEqualStrings("r2", items[1].object.get("request").?.string);
    try testing.expectEqual(@as(usize, 0), app.marks.items.len);
    try respond(&app, a, null);
    try view.render(&app, &surface);
    try cursorIs(&app, "a7/r3");
    try testing.expectEqual(@as(usize, 6), (try app.visibleItems()).len);
    // N denies marked; a question in the batch is refused too.
    _ = try app.feed("mjmN");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "only approvals") != null);
    _ = try app.feed("mkm");
    try testing.expectEqual(@as(usize, 0), app.marks.items.len);
    try cursorIs(&app, "a7/r3");

    // Approval keys. Each answer moves to the next item; a failed answer
    // brings the item back (the cursor stays where it went).
    _ = try app.feed("y");
    try expectAnswer(a, &app, "a7", "r3", "allow_once", null);
    try cursorIs(&app, "a8/q1");
    try respond(&app, a, "conflict.request_resolved");
    try testing.expect(std.mem.indexOf(u8, app.message.items, "inbox answer: conflict.request_resolved") != null);
    try view.render(&app, &surface);
    try cursorIs(&app, "a8/q1");
    _ = try app.feed("k");
    try cursorIs(&app, "a7/r3");
    for ([_]struct { []const u8, []const u8 }{ .{ "a", "allow_always" }, .{ "n", "deny" } }) |c| {
        _ = try app.feed(c[0]);
        try expectAnswer(a, &app, "a7", "r3", c[1], null);
        try respond(&app, a, "conflict.request_resolved");
        _ = try app.feed("k");
        try view.render(&app, &surface);
        try cursorIs(&app, "a7/r3");
    }
    // r asks for the reason; esc drops it, nothing sent.
    _ = try app.feed("r");
    try view.render(&app, &surface);
    const asking = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, asking, "┌ Deny with a reason") != null);
    try testing.expect(std.mem.indexOf(u8, asking, "│  INPUT") != null);
    _ = try app.feed("no\x1b");
    try testing.expect(app.prompt == null and (try take(a, &app)) == null);
    _ = try app.feed("r\r");
    try testing.expect(app.prompt != null and (try take(a, &app)) == null); // empty: kept open
    _ = try app.feed("too risky\r");
    try expectAnswer(a, &app, "a7", "r3", "deny", "too risky");
    try respond(&app, a, "conflict.request_resolved");
    _ = try app.feed("k");
    try view.render(&app, &surface);
    // e: allow an edited command, sent as args.
    _ = try app.feed("erm -rf zig-out/cache\r");
    const e = (try take(a, &app)).?;
    try testing.expectEqualStrings("allow_edited", param(e, "answer"));
    try testing.expectEqualStrings("{\"command\":\"rm -rf zig-out/cache\"}", param(e, "args"));
    try respond(&app, a, null);
    try view.render(&app, &surface);
    try cursorIs(&app, "a8/q1");

    // Question: 1–9 picks, ⏎ types an answer.
    _ = try app.feed("2");
    const picked = (try take(a, &app)).?;
    try testing.expectEqualStrings("inbox.answer", picked.verb);
    try testing.expectEqualStrings("LEB128 varint", param(picked, "answer"));
    try testing.expectEqualStrings("{\"q1\":[\"LEB128 varint\"]}", param(picked, "args"));
    try cursorIs(&app, "a9/p1");
    try respond(&app, a, "conflict.request_resolved");
    _ = try app.feed("k\rKeep varint\r");
    try expectAnswer(a, &app, "a8", "q1", "Keep varint", null);
    try respond(&app, a, null);
    try view.render(&app, &surface);
    try cursorIs(&app, "a9/p1");

    // Plan: y approves, n rejects with feedback.
    _ = try app.feed("y");
    try expectAnswer(a, &app, "a9", "p1", "approve", null);
    try respond(&app, a, "conflict.request_resolved");
    _ = try app.feed("k");
    try view.render(&app, &surface);
    try cursorIs(&app, "a9/p1");
    _ = try app.feed("a"); // no action for a plan
    try testing.expect((try take(a, &app)) == null);
    _ = try app.feed("nsmaller steps\r");
    try expectAnswer(a, &app, "a9", "p1", "reject", "smaller steps");
    try respond(&app, a, null);
    try view.render(&app, &surface);
    try cursorIs(&app, "a2/failed");

    // Failed and limit: R retry is local for now; \ opens the split menu
    // for the item's agent on the main view; s snoozes.
    _ = try app.feed("R");
    try testing.expect((try take(a, &app)) == null);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "retry") != null);
    _ = try app.feed("\\");
    try testing.expectEqualStrings("a2", app.menu.?.agent);
    try testing.expectEqual(@import("app.zig").Screen.main, app.screen);
    _ = try app.feed("\x1b");
    try testing.expect(app.menu == null);
    _ = try t.sent(a, &app); // the main view's agent.show for a2
    _ = try app.feed(" i");
    try view.render(&app, &surface);
    try cursorIs(&app, "a2/failed");
    _ = try app.feed("s");
    const sn = (try take(a, &app)).?;
    try testing.expectEqualStrings("inbox.snooze", sn.verb);
    try testing.expectEqualStrings("a2", param(sn, "agent"));
    try testing.expectEqualStrings("failed", param(sn, "item"));
    try respond(&app, a, null);
    try view.render(&app, &surface);
    try cursorIs(&app, "a10/limit");
    _ = try app.feed("s");
    try testing.expectEqualStrings("limit", param((try take(a, &app)).?, "item"));
    try respond(&app, a, null);
    try view.render(&app, &surface);

    // Review: x archives, o opens the agent in the main view.
    try cursorIs(&app, "a4/review");
    _ = try app.feed("x");
    const ar = (try take(a, &app)).?;
    try testing.expectEqualStrings("agent.archive", ar.verb);
    try testing.expectEqualStrings("a4", param(ar, "agent"));
    try respond(&app, a, "conflict.agent_handed_over");
    try view.render(&app, &surface);
    try cursorIs(&app, "a4/review");
    _ = try app.feed("o");
    try testing.expectEqual(@import("app.zig").Screen.main, app.screen);
    try testing.expectEqualStrings("a4", app.selected.items);
    try testing.expectEqual(@import("app.zig").Area.transcript, app.area());
    // Its agent.show is queued behind the one still in flight.
    try testing.expect(app.show_again);

    // The daemon's next list drops what was answered.
    try app.onEvent(try std.json.parseFromSliceLeaky(Value, a,
        \\{"seq":41,"ts":"2026-11-06T14:30:01.000Z","source":"venom/0e1","type":"agent.attention_cleared","data":{"agent":"a7","by":"answer"}}
    , .{}));
    const next =
        \\{"items":[{"agent":"a1","kind":"approval","age_s":5,"reason":"Bash wants to run: zig build","item":"r5","request":"r5","title":"venom-echo conformance","stale":false,"grant":"exec:zig","context":[]},
        \\{"agent":"a4","kind":"review","age_s":1320,"reason":"finished, unread","item":"review","title":"cfg ZON schema verbs","stale":false,"context":[]}]}
    ;
    // The list in flight was asked before the answers succeeded: it
    // keeps them hidden, and a fresh one follows, which drops them.
    try t.answer(&app, a, "inbox.list", next);
    try testing.expect(app.hidden.items.len > 0);
    try testing.expectEqualStrings("inbox.list() ", try t.sent(a, &app));
    try t.answer(&app, a, "inbox.list", next);
    try testing.expectEqual(@as(usize, 0), app.hidden.items.len);
    _ = try t.sent(a, &app);

    // Inline: a1's new approval in its transcript, answered with the
    // transcript focused; the agent stays selected.
    try app.preselect("a1");
    try view.render(&app, &surface);
    _ = try t.sent(a, &app);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), "y once  a always  e edit") != null);
    _ = try app.feed("r"); // deny with a reason, inline
    try view.render(&app, &surface);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), "┌ Deny with a reason") != null);
    _ = try app.feed("\x1b");
    try testing.expect(app.prompt == null);
    try testing.expectEqual(@import("app.zig").Area.transcript, app.area());
    _ = try app.feed("y");
    try expectAnswer(a, &app, "a1", "r5", "allow_once", null);
    try testing.expectEqual(@import("app.zig").Screen.main, app.screen);
    try testing.expectEqualStrings("a1", app.selected.items);
    try view.render(&app, &surface);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), "y once  a always") == null);
    // Nothing pending for a1 now: y is no longer an answer.
    _ = try app.feed("y");
    try testing.expect((try take(a, &app)) == null);
}

// ---- Live, against a real daemon ---------------------------------------

/// Every turn asks something and echoes the answer it got.
const script =
    \\{"turns":[{"match":"build","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build"}},{"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build?","echo":true}},{"text":"built"}]},
    \\          {"match":"remove","steps":[{"tool":{"id":"tu2","name":"Bash","kind":"exec","title":"rm -rf out"}},{"ask":{"id":"p2","kind":"approval","call":"tu2","reason":"Remove out?","echo":true}}]},
    \\          {"match":"quiz","steps":[{"ask":{"id":"q1","kind":"question","reason":"Keep varint framing?","questions":[{"question":"Keep varint framing?","options":["Keep varint","Fixed u32"]}],"echo":true}}]},
    \\          {"match":"duo","steps":[{"ask":{"id":"q2","kind":"question","reason":"Two things","questions":[{"question":"Framing?","options":["Keep varint","Fixed u32"]},{"question":"Order?","options":["big","little"]}],"echo":true}}]},
    \\          {"match":"plan","steps":[{"ask":{"id":"l1","kind":"plan","reason":"Plan: split proto","echo":true}}]},
    \\          {"match":"fail","steps":[{"text":"oops"},{"end":"failed"}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

/// The inbox shows `n` items.
const Items = struct {
    n: usize,
    pub fn check(self: Items, app: *App, _: *term.Surface) !bool {
        return app.inbox.loaded and (try app.visibleItems()).len == self.n;
    }
};

/// The inbox cursor's item is of `kind`.
const CursorKind = struct {
    kind: @import("inbox.zig").Kind,
    pub fn check(self: CursorKind, app: *App, _: *term.Surface) !bool {
        const it = (try app.currentItem()) orelse return false;
        return it.kind == self.kind;
    }
};

/// The inbox has an item for `agent`.
const HasItem = struct {
    agent: []const u8,
    pub fn check(self: HasItem, app: *App, _: *term.Surface) !bool {
        return app.itemOf(self.agent) != null;
    }
};

/// The agent's transcript (`agent show --json`) contains `text`.
fn heard(d: *t.Daemon, a: std.mem.Allocator, agent: []const u8, text: []const u8) !void {
    const v = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{agent}) });
    const json = try std.json.Stringify.valueAlloc(a, v, .{});
    if (std.mem.indexOf(u8, json, text) == null) {
        std.debug.print("{s} did not hear {s}: {s}\n", .{ agent, text, json });
        return error.NotHeard;
    }
}

test "live: the inbox answers every kind against the fake harness, with answer-and-advance and inline attention" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = ".{ .harness = .{ .claude_code = .{ .enabled = false }, .codex = .{ .enabled = false } } }" });
    try tmp.dir.createDirPath(testing.io, "work");
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (std.c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
    var d: t.Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}), .script = script };
    defer d.deinit();
    try d.start();
    defer d.halt();

    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 110, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try t.until(&app, &link, &surface, &d, "connect", t.Connected{});

    // Six agents, each needing you in another way; spawned one by one so
    // the inbox's oldest-first order is theirs.
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{work});
    const tasks = [_][]const u8{ "build one", "build two", "remove out", "quiz me", "plan it", "fail now" };
    for (tasks, 1..) |task, n| {
        _ = try d.run(a, &.{ "agent", "spawn", cwd, try std.fmt.allocPrint(a, "--task={s}", .{task}), "--harness=fake" });
        try t.until(&app, &link, &surface, &d, "the next item", Items{ .n = n });
    }
    _ = try app.feed(" i");
    try t.until(&app, &link, &surface, &d, "the inbox screen", t.Shows{ .text = " INBOX " });
    try cursorIs(&app, "a1/r1");

    // A batch over exec:zig and the rm grant is refused, unsent; a1 + a2
    // (both exec:zig) go together.
    _ = try app.feed("mjjmY");
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    try testing.expect(std.mem.indexOf(u8, app.message.items, "different grants") != null);
    _ = try app.feed("mkmY");
    try cursorIs(&app, "a3/r1");
    try t.until(&app, &link, &surface, &d, "a1 settled", t.InState{ .id = "a1", .state = .settled });
    try t.until(&app, &link, &surface, &d, "a2 settled", t.InState{ .id = "a2", .state = .settled });

    // Answer and advance through the rest.
    _ = try app.feed("erm -rf out/cache\r");
    try cursorIs(&app, "a4/r1");
    // The digit picks from what was drawn: wait for the options on screen.
    try t.until(&app, &link, &surface, &d, "a4's options", t.Shows{ .text = "2 Fixed u32" });
    _ = try app.feed("2");
    try cursorIs(&app, "a5/r1");
    _ = try app.feed("nsmaller steps\r");
    try cursorIs(&app, "a6/failed");
    _ = try app.feed("s");
    for ([_][]const u8{ "a3", "a4", "a5" }) |id| try t.until(&app, &link, &surface, &d, "settled", t.InState{ .id = id, .state = .settled });
    try heard(&d, a, "a1", "answer=allow_once");
    try heard(&d, a, "a2", "answer=allow_once");
    try heard(&d, a, "a3", "answer=allow_edited reason= args={\\\"command\\\":\\\"rm -rf out/cache\\\"}");
    try heard(&d, a, "a4", "answer=Fixed u32 reason= args={\\\"q1\\\":[\\\"Fixed u32\\\"]}");
    try heard(&d, a, "a5", "answer=reject reason=smaller steps");

    // Only reviews are left (a6 is snoozed); x archives the one under the
    // cursor.
    try t.until(&app, &link, &surface, &d, "a review under the cursor", CursorKind{ .kind = .review });
    const reviewed = try a.dupe(u8, (try app.currentItem()).?.agent);
    _ = try app.feed("x");
    try t.until(&app, &link, &surface, &d, "archived", t.InState{ .id = reviewed, .state = .archived });

    // Inline: a new approval, opened from the inbox (blocking first) and
    // answered "always" in the agent's transcript.
    _ = try d.run(a, &.{ "agent", "spawn", cwd, "--task=build three", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "a7 needs you", t.InState{ .id = "a7", .state = .needs_you });
    try t.until(&app, &link, &surface, &d, "a7's approval in the inbox", HasItem{ .agent = "a7" });
    _ = try app.feed("\x1b[H"); // Home: the most urgent item
    _ = try app.feed("o");
    try testing.expectEqualStrings("a7", app.selected.items);
    try t.until(&app, &link, &surface, &d, "a7's inline keys", t.Shows{ .text = "y once  a always" });
    _ = try app.feed("a");
    try t.until(&app, &link, &surface, &d, "a7 settled", t.InState{ .id = "a7", .state = .settled });
    try heard(&d, a, "a7", "answer=allow_always");
    const always = try std.json.Stringify.valueAlloc(a, try d.run(a, &.{ "always", "list" }), .{});
    try testing.expect(std.mem.indexOf(u8, always, "exec:zig") != null);
}

test "live: a question with two questions is answered by one pick each, and the harness hears both labels" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = ".{ .harness = .{ .claude_code = .{ .enabled = false }, .codex = .{ .enabled = false } } }" });
    try tmp.dir.createDirPath(testing.io, "work");
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (std.c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;
    const work = try std.fmt.allocPrint(a, "{s}/work", .{dir});
    var d: t.Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}), .script = script };
    defer d.deinit();
    try d.start();
    defer d.halt();
    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 110, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try t.until(&app, &link, &surface, &d, "connect", t.Connected{});
    _ = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{work}), "--task=duo", "--harness=fake" });
    try t.until(&app, &link, &surface, &d, "the question", Items{ .n = 1 });
    _ = try app.feed(" i");
    try t.until(&app, &link, &surface, &d, "its options", t.Shows{ .text = "1 Keep varint" });
    _ = try app.feed("2");
    try t.until(&app, &link, &surface, &d, "q2's options", t.Shows{ .text = "✓ Fixed u32" });
    _ = try app.feed("2");
    try t.until(&app, &link, &surface, &d, "a1 settled", t.InState{ .id = "a1", .state = .settled });
    try heard(&d, a, "a1", "answer=Fixed u32, little reason= args={\\\"q1\\\":[\\\"Fixed u32\\\"],\\\"q2\\\":[\\\"little\\\"]}");
}

test "the BEL: once per new blocking item, not for what was there at the start, not for review, attention.bell read live" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(testing.allocator);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    app.rings = true;
    const item = struct {
        fn f(comptime id: []const u8, comptime kind: []const u8) []const u8 {
            return "{\"agent\":\"a1\",\"item\":\"" ++ id ++ "\",\"request\":\"" ++ id ++ "\",\"kind\":\"" ++ kind ++ "\",\"reason\":\"r\",\"title\":\"t\",\"age_s\":1,\"context\":[]}";
        }
    }.f;
    const lists = struct {
        fn send(x: *App, y: std.mem.Allocator, json: []const u8) !void {
            try x.requestInbox();
            _ = try t.sent(y, x);
            try t.answer(x, y, "inbox.list", json);
        }
    };
    // The first list: already on the screen.
    try t.answer(&app, a, "inbox.list", "{\"items\":[" ++ comptime item("p1", "approval") ++ "]}");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    // A review never rings.
    try lists.send(&app, a, "{\"items\":[" ++ comptime item("p1", "approval") ++ "," ++ item("review", "review") ++ "]}");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    // A new blocking item asks for the setting, and rings on its answer.
    try lists.send(&app, a, "{\"items\":[" ++ comptime item("p1", "approval") ++ "," ++ item("p2", "question") ++ "]}");
    try testing.expectEqualStrings("config.get() ", try t.sent(a, &app));
    try testing.expect(!app.takeBell());
    try t.answer(&app, a, "config.get", "{\"content\":\"true\",\"source\":\"default\"}");
    try testing.expect(app.takeBell());
    try testing.expect(!app.takeBell());
    // Seen: no second ring.
    try lists.send(&app, a, "{\"items\":[" ++ comptime item("p1", "approval") ++ "," ++ item("p2", "question") ++ "]}");
    try testing.expectEqualStrings("", try t.sent(a, &app));
    // attention.bell = false: asked, and silent.
    try lists.send(&app, a, "{\"items\":[" ++ comptime item("p3", "plan") ++ "]}");
    try testing.expectEqualStrings("config.get() ", try t.sent(a, &app));
    try t.answer(&app, a, "config.get", "{\"content\":\"false\",\"source\":\"user\"}");
    try testing.expect(!app.takeBell());
    // --solo, and tests by default, never ask.
    app.rings = false;
    try lists.send(&app, a, "{\"items\":[" ++ comptime item("p4", "plan") ++ "]}");
    try testing.expectEqualStrings("", try t.sent(a, &app));
}

test "a limit item shows when it resets, in local time, in the inbox and inline (testdata/inbox_limit.txt)" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App.init(ta);
    defer app.deinit();
    try t.fixtureApp(&app, a);
    app.utc_offset_override = 2 * 3600; // the fixture's 14:30 UTC is 16:30 here
    try t.answer(&app, a, "inbox.list",
        \\{"items":[
        \\{"agent":"a2","kind":"limit","age_s":300,"reason":"usage limit hit","item":"limit","blocking":true,"level":"warn","title":"libghostty-vt spike","state":"failed","stale":false,"answers":[],"resets_at":"2026-11-07T15:00:00Z","context":[]},
        \\{"agent":"a4","kind":"limit","age_s":10,"reason":"weekly limit hit","item":"limit","blocking":true,"level":"warn","title":"cfg ZON schema verbs","state":"failed","stale":false,"answers":[],"resets_at":"2026-11-09T09:00:00Z","context":[]}]}
    );
    var surface = try term.Surface.init(ta, 120, 30);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&app, &surface);
    _ = try t.sent(a, &app);
    _ = try app.feed(" i");
    try view.render(&app, &surface);
    const got = try t.dump(a, &surface);
    const want = @embedFile("testdata/inbox_limit.txt");
    if (!std.mem.eql(u8, want, got)) std.debug.print("inbox limit view:\n{s}\n", .{got});
    try testing.expectEqualStrings(want, got);

    // A reset on another day shows its date.
    _ = try app.feed("j");
    try view.render(&app, &surface);
    try testing.expect(std.mem.indexOf(u8, try t.dump(a, &surface), "weekly limit hit  · resets at 11-09 11:00") != null);

    // Inline, in the transcript of the agent that hit the limit.
    _ = try app.feed("\x1b");
    try app.preselect("a2");
    try view.render(&app, &surface);
    const inline_view = try t.dump(a, &surface);
    try testing.expect(std.mem.indexOf(u8, inline_view, "usage limit hit  · resets at 17:00") != null);
}

fn offsetWinter(_: i64) i32 {
    return 3600;
}

fn offsetDst(unix_s: i64) i32 {
    // DST starts at 2026-03-29T01:00:00Z.
    return if (unix_s >= 1774746000) 7200 else 3600;
}

test "resets_at label: local time, the date when it is another day, past resets, nothing when unknown" {
    const inbox_mod = @import("inbox.zig");
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const now = inbox_mod.parseRfc3339("2026-11-07T14:30:00Z").?;
    try testing.expectEqual(@as(i64, 1794063600 - 1800), now);
    try testing.expectEqualStrings("resets at 15:00", try inbox_mod.resetsAtLabel(a, "2026-11-07T15:00:00Z", 0, now));
    try testing.expectEqualStrings("resets at 17:00", try inbox_mod.resetsAtLabel(a, "2026-11-07T15:00:00Z", 7200, now));
    try testing.expectEqualStrings("resets at 11-08 03:30", try inbox_mod.resetsAtLabel(a, "2026-11-07T22:00:00-05:30", 0, now));
    try testing.expectEqualStrings("resets at 11-08 00:00", try inbox_mod.resetsAtLabel(a, "2026-11-07T22:00:00Z", 7200, now));
    try testing.expectEqualStrings("", try inbox_mod.resetsAtLabel(a, "", 0, now));
    try testing.expectEqualStrings("", try inbox_mod.resetsAtLabel(a, "tomorrow", 0, now));
    // Already past: "reset"; unknown now: the date form.
    try testing.expectEqualStrings("reset at 14:00", try inbox_mod.resetsAtLabel(a, "2026-11-07T14:00:00Z", 0, now));
    try testing.expectEqualStrings("reset at 14:30", try inbox_mod.resetsAtLabel(a, "2026-11-07T14:30:00Z", 0, now));
    try testing.expectEqualStrings("resets at 11-07 15:00", try inbox_mod.resetsAtLabel(a, "2026-11-07T15:00:00Z", 0, 0));
}

test "resets_at label: the offset is taken at each instant, across a DST change" {
    const inbox_mod = @import("inbox.zig");
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    // Now (23:30Z, 28th) is in winter time (+1h), so 00:30 on the 29th.
    const now = inbox_mod.parseRfc3339("2026-03-28T23:30:00Z").?;
    // 10:00Z on the 29th is after the change (+2h): 12:00, same local day.
    try testing.expectEqualStrings("resets at 12:00", try inbox_mod.resetsAtLabelWith(a, "2026-03-29T10:00:00Z", null, now, offsetDst));
    // The same instant under winter time only would read 11:00.
    try testing.expectEqualStrings("resets at 11:00", try inbox_mod.resetsAtLabelWith(a, "2026-03-29T10:00:00Z", null, now, offsetWinter));
    // 22:30Z on the 29th is 00:30 on the 30th after the change, another day.
    try testing.expectEqualStrings("resets at 03-30 00:30", try inbox_mod.resetsAtLabelWith(a, "2026-03-29T22:30:00Z", null, now, offsetDst));
}

test "parseRfc3339: strict" {
    const p = @import("inbox.zig").parseRfc3339;
    try testing.expectEqual(@as(i64, 1794063600), p("2026-11-07T15:00:00Z").?);
    try testing.expectEqual(@as(i64, 1794063600), p("2026-11-07T15:00:00.123456Z").?);
    try testing.expectEqual(@as(i64, 1794063600), p("2026-11-07T17:00:00+02:00").?);
    try testing.expectEqual(@as(i64, 1794063600), p("2026-11-07T12:00:00-03:00").?);
    try testing.expect(p("2026-02-29T00:00:00Z") == null);
    try testing.expect(p("2028-02-29T00:00:00Z") != null);
    try testing.expect(p("2026-04-31T00:00:00Z") == null);
    try testing.expect(p("+026-11-07T15:00:00Z") == null);
    try testing.expect(p("2026-1-+7T15:00:00Z") == null);
    try testing.expect(p("2026-11-07T-5:00:00Z") == null);
    try testing.expect(p("2026-11-07T15:00:00.Z") == null);
    try testing.expect(p("2026-11-07T15:00:00+24:00") == null);
    try testing.expect(p("2026-11-07T15:00:00+02:60") == null);
    try testing.expect(p("2026-11-07T15:00:00+0:200") == null);
    try testing.expect(p("2026-11-07T15:00:00+-2:00") == null);
    try testing.expect(p("2026-11-07T15:00:00") == null);
}
