//! The pure half of the harness records: decide and
//! evolve rules for `tool.started`, `tool.ended`, `usage` and
//! `agent.binding`. The adapters and process supervision that produce them
//! are in `../harness/`.
//!
//! Rules:
//! - tool calls and usage belong to the agent's open turn;
//! - a call is started once and ended once;
//! - `agent.binding` needs an existing agent and sets its `harness_session`
//!   (`protocol` mode also ends a fork's `fork_source`);
//!   a `tui` binding records the take-over pane, a
//!   `protocol` binding clears it.
const std = @import("std");
const ev = @import("events.zig");
const decider = @import("decider.zig");
const Event = ev.Event;
const State = decider.State;
const Rejection = decider.Rejection;

pub fn decide(state: *const State, e: Event, a: std.mem.Allocator, out: *std.ArrayList(Event)) (Rejection || error{OutOfMemory})!void {
    switch (e) {
        .tool_started => |t| {
            const agent = try turnOf(state, t.agent, t.turn);
            if (callState(agent, t.call) != .unknown) return error.Conflict;
        },
        .tool_ended => |t| {
            const agent = try turnOf(state, t.agent, t.turn);
            switch (callState(agent, t.call)) {
                .unknown => return error.NotFound,
                .ended => return error.Conflict,
                .open => {},
            }
        },
        .usage => |u| _ = try turnOf(state, u.agent, u.turn),
        .agent_binding => |b| {
            if (!state.agents.contains(b.agent)) return error.NotFound;
            if (b.harness.len == 0) return error.InvalidCommand;
        },
        else => unreachable,
    }
    try out.append(a, e);
}

pub fn evolve(state: *State, event: Event) error{OutOfMemory}!void {
    const a = state.arena.allocator();
    switch (event) {
        .tool_started, .tool_ended, .usage => {
            const copy = try event.dupe(a);
            const id = switch (copy) {
                inline .tool_started, .tool_ended, .usage => |p| p.agent,
                else => unreachable,
            };
            const agent = state.agents.getPtr(id) orelse return;
            try agent.transcript.append(a, copy);
            if (copy == .tool_started) agent.calls += 1;
        },
        .agent_binding => |b| if (state.agents.getPtr(b.agent)) |agent| {
            if (b.harness_session) |s| agent.harness_session = try a.dupe(u8, s);
            if (b.model) |m| agent.model = try a.dupe(u8, m);
            if (std.mem.eql(u8, b.mode, "tui")) {
                agent.pane = if (b.pane) |p| try a.dupe(u8, p) else null;
                agent.pane_root = b.root;
                agent.transcript_ref = if (b.transcript_ref) |t| try a.dupe(u8, t) else null;
            } else {
                agent.pane = null;
                agent.pane_root = null;
                // A process ran with this conversation: a fork's copy exists.
                agent.fork_source = null;
            }
        },
        else => unreachable,
    }
}

fn turnOf(state: *const State, agent_id: []const u8, turn: []const u8) Rejection!*const decider.Agent {
    const agent = state.agents.getPtr(agent_id) orelse return error.NotFound;
    const open = agent.open_turn orelse return error.Conflict;
    if (!std.mem.eql(u8, open, turn)) return error.Conflict;
    return agent;
}

const CallState = enum { unknown, open, ended };

/// Scans the agent's transcript. Calls are per agent, so the whole
/// transcript counts, not only the open turn.
fn callState(agent: *const decider.Agent, call: []const u8) CallState {
    var s: CallState = .unknown;
    for (agent.transcript.items) |e| switch (e) {
        .tool_started => |t| if (std.mem.eql(u8, t.call, call)) {
            s = .open;
        },
        .tool_ended => |t| if (std.mem.eql(u8, t.call, call)) {
            s = .ended;
        },
        else => {},
    };
    return s;
}

const testing = std.testing;

test "harness records: tool calls and usage live in the open turn" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const apply = decider.apply;
    const started: Event = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build" } };
    try testing.expectError(error.NotFound, apply(&state, .{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "fake" } } }, s));
    _ = try apply(&state, .{ .create = .{ .agent = "a1", .title = "task", .harness = "fake", .workspace = "/w" } }, s);
    try testing.expectError(error.Conflict, apply(&state, .{ .record = started }, s));
    _ = try apply(&state, .{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = "fake", .harness_session = "s1" } } }, s);
    try testing.expectEqualStrings("s1", state.agents.get("a1").?.harness_session.?);
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    try testing.expectError(error.NotFound, apply(&state, .{ .record = .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .status = "ok" } } }, s));
    _ = try apply(&state, .{ .record = started }, s);
    try testing.expectError(error.Conflict, apply(&state, .{ .record = started }, s));
    _ = try apply(&state, .{ .record = .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .status = "ok", .exit = 0 } } }, s);
    try testing.expectError(error.Conflict, apply(&state, .{ .record = .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .status = "ok" } } }, s));
    _ = try apply(&state, .{ .record = .{ .usage = .{ .agent = "a1", .turn = "t1", .tokens_in = 5, .tokens_out = 7 } } }, s);
    try testing.expectError(error.Conflict, apply(&state, .{ .record = .{ .usage = .{ .agent = "a1", .turn = "t9" } } }, s));
    const agent = state.agents.get("a1").?;
    try testing.expectEqual(@as(u32, 1), agent.calls);
    try testing.expectEqual(@as(usize, 4), agent.transcript.items.len);
}
