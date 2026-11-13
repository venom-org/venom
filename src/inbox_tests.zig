//! The inbox verbs with the fake harness through the
//! generated CLI (`--json`): the inbox order, answer and
//! snooze, the `attention.approval_timeout` deny, and `inbox list --json`
//! in its documented shape. Uses `agent_verbs_tests.zig`'s daemon (real
//! serve loop on its own thread; vendor harnesses disabled).
const std = @import("std");
const main = @import("main.zig");
const supervisor = @import("supervisor");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const vendors_off = @import("agent_verbs_tests.zig").vendors_off;
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const script =
    \\{"turns":[{"match":"approve","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build"}},
    \\                                      {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build?"}},
    \\                                      {"tool_end":{"id":"tu1","status":"ok","exit":0}},{"text":"built"}]},
    \\          {"match":"question","steps":[{"text":"thinking"},{"ask":{"id":"q1","kind":"question","reason":"keep varint framing?","questions":[{"question":"keep varint framing?","options":["Keep varint","Fixed u32"]}]}},{"text":"ok"}]},
    \\          {"match":"mixed","steps":[{"ask":{"id":"m1","kind":"question","reason":"Two things","questions":[{"question":"Framing?","options":["Keep varint","Fixed u32"]},{"question":"Anything else?","options":["no","yes"],"free_text":true}],"echo":true}}]},
    \\          {"match":"typed","steps":[{"ask":{"id":"t1","kind":"question","reason":"Why?","questions":[{"question":"Why?"}],"echo":true}}]},
    \\          {"match":"plan","steps":[{"ask":{"id":"pl1","kind":"plan","reason":"1. Add caps"}},{"text":"planned"}]},
    \\          {"match":"fail","steps":[{"text":"oops"},{"end":"failed"}]},
    \\          {"match":"limit","steps":[{"context":{"used":5000,"window":200000}},{"end":"limit","resets_at":1794063600}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
fn errorCode(v: Value) []const u8 {
    return v.object.get("error").?.object.get("code").?.string;
}

fn sleepMs(ms: u64) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = c.nanosleep(&ts, null);
}

fn spawn(d: *Daemon, a: std.mem.Allocator, task: []const u8, want: []const u8) ![]const u8 {
    const r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), try std.fmt.allocPrint(a, "--task={s}", .{task}), "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const id = str(r.json, "agent");
    _ = try d.waitState(a, id, want);
    // Distinct timestamps, so "oldest first" is well defined.
    sleepMs(5);
    return id;
}

fn items(d: *Daemon, a: std.mem.Allocator, args: []const []const u8) ![]Value {
    const r = try d.run(a, args);
    try testing.expectEqual(@as(u8, 0), r.status);
    return r.json.object.get("items").?.array.items;
}

/// `venom events --after=<source>:0 --follow=false --json`: every event
/// published so far (the source is fixed when the daemon starts).
fn events(d: *Daemon, a: std.mem.Allocator) ![]std.json.ObjectMap {
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(ta);
    defer err.deinit();
    const status = try main.App.run(ta, &.{ "events", "--follow=false", try std.fmt.allocPrint(a, "--after={s}:0", .{d.events.source}), "--json", try std.fmt.allocPrint(a, "--socket={s}", .{d.socket}) }, .{ .stdout = &out.writer, .stderr = &err.writer, .local = main.noView() });
    try testing.expectEqual(@as(u8, 0), status);
    var list: std.ArrayList(std.json.ObjectMap) = .empty;
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{});
        if (v != .object) continue;
        const ev = if (v.object.get("item")) |i| i else v;
        if (ev == .object and ev.object.get("type") != null) try list.append(a, ev.object);
    }
    return list.items;
}

fn hasEvent(evs: []const std.json.ObjectMap, typ: []const u8, agent: []const u8, key: []const u8, value: []const u8) bool {
    for (evs) |e| {
        if (!std.mem.eql(u8, e.get("type").?.string, typ)) continue;
        const data = (e.get("data") orelse continue).object;
        if (!std.mem.eql(u8, data.get("agent").?.string, agent)) continue;
        const v = data.get(key) orelse continue;
        if (v == .string and std.mem.eql(u8, v.string, value)) return true;
    }
    return false;
}

test "inbox answer: a question takes its labels, and any one string where the harness takes a typed answer" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try spawn(&d, a, "mixed", "needs_you");
    const list = try items(&d, a, &.{ "inbox", "list" });
    const q = list[0].object.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 2), q.len);
    try testing.expect(!q[0].object.get("free_text").?.bool);
    try testing.expect(q[1].object.get("free_text").?.bool);

    // A plain answer reaches every question, so it must be a label of q1.
    {
        const r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=anything at all" });
        try testing.expectEqual(@as(u8, 2), r.status);
        try testing.expectEqualStrings("invalid_params.answer", errorCode(r.json));
    }
    // q1 takes only its labels; an unknown id or a bad value is refused.
    for ([_][]const u8{
        "{\"q1\":[\"Use another encoding\"]}",
        "{\"q1\":[\"Keep varint\"],\"q3\":[\"x\"]}",
        "{\"q1\":[]}",
        "{\"q2\":[5]}",
    }) |args| {
        const r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=x", try std.fmt.allocPrint(a, "--args={s}", .{args}) });
        try testing.expectEqual(@as(u8, 2), r.status);
        try testing.expectEqualStrings("invalid_params.answer", errorCode(r.json));
    }
    // A label for q1 with an "Other" text for q2: one request, mixed.
    const r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=Fixed u32, only the header", "--args={\"q1\":[\"Fixed u32\"],\"q2\":[\"only the header\"]}" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    const shown = try d.run(a, &.{ "agent", "show", "--agent=a1" });
    try testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(a, shown.json, .{}), "args={\\\"q1\\\":[\\\"Fixed u32\\\"],\\\"q2\\\":[\\\"only the header\\\"]}") != null);
}

test "inbox answer: a question the harness gave no options takes a typed answer, plain or by id" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try spawn(&d, a, "typed", "needs_you");
    const list = try items(&d, a, &.{ "inbox", "list" });
    const q = list[0].object.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expect(q[0].object.get("free_text").?.bool);
    const r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=because", "--args={\"q1\":[\"because\"]}" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
}

test "inbox: urgency order, the list shape, answer and snooze through the CLI" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    // Oldest first: a1 review, a2 question, a3 approval, a4 failed,
    // a5 limit, a6 plan, a7 approval.
    _ = try spawn(&d, a, "say hi", "settled");
    _ = try spawn(&d, a, "a question", "needs_you");
    _ = try spawn(&d, a, "approve this", "needs_you");
    _ = try spawn(&d, a, "fail now", "failed");
    _ = try spawn(&d, a, "limit hit", "failed");
    _ = try spawn(&d, a, "plan first", "needs_you");
    _ = try spawn(&d, a, "approve that", "needs_you");

    var list = try items(&d, a, &.{ "inbox", "list" });
    const want = [_]struct { []const u8, []const u8 }{ .{ "a3", "approval" }, .{ "a7", "approval" }, .{ "a2", "question" }, .{ "a6", "plan" }, .{ "a4", "failed" }, .{ "a5", "limit" }, .{ "a1", "review" } };
    try testing.expectEqual(want.len, list.len);
    for (want, list) |w, it| {
        try testing.expectEqualStrings(w[0], str(it, "agent"));
        try testing.expectEqualStrings(w[1], str(it, "kind"));
        try testing.expect(it.object.get("age_s").? == .integer);
        try testing.expectEqual(!std.mem.eql(u8, w[1], "review"), it.object.get("blocking").?.bool);
    }
    // The expected members: {"agent":"a2","kind":"question","age_s":…,"reason":"keep varint framing?"}
    try testing.expectEqualStrings("keep varint framing?", str(list[2], "reason"));
    try testing.expectEqualStrings("r1", str(list[2], "request"));
    // The question's options, per question id.
    const q = list[2].object.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expectEqualStrings("q1", str(q[0], "id"));
    try testing.expectEqualStrings("keep varint framing?", str(q[0], "question"));
    try testing.expectEqualStrings("Keep varint", q[0].object.get("labels").?.array.items[0].string);
    try testing.expectEqualStrings("Fixed u32", q[0].object.get("labels").?.array.items[1].string);
    try testing.expectEqual(@as(usize, 0), list[0].object.get("options").?.array.items.len);
    // agent.show has them too.
    const shown = try d.run(a, &.{ "agent", "show", "--agent=a2" });
    try testing.expectEqual(@as(u8, 0), shown.status);
    const sq = shown.json.object.get("requests").?.array.items[0].object.get("options").?.array.items;
    try testing.expectEqualStrings("q1", str(sq[0], "id"));
    try testing.expectEqualStrings("Fixed u32", sq[0].object.get("labels").?.array.items[1].string);
    try testing.expectEqualStrings("Run zig build?", str(list[0], "reason"));
    try testing.expectEqualStrings("urgent", str(list[0], "level"));
    try testing.expectEqualStrings("failed.harness_turn", str(list[4], "reason"));
    try testing.expectEqualStrings("warn", str(list[5], "level"));
    try testing.expectEqualStrings("review", str(list[6], "item"));
    // The last turns of context.
    const ctx = list[2].object.get("context").?.array.items;
    try testing.expectEqualStrings("thinking", str(ctx[ctx.len - 1], "text"));
    try testing.expectEqualStrings("Done.", str(list[6].object.get("context").?.array.items[0], "text"));

    // Answer the oldest approval: the agent runs on and settles.
    var r = try d.run(a, &.{ "inbox", "answer", "--agent=a3", "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("r1", str(r.json, "request"));
    _ = try d.waitState(a, "a3", "settled");
    // Answering again, anywhere: conflict (exit 5).
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a3", "--request=r1", "--answer=deny" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.request_resolved", errorCode(r.json));
    // An answer that does not fit the kind: exit 2; unknown agent: exit 3.
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a7", "--answer=approve" });
    try testing.expectEqual(@as(u8, 2), r.status);
    try testing.expectEqualStrings("invalid_params.answer", errorCode(r.json));
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a99", "--answer=deny" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.agent", errorCode(r.json));
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a4", "--answer=deny" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.request", errorCode(r.json));
    // Plan and question answers.
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a6", "--answer=approve" });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a2", "--answer=Keep varint", "--args={\"q1\":[\"Keep varint\"]}" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a6", "settled");
    _ = try d.waitState(a, "a2", "settled");

    // Now: a7's approval, the two failures, then four reviews.
    list = try items(&d, a, &.{ "inbox", "list" });
    try testing.expectEqual(@as(usize, 7), list.len);
    try testing.expectEqualStrings("a7", str(list[0], "agent"));
    try testing.expectEqualStrings("failed", str(list[1], "kind"));
    try testing.expectEqualStrings("limit", str(list[2], "kind"));
    // When the limit resets.
    try testing.expectEqualStrings("2026-11-07T15:00:00Z", str(list[2], "resets_at"));
    for (list[3..]) |it| try testing.expectEqualStrings("review", str(it, "kind"));
    try testing.expectEqualStrings("a1", str(list[3], "agent"));

    // Snooze a7 (its most urgent item, for the default 15m).
    r = try d.run(a, &.{ "inbox", "snooze", "--agent=a7" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("r1", str(r.json, "item"));
    const until = r.json.object.get("until").?.integer;
    list = try items(&d, a, &.{ "inbox", "list" });
    try testing.expectEqual(@as(usize, 6), list.len);
    try testing.expectEqualStrings("failed", str(list[0], "kind"));
    list = try items(&d, a, &.{ "inbox", "list", "--snoozed=true" });
    try testing.expectEqual(@as(usize, 7), list.len);
    try testing.expectEqual(until, list[0].object.get("snoozed_until").?.integer);
    // Snooze a review by item id; errors.
    r = try d.run(a, &.{ "inbox", "snooze", "--agent=a1", "--item=review", "--duration=2h" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 5), (try items(&d, a, &.{ "inbox", "list" })).len);
    r = try d.run(a, &.{ "inbox", "snooze", "--agent=a1", "--item=r9" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.item", errorCode(r.json));
    r = try d.run(a, &.{ "inbox", "snooze", "--agent=a4", "--duration=soon" });
    try testing.expectEqual(@as(u8, 2), r.status);
    try testing.expectEqualStrings("invalid_params.duration", errorCode(r.json));
    // A snoozed request can still be answered; that clears it everywhere.
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a7", "--answer=deny", "--reason=not now" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a7", "settled");

    // Archiving clears the failure item.
    r = try d.run(a, &.{ "agent", "archive", "--agent=a4" });
    try testing.expectEqual(@as(u8, 0), r.status);

    const evs = try events(&d, a);
    try testing.expect(hasEvent(evs, "agent.attention", "a2", "kind", "question"));
    try testing.expect(hasEvent(evs, "agent.attention", "a2", "reason", "keep varint framing?"));
    try testing.expect(hasEvent(evs, "agent.attention", "a4", "kind", "failed"));
    try testing.expect(hasEvent(evs, "agent.attention", "a5", "kind", "limit"));
    // `context` is published as agent.context {agent, used, window}.
    var context = false;
    for (evs) |e| if (std.mem.eql(u8, e.get("type").?.string, "agent.context")) {
        const data = e.get("data").?.object;
        try testing.expectEqualStrings("a5", data.get("agent").?.string);
        try testing.expectEqual(@as(i64, 5000), data.get("used").?.integer);
        try testing.expectEqual(@as(i64, 200000), data.get("window").?.integer);
        context = true;
    };
    try testing.expect(context);
    try testing.expect(hasEvent(evs, "agent.attention", "a1", "kind", "review"));
    try testing.expect(hasEvent(evs, "agent.attention_cleared", "a3", "by", "venom"));
    try testing.expect(hasEvent(evs, "agent.attention_cleared", "a4", "by", "archived"));
}

test "inbox: attention.approval_timeout denies an unanswered approval with reason timeout" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script, .config = ".{ " ++ vendors_off ++ ", .attention = .{ .approval_timeout = \"300ms\" } }" });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    // Nobody answers: the deny arrives on its own, the call is declined
    // and the turn completes.
    const r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=approve this", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    const evs = try events(&d, a);
    try testing.expect(hasEvent(evs, "agent.attention", "a1", "kind", "approval"));
    try testing.expect(hasEvent(evs, "agent.attention_cleared", "a1", "by", "timeout"));
    try testing.expect(hasEvent(evs, "agent.tool_call", "a1", "status", "declined"));
    // Only the review is left.
    const list = try items(&d, a, &.{ "inbox", "list" });
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("review", str(list[0], "kind"));
}
