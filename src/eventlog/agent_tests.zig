//! The agent state machine on the event log:
//! every diagram edge, every other edge rejected, unread, and
//! `agents.archive_after` with an injected clock.
const std = @import("std");
const proto = @import("proto");
const eventlog = @import("root.zig");
const decider = eventlog.decider;
const model = eventlog.agent;
const AgentState = model.State;
const Edge = model.Edge;
const State = decider.State;
const Event = eventlog.Event;
const testing = std.testing;

const Fixture = struct {
    state: State,
    scratch: std.heap.ArenaAllocator,
    turns: usize = 0,

    fn init() Fixture {
        return .{ .state = State.init(testing.allocator), .scratch = .init(testing.allocator) };
    }
    fn deinit(self: *Fixture) void {
        self.scratch.deinit();
        self.state.deinit();
    }
    fn s(self: *Fixture) std.mem.Allocator {
        return self.scratch.allocator();
    }
    fn agent(self: *Fixture, id: []const u8) decider.Agent {
        return self.state.agents.get(id).?;
    }
    /// Decides `cmd` and returns the events, folding them in on success.
    fn run(self: *Fixture, cmd: eventlog.Command) ![]const Event {
        var out: std.ArrayList(Event) = .empty;
        try decider.decide(&self.state, cmd, 1000, self.s(), &out);
        for (out.items) |e| try decider.evolve(&self.state, e);
        return out.items;
    }
    fn turn(self: *Fixture) ![]const u8 {
        self.turns += 1;
        return std.fmt.allocPrint(self.s(), "t{d}", .{self.turns});
    }
    fn openTurn(self: *Fixture, id: []const u8) ![]const u8 {
        return self.agent(id).open_turn orelse error.NoOpenTurn;
    }

    fn startTurn(self: *Fixture, id: []const u8) ![]const Event {
        return self.run(.{ .record = .{ .turn_started = .{ .agent = id, .turn = try self.turn(), .origin = "user" } } });
    }
    fn endTurn(self: *Fixture, id: []const u8, reason: []const u8) ![]const Event {
        return self.run(.{ .record = .{ .turn_ended = .{ .agent = id, .turn = try self.openTurn(id), .reason = reason } } });
    }
    fn ask(self: *Fixture, id: []const u8, request: []const u8) ![]const Event {
        return self.run(.{ .record = .{ .request = .{ .agent = id, .request = request, .kind = "approval", .reason = "run zig build?" } } });
    }

    /// Takes the agent along the edge with the entry point that drives it.
    fn drive(self: *Fixture, id: []const u8, e: Edge) ![]const Event {
        return switch (e.to) {
            .running => switch (e.from) {
                .needs_you => self.run(.{ .answer = .{ .agent = id, .request = "r1", .decision = "allow" } }),
                else => self.startTurn(id),
            },
            .needs_you => self.ask(id, "r1"),
            .settled => switch (e.from) {
                .running => self.endTurn(id, "completed"),
                // The stop edges: the queue is left at once; a blocked
                // turn settles when its interrupt ends it.
                .queued => self.run(.{ .stop = .{ .agent = id } }),
                .needs_you => blk: {
                    _ = try self.run(.{ .stop = .{ .agent = id } });
                    break :blk self.endTurn(id, "interrupted");
                },
                else => self.run(.{ .transition = .{ .agent = id, .to = .settled } }),
            },
            .failed => self.endTurn(id, "failed"),
            .archived, .handed_over => self.run(.{ .transition = .{ .agent = id, .to = e.to } }),
            .queued => unreachable,
        };
    }

    /// Creates `id` and walks it to `target` along diagram edges.
    fn reach(self: *Fixture, id: []const u8, target: AgentState) !void {
        _ = try self.run(.{ .create = .{ .agent = id, .title = "task", .harness = "claude-code", .workspace = "/w" } });
        const path: []const AgentState = switch (target) {
            .queued => &.{},
            .running => &.{.running},
            .needs_you => &.{ .running, .needs_you },
            .settled => &.{ .running, .settled },
            .failed => &.{ .running, .failed },
            .handed_over => &.{ .running, .settled, .handed_over },
            .archived => &.{ .running, .settled, .archived },
        };
        for (path) |to| _ = try self.drive(id, .{ .from = self.agent(id).state, .to = to });
        try testing.expectEqual(target, self.agent(id).state);
    }
};

fn lastChange(events: []const Event) ?eventlog.events.AgentStateChanged {
    var i = events.len;
    while (i > 0) {
        i -= 1;
        if (events[i] == .agent_state_changed) return events[i].agent_state_changed;
    }
    return null;
}

test "agents: a new agent is queued with its attributes" {
    var f = Fixture.init();
    defer f.deinit();
    const out = try f.run(.{ .create = .{ .agent = "a1", .title = "Add hello", .harness = "codex", .workspace = "/w", .repos = &.{"venom-std"}, .parent = "a0", .harness_session = "6f1c" } });
    try testing.expectEqual(@as(usize, 1), out.len);
    const a1 = f.agent("a1");
    try testing.expectEqual(AgentState.queued, a1.state);
    try testing.expectEqualStrings("Add hello", a1.title);
    try testing.expectEqualStrings("venom-std", a1.repos[0]);
    try testing.expectEqualStrings("a0", a1.parent.?);
    try testing.expectEqualStrings("6f1c", a1.harness_session.?);
    try testing.expectEqual(@as(i64, 1000), a1.created_at);
    try testing.expect(!a1.unread);
    try testing.expectError(error.Conflict, f.run(.{ .create = .{ .agent = "a1", .title = "x", .harness = "codex", .workspace = "/w" } }));
    try testing.expectError(error.InvalidCommand, f.run(.{ .create = .{ .agent = "", .title = "x", .harness = "codex", .workspace = "/w" } }));
    // Agent records only come from their commands.
    try testing.expectError(error.InvalidCommand, f.run(.{ .record = .{ .agent_state_changed = .{ .agent = "a1", .from = .queued, .to = .running } } }));
    try testing.expectError(error.InvalidCommand, f.run(.{ .record = .{ .agent_created = .{ .agent = "a2", .title = "x", .harness = "codex", .workspace = "/w" } } }));
}

test "agents: every edge of the agent state diagram" {
    for (model.edges) |e| {
        var f = Fixture.init();
        defer f.deinit();
        try f.reach("a1", e.from);
        const out = try f.drive("a1", e);
        const change = lastChange(out) orelse return error.NoStateChange;
        try testing.expectEqualStrings("a1", change.agent);
        try testing.expectEqual(e.from, change.from);
        try testing.expectEqual(e.to, change.to);
        try testing.expectEqual(e.to, f.agent("a1").state);
        // One record per state change, and only diagram edges on the way.
        for (out) |ev| if (ev == .agent_state_changed) try testing.expect(model.allowed(ev.agent_state_changed.from, ev.agent_state_changed.to));
    }
}

test "agents: every other transition is rejected with conflict.invalid_transition" {
    var rejected: usize = 0;
    for (std.enums.values(AgentState)) |from| for (std.enums.values(AgentState)) |to| {
        if (model.allowed(from, to)) continue;
        var f = Fixture.init();
        defer f.deinit();
        try f.reach("a1", from);
        const before = try f.state.render(testing.allocator);
        defer testing.allocator.free(before);
        try testing.expectError(error.InvalidTransition, f.run(.{ .transition = .{ .agent = "a1", .to = to } }));
        if (to == .running) try testing.expectError(error.InvalidTransition, f.startTurn("a1"));
        const after = try f.state.render(testing.allocator);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
        rejected += 1;
    };
    try testing.expectEqual(@as(usize, 7 * 7 - model.edges.len), rejected);
    try testing.expectEqualStrings("conflict.invalid_transition", decider.errorCode(error.InvalidTransition));
    // Turn-driven edges are not available through `transition`.
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .running);
    try testing.expectError(error.InvalidCommand, f.run(.{ .transition = .{ .agent = "a1", .to = .settled } }));
    try testing.expectError(error.NotFound, f.run(.{ .transition = .{ .agent = "nope", .to = .archived } }));
}

test "agents: needs_you stays until the last live request is resolved" {
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .running);
    _ = try f.ask("a1", "r1");
    try testing.expect(lastChange(try f.ask("a1", "r2")) == null);
    try testing.expect(lastChange(try f.run(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow" } })) == null);
    try testing.expectEqual(AgentState.needs_you, f.agent("a1").state);
    const out = try f.run(.{ .record = .{ .request_resolved = .{ .agent = "a1", .request = "r2", .by = "harness" } } });
    try testing.expectEqual(AgentState.running, lastChange(out).?.to);
}

test "agents: a settled agent is unread until opened" {
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .running);
    try testing.expectEqual(@as(usize, 0), (try f.run(.{ .open = .{ .agent = "a1" } })).len);
    _ = try f.endTurn("a1", "completed");
    try testing.expect(f.agent("a1").unread);
    try testing.expectEqual(@as(usize, 1), (try f.run(.{ .open = .{ .agent = "a1" } })).len);
    try testing.expect(!f.agent("a1").unread);
    // Opening twice changes nothing.
    try testing.expectEqual(@as(usize, 0), (try f.run(.{ .open = .{ .agent = "a1" } })).len);
    // A new prompt, then settled again: unread again.
    _ = try f.startTurn("a1");
    try testing.expect(!f.agent("a1").unread);
    _ = try f.endTurn("a1", "interrupted");
    try testing.expect(f.agent("a1").unread);
    // Back from the harness's own TUI the user has just seen it.
    _ = try f.run(.{ .transition = .{ .agent = "a1", .to = .handed_over } });
    _ = try f.run(.{ .transition = .{ .agent = "a1", .to = .settled } });
    try testing.expect(!f.agent("a1").unread);
    try testing.expectError(error.NotFound, f.run(.{ .open = .{ .agent = "nope" } }));
}

const FakeClock = struct {
    now: i64,
    fn read(ptr: ?*anyopaque) i64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr.?));
        return self.now;
    }
    fn clock(self: *FakeClock) eventlog.Clock {
        return .{ .ptr = self, .nowFn = read };
    }
};

test "agents: archive_after archives settled agents (injected clock), keeps the transcript and publishes the change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, eventlog.file_name });
    defer testing.allocator.free(path);

    const day: i64 = 86_400_000;
    const archive_after: u64 = try @import("../config.zig").Duration.parseMs("3d");
    var clock: FakeClock = .{ .now = 10 * day };
    var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
    defer log.deinit();
    log.catalog = &eventlog.catalog.entries;
    {
        var engine = try eventlog.Engine.open(testing.allocator, path, .{ .events = &log, .clock = clock.clock() });
        defer engine.deinit();
        try engine.start();
        for ([_][]const u8{ "a1", "a2", "a3" }) |id| {
            _ = try engine.submit(.{ .create = .{ .agent = id, .title = "task", .harness = "claude-code", .workspace = "/w" } });
            _ = try engine.submit(.{ .record = .{ .turn_started = .{ .agent = id, .turn = "t1", .origin = "user" } } });
        }
        _ = try engine.submit(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } } });
        _ = try engine.submit(.{ .record = .{ .turn_ended = .{ .agent = "a3", .turn = "t1", .reason = "limit" } } });
        clock.now += day;
        _ = try engine.submit(.{ .record = .{ .turn_ended = .{ .agent = "a2", .turn = "t1", .reason = "completed" } } });

        // Just before a1's deadline nothing is archived and nothing is logged.
        clock.now = 13 * day - 1;
        const commits = engine.store.commits;
        try testing.expectEqual(@as(usize, 0), try engine.sweep(archive_after));
        try testing.expectEqual(commits, engine.store.commits);

        const high = log.high;
        clock.now = 13 * day;
        try testing.expectEqual(@as(usize, 1), try engine.sweep(archive_after));
        const a1 = engine.state.agents.get("a1").?;
        try testing.expectEqual(AgentState.archived, a1.state);
        try testing.expectEqual(@as(usize, 2), a1.transcript.items.len);
        try testing.expectEqual(AgentState.settled, engine.state.agents.get("a2").?.state);
        // Failed agents are not archived automatically.
        try testing.expectEqual(AgentState.failed, engine.state.agents.get("a3").?.state);
        // agent.state_changed, and the unread review cleared.
        try testing.expectEqual(high + 2, log.high);
        try testing.expectEqual(@as(usize, 0), try engine.sweep(archive_after));

        clock.now = 14 * day;
        try testing.expectEqual(@as(usize, 1), try engine.sweep(archive_after));
        try testing.expectEqual(AgentState.archived, engine.state.agents.get("a2").?.state);
    }
    // The archive is durable: the replayed state keeps it.
    var engine = try eventlog.Engine.open(testing.allocator, path, .{ .clock = clock.clock() });
    defer engine.deinit();
    try testing.expectEqual(AgentState.archived, engine.state.agents.get("a1").?.state);
    try testing.expectEqual(@as(i64, 13 * day), engine.state.agents.get("a1").?.changed_at);
    try testing.expectEqual(AgentState.archived, engine.state.agents.get("a2").?.state);
}

fn changes(a: std.mem.Allocator, events: []const Event) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (events) |e| if (e == .agent_state_changed) try out.append(a, try std.fmt.allocPrint(a, "{s}>{s}", .{ @tagName(e.agent_state_changed.from), @tagName(e.agent_state_changed.to) }));
    return out.items;
}

fn expectChanges(f: *Fixture, want: []const []const u8, events: []const Event) !void {
    const got = try changes(f.s(), events);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "agents: stop of a queued agent settles it without a turn, not unread" {
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .queued);
    const out = try f.run(.{ .stop = .{ .agent = "a1" } });
    try expectChanges(&f, &.{"queued>settled"}, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    const a1 = f.agent("a1");
    try testing.expectEqual(AgentState.settled, a1.state);
    try testing.expect(!a1.unread);
    try testing.expectEqual(@as(u32, 0), a1.turns);
    try testing.expectEqual(@as(usize, 0), f.state.effects.count());
}

test "agents: stop of a running agent interrupts its turn through the outbox; turn.ended settles it" {
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .running);
    const out = try f.run(.{ .stop = .{ .agent = "a1" } });
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("t1", out[0].agent_stop_requested.turn);
    try testing.expect(!out[0].agent_stop_requested.archive);
    try testing.expectEqualStrings("harness.stop", out[1].effect_requested.kind);
    try testing.expectEqualStrings("stop:a1:t1", out[1].effect_requested.key);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"turn\":\"t1\"}", out[1].effect_requested.payload);
    // Still running until the harness ends the turn; stopping again is a no-op.
    try testing.expectEqual(AgentState.running, f.agent("a1").state);
    try testing.expectEqual(@as(usize, 0), (try f.run(.{ .stop = .{ .agent = "a1" } })).len);
    try expectChanges(&f, &.{"running>settled"}, try f.endTurn("a1", "interrupted"));
    const a1 = f.agent("a1");
    try testing.expect(a1.unread);
    try testing.expect(a1.stopping == null);
    // The next turn can be stopped again, with a new effect key.
    _ = try f.startTurn("a1");
    const again = try f.run(.{ .stop = .{ .agent = "a1" } });
    try testing.expectEqualStrings("stop:a1:t2", again[again.len - 1].effect_requested.key);
}

test "agents: stop of a needs_you agent clears its requests by stop, and the interrupted turn settles it directly" {
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .needs_you);
    _ = try f.ask("a1", "r2");
    const out = try f.run(.{ .stop = .{ .agent = "a1" } });
    try testing.expectEqual(@as(usize, 4), out.len);
    for (out[0..2], [_][]const u8{ "r1", "r2" }) |e, r| {
        try testing.expectEqualStrings(r, e.request_resolved.request);
        try testing.expectEqualStrings("stop", e.request_resolved.by);
    }
    try testing.expect(out[2] == .agent_stop_requested);
    try testing.expectEqualStrings("harness.stop", out[3].effect_requested.kind);
    try testing.expectEqual(@as(usize, 0), f.agent("a1").requests.items.len);
    // No inbox item left, but the turn is still open until it ends.
    try testing.expectEqual(AgentState.needs_you, f.agent("a1").state);
    const end = try f.endTurn("a1", "interrupted");
    // No request is closed twice, and only the stop edge is taken.
    for (end) |e| try testing.expect(e != .request_resolved);
    try expectChanges(&f, &.{"needs_you>settled"}, end);
    try testing.expect(f.agent("a1").unread);
}

test "agents: stop of settled, failed and archived agents decides nothing; handed_over is conflict.agent_handed_over" {
    for ([_]AgentState{ .settled, .failed, .archived }) |s| {
        var f = Fixture.init();
        defer f.deinit();
        try f.reach("a1", s);
        try testing.expectEqual(@as(usize, 0), (try f.run(.{ .stop = .{ .agent = "a1" } })).len);
        try testing.expectEqual(s, f.agent("a1").state);
    }
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .handed_over);
    try testing.expectError(error.HandedOver, f.run(.{ .stop = .{ .agent = "a1" } }));
    try testing.expectError(error.HandedOver, f.run(.{ .archive = .{ .agent = "a1" } }));
    try testing.expectEqualStrings("conflict.agent_handed_over", decider.errorCode(error.HandedOver));
    try testing.expectEqual(AgentState.handed_over, f.agent("a1").state);
    try testing.expectError(error.NotFound, f.run(.{ .stop = .{ .agent = "nope" } }));
    try testing.expectError(error.NotFound, f.run(.{ .archive = .{ .agent = "nope" } }));
    // `agent.stop_requested` only comes from the commands.
    try testing.expectError(error.InvalidCommand, f.run(.{ .record = .{ .agent_stop_requested = .{ .agent = "a1", .turn = "t1" } } }));
}

test "agents: archive of a live agent is a stop, then settled → archived (two transitions)" {
    {
        var f = Fixture.init();
        defer f.deinit();
        try f.reach("a1", .queued);
        try expectChanges(&f, &.{ "queued>settled", "settled>archived" }, try f.run(.{ .archive = .{ .agent = "a1" } }));
        try testing.expectEqual(AgentState.archived, f.agent("a1").state);
        try testing.expectEqual(@as(usize, 0), (try f.run(.{ .archive = .{ .agent = "a1" } })).len);
    }
    for ([_]AgentState{ .running, .needs_you }) |s| {
        var f = Fixture.init();
        defer f.deinit();
        try f.reach("a1", s);
        const out = try f.run(.{ .archive = .{ .agent = "a1" } });
        try expectChanges(&f, &.{}, out);
        try testing.expect(lastStop(out).?.archive);
        try expectChanges(&f, if (s == .running) &.{ "running>settled", "settled>archived" } else &.{ "needs_you>settled", "settled>archived" }, try f.endTurn("a1", "interrupted"));
        try testing.expectEqual(AgentState.archived, f.agent("a1").state);
        try testing.expect(!f.agent("a1").archive_on_stop);
    }
    for ([_]AgentState{ .settled, .failed }) |s| {
        var f = Fixture.init();
        defer f.deinit();
        try f.reach("a1", s);
        try expectChanges(&f, &.{if (s == .settled) "settled>archived" else "failed>archived"}, try f.run(.{ .archive = .{ .agent = "a1" } }));
    }
    // A stop already in flight becomes an archive without a second effect.
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .running);
    _ = try f.run(.{ .stop = .{ .agent = "a1" } });
    const upgrade = try f.run(.{ .archive = .{ .agent = "a1" } });
    try testing.expectEqual(@as(usize, 1), upgrade.len);
    try testing.expect(upgrade[0].agent_stop_requested.archive);
    try testing.expectEqual(@as(usize, 0), (try f.run(.{ .archive = .{ .agent = "a1" } })).len);
    try testing.expectEqual(@as(usize, 1), f.state.effects.count());
    try expectChanges(&f, &.{ "running>settled", "settled>archived" }, try f.endTurn("a1", "interrupted"));
}

fn lastStop(events: []const Event) ?eventlog.events.AgentStopRequested {
    for (events) |e| if (e == .agent_stop_requested) return e.agent_stop_requested;
    return null;
}

test "agents: a restart keeps handed_over agents whose take-over pane still runs, and takes back the rest" {
    var f = Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "a1", "a2", "a3" }) |id| try f.reach(id, .handed_over);
    // Host mode records the split's pane; own mode has none.
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "claude-code", .harness_session = "s1", .mode = "tui", .pane = "p1" } } });
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a2", .harness = "claude-code", .harness_session = "s2", .mode = "tui", .pane = "p2" } } });
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a3", .harness = "claude-code", .harness_session = "s3", .mode = "tui" } } });
    try testing.expectEqualStrings("p1", f.agent("a1").pane.?);

    // p1 is still running; p2 is gone (or exited).
    const out = try f.run(.{ .start = .{ .panes = &.{ "p1", "p9" } } });
    try expectChanges(&f, &.{ "handed_over>settled", "handed_over>settled" }, out);
    try testing.expectEqual(AgentState.handed_over, f.agent("a1").state);
    try testing.expectEqualStrings("p1", f.agent("a1").pane.?);
    for ([_][]const u8{ "a2", "a3" }) |id| {
        const ag = f.agent(id);
        try testing.expectEqual(AgentState.settled, ag.state);
        try testing.expect(ag.pane == null);
        // Unread only once take back imports a turn.
        try testing.expect(!ag.unread);
    }
    const keys = f.state.effects.keys();
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("takeback:a2:1", keys[0]);
    try testing.expectEqualStrings("harness.takeback", f.state.effects.get(keys[0]).?.kind);
    // `since`: when a3 was handed over (catch-up imports from then on).
    try testing.expectEqualStrings("{\"agent\":\"a3\",\"since\":1000}", f.state.effects.get(keys[1]).?.payload);

    // Back in protocol mode the pane is forgotten. An unreachable venomx
    // (no live panes) takes a1 back at the next start.
    const back = try f.run(.{ .start = .{} });
    try expectChanges(&f, &.{"handed_over>settled"}, back);
    try testing.expectEqualStrings("takeback:a1:2", back[back.len - 1].effect_requested.key);
    try testing.expect(f.agent("a1").pane == null);
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "claude-code", .harness_session = "s1", .mode = "protocol", .pane = "p1" } } });
    try testing.expect(f.agent("a1").pane == null);
}

test "agents: takeover only between turns; takeback settles the agent and queues the catch-up" {
    var f = Fixture.init();
    defer f.deinit();
    try f.reach("a1", .running);
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "claude-code", .harness_session = "s1", .cwd = "/w/wt" } } });
    // Mid-turn: the TUI asks first (after this turn, interrupt now, cancel).
    try testing.expectError(error.TurnRunning, f.run(.{ .takeover = .{ .agent = "a1" } }));
    try testing.expectEqualStrings("conflict.turn_running", decider.errorCode(error.TurnRunning));
    _ = try f.endTurn("a1", "completed");

    const over = try f.run(.{ .takeover = .{ .agent = "a1", .pane = "p7" } });
    try testing.expectEqual(@as(usize, 2), over.len);
    const b = over[0].agent_binding;
    try testing.expectEqualStrings("tui", b.mode);
    try testing.expectEqualStrings("s1", b.harness_session.?);
    try testing.expectEqualStrings("p7", b.pane.?);
    try expectChanges(&f, &.{"settled>handed_over"}, over);
    try testing.expectEqualStrings("p7", f.agent("a1").pane.?);
    try testing.expectError(error.HandedOver, f.run(.{ .takeover = .{ .agent = "a1" } }));
    try testing.expectError(error.HandedOver, f.run(.{ .stop = .{ .agent = "a1" } }));

    const back = try f.run(.{ .takeback = .{ .agent = "a1" } });
    try expectChanges(&f, &.{"handed_over>settled"}, back);
    const effect = back[back.len - 1].effect_requested;
    try testing.expectEqualStrings("harness.takeback", effect.kind);
    try testing.expectEqualStrings("takeback:a1:@1000", effect.key);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"since\":1000}", effect.payload);
    try testing.expect(f.agent("a1").pane == null);
    try testing.expect(!f.agent("a1").unread);
    // The split's exit and `T` may both ask: a settled agent decides nothing.
    try testing.expectEqual(@as(usize, 0), (try f.run(.{ .takeback = .{ .agent = "a1" } })).len);
    // A turn imported by the catch-up makes the agent unread.
    _ = try f.run(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t9", .origin = "catch_up" } } });
    _ = try f.endTurn("a1", "completed");
    try testing.expect(f.agent("a1").unread);

    try f.reach("a2", .failed);
    try testing.expectError(error.InvalidTransition, f.run(.{ .takeover = .{ .agent = "a2" } }));
    try testing.expectError(error.InvalidTransition, f.run(.{ .takeback = .{ .agent = "a2" } }));
    try testing.expectError(error.NotFound, f.run(.{ .takeover = .{ .agent = "a9" } }));
}

test "agents: agent.created is published with the initial state before any agent.state_changed; stop clears attention by stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, eventlog.file_name });
    defer testing.allocator.free(path);
    var log = try proto.events.Log.init(testing.allocator, "venom", .{}, null);
    defer log.deinit();
    log.catalog = &eventlog.catalog.entries;
    var engine = try eventlog.Engine.open(testing.allocator, path, .{ .events = &log });
    defer engine.deinit();
    try engine.start();
    _ = try engine.submit(.{ .create = .{ .agent = "a2", .title = "Sub", .harness = "codex", .workspace = "/w", .repos = &.{ "venom-term", "venom-std" }, .parent = "a1" } });
    _ = try engine.submit(.{ .record = .{ .turn_started = .{ .agent = "a2", .turn = "t1", .origin = "user" } } });
    _ = try engine.submit(.{ .record = .{ .request = .{ .agent = "a2", .request = "r1", .kind = "approval", .reason = "x" } } });
    _ = try engine.submit(.{ .stop = .{ .agent = "a2" } });
    try testing.expectError(error.InvalidCommand, engine.submit(.{ .create = .{ .agent = "a3", .title = "x", .harness = "codex", .workspace = "/w", .state = .running } }));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var types: std.ArrayList([]const u8) = .empty;
    var first: ?std.json.ObjectMap = null;
    var cleared_by: ?[]const u8 = null;
    for (log.entries.items[log.head..]) |entry| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, entry.bytes, .{});
        const t = v.object.get("type").?.string;
        try types.append(a, t);
        if (first == null) first = v.object.get("data").?.object;
        if (std.mem.eql(u8, t, "agent.attention_cleared")) cleared_by = v.object.get("data").?.object.get("by").?.string;
    }
    try testing.expectEqualStrings("agent.created", types.items[0]);
    try testing.expectEqualStrings("a2", first.?.get("agent").?.string);
    try testing.expectEqualStrings("a1", first.?.get("parent").?.string);
    try testing.expectEqualStrings("queued", first.?.get("state").?.string);
    try testing.expectEqualStrings("venom-std", first.?.get("repos").?.array.items[1].string);
    try testing.expectEqualStrings("stop", cleared_by.?);
    // The internal stop record is not published.
    for (types.items) |t| try testing.expect(!std.mem.eql(u8, t, "agent.stop_requested"));
}

test "fork source: survives in the log until a process ran, and a fork of an unstarted fork copies the same source" {
    var f = Fixture.init();
    defer f.deinit();
    _ = try f.run(.{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } });
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "fake", .harness_session = "src" } } });
    try testing.expect(f.agent("a1").fork_source == null);
    _ = try f.run(.{ .fork = .{ .agent = "a1" } });
    _ = try f.run(.{ .complete = .{ .key = "fork:a1:1", .ok = true, .detail = "copy" } });
    try testing.expectEqualStrings("src", f.agent("a2").fork_source.?);

    _ = try f.run(.{ .fork = .{ .agent = "a2" } });
    _ = try f.run(.{ .complete = .{ .key = "fork:a2:1", .ok = true, .detail = "copy2" } });
    try testing.expectEqualStrings("src", f.agent("a3").fork_source.?);

    // A take-over's binding runs nothing here; a protocol one means it started.
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a2", .harness = "fake", .harness_session = "copy", .mode = "tui" } } });
    try testing.expectEqualStrings("src", f.agent("a2").fork_source.?);
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a2", .harness = "fake", .harness_session = "copy" } } });
    try testing.expect(f.agent("a2").fork_source == null);
    try testing.expectEqualStrings("src", f.agent("a3").fork_source.?);
}

test "fork ended: a sub-agent in the source's folder with its grants narrowed, or no agent at all" {
    var f = Fixture.init();
    defer f.deinit();
    const g = @import("proto").grants.Grant;
    const grants: []const g = &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = "agent:a1" }, .{ .right = .spawn, .scope = "agent:a1" } };
    _ = try f.run(.{ .create = .{ .agent = "a1", .title = "rename", .harness = "fake", .workspace = "/w", .repos = &.{"r"}, .cwd = "/w/.wt/r", .worktrees = &.{.{ .repo = "r", .path = "/w/.wt/r" }}, .mode = "plan", .spawn_model = "m", .grants = grants } });
    _ = try f.run(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "fake", .harness_session = "6f1c" } } });
    _ = try f.run(.{ .fork = .{ .agent = "a1", .task = "sum up" } });
    const done = try f.run(.{ .complete = .{ .key = "fork:a1:1", .ok = true, .detail = "thr_new" } });
    try testing.expectEqual(@as(usize, 3), done.len);
    try testing.expectEqualStrings("a2", done[2].agent_fork_ended.fork.?);
    const x = f.agent("a2");
    try testing.expectEqualStrings("a1", x.parent.?);
    try testing.expectEqualStrings("fork of rename", x.title);
    try testing.expectEqualStrings("thr_new", x.harness_session.?);
    try testing.expectEqualStrings("6f1c", x.fork_source.?);
    try testing.expectEqualStrings("/w/.wt/r", x.cwd.?);
    try testing.expectEqualStrings("/w/.wt/r", x.worktrees[0].path);
    try testing.expect(x.borrowed);
    try testing.expectEqualStrings("sum up", x.task.?);
    try testing.expectEqualStrings("plan", x.mode.?);
    try testing.expectEqualStrings("m", x.spawn_model.?);
    try testing.expect(x.waiting());
    // Never more than the source, and nothing on the source itself.
    try testing.expectEqualStrings("*", x.grants.?[0].scope);
    try testing.expectEqualStrings("agent:a2", x.grants.?[1].scope);
    try testing.expectEqualStrings("agent:a2", x.grants.?[2].scope);
    try testing.expectEqualStrings("a2", f.agent("a1").forks.items[0].fork.?);

    try testing.expectEqual(AgentState.queued, x.state);

    // No task: nothing would dispatch it, so it is idle, not waiting.
    _ = try f.run(.{ .fork = .{ .agent = "a1" } });
    _ = try f.run(.{ .complete = .{ .key = "fork:a1:2", .ok = true, .detail = "thr_idle" } });
    try testing.expectEqual(AgentState.settled, f.agent("a3").state);
    try testing.expect(!f.agent("a3").waiting());

    // A refusal makes nothing and leaves the source alone.
    _ = try f.run(.{ .fork = .{ .agent = "a1" } });
    const refused = try f.run(.{ .complete = .{ .key = "fork:a1:3", .ok = false, .detail = "conflict.harness_fork_refused" } });
    try testing.expectEqualStrings("conflict.harness_fork_refused", refused[refused.len - 1].agent_fork_ended.code.?);
    try testing.expectEqual(@as(usize, 3), f.state.agents.count());

    // The source archived meanwhile: its worktree may be gone.
    _ = try f.run(.{ .fork = .{ .agent = "a1" } });
    _ = try f.run(.{ .archive = .{ .agent = "a1" } });
    const late = try f.run(.{ .complete = .{ .key = "fork:a1:4", .ok = true, .detail = "thr_late" } });
    try testing.expect(!late[late.len - 1].agent_fork_ended.ok);
    try testing.expectEqual(@as(usize, 3), f.state.agents.count());
}

test "mcp off: between turns; what is off adds up, once each" {
    var f = Fixture.init();
    defer f.deinit();
    _ = try f.run(.{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } });
    _ = try f.run(.{ .mcp_off = .{ .agent = "a1", .servers = &.{ "docs", "linear" } } });
    _ = try f.run(.{ .mcp_off = .{ .agent = "a1", .servers = &.{ "linear", "figma" } } });
    try testing.expectEqual(@as(usize, 3), f.agent("a1").mcp_off.len);
    _ = try f.run(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } });
    try testing.expectError(error.TurnRunning, f.run(.{ .mcp_off = .{ .agent = "a1", .servers = &.{"x"} } }));
    try testing.expectError(error.NotFound, f.run(.{ .mcp_off = .{ .agent = "a9", .servers = &.{"x"} } }));
}

test "fork: an effect per request, between turns only" {
    var f = Fixture.init();
    defer f.deinit();
    _ = try f.run(.{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } });
    const out = try f.run(.{ .fork = .{ .agent = "a1", .through_turn = "t1" } });
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("fork:a1:1", out[0].effect_requested.key);
    try testing.expectEqualStrings("harness.fork", out[0].effect_requested.kind);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"through_turn\":\"t1\"}", out[0].effect_requested.payload);
    try testing.expectEqualStrings("fork:a1:2", try decider.forkKey(&f.state, "a1", f.s()));
    // The agent is untouched, and each fork gets its own key.
    try testing.expectEqual(AgentState.queued, f.agent("a1").state);
    try testing.expectEqualStrings("fork:a1:2", (try f.run(.{ .fork = .{ .agent = "a1" } }))[0].effect_requested.key);
    // The completion carries the result and retires it.
    _ = try f.run(.{ .complete = .{ .key = "fork:a1:1", .ok = true, .detail = "thr_new" } });
    try testing.expectEqualStrings("thr_new", f.state.effects.get("fork:a1:1").?.detail);
    try testing.expect(f.state.effects.get("fork:a1:1").?.ok);

    try testing.expectError(error.NotFound, f.run(.{ .fork = .{ .agent = "a9" } }));
    _ = try f.run(.{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } });
    try testing.expectError(error.TurnRunning, f.run(.{ .fork = .{ .agent = "a1" } }));
    _ = try f.run(.{ .record = .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "completed" } } });
    _ = try f.run(.{ .takeover = .{ .agent = "a1" } });
    try testing.expectError(error.HandedOver, f.run(.{ .fork = .{ .agent = "a1" } }));
    _ = try f.run(.{ .takeback = .{ .agent = "a1" } });
    _ = try f.run(.{ .archive = .{ .agent = "a1" } });
    try testing.expectError(error.InvalidTransition, f.run(.{ .fork = .{ .agent = "a1" } }));
}
