//! Settings scope: user → workspace → repo files through the real
//! dispatcher, in temp dirs only.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const main = @import("main.zig");
const scope = @import("scope.zig");
const config = @import("config.zig");
const eventlog = @import("eventlog/root.zig");
const testing = std.testing;
const ta = testing.allocator;

/// Only the config verbs, extended as the daemon's schema is.
const model = scope.extend(cfg.merge(.{ .tool = "venom", .summary = "config scope tests", .verbs = &.{} }));

const Peer = struct {
    conn: proto.Connection,
    other: std.c.fd_t,
    last: ?proto.Response = null,
    fn init() !Peer {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        var conn = proto.Connection.init(ta, fds[0]);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        return .{ .conn = conn, .other = fds[1] };
    }
    fn deinit(self: *Peer) void {
        if (self.last) |*r| r.deinit();
        self.conn.deinit();
        proto.os.close(self.other);
    }
    fn send(self: *Peer, d: *proto.Dispatcher, line: []const u8) !proto.Response {
        try d.message(&self.conn, .{ .ndjson = line });
        if (self.last) |*r| r.deinit();
        self.last = null;
        const out = std.mem.trimEnd(u8, self.conn.output.items, "\n");
        try testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
        self.last = try proto.Response.parse(ta, out);
        self.conn.output.clearRetainingCapacity();
        return self.last.?;
    }
};

const Fixture = struct {
    tmp: testing.TmpDir = undefined,
    dir: [:0]u8 = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    user: []const u8 = undefined,
    engine: eventlog.Engine = undefined,
    store: config.Store = undefined,
    scoped: scope.Config = undefined,
    dispatcher: proto.Dispatcher = undefined,
    peer: Peer = undefined,
    registry: proto.grants.Registry = undefined,
    next_id: usize = 1,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", ta);
        errdefer ta.free(self.dir);
        self.arena = .init(ta);
        errdefer self.arena.deinit();
        self.user = try self.path("home/config/venom/config.zon");
        self.engine = try eventlog.Engine.open(ta, try self.path(eventlog.file_name), .{});
        errdefer self.engine.deinit();
        self.store = try config.Store.init(ta, .{ .io = testing.io, .path = self.user, .validate = config.validate });
        errdefer self.store.deinit();
        self.scoped = .{ .store = &self.store, .engine = &self.engine, .layers = .{ .gpa = ta, .io = testing.io, .user = self.user } };
        const bindings = self.scoped.bindings();
        self.dispatcher = try proto.Dispatcher.init(ta, &model, &bindings, .{}, null);
        errdefer self.dispatcher.deinit();
        self.peer = try Peer.init();
        errdefer self.peer.deinit();
        self.registry = try proto.grants.Registry.init(ta, main.tool, .{});
    }
    fn deinit(self: *Fixture) void {
        self.registry.deinit();
        self.peer.deinit();
        self.dispatcher.deinit();
        self.store.deinit();
        self.engine.deinit();
        self.arena.deinit();
        ta.free(self.dir);
        self.tmp.cleanup();
    }
    /// Gives the peer the owner's rights (config set needs admin).
    fn owner(self: *Fixture) void {
        self.peer.conn.registry = &self.registry;
        self.peer.conn.identity = .{ .principal = proto.grants.owner };
    }
    fn path(self: *Fixture, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.dir, rel });
    }
    fn write(self: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }
    /// The file's bytes, or "" when it does not exist.
    fn read(self: *Fixture, rel: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, rel, self.arena.allocator(), .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => err,
        };
    }
    /// Adds a workspace with its repos (relative names) to the durable log.
    fn workspace(self: *Fixture, rel: []const u8, repos: []const []const u8) ![]const u8 {
        const p = try self.path(rel);
        try self.tmp.dir.createDirPath(testing.io, rel);
        _ = try self.engine.submit(.{ .workspace_add = .{ .path = p, .repos = repos } });
        return p;
    }
    fn call(self: *Fixture, verb: []const u8, params: anytype) !proto.Response {
        const line = try std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .id = self.next_id, .verb = verb, .params = params }, .{ .emit_null_optional_fields = false });
        self.next_id += 1;
        return self.peer.send(&self.dispatcher, line);
    }
    fn get(self: *Fixture, key: []const u8, workspace_path: ?[]const u8, repo: ?[]const u8) !proto.Response {
        return self.call("config.get", .{ .key = key, .workspace = workspace_path, .repo = repo });
    }
    fn set(self: *Fixture, key: []const u8, value: []const u8, workspace_path: ?[]const u8, repo: ?[]const u8) !proto.Response {
        return self.call("config.set", .{ .key = key, .value = value, .workspace = workspace_path, .repo = repo });
    }
};

fn errCode(r: proto.Response) []const u8 {
    return if (r.body == .@"error") r.body.@"error".code else "";
}
fn ok(r: proto.Response) !std.json.ObjectMap {
    if (r.body != .ok) {
        std.debug.print("unexpected error: {s}\n", .{errCode(r)});
        return error.TestUnexpectedResult;
    }
    return r.body.ok.object;
}
fn errData(r: proto.Response) std.json.ObjectMap {
    return r.body.@"error".data.?.object;
}
/// The source (and file) `config get` reports for one value.
fn sourceOf(r: proto.Response, key: []const u8) !struct { []const u8, ?[]const u8 } {
    for ((try ok(r)).get("sources").?.array.items) |e| if (std.mem.eql(u8, e.object.get("key").?.string, key)) {
        const p = e.object.get("path");
        return .{ e.object.get("source").?.string, if (p) |v| (if (v == .string) v.string else null) else null };
    };
    std.debug.print("no source for {s}\n", .{key});
    return error.TestUnexpectedResult;
}

test "allowedInScope: agents.* and attention.* but not user-only keys" {
    for ([_][]const u8{ "agents.default", "agents.mode", "agents.isolation", "agents.spawn", "agents.spawn.depth", "agents.archive_after", "attention", "attention.bell" }) |k| try testing.expect(scope.allowedInScope(k));
    for ([_][]const u8{ "", "agents", "agents.max_concurrent", "agents.modes", "ui", "ui.chrome", "grants", "grants.unknown", "log", "attentions" }) |k| try testing.expect(!scope.allowedInScope(k));
}

test "config get|set carry --workspace and --repo in the daemon schema" {
    for ([_][]const u8{ "config.get", "config.set" }) |name| {
        const v = main.App.schema.find(name).?;
        var n: usize = 0;
        for (v.params) |p| if (std.mem.eql(u8, p.name, "workspace") or std.mem.eql(u8, p.name, "repo")) {
            try testing.expect(!p.required);
            n += 1;
        };
        try testing.expectEqual(@as(usize, 2), n);
    }
    for (main.App.schema.find("config.check").?.params) |p| try testing.expect(!std.mem.eql(u8, p.name, "repo"));
}

test "a repo file overrides the workspace and user files per key; get reports value and source file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const org = try f.workspace("org", &.{ "venom", "venom-std" });
    const repo = try f.path("org/venom");
    const repo_file = try f.path("org/venom/.venom/repo.zon");
    const ws_file = try f.path("org/.venom/workspace.zon");
    try f.write("home/config/venom/config.zon", ".{ .agents = .{ .mode = .plan, .spawn = .{ .depth = 3 } }, .attention = .{ .bell = false } }");
    try f.write("org/.venom/workspace.zon", ".{ .agents = .{ .mode = .accept_edits, .isolation = .in_place } }");
    try f.write("org/venom/.venom/repo.zon", ".{ .agents = .{ .isolation = .copy } }");

    // One key: the effective value and the file it comes from.
    var r = try f.get("agents.isolation", null, repo);
    var o = try ok(r);
    try testing.expectEqualStrings(".copy", o.get("content").?.string);
    try testing.expectEqualStrings("repo", o.get("source").?.string);
    try testing.expectEqualStrings(repo_file, o.get("path").?.string);

    // Every key under the repo: narrowest wins per key.
    r = try f.get("", null, repo);
    const want = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "agents.isolation", "repo", repo_file },
        .{ "agents.mode", "workspace", ws_file },
        .{ "agents.spawn.depth", "user", null },
        .{ "attention.bell", "user", null },
        .{ "agents.default", "builtin", null },
    };
    for (want) |w| {
        const got = try sourceOf(r, w[0]);
        try testing.expectEqualStrings(w[1], got[0]);
        if (w[2]) |p| try testing.expectEqualStrings(p, got[1].?) else try testing.expect(got[1] == null);
    }

    // The same repo, named relative to its workspace.
    r = try f.get("agents.isolation", org, "venom");
    try testing.expectEqualStrings(".copy", (try ok(r)).get("content").?.string);

    // A sibling repo without a file sees the workspace value.
    r = try f.get("agents.isolation", null, try f.path("org/venom-std"));
    o = try ok(r);
    try testing.expectEqualStrings(".in_place", o.get("content").?.string);
    try testing.expectEqualStrings("workspace", o.get("source").?.string);
    try testing.expectEqualStrings(ws_file, o.get("path").?.string);

    // The workspace alone, and no scope (the user file, as before).
    r = try f.get("agents.mode", org, null);
    try testing.expectEqualStrings(".accept_edits", (try ok(r)).get("content").?.string);
    r = try f.get("agents.mode", null, null);
    o = try ok(r);
    try testing.expectEqualStrings(".plan", o.get("content").?.string);
    try testing.expectEqualStrings("user", o.get("source").?.string);

    // The typed config in effect for an agent in that repo.
    var scratch: std.heap.ArenaAllocator = .init(ta);
    defer scratch.deinit();
    var store = try f.scoped.layers.open(scratch.allocator(), .{ .workspace = org, .repo = repo });
    defer store.deinit();
    const c = store.current();
    try testing.expectEqual(config.Isolation.copy, c.agents.isolation);
    try testing.expectEqual(config.Mode.accept_edits, c.agents.mode);
    try testing.expectEqual(@as(u8, 3), c.agents.spawn.depth);
    try testing.expect(!c.attention.bell);
}

test "config set --workspace writes only the workspace file; --repo only the repo file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.owner();
    const org = try f.workspace("org", &.{"venom"});
    const user_before = ".{ .agents = .{ .mode = .plan } }";
    const repo_before = ".{ .agents = .{ .isolation = .copy } }";
    try f.write("home/config/venom/config.zon", user_before);
    try f.write("org/venom/.venom/repo.zon", repo_before);

    var r = try f.set("agents.mode", ".accept_edits", org, null);
    try testing.expect((try ok(r)).get("changed").?.bool);
    try testing.expect(std.mem.indexOf(u8, try f.read("org/.venom/workspace.zon"), "accept_edits") != null);
    try testing.expectEqualStrings(user_before, try f.read("home/config/venom/config.zon"));
    try testing.expectEqualStrings(repo_before, try f.read("org/venom/.venom/repo.zon"));
    // The workspace value is now in effect for the workspace, not the user.
    try testing.expectEqualStrings("workspace", (try ok(try f.get("agents.mode", org, null))).get("source").?.string);
    try testing.expectEqualStrings(".plan", (try ok(try f.get("agents.mode", null, null))).get("content").?.string);
    // Writing the same value again is a no-op.
    try testing.expect(!(try ok(try f.set("agents.mode", ".accept_edits", org, null))).get("changed").?.bool);

    const ws_after = try f.read("org/.venom/workspace.zon");
    r = try f.set("attention.notify_after", "\"30s\"", org, "venom");
    try testing.expect((try ok(r)).get("changed").?.bool);
    const repo_after = try f.read("org/venom/.venom/repo.zon");
    try testing.expect(std.mem.indexOf(u8, repo_after, "30s") != null);
    try testing.expect(std.mem.indexOf(u8, repo_after, "copy") != null);
    try testing.expectEqualStrings(ws_after, try f.read("org/.venom/workspace.zon"));
    try testing.expectEqualStrings(user_before, try f.read("home/config/venom/config.zon"));

    // User-only keys cannot be written to a workspace or repo file.
    for ([_][2][]const u8{ .{ "ui.chrome", ".own" }, .{ "grants.unknown", ".{}" }, .{ "agents.max_concurrent", "2" }, .{ "agents", ".{}" } }) |kv| {
        r = try f.set(kv[0], kv[1], org, null);
        try testing.expectEqualStrings("invalid_params.config_scope", errCode(r));
        try testing.expectEqualStrings(kv[0], errData(r).get("key").?.string);
        try testing.expectEqualStrings("workspace", errData(r).get("source").?.string);
    }
    try testing.expectEqualStrings(ws_after, try f.read("org/.venom/workspace.zon"));
    // Unknown keys and bad values fail as without a scope.
    try testing.expectEqualStrings("invalid_params.config_key", errCode(try f.set("agents.nope", "1", org, null)));
    try testing.expectEqualStrings("invalid_params.config_value", errCode(try f.set("attention.notify_after", "\"soon\"", org, null)));
    try testing.expectEqualStrings(ws_after, try f.read("org/.venom/workspace.zon"));
    // Without a scope flag, set writes the user file as before.
    try testing.expect((try ok(try f.set("ui.chrome", ".own", null, null))).get("changed").?.bool);
    try testing.expect(std.mem.indexOf(u8, try f.read("home/config/venom/config.zon"), "own") != null);
}

test "scope errors: grants, unknown workspaces and repos, nesting, misplaced and broken files" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const org = try f.workspace("org", &.{ "team/svc", "venom" });
    const team = try f.workspace("org/team", &.{"svc"});
    const single = try f.workspace("single", &.{"."});

    // config set is admin, with or without a scope.
    try testing.expectEqualStrings("denied.admin", errCode(try f.set("agents.mode", ".plan", org, null)));
    try testing.expectEqualStrings("", try f.read("org/.venom/workspace.zon"));
    f.owner();

    var r = try f.get("", try f.path("nope"), null);
    try testing.expectEqualStrings("not_found.workspace", errCode(r));
    try testing.expectEqualStrings("workspace", errData(r).get("param").?.string);
    try testing.expectEqualStrings("not_found.repo", errCode(try f.get("", org, "missing")));
    try testing.expectEqualStrings("not_found.repo", errCode(try f.get("", null, "venom")));
    try testing.expectEqualStrings("not_found.repo", errCode(try f.get("", null, try f.path("elsewhere/x"))));
    try testing.expectEqualStrings("not_found.repo", errCode(try f.get("", null, try f.path("org/venom/../venom"))));
    // --workspace and --repo must agree.
    try testing.expectEqualStrings("not_found.repo", errCode(try f.get("", team, try f.path("org/venom"))));

    // Nesting: the closest workspace's file applies to its repos.
    try f.write("org/.venom/workspace.zon", ".{ .agents = .{ .mode = .plan } }");
    try f.write("org/team/.venom/workspace.zon", ".{ .agents = .{ .mode = .accept_edits } }");
    const svc = try f.path("org/team/svc");
    try testing.expectEqualStrings(".accept_edits", (try ok(try f.get("agents.mode", null, svc))).get("content").?.string);
    // Unless the outer workspace is named.
    try testing.expectEqualStrings(".plan", (try ok(try f.get("agents.mode", org, svc))).get("content").?.string);

    // A workspace that is itself a repo: both files sit in its .venom/.
    try f.write("single/.venom/repo.zon", ".{ .agents = .{ .isolation = .in_place } }");
    r = try f.get("agents.isolation", single, ".");
    try testing.expectEqualStrings("repo", (try ok(r)).get("source").?.string);

    // A repo file with a user-only key is rejected, naming key and file.
    try f.write("org/venom/.venom/repo.zon", ".{ .ui = .{ .chrome = .own } }");
    r = try f.get("agents.mode", null, try f.path("org/venom"));
    try testing.expectEqualStrings("invalid_params.config_scope", errCode(r));
    try testing.expectEqualStrings("ui.chrome", errData(r).get("key").?.string);
    try testing.expectEqualStrings("repo", errData(r).get("source").?.string);
    try testing.expectEqualStrings(try f.path("org/venom/.venom/repo.zon"), errData(r).get("path").?.string);

    // A file that does not load names its layer and path.
    try f.write("org/venom/.venom/repo.zon", ".{ .agents = .{ .mode = .yolo } }");
    r = try f.get("", null, try f.path("org/venom"));
    try testing.expectEqualStrings("invalid_params.config_value", errCode(r));
    try testing.expectEqualStrings("repo", errData(r).get("source").?.string);
    try f.write("org/.venom/workspace.zon", "not zon");
    r = try f.set("agents.mode", ".plan", org, null);
    try testing.expectEqualStrings("invalid_params.config_value", errCode(r));
    try testing.expectEqualStrings("workspace", errData(r).get("source").?.string);
    try testing.expectEqualStrings("not zon", try f.read("org/.venom/workspace.zon"));
}
