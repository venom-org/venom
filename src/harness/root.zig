//! Harness adapters: the adapter interface
//! (`contract.zig`), harness processes (`process.zig`), the host that
//! supervises them and logs their normalized events (`host.zig`), and the
//! fake harness used by tests (`fake.zig`, binary `fake_main.zig`), the
//! claude-code adapter (`claude_code.zig`), and the Codex adapter
//! over `codex app-server` (`codex.zig`), and how both get
//! venom's MCP server for the agent (`mcp.zig`), and the test
//! guard that keeps tests off the real vendor CLIs (`guard.zig`),
//! and `<harness> --version` for probe and doctor (`version.zig`),
//! and what `doctor` and `harness.list` ask each vendor CLI (`discovery.zig`),
//! and the generic ACP adapter (`acp.zig`).
pub const contract = @import("contract.zig");
pub const process = @import("process.zig");
pub const host = @import("host.zig");
pub const fake = @import("fake.zig");
pub const claude_code = @import("claude_code.zig");
pub const claude_transcript = @import("claude_transcript.zig");
pub const codex = @import("codex.zig");
pub const codex_record = @import("codex_record.zig");
pub const acp = @import("acp.zig");
pub const mcp = @import("mcp.zig");
pub const guard = @import("guard.zig");
pub const version = @import("version.zig");
pub const discovery = @import("discovery.zig");
pub const Adapter = contract.Adapter;
pub const Conversation = contract.Conversation;
pub const Descriptor = contract.Descriptor;
pub const Host = host.Host;
pub const Fake = fake.Fake;
pub const ClaudeCode = claude_code.ClaudeCode;
pub const Codex = codex.Codex;
pub const Acp = acp.Acp;

test {
    _ = contract;
    _ = process;
    _ = host;
    _ = fake;
    _ = claude_code;
    _ = claude_transcript;
    _ = @import("claude_code_tests.zig");
    _ = codex;
    _ = acp;
    _ = mcp;
    _ = guard;
    _ = version;
    _ = discovery;
}
