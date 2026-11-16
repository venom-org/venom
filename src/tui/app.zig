//! The TUI's state and controller: the model, the widgets'
//! state, key routing and the verb requests the keys turn into. It never
//! touches a socket or a terminal: `Link` (link.zig) carries its requests
//! to the daemon and feeds back responses and events, and `view.zig` draws
//! it into a Surface. Tests drive it with key bytes and JSON.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const model_mod = @import("model.zig");
const keys = @import("keys.zig");
const inbox_mod = @import("inbox.zig");
const split = @import("split.zig");
const host_mod = @import("host.zig");
const input_box = @import("input_box.zig");
const transcript = @import("transcript.zig");
const workspaces = @import("workspaces.zig");
const new_agent = @import("new_agent.zig");
const settings_mod = @import("settings.zig");
const usage_view = @import("usage_view.zig");
const context_panel = @import("context_panel.zig");
const diff = @import("diff.zig");
const agent_list = @import("agent_list.zig");
const fan_out = @import("fan_out.zig");
const config_mod = @import("../config.zig");
const chord = term.chrome.keys;
const leader_popup = term.chrome.leader_popup;
const Kind = inbox_mod.Kind;
const Model = model_mod.Model;
const State = model_mod.State;
const Value = std.json.Value;

/// `split` is any open split; which one is `App.focusedSplit`.
pub const Area = enum(u2) { list = 0, transcript = 1, input = 2, split = 3 };

/// The focus ring's fixed areas; the splits follow them.
const fixed_areas = 3;

/// The main view, the inbox screen or the
/// workspaces panel, or the settings screen.
/// What a popup says when asked to open an agent (`setSingleView`).
pub const single_view_open = "open it from the control pane: this popup only reads";

pub const Screen = enum { main, inbox, workspaces, settings, usage };

/// venom-term's widget roles, with focus kept out of the signal: a focused
/// box or pane edge is `rule_strong`, not a border in blood. The signal
/// stays for the status bar's block, the active view's `▸`, the selected
/// row's `▌` and the prompt of an input being typed in.
pub fn widgetTheme(chrome: term.theme.Chrome) w.Theme {
    var t = chrome.widgets();
    t.border_focus = chrome.text(chrome.theme.rule_strong);
    return t;
}

/// `widgetTheme` with every role on `crypt`, the ground of floating surfaces
/// (popups, dialogs) and the input box. Selected rows keep their own fill.
pub fn cryptTheme(chrome: term.theme.Chrome) w.Theme {
    var t = widgetTheme(chrome);
    const ground = chrome.color(chrome.theme.crypt);
    inline for (@typeInfo(w.Theme).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "selection")) {
            const style = &@field(t, name);
            if (style.bg == .default) style.bg = ground;
        }
    }
    return t;
}

/// Where keys go. A view only decides what the bare
/// keys do. Only a key changes the mode, never a background event.
pub const KeyMode = enum {
    /// Bare keys act on what is under the cursor.
    normal,
    /// Text and the send keys: the input box, the filter, text fields, the
    /// new-agent dialog.
    input,
    /// Everything goes to the program in a shell or take-over split.
    terminal,

    pub fn label(self: KeyMode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .input => "INPUT",
            .terminal => "TERMINAL",
        };
    }

    /// The DECSCUSR that gives the mode its cursor: a steady bar in Input,
    /// the terminal's default otherwise.
    pub fn cursorSequence(self: KeyMode) []const u8 {
        return if (self == .input) "\x1b[6 q" else "\x1b[0 q";
    }
};

/// Why a request was sent, so its response lands in the right place.
pub const Purpose = union(enum) {
    list,
    show,
    inbox,
    /// `agent.tool` for a pager's part.
    tool: struct { pager: u64, part: usize },
    /// `agent.tool` for the whole body of an open row; the agent and the
    /// call, owned.
    full_body: struct { agent: []u8, call: []u8 },
    /// `config.get` of a transcript setting, read when the TUI starts.
    config: enum { density, open_running_after, bell, group_by, children, leave_terminal, leader, popup_delay_ms, timeout_ms },
    /// An agent-view split's `agent.show`; the agent, owned.
    split_show: []u8,
    /// `agent.takeover`: its answer opens the take-over split.
    /// `focus`: a key asked for it now, so the split may take the focus.
    takeover: struct { agent: []u8, side: split.Side, focus: bool },
    /// `agent.takeback` this client owes (`owed`); the agent, owned.
    takeback: []u8,
    /// `d`'s `agent.show`, for the agent's folders; the agent, owned.
    diff: []u8,
    /// A key's verb; failures are shown in the status bar.
    action: []const u8,
    /// `agent.send` from the input box; both owned. If it fails, or the
    /// connection goes first, the text returns to that agent's draft.
    send: struct { agent: []u8, text: []u8 },
    /// An attention action. `keys` (owned, one `agent/item` per
    /// line) are the items hidden until the daemon's inbox drops them;
    /// on failure they come back.
    answer: struct { label: []u8, keys: []u8 },
    /// `workspace.list`.
    workspaces,
    /// `harness.list`, for the new-agent dialog.
    harnesses,
    /// `workspace.add` from the panel.
    workspace_add,
    /// `workspace.scan` from the panel.
    workspace_scan,
    /// The new-agent dialog's `agent.spawn` dry run.
    preview,
    /// The new-agent dialog's `agent.spawn`, by the start key that sent it.
    spawn: new_agent.Start,
    /// The settings screen's requests.
    settings: settings_mod.Request,
    /// A fan-out card's `agent.show`; the child, owned.
    card_show: []u8,
    /// `w`'s `agent.wait`; the parent, owned.
    fan_wait: []u8,
    /// `K`'s `agent.stop --tree`.
    stop_tree,
    /// The usage screen's requests.
    usage: usage_view.Request,
    /// The context panel's requests.
    context: context_panel.Request,
};

/// A text prompt an attention key opened: Enter sends it, Esc drops it.
pub const Prompt = struct {
    pub const Mode = enum {
        /// approval `r`: deny with this reason.
        deny_reason,
        /// approval `e`: allow this command instead.
        edit_command,
        /// plan `n`: reject with this feedback.
        reject_feedback,
        /// question `⏎`: this answer.
        question,

        pub fn title(self: Mode) []const u8 {
            return switch (self) {
                .deny_reason => "Deny with a reason",
                .edit_command => "Allow an edited command",
                .reject_feedback => "Reject the plan with feedback",
                .question => "Your answer",
            };
        }

        pub fn placeholder(self: Mode) []const u8 {
            return switch (self) {
                .deny_reason => "Why not? It reaches the model; enter denies",
                .edit_command => "The command to run instead; enter allows it",
                .reject_feedback => "What should change? enter rejects",
                .question => "Type an answer; enter sends it",
            };
        }
    };
    mode: Mode,
    /// `agent/item` of the item it answers.
    key: []u8,
    /// Move to the next item after it is sent (the inbox screen).
    advance: bool,
};

/// A take-over to start once the agent settles.
pub const Waiting = struct { agent: []u8, side: split.Side };

/// An item answered here, hidden until an `inbox.list` requested after
/// the answer succeeded (`after`: the first such request id) drops it.
const Hidden = struct { key: []u8, after: ?i64 = null };

fn noResume(_: []const u8) bool {
    return false;
}

/// The agent an `agent.*` event is about (not snapshots, not checkpoints).
fn eventAgent(item: Value) ?[]const u8 {
    if (item != .object) return null;
    const typ = item.object.get("type") orelse return null;
    if (typ != .string or !std.mem.startsWith(u8, typ.string, "agent.")) return null;
    const data = item.object.get("data") orelse return null;
    if (data != .object) return null;
    const id = data.object.get("agent") orelse return null;
    return if (id == .string) id.string else null;
}

fn isCreated(item: Value) bool {
    if (item != .object) return false;
    const typ = item.object.get("type") orelse return false;
    return typ == .string and std.mem.eql(u8, typ.string, "agent.created");
}

pub fn kindRole(k: Kind) w.Role {
    return switch (k) {
        .approval, .question, .plan => .warn,
        .failed, .limit => .err,
        .review => .ok,
    };
}

pub fn stateRole(s: State) w.Role {
    return switch (s) {
        .running => .info,
        .needs_you => .warn,
        .failed => .err,
        .settled => .ok,
        .queued, .handed_over, .archived => .muted,
    };
}

pub const App = struct {
    gpa: std.mem.Allocator,
    model: Model,
    list: agent_list.View = .{},
    /// `g` and `t`; start from `ui.group_by` and `ui.children`. Per TUI, for
    /// this run, as `density` is.
    group_by: config_mod.GroupBy = .state,
    children: config_mod.Children = .tree,
    /// `/`: the list's filter, and whether it has the keys.
    filter_input: w.TextInput,
    filtering: bool = false,
    /// Groups folded or unfolded against their default, by title (owned).
    fold_flips: std.ArrayList([]u8) = .empty,
    scroll: w.ScrollView = .{},
    /// The transcript's rows and the user's choices.
    rows: transcript.View = .{},
    /// `v`; starts from `ui.transcript.density`. Per TUI, for this run.
    density: transcript.Density = .normal,
    /// `ui.transcript.open_running_after`.
    open_running_after_ms: u64 = 5000,
    /// `p` / `J`: over the main view until closed.
    pager: ?transcript.Pager = null,
    next_pager: u64 = 1,
    /// When a running call's live tail was last asked for.
    tail_at: i64 = 0,
    input: w.TextInput,
    focus: w.FocusRing = .{ .count = 3 },
    parser: term.Input = .{},
    /// The selected agent's id; empty when there is none.
    selected: std.ArrayList(u8) = .empty,
    /// The list cursor sits on a group header (no agent selected by it).
    on_header: bool = false,
    help: bool = false,
    /// `leader ?`: every key, not this view's.
    help_all: bool = false,
    /// The first row the help shows; `j` and `k` move it.
    help_top: u16 = 0,
    quit: bool = false,
    /// What the daemon's `tui.hold` item last said; null until one came.
    hold: ?Hold = null,
    /// The quit confirmation is open (an on-demand daemon whose last TUI
    /// this is, with work in progress).
    quit_prompt: bool = false,
    /// The human confirmed it: quit now.
    quit_confirmed: bool = false,
    connected: bool = false,
    /// A one-line message for the status bar (a failed verb, offline).
    message: std.ArrayList(u8) = .empty,
    /// Encoded request lines for the link to send.
    outbox: std.ArrayList([]u8) = .empty,
    pending: std.AutoHashMapUnmanaged(i64, Purpose) = .empty,
    next_id: i64 = 10,
    show_inflight: bool = false,
    show_again: bool = false,
    /// Wall clock for ages, ms since the epoch; set by the caller per frame.
    now_ms: i64 = 0,
    /// `$HOME`, shown as `~` in paths.
    home: []const u8 = "",
    /// Fixes the local time zone's offset from UTC, in seconds (tests); null:
    /// ask the system per instant, so DST is right.
    utc_offset_override: ?i32 = null,
    chrome: term.theme.Chrome = .{},
    theme: w.Theme = widgetTheme(.{}),
    /// `theme` on `crypt`: popups, dialogs and the input box.
    crypt: w.Theme = cryptTheme(.{}),
    /// Per-frame allocations (groups, spans).
    frame: std.heap.ArenaAllocator,
    /// Where the input box was last drawn (for clicks).
    input_area: term.Region = .{ .width = 0, .height = 0 },
    /// Inside a bracketed paste: its keys are text, never commands.
    pasting: bool = false,
    /// Inside a bracketed paste that goes to the focused shell split, as
    /// bytes: `feed` looks only for its end.
    shell_paste: bool = false,
    /// Unsent box text of agents other than the selected one, and with no
    /// agent-view split open, by agent id (both owned). A box's text belongs
    /// to its agent, so a prompt can't be sent to an agent it wasn't written
    /// for. An agent has one draft: it lives here, or in `boxOf(agent)`.
    drafts: std.StringHashMapUnmanaged([]u8) = .empty,

    // ---- Inbox -----------------------------------------------------------
    screen: Screen = .main,
    /// The split Terminal mode last left: focusing one is Terminal again, so
    /// this is what `leader v x` closes from Normal.
    left_split: ?usize = null,
    /// Where esc returns to from the main input box.
    input_from: Area = .list,
    /// `ui.keys.leave_terminal`, parsed, and as the bar shows it.
    leave_terminal: chord.Chord = .{ .cp = ']', .mods = .{ .ctrl = true } },
    leave_terminal_text: [32]u8 = "⌃]".* ++ @as([32 - "⌃]".len]u8, @splat(0)),
    leave_terminal_len: u8 = "⌃]".len,
    /// `ui.keys.leader` and the rest, set from config.
    /// `chord.Settings{}` keeps a multiplexer's defaults on purpose, so each
    /// value is venom's here.
    /// See `setSingleView`.
    single_view: bool = false,
    key_settings: chord.Settings = .{ .leader = chord.parseChord("space").?, .popup_delay_ms = 200, .timeout_ms = 0 },
    /// The leader as the help, the hints and the settings print it.
    leader_text: [32]u8 = "space".* ++ @as([32 - "space".len]u8, @splat(0)),
    leader_len: u8 = "space".len,
    leader: keys.K.Router,
    leader_timer: leader_popup.Timer = .{},
    inbox: inbox_mod.Inbox,
    inbox_list: w.GroupedList = .{},
    /// The inbox item's detail (context, the request, its keys).
    inbox_scroll: w.ScrollView = .{},
    /// `agent/item` under the inbox cursor; empty: the first item.
    inbox_cursor: std.ArrayList(u8) = .empty,
    /// The cursor's position in the visible items, for when its item goes.
    inbox_index: usize = 0,
    /// Marked `agent/item` keys (`m`), for `Y` / `N`.
    marks: std.ArrayList([]u8) = .empty,
    /// The option picks made so far on a question with several questions.
    picks: inbox_mod.Picks = .{},
    /// The item and options last drawn (`inbox_mod.itemHash` / `optionsSig`):
    /// a digit picks from what was drawn, so it is refused when the item's
    /// options changed since.
    drawn: ?struct { item: u64, sig: u64 } = null,
    hidden: std.ArrayList(Hidden) = .empty,
    prompt: ?Prompt = null,
    /// The prompt's own text box, so a draft answer is kept.
    answer_input: w.TextInput,
    inbox_inflight: bool = false,
    inbox_again: bool = false,

    // ---- Splits ----------------------------------------------------------
    /// Open splits, in focus order; each draws on its `side`.
    splits: std.ArrayList(split.Split) = .empty,
    menu: ?split.Menu = null,
    /// The shell a "Shell in worktree" split runs (`$SHELL`, resolved).
    shell_path: []const u8 = "/bin/sh",
    /// The environment shells inherit; none in tests.
    env: ?*const std.process.Environ.Map = null,
    /// Whether a harness's adapter provides resume (take-over); the menu
    /// offers "Take over in <harness>" only then.
    resumes: *const fn (harness: []const u8) bool = noResume,
    /// The mid-turn take-over question.
    ask: ?split.Ask = null,
    /// A take-over waiting for its agent's turn to end ("after this turn",
    /// or after "interrupt now" stopped it).
    waiting: ?Waiting = null,
    /// Agents whose take-over split this client closed (its harness TUI
    /// reaped) and that the daemon has not taken back yet: sent again on
    /// every (re)connect until it answers.
    owed: std.ArrayList([]u8) = .empty,

    // ---- Chrome modes ----------------------------------------------------
    /// `ui.chrome = host`: this TUI is a control pane (host.zig).
    host: ?*host_mod.Host = null,
    /// An agent's venomx pane: only the view, no list and no bar.
    solo: bool = false,
    /// This TUI rings for new blocking items. Set
    /// by the terminal loop unless `--solo`: an agent's pane or a popup would
    /// only ring again for what the main view rings for.
    rings: bool = false,
    bell_watch: inbox_mod.BellWatch = .{},
    /// A BEL is owed; the terminal loop writes it between frames.
    bell_due: bool = false,

    // ---- Workspaces and new agents ---------------------------------------
    panel: workspaces.Panel,
    dialog: ?new_agent.Dialog = null,
    /// A started agent whose view opens once the model knows it.
    follow: ?new_agent.Follow = null,
    /// Harnesses to offer that `harness.list` does not name (tests' fake).
    extra_harnesses: []const []const u8 = &.{},
    // ---- Settings --------------------------------------------------------
    settings: settings_mod.Settings,
    // ---- Agents that spawn agents ----------------------------------------
    fan: fan_out.State = .{},
    // ---- Usage and context -----------------------------------------------
    usage: usage_view.Usage,
    context_panel: context_panel.Panel,
    /// To write `usage.export`'s CSV; set by the terminal loop.
    io: ?std.Io = null,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .model = .init(gpa),
            .input = .init(gpa, .{ .prompt = "› " }),
            .filter_input = .init(gpa, .{ .prompt = "/ " }),
            .answer_input = .init(gpa, .{ .prompt = "› " }),
            .inbox = .init(gpa),
            .panel = .init(gpa),
            .usage = .init(gpa),
            .context_panel = .init(gpa),
            .settings = .init(gpa),
            .frame = .init(gpa),
            .leader = .init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.leader.deinit();
        self.bell_watch.deinit(self.gpa);
        self.model.deinit();
        self.scroll.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        if (self.pager) |*pg| pg.deinit(self.gpa);
        self.input.deinit();
        self.filter_input.deinit();
        for (self.fold_flips.items) |f| self.gpa.free(f);
        self.fold_flips.deinit(self.gpa);
        var drafts = self.drafts.iterator();
        while (drafts.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.drafts.deinit(self.gpa);
        self.selected.deinit(self.gpa);
        self.message.deinit(self.gpa);
        for (self.outbox.items) |line| self.gpa.free(line);
        self.outbox.deinit(self.gpa);
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.inbox.deinit();
        self.inbox_scroll.deinit(self.gpa);
        self.inbox_cursor.deinit(self.gpa);
        for (self.marks.items) |m| self.gpa.free(m);
        self.marks.deinit(self.gpa);
        for (self.hidden.items) |h| self.gpa.free(h.key);
        self.hidden.deinit(self.gpa);
        self.dropPrompt();
        self.answer_input.deinit();
        for (self.splits.items) |*sp| sp.deinit(self.gpa);
        self.splits.deinit(self.gpa);
        self.dropMenu();
        self.dropAsk();
        self.dropWaiting();
        for (self.owed.items) |o| self.gpa.free(o);
        self.owed.deinit(self.gpa);
        new_agent.close(self);
        self.panel.deinit(self.gpa);
        if (self.follow) |f| self.gpa.free(f.agent);
        self.settings.deinit();
        self.fan.deinit(self.gpa);
        self.usage.deinit();
        self.context_panel.deinit();
        self.frame.deinit();
        self.* = undefined;
    }

    fn clearPending(self: *App) void {
        var it = self.pending.valueIterator();
        while (it.next()) |p| switch (p.*) {
            .action, .split_show, .takeback, .card_show, .fan_wait, .diff => |v| self.gpa.free(v),
            .send => |v| {
                self.gpa.free(v.agent);
                self.gpa.free(v.text);
            },
            .takeover => |v| self.gpa.free(v.agent),
            .full_body => |v| {
                self.gpa.free(v.agent);
                self.gpa.free(v.call);
            },
            .answer => |v| {
                self.gpa.free(v.label);
                self.gpa.free(v.keys);
            },
            .list, .show, .inbox, .tool, .config, .workspaces, .harnesses, .workspace_add, .workspace_scan, .preview, .spawn, .settings, .stop_tree, .usage, .context => {},
        };
        self.pending.clearRetainingCapacity();
    }

    /// True once per BEL owed.
    pub fn takeBell(self: *App) bool {
        defer self.bell_due = false;
        return self.bell_due;
    }

    /// `--solo`: the list is not drawn, so it never has focus.
    /// The `ctrl+a v i` and `v u` popups (`host.keyTable`): this screen and no
    /// other. `esc` leaves the TUI, which closes the popup, and no
    /// key opens an agent, because their connection only reads.
    pub fn setSingleView(self: *App) void {
        self.single_view = true;
    }

    pub fn setSolo(self: *App) void {
        self.solo = true;
        self.focus.set(@backingInt(Area.transcript));
    }

    pub fn setTheme(self: *App, chrome: term.theme.Chrome) void {
        self.chrome = chrome;
        self.theme = widgetTheme(chrome);
        self.crypt = cryptTheme(chrome);
    }

    /// The colours a shell split is drawn on. Without truecolor they are the
    /// terminal's own, which the shell's queries already report.
    pub fn shellColors(self: *const App) term.Vt.QueryColors {
        if (self.chrome.mode != .truecolor) return .{};
        return .{ .fg = self.chrome.theme.bone.rgb, .bg = self.chrome.theme.void.rgb };
    }

    /// Pre-selects an agent (`venom agent view --agent=<id>`).
    pub fn preselect(self: *App, id: []const u8) !void {
        self.selected.clearRetainingCapacity();
        try self.selected.appendSlice(self.gpa, id);
        try self.model.select(id);
    }

    /// The mode the next key is in; this follows `routeKey`'s order.
    pub fn keyMode(self: *const App) KeyMode {
        if (self.help or self.pager != null) return .normal;
        if (self.prompt != null) return .input;
        if (self.menu != null or self.ask != null) return .normal;
        // While a spawn starts nothing is typed, and ⌃c quits.
        if (self.dialog) |*d| return if (d.starting != null) .normal else .input;
        if (self.filtering) return .input;
        if (self.context_panel.agent != null) return .normal;
        switch (self.screen) {
            .main => {},
            .inbox, .usage => return .normal,
            .workspaces => return if (self.panel.adding) .input else .normal,
            .settings => return if (self.settings.editing != null) .input else .normal,
        }
        if (self.focusedSplit()) |i| if (self.splits.items[i].shell != null or self.splits.items[i].exited) return .terminal;
        return if (self.inFocusedBox()) .input else .normal;
    }

    pub fn area(self: *const App) Area {
        if (self.focus.index >= fixed_areas) return .split;
        return @fromBackingInt(@intCast(self.focus.index));
    }

    /// The index in `splits` of the focused split, if one has focus.
    pub fn focusedSplit(self: *const App) ?usize {
        if (self.focus.index < fixed_areas) return null;
        const i = self.focus.index - fixed_areas;
        return if (i < self.splits.items.len) i else null;
    }

    pub const Hold = struct { on_demand: bool, others: i64, lingering: bool };

    /// A `tui.hold` item: the daemon's lifetime and who else holds it.
    pub fn onHold(self: *App, item: std.json.Value) void {
        if (item != .object) return;
        const o = item.object;
        const lifetime = o.get("lifetime") orelse return;
        const others = o.get("others") orelse return;
        const phase = o.get("phase") orelse return;
        if (lifetime != .string or others != .integer or phase != .string) return;
        self.hold = .{ .on_demand = std.mem.eql(u8, lifetime.string, "on-demand"), .others = others.integer, .lingering = std.mem.eql(u8, phase.string, "lingering") };
    }

    /// Whether quitting now needs a confirmation: no other hold would
    /// survive it on an on-demand daemon, and agents are queued, running or
    /// waiting on the human, or own mode has a take-over split open.
    pub fn quitNeedsConfirm(self: *const App) bool {
        const h = self.hold orelse return false;
        if (!h.on_demand or h.others > 0) return false;
        const c = self.quitCounts();
        return c.running + c.queued > 0 or c.takeovers > 0;
    }

    const QuitCounts = struct { running: usize, queued: usize, takeovers: usize };
    fn quitCounts(self: *const App) QuitCounts {
        var out: QuitCounts = .{ .running = 0, .queued = 0, .takeovers = 0 };
        for (self.model.agents.items) |ag| switch (ag.state) {
            .running, .needs_you => out.running += 1,
            .queued => out.queued += 1,
            else => {},
        };
        if (self.host == null) for (self.splits.items) |sp| {
            out.takeovers += @intFromBool(sp.kind == .take_over and !sp.exited);
        };
        return out;
    }

    /// The quit confirmation's text, naming running and queued agents apart.
    pub fn quitPromptText(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const n = self.quitCounts();
        var out: std.Io.Writer.Allocating = .init(a);
        const wr = &out.writer;
        try wr.writeAll("Quit venom? ");
        if (n.running > 0 and n.queued > 0) {
            try wr.print("{d} {s} running, {d} {s} queued. Quitting stops the running {s}; {s} its work and continues when you send to it again. Queued agents wait and start when venom runs again.", .{ n.running, if (n.running == 1) "agent is" else "agents are", n.queued, if (n.queued == 1) "is" else "are", if (n.running == 1) "one" else "ones", if (n.running == 1) "it keeps" else "each keeps" });
        } else if (n.running > 0) {
            try wr.print("{d} {s} running. Quitting stops {s}; {s} its work and continues when you send to it again.", .{ n.running, if (n.running == 1) "agent is" else "agents are", if (n.running == 1) "it" else "them", if (n.running == 1) "it keeps" else "each keeps" });
        } else if (n.queued > 0) {
            try wr.print("{d} {s} queued. Queued agents wait and start when venom runs again.", .{ n.queued, if (n.queued == 1) "agent is" else "agents are" });
        }
        if (n.takeovers > 0) try wr.writeAll(" The take-over split ends with venom; its agent is taken back first.");
        if (self.host != null) try wr.writeAll(" Detaching venomx (its leader, then d) keeps the control pane, and so the agents, running.");
        return out.written();
    }

    /// The loop saw `quit`: ask first when this quit would stop an
    /// on-demand daemon's work. True when the TUI may quit now.
    pub fn confirmQuit(self: *App) bool {
        if (self.quit_confirmed or !self.quitNeedsConfirm()) return true;
        self.quit = false;
        self.quit_prompt = true;
        return false;
    }

    fn quitPromptKey(self: *App, key: term.Input.Key) void {
        const k = term.widgets.keys;
        if (!k.pressed(key)) return;
        if (k.named(key, .enter)) {
            self.quit_prompt = false;
            self.quit_confirmed = true;
            self.quit = true;
        } else if (k.named(key, .escape)) self.quit_prompt = false;
    }

    pub fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.message.clearRetainingCapacity();
        self.message.print(self.gpa, fmt, args) catch {};
    }

    // ---- Requests ------------------------------------------------------

    pub fn request(self: *App, purpose: Purpose, verb: []const u8, params: anytype) !void {
        const id = self.next_id;
        self.next_id += 1;
        const line = try std.json.Stringify.valueAlloc(self.gpa, .{ .id = id, .verb = verb, .params = params }, .{ .emit_null_optional_fields = false });
        errdefer self.gpa.free(line);
        try self.outbox.append(self.gpa, line);
        try self.pending.put(self.gpa, id, purpose);
    }

    pub fn requestShow(self: *App) !void {
        if (self.selected.items.len == 0 or !self.connected) return;
        if (self.show_inflight) {
            self.show_again = true;
            return;
        }
        self.show_inflight = true;
        try self.sendShow(.show, self.selected.items, self.model.detail.nextPage(false));
    }

    /// `agent.show` of one page of the transcript.
    fn sendShow(self: *App, purpose: Purpose, agent: []const u8, page: model_mod.ShowPage) !void {
        try self.request(purpose, "agent.show", .{ .agent = agent, .tools = true, .since = page.since, .before = page.before });
    }

    /// Once per draw of a transcript, after `transcript.keepPlace`: reads
    /// older records when less than a screen of them is left above. One
    /// `agent.show` at a time per transcript; the answer brings another draw.
    pub fn readOlder(self: *App, d: *const model_mod.Detail, scroll: *const w.ScrollView, height: u16, sp: ?*split.Split) !void {
        if (!self.connected or !d.hasOlder()) return;
        const inflight = if (sp) |s| s.show_inflight else self.show_inflight;
        if (inflight) return;
        const lines = scroll.lineCount();
        const top = scroll.top orelse (lines -| height);
        if (top >= height) return;
        if (sp) |s| {
            s.show_inflight = true;
            const agent = try self.gpa.dupe(u8, s.agent);
            errdefer self.gpa.free(agent);
            try self.sendShow(.{ .split_show = agent }, s.agent, d.nextPage(true));
        } else {
            self.show_inflight = true;
            try self.sendShow(.show, self.selected.items, d.nextPage(true));
        }
    }

    /// Refetches the inbox; one request at a time, coalesced.
    pub fn requestInbox(self: *App) !void {
        if (!self.connected) return;
        if (self.inbox_inflight) {
            self.inbox_again = true;
            return;
        }
        self.inbox_inflight = true;
        try self.request(.inbox, "inbox.list", struct {}{});
    }

    /// Reads the transcript's settings (`ui.transcript.*`); the TUI does
    /// this once, when it starts.
    pub fn requestTranscriptConfig(self: *App) !void {
        try self.request(.{ .config = .density }, "config.get", .{ .key = "ui.transcript.density" });
        try self.request(.{ .config = .open_running_after }, "config.get", .{ .key = "ui.transcript.open_running_after" });
    }

    /// Reads the list's settings (`ui.group_by`, `ui.children`); the TUI does
    /// this once, when it starts.
    pub fn requestListConfig(self: *App) !void {
        try self.request(.{ .config = .group_by }, "config.get", .{ .key = "ui.group_by" });
        try self.request(.{ .config = .children }, "config.get", .{ .key = "ui.children" });
    }

    /// Reads `ui.keys.*`; the TUI does this once, when it starts.
    pub fn requestKeysConfig(self: *App) !void {
        try self.request(.{ .config = .leave_terminal }, "config.get", .{ .key = "ui.keys.leave_terminal" });
        try self.request(.{ .config = .leader }, "config.get", .{ .key = "ui.keys.leader" });
        try self.request(.{ .config = .popup_delay_ms }, "config.get", .{ .key = "ui.keys.popup_delay_ms" });
        try self.request(.{ .config = .timeout_ms }, "config.get", .{ .key = "ui.keys.timeout_ms" });
    }

    /// Options for building a transcript now.
    pub fn rowOptions(self: *const App) transcript.Options {
        return .{ .density = self.density, .now_ms = self.now_ms, .open_running_after_ms = self.open_running_after_ms };
    }

    /// `rowOptions` for the transcript of `agent`, with its fan-out block.
    /// The block is in `frame`: it is only for building rows now.
    pub fn optionsFor(self: *App, agent: []const u8) !transcript.Options {
        var o = self.rowOptions();
        o.fan = try fan_out.block(self, agent);
        return o;
    }

    /// Builds `rows` again if anything it shows changed.
    pub fn refreshRows(self: *App, rows: *transcript.View, d: *const model_mod.Detail, agent: []const u8) !void {
        try rows.refresh(self.gpa, d, try self.optionsFor(agent));
    }

    /// Asks for the whole bodies `rows` wants (an open
    /// row shows its body in full; `agent.show` only carries the start).
    pub fn fetchBodies(self: *App, rows: *transcript.View, agent: []const u8) !void {
        if (!self.connected) return;
        while (rows.nextWanted()) |call| {
            const a = try self.gpa.dupe(u8, agent);
            errdefer self.gpa.free(a);
            const c = try self.gpa.dupe(u8, call);
            errdefer self.gpa.free(c);
            try self.request(.{ .full_body = .{ .agent = a, .call = c } }, "agent.tool", .{ .agent = agent, .call = call });
        }
    }

    /// Once per frame: an open running call's live tail is not in the
    /// event stream, so `agent.show` is asked again,
    /// at most once a second.
    pub fn tick(self: *App) !void {
        if (self.now_ms - self.tail_at < 1000) return;
        const after: i64 = @intCast(self.open_running_after_ms);
        const long = struct {
            fn check(d: *const model_mod.Detail, now: i64, min: i64) bool {
                for (d.records.items) |*r| if (r.kind == .tool and !r.tool.ended() and r.tool.at > 0 and now - r.tool.at >= min) return true;
                return false;
            }
        }.check;
        var asked = false;
        if (long(&self.model.detail, self.now_ms, after)) {
            try self.requestShow();
            asked = true;
        }
        for (self.splits.items) |*sp| if (long(&sp.detail, self.now_ms, after)) {
            try self.requestSplitShow(sp);
            asked = true;
        };
        if (asked) self.tail_at = self.now_ms;
    }

    /// Refetches the agents, for what their events don't carry.
    pub fn requestAgents(self: *App) !void {
        try self.request(.list, "agent.list", .{ .archived = true });
    }

    /// The link (re)connected and subscribed: fetch what events don't carry.
    pub fn onConnected(self: *App) !void {
        self.connected = true;
        self.message.clearRetainingCapacity();
        // What was asked for on the last connection will not be answered.
        self.rows.forgetAsked(self.gpa);
        for (self.splits.items) |*sp| sp.rows.forgetAsked(self.gpa);
        // Take-backs the last connection did not see answered.
        for (self.owed.items) |agent| try self.sendTakeback(agent);
        if (self.screen == .workspaces or self.dialog != null) try workspaces.requestList(self);
        // The dialog's harness chips come from `harness.list`.
        if (self.dialog != null) try workspaces.requestHarnesses(self);
        if (self.screen == .settings) try self.settings.refresh(self);
        self.usage.inflight = false;
        self.context_panel.inflight = false;
        if (self.screen == .usage) try usage_view.request(self);
        try context_panel.request(self);
    }

    /// The link lost the daemon. The model stays, so the screen keeps the
    /// last known state until the next snapshot replaces it.
    pub fn onDisconnected(self: *App) !void {
        self.connected = false;
        for (self.outbox.items) |line| self.gpa.free(line);
        self.outbox.clearRetainingCapacity();
        try self.returnPendingSends();
        self.clearPending();
        self.show_inflight = false;
        self.show_again = false;
        self.inbox_inflight = false;
        self.inbox_again = false;
        self.settings.onDisconnected();
        self.fan.onDisconnected(self.gpa);
        for (self.splits.items) |*sp| {
            sp.show_inflight = false;
            sp.show_again = false;
        }
        self.panel.inflight = false;
        self.panel.again = false;
        self.panel.harness_inflight = false;
        new_agent.onDisconnected(self);
        // The next snapshot's inbox.list is the truth again.
        for (self.hidden.items) |h| self.gpa.free(h.key);
        self.hidden.clearRetainingCapacity();
    }

    /// One `events` item.
    pub fn onEvent(self: *App, item: Value) !void {
        const change = try self.model.applyItem(item);
        if (eventAgent(item)) |id| self.fan.touch(id);
        if (change.resync) {
            self.fan.touchAll();
            try self.request(.list, "agent.list", .{ .archived = true });
            try self.requestInbox();
            try self.requestShow();
            for (self.splits.items) |*sp| try self.requestSplitShow(sp);
        } else {
            // An agent-view split follows its agent's events.
            if (eventAgent(item)) |id| for (self.splits.items) |*sp| {
                if (sp.kind == .agent_view and std.mem.eql(u8, sp.agent, id)) try self.requestSplitShow(sp);
            };
            // Attention and states feed the inbox.
            if (change.agents) try self.requestInbox();
            if (change.detail) try self.requestShow();
        }
        try self.followUsage(item);
        try self.checkWaiting();
        try self.syncTakeovers();
        try new_agent.followSpawn(self);
        // The next agent's id names its worktrees and branch.
        if (change.resync or isCreated(item)) try new_agent.requestPreview(self);
    }

    /// Keeps the usage screen and the context panel current, and takes the
    /// result of a fork asked here.
    fn followUsage(self: *App, item: Value) !void {
        if (item != .object) return;
        const kind = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        const data = item.object.get("data") orelse return;
        if (std.mem.eql(u8, kind, "agent.fork_ended")) return context_panel.onForkEnded(self, data);
        const usage_moved = std.mem.eql(u8, kind, "agent.usage") or std.mem.eql(u8, kind, "agent.turn_ended") or std.mem.eql(u8, kind, "agent.context");
        if (self.screen == .usage and usage_moved) try usage_view.request(self);
        const shown = self.context_panel.agent orelse return;
        const agent = eventAgent(item) orelse return;
        if (std.mem.eql(u8, agent, shown) and (usage_moved or std.mem.eql(u8, kind, "agent.tool_call"))) try context_panel.request(self);
    }

    /// `leader a c`: the context panel for `agent`.
    pub fn openContextPanel(self: *App, agent: []const u8) !void {
        try context_panel.open(self, agent);
    }

    /// The final response to request `id`.
    pub fn onResponse(self: *App, id: i64, body: @import("proto").Response.Body) !void {
        const entry = self.pending.fetchRemove(id) orelse return;
        switch (entry.value) {
            .full_body => |v| {
                defer {
                    self.gpa.free(v.agent);
                    self.gpa.free(v.call);
                }
                const text: []const u8 = blk: {
                    if (body != .ok or body.ok != .object) break :blk "";
                    const b = body.ok.object.get("body") orelse break :blk "";
                    if (b != .object) break :blk "";
                    const t = b.object.get("text") orelse break :blk "";
                    break :blk if (t == .string) t.string else "";
                };
                if (std.mem.eql(u8, self.selected.items, v.agent)) try self.rows.setFull(self.gpa, v.agent, v.call, text);
                for (self.splits.items) |*sp| if (std.mem.eql(u8, sp.agent, v.agent)) try sp.rows.setFull(self.gpa, v.agent, v.call, text);
            },
            .tool => |t| if (self.pager) |*pg| if (pg.id == t.pager) {
                if (body == .ok) try pg.fill(self.gpa, t.part, body.ok) else if (body == .@"error") self.say("agent tool: {s}", .{body.@"error".code});
            },
            .config => |which| if (body == .ok and body.ok == .object) {
                const v = body.ok.object.get("content") orelse return;
                if (v == .string) self.applyConfig(which, v.string);
            },
            .list => if (body == .ok) {
                try self.model.applyList(body.ok);
                try self.checkWaiting();
                try self.syncTakeovers();
                try new_agent.followSpawn(self);
            },
            .takeback => |agent| {
                defer self.gpa.free(agent);
                // Done, or nothing left to take back: no longer owed.
                const settled = body == .ok or (body == .@"error" and (std.mem.eql(u8, body.@"error".code, "conflict.invalid_transition") or std.mem.eql(u8, body.@"error".code, "not_found.agent")));
                if (settled) {
                    self.unowe(agent);
                } else if (body == .@"error") {
                    const e = body.@"error";
                    // A definite no, with its reason: retrying will not help.
                    if (std.mem.eql(u8, e.code, "conflict.takeover_pane_running") or std.mem.eql(u8, e.code, "unavailable.takeover_pane")) {
                        self.unowe(agent);
                        self.say("{s}: {s}", .{ agent, e.message });
                    } else self.say("agent takeback: {s}", .{e.code});
                }
            },
            .takeover => |t| {
                defer self.gpa.free(t.agent);
                if (body == .@"error") return self.say("take over: {s}", .{body.@"error".code});
                if (body == .ok) try self.openTakeover(t.agent, t.side, t.focus, body.ok);
            },
            .show => {
                self.show_inflight = false;
                if (body == .ok) {
                    const ok = body.ok;
                    const agent = if (ok == .object) if (ok.object.get("agent")) |v| (if (v == .string) v.string else "") else "" else "";
                    // A stale answer for an agent no longer selected.
                    if (std.mem.eql(u8, agent, self.selected.items)) try self.model.applyShow(ok);
                } else if (body == .@"error") {
                    self.model.detail.older_failed = true;
                    self.say("agent show: {s}", .{body.@"error".code});
                }
                if (self.show_again or (body == .ok and self.model.detail.behind())) {
                    self.show_again = false;
                    try self.requestShow();
                }
            },
            .split_show => |agent| {
                defer self.gpa.free(agent);
                for (self.splits.items) |*sp| {
                    if (sp.kind != .agent_view or !std.mem.eql(u8, sp.agent, agent)) continue;
                    sp.show_inflight = false;
                    if (body == .ok) try self.model.fillDetail(&sp.detail, body.ok) else if (body == .@"error") {
                        sp.detail.older_failed = true;
                        self.say("agent show: {s}", .{body.@"error".code});
                    }
                    if (sp.show_again or (body == .ok and sp.detail.behind())) {
                        sp.show_again = false;
                        try self.requestSplitShow(sp);
                    }
                }
            },
            .diff => |agent| {
                defer self.gpa.free(agent);
                if (body == .@"error") return self.say("agent diff: {s}", .{body.@"error".code});
                if (body == .ok) try self.openDiff(agent, body.ok);
            },
            .action => |verb| {
                defer self.gpa.free(verb);
                // A harness that ended at once: its pane's end takes the agent
                // back (`Host.applyList`), and that is all there is to say.
                if (body == .@"error" and !std.mem.eql(u8, body.@"error".code, "conflict.takeover_pane_gone")) self.say("{s}: {s}", .{ verb, body.@"error".code });
            },
            .send => |v| {
                defer {
                    self.gpa.free(v.agent);
                    self.gpa.free(v.text);
                }
                if (body != .@"error") return;
                try self.returnPrompt(v.agent, v.text);
                self.say("agent send: {s}; the prompt is back in {s}'s box", .{ body.@"error".code, v.agent });
            },
            .inbox => {
                self.inbox_inflight = false;
                if (body == .ok) {
                    try self.inbox.apply(body.ok);
                    // Asked each time, so `attention.bell` applies at once.
                    if (self.rings and try self.bell_watch.update(self.gpa, self.inbox.items.items))
                        try self.request(.{ .config = .bell }, "config.get", .{ .key = "attention.bell" });
                    // Answered items whose answer this list already saw.
                    var i: usize = 0;
                    while (i < self.hidden.items.len) {
                        const h = self.hidden.items[i];
                        if (h.after != null and id >= h.after.?) {
                            self.gpa.free(h.key);
                            _ = self.hidden.orderedRemove(i);
                        } else i += 1;
                    }
                    self.pruneMarks();
                } else if (body == .@"error") self.say("inbox list: {s}", .{body.@"error".code});
                if (self.inbox_again) {
                    self.inbox_again = false;
                    try self.requestInbox();
                }
            },
            .answer => |ans| {
                defer {
                    self.gpa.free(ans.label);
                    self.gpa.free(ans.keys);
                }
                var lines = std.mem.splitScalar(u8, ans.keys, '\n');
                if (body == .@"error") {
                    // The items come back.
                    while (lines.next()) |key| self.unhide(key);
                    self.say("{s}: {s}", .{ ans.label, body.@"error".code });
                    return;
                }
                while (lines.next()) |key| for (self.hidden.items) |*h| {
                    if (std.mem.eql(u8, h.key, key) and h.after == null) h.after = self.next_id;
                };
                try self.requestInbox();
            },
            .workspaces => try workspaces.onList(self, body),
            .harnesses => try workspaces.onHarnesses(self, body),
            .workspace_add => try workspaces.onAdded(self, body),
            .workspace_scan => try workspaces.onScanned(self, body),
            .preview => try new_agent.onPreview(self, id, body),
            .spawn => |start| try new_agent.onSpawned(self, start, body),
            .settings => |request_kind| try self.settings.onResponse(self, request_kind, body),
            .card_show => |agent| {
                defer self.gpa.free(agent);
                try fan_out.onShow(self, agent, body);
            },
            .fan_wait => |agent| {
                defer self.gpa.free(agent);
                fan_out.onWait(self, agent, body);
            },
            .stop_tree => fan_out.onStopTree(self, body),
            .usage => |which| try usage_view.onResponse(self, which, body),
            .context => |which| try context_panel.onResponse(self, which, body),
        }
    }

    // ---- Drafts --------------------------------------------------------

    /// Sends the connection took with it return to their drafts, newest
    /// first so the oldest ends up in front. They may have reached the
    /// daemon before it went; the user sees them and decides.
    fn returnPendingSends(self: *App) !void {
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(self.gpa);
        var it = self.pending.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .send) try ids.append(self.gpa, e.key_ptr.*);
        if (ids.items.len == 0) return;
        std.mem.sortUnstable(i64, ids.items, {}, std.sort.desc(i64));
        for (ids.items) |id| {
            const v = self.pending.getPtr(id).?.send;
            try self.returnPrompt(v.agent, v.text);
        }
        self.say("the daemon went away; unanswered prompts are back in their boxes", .{});
    }

    /// `text` goes back to `agent`'s draft, in front of anything written
    /// since: never lost, and never in another agent's box.
    fn returnPrompt(self: *App, agent: []const u8, text: []const u8) !void {
        const box = self.boxOf(agent);
        const current = if (box) |b| b.value() else self.drafts.get(agent) orelse "";
        const joined = if (current.len > 0) try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ text, current }) else try self.gpa.dupe(u8, text);
        defer self.gpa.free(joined);
        if (box) |b| return loadBox(b, joined);
        try self.putDraft(agent, joined);
    }

    fn loadBox(box: *w.TextInput, text: []const u8) !void {
        box.clear();
        try box.insert(text);
    }

    /// The box `agent`'s draft is in: the main view's while it is selected,
    /// else that of its first agent-view split; null when none is open.
    pub fn boxOf(self: *App, agent: []const u8) ?*w.TextInput {
        if (std.mem.eql(u8, agent, self.selected.items)) return &self.input;
        return self.splitBox(agent);
    }

    fn splitBox(self: *App, agent: []const u8) ?*w.TextInput {
        for (self.splits.items) |*sp| {
            if (sp.kind == .agent_view and std.mem.eql(u8, sp.agent, agent)) if (sp.input) |*i| return i;
        }
        return null;
    }

    fn putDraft(self: *App, agent: []const u8, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        const slot = try self.drafts.getOrPut(self.gpa, agent);
        if (slot.found_existing) {
            self.gpa.free(slot.value_ptr.*);
        } else {
            slot.key_ptr.* = self.gpa.dupe(u8, agent) catch |err| {
                self.drafts.removeByPtr(slot.key_ptr);
                return err;
            };
        }
        slot.value_ptr.* = copy;
    }

    /// The selection moves from the current agent to `id`: the box's text
    /// stays with the agent it was written for, and `id`'s draft comes up.
    fn swapDrafts(self: *App, id: []const u8) !void {
        if (self.selected.items.len > 0) {
            if (self.input.value().len > 0) {
                if (self.splitBox(self.selected.items)) |b| {
                    try loadBox(b, self.input.value());
                } else try self.putDraft(self.selected.items, self.input.value());
            }
            self.input.clear();
        }
        if (self.splitBox(id)) |b| {
            try loadBox(&self.input, b.value());
            b.clear();
            return;
        }
        const entry = self.drafts.fetchRemove(id) orelse return;
        defer {
            self.gpa.free(entry.key);
            self.gpa.free(entry.value);
        }
        try loadBox(&self.input, entry.value);
    }

    // ---- Input ---------------------------------------------------------

    /// Feeds terminal input bytes; returns how many were used (a partial
    /// escape sequence is left for the next call).
    pub fn feed(self: *App, bytes: []const u8) !usize {
        var used: usize = 0;
        while (used < bytes.len) {
            if (self.shell_paste) {
                used += try self.feedShellPaste(bytes[used..]);
                // Still inside: what is left may be the start of its end.
                if (self.shell_paste) break;
                continue;
            }
            const r = self.parser.parse(bytes[used..]) catch {
                used += 1;
                continue;
            };
            if (r.consumed == 0) break;
            used += r.consumed;
            const ev = r.event orelse continue;
            switch (ev) {
                .key => |key| try self.handleKey(key),
                .mouse => |m| try self.handleMouse(m),
                .paste_start => {
                    // A paste is never commands, so it is no next key either.
                    self.leader.end();
                    self.syncLeader();
                    if (self.pasteShell()) |sh| {
                        self.shell_paste = true;
                        try self.shellPasted(sh.pasteStart());
                    } else {
                        self.pasting = true;
                    }
                },
                .paste_end => self.pasting = false,
                .focus, .mouse_leave, .resize => {},
            }
        }
        return used;
    }

    /// The shell a paste goes to now: the focused one, with nothing over it.
    fn pasteShell(self: *App) ?*split.Shell {
        if (self.help or self.pager != null or self.dialog != null or self.prompt != null or self.menu != null or self.ask != null or self.screen != .main) return null;
        const i = self.focusedSplit() orelse return null;
        return self.splits.items[i].shell;
    }

    /// Passes pasted bytes to the focused shell as they are, so they are
    /// never keys here, so a paste cannot close the split. Returns how
    /// many it used. If the split went meanwhile, the rest is dropped.
    fn feedShellPaste(self: *App, bytes: []const u8) !usize {
        const end = "\x1b[201~";
        if (std.mem.indexOf(u8, bytes, end)) |at| {
            self.shell_paste = false;
            if (self.pasteShell()) |sh| {
                try self.shellPasted(sh.paste(bytes[0..at]));
                try self.shellPasted(sh.pasteEnd());
            }
            return at + end.len;
        }
        // The end marker may be cut by the read: keep what could start it.
        var keep: usize = @min(end.len - 1, bytes.len);
        while (keep > 0 and !std.mem.startsWith(u8, end, bytes[bytes.len - keep ..])) keep -= 1;
        const text = bytes[0 .. bytes.len - keep];
        if (self.pasteShell()) |sh| try self.shellPasted(sh.paste(text));
        return text.len;
    }

    fn shellPasted(self: *App, result: anyerror!void) !void {
        result catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.say("shell: {s}", .{@errorName(err)});
        };
        if (self.pasteShell()) |sh| _ = self.sayCut(sh);
    }

    /// Tells the user a paste was cut; true if one was.
    fn sayCut(self: *App, sh: *split.Shell) bool {
        const cut = sh.takeCut() orelse return false;
        self.say("paste cut after {d} bytes: {s}; the rest was dropped", .{ cut.sent, cut.reason.text() });
        return true;
    }

    /// A key of a bracketed paste: text for a text box or a
    /// shell, and nothing anywhere else. It never acts as a command.
    fn pastedKey(self: *App, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        if (self.help or self.pager != null or self.menu != null or self.ask != null) return;
        if (self.dialog != null) return new_agent.key(self, key);
        if (self.screen == .workspaces) return workspaces.key(self, key);
        if (self.screen == .settings) return self.settings.pasted(key);
        if (self.prompt != null) {
            if (k.namedAny(key, .escape)) return;
            if (keys.pastedBreak(key)) return self.answer_input.insert(" ");
            _ = try self.answer_input.handleKey(key);
            return;
        }
        if (self.screen == .inbox) return;
        if (self.filtering) {
            if (k.namedAny(key, .escape)) return;
            if (keys.pastedBreak(key)) return self.filter_input.insert(" ");
            _ = try self.filter_input.handleKey(key);
            self.listChanged();
            return;
        }
        // A focused shell's own paste goes to it as bytes (`feed`), so this one
        // began under an overlay: it never reaches the shell as keys.
        if (self.focusedSplit()) |i| if (self.splits.items[i].shell != null or self.splits.items[i].exited) return;
        // Text in the focused box, main or split; a split's transcript takes
        // nothing, so pasted letters can't answer its approval.
        const box = self.focusedBox() orelse return;
        if (self.boxClosed(box.agent)) return;
        // A pasted line break must not send, nor a pasted tab move the focus.
        if (keys.pastedBreak(key)) return box.input.insert(" ");
        if (k.namedAny(key, .escape)) return;
        _ = try box.input.handleKey(key);
    }

    pub fn handleKey(self: *App, key: term.Input.Key) !void {
        // Nothing else ends a message, and one must not hide the bar's notice
        // for long.
        if (key.action != .release) if (self.host) |h| if (h.notice() != null) self.message.clearRetainingCapacity();
        if (self.pasting) return self.pastedKey(key);
        if (self.quit_prompt) return self.quitPromptKey(key);
        if (!try self.leaderKey(key)) try self.routeKey(key);
        // `--solo` has no list to land on: past it, in the way Tab was going.
        if (self.solo and self.area() == .list) self.focus.set(@backingInt(if (key.mods.shift) Area.input else Area.transcript));
    }

    // ---- The leader -------------------------------------------------------

    /// The leader is live here. `keyMode` alone can't say: the help, the pager,
    /// the menu, the question and the context panel are Normal but own their
    /// keys, and a new-agent dialog that is starting owns them too. `venom
    /// settings` is that one view, so it has nowhere to go.
    pub fn leaderActive(self: *const App) bool {
        if (self.help or self.pager != null or self.menu != null or self.ask != null) return false;
        if (self.dialog != null or self.context_panel.agent != null) return false;
        if (self.screen == .settings and self.settings.standalone) return false;
        if (self.single_view) return false;
        return self.keyMode() == .normal;
    }

    /// `ui.keys.leader` as the help and the hints print it.
    pub fn leaderText(self: *const App) []const u8 {
        return self.leader_text[0..self.leader_len];
    }

    /// Sets the leader; text that is no leader changes nothing (`config set`
    /// refuses it, so this is a hand-edited file).
    fn setLeader(self: *App, text: []const u8) void {
        if (!config_mod.validLeader(text)) return;
        const c = chord.parseChord(text).?;
        var out: std.Io.Writer = .fixed(&self.leader_text);
        chord.formatChord(&out, c) catch return;
        self.leader_len = @intCast(out.buffered().len);
        self.leader.end();
        self.key_settings.leader = c;
        self.settings.leader = self.leaderText();
        self.syncLeader();
    }

    /// Once per loop turn, and after any key: ends a leader mode that ran out
    /// of time or that something else ended the need for, and tells the popup.
    pub fn syncLeader(self: *App) void {
        _ = self.leader.tick(self.now_ms);
        if (self.leader.pending() and !self.leaderActive()) self.leader.end();
        _ = self.leader_timer.sync(.of(&self.leader), self.key_settings.popup_delay_ms, self.now_ms);
    }

    /// When the loop must wake for the leader; null when nothing is waiting.
    pub fn leaderWake(self: *const App) ?i64 {
        const popup = self.leader_timer.nextWake();
        const deadline = self.leader.nextDeadline();
        if (popup == null) return deadline;
        if (deadline == null) return popup;
        return @min(popup.?, deadline.?);
    }

    /// Offers `key` to the leader. True when it was taken, so nothing else may
    /// see it: an unbound key cancels and is swallowed.
    fn leaderKey(self: *App, raw: term.Input.Key) !bool {
        if (raw.action == .release) return self.leader.pending();
        self.syncLeader();
        if (!self.leaderActive()) return false;
        const c = self.leader.chordOf(self.key_settings, raw.codepoint, chordMods(raw), raw.shifted, raw.text, raw.base_layout);
        defer self.syncLeader();
        switch (try self.leader.feed(self.key_settings, keys.treeTables(self.host != null), null, c, self.now_ms)) {
            .pass => return false,
            .leader, .partial, .unbound, .overflow, .unlocked => {},
            .send_leader => self.leaderTwice(),
            .run => |b| try self.runTree(b.target.local, raw),
        }
        return true;
    }

    /// `leader leader`: the agent switcher, once it exists.
    fn leaderTwice(self: *App) void {
        self.say("no agent switcher yet: j k in the list", .{});
    }

    /// A row of the tree. It acts on the agent under the cursor of whichever
    /// view it came from, and what needs the main view goes there first.
    fn runTree(self: *App, action: keys.Action, key: term.Input.Key) !void {
        const stays = action == .local and (action.local == .help or action.local == .help_all or action.local == .settings);
        if (self.screen == .settings and !stays) {
            // Unsaved settings ask first.
            try self.settings.leave(self, false);
            if (self.screen == .settings) return;
        }
        const agent = try self.frame.allocator().dupe(u8, try self.agentHere());
        switch (action) {
            .verb => |verb| {
                if (std.mem.eql(u8, verb, "agent.fork")) return context_panel.fork(self, agent);
                return self.runVerbOn(verb, agent);
            },
            .local => |l| {
                const main_view = switch (l) {
                    .split_menu, .shell_split, .take_over, .close_split, .focus_left, .focus_down, .focus_up, .focus_right, .diff => true,
                    // Their screens draw these over themselves.
                    .new_agent, .new_agent_pick => self.screen != .workspaces,
                    .context_panel => self.screen != .usage,
                    else => false,
                };
                if (main_view and self.screen != .main) {
                    self.on_header = false;
                    if (agent.len > 0) try self.setSelected(agent);
                    self.screen = .main;
                }
                return self.run(action, key);
            },
            .attention => {},
        }
    }

    /// The agent under the cursor: an inbox item's or a usage row's on their
    /// screens, else the focused split's, else the selected one.
    fn agentHere(self: *App) ![]const u8 {
        if (self.screen == .inbox) {
            try self.syncInbox(try self.buildInboxGroups());
            if (try self.currentItem()) |it| return it.agent;
        }
        if (self.screen == .usage) if (self.usage.currentAgent()) |id| return id;
        if (self.focusedSplit()) |i| return self.splits.items[i].agent;
        return self.selected.items;
    }

    /// `d`: asks for the agent's folders, and `openDiff` runs git in them.
    fn requestDiff(self: *App) !void {
        if (!self.connected) return self.say("diff: the daemon is not connected", .{});
        const agent = try self.agentHere();
        if (agent.len == 0) return self.say("no agent selected", .{});
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        try self.request(.{ .diff = id }, "agent.show", .{ .agent = agent });
    }

    /// The agent's diff in the pager. This answer is a background event, so if
    /// a key has moved on since, it must not take the next keys.
    fn openDiff(self: *App, agent: []const u8, show: Value) !void {
        if (self.screen != .main or !self.leaderActive()) return self.say("diff of {s}: not opened over this; d again", .{agent});
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        const folders = if (show == .object) try host_mod.diffFolders(a, show) else &[_][]const u8{};
        if (folders.len == 0) return self.say("{s} has no folder yet", .{agent});
        for (folders) |folder| {
            if (text.items.len > 0) try text.append(self.gpa, '\n');
            try text.print(self.gpa, "── {s} ({s})\n", .{ folder, agent });
            const before = text.items.len;
            try diff.capture(self.gpa, folder, &text);
            if (text.items.len == before) try text.appendSlice(self.gpa, "no changes\n");
        }
        const title = try std.fmt.allocPrint(self.gpa, "Diff · {s}", .{agent});
        errdefer self.gpa.free(title);
        const parts = try self.gpa.alloc([]u8, 1);
        errdefer self.gpa.free(parts);
        parts[0] = try self.gpa.dupe(u8, text.items);
        const id = self.next_pager;
        self.next_pager += 1;
        self.pager = .{ .mode = .body, .title = title, .id = id, .parts = parts };
    }

    /// `!`: the next item that needs you, after the one under the cursor; the
    /// list's order is the inbox's, most urgent first.
    fn nextAttention(self: *App) !void {
        const a = self.frame.allocator();
        var blocking: std.ArrayList(*inbox_mod.Item) = .empty;
        for (try self.visibleItems()) |it| if (it.kind.blocking()) try blocking.append(a, it);
        if (blocking.items.len == 0) return self.say("nothing needs you", .{});
        if (self.screen == .inbox) {
            try self.syncInbox(try self.buildInboxGroups());
            const current = try self.currentItem();
            var next = blocking.items[0];
            for (blocking.items, 0..) |it, i| if (it == current) {
                next = blocking.items[(i + 1) % blocking.items.len];
            };
            return self.setInboxCursor(next);
        }
        // The next item of another agent: an agent has one transcript to open.
        const here = self.selected.items;
        var from: usize = 0;
        for (blocking.items, 0..) |it, i| if (std.mem.eql(u8, it.agent, here)) {
            from = i + 1;
        };
        var next = blocking.items[from % blocking.items.len];
        for (0..blocking.items.len) |n| {
            const it = blocking.items[(from + n) % blocking.items.len];
            if (!std.mem.eql(u8, it.agent, here)) {
                next = it;
                break;
            }
        }
        self.on_header = false;
        self.fan.pinned = false;
        try self.setSelected(next.agent);
        self.scroll.follow();
        // Host mode: its own pane, as `⏎` does.
        if (self.host) |h| return h.openAgent(next.agent);
        self.focus.set(@backingInt(Area.transcript));
    }

    /// The direction rows (own mode): the splits sit side by side, left ones,
    /// the main view, right ones, with the list before them. The transcript
    /// has its box below it, and from a box the leader isn't live, so `k` has
    /// nowhere to go.
    fn moveSplits(self: *App, l: keys.Local) void {
        if (l == .focus_up) return;
        if (l == .focus_down) {
            if (self.area() == .transcript or self.focusedSplit() != null) self.enterInput();
            return;
        }
        // Each stop is a focus index.
        var stops: [2 + split.max]usize = undefined;
        var n: usize = 0;
        if (!self.solo) {
            stops[n] = @backingInt(Area.list);
            n += 1;
        }
        for (self.splits.items, 0..) |sp, i| if (sp.side == .left) {
            stops[n] = fixed_areas + i;
            n += 1;
        };
        stops[n] = @backingInt(Area.transcript);
        n += 1;
        for (self.splits.items, 0..) |sp, i| if (sp.side != .left) {
            stops[n] = fixed_areas + i;
            n += 1;
        };
        const at = for (stops[0..n], 0..) |stop, i| {
            if (stop == self.focus.index) break i;
        } else return;
        const to = if (l == .focus_left) at -| 1 else @min(at + 1, n - 1);
        self.focus.set(stops[to]);
        if (self.focusedSplit()) |i| self.splits.items[i].in_box = false;
    }

    fn routeKey(self: *App, key: term.Input.Key) !void {
        if (self.help) {
            // `j` and `k` read it; any other key closes it; quit still quits.
            const k = term.widgets.keys;
            if (k.char(key, 'j') or k.named(key, .down)) {
                self.help_top +|= 1;
                return;
            }
            if (k.char(key, 'k') or k.named(key, .up)) {
                self.help_top -|= 1;
                return;
            }
            if (keys.match(key, .any)) |a| if (a == .local and a.local == .quit) {
                self.closeHelp();
                // Unsaved settings ask first, here too.
                if (self.screen == .settings) return self.settings.leave(self, true);
                self.quit = true;
                return;
            };
            if (key.action != .release) self.closeHelp();
            return;
        }
        if (self.pager != null) return self.pagerKey(key);
        if (self.prompt != null) return self.promptKey(key);
        if (self.menu != null) return self.menuKey(key);
        if (self.ask != null) return self.askKey(key);
        if (self.dialog != null) return new_agent.key(self, key);
        if (self.filtering) return self.filterKey(key);
        if (self.context_panel.agent != null) return context_panel.key(self, key);
        if (self.screen == .usage) return usage_view.key(self, key);
        if (self.screen == .inbox) return self.inboxKey(key);
        if (self.screen == .workspaces) return workspaces.key(self, key);
        if (self.screen == .settings) return self.settings.handleKey(self, key);
        if (self.focusedSplit()) |i| if (self.splits.items[i].exited) {
            // Its program went on its own: still Terminal, so keys typed for
            // it can't act on anything else. Only these two leave.
            if (term.widgets.keys.named(key, .escape) or self.isLeaveTerminal(key)) {
                var gone = self.removeSplit(i);
                gone.deinit(self.gpa);
                self.focus.set(@backingInt(Area.list));
            }
            return;
        };
        if (self.focusedSplit()) |i| if (self.splits.items[i].shell) |sh| {
            // Terminal mode: the program takes every key but this one.
            if (self.isLeaveTerminal(key)) return self.run(.{ .local = .leave_terminal }, key);
            return sh.key(encodableKey(key)) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.say("shell: {s}", .{@errorName(err)});
            };
        };
        const box = self.focusedBox();
        if (box) |b| if (self.boxClosed(b.agent)) return self.disabledKey(key, b.agent);
        const ctx: keys.Context = if (box != null) .input else switch (self.area()) {
            .list => .list,
            .transcript => .transcript,
            .input => .input,
            .split => .split,
        };
        if (keys.match(key, ctx)) |action| return self.run(action, key);
        switch (self.area()) {
            .list => {
                const r = try self.buildRows();
                if (self.list.handleKey(r, key)) |action| try self.listActed(r, action);
            },
            .transcript => {
                // Inline attention: the selected agent's most urgent item.
                if (self.itemOf(self.selected.items)) |it| if (keys.matchItem(key, it, false)) |at| {
                    if (at != .open) return self.attend(at, it, key, false);
                };
                try self.transcriptKey(&self.rows, &self.scroll, &self.model.detail, self.selected.items, key);
            },
            .input => _ = try self.input.handleKey(key),
            .split => if (self.focusedSplit()) |i| {
                if (box) |b| {
                    _ = try b.input.handleKey(key);
                    return;
                }
                // Inline attention, as in the main view's transcript.
                const sp = &self.splits.items[i];
                if (self.itemOf(sp.agent)) |it| if (keys.matchItem(key, it, false)) |at| {
                    if (at != .open) return self.attend(at, it, key, false);
                };
                try self.transcriptKey(&sp.rows, &sp.scroll, &sp.detail, sp.agent, key);
            },
        }
    }

    fn closeHelp(self: *App) void {
        self.help = false;
        self.help_all = false;
        self.help_top = 0;
    }

    /// `ZON` for a transcript setting: `.compact`, `"5s"`.
    fn applyConfig(self: *App, which: @FieldType(Purpose, "config"), content: []const u8) void {
        const v = std.mem.trim(u8, content, " \n\".");
        switch (which) {
            .density => if (std.meta.stringToEnum(transcript.Density, v)) |d| {
                self.density = d;
            },
            .open_running_after => if (@import("../config.zig").Duration.parseMs(v)) |ms| {
                self.open_running_after_ms = ms;
            } else |_| {},
            .bell => self.bell_due = self.bell_due or std.mem.eql(u8, v, "true"),
            .group_by => if (std.meta.stringToEnum(config_mod.GroupBy, v)) |g| {
                self.group_by = g;
                self.listChanged();
            },
            .children => if (std.meta.stringToEnum(config_mod.Children, v)) |c| {
                self.children = c;
                self.listChanged();
            },
            .leave_terminal, .leader => {
                // A ZON string: `ctrl+\\\\` is `ctrl+\\`, and `.` must survive.
                var buf: [64]u8 = undefined;
                var out: std.Io.Writer = .fixed(&buf);
                switch (std.zig.string_literal.parseWrite(&out, std.mem.trim(u8, content, " \n")) catch return) {
                    .success => if (which == .leader) self.setLeader(out.buffered()) else self.setLeaveTerminal(out.buffered()),
                    .failure => {},
                }
            },
            .popup_delay_ms => if (std.fmt.parseInt(u32, v, 10)) |ms| {
                self.key_settings.popup_delay_ms = ms;
            } else |_| {},
            .timeout_ms => if (std.fmt.parseInt(u32, v, 10)) |ms| {
                self.key_settings.timeout_ms = ms;
            } else |_| {},
        }
    }

    /// A key on a transcript: rows (`j` `k`, `⏎`), then scrolling.
    fn transcriptKey(self: *App, rows: *transcript.View, scroll: *w.ScrollView, d: *model_mod.Detail, agent: []const u8, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        d.to_start = k.named(key, .home);
        try self.refreshRows(rows, d, agent);
        if (k.named(key, .up) or k.char(key, 'k') or k.named(key, .down) or k.char(key, 'j')) {
            const down = k.named(key, .down) or k.char(key, 'j');
            scroll.selected = rows.selectedIndex();
            // Nothing selected yet: start from the tail, which is on screen.
            const picked = if (scroll.selected == null) scroll.selectNext(rows.blocks, -1) else scroll.selectNext(rows.blocks, if (down) 1 else -1);
            if (picked) |i| return rows.select(self.gpa, i);
            scroll.scrollBy(if (down) 1 else -1);
            return;
        }
        if (k.named(key, .enter)) {
            scroll.selected = rows.selectedIndex() orelse scroll.selectNext(rows.blocks, -1);
            const i = scroll.selected orelse return;
            try rows.select(self.gpa, i);
            scroll.toggle(rows.blocks, i);
            return rows.choose(self.gpa, i, !rows.blocks[i].collapsed, d.requests.items, self.rowOptions());
        }
        _ = scroll.handleKey(&.{}, key);
    }

    /// The transcript that has the keys: the main view's or a split's.
    pub fn focusedRows(self: *App) struct { rows: *transcript.View, scroll: *w.ScrollView, detail: *model_mod.Detail, agent: []const u8 } {
        if (self.focusedSplit()) |i| {
            const sp = &self.splits.items[i];
            return .{ .rows = &sp.rows, .scroll = &sp.scroll, .detail = &sp.detail, .agent = sp.agent };
        }
        return .{ .rows = &self.rows, .scroll = &self.scroll, .detail = &self.model.detail, .agent = self.selected.items };
    }

    /// `p` / `J`: the selected row (or the last one) in the pager.
    pub fn openPager(self: *App, mode: transcript.Pager.Mode) !void {
        const f = self.focusedRows();
        // The detail may have changed since the last draw (rows point into it).
        try self.refreshRows(f.rows, f.detail, f.agent);
        const on = f.rows.selectedRow();
        const row = if (on != null and on.?.isTool()) on.? else blk: {
            var i = f.rows.rows.len;
            while (i > 0) {
                i -= 1;
                if (f.rows.rows[i].isTool()) break :blk &f.rows.rows[i];
            }
            return self.say("no tool call to show", .{});
        };
        if (self.pager) |*pg| pg.deinit(self.gpa);
        self.pager = null;
        const title = try transcript.pagerTitle(self.gpa, row, mode);
        errdefer self.gpa.free(title);
        const id = self.next_pager;
        self.next_pager += 1;
        self.pager = .{ .mode = mode, .title = title, .id = id, .parts = try transcript.pagerParts(self.gpa, row, mode) };
        if (!self.connected) return;
        for (row.calls, 0..) |t, part| try self.request(.{ .tool = .{ .pager = id, .part = part } }, "agent.tool", .{ .agent = f.agent, .call = t.call });
    }

    fn pagerKey(self: *App, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        if (key.action == .release) return;
        const pg = &self.pager.?;
        if (k.ctrl(key, 'c')) {
            self.quit = true;
        } else if (k.named(key, .escape) or k.char(key, 'q') or k.char(key, 'p') or k.char(key, 'J')) {
            pg.deinit(self.gpa);
            self.pager = null;
        } else _ = pg.scroll.handleKey(&.{}, key);
    }

    fn handleMouse(self: *App, m: term.Input.Mouse) !void {
        if (self.pager) |*pg| {
            _ = pg.scroll.handleMouse(&.{}, m);
            return;
        }
        if (self.screen != .main or self.prompt != null or self.dialog != null) return;
        if (m.action == .press) self.filtering = false;
        // Click to focus; the wheel scrolls the transcript.
        var regions: [fixed_areas + split.max]term.Region = undefined;
        regions[0..fixed_areas].* = .{ self.list.area, self.scroll.area, self.input_area };
        for (self.splits.items, 0..) |sp, i| regions[fixed_areas + i] = sp.area;
        const was = self.area();
        const clicked = self.focus.handleMouse(m, regions[0 .. fixed_areas + self.splits.items.len]);
        self.noteInputFrom(was);
        // A click in an agent view: its box, or its transcript.
        if (clicked != null) if (self.focusedSplit()) |i| {
            const sp = &self.splits.items[i];
            sp.in_box = sp.kind == .agent_view and w.layout.hit(sp.box_area, m.x, m.y) != null;
        };
        if (self.area() == .list) {
            const r = try self.buildRows();
            if (self.list.handleMouse(r, m)) |action| try self.listActed(r, action);
        } else if (self.area() == .transcript) {
            try self.transcriptMouse(&self.rows, &self.scroll, &self.model.detail, self.selected.items, m);
        } else if (self.focusedSplit()) |i| if (self.splits.items[i].kind == .agent_view) {
            const sp = &self.splits.items[i];
            try self.transcriptMouse(&sp.rows, &sp.scroll, &sp.detail, sp.agent, m);
        };
    }

    /// The wheel scrolls; a click on a row's line opens or closes it.
    fn transcriptMouse(self: *App, rows: *transcript.View, scroll: *w.ScrollView, d: *model_mod.Detail, agent: []const u8, m: term.Input.Mouse) !void {
        d.to_start = false;
        try self.refreshRows(rows, d, agent);
        switch (scroll.handleMouse(rows.blocks, m) orelse return) {
            .toggled => |i| {
                try rows.select(self.gpa, i);
                try rows.choose(self.gpa, i, !rows.blocks[i].collapsed, d.requests.items, self.rowOptions());
            },
            .selected => |i| try rows.select(self.gpa, i),
            else => {},
        }
    }

    pub fn run(self: *App, action: keys.Action, key: term.Input.Key) !void {
        switch (action) {
            .local => |l| switch (l) {
                .move => {},
                .focus => self.moveFocus(key.mods.shift),
                .input => self.enterInput(),
                .clear_draft => if (self.focusedBox()) |box| box.input.clear(),
                .inbox => self.openInbox(),
                .settings => try self.openSettings(),
                .usage => try usage_view.open(self),
                .context_panel => try self.openContextPanel(try self.agentHere()),
                .help => self.help = true,
                .help_all => {
                    self.help = true;
                    self.help_all = true;
                },
                .agents => {
                    self.screen = .main;
                    self.focus.set(@backingInt(Area.list));
                },
                .diff => try self.requestDiff(),
                .next_attention => try self.nextAttention(),
                .workspaces => try workspaces.open(self),
                .workspace_add => {
                    try workspaces.open(self);
                    self.panel.adding = true;
                },
                .workspace_rescan => {
                    try workspaces.open(self);
                    try workspaces.rescan(self);
                },
                .shell_split, .take_over => {
                    const option: split.Option = if (l == .shell_split) .shell else .take_over;
                    const agent = try self.agentHere();
                    if (agent.len == 0) return self.say("no agent selected", .{});
                    const ag = self.model.find(agent) orelse return self.say("no agent {s}", .{agent});
                    const offered = split.options(ag, self.resumes(ag.harness));
                    if (offered.has(option)) return self.openOption(option, ag, .right);
                    if (option == .shell) return self.say("{s} has no folder yet", .{agent});
                    return self.say("take over: {s} has no resume", .{ag.harness});
                },
                .focus_left, .focus_down, .focus_up, .focus_right => self.moveSplits(l),
                .new_agent => try new_agent.open(self, self.hereWorkspace(), false),
                .new_agent_pick => try new_agent.open(self, self.hereWorkspace(), true),
                .back => if (self.single_view) {
                    self.quit = true;
                } else if (self.screen != .main) {
                    self.screen = .main;
                } else if (self.area() == .list and self.filter_input.value().len > 0) {
                    self.filter_input.clear();
                    self.listChanged();
                } else if (self.inSplitBox()) |i| {
                    // Out of a split's box: to its transcript, still in the split.
                    self.splits.items[i].in_box = false;
                } else if (self.area() == .input) {
                    // Back where Input was entered from; the draft stays.
                    self.focus.set(@backingInt(self.input_from));
                } else self.focus.set(@backingInt(Area.list)),
                .quit => self.quit = true,
                .split_menu => {
                    if (self.single_view) return self.say("{s}", .{single_view_open});
                    // A fan-out card: its child. From a split: the split's
                    // agent; else the selected one.
                    const agent = try fan_out.focusedCard(self) orelse if (self.focusedSplit()) |i| self.splits.items[i].agent else self.selected.items;
                    try self.openMenu(agent);
                },
                .close_split => if (self.splits.items.len > 0) {
                    try self.closeSplit(self.focusedSplit() orelse self.left_split orelse self.splits.items.len - 1);
                } else if (self.host) |h| {
                    try h.closeNewest(self, self.selected.items);
                } else self.say("no split to close", .{}),
                .leave_terminal => {
                    self.left_split = self.focusedSplit();
                    self.focus.set(@backingInt(Area.list));
                },
                .take_back => {
                    const agent = if (self.focusedSplit()) |i| self.splits.items[i].agent else self.selected.items;
                    try self.takeBack(agent);
                },
                .group_by => {
                    self.group_by = agent_list.next(self.group_by);
                    self.listChanged();
                    self.say("group by: {s}", .{@tagName(self.group_by)});
                },
                .children => {
                    self.children = agent_list.next(self.children);
                    self.listChanged();
                    self.say("sub-agents: {s}", .{@tagName(self.children)});
                },
                .filter => self.filtering = true,
                .density => {
                    self.density = self.density.next();
                    // Every transcript follows it; choices start over.
                    self.rows.reset(self.gpa);
                    for (self.splits.items) |*sp| sp.rows.reset(self.gpa);
                    self.say("density: {s}", .{@tagName(self.density)});
                },
                .expand_all, .collapse_all => {
                    const f = self.focusedRows();
                    try self.refreshRows(f.rows, f.detail, f.agent);
                    try f.rows.chooseAll(self.gpa, l == .expand_all, f.detail.requests.items, self.rowOptions());
                },
                .pager => try self.openPager(.body),
                .raw_json => try self.openPager(.raw),
                .to_child => try fan_out.intoChild(self),
                .to_parent => try fan_out.toParent(self),
                .promote => try fan_out.promote(self),
                .wait_all => try fan_out.waitAll(self),
                .stop_all => try fan_out.stopAll(self),
            },
            .verb => |verb| if (std.mem.eql(u8, verb, "agent.send")) try self.sendPrompt(input_box.Press.of(key)) else try self.runVerb(verb),
            .attention => {},
        }
    }

    /// Where "new agent here" starts: the panel's workspace, else the
    /// selected agent's.
    fn hereWorkspace(self: *const App) []const u8 {
        if (self.screen == .workspaces) if (self.panel.current()) |c| return c.path;
        return if (self.model.find(self.selected.items)) |ag| ag.workspace else "";
    }

    /// Tab: the next area of the ring. An agent-view split is two stops, its
    /// transcript and then its box, so the box is reached the same way as the
    /// main view's.
    /// `i`: Input on the agent under the cursor: an agent view's own, else
    /// the main view's.
    fn enterInput(self: *App) void {
        if (self.focusedSplit()) |i| {
            const sp = &self.splits.items[i];
            if (sp.kind == .agent_view) sp.in_box = true;
            return;
        }
        const was = self.area();
        self.focus.set(@backingInt(Area.input));
        self.noteInputFrom(was);
    }

    /// Focus moved from `was`: if that entered the main box, esc returns there.
    fn noteInputFrom(self: *App, was: Area) void {
        if (self.area() != .input or was == .input) return;
        self.input_from = if (was == .transcript) .transcript else .list;
    }

    fn chordMods(key: term.Input.Key) chord.Mods {
        const m = key.mods;
        return .{ .ctrl = m.ctrl, .alt = m.alt, .shift = m.shift, .super = m.super };
    }

    /// `key`, as the VT encoder can send it. A legacy terminal's ⌃\\ ⌃] ⌃^ ⌃_
    /// arrive as the bare control byte, which it drops; `fromKey` names the key.
    fn encodableKey(key: term.Input.Key) term.Input.Key {
        if (key.codepoint >= 0x20 or key.mods.ctrl) return key;
        const c = chord.fromKey(key.codepoint, chordMods(key), key.shifted, key.text);
        if (!c.mods.ctrl) return key;
        var out = key;
        out.codepoint = c.cp;
        out.mods.ctrl = true;
        return out;
    }

    /// `key` is `ui.keys.leave_terminal`. As for the leader, a non-Latin layout
    /// falls back to the Latin base key unless the character itself is the key:
    /// no leader mode runs in Terminal, so this key is the only one to protect.
    fn isLeaveTerminal(self: *const App, key: term.Input.Key) bool {
        if (!term.widgets.keys.pressed(key)) return false;
        const settings: chord.Settings = .{ .leader = self.leave_terminal, .unlock = self.leave_terminal };
        return self.leader.chordOf(settings, key.codepoint, chordMods(key), key.shifted, key.text, key.base_layout).eql(self.leave_terminal);
    }

    /// `ui.keys.leave_terminal` as the bar and the help show it.
    pub fn leaveTerminalText(self: *const App) []const u8 {
        return self.leave_terminal_text[0..self.leave_terminal_len];
    }

    /// Sets the key that leaves Terminal mode; text that is no chord changes
    /// nothing (`config set` refuses it, so this is a hand-edited file).
    fn setLeaveTerminal(self: *App, text: []const u8) void {
        const c = chord.parseChord(text) orelse return;
        if (c.plain()) return;
        var buf: [32]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        chord.formatChord(&out, c) catch return;
        const canon = out.buffered();
        const plain_ctrl = c.mods.ctrl and !c.mods.alt and !c.mods.shift and !c.mods.super;
        const shown = if (plain_ctrl) canon["ctrl+".len..] else canon;
        const prefix: []const u8 = if (plain_ctrl) "⌃" else "";
        if (prefix.len + shown.len > self.leave_terminal_text.len) return;
        @memcpy(self.leave_terminal_text[0..prefix.len], prefix);
        @memcpy(self.leave_terminal_text[prefix.len..][0..shown.len], shown);
        self.leave_terminal_len = @intCast(prefix.len + shown.len);
        self.leave_terminal = c;
    }

    fn moveFocus(self: *App, back: bool) void {
        if (self.focusedSplit()) |i| {
            const sp = &self.splits.items[i];
            if (sp.kind == .agent_view and sp.in_box == back) {
                sp.in_box = !back;
                return;
            }
        }
        const was = self.area();
        if (back) self.focus.prev() else self.focus.next();
        self.noteInputFrom(was);
        if (self.focusedSplit()) |i| {
            const sp = &self.splits.items[i];
            sp.in_box = back and sp.kind == .agent_view;
        }
    }

    /// The focused split, if focus is on its input box.
    fn inSplitBox(self: *const App) ?usize {
        const i = self.focusedSplit() orelse return null;
        const sp = &self.splits.items[i];
        return if (sp.kind == .agent_view and sp.in_box) i else null;
    }

    /// An input box has focus: the main view's or an agent-view split's.
    pub fn inFocusedBox(self: *const App) bool {
        return self.area() == .input or self.inSplitBox() != null;
    }

    /// A focused box, and what it writes to.
    const FocusedBox = struct {
        input: *w.TextInput,
        agent: []const u8,
        detail: *const model_mod.Detail,
    };

    fn focusedBox(self: *App) ?FocusedBox {
        if (self.area() == .input) return .{ .input = &self.input, .agent = self.selected.items, .detail = &self.model.detail };
        const i = self.inSplitBox() orelse return null;
        const sp = &self.splits.items[i];
        return .{ .input = self.boxOf(sp.agent).?, .agent = sp.agent, .detail = &sp.detail };
    }

    /// Attention keys for `agent` work where the focus is now.
    pub fn answersHere(self: *const App, agent: []const u8) bool {
        if (self.area() == .transcript) return std.mem.eql(u8, agent, self.selected.items);
        const i = self.focusedSplit() orelse return false;
        const sp = &self.splits.items[i];
        return sp.kind == .agent_view and !sp.in_box and std.mem.eql(u8, sp.agent, agent);
    }

    fn runVerb(self: *App, verb: []const u8) !void {
        return self.runVerbOn(verb, self.selected.items);
    }

    fn runVerbOn(self: *App, verb: []const u8, agent: []const u8) !void {
        if (!self.connected) return self.say("{s}: the daemon is not connected", .{verb});
        if (agent.len == 0) return self.say("no agent selected", .{});
        if (std.mem.eql(u8, verb, "agent.show")) {
            // ⏎ on a group's header folds it.
            if (self.on_header) {
                const r = try self.buildRows();
                const i = self.list.cursor;
                if (i < r.rows.len and r.rows[i] == .header) try self.listActed(r, .{ .toggled = i });
                return;
            }
            // Host mode: the agent lives in its own pane; focus stays here
            // and no verb moves the human's.
            if (self.host) |h| {
                try h.openAgent(agent);
                return self.requestShow();
            }
            self.focus.set(@backingInt(Area.transcript));
            self.scroll.follow();
            return self.requestShow();
        }
        const label = if (std.mem.eql(u8, verb, "agent.stop")) "agent stop" else "agent archive";
        try self.request(.{ .action = try self.gpa.dupe(u8, label) }, verb, .{ .agent = agent });
    }

    /// A key in the disabled box. The box still has the focus, so this is
    /// Input: the agent being handed over while the user types must not turn
    /// their letters into commands. Only esc, tab and ⌃c act (`[` too for a
    /// native sub-agent, which no event makes one), and never from a paste.
    /// `T` and `\\` work once esc has left the box.
    fn disabledKey(self: *App, key: term.Input.Key, agent: []const u8) !void {
        const k = term.widgets.keys;
        if (self.pasting or !k.pressed(key)) return;
        const tab = k.namedAny(key, .tab) and !key.mods.ctrl and !key.mods.alt;
        const native = self.isNative(agent);
        if (k.ctrl(key, 'c')) return self.run(.{ .local = .clear_draft }, key);
        if (tab or (native and k.char(key, '[')) or k.named(key, .escape)) {
            if (keys.match(key, .transcript)) |action| return self.run(action, key);
        }
        if (native) return self.say("{s} belongs to its harness. Message the parent to steer it; [ goes there", .{agent});
        self.sayHandedOver(agent);
    }

    /// The input box is disabled while the harness's own TUI has the agent.
    pub fn inputDisabled(self: *const App) bool {
        return self.handedOver(self.selected.items);
    }

    fn handedOver(self: *const App, agent: []const u8) bool {
        const ag = self.model.find(agent) orelse return false;
        return ag.state == .handed_over;
    }

    /// The harness's own sub-agent: the human can't prompt it.
    fn isNative(self: *const App, agent: []const u8) bool {
        const ag = self.model.find(agent) orelse return false;
        return ag.native;
    }

    /// The input box of `agent` takes no text.
    fn boxClosed(self: *const App, agent: []const u8) bool {
        return self.handedOver(agent) or self.isNative(agent);
    }

    fn sayHandedOver(self: *App, agent: []const u8) void {
        const ag = self.model.find(agent) orelse return;
        self.say("{s} is in {s}'s own TUI; esc, then T takes it back", .{ ag.id, ag.harness });
    }

    /// The status bar's keys while the input box has focus.
    pub fn inputHint(self: *const App) []const u8 {
        const split_box: ?*const split.Split = if (self.inSplitBox()) |i| &self.splits.items[i] else null;
        const agent = if (split_box) |sp| sp.agent else self.selected.items;
        if (self.handedOver(agent)) return "esc first, then T take back  \\ split";
        if (self.isNative(agent)) return "[ parent  esc back";
        const ag = self.model.find(agent) orelse return input_box.hint(.settled, .unknown, null);
        const d = if (split_box) |sp| &sp.detail else &self.model.detail;
        return input_box.hint(ag.state, d.steer, d.interrupt);
    }

    /// The focused box's `agent.send`; `press` picks the mode (input_box.zig).
    fn sendPrompt(self: *App, press: input_box.Press) !void {
        if (!self.connected) return self.say("agent.send: the daemon is not connected", .{});
        const box = self.focusedBox() orelse return;
        const agent = box.agent;
        if (agent.len == 0) return self.say("no agent selected", .{});
        if (self.handedOver(agent)) return self.sayHandedOver(agent);
        if (self.isNative(agent)) return self.say("{s} belongs to its harness. Message the parent to steer it", .{agent});
        if (std.mem.trim(u8, box.input.value(), " \t\r\n").len == 0) return;
        const state: State = if (self.model.find(agent)) |ag| ag.state else .settled;
        const d = box.detail;
        const mode = switch (input_box.choose(press, state, d.steer, d.interrupt)) {
            .send => |m| m,
            .refuse => |why| {
                const harness = if (self.model.find(agent)) |ag| ag.harness else "this harness";
                return self.say("{s} {s}", .{ harness, why.text() });
            },
        };
        const owner = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(owner);
        const text = try box.input.submit();
        errdefer self.gpa.free(text);
        try self.request(.{ .send = .{ .agent = owner, .text = text } }, "agent.send", .{ .agent = agent, .text = text, .mode = @tagName(mode) });
    }

    pub fn setSelected(self: *App, id: []const u8) !void {
        if (std.mem.eql(u8, self.selected.items, id)) return;
        try self.swapDrafts(id);
        self.selected.clearRetainingCapacity();
        try self.selected.appendSlice(self.gpa, id);
        try self.model.select(id);
        self.scroll.follow();
        try self.requestShow();
    }

    /// `leader s` or `venom settings`: the settings screen, fresh values.
    pub fn openSettings(self: *App) !void {
        self.screen = .settings;
        self.message.clearRetainingCapacity();
        try self.settings.refresh(self);
    }

    // ---- Inbox -----------------------------------------------------------

    pub fn openInbox(self: *App) void {
        self.screen = .inbox;
        self.message.clearRetainingCapacity();
    }

    pub fn isHidden(self: *const App, it: *const inbox_mod.Item) bool {
        for (self.hidden.items) |h| if (keyIs(h.key, it)) return true;
        return false;
    }

    fn keyIs(key: []const u8, it: *const inbox_mod.Item) bool {
        const slash = std.mem.indexOfScalar(u8, key, '/') orelse return false;
        return it.is(key[0..slash], key[slash + 1 ..]);
    }

    fn unhide(self: *App, key: []const u8) void {
        for (self.hidden.items, 0..) |h, i| if (std.mem.eql(u8, h.key, key)) {
            self.gpa.free(h.key);
            _ = self.hidden.orderedRemove(i);
            return;
        };
    }

    pub fn isMarked(self: *const App, it: *const inbox_mod.Item) bool {
        for (self.marks.items) |m| if (keyIs(m, it)) return true;
        return false;
    }

    /// Drops marks whose item is gone or hidden.
    fn pruneMarks(self: *App) void {
        var i: usize = 0;
        while (i < self.marks.items.len) {
            const m = self.marks.items[i];
            const slash = std.mem.indexOfScalar(u8, m, '/') orelse 0;
            const live = if (self.inbox.find(m[0..slash], m[slash + 1 ..])) |it| !self.isHidden(it) else false;
            if (live) {
                i += 1;
            } else {
                self.gpa.free(m);
                _ = self.marks.orderedRemove(i);
            }
        }
    }

    /// The inbox items shown now (answered ones are hidden), in order.
    pub fn visibleItems(self: *App) ![]*inbox_mod.Item {
        const a = self.frame.allocator();
        var out: std.ArrayList(*inbox_mod.Item) = .empty;
        for (self.inbox.items.items) |*it| if (!self.isHidden(it)) try out.append(a, it);
        return out.items;
    }

    /// The agent's most urgent visible item (inline attention).
    pub fn itemOf(self: *const App, agent: []const u8) ?*inbox_mod.Item {
        if (agent.len == 0) return null;
        for (self.inbox.items.items) |*it| if (std.mem.eql(u8, it.agent, agent) and !self.isHidden(it)) return it;
        return null;
    }

    /// The item under the inbox cursor, after `syncInbox`.
    pub fn currentItem(self: *App) !?*inbox_mod.Item {
        const items = try self.visibleItems();
        for (items) |it| if (keyIs(self.inbox_cursor.items, it)) return it;
        return null;
    }

    pub const InboxGroups = struct {
        groups: []w.list.Group,
        /// The items behind each group's rows.
        items: [][]*inbox_mod.Item,
    };

    /// The inbox list's groups for this frame (allocated in `frame`).
    pub fn buildInboxGroups(self: *App) !InboxGroups {
        const a = self.frame.allocator();
        var rows: [inbox_mod.group_names.len]std.ArrayList(w.list.Item) = @splat(.empty);
        var refs: [inbox_mod.group_names.len]std.ArrayList(*inbox_mod.Item) = @splat(.empty);
        for (try self.visibleItems()) |it| {
            const g = it.kind.group();
            const detail = try a.alloc(w.Span, 1);
            const scope = if (self.model.find(it.agent)) |ag| ag.harness else "";
            // The agent, then what the item needs (the grant) or who runs it.
            const extra = if (it.grant.len > 0) it.grant else scope;
            detail[0] = .{ .text = try std.fmt.allocPrint(a, "{s} · {s}{s}{s}", .{ if (it.title.len > 0) it.title else it.agent, it.agent, if (extra.len > 0) " · " else "", extra }) };
            const mark = if (self.isMarked(it)) "◉ " else "";
            try rows[g].append(a, .{
                .glyph = it.kind.glyph(),
                .glyph_role = kindRole(it.kind),
                .title = try std.fmt.allocPrint(a, "{s}{s}: {s}", .{ mark, it.kind.label(), it.reason }),
                .meta = try inbox_mod.ageText(a, it.age_s),
                .detail = detail,
                .bold = it.kind == .review,
            });
            try refs[g].append(a, it);
        }
        var groups: std.ArrayList(w.list.Group) = .empty;
        var items: std.ArrayList([]*inbox_mod.Item) = .empty;
        for (0..inbox_mod.group_names.len) |n| {
            if (rows[n].items.len == 0) continue;
            try groups.append(a, .{ .title = inbox_mod.group_names[n], .items = rows[n].items, .summary = try std.fmt.allocPrint(a, "{d}", .{rows[n].items.len}) });
            try items.append(a, refs[n].items);
        }
        return .{ .groups = groups.items, .items = items.items };
    }

    /// Keeps the inbox cursor on its item; when the item went (answered
    /// here or elsewhere), takes the one now at its position: the next.
    pub fn syncInbox(self: *App, g: InboxGroups) !void {
        var n: usize = 0;
        for (g.items, 0..) |group, gi| for (group, 0..) |it, ii| {
            if (keyIs(self.inbox_cursor.items, it)) {
                self.inbox_list.select(g.groups, .{ .item = .{ .group = gi, .index = ii } });
                self.inbox_index = n;
                return;
            }
            n += 1;
        };
        if (n == 0) return;
        const want = @min(self.inbox_index, n - 1);
        n = 0;
        for (g.items, 0..) |group, gi| for (group, 0..) |it, ii| {
            if (n == want) {
                try self.setInboxCursor(it);
                self.inbox_list.select(g.groups, .{ .item = .{ .group = gi, .index = ii } });
                self.inbox_index = n;
                return;
            }
            n += 1;
        };
    }

    fn setInboxCursor(self: *App, it: *const inbox_mod.Item) !void {
        self.inbox_cursor.clearRetainingCapacity();
        try self.inbox_cursor.print(self.gpa, "{s}/{s}", .{ it.agent, it.item });
        self.inbox_scroll.follow();
    }

    fn inboxKey(self: *App, key: term.Input.Key) !void {
        if (keys.match(key, .inbox)) |action| return self.run(action, key);
        const g = try self.buildInboxGroups();
        try self.syncInbox(g);
        if (try self.currentItem()) |it| if (keys.matchItem(key, it, true)) |at| return self.attend(at, it, key, true);
        const down = term.widgets.keys.char(key, 'j') or term.widgets.keys.named(key, .down);
        if (self.inbox_list.handleKey(g.groups, key)) |act| {
            if (act == .toggled) return;
            // Headers are skipped: the cursor is always on an item.
            if (self.inbox_list.selected(g.groups)) |sel| if (sel == .group) {
                self.inbox_list.moveBy(g.groups, if (down or self.inbox_list.cursor == 0) 1 else -1);
            };
            if (self.inbox_list.selected(g.groups)) |sel| if (sel == .item) {
                try self.setInboxCursor(g.items[sel.item.group][sel.item.index]);
            };
            return;
        }
        if (term.widgets.keys.pressed(key)) if (try self.currentItem()) |it| {
            if (key.codepoint >= 0x20 and key.codepoint < 0x7f) self.say("{u}: no action for a {s} item; ? keys", .{ key.codepoint, @tagName(it.kind) });
        };
    }

    /// Hides `it` and moves the inbox cursor to the item after it
    /// (answer-and-advance).
    fn hide(self: *App, it: *const inbox_mod.Item, advance: bool) ![]u8 {
        const key = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ it.agent, it.item });
        errdefer self.gpa.free(key);
        if (advance) {
            const items = try self.visibleItems();
            var next: ?*inbox_mod.Item = null;
            for (items, 0..) |x, i| if (x == it) {
                next = if (i + 1 < items.len) items[i + 1] else if (i > 0) items[i - 1] else null;
                self.inbox_index = i;
            };
            if (next) |n| try self.setInboxCursor(n) else self.inbox_cursor.clearRetainingCapacity();
        }
        const copy = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(copy);
        try self.hidden.append(self.gpa, .{ .key = copy });
        return key;
    }

    /// Sends an attention verb for `it`; the item is hidden meanwhile.
    fn answerItem(self: *App, it: *const inbox_mod.Item, advance: bool, label: []const u8, verb: []const u8, params: anytype) !void {
        if (!self.connected) return self.say("{s}: the daemon is not connected", .{label});
        const keys_owned = try self.hide(it, advance);
        errdefer self.gpa.free(keys_owned);
        const label_owned = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(label_owned);
        try self.request(.{ .answer = .{ .label = label_owned, .keys = keys_owned } }, verb, params);
    }

    const AnswerParams = struct {
        agent: []const u8,
        request: []const u8,
        answer: []const u8,
        reason: ?[]const u8 = null,
        args: ?[]const u8 = null,
    };

    fn sendAnswer(self: *App, it: *const inbox_mod.Item, advance: bool, answer: []const u8, reason: ?[]const u8, args: ?[]const u8) !void {
        try self.answerItem(it, advance, "inbox answer", "inbox.answer", AnswerParams{ .agent = it.agent, .request = it.request, .answer = answer, .reason = reason, .args = args });
    }

    /// `1`-`9` on a question: the option's label is the
    /// answer, under the question's id in `args` (`{"q1":["label"]}`). With
    /// several questions each digit picks for the next one, and the answer
    /// goes when the last is picked. Without options (an older daemon, or a
    /// harness that lists none) the number is the reply.
    fn pickOption(self: *App, it: *inbox_mod.Item, advance: bool, key: term.Input.Key) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(key.codepoint, &buf) catch 0;
        const digit: usize = if (n == 1 and buf[0] >= '1' and buf[0] <= '9') buf[0] - '0' else 0;
        // What was drawn is what is picked from: refused before anything is
        // sent when nothing was drawn for this item, or its options changed
        // since (also when they vanished, so the digit is not sent as text).
        if (it.kind == .question) {
            const d = self.drawn orelse return self.say("the options were not drawn yet; look at them again", .{});
            if (d.item != inbox_mod.itemHash(it) or d.sig != inbox_mod.optionsSig(it))
                return self.say("the options changed; look at them again", .{});
        }
        if (it.options.len == 0 or digit == 0) return self.sendAnswer(it, advance, buf[0..n], null, null);
        for (it.options) |q| if (q.labels.len == 0) {
            if (!q.free_text) return self.say("{s} cannot be answered here (no options kept); answer it in the harness, or cancel", .{q.id});
            return self.say("{s} takes a typed answer; enter types one for all of them", .{q.id});
        };
        if (it.options.len > self.picks.chosen.len) return self.say("too many questions to pick here; answer in the harness", .{});
        const done = self.picks.count(it);
        const q = it.options[done];
        if (digit > q.labels.len) return self.say("no option {d}; enter types an answer", .{digit});
        self.picks.push(it, digit - 1);
        if (done + 1 < it.options.len) return self.say("picked {s}; now {s}", .{ q.labels[digit - 1], it.options[done + 1].id });
        const a = self.frame.allocator();
        var args: std.Io.Writer.Allocating = .init(a);
        var text: std.Io.Writer.Allocating = .init(a);
        try args.writer.writeByte('{');
        for (it.options, 0..) |oq, i| {
            const label = oq.labels[self.picks.chosen[i]];
            if (i > 0) {
                try args.writer.writeByte(',');
                try text.writer.writeAll(", ");
            }
            try args.writer.print("{f}:[{f}]", .{ std.json.fmt(oq.id, .{}), std.json.fmt(label, .{}) });
            try text.writer.writeAll(label);
        }
        try args.writer.writeByte('}');
        self.picks.n = 0;
        try self.sendAnswer(it, advance, text.written(), null, args.written());
    }

    /// One inbox action on `it`. `advance`: on the inbox
    /// screen, answering moves to the next item.
    fn attend(self: *App, at: keys.Attention, it: *inbox_mod.Item, key: term.Input.Key, advance: bool) !void {
        switch (at) {
            .yes => try self.sendAnswer(it, advance, if (it.kind == .plan) "approve" else "allow_once", null, null),
            .always => {
                if (it.grant.len == 0) return self.say("allow always: this approval has no grant to keep; allow it once (y)", .{});
                try self.sendAnswer(it, advance, "allow_always", null, null);
            },
            .no => if (it.kind == .plan) try self.openPrompt(.reject_feedback, it, advance) else try self.sendAnswer(it, advance, "deny", null, null),
            .reason => try self.openPrompt(.deny_reason, it, advance),
            .edit => try self.openPrompt(.edit_command, it, advance),
            .type_answer => try self.openPrompt(.question, it, advance),
            .pick => try self.pickOption(it, advance, key),
            .snooze => try self.answerItem(it, advance, "inbox snooze", "inbox.snooze", .{ .agent = it.agent, .item = it.item }),
            .archive => try self.answerItem(it, advance, "agent archive", "agent.archive", .{ .agent = it.agent }),
            .open => {
                if (self.single_view) return self.say("{s}", .{single_view_open});
                self.screen = .main;
                self.on_header = false;
                try self.setSelected(it.agent);
                self.focus.set(@backingInt(Area.transcript));
                self.scroll.follow();
            },
            .retry => if (self.single_view) self.say("{s}", .{single_view_open}) else self.say("retry: venom has no retry verb yet; o opens the agent, i there sends it a prompt", .{}),
            .split => {
                if (self.single_view) return self.say("{s}", .{single_view_open});
                self.screen = .main;
                self.on_header = false;
                try self.setSelected(it.agent);
                try self.openMenu(it.agent);
            },
            .mark => {
                for (self.marks.items, 0..) |m, i| if (keyIs(m, it)) {
                    self.gpa.free(m);
                    _ = self.marks.orderedRemove(i);
                    return;
                };
                const m = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ it.agent, it.item });
                errdefer self.gpa.free(m);
                try self.marks.append(self.gpa, m);
            },
            .batch_allow, .batch_deny => try self.batch(if (at == .batch_allow) "allow_once" else "deny"),
        }
    }

    /// `Y` / `N`: only approvals that request one and the same grant;
    /// anything else is refused here, unsent.
    fn batch(self: *App, answer: []const u8) !void {
        self.pruneMarks();
        if (self.marks.items.len == 0) return self.say("batch: mark approvals with m first", .{});
        const a = self.frame.allocator();
        var picked: std.ArrayList(*inbox_mod.Item) = .empty;
        for (self.inbox.items.items) |*it| if (self.isMarked(it)) try picked.append(a, it);
        var grant: []const u8 = "";
        for (picked.items) |it| {
            if (it.kind != .approval) return self.say("batch: only approvals can be answered together; {s} is a {s}", .{ it.agent, @tagName(it.kind) });
            if (it.grant.len == 0) return self.say("batch: {s}'s approval has no grant; answer it alone", .{it.agent});
            if (grant.len == 0) grant = it.grant;
            if (!std.mem.eql(u8, grant, it.grant)) return self.say("batch: the marked approvals request different grants ({s}, {s}); nothing sent", .{ grant, it.grant });
        }
        if (!self.connected) return self.say("inbox batch: the daemon is not connected", .{});
        const Pair = struct { agent: []const u8, request: []const u8 };
        const pairs = try a.alloc(Pair, picked.items.len);
        var joined: std.ArrayList(u8) = .empty;
        errdefer joined.deinit(self.gpa);
        // Hide them all; the cursor advances past the one it was on.
        const current = try self.currentItem();
        for (picked.items, pairs, 0..) |it, *p, i| {
            p.* = .{ .agent = it.agent, .request = it.request };
            if (i > 0) try joined.append(self.gpa, '\n');
            const key = try self.hide(it, current != null and current.? == it);
            defer self.gpa.free(key);
            try joined.appendSlice(self.gpa, key);
        }
        // A cursor left on a marked item moves on as well.
        if (try self.currentItem() == null) if ((try self.visibleItems()).len > 0) {
            const items = try self.visibleItems();
            try self.setInboxCursor(items[@min(self.inbox_index, items.len - 1)]);
        };
        for (self.marks.items) |m| self.gpa.free(m);
        self.marks.clearRetainingCapacity();
        const label = try self.gpa.dupe(u8, "inbox batch");
        errdefer self.gpa.free(label);
        const keys_owned = try joined.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(keys_owned);
        try self.request(.{ .answer = .{ .label = label, .keys = keys_owned } }, "inbox.batch", .{ .items = pairs, .answer = answer });
    }

    fn openPrompt(self: *App, mode: Prompt.Mode, it: *const inbox_mod.Item, advance: bool) !void {
        self.dropPrompt();
        const key = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ it.agent, it.item });
        self.prompt = .{ .mode = mode, .key = key, .advance = advance };
        self.answer_input.clear();
        self.answer_input.opts.placeholder = mode.placeholder();
    }

    fn dropPrompt(self: *App) void {
        if (self.prompt) |p| self.gpa.free(p.key);
        self.prompt = null;
    }

    fn promptKey(self: *App, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        if (!k.pressed(key)) return;
        if (k.ctrl(key, 'c')) return self.answer_input.clear();
        if (k.named(key, .escape)) return self.dropPrompt();
        if (!k.named(key, .enter)) {
            _ = try self.answer_input.handleKey(key);
            return;
        }
        const p = self.prompt.?;
        const text = std.mem.trim(u8, self.answer_input.value(), " \t\r\n");
        if (text.len == 0) return self.say("{s}: write something first, or esc", .{p.mode.title()});
        const slash = std.mem.indexOfScalar(u8, p.key, '/') orelse return self.dropPrompt();
        const it = self.inbox.find(p.key[0..slash], p.key[slash + 1 ..]) orelse {
            self.dropPrompt();
            return self.say("the item was answered elsewhere", .{});
        };
        const a = self.frame.allocator();
        const value = try a.dupe(u8, text);
        switch (p.mode) {
            .deny_reason => try self.sendAnswer(it, p.advance, "deny", value, null),
            .reject_feedback => try self.sendAnswer(it, p.advance, "reject", value, null),
            .question => try self.sendAnswer(it, p.advance, value, null, null),
            .edit_command => try self.sendAnswer(it, p.advance, "allow_edited", null, try std.json.Stringify.valueAlloc(a, .{ .command = value }, .{})),
        }
        self.answer_input.clear();
        self.dropPrompt();
    }

    // ---- Splits ----------------------------------------------------------

    fn requestSplitShow(self: *App, sp: *split.Split) !void {
        if (sp.kind != .agent_view or !self.connected) return;
        if (sp.show_inflight) {
            sp.show_again = true;
            return;
        }
        sp.show_inflight = true;
        const agent = try self.gpa.dupe(u8, sp.agent);
        errdefer self.gpa.free(agent);
        try self.sendShow(.{ .split_show = agent }, sp.agent, sp.detail.nextPage(false));
    }

    /// The split menu for `agent`.
    pub fn openMenu(self: *App, agent: []const u8) !void {
        if (agent.len == 0) return self.say("no agent selected", .{});
        const ag = self.model.find(agent) orelse return self.say("no agent {s}", .{agent});
        // Handed over: `\` focuses its take-over split (the banner's
        // "Focus split"). No verb moves a venomx client's focus, so there it
        // says where the pane is.
        if (ag.state == .handed_over) {
            if (self.takeoverSplit(agent)) |i| {
                self.focus.set(fixed_areas + i);
                return;
            }
            if (self.host) |h| if (h.takeoverPane(agent)) |p| return self.say("{s} is in pane {s}", .{ agent, p.pane });
        }
        const opts = split.options(ag, self.resumes(ag.harness));
        const id = try self.gpa.dupe(u8, agent);
        self.dropMenu();
        self.menu = .{ .agent = id, .opts = opts };
        self.message.clearRetainingCapacity();
    }

    fn dropMenu(self: *App) void {
        if (self.menu) |m| self.gpa.free(m.agent);
        self.menu = null;
    }

    fn menuKey(self: *App, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        if (!k.pressed(key)) return;
        const m = &self.menu.?;
        const n = m.opts.len;
        if (k.ctrl(key, 'c')) {
            self.quit = true;
            return;
        }
        if (k.named(key, .escape) or k.char(key, 'q')) return self.dropMenu();
        if (k.char(key, 'j') or k.named(key, .down) or k.named(key, .tab)) {
            m.cursor = (m.cursor + 1) % n;
        } else if (k.char(key, 'k') or k.named(key, .up)) {
            m.cursor = (m.cursor + n - 1) % n;
        } else if (k.char(key, 'h') or k.named(key, .left)) {
            m.side = .left;
        } else if (k.char(key, 'l') or k.named(key, .right)) {
            m.side = .right;
        } else if (k.named(key, .enter) or k.ctrl(key, @backingInt(term.Input.NamedKey.enter))) {
            return self.pick(m.opts.items[m.cursor]);
        } else if (key.codepoint >= '1' and key.codepoint < '1' + n and !key.mods.ctrl and !key.mods.alt) {
            return self.pick(m.opts.items[key.codepoint - '1']);
        }
    }

    fn pick(self: *App, option: split.Option) !void {
        const m = self.menu.?;
        defer self.dropMenu();
        const ag = self.model.find(m.agent) orelse return self.say("the agent is gone", .{});
        return self.openOption(option, ag, m.side);
    }

    /// One of the split menu's options, from the menu or the tree.
    fn openOption(self: *App, option: split.Option, ag: *const model_mod.Agent, side: split.Side) !void {
        // Host mode: panes of their own (host.zig), never this pane's children.
        if (self.host) |h| switch (option) {
            .agent_view => return h.openAgent(ag.id),
            .shell => return h.openShell(self, ag.id),
            .take_over => {},
        };
        switch (option) {
            .agent_view => try self.openSplit(.agent_view, ag, side),
            .shell => try self.openSplit(.shell, ag, side),
            .take_over => try self.takeOver(ag.id, side, true),
        }
    }

    // ---- Take-over ---------------------------------------------------------

    /// The open take-over split of `agent`, if any.
    pub fn takeoverSplit(self: *const App, agent: []const u8) ?usize {
        for (self.splits.items, 0..) |sp, i| if (sp.kind == .take_over and !sp.exited and std.mem.eql(u8, sp.agent, agent)) return i;
        return null;
    }

    /// "Take over in <harness>": between turns at once; mid-turn the user
    /// is asked first (after this turn, interrupt now, cancel).
    /// `focus`: the split takes the focus when it opens; not when the turn's
    /// end started it, with no key pressed.
    pub fn takeOver(self: *App, agent: []const u8, side: split.Side, focus: bool) !void {
        const ag = self.model.find(agent) orelse return self.say("no agent {s}", .{agent});
        switch (ag.state) {
            .settled => {},
            .queued, .running, .needs_you => {
                const id = try self.gpa.dupe(u8, agent);
                self.dropAsk();
                self.ask = .{ .agent = id, .side = side };
                return;
            },
            .handed_over => {
                if (self.takeoverSplit(agent)) |i| return self.focus.set(fixed_areas + i);
                if (self.host) |h| if (h.takeoverPane(agent)) |p| return self.say("{s} is in pane {s}", .{ agent, p.pane });
                return self.say("{s} is in {s}'s own TUI elsewhere; T takes it back", .{ agent, ag.harness });
            },
            .failed, .archived => return self.say("take over: only between turns ({s} is {s})", .{ agent, ag.state.label() }),
        }
        if (!self.connected) return self.say("take over: the daemon is not connected", .{});
        if (self.host == null and self.splits.items.len >= split.max) return self.say("{d} splits are open; close one with {s} v x first", .{ split.max, self.leaderText() });
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        // Own mode: the split is this client's child, and `tui:<pid>` tells a
        // restarted daemon to leave the agent handed over while this process
        // lives. Host mode: a venomx pane, which outlives this process; its
        // ID comes after the command this call returns (`recordTakeoverPane`).
        var pane_buf: [32]u8 = undefined;
        const pane = if (self.host != null) "venomx" else try std.fmt.bufPrint(&pane_buf, "tui:{d}", .{std.c.getpid()});
        try self.request(.{ .takeover = .{ .agent = id, .side = side, .focus = focus } }, "agent.takeover", .{ .agent = agent, .pane = pane });
        self.say("handing {s} over to {s}", .{ agent, ag.harness });
    }

    fn dropAsk(self: *App) void {
        if (self.ask) |q| self.gpa.free(q.agent);
        self.ask = null;
    }

    fn dropWaiting(self: *App) void {
        if (self.waiting) |wt| self.gpa.free(wt.agent);
        self.waiting = null;
    }

    fn askKey(self: *App, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        if (!k.pressed(key)) return;
        const q = &self.ask.?;
        const n = split.Ask.choices.len;
        if (k.ctrl(key, 'c')) {
            self.quit = true;
            return;
        }
        if (k.named(key, .escape) or k.char(key, 'q')) return self.choose(.cancel);
        if (k.char(key, 'j') or k.named(key, .down) or k.named(key, .tab)) {
            q.cursor = (q.cursor + 1) % n;
        } else if (k.char(key, 'k') or k.named(key, .up)) {
            q.cursor = (q.cursor + n - 1) % n;
        } else if (k.named(key, .enter)) {
            return self.choose(split.Ask.choices[q.cursor]);
        } else if (key.codepoint >= '1' and key.codepoint < '1' + n and !key.mods.ctrl and !key.mods.alt) {
            return self.choose(split.Ask.choices[key.codepoint - '1']);
        }
    }

    fn choose(self: *App, choice: split.Ask.Choice) !void {
        const q = self.ask.?;
        self.ask = null;
        defer self.gpa.free(q.agent);
        switch (choice) {
            .cancel => self.say("take over cancelled; the agent keeps running", .{}),
            .after_turn => {
                try self.waitFor(q.agent, q.side);
                self.say("{s} goes to its harness's TUI after this turn", .{q.agent});
            },
            .interrupt => {
                try self.waitFor(q.agent, q.side);
                try self.request(.{ .action = try self.gpa.dupe(u8, "agent stop") }, "agent.stop", .{ .agent = q.agent });
                self.say("stopping {s}'s turn, then taking over", .{q.agent});
            },
        }
        try self.checkWaiting();
    }

    fn waitFor(self: *App, agent: []const u8, side: split.Side) !void {
        const id = try self.gpa.dupe(u8, agent);
        self.dropWaiting();
        self.waiting = .{ .agent = id, .side = side };
    }

    /// Starts a waiting take-over once its agent has settled; drops it if
    /// the agent went elsewhere (failed, archived, handed over).
    fn checkWaiting(self: *App) !void {
        const wt = self.waiting orelse return;
        const ag = self.model.find(wt.agent) orelse return self.dropWaiting();
        switch (ag.state) {
            .queued, .running, .needs_you => {},
            .settled => {
                self.waiting = null;
                defer self.gpa.free(wt.agent);
                try self.takeOver(wt.agent, wt.side, false);
            },
            .failed, .archived, .handed_over => {
                self.say("take over of {s} dropped: it is {s}", .{ wt.agent, ag.state.label() });
                self.dropWaiting();
            },
        }
    }

    /// `agent.takeover` answered: run its command in a split.
    fn openTakeover(self: *App, agent: []const u8, side: split.Side, focus: bool, ok: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const Result = struct { harness: []const u8 = "", argv: []const []const u8, cwd: []const u8, env: []const struct { name: []const u8, value: []const u8 } = &.{} };
        const r = std.json.parseFromValueLeaky(Result, a, ok, .{ .ignore_unknown_fields = true }) catch return self.say("take over: unexpected answer", .{});
        if (r.argv.len == 0) return self.say("take over: no command", .{});
        const exe = try split.findExe(a, self.env, r.argv[0]) orelse {
            try self.requestTakeback(agent);
            return self.say("take over: {s} is not in PATH; taking {s} back", .{ r.argv[0], agent });
        };
        if (self.host) |h| {
            const argv = try a.dupe([]const u8, r.argv);
            argv[0] = exe;
            const vars = try a.alloc(host_mod.EnvVar, r.env.len);
            for (r.env, vars) |e, *o| o.* = .{ .name = e.name, .value = e.value };
            return h.openTakeover(a, agent, argv, r.cwd, vars);
        }
        const env = try a.alloc([2][]const u8, r.env.len);
        for (r.env, env) |e, *o| o.* = .{ e.name, e.value };
        var sp: split.Split = .{ .kind = .take_over, .agent = try self.gpa.dupe(u8, agent), .side = side };
        errdefer sp.deinit(self.gpa);
        sp.cwd = try self.gpa.dupe(u8, r.cwd);
        sp.harness = try self.gpa.dupe(u8, r.harness);
        if (self.model.find(agent)) |ag| sp.handed = ag.state == .handed_over;
        sp.shell = split.Shell.start(self.gpa, .{ .shell = exe, .args = r.argv[1..], .extra_env = env, .cwd = r.cwd, .env = self.env, .agent = agent, .colors = self.shellColors() }, .{ .cols = 80, .rows = 24 }) catch |err| {
            if (err == error.OutOfMemory) return err;
            sp.deinit(self.gpa);
            try self.requestTakeback(agent);
            return self.say("take over: {s}; taking {s} back", .{ @errorName(err), agent });
        };
        const root = sp.shell.?.pid();
        // Input keeps the keys, even if a key asked for this before it was entered.
        const take_focus = focus and self.keyMode() != .input;
        if (take_focus) try self.addSplit(sp) else try self.addSplitBehind(sp);
        // Hooks from inside this split, and only those, may report for it.
        try self.request(.{ .action = try self.gpa.dupe(u8, "agent takeover-split") }, "agent.takeover_split", .{ .agent = agent, .pid = root });
        if (take_focus) return self.say("{s} has {s}; quit it, or T, to take it back", .{ r.harness, agent });
        self.say("{s} has {s}; from Normal, \\ focuses its split", .{ r.harness, agent });
    }

    /// `T`: closes the take-over split (which takes the agent back), or
    /// takes back an agent handed over elsewhere.
    pub fn takeBack(self: *App, agent: []const u8) !void {
        if (agent.len == 0) return self.say("no agent selected", .{});
        if (self.takeoverSplit(agent)) |i| return self.closeSplit(i);
        const ag = self.model.find(agent) orelse return self.say("no agent {s}", .{agent});
        if (ag.state != .handed_over) return self.say("{s} is not handed over", .{agent});
        // Its pane first: the take-back follows once the harness is gone.
        if (self.host) |h| if (h.takeoverPane(agent)) |p| {
            self.say("closing pane {s}, then taking {s} back", .{ p.pane, agent });
            return h.close(p);
        };
        try self.requestTakeback(agent);
        self.say("taking {s} back", .{agent});
    }

    /// Owes `agent.takeback` for `agent` until the daemon answers it.
    fn requestTakeback(self: *App, agent: []const u8) !void {
        for (self.owed.items) |o| if (std.mem.eql(u8, o, agent)) return self.sendTakeback(agent);
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        try self.owed.append(self.gpa, id);
        try self.sendTakeback(agent);
    }

    fn sendTakeback(self: *App, agent: []const u8) !void {
        if (!self.connected) return;
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        try self.request(.{ .takeback = id }, "agent.takeback", .{ .agent = agent });
    }

    /// Host mode: this client saw the take-over pane end (or it never ran), so
    /// the daemon need not be able to see that itself (`grants.unknown`).
    pub fn takebackPaneEnded(self: *App, agent: []const u8) !void {
        if (!self.connected) return;
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        try self.request(.{ .takeback = id }, "agent.takeback", .{ .agent = agent, .force = true });
    }

    /// Host mode: the take-over's pane is open; the daemon goes by its ID, and
    /// checks the process with venomx before its hooks count. In this order: it
    /// has to know the pane to ask about it.
    pub fn recordTakeoverPane(self: *App, agent: []const u8, pane: []const u8, pid: ?i64) !void {
        if (!self.connected) return;
        try self.request(.{ .action = try self.gpa.dupe(u8, "agent takeover-pane") }, "agent.takeover_pane", .{ .agent = agent, .pane = pane });
        if (pid) |root| try self.request(.{ .action = try self.gpa.dupe(u8, "agent takeover-split") }, "agent.takeover_split", .{ .agent = agent, .pid = root });
    }

    fn unowe(self: *App, agent: []const u8) void {
        for (self.owed.items, 0..) |o, i| if (std.mem.eql(u8, o, agent)) {
            self.gpa.free(o);
            _ = self.owed.orderedRemove(i);
            return;
        };
    }

    /// Take-back owed to the daemon (for the terminal loop's exit).
    pub fn owesTakeback(self: *const App) bool {
        return self.owed.items.len > 0;
    }

    /// Closes take-over splits whose agent is no longer handed over (taken
    /// back by another client or the CLI, or after a daemon restart took it
    /// back): their harness TUI must not keep writing to the conversation
    /// venom drives again. Nothing is sent: the agent is back already.
    fn syncTakeovers(self: *App) !void {
        var i: usize = 0;
        while (i < self.splits.items.len) {
            const sp = &self.splits.items[i];
            if (sp.kind != .take_over or sp.exited) {
                i += 1;
                continue;
            }
            const state = if (self.model.find(sp.agent)) |ag| ag.state else null;
            if (state == .handed_over) {
                sp.handed = true;
                i += 1;
                continue;
            }
            // Until the daemon's hand-over reached the model the split is
            // new; an agent the model does not know (yet) is left alone.
            if (!sp.handed or state == null) {
                i += 1;
                continue;
            }
            self.say("{s} was taken back elsewhere; its {s} split closed", .{ sp.agent, sp.harness });
            self.retireOrRemove(i);
        }
    }

    /// Closes every take-over split (their harness TUIs end) and owes
    /// their take-backs: the TUI is quitting.
    pub fn releaseTakeovers(self: *App) !void {
        var i = self.splits.items.len;
        while (i > 0) {
            i -= 1;
            if (self.splits.items[i].kind == .take_over and !self.splits.items[i].exited) try self.closeSplit(i);
        }
    }

    fn openSplit(self: *App, kind: split.Kind, ag: *const model_mod.Agent, side: split.Side) !void {
        if (self.splits.items.len >= split.max) return self.say("{d} splits are open; close one with {s} v x first", .{ split.max, self.leaderText() });
        var sp: split.Split = .{ .kind = kind, .agent = try self.gpa.dupe(u8, ag.id), .side = side };
        errdefer sp.deinit(self.gpa);
        if (kind == .shell) {
            sp.cwd = try self.gpa.dupe(u8, ag.cwd);
            // Sized on its first draw.
            sp.shell = split.Shell.start(self.gpa, .{ .shell = self.shell_path, .cwd = ag.cwd, .env = self.env, .agent = ag.id, .colors = self.shellColors() }, .{ .cols = 80, .rows = 24 }) catch |err| {
                if (err == error.OutOfMemory) return err;
                sp.deinit(self.gpa);
                return self.say("shell in worktree: {s}", .{@errorName(err)});
            };
        }
        if (kind == .agent_view) {
            sp.input = .init(self.gpa, .{ .prompt = "› " });
            // The agent's draft comes up in its box, unless a box has it.
            if (self.boxOf(ag.id) == null) if (self.drafts.fetchRemove(ag.id)) |entry| {
                defer {
                    self.gpa.free(entry.key);
                    self.gpa.free(entry.value);
                }
                try loadBox(&sp.input.?, entry.value);
            };
        }
        try self.addSplit(sp);
    }

    /// A split a key opened: it takes the focus.
    pub fn addSplit(self: *App, sp: split.Split) !void {
        try self.addSplitBehind(sp);
        self.focus.set(fixed_areas + self.splits.items.len - 1);
        // `leader v x` from Normal now means the newest, not one left before it.
        self.left_split = null;
    }

    /// A split no key opened: the focus, and so the mode, stay as they are.
    fn addSplitBehind(self: *App, sp: split.Split) !void {
        try self.splits.append(self.gpa, sp);
        self.focus.count = fixed_areas + self.splits.items.len;
        try self.requestSplitShow(&self.splits.items[self.splits.items.len - 1]);
    }

    /// Split `i`'s program is gone with no key pressed. Focused, the split
    /// stays as `[process exited]`: leaving it would put the next typed keys
    /// in Normal, where they can answer another agent's approval or quit.
    fn retireOrRemove(self: *App, i: usize) void {
        if (self.focusedSplit() == i) {
            const sp = &self.splits.items[i];
            if (sp.shell) |sh| sh.deinit();
            sp.shell = null;
            sp.exited = true;
            return;
        }
        var gone = self.removeSplit(i);
        gone.deinit(self.gpa);
    }

    /// Closes split `i`. Only the view goes (and the shell it ran): the
    /// agent keeps running, and no verb is sent. A take-over split is the
    /// exception: its harness TUI ends (SIGHUP, reaped), then
    /// `agent.takeback` gives the agent back to venom.
    pub fn closeSplit(self: *App, i: usize) !void {
        var sp = self.removeSplit(i);
        defer sp.deinit(self.gpa);
        if (sp.kind == .agent_view) try self.keepDraft(&sp);
        if (sp.kind != .take_over) return self.say("split closed; the agent keeps running", .{});
        try self.endTakeover(&sp);
    }

    /// Take back only once the harness TUI is gone (reaped), so venom is the
    /// conversation's only client again.
    fn endTakeover(self: *App, sp: *split.Split) !void {
        const ended = if (sp.shell) |sh| sh.end() else true;
        if (!ended) return self.say("{s} did not exit; {s} stays handed over (T tries again)", .{ sp.harness, sp.agent });
        try self.requestTakeback(sp.agent);
        self.say("taking {s} back from {s}", .{ sp.agent, sp.harness });
    }

    /// A closing agent view's text stays the agent's draft.
    fn keepDraft(self: *App, sp: *split.Split) !void {
        const text = if (sp.input) |*i| i.value() else "";
        if (text.len == 0) return;
        if (self.boxOf(sp.agent)) |b| return loadBox(b, text);
        try self.putDraft(sp.agent, text);
    }

    /// Takes split `i` out of the layout; the caller deinits it.
    fn removeSplit(self: *App, i: usize) split.Split {
        const sp = self.splits.orderedRemove(i);
        if (self.left_split) |l| self.left_split = if (l == i) null else if (l > i) l - 1 else l;
        const was = self.focus.index;
        self.focus.count = fixed_areas + self.splits.items.len;
        if (was == fixed_areas + i) {
            self.focus.set(@backingInt(Area.transcript));
        } else if (was > fixed_areas + i) self.focus.index = was - 1;
        return sp;
    }

    /// Reads what shells wrote; closes the split of a shell that exited.
    /// True when anything changed. The terminal loop calls it each turn.
    pub fn pumpShells(self: *App) !bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.splits.items.len) {
            const sh = self.splits.items[i].shell orelse {
                // An exited split the focus has moved off (a click): done.
                if (self.splits.items[i].exited and self.focusedSplit() != i) {
                    var gone = self.removeSplit(i);
                    gone.deinit(self.gpa);
                    changed = true;
                    continue;
                }
                i += 1;
                continue;
            };
            sh.flush() catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                self.say("shell: {s}", .{@errorName(err)});
            };
            if (self.sayCut(sh)) changed = true;
            var failed: ?anyerror = null;
            changed = (sh.pump() catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                failed = err;
                break :blk true;
            }) or changed;
            // A read that fails will fail again: it counts as an exit, or
            // the split stays open with nothing behind it.
            if (failed != null or sh.exited()) {
                try self.shellGone(i, failed);
                changed = true;
                continue;
            }
            i += 1;
        }
        return changed;
    }

    /// Split `i`'s command exited, or reading it failed with `failed`. Its
    /// process is ended if it is still there. The agent keeps running.
    fn shellGone(self: *App, i: usize, failed: ?anyerror) !void {
        if (self.splits.items[i].kind == .take_over) {
            try self.endTakeover(&self.splits.items[i]);
            self.retireOrRemove(i);
            // Why, in front of what closing it did.
            if (failed) |err| {
                const did = try self.gpa.dupe(u8, self.message.items);
                defer self.gpa.free(did);
                self.say("shell: {s}; {s}", .{ @errorName(err), did });
            }
            return;
        }
        self.retireOrRemove(i);
        if (failed) |err| return self.say("shell: {s}; its split closed, the agent keeps running", .{@errorName(err)});
        self.say("the shell exited; the agent keeps running", .{});
    }

    /// The PTY masters to poll, at most `split.max`.
    /// A shell's PTY has bytes waiting to be written: poll it for room.
    pub fn shellWantsWrite(self: *const App, fd: std.c.fd_t) bool {
        for (self.splits.items) |sp| if (sp.shell) |sh| {
            if (sh.pty.fd == fd) return sh.pending();
        };
        return false;
    }

    pub fn shellFds(self: *const App, out: *[split.max]std.c.fd_t) []std.c.fd_t {
        var n: usize = 0;
        for (self.splits.items) |sp| if (sp.shell) |sh| {
            out[n] = sh.pty.fd;
            n += 1;
        };
        return out[0..n];
    }

    // ---- Groups --------------------------------------------------------

    /// The agent list's rows for this frame (allocated in `frame`).
    pub fn buildRows(self: *App) !agent_list.Rows {
        return agent_list.build(self);
    }

    /// Keeps the list cursor on the selected agent when rows move. An agent
    /// that left the list gives way to its nearest listed ancestor, else to
    /// the first row, which also selects one when none is yet.
    pub fn syncCursor(self: *App, r: agent_list.Rows) !void {
        if (self.on_header) return;
        if (fan_out.keepPinned(self, r)) return;
        var id: []const u8 = self.selected.items;
        var steps = self.model.agents.items.len;
        while (id.len > 0) {
            if (r.indexOf(id)) |i| {
                try self.setSelected(id);
                self.list.cursor = i;
                return;
            }
            // Under a folded group: the cursor stays until it is moved.
            if (r.inFoldedGroup(id)) return;
            // Typing to an agent that left the list: the rest of the line must
            // not go to another one. Leaving the box moves the selection.
            if (self.inFocusedBox()) return;
            if (steps == 0) break;
            steps -= 1;
            id = (self.model.find(id) orelse break).parent;
        }
        for (r.rows, 0..) |row, i| if (row == .agent) {
            try self.setSelected(row.agent.id);
            self.list.cursor = i;
            return;
        };
    }

    /// Rows moved under the user's hand: `syncCursor` finds the agent again.
    fn listChanged(self: *App) void {
        self.on_header = false;
    }

    /// The list's fold of the group named `title`; `Archived` starts folded.
    pub fn groupFolded(self: *const App, title: []const u8) bool {
        const flipped = for (self.fold_flips.items) |f| {
            if (std.mem.eql(u8, f, title)) break true;
        } else false;
        return flipped != std.mem.eql(u8, title, agent_list.archived_title);
    }

    fn toggleGroup(self: *App, title: []const u8) !void {
        for (self.fold_flips.items, 0..) |f, i| if (std.mem.eql(u8, f, title)) {
            self.gpa.free(self.fold_flips.orderedRemove(i));
            return;
        };
        const copy = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(copy);
        try self.fold_flips.append(self.gpa, copy);
    }

    /// What the list's cursor or a fold changed.
    fn listActed(self: *App, r: agent_list.Rows, action: agent_list.Action) !void {
        switch (action) {
            .toggled => |i| try self.toggleGroup(r.rows[i].header.title),
            .moved => {},
        }
        const i = self.list.cursor;
        if (i >= r.rows.len) return;
        switch (r.rows[i]) {
            .header => self.on_header = true,
            .agent => |row| {
                self.on_header = false;
                self.fan.pinned = false;
                try self.setSelected(row.id);
            },
            .summary => {},
        }
    }

    /// A key while `/` has the focus: text narrows the list as it is typed,
    /// ⏎ keeps the filter and esc drops it.
    fn filterKey(self: *App, key: term.Input.Key) !void {
        const k = term.widgets.keys;
        if (k.ctrl(key, 'c')) {
            self.filter_input.clear();
            self.listChanged();
        } else if (k.named(key, .escape) or k.namedAny(key, .enter)) {
            // The filter stays on; esc on the list clears it.
            self.filtering = false;
        } else if (k.named(key, .up) or k.named(key, .down)) {
            const r = try self.buildRows();
            if (self.list.handleKey(r, key)) |action| try self.listActed(r, action);
        } else if (!k.namedAny(key, .tab)) {
            _ = try self.filter_input.handleKey(key);
            self.listChanged();
        }
    }

    pub fn age(self: *const App, a: std.mem.Allocator, at: i64) ![]const u8 {
        if (at <= 0 or self.now_ms <= 0) return "";
        const s = @divFloor(@max(self.now_ms - at, 0), 1000);
        if (s < 60) return std.fmt.allocPrint(a, "{d}s", .{s});
        if (s < 3600) return std.fmt.allocPrint(a, "{d}m", .{@divFloor(s, 60)});
        if (s < 48 * 3600) return std.fmt.allocPrint(a, "{d}h", .{@divFloor(s, 3600)});
        return std.fmt.allocPrint(a, "{d}d", .{@divFloor(s, 86400)});
    }

    /// `path` with `$HOME` shown as `~`.
    pub fn shortPath(self: *const App, a: std.mem.Allocator, path: []const u8) ![]const u8 {
        if (self.home.len > 1 and std.mem.startsWith(u8, path, self.home) and (path.len == self.home.len or path[self.home.len] == '/'))
            return std.fmt.allocPrint(a, "~{s}", .{path[self.home.len..]});
        return path;
    }
};
