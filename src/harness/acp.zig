//! The generic ACP adapter: drives any Agent Client Protocol agent
//! over stdio, JSON-RPC 2.0 with one object per line, against the adapter
//! contract.
//!
//! One agent process per venom agent, run in the agent's cwd. The adapter is
//! the ACP client:
//!
//! 1. `start` returns the argv and, as the handshake `Spawn.input`, the
//!    `initialize` request (protocol version 1, no `fs` or `terminal`: venom
//!    serves neither, and any such request gets a JSON-RPC error).
//! 2. On its response: the capabilities (below), then `session/new`, or with a
//!    stored `harness_session`, `session/resume` or `session/load`. The session
//!    id is the `harness_session`.
//! 3. Sends wait until then, and while a turn runs (`steer = "queue"`: ACP has
//!    no way into a running turn): each becomes `session/prompt` once the
//!    conversation is between turns. Its response's `stopReason` ends the turn.
//!
//! **Capabilities come from `initialize`** and are kept per adapter, since an
//! adapter is one agent binary: `caps` is the most restrictive answer until the
//! first one, and the host re-reads the descriptor at each `session`.
//! `loadSession` or `sessionCapabilities.resume` gives `release`;
//! `agentInfo.version` gives `harness_version`. A version other than 1 ends the
//! connection (`unsupported.harness_version`), as the protocol says to.
//!
//! **Reattach.** `session/resume` where declared, as it replays nothing; else
//! `session/load`, whose replay arrives before its response and is dropped:
//! venom's log already has those turns, and `catch_up` is `none`. Without
//! either, a conversation lives as long as its process. A send to one whose
//! process is gone fails its turn with `unsupported.harness_capability`, and
//! nothing starts a new conversation in its place: the model would have lost
//! the task with no sign of it.
//!
//! **Turns.** ACP reports no turn start, so the turn starts when
//! `session/prompt` is written. `end_turn` is `completed`, `cancelled` is
//! `interrupted`, and `max_tokens`, `max_turn_requests` and `refusal` are
//! `failed.harness_turn`. An error response is `failed.harness_turn`, or
//! `unavailable.harness_not_signed_in` for ACP's `auth_required`; venom never
//! calls `authenticate`, since signing in is the agent's own business. An
//! unknown stop reason is `completed`.
//!
//! **Interrupt and stop.** `session/cancel`, and every pending permission
//! request answered `cancelled`, as the protocol requires. The turn ends on the
//! prompt's response. `Conversation.turnEnd` closes any open tool call as
//! `interrupted`, since ACP has no such status.
//!
//! **Text and plans.** `agent_message_chunk` text is a delta; the full message
//! is logged when its `messageId` changes, a tool call starts, a plan arrives or
//! the turn ends. `plan` is progress, not an approval (`requests.plan` is
//! false), so it is logged as a text checklist when it changed.
//! `agent_thought_chunk` and `user_message_chunk` are dropped. `usage_update` is
//! `context` with source `exact`; ACP's baseline reports no per-turn tokens.
//!
//! **Tool calls.** A `tool_call` is held until it can be named: while it is
//! `pending` with no `rawInput`, which agents commonly send next in an update.
//! `execute` is `exec`; `delete` and `move` are `edit`. The title is what the
//! grant is made of, and ACP's own is free text. So it is
//! the command for `exec` (a string `rawInput.command`, and no `rawInput.args`)
//! and the path for `read` and `edit` (exactly one location). Otherwise the
//! call can't be named: its title ends in ` …`, the form that marks
//! a title as cut short, and `allow_always` isn't offered.
//!
//! **Approvals.** `session/request_permission` is an approval on that tool call.
//! `allow_always` selects the agent's `allow_once` option: venom's grant is
//! authoritative and answers later requests, and the agent's `allow_always` may
//! be a rule venom can't see or undo (the same choice as for codex). It
//! selects the agent's own option only when the agent offers no `allow_once`.
//! `deny` is `reject_once`, else `reject_always`, else the `cancelled` outcome,
//! which ends the turn: it never runs the call. **A deny reason does not reach
//! the agent**: an option id is all ACP takes, and a new turn just to say it
//! would spend quota nobody asked for. `edit` is false. A request whose
//! `rawInput` differs from what the logged call said names no call, so no
//! grant can answer it. `$/cancel_request` withdraws one (`by: harness`).
//!
//! Scope. ACP has no write allowlist, and venom can't serve as the
//! agent's file system, since agents use their own tools. Folders outside the
//! cwd go in `additionalDirectories` where declared. An approval with a location
//! or diff outside the scope is stamped `outside_scope`. **Unenforceable: a
//! write the agent does not ask about never reaches venom**, so a narrowed scope
//! is routing, not containment.
//!
//! Permission modes: none. ACP modes are ids each agent makes up (`session/
//! set_mode`), so venom can't tell which means `plan`. `permission_modes` stays
//! empty, a sub-agent of another harness is refused (`denied.spawn_harness`),
//! and a `--mode` or `--model` on an ACP agent has no effect on the agent.
//!
//! Not declared: `resume_tui` (a generic agent documents no resume command),
//! `fork`, `compact`, `catch_up`, `mcp_off`, `attention_away`.
const std = @import("std");
const contract = @import("contract.zig");
const mcp = @import("mcp.zig");
const agent_scope = @import("../eventlog/agent_scope.zig");
const Conversation = contract.Conversation;
const Value = std.json.Value;

pub const name = "acp";
/// The protocol version venom speaks.
pub const protocol_version: i64 = 1;
/// ACP's `auth_required`.
const auth_required: i64 = -32000;
const method_not_found: i64 = -32601;
/// `$/cancel_request`: the request was cancelled.
const request_cancelled: i64 = -32800;
/// Marks a title that does not name its call (`always.truncated`).
const unnamed = " \u{2026}";

const Purpose = enum { initialize, open, prompt };

/// What `initialize` said; strings in the adapter's `known_arena`.
const Known = struct {
    load_session: bool = false,
    @"resume": bool = false,
    additional_directories: bool = false,
    version: ?[]const u8 = null,
};

pub const Acp = struct {
    gpa: std.mem.Allocator,
    /// The command: `harness.acp.path` and `extra_args`, or a test's fake.
    argv: []const []const u8,
    env: []const contract.EnvVar = &.{},
    /// venom's MCP server for the agent, in `mcpServers`. Borrowed.
    mcp: ?mcp.Server = null,
    client_version: []const u8 = "0.1.0",
    /// The last `initialize` answer; null until the first.
    known: ?Known = null,
    known_arena: std.heap.ArenaAllocator,
    states: std.StringArrayHashMapUnmanaged(*State) = .empty,
    /// Owns `argv` when built by `initCommand`.
    owned: ?std.heap.ArenaAllocator = null,

    /// `argv` is borrowed.
    pub fn init(gpa: std.mem.Allocator, argv: []const []const u8) Acp {
        return .{ .gpa = gpa, .argv = argv, .known_arena = .init(gpa) };
    }

    /// `<exe> <extra_args…>`, copied so config reloads cannot free them.
    pub fn initCommand(gpa: std.mem.Allocator, exe: []const u8, extra_args: []const []const u8) !Acp {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const argv = try a.alloc([]const u8, 1 + extra_args.len);
        argv[0] = try a.dupe(u8, exe);
        for (argv[1..], extra_args) |*d, arg| d.* = try a.dupe(u8, arg);
        return .{ .gpa = gpa, .argv = argv, .owned = arena, .known_arena = .init(gpa) };
    }

    pub fn deinit(self: *Acp) void {
        if (self.owned) |*o| o.deinit();
        self.known_arena.deinit();
        for (self.states.values()) |s| {
            s.deinit(self.gpa);
            self.gpa.destroy(s);
        }
        for (self.states.keys()) |k| self.gpa.free(k);
        self.states.deinit(self.gpa);
    }

    pub fn adapter(self: *Acp) contract.Adapter {
        return .init(self);
    }

    pub fn probe(self: *Acp, _: std.mem.Allocator) anyerror!contract.Descriptor {
        return .{
            .harness = name,
            .harness_version = if (self.known) |k| k.version else null,
            .channel = "acp",
            .caps = self.caps(),
        };
    }

    /// ACP's baseline, plus what the last `initialize` declared.
    pub fn caps(self: *Acp) contract.Caps {
        const k = self.known orelse Known{};
        return .{
            .steer = .queue,
            .interrupt = true,
            // "always" is venom's grant: see the file comment.
            .requests = .{ .approval = .{ .edit = false, .always = .none } },
            .release = k.load_session or k.@"resume",
            .usage = .{ .context = .exact },
        };
    }

    pub fn compact(_: *Acp, _: *Conversation) anyerror!void {
        return error.UnsupportedCapability;
    }

    pub fn start(self: *Acp, a: std.mem.Allocator, params: contract.Start) anyerror!contract.Spawn {
        const s = try self.state(params.agent);
        s.reset(self.gpa);
        const l = s.life.allocator();
        s.resume_session = if (params.harness_session) |h| try l.dupe(u8, h) else null;
        s.cwd = try l.dupe(u8, params.cwd);
        s.writable = try dupeAll(l, params.writable);
        const id = try s.call(self.gpa, .initialize);
        const hello = try std.json.Stringify.valueAlloc(a, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = "initialize",
            .params = .{
                .protocolVersion = protocol_version,
                .clientCapabilities = .{ .fs = .{ .readTextFile = false, .writeTextFile = false }, .terminal = false },
                .clientInfo = .{ .name = "venom", .title = "venom", .version = self.client_version },
            },
        }, .{});
        var env = self.env;
        if (self.mcp) |m| if (m.socket) |path| {
            env = try std.mem.concat(a, contract.EnvVar, &.{ self.env, &.{.{ .name = mcp.socket_env, .value = path }} });
        };
        return .{ .argv = self.argv, .cwd = params.cwd, .env = env, .harness_session = null, .input = try std.mem.concat(a, u8, &.{ hello, "\n" }) };
    }

    pub fn send(self: *Acp, conv: *Conversation, text: []const u8, mode: contract.SendMode) anyerror!void {
        const s = try self.state(conv.agent);
        if (mode == .interrupt_then_send) try self.interrupt(conv);
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        try s.queue.append(self.gpa, copy);
        // The host logs this prompt after this call returns.
        try self.pump(conv, s, true);
    }

    pub fn interrupt(self: *Acp, conv: *Conversation) anyerror!void {
        if (!conv.inTurn()) return;
        const s = try self.state(conv.agent);
        try self.cancelTurn(conv, s);
        var it = s.asks.iterator();
        while (it.next()) |e| try answerCancelled(conv, s, e.key_ptr.*);
        s.asks = .empty;
    }

    pub fn respond(self: *Acp, conv: *Conversation, request: contract.Pending, answer: contract.Answer) anyerror!void {
        const s = try self.state(conv.agent);
        const ask = s.asks.get(request.harness_ref) orelse return error.RequestResolved;
        const pick: ?[]const u8 = if (eql(answer.answer, "allow_once"))
            ask.allow_once orelse return error.InvalidAnswer
        else if (eql(answer.answer, "allow_always"))
            ask.allow_once orelse ask.allow_always orelse return error.InvalidAnswer
        else if (eql(answer.answer, "deny"))
            ask.reject_once orelse ask.reject_always
        else if (eql(answer.answer, "cancel_turn"))
            null
        else
            return error.InvalidAnswer;
        if (pick) |option| {
            const a = s.turn.allocator();
            const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":{f}}}}}}}", .{ request.harness_ref, std.json.fmt(option, .{}) });
            try conv.writeLine(line);
        } else {
            // Only a cancelled turn may answer `cancelled`.
            try self.cancelTurn(conv, s);
            try answerCancelled(conv, s, request.harness_ref);
        }
        _ = s.asks.remove(request.harness_ref);
        if (eql(answer.answer, "deny")) if (ask.call) |id| if (s.tools.getPtr(id)) |t| {
            t.declined = true;
        };
    }

    pub fn decode(self: *Acp, conv: *Conversation, line: []const u8) anyerror!void {
        var arena: std.heap.ArenaAllocator = .init(conv.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // A line that is not JSON is skipped.
        const v = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch return;
        if (v != .object) return;
        const s = try self.state(conv.agent);
        if (str(v, "method")) |method| {
            if (v.object.get("id")) |id| return self.agentRequest(conv, s, a, method, id, field(v, "params"));
            return self.notification(conv, s, a, method, field(v, "params"));
        }
        const id = int(v, "id") orelse return;
        return self.response(conv, s, @intCast(@max(0, id)), field(v, "result"), field(v, "error"));
    }

    pub fn fork(_: *Acp, _: std.mem.Allocator, _: *Conversation, _: ?[]const u8) anyerror!contract.ForkStep {
        return error.UnsupportedCapability;
    }

    pub fn release(_: *Acp, conv: *Conversation) anyerror!void {
        if (conv.inTurn()) return error.TurnRunning;
        conv.closeInput();
        conv.signal(.TERM) catch {};
    }

    pub fn resume_command(_: *Acp, _: std.mem.Allocator, _: contract.Resume) anyerror!contract.Spawn {
        return error.UnsupportedCapability;
    }

    pub fn catch_up(_: *Acp, _: *Conversation, _: contract.Resume) anyerror!u32 {
        return error.UnsupportedCapability;
    }

    // ------------------------------------------------------------ internals

    fn state(self: *Acp, agent: []const u8) !*State {
        if (self.states.get(agent)) |s| return s;
        const s = try self.gpa.create(State);
        errdefer self.gpa.destroy(s);
        s.* = .{ .life = .init(self.gpa), .turn = .init(self.gpa) };
        const key = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(key);
        try self.states.put(self.gpa, key, s);
        return s;
    }

    /// Starts the next waiting message when the conversation is between turns.
    /// `sending`: called from `send`, so the host logs its prompt only later.
    fn pump(self: *Acp, conv: *Conversation, s: *State, sending: bool) !void {
        if (s.phase != .ready or conv.inTurn() or s.prompt_id != null or s.queue.items.len == 0) return;
        const text = s.queue.orderedRemove(0);
        defer self.gpa.free(text);
        const id = try s.call(self.gpa, .prompt);
        s.prompt_id = id;
        try conv.writeJson(.{ .jsonrpc = "2.0", .id = id, .method = "session/prompt", .params = .{ .sessionId = s.session orelse "", .prompt = &[_]TextBlock{.{ .text = text }} } });
        if (sending) try conv.turnStartedBySend(null) else try conv.turnStarted(null, "user");
    }

    fn cancelTurn(_: *Acp, conv: *Conversation, s: *State) !void {
        if (s.cancelled or s.prompt_id == null) return;
        s.cancelled = true;
        try conv.writeJson(.{ .jsonrpc = "2.0", .method = "session/cancel", .params = .{ .sessionId = s.session orelse "" } });
    }

    fn openSession(self: *Acp, conv: *Conversation, s: *State, a: std.mem.Allocator) !void {
        const k = self.known orelse Known{};
        var extra: std.ArrayList([]const u8) = .empty;
        if (k.additional_directories) for (s.writable) |w| {
            if (!agent_scope.withinPath(s.cwd, w)) try extra.append(a, w);
        };
        const servers = try mcpServers(a, self.mcp);
        const dirs: ?[]const []const u8 = if (extra.items.len > 0) extra.items else null;
        const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
        const P = struct { sessionId: ?[]const u8 = null, cwd: []const u8, mcpServers: []const McpServer, additionalDirectories: ?[]const []const u8 = null };
        const params: P = .{ .sessionId = s.resume_session, .cwd = s.cwd, .mcpServers = servers, .additionalDirectories = dirs };
        const method: []const u8 = if (s.resume_session == null)
            "session/new"
        else if (k.@"resume")
            "session/resume"
        else if (k.load_session)
            "session/load"
        else
            return self.failOpen(conv, s, "unsupported.harness_capability");
        const id = try s.call(self.gpa, .open);
        const line = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, options);
        try conv.writeLine(line);
    }

    fn response(self: *Acp, conv: *Conversation, s: *State, id: u64, result: ?Value, err: ?Value) !void {
        const purpose = (s.calls.fetchRemove(id) orelse return).value;
        switch (purpose) {
            .initialize => {
                const r = result orelse return self.failOpen(conv, s, "failed.harness_protocol");
                // A version venom does not speak: close, as the protocol says.
                if ((int(r, "protocolVersion") orelse -1) != protocol_version) return self.failOpen(conv, s, "unsupported.harness_version");
                try self.learn(r);
                s.phase = .opening;
                var arena: std.heap.ArenaAllocator = .init(self.gpa);
                defer arena.deinit();
                try self.openSession(conv, s, arena.allocator());
            },
            .open => {
                const resuming = s.resume_session != null;
                if (err) |e| return self.failOpen(conv, s, if (int(e, "code") == auth_required) "unavailable.harness_not_signed_in" else if (resuming) "not_found.harness_session" else "failed.harness_protocol");
                const r = result orelse return self.failOpen(conv, s, "failed.harness_protocol");
                const session = if (resuming) s.resume_session.? else str(r, "sessionId") orelse return self.failOpen(conv, s, "failed.harness_protocol");
                s.session = try s.life.allocator().dupe(u8, session);
                s.phase = .ready;
                try conv.session(session, null, if (self.known) |k| k.version else null);
                try self.pump(conv, s, false);
            },
            .prompt => {
                s.prompt_id = null;
                if (!conv.inTurn()) return;
                try self.flushText(conv, s);
                try self.endTurn(conv, s, result, err);
                s.endTurn(self.gpa);
                try self.pump(conv, s, false);
            },
        }
    }

    fn endTurn(_: *Acp, conv: *Conversation, s: *State, result: ?Value, err: ?Value) !void {
        if (err) |e| {
            // The protocol says to answer `cancelled`; an agent may not.
            if (s.cancelled) return conv.turnEnded("interrupted", null);
            return conv.turnEnded("failed", if (int(e, "code") == auth_required) "unavailable.harness_not_signed_in" else "failed.harness_turn");
        }
        const stop = if (result) |r| str(r, "stopReason") orelse "end_turn" else "end_turn";
        if (eql(stop, "cancelled")) return conv.turnEnded("interrupted", null);
        if (eql(stop, "max_tokens") or eql(stop, "max_turn_requests") or eql(stop, "refusal")) return conv.turnEnded("failed", "failed.harness_turn");
        try conv.turnEnded("completed", null);
    }

    /// Keeps what `initialize` declared. Omitted means unsupported.
    fn learn(self: *Acp, r: Value) !void {
        _ = self.known_arena.reset(.retain_capacity);
        const agent = field(r, "agentCapabilities");
        const session = if (agent) |x| field(x, "sessionCapabilities") else null;
        const info = field(r, "agentInfo");
        self.known = .{
            .load_session = if (agent) |x| boolean(x, "loadSession") else false,
            .@"resume" = if (session) |x| field(x, "resume") != null else false,
            .additional_directories = if (session) |x| field(x, "additionalDirectories") != null else false,
            .version = if (info) |x| if (str(x, "version")) |w| try self.known_arena.allocator().dupe(u8, w) else null else null,
        };
    }

    /// The conversation could not be opened: whatever was sent fails, and the
    /// process is told to exit (end of input).
    fn failOpen(self: *Acp, conv: *Conversation, s: *State, code: []const u8) !void {
        s.phase = .failed;
        if (s.queue.items.len > 0 or conv.sending) {
            for (s.queue.items) |t| self.gpa.free(t);
            s.queue.clearRetainingCapacity();
            if (!conv.inTurn()) try conv.turnStarted(null, "user");
            try conv.turnEnded("failed", code);
        }
        conv.closeInput();
    }

    fn notification(self: *Acp, conv: *Conversation, s: *State, a: std.mem.Allocator, method: []const u8, params: ?Value) !void {
        const p = params orelse return;
        if (eql(method, "$/cancel_request")) {
            const id = try idKey(a, p.object.get("requestId") orelse return);
            if (!s.asks.contains(id)) return;
            _ = s.asks.remove(id);
            try conv.requestResolved(id, "harness");
            return conv.writeLine(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"cancelled\"}}}}", .{ id, request_cancelled }));
        }
        if (!eql(method, "session/update")) return;
        // A `session/load` replay comes before its response: never logged.
        if (s.phase != .ready) return;
        if (str(p, "sessionId")) |id| if (!eql(id, s.session orelse "")) return;
        const update = field(p, "update") orelse return;
        const kind = str(update, "sessionUpdate") orelse return;
        if (eql(kind, "usage_update")) {
            if (int(update, "size")) |size| if (size > 0) try conv.context(count(update, "used"), @intCast(size), "exact");
            return;
        }
        // What an agent says between turns has no turn to belong to.
        if (!conv.inTurn()) return;
        if (eql(kind, "agent_message_chunk")) {
            try self.chunk(conv, s, update);
        } else if (eql(kind, "tool_call") or eql(kind, "tool_call_update")) {
            try self.flushText(conv, s);
            try self.toolUpdate(conv, s, a, update);
        } else if (eql(kind, "plan")) {
            try self.flushText(conv, s);
            try plan(conv, s, a, update);
        }
        // Other kinds are ignored.
    }

    fn chunk(self: *Acp, conv: *Conversation, s: *State, update: Value) !void {
        const content = field(update, "content") orelse return;
        if (!eql(str(content, "type") orelse "", "text")) return;
        const message = str(update, "messageId");
        if (message) |m| {
            if (s.message) |prev| if (!eql(prev, m)) try self.flushText(conv, s);
            s.message = try s.turn.allocator().dupe(u8, m);
        }
        const text = str(content, "text") orelse return;
        try s.text.appendSlice(self.gpa, text);
        try conv.text(text, false);
    }

    /// One `final` per message, with its whole text.
    fn flushText(_: *Acp, conv: *Conversation, s: *State) !void {
        if (s.text.items.len == 0) return;
        try conv.text(s.text.items, true);
        s.text.clearRetainingCapacity();
    }

    fn toolUpdate(self: *Acp, conv: *Conversation, s: *State, a: std.mem.Allocator, update: Value) !void {
        const id = str(update, "toolCallId") orelse return;
        const t = try s.tool(self.gpa, id);
        if (t.ended) return;
        try t.merge(s.turn.allocator(), a, update);
        // Still pending and not nameable: wait for its input.
        if (!t.started and (t.raw != null or !eql(t.status, "pending"))) try startTool(conv, s, a, id, t);
        if (t.started) try self.toolOutput(conv, a, id, t, update);
    }

    /// `content` replaces what the call showed: the delta is what grew.
    fn toolOutput(self: *Acp, conv: *Conversation, a: std.mem.Allocator, id: []const u8, t: *Tool, update: Value) !void {
        const body = try bodyOf(a, update);
        if (body) |text| {
            if (std.mem.startsWith(u8, text, t.body.items)) {
                const delta = text[t.body.items.len..];
                if (delta.len > 0) try conv.toolUpdated(id, delta);
            }
            t.body.clearRetainingCapacity();
            try t.body.appendSlice(self.gpa, text);
        }
        const status = str(update, "status") orelse return;
        const ended: []const u8 = if (eql(status, "completed"))
            (if (t.declined) "declined" else "ok")
        else if (eql(status, "failed"))
            (if (t.declined) "declined" else "error")
        else
            return;
        t.ended = true;
        const output: ?[]const u8 = if (t.body.items.len > 0) t.body.items else if (field(update, "rawOutput")) |raw| try rawText(a, raw) else null;
        try conv.toolEnd(id, .{ .status = ended, .body = output });
    }

    fn agentRequest(self: *Acp, conv: *Conversation, s: *State, a: std.mem.Allocator, method: []const u8, id: Value, params: ?Value) !void {
        if (!eql(method, "session/request_permission")) {
            const msg = try std.fmt.allocPrint(a, "venom does not handle {s}", .{method});
            return conv.writeLine(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = method_not_found, .message = msg } }, .{}));
        }
        const key = try idKey(a, id);
        // Outside a turn, or a turn already cancelled: nobody can be asked.
        if (!conv.inTurn() or s.cancelled) return answerCancelled(conv, s, key);
        try self.flushText(conv, s);
        const p = params orelse return answerCancelled(conv, s, key);
        const tt = s.turn.allocator();
        var ask = try askOf(tt, p);
        const call = field(p, "toolCall") orelse Value{ .null = {} };
        const call_id = str(call, "toolCallId");
        var named = false;
        // What is asked is what the logged call says.
        var same = true;
        var input: ?[]const u8 = null;
        var reason: []const u8 = "Run a tool";
        var outside = false;
        if (call_id) |ref| {
            const t = try s.tool(self.gpa, ref);
            const logged = t.started;
            const logged_raw = t.raw;
            const logged_paths = t.paths.items.len;
            try t.merge(tt, a, call);
            if (logged) {
                if (logged_raw) |was| same = eql(was, t.raw orelse "");
                if (t.paths.items.len != logged_paths) same = false;
            } else try startTool(conv, s, a, ref, t);
            input = t.raw;
            named = t.named;
            if (t.title.len > 0) reason = t.title;
            outside = try s.outside(self.gpa, t);
            ask.call = try tt.dupe(u8, ref);
        }
        var answers: std.ArrayList([]const u8) = .empty;
        if (ask.allow_once != null) try answers.append(a, "allow_once");
        if ((named and same and ask.allow_once != null) or (ask.allow_once == null and ask.allow_always != null)) try answers.append(a, "allow_always");
        try answers.appendSlice(a, &.{ "deny", "cancel_turn" });
        const owned = try tt.dupe(u8, key);
        try s.asks.put(tt, owned, ask);
        try conv.request(.{ .harness_ref = owned, .kind = "approval", .call_ref = if (same) call_id else null, .reason = reason, .answers = answers.items, .input_json = input, .outside_scope = outside });
    }
};

const TextBlock = struct { type: []const u8 = "text", text: []const u8 };
const EnvEntry = struct { name: []const u8, value: []const u8 };
const McpServer = struct { name: []const u8, command: []const u8, args: []const []const u8, env: []const EnvEntry };

/// venom's own server, over stdio: every ACP agent must take that transport.
fn mcpServers(a: std.mem.Allocator, server: ?mcp.Server) ![]const McpServer {
    const m = server orelse return &.{};
    const env: []const EnvEntry = if (m.socket) |path| try a.dupe(EnvEntry, &.{.{ .name = mcp.socket_env, .value = path }}) else &.{};
    return a.dupe(McpServer, &.{.{ .name = mcp.server_name, .command = m.command, .args = m.args, .env = env }});
}

/// The turn's `cancelled` answer to request `key`.
fn answerCancelled(conv: *Conversation, s: *State, key: []const u8) !void {
    const line = try std.fmt.allocPrint(s.turn.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"outcome\":{{\"outcome\":\"cancelled\"}}}}}}", .{key});
    try conv.writeLine(line);
}

/// The options of a request, by kind: the first of each.
fn askOf(a: std.mem.Allocator, params: Value) !Ask {
    var ask: Ask = .{};
    const options = field(params, "options") orelse return ask;
    if (options != .array) return ask;
    for (options.array.items) |o| {
        const id = str(o, "optionId") orelse continue;
        const kind = str(o, "kind") orelse continue;
        const slot = if (eql(kind, "allow_once")) &ask.allow_once else if (eql(kind, "allow_always")) &ask.allow_always else if (eql(kind, "reject_once")) &ask.reject_once else if (eql(kind, "reject_always")) &ask.reject_always else continue;
        if (slot.* == null) slot.* = try a.dupe(u8, id);
    }
    return ask;
}

/// Logs a tool call, named as the file comment says.
fn startTool(conv: *Conversation, s: *State, a: std.mem.Allocator, id: []const u8, t: *Tool) !void {
    const named_as = try nameOf(a, t, s.cwd);
    t.named = named_as.named;
    t.title = try s.turn.allocator().dupe(u8, named_as.title);
    t.started = true;
    const status: []const u8 = if (eql(t.status, "pending")) "pending" else "running";
    try conv.toolStarted(.{ .harness_ref = id, .kind = named_as.kind, .name = t.name orelse t.acp_kind, .title = t.title, .status = status, .args = named_as.args, .raw_input = t.raw });
}

const Named = struct { kind: []const u8, title: []const u8, named: bool, args: contract.ToolArgs };

/// The tool kind, title and args from ACP's own kinds. `named`: the title says all of
/// what the call does, so a grant may be made from it.
fn nameOf(a: std.mem.Allocator, t: *const Tool, cwd: []const u8) !Named {
    const raw: ?Value = if (t.raw) |r| std.json.parseFromSliceLeaky(Value, a, r, .{}) catch null else null;
    const k = t.acp_kind;
    if (eql(k, "execute")) {
        const command = if (raw) |r| str(r, "command") else null;
        const has_args = if (raw) |r| field(r, "args") != null else false;
        const given = if (raw) |r| str(r, "cwd") orelse cwd else cwd;
        if (command) |line| if (!has_args and line.len > 0) {
            if (std.mem.indexOfScalar(u8, line, '\n')) |nl| return .{ .kind = "exec", .title = try std.fmt.allocPrint(a, "{s}{s}", .{ line[0..nl], unnamed }), .named = false, .args = .{ .command = line, .cwd = given } };
            return .{ .kind = "exec", .title = line, .named = true, .args = .{ .command = line, .cwd = given } };
        };
        return .{ .kind = "exec", .title = try unnamedTitle(a, t), .named = false, .args = .{ .cwd = given } };
    }
    const one = if (t.paths.items.len == 1) t.paths.items[0] else null;
    if (eql(k, "read")) {
        if (one) |path| return .{ .kind = "read", .title = path, .named = true, .args = .{ .path = path } };
        return .{ .kind = "read", .title = try unnamedTitle(a, t), .named = false, .args = .{} };
    }
    if (eql(k, "edit") or eql(k, "delete") or eql(k, "move")) {
        const change: []const u8 = if (eql(k, "delete")) "delete" else "modify";
        if (one) |path| return .{ .kind = "edit", .title = path, .named = true, .args = .{ .path = path, .change = change } };
        return .{ .kind = "edit", .title = try unnamedTitle(a, t), .named = false, .args = .{ .change = change } };
    }
    const title = try unnamedTitle(a, t);
    if (eql(k, "search")) return .{ .kind = "search", .title = title, .named = false, .args = .{ .query = if (raw) |r| str(r, "query") orelse str(r, "pattern") else null, .path = one } };
    if (eql(k, "fetch")) return .{ .kind = "fetch", .title = title, .named = false, .args = .{ .url = if (raw) |r| str(r, "url") else null, .query = if (raw) |r| str(r, "query") else null } };
    return .{ .kind = "other", .title = title, .named = false, .args = .{} };
}

fn unnamedTitle(a: std.mem.Allocator, t: *const Tool) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ if (t.title.len > 0) t.title else t.acp_kind, unnamed });
}

/// A plan as a text message, when it changed. The whole list comes every time.
fn plan(conv: *Conversation, s: *State, a: std.mem.Allocator, update: Value) !void {
    const entries = field(update, "entries") orelse return;
    if (entries != .array) return;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "Plan:");
    for (entries.array.items) |e| {
        const status = str(e, "status") orelse "pending";
        const mark: []const u8 = if (eql(status, "completed")) "[x]" else if (eql(status, "in_progress")) "[~]" else "[ ]";
        try out.print(a, "\n{s} {s}", .{ mark, str(e, "content") orelse "" });
    }
    if (s.last_plan) |prev| if (eql(prev, out.items)) return;
    s.last_plan = try s.turn.allocator().dupe(u8, out.items);
    try conv.text(out.items, true);
}

/// A call's output: text blocks as they are, diffs in unified form. Null when
/// the update carries no `content`.
fn bodyOf(a: std.mem.Allocator, update: Value) !?[]const u8 {
    const content = field(update, "content") orelse return null;
    if (content != .array) return null;
    var out: std.ArrayList(u8) = .empty;
    for (content.array.items) |c| {
        const kind = str(c, "type") orelse continue;
        if (eql(kind, "content")) {
            const block = field(c, "content") orelse continue;
            if (eql(str(block, "type") orelse "", "text")) try out.appendSlice(a, str(block, "text") orelse "");
        } else if (eql(kind, "diff")) {
            const path = str(c, "path") orelse "";
            try out.print(a, "--- {s}\n+++ {s}\n", .{ path, path });
            try prefixed(a, &out, '-', str(c, "oldText") orelse "");
            try prefixed(a, &out, '+', str(c, "newText") orelse "");
        }
    }
    return out.items;
}

fn prefixed(a: std.mem.Allocator, out: *std.ArrayList(u8), mark: u8, text: []const u8) !void {
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try out.print(a, "{c}{s}\n", .{ mark, line });
}

/// `rawOutput` as a body: a string as it is, anything else as JSON.
fn rawText(a: std.mem.Allocator, raw: Value) !?[]const u8 {
    return if (raw == .string) raw.string else try contract.rawJson(a, raw);
}

fn dupeAll(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

/// The option ids of one permission request, and its call.
const Ask = struct {
    allow_once: ?[]const u8 = null,
    allow_always: ?[]const u8 = null,
    reject_once: ?[]const u8 = null,
    reject_always: ?[]const u8 = null,
    call: ?[]const u8 = null,
};

/// One tool call of the open turn, as merged from its reports. Strings are in
/// the turn arena; `body` is gpa-owned, since `content` replaces it each time.
const Tool = struct {
    acp_kind: []const u8 = "other",
    name: ?[]const u8 = null,
    title: []const u8 = "",
    status: []const u8 = "pending",
    raw: ?[]const u8 = null,
    paths: std.ArrayList([]const u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    started: bool = false,
    ended: bool = false,
    named: bool = false,
    declined: bool = false,

    /// Only changed fields are sent. Once logged, a call keeps its title.
    fn merge(self: *Tool, tt: std.mem.Allocator, a: std.mem.Allocator, v: Value) !void {
        if (str(v, "status")) |x| self.status = try tt.dupe(u8, x);
        if (field(v, "rawInput")) |raw| {
            if (!(raw == .object and raw.object.count() == 0)) self.raw = try tt.dupe(u8, (try contract.rawJson(a, raw)).?);
        }
        if (field(v, "locations")) |list| if (list == .array) for (list.array.items) |l| try self.addPath(tt, str(l, "path") orelse continue);
        if (field(v, "content")) |list| if (list == .array) for (list.array.items) |c| {
            if (eql(str(c, "type") orelse "", "diff")) try self.addPath(tt, str(c, "path") orelse continue);
        };
        if (self.started) return;
        if (str(v, "kind")) |x| self.acp_kind = try tt.dupe(u8, x);
        if (str(v, "name")) |x| self.name = try tt.dupe(u8, x);
        if (str(v, "title")) |x| self.title = try tt.dupe(u8, x);
    }

    fn addPath(self: *Tool, tt: std.mem.Allocator, path: []const u8) !void {
        for (self.paths.items) |p| if (eql(p, path)) return;
        try self.paths.append(tt, try tt.dupe(u8, path));
    }
};

/// One agent's connection. `life` lives as long as the process (reset by
/// `start`), `turn` as long as the open turn.
const State = struct {
    life: std.heap.ArenaAllocator,
    turn: std.heap.ArenaAllocator,
    phase: enum { initializing, opening, ready, failed } = .initializing,
    next_id: u64 = 0,
    /// Requests venom sent and still waits on, by JSON-RPC id.
    calls: std.AutoHashMapUnmanaged(u64, Purpose) = .empty,
    /// Messages waiting for the conversation to be between turns.
    queue: std.ArrayList([]u8) = .empty,
    cwd: []const u8 = "",
    writable: []const []const u8 = &.{},
    resume_session: ?[]const u8 = null,
    session: ?[]const u8 = null,
    /// The `session/prompt` in flight.
    prompt_id: ?u64 = null,
    /// `session/cancel` was sent for it.
    cancelled: bool = false,
    /// The open message's text, and its `messageId` (gpa-owned; turn arena).
    text: std.ArrayList(u8) = .empty,
    message: ?[]const u8 = null,
    last_plan: ?[]const u8 = null,
    /// Pending permission requests, by JSON-RPC id as JSON text (turn arena).
    asks: std.StringHashMapUnmanaged(Ask) = .empty,
    /// The turn's tool calls, by `toolCallId` (keys in the turn arena).
    tools: std.StringHashMapUnmanaged(Tool) = .empty,

    fn call(self: *State, alloc: std.mem.Allocator, purpose: Purpose) !u64 {
        const id = self.next_id;
        try self.calls.put(alloc, id, purpose);
        self.next_id += 1;
        return id;
    }

    fn tool(self: *State, alloc: std.mem.Allocator, id: []const u8) !*Tool {
        const tt = self.turn.allocator();
        const got = try self.tools.getOrPut(alloc, id);
        if (!got.found_existing) {
            got.key_ptr.* = try tt.dupe(u8, id);
            got.value_ptr.* = .{};
        }
        return got.value_ptr;
    }

    /// Whether a call names a path outside the agent's scope.
    fn outside(self: *State, alloc: std.mem.Allocator, t: *const Tool) !bool {
        if (self.writable.len == 0) return false;
        if (eql(t.acp_kind, "read") or eql(t.acp_kind, "search")) return false;
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        for (t.paths.items) |path| if (try agent_scope.outsideRoots(arena.allocator(), self.writable, self.cwd, path)) return true;
        return false;
    }

    fn endTurn(self: *State, alloc: std.mem.Allocator) void {
        var it = self.tools.valueIterator();
        while (it.next()) |t| t.body.deinit(alloc);
        self.tools.clearRetainingCapacity();
        self.text.clearRetainingCapacity();
        self.message = null;
        self.last_plan = null;
        self.asks = .empty;
        self.cancelled = false;
        _ = self.turn.reset(.retain_capacity);
    }

    /// A new process: nothing of the previous one carries over.
    fn reset(self: *State, alloc: std.mem.Allocator) void {
        for (self.queue.items) |t| alloc.free(t);
        self.queue.clearRetainingCapacity();
        self.calls.clearRetainingCapacity();
        self.endTurn(alloc);
        _ = self.life.reset(.retain_capacity);
        const kept = self.*;
        self.* = .{ .life = kept.life, .turn = kept.turn, .calls = kept.calls, .queue = kept.queue, .text = kept.text, .tools = kept.tools };
    }

    fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.reset(alloc);
        self.calls.deinit(alloc);
        self.queue.deinit(alloc);
        self.text.deinit(alloc);
        self.tools.deinit(alloc);
        self.turn.deinit();
        self.life.deinit();
    }
};

/// A JSON-RPC id as JSON text: what an answer writes back.
fn idKey(a: std.mem.Allocator, id: Value) ![]const u8 {
    return switch (id) {
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        else => std.json.Stringify.valueAlloc(a, id, .{}),
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn field(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .null) null else x;
}
fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return if (x == .string) x.string else null;
}
fn int(v: Value, key: []const u8) ?i64 {
    const x = field(v, key) orelse return null;
    return if (x == .integer) x.integer else null;
}
fn count(v: Value, key: []const u8) u64 {
    return @intCast(@max(0, int(v, key) orelse 0));
}
fn boolean(v: Value, key: []const u8) bool {
    const x = field(v, key) orelse return false;
    return x == .bool and x.bool;
}

comptime {
    @import("iface").assertImplements(contract.Adapter.VTable, Acp);
}

test {
    _ = @import("acp_tests.zig");
}
