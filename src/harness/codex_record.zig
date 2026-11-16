//! codex catch-up (`catch_up = api`): imports
//! the turns Codex's own TUI ran from the thread's record and replays them into
//! the agent's conversation, so they are logged like any other turn
//! (`turn.started {origin: catch_up}`, prompt, text, tool calls, usage,
//! `turn.ended`) with venom's ids.
//!
//! The turns come from a short-lived `codex app-server`, which exits before the
//! replay starts: `initialize`, then `thread/turns/list {sortDirection: desc,
//! itemsView: full}` page by page, newest first, until the last turn venom knows
//! (`harness_last_turn`) or a turn from before the hand-over (`since_ms`). The
//! list needs no `thread/resume`, so no MCP server starts and the thread is not
//! loaded. It runs on the daemon's reactor, like the Claude Code read, bounded
//! by `deadline_ms`; 0.167.0 answers within about 60 ms.
//!
//! The list carries no usage, and `thread/resume` replays only the thread's
//! total, which would need a base that outlives the daemon and cannot split
//! several turns. So per-turn tokens come from the rollout file `thread/read`
//! names (`thread.path`), read tolerantly: `task_started` and `turn_context`
//! say which turn is running, each `token_count` carries the thread's running
//! total, and a turn's usage is how much that total grew during it. The rollout
//! is not a stable format, so without it a turn is still imported, with no
//! usage and a warning.
//!
//! Mapping (`Turn` of the list):
//!
//! | item | normalized |
//! |---|---|
//! | `userMessage` | `turn.prompt` (its text parts) |
//! | `agentMessage` | `text {final: true}` |
//! | tool items | `tool.started` and `tool.ended`, as a live `item/completed` |
//! | `status: completed` | `turn.ended completed` |
//! | `status: interrupted`, `inProgress` | `turn.ended interrupted` (a forced take-back can catch a turn still running) |
//! | `status: failed` | `turn.ended interrupted` with the classified error code: it happened while the human watched, and take-back settles the agent |
const std = @import("std");
const supervisor = @import("supervisor");
const contract = @import("contract.zig");
const codex = @import("codex.zig");
const process = @import("process.zig");
const version = @import("version.zig");
const claude_transcript = @import("claude_transcript.zig");
const Conversation = contract.Conversation;
const Process = process.Process;
const Tokens = codex.Tokens;
const Value = std.json.Value;
const c = std.c;

/// How long the whole read may take: it holds up the daemon's reactor.
pub const deadline_ms = 10_000;
/// Turns per page. Few: a page is one line, and `process.line_max` ends it.
const page_turns = 8;

const Thread = struct {
    /// Oldest first.
    turns: []const Value,
    path: ?[]const u8 = null,
    model: []const u8 = "",
};

/// `catch_up`. `conv` must be between turns and have no process.
pub fn catchUp(cx: *codex.Codex, conv: *Conversation, record: contract.Resume) !u32 {
    if (conv.inTurn()) return error.TurnRunning;
    var arena: std.heap.ArenaAllocator = .init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const thread = try readThread(cx, a, record);
    if (thread.turns.len == 0) return 0;
    var usage: Usage = .empty;
    if (thread.path) |path| {
        if (claude_transcript.readRegular(a, path)) |bytes| {
            usage = try usageByTurn(a, bytes);
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => if (cx.logger) |l| l.warn("cannot read the rollout; the imported turns have no usage", .{ .agent = conv.agent, .rollout = path }),
        }
    } else if (cx.logger) |l| l.warn("codex names no rollout; the imported turns have no usage", .{ .agent = conv.agent });
    for (thread.turns) |turn| try replayTurn(cx, conv, turn, usage, thread.model);
    return @intCast(thread.turns.len);
}

fn replayTurn(cx: *codex.Codex, conv: *Conversation, turn: Value, usage: Usage, model: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const id = str(turn, "id");
    try conv.turnStarted(id, "catch_up");
    if (field(turn, "items")) |items| if (items == .array) for (items.array.items) |item| {
        const kind = str(item, "type") orelse continue;
        if (eql(kind, "userMessage")) {
            const text = try promptOf(a, item);
            if (text.len > 0) try conv.prompt(text);
        } else if (eql(kind, "agentMessage")) {
            try conv.text(str(item, "text") orelse "", true);
        } else try cx.toolCompleted(conv, item, conv.cwd);
    };
    if (id) |t| if (usage.get(t)) |u| if (!u.tokens.isZero()) {
        try conv.usage(.{ .model = u.model orelse model, .tokens_in = u.tokens.input -| u.tokens.cached, .tokens_out = u.tokens.output, .cache_read = u.tokens.cached, .cache_write = u.tokens.cache_write });
    };
    const status = str(turn, "status") orelse "completed";
    if (eql(status, "completed")) return conv.turnEnded("completed", null);
    if (eql(status, "failed")) return conv.turnEnded("interrupted", codex.failureCode(field(turn, "error")));
    return conv.turnEnded("interrupted", null);
}

/// The text parts of a `userMessage`, one per line.
fn promptOf(a: std.mem.Allocator, item: Value) ![]const u8 {
    const content = field(item, "content") orelse return "";
    if (content != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (content.array.items) |part| {
        if (!eql(str(part, "type") orelse "", "text")) continue;
        if (out.items.len > 0) try out.append(a, '\n');
        try out.appendSlice(a, str(part, "text") orelse "");
    }
    return out.items;
}

// ------------------------------------------------------------ the app-server

fn readThread(cx: *codex.Codex, a: std.mem.Allocator, record: contract.Resume) !Thread {
    var leaders: supervisor.Leaders = .init(cx.gpa, .{});
    defer leaders.deinit();
    var p = try Process.spawn(cx.gpa, &leaders, .{ .argv = cx.argv, .cwd = record.cwd, .env = try codex.withHome(a, cx.env, record.home) });
    defer p.deinit();
    // It only read, and nothing of it is wanted any more.
    defer version.stop(&p, &leaders) catch {};
    var rpc: Rpc = .{ .p = &p, .a = a, .deadline = supervisor.monotonicMs() + deadline_ms };
    _ = try rpc.call("initialize", .{ .clientInfo = .{ .name = "venom", .title = "venom", .version = cx.client_version } });
    try rpc.write(.{ .method = "initialized", .params = struct {}{} });

    var newest_first: std.ArrayList(Value) = .empty;
    var cursor: ?[]const u8 = null;
    pages: while (true) {
        const page = try rpc.call("thread/turns/list", .{ .threadId = record.harness_session, .cursor = cursor, .limit = page_turns, .sortDirection = "desc", .itemsView = "full" });
        const data = field(page, "data") orelse return error.HarnessCatchUp;
        if (data != .array) return error.HarnessCatchUp;
        for (data.array.items) |turn| {
            if (!isNew(turn, record)) break :pages;
            try newest_first.append(a, turn);
        }
        cursor = str(page, "nextCursor") orelse break;
    }
    std.mem.reverse(Value, newest_first.items);
    var out: Thread = .{ .turns = newest_first.items };
    if (out.turns.len == 0) return out;
    const read = try rpc.call("thread/read", .{ .threadId = record.harness_session, .includeTurns = false });
    if (field(read, "thread")) |t| {
        out.path = str(t, "path");
        out.model = str(t, "model") orelse "";
    }
    return out;
}

/// Whether `turn`, reached newest first, ran after the hand-over: not the last
/// turn venom knows, and not started before venom handed the thread over. The
/// list gives whole seconds, so the same second counts as after: the id is
/// what tells a turn that ended just before.
fn isNew(turn: Value, record: contract.Resume) bool {
    if (record.harness_last_turn) |known| if (str(turn, "id")) |id| if (eql(id, known)) return false;
    const since = record.since_ms orelse return true;
    const started = int(turn, "startedAt") orelse return true;
    return started >= @divFloor(since, 1000);
}

/// A blocking JSON-RPC client over one process: everything but the answer it
/// waits for is skipped, and every wait is bounded by `deadline`.
const Rpc = struct {
    p: *Process,
    a: std.mem.Allocator,
    deadline: i64,
    next: i64 = 0,

    fn write(self: *Rpc, value: anytype) !void {
        const line = try std.json.Stringify.valueAlloc(self.a, value, .{ .emit_null_optional_fields = false });
        try self.p.write(line);
        try self.p.write("\n");
    }

    /// The `result` of `method`; a JSON-RPC error is `error.HarnessCatchUp`.
    fn call(self: *Rpc, method: []const u8, params: anytype) !Value {
        const id = self.next;
        self.next += 1;
        try self.write(.{ .method = method, .id = id, .params = params });
        while (true) {
            // Too long a line, or a read that failed, ends the catch-up.
            _ = self.p.pump() catch return error.HarnessCatchUp;
            while (self.p.nextLine()) |line| {
                const v = std.json.parseFromSliceLeaky(Value, self.a, line, .{ .allocate = .alloc_always }) catch continue;
                if (field(v, "method") != null or int(v, "id") != id) continue;
                return field(v, "result") orelse error.HarnessCatchUp;
            }
            if (self.p.stdout < 0) return error.HarnessCatchUp;
            const left = self.deadline - supervisor.monotonicMs();
            if (left <= 0) return error.HarnessCatchUp;
            var fds = [_]c.pollfd{.{ .fd = self.p.stdout, .events = c.POLL.IN, .revents = 0 }};
            _ = c.poll(&fds, fds.len, @intCast(@min(left, 100)));
        }
    }
};

// ------------------------------------------------------------ the rollout

pub const TurnUsage = struct { tokens: Tokens = .{}, model: ?[]const u8 = null };
pub const Usage = std.StringArrayHashMapUnmanaged(TurnUsage);

/// What each turn added to the thread's total (see the file comment), by the
/// harness's turn id. Lines that are not JSON or not understood are skipped.
pub fn usageByTurn(a: std.mem.Allocator, bytes: []const u8) !Usage {
    var out: Usage = .empty;
    var current: ?[]const u8 = null;
    var total: Tokens = .{};
    var per_line: std.heap.ArenaAllocator = .init(a);
    defer per_line.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        // Most of a rollout is message bodies: only these lines are parsed.
        if (std.mem.indexOf(u8, line, "\"token_count\"") == null and std.mem.indexOf(u8, line, "\"task_started\"") == null and std.mem.indexOf(u8, line, "\"turn_context\"") == null) continue;
        _ = per_line.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(Value, per_line.allocator(), line, .{}) catch continue;
        const payload = field(v, "payload") orelse continue;
        const kind = str(v, "type") orelse continue;
        if (eql(kind, "turn_context")) {
            const turn = str(payload, "turn_id") orelse continue;
            const entry = try entryOf(a, &out, turn);
            current = out.keys()[entry];
            if (str(payload, "model")) |m| out.values()[entry].model = try a.dupe(u8, m);
        } else if (eql(kind, "event_msg")) {
            const event = str(payload, "type") orelse continue;
            if (eql(event, "task_started")) {
                const turn = str(payload, "turn_id") orelse continue;
                const entry = try entryOf(a, &out, turn);
                current = out.keys()[entry];
            } else if (eql(event, "token_count")) {
                const info = field(payload, "info") orelse continue;
                const now = Tokens.ofRollout(field(info, "total_token_usage") orelse continue);
                const added = now.minus(total);
                total = now;
                if (current) |turn| {
                    const u = out.getPtr(turn).?;
                    u.tokens = u.tokens.plus(added);
                }
            }
        }
    }
    return out;
}

fn entryOf(a: std.mem.Allocator, out: *Usage, turn: []const u8) !usize {
    if (out.getIndex(turn)) |i| return i;
    try out.put(a, try a.dupe(u8, turn), .{});
    return out.count() - 1;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
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

const testing = std.testing;

test "usageByTurn: what the running total grew by in each turn, with its model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rollout =
        \\{"type":"session_meta","payload":{"id":"thr"}}
        \\{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        \\{"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-a"}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":null}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":5}}}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"cache_write_input_tokens":1,"output_tokens":9}}}}
        \\{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}
        \\this "token_count" line is torn
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"cache_write_input_tokens":1,"output_tokens":9}}}}
        \\{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}
        \\{"type":"turn_context","payload":{"turn_id":"t2","model":"gpt-b"}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":90,"cache_write_input_tokens":1,"output_tokens":12}}}}
    ;
    const usage = try usageByTurn(a, rollout);
    try testing.expectEqual(@as(usize, 2), usage.count());
    const t1 = usage.get("t1").?;
    try testing.expectEqual(@as(u64, 150), t1.tokens.input);
    try testing.expectEqual(@as(u64, 60), t1.tokens.cached);
    try testing.expectEqual(@as(u64, 1), t1.tokens.cache_write);
    try testing.expectEqual(@as(u64, 9), t1.tokens.output);
    try testing.expectEqualStrings("gpt-a", t1.model.?);
    const t2 = usage.get("t2").?;
    try testing.expectEqual(@as(u64, 50), t2.tokens.input);
    try testing.expectEqual(@as(u64, 30), t2.tokens.cached);
    try testing.expectEqual(@as(u64, 3), t2.tokens.output);
    try testing.expectEqualStrings("gpt-b", t2.model.?);
}

test "isNew: not the last known turn, nor one from before the hand-over; the same second counts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const turn = struct {
        fn of(a: std.mem.Allocator, json: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, a, json, .{});
        }
    }.of;
    const a = arena.allocator();
    const record: contract.Resume = .{ .harness = "codex", .harness_session = "thr", .cwd = "/w", .harness_last_turn = "t1", .since_ms = 10_500 };
    try testing.expect(!isNew(try turn(a, "{\"id\":\"t1\",\"startedAt\":11}"), record));
    try testing.expect(isNew(try turn(a, "{\"id\":\"t2\",\"startedAt\":10}"), record));
    try testing.expect(!isNew(try turn(a, "{\"id\":\"t0\",\"startedAt\":9}"), record));
    try testing.expect(isNew(try turn(a, "{\"id\":\"t3\",\"startedAt\":null}"), record));
    const bare: contract.Resume = .{ .harness = "codex", .harness_session = "thr", .cwd = "/w" };
    try testing.expect(isNew(try turn(a, "{\"id\":\"t0\",\"startedAt\":9}"), bare));
}
