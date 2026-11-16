//! Caller grants for venom's verbs and a principal per agent: the grant table through the real dispatcher, for the
//! owner, `unknown`, read-only and write-only tokens, and agents whose
//! identity is resolved from their real harness process and token, as
//! the daemon would at `accept` and `hello`.
//! Fake harness only; vendor harnesses are never constructed here.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const cli = @import("cli");
const build_options = @import("build_options");
const main = @import("main.zig");
const config = @import("config.zig");
const scope = @import("scope.zig");
const eventlog = @import("eventlog/root.zig");
const harness = @import("harness/root.zig");
const harnesses = @import("harnesses.zig");
const Workspaces = @import("workspaces.zig").Workspaces;
const Agents = @import("agents.zig").Agents;
const Principals = @import("principals.zig").Principals;
const Inbox = @import("inbox.zig").Inbox;
const Usage = @import("usage.zig").Usage;
const ContextVerbs = @import("context.zig").Verbs;

const Stub = struct {
    pub fn call(_: *Stub, call_: *proto.Call) anyerror!void {
        try call_.ok(.{});
    }
};
const grants = proto.grants;
const testing = std.testing;
const ta = testing.allocator;

const model = scope.extend(cfg.merge(cli.manifest.normalize(main.input)));

const Peer = struct {
    conn: proto.Connection,
    other: std.c.fd_t,
    last: ?proto.Response = null,
    fn init(registry: *grants.Registry) !Peer {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        var conn = proto.Connection.init(ta, fds[0]);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        conn.registry = registry;
        return .{ .conn = conn, .other = fds[1] };
    }
    fn deinit(self: *Peer) void {
        if (self.last) |*r| r.deinit();
        self.conn.deinit();
        proto.os.close(self.other);
    }
};

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: []const u8,
    arena: std.heap.ArenaAllocator,
    exe: [std.fs.max_path_bytes:0]u8,
    fake: harness.Fake,
    adapters: [1]harness.host.Registered,
    store: config.Store,
    engine: eventlog.Engine,
    host: harness.Host,
    registry: grants.Registry,
    principals: Principals,
    workspaces: Workspaces,
    ws_add: Workspaces.Add,
    ws_remove: Workspaces.Remove,
    ws_scan: Workspaces.Scan,
    agents: Agents,
    scoped: scope.Config,
    inbox: Inbox,
    usage: Usage,
    stub: Stub = .{},
    context_verbs: ContextVerbs,
    dispatcher: proto.Dispatcher,
    peer: Peer,
    next_id: usize,

    fn init(self: *Fixture) !void {
        self.next_id = 1;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = .init(ta);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        try self.tmp.dir.createDirPath(testing.io, "w");
        try self.tmp.dir.createDirPath(testing.io, "other");
        const rel = try a.dupeSentinel(u8, build_options.fake_harness, 0);
        if (std.c.realpath(rel, &self.exe) == null) return error.FakeHarnessMissing;
        self.fake = .{ .exe = std.mem.sliceTo(&self.exe, 0), .script = "{\"turns\":[{\"match\":\"\",\"steps\":[{\"text\":\"Done.\"}]}]}", .state_dir = self.dir };
        self.adapters = .{.{ .harness = harness.fake.name, .adapter = self.fake.adapter() }};
        // Vendor harnesses off, as every test that could start one must.
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = harnesses.testConfig("") });
        const user = try std.fmt.allocPrint(a, "{s}/config.zon", .{self.dir});
        self.store = try config.Store.init(ta, .{ .io = testing.io, .path = user, .validate = config.validate });
        errdefer self.store.deinit();
        self.engine = try eventlog.Engine.open(ta, try std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, eventlog.file_name }), .{});
        errdefer self.engine.deinit();
        self.registry = try grants.Registry.init(ta, main.tool, .{});
        errdefer self.registry.deinit();
        self.principals = .{ .gpa = ta, .registry = &self.registry, .engine = &self.engine };
        errdefer self.principals.deinit();
        self.principals.install();
        self.host = harness.Host.init(ta, &self.engine, &self.adapters, .{});
        errdefer self.host.deinit();
        self.host.credentials = self.principals.credentials();
        self.engine.options.executors = self.host.executor();
        try self.engine.start();

        self.workspaces = .{ .engine = &self.engine, .io = testing.io };
        self.ws_add = self.workspaces.adder();
        self.ws_remove = self.workspaces.remover();
        self.ws_scan = self.workspaces.scanner();
        self.agents = .{ .engine = &self.engine, .host = &self.host, .io = testing.io, .config = &self.store, .principals = &self.principals };
        self.usage = .{ .engine = &self.engine };
        self.context_verbs = .{ .agents = &self.agents };
        self.inbox = .{ .engine = &self.engine, .principals = &self.principals };
        self.scoped = .{ .store = &self.store, .engine = &self.engine, .layers = .{ .gpa = ta, .io = testing.io, .user = user } };
        const bindings = [_]proto.Binding{
            .{ .verb = "workspace.add", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.ws_add) },
            .{ .verb = "workspace.list", .handler = proto.VerbHandler.init(&self.workspaces) },
            .{ .verb = "workspace.remove", .handler = proto.VerbHandler.typed(Workspaces.PathParams, &self.ws_remove) },
            .{ .verb = "workspace.scan", .handler = proto.VerbHandler.typed(Workspaces.ScanParams, &self.ws_scan) },
            // Plain reads; harness_verbs_tests.zig has them.
            .{ .verb = "harness.list", .handler = proto.VerbHandler.init(&self.stub) },
            .{ .verb = "harness.show", .handler = proto.VerbHandler.init(&self.stub) },
            .{ .verb = "provider.list", .handler = proto.VerbHandler.init(&self.stub) },
            .{ .verb = "tui.hold", .handler = proto.VerbHandler.init(&self.stub) },
        } ++ self.agents.bindings() ++ self.usage.bindings() ++ self.context_verbs.bindings() ++ self.inbox.bindings() ++ self.scoped.bindings();
        self.dispatcher = try proto.Dispatcher.init(ta, &model, &bindings, .{}, null);
        errdefer self.dispatcher.deinit();
        self.peer = try Peer.init(&self.registry);
    }

    fn deinit(self: *Fixture) void {
        self.peer.deinit();
        self.dispatcher.deinit();
        // Ends every fake process; their tokens are released on exit.
        self.host.deinit();
        self.engine.deinit();
        self.principals.deinit();
        self.registry.deinit();
        self.store.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *Fixture, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.dir, rel });
    }

    /// One request as `who`; the response lives until the next call.
    fn callOn(self: *Fixture, d: *proto.Dispatcher, who: grants.Identity, verb: []const u8, params: anytype) !proto.Response {
        self.peer.conn.identity = who;
        const a = self.arena.allocator();
        const line = if (@typeInfo(@TypeOf(params)).@"struct".field_names.len == 0)
            try std.json.Stringify.valueAlloc(a, .{ .id = self.next_id, .verb = verb }, .{})
        else
            try std.json.Stringify.valueAlloc(a, .{ .id = self.next_id, .verb = verb, .params = params }, .{ .emit_null_optional_fields = false });
        self.next_id += 1;
        try d.message(&self.peer.conn, .{ .ndjson = line });
        if (self.peer.last) |*r| r.deinit();
        self.peer.last = null;
        const out = std.mem.trimEnd(u8, self.peer.conn.output.items, "\n");
        try testing.expect(out.len > 0 and std.mem.indexOfScalar(u8, out, '\n') == null);
        self.peer.last = try proto.Response.parse(ta, out);
        self.peer.conn.output.clearRetainingCapacity();
        return self.peer.last.?;
    }
    fn call(self: *Fixture, who: grants.Identity, verb: []const u8, params: anytype) !proto.Response {
        return self.callOn(&self.dispatcher, who, verb, params);
    }
    /// `inbox.answer` as `who`. The agents have no pending request, so a
    /// caller that passes the grant checks gets `not_found.request`.
    fn answerAs(self: *Fixture, who: grants.Identity, agent: []const u8) ![]const u8 {
        const r = code(try self.call(who, "inbox.answer", .{ .agent = agent, .answer = "deny" }));
        return if (std.mem.eql(u8, r, "not_found.request")) "ok" else r;
    }

    /// A bearer token principal issued by the owner, used from outside.
    fn token(self: *Fixture, gs: []const grants.Grant) !grants.Identity {
        const issued = try self.registry.issueChild(.{ .principal = grants.owner }, .{ .grants = gs, .label = "test" }, grants.nowSeconds());
        ta.free(issued.token);
        return .{ .principal = issued.principal };
    }

    /// The identity of `agent`'s harness process, resolved as the daemon
    /// does: the ancestry walk from its pid, then `hello`
    /// with the `VENOM_TOKEN` from its environment.
    fn agentIdentity(self: *Fixture, agent: []const u8) !grants.Identity {
        const b = self.host.binding(agent) orelse return error.NoBinding;
        const pid = b.process.?.pid();
        // Until exec, /proc shows the daemon's own environment.
        const deadline = @import("supervisor").monotonicMs() + 5000;
        while (!std.mem.startsWith(u8, try self.proc(pid, "cmdline"), self.fake.exe)) {
            if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        const env = try self.proc(pid, "environ");
        const tok = envValue(env, harness.host.token_env) orelse return error.NoToken;
        try testing.expect(std.mem.startsWith(u8, tok, "vnt1.venom.g"));
        const principal = envValue(env, harness.host.principal_env).?;
        var identity = self.registry.resolve(proto.process.walk(pid, std.c.getpid()), pid, grants.nowSeconds());
        try testing.expect(identity.floor == .bound);
        try testing.expectEqual(@as(?grants.TokenFailure, null), self.registry.authenticate(&identity, tok, grants.nowSeconds()));
        var buf: [24]u8 = undefined;
        try testing.expectEqualStrings(principal, grants.name(identity.principal, &buf));
        try testing.expectEqualStrings(agent, self.principals.agentOf(identity.principal).?);
        return identity;
    }

    /// A /proc file (size 0 in stat, so read until EOF).
    fn proc(self: *Fixture, pid: std.c.pid_t, file: []const u8) ![]const u8 {
        const p = try std.fmt.allocPrintSentinel(self.arena.allocator(), "/proc/{d}/{s}", .{ pid, file }, 0);
        const fd = std.c.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return error.ProcessGone;
        defer _ = std.c.close(fd);
        var out: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            try out.appendSlice(self.arena.allocator(), buf[0..@intCast(n)]);
        }
        return out.items;
    }
};

fn envValue(env: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, env, 0);
    while (it.next()) |e| if (e.len > name.len and e[name.len] == '=' and std.mem.startsWith(u8, e, name)) return e[name.len + 1 ..];
    return null;
}

fn code(r: proto.Response) []const u8 {
    return if (r.body == .@"error") r.body.@"error".code else "ok";
}
/// A string field of an ok result, copied out of the response.
fn okStr(f: *Fixture, r: proto.Response, field: []const u8) ![]const u8 {
    if (r.body != .ok) {
        std.debug.print("unexpected error: {s}\n", .{r.body.@"error".code});
        return error.TestUnexpectedResult;
    }
    return f.arena.allocator().dupe(u8, r.body.ok.object.get(field).?.string);
}
fn count(r: proto.Response, field: []const u8) !usize {
    try testing.expect(r.body == .ok);
    return r.body.ok.object.get(field).?.array.items.len;
}

const owner: grants.Identity = .{ .principal = grants.owner };
const unknown: grants.Identity = .{ .principal = grants.unknown };

test "grants: the context panel's verbs: reads on read, actions on write, a fork also on spawn" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const w = try f.path("w");
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));
    const a1 = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" }), "agent");
    const own = try std.fmt.allocPrint(f.arena.allocator(), "agent:{s}", .{a1});
    try testing.expectEqualStrings("ok", code(try f.call(unknown, "agent.context", .{ .agent = a1 })));
    try testing.expectEqualStrings("denied.write", code(try f.call(unknown, "agent.compact", .{ .agent = a1 })));
    try testing.expectEqualStrings("denied.write", code(try f.call(unknown, "agent.fork", .{ .agent = a1 })));
    try testing.expectEqualStrings("denied.write", code(try f.call(unknown, "agent.mcp_off", .{ .agent = a1 })));
    // Reads are per agent; a caller may hold neither.
    const other = try f.token(&.{.{ .right = .read, .scope = "agent:a99" }});
    try testing.expectEqualStrings("denied.read", code(try f.call(other, "agent.context", .{ .agent = a1 })));
    // Write on the agent is not spawn on the workspace.
    const writer = try f.token(&.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = own } });
    try testing.expectEqualStrings("denied.spawn", code(try f.call(writer, "agent.fork", .{ .agent = a1 })));
}

test "grants: agent.fork holds an agent to the sub-agent limits; a person is not" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const w = try f.path("w");
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{w});
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));
    const a1 = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } } }), "agent");
    const id1 = try f.agentIdentity(a1);
    const issued = try f.registry.issueChild(id1, .{ .grants = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = ws }, .{ .right = .spawn, .scope = ws } }, .label = "delegated" }, grants.nowSeconds());
    ta.free(issued.token);
    const tok: grants.Identity = .{ .principal = issued.principal };
    const a2 = try okStr(&f, try f.call(tok, "agent.spawn", .{ .cwd = w, .task = "t" }), "agent");
    // Both between turns; this fixture has no reactor of its own.
    const deadline = @import("supervisor").monotonicMs() + 10_000;
    while (f.engine.state.agents.getPtr(a1).?.state != .settled or f.engine.state.agents.getPtr(a2).?.state != .settled) {
        if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
        try f.host.poll(5);
    }

    // Forking its child would make depth 3 of the default 2.
    try testing.expectEqualStrings("denied.spawn_depth", code(try f.call(tok, "agent.fork", .{ .agent = a2 })));
    // Forking itself fits, but it has no turn running: it may not make agents now.
    try testing.expectEqualStrings("conflict.parent_stopped", code(try f.call(tok, "agent.fork", .{ .agent = a1 })));
    // A person is held to neither.
    try testing.expectEqualStrings("ok", code(try f.call(owner, "agent.fork", .{ .agent = a2 })));

    // allow off: agents are denied; a person is not.
    try testing.expectEqualStrings("ok", code(try f.call(owner, "config.set", .{ .key = "agents.spawn.allow", .value = "false" })));
    _ = try f.store.reload();
    try testing.expectEqualStrings("denied.spawn_disabled", code(try f.call(tok, "agent.fork", .{ .agent = a1 })));
    try testing.expectEqualStrings("ok", code(try f.call(owner, "agent.fork", .{ .agent = a1 })));

    // Within the limits: the caller at work forks its settled child. Being at
    // work is asked of the caller, never of the source.
    try testing.expectEqualStrings("ok", code(try f.call(owner, "config.set", .{ .key = "agents.spawn.allow", .value = "true" })));
    try testing.expectEqualStrings("ok", code(try f.call(owner, "config.set", .{ .key = "agents.spawn.depth", .value = "3" })));
    _ = try f.store.reload();
    try testing.expectEqualStrings("ok", code(try f.call(owner, "agent.send", .{ .agent = a1, .text = "again" })));
    try testing.expectEqualStrings("ok", code(try f.call(tok, "agent.fork", .{ .agent = a2 })));
}

test "grants: the venom grant table for owner, unknown and token callers" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const w = try f.path("w");
    const other = try f.path("other");
    const ws = try std.fmt.allocPrint(f.arena.allocator(), "workspace:{s}", .{w});

    // unknown: reads only.
    try testing.expectEqualStrings("ok", code(try f.call(unknown, "workspace.list", .{})));
    try testing.expectEqualStrings("ok", code(try f.call(unknown, "agent.list", .{})));
    try testing.expectEqualStrings("denied.write", code(try f.call(unknown, "workspace.add", .{ .path = w })));
    try testing.expectEqualStrings("denied.write", code(try f.call(unknown, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" })));
    try testing.expectEqualStrings("denied.admin", code(try f.call(unknown, "config.set", .{ .key = "agents.archive_after", .value = "\"1h\"" })));

    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = other })));

    // A read-only caller is denied agent.spawn (and every write).
    const reader = try f.token(&.{.{ .right = .read, .scope = "*" }});
    try testing.expectEqualStrings("denied.write", code(try f.call(reader, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" })));
    try testing.expectEqualStrings("denied.write", code(try f.call(reader, "workspace.scan", .{})));
    try testing.expectEqual(@as(usize, 2), try count(try f.call(reader, "workspace.list", .{}), "workspaces"));

    // write on a workspace without spawn: no agent.spawn.
    const writer = try f.token(&.{.{ .right = .write, .scope = ws }});
    try testing.expectEqualStrings("denied.spawn", code(try f.call(writer, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" })));
    // Its write is scoped: not the other workspace; lists are filtered.
    try testing.expectEqualStrings("denied.write", code(try f.call(writer, "workspace.remove", .{ .path = other })));
    try testing.expectEqualStrings("denied.write", code(try f.call(writer, "workspace.add", .{ .path = try f.path("nope") })));
    try testing.expectEqual(@as(usize, 1), try count(try f.call(writer, "workspace.list", .{}), "workspaces"));
    try testing.expectEqual(@as(usize, 1), try count(try f.call(writer, "workspace.scan", .{}), "workspaces"));

    // write and spawn on the workspace: spawning there, not elsewhere; and
    // never more than it holds.
    const lead = try f.token(&.{ .{ .right = .write, .scope = ws }, .{ .right = .spawn, .scope = ws } });
    try testing.expectEqualStrings("denied.write", code(try f.call(lead, "agent.spawn", .{ .cwd = other, .task = "t", .harness = "fake" })));
    try testing.expectEqualStrings("denied.delegation", code(try f.call(lead, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{.{ .right = "write", .scope = "*" }} })));
    try testing.expectEqualStrings("invalid_params.grant_scope", code(try f.call(lead, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{.{ .right = "write", .scope = "agent:a:b" }} })));
    try testing.expectEqual(@as(usize, 0), f.engine.state.agents.count());
    const a1 = try okStr(&f, try f.call(lead, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" }), "agent");
    // Without read *, its agent reads what the spawner can: the workspace.
    const p1 = f.registry.get(f.principals.principalOf(a1).?).?;
    try testing.expectEqual(lead.principal, p1.parent.?);
    try testing.expectEqualStrings(ws, p1.grants[0].scope);
    // A token's expiry bounds the agent it spawned.
    try testing.expectEqual(f.registry.get(lead.principal).?.expires, p1.expires);
    try testing.expectEqualStrings("ok", code(try f.call(lead, "agent.send", .{ .agent = a1, .text = "more" })));
    try testing.expectEqualStrings("ok", code(try f.call(writer, "agent.show", .{ .agent = a1 })));

    // The person's token is different: still covered
    // at issue, but its agents are the owner's and outlive it.
    const issued_person = try f.registry.issueChild(.{ .principal = grants.owner }, .{ .grants = &.{ .{ .right = .write, .scope = ws }, .{ .right = .spawn, .scope = ws } }, .namespace = "person", .ttl = 3600 }, grants.nowSeconds());
    defer ta.free(issued_person.token);
    const person: grants.Identity = .{ .principal = issued_person.principal };
    try testing.expectEqualStrings("denied.delegation", code(try f.call(person, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{.{ .right = "write", .scope = "*" }} })));
    const a_person = try okStr(&f, try f.call(person, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" }), "agent");
    const p_person = f.registry.get(f.principals.principalOf(a_person).?).?;
    try testing.expectEqual(grants.owner, p_person.parent.?);
    try testing.expectEqual(@as(?i64, null), p_person.expires);

    // A control pane's principal is bound to its process: the same for what it starts, and no agent of its may bind.
    const bound_root = (try @import("proto").process.stat(std.c.getppid())).ref;
    const bound_issue = try f.registry.issueChild(.{ .principal = grants.owner }, .{ .kind = .process, .root = bound_root, .grants = &.{ .{ .right = .write, .scope = ws }, .{ .right = .spawn, .scope = ws } }, .namespace = "person" }, grants.nowSeconds());
    defer ta.free(bound_issue.token);
    const control: grants.Identity = .{ .principal = bound_issue.principal, .floor = .{ .bound = bound_issue.principal } };
    const a_bound = try okStr(&f, try f.call(control, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" }), "agent");
    const p_bound = f.registry.get(f.principals.principalOf(a_bound).?).?;
    try testing.expectEqual(grants.owner, p_bound.parent.?);
    try testing.expectEqual(@as(?i64, null), p_bound.expires);
    try testing.expect(!f.registry.mayBind(.{ .principal = p_bound.id }, grants.nowSeconds()));

    // An existing and a missing agent look the same to a caller without
    // rights on them.
    const outsider = try f.token(&.{.{ .right = .write, .scope = "agent:a9" }});
    try testing.expectEqualStrings("denied.write", code(try f.call(outsider, "agent.stop", .{ .agent = a1 })));
    try testing.expectEqualStrings("not_found.agent", code(try f.call(outsider, "agent.stop", .{ .agent = "a9" })));
    try testing.expectEqualStrings("denied.write", code(try f.call(outsider, "agent.stop", .{ .agent = "a8" })));
    try testing.expectEqualStrings("denied.write", code(try f.call(reader, "agent.archive", .{ .agent = a1 })));
    // agent.tool reads one agent's call: bodies are as private as agent.show.
    const elsewhere = try f.token(&.{.{ .right = .read, .scope = "agent:a9" }});
    try testing.expectEqualStrings("denied.read", code(try f.call(elsewhere, "agent.tool", .{ .agent = a1, .call = "c1" })));
    try testing.expectEqualStrings("denied.read", code(try f.call(elsewhere, "agent.show", .{ .agent = a1, .tools = true })));
    try testing.expectEqualStrings("not_found.call", code(try f.call(reader, "agent.tool", .{ .agent = a1, .call = "c999" })));

    // config set stays the owner's: grants are user-only.
    try testing.expectEqualStrings("denied.admin", code(try f.call(lead, "config.set", .{ .key = "agents.archive_after", .value = "\"1h\"" })));
    try testing.expectEqualStrings("ok", code(try f.call(owner, "config.set", .{ .key = "agents.archive_after", .value = "\"1h\"" })));
}

test "grants: each agent's harness gets its own token; agents cannot answer themselves or their sub-agents" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const w = try f.path("w");
    const ws = try std.fmt.allocPrint(f.arena.allocator(), "workspace:{s}", .{w});
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));

    // Default profile: read *, write on itself; spawn on itself always.
    const a1 = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" }), "agent");
    const p1 = f.registry.get(f.principals.principalOf(a1).?).?;
    try testing.expectEqual(grants.owner, p1.parent.?);
    try testing.expectEqual(@as(usize, 3), p1.grants.len);
    try testing.expectEqualStrings("*", p1.grants[0].scope);
    try testing.expectEqualStrings("agent:a1", p1.grants[1].scope);
    try testing.expectEqual(grants.Right.spawn, p1.grants[2].right);
    // A lead agent that may spawn in the workspace.
    const a2 = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } } }), "agent");

    const id1 = try f.agentIdentity(a1);
    const id2 = try f.agentIdentity(a2);
    try testing.expect(id1.principal != id2.principal);
    // The process principal is bound to the harness process, not to argv.
    const q1 = f.registry.get(id1.principal).?;
    try testing.expect(q1.root != null);
    try testing.expectEqual(f.principals.principalOf(a1).?, q1.parent.?);
    const argv = try f.proc(f.host.binding(a1).?.process.?.pid(), "cmdline");
    try testing.expect(std.mem.indexOf(u8, argv, "vnt1.") == null);

    // a1's token: read-only beyond itself.
    try testing.expectEqualStrings("ok", code(try f.call(id1, "agent.show", .{ .agent = a2 })));
    try testing.expectEqualStrings("denied.write", code(try f.call(id1, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" })));
    try testing.expectEqualStrings("denied.write", code(try f.call(id1, "agent.send", .{ .agent = a2, .text = "hi" })));
    try testing.expectEqualStrings("denied.write", code(try f.call(id1, "agent.stop", .{ .agent = a2 })));
    try testing.expectEqualStrings("denied.write", code(try f.call(id1, "workspace.add", .{ .path = try f.path("x") })));
    try testing.expectEqualStrings("denied.admin", code(try f.call(id1, "config.set", .{ .key = "agents.archive_after", .value = "\"1h\"" })));

    // a2 spawns a sub-agent: it is a2's child, in agent and principal tree.
    // Its default grants could not touch a2; give it write on the
    // workspace (within a2's), so only the self-approval rule stops it.
    try testing.expectEqualStrings("denied.delegation", code(try f.call(id2, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{.{ .right = "admin", .scope = "*" }} })));
    const a3 = try okStr(&f, try f.call(id2, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws } } }), "agent");
    try testing.expectEqualStrings(a2, f.engine.state.agents.getPtr(a3).?.parent.?);
    try testing.expect(f.registry.descendant(f.principals.principalOf(a3).?, f.principals.principalOf(a2).?));
    const id3 = try f.agentIdentity(a3);

    // inbox.answer: write on the agent, never the agent itself or its
    // descendants (denied.self_approval).
    try testing.expectEqualStrings("denied.self_approval", try f.answerAs(id2, a2));
    try testing.expectEqualStrings("denied.self_approval", try f.answerAs(id3, a2));
    try testing.expectEqualStrings("denied.self_approval", try f.answerAs(id3, a3));
    try testing.expectEqualStrings("denied.self_approval", try f.answerAs(id1, a1));
    try testing.expectEqualStrings("denied.write", try f.answerAs(id1, a2));
    // inbox.batch checks every item the same way; always.revoke needs write
    // on the workspace.
    try testing.expectEqualStrings("denied.self_approval", code(try f.call(id3, "inbox.batch", .{ .items = .{.{ .agent = a2, .request = "r1" }}, .answer = "deny" })));
    try testing.expectEqualStrings("not_found.request", code(try f.call(owner, "inbox.batch", .{ .items = .{.{ .agent = a2, .request = "r1" }}, .answer = "deny" })));
    try testing.expectEqualStrings("denied.write", code(try f.call(id1, "always.revoke", .{ .workspace = w, .grant = "exec:zig" })));
    try testing.expectEqualStrings("not_found.grant", code(try f.call(owner, "always.revoke", .{ .workspace = w, .grant = "exec:zig" })));
    try testing.expectEqualStrings("ok", code(try f.call(id1, "always.list", .{})));
    // Outside its own tree the rule does not apply.
    try testing.expectEqualStrings("ok", try f.answerAs(id3, a1));
    // A sub-agent with no `grants` inherits its parent's,
    // and the parent's scope on itself narrows to the child: a2 holds
    // `write` on the workspace, so the self-approval rule stops the child.
    const a4 = try okStr(&f, try f.call(id2, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake" }), "agent");
    const id4 = try f.agentIdentity(a4);
    const self_scope = try std.fmt.allocPrint(f.arena.allocator(), "agent:{s}", .{a2});
    for (f.registry.get(f.principals.principalOf(a4).?).?.grants) |g| try testing.expect(!std.mem.eql(u8, g.scope, self_scope));
    try testing.expectEqualStrings("denied.self_approval", try f.answerAs(id4, a2));
    try testing.expectEqualStrings("denied.self_approval", try f.answerAs(id4, a4));
    // A parent may answer its sub-agent; the human answers anyone.
    try testing.expectEqualStrings("ok", try f.answerAs(id2, a3));
    try testing.expectEqualStrings("ok", try f.answerAs(owner, a2));
    try testing.expectEqualStrings("ok", try f.answerAs(owner, a3));
    try testing.expect(f.principals.mayAnswer(id2.principal, a3));

    // Archiving a2 revokes it, its process and its sub-agent.
    try testing.expectEqualStrings("ok", code(try f.call(owner, "agent.archive", .{ .agent = a2 })));
    try testing.expectEqualStrings("denied.revoked", code(try f.call(id2, "agent.show", .{ .agent = a2 })));
    try testing.expectEqualStrings("denied.revoked", code(try f.call(id3, "agent.show", .{ .agent = a3 })));
    try testing.expectEqualStrings("ok", code(try f.call(id1, "agent.show", .{ .agent = a1 })));
    try testing.expectEqualStrings("denied.revoked", code(try f.call(id4, "agent.show", .{ .agent = a4 })));
    try testing.expect(f.registry.get(f.principals.principalOf(a3).?).?.revoked);
    // Its sub-agents' grants are gone for good: refused, not half promoted.
    try testing.expectEqualStrings("conflict.parent_archived", code(try f.call(owner, "agent.promote", .{ .agent = a3 })));
    try testing.expectEqualStrings(a2, f.engine.state.agents.getPtr(a3).?.parent.?);
}

test "grants: a token an agent issued is still that agent for every sub-agent limit" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const w = try f.path("w");
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{w});
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));
    const lead_grants = .{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } };

    // A plan parent, and a token its harness issued (`grant.issue`).
    const a1 = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .mode = "plan", .grants = lead_grants }), "agent");
    const id1 = try f.agentIdentity(a1);
    const mint = struct {
        fn run(fx: *Fixture, by: grants.Identity, gs: []const grants.Grant) !grants.Identity {
            const issued = try fx.registry.issueChild(by, .{ .grants = gs, .label = "delegated" }, grants.nowSeconds());
            ta.free(issued.token);
            return .{ .principal = issued.principal };
        }
    }.run;
    const wide: []const grants.Grant = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = ws }, .{ .right = .spawn, .scope = ws } };
    const tok = try mint(&f, id1, wide);
    try testing.expectEqualStrings(a1, f.principals.agentOf(tok.principal).?);

    // Mode, model, grants: the parent's limits hold through the token.
    try testing.expectEqualStrings("denied.spawn_mode", code(try f.call(tok, "agent.spawn", .{ .cwd = w, .task = "t", .mode = "accept_edits" })));
    try testing.expectEqualStrings("denied.spawn_model", code(try f.call(tok, "agent.spawn", .{ .cwd = w, .task = "t", .model = "other" })));
    try testing.expectEqualStrings("denied.delegation", code(try f.call(tok, "agent.spawn", .{ .cwd = w, .task = "t", .grants = .{.{ .right = "admin", .scope = "*" }} })));
    // A token cannot give what it does not hold, though its agent could.
    const thin = try mint(&f, id1, &.{ .{ .right = .write, .scope = ws }, .{ .right = .spawn, .scope = ws } });
    const thin_read = try mint(&f, thin, &.{.{ .right = .spawn, .scope = ws }});
    try testing.expectEqualStrings("denied.write", code(try f.call(thin_read, "agent.spawn", .{ .cwd = w, .task = "t" })));

    // Promote: never by an agent, with a token neither.
    const a2 = try okStr(&f, try f.call(tok, "agent.spawn", .{ .cwd = w, .task = "t" }), "agent");
    const child = f.engine.state.agents.getPtr(a2).?;
    try testing.expectEqualStrings(a1, child.parent.?);
    try testing.expectEqualStrings("plan", child.mode.?);
    try testing.expectEqualStrings("denied.promote", code(try f.call(tok, "agent.promote", .{ .agent = a2 })));

    // Depth: a depth-limited child's token cannot start a new tree.
    const id2 = try f.agentIdentity(a2);
    const child_tok = try mint(&f, id2, wide);
    try testing.expectEqualStrings("denied.spawn_depth", code(try f.call(child_tok, "agent.spawn", .{ .cwd = w, .task = "t" })));
    try testing.expectEqualStrings("denied.promote", code(try f.call(child_tok, "agent.promote", .{ .agent = a2 })));

    // A token from elsewhere, used below the agent's harness, is that agent too.
    const outside = try f.token(wide);
    var under = id1;
    under.principal = outside.principal;
    try testing.expectEqualStrings(a1, f.principals.callerAgent(under).?);

    // spawn.allow.
    try testing.expectEqualStrings("ok", code(try f.call(owner, "config.set", .{ .key = "agents.spawn.allow", .value = "false" })));
    _ = try f.store.reload();
    try testing.expectEqualStrings("denied.spawn_disabled", code(try f.call(tok, "agent.spawn", .{ .cwd = w, .task = "t" })));
}

test "grants: harness processes never inherit venom's own credentials" {
    try testing.expect(harness.process.inheritedCredential("VENOM_TOKEN=vnt1.venom.owner.x"));
    try testing.expect(harness.process.inheritedCredential("VENOMX_TOKEN=x"));
    try testing.expect(harness.process.inheritedCredential("VENOM_DESK_TOKEN=x"));
    try testing.expect(harness.process.inheritedCredential("VENOM_PRINCIPAL=g3"));
    try testing.expect(!harness.process.inheritedCredential("VENOM_AGENT=a2"));
    try testing.expect(!harness.process.inheritedCredential("CLAUDE_CODE_OAUTH_TOKEN=x"));
    try testing.expect(!harness.process.inheritedCredential("VENOM_TOKEN"));
}

test "grants: only a person can allow: an agent's allow_once, allow_always and approve are refused and stay pending, from any mode" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const w = try f.path("w");
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{w});
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));
    const lead_grants = .{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } };

    for ([_][]const u8{ "plan", "ask", "accept_edits" }) |mode| {
        const parent = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .mode = mode, .grants = lead_grants }), "agent");
        const id = try f.agentIdentity(parent);
        const child = try okStr(&f, try f.call(id, "agent.spawn", .{ .cwd = w, .task = "t" }), "agent");
        // A token the parent issued is the parent.
        const issued = try f.registry.issueChild(id, .{ .grants = &.{.{ .right = .write, .scope = ws }}, .label = "delegated" }, grants.nowSeconds());
        ta.free(issued.token);
        const delegated: grants.Identity = .{ .principal = issued.principal };

        // The child's turn asks: an approval with a grant to keep, and a plan.
        _ = try f.engine.submit(.{ .record = .{ .turn_started = .{ .agent = child, .turn = "t1", .origin = "user" } } });
        _ = try f.engine.submit(.{ .record = .{ .tool_started = .{ .agent = child, .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build", .args = .{ .command = "zig build" } } } });
        _ = try f.engine.submit(.{ .record = .{ .request = .{ .agent = child, .request = "r1", .kind = "approval", .reason = "run it?", .call = "c1" } } });
        _ = try f.engine.submit(.{ .record = .{ .request = .{ .agent = child, .request = "r2", .kind = "plan", .reason = "the plan" } } });
        try testing.expect(f.engine.state.agents.getPtr(child).?.requests.items[0].grant != null);
        const effects = f.engine.state.effects.count();
        for ([_]grants.Identity{ id, delegated }) |who| {
            for ([_][]const u8{ "allow_once", "allow_always" }) |answer| {
                try testing.expectEqualStrings("denied.agent_approval", code(try f.call(who, "inbox.answer", .{ .agent = child, .request = "r1", .answer = answer })));
                try testing.expectEqualStrings("denied.agent_approval", code(try f.call(who, "inbox.batch", .{ .items = .{.{ .agent = child, .request = "r1" }}, .answer = answer })));
            }
            try testing.expectEqualStrings("denied.agent_approval", code(try f.call(who, "inbox.answer", .{ .agent = child, .request = "r1", .answer = "allow_edited", .args = "{}" })));
            try testing.expectEqualStrings("denied.agent_approval", code(try f.call(who, "inbox.answer", .{ .agent = child, .request = "r2", .answer = "approve" })));
        }
        // Nothing reached the harness, and nothing was kept.
        try testing.expectEqual(effects, f.engine.state.effects.count());
        try testing.expectEqual(@as(usize, 2), f.engine.state.agents.getPtr(child).?.requests.items.len);
        try testing.expectEqual(@as(usize, 0), f.engine.state.standing.items.len);
        // Refusing is fine, and a person can still allow what is left.
        try testing.expectEqualStrings("ok", code(try f.call(id, "inbox.answer", .{ .agent = child, .request = "r2", .answer = "reject" })));
        try testing.expectEqualStrings("ok", code(try f.call(owner, "inbox.answer", .{ .agent = child, .request = "r1", .answer = "allow_once" })));
    }
}

test "grants: a standing allow-always does not answer an agent in plan mode" {
    var state = eventlog.decider.State.init(ta);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(ta);
    defer scratch.deinit();
    const s = scratch.allocator();
    const apply = eventlog.decider.apply;
    for ([_][]const u8{ "a1", "a2" }, [_][]const u8{ "plan", "ask" }) |id, mode| {
        _ = try apply(&state, .{ .create = .{ .agent = id, .title = "t", .harness = "fake", .workspace = "/w", .mode = mode } }, s);
        _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = id, .turn = "t1", .origin = "user" } } }, s);
        _ = try apply(&state, .{ .record = .{ .tool_started = .{ .agent = id, .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build", .args = .{ .command = "zig build" } } } }, s);
    }
    try state.standing.append(state.arena.allocator(), .{ .workspace = "/w", .grant = "exec:zig", .agent = "a0", .request = "r0", .at = 0 });
    for ([_][]const u8{ "a1", "a2" }) |id| _ = try apply(&state, .{ .record = .{ .request = .{ .agent = id, .request = "r1", .kind = "approval", .reason = "run?", .call = "c1" } } }, s);
    // a1 (plan) still waits for a person; a2's was answered by the grant.
    try testing.expectEqual(@as(usize, 1), state.agents.getPtr("a1").?.requests.items.len);
    try testing.expectEqual(@as(usize, 0), state.agents.getPtr("a2").?.requests.items.len);
}

test "grants: agents and their children get nothing through take-over and hooks" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const w = try f.path("w");
    const ws = try std.fmt.allocPrint(a, "workspace:{s}", .{w});
    try testing.expectEqualStrings("ok", code(try f.call(owner, "workspace.add", .{ .path = w })));
    const parent = try okStr(&f, try f.call(owner, "agent.spawn", .{ .cwd = w, .task = "t", .harness = "fake", .grants = .{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = ws }, .{ .right = "spawn", .scope = ws } } }), "agent");
    const id = try f.agentIdentity(parent);
    const child = try okStr(&f, try f.call(id, "agent.spawn", .{ .cwd = w, .task = "t" }), "agent");
    const child_id = try f.agentIdentity(child);
    const issued = try f.registry.issueChild(id, .{ .grants = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = ws } }, .label = "delegated" }, grants.nowSeconds());
    ta.free(issued.token);
    for ([_]grants.Identity{ id, child_id, .{ .principal = issued.principal } }) |who| {
        try testing.expectEqualStrings("denied.agent_caller", code(try f.call(who, "agent.takeover", .{ .agent = child })));
        try testing.expectEqualStrings("denied.agent_caller", code(try f.call(who, "agent.takeover_split", .{ .agent = child, .pid = 2 })));
        try testing.expectEqualStrings("denied.agent_caller", code(try f.call(who, "harness.hook", .{ .agent = child, .input = "{}" })));
    }
}
