//! The context panel (`leader a c`):
//!
//! ```text
//! ╭ Context window ─────────── title ╮
//! │ ▰▰▰▰▰▰▱▱▱▱ 62% · ~124k of 200k    │
//! │ What fills it · estimated         │
//! │   system, instructions, tools 30k │
//! │   messages + tool results     61k │
//! │   files read                  33k │
//! │ Largest items                     │
//! │   Read big.json               14k │
//! │ Actions                           │
//! │   c Compact now                   │
//! │   f Fork to a fresh agent …       │
//! │   m Turn off MCP servers it …     │
//! ╰───────────────────────────────────╯
//! ```
//!
//! A client of `agent.context`, `agent.compact`, `agent.fork` and
//! `agent.mcp_off`. An action is drawn and has a key only when `actions` says
//! the agent's adapter supports it.
//!
//! **Fork** returns at once: the result comes as `agent.fork_ended`
//! on the events stream, and this client then moves to the new agent. It waits
//! by source agent, not by key, because the event may overtake the response.
//! "With a summary": the fork is the harness's copy of the conversation, and
//! `fork_task` is its first prompt, because venom makes no model calls itself.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const k = term.widgets.keys;
const Surface = term.Surface;
const Region = term.Region;
const Value = std.json.Value;
const App = @import("app.zig").App;
const input_box = @import("input_box.zig");
const proto = @import("proto");

pub const Request = enum { show, compact, fork, mcp_off };

pub const fork_task = "You are a fork of another agent, with its conversation. Summarize in a few lines where the work stands: what is done, what is next and what to watch out for. Then wait for instructions.";

pub const Fill = struct { kind: []const u8, tokens: u64 };
pub const Item = struct { kind: []const u8, name: []const u8, title: []const u8, tokens: u64 };

pub const Panel = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// The agent shown; gpa-owned. Null: closed.
    agent: ?[]u8 = null,
    /// `agent.fork` was asked here for this agent; gpa-owned.
    forking: ?[]u8 = null,
    loaded: bool = false,
    title: []const u8 = "",
    used: ?u64 = null,
    window: ?u64 = null,
    estimate: bool = false,
    warn_at: u8 = 80,
    fills: []const Fill = &.{},
    largest: []const Item = &.{},
    unused: []const []const u8 = &.{},
    off: []const []const u8 = &.{},
    can_compact: bool = false,
    can_fork: bool = false,
    can_mcp_off: bool = false,
    inflight: bool = false,
    again: bool = false,

    pub fn init(gpa: std.mem.Allocator) Panel {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Panel) void {
        self.close();
        if (self.forking) |f| self.gpa.free(f);
        self.arena.deinit();
    }

    pub fn close(self: *Panel) void {
        if (self.agent) |x| self.gpa.free(x);
        self.agent = null;
        self.loaded = false;
    }

    /// Takes an `agent.context` result.
    pub fn apply(self: *Panel, ok: Value) !void {
        const agent = self.agent orelse return;
        // A stale answer for an agent no longer shown.
        if (!std.mem.eql(u8, str(ok, "agent") orelse "", agent)) return;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.loaded = true;
        self.title = try a.dupe(u8, str(ok, "title") orelse "");
        self.used = opt(ok, "used");
        self.window = opt(ok, "window");
        self.estimate = !std.mem.eql(u8, str(ok, "source") orelse "", "exact");
        self.warn_at = @intCast(@min(opt(ok, "warn_at") orelse 80, 100));
        var fills: std.ArrayList(Fill) = .empty;
        for (list(ok, "fills")) |f| try fills.append(a, .{ .kind = try a.dupe(u8, str(f, "kind") orelse ""), .tokens = opt(f, "tokens") orelse 0 });
        self.fills = fills.items;
        var items: std.ArrayList(Item) = .empty;
        for (list(ok, "largest")) |f| try items.append(a, .{ .kind = try a.dupe(u8, str(f, "kind") orelse ""), .name = try a.dupe(u8, str(f, "name") orelse ""), .title = try a.dupe(u8, str(f, "title") orelse ""), .tokens = opt(f, "tokens") orelse 0 });
        self.largest = items.items;
        const mcp = ok.object.get("mcp") orelse Value{ .null = {} };
        self.unused = try strings(a, list(mcp, "unused"));
        self.off = try strings(a, list(mcp, "off"));
        const actions = ok.object.get("actions") orelse Value{ .null = {} };
        self.can_compact = flag(actions, "compact");
        self.can_fork = flag(actions, "fork");
        self.can_mcp_off = flag(actions, "mcp_off");
    }
};

fn str(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(name) orelse return null;
    return if (x == .string) x.string else null;
}

fn opt(v: Value, name: []const u8) ?u64 {
    if (v != .object) return null;
    const x = v.object.get(name) orelse return null;
    return if (x == .integer and x.integer >= 0) @intCast(x.integer) else null;
}

fn flag(v: Value, name: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(name) orelse return false;
    return x == .bool and x.bool;
}

fn list(v: Value, name: []const u8) []const Value {
    if (v != .object) return &.{};
    const x = v.object.get(name) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn strings(a: std.mem.Allocator, values: []const Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (values) |v| if (v == .string) try out.append(a, try a.dupe(u8, v.string));
    return out.items;
}

// ---- Requests and keys ------------------------------------------------

pub fn request(app: *App) !void {
    const agent = app.context_panel.agent orelse return;
    if (!app.connected) return;
    if (app.context_panel.inflight) {
        app.context_panel.again = true;
        return;
    }
    app.context_panel.inflight = true;
    try app.request(.{ .context = .show }, "agent.context", .{ .agent = agent });
}

pub fn open(app: *App, agent: []const u8) !void {
    if (agent.len == 0) return app.say("context: no agent selected", .{});
    const copy = try app.gpa.dupe(u8, agent);
    app.context_panel.close();
    app.context_panel.agent = copy;
    try request(app);
}

pub fn onResponse(app: *App, which: Request, body: proto.Response.Body) !void {
    const p = &app.context_panel;
    switch (which) {
        .show => {
            p.inflight = false;
            if (body == .ok) try p.apply(body.ok) else if (body == .@"error") app.say("agent context: {s}", .{body.@"error".code});
            if (p.again) {
                p.again = false;
                try request(app);
            }
        },
        .compact => {
            if (body == .@"error") return app.say("agent compact: {s}", .{body.@"error".code});
            app.say("compacting…", .{});
        },
        .fork => {
            if (body == .@"error") {
                stopWaiting(p);
                return app.say("agent fork: {s}", .{body.@"error".code});
            }
            if (p.forking != null) app.say("forking…", .{});
        },
        .mcp_off => {
            if (body == .@"error") return app.say("agent mcp off: {s}", .{body.@"error".code});
            if (body == .ok) {
                const off = list(body.ok, "off");
                app.say("{d} MCP server{s} off from the next start", .{ off.len, if (off.len == 1) "" else "s" });
            }
            try request(app);
        },
    }
}

/// `f` here, `leader a f` anywhere: forks `agent`, and `onForkEnded` opens the
/// result. From the tree the panel has not asked whether the harness can; the
/// daemon's answer says.
pub fn fork(app: *App, agent: []const u8) !void {
    if (!app.connected) return app.say("agent fork: the daemon is not connected", .{});
    if (agent.len == 0) return app.say("no agent selected", .{});
    const p = &app.context_panel;
    stopWaiting(p);
    p.forking = try p.gpa.dupe(u8, agent);
    try app.request(.{ .context = .fork }, "agent.fork", .{ .agent = agent, .task = fork_task });
}

fn stopWaiting(p: *Panel) void {
    if (p.forking) |f| p.gpa.free(f);
    p.forking = null;
}

/// `agent.fork_ended` from the events stream: `data` is its payload.
pub fn onForkEnded(app: *App, data: Value) !void {
    const p = &app.context_panel;
    const waiting = p.forking orelse return;
    if (!std.mem.eql(u8, str(data, "agent") orelse "", waiting)) return;
    stopWaiting(p);
    if (flag(data, "ok")) {
        const forked = str(data, "fork") orelse return;
        app.say("forked to {s}", .{forked});
        // Typing: the rest of the line stays with the agent it was for.
        if (app.keyMode() != .input) try app.setSelected(forked);
    } else app.say("fork failed: {s}", .{str(data, "code") orelse "unknown"});
}

pub fn key(app: *App, input: term.Input.Key) !void {
    if (!k.pressed(input)) return;
    const p = &app.context_panel;
    const agent = p.agent orelse return;
    if (k.ctrl(input, 'c') or k.char(input, 'q')) {
        p.close();
        app.quit = true;
    } else if (k.named(input, .escape)) {
        p.close();
    } else if (k.char(input, '?')) {
        app.help = true;
    } else if (k.char(input, 'c') and p.can_compact) {
        try app.request(.{ .context = .compact }, "agent.compact", .{ .agent = agent });
        p.close();
    } else if (k.char(input, 'f') and p.can_fork) {
        // `fork` copies it: `close` frees what `agent` points at.
        try fork(app, agent);
        p.close();
    } else if (k.char(input, 'm') and p.can_mcp_off) {
        try app.request(.{ .context = .mcp_off }, "agent.mcp_off", .{ .agent = agent });
    }
}

// ---- Drawing ----------------------------------------------------------

fn fillLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "system")) return "system + instructions";
    if (std.mem.eql(u8, kind, "tools")) return "tool definitions";
    if (std.mem.eql(u8, kind, "messages")) return "messages + tool results";
    if (std.mem.eql(u8, kind, "files")) return "files read";
    // What the transcript does not explain.
    if (std.mem.eql(u8, kind, "fixed")) return "system, instructions, tool definitions";
    return kind;
}

const Line = struct { left: []const u8, right: []const u8 = "", role: w.Role = .secondary };

pub fn draw(app: *App, surface: *Surface, main: Region) !void {
    const p = &app.context_panel;
    const a = app.frame.allocator();
    const theme = &app.crypt;
    var lines: std.ArrayList(Line) = .empty;
    var meter_line: ?input_box.Meter = null;
    if (!p.loaded) {
        try lines.append(a, .{ .left = "loading…", .role = .faint });
    } else {
        if (p.used != null and p.window != null) {
            meter_line = input_box.meter(p.used.?, p.window.?, p.warn_at);
            const prefix: []const u8 = if (p.estimate) "~" else "";
            try lines.append(a, .{ .left = try std.fmt.allocPrint(a, "{s}{s} of {s}", .{ prefix, try input_box.tokens(a, p.used.?), try input_box.tokens(a, p.window.?) }), .role = .normal });
        } else try lines.append(a, .{ .left = "Its harness has not reported a context size yet.", .role = .faint });
        if (p.fills.len > 0) {
            try lines.append(a, .{ .left = "" });
            try lines.append(a, .{ .left = "What fills it · estimated", .role = .muted });
            for (p.fills) |f| try lines.append(a, .{ .left = fillLabel(f.kind), .right = try input_box.tokens(a, f.tokens) });
        }
        if (p.largest.len > 0) {
            try lines.append(a, .{ .left = "" });
            try lines.append(a, .{ .left = "Largest items", .role = .muted });
            for (p.largest) |it| try lines.append(a, .{ .left = try std.fmt.allocPrint(a, "{s} {s}", .{ it.name, it.title }), .right = try input_box.tokens(a, it.tokens) });
        }
        if (p.off.len > 0) {
            try lines.append(a, .{ .left = "" });
            try lines.append(a, .{ .left = try std.fmt.allocPrint(a, "MCP off: {s}", .{try std.mem.join(a, ", ", p.off)}), .role = .muted });
        }
        if (p.can_compact or p.can_fork or p.can_mcp_off) {
            try lines.append(a, .{ .left = "" });
            try lines.append(a, .{ .left = "Actions", .role = .muted });
            if (p.can_compact) try lines.append(a, .{ .left = "c  Compact now", .role = .secondary });
            if (p.can_fork) try lines.append(a, .{ .left = "f  Fork to a fresh agent with a summary", .role = .secondary });
            if (p.can_mcp_off) try lines.append(a, .{ .left = try std.fmt.allocPrint(a, "m  Turn off MCP servers it hasn't used: {s}", .{try std.mem.join(a, ", ", p.unused)}), .role = .secondary });
        }
    }
    const bw: u16 = @min(main.width -| 2, 64);
    const bh: u16 = @min(main.height, @as(u16, @intCast(lines.items.len)) + 2 + @intFromBool(meter_line != null));
    const region: Region = .{ .x = main.x + (main.width -| bw) / 2, .y = main.y + (main.height -| bh) / 2, .width = bw, .height = bh };
    const inner = try w.box.draw(surface, region, theme, .{ .title = "Context window", .badge = if (p.title.len > 0) p.title else (p.agent orelse ""), .focused = true, .clear = true });
    if (inner.width < 4) return;
    var y = inner.y;
    const bottom = inner.y + inner.height;
    const left = inner.x + 1;
    const right = inner.x + inner.width - 1;
    if (meter_line) |m| {
        var cells: std.ArrayList(u8) = .empty;
        for (0..input_box.cells) |i| try cells.appendSlice(a, if (i < m.on) "▰" else "▱");
        const text = try std.fmt.allocPrint(a, "{s} {d}%", .{ cells.items, m.percent });
        _ = try w.text.drawText(surface, left, y, right - left, text, if (m.hot) .warn else .secondary, theme, .{});
        y += 1;
    }
    for (lines.items) |l| {
        if (y >= bottom) break;
        const right_w: u16 = @intCast(w.text.width(l.right));
        const room = (right - left) -| right_w -| 1;
        _ = try w.text.drawText(surface, left, y, room, l.left, l.role, theme, .{ .ellipsis = true });
        if (right_w > 0) _ = try w.text.drawText(surface, right -| right_w, y, right_w, l.right, .secondary, theme, .{});
        y += 1;
    }
}

/// The status bar's keys: the actions on offer.
pub fn hint(app: *const App, a: std.mem.Allocator) ![]const u8 {
    const p = &app.context_panel;
    return std.fmt.allocPrint(a, "{s}{s}{s}esc close", .{ if (p.can_compact) "c compact  " else "", if (p.can_fork) "f fork  " else "", if (p.can_mcp_off) "m MCP off  " else "" });
}
