//! Paging: an agent whose transcript is several times `max_frame`
//! renders in the TUI, scrolls back to its start, and each refresh transfers
//! only what changed. The live test runs the whole way, from a durable log
//! through a real daemon and its socket to the screen; `Link.response_bytes`
//! measures what crosses the socket. The fixtures below are for what a live
//! agent does not do on demand.
const std = @import("std");
const term = @import("venom-term");
const proto = @import("proto");
const supervisor = @import("supervisor");
const eventlog = @import("../eventlog/root.zig");
const harnesses = @import("../harnesses.zig");
const tests = @import("tests.zig");
const Daemon = tests.Daemon;
const App = @import("app.zig").App;
const Link = @import("link.zig").Link;
const model = @import("model.zig");
const view = @import("view.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const page_up = "\x1b[5~";
const home = "\x1b[H";

/// Writes an agent with `turns` turns to the durable log, as a daemon would
/// have: each turn has a prompt, long texts, and tool calls with bodies. The
/// bodies stay collapsed: they cross the socket, but take no time to wrap.
fn seed(a: std.mem.Allocator, dir: []const u8, turns: usize) !void {
    var engine = try eventlog.Engine.open(ta, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, eventlog.file_name }), .{});
    defer engine.deinit();
    try engine.start();
    _ = try engine.submit(.{ .create = .{ .agent = "a1", .title = "long run", .harness = "fake", .workspace = dir, .cwd = dir } });
    const text = try a.alloc(u8, 8 * 1024);
    @memset(text, 'w');
    for (0..turns) |i| {
        const turn = try std.fmt.allocPrint(a, "t{d}", .{i + 1});
        _ = try engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = turn, .origin = "user" } } });
        _ = try engine.submit(.{ .record = .{ .turn_prompt = .{ .agent = "a1", .turn = turn, .text = "go on" } } });
        if (i == 0) _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = turn, .message = "m0", .text = "the very first words" } } });
        for (0..2) |k| _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = turn, .message = try std.fmt.allocPrint(a, "m{d}", .{k + 1}), .text = text } } });
        for (0..3) |k| {
            const call = try std.fmt.allocPrint(a, "c{d}-{d}", .{ i + 1, k });
            _ = try engine.submit(.{ .record = .{ .tool_started = .{ .agent = "a1", .turn = turn, .call = call, .kind = "exec", .name = "Bash", .title = "ls" } } });
            _ = try engine.submit(.{ .record = .{ .tool_ended = .{ .agent = "a1", .turn = turn, .call = call, .status = "ok", .body = .{ .text = text, .bytes = text.len } } } });
        }
        if (i + 1 == turns) _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = turn, .message = "m9", .text = "the very last words" } } });
        _ = try engine.submit(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = turn, .reason = "completed" } } });
    }
    // What surrounds the transcript grows too: the plain read must still fit.
    const prompt = try a.alloc(u8, 64 * 1024);
    @memset(prompt, 'p');
    for (0..eventlog.decider.child_prompts_max) |_| _ = try engine.submit(.{ .child_prompted = .{ .parent = "a1", .child = "a2", .text = prompt } });
}

const HasRecords = struct {
    pub fn check(_: HasRecords, app: *App, _: *term.Surface) !bool {
        return app.model.detail.windowed and app.model.detail.records.items.len > 0;
    }
};

const AtStart = struct {
    pub fn check(_: AtStart, app: *App, _: *term.Surface) !bool {
        return app.model.detail.windowed and app.model.detail.start == 0 and app.show_inflight == false;
    }
};

const Grew = struct {
    from: u64,
    pub fn check(self: Grew, app: *App, _: *term.Surface) !bool {
        return app.model.detail.end > self.from and app.model.detail.end == app.model.detail.total and !app.show_inflight;
    }
};

const Idle = struct {
    pub fn check(_: Idle, app: *App, _: *term.Surface) !bool {
        return !app.show_inflight;
    }
};

test "live: a transcript several times max_frame renders, scrolls back to its start, and a refresh transfers only what changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
    const run_dir = try std.fmt.allocPrintSentinel(a, "{s}/run", .{dir}, 0);
    if (c.mkdir(run_dir, 0o700) != 0) return error.MkdirFailed;

    const turns = 100;
    try seed(a, dir, turns);
    // Texts and bodies alone: each turn has 5 x 8 KiB.
    const transcript_bytes: u64 = turns * 5 * 8 * 1024;
    try testing.expect(transcript_bytes > 3 * proto.default_max_frame);

    var d: Daemon = .{ .dir = dir, .socket = try std.fmt.allocPrint(a, "{s}/venom.sock", .{run_dir}) };
    defer d.deinit();
    try d.start();
    defer d.halt();

    // A caller with no new parameters: no error, a frame at most, and it can
    // tell there is more.
    const plain = try d.run(a, &.{ "agent", "show", "--agent=a1", "--tools=true" });
    const plain_size = (try std.json.Stringify.valueAlloc(a, plain, .{ .emit_null_optional_fields = false })).len;
    try testing.expect(plain_size <= proto.default_max_frame);
    try testing.expect(plain.object.get("transcript_start").?.integer > 0);
    try testing.expect(plain.object.get("transcript").?.array.items.len > 0);
    try testing.expect(plain.object.get("child_prompts").?.array.items.len > 0);

    var app = App.init(ta);
    defer app.deinit();
    var link: Link = .{ .gpa = ta, .path = .{ .socket = d.socket } };
    defer link.deinit();
    var surface = try term.Surface.init(ta, 100, 26);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);

    // 1. It renders: the tail, in less than the transcript.
    try tests.until(&app, &link, &surface, &d, "connect", tests.Connected{});
    try tests.until(&app, &link, &surface, &d, "the tail", tests.Shows{ .text = "the very last words" });
    const detail = &app.model.detail;
    try testing.expect(detail.start > 0);
    try testing.expectEqual(detail.total, detail.end);
    try testing.expect(link.response_bytes < 2 * proto.default_max_frame);
    try testing.expectEqual(@as(usize, 0), app.message.items.len);
    const first_page = detail.records.items.len;
    const total_before = detail.total;

    // 2a. A refresh with nothing new carries no records at all.
    try tests.until(&app, &link, &surface, &d, "idle", Idle{});
    var before = link.response_bytes;
    try app.requestShow();
    try tests.until(&app, &link, &surface, &d, "nothing new", struct {
        link: *Link,
        before: u64,
        pub fn check(self: @This(), ap: *App, _: *term.Surface) !bool {
            return !ap.show_inflight and self.link.response_bytes > self.before;
        }
    }{ .link = &link, .before = before });
    const idle_refresh = link.response_bytes - before;
    try testing.expect(idle_refresh < 2 * 1024);
    try testing.expectEqual(first_page, detail.records.items.len);

    // 2b. A new turn: only its records cross the socket, and the view follows.
    before = link.response_bytes;
    _ = try app.feed("iagain\r\x1b");
    try tests.until(&app, &link, &surface, &d, "the new turn", tests.InState{ .id = "a1", .state = .settled });
    try tests.until(&app, &link, &surface, &d, "its records", Grew{ .from = total_before });
    try tests.until(&app, &link, &surface, &d, "on screen", tests.Shows{ .text = "Done." });
    const turn_bytes = link.response_bytes - before;
    try testing.expect(detail.total > total_before);
    try testing.expect(detail.records.items.len > first_page);
    try testing.expect(turn_bytes < 64 * 1024);

    app.focus.set(@backingInt(@import("app.zig").Area.transcript));

    // 3a. Scrolling up by pages: older records arrive before the top does,
    // and the lines on screen stay put when they do.
    const start_tail = detail.start;
    const deadline = supervisor.monotonicMs() + 60 * std.time.ms_per_s;
    var shown = try tests.dump(a, &surface);
    while (detail.start == start_tail) {
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        _ = try app.feed(page_up);
        try view.render(&app, &surface);
        shown = try tests.dump(a, &surface);
        if (app.show_inflight) {
            while (app.show_inflight) try link.pump(&app, 20);
            try view.render(&app, &surface);
            try testing.expectEqualStrings(shown, try tests.dump(a, &surface));
        }
    }
    try testing.expect(detail.start < start_tail);
    try testing.expect(!app.scroll.following());
    // One page, not the rest of the transcript.
    try testing.expect(link.response_bytes - before < 2 * proto.default_max_frame);

    // 3b. `Home` goes on to the very start, and the first words show.
    _ = try app.feed(home);
    // Each page wraps what is loaded so far anew, which takes a while in a
    // debug build; hence no `until`, with its 10 s.
    const home_deadline = supervisor.monotonicMs() + 120 * std.time.ms_per_s;
    while (!try (AtStart{}).check(&app, &surface)) {
        if (supervisor.monotonicMs() > home_deadline) return error.Timeout;
        try link.pump(&app, 20);
        try view.render(&app, &surface);
    }
    try tests.until(&app, &link, &surface, &d, "the first words", tests.Shows{ .text = "the very first words" });
    try testing.expectEqual(@as(?usize, 0), app.scroll.top);
    try testing.expectEqual(@as(u64, 0), detail.start);
    try testing.expectEqual(detail.total, detail.end);
    try testing.expectEqual(@as(usize, 0), detail.orphans.items.len);
    // Every call is closed, whichever page its end came in.
    for (detail.records.items) |*r| if (r.kind == .tool) try testing.expect(r.tool.ended());

    // A refresh with everything loaded is still small.
    before = link.response_bytes;
    try app.requestShow();
    try tests.until(&app, &link, &surface, &d, "one more refresh", struct {
        link: *Link,
        before: u64,
        pub fn check(self: @This(), ap: *App, _: *term.Surface) !bool {
            return !ap.show_inflight and self.link.response_bytes > self.before;
        }
    }{ .link = &link, .before = before });
    try testing.expect(link.response_bytes - before < 2 * 1024);
}

/// Answers the pending `agent.show` with `ok`, and returns the page it asked
/// for: `since=N`, `before=N`, or empty.
fn answerShow(app: *App, a: std.mem.Allocator, ok: []const u8) ![]const u8 {
    try testing.expectEqual(@as(usize, 1), app.outbox.items.len);
    const line = app.outbox.items[0];
    defer ta.free(line);
    app.outbox.clearRetainingCapacity();
    const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{});
    try testing.expectEqualStrings("agent.show", v.object.get("verb").?.string);
    const p = v.object.get("params").?.object;
    const asked = if (p.get("since")) |n| try std.fmt.allocPrint(a, "since={d}", .{n.integer}) else if (p.get("before")) |n| try std.fmt.allocPrint(a, "before={d}", .{n.integer}) else "";
    try app.onResponse(v.object.get("id").?.integer, .{ .ok = try std.json.parseFromSliceLeaky(Value, a, ok, .{}) });
    return asked;
}

const head = "\"agent\":\"a1\",\"title\":\"t\",\"harness\":\"fake\",\"state\":\"running\",\"unread\":false,\"workspace\":\"/w\",\"cwd\":\"/w\",\"turns\":1,\"requests\":[]";

fn show(a: std.mem.Allocator, start: u64, end: u64, total: u64, rest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{{s},\"transcript_start\":{d},\"transcript_end\":{d},\"transcript_total\":{d},{s}}}", .{ head, start, end, total, rest });
}

const OneAgent = struct {
    app: App,
    surface: term.Surface,

    fn init(self: *OneAgent, a: std.mem.Allocator, width: u16, height: u16) !void {
        self.app = App.init(ta);
        self.surface = try term.Surface.init(ta, width, height);
        try self.app.onConnected();
        try tests.feedJson(&self.app, a,
            \\{"seq":1,"ts":"2026-11-06T14:30:00.000Z","source":"venom/0e1","type":"state.snapshot","data":{"reason":"initial","complete":true,"entities":[{"resource":"agent:a1","entity_type":"agent","content":"{\"agent\":\"a1\",\"title\":\"t\",\"harness\":\"fake\",\"state\":\"running\",\"unread\":false}"}]}}
        );
        try tests.answer(&self.app, a, "agent.list",
            \\{"agents":[{"agent":"a1","title":"t","harness":"fake","state":"running","unread":false,"workspace":"/w","cwd":"/w","created_at":1,"changed_at":1}]}
        );
        _ = try tests.sent(a, &self.app);
        self.app.now_ms = 10_000;
        try self.app.preselect("a1");
        try self.app.requestShow();
    }

    fn deinit(self: *OneAgent) void {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        self.surface.deinit(&discard.writer);
        self.app.deinit();
    }
};

test "paging: an end before its start waits for the older page, and so does a turn's end" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: OneAgent = undefined;
    try t.init(a, 80, 20);
    defer t.deinit();
    const app = &t.app;
    const d = &app.model.detail;

    // The tail has c1's end and t1's end, not their starts.
    try testing.expectEqualStrings("before=9007199254740991", try answerShow(app, a, try show(a, 4, 7, 7,
        \\"transcript":[{"type":"tool.ended","turn":"t1","call":"c1","status":"error","exit":2,"duration_ms":5,"body":{"text":"boom","truncated":false,"bytes":4}},{"type":"text","turn":"t1","text":"later"},{"type":"turn.ended","turn":"t1","reason":"interrupted"}]
    )));
    try testing.expectEqual(@as(usize, 2), d.records.items.len);
    try testing.expectEqual(@as(usize, 1), d.orphans.items.len);
    // Older: the call's start, and another call the turn's end closes.
    try view.render(app, &t.surface);
    try testing.expectEqualStrings("before=4", try answerShow(app, a, try show(a, 0, 4, 7,
        \\"transcript":[{"type":"turn.started","turn":"t1"},{"type":"tool.started","turn":"t1","call":"c1","kind":"exec","name":"Bash","title":"make","status":"running","at":5},{"type":"tool.started","turn":"t1","call":"c2","kind":"exec","name":"Bash","title":"sleep","status":"running","at":6},{"type":"text","turn":"t1","text":"early"}]
    )));
    try testing.expectEqual(@as(u64, 0), d.start);
    try testing.expectEqual(@as(u64, 7), d.end);
    try testing.expectEqual(@as(usize, 0), d.orphans.items.len);
    try testing.expectEqual(@as(usize, 6), d.records.items.len);
    const c1 = &d.records.items[1].tool;
    try testing.expectEqualStrings("error", c1.status);
    try testing.expectEqual(@as(?i64, 2), c1.exit);
    try testing.expectEqualStrings("boom", c1.body);
    try testing.expectEqualStrings("interrupted", d.records.items[2].tool.status);
}

test "paging: a refresh appends, updates an open call's tail wherever it is, and starts over if it lost its place" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: OneAgent = undefined;
    try t.init(a, 80, 20);
    defer t.deinit();
    const app = &t.app;
    const d = &app.model.detail;

    try testing.expectEqualStrings("before=9007199254740991", try answerShow(app, a, try show(a, 0, 2, 2,
        \\"transcript":[{"type":"turn.started","turn":"t1"},{"type":"tool.started","turn":"t1","call":"c1","kind":"exec","name":"Bash","title":"make","status":"running","at":5}]
    )));
    const revision = d.revision;
    // Nothing new but the tail.
    try app.requestShow();
    try testing.expectEqualStrings("since=2", try answerShow(app, a, try show(a, 2, 2, 2,
        \\"tails":[{"call":"c1","tail":"building\n"}],"transcript":[]
    )));
    try testing.expectEqual(@as(usize, 2), d.records.items.len);
    try testing.expectEqualStrings("building\n", d.records.items[1].tool.tail);
    try testing.expect(d.revision != revision);
    // New records.
    try app.requestShow();
    try testing.expectEqualStrings("since=2", try answerShow(app, a, try show(a, 2, 3, 3,
        \\"transcript":[{"type":"text","turn":"t1","text":"more"}]
    )));
    try testing.expectEqual(@as(usize, 3), d.records.items.len);
    try testing.expectEqual(@as(u64, 3), d.end);
    // More than one answer can carry: the next is asked for at once.
    try app.requestShow();
    try testing.expectEqualStrings("since=3", try answerShow(app, a, try show(a, 3, 4, 9,
        \\"transcript":[{"type":"text","turn":"t1","text":"four"}]
    )));
    try testing.expectEqualStrings("since=4", try answerShow(app, a, try show(a, 4, 9, 9,
        \\"transcript":[{"type":"text","turn":"t1","text":"five"}]
    )));
    try testing.expectEqual(@as(u64, 9), d.end);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    // An answer that joins nothing (another log behind the same agent)
    // replaces what is held.
    try app.requestShow();
    try testing.expectEqualStrings("since=9", try answerShow(app, a, try show(a, 2, 2, 2,
        \\"transcript":[]
    )));
    try testing.expectEqual(@as(usize, 0), d.records.items.len);
    try testing.expectEqual(@as(u64, 2), d.start);
    try testing.expectEqual(@as(u64, 2), d.end);
}

test "paging: a failed read of older records is not asked again by every draw" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: OneAgent = undefined;
    try t.init(a, 80, 20);
    defer t.deinit();
    const app = &t.app;
    try testing.expectEqualStrings("before=9007199254740991", try answerShow(app, a, try show(a, 5, 6, 6,
        \\"transcript":[{"type":"text","turn":"t1","text":"tail"}]
    )));
    // Short of the screen: the draw asks for older records.
    try view.render(app, &t.surface);
    try testing.expectEqual(@as(usize, 1), app.outbox.items.len);
    const line = app.outbox.items[0];
    defer ta.free(line);
    app.outbox.clearRetainingCapacity();
    const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{});
    try testing.expectEqual(@as(i64, 5), v.object.get("params").?.object.get("before").?.integer);
    try app.onResponse(v.object.get("id").?.integer, .{ .@"error" = .{ .code = "denied.read", .message = "no", .data = null } });
    try view.render(app, &t.surface);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
}

test "paging: older records come in above the screen and move nothing on it; Home stays at the top" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var t: OneAgent = undefined;
    try t.init(a, 100, 20);
    defer t.deinit();
    const app = &t.app;
    const d = &app.model.detail;
    const records = struct {
        fn of(al: std.mem.Allocator, word: []const u8, n: usize) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(al, "\"transcript\":[");
            for (0..n) |i| {
                if (i > 0) try out.append(al, ',');
                try out.print(al, "{{\"type\":\"text\",\"turn\":\"t1\",\"text\":\"{s}-{d}\"}}", .{ word, i });
            }
            try out.append(al, ']');
            return out.items;
        }
    }.of;

    _ = try answerShow(app, a, try show(a, 200, 260, 260, try records(a, "tail", 60)));
    try view.render(app, &t.surface);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
    app.focus.set(@backingInt(@import("app.zig").Area.transcript));
    // Up, until less than a screen is left above: the draw asks.
    var presses: usize = 0;
    while (app.outbox.items.len == 0) : (presses += 1) {
        try testing.expect(presses < 50);
        _ = try app.feed(page_up);
        try view.render(app, &t.surface);
    }
    try testing.expect(!app.scroll.following());
    const before = try tests.dump(a, &t.surface);
    try testing.expect(std.mem.indexOf(u8, before, "tail-") != null);
    const top = app.scroll.top.?;
    try testing.expectEqualStrings("before=200", try answerShow(app, a, try show(a, 170, 200, 260, try records(a, "old", 30))));
    try testing.expectEqual(@as(u64, 170), d.start);
    try view.render(app, &t.surface);
    try testing.expectEqualStrings(before, try tests.dump(a, &t.surface));
    try testing.expectEqual(top + 30, app.scroll.top.?);

    // Home: at the top, reading on until there is nothing above.
    _ = try app.feed(home);
    try view.render(app, &t.surface);
    try testing.expectEqualStrings("before=170", try answerShow(app, a, try show(a, 0, 170, 260, try records(a, "first", 30))));
    try view.render(app, &t.surface);
    try testing.expectEqual(@as(?usize, 0), app.scroll.top);
    try testing.expect(std.mem.indexOf(u8, try tests.dump(a, &t.surface), "first-0") != null);
    try testing.expectEqual(@as(usize, 0), app.outbox.items.len);
}
