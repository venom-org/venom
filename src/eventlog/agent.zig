//! The agent state machine.
//!
//! An agent is one run of a harness on a task. It is in exactly one of
//! seven states, and only the transitions of this diagram exist:
//!
//! ```
//! queued ──► running ──► settled ──► archived
//!               │  ▲         │
//!               ▼  │         └──► running (new prompt)
//!           needs_you
//!               │
//! running ──► failed ──► running (retry) | archived
//! settled ──► handed_over ──► settled (harness TUI quit)
//!
//! stop:     queued ──► settled            (no turn ran)
//!           running | needs_you ──► settled   (turn interrupted)
//! ```
//!
//! Every other transition is rejected with `error.InvalidTransition`, which
//! is reported on the wire as `conflict.invalid_transition` (exit code
//! 5).
//!
//! Who drives which edge: turn records drive `queued|settled|failed →
//! running` (`turn.started`), `running ⇄ needs_you` (`request`, and the
//! last live request resolved) and `running → settled|failed`
//! (`turn.ended`). The `transition` command drives the rest:
//! `settled|failed → archived`, `settled → handed_over` and
//! `handed_over → settled`. The `stop` and `archive` commands
//! drive `queued → settled` themselves and interrupt a running turn, whose
//! `turn.ended {interrupted}` then drives `running|needs_you → settled`;
//! `archive` adds `settled → archived` once the agent is settled. The `start`
//! command takes a `handed_over` agent whose take-over pane is gone back to
//! `settled`. The `sweep` command archives settled agents
//! after `agents.archive_after`. Nothing here reads a clock: the decider
//! gets the time from its caller.
const std = @import("std");

pub const State = enum {
    queued,
    running,
    needs_you,
    failed,
    settled,
    handed_over,
    archived,

    /// The brand-book glyph. A state is never shown by
    /// colour alone.
    pub fn glyph(self: State) []const u8 {
        return switch (self) {
            .queued, .archived => "○",
            .running => "◆",
            .needs_you => "▲",
            .failed => "✕",
            .settled => "●",
            .handed_over => "⇄",
        };
    }
};

pub const Edge = struct { from: State, to: State };

/// Exactly the edges of the agent state diagram.
pub const edges = [_]Edge{
    .{ .from = .queued, .to = .running },
    .{ .from = .running, .to = .settled },
    .{ .from = .running, .to = .needs_you },
    .{ .from = .needs_you, .to = .running },
    .{ .from = .running, .to = .failed },
    .{ .from = .settled, .to = .running },
    .{ .from = .settled, .to = .archived },
    .{ .from = .settled, .to = .handed_over },
    .{ .from = .handed_over, .to = .settled },
    .{ .from = .failed, .to = .running },
    .{ .from = .failed, .to = .archived },
    // stop
    .{ .from = .queued, .to = .settled },
    .{ .from = .needs_you, .to = .settled },
};

pub fn allowed(from: State, to: State) bool {
    for (edges) |e| if (e.from == from and e.to == to) return true;
    return false;
}

/// Edges a caller may ask for with the `transition` command. The others
/// follow from turn records, so that the state always matches the turn.
pub fn requestable(from: State, to: State) bool {
    if (!allowed(from, to)) return false;
    return to == .archived or to == .handed_over or (from == .handed_over and to == .settled);
}

/// A take-over split a venom TUI client runs itself (own mode)
/// is recorded as pane `tui:<pid>`, the client's process id.
pub const client_pane_prefix = "tui:";

/// A host-mode take-over whose venomx pane is being opened: its ID comes after
/// the command `agent.takeover` returns (`agent.takeover_pane` records it).
pub const pending_venomx_pane = "venomx";

/// The client process of a `tui:<pid>` pane; null for venomx panes.
pub fn clientPanePid(pane: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, pane, client_pane_prefix)) return null;
    return std.fmt.parseInt(i32, pane[client_pane_prefix.len..], 10) catch null;
}

/// Whether process `pid` exists (a TUI client that owns a take-over split).
pub fn processAlive(pid: i32) bool {
    if (pid <= 0) return false;
    const rc = std.c.kill(pid, @fromBackingInt(@intCast(0)));
    return rc == 0 or std.c.errno(rc) == .PERM;
}

/// The live TUI client whose take-over split has the agent, if any.
pub fn owningClient(pane: ?[]const u8) ?i32 {
    const pid = clientPanePid(pane orelse return null) orelse return null;
    return if (processAlive(pid)) pid else null;
}

/// The wire error code for a rejected transition.
pub const invalid_transition_code = "conflict.invalid_transition";
/// The wire error code for stopping or archiving a `handed_over` agent: the
/// harness's own TUI owns the turn until take back.
pub const handed_over_code = "conflict.agent_handed_over";

const testing = std.testing;

test "agent: the transition table is exactly the agent state diagram" {
    try testing.expectEqual(@as(usize, 13), edges.len);
    var n: usize = 0;
    for (std.enums.values(State)) |from| for (std.enums.values(State)) |to| {
        n += @intFromBool(allowed(from, to));
    };
    try testing.expectEqual(edges.len, n);
    // Nothing leaves `archived`; nothing re-enters `queued`.
    for (std.enums.values(State)) |s| {
        try testing.expect(!allowed(.archived, s));
        try testing.expect(!allowed(s, .queued));
        try testing.expect(!allowed(s, s));
    }
    try testing.expect(requestable(.settled, .archived));
    try testing.expect(requestable(.failed, .archived));
    try testing.expect(requestable(.settled, .handed_over));
    try testing.expect(requestable(.handed_over, .settled));
    try testing.expect(!requestable(.running, .settled));
    try testing.expect(!requestable(.queued, .archived));
    // Stop edges come from `stop`/`archive` and turn records only.
    try testing.expect(!requestable(.queued, .settled));
    try testing.expect(!requestable(.needs_you, .settled));
    // Edges into `archived` only come from `settled` and `failed`.
    for (std.enums.values(State)) |s| if (allowed(s, .archived)) try testing.expect(s == .settled or s == .failed);
}
