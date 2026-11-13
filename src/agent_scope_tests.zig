//! Agent scope with the fake harness through the
//! generated CLI (`--json`): `agent spawn --workspace W --repos a,b`
//! records the scope; an edit in repo `c` raises an approval (stamped
//! `outside_scope`, with no "always" grant) and one in `a` does not; nested
//! workspaces resolve to the closest one. A command that writes
//! outside is stamped the same way, on `inbox.list` too, and a standing
//! grant does not answer it. Uses `agent_verbs_tests.zig`'s
//! daemon (real serve loop; vendor harnesses off, fake harness only).
//! `--repos` takes `a,b` or one JSON value (`--repos='["a","b"]'`).
const std = @import("std");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

/// Edits by path, relative to the agent's cwd (the workspace root).
const script =
    \\{"turns":[{"match":"edit c","steps":[{"tool":{"id":"tu1","name":"Edit","kind":"edit","title":"c/x.zig"}},
    \\                                     {"tool_end":{"id":"tu1","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"edit a","steps":[{"tool":{"id":"tu1","name":"Edit","kind":"edit","title":"a/x.zig"}},
    \\                                     {"tool_end":{"id":"tu1","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"cd then touch","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"cd c"}},
    \\                                            {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run it?"}},
    \\                                            {"tool_end":{"id":"tu1","status":"ok"}},
    \\                                            {"tool":{"id":"tu2","name":"Bash","kind":"exec","title":"zig build"}},
    \\                                            {"ask":{"id":"p2","kind":"approval","call":"tu2","reason":"Run it?"}},
    \\                                            {"tool_end":{"id":"tu2","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"run in a","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"cd a && zig build"}},
    \\                                       {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run it?"}},
    \\                                       {"tool_end":{"id":"tu1","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"run in c","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"cd c && zig build"}},
    \\                                       {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run it?"}},
    \\                                       {"tool_end":{"id":"tu1","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"build","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build"}},
    \\                                    {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run it?"}},
    \\                                    {"tool_end":{"id":"tu1","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"rm c","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"rm -rf c/x"}},
    \\                                   {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run it?"}},
    \\                                   {"tool_end":{"id":"tu1","status":"ok"}},{"text":"Done."}]},
    \\          {"match":"","steps":[{"text":"Done."}]}]}
;

fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
fn errorCode(v: Value) []const u8 {
    return v.object.get("error").?.object.get("code").?.string;
}
fn strings(v: Value, key: []const u8) []const Value {
    return v.object.get(key).?.array.items;
}

/// Polls `agent show` until request `id` is the oldest pending one (10 s).
fn waitRequest(d: *Daemon, a: std.mem.Allocator, agent: []const u8, id: []const u8) !Value {
    const flag = try std.fmt.allocPrint(a, "--agent={s}", .{agent});
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        const r = try d.run(a, &.{ "agent", "show", flag });
        const pending = strings(r.json, "requests");
        if (pending.len > 0 and std.mem.eql(u8, str(pending[0], "request"), id)) return r.json;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.Timeout;
}

/// `work/{a,b,c}` and `work/team/{x,y}` are repos; `work/team` is also a
/// workspace of its own.
fn tree(d: *Daemon, a: std.mem.Allocator) !void {
    for ([_][]const u8{ "a", "b", "c", "team/x", "team/y" }) |r| try d.tmp.dir.createDirPath(testing.io, try std.fmt.allocPrint(a, "work/{s}/.git", .{r}));
    var r = try d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}", .{d.work}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}/team", .{d.work}) });
    try testing.expectEqual(@as(u8, 0), r.status);
}

fn spawn(d: *Daemon, a: std.mem.Allocator, task: []const u8, extra: []const []const u8) !Daemon.Out {
    var args: std.ArrayList([]const u8) = .empty;
    // The repos here are bare `.git` folders: in place (isolation
    // is tested on real repos in `isolation_tests.zig`).
    try args.appendSlice(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--task={s}", .{task}), "--harness=fake", "--isolation=in_place" });
    try args.appendSlice(a, extra);
    return d.run(a, args.items);
}

test "agent scope: spawn --workspace --repos records the scope; an edit outside it asks, one inside does not" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    try tree(&d, a);
    const ws = try std.fmt.allocPrint(a, "--workspace={s}", .{d.work});

    // Scope a,b: recorded, starts at the workspace root.
    var r = try spawn(&d, a, "edit c please", &.{ ws, "--repos=b,a" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings(d.work, str(r.json, "workspace"));
    try testing.expectEqualStrings(d.work, str(r.json, "cwd"));
    try testing.expectEqual(@as(usize, 2), strings(r.json, "repos").len);
    try testing.expectEqualStrings("a", strings(r.json, "repos")[0].string);
    const id = str(r.json, "agent");

    // The edit in c: an approval through the harness's permission channel,
    // outside the scope, with no grant (never "always").
    const shown = try d.waitState(a, id, "needs_you");
    try testing.expectEqualStrings("b", strings(shown, "repos")[1].string);
    const req = strings(shown, "requests")[0];
    try testing.expect(req.object.get("outside_scope").?.bool);
    const inbox = try d.run(a, &.{ "inbox", "list" });
    const item = strings(inbox.json, "items")[0];
    try testing.expect(item.object.get("grant") == null or item.object.get("grant").? == .null);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{id}), "--answer=allow_always" });
    try testing.expect(r.status != 0);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{id}), "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, id, "settled");
    r = try d.run(a, &.{ "always", "list" });
    try testing.expectEqual(@as(usize, 0), strings(r.json, "grants").len);

    // The edit in a: in scope, nothing asked.
    r = try spawn(&d, a, "edit a please", &.{ ws, "--repos=[\"a\",\"b\"]" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const inside = try d.waitState(a, str(r.json, "agent"), "settled");
    try testing.expectEqual(@as(usize, 0), strings(inside, "requests").len);

    // A whole-workspace agent edits c without asking.
    r = try spawn(&d, a, "edit c again", &.{ws});
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 0), strings(r.json, "repos").len);
    _ = try d.waitState(a, str(r.json, "agent"), "settled");

    // `agent list` carries the scope.
    r = try d.run(a, &.{ "agent", "list" });
    const listed = strings(r.json, "agents");
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqual(@as(usize, 0), strings(listed[0], "repos").len);
    try testing.expectEqual(@as(usize, 2), strings(listed[2], "repos").len);
}

test "agent scope: a command that writes outside is always asked, one that stays inside keeps its grant" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    try tree(&d, a);
    const ws = try std.fmt.allocPrint(a, "--workspace={s}", .{d.work});
    const scope = "--repos=[\"a\"]";

    // `rm c/x` in scope a: outside on `agent show` and `inbox list`, no grant.
    var r = try spawn(&d, a, "rm c please", &.{ ws, scope });
    try testing.expectEqual(@as(u8, 0), r.status);
    const removing = str(r.json, "agent");
    const shown = try d.waitState(a, removing, "needs_you");
    try testing.expect(strings(shown, "requests")[0].object.get("outside_scope").?.bool);
    var inbox = try d.run(a, &.{ "inbox", "list" });
    var item = strings(inbox.json, "items")[0];
    try testing.expect(item.object.get("outside_scope").?.bool);
    try testing.expect(item.object.get("grant") == null or item.object.get("grant").? == .null);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{removing}), "--answer=allow_always" });
    try testing.expect(r.status != 0);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{removing}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, removing, "settled");

    // `zig build`: not outside, and "allow always" records exec:zig.
    r = try spawn(&d, a, "build please", &.{ ws, scope });
    const building = str(r.json, "agent");
    _ = try d.waitState(a, building, "needs_you");
    inbox = try d.run(a, &.{ "inbox", "list" });
    item = strings(inbox.json, "items")[0];
    try testing.expect(!item.object.get("outside_scope").?.bool);
    try testing.expectEqualStrings("exec:zig", str(item, "grant"));
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{building}), "--answer=allow_always" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, building, "settled");

    // A later `cd c && zig build` is not answered by that grant, though the
    // command in a is judged in scope.
    r = try spawn(&d, a, "run in c", &.{ ws, scope });
    const leaving = str(r.json, "agent");
    const left = try d.waitState(a, leaving, "needs_you");
    try testing.expect(strings(left, "requests")[0].object.get("outside_scope").?.bool);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{leaving}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, leaving, "settled");
    r = try spawn(&d, a, "run in a", &.{ ws, scope });
    const staying = str(r.json, "agent");
    const stayed = try d.waitState(a, staying, "needs_you");
    try testing.expect(!strings(stayed, "requests")[0].object.get("outside_scope").?.bool);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{staying}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, staying, "settled");

    // `cd c` asks with no grant, and it lasts: the next `zig build` may run
    // there, so the standing exec:zig does not answer it. A declined `cd`
    // moved nothing: the same command is then answered by the grant.
    r = try spawn(&d, a, "cd then touch", &.{ ws, scope });
    const moving = str(r.json, "agent");
    var moved = try d.waitState(a, moving, "needs_you");
    try testing.expect(strings(moved, "requests")[0].object.get("outside_scope").?.bool);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{moving}), "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), r.status);
    moved = try waitRequest(&d, a, moving, "r2");
    try testing.expect(strings(moved, "requests")[0].object.get("outside_scope").?.bool);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{moving}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, moving, "settled");
    r = try spawn(&d, a, "cd then touch", &.{ ws, scope });
    const refused = str(r.json, "agent");
    _ = try d.waitState(a, refused, "needs_you");
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{refused}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, refused, "settled");

    // A whole-workspace agent has no outside.
    r = try spawn(&d, a, "rm c again", &.{ws});
    const whole = str(r.json, "agent");
    const open = try d.waitState(a, whole, "needs_you");
    try testing.expect(!strings(open, "requests")[0].object.get("outside_scope").?.bool);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{whole}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, whole, "settled");
}

test "agent scope: nested workspaces resolve to the closest; one repo; errors" {
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    try tree(&d, a);
    const ws = try std.fmt.allocPrint(a, "--workspace={s}", .{d.work});
    const team = try std.fmt.allocPrint(a, "{s}/team", .{d.work});

    // Repos of the nested workspace: it owns the agent, which starts there.
    var r = try spawn(&d, a, "hi", &.{ ws, "--repos=[\"team/x\"]" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings(team, str(r.json, "workspace"));
    try testing.expectEqualStrings(team, str(r.json, "cwd"));
    try testing.expectEqualStrings("x", strings(r.json, "repos")[0].string);
    _ = try d.waitState(a, str(r.json, "agent"), "settled");

    // A repo folder as the workspace: one repo of the outer workspace.
    r = try spawn(&d, a, "hi", &.{try std.fmt.allocPrint(a, "--workspace={s}/c", .{d.work})});
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings(d.work, str(r.json, "workspace"));
    try testing.expectEqualStrings("c", strings(r.json, "repos")[0].string);
    // It edits a, outside its one repo: asked.
    r = try spawn(&d, a, "edit a now", &.{try std.fmt.allocPrint(a, "--workspace={s}/c", .{d.work})});
    try testing.expectEqual(@as(u8, 0), r.status);
    const asked = try d.waitState(a, str(r.json, "agent"), "needs_you");
    try testing.expect(strings(asked, "requests")[0].object.get("outside_scope").?.bool);
    r = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{str(asked, "agent")}), "--answer=deny" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, str(asked, "agent"), "settled");

    // Errors: stable codes, nothing created.
    r = try spawn(&d, a, "hi", &.{ ws, "--repos=[\"nope\"]" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.repo", errorCode(r.json));
    r = try spawn(&d, a, "hi", &.{ ws, "--repos=[\"../c\"]" });
    try testing.expectEqualStrings("invalid_params.repos", errorCode(r.json));
    r = try spawn(&d, a, "hi", &.{ "--workspace=/no/such/place", "--repos=[\"a\"]" });
    try testing.expectEqualStrings("not_found.workspace", errorCode(r.json));
    r = try spawn(&d, a, "hi", &.{});
    try testing.expectEqualStrings("invalid_params.workspace", errorCode(r.json));
    r = try spawn(&d, a, "hi", &.{ ws, "--cwd=/elsewhere" });
    try testing.expectEqualStrings("invalid_params.cwd", errorCode(r.json));
    r = try d.run(a, &.{ "agent", "list", "--archived=true" });
    try testing.expectEqual(@as(usize, 3), strings(r.json, "agents").len);
}
