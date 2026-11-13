//! `venom agent permission-server`: the stdio MCP server Claude
//! Code gets as `venom-permissions`, whose one tool `permission_prompt` is
//! its `--permission-prompt-tool`. venom starts it
//! through `--mcp-config`; it is not meant to be run by hand.
//!
//! Claude Code calls `permission_prompt` with `{tool_name, input,
//! tool_use_id}` whenever a tool call needs a decision, and waits. Each
//! call is forwarded to the daemon as `harness.permission_prompt` on its own
//! connection, with the harness process's token from the environment
//! (`VENOM_TOKEN`, inherited from Claude Code), so the daemon knows the
//! agent. That daemon call stays open until the request is answered in
//! venom; its `result` string, Claude Code's permission result JSON, is
//! returned verbatim as the tool result's text, as Claude Code requires.
//! Calls are independent: several prompts can wait at once.
//!
//! Why not a tool of `venom mcp`: the generated server wraps every result
//! as `{"result":…}` (Claude Code would not read it as a permission
//! result) and serves one call at a time.
//!
//! Fail closed: anything that keeps a prompt from reaching venom (no
//! daemon, a refused token, a caller that is not an agent, bad arguments)
//! answers it with a `deny` result naming the error, so Claude Code goes on
//! without running the tool. A `notifications/cancelled` for a call, or the
//! end of stdin, closes its daemon connection, which ends the daemon call.
//! Diagnostics go to stderr only. It reads fd 0 (venom-std's local
//! command context carries no stdin), so it runs as its own process.
const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const mcp = @import("harness/mcp.zig");
const c = std.c;
const Value = std.json.Value;

pub const protocol_version = "2025-06-18";
const max_line = 4 * 1024 * 1024;

/// The local verb (a local command; never an MCP tool itself).
pub const local_commands = .{.{
    .name = "agent.permission_server",
    .summary = "Serve Claude Code's permission prompt tool over MCP stdio (venom starts it for claude-code agents; not for people)",
    .params = .{},
    .result = .{ .kind = .object, .fields = .{} },
}};

const tool_description = "Ask venom (the human in its inbox) whether a tool call may run. Claude Code's --permission-prompt-tool.";

/// One `tools/call` waiting on the daemon.
const Pending = struct {
    /// The JSON-RPC id, as JSON.
    id: []u8,
    client: proto.Client,
    sent: bool = false,
    params: []u8,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    input: c.fd_t = 0,
    output: *std.Io.Writer,
    path: proto.SocketOptions,
    interrupted: ?*const std.atomic.Value(bool) = null,
    buf: std.ArrayList(u8) = .empty,
    eof: bool = false,
    pending: std.ArrayList(Pending) = .empty,

    pub fn deinit(self: *Server) void {
        for (self.pending.items) |*p| self.drop(p);
        self.pending.deinit(self.gpa);
        self.buf.deinit(self.gpa);
    }

    fn drop(self: *Server, p: *Pending) void {
        p.client.deinit();
        self.gpa.free(p.id);
        self.gpa.free(p.params);
    }

    fn stopping(self: *Server) bool {
        return if (self.interrupted) |f| f.load(.monotonic) else false;
    }

    /// Serves until stdin closes or `interrupted` is set.
    pub fn run(self: *Server) !void {
        while (!self.stopping()) {
            try self.fill(if (self.pending.items.len > 0) 10 else 100);
            while (try self.nextLine()) |line| {
                defer self.gpa.free(line);
                try self.handle(line);
            }
            try self.advance();
            // The end of input: nobody will read an answer any more. The
            // daemon calls end with their connections.
            if (self.eof) return;
        }
    }

    // ------------------------------------------------------------ input

    fn fill(self: *Server, timeout_ms: i32) !void {
        if (self.eof) return;
        var fds = [_]c.pollfd{.{ .fd = self.input, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, timeout_ms) <= 0 or fds[0].revents == 0) return;
        var chunk: [64 * 1024]u8 = undefined;
        const n = c.read(self.input, &chunk, chunk.len);
        if (n < 0) switch (c.errno(n)) {
            .INTR, .AGAIN => return,
            else => {
                self.eof = true;
                return;
            },
        };
        if (n == 0) {
            self.eof = true;
            return;
        }
        try self.buf.appendSlice(self.gpa, chunk[0..@intCast(n)]);
        if (self.buf.items.len > max_line and std.mem.indexOfScalar(u8, self.buf.items, '\n') == null) {
            // One line too long to be a prompt: drop it and answer nothing.
            self.buf.clearRetainingCapacity();
            std.debug.print("venom permission-server: dropped an over-long line\n", .{});
        }
    }

    /// The next complete line (gpa-owned); at EOF a trailing partial line.
    fn nextLine(self: *Server) !?[]u8 {
        if (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |end| {
            const line = try self.gpa.dupe(u8, self.buf.items[0..end]);
            const rest = self.buf.items.len - end - 1;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[end + 1 ..]);
            self.buf.items.len = rest;
            return line;
        }
        if (self.eof and self.buf.items.len > 0) {
            const line = try self.gpa.dupe(u8, self.buf.items);
            self.buf.clearRetainingCapacity();
            return line;
        }
        return null;
    }

    // --------------------------------------------------------- messages

    fn handle(self: *Server, line: []const u8) !void {
        if (std.mem.trim(u8, line, " \t\r").len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch return self.rpcError("null", -32700, "parse error");
        if (msg != .object) return self.rpcError("null", -32600, "invalid request");
        const method = msg.object.get("method") orelse return; // a response; we send no requests
        if (method != .string) return self.rpcError("null", -32600, "method must be a string");
        const params = msg.object.get("params") orelse .null;
        const raw_id = msg.object.get("id") orelse {
            // Notifications: only a cancellation matters.
            if (std.mem.eql(u8, method.string, "notifications/cancelled") and params == .object) {
                if (params.object.get("requestId")) |rid| self.cancel(try std.json.Stringify.valueAlloc(a, rid, .{}));
            }
            return;
        };
        if (raw_id != .integer and raw_id != .string) return self.rpcError("null", -32600, "invalid request id");
        const id = try std.json.Stringify.valueAlloc(a, raw_id, .{});
        const m = method.string;
        if (std.mem.eql(u8, m, "initialize")) {
            return self.result(id, try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"0.0.0\"}}}}", .{ protocol_version, mcp.permissions_server_name }));
        }
        if (std.mem.eql(u8, m, "ping")) return self.result(id, "{}");
        if (std.mem.eql(u8, m, "tools/list")) return self.result(id, try toolList(a));
        if (std.mem.eql(u8, m, "tools/call")) return self.call(a, id, params);
        return self.rpcError(id, -32601, "method not found");
    }

    fn call(self: *Server, a: std.mem.Allocator, id: []const u8, params: Value) !void {
        if (params != .object) return self.rpcError(id, -32602, "params must be an object");
        const name = params.object.get("name") orelse .null;
        if (name != .string or !std.mem.eql(u8, name.string, mcp.permission_tool)) return self.rpcError(id, -32602, "unknown tool");
        const args = params.object.get("arguments") orelse .null;
        const tool_name = field(args, "tool_name");
        const tool_use_id = field(args, "tool_use_id");
        const input = if (args == .object) args.object.get("input") else null;
        if (tool_name == null or tool_use_id == null or input == null or input.? != .object)
            return self.text(id, try denial(a, "invalid_params", "permission_prompt needs tool_name, tool_use_id and an input object"));
        const forwarded = try std.json.Stringify.valueAlloc(self.gpa, .{ .tool_name = tool_name.?, .input = try std.json.Stringify.valueAlloc(a, input.?, .{}), .tool_use_id = tool_use_id.? }, .{});
        errdefer self.gpa.free(forwarded);
        const client = proto.Client.init(self.gpa, .{
            .tool = "venom",
            .path = self.path,
            .hello = .{ .identity = .{ .name = mcp.permissions_server_name, .version = "0.0.0" }, .caps = &.{"cancel"} },
        }) catch |err| {
            self.gpa.free(forwarded);
            return self.text(id, try denial(a, "unavailable.daemon", @errorName(err)));
        };
        const owned_id = try self.gpa.dupe(u8, id);
        try self.pending.append(self.gpa, .{ .id = owned_id, .client = client, .params = forwarded });
    }

    fn cancel(self: *Server, id: []const u8) void {
        for (self.pending.items, 0..) |*p, i| if (std.mem.eql(u8, p.id, id)) {
            // MCP: no response for a cancelled request.
            self.drop(p);
            _ = self.pending.orderedRemove(i);
            return;
        };
    }

    /// Moves every pending call on: hello, the request, its response.
    fn advance(self: *Server) !void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (try self.step(&self.pending.items[i])) {
                self.drop(&self.pending.items[i]);
                _ = self.pending.orderedRemove(i);
            } else i += 1;
        }
    }

    /// True when the call was answered.
    fn step(self: *Server, p: *Pending) !bool {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (!p.sent) {
            const ready = p.client.pollHello(0) catch |err| {
                const why = if (err == error.DeniedToken) "denied.token" else "unavailable.daemon";
                try self.text(p.id, try denial(a, why, @errorName(err)));
                return true;
            };
            if (!ready) return false;
            // The params are already JSON: send them as a raw value.
            const params = try std.json.parseFromSliceLeaky(Value, a, p.params, .{});
            p.client.request(@as(i64, 2), "harness.permission_prompt", params) catch |err| {
                try self.text(p.id, try denial(a, "unavailable.daemon", @errorName(err)));
                return true;
            };
            p.sent = true;
        }
        const msg = (p.client.receive(0) catch |err| {
            try self.text(p.id, try denial(a, "unavailable.daemon", @errorName(err)));
            return true;
        }) orelse return false;
        if (msg != .ndjson) {
            try self.text(p.id, try denial(a, "internal", "unexpected frame from the daemon"));
            return true;
        }
        var response = proto.Response.parse(self.gpa, msg.ndjson) catch {
            try self.text(p.id, try denial(a, "internal", "invalid response from the daemon"));
            return true;
        };
        defer response.deinit();
        switch (response.body) {
            .item => return false,
            .@"error" => |e| try self.text(p.id, try denial(a, e.code, e.message)),
            .ok => |v| {
                const r = field(v, "result") orelse {
                    try self.text(p.id, try denial(a, "internal.result", "the daemon's answer has no result"));
                    return true;
                };
                try self.text(p.id, r);
            },
        }
        return true;
    }

    // ----------------------------------------------------------- output

    fn text(self: *Server, id: []const u8, body: []const u8) !void {
        try self.output.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}]}}}}\n", .{ id, std.json.fmt(body, .{}) });
        try self.output.flush();
    }

    fn result(self: *Server, id: []const u8, json: []const u8) !void {
        try self.output.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id, json });
        try self.output.flush();
    }

    fn rpcError(self: *Server, id: []const u8, code: i64, message: []const u8) !void {
        try self.output.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{f}}}}}\n", .{ id, code, std.json.fmt(message, .{}) });
        try self.output.flush();
    }
};

/// The `tools/list` result: the one tool.
fn toolList(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"tools\":[{{\"name\":\"{s}\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"tool_name\":{{\"type\":\"string\",\"description\":\"The tool that asks for permission\"}},\"input\":{{\"type\":\"object\",\"description\":\"The tool's input\"}},\"tool_use_id\":{{\"type\":\"string\",\"description\":\"The tool_use id of the call\"}}}},\"required\":[\"tool_name\",\"input\"]}}}}]}}", .{ mcp.permission_tool, std.json.fmt(tool_description, .{}) });
}

/// A deny permission result for a prompt venom could not take.
pub fn denial(a: std.mem.Allocator, code: []const u8, message: []const u8) ![]const u8 {
    const why = try std.fmt.allocPrint(a, "venom could not ask for permission ({s}: {s}); the call was not run.", .{ code, message });
    return std.fmt.allocPrint(a, "{{\"behavior\":\"deny\",\"message\":{f}}}", .{std.json.fmt(why, .{})});
}

fn field(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

/// The local handler for `agent.permission_server`.
pub fn serve(gpa: std.mem.Allocator, ctx: cli.Local.Context) !cli.Local.Outcome {
    var server: Server = .{ .gpa = gpa, .output = ctx.stdout, .path = ctx.path, .interrupted = ctx.interrupted };
    defer server.deinit();
    try server.run();
    return .{ .status = 0 };
}

const testing = std.testing;

test "denial is a deny permission result naming the error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\{"behavior":"deny","message":"venom could not ask for permission (denied.not_agent: only \"agents\"); the call was not run."}
    , try denial(arena.allocator(), "denied.not_agent", "only \"agents\""));
    const list = try std.json.parseFromSliceLeaky(Value, arena.allocator(), try toolList(arena.allocator()), .{});
    try testing.expectEqualStrings("permission_prompt", list.object.get("tools").?.array.items[0].object.get("name").?.string);
}
