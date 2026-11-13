//! Take-over and take-back: a claude-code agent is taken over between turns,
//! a turn runs in the harness's own TUI, the TUI exits, and take back
//! imports that turn and its usage with the agent `settled`; mid-turn,
//! take-over is refused (`conflict.turn_running`; the TUI asks first, see
//! `tui/split_tests.zig`).
//!
//!
//! Attention while handed over: the
//! hooks fake-claude's TUI mode runs, through the real `venom agent hook`.
//!
//! The daemon is the real serve loop with the claude-code adapter pointed
//! at `harness/testdata/fake-claude.py`, which plays print mode for venom
//! and Claude Code's TUI for `--resume`, keeping the session transcript
//! the way Claude Code does. The real `claude` runs only in the opt-in
//! test at the end (`VENOM_CLAUDE_E2E=1`).
//!
//! The same for codex, with `harness/testdata/fake-codex.py` and
//! the opt-in `VENOM_CODEX_E2E=1`, skipped without `codex`.
const std = @import("std");
const verbs = @import("agent_verbs_tests.zig");
const harness = @import("harness/root.zig");
const eventlog = @import("eventlog/root.zig");
const split = @import("tui/split.zig");
const supervisor = @import("supervisor");
const build_options = @import("build_options");
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;
const Daemon = verbs.Daemon;

/// One protocol turn: the session, an answer, usage.
const trace =
    \\{"turns":[
    \\ [{"type":"system","subtype":"init","session_id":"$SESSION","cwd":"/w","model":"claude-opus-4-7","claude_code_version":"2.1.319"},
    \\  {"type":"assistant","session_id":"$SESSION","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"Tests pass."}]}},
    \\  {"type":"result","subtype":"success","session_id":"$SESSION","is_error":false,"modelUsage":{"claude-opus-4-7":{"inputTokens":100,"outputTokens":50,"cacheReadInputTokens":1000,"cacheCreationInputTokens":10}}}],
    \\ [{"type":"system","subtype":"init","session_id":"$SESSION","cwd":"/w","model":"claude-opus-4-7","claude_code_version":"2.1.319"},
    \\  {"type":"assistant","session_id":"$SESSION","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"Back in venom."}]}},
    \\  {"type":"result","subtype":"success","session_id":"$SESSION","is_error":false,"modelUsage":{"claude-opus-4-7":{"inputTokens":7,"outputTokens":3}}}]
    \\]}
;

pub fn writeFile(path: []const u8, bytes: []const u8, mode: c.mode_t) !void {
    var z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = c.open(&z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
}

fn readAll(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = c.open(try a.dupeSentinel(u8, path, 0), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.OpenFailed;
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

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

fn hasPython() bool {
    const r = std.process.run(ta, testing.io, .{ .argv = &.{ "python3", "-c", "" } }) catch return false;
    ta.free(r.stdout);
    ta.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

fn code(v: Value) []const u8 {
    return v.object.get("error").?.object.get("code").?.string;
}

/// A claude-code adapter on fake-claude, with a config dir in `dir`.
pub const FakeClaude = struct {
    exe: []const u8,
    config: []const u8,
    extra: [4][]const u8,
    cc: harness.ClaudeCode,

    pub fn init(self: *FakeClaude, a: std.mem.Allocator, dir: []const u8) !void {
        try self.initWith(a, dir, true);
    }
    /// `with_config` false: no Claude Code config dir, so `catch_up` is none.
    pub fn initWith(self: *FakeClaude, a: std.mem.Allocator, dir: []const u8, with_config: bool) !void {
        self.exe = try std.fmt.allocPrint(a, "{s}/fake-claude", .{dir});
        self.config = try std.fmt.allocPrint(a, "{s}/claude-config", .{dir});
        const trace_path = try std.fmt.allocPrint(a, "{s}/trace.json", .{dir});
        try writeFile(self.exe, @embedFile("harness/testdata/fake-claude.py"), 0o755);
        try writeFile(trace_path, trace, 0o644);
        self.extra = .{ "--fake-trace", trace_path, "--fake-replies", dir };
        self.cc = try .init(ta, .{ .exe = self.exe, .extra_args = &self.extra, .config_dir = if (with_config) self.config else null });
    }
    pub fn deinit(self: *FakeClaude) void {
        self.cc.deinit();
    }
};

test "take-over e2e: between turns into claude-code's own TUI, a turn there, exit; take back imports the turn and its usage, settled" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});

    // a1 (claude-code) runs one turn in protocol mode and settles.
    var r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");

    // Mid-turn take-over is refused (the TUI asks first): a2 runs a slow turn.
    r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=slow work", "--harness=fake" });
    _ = try d.waitState(a, "a2", "running");
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a2" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.turn_running", code(r.json));
    _ = try d.run(a, &.{ "agent", "stop", "--agent=a2" });
    _ = try d.waitState(a, "a2", "settled");
    // A harness without resume has no take-over.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a2" });
    try testing.expectEqualStrings("unsupported.harness_capability", code(r.json));

    // Take over a1 between turns: the protocol process is released and
    // gone; the result is the command that resumes the conversation.
    // The split runs in this process, as a venom TUI's would (`tui:<pid>`).
    const pane = try std.fmt.allocPrint(a, "tui:{d}", .{c.getpid()});
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane={s}", .{pane}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("handed_over", r.json.object.get("state").?.string);
    try testing.expectEqualStrings(pane, r.json.object.get("split").?.string);
    try testing.expectEqualStrings("claude-code", r.json.object.get("harness").?.string);
    const argv = r.json.object.get("argv").?.array.items;
    try testing.expectEqual(@as(usize, 5), argv.len);
    try testing.expectEqualStrings(fc.exe, argv[0].string);
    try testing.expectEqualStrings("--resume", argv[1].string);
    const session = argv[2].string;
    try testing.expectEqualStrings("--settings", argv[3].string);
    try testing.expect(std.mem.indexOf(u8, argv[4].string, "venom agent hook --agent a1") != null);
    try testing.expectEqualStrings(d.work, r.json.object.get("cwd").?.string);
    const env = r.json.object.get("env").?.array.items;
    try testing.expectEqualStrings("CLAUDE_CONFIG_DIR", env[0].object.get("name").?.string);
    try testing.expectEqualStrings(fc.config, env[0].object.get("value").?.string);
    var show = try d.waitState(a, "a1", "handed_over");
    // While handed over venom does not drive it.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=hello" });
    try testing.expectEqualStrings("conflict.handed_over", code(r.json));
    r = try d.run(a, &.{ "agent", "stop", "--agent=a1" });
    try testing.expectEqualStrings("conflict.agent_handed_over", code(r.json));
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1" });
    try testing.expectEqualStrings("conflict.handed_over", code(r.json));
    // A daemon restart leaves it handed over: the split's client lives.
    try d.restart();
    show = try d.waitState(a, "a1", "handed_over");

    // The user works in the harness's own TUI: one turn, then quits.
    const script = "cd \"$1\" && printf 'Add a changelog entry\\n/exit\\n' | CLAUDE_CONFIG_DIR=\"$2\" \"$3\" --resume \"$4\"";
    const tui = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", d.work, fc.config, fc.exe, session } });
    defer ta.free(tui.stdout);
    defer ta.free(tui.stderr);
    try testing.expect(tui.term == .exited and tui.term.exited == 0);
    try testing.expect(std.mem.indexOf(u8, tui.stdout, "Done: Add a changelog entry") != null);

    // Take back: the TUI's turn is imported (the protocol turn already in
    // the transcript is not), and the agent settles, unread.
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);
    try testing.expectEqual(@as(i64, 1), r.json.object.get("imported").?.integer);
    try testing.expectEqualStrings("", r.json.object.get("catch_up").?.string);
    // Asking again (the split's exit and `T` both may) changes nothing.
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(i64, 0), r.json.object.get("imported").?.integer);
    show = try d.waitState(a, "a1", "settled");
    try testing.expect(show.object.get("unread").?.bool);
    var texts: std.ArrayList([]const u8) = .empty;
    var prompts: std.ArrayList([]const u8) = .empty;
    for (show.object.get("transcript").?.array.items) |e| if (e.object.get("text")) |t| if (t == .string) {
        const prompt = std.mem.eql(u8, e.object.get("type").?.string, "turn.prompt");
        try (if (prompt) &prompts else &texts).append(a, t.string);
    };
    try testing.expectEqual(@as(usize, 2), texts.items.len);
    try testing.expectEqualStrings("Tests pass.", texts.items[0]);
    try testing.expectEqualStrings("Done: Add a changelog entry", texts.items[1]);
    // The prompt typed into its own TUI comes back with the turn.
    try testing.expectEqualStrings("Add a changelog entry", prompts.items[prompts.items.len - 1]);

    // The next prompt reattaches the same conversation in protocol mode.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=Carry on" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const until = supervisor.monotonicMs() + 10_000;
    while (true) {
        show = try d.waitState(a, "a1", "settled");
        if (show.object.get("turns").?.integer == 3) break;
        if (supervisor.monotonicMs() > until) return error.Timeout;
        sleepMs(20);
    }
    const starts = try readAll(a, try std.fmt.allocPrint(a, "{s}/argv.log", .{dir}));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, starts, "\n"), '\n');
    _ = lines.next();
    const again = try std.json.parseFromSliceLeaky([]const []const u8, a, lines.next().?, .{});
    // fake-claude logs its arguments without argv[0].
    try testing.expectEqualStrings("--resume", again[6]);
    try testing.expectEqualStrings(session, again[7]);

    // The imported turn is t2 (origin catch_up), with its call and the
    // usage of both API messages; the next turn is t3.
    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    var origins: std.ArrayList([]const u8) = .empty;
    var t2_in: u64 = 0;
    var t2_out: u64 = 0;
    var t2_calls: usize = 0;
    for (x.transcript.items) |e| switch (e) {
        .turn_started => |t| try origins.append(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ t.turn, t.origin })),
        .usage => |u| if (std.mem.eql(u8, u.turn, "t2")) {
            t2_in += u.tokens_in;
            t2_out += u.tokens_out;
            try testing.expectEqual(@as(u64, 3000), u.cache_read);
            try testing.expectEqualStrings("claude-opus-4-7", u.model);
        },
        .tool_ended => |t| if (std.mem.eql(u8, t.turn, "t2")) {
            t2_calls += 1;
            try testing.expectEqualStrings("ok", t.status);
            try testing.expectEqualStrings("git status", t.title);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), origins.items.len);
    try testing.expectEqualStrings("t1:user", origins.items[0]);
    try testing.expectEqualStrings("t2:catch_up", origins.items[1]);
    try testing.expectEqualStrings("t3:user", origins.items[2]);
    try testing.expectEqual(@as(u64, 42), t2_in);
    try testing.expectEqual(@as(u64, 42), t2_out);
    try testing.expectEqual(@as(usize, 1), t2_calls);
}

/// A fork has no conversation until its first start, so taking it
/// over before that must fork it; `ran_tui` plays a TUI that did. Returns
/// the argv of the start that follows a take-back and a send. `copy_kind`:
/// the take-over's command never ran (`none`), ran (`tui`), or left a copy
/// take-back cannot read (`unreadable`: over catch-up's size cap).
const CopyKind = enum { none, tui, unreadable };

fn takeOverUnstartedFork(copy_kind: CopyKind, expect_turns: i64) ![]const []const u8 {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    // a1's first start chose its conversation id: `--session-id <id>`.
    const first_log = try readAll(a, try std.fmt.allocPrint(a, "{s}/argv.log", .{dir}));
    const first_start = try std.json.parseFromSliceLeaky([]const []const u8, a, std.mem.sliceTo(first_log, '\n'), .{});
    var source: []const u8 = "";
    for (first_start, 0..) |x, i| if (std.mem.eql(u8, x, "--session-id")) {
        source = first_start[i + 1];
    };
    try testing.expect(source.len > 0);

    // Forked with no task: a2 has an id and no process, so no conversation.
    r = try d.run(a, &.{ "agent", "fork", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "settled");
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a2" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const argv = r.json.object.get("argv").?.array.items;
    try testing.expect(argv.len >= 6);
    try testing.expectEqualStrings("--resume", argv[1].string);
    try testing.expectEqualStrings(source, argv[2].string);
    try testing.expectEqualStrings("--fork-session", argv[3].string);
    try testing.expectEqualStrings("--session-id", argv[4].string);
    const copy = argv[5].string;
    try testing.expect(!std.mem.eql(u8, copy, source));
    _ = try d.waitState(a, "a2", "handed_over");

    if (copy_kind == .unreadable) {
        const enc = try a.dupe(u8, d.work);
        for (enc) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
            ch.* = '-';
        };
        // A sparse file over catch-up's size cap.
        const project = try std.fmt.allocPrint(a, "claude-config/projects/{s}", .{enc});
        try tmp.dir.createDirPath(testing.io, project);
        const big = try std.fmt.allocPrintSentinel(a, "{s}/{s}/{s}.jsonl", .{ dir, project, copy }, 0);
        const fd = c.open(big, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        defer _ = c.close(fd);
        try testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 257 * 1024 * 1024));
    }
    if (copy_kind == .tui) {
        // The user runs the command; Claude Code makes the copy.
        const script = "cd \"$1\" && printf 'hi\\n/exit\\n' | CLAUDE_CONFIG_DIR=\"$2\" \"$3\" --resume \"$4\" --fork-session --session-id \"$5\"";
        const tui = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", d.work, fc.config, fc.exe, source, copy } });
        defer ta.free(tui.stdout);
        defer ta.free(tui.stderr);
        try testing.expect(tui.term == .exited and tui.term.exited == 0);
    }
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a2", "--force=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "settled");
    // A take-back that finds no conversation while the agent is an unstarted
    // fork is not a failure; one that finds a copy it
    // cannot read still is.
    // The take-back's binding ends `fork_source` only on evidence that the
    // copy exists.
    const fork_source = d.engine.state.agents.getPtr("a2").?.fork_source;
    switch (copy_kind) {
        .tui => try testing.expect(fork_source == null),
        .none, .unreadable => try testing.expect(fork_source != null),
    }
    const catch_up = r.json.object.get("catch_up").?.string;
    switch (copy_kind) {
        .none, .tui => try testing.expectEqualStrings("", catch_up),
        .unreadable => try testing.expectEqualStrings("failed.harness_catch_up", catch_up),
    }

    r = try d.run(a, &.{ "agent", "send", "--agent=a2", "--text=Carry on" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const until = supervisor.monotonicMs() + 10_000;
    while (true) {
        const show = try d.waitState(a, "a2", "settled");
        if (show.object.get("turns").?.integer == expect_turns) break;
        if (supervisor.monotonicMs() > until) return error.Timeout;
        sleepMs(20);
    }
    const starts = try readAll(a, try std.fmt.allocPrint(a, "{s}/argv.log", .{dir}));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, starts, "\n"), '\n');
    var last: []const u8 = "";
    while (lines.next()) |l| last = l;
    const start = try std.json.parseFromSliceLeaky([]const []const u8, a, last, .{});
    // Copy out of the arena: the caller checks it against `copy`/`source`.
    var out: std.ArrayList([]const u8) = .empty;
    for (start) |x| try out.append(ta, try ta.dupe(u8, x));
    try out.append(ta, try ta.dupe(u8, copy));
    try out.append(ta, try ta.dupe(u8, source));
    return out.toOwnedSlice(ta);
}

fn freeArgv(argv: []const []const u8) void {
    for (argv) |x| ta.free(x);
    ta.free(argv);
}

test "take-over of a fork that has not started: the command forks it; with no copy made, the next start forks again" {
    if (!hasPython()) return error.SkipZigTest;
    const got = try takeOverUnstartedFork(.none, 1);
    defer freeArgv(got);
    const source = got[got.len - 1];
    const copy = got[got.len - 2];
    // fake-claude logs its arguments without argv[0]: the start follows `-p … --verbose`.
    try testing.expectEqualStrings("--resume", got[6]);
    try testing.expectEqualStrings(source, got[7]);
    try testing.expectEqualStrings("--fork-session", got[8]);
    try testing.expectEqualStrings("--session-id", got[9]);
    try testing.expectEqualStrings(copy, got[10]);
}

test "take-over of a fork that has not started: once the copy exists at take-back, the next start is a plain resume of it" {
    if (!hasPython()) return error.SkipZigTest;
    const got = try takeOverUnstartedFork(.tui, 2);
    defer freeArgv(got);
    const copy = got[got.len - 2];
    try testing.expectEqualStrings("--resume", got[6]);
    try testing.expectEqualStrings(copy, got[7]);
    for (got[0 .. got.len - 2]) |x| try testing.expect(!std.mem.eql(u8, x, "--fork-session"));
}

test "take-over of a fork that has not started: a copy take-back cannot read is resumed by the next start, not copied again" {
    if (!hasPython()) return error.SkipZigTest;
    const got = try takeOverUnstartedFork(.unreadable, 1);
    defer freeArgv(got);
    const copy = got[got.len - 2];
    try testing.expectEqualStrings("--resume", got[6]);
    try testing.expectEqualStrings(copy, got[7]);
    for (got[0 .. got.len - 2]) |x| try testing.expect(!std.mem.eql(u8, x, "--fork-session"));
}

test "take-over of a fork that has not started is refused without catch-up (claude-code with no config dir); the agent is unchanged and its first start still forks it" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.initWith(a, dir, false);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    r = try d.run(a, &.{ "agent", "fork", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "settled");
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a2" });
    try testing.expect(r.status != 0);
    try testing.expectEqualStrings("unsupported.harness_capability", code(r.json));
    _ = try d.waitState(a, "a2", "settled");
    r = try d.run(a, &.{ "agent", "send", "--agent=a2", "--text=Carry on" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const until = supervisor.monotonicMs() + 10_000;
    while (true) {
        const show = try d.waitState(a, "a2", "settled");
        if (show.object.get("turns").?.integer == 1) break;
        if (supervisor.monotonicMs() > until) return error.Timeout;
        sleepMs(20);
    }
    const starts = try readAll(a, try std.fmt.allocPrint(a, "{s}/argv.log", .{dir}));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, starts, "\n"), '\n');
    var last: []const u8 = "";
    while (lines.next()) |l| last = l;
    try testing.expect(std.mem.indexOf(u8, last, "--fork-session") != null);
}

/// The daemon dies while a take-back imports. `cut_mid_turn`
/// leaves the first imported turn unfinished; otherwise it is complete. The
/// restarted `harness.takeback` effect runs again over the same transcript,
/// and the agent ends up with each imported turn once.
fn crashMidImport(cut_mid_turn: bool) !void {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    // No split: a daemon restart takes it back at once.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const session = r.json.object.get("argv").?.array.items[2].string;
    _ = try d.waitState(a, "a1", "handed_over");

    // Two turns in the harness's own TUI.
    const script = "cd \"$1\" && printf 'first\\nsecond\\n/exit\\n' | CLAUDE_CONFIG_DIR=\"$2\" \"$3\" --resume \"$4\"";
    const tui = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", d.work, fc.config, fc.exe, session } });
    defer ta.free(tui.stdout);
    defer ta.free(tui.stderr);
    try testing.expect(tui.term == .exited and tui.term.exited == 0);

    // The first prompt's line uuid, as the import would log it.
    var found: ?[]const u8 = null;
    var second: ?[]const u8 = null;
    const file = try std.fmt.allocPrint(a, "{s}/projects/{s}/{s}.jsonl", .{ fc.config, try dashed(a, d.work), session });
    var lines = std.mem.splitScalar(u8, try readAll(a, file), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(Value, a, line, .{});
        const content = (v.object.get("message") orelse continue).object.get("content") orelse continue;
        if (content != .string) continue;
        if (std.mem.eql(u8, content.string, "first")) found = v.object.get("uuid").?.string;
        if (std.mem.eql(u8, content.string, "second")) second = v.object.get("uuid").?.string;
    }
    const first_uuid = found.?;

    // The crash: the first imported turn is committed (t2), the effect is not.
    d.pause();
    const rec = struct {
        fn go(dd: *Daemon, e: eventlog.Event) !void {
            _ = try dd.engine.submit(.{ .record = e });
        }
    }.go;
    // Take-back is logged (settled, effect requested); the worker never ran it.
    _ = try d.engine.submit(.{ .takeback = .{ .agent = "a1" } });
    try rec(&d, .{ .turn_started = .{ .agent = "a1", .turn = "t2", .origin = "catch_up", .harness_turn = first_uuid } });
    try rec(&d, .{ .turn_prompt = .{ .agent = "a1", .turn = "t2", .text = "first" } });
    try rec(&d, .{ .text = .{ .agent = "a1", .turn = "t2", .message = "m1", .text = "Done: first" } });
    if (!cut_mid_turn) {
        try rec(&d, .{ .usage = .{ .agent = "a1", .turn = "t2", .model = "claude-opus-4-7", .tokens_in = 42, .tokens_out = 42, .cache_read = 3000 } });
        try rec(&d, .{ .turn_ended = .{ .agent = "a1", .turn = "t2", .reason = "completed" } });
    }
    try d.restart();

    const until = supervisor.monotonicMs() + 10_000;
    while (true) {
        const show = try d.waitState(a, "a1", "settled");
        if (show.object.get("turns").?.integer == (if (cut_mid_turn) @as(i64, 4) else 3)) break;
        if (supervisor.monotonicMs() > until) return error.Timeout;
        sleepMs(20);
    }
    sleepMs(300);
    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    var done: std.ArrayList([]const u8) = .empty; // harness ids of completed catch-up turns
    var ended: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (x.transcript.items) |e| switch (e) {
        .turn_ended => |t| try ended.put(a, t.turn, t.reason),
        else => {},
    };
    var prompts: usize = 0;
    var tokens_in: u64 = 0;
    for (x.transcript.items) |e| switch (e) {
        .turn_started => |t| if (std.mem.eql(u8, t.origin, "catch_up") and std.mem.eql(u8, ended.get(t.turn) orelse "", "completed")) try done.append(a, t.harness_turn.?),
        .turn_prompt => |t| if (std.mem.eql(u8, t.text, "first") or std.mem.eql(u8, t.text, "second")) {
            if (!cut_mid_turn or !std.mem.eql(u8, t.turn, "t2")) prompts += 1;
        },
        .usage => |u| if (!std.mem.eql(u8, u.turn, "t1")) {
            tokens_in += u.tokens_in;
        },
        else => {},
    };
    // Each imported turn exactly once, whole, with its usage counted once.
    try testing.expectEqual(@as(usize, 2), done.items.len);
    try testing.expectEqualStrings(first_uuid, done.items[0]);
    try testing.expectEqualStrings(second.?, done.items[1]);
    try testing.expectEqual(@as(usize, 2), prompts);
    try testing.expectEqual(@as(u64, 84), tokens_in);
    if (cut_mid_turn) try testing.expectEqualStrings("failed", ended.get("t2").?);
}

fn dashed(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try a.dupe(u8, path);
    for (out) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
        ch.* = '-';
    };
    return out;
}

test "take-back e2e: a crash after the first imported turn is committed, then a restart, imports each turn once" {
    try crashMidImport(false);
}

test "take-back e2e: a crash in the middle of an imported turn re-imports that turn whole" {
    try crashMidImport(true);
}

extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

/// A process standing in for another venom TUI client: `sleep 30`.
fn otherClient() !c.pid_t {
    const argv = [_:null]?[*:0]const u8{ "sleep", "30" };
    const envp = [_:null]?[*:0]const u8{};
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = execve("/bin/sleep", &argv, &envp);
        _ = execve("/usr/bin/sleep", &argv, &envp);
        c._exit(127);
    }
    return pid;
}

fn reap(pid: c.pid_t) void {
    _ = c.kill(pid, .KILL);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

test "take-back of a take-over another live TUI client owns is refused unless --force; the owner (and anyone, once it is gone) passes" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");

    // Another client's split has a1: this caller (the CLI, in this
    // process) is refused, with the owner's pid.
    var other = try otherClient();
    var reaped = false;
    defer if (!reaped) reap(other);
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{other}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.owned_by_client", code(r.json));
    try testing.expectEqual(@as(i64, other), r.json.object.get("error").?.object.get("data").?.object.get("pid").?.integer);
    _ = try d.waitState(a, "a1", "handed_over");
    // --force=true takes it back anyway.
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1", "--force=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);

    // Once that client is gone, anyone may take the agent back.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{other}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    reap(other);
    reaped = true;
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);

    // The owner itself passes: a split of this process (`tui:<own pid>`).
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{c.getpid()}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);
    other = 0;
}

/// Polls `sh`'s terminal output until `want` shows (10 s at most).
fn awaitOutput(sh: *split.Shell, seen: *std.ArrayList(u8), want: []const u8) !void {
    const deadline = supervisor.monotonicMs() + 10_000;
    while (std.mem.indexOf(u8, seen.items, want) == null) {
        var buf: [4096]u8 = undefined;
        const n = try sh.pty.read(&buf);
        if (n > 0) try seen.appendSlice(ta, buf[0..n]) else sleepMs(10);
        if (supervisor.monotonicMs() > deadline) {
            std.debug.print("no {s} in:\n{s}\n", .{ want, seen.items });
            return error.Timeout;
        }
    }
}

/// `inbox list`'s items of `agent`.
fn itemsOf(d: *Daemon, a: std.mem.Allocator, agent: []const u8) ![]const Value {
    const r = try d.run(a, &.{ "inbox", "list" });
    try testing.expectEqual(@as(u8, 0), r.status);
    var out: std.ArrayList(Value) = .empty;
    for (r.json.object.get("items").?.array.items) |it| if (std.mem.eql(u8, it.object.get("agent").?.string, agent)) try out.append(a, it);
    return out.items;
}

test "attention while handed over: a permission-prompt hook from the take-over split puts the agent in the inbox, it clears on take back, and a hook from outside the split is refused" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    // The real `venom`, as `venom serve` tells its adapters.
    var exe_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const venom = std.mem.sliceTo(c.realpath(try a.dupeSentinel(u8, build_options.venom_exe, 0), &exe_buf) orelse return error.VenomMissing, 0);
    fc.cc.mcp = .{ .command = venom, .socket = d.socket };

    const permission_json = "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"message\":\"spoofed\"}";
    const input = "--input=" ++ permission_json;
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    _ = try d.run(a, &.{ "agent", "show", "--agent=a1" });

    // Not handed over: nothing to report on.
    r = try d.run(a, &.{ "harness", "hook", "--agent=a1", input });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.not_handed_over", code(r.json));
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", "--pid=1" });
    try testing.expectEqualStrings("conflict.not_handed_over", code(r.json));

    // Take over: the command carries the hooks and no token.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{c.getpid()}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    const out_argv = r.json.object.get("argv").?.array.items;
    const argv = try a.alloc([]const u8, out_argv.len);
    for (out_argv, argv) |v, *o| o.* = v.string;
    try testing.expectEqualStrings("--settings", argv[3]);
    try testing.expect(std.mem.indexOf(u8, argv[4], "agent hook --agent a1") != null);
    const split_cwd = r.json.object.get("cwd").?.string;
    var extra: std.ArrayList([2][]const u8) = .empty;
    for (r.json.object.get("env").?.array.items) |e| {
        try testing.expect(!std.mem.eql(u8, e.object.get("name").?.string, "VENOM_TOKEN"));
        try extra.append(a, .{ e.object.get("name").?.string, e.object.get("value").?.string });
    }

    // Before the split's process is known, nothing is inside it.
    r = try d.run(a, &.{ "harness", "hook", "--agent=a1", input });
    try testing.expectEqual(@as(u8, 4), r.status);
    try testing.expectEqualStrings("denied.outside_pane", code(r.json));

    // The split, as the TUI runs it: a token in the TUI's own environment
    // does not reach it.
    var env = try testing.environ.createMap(ta);
    defer env.deinit();
    try env.put("VENOM_TOKEN", "leak");
    const sh = try split.Shell.start(ta, .{ .shell = argv[0], .args = argv[1..], .extra_env = extra.items, .cwd = split_cwd, .env = &env, .agent = "a1" }, .{ .cols = 120, .rows = 40 });
    defer sh.deinit();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ta);
    // Only this client's child can be the split: not init, not itself, not
    // its parent. On a chain ending at init, pid 1 would admit anything.
    for ([_]c.pid_t{ 1, c.getpid(), c.getppid() }) |bad| {
        r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", try std.fmt.allocPrint(a, "--pid={d}", .{bad}) });
        try testing.expectEqual(@as(u8, 2), r.status);
        try testing.expectEqualStrings("invalid_params.pid", code(r.json));
    }
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", try std.fmt.allocPrint(a, "--pid={d}", .{sh.pid()}) });
    try testing.expectEqual(@as(u8, 0), r.status);

    // The harness's TUI hits a permission prompt.
    try sh.pty.writeAll("/hook Notification permission_prompt\n");
    try awaitOutput(sh, &seen, "hook Notification exit 0");
    const tui_env = try std.json.parseFromSliceLeaky(Value, a, try readAll(a, try std.fmt.allocPrint(a, "{s}/tui-env.json", .{fc.config})), .{});
    try testing.expectEqualStrings("a1", tui_env.object.get("VENOM_AGENT").?.string);
    try testing.expect(tui_env.object.get("VENOM_TOKEN") == null);
    var items = try itemsOf(&d, a, "a1");
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("approval", items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("Claude needs your permission to use Bash", items[0].object.get("reason").?.string);
    try testing.expectEqualStrings("away", items[0].object.get("item").?.string);
    try testing.expect(items[0].object.get("away").?.bool);
    try testing.expect(items[0].object.get("blocking").?.bool);
    // Answered in the harness's TUI, not here; venom still does not drive it.
    r = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=allow_once" });
    try testing.expectEqualStrings("not_found.request", code(r.json));
    _ = try d.waitState(a, "a1", "handed_over");

    // The same hook from a process outside the split: refused, through the
    // real command. This one is the split's sibling, a child of the same
    // client, as a shell split beside it would be. A report is exit 1 at
    // worst: exit 2 would make Claude Code block on it.
    // An inherited token is not presented: it would fail `denied.token`.
    const script = "printf '%s' \"$1\" | VENOM_TOKEN=bogus VENOM_SOCKET=\"$2\" \"$3\" agent hook --agent a1";
    const outside = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", permission_json, d.socket, venom } });
    defer ta.free(outside.stdout);
    defer ta.free(outside.stderr);
    try testing.expect(outside.term == .exited and outside.term.exited == 1);
    try testing.expectEqualStrings("", outside.stdout);
    try testing.expect(std.mem.indexOf(u8, outside.stderr, "denied.outside_pane") != null);
    r = try d.run(a, &.{ "harness", "hook", "--agent=a1", input });
    try testing.expectEqualStrings("denied.outside_pane", code(r.json));
    items = try itemsOf(&d, a, "a1");
    try testing.expectEqualStrings("Claude needs your permission to use Bash", items[0].object.get("reason").?.string);

    // `SessionEnd` is advisory; `Stop` turns it into a review. A restarted
    // daemon still knows the split, whose process lived on.
    try sh.pty.writeAll("/hook SessionEnd\n");
    try awaitOutput(sh, &seen, "hook SessionEnd exit 0");
    items = try itemsOf(&d, a, "a1");
    try testing.expectEqualStrings("approval", items[0].object.get("kind").?.string);
    try d.restart();
    _ = try d.waitState(a, "a1", "handed_over");
    try sh.pty.writeAll("/hook Stop\n");
    try awaitOutput(sh, &seen, "hook Stop exit 0");
    items = try itemsOf(&d, a, "a1");
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("review", items[0].object.get("kind").?.string);
    try testing.expect(!items[0].object.get("blocking").?.bool);
    seen.clearRetainingCapacity();
    try sh.pty.writeAll("/hook Notification idle_prompt\n");
    try awaitOutput(sh, &seen, "hook Notification exit 0");
    items = try itemsOf(&d, a, "a1");
    try testing.expectEqualStrings("question", items[0].object.get("kind").?.string);

    // The TUI exits and take-back runs: the item is gone.
    try sh.pty.writeAll("/exit\n");
    const exit_by = supervisor.monotonicMs() + 10_000;
    while (!sh.exited()) {
        var buf: [4096]u8 = undefined;
        _ = sh.pty.read(&buf) catch {};
        if (supervisor.monotonicMs() > exit_by) return error.Timeout;
        sleepMs(10);
    }
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    for (try itemsOf(&d, a, "a1")) |it| try testing.expect(!it.object.get("away").?.bool);
    r = try d.run(a, &.{ "harness", "hook", "--agent=a1", input });
    try testing.expectEqualStrings("conflict.not_handed_over", code(r.json));

    // The hook's transcript_path is on the binding, for catch-up.
    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    try testing.expect(std.mem.endsWith(u8, x.transcript_ref.?, ".jsonl"));
    try testing.expect(x.away == null and x.pane_root == null);
}

test "take-over split: only the TUI that owns the split reports it, and only a split it can report gets hooks" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    var exe_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const venom = std.mem.sliceTo(c.realpath(try a.dupeSentinel(u8, build_options.venom_exe, 0), &exe_buf) orelse return error.VenomMissing, 0);
    fc.cc.mcp = .{ .command = venom, .socket = d.socket };
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});
    var r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    const child = try otherClient();
    defer reap(child);
    const pid_flag = try std.fmt.allocPrint(a, "--pid={d}", .{child});

    // A plain take-over: no split to check, so no hooks, and no report.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1" });
    try testing.expectEqual(@as(usize, 3), r.json.object.get("argv").?.array.items.len);
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", pid_flag });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.not_client_split", code(r.json));
    _ = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });

    // A named venomx pane: nobody said they will report it, so no hooks. Its
    // process goes by what venomx says, and a child of this client is not it.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", "--pane=p14" });
    try testing.expectEqual(@as(usize, 3), r.json.object.get("argv").?.array.items.len);
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", pid_flag });
    try testing.expectEqualStrings("unavailable.takeover_pane", code(r.json));
    _ = try d.run(a, &.{ "agent", "takeback", "--agent=a1", "--force=true" });

    // A TUI's venomx pane: hooks, since it will report. Not before the pane is
    // named, and never init, whatever venomx says. Refused, nothing is recorded.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", "--pane=venomx" });
    try testing.expectEqual(@as(usize, 5), r.json.object.get("argv").?.array.items.len);
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", pid_flag });
    try testing.expectEqualStrings("conflict.not_client_split", code(r.json));
    r = try d.run(a, &.{ "agent", "takeover-pane", "--agent=a1", "--pane=p14" });
    try testing.expectEqual(@as(u8, 0), r.status);
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", "--pid=1" });
    try testing.expectEqualStrings("invalid_params.pid", code(r.json));
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", pid_flag });
    try testing.expectEqualStrings("unavailable.takeover_pane", code(r.json));
    r = try d.run(a, &.{ "harness", "hook", "--agent=a1", "--input={\"hook_event_name\":\"Stop\"}" });
    try testing.expectEqualStrings("denied.outside_pane", code(r.json));
    _ = try d.run(a, &.{ "agent", "takeback", "--agent=a1", "--force=true" });

    // Another TUI's split: no hooks from here, and it alone may report.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{child}) });
    try testing.expectEqual(@as(usize, 3), r.json.object.get("argv").?.array.items.len);
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", pid_flag });
    try testing.expectEqualStrings("conflict.owned_by_client", code(r.json));
    _ = try d.run(a, &.{ "agent", "takeback", "--agent=a1", "--force=true" });

    // Its own split, its own child: accepted.
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{c.getpid()}) });
    try testing.expectEqual(@as(usize, 5), r.json.object.get("argv").?.array.items.len);
    r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", pid_flag });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });

    // An agent is never the caller, even on itself: its harness process,
    // with its own token, asks for itself from its own Bash.
    r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a2", "settled");
    const out = try std.fmt.allocPrint(a, "{s}/agent-caller.json", .{dir});
    const text = try std.fmt.allocPrint(a, "--text=$run: VENOM_SOCKET={s} {s} agent takeover-split --agent=a2 --pid=1 --json > {s} 2>&1", .{ d.socket, venom, out });
    r = try d.run(a, &.{ "agent", "send", "--agent=a2", text });
    try testing.expectEqual(@as(u8, 0), r.status);
    const until = supervisor.monotonicMs() + 10_000;
    while (true) {
        const show = try d.waitState(a, "a2", "settled");
        if (show.object.get("turns").?.integer == 2) break;
        if (supervisor.monotonicMs() > until) return error.Timeout;
        sleepMs(20);
    }
    try testing.expect(std.mem.indexOf(u8, try readAll(a, out), "denied.agent_caller") != null);
}

// Opt-in: spends real Claude Code turns. `VENOM_CLAUDE_E2E=1 zig build
// test`. Skipped without `claude` or a sign-in (`claude auth status`).
// The turn "in the harness" runs through `claude --resume <id> -p`, the
// same conversation and transcript as the TUI: Claude Code's interactive
// TUI first asks whether to trust the (fresh, temporary) folder, which a
// test must not answer for the user. The TUI path itself is the hermetic
// test above.
test "a venomx take-over: its pane ID is recorded once; no take-back without --force when venomx cannot say" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeClaude = undefined;
    try fc.init(a, dir);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = fc.cc.adapter() }} });
    defer d.deinit();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});
    var r = try d.run(a, &.{ "agent", "spawn", cwd, "--task=Run the tests", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");

    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", "--pane=venomx" });
    try testing.expectEqual(@as(u8, 0), r.status);
    // This fixture's daemon has no environment to find venomx with.
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqualStrings("unavailable.takeover_pane", code(r.json));
    r = try d.run(a, &.{ "agent", "takeover-pane", "--agent=a1", "--pane=nonsense" });
    try testing.expectEqualStrings("invalid_params.pane", code(r.json));
    r = try d.run(a, &.{ "agent", "takeover-pane", "--agent=a1", "--pane=p4" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("p4", d.engine.state.agents.getPtr("a1").?.pane.?);
    r = try d.run(a, &.{ "agent", "takeover-pane", "--agent=a1", "--pane=p5" });
    try testing.expectEqualStrings("conflict.takeover_pane_set", code(r.json));
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqualStrings("unavailable.takeover_pane", code(r.json));
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=a second writer" });
    try testing.expect(r.status != 0);
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1", "--force=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
}

test "take-over e2e: a real claude-code agent, taken over for a turn in claude on the same conversation, then taken back (opt-in)" {
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
    var env = try testing.environ.createMap(ta);
    defer env.deinit();
    const config = if (env.get("CLAUDE_CONFIG_DIR")) |x| x else try std.fmt.allocPrint(a, "{s}/.claude", .{env.get("HOME") orelse return error.SkipZigTest});
    const exe = try split.findExe(a, &env, "claude") orelse return error.SkipZigTest;
    var cc: harness.ClaudeCode = try .init(ta, .{ .exe = exe, .config_dir = config });
    defer cc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.claude_code.name, .adapter = cc.adapter() }} });
    defer d.deinit();

    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Reply with the single word ready, and nothing else.", "--harness=claude-code" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try waitLong(&d, a, "a1", "settled");
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const argv = r.json.object.get("argv").?.array.items;
    try testing.expectEqualStrings("--resume", argv[1].string);
    const session = argv[2].string;

    // A turn on the same conversation, outside venom.
    const script = "cd \"$1\" && \"$2\" --resume \"$3\" -p 'Reply with the single word taken, and nothing else.'";
    const ran = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", d.work, exe, session } });
    defer ta.free(ran.stdout);
    defer ta.free(ran.stderr);
    try testing.expect(ran.term == .exited and ran.term.exited == 0);

    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);
    try testing.expectEqualStrings("", r.json.object.get("catch_up").?.string);
    try testing.expectEqual(@as(i64, 1), r.json.object.get("imported").?.integer);
    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    var imported_usage: u64 = 0;
    var catch_up_turn: ?[]const u8 = null;
    var said = false;
    for (x.transcript.items) |e| switch (e) {
        .turn_started => |t| if (std.mem.eql(u8, t.origin, "catch_up")) {
            catch_up_turn = t.turn;
        },
        .usage => |u| if (catch_up_turn) |t| if (std.mem.eql(u8, u.turn, t)) {
            imported_usage += u.tokens_out;
        },
        .text => |t| if (catch_up_turn) |turn| if (std.mem.eql(u8, t.turn, turn)) {
            said = std.ascii.findIgnoreCase(t.text, "taken") != null or said;
        },
        else => {},
    };
    try testing.expect(catch_up_turn != null);
    try testing.expect(imported_usage > 0);
    try testing.expect(said);
    try testing.expectEqual(eventlog.agent.State.settled, x.state);
}

fn waitLong(d: *Daemon, a: std.mem.Allocator, agent: []const u8, want: []const u8) !void {
    const deadline = supervisor.monotonicMs() + 300_000;
    while (true) {
        const r = try d.run(a, &.{ "agent", "show", try std.fmt.allocPrint(a, "--agent={s}", .{agent}) });
        const state = r.json.object.get("state").?.string;
        if (std.mem.eql(u8, state, want)) return;
        if (std.mem.eql(u8, state, "failed")) return error.AgentFailed;
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        sleepMs(200);
    }
}

/// A codex adapter on fake-codex, in `dir` with its traces and rollout.
const FakeCodex = struct {
    exe: []const u8,
    argv: [2][]const u8,
    cx: harness.Codex,

    fn init(self: *FakeCodex, a: std.mem.Allocator, dir: []const u8, codex_trace: []const u8) !void {
        self.exe = try std.fmt.allocPrint(a, "{s}/fake-codex", .{dir});
        try writeFile(self.exe, @embedFile("harness/testdata/fake-codex.py"), 0o755);
        try writeFile(try std.fmt.allocPrint(a, "{s}/codex_app_server.py", .{dir}), @embedFile("harness/testdata/codex_app_server.py"), 0o755);
        try writeFile(try std.fmt.allocPrint(a, "{s}/codex.trace", .{dir}), codex_trace, 0o644);
        self.argv = .{ self.exe, "app-server" };
        self.cx = .init(ta);
        self.cx.argv = &self.argv;
    }
    fn deinit(self: *FakeCodex) void {
        self.cx.deinit();
    }
};

const takeover_trace = @embedFile("harness/testdata/codex_takeover.trace");

/// What the TUI's turn adds to the rollout venom's turn is already in.
const native_rollout =
    \\{"type":"session_meta","payload":{"id":"thr_t"}}
    \\{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_1"}}
    \\{"type":"turn_context","payload":{"turn_id":"turn_1","model":"gpt-x"}}
    \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":5}}}}
    \\{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_1"}}
    \\{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_2"}}
    \\{"type":"turn_context","payload":{"turn_id":"turn_2","model":"gpt-native"}}
    \\{"type":"response_item","payload":{"type":"message","role":"user"}}
    \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":9}}}}
    \\{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_2"}}
    \\
;

/// Spawns a1 on codex, lets its one protocol turn settle, and takes it over.
fn takeOverCodex(d: *Daemon, a: std.mem.Allocator) !Value {
    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Run the tests", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), r.status);
    _ = try d.waitState(a, "a1", "settled");
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1", try std.fmt.allocPrint(a, "--pane=tui:{d}", .{c.getpid()}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("handed_over", r.json.object.get("state").?.string);
    return r.json;
}

/// Codex's own TUI: one turn, then it exits.
fn runCodexTui(exe: []const u8, cwd: []const u8) !void {
    const script = "cd \"$1\" && \"$2\" resume thr_t </dev/null";
    const tui = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", cwd, exe } });
    defer ta.free(tui.stdout);
    defer ta.free(tui.stderr);
    try testing.expect(tui.term == .exited and tui.term.exited == 0);
    try testing.expectEqualStrings("resumed thr_t\n", tui.stdout);
}

test "take-over e2e: between turns into codex's own TUI, a turn there, exit; take back imports the turn and its usage, settled" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var fc: FakeCodex = undefined;
    try fc.init(a, dir, takeover_trace);
    defer fc.deinit();
    try writeFile(try std.fmt.allocPrint(a, "{s}/native.jsonl", .{dir}), native_rollout, 0o644);
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.codex.name, .adapter = fc.cx.adapter() }} });
    defer d.deinit();

    // The protocol process is gone; the command resumes the same thread, in
    // the agent's folder, and the split can report turn ends.
    const taken = try takeOverCodex(&d, a);
    try testing.expectEqualStrings("codex", taken.object.get("harness").?.string);
    try testing.expectEqualStrings(d.work, taken.object.get("cwd").?.string);
    const argv = taken.object.get("argv").?.array.items;
    try testing.expectEqual(@as(usize, 5), argv.len);
    try testing.expectEqualStrings(fc.exe, argv[0].string);
    try testing.expectEqualStrings("resume", argv[1].string);
    try testing.expectEqualStrings("thr_t", argv[2].string);
    try testing.expectEqualStrings("-c", argv[3].string);
    try testing.expectEqualStrings("notify=[\"venom\",\"agent\",\"hook\",\"--agent\",\"a1\",\"--input\"]", argv[4].string);
    const env = taken.object.get("env").?.array.items;
    try testing.expectEqualStrings("VENOM_AGENT", env[0].object.get("name").?.string);
    for (env) |e| try testing.expect(!std.mem.eql(u8, e.object.get("name").?.string, "VENOM_TOKEN"));
    _ = try d.waitState(a, "a1", "handed_over");
    // A daemon restart leaves it handed over.
    try d.restart();
    _ = try d.waitState(a, "a1", "handed_over");

    try runCodexTui(fc.exe, d.work);

    // Take back: the TUI's turn is imported (the one venom ran is not).
    var r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);
    try testing.expectEqual(@as(i64, 1), r.json.object.get("imported").?.integer);
    try testing.expectEqualStrings("", r.json.object.get("catch_up").?.string);
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(i64, 0), r.json.object.get("imported").?.integer);
    var show = try d.waitState(a, "a1", "settled");
    try testing.expect(show.object.get("unread").?.bool);

    // The next prompt reattaches the thread; its replayed total only re-bases.
    r = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=Carry on" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const until = supervisor.monotonicMs() + 10_000;
    while (true) {
        show = try d.waitState(a, "a1", "settled");
        if (show.object.get("turns").?.integer == 3) break;
        if (supervisor.monotonicMs() > until) return error.Timeout;
        sleepMs(20);
    }

    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    var origins: std.ArrayList([]const u8) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    var prompts: std.ArrayList([]const u8) = .empty;
    var calls: usize = 0;
    var usages: usize = 0;
    for (x.transcript.items) |e| switch (e) {
        .turn_started => |s| try origins.append(a, try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ s.turn, s.origin, s.harness_turn orelse "" })),
        .text => |s| try texts.append(a, s.text),
        .turn_prompt => |s| try prompts.append(a, s.text),
        .tool_ended => |s| {
            calls += 1;
            try testing.expectEqualStrings("t2", s.turn);
            try testing.expectEqualStrings("ok", s.status);
            try testing.expectEqualStrings("git status", s.title);
        },
        .usage => |u| {
            usages += 1;
            const want: [4]u64 = if (std.mem.eql(u8, u.turn, "t1")) .{ 60, 5, 40, 0 } else if (std.mem.eql(u8, u.turn, "t2")) .{ 30, 4, 20, 0 } else .{ 20, 1, 0, 0 };
            try testing.expectEqual(want, [4]u64{ u.tokens_in, u.tokens_out, u.cache_read, u.cache_write });
            if (std.mem.eql(u8, u.turn, "t2")) try testing.expectEqualStrings("gpt-native", u.model);
        },
        else => {},
    };
    try testing.expectEqual(eventlog.agent.State.settled, x.state);
    try testing.expectEqual(@as(usize, 3), origins.items.len);
    try testing.expectEqualStrings("t1:user:turn_1", origins.items[0]);
    try testing.expectEqualStrings("t2:catch_up:turn_2", origins.items[1]);
    try testing.expectEqualStrings("t3:user:turn_3", origins.items[2]);
    try testing.expectEqual(@as(usize, 3), texts.items.len);
    try testing.expectEqualStrings("Done natively.", texts.items[1]);
    try testing.expectEqual(@as(usize, 3), prompts.items.len);
    try testing.expectEqualStrings("Add a changelog entry", prompts.items[1]);
    try testing.expectEqual(@as(usize, 1), calls);
    try testing.expectEqual(@as(usize, 3), usages);
}

test "codex take-back without a rollout imports the turn with no usage; a thread it cannot list leaves a settled agent and says so" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var fc: FakeCodex = undefined;
        try fc.init(a, try tmp.dir.realPathFileAlloc(testing.io, ".", a), takeover_trace);
        defer fc.deinit();
        var d: Daemon = undefined;
        try d.initWith(.{ .extra = &.{.{ .harness = harness.codex.name, .adapter = fc.cx.adapter() }} });
        defer d.deinit();
        _ = try takeOverCodex(&d, a);
        const r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
        try testing.expectEqual(@as(i64, 1), r.json.object.get("imported").?.integer);
        try testing.expectEqualStrings("", r.json.object.get("catch_up").?.string);
        d.pause();
        for (d.engine.state.agents.get("a1").?.transcript.items) |e| if (e == .usage) try testing.expectEqualStrings("t1", e.usage.turn);
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fc: FakeCodex = undefined;
    try fc.init(a, try tmp.dir.realPathFileAlloc(testing.io, ".", a), @embedFile("harness/testdata/codex_takeover_failed.trace"));
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.codex.name, .adapter = fc.cx.adapter() }} });
    defer d.deinit();
    _ = try takeOverCodex(&d, a);
    const r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);
    try testing.expectEqual(@as(i64, 0), r.json.object.get("imported").?.integer);
    try testing.expectEqualStrings("failed.harness_catch_up", r.json.object.get("catch_up").?.string);
}

test "attention while handed over to codex: notify from the split, through the real command, puts the turn's end up for review; from outside it is refused" {
    if (!hasPython()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fc: FakeCodex = undefined;
    try fc.init(a, try tmp.dir.realPathFileAlloc(testing.io, ".", a), takeover_trace);
    defer fc.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.codex.name, .adapter = fc.cx.adapter() }} });
    defer d.deinit();
    var exe_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const venom = std.mem.sliceTo(c.realpath(try a.dupeSentinel(u8, build_options.venom_exe, 0), &exe_buf) orelse return error.VenomMissing, 0);
    fc.cx.mcp = .{ .command = venom, .socket = d.socket };

    const taken = try takeOverCodex(&d, a);
    const out_argv = taken.object.get("argv").?.array.items;
    const argv = try a.alloc([]const u8, out_argv.len);
    for (out_argv, argv) |v, *o| o.* = v.string;
    var extra: std.ArrayList([2][]const u8) = .empty;
    for (taken.object.get("env").?.array.items) |e| try extra.append(a, .{ e.object.get("name").?.string, e.object.get("value").?.string });
    var env = try testing.environ.createMap(ta);
    defer env.deinit();
    try env.put("VENOM_TOKEN", "leak");
    const sh = try split.Shell.start(ta, .{ .shell = argv[0], .args = argv[1..], .extra_env = extra.items, .cwd = taken.object.get("cwd").?.string, .env = &env, .agent = "a1" }, .{ .cols = 120, .rows = 40 });
    defer sh.deinit();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(ta);
    var r = try d.run(a, &.{ "agent", "takeover-split", "--agent=a1", try std.fmt.allocPrint(a, "--pid={d}", .{sh.pid()}) });
    try testing.expectEqual(@as(u8, 0), r.status);

    try sh.pty.writeAll("/turn-end\n");
    try awaitOutput(sh, &seen, "notify exit 0");
    const items = try itemsOf(&d, a, "a1");
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("review", items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("turn ended in codex", items[0].object.get("reason").?.string);
    try testing.expect(items[0].object.get("away").?.bool);
    _ = try d.waitState(a, "a1", "handed_over");

    // The same report from outside the split is refused.
    const notify_json = "{\"type\":\"agent-turn-complete\"}";
    const outside = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "VENOM_SOCKET=\"$1\" \"$2\" agent hook --agent a1 --input \"$3\"", "sh", d.socket, venom, notify_json } });
    defer ta.free(outside.stdout);
    defer ta.free(outside.stderr);
    try testing.expect(outside.term == .exited and outside.term.exited == 1);
    try testing.expect(std.mem.indexOf(u8, outside.stderr, "denied.outside_pane") != null);

    try sh.pty.writeAll("/exit\n");
    const exit_by = supervisor.monotonicMs() + 10_000;
    while (!sh.exited()) {
        var buf: [4096]u8 = undefined;
        _ = sh.pty.read(&buf) catch {};
        if (supervisor.monotonicMs() > exit_by) return error.Timeout;
        sleepMs(10);
    }
    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    for (try itemsOf(&d, a, "a1")) |it| try testing.expect(!it.object.get("away").?.bool);
}

test "take-over e2e: a real codex agent, taken over for a turn in codex on the same thread, then taken back (opt-in)" {
    // One real turn each way: it spends the user's quota.
    const flag = c.getenv("VENOM_CODEX_E2E") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.sliceTo(flag, 0), "1")) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testing.environ.createMap(ta);
    defer env.deinit();
    const exe = try split.findExe(a, &env, "codex") orelse return error.SkipZigTest;
    {
        const s = std.process.run(ta, testing.io, .{ .argv = &.{ exe, "login", "status" } }) catch return error.SkipZigTest;
        defer ta.free(s.stdout);
        defer ta.free(s.stderr);
        if (s.term != .exited or s.term.exited != 0) return error.SkipZigTest;
    }
    var cx: harness.Codex = try .initCommand(ta, exe, &.{});
    defer cx.deinit();
    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = harness.codex.name, .adapter = cx.adapter() }} });
    defer d.deinit();

    var r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=Reply with the single word ready, and nothing else.", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try waitLong(&d, a, "a1", "settled");
    r = try d.run(a, &.{ "agent", "takeover", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const argv = r.json.object.get("argv").?.array.items;
    try testing.expectEqualStrings("resume", argv[1].string);
    const thread = argv[2].string;

    // A turn on the same thread, outside venom. `codex exec resume` is the
    // TUI's turn without a terminal: it records the same way.
    const script = "cd \"$1\" && \"$2\" exec resume --skip-git-repo-check \"$3\" 'Reply with the single word taken, and nothing else.' </dev/null";
    const ran = try std.process.run(ta, testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "sh", d.work, exe, thread } });
    defer ta.free(ran.stdout);
    defer ta.free(ran.stderr);
    try testing.expect(ran.term == .exited and ran.term.exited == 0);

    r = try d.run(a, &.{ "agent", "takeback", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("settled", r.json.object.get("state").?.string);
    try testing.expectEqualStrings("", r.json.object.get("catch_up").?.string);
    try testing.expectEqual(@as(i64, 1), r.json.object.get("imported").?.integer);
    d.pause();
    const x = d.engine.state.agents.get("a1").?;
    var imported_usage: u64 = 0;
    var catch_up_turn: ?[]const u8 = null;
    var said = false;
    var asked = false;
    for (x.transcript.items) |e| switch (e) {
        .turn_started => |t| if (std.mem.eql(u8, t.origin, "catch_up")) {
            catch_up_turn = t.turn;
        },
        .usage => |u| if (catch_up_turn) |t| if (std.mem.eql(u8, u.turn, t)) {
            imported_usage += u.tokens_out;
        },
        .text => |t| if (catch_up_turn) |turn| if (std.mem.eql(u8, t.turn, turn)) {
            said = std.ascii.findIgnoreCase(t.text, "taken") != null or said;
        },
        .turn_prompt => |t| if (catch_up_turn) |turn| if (std.mem.eql(u8, t.turn, turn)) {
            asked = std.mem.indexOf(u8, t.text, "taken") != null;
        },
        else => {},
    };
    try testing.expect(catch_up_turn != null);
    try testing.expect(imported_usage > 0);
    try testing.expect(said);
    try testing.expect(asked);
    try testing.expectEqual(eventlog.agent.State.settled, x.state);
}
