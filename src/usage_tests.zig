//! The usage verbs end to end: agents run on the
//! fake harness, whose default turn makes one tool call and reports
//! `usage {in:10, out:5, cache_read:100, cache_write:7}`; then `venom usage
//! show --json` for every grouping and range, and `venom usage export`.
//! Tree totals over parents are covered in `usage.zig` (the agent verbs do
//! not spawn sub-agents yet).
const std = @import("std");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const usage = @import("usage.zig");
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

fn int(v: Value, key: []const u8) i64 {
    return v.object.get(key).?.integer;
}

test "usage verbs: show by agent, workspace and harness over every range; CSV export" {
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try d.run(a, &.{ "usage", "show" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 0), r.json.object.get("rows").?.array.items.len);

    // a1 in the workspace (two turns), a2 outside it (one turn).
    r = try d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}/sub", .{d.work}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}/sub", .{d.work}), "--task=one", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=two" });
    try testing.expectEqual(@as(u8, 0), r.status);
    // `send` returns once the turn has started; wait for its end.
    const deadline = std.time.ms_per_s * 10;
    var waited: i64 = 0;
    while (true) : (waited += 20) {
        const shown = try d.waitState(a, "a1", "settled");
        if (int(shown, "turns") == 2) break;
        if (waited > deadline) return error.Timeout;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=three", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "settled");

    for ([_][]const u8{ "today", "7d", "30d" }) |range| {
        const rflag = try std.fmt.allocPrint(a, "--range={s}", .{range});

        r = try d.run(a, &.{ "usage", "show", "--group=agent", rflag });
        try testing.expectEqual(@as(u8, 0), r.status);
        try testing.expectEqualStrings(range, r.json.object.get("range").?.string);
        try testing.expect(int(r.json, "since") <= int(r.json, "until"));
        const rows = r.json.object.get("rows").?.array.items;
        try testing.expectEqual(@as(usize, 2), rows.len);
        try testing.expectEqualStrings("a1", rows[0].object.get("key").?.string);
        try testing.expectEqual(@as(i64, 2), int(rows[0], "turns"));
        try testing.expectEqual(@as(i64, 2), int(rows[0], "tool_calls"));
        try testing.expectEqual(@as(i64, 20), int(rows[0], "tokens_in"));
        try testing.expectEqual(@as(i64, 10), int(rows[0], "tokens_out"));
        try testing.expectEqual(@as(i64, 200), int(rows[0], "cache_read"));
        try testing.expectEqual(@as(i64, 14), int(rows[0], "cache_write"));
        try testing.expectEqualStrings("fake", rows[0].object.get("harness").?.string);
        // No sub-agents: the tree is the agent.
        try testing.expectEqual(@as(i64, 20), int(rows[0].object.get("tree").?, "tokens_in"));
        try testing.expectEqual(@as(i64, 10), int(rows[1], "tokens_in"));
        const total = r.json.object.get("total").?;
        try testing.expectEqual(@as(i64, 3), int(total, "turns"));
        try testing.expectEqual(@as(i64, 3), int(total, "tool_calls"));
        try testing.expectEqual(@as(i64, 30), int(total, "tokens_in"));
        try testing.expectEqual(int(rows[0], "wall_ms") + int(rows[1], "wall_ms"), int(total, "wall_ms"));

        r = try d.run(a, &.{ "usage", "show", "--group=workspace", rflag });
        try testing.expectEqual(@as(u8, 0), r.status);
        const ws = r.json.object.get("rows").?.array.items;
        try testing.expectEqual(@as(usize, 2), ws.len);
        // Sorted by path: the work folder, then its sub-folder workspace.
        try testing.expectEqualStrings(d.work, ws[0].object.get("key").?.string);
        try testing.expectEqual(@as(i64, 10), int(ws[0], "tokens_in"));
        try testing.expect(std.mem.endsWith(u8, ws[1].object.get("key").?.string, "/sub"));
        try testing.expectEqual(@as(i64, 20), int(ws[1], "tokens_in"));
        try testing.expect(ws[1].object.get("tree") == null);

        r = try d.run(a, &.{ "usage", "show", "--group=harness", rflag });
        try testing.expectEqual(@as(u8, 0), r.status);
        const hs = r.json.object.get("rows").?.array.items;
        try testing.expectEqual(@as(usize, 1), hs.len);
        try testing.expectEqualStrings("fake", hs[0].object.get("key").?.string);
        try testing.expectEqual(@as(i64, 2), int(hs[0], "agents"));
        try testing.expectEqual(@as(i64, 30), int(hs[0], "tokens_in"));
        try testing.expectEqual(@as(i64, 3), int(hs[0], "turns"));
    }

    r = try d.run(a, &.{ "usage", "export", "--group=harness", "--range=7d" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(i64, 1), int(r.json, "rows"));
    const header = r.json.object.get("header").?.array.items;
    try testing.expectEqual(usage.csv_header.len, header.len);
    for (header, usage.csv_header) |h, want| try testing.expectEqualStrings(want, h.string);
    const text = r.json.object.get("csv").?.string;
    var lines = std.mem.splitSequence(u8, text, "\r\n");
    try testing.expectEqualStrings("range,since,until,group,key,agents,turns,tool_calls,tokens_in,tokens_out,cache_read,cache_write,wall_ms", lines.next().?);
    const line = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, line, "7d,"));
    try testing.expect(std.mem.indexOf(u8, line, ",harness,fake,2,3,3,30,15,300,21,") != null);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expect(lines.next() == null);

    // Unknown values are usage errors (exit 2).
    r = try d.run(a, &.{ "usage", "show", "--range=year" });
    try testing.expectEqual(@as(u8, 2), r.status);
}
