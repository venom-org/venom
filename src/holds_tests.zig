//! `tui.hold` and the on-demand lifetime, through a real dispatcher: who may
//! hold, the items' `clients` and `others`, revocation, the linger and the
//! stopping daemon's refusals.
const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const cli = @import("cli");
const g = proto.grants;
const holds_mod = @import("holds.zig");
const Holds = holds_mod.Holds;
const lifecycle = @import("lifecycle.zig");

fn verbNamed(comptime name: []const u8) @TypeOf(@import("verbs.zon").verbs[0]) {
    @setEvalBranchQuota(100_000);
    for (@import("verbs.zon").verbs) |v| if (comptime std.mem.eql(u8, v.name, name)) return v;
    @compileError("no verb " ++ name);
}

const hold_verb = blk: {
    @setEvalBranchQuota(100_000);
    for (@import("verbs.zon").verbs, 0..) |v, i| if (std.mem.eql(u8, v.name, "tui.hold")) break :blk i;
    unreachable;
};

const schema = cli.manifest.normalize(.{ .format = 1, .tool = "venom", .summary = "holds test", .verbs = .{
    @import("verbs.zon").verbs[hold_verb],
    .{ .name = "thing.make", .summary = "A mutation", .grant = .write, .params = .{}, .result = .{ .kind = .object, .fields = .{} } },
    .{ .name = "thing.read", .summary = "A read", .grant = .read, .params = .{}, .result = .{ .kind = .object, .fields = .{} } },
} });

/// Counts the mutations that ran.
const Thing = struct {
    made: usize = 0,
    pub fn call(self: *Thing, c: *proto.Call) anyerror!void {
        if (c.verb.grant == .write) self.made += 1;
        return c.ok(struct {}{});
    }
};

var test_now: i64 = 0;
fn clock() i64 {
    return test_now;
}

const Fixture = struct {
    registry: g.Registry,
    holds: Holds,
    thing: Thing = .{},
    gated: [3]holds_mod.Gated = undefined,
    dispatcher: proto.Dispatcher,
    front: holds_mod.Front,

    fn init(self: *Fixture, lifetime: lifecycle.Lifetime) !void {
        test_now = 0;
        self.registry = try g.Registry.init(testing.allocator, "venom", .{ .isolation = true });
        self.holds = .{ .gpa = testing.allocator, .registry = &self.registry, .state = .{ .lifetime = lifetime, .origin = .interactive }, .clock = clock };
        self.thing = .{};
        const bindings = [_]proto.Binding{
            .{ .verb = "tui.hold", .handler = proto.VerbHandler.init(&self.holds) },
            .{ .verb = "thing.make", .handler = proto.VerbHandler.init(&self.thing) },
            .{ .verb = "thing.read", .handler = proto.VerbHandler.init(&self.thing) },
        };
        const gated = holds_mod.gate(3, bindings, &self.holds, &self.gated);
        self.dispatcher = try proto.Dispatcher.init(testing.allocator, &schema, &gated, .{}, null);
        self.front = .{ .dispatcher = &self.dispatcher, .holds = &self.holds };
        self.holds.ready();
    }
    fn deinit(self: *Fixture) void {
        self.dispatcher.deinit();
        self.holds.deinit();
        self.registry.deinit();
    }
};

fn connection(f: *Fixture, principal: g.Id) proto.Connection {
    var conn = proto.Connection.init(testing.allocator, -1);
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &f.registry;
    conn.identity = .{ .principal = principal };
    return conn;
}

fn send(f: *Fixture, conn: *proto.Connection, line: []const u8) !void {
    try f.dispatcher.message(conn, .{ .ndjson = line });
}

fn has(conn: *const proto.Connection, needle: []const u8) bool {
    return std.mem.indexOf(u8, conn.output.items, needle) != null;
}

fn issue(f: *Fixture, namespace: ?[]const u8, kind: g.Kind, parent: g.Id, root: ?proto.process.Ref) !g.Id {
    const caller: g.Identity = .{ .principal = parent };
    const got = try f.registry.issueChild(caller, .{ .kind = kind, .grants = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" } }, .namespace = namespace, .root = root, .label = "test" }, g.nowSeconds());
    testing.allocator.free(got.token);
    return got.principal;
}

test "holds: only the owner and person principals may hold" {
    var f: Fixture = undefined;
    try f.init(.on_demand);
    defer f.deinit();
    var owner = connection(&f, g.owner);
    defer owner.deinit();
    try send(&f, &owner, "{\"id\":1,\"verb\":\"tui.hold\"}");
    try testing.expect(has(&owner, "{\"id\":1,\"item\":{\"lifetime\":\"on-demand\",\"origin\":\"interactive\",\"phase\":\"active\",\"clients\":1,\"others\":0}}"));
    // An unknown caller has `read` but may not hold.
    var unknown = connection(&f, g.unknown);
    defer unknown.deinit();
    try send(&f, &unknown, "{\"id\":2,\"verb\":\"tui.hold\"}");
    try testing.expect(has(&unknown, "\"denied.tui_hold\""));
    // Nor may an agent's token, which is never `person`.
    const agent = try issue(&f, null, .token, g.owner, null);
    var ag = connection(&f, agent);
    defer ag.deinit();
    try send(&f, &ag, "{\"id\":3,\"verb\":\"tui.hold\"}");
    try testing.expect(has(&ag, "\"denied.tui_hold\""));
    try testing.expectEqual(@as(usize, 1), f.holds.count());
    // A person token holds, and the owner sees one other client.
    const person = try issue(&f, "person", .token, g.owner, null);
    var p = connection(&f, person);
    defer p.deinit();
    owner.output.clearRetainingCapacity();
    try send(&f, &p, "{\"id\":4,\"verb\":\"tui.hold\"}");
    try testing.expect(has(&p, "\"clients\":2,\"others\":1"));
    try testing.expect(has(&owner, "\"clients\":2,\"others\":1"));
    // Its revocation ends its hold with denied.revoked, and the count drops.
    try f.registry.revoke(.{ .principal = g.owner }, person, g.nowSeconds());
    try f.front.tick();
    try testing.expect(has(&p, "\"denied.revoked\""));
    try testing.expect(has(&owner, "\"clients\":1,\"others\":0"));
    try testing.expectEqual(lifecycle.Phase.active, f.holds.state.phase);
}

test "holds: the views bound below a control pane end with it" {
    var f: Fixture = undefined;
    try f.init(.on_demand);
    defer f.deinit();
    const chain = proto.process.walk(std.c.getpid(), 0);
    try testing.expect(chain.len >= 2);
    const control = try issue(&f, "person", .process, g.owner, chain.refs[0]);
    const view = try issue(&f, "person", .process, control, chain.refs[1]);
    var cp = connection(&f, control);
    defer cp.deinit();
    var vw = connection(&f, view);
    defer vw.deinit();
    try send(&f, &cp, "{\"id\":1,\"verb\":\"tui.hold\"}");
    try send(&f, &vw, "{\"id\":1,\"verb\":\"tui.hold\"}");
    // The control pane's view: two clients, none that outlive it.
    try testing.expect(has(&cp, "\"clients\":2,\"others\":0"));
    // The view's: the control pane outlives it.
    try testing.expect(has(&vw, "\"clients\":2,\"others\":1"));
}

test "holds: the linger stops the daemon, and a stopping daemon starts nothing" {
    var f: Fixture = undefined;
    try f.init(.on_demand);
    defer f.deinit();
    var stopped = false;
    f.holds.on_stopping = .{ .ctx = &stopped, .run = struct {
        fn run(ctx: *anyopaque) void {
            @as(*bool, @ptrCast(@alignCast(ctx))).* = true;
        }
    }.run };
    var owner = connection(&f, g.owner);
    try send(&f, &owner, "{\"id\":1,\"verb\":\"tui.hold\"}");
    // The TUI quits: its connection closes.
    f.dispatcher.closed(&owner);
    owner.deinit();
    test_now = 1000;
    try f.front.tick();
    try testing.expectEqual(lifecycle.Phase.lingering, f.holds.state.phase);
    // Verbs and reads do not extend the linger.
    var cli_conn = connection(&f, g.owner);
    defer cli_conn.deinit();
    try send(&f, &cli_conn, "{\"id\":2,\"verb\":\"thing.read\"}");
    test_now = 1000 + lifecycle.wait_ms - 1;
    try f.front.tick();
    try testing.expect(!f.holds.state.stopping());
    test_now = 1000 + lifecycle.wait_ms;
    try f.front.tick();
    try testing.expect(f.holds.state.stopping());
    try testing.expect(stopped);
    // A hold now fails, and a mutation fails after authorization, without
    // effect; a read still answers.
    cli_conn.output.clearRetainingCapacity();
    try send(&f, &cli_conn, "{\"id\":3,\"verb\":\"tui.hold\"}");
    try testing.expect(has(&cli_conn, "\"unavailable.shutdown\""));
    try send(&f, &cli_conn, "{\"id\":4,\"verb\":\"thing.make\"}");
    try testing.expectEqual(@as(usize, 0), f.thing.made);
    var unknown = connection(&f, g.unknown);
    defer unknown.deinit();
    try send(&f, &unknown, "{\"id\":5,\"verb\":\"thing.make\"}");
    try testing.expect(has(&unknown, "\"denied.write\""));
    cli_conn.output.clearRetainingCapacity();
    try send(&f, &cli_conn, "{\"id\":6,\"verb\":\"thing.read\"}");
    try testing.expect(has(&cli_conn, "{\"id\":6,\"ok\":{}}"));
}

test "holds: a hold within the linger keeps the daemon; a signal ends every hold" {
    var f: Fixture = undefined;
    try f.init(.on_demand);
    defer f.deinit();
    // Nobody held within the first-client grace: still waiting at 4999 ms.
    test_now = lifecycle.wait_ms - 1;
    try f.front.tick();
    try testing.expectEqual(lifecycle.Phase.awaiting_first_client, f.holds.state.phase);
    var a = connection(&f, g.owner);
    defer a.deinit();
    try send(&f, &a, "{\"id\":1,\"verb\":\"tui.hold\"}");
    try testing.expectEqual(lifecycle.Phase.active, f.holds.state.phase);
    test_now = 100_000;
    try f.front.tick();
    try testing.expectEqual(lifecycle.Phase.active, f.holds.state.phase);
    try f.holds.stop();
    try testing.expect(has(&a, "{\"id\":1,\"error\":{\"code\":\"unavailable.shutdown\""));
    try testing.expectEqual(@as(usize, 0), f.holds.count());
}

test "holds: the last hold ending on a failed item starts the linger" {
    var f: Fixture = undefined;
    try f.init(.on_demand);
    defer f.deinit();
    var a = connection(&f, g.owner);
    defer a.deinit();
    var b = connection(&f, g.owner);
    try send(&f, &a, "{\"id\":1,\"verb\":\"tui.hold\"}");
    try send(&f, &b, "{\"id\":1,\"verb\":\"tui.hold\"}");
    try testing.expectEqual(@as(usize, 2), f.holds.count());
    // `a` stops reading: its next item (clients 1 once `b` is gone) fails.
    a.output_limit = a.output.items.len - a.sent;
    f.dispatcher.closed(&b);
    b.deinit();
    test_now = 1000;
    try f.front.tick();
    try testing.expectEqual(@as(usize, 0), f.holds.count());
    try testing.expectEqual(lifecycle.Phase.lingering, f.holds.state.phase);
    test_now = 1000 + lifecycle.wait_ms;
    try f.front.tick();
    try testing.expect(f.holds.state.stopping());
}

test "holds: a persistent daemon counts holds and never stops on them" {
    var f: Fixture = undefined;
    try f.init(.persistent);
    defer f.deinit();
    var a = connection(&f, g.owner);
    try send(&f, &a, "{\"id\":1,\"verb\":\"tui.hold\"}");
    try testing.expect(has(&a, "\"lifetime\":\"persistent\""));
    try testing.expectEqual(@as(usize, 1), f.holds.count());
    f.dispatcher.closed(&a);
    a.deinit();
    test_now = 1_000_000;
    try f.front.tick();
    try testing.expectEqual(lifecycle.Phase.active, f.holds.state.phase);
    try testing.expectEqual(@as(usize, 0), f.holds.count());
}

comptime {
    _ = verbNamed;
}
