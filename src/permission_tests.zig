//! Claude Code's permission prompts reach venom's inbox: a claude-code agent's Bash call raises an approval through
//! `venom agent permission-server` and `harness.permission_prompt`, the
//! answer from `venom inbox answer` goes back as the permission result,
//! and the turn settles.
//!
//! The harness is `testdata/fake_mcp_harness.py --fake-mode
//! claude-approve`, driven by the real claude-code adapter: it reads the
//! `--mcp-config` and `--permission-prompt-tool` the adapter passed and
//! calls the real permission server (this build's binary) as Claude Code
//! does, with the token it inherited. The real `claude` runs only in the
//! opt-in test at the end (`VENOM_CLAUDE_E2E=1`).
const std = @import("std");
const build_options = @import("build_options");
const verbs = @import("agent_verbs_tests.zig");
const harness = @import("harness/root.zig");
const supervisor = @import("supervisor");
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

fn absolute(a: std.mem.Allocator, rel: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (c.realpath(try a.dupeSentinel(u8, rel, 0), &buf) == null) return error.FileNotFound;
    return a.dupe(u8, std.mem.sliceTo(&buf, 0));
}

fn readAll(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    const fd = c.open(try a.dupeSentinel(u8, path, 0), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(a, buf[0..@intCast(n)]);
    }
    return list.items;
}

fn writeAll(path: []const u8, bytes: []const u8, mode: c.mode_t) !void {
    var z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = c.open(&z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
}

/// The `n`-th line (1-based) the fake wrote to `path`, waiting for it.
fn waitLine(a: std.mem.Allocator, path: []const u8, n: usize) !Value {
    const deadline = supervisor.monotonicMs() + 30_000;
    while (true) {
        if (try readAll(a, path)) |bytes| {
            var it = std.mem.splitScalar(u8, bytes, '\n');
            var i: usize = 0;
            while (it.next()) |line| if (line.len > 0) {
                i += 1;
                if (i == n) return std.json.parseFromSliceLeaky(Value, a, line, .{});
            };
        }
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(20);
    }
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

/// The tool result text of a `tools/call` result.
fn text(result: Value) []const u8 {
    return result.object.get("content").?.array.items[0].object.get("text").?.string;
}

test "permission prompts: a claude-code agent's Bash call is approved, then denied with a reason, from venom inbox answer" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const script = try std.fmt.allocPrint(a, "{s}/fake_mcp_harness.py", .{dir});
    try writeAll(script, @embedFile("testdata/fake_mcp_harness.py"), 0o755);
    const out = try std.fmt.allocPrint(a, "{s}/claude.out", .{dir});
    const venom = try absolute(a, build_options.venom_exe);

    var cc: harness.ClaudeCode = try .init(ta, .{ .exe = script, .extra_args = &.{ "--fake-mode", "claude-approve", "--fake-out", out } });
    defer cc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = cc.adapter() }} });
    defer d.deinit();
    // What `venom serve` gives the adapter: this binary, this socket, and
    // the agents' replier.
    cc.mcp = .{ .command = venom, .socket = d.socket };
    cc.replier = d.agents.replier();

    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=say hi with echo", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "needs_you");
    // The approval is in the inbox, raised by the prompt the fake made.
    r = try d.run(a, &.{ "inbox", "list" });
    const items = r.json.object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("approval", items[0].object.get("kind").?.string);
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");

    // The fake got the one tool, and the permission result verbatim.
    var line = try waitLine(a, out, 1);
    const tools = line.object.get("tools").?.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("permission_prompt", tools[0].object.get("name").?.string);
    try testing.expectEqualStrings("{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"echo venom-1\"}}", text(line.object.get("result").?));

    // Second turn: denied with a reason, which reaches the model.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=again" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "needs_you");
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=deny", "--reason=not now" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    line = try waitLine(a, out, 2);
    try testing.expectEqualStrings("{\"behavior\":\"deny\",\"message\":\"not now\"}", text(line.object.get("result").?));

    d.pause();
    var statuses: std.ArrayList([]const u8) = .empty;
    for (d.engine.state.agents.get("a1").?.transcript.items) |e| switch (e) {
        .tool_ended => |t| try statuses.append(a, t.status),
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), statuses.items.len);
    try testing.expectEqualStrings("ok", statuses.items[0]);
    try testing.expectEqualStrings("declined", statuses.items[1]);
}

test "permission prompts: a caller that is not an agent gets a deny result, never a hang" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"permission_prompt","arguments":{"tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t1"}}}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"permission_prompt","arguments":{"tool_name":"Bash"}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"agent_dlist","arguments":{}}}
        \\
    ;
    // The real binary, as Claude Code starts it; stdin stays open until the
    // answers are in (EOF drops open calls). Without a token the call runs
    // as the test's own principal (a process ancestor), which is no agent.
    if (!hasPython()) return error.SkipZigTest;
    const venom = try absolute(a, build_options.venom_exe);
    const driver =
        \\import subprocess, sys, time
        \\p = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        \\p.stdin.write(sys.argv[1]); p.stdin.flush(); time.sleep(1.5)
        \\sys.stdout.write(p.communicate(timeout=30)[0])
    ;
    const run = try std.process.run(a, testing.io, .{ .argv = &.{ "python3", "-c", driver, input, venom, "agent", "permission-server", try std.fmt.allocPrint(a, "--socket={s}", .{d.socket}) } });
    try testing.expect(run.term == .exited and run.term.exited == 0);
    var got: [5]?Value = @splat(null);
    var it = std.mem.splitScalar(u8, run.stdout, '\n');
    while (it.next()) |l| if (l.len > 0) {
        const v = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, l), .{});
        got[@intCast(v.object.get("id").?.integer)] = v;
    };
    try testing.expectEqualStrings("venom-permissions", got[1].?.object.get("result").?.object.get("serverInfo").?.object.get("name").?.string);
    const denied = try std.json.parseFromSliceLeaky(Value, a, text(got[2].?.object.get("result").?), .{});
    try testing.expectEqualStrings("deny", denied.object.get("behavior").?.string);
    try testing.expect(std.mem.indexOf(u8, denied.object.get("message").?.string, "denied.not_agent") != null);
    const bad = try std.json.parseFromSliceLeaky(Value, a, text(got[3].?.object.get("result").?), .{});
    try testing.expectEqualStrings("deny", bad.object.get("behavior").?.string);
    // Only the permission tool is served here.
    try testing.expect(got[4].?.object.get("error") != null);
}

test "ClaudeCode.of tells the claude-code adapter from others" {
    var cc: harness.ClaudeCode = try .init(ta, .{});
    defer cc.deinit();
    try testing.expect(harness.ClaudeCode.of(cc.adapter()) == &cc);
    var fake: harness.Fake = .{ .exe = "x", .script = "", .state_dir = "" };
    try testing.expect(harness.ClaudeCode.of(fake.adapter()) == null);
}

// Opt-in: spends a real Claude Code turn. `VENOM_CLAUDE_E2E=1 zig build
// test`. Skipped without `claude` or a sign-in (`claude auth status`).
test "permission prompts e2e: a real claude-code agent asks to run a Bash command; the inbox answer reaches it (opt-in)" {
    const flag = c.getenv("VENOM_CLAUDE_E2E") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.sliceTo(flag, 0), "1")) return error.SkipZigTest;
    {
        const s = std.process.run(ta, testing.io, .{ .argv = &.{ "claude", "auth", "status", "--json" } }) catch return error.SkipZigTest;
        defer ta.free(s.stdout);
        defer ta.free(s.stderr);
        if (s.term != .exited or s.term.exited != 0) return error.SkipZigTest;
        const v = std.json.parseFromSlice(Value, ta, s.stdout, .{}) catch return error.SkipZigTest;
        defer v.deinit();
        const in = v.value.object.get("loggedIn") orelse return error.SkipZigTest;
        if (in != .bool or !in.bool) return error.SkipZigTest;
    }
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const venom = try absolute(a, build_options.venom_exe);
    // Manual mode, whatever the user's defaultMode: the command must ask.
    var cc: harness.ClaudeCode = try .init(ta, .{ .extra_args = &.{ "--permission-mode", "manual" } });
    defer cc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = cc.adapter() }} });
    defer d.deinit();
    cc.mcp = .{ .command = venom, .socket = d.socket };
    cc.replier = d.agents.replier();

    const task = "Use the Bash tool to run exactly this command and nothing else: touch venom-e2e.txt . Then reply done.";
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), try std.fmt.allocPrint(a, "--task={s}", .{task}), "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    var answered: usize = 0;
    const deadline = supervisor.monotonicMs() + 300_000;
    while (true) {
        r = try d.run(a, &.{ "agent", "show", "--agent=a1" });
        const state = r.json.object.get("state").?.string;
        if (std.mem.eql(u8, state, "settled") or std.mem.eql(u8, state, "failed")) break;
        if (std.mem.eql(u8, state, "needs_you")) {
            const ans = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=allow_once" });
            if (ans.status == 0) answered += 1;
        }
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(200);
    }
    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    try testing.expectEqualStrings("settled", @tagName(x.state));
    try testing.expect(answered >= 1);
    var ran = false;
    for (x.transcript.items) |e| switch (e) {
        .tool_ended => |t| if (std.mem.eql(u8, t.kind, "exec") and std.mem.eql(u8, t.status, "ok")) {
            ran = true;
        },
        else => {},
    };
    try testing.expect(ran);
    const made = try std.fmt.allocPrint(a, "{s}/venom-e2e.txt", .{d.work});
    try testing.expect(try readAll(a, made) != null);
}
