//! claude-code adapter tests. None of them runs the real
//! `claude`: unit tests feed recorded stream-json lines
//! straight into `decode`, and the host tests run
//! `testdata/fake-claude.py`, which replays a trace on stdout and waits for
//! permission results the way Claude Code waits on venom's MCP tool.
const std = @import("std");
const eventlog = @import("../eventlog/root.zig");
const harness = @import("root.zig");
const contract = harness.contract;
const claude_code = harness.claude_code;
const ClaudeCode = claude_code.ClaudeCode;
const Conversation = contract.Conversation;
const Host = harness.Host;
const Engine = eventlog.Engine;
const AgentState = eventlog.agent.State;
const c = std.c;
const testing = std.testing;

// ------------------------------------------------------------ fixtures

/// Records normalized events as `type {json}` lines. Measured durations
/// and raw inputs are dropped so the lines are stable; so are tool `args` and
/// `body` and `context` events unless `full` is set.
const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList([]const u8) = .empty,
    full: bool = false,

    fn sink(self: *Recorder) contract.Sink {
        return .{ .ptr = self, .emit = emit };
    }
    fn emit(ptr: *anyopaque, _: *Conversation, e: contract.Normalized) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const a = self.arena.allocator();
        var copy = e;
        if (copy == .tool_ended) copy.tool_ended.duration_ms = null;
        if (copy == .tool_started) copy.tool_started.raw_input = null;
        if (!self.full) switch (copy) {
            .tool_started => copy.tool_started.args = null,
            .tool_ended => copy.tool_ended.body = null,
            .request => copy.request.input_digest = null,
            .context => return,
            else => {},
        };
        const line = switch (copy) {
            inline else => |p, tag| try std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(tag), try std.json.Stringify.valueAlloc(a, p, .{ .emit_null_optional_fields = false }) }),
        };
        try self.events.append(a, line);
    }
    /// The events since `from`.
    fn since(self: *Recorder, from: usize) []const []const u8 {
        return self.events.items[from..];
    }
};

/// Captures what the adapter writes to the harness, and its signals.
const Pipe = struct {
    arena: std.heap.ArenaAllocator,
    written: std.ArrayList(u8) = .empty,
    signals: u32 = 0,
    closed: bool = false,

    fn channel(self: *Pipe) contract.Channel {
        return .{ .ptr = self, .vtable = &.{ .write = write, .signal = signal, .close_input = closeInput } };
    }
    fn write(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        try self.written.appendSlice(self.arena.allocator(), bytes);
    }
    fn signal(ptr: *anyopaque, sig: std.posix.SIG) anyerror!void {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        if (sig == .INT) self.signals += 1;
    }
    fn closeInput(ptr: *anyopaque) void {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

/// Stands in for venom's MCP server: keeps the last permission result.
const Replies = struct {
    arena: std.heap.ArenaAllocator,
    last: []const u8 = "",
    tool_use_id: []const u8 = "",
    /// When set, also writes each result to `<dir>/<tool_use_id>` for
    /// fake-claude.
    dir: ?[]const u8 = null,

    fn replier(self: *Replies) claude_code.Replier {
        return .{ .ptr = self, .reply = reply };
    }
    fn reply(ptr: *anyopaque, _: []const u8, tool_use_id: []const u8, _: u64, result: []const u8) anyerror!void {
        const self: *Replies = @ptrCast(@alignCast(ptr));
        const a = self.arena.allocator();
        self.last = try a.dupe(u8, result);
        self.tool_use_id = try a.dupe(u8, tool_use_id);
        if (self.dir) |d| {
            // Written whole, then renamed, so the fake never reads half.
            const tmp = try std.fmt.allocPrintSentinel(a, "{s}/.{s}.tmp", .{ d, tool_use_id }, 0);
            const dst = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ d, tool_use_id }, 0);
            try writeFile(tmp, result, 0o644);
            if (c.rename(tmp, dst) != 0) return error.RenameFailed;
        }
    }
};

/// One adapter and one conversation, driven by hand.
const Unit = struct {
    rec: Recorder,
    pipe: Pipe,
    replies: Replies,
    cc: ClaudeCode,
    conv: Conversation,

    fn init(self: *Unit, prompts: bool) !void {
        self.rec = .{ .arena = .init(testing.allocator) };
        self.pipe = .{ .arena = .init(testing.allocator) };
        self.replies = .{ .arena = .init(testing.allocator) };
        self.cc = try .init(testing.allocator, .{ .mcp = if (prompts) .{} else null, .replier = if (prompts) self.replies.replier() else null });
        try self.conv.init(testing.allocator, "a2", claude_code.name, "/home/u/venom-org/venom-std-246", .{}, self.rec.sink());
        self.conv.channel = self.pipe.channel();
    }
    fn deinit(self: *Unit) void {
        self.conv.deinit();
        self.cc.deinit();
        self.replies.arena.deinit();
        self.pipe.arena.deinit();
        self.rec.arena.deinit();
    }
    /// What the host does for a send.
    fn send(self: *Unit, text: []const u8) !void {
        try self.cc.send(&self.conv, text, .turn);
        if (!self.conv.inTurn()) self.conv.sending = true;
    }
    fn feed(self: *Unit, lines: []const u8) !void {
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| if (line.len > 0) try self.cc.decode(&self.conv, line);
    }
    /// What the host's `harness.respond` executor does.
    fn answer(self: *Unit, request: []const u8, ans: contract.Answer) !void {
        const p = self.conv.pending(request) orelse return error.NoSuchRequest;
        try self.cc.respond(&self.conv, p, ans);
        self.conv.answered(request);
    }
};

fn expectLines(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} events, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

// A sample turn, claude → venom stdout, split where the permission
// prompt happens.
const trace_init =
    \\{"type":"system","subtype":"init","session_id":"6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41","cwd":"/home/u/venom-org/venom-std-246","model":"claude-opus-4-7","permissionMode":"default","tools":["Bash","Edit","Read","Grep","Glob","mcp__venom__permission_prompt"],"mcp_servers":[{"name":"venom","status":"connected"}],"claude_code_version":"2.1.319","capabilities":["interrupt_receipt_v1"]}
    \\{"type":"assistant","session_id":"6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"I'll run the tests first."},{"type":"tool_use","id":"toolu_01A","name":"Bash","input":{"command":"zig build test","description":"Run proto tests"}}]}}
;
const trace_rest =
    \\{"type":"user","session_id":"6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01A","content":"All 112 tests passed.","is_error":false}]}}
    \\{"type":"assistant","session_id":"6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"All proto tests pass; nothing to fix."}]}}
    \\{"type":"result","subtype":"success","session_id":"6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41","is_error":false,"num_turns":2,"duration_ms":18234,"result":"All proto tests pass; nothing to fix.","usage":{"input_tokens":1200,"output_tokens":812,"cache_read_input_tokens":40210,"cache_creation_input_tokens":2048},"modelUsage":{"claude-opus-4-7":{"inputTokens":1200,"outputTokens":812,"cacheReadInputTokens":40210,"cacheCreationInputTokens":2048,"webSearchRequests":0,"costUSD":0.21,"contextWindow":200000,"maxOutputTokens":32000}},"total_cost_usd":0.21,"permission_denials":[]}
;
const bash_input = "{\"command\":\"zig build test\",\"description\":\"Run proto tests\"}";

// ---------------------------------------------------------- unit tests

test "claude-code: the sample trace maps to its events" {
    var u: Unit = undefined;
    try u.init(true);
    defer u.deinit();
    try u.send("Run the proto tests and fix what fails.");
    try testing.expectEqualStrings("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Run the proto tests and fix what fails.\"}}\n", u.pipe.written.items);
    try u.feed(trace_init);
    // venom's MCP server receives the permission prompt.
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Bash", .input_json = bash_input, .tool_use_id = "toolu_01A" });
    try u.answer("r1", .{ .answer = "allow_once" });
    try testing.expectEqualStrings("toolu_01A", u.replies.tool_use_id);
    try testing.expectEqualStrings("{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"zig build test\",\"description\":\"Run proto tests\"}}", u.replies.last);
    try u.feed(trace_rest);
    try expectLines(&.{
        "session {\"harness_session\":\"6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41\",\"model\":\"claude-opus-4-7\",\"harness_version\":\"2.1.319\",\"cwd\":\"/home/u/venom-org/venom-std-246\"}",
        "mcp_servers {\"servers\":[\"venom\"]}",
        "turn_started {\"turn\":\"t1\",\"origin\":\"user\"}",
        "text {\"turn\":\"t1\",\"message\":\"m1\",\"text\":\"I'll run the tests first.\",\"final\":true}",
        "tool_started {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build test\",\"status\":\"pending\",\"harness_ref\":\"toolu_01A\"}",
        "request {\"turn\":\"t1\",\"request\":\"r1\",\"kind\":\"approval\",\"call\":\"c1\",\"reason\":\"Bash zig build test\",\"answers\":[\"allow_once\",\"allow_always\",\"allow_edited\",\"deny\",\"cancel_turn\"]}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build test\",\"status\":\"ok\"}",
        "text {\"turn\":\"t1\",\"message\":\"m2\",\"text\":\"All proto tests pass; nothing to fix.\",\"final\":true}",
        "usage {\"turn\":\"t1\",\"model\":\"claude-opus-4-7\",\"tokens_in\":1200,\"tokens_out\":812,\"cache_read\":40210,\"cache_write\":2048,\"includes_subagents\":true,\"source\":\"exact\"}",
        "turn_ended {\"turn\":\"t1\",\"reason\":\"completed\"}",
    }, u.rec.events.items);
    try testing.expectEqualStrings("6f1c2e0a-7d1b-4c55-9a1e-3f0d7b2c8e41", u.conv.harness_session.?);
    try testing.expectEqual(@as(?u64, 200000), u.cc.contextOf("a2").?.window);
}

test "claude-code: tool args per kind, bodies, and the context estimate" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    u.rec.full = true;
    u.conv.body_max = 16;
    try u.send("go");
    try u.feed(
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"e1","name":"Edit","input":{"file_path":"/w/a.zig","old_string":"a\nb\n","new_string":"a\nc\nd"}},{"type":"tool_use","id":"e2","name":"MultiEdit","input":{"file_path":"/w/b.zig","edits":[{"old_string":"x","new_string":"y\nz"},{"old_string":"","new_string":"w"}]}},{"type":"tool_use","id":"e3","name":"Write","input":{"file_path":"/w/c.zig","content":"1\n2\n3\n"}},{"type":"tool_use","id":"e4","name":"NotebookEdit","input":{"notebook_path":"/w/n.ipynb","edit_mode":"delete"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":500,"cache_creation_input_tokens":90,"output_tokens":5}}}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/w/a.zig"}},{"type":"tool_use","id":"g1","name":"Grep","input":{"pattern":"fn main","path":"src"}},{"type":"tool_use","id":"l1","name":"Glob","input":{"pattern":"**/*.zig"}},{"type":"tool_use","id":"f1","name":"WebFetch","input":{"url":"https://ziglang.org"}},{"type":"tool_use","id":"m1","name":"mcp__venom__agent_list","input":{}},{"type":"tool_use","id":"a1","name":"Agent","input":{"description":"look"}},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[]}},{"type":"tool_use","id":"o1","name":"Frobnicate","input":{}}]}}
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":[{"type":"text","text":"const a = 1;"},{"type":"image"},{"type":"text","text":"const b = 2;"}]},{"type":"tool_result","tool_use_id":"g1","content":"src/main.zig:1"},{"type":"tool_result","tool_use_id":"l1"}]}}
        \\{"type":"result","subtype":"success","is_error":false,"modelUsage":{"haiku":{"inputTokens":1,"contextWindow":50000},"m":{"inputTokens":10,"contextWindow":200000}}}
    );
    var started: std.ArrayList([]const u8) = .empty;
    var ended: std.ArrayList([]const u8) = .empty;
    var context: ?[]const u8 = null;
    for (u.rec.events.items) |e| {
        if (std.mem.startsWith(u8, e, "tool_started ")) try started.append(u.rec.arena.allocator(), e[std.mem.indexOf(u8, e, "\"name\"").?..]);
        if (std.mem.startsWith(u8, e, "tool_ended ") and std.mem.indexOf(u8, e, "\"body\"") != null) try ended.append(u.rec.arena.allocator(), e[std.mem.indexOf(u8, e, "\"body\"").?..]);
        if (std.mem.startsWith(u8, e, "context ")) context = e;
    }
    try expectLines(&.{
        "\"name\":\"Edit\",\"title\":\"/w/a.zig\",\"status\":\"pending\",\"harness_ref\":\"e1\",\"args\":{\"path\":\"/w/a.zig\",\"change\":\"modify\",\"added\":3,\"removed\":2}}",
        "\"name\":\"MultiEdit\",\"title\":\"/w/b.zig\",\"status\":\"pending\",\"harness_ref\":\"e2\",\"args\":{\"path\":\"/w/b.zig\",\"change\":\"modify\",\"added\":3,\"removed\":1}}",
        "\"name\":\"Write\",\"title\":\"/w/c.zig\",\"status\":\"pending\",\"harness_ref\":\"e3\",\"args\":{\"path\":\"/w/c.zig\",\"change\":\"create\",\"added\":3}}",
        "\"name\":\"NotebookEdit\",\"title\":\"/w/n.ipynb\",\"status\":\"pending\",\"harness_ref\":\"e4\",\"args\":{\"path\":\"/w/n.ipynb\",\"change\":\"delete\"}}",
        "\"name\":\"Read\",\"title\":\"/w/a.zig\",\"status\":\"pending\",\"harness_ref\":\"r1\",\"args\":{\"path\":\"/w/a.zig\"}}",
        "\"name\":\"Grep\",\"title\":\"fn main\",\"status\":\"pending\",\"harness_ref\":\"g1\",\"args\":{\"path\":\"src\",\"query\":\"fn main\"}}",
        "\"name\":\"Glob\",\"title\":\"**/*.zig\",\"status\":\"pending\",\"harness_ref\":\"l1\",\"args\":{\"path\":\"**/*.zig\"}}",
        "\"name\":\"WebFetch\",\"title\":\"https://ziglang.org\",\"status\":\"pending\",\"harness_ref\":\"f1\",\"args\":{\"url\":\"https://ziglang.org\"}}",
        "\"name\":\"mcp__venom__agent_list\",\"title\":\"\",\"status\":\"pending\",\"harness_ref\":\"m1\",\"args\":{\"server\":\"venom\",\"tool\":\"agent_list\"}}",
        "\"name\":\"Agent\",\"title\":\"look\",\"status\":\"pending\",\"harness_ref\":\"a1\",\"args\":{}}",
        "\"name\":\"AskUserQuestion\",\"title\":\"\",\"status\":\"pending\",\"harness_ref\":\"q1\"}",
        "\"name\":\"Frobnicate\",\"title\":\"\",\"status\":\"pending\",\"harness_ref\":\"o1\",\"args\":{}}",
    }, started.items);
    // Text blocks joined, capped at body_max (16) on a UTF-8 boundary.
    try expectLines(&.{
        "\"body\":{\"text\":\"const a = 1;\\ncon\",\"truncated\":true,\"bytes\":25}}",
        "\"body\":{\"text\":\"src/main.zig:1\",\"truncated\":false,\"bytes\":14}}",
    }, ended.items);
    // Input plus cache tokens of the last call, over the main model's window.
    try testing.expectEqualStrings("context {\"used\":600,\"window\":200000,\"source\":\"estimate\"}", context.?);
    // A `[1m]` key is still the main model; without one, the busiest model's
    // window wins over a sub-agent's.
    u.rec.events.clearRetainingCapacity();
    try u.send("again");
    try u.feed(
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[],"usage":{"input_tokens":700}}}
        \\{"type":"result","subtype":"success","is_error":false,"modelUsage":{"haiku":{"inputTokens":9,"contextWindow":50000},"m[1m]":{"inputTokens":20,"contextWindow":1000000}}}
        \\{"type":"system","subtype":"init","session_id":"s1","model":"other"}
    );
    try testing.expectEqual(@as(?u64, 1000000), u.cc.contextOf("a2").?.window);
    try u.send("third");
    try u.feed(
        \\{"type":"result","subtype":"success","is_error":false,"modelUsage":{"haiku":{"inputTokens":30,"contextWindow":50000},"opus":{"inputTokens":5000,"outputTokens":100,"contextWindow":200000}}}
    );
    try testing.expectEqual(@as(?u64, 200000), u.cc.contextOf("a2").?.window);
    // The descriptor declares the estimate.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(contract.Context.estimate, (try u.cc.probe(arena.allocator())).caps.usage.context);
}

test "claude-code: usage is per turn, a mid-turn send is queued, harness-started turns, context estimate" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    try u.send("first");
    try u.feed(
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"one"}],"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":3}}}
    );
    // steer = queue: written now, it starts the next turn.
    try u.send("second");
    try testing.expect(!u.conv.sending);
    const mark = u.rec.events.items.len;
    try u.feed(
        \\{"type":"result","subtype":"success","is_error":false,"modelUsage":{"m":{"inputTokens":10,"outputTokens":4,"cacheReadInputTokens":100,"cacheCreationInputTokens":20,"contextWindow":1000}}}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"two"}]}}
        \\{"type":"result","subtype":"success","is_error":false,"modelUsage":{"m":{"inputTokens":25,"outputTokens":10,"cacheReadInputTokens":300,"cacheCreationInputTokens":20},"haiku":{"inputTokens":7,"outputTokens":1}}}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"a background task finished"}]}}
        \\{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":2,"output_tokens":1}}
    );
    try expectLines(&.{
        "usage {\"turn\":\"t1\",\"model\":\"m\",\"tokens_in\":10,\"tokens_out\":4,\"cache_read\":100,\"cache_write\":20,\"includes_subagents\":true,\"source\":\"exact\"}",
        "turn_ended {\"turn\":\"t1\",\"reason\":\"completed\"}",
        "turn_started {\"turn\":\"t2\",\"origin\":\"user\"}",
        "text {\"turn\":\"t2\",\"message\":\"m2\",\"text\":\"two\",\"final\":true}",
        // Running totals become deltas; one usage per model.
        "usage {\"turn\":\"t2\",\"model\":\"m\",\"tokens_in\":15,\"tokens_out\":6,\"cache_read\":200,\"cache_write\":0,\"includes_subagents\":true,\"source\":\"exact\"}",
        "usage {\"turn\":\"t2\",\"model\":\"haiku\",\"tokens_in\":7,\"tokens_out\":1,\"cache_read\":0,\"cache_write\":0,\"includes_subagents\":true,\"source\":\"exact\"}",
        "turn_ended {\"turn\":\"t2\",\"reason\":\"completed\"}",
        "turn_started {\"turn\":\"t3\",\"origin\":\"harness\"}",
        "text {\"turn\":\"t3\",\"message\":\"m3\",\"text\":\"a background task finished\",\"final\":true}",
        "usage {\"turn\":\"t3\",\"model\":\"m\",\"tokens_in\":2,\"tokens_out\":1,\"cache_read\":0,\"cache_write\":0,\"includes_subagents\":true,\"source\":\"exact\"}",
        "turn_ended {\"turn\":\"t3\",\"reason\":\"completed\"}",
    }, u.rec.since(mark));
    const ctx = u.cc.contextOf("a2").?;
    try testing.expectEqual(@as(u64, 125), ctx.used);
    try testing.expectEqual(@as(?u64, 1000), ctx.window);
    // A new process re-bases the running totals.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try u.cc.start(arena.allocator(), .{ .agent = "a2", .cwd = "/w", .harness_session = "s1" });
    try u.send("third");
    const mark2 = u.rec.events.items.len;
    try u.feed(
        \\{"type":"result","subtype":"success","is_error":false,"modelUsage":{"m":{"inputTokens":4,"outputTokens":2}}}
    );
    try testing.expectEqualStrings("usage {\"turn\":\"t4\",\"model\":\"m\",\"tokens_in\":4,\"tokens_out\":2,\"cache_read\":0,\"cache_write\":0,\"includes_subagents\":true,\"source\":\"exact\"}", u.rec.since(mark2)[1]);
}

test "claude-code: interrupt, usage limits, failed turns, sub-agent calls and lines it does not know" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    try u.send("long");
    try u.feed(
        \\not json at all
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
        \\{"type":"stream_event","event":{"type":"content_block_delta"}}
        \\{"type":"system","subtype":"compact_boundary"}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"tool_use","id":"tA","name":"Agent","input":{"description":"Explore the repo"}}]}}
        \\{"type":"assistant","parent_tool_use_id":"tA","message":{"content":[{"type":"text","text":"sub-agent prose"},{"type":"tool_use","id":"tG","name":"Grep","input":{"pattern":"fn main"}}]}}
        \\{"type":"user","parent_tool_use_id":"tA","message":{"content":[{"type":"tool_result","tool_use_id":"tG","content":"x","is_error":true}]}}
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"unknown","content":"x"}]}}
    );
    try u.cc.interrupt(&u.conv);
    try testing.expectEqual(@as(u32, 1), u.pipe.signals);
    try u.feed(
        \\{"type":"result","subtype":"error_during_execution","is_error":true}
    );
    try expectLines(&.{
        "session {\"harness_session\":\"s1\",\"model\":\"m\",\"cwd\":\"/home/u/venom-org/venom-std-246\"}",
        "turn_started {\"turn\":\"t1\",\"origin\":\"user\"}",
        "tool_started {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"agent\",\"name\":\"Agent\",\"title\":\"Explore the repo\",\"status\":\"pending\",\"harness_ref\":\"tA\"}",
        "tool_started {\"turn\":\"t1\",\"call\":\"c2\",\"kind\":\"search\",\"name\":\"Grep\",\"title\":\"fn main\",\"status\":\"pending\",\"parent_call\":\"c1\",\"harness_ref\":\"tG\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c2\",\"kind\":\"search\",\"name\":\"Grep\",\"title\":\"fn main\",\"status\":\"error\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"agent\",\"name\":\"Agent\",\"title\":\"Explore the repo\",\"status\":\"interrupted\"}",
        "turn_ended {\"turn\":\"t1\",\"reason\":\"interrupted\"}",
    }, u.rec.events.items);
    // Not in a turn: nothing to interrupt.
    try u.cc.interrupt(&u.conv);
    try testing.expectEqual(@as(u32, 1), u.pipe.signals);

    var mark = u.rec.events.items.len;
    try u.send("more");
    try u.feed(
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794067200,"rateLimitType":"five_hour"}}
        \\{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached"}
    );
    // The rejected rate limit's resetsAt.
    try testing.expectEqualStrings("turn_ended {\"turn\":\"t2\",\"reason\":\"limit\",\"error_code\":\"failed.usage_limit\",\"resets_at\":\"2026-11-07T16:00:00Z\"}", u.rec.since(mark)[1]);
    try testing.expectEqual(@as(?i64, 1794067200), u.cc.resetsAt("a2"));

    mark = u.rec.events.items.len;
    try u.send("again");
    try u.feed(
        \\{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":429}
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"x"}]}}
        \\{"type":"result","subtype":"error_max_turns","is_error":true}
    );
    try expectLines(&.{
        "turn_started {\"turn\":\"t3\",\"origin\":\"user\"}",
        // Still limited: the last known reset is kept until a turn completes.
        "turn_ended {\"turn\":\"t3\",\"reason\":\"limit\",\"error_code\":\"failed.usage_limit\",\"resets_at\":\"2026-11-07T16:00:00Z\"}",
        "turn_started {\"turn\":\"t4\",\"origin\":\"harness\"}",
        "text {\"turn\":\"t4\",\"message\":\"m1\",\"text\":\"x\",\"final\":true}",
        "turn_ended {\"turn\":\"t4\",\"reason\":\"failed\",\"error_code\":\"failed.harness_turn\"}",
    }, u.rec.since(mark));
    // An init without a session id is a protocol error for that line.
    try testing.expectError(error.HarnessProtocol, u.cc.decode(&u.conv, "{\"type\":\"system\",\"subtype\":\"init\"}"));
}

test "claude-code: answers become Claude Code permission results" {
    var u: Unit = undefined;
    try u.init(true);
    defer u.deinit();
    try u.send("go");
    try u.feed(
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
    );
    // A prompt that overtakes its stdout line starts the call itself; the
    // later tool_use is not started twice.
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Bash", .input_json = "{\"command\":\"rm -rf build\"}", .tool_use_id = "t1" });
    try u.feed(
        \\{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf build"}}]}}
    );
    try testing.expectError(error.InvalidAnswer, u.answer("r1", .{ .answer = "approve" }));
    try testing.expectError(error.InvalidAnswer, u.answer("r1", .{ .answer = "allow_edited" }));
    try u.answer("r1", .{ .answer = "deny", .reason = "use zig build clean" });
    try testing.expectEqualStrings("{\"behavior\":\"deny\",\"message\":\"use zig build clean\"}", u.replies.last);
    try testing.expectError(error.NoSuchRequest, u.answer("r1", .{ .answer = "deny" }));
    try u.feed(
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"use zig build clean","is_error":true}]}}
    );

    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Bash", .input_json = "{\"command\":\"zig build\"}", .tool_use_id = "t2" });
    try u.answer("r2", .{ .answer = "allow_edited", .args_json = "{\"command\":\"zig build -Doptimize=Debug\"}" });
    try testing.expectEqualStrings("{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"zig build -Doptimize=Debug\"}}", u.replies.last);
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Edit", .input_json = "{\"file_path\":\"/w/a.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}", .tool_use_id = "t3" });
    try u.answer("r3", .{ .answer = "allow_always" });
    try testing.expectEqualStrings("{\"behavior\":\"allow\",\"updatedInput\":{\"file_path\":\"/w/a.zig\",\"old_string\":\"a\",\"new_string\":\"b\"},\"updatedPermissions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Edit\",\"ruleContent\":\"/w/a.zig\"}],\"behavior\":\"allow\",\"destination\":\"session\"}]}", u.replies.last);

    // Questions: ids q1, q2 derived from the order; answers keyed by text.
    const questions = "{\"questions\":[{\"question\":\"Keep varint framing?\",\"header\":\"Framing\",\"options\":[{\"label\":\"Keep varint\"},{\"label\":\"Fixed u32\"}],\"multiSelect\":false}]}";
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "AskUserQuestion", .input_json = questions, .tool_use_id = "t4" });
    try u.answer("r4", .{ .answer = "", .args_json = "{\"q1\":[\"Keep varint\"]}" });
    try testing.expectEqualStrings("{\"behavior\":\"allow\",\"updatedInput\":{\"questions\":[{\"question\":\"Keep varint framing?\",\"header\":\"Framing\",\"options\":[{\"label\":\"Keep varint\"},{\"label\":\"Fixed u32\"}],\"multiSelect\":false}],\"answers\":{\"Keep varint framing?\":\"Keep varint\"}}}", u.replies.last);

    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "ExitPlanMode", .input_json = "{\"plan\":\"1. Add HelloCaps\"}", .tool_use_id = "t5" });
    try testing.expectError(error.InvalidAnswer, u.answer("r5", .{ .answer = "allow_once" }));
    try u.answer("r5", .{ .answer = "reject", .reason = "Split step 2" });
    try testing.expectEqualStrings("{\"behavior\":\"deny\",\"message\":\"Split step 2\"}", u.replies.last);
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "ExitPlanMode", .input_json = "{\"plan\":\"2. Better plan\"}", .tool_use_id = "t6" });
    try u.answer("r6", .{ .answer = "approve" });
    try testing.expectEqualStrings("{\"behavior\":\"allow\",\"updatedInput\":{\"plan\":\"2. Better plan\"}}", u.replies.last);

    // A prompt Claude Code settles on its own is withdrawn (`by: harness`).
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Bash", .input_json = "{\"command\":\"ls\"}", .tool_use_id = "t7" });
    const mark = u.rec.events.items.len;
    try u.feed(
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t7","content":"a b","is_error":false}]}}
    );
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Bash", .input_json = "{\"command\":\"make\"}", .tool_use_id = "t8" });
    try u.answer("r8", .{ .answer = "cancel_turn" });
    try testing.expectEqualStrings("{\"behavior\":\"deny\",\"message\":\"The user cancelled the turn in venom.\",\"interrupt\":true}", u.replies.last);
    try u.feed(
        \\{"type":"result","subtype":"success","is_error":false}
    );
    try expectLines(&.{
        "request_resolved {\"turn\":\"t1\",\"request\":\"r7\",\"by\":\"harness\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c7\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"ls\",\"status\":\"ok\"}",
        "tool_started {\"turn\":\"t1\",\"call\":\"c8\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"make\",\"status\":\"pending\",\"harness_ref\":\"t8\"}",
        "request {\"turn\":\"t1\",\"request\":\"r8\",\"kind\":\"approval\",\"call\":\"c8\",\"reason\":\"Bash make\",\"answers\":[\"allow_once\",\"allow_always\",\"allow_edited\",\"deny\",\"cancel_turn\"]}",
        // Calls that got no tool_result close as interrupted at turn end.
        "tool_ended {\"turn\":\"t1\",\"call\":\"c2\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build\",\"status\":\"interrupted\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c3\",\"kind\":\"edit\",\"name\":\"Edit\",\"title\":\"/w/a.zig\",\"status\":\"interrupted\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c4\",\"kind\":\"question\",\"name\":\"AskUserQuestion\",\"title\":\"\",\"status\":\"interrupted\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c5\",\"kind\":\"plan\",\"name\":\"ExitPlanMode\",\"title\":\"\",\"status\":\"interrupted\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c6\",\"kind\":\"plan\",\"name\":\"ExitPlanMode\",\"title\":\"\",\"status\":\"interrupted\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c8\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"make\",\"status\":\"interrupted\"}",
        "turn_ended {\"turn\":\"t1\",\"reason\":\"completed\"}",
    }, u.rec.since(mark));
    var declined = false;
    var question = false;
    for (u.rec.events.items) |e| {
        if (std.mem.indexOf(u8, e, "\"call\":\"c1\"") != null and std.mem.indexOf(u8, e, "\"status\":\"declined\"") != null) declined = true;
        if (std.mem.startsWith(u8, e, "request {\"turn\":\"t1\",\"request\":\"r4\",\"kind\":\"question\",\"call\":\"c4\",\"reason\":\"Keep varint framing?\"")) question = true;
    }
    try testing.expect(declined and question);
    // Requests of an ended turn are gone.
    try testing.expectError(error.RequestResolved, u.cc.respond(&u.conv, .{ .request = "r8", .harness_ref = "t8", .kind = "approval" }, .{ .answer = "deny" }));
}

test "claude-code: start, resume, fork and release argv; probe follows the approvals path" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Without venom's MCP server Claude Code has no approvals path.
    const bare = try u.cc.probe(a);
    try testing.expect(bare.valid());
    try testing.expect(bare.caps.requests.approval == null);
    try testing.expectEqual(contract.Steer.queue, bare.caps.steer);

    const fresh = try u.cc.start(a, .{ .agent = "a2", .cwd = "/w", .model = "opus", .permission_mode = "acceptEdits" });
    const id = fresh.harness_session.?;
    try testing.expectEqual(@as(usize, 36), id.len);
    try testing.expectEqual(@as(u8, '4'), id[14]);
    try expectArgv(&.{ "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--session-id", id, "--model", "opus", "--permission-mode", "acceptEdits" }, fresh.argv);
    try testing.expectEqualStrings("/w", fresh.cwd.?);
    try testing.expectEqualStrings("VENOM_AGENT", fresh.env[0].name);
    try testing.expect(!std.mem.eql(u8, id, (try u.cc.start(a, .{ .agent = "a2", .cwd = "/w" })).harness_session.?));

    // Scope: in-scope roots outside the cwd are added; out-of-scope
    // repos get session-only ask rules, so their edits and the commands that
    // name them reach venom.
    const scoped = try u.cc.start(a, .{ .agent = "a4", .cwd = "/w", .writable = &.{ "/w/a", "/wt/b-1" }, .read_only = &.{ "/w/c", "/other/d" } });
    try expectArgv(&.{ "--add-dir", "/wt/b-1", "--settings" }, scoped.argv[9..12]);
    const settings = try std.json.parseFromSliceLeaky(std.json.Value, a, scoped.argv[12], .{});
    var ask: std.ArrayList([]const u8) = .empty;
    for (settings.object.get("permissions").?.object.get("ask").?.array.items) |r| try ask.append(a, r.string);
    for ([_][]const u8{ "Edit(//w/c/**)", "Edit(//other/d/**)", "Bash(rm *c/*)", "Bash(rm *c)", "Bash(rm *c *)", "Bash(sed *c/*)", "Bash(cd *c/*)", "Bash(cd *c)", "Bash(rm */other/d/*)", "Bash(mv */other/d)" }) |want| {
        var found = false;
        for (ask.items) |r| found = found or std.mem.eql(u8, r, want);
        testing.expect(found) catch |err| {
            std.debug.print("no rule {s}\n", .{want});
            return err;
        };
    }
    // No read-only repos: no rules.
    const open = try u.cc.start(a, .{ .agent = "a5", .cwd = "/w", .writable = &.{"/w"} });
    for (open.argv) |arg| try testing.expect(!std.mem.eql(u8, arg, "--settings"));

    const again = try u.cc.start(a, .{ .agent = "a2", .cwd = "/w", .harness_session = "s1" });
    try expectArgv(&.{ "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--resume", "s1" }, again.argv);

    // fork = head: the new id is chosen now and its first start forks; once
    // the log has ended `fork_source`, it resumes.
    u.conv.harness_session = "s1";
    const forked = (try u.cc.fork(a, &u.conv, null)).done;
    const first = try u.cc.start(a, .{ .agent = "a3", .cwd = "/w", .harness_session = forked, .fork_source = "s1" });
    try expectArgv(&.{ "--resume", "s1", "--fork-session", "--session-id", forked }, first.argv[7..]);
    try expectArgv(&.{ "--resume", forked }, (try u.cc.start(a, .{ .agent = "a3", .cwd = "/w", .harness_session = forked })).argv[7..]);

    // Compacting is the documented `/compact` message.
    u.pipe.written.clearRetainingCapacity();
    try u.cc.compact(&u.conv);
    try testing.expect(std.mem.indexOf(u8, u.pipe.written.items, "\"content\":\"/compact\"") != null);
    try testing.expect(u.cc.caps().compact and u.cc.caps().mcp_off);

    // Unused MCP servers stay out of the next process, tools and all.
    const off = try u.cc.start(a, .{ .agent = "a4", .cwd = "/w", .harness_session = "s1", .mcp_off = &.{ "linear", "figma" } });
    try expectArgv(&.{ "--resume", "s1", "--disallowedTools", "mcp__linear", "--disallowedTools", "mcp__figma" }, off.argv[7..]);

    try u.cc.release(&u.conv);
    try testing.expect(u.pipe.closed);
    const tui = try u.cc.resume_command(a, .{ .harness = claude_code.name, .harness_session = "s1", .cwd = "/w" });
    try expectArgv(&.{ "claude", "--resume", "s1" }, tui.argv);
    try testing.expect(tui.env.len == 0);
    // Without a config dir take-back could not see the copy a
    // fork's take-over makes, so the take-over is refused.
    try testing.expectError(error.UnsupportedCapability, u.cc.resume_command(a, .{ .harness = claude_code.name, .harness_session = forked, .fork_source = "s1", .cwd = "/w" }));
    // Without Claude Code's config dir there is no transcript to read.
    try testing.expectEqual(contract.CatchUp.none, bare.caps.catch_up);
    try testing.expectError(error.UnsupportedCapability, u.cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "s1", .cwd = "/w" }));

    var with: ClaudeCode = try .init(testing.allocator, .{ .exe = "/opt/claude", .mcp = .{ .command = "/usr/bin/venom" }, .replier = u.replies.replier() });
    defer with.deinit();
    const d = try with.probe(a);
    try testing.expect(d.caps.requests.approval.?.edit);
    try testing.expect(d.caps.requests.plan);
    const s = try with.start(a, .{ .agent = "a2", .cwd = "/w", .harness_session = "s1" });
    try expectArgv(&.{ "/opt/claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--resume", "s1", "--mcp-config", "{\"mcpServers\":{\"venom\":{\"command\":\"/usr/bin/venom\",\"args\":[\"mcp\"]},\"venom-permissions\":{\"command\":\"/usr/bin/venom\",\"args\":[\"agent\",\"permission-server\"]}}}", "--permission-prompt-tool", "mcp__venom-permissions__permission_prompt" }, s.argv);
    try testing.expect(ClaudeCode.of(with.adapter()) == &with);

    // The MCP server alone (no replier) adds no
    // permission prompt tool and declares no requests; its socket goes
    // into the server entry and the harness's environment, never a token.
    var served: ClaudeCode = try .init(testing.allocator, .{ .mcp = .{ .command = "/usr/bin/venom", .socket = "/run/v.sock" } });
    defer served.deinit();
    try testing.expect((try served.probe(a)).caps.requests.approval == null);
    const m = try served.start(a, .{ .agent = "a4", .cwd = "/w", .harness_session = "s4" });
    try expectArgv(&.{ "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--resume", "s4", "--mcp-config", "{\"mcpServers\":{\"venom\":{\"command\":\"/usr/bin/venom\",\"args\":[\"mcp\"],\"env\":{\"VENOM_SOCKET\":\"/run/v.sock\"}}}}" }, m.argv);
    try testing.expectEqual(@as(usize, 2), m.env.len);
    try testing.expectEqualStrings("VENOM_SOCKET", m.env[1].name);
    try testing.expectEqualStrings("/run/v.sock", m.env[1].value);
    try testing.expectEqualStrings("other", claude_code.kindOf("Frobnicate"));
    try testing.expectEqualStrings("mcp", claude_code.kindOf("mcp__linear__get_issue"));
}

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("argv: ", .{});
        for (got) |g| std.debug.print("{s} ", .{g});
        std.debug.print("\n", .{});
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

// ---------------------------------------------- through the host (fake)

/// Two turns: an approved Bash call, then a denied one.
const host_trace =
    \\{"turns":[
    \\ [{"type":"system","subtype":"init","session_id":"$SESSION","cwd":"/w","model":"claude-opus-4-7","claude_code_version":"2.1.319"},
    \\  {"type":"assistant","session_id":"$SESSION","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"I'll run the tests first."},{"type":"tool_use","id":"toolu_01A","name":"Bash","input":{"command":"zig build test","description":"Run proto tests"}}]}},
    \\  {"$await":"toolu_01A",
    \\   "allow":[{"type":"user","session_id":"$SESSION","parent_tool_use_id":null,"tool_use_result":{"stdout":"All 112 tests passed.","exitCode":0},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01A","content":"All 112 tests passed.","is_error":false}]}}],
    \\   "deny":[{"type":"user","session_id":"$SESSION","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01A","content":"denied","is_error":true}]}}]},
    \\  {"type":"assistant","session_id":"$SESSION","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"All proto tests pass; nothing to fix."}],"usage":{"input_tokens":1200,"cache_read_input_tokens":40210,"cache_creation_input_tokens":2048,"output_tokens":812}}},
    \\  {"type":"result","subtype":"success","session_id":"$SESSION","is_error":false,"modelUsage":{"claude-opus-4-7":{"inputTokens":1200,"outputTokens":812,"cacheReadInputTokens":40210,"cacheCreationInputTokens":2048,"contextWindow":200000}}}],
    \\ [{"type":"system","subtype":"init","session_id":"$SESSION","cwd":"/w","model":"claude-opus-4-7","claude_code_version":"2.1.319"},
    \\  {"type":"assistant","session_id":"$SESSION","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02B","name":"Bash","input":{"command":"rm -rf zig-out"}}]}},
    \\  {"$await":"toolu_02B",
    \\   "allow":[{"type":"user","session_id":"$SESSION","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02B","content":"","is_error":false}]}}],
    \\   "deny":[{"type":"user","session_id":"$SESSION","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02B","content":"Keep zig-out","is_error":true}]}}]},
    \\  {"type":"result","subtype":"success","session_id":"$SESSION","is_error":false,"modelUsage":{"claude-opus-4-7":{"inputTokens":1500,"outputTokens":900,"cacheReadInputTokens":80000,"cacheCreationInputTokens":2048}}}]
    \\]}
;

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    log_path: [:0]u8,
    exe: [:0]u8,
    trace: [:0]u8,
    engine: Engine,
    replies: Replies,
    cc: ClaudeCode,
    adapters: [1]harness.host.Registered,
    host: Host,
    pids: std.ArrayList(c.pid_t) = .empty,
    extra: [4][]const u8,

    fn init(self: *Fixture) !void {
        self.pids = .empty;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.dir);
        const a = testing.allocator;
        self.log_path = try std.fmt.allocPrintSentinel(a, "{s}/events.log", .{self.dir}, 0);
        self.exe = try std.fmt.allocPrintSentinel(a, "{s}/fake-claude", .{self.dir}, 0);
        self.trace = try std.fmt.allocPrintSentinel(a, "{s}/trace.json", .{self.dir}, 0);
        try writeFile(self.exe, @embedFile("testdata/fake-claude.py"), 0o755);
        try writeFile(self.trace, host_trace, 0o644);
        self.engine = try Engine.open(a, self.log_path, .{});
        self.replies = .{ .arena = .init(a), .dir = self.dir };
        self.extra = .{ "--fake-trace", self.trace, "--fake-replies", self.dir };
        // `mcp` is set so the argv carries the permission prompt flags
        // (fake-claude ignores them) and probe declares approvals.
        self.cc = try .init(a, .{ .exe = self.exe, .mcp = .{}, .replier = self.replies.replier(), .extra_args = &self.extra });
        self.adapters = .{.{ .harness = claude_code.name, .adapter = self.cc.adapter() }};
        // A small `harness.body_max`, so the cap shows.
        self.host = Host.init(a, &self.engine, &self.adapters, .{ .body_max = 8 });
        self.engine.options.executors = self.host.executor();
        try self.engine.start();
        _ = try self.engine.submit(.{ .create = .{ .agent = "a1", .title = "Run the proto tests", .harness = claude_code.name, .workspace = self.dir } });
    }

    fn deinit(self: *Fixture) void {
        self.host.deinit();
        for (self.pids.items) |pid| {
            testing.expect(c.kill(pid, @fromBackingInt(@intCast(0))) != 0) catch @panic("a harness process outlived the host");
        }
        self.pids.deinit(testing.allocator);
        self.cc.deinit();
        self.replies.arena.deinit();
        self.engine.deinit();
        const a = testing.allocator;
        a.free(self.trace);
        a.free(self.exe);
        a.free(self.log_path);
        a.free(self.dir);
        self.tmp.cleanup();
    }

    /// What a daemon restart leaves: the log, and nothing else.
    fn restart(self: *Fixture) !void {
        const a = testing.allocator;
        self.host.deinit();
        self.cc.deinit();
        self.engine.deinit();
        self.engine = try Engine.open(a, self.log_path, .{});
        self.cc = try .init(a, .{ .exe = self.exe, .mcp = .{}, .replier = self.replies.replier(), .extra_args = &self.extra });
        self.adapters = .{.{ .harness = claude_code.name, .adapter = self.cc.adapter() }};
        self.host = Host.init(a, &self.engine, &self.adapters, .{ .body_max = 8 });
        self.engine.options.executors = self.host.executor();
        try self.engine.start();
    }

    fn agent(self: *Fixture) eventlog.decider.Agent {
        return self.engine.state.agents.get("a1").?;
    }

    fn until(self: *Fixture, comptime done: fn (*Fixture) bool) !void {
        const deadline = @import("supervisor").monotonicMs() + 10_000;
        while (!done(self)) {
            if (@import("supervisor").monotonicMs() > deadline) return error.Timeout;
            try self.host.poll(5);
            _ = try self.engine.runEffects();
            const b = self.host.binding("a1") orelse continue;
            const p = b.process orelse continue;
            for (self.pids.items) |pid| {
                if (pid == p.pid()) break;
            } else try self.pids.append(testing.allocator, p.pid());
        }
    }

    /// What `harness.permission_prompt` does when Claude Code
    /// calls the permission prompt tool for the open call `tool_use_id`.
    fn prompt(self: *Fixture, tool_use_id: []const u8, input_json: []const u8) !void {
        try self.cc.permissionPrompt(&self.host.binding("a1").?.conv, .{ .tool_name = "Bash", .input_json = input_json, .tool_use_id = tool_use_id });
    }

    fn records(self: *Fixture, a: std.mem.Allocator) ![]const []const u8 {
        const bytes = try readFile(a, self.log_path);
        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
            for (v.object.get("events").?.array.items) |e| {
                const t = e.object.get("type").?.string;
                if (std.mem.eql(u8, t, "agent.state_changed") or std.mem.startsWith(u8, t, "effect.") or std.mem.eql(u8, t, "daemon.started") or std.mem.eql(u8, t, "agent.created")) continue;
                try out.append(a, t);
            }
        }
        return out.items;
    }
};

fn openCalls(comptime n: usize) fn (*Fixture) bool {
    return struct {
        fn f(fx: *Fixture) bool {
            return fx.agent().calls == n and fx.agent().state == .running;
        }
    }.f;
}
fn isState(comptime s: AgentState) fn (*Fixture) bool {
    return struct {
        fn f(fx: *Fixture) bool {
            return fx.agent().state == s;
        }
    }.f;
}

test "claude-code via the host: spawn, a Bash call approved, then one denied; tool, usage and harness_session logged" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try fx.host.send("a1", "Run the proto tests and fix what fails.", .turn);
    // The session id venom chose is durable before any output.
    const session = fx.agent().harness_session.?;
    try testing.expectEqual(@as(usize, 36), session.len);
    try fx.until(openCalls(1));
    try fx.prompt("toolu_01A", bash_input);
    try testing.expectEqual(AgentState.needs_you, fx.agent().state);
    const req = fx.agent().requests.items[0];
    try testing.expectEqualStrings("c1", req.call.?);
    try testing.expectEqualStrings("Bash zig build test", req.reason);
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_once" } });
    try fx.until(isState(.settled));

    // fake-claude saw the documented flags and venom's session id.
    const argv = try std.json.parseFromSliceLeaky([]const []const u8, a, try readFile(a, try std.fmt.allocPrintSentinel(a, "{s}/argv.json", .{fx.dir}, 0)), .{});
    try expectArgv(&.{ "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--session-id", session }, argv[0..8]);
    try testing.expectEqualStrings("--permission-prompt-tool", argv[10]);
    try testing.expectEqualStrings(session, fx.agent().harness_session.?);

    // Second turn, same process: the call is denied with a reason.
    try fx.host.send("a1", "Clean up zig-out.", .turn);
    try fx.until(openCalls(2));
    try fx.prompt("toolu_02B", "{\"command\":\"rm -rf zig-out\"}");
    _ = try fx.engine.submit(.{ .answer = .{ .agent = "a1", .request = "r2", .decision = "deny" } });
    try fx.until(isState(.settled));
    try testing.expect(fx.host.binding("a1").?.running());

    // `context` once: the second turn's estimate did not change.
    try expectLines(&.{ "agent.binding", "agent.binding", "turn.started", "turn.prompt", "text", "tool.started", "request", "request.resolved", "tool.ended", "text", "usage", "context", "turn.ended", "agent.binding", "turn.started", "turn.prompt", "tool.started", "request", "request.resolved", "tool.ended", "usage", "turn.ended" }, try fx.records(a));
    const ctx = fx.engine.state.usage.agents.get("a1").?.context.?;
    try testing.expectEqual(@as(u64, 1200 + 40210 + 2048), ctx.used);
    try testing.expectEqual(@as(u64, 200000), ctx.window);
    try testing.expectEqualStrings("estimate", ctx.source);
    var ended: std.ArrayList([]const u8) = .empty;
    var usage: std.ArrayList(u64) = .empty;
    for (fx.agent().transcript.items) |e| switch (e) {
        .tool_started => |t| {
            // Tool args for exec: the command and the agent's cwd.
            try testing.expectEqualStrings(fx.dir, t.args.?.cwd.?);
            try testing.expectEqualStrings(if (std.mem.eql(u8, t.call, "c1")) "zig build test" else "rm -rf zig-out", t.args.?.command.?);
        },
        .tool_ended => |t| {
            try ended.append(a, t.status);
            if (std.mem.eql(u8, t.call, "c1")) {
                try testing.expectEqual(@as(?i64, 0), t.exit);
                try testing.expect(t.duration_ms != null);
                // The body is capped at body_max (8 bytes here).
                try testing.expectEqualStrings("All 112 ", t.body.?.text);
                try testing.expect(t.body.?.truncated);
                try testing.expectEqual(@as(u64, 21), t.body.?.bytes);
            } else {
                try testing.expectEqualStrings("Keep zig", t.body.?.text);
                try testing.expectEqual(@as(u64, 12), t.body.?.bytes);
            }
        },
        .usage => |u| {
            try testing.expectEqualStrings("claude-opus-4-7", u.model);
            try testing.expect(u.includes_subagents);
            try usage.appendSlice(a, &.{ u.tokens_in, u.tokens_out, u.cache_read });
        },
        .turn_ended => |t| try testing.expectEqualStrings("completed", t.reason),
        else => {},
    };
    try expectLines(&.{ "ok", "declined" }, ended.items);
    // Per-turn usage: the second turn is the delta of the running totals.
    try testing.expectEqualSlices(u64, &.{ 1200, 812, 40210, 300, 88, 39790 }, usage.items);
    try testing.expectEqualStrings("{\"behavior\":\"deny\",\"message\":\"The user denied this in venom.\"}", fx.replies.last);
}

/// A Claude Code session transcript (one line per content block; usage
/// repeated per API message), around a hand-over at 21:06:05.
const transcript_lines =
    \\{"type":"user","timestamp":"2026-11-07T21:00:00.000Z","uuid":"u0","message":{"role":"user","content":"Already logged by venom"}}
    \\{"type":"assistant","timestamp":"2026-11-07T21:00:01.000Z","uuid":"u0a","message":{"id":"msg_0","model":"claude-opus-4-7","content":[{"type":"text","text":"old"}],"usage":{"input_tokens":99,"output_tokens":99}}}
    \\{"type":"user","timestamp":"2026-11-07T21:09:00.000Z","uuid":"ux","message":{"role":"user","content":"[Request interrupted by user]"}}
    \\{"type":"user","timestamp":"2026-11-07T21:10:00.000Z","uuid":"u1","message":{"role":"user","content":"Fix the flaky test"}}
    \\{"type":"assistant","timestamp":"2026-11-07T21:10:01.000Z","uuid":"u2","message":{"id":"msg_1","model":"claude-opus-4-7","content":[{"type":"thinking","thinking":"hm"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}
    \\{"type":"assistant","timestamp":"2026-11-07T21:10:02.000Z","uuid":"u3","message":{"id":"msg_1","model":"claude-opus-4-7","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"zig build test"}}],"usage":{"input_tokens":10,"output_tokens":7,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}
    \\{"type":"user","timestamp":"2026-11-07T21:10:09.000Z","uuid":"u4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok","is_error":false}]}}
    \\{"type":"assistant","timestamp":"2026-11-07T21:10:10.000Z","uuid":"u5","message":{"id":"msg_2","model":"claude-opus-4-7","content":[{"type":"text","text":"Fixed."}],"usage":{"input_tokens":3,"output_tokens":2,"cache_read_input_tokens":200}}}
    \\{"type":"assistant","isSidechain":true,"timestamp":"2026-11-07T21:10:11.000Z","uuid":"u6","message":{"id":"msg_s","model":"claude-haiku-4-5","content":[{"type":"text","text":"sub-agent"}],"usage":{"input_tokens":50}}}
    \\not json
    \\{"type":"user","timestamp":"2026-11-07T21:11:00.000Z","uuid":"u7","message":{"role":"user","content":"<command-name>/model</command-name>"}}
    \\{"type":"user","isMeta":true,"timestamp":"2026-11-07T21:11:00.000Z","uuid":"u8","message":{"role":"user","content":"Caveat: local commands"}}
    \\{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-11-07T21:11:01.000Z"}
    \\{"type":"user","timestamp":"2026-11-07T21:12:00.000Z","uuid":"u10","message":{"role":"user","content":[{"type":"text","text":"Now the docs"}]}}
    \\{"type":"assistant","timestamp":"2026-11-07T21:12:01.000Z","uuid":"u11","message":{"id":"msg_3","model":"claude-haiku-4-5","content":[{"type":"text","text":"Writing docs"},{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"rm -rf docs"}}],"usage":{"input_tokens":1,"output_tokens":1}}}
    \\{"type":"user","timestamp":"2026-11-07T21:12:05.000Z","uuid":"u12","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"interrupted","is_error":true},{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
    \\
;

test "claude-code catch-up: a re-run after a crash mid-import imports each turn once" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    const since = harness.claude_transcript.timestampMs("2026-11-07T21:06:05.000Z").?;
    const replay = harness.claude_transcript.replay;
    // The import dies after the first turn is committed.
    const cut = std.mem.indexOf(u8, transcript_lines, "{\"type\":\"user\",\"timestamp\":\"2026-11-07T21:11:00.000Z\"").?;
    try testing.expectEqual(@as(u32, 1), (try replay(&u.conv, transcript_lines[0..cut], since, null)).turns);
    // The restarted effect starts after the newest turn venom has (u1).
    try testing.expectEqual(@as(u32, 1), (try replay(&u.conv, transcript_lines, since, "u1")).turns);
    var starts: [2][]const u8 = undefined;
    var n: usize = 0;
    for (u.rec.events.items) |e| if (std.mem.startsWith(u8, e, "turn_started")) {
        starts[n] = e;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOf(u8, starts[0], "\"harness_turn\":\"u1\"") != null);
    try testing.expect(std.mem.indexOf(u8, starts[1], "\"harness_turn\":\"u10\"") != null);
    // Nothing left to import; an id the transcript does not hold changes nothing.
    try testing.expectEqual(@as(u32, 0), (try replay(&u.conv, transcript_lines, since, "u10")).turns);
    try testing.expectEqual(@as(u32, 2), (try replay(&u.conv, transcript_lines, since, "nope")).turns);
}

test "claude-code: a fork that waits across a restart still forks at its first start" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try fx.engine.submit(.{ .record = .{ .agent_binding = .{ .agent = "a1", .harness = claude_code.name, .harness_session = "src", .cwd = fx.dir } } });

    // No task: nothing starts the fork, so it can outlive the daemon.
    const key = try fx.host.fork(a, "a1", null);
    try fx.until(struct {
        fn f(self: *Fixture) bool {
            return self.engine.state.agents.contains("a2");
        }
    }.f);
    try testing.expect(fx.engine.state.effects.get(key).?.ok);
    const id = try a.dupe(u8, fx.engine.state.agents.get("a2").?.harness_session.?);

    try fx.restart();
    try testing.expectEqualStrings("src", fx.engine.state.agents.get("a2").?.fork_source.?);

    try fx.host.send("a2", "go on", .turn);
    // Its first `system/init` ends it, so a later start resumes the copy.
    try fx.until(struct {
        fn f(self: *Fixture) bool {
            return self.engine.state.agents.get("a2").?.fork_source == null;
        }
    }.f);
    const argv = try std.json.parseFromSliceLeaky([]const []const u8, a, try readFile(a, try std.fmt.allocPrintSentinel(a, "{s}/argv.json", .{fx.dir}, 0)), .{});
    try expectArgv(&.{ "--resume", "src", "--fork-session", "--session-id", id }, argv[6..11]);
}

test "claude-code: a fork that has not started: the command forks it; refused with fork_at; a copy that exists is resumed, found by the recorded ref or under the physical cwd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.createDirPath(testing.io, "real");
    const real = try std.fmt.allocPrint(a, "{s}/real", .{dir});
    // A symlink to the real folder: Claude Code files under the real one.
    const link = try std.fmt.allocPrint(a, "{s}/link", .{dir});
    try testing.expectEqual(@as(c_int, 0), c.symlink(try a.dupeSentinel(u8, real, 0), try a.dupeSentinel(u8, link, 0)));
    var cc: ClaudeCode = try .init(testing.allocator, .{ .config_dir = dir });
    defer cc.deinit();
    const rec: contract.Resume = .{ .harness = claude_code.name, .harness_session = "copy", .fork_source = "src", .cwd = link };
    const forks = try cc.resume_command(a, rec);
    try expectArgv(&.{ "claude", "--resume", "src", "--fork-session", "--session-id", "copy" }, forks.argv);
    try testing.expectEqualStrings("copy", forks.harness_session.?);
    var with_at = rec;
    with_at.fork_at = "u9";
    try testing.expectError(error.UnsupportedCapability, cc.resume_command(a, with_at));

    // The copy, filed under the physical cwd.
    const enc = try a.dupe(u8, real);
    for (enc) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
        ch.* = '-';
    };
    const project = try std.fmt.allocPrint(a, "projects/{s}", .{enc});
    try tmp.dir.createDirPath(testing.io, project);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/copy.jsonl", .{project}), .data = "" });
    const resumes = try cc.resume_command(a, rec);
    try expectArgv(&.{ "claude", "--resume", "copy" }, resumes.argv);
    const started = try cc.start(a, .{ .agent = "a1", .cwd = link, .harness_session = "copy", .fork_source = "src" });
    try expectArgv(&.{ "--resume", "copy" }, started.argv[7..9]);
    for (started.argv) |x| try testing.expect(!std.mem.eql(u8, x, "--fork-session"));
    // Another cwd has no copy: the recorded ref names it.
    var elsewhere = rec;
    elsewhere.cwd = "/nowhere";
    const ref = try std.fmt.allocPrint(a, "{s}/{s}/copy.jsonl", .{ dir, project });
    try expectArgv(&.{ "claude", "--resume", "src", "--fork-session", "--session-id", "copy" }, (try cc.resume_command(a, elsewhere)).argv);
    elsewhere.transcript_ref = ref;
    try expectArgv(&.{ "claude", "--resume", "copy" }, (try cc.resume_command(a, elsewhere)).argv);
    // A ref naming another file is not the copy, even when that file exists.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/other.jsonl", .{project}), .data = "" });
    elsewhere.transcript_ref = try std.fmt.allocPrint(a, "{s}/{s}/other.jsonl", .{ dir, project });
    const forks_again = &[_][]const u8{ "claude", "--resume", "src", "--fork-session", "--session-id", "copy" };
    try expectArgv(forks_again, (try cc.resume_command(a, elsewhere)).argv);
    // A ref that does not pass what catch-up applies is not the copy: outside
    // `projects`, a symlink, a directory.
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/copy.jsonl", .data = "" });
    elsewhere.transcript_ref = try std.fmt.allocPrint(a, "{s}/outside/copy.jsonl", .{dir});
    try expectArgv(forks_again, (try cc.resume_command(a, elsewhere)).argv);
    try tmp.dir.createDirPath(testing.io, "projects/-linked");
    try testing.expectEqual(@as(c_int, 0), c.symlink(try a.dupeSentinel(u8, ref, 0), try std.fmt.allocPrintSentinel(a, "{s}/projects/-linked/copy.jsonl", .{dir}, 0)));
    elsewhere.transcript_ref = try std.fmt.allocPrint(a, "{s}/projects/-linked/copy.jsonl", .{dir});
    try expectArgv(forks_again, (try cc.resume_command(a, elsewhere)).argv);
    try tmp.dir.createDirPath(testing.io, "projects/-dir/copy.jsonl");
    elsewhere.transcript_ref = try std.fmt.allocPrint(a, "{s}/projects/-dir/copy.jsonl", .{dir});
    try expectArgv(forks_again, (try cc.resume_command(a, elsewhere)).argv);

    // Take-back finds no conversation while fork_source is set: not a failure
    // for the adapter's caller to log; without fork_source it still is.
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    try testing.expectError(error.NoConversation, cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "gone", .fork_source = "src", .cwd = "/nowhere" }));
    try testing.expectError(error.HarnessCatchUp, cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "gone", .cwd = "/nowhere" }));
}

test "claude-code catch-up: turns after the hand-over replay from the transcript with venom's ids and per-message usage" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.createDirPath(testing.io, "projects/-home-u-venom-org-venom-std-246");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "projects/-home-u-venom-org-venom-std-246/s1.jsonl", .data = transcript_lines });

    var cc: ClaudeCode = try .init(testing.allocator, .{ .config_dir = dir });
    defer cc.deinit();
    try testing.expectEqual(contract.CatchUp.transcript_file, (try cc.probe(a)).caps.catch_up);
    // The TUI writes where catch-up reads.
    const tui = try cc.resume_command(a, .{ .harness = claude_code.name, .harness_session = "s1", .cwd = u.conv.cwd });
    try testing.expectEqualStrings("CLAUDE_CONFIG_DIR", tui.env[0].name);
    try testing.expectEqualStrings(dir, tui.env[0].value);

    const since = harness.claude_transcript.timestampMs("2026-11-07T21:06:05.000Z").?;
    const n = try cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "s1", .cwd = u.conv.cwd, .since_ms = since });
    try testing.expectEqual(@as(u32, 2), n);
    try expectLines(&.{
        "turn_started {\"turn\":\"t1\",\"origin\":\"catch_up\",\"harness_turn\":\"u1\"}",
        "prompt {\"turn\":\"t1\",\"text\":\"Fix the flaky test\"}",
        "tool_started {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build test\",\"status\":\"running\",\"harness_ref\":\"toolu_1\"}",
        "tool_ended {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build test\",\"status\":\"ok\"}",
        "text {\"turn\":\"t1\",\"message\":\"m1\",\"text\":\"Fixed.\",\"final\":true}",
        "usage {\"turn\":\"t1\",\"model\":\"claude-opus-4-7\",\"tokens_in\":13,\"tokens_out\":9,\"cache_read\":300,\"cache_write\":20,\"includes_subagents\":false,\"source\":\"exact\"}",
        "turn_ended {\"turn\":\"t1\",\"reason\":\"completed\"}",
        "turn_started {\"turn\":\"t2\",\"origin\":\"catch_up\",\"harness_turn\":\"u10\"}",
        "prompt {\"turn\":\"t2\",\"text\":\"Now the docs\"}",
        "text {\"turn\":\"t2\",\"message\":\"m2\",\"text\":\"Writing docs\",\"final\":true}",
        "tool_started {\"turn\":\"t2\",\"call\":\"c2\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"rm -rf docs\",\"status\":\"running\",\"harness_ref\":\"toolu_2\"}",
        "tool_ended {\"turn\":\"t2\",\"call\":\"c2\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"rm -rf docs\",\"status\":\"error\"}",
        "usage {\"turn\":\"t2\",\"model\":\"claude-haiku-4-5\",\"tokens_in\":1,\"tokens_out\":1,\"cache_read\":0,\"cache_write\":0,\"includes_subagents\":false,\"source\":\"exact\"}",
        "turn_ended {\"turn\":\"t2\",\"reason\":\"interrupted\"}",
    }, u.rec.events.items);
    try testing.expect(!u.conv.inTurn());

    // A transcript under another project name (Claude Code shortens long
    // paths) is still found; none at all fails the catch-up.
    try tmp.dir.createDirPath(testing.io, "projects/elsewhere");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "projects/elsewhere/s2.jsonl", .data = transcript_lines });
    try testing.expectEqual(@as(u32, 2), try cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "s2", .cwd = "/nowhere", .since_ms = since }));
    try testing.expectError(error.HarnessCatchUp, cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "s3", .cwd = "/nowhere" }));

    // A last line still being written is skipped and reported; a bad line
    // before it is not.
    const replay = harness.claude_transcript.replay;
    try testing.expect(!(try replay(&u.conv, transcript_lines, since, null)).torn_tail);
    const torn = try std.fmt.allocPrint(a, "{s}{{\"type\":\"assistant\",\"timest", .{transcript_lines});
    const r = try replay(&u.conv, torn, since, null);
    try testing.expect(r.torn_tail);
    try testing.expectEqual(@as(u32, 2), r.turns);
}

// ------------------------------------------------------------- helpers

fn writeFile(path: [:0]const u8, bytes: []const u8, mode: c.mode_t) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return error.WriteFailed;
        done += @intCast(n);
    }
}

fn readFile(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(a, buf[0..@intCast(n)]);
    }
    return list.items;
}

test "claude-code: a multi-line command's title is marked as cut short" {
    var u: Unit = undefined;
    try u.init(true);
    defer u.deinit();
    try u.send("go");
    try u.feed(
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
    );
    try u.cc.permissionPrompt(&u.conv, .{ .tool_name = "Bash", .input_json = "{\"command\":\"zig build  \\nrm -rf ~\"}", .tool_use_id = "t1" });
    try expectLines(&.{
        "tool_started {\"turn\":\"t1\",\"call\":\"c1\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"zig build \u{2026}\",\"status\":\"pending\",\"harness_ref\":\"t1\"}",
        "request {\"turn\":\"t1\",\"request\":\"r1\",\"kind\":\"approval\",\"call\":\"c1\",\"reason\":\"Bash zig build \u{2026}\",\"answers\":[\"allow_once\",\"allow_always\",\"allow_edited\",\"deny\",\"cancel_turn\"]}",
    }, u.rec.events.items[u.rec.events.items.len - 2 ..]);
}

test "claude-code: a request carries the digest of the whole input, for every tool" {
    var u: Unit = undefined;
    try u.init(true);
    defer u.deinit();
    u.rec.full = true;
    try u.send("go");
    try u.feed(
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
    );
    const cases = [_]struct { tool: []const u8, same: []const u8, reordered: []const u8, changed: []const u8 }{
        .{ .tool = "ExitPlanMode", .same = "{\"plan\":\"A\",\"n\":1}", .reordered = "{\"n\":1,\"plan\":\"A\"}", .changed = "{\"plan\":\"B\",\"n\":1}" },
        .{ .tool = "AskUserQuestion", .same = "{\"questions\":[{\"question\":\"Q1\"}],\"n\":1}", .reordered = "{\"n\":1,\"questions\":[{\"question\":\"Q1\"}]}", .changed = "{\"questions\":[{\"question\":\"Q2\"}],\"n\":1}" },
        .{ .tool = "mcp__gh__delete_repo", .same = "{\"repo\":\"x\",\"n\":1}", .reordered = "{\"n\":1,\"repo\":\"x\"}", .changed = "{\"repo\":\"y\",\"n\":1}" },
        .{ .tool = "Task", .same = "{\"prompt\":\"read\",\"n\":1}", .reordered = "{\"n\":1,\"prompt\":\"read\"}", .changed = "{\"prompt\":\"rm\",\"n\":1}" },
        .{ .tool = "Frobnicate", .same = "{\"level\":1,\"n\":1}", .reordered = "{\"n\":1,\"level\":1}", .changed = "{\"level\":2,\"n\":1}" },
        .{ .tool = "Edit", .same = "{\"file_path\":\"/w/a\",\"new_string\":\"y\"}", .reordered = "{\"new_string\":\"y\",\"file_path\":\"/w/a\"}", .changed = "{\"file_path\":\"/w/a\",\"new_string\":\"z\"}" },
        .{ .tool = "Write", .same = "{\"file_path\":\"/w/a\",\"content\":\"1\"}", .reordered = "{\"content\":\"1\",\"file_path\":\"/w/a\"}", .changed = "{\"file_path\":\"/w/a\",\"content\":\"2\"}" },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: u32 = 0;
    for (cases) |case| {
        var digests: [3][]const u8 = undefined;
        for ([_][]const u8{ case.same, case.reordered, case.changed }, &digests) |input, *digest| {
            n += 1;
            const mark = u.rec.events.items.len;
            try u.cc.permissionPrompt(&u.conv, .{ .tool_name = case.tool, .input_json = input, .tool_use_id = try std.fmt.allocPrint(a, "t{d}", .{n}) });
            var found: ?[]const u8 = null;
            for (u.rec.since(mark)) |line| if (std.mem.startsWith(u8, line, "request ")) {
                const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line["request ".len..], .{});
                found = v.object.get("input_digest").?.string;
            };
            digest.* = found.?;
        }
        try testing.expectEqualStrings(digests[0], digests[1]);
        try testing.expect(!std.mem.eql(u8, digests[0], digests[2]));
    }
}

test "attention away: the resume command's hooks, and what each hook says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cc: claude_code.ClaudeCode = try .init(testing.allocator, .{ .exe = "/opt/claude", .config_dir = "/c", .mcp = .{ .command = "/opt/my venom", .socket = "/run/v.sock" } });
    defer cc.deinit();
    try testing.expectEqual(contract.AttentionAway.hooks, (try cc.probe(a)).caps.attention_away);
    const s = try cc.resume_command(a, .{ .agent = "a2", .hooks = true, .harness = claude_code.name, .harness_session = "s1", .cwd = "/w" });
    try testing.expectEqual(@as(usize, 5), s.argv.len);
    try testing.expectEqualStrings("--settings", s.argv[3]);
    try testing.expectEqualStrings(
        \\{"hooks":{"Notification":[{"matcher":"permission_prompt|idle_prompt","hooks":[{"type":"command","command":"'/opt/my venom' agent hook --agent a2"}]}],"Stop":[{"hooks":[{"type":"command","command":"'/opt/my venom' agent hook --agent a2"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"'/opt/my venom' agent hook --agent a2"}]}]}}
    , s.argv[4]);
    var names: [3][]const u8 = undefined;
    try testing.expectEqual(names.len, s.env.len);
    for (s.env, &names) |e, *n| n.* = e.name;
    try testing.expectEqualStrings("CLAUDE_CONFIG_DIR", names[0]);
    try testing.expectEqualStrings("VENOM_AGENT", names[1]);
    try testing.expectEqualStrings("a2", s.env[1].value);
    try testing.expectEqualStrings("VENOM_SOCKET", names[2]);

    // A split nobody can report gets no hooks: each would be a hook error.
    const plain = try cc.resume_command(a, .{ .agent = "a2", .harness = claude_code.name, .harness_session = "s1", .cwd = "/w" });
    try testing.expectEqual(@as(usize, 3), plain.argv.len);

    // Claude Code's hook JSON.
    var r = try claude_code.parseHook(a, "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\",\"transcript_path\":\"/c/s1.jsonl\"}");
    try testing.expectEqual(.approval, r.kind.?);
    try testing.expectEqualStrings("Claude needs your permission to use Bash", r.reason);
    try testing.expectEqualStrings("/c/s1.jsonl", r.transcript.?);
    r = try claude_code.parseHook(a, "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\"}");
    try testing.expectEqual(.question, r.kind.?);
    try testing.expectEqualStrings("waiting in claude-code", r.reason);
    r = try claude_code.parseHook(a, "{\"hook_event_name\":\"Notification\",\"notification_type\":\"auth_success\"}");
    try testing.expect(r.kind == null);
    r = try claude_code.parseHook(a, "{\"hook_event_name\":\"Stop\"}");
    try testing.expectEqual(.review, r.kind.?);
    r = try claude_code.parseHook(a, "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}");
    try testing.expect(r.kind == null);
    try testing.expectError(error.InvalidHook, claude_code.parseHook(a, "not json"));
    try testing.expectError(error.InvalidHook, claude_code.parseHook(a, "{}"));

    try testing.expect(claude_code.isTranscriptOf("/c/projects/w/s1.jsonl", "s1"));
    try testing.expect(!claude_code.isTranscriptOf("/c/projects/w/other.jsonl", "s1"));
    try testing.expect(!claude_code.isTranscriptOf("s1.jsonl", "s1"));
}

extern "c" fn mkfifo([*:0]const u8, std.c.mode_t) c_int;

test "catch-up refuses a forged transcript (outside folder, symlink, FIFO, oversize) and falls back to its own" {
    var u: Unit = undefined;
    try u.init(false);
    defer u.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const transcript = harness.claude_transcript;
    const project = "projects/-home-u-venom-org-venom-std-246";
    try tmp.dir.createDirPath(testing.io, project);
    try tmp.dir.createDirPath(testing.io, "elsewhere");
    const real = try std.fmt.allocPrint(a, "{s}/{s}/s1.jsonl", .{ dir, project });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = project ++ "/s1.jsonl", .data = transcript_lines });
    try testing.expectEqual(transcript_lines.len, (try transcript.read(a, dir, real)).len);

    // A folder outside `projects`, also through a symlinked folder inside.
    const forged = "{\"type\":\"user\",\"timestamp\":\"2026-11-07T21:06:06.000Z\",\"uuid\":\"forged\",\"message\":{\"role\":\"user\",\"content\":\"forged\"}}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "elsewhere/s1.jsonl", .data = forged });
    const outside = try std.fmt.allocPrint(a, "{s}/elsewhere/s1.jsonl", .{dir});
    try testing.expectError(error.HarnessCatchUp, transcript.read(a, dir, outside));
    const linked_dir = try std.fmt.allocPrintSentinel(a, "{s}/projects/linked", .{dir}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(try std.fmt.allocPrintSentinel(a, "{s}/elsewhere", .{dir}, 0), linked_dir));
    try testing.expectError(error.HarnessCatchUp, transcript.read(a, dir, try std.fmt.allocPrint(a, "{s}/s1.jsonl", .{linked_dir})));

    // A symlink, to a transcript or to a device that never ends.
    try tmp.dir.createDirPath(testing.io, "projects/p");
    for ([_][:0]const u8{ "/dev/zero", try a.dupeSentinel(u8, real, 0) }, [_][]const u8{ "zero", "real" }) |target, name| {
        const link = try std.fmt.allocPrintSentinel(a, "{s}/projects/p/{s}.jsonl", .{ dir, name }, 0);
        try testing.expectEqual(@as(c_int, 0), std.c.symlink(target, link));
        try testing.expectError(error.HarnessCatchUp, transcript.read(a, dir, link));
    }

    // A FIFO with no writer: refused at once, nothing hangs.
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/projects/p/s1.jsonl", .{dir}, 0);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    try testing.expectError(error.HarnessCatchUp, transcript.read(a, dir, fifo));

    // Over the cap (sparse, so the test writes nothing).
    const big = try std.fmt.allocPrintSentinel(a, "{s}/projects/p/big.jsonl", .{dir}, 0);
    const fd = std.c.open(big, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try testing.expect(fd >= 0);
    try testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(transcript.max_bytes + 1)));
    _ = std.c.close(fd);
    try testing.expectError(error.HarnessCatchUp, transcript.read(a, dir, big));

    // Each forged path falls back to the agent's own transcript: the real
    // turns come in, the forged one does not.
    var cc: ClaudeCode = try .init(testing.allocator, .{ .config_dir = dir });
    defer cc.deinit();
    const since = harness.claude_transcript.timestampMs("2026-11-07T21:06:05.000Z").?;
    const n = try cc.catch_up(&u.conv, .{ .harness = claude_code.name, .harness_session = "s1", .cwd = "/home/u/venom-org/venom-std-246", .transcript_ref = outside, .since_ms = since });
    try testing.expectEqual(@as(u32, 2), n);
    for (u.rec.events.items) |line| try testing.expect(std.mem.indexOf(u8, line, "forged") == null);
}
