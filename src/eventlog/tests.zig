//! Durability, crash and cursor tests for the event log.
const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const c = std.c;
const eventlog = @import("root.zig");
const Engine = eventlog.Engine;
const Executor = eventlog.Executor;
const testing = std.testing;

const Tmp = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    fn init() !Tmp {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator) };
    }
    fn deinit(self: *Tmp) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
    fn path(self: *const Tmp, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ self.dir, name }, 0);
    }
};

fn writeFile(path: [:0]const u8, bytes: []const u8, flags: c.O) !void {
    const fd = c.open(path, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
}
fn readFile(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(a, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(a);
}
fn exists(path: [:0]const u8) bool {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

fn render(engine: *const Engine) ![]u8 {
    return engine.state.render(testing.allocator);
}

/// A turn with a transcript, one answered request (its effect queued in the
/// outbox) and one pending request.
fn script(engine: *Engine) !void {
    _ = try engine.submit(.{ .create = .{ .agent = "a1", .title = "Add hello capability bits", .harness = "claude-code", .workspace = "/w" } });
    _ = try engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } });
    _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m1", .text = "Running the tests." } } });
    _ = try engine.submit(.{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "run zig build test?" } } });
    _ = try engine.submit(.{ .record = .{ .request = .{ .agent = "a1", .request = "r2", .kind = "question", .reason = "keep varint framing?" } } });
    _ = try engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow" } });
}

test "eventlog: the state rebuilt from the log equals the state that wrote it" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    var engine = try Engine.open(testing.allocator, path, .{});
    try engine.start();
    try script(&engine);
    try testing.expectError(error.Conflict, engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t2", .origin = "user" } } }));
    const before = try render(&engine);
    defer testing.allocator.free(before);
    const commits = engine.store.commits;
    engine.deinit();

    var again = try Engine.open(testing.allocator, path, .{});
    defer again.deinit();
    const after = try render(&again);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(commits, again.store.commits);
    // A second daemon on the same state directory is refused.
    try testing.expectError(error.LogLocked, Engine.open(testing.allocator, path, .{}));
}

test "eventlog: a torn last commit is cut off; a bad middle line is corruption" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    {
        var engine = try Engine.open(testing.allocator, path, .{});
        defer engine.deinit();
        try engine.start();
    }
    const good = try readFile(testing.allocator, path);
    defer testing.allocator.free(good);
    // A crash in the middle of a write leaves a partial line.
    try writeFile(path, "{\"commit\":2,\"ts\":\"2026-11-07T12:00:00.000Z\",\"events\":[{\"type\":\"te", .{ .ACCMODE = .WRONLY, .APPEND = true });
    {
        var engine = try Engine.open(testing.allocator, path, .{});
        defer engine.deinit();
        try testing.expect(engine.store.truncated > 0);
        try testing.expectEqual(@as(u64, 1), engine.store.commits);
        try testing.expectEqual(@as(u64, 1), engine.state.starts);
        try engine.start();
        try testing.expectEqual(@as(u64, 2), engine.store.commits);
    }
    // Complete JSON without its newline was never acknowledged either.
    try writeFile(path, good, .{ .ACCMODE = .WRONLY, .TRUNC = true });
    try writeFile(path, "{\"commit\":2,\"ts\":\"x\",\"events\":[{\"type\":\"daemon.started\",\"data\":{}}]}", .{ .ACCMODE = .WRONLY, .APPEND = true });
    {
        var engine = try Engine.open(testing.allocator, path, .{});
        defer engine.deinit();
        try testing.expectEqual(@as(u64, 1), engine.store.commits);
    }
    try writeFile(path, "garbage\n", .{ .ACCMODE = .WRONLY, .TRUNC = true });
    try writeFile(path, good, .{ .ACCMODE = .WRONLY, .APPEND = true });
    try testing.expectError(error.CorruptLog, Engine.open(testing.allocator, path, .{}));
    // A gap in commit numbers is corruption too, even on the last line.
    try writeFile(path, good, .{ .ACCMODE = .WRONLY, .TRUNC = true });
    try writeFile(path, "{\"commit\":5,\"ts\":\"x\",\"events\":[{\"type\":\"daemon.started\",\"data\":{}}]}\n", .{ .ACCMODE = .WRONLY, .APPEND = true });
    try testing.expectError(error.CorruptLog, Engine.open(testing.allocator, path, .{}));
}

/// The first daemon's executor: marks the effect as done in the world
/// (a file named after the idempotency key), tells the test, then hangs
/// until it is killed, before the completion is committed.
const Hang = struct {
    dir: []const u8,
    notify: c.fd_t,
    pub fn run(self: *Hang, key: []const u8, _: []const u8) anyerror!Executor.Outcome {
        var buf: [512]u8 = undefined;
        const marker = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ self.dir, key }, 0);
        try writeFile(marker, "done", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true });
        _ = c.write(self.notify, "E", 1);
        var none: [0]c.pollfd = .{};
        while (true) _ = c.poll(&none, 0, 1000);
    }
};

/// The restarted daemon's executor: idempotent per key.
const Idempotent = struct {
    dir: []const u8,
    runs: usize = 0,
    repeats: usize = 0,
    pub fn run(self: *Idempotent, key: []const u8, _: []const u8) anyerror!Executor.Outcome {
        self.runs += 1;
        var buf: [512]u8 = undefined;
        const marker = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ self.dir, key }, 0);
        if (exists(marker)) {
            self.repeats += 1;
            return .{ .detail = "already applied" };
        }
        try writeFile(marker, "done", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true });
        return .{};
    }
};

fn child(path: [:0]const u8, dir: []const u8, before: [:0]const u8, notify: c.fd_t) !void {
    const gpa = std.heap.page_allocator;
    var hang: Hang = .{ .dir = dir, .notify = notify };
    const executors = [_]Executor{.init("harness.respond", &hang)};
    var engine = try Engine.open(gpa, path, .{ .executors = &executors });
    try engine.start();
    try script(&engine);
    try writeFile(before, try engine.state.render(gpa), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    try engine.compact();
    _ = try engine.runEffects();
}

test "eventlog: SIGKILL mid-effect, then the restart rebuilds the same state and reruns the effect once" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    const before_path = try tmp.path("before.json");
    defer testing.allocator.free(before_path);
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = c.close(fds[0]);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.close(fds[0]);
        child(path, tmp.dir, before_path, fds[1]) catch {
            _ = c.write(fds[1], "F", 1);
        };
        c._exit(1);
    }
    _ = c.close(fds[1]);
    var byte: [1]u8 = undefined;
    const n = c.read(fds[0], &byte, 1);
    try testing.expectEqual(@as(isize, 1), n);
    try testing.expectEqual(@as(u8, 'E'), byte[0]); // the daemon is inside the effect
    try testing.expectEqual(@as(c_int, 0), c.kill(pid, .KILL));
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try testing.expect(std.posix.W.IFSIGNALED(@bitCast(status)));
    try testing.expectEqual(std.posix.SIG.KILL, std.posix.W.TERMSIG(@bitCast(status)));

    const before = try readFile(testing.allocator, before_path);
    defer testing.allocator.free(before);
    var idem: Idempotent = .{ .dir = tmp.dir };
    const executors = [_]Executor{.init("harness.respond", &idem)};
    var engine = try Engine.open(testing.allocator, path, .{ .executors = &executors });
    defer engine.deinit();
    const rebuilt = try render(&engine);
    defer testing.allocator.free(rebuilt);
    try testing.expectEqualStrings(before, rebuilt);
    try testing.expectEqual(@as(usize, 1), engine.state.pendingEffects());

    // Start: the open turn fails, the pending request survives as stale,
    // and the outbox effect runs again with the same key.
    try engine.start();
    const agent = engine.state.agents.get("a1").?;
    try testing.expect(agent.open_turn == null);
    const last = agent.transcript.items[agent.transcript.items.len - 1].turn_ended;
    try testing.expectEqualStrings("failed.daemon_restart", last.error_code.?);
    try testing.expectEqual(@as(usize, 1), agent.requests.items.len);
    try testing.expectEqualStrings("r2", agent.requests.items[0].request);
    try testing.expect(agent.requests.items[0].stale);
    try testing.expectEqual(@as(usize, 1), try engine.runEffects());
    try testing.expectEqual(@as(usize, 1), idem.runs);
    try testing.expectEqual(@as(usize, 1), idem.repeats);
    try testing.expectEqual(@as(usize, 0), engine.state.pendingEffects());
    try testing.expectEqual(@as(usize, 0), try engine.runEffects());
}

// --- `events` verb: cursor replay over the published log ---

const model = cli.manifest.normalize(.{ .format = 1, .tool = "venom", .summary = "events only", .verbs = .{eventlog.catalog.events_manifest} });

const Peer = struct {
    conn: proto.Connection,
    other: c.fd_t,
    fn init() !Peer {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        var conn = proto.Connection.init(testing.allocator, fds[0]);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        return .{ .conn = conn, .other = fds[1] };
    }
    fn deinit(self: *Peer) void {
        self.conn.deinit();
        proto.os.close(self.other);
    }
    /// Sends one request; returns the parsed output lines (in `a`).
    fn send(self: *Peer, d: *proto.Dispatcher, a: std.mem.Allocator, line: []const u8) ![]std.json.Value {
        try d.message(&self.conn, .{ .ndjson = line });
        var out: std.ArrayList(std.json.Value) = .empty;
        var it = std.mem.splitScalar(u8, self.conn.output.items, '\n');
        while (it.next()) |l| if (l.len > 0) try out.append(a, try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, l), .{}));
        self.conn.output.clearRetainingCapacity();
        return out.items;
    }
};

fn item(v: std.json.Value) std.json.ObjectMap {
    return v.object.get("item").?.object;
}

test "eventlog: events --after <cursor> resumes exactly after it; a restart falls back to a snapshot" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var old_cursor: []const u8 = undefined;
    {
        var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
        defer log.deinit();
        log.catalog = &eventlog.catalog.entries;
        var engine = try Engine.open(testing.allocator, path, .{ .events = &log });
        defer engine.deinit();
        var snaps: eventlog.catalog.Snapshots = .{ .engine = &engine };
        log.snapshot = proto.events.Snapshot.init(&snaps);
        const bindings = [_]proto.Binding{.{ .verb = "events", .handler = proto.VerbHandler.init(&log) }};
        var dispatcher = try proto.Dispatcher.init(testing.allocator, &model, &bindings, .{}, null);
        defer dispatcher.deinit();
        var peer = try Peer.init();
        defer peer.deinit();

        try engine.start(); // internal record: publishes nothing
        try testing.expectEqual(@as(u64, 0), log.high);
        _ = try engine.submit(.{ .create = .{ .agent = "a1", .title = "task", .harness = "claude-code", .workspace = "/w" } });
        try testing.expectEqual(@as(u64, 1), log.high); // agent.created is public
        _ = try engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } });
        _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m1", .text = "hi" } } });
        _ = try engine.submit(.{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "question", .reason = "keep varint framing?" } } });
        // agent.created, turn_started, queued→running, text, attention, running→needs_you
        try testing.expectEqual(@as(u64, 6), log.high);

        // agent.created comes first, before any agent.state_changed, and
        // passes the `events` item schema.
        const created = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":9,\"verb\":\"events\",\"params\":{{\"after\":\"{s}:0\",\"follow\":false}}}}", .{log.source}));
        try testing.expectEqualStrings("agent.created", item(created[0]).get("type").?.string);
        const cd = item(created[0]).get("data").?.object;
        inline for (.{ .{ "agent", "a1" }, .{ "title", "task" }, .{ "harness", "claude-code" }, .{ "workspace", "/w" }, .{ "state", "queued" } }) |kv| try testing.expectEqualStrings(kv[1], cd.get(kv[0]).?.string);
        try testing.expectEqual(@as(usize, 0), cd.get("repos").?.array.items.len);
        try testing.expect(cd.get("parent").? == .null); // top-level agent: explicit null
        try testing.expectEqualStrings("agent.turn_started", item(created[1]).get("type").?.string);
        try testing.expectEqualStrings("agent.state_changed", item(created[2]).get("type").?.string);

        const cursor = try std.fmt.allocPrint(a, "{s}:4", .{log.source});
        const lines = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":1,\"verb\":\"events\",\"params\":{{\"after\":\"{s}\",\"follow\":false}}}}", .{cursor}));
        try testing.expectEqual(@as(usize, 4), lines.len);
        try testing.expectEqual(@as(i64, 5), item(lines[0]).get("seq").?.integer);
        try testing.expectEqualStrings("agent.attention", item(lines[0]).get("type").?.string);
        const data = item(lines[0]).get("data").?.object;
        try testing.expectEqualStrings("a1", data.get("agent").?.string);
        try testing.expectEqualStrings("question", data.get("kind").?.string);
        try testing.expectEqualStrings("agent.state_changed", item(lines[1]).get("type").?.string);
        const changed = item(lines[1]).get("data").?.object;
        try testing.expectEqualStrings("a1", changed.get("agent").?.string);
        try testing.expectEqualStrings("running", changed.get("from").?.string);
        try testing.expectEqualStrings("needs_you", changed.get("to").?.string);
        try testing.expectEqualStrings("stream.checkpoint", item(lines[2]).get("type").?.string);
        try testing.expectEqual(@as(i64, 6), item(lines[2]).get("seq").?.integer);
        try testing.expect(lines[3].object.get("ok") != null);

        // At the watermark: nothing to replay, just the checkpoint.
        const at_high = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":2,\"verb\":\"events\",\"params\":{{\"after\":\"{s}:6\",\"follow\":false}}}}", .{log.source}));
        try testing.expectEqual(@as(usize, 2), at_high.len);
        try testing.expectEqualStrings("stream.checkpoint", item(at_high[0]).get("type").?.string);
        // Type filters apply to replay without renumbering.
        const texts = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":3,\"verb\":\"events\",\"params\":{{\"after\":\"{s}:0\",\"types\":[\"agent.text\"],\"follow\":false}}}}", .{log.source}));
        try testing.expectEqual(@as(usize, 3), texts.len);
        try testing.expectEqual(@as(i64, 4), item(texts[0]).get("seq").?.integer);
        old_cursor = cursor;
    }

    // Restart: a new epoch. The old cursor gets a snapshot that still has
    // the pending request, now stale, and the synthetic turn end is live.
    var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
    defer log.deinit();
    log.catalog = &eventlog.catalog.entries;
    var engine = try Engine.open(testing.allocator, path, .{ .events = &log });
    defer engine.deinit();
    var snaps: eventlog.catalog.Snapshots = .{ .engine = &engine };
    log.snapshot = proto.events.Snapshot.init(&snaps);
    try engine.start();
    // agent.turn_ended (failed), needs_you→running, running→failed and
    // its `failed` attention
    try testing.expectEqual(@as(u64, 4), log.high);
    const bindings = [_]proto.Binding{.{ .verb = "events", .handler = proto.VerbHandler.init(&log) }};
    var dispatcher = try proto.Dispatcher.init(testing.allocator, &model, &bindings, .{}, null);
    defer dispatcher.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    const lines = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":4,\"verb\":\"events\",\"params\":{{\"after\":\"{s}\",\"follow\":false}}}}", .{old_cursor}));
    try testing.expectEqual(@as(usize, 3), lines.len);
    const snap = item(lines[0]);
    try testing.expectEqualStrings("state.snapshot", snap.get("type").?.string);
    try testing.expectEqualStrings("source_changed", snap.get("data").?.object.get("reason").?.string);
    const entities = snap.get("data").?.object.get("entities").?.array.items;
    try testing.expectEqual(@as(usize, 2), entities.len);
    try testing.expectEqualStrings("agent:a1", entities[0].object.get("resource").?.string);
    try testing.expectEqualStrings("agent", entities[0].object.get("entity_type").?.string);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"title\":\"task\",\"harness\":\"claude-code\",\"state\":\"failed\",\"unread\":false}", entities[0].object.get("content").?.string);
    try testing.expectEqualStrings("agent:a1", entities[1].object.get("resource").?.string);
    try testing.expectEqualStrings("attention", entities[1].object.get("entity_type").?.string);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"requests\":[{\"request\":\"r1\",\"kind\":\"question\",\"reason\":\"keep varint framing?\",\"stale\":true}]}", entities[1].object.get("content").?.string);
    try testing.expectEqualStrings("stream.checkpoint", item(lines[1]).get("type").?.string);
}

test "eventlog: workspace changes are published, and a source_changed snapshot carries every workspace" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var old_cursor: []const u8 = undefined;
    {
        var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
        defer log.deinit();
        log.catalog = &eventlog.catalog.entries;
        var engine = try Engine.open(testing.allocator, path, .{ .events = &log });
        defer engine.deinit();
        const bindings = [_]proto.Binding{.{ .verb = "events", .handler = proto.VerbHandler.init(&log) }};
        var dispatcher = try proto.Dispatcher.init(testing.allocator, &model, &bindings, .{}, null);
        defer dispatcher.deinit();
        var peer = try Peer.init();
        defer peer.deinit();

        _ = try engine.submit(.{ .workspace_add = .{ .path = "/w", .repos = &.{ ".", "a/b" } } });
        try testing.expectEqual(@as(u64, 1), log.high);
        // Adding it again and a scan that finds the same repos change nothing.
        try testing.expectEqual(@as(usize, 0), try engine.submit(.{ .workspace_add = .{ .path = "/w", .repos = &.{"other"} } }));
        try testing.expectEqual(@as(usize, 0), try engine.submit(.{ .workspace_scan = .{ .path = "/w", .repos = &.{ ".", "a/b" } } }));
        try testing.expectEqual(@as(u64, 1), log.high);
        _ = try engine.submit(.{ .workspace_scan = .{ .path = "/w", .repos = &.{"c"} } });
        try testing.expectEqual(@as(u64, 2), log.high);
        // Removing it publishes the repos it last had, whatever the command says.
        _ = try engine.submit(.{ .workspace_remove = .{ .path = "/w", .repos = &.{"ignored"} } });
        try testing.expectEqual(@as(u64, 3), log.high);
        try testing.expectError(error.NotFound, engine.submit(.{ .workspace_remove = .{ .path = "/w" } }));
        try testing.expectEqual(@as(u64, 3), log.high);

        const lines = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":1,\"verb\":\"events\",\"params\":{{\"after\":\"{s}:0\",\"resources\":[\"workspace:/w\"],\"follow\":false}}}}", .{log.source}));
        try testing.expectEqual(@as(usize, 5), lines.len); // three events, the checkpoint and the result
        const expected = [_]struct { []const u8, []const []const u8 }{
            .{ "workspace.added", &.{ ".", "a/b" } },
            .{ "workspace.scanned", &.{"c"} },
            .{ "workspace.removed", &.{"c"} },
        };
        for (expected, lines[0..3]) |want, line| {
            try testing.expectEqualStrings(want[0], item(line).get("type").?.string);
            const data = item(line).get("data").?.object;
            try testing.expectEqual(@as(usize, 2), data.count());
            try testing.expectEqualStrings("/w", data.get("path").?.string);
            const repos = data.get("repos").?.array.items;
            try testing.expectEqual(want[1].len, repos.len);
            for (want[1], repos) |r, got| try testing.expectEqualStrings(r, got.string);
        }

        _ = try engine.submit(.{ .workspace_add = .{ .path = "/org", .repos = &.{ "venom", "venom-std" } } });
        _ = try engine.submit(.{ .workspace_add = .{ .path = "/scratch" } });
        _ = try engine.submit(.{ .workspace_add = .{ .path = "/gone", .repos = &.{"x"} } });
        _ = try engine.submit(.{ .workspace_remove = .{ .path = "/gone" } });
        old_cursor = try std.fmt.allocPrint(a, "{s}:0", .{log.source});
    }

    // Restart: the old cursor falls back to a snapshot with every workspace
    // still there and its repos, and none that was removed.
    var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
    defer log.deinit();
    log.catalog = &eventlog.catalog.entries;
    var engine = try Engine.open(testing.allocator, path, .{ .events = &log });
    defer engine.deinit();
    var snaps: eventlog.catalog.Snapshots = .{ .engine = &engine };
    log.snapshot = proto.events.Snapshot.init(&snaps);
    const bindings = [_]proto.Binding{.{ .verb = "events", .handler = proto.VerbHandler.init(&log) }};
    var dispatcher = try proto.Dispatcher.init(testing.allocator, &model, &bindings, .{}, null);
    defer dispatcher.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    const lines = try peer.send(&dispatcher, a, try std.fmt.allocPrint(a, "{{\"id\":2,\"verb\":\"events\",\"params\":{{\"after\":\"{s}\",\"follow\":false}}}}", .{old_cursor}));
    const snap = item(lines[0]);
    try testing.expectEqualStrings("state.snapshot", snap.get("type").?.string);
    try testing.expectEqualStrings("source_changed", snap.get("data").?.object.get("reason").?.string);
    const entities = snap.get("data").?.object.get("entities").?.array.items;
    try testing.expectEqual(@as(usize, 2), entities.len);
    try testing.expectEqualStrings("workspace:/org", entities[0].object.get("resource").?.string);
    try testing.expectEqualStrings("workspace", entities[0].object.get("entity_type").?.string);
    try testing.expectEqualStrings("{\"path\":\"/org\",\"repos\":[\"venom\",\"venom-std\"]}", entities[0].object.get("content").?.string);
    try testing.expectEqualStrings("workspace:/scratch", entities[1].object.get("resource").?.string);
    try testing.expectEqualStrings("{\"path\":\"/scratch\",\"repos\":[]}", entities[1].object.get("content").?.string);

    // Selecting the workspace events selects the entity; other types do not.
    const only_text = try peer.send(&dispatcher, a, "{\"id\":3,\"verb\":\"events\",\"params\":{\"types\":[\"agent.text\"],\"follow\":false}}");
    try testing.expectEqual(@as(usize, 0), item(only_text[0]).get("data").?.object.get("entities").?.array.items.len);
    const only_removed = try peer.send(&dispatcher, a, "{\"id\":4,\"verb\":\"events\",\"params\":{\"types\":[\"workspace.removed\"],\"follow\":false}}");
    try testing.expectEqual(@as(usize, 2), item(only_removed[0]).get("data").?.object.get("entities").?.array.items.len);
}

test "eventlog: a workspace with no published form commits but publishes nothing" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
    defer log.deinit();
    log.catalog = &eventlog.catalog.entries;
    var engine = try Engine.open(testing.allocator, path, .{ .events = &log });
    defer engine.deinit();
    var snaps: eventlog.catalog.Snapshots = .{ .engine = &engine };
    for ([_][]const u8{ "/a:b", "/a\nb" }) |p| {
        try testing.expectEqual(@as(usize, 1), try engine.submit(.{ .workspace_add = .{ .path = p } }));
        try testing.expectEqual(@as(usize, 1), try engine.submit(.{ .workspace_scan = .{ .path = p, .repos = &.{"r"} } }));
    }
    try testing.expectEqual(@as(usize, 1), try engine.submit(.{ .workspace_remove = .{ .path = "/a\nb" } }));
    try testing.expectEqual(@as(u64, 0), log.high);
    try testing.expectEqual(@as(usize, 1), engine.state.workspaces.count());
    try testing.expectEqual(@as(usize, 0), (try snaps.capture(arena.allocator())).len);
}

test "eventlog: a repo name that is not UTF-8 is never committed, and is dropped from old logs and snapshots" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const repos = struct {
        fn expect(engine: *const Engine, workspace: []const u8, want: []const u8) !void {
            const got = engine.state.workspaces.get(workspace).?.repos;
            try testing.expectEqual(@as(usize, 1), got.len);
            try testing.expectEqualStrings(want, got[0]);
        }
    }.expect;
    // What a build without the check committed: std.json writes a string that
    // is not UTF-8 as an array of its bytes, and reads that back as a string.
    try writeFile(path,
        \\{"commit":1,"ts":"2026-11-08T00:00:00.000Z","events":[{"type":"workspace.added","data":{"path":"/added","repos":["fine",[254,98,97,100]]}}]}
        \\{"commit":2,"ts":"2026-11-08T00:00:00.000Z","events":[{"type":"workspace.added","data":{"path":"/scanned"}}]}
        \\{"commit":3,"ts":"2026-11-08T00:00:00.000Z","events":[{"type":"workspace.scanned","data":{"path":"/scanned","repos":[[254,98,97,100],"fine"]}}]}
        \\
    , .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    {
        var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
        defer log.deinit();
        log.catalog = &eventlog.catalog.entries;
        var engine = try Engine.open(testing.allocator, path, .{ .events = &log });
        defer engine.deinit();
        try repos(&engine, "/added", "fine");
        try repos(&engine, "/scanned", "fine");
        // Those workspaces now have a published form, and a scan that finds the
        // same repos changes nothing.
        var snaps: eventlog.catalog.Snapshots = .{ .engine = &engine };
        try testing.expectEqual(@as(usize, 2), (try snaps.capture(arena.allocator())).len);
        try testing.expectEqual(@as(usize, 0), try engine.submit(.{ .workspace_scan = .{ .path = "/added", .repos = &.{"fine"} } }));

        // A command holding such a name commits and publishes without it.
        try testing.expectEqual(@as(u64, 0), log.high);
        try testing.expectEqual(@as(usize, 1), try engine.submit(.{ .workspace_add = .{ .path = "/new", .repos = &.{ "\xfe", "fine" } } }));
        try testing.expectEqual(@as(usize, 0), try engine.submit(.{ .workspace_scan = .{ .path = "/new", .repos = &.{ "fine", "\xfe" } } }));
        try repos(&engine, "/new", "fine");
        try testing.expectEqual(@as(u64, 1), log.high);
        const logged = try readFile(arena.allocator(), path);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, logged, "[254,"));

        // The snapshot such a build wrote: back to the same bytes, then
        // restored like any other. A string elsewhere in the state keeps them.
        engine.state.workspaces.getPtr("/added").?.repos = &.{ "fine", "\xfebad" };
        engine.state.workspaces.getPtr("/new").?.path = "/\xfepath";
        try engine.compact();
        engine.state.workspaces.getPtr("/new").?.path = "/new";
    }
    var again = try Engine.open(testing.allocator, path, .{});
    defer again.deinit();
    try repos(&again, "/added", "fine");
    try testing.expectEqualStrings("/\xfepath", again.state.workspaces.get("/new").?.path);
    const clean = try @import("snapshot.zig").encode(&again.state, testing.allocator);
    defer testing.allocator.free(clean);
    try testing.expect(std.mem.indexOf(u8, clean, "\"repos\":[\"fine\"]") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "[254,98") == null);
}

test "eventlog: snapshot plus suffix equals full replay, including transcripts and pending effects" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    var engine = try Engine.open(testing.allocator, path, .{});
    for (0..300) |_| try engine.start();
    try script(&engine);
    const old_size = engine.store.size;
    try engine.compact();
    try testing.expectEqual(@as(u64, 0), engine.store.size);
    try testing.expect(old_size > 0);
    const watermark = engine.store.commits;
    _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m2", .text = "after snapshot" } } });
    const expected = try @import("snapshot.zig").encode(&engine.state, testing.allocator);
    defer testing.allocator.free(expected);
    engine.deinit();
    var again = try Engine.open(testing.allocator, path, .{});
    defer again.deinit();
    const actual = try @import("snapshot.zig").encode(&again.state, testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
    try testing.expectEqual(watermark, again.store.snapshot_commit);
    try testing.expectEqual(watermark + 1, again.store.commits);
    try testing.expectEqual(@as(usize, 1), again.state.pendingEffects());
    try testing.expectEqual(@as(usize, 3), again.state.agents.get("a1").?.transcript.items.len);
    try testing.expectError(error.LogLocked, Engine.open(testing.allocator, path, .{}));
    try again.compact();
}

var snapshot_notify: c.fd_t = -1;
var snapshot_stage: u8 = 0;
fn snapshotHang(stage: u8) void {
    if (stage != snapshot_stage) return;
    _ = c.write(snapshot_notify, "S", 1);
    var none: [0]c.pollfd = .{};
    while (true) _ = c.poll(&none, 0, 1000);
}

test "eventlog: SIGKILL during snapshot write, publication and truncation preserves acknowledged state" {
    for (0..3) |stage| {
        var tmp = try Tmp.init();
        defer tmp.deinit();
        const path = try tmp.path(eventlog.file_name);
        defer testing.allocator.free(path);
        var engine = try Engine.open(testing.allocator, path, .{});
        try script(&engine);
        // Make the write exceed one chunk: stage zero kills a partial file.
        const body = try testing.allocator.alloc(u8, 100_000);
        defer testing.allocator.free(body);
        @memset(body, 'x');
        _ = try engine.submit(.{ .record = .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m2", .text = body } } });
        const expected = try @import("snapshot.zig").encode(&engine.state, testing.allocator);
        defer testing.allocator.free(expected);
        engine.deinit();
        var fds: [2]c.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.PipeFailed;
        defer _ = c.close(fds[0]);
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = c.close(fds[0]);
            snapshot_notify = fds[1];
            snapshot_stage = @intCast(stage);
            var child_engine = Engine.open(std.heap.page_allocator, path, .{}) catch c._exit(2);
            child_engine.store.test_hook = snapshotHang;
            child_engine.compact() catch c._exit(3);
            c._exit(4);
        }
        _ = c.close(fds[1]);
        var byte: [1]u8 = undefined;
        const n = c.read(fds[0], &byte, 1);
        _ = c.kill(pid, .KILL);
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        try testing.expectEqual(@as(isize, 1), n);
        try testing.expectEqual(@as(u8, 'S'), byte[0]);
        var again = try Engine.open(testing.allocator, path, .{});
        defer again.deinit();
        const actual = try @import("snapshot.zig").encode(&again.state, testing.allocator);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
        try again.start();
        try again.compact();
    }
}

test "eventlog: snapshot rejects corruption and suffix still repairs torn tails" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    const snap = try tmp.path("events.log.snapshot");
    defer testing.allocator.free(snap);
    {
        var engine = try Engine.open(testing.allocator, path, .{});
        defer engine.deinit();
        try script(&engine);
        try engine.compact();
    }
    try writeFile(path, "{\"commit\":", .{ .ACCMODE = .WRONLY, .APPEND = true });
    {
        var engine = try Engine.open(testing.allocator, path, .{});
        defer engine.deinit();
        try testing.expect(engine.store.truncated > 0);
        try testing.expectEqual(engine.store.snapshot_commit, engine.store.commits);
        try engine.start();
    }
    try writeFile(snap, "{", .{ .ACCMODE = .WRONLY, .TRUNC = true });
    try testing.expectError(error.CorruptSnapshot, Engine.open(testing.allocator, path, .{}));
}

test "eventlog: automatic checkpoint bounds repeated daemon starts" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    const path = try tmp.path(eventlog.file_name);
    defer testing.allocator.free(path);
    {
        var engine = try Engine.open(testing.allocator, path, .{});
        defer engine.deinit();
        for (0..4100) |_| try engine.start();
        try testing.expectEqual(@as(u64, 4096), engine.store.snapshot_commit);
        try testing.expect(engine.store.size < 1024);
    }
    var again = try Engine.open(testing.allocator, path, .{});
    defer again.deinit();
    try testing.expectEqual(@as(u64, 4100), again.state.starts);
    try testing.expectEqual(@as(u64, 4100), again.store.commits);
}
