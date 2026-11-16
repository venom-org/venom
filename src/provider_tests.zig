//! Providers end to end, on a real serve loop with claude-code and codex
//! adapters pointed at the fake MCP harness script: a provider's config
//! folder reaches its harness as `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, with
//! its model and permission mode; `agents.provider` is the default; an
//! unknown provider, or a harness that is not the provider's, is refused.
const std = @import("std");
const verbs = @import("agent_verbs_tests.zig");
const harness = @import("harness/root.zig");
const harnesses = @import("harnesses.zig");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;
const Daemon = verbs.Daemon;

fn hasPython() bool {
    const r = std.process.run(ta, testing.io, .{ .argv = &.{ "python3", "-c", "" } }) catch return false;
    ta.free(r.stdout);
    ta.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

/// The fake's record of how it was started, once it has written it.
fn record(a: std.mem.Allocator, out: []const u8) !Value {
    const path = try std.fmt.allocPrint(a, "{s}.argv.json", .{out});
    const deadline = @import("supervisor").monotonicMs() + 30_000;
    while (true) {
        if (std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20))) |bytes| {
            if (std.json.parseFromSliceLeaky(Value, a, bytes, .{})) |v| return v else |_| {}
        } else |_| {}
        if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
        var ts: c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
}

fn has(argv: []const Value, flag: []const u8, value: []const u8) bool {
    for (argv, 0..) |arg, i| if (std.mem.eql(u8, arg.string, flag) and i + 1 < argv.len and std.mem.eql(u8, argv[i + 1].string, value)) return true;
    return false;
}

fn home(rec: Value, name: []const u8) ?[]const u8 {
    const v = rec.object.get("homes").?.object.get(name) orelse return null;
    return v.string;
}

test "providers: the config folder, model and mode reach the harness; agents.provider is the default" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const script = try std.fmt.allocPrint(a, "{s}/fake_mcp_harness.py", .{dir});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fake_mcp_harness.py", .data = @embedFile("testdata/fake_mcp_harness.py"), .flags = .{ .permissions = .fromMode(0o755) } });
    const cc_out = try std.fmt.allocPrint(a, "{s}/claude.out", .{dir});
    const cx_out = try std.fmt.allocPrint(a, "{s}/codex.out", .{dir});

    var cc: harness.ClaudeCode = try .init(ta, .{ .exe = script, .extra_args = &.{ "--fake-mode", "claude", "--fake-out", cc_out } });
    defer cc.deinit();
    var cx: harness.Codex = .init(ta);
    defer cx.deinit();
    cx.argv = &.{ "python3", script, "--fake-mode", "codex", "--fake-out", cx_out };

    var d: Daemon = undefined;
    try d.initWith(.{
        .config = harnesses.testConfig(
            \\.agents = .{ .provider = "Personal Max" },
            \\.providers = .{
            \\    .{ .name = "work", .harness = .claude_code },
            \\    .{ .name = "Personal Max", .harness = .claude_code, .home = "/tmp/venom-test-claude-personal", .model = "opus", .mode = .bypass_permissions },
            \\    .{ .name = "cx", .harness = .codex, .home = "/tmp/venom-test-codex-alt" },
            \\}
        ),
        .extra = &.{
            .{ .harness = harness.claude_code.name, .adapter = cc.adapter() },
            .{ .harness = harness.codex.name, .adapter = cx.adapter() },
        },
    });
    defer d.deinit();
    const ws = try std.fmt.allocPrint(a, "--workspace={s}", .{d.work});

    // Dry runs: what each choice resolves to.
    var r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--dry-run=true" });
    try testing.expectEqualStrings("Personal Max", r.json.object.get("provider").?.string);
    try testing.expectEqualStrings("claude-code", r.json.object.get("harness").?.string);
    try testing.expectEqualStrings("opus", r.json.object.get("model").?.string);
    try testing.expectEqualStrings("bypass_permissions", r.json.object.get("permission_mode").?.string);
    r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--dry-run=true", "--provider=work", "--model=sonnet", "--mode=plan" });
    try testing.expectEqualStrings("sonnet", r.json.object.get("model").?.string);
    try testing.expectEqualStrings("plan", r.json.object.get("permission_mode").?.string);
    r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--dry-run=true", "--harness=codex" });
    try testing.expect(r.json.object.get("provider") == null or r.json.object.get("provider").? == .null);
    r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--dry-run=true", "--provider=nope" });
    try testing.expectEqualStrings("not_found.provider", r.json.object.get("error").?.object.get("code").?.string);
    r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--dry-run=true", "--provider=cx", "--harness=claude-code" });
    try testing.expectEqualStrings("invalid_params.provider", r.json.object.get("error").?.object.get("code").?.string);

    // The default provider, started: its folder, model and mode.
    r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--isolation=in_place" });
    try testing.expectEqual(@as(u8, 0), r.status);
    var rec = try record(a, cc_out);
    try testing.expectEqualStrings("/tmp/venom-test-claude-personal", home(rec, "CLAUDE_CONFIG_DIR").?);
    try testing.expect(has(rec.object.get("argv").?.array.items, "--model", "opus"));
    try testing.expect(has(rec.object.get("argv").?.array.items, "--permission-mode", "bypassPermissions"));

    // Codex: its CODEX_HOME.
    r = try d.run(a, &.{ "agent", "spawn", "--task=t", ws, "--isolation=in_place", "--provider=cx" });
    try testing.expectEqual(@as(u8, 0), r.status);
    rec = try record(a, cx_out);
    try testing.expectEqualStrings("/tmp/venom-test-codex-alt", home(rec, "CODEX_HOME").?);
}
