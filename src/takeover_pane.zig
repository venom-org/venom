//! Is a host-mode take-over's harness still running? Its venomx
//! pane outlives the TUI that opened it and the venom
//! daemon, so nobody may settle the agent on a guess: that would put venom and
//! the harness on one conversation. venom's daemon has no standing link to
//! venomx. It connects as itself just to read, and acts for nobody there.
//!
//! `prove` is the other question, whether a pid is a take-over pane's process.
//!
//! `unknown` is an answer: the caller keeps the agent handed over and says why.
//! venomx not answering counts as `unknown` too. It may be on a socket this
//! daemon does not know, with the harness still running.
const std = @import("std");
const proto = @import("proto");
const agent_model = @import("eventlog/agent.zig");
const Value = std.json.Value;

pub const State = union(enum) {
    running,
    gone,
    unknown: []const u8,
};

const no_environ = "this daemon has no environment to find venomx with";
const hello: proto.HelloOptions = .{ .identity = .{ .name = "venom", .version = "0.0.0" }, .caps = &.{} };
const wait_ms = 1000;
/// No pane has it, and only a caller with `read` on every pane gets
/// `not_found.pane` for it rather than `denied.read`.
const absent_pane = "p4294967295";

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn tagOf(pane: Value, key: []const u8) ?[]const u8 {
    const tags = pane.object.get("tags") orelse return null;
    if (tags != .array) return null;
    for (tags.array.items) |t| {
        if (t != .object) continue;
        const k = t.object.get("key") orelse continue;
        const v = t.object.get("value") orelse continue;
        if (k == .string and v == .string and std.mem.eql(u8, k.string, key)) return v.string;
    }
    return null;
}

/// One entry of `pane.list`: is it this take-over, still running?
pub fn isRunning(entry: Value, agent: []const u8, pane: []const u8) bool {
    if (entry != .object) return false;
    const id = entry.object.get("pane") orelse return false;
    if (id != .string) return false;
    if (entry.object.get("exited")) |x| if (x == .bool and x.bool) return false;
    const group = tagOf(entry, "group");
    if (std.mem.eql(u8, pane, agent_model.pending_venomx_pane)) {
        // The TUI went before it could say which: venom's tags tell.
        const kind = tagOf(entry, "venom.split") orelse return false;
        return std.mem.eql(u8, kind, "take_over") and group != null and std.mem.eql(u8, group.?, agent);
    }
    if (!std.mem.eql(u8, id.string, pane)) return false;
    // A restarted venomx hands out the same IDs: another agent's is not ours.
    // No tag at all fails safe: `agent.takeover --pane` may name any pane.
    return group == null or std.mem.eql(u8, group.?, agent);
}

fn connect(gpa: std.mem.Allocator, env: std.process.Environ) ?proto.Client {
    var client = proto.Client.init(gpa, .{ .tool = "venomx", .path = .{ .environ = env }, .hello = hello }) catch return null;
    const until = nowMs() + wait_ms;
    while (!(client.pollHello(100) catch {
        client.deinit();
        return null;
    })) {
        if (nowMs() > until) {
            client.deinit();
            return null;
        }
    }
    return client;
}

pub fn check(gpa: std.mem.Allocator, environ: ?std.process.Environ, agent: []const u8, pane: []const u8) State {
    const env = environ orelse return .{ .unknown = no_environ };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var client = connect(gpa, env) orelse return .{ .unknown = "venomx does not answer" };
    defer client.deinit();
    const listed = call(a, &client, 1, "pane.list", struct {}{}) orelse return .{ .unknown = "venomx does not answer" };
    if (listed == .@"error") return .{ .unknown = "venomx does not let this daemon read its panes" };
    const panes = if (listed.ok == .object) listed.ok.object.get("panes") else null;
    if (panes == null or panes.? != .array) return .{ .unknown = "venomx gave an unexpected answer" };
    for (panes.?.array.items) |entry| if (isRunning(entry, agent, pane)) return .running;
    // Not listed: it is gone only if the list could have shown it.
    const probe = call(a, &client, 2, "pane.capture", .{ .pane = absent_pane }) orelse return .{ .unknown = "venomx does not answer" };
    if (probe == .@"error" and std.mem.eql(u8, probe.@"error".code, "not_found.pane")) return .gone;
    return .{ .unknown = "venomx shows this daemon only some of its panes" };
}

/// What `pane.list` says of a take-over's process.
pub const Listed = union(enum) {
    /// Its pane, with the process venomx runs in it.
    root: proto.process.Ref,
    /// Its pane has exited: the harness ended before it could be reported.
    gone,
    /// Its pane, but not running this take-over. No pid can pass.
    refused: []const u8,
    /// venomx does not say: too old to report a process, for one.
    unknown: []const u8,
};

/// One `pane.list`, looked at for `pane`. The tags are required here, unlike in
/// `isRunning`: nothing is proved by a pane not labelled as this agent's
/// take-over. They keep out read-only splits, which can't write tags. They don't
/// say who opened the pane: `pane.tag` needs only `write` on it, and `spawn` can
/// set any tags at creation.
pub fn listedRoot(panes: []const Value, agent: []const u8, pane: []const u8) Listed {
    for (panes) |entry| {
        if (entry != .object) continue;
        const id = entry.object.get("pane") orelse continue;
        if (id != .string or !std.mem.eql(u8, id.string, pane)) continue;
        if (entry.object.get("exited")) |x| if (x == .bool and x.bool) return .gone;
        const group = tagOf(entry, "group") orelse return .{ .refused = "that pane is not this agent's" };
        if (!std.mem.eql(u8, group, agent)) return .{ .refused = "that pane is not this agent's" };
        const kind = tagOf(entry, "venom.split") orelse return .{ .refused = "that pane is not a take-over's" };
        if (!std.mem.eql(u8, kind, "take_over")) return .{ .refused = "that pane is not a take-over's" };
        const pid = entry.object.get("pid") orelse return .{ .unknown = "venomx does not report its panes' processes" };
        const start = entry.object.get("start") orelse return .{ .unknown = "venomx does not report its panes' processes" };
        if (pid != .integer or start != .integer) return .{ .unknown = "venomx gave an unexpected answer" };
        return .{ .root = .{
            .pid = std.math.cast(std.c.pid_t, pid.integer) orelse return .{ .unknown = "venomx gave an unexpected answer" },
            .start = std.math.cast(u64, start.integer) orelse return .{ .unknown = "venomx gave an unexpected answer" },
        } };
    }
    return .{ .unknown = "venomx does not show this daemon that pane" };
}

fn paneListed(panes: []const Value, pane: []const u8) bool {
    for (panes) |entry| {
        if (entry != .object) continue;
        const id = entry.object.get("pane") orelse continue;
        if (id == .string and std.mem.eql(u8, id.string, pane)) return true;
    }
    return false;
}

/// Is `pid` the process of `pane`, the agent's take-over pane? A pane's process
/// is venomx's child, so it can't be checked the way a TUI's own split is. Only
/// venomx knows, so this asks it, and takes its word: its socket is trusted at
/// same-UID level. This says what the pane runs, not who staged the pane.
/// `unknown` proves nothing and records nothing.
pub const Proof = union(enum) {
    root: proto.process.Ref,
    /// The pane has ended. Whoever opened it sees that and takes the agent back.
    gone,
    refused: []const u8,
    unknown: []const u8,
};

pub fn prove(gpa: std.mem.Allocator, environ: ?std.process.Environ, agent: []const u8, pane: []const u8, pid: std.c.pid_t) Proof {
    const env = environ orelse return .{ .unknown = no_environ };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var client = connect(gpa, env) orelse return .{ .unknown = "venomx does not answer" };
    defer client.deinit();
    const listed = call(a, &client, 1, "pane.list", struct {}{}) orelse return .{ .unknown = "venomx does not answer" };
    if (listed == .@"error") return .{ .unknown = "venomx does not let this daemon read its panes" };
    const panes = if (listed.ok == .object) listed.ok.object.get("panes") else null;
    if (panes == null or panes.? != .array) return .{ .unknown = "venomx gave an unexpected answer" };
    const root = switch (listedRoot(panes.?.array.items, agent, pane)) {
        .root => |r| r,
        .gone => return .gone,
        .refused => |why| return .{ .refused = why },
        .unknown => |why| {
            // Not listed: it is gone only if the list could have shown it.
            const listed_all = call(a, &client, 2, "pane.capture", .{ .pane = absent_pane });
            if (listed_all != null and listed_all.? == .@"error" and std.mem.eql(u8, listed_all.?.@"error".code, "not_found.pane") and !paneListed(panes.?.array.items, pane)) return .gone;
            return .{ .unknown = why };
        },
    };
    return judge(root, pid, proto.process.stat(pid) catch return .{ .refused = "no such process" }, proto.process.peerPid(client.connection.fd));
}

/// The process seen here must be the one venomx named, a child of the venomx
/// that answered (a PID 0 is one the kernel would not say).
pub fn judge(root: proto.process.Ref, pid: std.c.pid_t, st: proto.process.Stat, venomx: std.c.pid_t) Proof {
    if (pid <= 1 or pid != root.pid) return .{ .refused = "that is not this pane's process" };
    if (!st.ref.eql(root)) return .{ .refused = "that is not this pane's process" };
    if (venomx <= 0) return .{ .unknown = "cannot tell which process venomx is" };
    if (st.parent != venomx) return .{ .refused = "that process is not venomx's child" };
    return .{ .root = root };
}

fn call(a: std.mem.Allocator, client: *proto.Client, id: i64, verb: []const u8, params: anytype) ?proto.Response.Body {
    client.request(id, verb, params) catch return null;
    const until = nowMs() + wait_ms;
    while (nowMs() < until) {
        const msg = (client.receive(100) catch return null) orelse continue;
        if (msg != .ndjson) return null;
        const r = proto.Response.parse(a, msg.ndjson) catch return null;
        const rid = r.id orelse continue;
        if (rid != .integer or rid.integer != id or !r.final()) continue;
        return r.body;
    }
    return null;
}

test "isRunning: its ID and group; a recycled ID is not; pending goes by tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn of(x: std.mem.Allocator, json: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, x, json, .{});
        }
    }.of;
    const ours = try parse(a, "{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"take_over\"}]}");
    try std.testing.expect(isRunning(ours, "a1", "p4"));
    try std.testing.expect(isRunning(ours, "a1", agent_model.pending_venomx_pane));
    try std.testing.expect(!isRunning(ours, "a1", "p5"));
    try std.testing.expect(!isRunning(ours, "a2", "p4"));
    try std.testing.expect(!isRunning(ours, "a2", agent_model.pending_venomx_pane));
    try std.testing.expect(!isRunning(try parse(a, "{\"pane\":\"p4\",\"exited\":true,\"tags\":[]}"), "a1", "p4"));
    const untagged = try parse(a, "{\"pane\":\"p4\",\"exited\":false,\"tags\":[]}");
    try std.testing.expect(isRunning(untagged, "a1", "p4"));
    try std.testing.expect(!isRunning(untagged, "a1", agent_model.pending_venomx_pane));
    const view = try parse(a, "{\"pane\":\"p4\",\"tags\":[{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"shell\"}]}");
    try std.testing.expect(!isRunning(view, "a1", agent_model.pending_venomx_pane));
}

test "listedRoot: only this agent's live take-over pane, and only with a process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = struct {
        fn of(x: std.mem.Allocator, json: []const u8) ![]const Value {
            return (try std.json.parseFromSliceLeaky(Value, x, json, .{})).array.items;
        }
    }.of;
    const tags = "\"tags\":[{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"take_over\"}]";
    const ours = try list(a, "[{\"pane\":\"p4\",\"exited\":false,\"pid\":77,\"start\":9," ++ tags ++ "}]");
    const got = listedRoot(ours, "a1", "p4");
    try std.testing.expectEqual(@as(std.c.pid_t, 77), got.root.pid);
    try std.testing.expectEqual(@as(u64, 9), got.root.start);
    try std.testing.expect(listedRoot(ours, "a2", "p4") == .refused);
    // Not listed, or a venomx too old to say: nothing is proved either way.
    try std.testing.expect(listedRoot(ours, "a1", "p5") == .unknown);
    try std.testing.expect(listedRoot(try list(a, "[{\"pane\":\"p4\",\"exited\":false," ++ tags ++ "}]"), "a1", "p4") == .unknown);
    try std.testing.expect(listedRoot(try list(a, "[{\"pane\":\"p4\",\"exited\":true," ++ tags ++ "}]"), "a1", "p4") == .gone);
    // A shell beside it, untagged panes: the tags are not optional here.
    try std.testing.expect(listedRoot(try list(a, "[{\"pane\":\"p4\",\"pid\":77,\"start\":9,\"tags\":[{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"shell\"}]}]"), "a1", "p4") == .refused);
    try std.testing.expect(listedRoot(try list(a, "[{\"pane\":\"p4\",\"pid\":77,\"start\":9,\"tags\":[]}]"), "a1", "p4") == .refused);
}

test "judge: venomx's process, under venomx; not a reused pid, a stranger or init" {
    const root: proto.process.Ref = .{ .pid = 77, .start = 9 };
    const stat_of = struct {
        fn of(start: u64, parent: std.c.pid_t) proto.process.Stat {
            return .{ .ref = .{ .pid = 77, .start = start }, .parent = parent };
        }
    }.of;
    try std.testing.expect(judge(root, 77, stat_of(9, 5), 5) == .root);
    // The caller named another process than venomx's.
    try std.testing.expect(judge(root, 78, stat_of(9, 5), 5) == .refused);
    // The PID was reused since venomx said.
    try std.testing.expect(judge(root, 77, stat_of(10, 5), 5) == .refused);
    // Not this venomx's child: something else answers on that socket.
    try std.testing.expect(judge(root, 77, stat_of(9, 6), 5) == .refused);
    try std.testing.expect(judge(.{ .pid = 1, .start = 9 }, 1, .{ .ref = .{ .pid = 1, .start = 9 }, .parent = 0 }, 5) == .refused);
    try std.testing.expect(judge(root, 77, stat_of(9, 5), 0) == .unknown);
}
