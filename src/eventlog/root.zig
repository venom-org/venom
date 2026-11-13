//! venom's event sourcing: a pure decider (`decider.zig`), a
//! durable append-only log (`store.zig`), a transactional outbox and effect
//! worker (`engine.zig`), and what is published on `venom events`
//! (`catalog.zig`). The log lives at `$XDG_STATE_HOME/venom/venom/events.log`.
pub const events = @import("events.zig");
pub const decider = @import("decider.zig");
pub const Store = @import("store.zig").Store;
pub const engine = @import("engine.zig");
pub const Engine = engine.Engine;
pub const Executor = engine.Executor;
pub const catalog = @import("catalog.zig");
pub const agent = @import("agent.zig");
pub const Clock = engine.Clock;
pub const workspaces = @import("workspaces.zig");
pub const harness = @import("harness.zig");
pub const usage = @import("usage.zig");
pub const attention = @import("attention.zig");
pub const always = @import("always.zig");
pub const oneshot = @import("oneshot.zig");
pub const agent_scope = @import("agent_scope.zig");
pub const Event = events.Event;
pub const Command = events.Command;
pub const State = decider.State;

/// The log file name inside venom's XDG state directory.
pub const file_name = "events.log";

test {
    _ = events;
    _ = decider;
    _ = agent;
    _ = workspaces;
    _ = harness;
    _ = usage;
    _ = attention;
    _ = always;
    _ = oneshot;
    _ = agent_scope;
    _ = @import("tests.zig");
    _ = @import("agent_tests.zig");
}
