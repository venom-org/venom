//! The fake harness's adapter: venom's side of `venom-fake-harness`
//! (`fake_main.zig`, which documents the line protocol). It implements the
//! whole adapter interface, so tests drive agents through every state with
//! a real child process and no vendor CLI. Later adapters (claude-code,
//! codex) follow the same shape: `start` builds argv,
//! `send`/`respond` write lines, `interrupt` signals, `decode` maps output
//! onto the `Conversation` helpers.
const std = @import("std");
const contract = @import("contract.zig");
const Conversation = contract.Conversation;

pub const name = "fake";

pub const Fake = struct {
    /// Path of the `venom-fake-harness` binary.
    exe: []const u8,
    /// The script (JSON) every process of this adapter runs.
    script: []const u8 = "{}",
    /// Where the fake keeps its counters (`crash_on_resume`).
    state_dir: ?[]const u8 = null,

    pub fn adapter(self: *Fake) contract.Adapter {
        return .init(self);
    }

    pub fn probe(self: *Fake, _: std.mem.Allocator) anyerror!contract.Descriptor {
        return .{
            .harness = name,
            .harness_version = "0.1.0",
            .channel = "ndjson",
            .min_version = "0.1.0",
            .tested_version = "0.1.0",
            .caps = self.caps(),
        };
    }

    pub fn caps(_: *Fake) contract.Caps {
        return .{
            .steer = .queue,
            .interrupt = true,
            .permission_modes = &.{ "manual", "acceptEdits", "plan" },
            .requests = .{ .approval = .{ .edit = true, .always = .session_rule }, .question = .{ .free_text = true }, .plan = true },
            .fork = .head,
            .release = true,
            .usage = .{ .per_turn = true, .context = .estimate },
            .compact = true,
            .mcp_off = true,
        };
    }

    pub fn compact(_: *Fake, conv: *Conversation) anyerror!void {
        try conv.writeJson(.{ .op = "compact" });
    }

    pub fn start(self: *Fake, a: std.mem.Allocator, params: contract.Start) anyerror!contract.Spawn {
        // The id is chosen up front.
        const session = params.harness_session orelse try std.fmt.allocPrint(a, "fake-{s}", .{params.agent});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ self.exe, if (params.harness_session != null) "--resume" else "--session", session, "--script", self.script });
        if (self.state_dir) |d| try argv.appendSlice(a, &.{ "--state", d });
        // Scope: the fake asks before an edit outside these, the
        // way a sandbox or permission rule would. A whole-workspace scope
        // passes its root, which covers everything under the cwd.
        for (params.writable) |w| try argv.appendSlice(a, &.{ "--writable", w });
        if (params.permission_mode) |m| try argv.appendSlice(a, &.{ "--permission-mode", m });
        for (params.mcp_off) |m| try argv.appendSlice(a, &.{ "--mcp-off", m });
        return .{ .argv = argv.items, .cwd = params.cwd, .harness_session = session };
    }

    pub fn send(_: *Fake, conv: *Conversation, text: []const u8, mode: contract.SendMode) anyerror!void {
        if (mode == .interrupt_then_send and conv.inTurn()) try conv.signal(.INT);
        try conv.writeJson(.{ .op = "send", .text = text });
    }

    pub fn interrupt(_: *Fake, conv: *Conversation) anyerror!void {
        if (!conv.inTurn()) return;
        try conv.signal(.INT);
    }

    pub fn respond(_: *Fake, conv: *Conversation, request: contract.Pending, answer: contract.Answer) anyerror!void {
        try conv.writeJson(.{ .op = "respond", .id = request.harness_ref, .answer = answer.answer, .reason = answer.reason, .args = answer.args_json });
    }

    pub fn decode(_: *Fake, conv: *Conversation, line: []const u8) anyerror!void {
        var arena: std.heap.ArenaAllocator = .init(conv.gpa);
        defer arena.deinit();
        // A line that is not JSON is skipped.
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return;
        const t = str(v, "t") orelse return;
        if (eql(t, "init")) {
            try conv.session(str(v, "session") orelse return error.HarnessProtocol, str(v, "model"), str(v, "version"));
            if (v.object.get("mcp")) |list| if (list == .array) {
                var servers: std.ArrayList([]const u8) = .empty;
                for (list.array.items) |item| if (item == .string) try servers.append(arena.allocator(), item.string);
                try conv.mcpServers(servers.items);
            };
        } else if (eql(t, "turn")) {
            try conv.turnStarted(str(v, "id"), "user");
        } else if (eql(t, "text")) {
            try conv.text(str(v, "text") orelse "", true);
        } else if (eql(t, "tool")) {
            try conv.toolStarted(.{ .harness_ref = str(v, "id") orelse "", .kind = str(v, "kind") orelse "other", .name = str(v, "name") orelse "", .title = str(v, "title") orelse "", .raw_input = if (v.object.get("input")) |input| try contract.rawJson(arena.allocator(), input) else null, .args = if (str(v, "server")) |s| .{ .server = s } else null });
        } else if (eql(t, "tool_end")) {
            const ms = int(v, "ms");
            try conv.toolEnd(str(v, "id") orelse "", .{ .status = str(v, "status") orelse "ok", .exit = int(v, "exit"), .duration_ms = if (ms) |m| @intCast(@max(0, m)) else null, .body = str(v, "body") });
        } else if (eql(t, "ask")) {
            var answers: std.ArrayList([]const u8) = .empty;
            if (v.object.get("answers")) |list| if (list == .array) for (list.array.items) |item| if (item == .string) try answers.append(arena.allocator(), item.string);
            try conv.request(.{ .harness_ref = str(v, "id") orelse "", .kind = str(v, "kind") orelse "approval", .call_ref = str(v, "call"), .reason = str(v, "reason") orelse "", .answers = answers.items, .input_json = str(v, "input"), .options = if (v.object.get("questions")) |qs| try contract.questionOptions(arena.allocator(), qs, false) else &.{} });
        } else if (eql(t, "resolved")) {
            // Confirms an answer venom sent; anything else the harness withdrew.
            try conv.requestResolved(str(v, "id") orelse "", "venom");
        } else if (eql(t, "usage")) {
            try conv.usage(.{ .model = str(v, "model") orelse "", .tokens_in = count(v, "in"), .tokens_out = count(v, "out"), .cache_read = count(v, "cache_read"), .cache_write = count(v, "cache_write") });
        } else if (eql(t, "context")) {
            try conv.contextFill(count(v, "used"), count(v, "window"), "estimate", if (int(v, "system")) |n| @intCast(@max(0, n)) else null, if (int(v, "tools")) |n| @intCast(@max(0, n)) else null);
        } else if (eql(t, "end")) {
            const reason = str(v, "reason") orelse "completed";
            const resets: ?[]const u8 = if (int(v, "resets_at")) |r| try contract.rfc3339(arena.allocator(), r) else null;
            try conv.turnEnd(.{ .reason = reason, .error_code = if (eql(reason, "failed")) "failed.harness_turn" else null, .resets_at = resets });
        }
        // Unknown types are ignored.
    }

    pub fn fork(_: *Fake, a: std.mem.Allocator, conv: *Conversation, _: ?[]const u8) anyerror!contract.ForkStep {
        if (conv.inTurn()) return error.TurnRunning;
        const session = conv.harness_session orelse return error.HarnessSessionNotFound;
        // `head`: a new conversation from the latest turn. The fake has no
        // history to copy, so the new id is all there is.
        return .{ .done = try std.fmt.allocPrint(a, "{s}-fork{d}", .{ session, conv.turns }) };
    }

    pub fn release(_: *Fake, conv: *Conversation) anyerror!void {
        if (conv.inTurn()) return error.TurnRunning;
        conv.closeInput(); // the fake exits 0 at end of input
    }

    pub fn resume_command(_: *Fake, _: std.mem.Allocator, _: contract.Resume) anyerror!contract.Spawn {
        return error.UnsupportedCapability; // no TUI (resume_tui = false)
    }

    pub fn catch_up(_: *Fake, _: *Conversation, _: contract.Resume) anyerror!u32 {
        return error.UnsupportedCapability; // catch_up = none
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
fn int(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}
fn count(v: std.json.Value, key: []const u8) u64 {
    return @intCast(@max(0, int(v, key) orelse 0));
}

comptime {
    // The nullclaw pattern: a missing or mistyped operation fails here.
    @import("iface").assertImplements(contract.Adapter.VTable, Fake);
}
