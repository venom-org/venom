//! The context panel's verbs: `agent.context`
//! reads what fills an agent's window, and `agent.compact`, `agent.fork` and
//! `agent.mcp_off` are the panel's three actions.
//!
//! **What fills the window.** No harness venom drives says, so this is an
//! estimate from what venom holds, and the panel labels it so:
//!
//! - `messages` and `files`: the transcript's text and tool results, at four
//!   bytes a token; `files` are the results of `read` calls. A compaction or
//!   the harness's own pruning leaves them too high, so they are scaled down
//!   to fit the size the harness last reported, never up.
//! - `system` and `tools`: only when the adapter reports them
//!   (`Conversation.contextFill`).
//! - `fixed`: the rest of the reported size when it does not. It is what the
//!   transcript does not explain, mostly the system prompt, the instructions
//!   and the tool definitions, and it is never split by guesswork.
//!
//! `largest` is the largest tool results, on the same scale.
//!
//! **Actions** are offered only where the adapter says it can
//! (`Host.capsOf`, which runs nothing, so this verb is safe on the reactor).
//!
//! **Forking is asynchronous**: `agent.fork` returns the effect's
//! key at once. How it ended is published as `agent.fork_ended {agent, key, ok,
//! fork?, code?}` and listed under `forks` on `agent.show`, for callers that do
//! not follow `events`. A successful fork is a new sub-agent of the source, in
//! the decider (`forkEnded`), so the two cannot disagree after a restart. With
//! a task it queues for a slot; without one it is `settled`, idle until a send.
const std = @import("std");
const proto = @import("proto");
const eventlog = @import("eventlog/root.zig");
const harness = @import("harness/root.zig");
const agents = @import("agents.zig");
const Agent = eventlog.decider.Agent;

/// The rule of thumb for text without a tokenizer.
const bytes_per_token = 4;
const largest_max = 5;

pub const Fill = struct { kind: []const u8, tokens: u64 };
pub const Item = struct { call: []const u8, kind: []const u8, name: []const u8, title: []const u8, tokens: u64 };
pub const Mcp = struct { servers: []const []const u8, unused: []const []const u8, off: []const []const u8 };
pub const Actions = struct { compact: bool, fork: bool, mcp_off: bool };

/// `venom`'s own servers: turning them off would cut the agent off from venom.
fn own(server: []const u8) bool {
    return std.mem.eql(u8, server, harness.mcp.server_name) or std.mem.eql(u8, server, harness.mcp.permissions_server_name);
}

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// The agent's MCP servers, by what it did with them.
pub fn mcpOf(a: std.mem.Allocator, x: *const Agent) !Mcp {
    var used: std.ArrayList([]const u8) = .empty;
    for (x.transcript.items) |e| {
        if (e != .tool_started) continue;
        const args = e.tool_started.args orelse continue;
        if (args.server) |s| try used.append(a, s);
    }
    var servers: std.ArrayList([]const u8) = .empty;
    var unused: std.ArrayList([]const u8) = .empty;
    for (x.mcp_servers) |s| {
        if (own(s)) continue;
        try servers.append(a, s);
        if (!has(used.items, s) and !has(x.mcp_off, s)) try unused.append(a, s);
    }
    return .{ .servers = servers.items, .unused = unused.items, .off = x.mcp_off };
}

fn itemLess(_: void, l: Item, r: Item) bool {
    return l.tokens > r.tokens;
}

/// The result's `fills` and `largest`.
pub fn fillOf(a: std.mem.Allocator, x: *const Agent, c: eventlog.usage.Context) !struct { fills: []const Fill, largest: []const Item } {
    var messages: u64 = 0;
    var files: u64 = 0;
    var items: std.ArrayList(Item) = .empty;
    for (x.transcript.items) |e| switch (e) {
        .text => |t| messages +|= t.text.len,
        .tool_ended => |t| {
            const body = t.body orelse continue;
            const bytes = @max(body.bytes, body.text.len);
            if (std.mem.eql(u8, t.kind, "read")) files +|= bytes else messages +|= bytes;
            try items.append(a, .{ .call = t.call, .kind = t.kind, .name = t.name, .title = t.title, .tokens = bytes / bytes_per_token });
        },
        else => {},
    };
    messages /= bytes_per_token;
    files /= bytes_per_token;
    const fixed = (c.system orelse 0) +| (c.tools orelse 0);
    const room = c.used -| fixed;
    const held = messages +| files;
    // What the harness dropped still counts here: scale to what it reports.
    if (held > room) {
        messages = scaled(messages, room, held);
        files = room - @min(room, messages);
        for (items.items) |*it| it.tokens = scaled(it.tokens, room, held);
    }
    var fills: std.ArrayList(Fill) = .empty;
    const rest = room -| (messages +| files);
    if (c.system != null or c.tools != null) {
        if (c.system) |n| try fills.append(a, .{ .kind = "system", .tokens = n });
        if (c.tools) |n| try fills.append(a, .{ .kind = "tools", .tokens = n });
        // Known fixed parts: the unexplained rest is conversation.
        messages +|= rest;
    } else try fills.append(a, .{ .kind = "fixed", .tokens = rest });
    try fills.append(a, .{ .kind = "messages", .tokens = messages });
    try fills.append(a, .{ .kind = "files", .tokens = files });
    std.mem.sort(Item, items.items, {}, itemLess);
    return .{ .fills = fills.items, .largest = items.items[0..@min(items.items.len, largest_max)] };
}

fn scaled(n: u64, room: u64, held: u64) u64 {
    return @intCast(@as(u128, n) * room / held);
}

pub const Verbs = struct {
    agents: *agents.Agents,
    show_: Show = undefined,
    compact_: Compact = undefined,
    fork_: Fork = undefined,
    mcp_off_: McpOff = undefined,

    /// The four bindings. `self` must not move afterwards.
    pub fn bindings(self: *Verbs) [4]proto.Binding {
        self.show_ = .{ .verbs = self };
        self.compact_ = .{ .verbs = self };
        self.fork_ = .{ .verbs = self };
        self.mcp_off_ = .{ .verbs = self };
        return .{
            .{ .verb = "agent.context", .handler = proto.VerbHandler.typed(AgentParams, &self.show_) },
            .{ .verb = "agent.compact", .handler = proto.VerbHandler.typed(AgentParams, &self.compact_) },
            .{ .verb = "agent.fork", .handler = proto.VerbHandler.typed(Fork.Params, &self.fork_) },
            .{ .verb = "agent.mcp_off", .handler = proto.VerbHandler.typed(McpOff.Params, &self.mcp_off_) },
        };
    }

    fn get(self: *const Verbs, id: []const u8) ?*const Agent {
        return self.agents.engine.state.agents.getPtr(id);
    }
};

const AgentParams = struct { agent: []const u8 };

/// `agent.context` (read).
pub const Show = struct {
    verbs: *Verbs,

    pub fn call(self: *Show, c: *proto.Call, p: AgentParams) anyerror!void {
        const a = c.arena();
        if (!try c.authorize(.read, agents.agentResource(p.agent))) return;
        const x = self.verbs.get(p.agent) orelse return agents.notFound(c, p.agent);
        const ctx: ?eventlog.usage.Context = if (self.verbs.agents.engine.state.usage.agents.get(p.agent)) |u| u.context else null;
        const filled = if (ctx) |k| try fillOf(a, x, k) else null;
        const mcp = try mcpOf(a, x);
        const caps = self.verbs.agents.host.capsOf(p.agent) orelse harness.contract.Caps{};
        try c.ok(.{
            .agent = p.agent,
            .title = x.title,
            .harness = x.harness,
            .used = if (ctx) |k| k.used else null,
            .window = if (ctx) |k| k.window else null,
            .source = if (ctx) |k| k.source else null,
            .warn_at = self.verbs.agents.config.current().ui.context.warn_at,
            .fills = if (filled) |f| f.fills else &[_]Fill{},
            .largest = if (filled) |f| f.largest else &[_]Item{},
            .mcp = mcp,
            .actions = Actions{ .compact = caps.compact, .fork = caps.fork != .none, .mcp_off = caps.mcp_off and mcp.unused.len > 0 },
        });
    }
};

/// `agent.compact` (write).
pub const Compact = struct {
    verbs: *Verbs,

    pub fn call(self: *Compact, c: *proto.Call, p: AgentParams) anyerror!void {
        if (!try c.authorize(.write, agents.agentResource(p.agent))) return;
        self.verbs.agents.host.compact(p.agent) catch |err| return agents.hostFailure(c, err, p.agent, self.verbs.get(p.agent));
        try c.ok(.{ .agent = p.agent });
    }
};

/// `agent.fork` (write on the agent, `spawn` on its workspace: it makes an
/// agent). An agent asking is also held to the sub-agent
/// limits (`agents.forkAllowed`).
pub const Fork = struct {
    verbs: *Verbs,
    pub const Params = struct { agent: []const u8, through_turn: ?[]const u8 = null, task: ?[]const u8 = null };

    pub fn call(self: *Fork, c: *proto.Call, p: Params) anyerror!void {
        if (!try c.authorize(.write, agents.agentResource(p.agent))) return;
        const x = self.verbs.get(p.agent) orelse return agents.notFound(c, p.agent);
        if (!try c.authorize(.spawn, .{ .kind = "workspace", .id = x.workspace })) return;
        if (p.task) |t| if (std.mem.trim(u8, t, " \t\r\n").len == 0) return c.fail("invalid_params.task", "the task is empty", .{ .param = "task" });
        if (!try agents.forkAllowed(self.verbs.agents, c, x)) return;
        const key = self.verbs.agents.host.forkWith(c.arena(), p.agent, p.through_turn, p.task) catch |err| switch (err) {
            // `Host.fork`'s other NotFound: the agent was checked above.
            error.NotFound => return c.fail("not_found.turn", "no such turn, or the harness has no id for it", .{ .agent = p.agent, .turn = p.through_turn }),
            else => return agents.hostFailure(c, err, p.agent, x),
        };
        try c.ok(.{ .agent = p.agent, .key = key });
    }
};

/// `agent.mcp_off` (write).
pub const McpOff = struct {
    verbs: *Verbs,
    pub const Params = struct { agent: []const u8, servers: ?[]const []const u8 = null };

    pub fn call(self: *McpOff, c: *proto.Call, p: Params) anyerror!void {
        if (!try c.authorize(.write, agents.agentResource(p.agent))) return;
        const x = self.verbs.get(p.agent) orelse return agents.notFound(c, p.agent);
        const mcp = try mcpOf(c.arena(), x);
        const servers = p.servers orelse mcp.unused;
        for (servers) |s| if (!has(mcp.servers, s))
            return c.fail("invalid_params.servers", "venom's own server, or one its harness did not report", .{ .param = "servers", .server = s });
        self.verbs.agents.host.mcpOff(p.agent, servers) catch |err| return agents.hostFailure(c, err, p.agent, self.verbs.get(p.agent));
        try c.ok(.{ .agent = p.agent, .off = servers });
    }
};

const testing = std.testing;

fn agentWith(a: std.mem.Allocator, events: []const eventlog.Event) !Agent {
    var x: Agent = .{};
    try x.transcript.appendSlice(a, events);
    return x;
}

test "context fill: the transcript's parts, the fixed rest, and largest first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const read: eventlog.Event = .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "read", .name = "Read", .title = "big.json", .status = "ok", .body = .{ .text = "x", .truncated = true, .bytes = 40_000 } } };
    const exec: eventlog.Event = .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c2", .kind = "exec", .name = "Bash", .title = "zig build", .status = "ok", .body = .{ .text = "y", .truncated = true, .bytes = 8_000 } } };
    const x = try agentWith(a, &.{ exec, read, .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m1", .text = "12345678" } } });
    const r = try fillOf(a, &x, .{ .used = 30_000, .window = 200_000 });
    try testing.expectEqual(@as(usize, 3), r.fills.len);
    try testing.expectEqualStrings("fixed", r.fills[0].kind);
    try testing.expectEqual(@as(u64, 30_000 - 2_002 - 10_000), r.fills[0].tokens);
    try testing.expectEqual(@as(u64, 2_002), r.fills[1].tokens);
    try testing.expectEqual(@as(u64, 10_000), r.fills[2].tokens);
    try testing.expectEqualStrings("big.json", r.largest[0].title);
    try testing.expectEqualStrings("zig build", r.largest[1].title);
}

test "context fill: reported parts stand alone; a compacted transcript is scaled to the size" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const read: eventlog.Event = .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "read", .name = "Read", .title = "big.json", .status = "ok", .body = .{ .text = "x", .bytes = 400_000 } } };
    const x = try agentWith(a, &.{read});
    const known = try fillOf(a, &x, .{ .used = 150_000, .window = 200_000, .system = 10_000, .tools = 20_000 });
    try testing.expectEqualStrings("system", known.fills[0].kind);
    try testing.expectEqualStrings("tools", known.fills[1].kind);
    try testing.expectEqual(@as(u64, 20_000), known.fills[1].tokens);
    try testing.expectEqual(@as(u64, 20_000), known.fills[2].tokens); // the rest
    try testing.expectEqual(@as(u64, 100_000), known.fills[3].tokens);
    // After a compaction the harness reports 1k; the transcript still holds 100k.
    const small = try fillOf(a, &x, .{ .used = 1_000, .window = 200_000 });
    var sum: u64 = 0;
    for (small.fills) |f| sum += f.tokens;
    try testing.expectEqual(@as(u64, 1_000), sum);
    try testing.expectEqual(@as(u64, 1_000), small.largest[0].tokens);
}

test "context mcp: venom's own are hidden; used and off are not unused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try agentWith(a, &.{.{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "mcp", .name = "search", .title = "s", .args = .{ .server = "docs" } } }});
    x.mcp_servers = &.{ "venom", "venom-permissions", "docs", "linear", "figma" };
    x.mcp_off = &.{"figma"};
    const m = try mcpOf(a, &x);
    try testing.expectEqual(@as(usize, 3), m.servers.len);
    try testing.expectEqual(@as(usize, 1), m.unused.len);
    try testing.expectEqualStrings("linear", m.unused[0]);
}
