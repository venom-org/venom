//! The TUI's key table (CLI parity): every key
//! is either a schema verb, sent with the TUI's own identity, or a typed
//! local presentation action that never leaves the process. The help
//! overlay (`?`) and the leader tree are both made
//! from this table, so the popup, the help and the keys that run agree, and
//! a test checks that every verb named here exists in venom's schema.
const std = @import("std");
const term = @import("venom-term");
const Key = term.Input.Key;
const NamedKey = term.Input.NamedKey;
const k = term.widgets.keys;
const chord = term.chrome.keys;

/// Local presentation actions: no wire name, no daemon dispatch.
pub const Local = enum {
    /// Move the list cursor (j/k, arrows, PgUp/PgDn, Home/End) and fold
    /// groups (h/l, arrows): the list widget's own keys.
    move,
    /// Tab / Shift-Tab: agent list → transcript → input box → splits (an
    /// agent view: its transcript, then its input box).
    focus,
    /// `i`: enter Input mode on the selected agent.
    input,
    /// `⌃c` in Input: clear the draft. The mode does not change.
    clear_draft,
    /// `leader i`: the inbox screen.
    inbox,
    /// `leader s`: the settings screen.
    settings,
    /// `leader u`: the usage screen.
    usage,
    /// `leader a c`: the context panel for the agent.
    context_panel,
    /// `?`: the keys of this view.
    help,
    /// `leader ?`: all the keys.
    help_all,
    /// `leader a a`: the agents screen, on its list.
    agents,
    /// `d`, `leader d`: the agent's diff in the pager.
    diff,
    /// `!`: the next item that needs you.
    next_attention,
    /// Leave the input box or close the help.
    back,
    /// Leave the TUI. Agents keep running in the daemon.
    quit,
    /// `\` / `⌃⏎`: the split menu for the agent.
    split_menu,
    /// `leader v x`: close the split; the agent keeps running.
    close_split,
    /// `leader v s`: a shell in the agent's folder, without the menu.
    shell_split,
    /// `leader v t`: take over in the harness's own TUI, without the menu.
    take_over,
    /// `leader v` then a direction: move between splits (own mode only).
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    /// `ui.keys.leave_terminal` (`⌃]`): leave Terminal mode, where the
    /// program takes every other key.
    leave_terminal,
    /// `T`: take a handed-over agent back from its harness's own TUI:
    /// closes the take-over split, then
    /// `agent.takeback`.
    take_back,
    /// `g`: cycle the agent list's grouping.
    group_by,
    /// `t`: cycle how the agent list shows sub-agents.
    children,
    /// `/`: filter the agent list.
    filter,
    /// `v`: cycle the transcript's density.
    density,
    /// `E` / `C`: expand or collapse every row.
    expand_all,
    collapse_all,
    /// `p`: the selected row's body in the pager (`agent.tool`).
    pager,
    /// `J`: the selected row's raw tool JSON (`agent.tool`).
    raw_json,
    /// `leader w w`: the workspaces panel.
    workspaces,
    /// `leader w a`: the panel, asking for a folder to add.
    workspace_add,
    /// `leader w r`: the panel, rescanning the workspace under its cursor.
    workspace_rescan,
    /// `]`: into the focused child.
    to_child,
    /// `[`: to the parent.
    to_parent,
    /// `P`: promote the focused child (`agent.promote`).
    promote,
    /// `w` in a transcript: wait for all the children (`agent.wait`).
    wait_all,
    /// `K`: stop the agent and all below it (`agent.stop --tree`).
    stop_all,
    /// `n`: the new-agent dialog, in this workspace.
    new_agent,
    /// `leader a N`: the new-agent dialog, on its workspace field.
    new_agent_pick,
};

/// The actions on an inbox item: on the inbox
/// screen for the item under the cursor, and inline in the transcript for
/// the selected agent's most urgent item. Most are `inbox.*` verbs.
pub const Attention = enum {
    /// approval `y`: allow once; plan `y`: approve.
    yes,
    /// approval `a`: allow always (the narrowest grant).
    always,
    /// approval `e`: allow an edited command (asks for it).
    edit,
    /// approval `n`: deny; plan `n`: reject with feedback (asks for it).
    no,
    /// approval `r`: deny with a reason (asks for it).
    reason,
    /// question `1`–`9`: pick an option.
    pick,
    /// question `⏎`: type an answer.
    type_answer,
    /// failed, limit `R`: retry.
    retry,
    /// failed, limit, review `o` (and any kind on the inbox screen): open the agent.
    open,
    /// review `x`: archive.
    archive,
    /// any `s`: snooze 15m.
    snooze,
    /// any `\`: open in split.
    split,
    /// any `m`: mark for a batch (inbox screen).
    mark,
    /// `Y`: allow the marked approvals once (same grant only).
    batch_allow,
    /// `N`: deny the marked approvals.
    batch_deny,

    /// The verb the action sends, if any (for help and the schema test).
    pub fn verb(self: Attention) ?[]const u8 {
        return switch (self) {
            .yes, .always, .edit, .no, .reason, .pick, .type_answer => "inbox.answer",
            .archive => "agent.archive",
            .snooze => "inbox.snooze",
            .batch_allow, .batch_deny => "inbox.batch",
            .retry, .open, .split, .mark => null,
        };
    }
};

pub const Action = union(enum) {
    /// A verb from venom's schema, applied to the selected agent.
    verb: []const u8,
    local: Local,
    attention: Attention,
};

/// Where a binding applies: `inbox` is the inbox screen's list,
/// `attention` the per-kind keys there and inline in the transcript;
/// `workspaces` is the workspaces panel, `dialog` the new-agent dialog,
/// `settings` the settings screen (settings.zig reads its keys). `leader` is
/// the tree after `ui.keys.leader`, and `leader_own`
/// the part of it that has no meaning under venomx, because no verb moves a
/// client's focus.
pub const Context = enum { list, transcript, input, inbox, attention, split, workspaces, dialog, settings, usage, context, any, leader, leader_own };

/// The popup a tree row opens from any pane under venomx: its `ctrl+a v` key.
/// Only a row with such a target can run outside venom.
pub const Outside = enum { inbox, settings, diff, usage };

pub const Binding = struct {
    /// Display text; for the two leader contexts, the key sequence after the
    /// leader in venomx's key syntax.
    keys: []const u8,
    /// Short enough for the popup in the leader contexts (40 bytes).
    label: []const u8,
    action: Action,
    context: Context,
    /// A second sequence for the same row (`v h` and `v left`). The leader contexts only.
    alt: ?[]const u8 = null,
    /// What host mode registers for this row (`host.keyTable`). The leader
    /// context only.
    outside: ?Outside = null,

    /// A row that leaves the screen for an agent, which a popup that only
    /// reads doesn't offer (`App.setSingleView`).
    pub fn opensAgent(self: *const Binding) bool {
        if (self.context == .usage) return std.mem.eql(u8, self.keys, "⏎");
        return switch (self.action) {
            .attention => |at| at == .open or at == .split or at == .retry,
            else => false,
        };
    }

    pub fn inTree(self: *const Binding) bool {
        return self.context == .leader or self.context == .leader_own;
    }
};

/// The table, in help order. `match` below decides the bare keys, for which
/// `keys` is display text; the router runs the leader rows.
pub const table = [_]Binding{
    .{ .keys = "j k ↑ ↓", .label = "move", .action = .{ .local = .move }, .context = .list },
    .{ .keys = "⏎", .label = "open the agent", .action = .{ .verb = "agent.show" }, .context = .list },
    .{ .keys = "g", .label = "group by: state, workspace, repo", .action = .{ .local = .group_by }, .context = .list },
    .{ .keys = "t", .label = "sub-agents: tree, folded, hidden", .action = .{ .local = .children }, .context = .list },
    .{ .keys = "/", .label = "filter: harness, repo, issue, title", .action = .{ .local = .filter }, .context = .list },
    .{ .keys = "i", .label = "input: write to the selected agent", .action = .{ .local = .input }, .context = .list },
    .{ .keys = "⏎", .label = "send; mid-turn steer or queue, as the harness can", .action = .{ .verb = "agent.send" }, .context = .input },
    .{ .keys = "⇧⏎", .label = "queue after the running turn", .action = .{ .verb = "agent.send" }, .context = .input },
    .{ .keys = "⌥⏎", .label = "interrupt the running turn and send", .action = .{ .verb = "agent.send" }, .context = .input },
    .{ .keys = "⌃c", .label = "input: clear the draft", .action = .{ .local = .clear_draft }, .context = .input },
    .{ .keys = "⌃u ⌃w ⌃a", .label = "input: edit the text", .action = .{ .local = .move }, .context = .input },
    .{ .keys = "S", .label = "stop the agent's turn", .action = .{ .verb = "agent.stop" }, .context = .list },
    .{ .keys = "x", .label = "archive the agent", .action = .{ .verb = "agent.archive" }, .context = .list },
    .{ .keys = "n", .label = "new agent here", .action = .{ .local = .new_agent }, .context = .list },
    .{ .keys = "h l ← →", .label = "fold or unfold the group", .action = .{ .local = .move }, .context = .list },
    .{ .keys = "d", .label = "the agent's diff", .action = .{ .local = .diff }, .context = .list },
    .{ .keys = "!", .label = "next item that needs you", .action = .{ .local = .next_attention }, .context = .list },
    .{ .keys = "\\ ⌃⏎", .label = "open in split: agent view, shell, take over", .action = .{ .local = .split_menu }, .context = .list },
    .{ .keys = "⌃]", .label = "leave Terminal mode (ui.keys.leave_terminal)", .action = .{ .local = .leave_terminal }, .context = .split },
    .{ .keys = "⇥", .label = "agent view split: to its input box", .action = .{ .local = .focus }, .context = .split },
    .{ .keys = "y a n …", .label = "agent view split: answer its item", .action = .{ .attention = .yes }, .context = .split },
    .{ .keys = "T", .label = "take back from the harness's own TUI", .action = .{ .local = .take_back }, .context = .list },
    .{ .keys = "]", .label = "into the focused child", .action = .{ .local = .to_child }, .context = .list },
    .{ .keys = "[", .label = "to the parent", .action = .{ .local = .to_parent }, .context = .list },
    .{ .keys = "P", .label = "promote the child to top level", .action = .{ .verb = "agent.promote" }, .context = .list },
    .{ .keys = "j k ↑ ↓", .label = "transcript: previous / next row", .action = .{ .local = .move }, .context = .transcript },
    .{ .keys = "⏎", .label = "open or close the row", .action = .{ .local = .move }, .context = .transcript },
    .{ .keys = "v", .label = "density: compact, normal, verbose", .action = .{ .local = .density }, .context = .transcript },
    .{ .keys = "E C", .label = "expand / collapse all rows", .action = .{ .local = .expand_all }, .context = .transcript },
    .{ .keys = "p", .label = "the row's body in the pager", .action = .{ .local = .pager }, .context = .transcript },
    .{ .keys = "J", .label = "the row's raw tool JSON", .action = .{ .local = .raw_json }, .context = .transcript },
    .{ .keys = "w", .label = "wait for all its sub-agents", .action = .{ .verb = "agent.wait" }, .context = .transcript },
    .{ .keys = "K", .label = "stop it and all its sub-agents", .action = .{ .verb = "agent.stop" }, .context = .transcript },
    .{ .keys = "y a n …", .label = "answer the agent's item (in the transcript)", .action = .{ .attention = .yes }, .context = .transcript },
    .{ .keys = "j k ↑ ↓", .label = "next / previous item", .action = .{ .local = .move }, .context = .inbox },
    .{ .keys = "y", .label = "allow once · plan: approve", .action = .{ .attention = .yes }, .context = .attention },
    .{ .keys = "a", .label = "allow always (narrowest grant)", .action = .{ .attention = .always }, .context = .attention },
    .{ .keys = "e", .label = "allow an edited command", .action = .{ .attention = .edit }, .context = .attention },
    .{ .keys = "n", .label = "deny · plan: reject with feedback", .action = .{ .attention = .no }, .context = .attention },
    .{ .keys = "r", .label = "deny with a reason", .action = .{ .attention = .reason }, .context = .attention },
    .{ .keys = "1–9 ⏎", .label = "question: pick an option, or type", .action = .{ .attention = .pick }, .context = .attention },
    .{ .keys = "R", .label = "failed, limit: retry", .action = .{ .attention = .retry }, .context = .attention },
    .{ .keys = "o", .label = "open the agent", .action = .{ .attention = .open }, .context = .attention },
    .{ .keys = "x", .label = "review: archive", .action = .{ .attention = .archive }, .context = .attention },
    .{ .keys = "s", .label = "snooze 15m", .action = .{ .attention = .snooze }, .context = .attention },
    .{ .keys = "\\", .label = "open in split", .action = .{ .attention = .split }, .context = .attention },
    .{ .keys = "m", .label = "mark for a batch", .action = .{ .attention = .mark }, .context = .inbox },
    .{ .keys = "Y N", .label = "allow / deny marked (same grant)", .action = .{ .attention = .batch_allow }, .context = .inbox },
    .{ .keys = "!", .label = "next item that needs you", .action = .{ .local = .next_attention }, .context = .inbox },
    .{ .keys = "esc", .label = "back to the agents", .action = .{ .local = .back }, .context = .inbox },
    .{ .keys = "j k ↑ ↓", .label = "next / previous workspace", .action = .{ .local = .move }, .context = .workspaces },
    .{ .keys = "n", .label = "new agent here", .action = .{ .local = .new_agent }, .context = .workspaces },
    .{ .keys = "N", .label = "new agent, pick the workspace", .action = .{ .local = .new_agent_pick }, .context = .workspaces },
    .{ .keys = "+ a", .label = "add a folder", .action = .{ .verb = "workspace.add" }, .context = .workspaces },
    .{ .keys = "R", .label = "rescan its repos", .action = .{ .verb = "workspace.scan" }, .context = .workspaces },
    .{ .keys = "esc", .label = "back to the agents", .action = .{ .local = .back }, .context = .workspaces },
    .{ .keys = "⏎", .label = "start and show in the main view", .action = .{ .verb = "agent.spawn" }, .context = .dialog },
    .{ .keys = "⇧⏎", .label = "run in background (appears in the list)", .action = .{ .verb = "agent.spawn" }, .context = .dialog },
    .{ .keys = "⌃⏎", .label = "start, then the split menu", .action = .{ .verb = "agent.spawn" }, .context = .dialog },
    .{ .keys = "⇥ ↑ ↓", .label = "next / previous field", .action = .{ .local = .move }, .context = .dialog },
    .{ .keys = "h l ← →", .label = "change the option", .action = .{ .local = .move }, .context = .dialog },
    .{ .keys = "space", .label = "pick the repo under the cursor", .action = .{ .local = .move }, .context = .dialog },
    .{ .keys = "j k ↑ ↓", .label = "move", .action = .{ .local = .move }, .context = .settings },
    .{ .keys = "⇥", .label = "sections, fields, preview", .action = .{ .local = .focus }, .context = .settings },
    .{ .keys = "h l ← →", .label = "step the value; elsewhere, the next pane", .action = .{ .local = .move }, .context = .settings },
    .{ .keys = "⇟ ⇞", .label = "scroll the preview", .action = .{ .local = .move }, .context = .settings },
    .{ .keys = "⏎", .label = "edit the field, toggle or step", .action = .{ .local = .move }, .context = .settings },
    .{ .keys = "S", .label = "switch layer: user, workspace, repo", .action = .{ .verb = "config.get" }, .context = .settings },
    .{ .keys = "u", .label = "undo the last pending change", .action = .{ .local = .move }, .context = .settings },
    .{ .keys = "⌃s", .label = "save and reload", .action = .{ .verb = "config.set" }, .context = .settings },
    .{ .keys = "esc", .label = "back to the agents", .action = .{ .local = .back }, .context = .settings },
    .{ .keys = "1 2 3", .label = "range: today, 7 days, 30 days", .action = .{ .verb = "usage.show" }, .context = .usage },
    .{ .keys = "g", .label = "group by: agent, harness, workspace", .action = .{ .verb = "usage.show" }, .context = .usage },
    .{ .keys = "j k ↑ ↓", .label = "move", .action = .{ .local = .move }, .context = .usage },
    .{ .keys = "⏎", .label = "open the agent", .action = .{ .local = .back }, .context = .usage },
    .{ .keys = "e", .label = "export CSV to this folder", .action = .{ .verb = "usage.export" }, .context = .usage },
    .{ .keys = "esc", .label = "back to the agents", .action = .{ .local = .back }, .context = .usage },
    .{ .keys = "c", .label = "compact now, where the harness can", .action = .{ .verb = "agent.compact" }, .context = .context },
    .{ .keys = "f", .label = "fork to a fresh agent with a summary", .action = .{ .verb = "agent.fork" }, .context = .context },
    .{ .keys = "m", .label = "turn off MCP servers it hasn't used", .action = .{ .verb = "agent.mcp_off" }, .context = .context },
    .{ .keys = "esc", .label = "close", .action = .{ .local = .back }, .context = .context },
    .{ .keys = "⇥ ⇧⇥", .label = "next / previous area", .action = .{ .local = .focus }, .context = .any },
    .{ .keys = "esc", .label = "back one step; keeps the draft", .action = .{ .local = .back }, .context = .any },
    .{ .keys = "?", .label = "keys (this help)", .action = .{ .local = .help }, .context = .any },
    .{ .keys = "q ⌃c", .label = "quit (agents keep running)", .action = .{ .local = .quit }, .context = .any },
    // The leader tree. `leader leader` is the switcher
    // and `leader :` the command prompt; the router
    // takes the first itself, so neither is a row here.
    .{ .keys = "a a", .label = "agents screen", .action = .{ .local = .agents }, .context = .leader },
    .{ .keys = "a n", .label = "new agent here", .action = .{ .local = .new_agent }, .context = .leader },
    .{ .keys = "a N", .label = "new agent, pick the workspace", .action = .{ .local = .new_agent_pick }, .context = .leader },
    .{ .keys = "a s", .label = "stop its turn", .action = .{ .verb = "agent.stop" }, .context = .leader },
    .{ .keys = "a x", .label = "archive", .action = .{ .verb = "agent.archive" }, .context = .leader },
    .{ .keys = "a f", .label = "fork", .action = .{ .verb = "agent.fork" }, .context = .leader },
    .{ .keys = "a c", .label = "context window", .action = .{ .local = .context_panel }, .context = .leader },
    .{ .keys = "w w", .label = "workspaces", .action = .{ .local = .workspaces }, .context = .leader },
    .{ .keys = "w a", .label = "add a folder", .action = .{ .local = .workspace_add }, .context = .leader },
    .{ .keys = "w r", .label = "rescan its repos", .action = .{ .local = .workspace_rescan }, .context = .leader },
    .{ .keys = "v v", .label = "split menu", .action = .{ .local = .split_menu }, .context = .leader },
    .{ .keys = "v s", .label = "shell split", .action = .{ .local = .shell_split }, .context = .leader },
    .{ .keys = "v t", .label = "take over", .action = .{ .local = .take_over }, .context = .leader },
    .{ .keys = "v x", .label = "close the split", .action = .{ .local = .close_split }, .context = .leader },
    .{ .keys = "i", .label = "inbox", .action = .{ .local = .inbox }, .context = .leader, .outside = .inbox },
    .{ .keys = "s", .label = "settings", .action = .{ .local = .settings }, .context = .leader, .outside = .settings },
    .{ .keys = "d", .label = "diff", .action = .{ .local = .diff }, .context = .leader, .outside = .diff },
    .{ .keys = "u", .label = "usage", .action = .{ .local = .usage }, .context = .leader, .outside = .usage },
    .{ .keys = "?", .label = "all keys", .action = .{ .local = .help_all }, .context = .leader },
    .{ .keys = "v h", .alt = "v left", .label = "split to the left", .action = .{ .local = .focus_left }, .context = .leader_own },
    .{ .keys = "v j", .alt = "v down", .label = "down, into the input box", .action = .{ .local = .focus_down }, .context = .leader_own },
    .{ .keys = "v k", .alt = "v up", .label = "up", .action = .{ .local = .focus_up }, .context = .leader_own },
    .{ .keys = "v l", .alt = "v right", .label = "split to the right", .action = .{ .local = .focus_right }, .context = .leader_own },
};

// ---- The leader tree ---------------------------------------------------------

/// A command's name, for the popup's fallback and the command prompt: its
/// local action or its verb.
fn actionName(action: Action) []const u8 {
    return switch (action) {
        .verb => |v| v,
        .local => |l| @tagName(l),
        .attention => |at| @tagName(at),
    };
}

/// The tree's action named `name`: `leader :` runs a command by name through
/// the same path as its key.
pub fn commandNamed(name: []const u8) ?Action {
    for (table) |b| if (b.inTree() and std.mem.eql(u8, actionName(b.action), name)) return b.action;
    return null;
}

/// venom-term's router and tables, over the actions bare keys run too.
pub const K = chord.Tables(Action, .{ .parseLocal = commandNamed, .localName = actionName });

fn treeRows(comptime context: Context) usize {
    var n: usize = 0;
    for (table) |b| {
        if (b.context == context) n += if (b.alt != null) 2 else 1;
    }
    return n;
}

fn treeBindings(comptime context: Context) [treeRows(context)]K.Binding {
    @setEvalBranchQuota(100_000);
    var out: [treeRows(context)]K.Binding = undefined;
    var n: usize = 0;
    for (table) |b| {
        if (b.context != context) continue;
        out[n] = K.labeled(b.keys, .{ .local = b.action }, b.label);
        n += 1;
        if (b.alt) |alt| {
            out[n] = K.labeled(alt, .{ .local = b.action }, b.label);
            n += 1;
        }
    }
    return out;
}

const shared_bindings = treeBindings(.leader);
const own_bindings = treeBindings(.leader_own);
const tree_groups = [_]chord.Group{ chord.group("a", "agents", false), chord.group("w", "workspaces", false), chord.group("v", "splits", false) };

/// The tree that works everywhere. `host.keyTable` registers its rows that have
/// an `outside` target with venomx, under its prefix.
pub const shared_table: K.Table = .{ .name = "venom", .layer = .product, .groups = &tree_groups, .bindings = &shared_bindings };
const own_table: K.Table = .{ .name = "venom-own", .layer = .product, .bindings = &own_bindings };

const own_tables = [_]K.Table{ shared_table, own_table };
const host_tables = [_]K.Table{shared_table};

/// What the router resolves. Under venomx the direction rows are absent, from
/// the keys and the popup alike.
pub fn treeTables(host: bool) []const K.Table {
    return if (host) &host_tables else &own_tables;
}

/// The keys of a row as the help prints them. A leader row starts with the
/// configured leader, and its second sequence
/// differs only in the last key: `space v h ←`.
pub fn shownKeys(a: std.mem.Allocator, b: *const Binding, leader: []const u8) ![]const u8 {
    if (!b.inTree()) return b.keys;
    const alt = b.alt orelse return std.fmt.allocPrint(a, "{s} {s}", .{ leader, b.keys });
    const seq = chord.parseSequence(alt) orelse return std.fmt.allocPrint(a, "{s} {s}", .{ leader, b.keys });
    return std.fmt.allocPrint(a, "{s} {s} {s}", .{ leader, b.keys, try term.chrome.leader_popup.keyText(a, seq.slice()[seq.len - 1]) });
}

/// The binding for `key` in `ctx`, or null when the focused widget should
/// have it. Input mode takes text and its own keys:
/// the send keys, esc, ⌃c, and Tab to move on around the focus ring. `⌃u`,
/// `⌃w` and `⌃a` edit the text, so they are the widget's.
pub fn match(key: Key, ctx: Context) ?Action {
    if (!k.pressed(key)) return null;
    const tab = k.namedAny(key, .tab) and !key.mods.ctrl and !key.mods.alt;
    if (ctx == .input) {
        if (k.ctrl(key, 'c')) return .{ .local = .clear_draft };
        if (tab) return .{ .local = .focus };
        if (k.named(key, .escape)) return .{ .local = .back };
        // ⏎, ⇧⏎ and ⌥⏎ are the send modes (input_box.zig).
        if (k.namedAny(key, .enter) and !key.mods.ctrl and !key.mods.super and !key.mods.hyper and !key.mods.meta) return .{ .verb = "agent.send" };
        return null;
    }
    if (k.ctrl(key, 'c')) return .{ .local = .quit };
    if (tab) return .{ .local = .focus };
    if (k.named(key, .escape)) return .{ .local = .back };
    if (k.ctrl(key, @backingInt(NamedKey.enter))) return .{ .local = .split_menu };
    if (k.char(key, '?')) return .{ .local = .help };
    if (k.char(key, 'q')) return .{ .local = .quit };
    if (ctx == .inbox and k.char(key, '!')) return .{ .local = .next_attention };
    if ((ctx == .list or ctx == .transcript or ctx == .split) and k.char(key, 'i')) return .{ .local = .input };
    if ((ctx == .list or ctx == .transcript or ctx == .split) and k.char(key, '\\')) return .{ .local = .split_menu };
    if ((ctx == .list or ctx == .transcript or ctx == .split) and k.char(key, 'T')) return .{ .local = .take_back };
    if (ctx == .list or ctx == .transcript or ctx == .split) {
        if (k.char(key, ']')) return .{ .local = .to_child };
        if (k.char(key, '[')) return .{ .local = .to_parent };
        if (k.char(key, 'P')) return .{ .local = .promote };
        if (k.char(key, 'd')) return .{ .local = .diff };
        if (k.char(key, '!')) return .{ .local = .next_attention };
    }
    if (ctx == .transcript or ctx == .split) {
        if (k.char(key, 'w')) return .{ .local = .wait_all };
        if (k.char(key, 'K')) return .{ .local = .stop_all };
        if (k.char(key, 'v')) return .{ .local = .density };
        if (k.char(key, 'E')) return .{ .local = .expand_all };
        if (k.char(key, 'C')) return .{ .local = .collapse_all };
        if (k.char(key, 'p')) return .{ .local = .pager };
        if (k.char(key, 'J')) return .{ .local = .raw_json };
    }
    if (ctx != .list) return null;
    if (k.named(key, .enter)) return .{ .verb = "agent.show" };
    if (k.char(key, 'g')) return .{ .local = .group_by };
    if (k.char(key, 't')) return .{ .local = .children };
    if (k.char(key, '/')) return .{ .local = .filter };
    if (k.char(key, 'S')) return .{ .verb = "agent.stop" };
    if (k.char(key, 'x')) return .{ .verb = "agent.archive" };
    if (k.char(key, 'n')) return .{ .local = .new_agent };
    return null;
}

/// A key of a bracketed paste that is a line break or a tab: a space in a
/// text box. A CR parses as Enter and a bare LF as ⌃j.
pub fn pastedBreak(key: Key) bool {
    return k.namedAny(key, .enter) or k.namedAny(key, .tab) or k.ctrl(key, 'j') or (k.pressed(key) and key.codepoint == '\n');
}

/// The workspaces panel's keys, or null for the cursor's.
pub fn matchWorkspaces(key: Key) ?Action {
    if (!k.pressed(key)) return null;
    if (k.ctrl(key, 'c') or k.char(key, 'q')) return .{ .local = .quit };
    if (k.named(key, .escape)) return .{ .local = .back };
    if (k.char(key, '?')) return .{ .local = .help };
    if (k.char(key, 'n')) return .{ .local = .new_agent };
    if (k.char(key, 'N')) return .{ .local = .new_agent_pick };
    if (k.char(key, 'R')) return .{ .verb = "workspace.scan" };
    if (k.char(key, '+') or k.char(key, 'a')) return .{ .verb = "workspace.add" };
    return null;
}

/// The per-kind attention key for an item of `kind`,
/// or null when `key` is no action for it. `screen` is true on the inbox
/// screen, where `o`, `m`, `Y`, `N` and `⏎` apply to every kind.
pub fn matchAttention(key: Key, kind: @import("inbox.zig").Kind, screen: bool) ?Attention {
    if (!k.pressed(key) or key.mods.ctrl or key.mods.alt) return null;
    const request = kind == .approval or kind == .question or kind == .plan;
    if (k.char(key, 's')) return .snooze;
    if (k.char(key, '\\')) return .split;
    if (screen) {
        if (k.char(key, 'm')) return .mark;
        if (k.char(key, 'Y')) return .batch_allow;
        if (k.char(key, 'N')) return .batch_deny;
        if (k.char(key, 'o')) return .open;
    }
    switch (kind) {
        .approval => {
            if (k.char(key, 'y')) return .yes;
            if (k.char(key, 'a')) return .always;
            if (k.char(key, 'e')) return .edit;
            if (k.char(key, 'n')) return .no;
            if (k.char(key, 'r')) return .reason;
        },
        .question => {
            if (k.named(key, .enter)) return .type_answer;
            var d: u21 = '1';
            while (d <= '9') : (d += 1) if (k.char(key, d)) return .pick;
        },
        .plan => {
            if (k.char(key, 'y')) return .yes;
            if (k.char(key, 'n')) return .no;
        },
        .failed, .limit => {
            if (k.char(key, 'R')) return .retry;
            if (k.char(key, 'o')) return .open;
        },
        .review => {
            if (k.char(key, 'o')) return .open;
            if (k.char(key, 'x')) return .archive;
        },
    }
    if (screen and !request and k.named(key, .enter)) return .open;
    return null;
}

/// The attention key for an inbox item: `matchAttention`, except that an
/// item waiting in the harness's own TUI is answered there. `\\` focuses its
/// split (`App.openMenu`); only snoozing and opening are left besides.
pub fn matchItem(key: Key, it: *const @import("inbox.zig").Item, screen: bool) ?Attention {
    if (!it.away) return matchAttention(key, it.kind, screen);
    if (!k.pressed(key) or key.mods.ctrl or key.mods.alt) return null;
    if (k.char(key, 's')) return .snooze;
    if (k.char(key, '\\')) return .split;
    if (screen and k.char(key, 'o')) return .open;
    return null;
}

/// The hints of an item waiting in the harness's own TUI.
pub const away_hints = "\\ focus split  s snooze";

/// The key hints for an inbox item.
pub fn itemHints(it: *const @import("inbox.zig").Item) []const u8 {
    return if (it.away) away_hints else hints(it.kind);
}

/// `itemHints` in a popup that only reads: nothing that opens an agent.
pub fn popupHints(it: *const @import("inbox.zig").Item) []const u8 {
    if (it.away) return "s snooze";
    return switch (it.kind) {
        .failed, .limit => "s snooze",
        .review => "x archive  s snooze",
        else => hints(it.kind),
    };
}

/// The key hints for an item of `kind` (status bar, inline block).
pub fn hints(kind: @import("inbox.zig").Kind) []const u8 {
    return switch (kind) {
        .approval => "y allow once  a always  e edit  n deny  r deny with reason  s snooze",
        .question => "1–9 pick  ⏎ type an answer  s snooze",
        .plan => "y approve  n reject with feedback  s snooze",
        .failed, .limit => "R retry  o open  s snooze",
        .review => "o open  x archive  s snooze",
    };
}

test "every bound verb is in venom's schema, and match agrees with the table" {
    const App = @import("../main.zig").App;
    const press = k.testKey;
    for (table) |b| switch (b.action) {
        .verb => |v| try std.testing.expect(App.schema.find(v) != null),
        .attention => |at| if (at.verb()) |v| try std.testing.expect(App.schema.find(v) != null),
        .local => {},
    };
    for (std.enums.values(Attention)) |at| if (at.verb()) |v| try std.testing.expect(App.schema.find(v) != null);
    try std.testing.expectEqual(Attention.yes, matchAttention(press('y', .{}), .plan, false).?);
    try std.testing.expect(matchAttention(press('a', .{}), .plan, false) == null);
    try std.testing.expectEqual(Attention.pick, matchAttention(press('7', .{}), .question, false).?);
    try std.testing.expect(matchAttention(press('m', .{}), .approval, false) == null);
    try std.testing.expect(matchAttention(press(' ', .{}), .approval, true) == null);
    try std.testing.expectEqual(Attention.mark, matchAttention(press('m', .{}), .approval, true).?);
    try std.testing.expectEqualStrings("agent.stop", match(press('S', .{}), .list).?.verb);
    try std.testing.expectEqualStrings("agent.send", match(k.testNamed(.enter), .input).?.verb);
    try std.testing.expectEqualStrings("agent.send", match(press(@backingInt(NamedKey.enter), .{ .shift = true }), .input).?.verb);
    try std.testing.expectEqualStrings("agent.send", match(press(@backingInt(NamedKey.enter), .{ .alt = true }), .input).?.verb);
    try std.testing.expect(match(press('x', .{}), .input) == null);
    // ⌃c quits in Normal and clears the draft in Input.
    try std.testing.expectEqual(Local.clear_draft, match(press('c', .{ .ctrl = true }), .input).?.local);
    for ([_]Context{ .list, .transcript, .split, .inbox }) |ctx| try std.testing.expectEqual(Local.quit, match(press('c', .{ .ctrl = true }), ctx).?.local);
    // `i` enters Input wherever bare keys act on an agent; `r` no longer does.
    for ([_]Context{ .list, .transcript, .split }) |ctx| try std.testing.expectEqual(Local.input, match(press('i', .{}), ctx).?.local);
    try std.testing.expect(match(press('r', .{}), .list) == null);
    // The bare keys, and text in the box.
    for ([_]Context{ .list, .transcript, .split }) |ctx| {
        try std.testing.expectEqual(Local.diff, match(press('d', .{}), ctx).?.local);
        try std.testing.expectEqual(Local.next_attention, match(press('!', .{}), ctx).?.local);
    }
    try std.testing.expect(match(press('d', .{}), .input) == null);
    try std.testing.expect(match(press('!', .{}), .input) == null);
    // The keys that moved under the leader are gone from the bare keys.
    for ([_]Key{ press('I', .{ .shift = true }), press(',', .{}), press('u', .{}), press('N', .{ .shift = true }), press('u', .{ .ctrl = true }), press('w', .{ .ctrl = true }) }) |gone| {
        try std.testing.expect(match(gone, .list) == null);
    }
    try std.testing.expect(match(press('w', .{}), .list) == null);
    try std.testing.expect(match(press('I', .{ .shift = true }), .inbox) == null);
    // Input takes only text and its own keys: ⌃u and ⌃w edit, ⌃⏎ is nothing.
    try std.testing.expect(match(press('u', .{ .ctrl = true }), .input) == null);
    try std.testing.expect(match(press('w', .{ .ctrl = true }), .input) == null);
    try std.testing.expect(match(press('a', .{ .ctrl = true }), .input) == null);
    try std.testing.expect(match(press('i', .{}), .input) == null);
    try std.testing.expect(match(press('j', .{}), .list) == null); // the list widget's
    // Splits: `\` and ⌃⏎ open the menu, ⌃w closes; in the input
    // box `\` is text and ⌃w deletes a word.
    try std.testing.expectEqual(Local.split_menu, match(press('\\', .{}), .list).?.local);
    try std.testing.expectEqual(Local.split_menu, match(press('\\', .{}), .transcript).?.local);
    try std.testing.expectEqual(Local.split_menu, match(press(@backingInt(NamedKey.enter), .{ .ctrl = true }), .list).?.local);
    try std.testing.expect(match(press(@backingInt(NamedKey.enter), .{ .ctrl = true }), .input) == null);
    try std.testing.expect(match(press('w', .{ .ctrl = true }), .input) == null);
    try std.testing.expect(match(press('\\', .{}), .input) == null);
    // The transcript's own keys; text in the input box.
    try std.testing.expectEqual(Local.density, match(press('v', .{}), .transcript).?.local);
    try std.testing.expectEqual(Local.pager, match(press('p', .{}), .split).?.local);
    try std.testing.expectEqual(Local.raw_json, match(press('J', .{ .shift = true }), .transcript).?.local);
    try std.testing.expect(match(press('v', .{}), .input) == null);
    try std.testing.expect(match(press('v', .{}), .list) == null);
    // New agents and workspaces: list keys, and text in the box.
    try std.testing.expectEqual(Local.new_agent, match(press('n', .{}), .list).?.local);
    try std.testing.expect(match(press('n', .{}), .input) == null);
    try std.testing.expect(match(press('n', .{}), .transcript) == null);
    try std.testing.expectEqualStrings("workspace.scan", matchWorkspaces(press('R', .{})).?.verb);
    try std.testing.expect(matchWorkspaces(press('w', .{})) == null);
    try std.testing.expectEqual(Local.back, matchWorkspaces(k.testNamed(.escape)).?.local);
}

test "the tree: every row resolves, with no conflict, and names what it runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |host| {
        const r = try K.resolve(a, treeTables(host), null);
        try std.testing.expectEqual(@as(usize, 0), r.conflicts.len);
        try std.testing.expectEqual(@as(usize, 0), r.shadowed.len);
        for (&table) |*b| {
            if (!b.inTree() or (host and b.context == .leader_own)) continue;
            const m = r.lookup((chord.parseSequence(b.keys).?).slice());
            try std.testing.expectEqualStrings(b.label, m.exact.binding.label.?);
            // The command prompt finds the same action by name.
            try std.testing.expect(commandNamed(actionName(b.action)) != null);
        }
        // A key is never a binding and a prefix,
        // and the group's default is its double tap.
        try std.testing.expect(r.lookup((chord.parseSequence("a").?).slice()) == .partial);
        try std.testing.expect(r.lookup((chord.parseSequence("a a").?).slice()) == .exact);
    }
    const own = try K.resolve(a, treeTables(false), null);
    const host = try K.resolve(a, treeTables(true), null);
    try std.testing.expect(own.lookup((chord.parseSequence("v left").?).slice()) == .exact);
    try std.testing.expect(host.lookup((chord.parseSequence("v h").?).slice()) == .none);
    try std.testing.expect(host.lookup((chord.parseSequence("v left").?).slice()) == .none);
    // Rows share by target: `h ←` in the popup, one row for both.
    const rows = try term.chrome.leader_popup.rows(a, try own.next(a, (chord.parseSequence("v").?).slice()));
    var found = false;
    for (rows) |row| {
        if (std.mem.eql(u8, row.label, "split to the left")) {
            found = true;
            try std.testing.expectEqualStrings("h ←", row.keys);
        }
    }
    try std.testing.expect(found);
}

test "shownKeys prints the configured leader, and the second sequence as a glyph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plain: ?*const Binding = null;
    var both: ?*const Binding = null;
    for (&table) |*b| {
        if (b.context == .leader and std.mem.eql(u8, b.keys, "a s")) plain = b;
        if (b.alt != null and std.mem.eql(u8, b.keys, "v h")) both = b;
    }
    try std.testing.expectEqualStrings("ctrl+x a s", try shownKeys(a, plain.?, "ctrl+x"));
    try std.testing.expectEqualStrings("space v h ←", try shownKeys(a, both.?, "space"));
    try std.testing.expectEqualStrings("⌃c", try shownKeys(a, &.{ .keys = "⌃c", .label = "x", .action = .{ .local = .quit }, .context = .input }, "space"));
}
