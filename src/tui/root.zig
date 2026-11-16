//! venom's own TUI: `venom` and `venom agent view`,
//! a client of the daemon over its socket, its verbs and `venom events`.
//!
//! - model.zig: what the daemon said (snapshot, events, list, show)
//! - app.zig: widget state, keys → verbs or local actions, requests
//! - keys.zig: the key table and the help overlay's contents
//! - input_box.zig: send modes, context meter and the box
//! - inbox.zig: the last `inbox.list`
//! - view.zig: the main layout drawn into a venom-term Surface
//! - agent_list.zig: the agent list's rows and cursor
//! - transcript.zig: tool-call rows, density, grouping, pager
//! - fan_out.zig: the fan-out block, `[` `]`, breadcrumb, wait, stop, promote
//! - inbox_view.zig: the inbox screen (`leader i`, `venom inbox`)
//! - settings.zig: the settings screen's state and keys
//! - settings_view.zig: draws it (`leader s`, `venom settings`)
//! - providers.zig: the `providers` value, parsed and written back, and sign-in commands
//! - provider_popup.zig: Settings › Providers' popup: a new provider, or changes to one
//! - usage_view.zig: the usage screen (`leader u`)
//! - context_panel.zig: the context panel (`leader a c`)
//! - diff.zig: `git diff` for the pager (`d`)
//! - zon_text.zig: the pending ZON diff, from `config get`'s text
//! - split.zig, pty.zig: own-mode splits, the split menu
//! - host.zig: `ui.chrome`, the venomx control pane
//! - workspaces.zig: the workspaces panel (`leader w w`)
//! - new_agent.zig: the new-agent dialog (`n`, `leader a N`)
//! - link.zig: the socket client, subscription and reconnects
//! - terminal.zig: the local command, raw mode and the loop
pub const model = @import("model.zig");
pub const keys = @import("keys.zig");
pub const inbox = @import("inbox.zig");
pub const App = @import("app.zig").App;
pub const view = @import("view.zig");
pub const Link = @import("link.zig").Link;
pub const terminal = @import("terminal.zig");
pub const split = @import("split.zig");
pub const transcript = @import("transcript.zig");
pub const host = @import("host.zig");
pub const fan_out = @import("fan_out.zig");
pub const link_now = @import("link.zig").nowMs;
pub const Command = terminal.Command;
pub const local_commands = terminal.local_commands;
pub const rewriteArgs = terminal.rewriteArgs;

test {
    _ = model;
    _ = keys;
    _ = inbox;
    _ = terminal;
    _ = split;
    _ = transcript;
    _ = @import("approval_card.zig");
    _ = @import("fan_out_tests.zig");
    _ = @import("transcript_tests.zig");
    _ = host;
    _ = @import("host_tests.zig");
    _ = @import("pty.zig");
    _ = @import("split_tests.zig");
    _ = @import("tests.zig");
    _ = @import("paging_tests.zig");
    _ = @import("agent_list_tests.zig");
    _ = @import("inbox_tests.zig");
    _ = @import("input_box.zig");
    _ = @import("input_box_tests.zig");
    _ = @import("workspaces.zig");
    _ = @import("diff.zig");
    _ = @import("leader_tests.zig");
    _ = @import("new_agent.zig");
    _ = @import("new_agent_tests.zig");
    _ = @import("settings.zig");
    _ = @import("providers.zig");
    _ = @import("provider_popup.zig");
    _ = @import("zon_text.zig");
    _ = @import("settings_tests.zig");
    _ = @import("usage_view_tests.zig");
}
