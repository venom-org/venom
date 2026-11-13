//! What venom publishes on `venom events` from its durable log.
//!
//! Published types are the protocol's published names for the adapter events
//! the log keeps; their resource is `agent:<agent>`:
//!
//! | Log record | Published as |
//! |---|---|
//! | `agent.created` | `agent.created {agent, title, harness, workspace, repos, parent, issue, state}` (`parent` is `null` for a top-level agent, `issue` for an agent with no linked issue) |
//! | `agent.promoted` | `agent.promoted {agent, parent}` (`parent` is who it belonged to) |
//! | `agent.fork_ended` | `agent.fork_ended {agent, key, ok, fork?, code?}` (`key` is what `agent.fork` returned; `fork` the new agent, `code` the refusal code) |
//! | `agent.child_prompted` | `agent.child_prompted {agent, child, text}` (`agent` is the parent) |
//! | `turn.started` | `agent.turn_started {agent, turn, origin}` |
//! | `turn.ended` | `agent.turn_ended {agent, turn, reason}` |
//! | `text` | `agent.text {agent, turn, message, text}` |
//! | `request` | `agent.attention {agent, kind, reason, age_s}` (`age_s` is 0 when raised) |
//! | `request.resolved` | `agent.attention_cleared {agent, by, kind}` |
//! | `agent.state_changed` | `agent.state_changed {agent, from, to}`, then the attention it raises or clears |
//! | `agent.opened` | `agent.attention_cleared {agent, by: "open", kind: "review"}` |
//! | `workspace.added` | `workspace.added {path, repos}` (resource `workspace:<path>`) |
//! | `workspace.scanned` | `workspace.scanned {path, repos}` (only a scan that changed the repos has a record) |
//! | `workspace.removed` | `workspace.removed {path, repos}` (`repos` is what it last had) |
//!
//! Attention (`attention.zig`): besides
//! requests, an agent that becomes `failed` raises `failed` or `limit`, and
//! one that settles after a turn raises `review`. Leaving `failed` clears
//! it (`by`: `retry`, `archived`); leaving an unread `settled` clears the
//! review (`send`, `archive`, `takeover`), as does opening it (`open`).
//! `kind` on `agent.attention_cleared` says which item went. A harness TUI
//! waiting while handed over (`attention.away`, `attention.away_cleared`)
//! publishes the same two events; the agent stays `handed_over`.
//! | `tool.started`, `tool.ended` | `agent.tool_call {agent, call, turn, kind, verb, title, status, exit?, duration_ms?}` |
//! | `usage` | `agent.usage {agent, turn, model, tokens_in, tokens_out, cache_read, cache_write}` |
//! | `context` | `agent.context {agent, used, window}` |
//!
//! Tool calls' `args` and `body` and a limit's
//! `resets_at` stay in the log, for views and the inbox; the
//! published forms are the ones above.
//!
//! `daemon.started`, the `effect.*` outbox records, `agent.binding`,
//! `mcp.servers`, `agent.mcp_off`,
//! `agent.stop_requested`, `attention.snoozed`, `plan_windows` (they have no
//! published form), the `always.*` and the
//! `decision.*` records are internal. A request a standing "allow always" or
//! a one-shot decision answered at once (`request.resolved` with `grant` or
//! `one_shot`) publishes nothing: no attention was raised.
//! `request.reopened` (a failed resume brought a stale request
//! back) is published as `agent.attention`. `agent.created`
//! is an agent's first record, so it is published before any
//! `agent.state_changed` for it.
//!
//! A workspace whose path cannot be a resource id (a
//! colon, control characters) has no published form: no events and no entity.
//!
//! Snapshots: the turn and text events are history
//! and contribute no entity. Each agent with pending requests has one
//! `attention` entity whose `content` is
//! `{"agent":…,"requests":[{"request":…,"kind":…,"reason":…,"stale":bool}]}`;
//! it disappears when the last request is resolved. Every agent also has
//! one `agent` entity whose `content` is
//! `{"agent":…,"title":…,"harness":…,"state":…,"unread":bool}`. Every
//! workspace has one `workspace` entity whose `content` is
//! `{"path":…,"repos":[…]}`; it disappears when the workspace is removed.
//!
//! Epochs: the daemon starts a new event-log epoch on every start,
//! so a cursor from before a restart falls back to a
//! `source_changed` snapshot, which carries the pending requests that
//! survived the restart. Durable history stays in the log and the state.
const std = @import("std");
const proto = @import("proto");
const ev = @import("events.zig");
const Engine = @import("engine.zig").Engine;
const attention = @import("attention.zig");
const Entry = proto.events.catalog.Entry;
const Field = proto.schema.Field;

const str: proto.schema.Type = .{ .kind = .string };
fn f(comptime name: []const u8, comptime t: proto.schema.Type) Field {
    return .{ .name = name, .summary = name, .type = t, .required = true };
}
const agent = f("agent", str);
const turn = f("turn", str);
const AgentState = @import("agent.zig").State;
const states: proto.schema.Type = .{ .kind = .string, .choices = std.meta.fieldNames(AgentState) };

const strings: proto.schema.Type = .{ .kind = .array, .items = &str };

pub const entries = proto.events.catalog.entries ++ [_]Entry{
    .{ .name = "agent.created", .resource_kind = "agent", .fields = &.{ agent, f("title", str), f("harness", str), f("workspace", str), f("repos", strings), f("parent", .{ .kind = .string, .nullable = true }), f("issue", .{ .kind = .string, .nullable = true }), f("state", states) } },
    .{ .name = "agent.promoted", .resource_kind = "agent", .fields = &.{ agent, f("parent", str) } },
    .{ .name = "agent.fork_ended", .resource_kind = "agent", .fields = &.{ agent, f("key", str), f("ok", .{ .kind = .boolean }), opt("fork", str), opt("code", str) } },
    .{ .name = "agent.child_prompted", .resource_kind = "agent", .fields = &.{ agent, f("child", str), f("text", str) } },
    .{ .name = "agent.turn_started", .resource_kind = "agent", .fields = &.{ agent, turn, f("origin", str) } },
    .{ .name = "agent.turn_ended", .resource_kind = "agent", .fields = &.{ agent, turn, f("reason", str) } },
    .{ .name = "agent.text", .resource_kind = "agent", .fields = &.{ agent, turn, f("message", str), f("text", str) } },
    .{ .name = "agent.attention", .resource_kind = "agent", .fields = &.{ agent, f("kind", str), f("reason", str), f("age_s", .{ .kind = .integer, .min = 0 }) } },
    .{ .name = "agent.attention_cleared", .resource_kind = "agent", .fields = &.{ agent, f("by", str), opt("kind", str) } },
    .{ .name = "agent.state_changed", .resource_kind = "agent", .fields = &.{ agent, f("from", states), f("to", states) } },
    .{ .name = "agent.tool_call", .resource_kind = "agent", .fields = &.{ agent, f("call", str), turn, f("kind", str), f("verb", str), f("title", str), f("status", str), opt("exit", .{ .kind = .integer }), opt("duration_ms", count) } },
    .{ .name = "agent.usage", .resource_kind = "agent", .fields = &.{ agent, turn, f("model", str), f("tokens_in", count), f("tokens_out", count), f("cache_read", count), f("cache_write", count) } },
    .{ .name = "agent.context", .resource_kind = "agent", .fields = &.{ agent, f("used", count), f("window", count) } },
    .{ .name = "workspace.added", .resource_kind = "workspace", .fields = workspace_fields },
    .{ .name = "workspace.scanned", .resource_kind = "workspace", .fields = workspace_fields },
    .{ .name = "workspace.removed", .resource_kind = "workspace", .fields = workspace_fields },
};
const workspace_fields: []const Field = &.{ f("path", str), f("repos", strings) };
const count: proto.schema.Type = .{ .kind = .integer, .min = 0 };
fn opt(comptime name: []const u8, comptime t: proto.schema.Type) Field {
    return .{ .name = name, .summary = name, .type = t };
}

/// The shared `events` verb with venom's payload fields added to the
/// item's `data` descriptor (products extend it at
/// build time). `reason` and `title` already exist with the same type.
pub const events_manifest = blk: {
    const base = proto.events.manifest;
    const fields = base.item.fields;
    const extra = .{
        .{ .name = "agent", .summary = "agent", .type = .{ .kind = .string } },
        .{ .name = "harness", .summary = "harness", .type = .{ .kind = .string } },
        .{ .name = "workspace", .summary = "workspace", .type = .{ .kind = .string } },
        .{ .name = "repos", .summary = "repos", .type = .{ .kind = .array, .items = .{ .kind = .string } } },
        .{ .name = "parent", .summary = "parent", .type = .{ .kind = .string, .nullable = true } },
        .{ .name = "issue", .summary = "issue", .type = .{ .kind = .string, .nullable = true } },
        .{ .name = "state", .summary = "state", .type = .{ .kind = .string, .choices = std.meta.fieldNames(AgentState) } },
        .{ .name = "child", .summary = "child", .type = .{ .kind = .string } },
        .{ .name = "turn", .summary = "turn", .type = .{ .kind = .string } },
        .{ .name = "origin", .summary = "origin", .type = .{ .kind = .string } },
        .{ .name = "message", .summary = "message", .type = .{ .kind = .string } },
        .{ .name = "text", .summary = "text", .type = .{ .kind = .string } },
        .{ .name = "kind", .summary = "kind", .type = .{ .kind = .string } },
        .{ .name = "by", .summary = "by", .type = .{ .kind = .string } },
        .{ .name = "age_s", .summary = "age_s", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "from", .summary = "from", .type = .{ .kind = .string, .choices = std.meta.fieldNames(AgentState) } },
        .{ .name = "to", .summary = "to", .type = .{ .kind = .string, .choices = std.meta.fieldNames(AgentState) } },
        .{ .name = "call", .summary = "call", .type = .{ .kind = .string } },
        .{ .name = "verb", .summary = "verb", .type = .{ .kind = .string } },
        .{ .name = "status", .summary = "status", .type = .{ .kind = .string } },
        .{ .name = "exit", .summary = "exit", .type = .{ .kind = .integer } },
        .{ .name = "duration_ms", .summary = "duration_ms", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "model", .summary = "model", .type = .{ .kind = .string } },
        .{ .name = "tokens_in", .summary = "tokens_in", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "tokens_out", .summary = "tokens_out", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "cache_read", .summary = "cache_read", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "cache_write", .summary = "cache_write", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "key", .summary = "key", .type = .{ .kind = .string } },
        .{ .name = "ok", .summary = "ok", .type = .{ .kind = .boolean } },
        .{ .name = "fork", .summary = "fork", .type = .{ .kind = .string } },
        .{ .name = "code", .summary = "code", .type = .{ .kind = .string } },
        .{ .name = "used", .summary = "used", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "window", .summary = "window", .type = .{ .kind = .integer, .min = 0 } },
        .{ .name = "path", .summary = "path", .type = .{ .kind = .string } },
    };
    const data = fields[4];
    break :blk .{
        .name = base.name,
        .summary = base.summary,
        .grant = base.grant,
        .streams = base.streams,
        .params = base.params,
        .result = base.result,
        .item = .{ .kind = base.item.kind, .fields = .{ fields[0], fields[1], fields[2], fields[3], .{ .name = data.name, .summary = data.summary, .type = .{ .kind = data.type.kind, .fields = data.type.fields ++ extra }, .required = data.required } } },
    };
};

/// Appends the published form of `e`, if it has one. `change` is
/// `attention.change` of `e`, taken before `e` was folded into the state.
pub fn publish(log: *proto.events.Log, a: std.mem.Allocator, e: ev.Event, change: ?attention.Change) !void {
    try publishRecord(log, a, e, change);
    // Requests are published as attention by `publishRecord` itself.
    if (e == .request or e == .request_resolved) return;
    if (change) |ch| switch (ch) {
        .raise => |r| try log.append(try resource(a, r.agent), "agent.attention", .{ .agent = r.agent, .kind = @tagName(r.kind), .reason = r.reason, .age_s = @as(u64, 0) }),
        .clear => |cl| try log.append(try resource(a, cl.agent), "agent.attention_cleared", .{ .agent = cl.agent, .by = cl.by, .kind = @tagName(cl.kind) }),
    };
}

fn publishRecord(log: *proto.events.Log, a: std.mem.Allocator, e: ev.Event, change: ?attention.Change) !void {
    switch (e) {
        .agent_created => |c| try log.append(try resource(a, c.agent), "agent.created", Created{ .agent = c.agent, .title = c.title, .harness = c.harness, .workspace = c.workspace, .repos = c.repos, .parent = c.parent, .issue = c.issue, .state = c.state }),
        .agent_promoted => |p| try log.append(try resource(a, p.agent), "agent.promoted", .{ .agent = p.agent, .parent = p.parent }),
        .agent_fork_ended => |x| try log.append(try resource(a, x.agent), "agent.fork_ended", x),
        .child_prompted => |p| try log.append(try resource(a, p.agent), "agent.child_prompted", .{ .agent = p.agent, .child = p.child, .text = p.text }),
        .turn_started => |t| try log.append(try resource(a, t.agent), "agent.turn_started", .{ .agent = t.agent, .turn = t.turn, .origin = t.origin }),
        .turn_ended => |t| try log.append(try resource(a, t.agent), "agent.turn_ended", .{ .agent = t.agent, .turn = t.turn, .reason = t.reason }),
        .text => |t| try log.append(try resource(a, t.agent), "agent.text", .{ .agent = t.agent, .turn = t.turn, .message = t.message, .text = t.text }),
        // A request a standing grant or a one-shot decision answered at once
        // raised no attention.
        .request => |r| if (change != null) try log.append(try resource(a, r.agent), "agent.attention", .{ .agent = r.agent, .kind = r.kind, .reason = r.reason, .age_s = @as(u64, 0) }),
        .request_resolved => |r| if (r.grant == null and r.one_shot == null) {
            const kind: ?[]const u8 = if (change) |ch| (if (ch == .clear) @tagName(ch.clear.kind) else null) else null;
            try log.append(try resource(a, r.agent), "agent.attention_cleared", Cleared{ .agent = r.agent, .by = r.by, .kind = kind });
        },
        .agent_state_changed => |c| try log.append(try resource(a, c.agent), "agent.state_changed", .{ .agent = c.agent, .from = c.from, .to = c.to }),
        .tool_started => |t| try log.append(try resource(a, t.agent), "agent.tool_call", .{ .agent = t.agent, .call = t.call, .turn = t.turn, .kind = t.kind, .verb = t.name, .title = t.title, .status = t.status }),
        .tool_ended => |t| try log.append(try resource(a, t.agent), "agent.tool_call", ToolCallEnded{ .agent = t.agent, .call = t.call, .turn = t.turn, .kind = t.kind, .verb = t.name, .title = t.title, .status = t.status, .exit = t.exit, .duration_ms = t.duration_ms }),
        .usage => |u| try log.append(try resource(a, u.agent), "agent.usage", .{ .agent = u.agent, .turn = u.turn, .model = u.model, .tokens_in = u.tokens_in, .tokens_out = u.tokens_out, .cache_read = u.cache_read, .cache_write = u.cache_write }),
        .context => |x| try log.append(try resource(a, x.agent), "agent.context", .{ .agent = x.agent, .used = x.used, .window = x.window }),
        .workspace_added => |w| try publishWorkspace(log, a, "workspace.added", w.path, w.repos),
        .workspace_scanned => |w| try publishWorkspace(log, a, "workspace.scanned", w.path, w.repos),
        .workspace_removed => |w| try publishWorkspace(log, a, "workspace.removed", w.path, w.repos),
        .turn_prompt, .mcp_servers, .agent_mcp_off, .daemon_started, .effect_requested, .effect_completed, .agent_opened, .agent_binding, .plan_windows, .agent_stop_requested, .attention_snoozed, .attention_away, .attention_away_cleared, .always_granted, .always_revoked, .decision_recorded, .decision_closed, .request_reopened, .agent_dispatched, .agent_revoked => {},
    }
}

/// The record is already durable here, so a workspace with no published form
/// must not fail the verb that committed it.
fn publishWorkspace(log: *proto.events.Log, a: std.mem.Allocator, kind: []const u8, path: []const u8, repos: []const []const u8) !void {
    const r = try workspaceResource(a, path) orelse return;
    try log.append(r, kind, .{ .path = path, .repos = repos });
}

/// `parent` is an explicit `null` for a top-level agent: the
/// log drops null optionals, so every field is written by hand.
const Created = struct {
    agent: []const u8,
    title: []const u8,
    harness: []const u8,
    workspace: []const u8,
    repos: []const []const u8,
    parent: ?[]const u8,
    issue: ?[]const u8,
    state: @import("agent.zig").State,

    pub fn jsonStringify(self: Created, w: anytype) !void {
        try w.beginObject();
        inline for (comptime std.meta.fieldNames(Created)) |name| {
            try w.objectField(name);
            try w.write(@field(self, name));
        }
        try w.endObject();
    }
};

const Cleared = struct { agent: []const u8, by: []const u8, kind: ?[]const u8 };

const ToolCallEnded = struct { agent: []const u8, call: []const u8, turn: []const u8, kind: []const u8, verb: []const u8, title: []const u8, status: []const u8, exit: ?i64, duration_ms: ?u64 };

const InboxItem = struct { request: []const u8, kind: []const u8, reason: []const u8, stale: bool };

/// The documented `attention` entity members only.
fn inboxItems(a: std.mem.Allocator, ag: *const @import("decider.zig").Agent) ![]const InboxItem {
    const requests = ag.requests.items;
    const out = try a.alloc(InboxItem, requests.len + @intFromBool(ag.away != null));
    for (out[0..requests.len], requests) |*o, r| o.* = .{ .request = r.request, .kind = r.kind, .reason = r.reason, .stale = r.stale };
    if (ag.away) |x| out[requests.len] = .{ .request = attention.away_item, .kind = x.kind, .reason = x.reason, .stale = false };
    return out;
}

fn resource(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "agent:{s}", .{id});
}

/// The workspace's resource, or null when it has no published form.
fn workspaceResource(a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const r = try std.fmt.allocPrint(a, "workspace:{s}", .{path});
    return if (proto.events.validResource(r)) r else null;
}

/// The daemon's snapshot provider: the other providers' entities (config),
/// one `workspace` entity per workspace, then one `agent` entity per agent
/// and one `attention` entity per agent with pending requests.
pub const Snapshots = struct {
    engine: *Engine,
    others: []const proto.events.Snapshot = &.{},

    pub fn capture(self: *Snapshots, a: std.mem.Allocator) anyerror![]const proto.events.Entity {
        var out: std.ArrayList(proto.events.Entity) = .empty;
        for (self.others) |other| try out.appendSlice(a, try other.vtable.capture(other.ptr, a));
        const state = &self.engine.state;
        for (state.workspaces.values()) |w| {
            const r = try workspaceResource(a, w.path) orelse continue;
            try out.append(a, .{
                .resource = r,
                .entity_type = "workspace",
                .event_types = &.{ "workspace.added", "workspace.scanned", "workspace.removed" },
                .content = try std.json.Stringify.valueAlloc(a, .{ .path = w.path, .repos = w.repos }, .{}),
            });
        }
        for (state.agents.keys(), state.agents.values()) |id, *ag| {
            try out.append(a, .{
                .resource = try resource(a, id),
                .entity_type = "agent",
                .event_types = &.{ "agent.created", "agent.state_changed" },
                .content = try std.json.Stringify.valueAlloc(a, .{ .agent = id, .title = ag.title, .harness = ag.harness, .state = ag.state, .unread = ag.unread }, .{}),
            });
            if (ag.requests.items.len == 0 and ag.away == null) continue;
            try out.append(a, .{
                .resource = try resource(a, id),
                .entity_type = "attention",
                .event_types = &.{ "agent.attention", "agent.attention_cleared" },
                .content = try std.json.Stringify.valueAlloc(a, .{ .agent = id, .requests = try inboxItems(a, ag) }, .{}),
            });
        }
        return out.items;
    }
};
