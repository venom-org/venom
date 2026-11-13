//! `harness.permission_prompt`: the daemon side of Claude Code's
//! permission prompts.
//!
//! Claude Code calls the `permission_prompt` tool of venom's
//! `venom-permissions` MCP server (`permission_server.zig`), which forwards
//! the call here over the socket with the harness process's own token. The
//! handler finds the caller's agent from that token (`Principals.agentOf`),
//! checks the agent runs on the claude-code adapter, and hands the prompt
//! to `ClaudeCode.permissionPrompt`, which raises the request (approval,
//! question or plan) on the agent's conversation. The call is **left
//! open**: its dispatcher ticket travels with the prompt.
//!
//! When the request is answered (`inbox.answer`, `inbox.batch`, a kept
//! "allow always" grant, `agent.stop`'s `cancel_turn`), the decider queues
//! `harness.respond`, the adapter builds Claude Code's permission result
//! and calls the `Replier` here, which finishes the open call with
//! `{"result": <permission result JSON>}`. If the call is gone by then (the
//! MCP server cancelled it, or Claude Code exited), the reply fails with
//! `conflict.request_resolved` and the harness settles the call itself.
//!
//! Only an agent's own harness process can raise its prompts: a caller
//! that is not an agent gets `denied.not_agent`, and the agent needs
//! `write` on itself. Everything runs on the reactor thread.
const std = @import("std");
const proto = @import("proto");
const harness = @import("harness/root.zig");
const Principals = @import("principals.zig").Principals;
const ClaudeCode = harness.ClaudeCode;

pub const Permissions = struct {
    host: *harness.Host,
    principals: ?*Principals = null,
    /// Learned from the first call: the dispatcher that owns the tickets.
    dispatcher: ?*proto.Dispatcher = null,

    pub const Params = struct { tool_name: []const u8, input: []const u8, tool_use_id: []const u8 };

    pub fn binding(self: *Permissions) proto.Binding {
        return .{ .verb = "harness.permission_prompt", .handler = proto.VerbHandler.typed(Params, self) };
    }

    /// What the claude-code adapter answers prompts through. `self` must
    /// not move afterwards.
    pub fn replier(self: *Permissions) harness.claude_code.Replier {
        return .{ .ptr = self, .reply = reply };
    }

    pub fn call(self: *Permissions, c: *proto.Call, p: Params) anyerror!void {
        self.dispatcher = c.dispatcher;
        const pr = self.principals orelse return c.fail("denied.not_agent", "only an agent's harness process may raise its permission prompts", .{});
        const agent = pr.ownAgentOf(c.conn.identity.principal) orelse return c.fail("denied.not_agent", "only an agent's harness process may raise its permission prompts", .{});
        if (!try c.authorize(.write, .{ .kind = "agent", .id = agent })) return;
        const b = self.host.binding(agent) orelse return c.fail("not_found.agent", "the agent has no harness binding", .{ .agent = agent });
        const cc = ClaudeCode.of(b.adapter) orelse return c.fail("unsupported.harness_capability", "the agent's harness has no permission prompt tool", .{ .agent = agent, .harness = b.conv.harness });
        if (!b.running()) return c.fail("failed.harness_exited", "the agent's harness process is gone", .{ .agent = agent });
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, c.arena(), p.input, .{}) catch null;
        if (parsed == null or parsed.? != .object) return c.fail("invalid_params.input", "input must be a JSON object", .{ .param = "input" });
        // The ticket is kept before the request is raised: an answer that
        // a kept grant gives at once still finds the call.
        const ticket = c.ticket;
        cc.permissionPrompt(&b.conv, .{ .tool_name = p.tool_name, .input_json = p.input, .tool_use_id = p.tool_use_id, .ticket = ticket }) catch |err| {
            const f = harness.contract.failure(err) orelse return err;
            // A tool_use_id already prompted for is a harness protocol slip.
            return c.fail(f.code, @errorName(err), .{ .agent = agent, .tool_use_id = p.tool_use_id });
        };
    }

    fn reply(ptr: *anyopaque, agent: []const u8, tool_use_id: []const u8, ticket: u64, result: []const u8) anyerror!void {
        const self: *Permissions = @ptrCast(@alignCast(ptr));
        _ = agent;
        _ = tool_use_id;
        const d = self.dispatcher orelse return error.RequestResolved;
        const open = d.get(ticket) orelse return error.RequestResolved;
        try open.ok(.{ .result = result });
    }
};
