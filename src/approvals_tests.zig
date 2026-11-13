//! Approvals with the fake harness through the
//! generated CLI (`--json`): every inbox approval, question and
//! plan action through `inbox.answer`, with what reached the harness echoed
//! back by the fake; "allow always" kept across a daemon restart and
//! answering the next matching approval on its own; `always list|revoke`;
//! batches of same-grant approvals, and a mixed batch rejected whole. Uses
//! `agent_verbs_tests.zig`'s daemon (real serve loop; vendor harnesses off).
const std = @import("std");
const main = @import("main.zig");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

/// Every ask echoes what the harness received as a final `text`.
const script =
    \\{"turns":[{"match":"build","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build test"}},
    \\                                    {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build test?","echo":true}},
    \\                                    {"tool_end":{"id":"tu1","status":"ok","exit":0}}]},
    \\          {"match":"fmt","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig fmt --check ."}},
    \\                                  {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig fmt?","echo":true}},
    \\                                  {"tool_end":{"id":"tu1","status":"ok","exit":0}}]},
    \\          {"match":"edit","steps":[{"tool":{"id":"tu1","name":"Edit","kind":"edit","title":"src/proto.zig"}},
    \\                                   {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Edit src/proto.zig?","echo":true}},
    \\                                   {"tool_end":{"id":"tu1","status":"ok"}}]},
    \\          {"match":"question","steps":[{"ask":{"id":"q1","kind":"question","reason":"keep varint framing?","echo":true}}]},
    \\          {"match":"plan","steps":[{"ask":{"id":"pl1","kind":"plan","reason":"1. Add caps","echo":true}}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
fn errorCode(v: Value) []const u8 {
    return v.object.get("error").?.object.get("code").?.string;
}

fn spawn(d: *Daemon, a: std.mem.Allocator, task: []const u8, want: []const u8) ![]const u8 {
    const r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), try std.fmt.allocPrint(a, "--task={s}", .{task}), "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const id = str(r.json, "agent");
    _ = try d.waitState(a, id, want);
    return id;
}

/// `inbox answer` for the agent's oldest request, expecting success.
fn answer(d: *Daemon, a: std.mem.Allocator, agent: []const u8, extra: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{agent}) });
    try args.appendSlice(a, extra);
    const r = try d.run(a, args.items);
    if (r.status != 0) std.debug.print("inbox answer failed: {f}\n", .{std.json.fmt(r.json, .{})});
    try testing.expectEqual(@as(u8, 0), r.status);
}

/// The agent's last text: the fake's echo of the answer it received.
fn lastText(d: *Daemon, a: std.mem.Allocator, agent: []const u8) ![]const u8 {
    const r = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{agent}) });
    var last: []const u8 = "";
    for (r.json.object.get("transcript").?.array.items) |e| if (std.mem.eql(u8, str(e, "type"), "text")) {
        last = str(e, "text");
    };
    return last;
}

fn items(d: *Daemon, a: std.mem.Allocator, args: []const []const u8) ![]Value {
    const r = try d.run(a, args);
    try testing.expectEqual(@as(u8, 0), r.status);
    return r.json.object.get(if (std.mem.eql(u8, args[0], "always")) "grants" else "items").?.array.items;
}

/// Was `agent.attention` ever published for `agent`?
fn raised(d: *Daemon, a: std.mem.Allocator, agent: []const u8) !bool {
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(ta);
    defer err.deinit();
    const status = try main.App.run(ta, &.{ "events", "--follow=false", try std.fmt.allocPrint(a, "--after={s}:0", .{d.events.source}), "--json", try std.fmt.allocPrint(a, "--socket={s}", .{d.socket}) }, .{ .stdout = &out.writer, .stderr = &err.writer, .local = main.noView() });
    try testing.expectEqual(@as(u8, 0), status);
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, line), .{});
        if (v != .object) continue;
        const ev = if (v.object.get("item")) |i| i else v;
        if (ev != .object) continue;
        const t = ev.object.get("type") orelse continue;
        if (!std.mem.eql(u8, t.string, "agent.attention")) continue;
        const data = (ev.object.get("data") orelse continue).object;
        if (std.mem.eql(u8, data.get("agent").?.string, agent) and std.mem.eql(u8, data.get("kind").?.string, "approval")) return true;
    }
    return false;
}

test "approvals: every approval, question and plan action reaches the harness through inbox.answer" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    // The approval shows its narrowest grant.
    var id = try spawn(&d, a, "build y", "needs_you");
    const list = try items(&d, a, &.{ "inbox", "list" });
    try testing.expectEqualStrings("exec:zig", str(list[0], "grant"));
    // y: allow once.
    try answer(&d, a, id, &.{"--answer=allow_once"});
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=allow_once reason= args=", try lastText(&d, a, id));

    // n: deny; r: deny with a reason, which reaches the harness.
    id = try spawn(&d, a, "build n", "needs_you");
    try answer(&d, a, id, &.{"--answer=deny"});
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=deny reason= args=", try lastText(&d, a, id));
    id = try spawn(&d, a, "build r", "needs_you");
    try answer(&d, a, id, &.{ "--answer=deny", "--reason=use the wasm target" });
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=deny reason=use the wasm target args=", try lastText(&d, a, id));

    // e: allow with the edited command; without args it is refused.
    id = try spawn(&d, a, "build e", "needs_you");
    var r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{id}), "--answer=allow_edited" });
    try testing.expectEqual(@as(u8, 2), r.status);
    try testing.expectEqualStrings("invalid_params.answer", errorCode(r.json));
    try answer(&d, a, id, &.{ "--answer=allow_edited", "--args={\"command\":\"zig build test -Doptimize=Debug\"}" });
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=allow_edited reason= args={\"command\":\"zig build test -Doptimize=Debug\"}", try lastText(&d, a, id));

    // Cancel the turn: it ends interrupted.
    id = try spawn(&d, a, "build c", "needs_you");
    try answer(&d, a, id, &.{"--answer=cancel_turn"});
    _ = try d.waitState(a, id, "settled");

    // Question: an option label with the picks per question.
    id = try spawn(&d, a, "a question", "needs_you");
    try answer(&d, a, id, &.{ "--answer=Keep varint", "--args={\"q1\":[\"Keep varint\"]}" });
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=Keep varint reason= args={\"q1\":[\"Keep varint\"]}", try lastText(&d, a, id));
    id = try spawn(&d, a, "another question", "needs_you");
    try answer(&d, a, id, &.{"--answer=Ask me after the tests pass"});
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=Ask me after the tests pass reason= args=", try lastText(&d, a, id));

    // Plan: approve; reject with feedback; approval answers don't fit.
    id = try spawn(&d, a, "plan it", "needs_you");
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{id}), "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 2), r.status);
    try answer(&d, a, id, &.{"--answer=approve"});
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=approve reason= args=", try lastText(&d, a, id));
    id = try spawn(&d, a, "plan again", "needs_you");
    try answer(&d, a, id, &.{ "--answer=reject", "--reason=Split step 2" });
    _ = try d.waitState(a, id, "settled");
    try testing.expectEqualStrings("answer=reject reason=Split step 2 args=", try lastText(&d, a, id));

    // Nothing above was "always".
    try testing.expectEqual(@as(usize, 0), (try items(&d, a, &.{ "always", "list" })).len);
}

test "approvals: allow always keeps the narrowest grant across a restart and allows the next match; revoke" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    // a: always. The harness hears allow_always; venom keeps exec:zig.
    const first = try spawn(&d, a, "build a", "needs_you");
    try answer(&d, a, first, &.{"--answer=allow_always"});
    _ = try d.waitState(a, first, "settled");
    try testing.expectEqualStrings("answer=allow_always reason= args=", try lastText(&d, a, first));
    var grants = try items(&d, a, &.{ "always", "list" });
    try testing.expectEqual(@as(usize, 1), grants.len);
    try testing.expectEqualStrings("exec:zig", str(grants[0], "grant"));
    try testing.expectEqualStrings(d.work, str(grants[0], "workspace"));
    try testing.expectEqualStrings(first, str(grants[0], "agent"));
    try testing.expectEqual(@as(usize, 1), (try items(&d, a, &.{ "always", "list", try std.fmt.allocPrint(a, "--workspace={s}", .{d.work}) })).len);
    try testing.expectEqual(@as(usize, 0), (try items(&d, a, &.{ "always", "list", "--workspace=/elsewhere" })).len);

    // Another zig command: allowed at once, never in the inbox.
    var id = try spawn(&d, a, "fmt please", "settled");
    try testing.expectEqualStrings("answer=allow_once reason= args=", try lastText(&d, a, id));
    try testing.expect(!try raised(&d, a, id));
    try testing.expect(try raised(&d, a, first));
    // A different grant still asks.
    id = try spawn(&d, a, "edit it", "needs_you");
    try testing.expectEqualStrings("edit:src/proto.zig", str((try items(&d, a, &.{ "inbox", "list" }))[0], "grant"));
    try answer(&d, a, id, &.{"--answer=deny"});
    _ = try d.waitState(a, id, "settled");

    // After a restart the grant is still there and still answers.
    try d.restart();
    grants = try items(&d, a, &.{ "always", "list" });
    try testing.expectEqual(@as(usize, 1), grants.len);
    try testing.expectEqualStrings("exec:zig", str(grants[0], "grant"));
    id = try spawn(&d, a, "build again", "settled");
    try testing.expectEqualStrings("answer=allow_once reason= args=", try lastText(&d, a, id));
    try testing.expect(!try raised(&d, a, id));

    // Revoked: the next one asks again; revoking twice is not_found (3).
    var r = try d.run(a, &.{ "always", "revoke", try std.fmt.allocPrint(a, "--workspace={s}", .{d.work}), "--grant=exec:zig" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("exec:zig", str(r.json, "grant"));
    try testing.expectEqual(@as(usize, 0), (try items(&d, a, &.{ "always", "list" })).len);
    r = try d.run(a, &.{ "always", "revoke", try std.fmt.allocPrint(a, "--workspace={s}", .{d.work}), "--grant=exec:zig" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.grant", errorCode(r.json));
    id = try spawn(&d, a, "build once more", "needs_you");
    try answer(&d, a, id, &.{"--answer=allow_once"});
    _ = try d.waitState(a, id, "settled");
}

test "approvals: a batch answers same-grant approvals; mixed grants or non-approvals are rejected whole" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    const build = try spawn(&d, a, "build 1", "needs_you");
    const fmt = try spawn(&d, a, "fmt 2", "needs_you");
    const edit = try spawn(&d, a, "edit 3", "needs_you");
    const question = try spawn(&d, a, "question 4", "needs_you");
    const item = struct {
        fn f(al: std.mem.Allocator, ids: []const []const u8) ![]const u8 {
            var out: std.Io.Writer.Allocating = .init(al);
            try out.writer.writeAll("--items=[");
            for (ids, 0..) |x, n| try out.writer.print("{s}{{\"agent\":\"{s}\",\"request\":\"r1\"}}", .{ if (n > 0) "," else "", x });
            try out.writer.writeAll("]");
            return out.written();
        }
    }.f;

    // Mixed grants (exec:zig and edit:src/proto.zig): nothing is answered.
    var r = try d.run(a, &.{ "inbox", "batch", try item(a, &.{ build, edit }), "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 2), r.status);
    try testing.expectEqualStrings("invalid_params.batch", errorCode(r.json));
    try testing.expectEqual(@as(usize, 2), r.json.object.get("error").?.object.get("data").?.object.get("grants").?.array.items.len);
    // A question is not an approval; an empty batch; a repeated item.
    r = try d.run(a, &.{ "inbox", "batch", try item(a, &.{ build, question }), "--answer=allow_once" });
    try testing.expectEqualStrings("invalid_params.batch", errorCode(r.json));
    r = try d.run(a, &.{ "inbox", "batch", "--items=[]", "--answer=deny" });
    try testing.expectEqualStrings("invalid_params.batch", errorCode(r.json));
    r = try d.run(a, &.{ "inbox", "batch", try item(a, &.{ build, build }), "--answer=deny" });
    try testing.expectEqualStrings("invalid_params.batch", errorCode(r.json));
    try testing.expectEqual(@as(usize, 4), (try items(&d, a, &.{ "inbox", "list" })).len);

    // Y on the two exec:zig approvals.
    r = try d.run(a, &.{ "inbox", "batch", try item(a, &.{ build, fmt }), "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("exec:zig", str(r.json, "grant"));
    try testing.expectEqual(@as(usize, 2), r.json.object.get("answered").?.array.items.len);
    _ = try d.waitState(a, build, "settled");
    _ = try d.waitState(a, fmt, "settled");
    try testing.expectEqualStrings("answer=allow_once reason= args=", try lastText(&d, a, fmt));
    // Answered already: conflict (5).
    r = try d.run(a, &.{ "inbox", "batch", try item(a, &.{build}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.request_resolved", errorCode(r.json));

    // N with a reason on two more.
    const b5 = try spawn(&d, a, "build 5", "needs_you");
    const b6 = try spawn(&d, a, "fmt 6", "needs_you");
    r = try d.run(a, &.{ "inbox", "batch", try item(a, &.{ b5, b6 }), "--answer=deny", "--reason=not on main" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, b6, "settled");
    try testing.expectEqualStrings("answer=deny reason=not on main args=", try lastText(&d, a, b6));
    // The edit approval and the question still wait.
    var blocking: usize = 0;
    for (try items(&d, a, &.{ "inbox", "list" })) |it| blocking += @intFromBool(it.object.get("request") != null);
    try testing.expectEqual(@as(usize, 2), blocking);
}
