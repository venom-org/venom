//! The context panel's verbs (the actions call the
//! adapter) with the fake harness through the generated CLI, on
//! `agent_verbs_tests.zig`'s daemon (real serve loop on its own thread; vendor
//! harnesses disabled).
const std = @import("std");
const main = @import("main.zig");
const supervisor = @import("supervisor");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const script =
    \\{"mcp_servers":["venom","docs","linear"],"compact_context":{"used":9000,"window":200000},
    \\ "turns":[{"match":"look","steps":[{"tool":{"id":"tu1","name":"Read","kind":"read","title":"big.json"}},
    \\                                   {"tool_end":{"id":"tu1","status":"ok","body":"0123456789012345"}},
    \\                                   {"tool":{"id":"tu2","name":"search","kind":"mcp","title":"docs: frames","server":"docs"}},
    \\                                   {"tool_end":{"id":"tu2","status":"ok"}},
    \\                                   {"context":{"used":120000,"window":200000}},{"text":"Done."}]},
    \\         {"match":"Summarize","steps":[{"text":"Here is where it stands."}]},
    \\         {"match":"","steps":[{"text":"Done."}]}]}
;

fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

fn spawned(d: *Daemon, a: std.mem.Allocator) !void {
    const r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=look around", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
}

fn readState(d: *Daemon, a: std.mem.Allocator, name: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, std.fmt.allocPrint(a, "{s}/{s}", .{ d.dir, name }) catch return "", a, .limited(1 << 20)) catch "";
}

/// Polls `agent show` until its transcript holds `text`.
fn waitText(d: *Daemon, a: std.mem.Allocator, agent: []const u8, text: []const u8) !void {
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while (true) {
        const r = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{agent}) });
        for (r.json.object.get("transcript").?.array.items) |e| {
            if (e.object.get("text")) |t| if (t == .string and std.mem.indexOf(u8, t.string, text) != null) return;
        }
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(20);
    }
}

test "agent.context: what fills the window, the largest items, and the actions offered" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try spawned(&d, a);
    const r = (try d.run(a, &.{ "agent", "context", "--agent=a1" })).json;
    try testing.expectEqual(@as(i64, 120000), r.object.get("used").?.integer);
    const fills = r.object.get("fills").?.array.items;
    try testing.expectEqualStrings("fixed", str(fills[0], "kind"));
    try testing.expectEqualStrings("files", str(fills[2], "kind"));
    try testing.expectEqual(@as(i64, 4), fills[2].object.get("tokens").?.integer);
    try testing.expectEqualStrings("big.json", str(r.object.get("largest").?.array.items[0], "title"));
    const mcp = r.object.get("mcp").?.object;
    // venom's own is hidden and `docs` was called.
    try testing.expectEqual(@as(usize, 2), mcp.get("servers").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), mcp.get("unused").?.array.items.len);
    try testing.expectEqualStrings("linear", mcp.get("unused").?.array.items[0].string);
    const actions = r.object.get("actions").?.object;
    try testing.expect(actions.get("compact").?.bool and actions.get("fork").?.bool and actions.get("mcp_off").?.bool);
}

test "agent.compact reaches the adapter and runs as a turn" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try spawned(&d, a);
    try testing.expectEqual(@as(u8, 0), (try d.run(a, &.{ "agent", "compact", "--agent=a1" })).status);
    try waitText(&d, a, "a1", "compacted");
    _ = try d.waitState(a, "a1", "settled");
    try testing.expect(std.mem.indexOf(u8, readState(&d, a, "compacts"), "fake-a1") != null);
    const after = (try d.run(a, &.{ "agent", "context", "--agent=a1" })).json;
    try testing.expectEqual(@as(i64, 9000), after.object.get("used").?.integer);
    // The harness dropped most of the transcript: the parts fit the new size.
    var sum: i64 = 0;
    for (after.object.get("fills").?.array.items) |f| sum += f.object.get("tokens").?.integer;
    try testing.expectEqual(@as(i64, 9000), sum);

    const gone = try d.run(a, &.{ "agent", "compact", "--agent=a9" });
    try testing.expectEqual(@as(u8, 3), gone.status);
}

test "agent.mcp_off: the next process starts without the unused server; venom's own is refused" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try spawned(&d, a);
    const own = try d.run(a, &.{ "agent", "mcp-off", "--agent=a1", "--servers=[\"venom\"]" });
    try testing.expectEqualStrings("invalid_params.servers", own.json.object.get("error").?.object.get("code").?.string);
    const r = try d.run(a, &.{ "agent", "mcp-off", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("linear", r.json.object.get("off").?.array.items[0].string);
    // A send starts the new process, once the old one is gone.
    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    while (true) {
        const sent = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=look again" });
        if (sent.status == 0) break;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(20);
    }
    // The send returns before the new process has answered.
    while ((try d.run(a, &.{ "agent", "show", "--agent=a1" })).json.object.get("turns").?.integer < 2) {
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(20);
    }
    _ = try d.waitState(a, "a1", "settled");
    try testing.expect(std.mem.indexOf(u8, readState(&d, a, "mcp_off"), "fake-a1 linear") != null);
    const after = (try d.run(a, &.{ "agent", "context", "--agent=a1" })).json;
    const mcp = after.object.get("mcp").?.object;
    try testing.expectEqualStrings("linear", mcp.get("off").?.array.items[0].string);
    // The harness no longer reports it; nothing is left to offer.
    try testing.expect(!after.object.get("actions").?.object.get("mcp_off").?.bool);
}

test "agent.fork with no task: settled, so agent.wait ends; a later send runs it" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try spawned(&d, a);
    try testing.expectEqual(@as(u8, 0), (try d.run(a, &.{ "agent", "fork", "--agent=a1" })).status);
    _ = try d.waitState(a, "a2", "settled");
    // A timeout it would run to if the fork counted as unfinished.
    const started = supervisor.monotonicMs();
    const waited = (try d.run(a, &.{ "agent", "wait", "--agent=a1", "--timeout-s=20" })).json;
    try testing.expect(waited.object.get("done").?.bool);
    try testing.expect(supervisor.monotonicMs() - started < 10 * std.time.ms_per_s);
    try testing.expectEqual(@as(u8, 0), (try d.run(a, &.{ "agent", "send", "--agent=a2", "--text=Summarize it" })).status);
    try waitText(&d, a, "a2", "Here is where it stands.");
    _ = try d.waitState(a, "a2", "settled");
    try testing.expectEqual(@as(i64, 1), (try d.run(a, &.{ "agent", "show", "--agent=a2" })).json.object.get("turns").?.integer);
}

test "agent.fork: returns at once; the effect's end makes a sub-agent that runs its task, and is published" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try spawned(&d, a);
    const r = try d.run(a, &.{ "agent", "fork", "--agent=a1", "--task=Summarize where the work stands" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const key = str(r.json, "key");
    try testing.expectEqualStrings("fork:a1:1", key);
    _ = try d.waitState(a, "a2", "settled");
    try waitText(&d, a, "a2", "Here is where it stands.");
    const show = (try d.run(a, &.{ "agent", "show", "--agent=a1" })).json;
    const forks = show.object.get("forks").?.array.items;
    try testing.expectEqual(@as(usize, 1), forks.len);
    try testing.expectEqualStrings("ok", str(forks[0], "state"));
    try testing.expectEqualStrings("a2", str(forks[0], "fork"));
    const child = (try d.run(a, &.{ "agent", "show", "--agent=a2" })).json;
    try testing.expectEqualStrings("a1", str(child, "parent"));
    try testing.expectEqualStrings("fork of look around", str(child, "title"));
    try testing.expectEqualStrings(str(show, "cwd"), str(child, "cwd"));

    // Published: what a client that follows `events` learns.
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(ta);
    defer err.deinit();
    const status = try main.App.run(ta, &.{ "events", "--follow=false", try std.fmt.allocPrint(a, "--after={s}:0", .{d.events.source}), "--json", try std.fmt.allocPrint(a, "--socket={s}", .{d.socket}) }, .{ .stdout = &out.writer, .stderr = &err.writer, .local = main.noView() });
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"agent.fork_ended\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"fork\":\"a2\"") != null);

    // Survives a restart: the fold, not memory, knows the new agent.
    try d.restart();
    const again = (try d.run(a, &.{ "agent", "show", "--agent=a1" })).json;
    try testing.expectEqualStrings("a2", str(again.object.get("forks").?.array.items[0], "fork"));
}
