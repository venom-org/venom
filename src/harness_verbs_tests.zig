//! `harness.list` and `harness.show` through a daemon's reactor:
//! the call waits for a discovery run off the reactor and is answered from
//! `ServeLoop.step`. With fake binaries, doctor and `venom` itself:
//! `scripts/harness_discovery_test.py`.
const std = @import("std");
const build_options = @import("build_options");
const harness = @import("harness/root.zig");
const supervisor = @import("supervisor");
const verbs = @import("agent_verbs_tests.zig");
const Daemon = verbs.Daemon;
const c = std.c;
const testing = std.testing;
const ta = testing.allocator;

test "harness list and show: every adapter, off ones not run; an unknown id is not_found" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Daemon = undefined;
    try d.init();
    defer d.deinit();

    const list = try d.run(a, &.{ "harness", "list" });
    try testing.expectEqual(@as(u8, 0), list.status);
    const items = list.json.object.get("harnesses").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("claude-code", items[0].object.get("harness").?.string);
    try testing.expectEqualStrings("codex", items[1].object.get("harness").?.string);
    // The test daemon has the vendor harnesses off: nothing was run.
    for (items) |item| {
        try testing.expect(!item.object.get("enabled").?.bool);
        try testing.expect(item.object.get("version") == null);
        try testing.expect(item.object.get("signed_in") == null);
        try testing.expect(item.object.get("protocol") == null);
    }

    const show = try d.run(a, &.{ "harness", "show", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), show.status);
    try testing.expectEqualStrings("codex", show.json.object.get("harness").?.string);
    try testing.expectEqualStrings(@import("harness/root.zig").codex.tested_version, show.json.object.get("tested_version").?.string);

    const unknown = try d.run(a, &.{ "harness", "show", "--harness=nope" });
    try testing.expectEqual(@as(u8, 3), unknown.status);
    try testing.expectEqualStrings("not_found.harness", unknown.json.object.get("error").?.object.get("code").?.string);
}

/// A fake `codex` whose `login status` says it was asked, then waits for the
/// test to let it answer: while it waits, only a reactor that is not blocked
/// can answer anything.
const held_codex =
    \\#!/bin/sh
    \\here="$(dirname "$0")"
    \\[ "$*" = "login status" ] || exit 2
    \\: > "$here/asked"
    \\while [ ! -e "$here/answer" ]; do sleep 0.01; done
    \\if [ -e "$here/signed-out" ]; then echo 'Not logged in' >&2; exit 1; fi
    \\echo 'Logged in using ChatGPT'
    \\
;

/// `venom agent spawn` on a thread: the test thread stays free to be another
/// client of the daemon while the call is held.
const Spawner = struct {
    d: *Daemon,
    arena: std.heap.ArenaAllocator,
    args: []const []const u8,
    out: ?Daemon.Out = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(self: *Spawner, d: *Daemon, args: []const []const u8) !void {
        self.* = .{ .d = d, .arena = .init(ta), .args = args };
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }
    fn work(self: *Spawner) void {
        self.out = self.d.run(self.arena.allocator(), self.args) catch null;
        self.finished.store(true, .release);
    }
    fn deinit(self: *Spawner) void {
        self.arena.deinit();
    }
};

fn waitForFile(dir: std.Io.Dir, name: []const u8) !void {
    const deadline = supervisor.monotonicMs() + 20 * std.time.ms_per_s;
    while (true) {
        if (dir.access(testing.io, name, .{})) |_| return else |_| {}
        if (supervisor.monotonicMs() > deadline) return error.Timeout;
        var ts: c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
}

test "agent spawn holds its call off the reactor, refuses a signed-out harness with its sign-in command, and starts a signed-in one" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();

    var bin = testing.tmpDir(.{});
    defer bin.cleanup();
    const dir = try bin.dir.realPathFileAlloc(testing.io, ".", a);
    const exe = try std.fmt.allocPrint(a, "{s}/codex", .{dir});
    try bin.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = held_codex });
    if (c.chmod(try a.dupeSentinel(u8, exe, 0), 0o755) != 0) return error.ChmodFailed;
    try bin.dir.writeFile(testing.io, .{ .sub_path = "signed-out", .data = "" });

    // The adapter behind the name: what starts once the check lets it.
    var real: [std.fs.max_path_bytes:0]u8 = undefined;
    if (c.realpath(try a.dupeSentinel(u8, build_options.fake_harness, 0), &real) == null) return error.FakeHarnessMissing;
    var fake: harness.Fake = .{ .exe = std.mem.sliceTo(&real, 0), .script = "{\"turns\":[{\"match\":\"\",\"steps\":[{\"text\":\"Done.\"}]}]}", .state_dir = dir };

    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = "codex", .adapter = fake.adapter() }}, .sign_in_exe = exe });
    defer d.deinit();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});
    const spawn_args: []const []const u8 = &.{ "agent", "spawn", cwd, "--task=hello", "--harness=codex" };

    // Signed out, with the status command still running.
    var refused: Spawner = undefined;
    try refused.start(&d, spawn_args);
    defer refused.deinit();
    waitForFile(bin.dir, "asked") catch |err| {
        bin.dir.writeFile(testing.io, .{ .sub_path = "answer", .data = "" }) catch {};
        refused.thread.join();
        return err;
    };
    // The reactor answers other clients meanwhile, and the spawn is still held.
    const during = d.run(a, &.{ "agent", "list" });
    const held = !refused.finished.load(.acquire);
    // Answer before any check can fail, so the thread can be joined.
    try bin.dir.writeFile(testing.io, .{ .sub_path = "answer", .data = "" });
    refused.thread.join();
    const listed = try during;
    try testing.expectEqual(@as(u8, 0), listed.status);
    try testing.expectEqual(@as(usize, 0), listed.json.object.get("agents").?.array.items.len);
    try testing.expect(held);

    const out = refused.out.?;
    try testing.expectEqual(@as(u8, 6), out.status);
    const failure = out.json.object.get("error").?.object;
    try testing.expectEqualStrings("unavailable.harness_not_signed_in", failure.get("code").?.string);
    const data = failure.get("data").?.object;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} login", .{exe}), data.get("fix").?.string);
    try testing.expectEqualStrings("codex", data.get("harness").?.string);

    // Not started: no agent, and the next id is still the first.
    const after = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(usize, 0), after.json.object.get("agents").?.array.items.len);

    // A dry run says the same, so its preview does not promise a spawn.
    const dry = try d.run(a, &.{ "agent", "spawn", cwd, "--task=hello", "--harness=codex", "--dry-run=true" });
    try testing.expectEqual(@as(u8, 6), dry.status);
    try testing.expectEqualStrings("unavailable.harness_not_signed_in", dry.json.object.get("error").?.object.get("code").?.string);

    // Other checks come first: a bad call never runs the status command.
    try bin.dir.deleteFile(testing.io, "asked");
    const bad = try d.run(a, &.{ "agent", "spawn", "--cwd=/nonexistent/venom-68", "--task=hello", "--harness=codex" });
    try testing.expectEqual(@as(u8, 3), bad.status);
    try testing.expectError(error.FileNotFound, bin.dir.access(testing.io, "asked", .{}));

    // A harness venom has no sign-in check for is not held.
    const other = try d.run(a, &.{ "agent", "spawn", cwd, "--task=hello", "--harness=fake", "--dry-run=true" });
    try testing.expectEqual(@as(u8, 0), other.status);
    try testing.expectError(error.FileNotFound, bin.dir.access(testing.io, "asked", .{}));

    // Signed in: the same spawn starts, from a held call too. Never cached:
    // the refusal above does not outlive the sign-in.
    try bin.dir.deleteFile(testing.io, "signed-out");
    const started = try d.run(a, spawn_args);
    try testing.expectEqual(@as(u8, 0), started.status);
    try testing.expectEqualStrings("a1", started.json.object.get("agent").?.string);
    _ = try d.waitState(a, "a1", "settled");
}

test "a status command that cannot tell does not refuse the spawn" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var bin = testing.tmpDir(.{});
    defer bin.cleanup();
    const dir = try bin.dir.realPathFileAlloc(testing.io, ".", a);
    const exe = try std.fmt.allocPrint(a, "{s}/codex", .{dir});
    try bin.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = "#!/bin/sh\nexec sleep 60\n" });
    if (c.chmod(try a.dupeSentinel(u8, exe, 0), 0o755) != 0) return error.ChmodFailed;

    var real: [std.fs.max_path_bytes:0]u8 = undefined;
    if (c.realpath(try a.dupeSentinel(u8, build_options.fake_harness, 0), &real) == null) return error.FakeHarnessMissing;
    var fake: harness.Fake = .{ .exe = std.mem.sliceTo(&real, 0), .script = "{\"turns\":[]}", .state_dir = dir };

    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = "codex", .adapter = fake.adapter() }}, .sign_in_exe = exe, .sign_in_timeout_ms = 100 });
    defer d.deinit();
    const r = try d.run(a, &.{ "agent", "spawn", try std.fmt.allocPrint(a, "--cwd={s}", .{d.work}), "--task=hello", "--harness=codex", "--dry-run=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
}

/// A fake `codex` for the starts that come after the spawn. `signed-out`
/// makes `login status` say so; while `hold` exists it waits for `answer`.
const switch_codex =
    \\#!/bin/sh
    \\here="$(dirname "$0")"
    \\[ "$*" = "login status" ] || exit 2
    \\: > "$here/asked"
    \\while [ -e "$here/hold" ] && [ ! -e "$here/answer" ]; do sleep 0.01; done
    \\if [ -e "$here/signed-out" ]; then echo 'Not logged in' >&2; exit 1; fi
    \\echo 'Logged in using ChatGPT'
    \\
;

fn touch(dir: std.Io.Dir, name: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
}

fn remove(dir: std.Io.Dir, name: []const u8) void {
    dir.deleteFile(testing.io, name) catch {};
}

fn errorOf(out: Daemon.Out) std.json.ObjectMap {
    return out.json.object.get("error").?.object;
}

test "a queued agent whose harness signed out meanwhile fails unstarted with the fix, and the queue asks off the reactor" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var bin = testing.tmpDir(.{});
    defer bin.cleanup();
    const dir = try bin.dir.realPathFileAlloc(testing.io, ".", a);
    const exe = try std.fmt.allocPrint(a, "{s}/codex", .{dir});
    try bin.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = switch_codex });
    if (c.chmod(try a.dupeSentinel(u8, exe, 0), 0o755) != 0) return error.ChmodFailed;

    var real: [std.fs.max_path_bytes:0]u8 = undefined;
    if (c.realpath(try a.dupeSentinel(u8, build_options.fake_harness, 0), &real) == null) return error.FakeHarnessMissing;
    var fake: harness.Fake = .{ .exe = std.mem.sliceTo(&real, 0), .script = "{\"turns\":[{\"match\":\"\",\"steps\":[{\"text\":\"Done.\"}]}]}", .state_dir = dir };

    var d: Daemon = undefined;
    try d.initWith(.{
        .script = "{\"turns\":[{\"match\":\"\",\"steps\":[{\"text\":\"working\"},{\"sleep_ms\":20000}]}]}",
        .config = @import("harnesses.zig").testConfig(".agents = .{ .max_concurrent = 1 }"),
        .extra = &.{.{ .harness = "codex", .adapter = fake.adapter() }},
        .sign_in_exe = exe,
    });
    defer d.deinit();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});

    // The only slot is taken; the codex agent is signed in when it is spawned.
    const first = try d.run(a, &.{ "agent", "spawn", cwd, "--task=slow", "--harness=fake" });
    try testing.expectEqual(@as(u8, 0), first.status);
    _ = try d.waitState(a, "a1", "running");
    const queued = try d.run(a, &.{ "agent", "spawn", cwd, "--task=hello", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), queued.status);
    try testing.expectEqualStrings("queued", queued.json.object.get("state").?.string);

    // It signs out while it waits, and the slot frees with the check slow.
    try touch(bin.dir, "signed-out");
    try touch(bin.dir, "hold");
    remove(bin.dir, "asked");
    _ = try d.run(a, &.{ "agent", "stop", "--agent=a1" });
    waitForFile(bin.dir, "asked") catch |err| {
        touch(bin.dir, "answer") catch {};
        return err;
    };
    // The reactor answers meanwhile, and the agent still waits.
    const mid = d.run(a, &.{ "agent", "show", "--agent=a2" }) catch |err| {
        touch(bin.dir, "answer") catch {};
        return err;
    };
    errdefer touch(bin.dir, "answer") catch {};
    try testing.expectEqual(@as(u8, 0), mid.status);
    // Held: still queued, and no turn has started.
    try testing.expectEqualStrings("queued", mid.json.object.get("state").?.string);
    try testing.expectEqual(@as(i64, 0), mid.json.object.get("turns").?.integer);
    for (mid.json.object.get("transcript").?.array.items) |r| try testing.expect(!std.mem.eql(u8, r.object.get("type").?.string, "turn.started"));
    try touch(bin.dir, "answer");

    const shown = try d.waitState(a, "a2", "failed");
    const transcript = shown.object.get("transcript").?.array.items;
    var ended: ?std.json.ObjectMap = null;
    for (transcript) |r| if (std.mem.eql(u8, r.object.get("type").?.string, "turn.ended")) {
        ended = r.object;
    };
    try testing.expectEqualStrings("unavailable.harness_not_signed_in", ended.?.get("error_code").?.string);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} login", .{exe}), ended.?.get("fix").?.string);
}

test "a send that reattaches a crashed harness checks sign-in, off the reactor" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var bin = testing.tmpDir(.{});
    defer bin.cleanup();
    const dir = try bin.dir.realPathFileAlloc(testing.io, ".", a);
    const exe = try std.fmt.allocPrint(a, "{s}/codex", .{dir});
    try bin.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = switch_codex });
    if (c.chmod(try a.dupeSentinel(u8, exe, 0), 0o755) != 0) return error.ChmodFailed;

    var real: [std.fs.max_path_bytes:0]u8 = undefined;
    if (c.realpath(try a.dupeSentinel(u8, build_options.fake_harness, 0), &real) == null) return error.FakeHarnessMissing;
    var fake: harness.Fake = .{ .exe = std.mem.sliceTo(&real, 0), .script = "{\"turns\":[{\"match\":\"crash\",\"steps\":[{\"text\":\"hm\"},{\"crash\":3}]},{\"match\":\"\",\"steps\":[{\"text\":\"Done.\"}]}]}", .state_dir = dir };

    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = "codex", .adapter = fake.adapter() }}, .sign_in_exe = exe });
    defer d.deinit();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});

    // Its process dies; the agent fails, and only a send starts it again.
    const spawned = try d.run(a, &.{ "agent", "spawn", cwd, "--task=crash", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), spawned.status);
    _ = try d.waitState(a, "a1", "failed");

    try touch(bin.dir, "signed-out");
    try touch(bin.dir, "hold");
    remove(bin.dir, "asked");
    var send: Spawner = undefined;
    try send.start(&d, &.{ "agent", "send", "--agent=a1", "--text=again" });
    defer send.deinit();
    waitForFile(bin.dir, "asked") catch |err| {
        touch(bin.dir, "answer") catch {};
        send.thread.join();
        return err;
    };
    const during = d.run(a, &.{ "agent", "list" });
    const held = !send.finished.load(.acquire);
    try touch(bin.dir, "answer");
    send.thread.join();
    try testing.expectEqual(@as(u8, 0), (try during).status);
    try testing.expect(held);

    const out = send.out.?;
    try testing.expectEqual(@as(u8, 6), out.status);
    const failure = errorOf(out);
    try testing.expectEqualStrings("unavailable.harness_not_signed_in", failure.get("code").?.string);
    const data = failure.get("data").?.object;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} login", .{exe}), data.get("fix").?.string);
    // Not restarted: still failed, with one turn.
    const after = try d.run(a, &.{ "agent", "show", "--agent=a1" });
    try testing.expectEqualStrings("failed", after.json.object.get("state").?.string);
    try testing.expectEqual(@as(i64, 1), after.json.object.get("turns").?.integer);

    // Signed in again: the same send reattaches.
    remove(bin.dir, "signed-out");
    remove(bin.dir, "hold");
    remove(bin.dir, "answer");
    const ok = try d.run(a, &.{ "agent", "send", "--agent=a1", "--text=again" });
    try testing.expectEqual(@as(u8, 0), ok.status);
    _ = try d.waitState(a, "a1", "settled");
}

fn killHarness(_: *Daemon.Job, d: *Daemon) anyerror!void {
    const b = d.runner.host.bindings.get("a1") orelse return error.NoBinding;
    const p = b.process orelse return error.NoProcess;
    if (c.kill(p.pid(), @fromBackingInt(9)) != 0) return error.KillFailed;
}

test "a stale request answered after a crash reattaches only if the harness is signed in; signed out, the resume fails with the fix" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var bin = testing.tmpDir(.{});
    defer bin.cleanup();
    const dir = try bin.dir.realPathFileAlloc(testing.io, ".", a);
    const exe = try std.fmt.allocPrint(a, "{s}/codex", .{dir});
    try bin.dir.writeFile(testing.io, .{ .sub_path = "codex", .data = switch_codex });
    if (c.chmod(try a.dupeSentinel(u8, exe, 0), 0o755) != 0) return error.ChmodFailed;

    var real: [std.fs.max_path_bytes:0]u8 = undefined;
    if (c.realpath(try a.dupeSentinel(u8, build_options.fake_harness, 0), &real) == null) return error.FakeHarnessMissing;
    var fake: harness.Fake = .{ .exe = std.mem.sliceTo(&real, 0), .script = "{\"turns\":[{\"match\":\"ask\",\"steps\":[{\"ask\":{\"id\":\"p1\",\"kind\":\"approval\",\"call\":\"tu1\",\"reason\":\"Run?\"}}]},{\"match\":\"\",\"steps\":[{\"text\":\"Done.\"}]}]}", .state_dir = dir };

    var d: Daemon = undefined;
    try d.initWith(.{ .extra = &.{.{ .harness = "codex", .adapter = fake.adapter() }}, .sign_in_exe = exe });
    defer d.deinit();
    const cwd = try std.fmt.allocPrint(a, "--cwd={s}", .{d.work});
    const spawned = try d.run(a, &.{ "agent", "spawn", cwd, "--task=ask", "--harness=codex" });
    try testing.expectEqual(@as(u8, 0), spawned.status);
    _ = try d.waitState(a, "a1", "needs_you");
    // The harness process dies with the request open: the request is stale.
    var kill: Daemon.Job = .{ .run = killHarness };
    try d.onReactor(&kill);
    _ = try d.waitState(a, "a1", "failed");

    // It signs out before the answer; the check is slow.
    try touch(bin.dir, "signed-out");
    try touch(bin.dir, "hold");
    remove(bin.dir, "asked");
    const answered = try d.run(a, &.{ "inbox", "answer", "--agent=a1", "--answer=allow_once" });
    try testing.expectEqual(@as(u8, 0), answered.status);
    waitForFile(bin.dir, "asked") catch |err| {
        touch(bin.dir, "answer") catch {};
        return err;
    };
    // The reactor answers meanwhile, and nothing was resumed yet.
    const mid = d.run(a, &.{ "agent", "show", "--agent=a1" }) catch |err| {
        touch(bin.dir, "answer") catch {};
        return err;
    };
    try touch(bin.dir, "answer");
    try testing.expectEqual(@as(u8, 0), mid.status);
    try testing.expectEqual(@as(i64, 1), mid.json.object.get("turns").?.integer);

    const deadline = supervisor.monotonicMs() + 10 * std.time.ms_per_s;
    var ended: ?std.json.ObjectMap = null;
    while (ended == null) {
        const shown = try d.run(a, &.{ "agent", "show", "--agent=a1" });
        if (shown.json.object.get("turns").?.integer == 2) for (shown.json.object.get("transcript").?.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("type").?.string, "turn.ended") and std.mem.eql(u8, r.object.get("turn").?.string, "t2")) ended = r.object;
        };
        if (ended == null and supervisor.monotonicMs() > deadline) return error.Timeout;
        var ts: c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    try testing.expectEqualStrings("unavailable.harness_not_signed_in", ended.?.get("error_code").?.string);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} login", .{exe}), ended.?.get("fix").?.string);
}
