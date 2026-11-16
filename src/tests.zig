//! venom's product verbs against the real dispatcher, and the base verb
//! surface the generated CLI exposes.
const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const main = @import("main.zig");
const Workspaces = @import("workspaces.zig").Workspaces;
const eventlog = @import("eventlog/root.zig");
const testing = std.testing;

/// The product verbs alone (no shared bundles), as the dispatcher sees them.
const model = cli.manifest.normalize(main.input);

/// One NDJSON connection over a socketpair; responses are read from memory.
const Peer = struct {
    conn: proto.Connection,
    other: std.c.fd_t,
    lines: std.ArrayList(proto.Response) = .empty,
    fn init() !Peer {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        var conn = proto.Connection.init(testing.allocator, fds[0]);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        return .{ .conn = conn, .other = fds[1] };
    }
    fn deinit(self: *Peer) void {
        self.clear();
        self.lines.deinit(testing.allocator);
        self.conn.deinit();
        proto.os.close(self.other);
    }
    fn clear(self: *Peer) void {
        for (self.lines.items) |*r| r.deinit();
        self.lines.clearRetainingCapacity();
    }
    fn send(self: *Peer, d: *proto.Dispatcher, line: []const u8) !proto.Response {
        try d.message(&self.conn, .{ .ndjson = line });
        self.clear();
        var it = std.mem.splitScalar(u8, self.conn.output.items, '\n');
        while (it.next()) |l| if (l.len > 0) try self.lines.append(testing.allocator, try proto.Response.parse(testing.allocator, l));
        self.conn.output.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 1), self.lines.items.len);
        return self.lines.items[0];
    }
};

/// The agent verbs are tested in agent_verbs_tests.zig; here they only
/// need a handler.
const Stub = struct {
    pub fn call(_: *Stub, call_: *proto.Call) anyerror!void {
        try call_.ok(.{});
    }
};

/// The product verbs over a durable event log in a temp dir.
const Fixture = struct {
    stub: Stub = .{},
    tmp: testing.TmpDir = undefined,
    dir: [:0]u8 = undefined,
    log_path: []u8 = &.{},
    engine: eventlog.Engine = undefined,
    workspaces: Workspaces = undefined,
    add: Workspaces.Add = undefined,
    remove: Workspaces.Remove = undefined,
    scan: Workspaces.Scan = undefined,
    dispatcher: proto.Dispatcher = undefined,
    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.dir);
        self.log_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.dir, eventlog.file_name });
        errdefer testing.allocator.free(self.log_path);
        try self.open();
    }
    /// Opens the log and the dispatcher; `reopen` checks durability.
    fn open(self: *Fixture) !void {
        self.engine = try eventlog.Engine.open(testing.allocator, self.log_path, .{});
        errdefer self.engine.deinit();
        self.workspaces = .{ .engine = &self.engine, .io = testing.io };
        self.add = self.workspaces.adder();
        self.remove = self.workspaces.remover();
        self.scan = self.workspaces.scanner();
        const bindings = [_]proto.Binding{
            .{ .verb = "workspace.add", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.add) },
            .{ .verb = "workspace.list", .handler = proto.VerbHandler.init(&self.workspaces) },
            .{ .verb = "workspace.remove", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.remove) },
            .{ .verb = "workspace.scan", .handler = proto.VerbHandler.typed(Workspaces.ScanParams, &self.scan) },
        } ++ stubs(&self.stub);
        self.dispatcher = try proto.Dispatcher.init(testing.allocator, &model, &bindings, .{}, null);
    }
    fn close(self: *Fixture) void {
        self.dispatcher.deinit();
        self.engine.deinit();
    }
    fn reopen(self: *Fixture) !void {
        self.close();
        try self.open();
    }
    fn deinit(self: *Fixture) void {
        self.close();
        testing.allocator.free(self.log_path);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
    fn path(self: *const Fixture, a: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, rel });
    }
    fn mkdir(self: *Fixture, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, rel);
    }
    fn write(self: *Fixture, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }
};

/// Grants the peer the owner's rights.
const Owner = struct {
    registry: proto.grants.Registry,
    fn init(self: *Owner, peer: *Peer) !void {
        self.registry = try proto.grants.Registry.init(testing.allocator, main.tool, .{});
        peer.conn.registry = &self.registry;
        peer.conn.identity = .{ .principal = proto.grants.owner };
    }
    fn deinit(self: *Owner) void {
        self.registry.deinit();
    }
};

fn stubs(stub: *Stub) [32]proto.Binding {
    var out: [32]proto.Binding = undefined;
    for (&out, [_][]const u8{ "agent.spawn", "agent.list", "agent.show", "agent.tool", "agent.send", "agent.stop", "agent.archive", "agent.clean", "agent.takeover", "agent.takeback", "agent.wait", "agent.promote", "agent.takeover_split", "agent.takeover_pane", "harness.hook", "harness.permission_prompt", "agent.context", "agent.compact", "agent.fork", "agent.mcp_off", "usage.show", "usage.export", "inbox.list", "inbox.answer", "inbox.snooze", "inbox.batch", "always.list", "always.revoke", "harness.list", "harness.show", "provider.list", "tui.hold" }) |*b, verb| b.* = .{ .verb = verb, .handler = proto.VerbHandler.init(stub) };
    return out;
}

fn errCode(r: proto.Response) []const u8 {
    return if (r.body == .@"error") r.body.@"error".code else "";
}
fn listLen(r: proto.Response, field: []const u8) !usize {
    try testing.expect(r.body == .ok);
    return r.body.ok.object.get(field).?.array.items.len;
}

test "workspace.add needs write; workspace.list is read-only" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try f.mkdir("w");
    const w = try f.path(s, "w");
    const add = try std.fmt.allocPrint(s, "{{\"id\":2,\"verb\":\"workspace.add\",\"params\":{{\"path\":\"{s}\"}}}}", .{w});
    try testing.expectEqual(@as(usize, 0), try listLen(try peer.send(&f.dispatcher, "{\"id\":1,\"verb\":\"workspace.list\"}"), "workspaces"));
    // Without a registry a caller has read only: denied before the handler.
    try testing.expectEqualStrings("denied.write", errCode(try peer.send(&f.dispatcher, add)));
    try testing.expectEqualStrings("denied.write", errCode(try peer.send(&f.dispatcher, "{\"id\":3,\"verb\":\"workspace.scan\"}")));
    try testing.expectEqual(@as(usize, 0), f.engine.state.workspaces.count());

    var owner: Owner = undefined;
    try owner.init(&peer);
    defer owner.deinit();
    var r = try peer.send(&f.dispatcher, add);
    try testing.expect(r.body.ok.object.get("added").?.bool);
    try testing.expectEqualStrings(w, r.body.ok.object.get("path").?.string);
    r = try peer.send(&f.dispatcher, add);
    try testing.expect(!r.body.ok.object.get("added").?.bool);
    try testing.expectEqualStrings("invalid_params.workspace_path", errCode(try peer.send(&f.dispatcher, "{\"id\":5,\"verb\":\"workspace.add\",\"params\":{\"path\":\"w/../x\"}}")));
    const missing = try std.fmt.allocPrint(s, "{{\"id\":6,\"verb\":\"workspace.add\",\"params\":{{\"path\":\"{s}/nope\"}}}}", .{f.dir});
    try testing.expectEqualStrings("not_found.workspace_path", errCode(try peer.send(&f.dispatcher, missing)));
    r = try peer.send(&f.dispatcher, "{\"id\":7,\"verb\":\"workspace.list\"}");
    try testing.expectEqual(@as(usize, 1), try listLen(r, "workspaces"));
    try testing.expectEqualStrings(w, r.body.ok.object.get("workspaces").?.array.items[0].object.get("path").?.string);
}

/// The repos of the listed workspace at `path`, as "name=path" lines.
fn listedRepos(a: std.mem.Allocator, r: proto.Response, path: []const u8) ![]const u8 {
    for (r.body.ok.object.get("workspaces").?.array.items) |w| {
        if (!std.mem.eql(u8, w.object.get("path").?.string, path)) continue;
        var out: std.ArrayList(u8) = .empty;
        for (w.object.get("repos").?.array.items) |repo| {
            try out.print(a, "{s}={s}\n", .{ repo.object.get("name").?.string, repo.object.get("path").?.string });
        }
        return out.items;
    }
    return error.NotListed;
}

test "workspaces: a repo folder whose name is not UTF-8 breaks no verb, fresh or already in the log" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    var owner: Owner = undefined;
    try owner.init(&peer);
    defer owner.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    // The same tree twice: `fresh` is added now, `old` was added before
    // discovery skipped such folders.
    for ([_][]const u8{ "fresh", "old" }) |w| {
        for ([_][]const u8{ "\xfebad/.git", "\xfedir/nested/.git", "fine/.git" }) |rel| try f.mkdir(try std.fmt.allocPrint(s, "{s}/{s}", .{ w, rel }));
    }
    const fresh = try f.path(s, "fresh");
    const old = try f.path(s, "old");
    const fresh_repos = try std.fmt.allocPrint(s, "fine={s}/fine\n", .{fresh});
    const old_repos = try std.fmt.allocPrint(s, "fine={s}/fine\n", .{old});

    // A log such a build left: the record is durable, with the name as bytes.
    f.close();
    {
        const log = try s.dupeSentinel(u8, f.log_path, 0);
        const fd = std.c.open(log, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        const line = try std.fmt.allocPrint(s, "{{\"commit\":1,\"ts\":\"2026-11-08T00:00:00.000Z\",\"events\":[{{\"type\":\"workspace.added\",\"data\":{{\"path\":\"{s}\",\"repos\":[[254,98,97,100],[254,100,105,114,47,110,101,115,116,101,100],\"fine\"]}}}}]}}\n", .{old});
        try testing.expectEqual(@as(isize, @intCast(line.len)), std.c.write(fd, line.ptr, line.len));
    }
    try f.open();

    const check = struct {
        fn run(fx: *Fixture, pr: *Peer, a: std.mem.Allocator, paths: [2][]const u8, want: [2][]const u8) !void {
            const r = try pr.send(&fx.dispatcher, "{\"id\":100,\"verb\":\"workspace.list\"}");
            try testing.expectEqual(@as(usize, 2), try listLen(r, "workspaces"));
            for (paths, want) |p, w| try testing.expectEqualStrings(w, try listedRepos(a, r, p));
        }
    }.run;

    // Adding either one succeeds and shows the repos that can be named.
    var r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":1,\"verb\":\"workspace.add\",\"params\":{{\"path\":\"{s}\"}}}}", .{fresh}));
    try testing.expect(r.body.ok.object.get("added").?.bool);
    try testing.expectEqual(@as(usize, 1), try listLen(r, "repos"));
    r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":2,\"verb\":\"workspace.add\",\"params\":{{\"path\":\"{s}\"}}}}", .{old}));
    try testing.expect(!r.body.ok.object.get("added").?.bool);
    try testing.expectEqual(@as(usize, 1), try listLen(r, "repos"));
    try check(&f, &peer, s, .{ fresh, old }, .{ fresh_repos, old_repos });

    // Scan and doctor agree with the log: nothing changed.
    r = try peer.send(&f.dispatcher, "{\"id\":3,\"verb\":\"workspace.scan\"}");
    for (r.body.ok.object.get("workspaces").?.array.items) |w| try testing.expect(!w.object.get("changed").?.bool);
    var report: cli.doctor.Report = .{ .arena = s, .tool = main.tool };
    var doctor = f.workspaces.check();
    try doctor.run(&report);
    for (report.results.items) |res| try testing.expectEqual(cli.doctor.Status.ok, res.status);

    // All the same after a restart, and after a checkpoint.
    try f.reopen();
    try check(&f, &peer, s, .{ fresh, old }, .{ fresh_repos, old_repos });
    try f.engine.compact();
    try f.reopen();
    try check(&f, &peer, s, .{ fresh, old }, .{ fresh_repos, old_repos });

    // And the workspace can still be removed.
    r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":4,\"verb\":\"workspace.remove\",\"params\":{{\"path\":\"{s}\"}}}}", .{old}));
    try testing.expect(r.body.ok.object.get("removed").?.bool);
}

test "workspaces: discovery, nesting, repo-less folders, durability and doctor on a temp tree" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var peer = try Peer.init();
    defer peer.deinit();
    var owner: Owner = undefined;
    try owner.init(&peer);
    defer owner.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    // org/ holds repos, a nested workspace (team/) and things discovery skips.
    try f.mkdir("org/venom/.git/worktrees/venom-fix-7");
    try f.write("org/venom/.git/worktrees/venom-fix-7/locked", "venom: agent a7");
    try f.mkdir("org/venom/.git/worktrees/user-wt");
    try f.mkdir("org/venom/sub/.git"); // inside a repo: not a separate repo
    try f.mkdir("org/venom-fix-7");
    try f.write("org/venom-fix-7/.git", "gitdir: ../venom/.git/worktrees/venom-fix-7\n");
    try f.mkdir("org/user-wt");
    try f.write("org/user-wt/.git", try std.fmt.allocPrint(s, "gitdir: {s}/org/venom/.git/worktrees/user-wt\n", .{f.dir}));
    try f.mkdir("org/deep/a/lib/.git");
    try f.mkdir("org/deep/a/b/c/d/.git"); // 5 levels down: past max_depth
    try f.mkdir("org/node_modules/x/.git");
    try f.mkdir("org/.hidden/y/.git");
    try f.mkdir("org/team/svc/.git");
    try f.mkdir("org/notes");
    try f.mkdir("plain/docs");
    try f.mkdir("single/.git");
    try f.mkdir("single/src");
    {
        const target = try std.fmt.allocPrintSentinel(s, "{s}/single", .{f.dir}, 0);
        const link = try std.fmt.allocPrintSentinel(s, "{s}/org/link", .{f.dir}, 0);
        try testing.expectEqual(@as(c_int, 0), std.c.symlink(target, link)); // never followed
    }

    const org = try f.path(s, "org");
    const team = try f.path(s, "org/team");
    const plain = try f.path(s, "plain");
    const single = try f.path(s, "single");
    var id: usize = 1;
    for ([_][]const u8{ org, team, plain, single }) |p| {
        const r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":{d},\"verb\":\"workspace.add\",\"params\":{{\"path\":\"{s}\"}}}}", .{ id, p }));
        id += 1;
        try testing.expect(r.body.ok.object.get("added").?.bool);
    }

    const want_org = try std.fmt.allocPrint(s, "deep/a/lib={0s}/deep/a/lib\nteam/svc={0s}/team/svc\nuser-wt={0s}/user-wt\nvenom={0s}/venom\n", .{org});
    const check = struct {
        fn run(fx: *Fixture, pr: *Peer, a: std.mem.Allocator, want: []const u8, paths: [4][]const u8) !void {
            const r = try pr.send(&fx.dispatcher, "{\"id\":100,\"verb\":\"workspace.list\"}");
            try testing.expectEqual(@as(usize, 4), try listLen(r, "workspaces"));
            try testing.expectEqualStrings(want, try listedRepos(a, r, paths[0]));
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "svc={s}/svc\n", .{paths[1]}), try listedRepos(a, r, paths[1]));
            try testing.expectEqualStrings("", try listedRepos(a, r, paths[2]));
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, ".={s}\n", .{paths[3]}), try listedRepos(a, r, paths[3]));
        }
    }.run;
    try check(&f, &peer, s, want_org, .{ org, team, plain, single });

    // Nesting: the closest workspace owns a path.
    try testing.expectEqualStrings(team, f.workspaces.owner(try f.path(s, "org/team/svc")).?.path);
    try testing.expectEqualStrings(org, f.workspaces.owner(try f.path(s, "org/venom")).?.path);
    try testing.expectEqualStrings(plain, f.workspaces.owner(plain).?.path);
    try testing.expect(f.workspaces.owner(f.dir) == null);

    // Durable: a restart rebuilds the same workspaces from the log.
    try f.reopen();
    try check(&f, &peer, s, want_org, .{ org, team, plain, single });

    // Doctor: all present and current.
    var report: cli.doctor.Report = .{ .arena = s, .tool = main.tool };
    var doctor = f.workspaces.check();
    try doctor.run(&report);
    try testing.expectEqual(@as(u8, 0), report.status());
    for (report.results.items) |res| try testing.expectEqual(cli.doctor.Status.ok, res.status);

    // A new repo appears: doctor warns, scan picks it up once.
    try f.mkdir("plain/fresh/.git");
    report = .{ .arena = s, .tool = main.tool };
    try doctor.run(&report);
    try testing.expectEqual(@as(u8, 0), report.status());
    var warned = false;
    for (report.results.items) |res| if (res.status == .warn) {
        warned = true;
        try testing.expectEqualStrings("workspace.repos", res.id);
    };
    try testing.expect(warned);
    var r = try peer.send(&f.dispatcher, "{\"id\":200,\"verb\":\"workspace.scan\"}");
    var changed: usize = 0;
    for (r.body.ok.object.get("workspaces").?.array.items) |w| changed += @intFromBool(w.object.get("changed").?.bool);
    try testing.expectEqual(@as(usize, 1), changed);
    r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":201,\"verb\":\"workspace.scan\",\"params\":{{\"path\":\"{s}\"}}}}", .{plain}));
    try testing.expect(!r.body.ok.object.get("workspaces").?.array.items[0].object.get("changed").?.bool);
    try testing.expectEqualStrings("not_found.workspace", errCode(try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":202,\"verb\":\"workspace.scan\",\"params\":{{\"path\":\"{s}/nope\"}}}}", .{f.dir}))));

    // The folder goes away: doctor fails with a runnable fix, scan keeps the
    // last repos and says the folder is missing.
    try f.tmp.dir.deleteTree(testing.io, "single");
    report = .{ .arena = s, .tool = main.tool };
    try doctor.run(&report);
    try testing.expectEqual(@as(u8, 1), report.status());
    var failed: usize = 0;
    for (report.results.items) |res| if (res.status == .fail) {
        failed += 1;
        try testing.expectEqualStrings("workspace.path", res.id);
        try testing.expectEqualStrings(try std.fmt.allocPrint(s, "venom workspace remove --path={s} --json", .{single}), res.fix);
    };
    try testing.expectEqual(@as(usize, 1), failed);
    r = try peer.send(&f.dispatcher, "{\"id\":203,\"verb\":\"workspace.scan\"}");
    for (r.body.ok.object.get("workspaces").?.array.items) |w| {
        const is_single = std.mem.eql(u8, w.object.get("path").?.string, single);
        try testing.expectEqual(is_single, w.object.get("missing").?.bool);
        if (is_single) try testing.expectEqual(@as(usize, 1), w.object.get("repos").?.array.items.len);
    }

    // Remove forgets it (idempotently); the nested owner falls back.
    r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":204,\"verb\":\"workspace.remove\",\"params\":{{\"path\":\"{s}\"}}}}", .{team}));
    try testing.expect(r.body.ok.object.get("removed").?.bool);
    r = try peer.send(&f.dispatcher, try std.fmt.allocPrint(s, "{{\"id\":205,\"verb\":\"workspace.remove\",\"params\":{{\"path\":\"{s}\"}}}}", .{team}));
    try testing.expect(!r.body.ok.object.get("removed").?.bool);
    try testing.expectEqualStrings(org, f.workspaces.owner(try f.path(s, "org/team/svc")).?.path);
    try f.reopen();
    try testing.expectEqual(@as(usize, 3), try listLen(try peer.send(&f.dispatcher, "{\"id\":206,\"verb\":\"workspace.list\"}"), "workspaces"));
}

test "base verb surface: serve, events, config, skill, doctor, mcp" {
    const want = [_][]const u8{ "serve", "events", "config.get", "config.set", "config.check", "config.reload", "config.schema", "skill", "skill.install", "doctor", "mcp", "docs", "completions", "whoami", "workspace.add", "workspace.list", "workspace.remove", "workspace.scan", "agent.spawn", "agent.list", "agent.show", "agent.send", "agent.stop", "agent.archive", "inbox.list", "inbox.answer", "inbox.snooze", "harness.list", "harness.show", "provider.list" };
    for (want) |name| {
        var found = false;
        for (main.App.verbs) |v| if (std.mem.eql(u8, v.name, name)) {
            found = true;
        };
        if (!found) std.debug.print("missing verb: {s}\n", .{name});
        try testing.expect(found);
    }
    // venom never calls its things sessions, threads or projects.
    for (main.App.verbs) |v| for ([_][]const u8{ "session", "thread", "project" }) |word| {
        try testing.expect(std.mem.indexOf(u8, v.name, word) == null);
    };
}
