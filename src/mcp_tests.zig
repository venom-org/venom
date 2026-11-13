//! venom's MCP server for agents: a claude-code
//! agent and a codex agent each call `agent_dlist` over the `venom mcp`
//! server venom configured for their run, and the daemon attributes each
//! call to that agent's principal; the user's harness config is unchanged.
//!
//! The harnesses are `testdata/fake_mcp_harness.py`, driven by the real
//! claude-code and codex adapters: it reads the MCP config the adapter put
//! on its command line and starts the real `venom mcp` (this build's
//! binary) the way each harness does, environment rules included. The
//! vendor harnesses stay disabled in the config (`vendors_off`); the real
//! claude and codex only run in the opt-in test at the end.
//!
//! Attribution is observable through grants: each agent is spawned with
//! `read` on itself only, so its `agent_dlist` returns just itself, while
//! the test's own caller sees both agents.
const std = @import("std");
const build_options = @import("build_options");
const verbs = @import("agent_verbs_tests.zig");
const harness = @import("harness/root.zig");
const main = @import("main.zig");
const cli = @import("cli");
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

/// What a `claude mcp add` or `codex mcp add` would change in the user's
/// own harness config: Claude Code's settings file, the `mcpServers` of
/// `~/.claude.json` (the rest of it changes whenever any claude runs), and
/// Codex's `config.toml`. Missing files count as empty.
fn harnessConfig(a: std.mem.Allocator) ![]const u8 {
    const home = std.mem.sliceTo(c.getenv("HOME") orelse return "", 0);
    var out: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ ".claude/settings.json", ".codex/config.toml" }) |rel| {
        const bytes = (try readAll(a, try std.fs.path.join(a, &.{ home, rel }))) orelse "";
        try out.print(a, "{s}:{d}:", .{ rel, bytes.len });
        try out.appendSlice(a, bytes);
    }
    if (try readAll(a, try std.fs.path.join(a, &.{ home, ".claude.json" }))) |bytes| {
        if (std.json.parseFromSliceLeaky(Value, a, bytes, .{})) |v| {
            if (v == .object) {
                try out.appendSlice(a, ".claude.json mcpServers:");
                if (v.object.get("mcpServers")) |m| try out.appendSlice(a, try std.json.Stringify.valueAlloc(a, m, .{}));
            }
        } else |_| {} // being rewritten by a running claude: not ours to judge
    }
    return out.items;
}

/// The agents (`agent` field) of the last `agent_dlist` result in `path`.
fn lastList(a: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const bytes = (try readAll(a, path)) orelse return error.NoMcpCall;
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| if (line.len > 0) {
        last = line;
    };
    const v = try std.json.parseFromSliceLeaky(Value, a, last, .{});
    const result = verbs.mcpResult(v) catch {
        std.debug.print("{s}: {s}\n", .{ path, last });
        return error.McpCallFailed;
    };
    var ids: std.ArrayList([]const u8) = .empty;
    for (result.object.get("agents").?.array.items) |x| try ids.append(a, x.object.get("agent").?.string);
    return ids.items;
}

fn expectIds(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("agents: {d}, want {d}\n", .{ got.len, want.len });
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn calls(a: std.mem.Allocator, path: []const u8) !usize {
    const bytes = (try readAll(a, path)) orelse return 0;
    return std.mem.count(u8, bytes, "\n");
}

/// Waits until `path` holds `n` MCP results and the agent has settled.
fn waitCalls(d: *Daemon, a: std.mem.Allocator, agent: []const u8, path: []const u8, n: usize) !void {
    const deadline = @import("supervisor").monotonicMs() + 30_000;
    while (try calls(a, path) < n) {
        if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
        var ts: c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    _ = try d.waitState(a, agent, "settled");
}

test "agent MCP: claude-code and codex agents call agent_dlist over venom mcp as their own principal; harness config unchanged" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try harnessConfig(a);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const script = try std.fmt.allocPrint(a, "{s}/fake_mcp_harness.py", .{dir});
    try writeAll(script, @embedFile("testdata/fake_mcp_harness.py"), 0o755);
    const cc_out = try std.fmt.allocPrint(a, "{s}/claude.out", .{dir});
    const cx_out = try std.fmt.allocPrint(a, "{s}/codex.out", .{dir});
    const venom = try absolute(a, build_options.venom_exe);

    var cc: harness.ClaudeCode = try .init(ta, .{ .exe = script, .extra_args = &.{ "--fake-mode", "claude", "--fake-out", cc_out } });
    defer cc.deinit();
    var cx: harness.Codex = .init(ta);
    defer cx.deinit();
    cx.argv = &.{ "python3", script, "--fake-mode", "codex", "--fake-out", cx_out };

    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{
        .{ .harness = harness.claude_code.name, .adapter = cc.adapter() },
        .{ .harness = harness.codex.name, .adapter = cx.adapter() },
    } });
    defer d.deinit();
    // What `venom serve` gives the runner: this binary and this socket.
    const server: harness.mcp.Server = .{ .command = venom, .socket = d.socket };
    cc.mcp = server;
    cx.mcp = server;

    var r = try verbs.mcpResult(try verbs.mcpCall(&d, a, "agent_dspawn", .{ .cwd = d.work, .task = "list the agents", .harness = "claude-code", .grants = .{.{ .right = "read", .scope = "agent:a1" }} }));
    try testing.expectEqualStrings("a1", r.object.get("agent").?.string);
    r = try verbs.mcpResult(try verbs.mcpCall(&d, a, "agent_dspawn", .{ .cwd = d.work, .task = "list the agents", .harness = "codex", .grants = .{.{ .right = "read", .scope = "agent:a2" }} }));
    try testing.expectEqualStrings("a2", r.object.get("agent").?.string);
    try waitCalls(&d, a, "a1", cc_out, 1);
    try waitCalls(&d, a, "a2", cx_out, 1);

    // Both agents exist now; a second turn each lists again.
    for ([_][]const u8{ "a1", "a2" }) |id| {
        const s = try d.run(a, &.{ "agent", "send", try std.fmt.allocPrint(a, "--agent={s}", .{id}), "--text=again" });
        try testing.expectEqual(@as(u8, 0), s.status);
    }
    try waitCalls(&d, a, "a1", cc_out, 2);
    try waitCalls(&d, a, "a2", cx_out, 2);

    // Each call ran as that agent: it reads only itself...
    try expectIds(&.{"a1"}, try lastList(a, cc_out));
    try expectIds(&.{"a2"}, try lastList(a, cx_out));
    // ...while the test's caller reads both.
    r = try verbs.mcpResult(try verbs.mcpCall(&d, a, "agent_dlist", .{ .archived = false }));
    try testing.expectEqual(@as(usize, 2), r.object.get("agents").?.array.items.len);

    // The token reached the harness through its environment, never argv.
    for ([_][]const u8{ cc_out, cx_out }) |out| {
        const rec = try std.json.parseFromSliceLeaky(Value, a, (try readAll(a, try std.fmt.allocPrint(a, "{s}.argv.json", .{out}))).?, .{});
        for (rec.object.get("argv").?.array.items) |arg| try testing.expect(std.mem.indexOf(u8, arg.string, "vnt1.") == null);
        var has_token = false;
        for (rec.object.get("env").?.array.items) |name| if (std.mem.eql(u8, name.string, "VENOM_TOKEN")) {
            has_token = true;
        };
        try testing.expect(has_token);
    }
    try testing.expectEqualStrings(before, try harnessConfig(a));
}

test "venom skill documents venom's MCP server for agents; skill install writes only where it is told" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try cli.skill.render(main.App, a, main.skill_notes);
    for ([_][]const u8{ "agent_dspawn", "agent_dlist", "VENOM_TOKEN", "skill install" }) |want| {
        if (std.mem.indexOf(u8, content, want) == null) {
            std.debug.print("SKILL.md lacks {s}\n", .{want});
            return error.TestExpectedEqual;
        }
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    for ([_][]const u8{ "claude", "codex" }) |target| {
        const dir = try std.fs.path.join(a, &.{ root, target, main.tool });
        try testing.expect(try cli.skill.install(a, dir, content, false));
        try testing.expectEqualStrings(content, (try readAll(a, try std.fs.path.join(a, &.{ dir, "SKILL.md" }))).?);
        // Installing the same bytes again changes nothing.
        try testing.expect(!try cli.skill.install(a, dir, content, false));
    }
}

// Opt-in: spends a real Claude Code turn and a real Codex turn.
// `VENOM_MCP_E2E=1 zig build test`. Skipped without the harnesses.
test "agent MCP e2e: real claude-code and codex agents call agent_dlist as themselves (opt-in)" {
    const flag = c.getenv("VENOM_MCP_E2E") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.sliceTo(flag, 0), "1")) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const []const u8{ &.{ "claude", "--version" }, &.{ "codex", "login", "status" } }) |argv| {
        const s = std.process.run(ta, testing.io, .{ .argv = argv }) catch return error.SkipZigTest;
        ta.free(s.stdout);
        ta.free(s.stderr);
        if (s.term != .exited or s.term.exited != 0) return error.SkipZigTest;
    }
    const before = try harnessConfig(a);
    const venom = try absolute(a, build_options.venom_exe);
    // Print mode needs the tool allowed up front until the permission
    // prompt tool exists.
    var cc: harness.ClaudeCode = try .init(ta, .{ .extra_args = &.{ "--allowedTools", "mcp__venom__agent_dlist" } });
    defer cc.deinit();
    var cx = try harness.Codex.initCommand(ta, "codex", &.{});
    defer cx.deinit();

    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{
        .{ .harness = harness.claude_code.name, .adapter = cc.adapter() },
        .{ .harness = harness.codex.name, .adapter = cx.adapter() },
    } });
    defer d.deinit();
    const server: harness.mcp.Server = .{ .command = venom, .socket = d.socket };
    cc.mcp = server;
    cx.mcp = server;

    const task = "Call the agent_list tool of the MCP server named venom exactly once, then reply with the agent ids it returned.";
    _ = try verbs.mcpResult(try verbs.mcpCall(&d, a, "agent_dspawn", .{ .cwd = d.work, .task = task, .harness = "claude-code", .grants = .{.{ .right = "read", .scope = "agent:a1" }} }));
    _ = try verbs.mcpResult(try verbs.mcpCall(&d, a, "agent_dspawn", .{ .cwd = d.work, .task = task, .harness = "codex", .grants = .{.{ .right = "read", .scope = "agent:a2" }} }));
    for ([_][]const u8{ "a1", "a2" }) |id| {
        const deadline = @import("supervisor").monotonicMs() + 300_000;
        while (true) {
            const s = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{id}) });
            const state = s.json.object.get("state").?.string;
            if (std.mem.eql(u8, state, "settled") or std.mem.eql(u8, state, "failed")) break;
            // Approve whatever the harness asks (the MCP call itself).
            if (std.mem.eql(u8, state, "needs_you")) _ = try d.run(a, &.{ "inbox", "answer", try std.fmt.allocPrint(a, "--agent={s}", .{id}), "--answer=allow_once" });
            if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
            var ts: c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
        }
    }
    // Each agent made an `mcp` tool call that ended ok, as itself: its
    // reply names its own id and not the other agent's.
    d.pause();
    for ([_][]const u8{ "a1", "a2" }, [_][]const u8{ "a2", "a1" }) |id, other| {
        const x = d.engine.state.agents.get(id).?;
        try testing.expectEqualStrings("settled", @tagName(x.state));
        var ok = false;
        var text: std.ArrayList(u8) = .empty;
        for (x.transcript.items) |e| switch (e) {
            .tool_ended => |t| if (std.mem.eql(u8, t.kind, "mcp") and std.mem.eql(u8, t.status, "ok")) {
                ok = true;
            },
            .text => |t| try text.appendSlice(a, t.text),
            else => {},
        };
        try testing.expect(ok);
        try testing.expect(std.mem.indexOf(u8, text.items, id) != null);
        try testing.expect(std.mem.indexOf(u8, text.items, other) == null);
    }
    try testing.expectEqualStrings(before, try harnessConfig(a));
}
