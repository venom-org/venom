//! venom's MCP server for agents: how a claude-code or codex
//! agent gets `venom mcp` for its run, so agents can orchestrate agents
//! (`agent_dspawn`, `agent_dlist`, … over MCP).
//!
//! Each adapter configures the server through the harness's official
//! per-run mechanism, never by writing the user's harness config:
//!
//! | Harness | Mechanism |
//! |---|---|
//! | claude-code | `--mcp-config '{"mcpServers":{"venom":{"command":…,"args":["mcp"],"env":{"VENOM_SOCKET":…}}}}'` |
//! | codex | `-c mcp_servers.venom.command=…`, `.args=["mcp"]`, `.env={VENOM_SOCKET=…}`, `.env_vars=["VENOM_TOKEN"]` on `codex app-server` |
//!
//! **Identity.** The harness process gets its own token as `VENOM_TOKEN`
//! (`principals.zig`), and the token is bound to that process.
//! `venom mcp` is the harness's child, so it inherits the variable (Claude
//! Code passes its environment to stdio servers; Codex forwards only what
//! `env_vars` names) and presents it in `hello.auth`, which attributes every
//! MCP call to the agent's principal. The token is
//! never put into argv or the config text, so it cannot show up in `ps`
//! output or a harness log. Without it, the call still resolves to the
//! harness's principal through the process binding (the adapter is a
//! descendant of the bound process).
//!
//! **Socket.** `VENOM_SOCKET` carries the daemon's socket path (it follows
//! `venom serve --socket`), both in the harness's environment (for `venom`
//! CLI calls from the agent's shell) and in the server entry, because Codex
//! does not forward the rest of its environment.
//!
//! `venom mcp` takes no parameters: the token names the agent (an
//! `--agent` flag could not be trusted anyway).
//!
//! **Permission prompts.** Claude Code also gets a second stdio
//! server, `venom-permissions` (`venom agent permission-server`,
//! `permission_server.zig`), whose one tool `permission_prompt` is the
//! `--permission-prompt-tool`. It is separate from `venom mcp` because
//! Claude Code reads the tool result's text as the permission result JSON
//! itself, while the generated server wraps every result as
//! `{"result":…}`, and because a prompt stays open until a human answers,
//! which the generated server (one call at a time) would block on. Same
//! binary, same socket and token rules.
const std = @import("std");

/// The server's name in the harness's MCP config; Claude Code's tools are
/// `mcp__venom__<tool>`.
pub const server_name = "venom";
/// The token variable, set by the harness host.
pub const token_env = "VENOM_TOKEN";
/// The daemon socket variable.
pub const socket_env = "VENOM_SOCKET";
/// The permission prompt server's name in Claude Code's MCP config.
pub const permissions_server_name = "venom-permissions";
/// Its arguments: the local verb `agent.permission_server`.
pub const permissions_args = [_][]const u8{ "agent", "permission-server" };
/// The tool Claude Code calls for permission prompts, under that server.
pub const permission_tool = "permission_prompt";

/// venom's MCP server as a harness should start it.
pub const Server = struct {
    /// The venom binary; the daemon passes its own executable path.
    command: []const u8 = "venom",
    args: []const []const u8 = &.{"mcp"},
    /// The daemon's socket, passed as `VENOM_SOCKET`; null leaves the
    /// default (`$XDG_RUNTIME_DIR/venom/venom.sock`).
    socket: ?[]const u8 = null,
};

/// Claude Code's `--mcp-config` JSON for `server`; with `permissions`,
/// also the permission prompt server (same binary and socket).
pub fn claudeConfig(a: std.mem.Allocator, server: Server, permissions: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("mcpServers");
    try s.beginObject();
    try stdioEntry(&s, server_name, server.command, server.args, server.socket);
    if (permissions) try stdioEntry(&s, permissions_server_name, server.command, &permissions_args, server.socket);
    try s.endObject();
    try s.endObject();
    return out.written();
}

fn stdioEntry(s: *std.json.Stringify, name: []const u8, command: []const u8, args: []const []const u8, socket: ?[]const u8) !void {
    try s.objectField(name);
    try s.beginObject();
    try s.objectField("command");
    try s.write(command);
    try s.objectField("args");
    try s.write(args);
    if (socket) |path| {
        try s.objectField("env");
        try s.beginObject();
        try s.objectField(socket_env);
        try s.write(path);
        try s.endObject();
    }
    try s.endObject();
}

/// Codex `-c key=value` overrides (TOML values) for `server`, as argv.
pub fn codexOverrides(a: std.mem.Allocator, server: Server) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const prefix = "mcp_servers." ++ server_name;
    try out.appendSlice(a, &.{ "-c", try std.fmt.allocPrint(a, prefix ++ ".command={f}", .{tomlString(server.command)}) });
    var args: std.Io.Writer.Allocating = .init(a);
    try args.writer.writeByte('[');
    for (server.args, 0..) |arg, i| {
        if (i > 0) try args.writer.writeByte(',');
        try args.writer.print("{f}", .{tomlString(arg)});
    }
    try args.writer.writeByte(']');
    try out.appendSlice(a, &.{ "-c", try std.fmt.allocPrint(a, prefix ++ ".args={s}", .{args.written()}) });
    if (server.socket) |path| try out.appendSlice(a, &.{ "-c", try std.fmt.allocPrint(a, prefix ++ ".env={{" ++ socket_env ++ "={f}}}", .{tomlString(path)}) });
    try out.appendSlice(a, &.{ "-c", prefix ++ ".env_vars=[\"" ++ token_env ++ "\"]" });
    return out.items;
}

/// The Codex `-c notify=[...]` override (`attention_away`):
/// Codex appends its JSON as the last argument, which makes it `--input`'s value.
pub fn codexNotify(a: std.mem.Allocator, venom: []const u8, agent: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "notify=[{f},\"agent\",\"hook\",\"--agent\",{f},\"--input\"]", .{ tomlString(venom), tomlString(agent) });
}

/// A TOML basic string. JSON string escapes are valid TOML escapes, and
/// std.json escapes every control character.
fn tomlString(s: []const u8) std.json.Formatter([]const u8) {
    return std.json.fmt(s, .{});
}

const testing = std.testing;

test "claudeConfig: the venom stdio server with its socket, never a token" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\{"mcpServers":{"venom":{"command":"/usr/bin/venom","args":["mcp"],"env":{"VENOM_SOCKET":"/run/u/venom \"x\".sock"}}}}
    , try claudeConfig(a, .{ .command = "/usr/bin/venom", .socket = "/run/u/venom \"x\".sock" }, false));
    try testing.expectEqualStrings(
        \\{"mcpServers":{"venom":{"command":"venom","args":["mcp"]}}}
    , try claudeConfig(a, .{}, false));
    // The permission prompt server beside it, same binary and socket.
    try testing.expectEqualStrings(
        \\{"mcpServers":{"venom":{"command":"/usr/bin/venom","args":["mcp"],"env":{"VENOM_SOCKET":"/run/v.sock"}},"venom-permissions":{"command":"/usr/bin/venom","args":["agent","permission-server"],"env":{"VENOM_SOCKET":"/run/v.sock"}}}}
    , try claudeConfig(a, .{ .command = "/usr/bin/venom", .socket = "/run/v.sock" }, true));
}

test "codexNotify: a TOML array that ends in --input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\notify=["/opt/v\\enom","agent","hook","--agent","a1","--input"]
    , try codexNotify(arena.allocator(), "/opt/v\\enom", "a1"));
}

test "codexOverrides: -c overrides with TOML strings; the token is forwarded by name only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try codexOverrides(a, .{ .command = "/opt/v\\enom", .socket = "/run/u/venom.sock" });
    const want = [_][]const u8{
        "-c", "mcp_servers.venom.command=\"/opt/v\\\\enom\"",
        "-c", "mcp_servers.venom.args=[\"mcp\"]",
        "-c", "mcp_servers.venom.env={VENOM_SOCKET=\"/run/u/venom.sock\"}",
        "-c", "mcp_servers.venom.env_vars=[\"VENOM_TOKEN\"]",
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(@as(usize, 6), (try codexOverrides(a, .{})).len);
}
