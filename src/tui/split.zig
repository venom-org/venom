//! Own-mode splits: with `ui.chrome = own`
//! venom draws a split itself,
//! side by side with the main view. The user's words and keys are the same
//! as in host mode (venomx panes, host.zig): `⌃⏎` or `\` opens the split
//! menu for an agent, `leader v x` closes a split. A split is only a view: closing
//! one, or its shell exiting, never stops or touches the agent.
//!
//! - **Agent view** (default): venom's view of that agent, from its own
//!   `agent.show` (a second `Detail`, refreshed by the agent's events):
//!   transcript with inline attention, and the input box. `⇥` goes
//!   from the transcript to the box, esc back.
//! - **Shell in worktree**: `$SHELL` in a PTY in the agent's folder (its
//!   worktree, or the folder it runs in in place), drawn with venom-term's
//!   `Vt` and `VtView`.
//! - **Take over in `<harness>`**: offered only when the harness's adapter
//!   provides resume (`resume_tui`). Between turns,
//!   `agent.takeover` hands the agent over and returns the harness's resume
//!   command, which runs in a PTY split like the shell. Mid-turn the TUI
//!   asks first (`Ask`). When the command
//!   exits, or on `T` / `leader v x`, the split closes and `agent.takeback` imports
//!   what ran there.
const std = @import("std");
const transcript = @import("transcript.zig");
const term = @import("venom-term");
const w = term.widgets;
const model = @import("model.zig");
const pty = @import("pty.zig");
const process = @import("../harness/process.zig");

/// At most this many splits are open beside the main view.
pub const max = 2;

/// Where a split opens: left or right of the main view (`h` / `l`).
pub const Side = enum { left, right };

pub const Option = enum {
    agent_view,
    shell,
    take_over,

    pub fn title(self: Option, a: std.mem.Allocator, harness: []const u8) ![]const u8 {
        return switch (self) {
            .agent_view => "Agent view",
            .shell => "Shell in worktree",
            .take_over => std.fmt.allocPrint(a, "Take over in {s}", .{harness}),
        };
    }

    /// The split menu's second line.
    pub fn description(self: Option, a: std.mem.Allocator, harness: []const u8, folder: []const u8) ![]const u8 {
        return switch (self) {
            .agent_view => "This agent's conversation, tool calls and approvals.",
            .shell => std.fmt.allocPrint(a, "A plain shell in {s}/. The agent keeps running.", .{folder}),
            .take_over => std.fmt.allocPrint(a, "Opens {s}'s own interface on this conversation. venom steps back until you quit it.", .{harness}),
        };
    }
};

/// The options the menu offers, in order. Unavailable ones are left out, not greyed.
pub const Options = struct {
    items: [3]Option = undefined,
    len: usize = 0,

    pub fn slice(self: *const Options) []const Option {
        return self.items[0..self.len];
    }

    pub fn has(self: *const Options, o: Option) bool {
        return std.mem.indexOfScalar(Option, self.slice(), o) != null;
    }
};

/// `resumes`: the harness's adapter provides resume (a take-over command).
pub fn options(agent: *const model.Agent, resumes: bool) Options {
    var out: Options = .{};
    out.items[out.len] = .agent_view;
    out.len += 1;
    // A worktree, a copy or the folder it runs in in place: every agent
    // has one, but an agent the TUI knows no folder of yet gets no shell.
    if (agent.cwd.len > 0 and std.fs.path.isAbsolute(agent.cwd)) {
        out.items[out.len] = .shell;
        out.len += 1;
    }
    if (resumes) {
        out.items[out.len] = .take_over;
        out.len += 1;
    }
    return out;
}

/// The open menu, for one agent.
pub const Menu = struct {
    agent: []u8,
    opts: Options,
    cursor: usize = 0,
    side: Side = .right,
};

/// `$SHELL` in a PTY, and the terminal state it draws into.
pub const Shell = struct {
    gpa: std.mem.Allocator,
    pty: pty.Pty,
    vt: term.Vt,
    view: term.VtView = .{},
    size: pty.Size,
    /// The paste in progress is wrapped in bracketed-paste markers.
    bracketed: bool = false,
    /// The last pasted byte was CR (a CRLF can straddle two reads).
    last_cr: bool = false,
    /// Paste bytes the PTY has not taken yet, from `paste_head`: its start
    /// marker, its text, its end marker. The UI loop never waits for a PTY:
    /// `flush` writes what fits, and `App.pumpShells` calls it each turn.
    paste_q: std.ArrayList(u8) = .empty,
    paste_head: usize = 0,
    /// How much of the start marker is still at the front of `paste_q`.
    marker_left: usize = 0,
    /// `paste_q` was started with markers, so it owes an end marker.
    q_bracketed: bool = false,
    /// The paste was cut: its remaining text is dropped.
    cut: bool = false,
    /// Text the PTY took of the paste being written.
    paste_sent: usize = 0,
    /// A cut the user has not been told about (`takeCut`).
    cut_notice: ?Cut = null,
    stall_at: i64 = 0,
    give_up_at: i64 = 0,
    paste_stall_ms: i64 = 5_000,
    paste_total_ms: i64 = 60_000,
    /// Keys and terminal answers the PTY has not taken yet. They go after
    /// any paste, so they can't land inside it.
    out_q: std.ArrayList(u8) = .empty,
    out_head: usize = 0,
    out_max: usize = 64 * 1024,

    pub const Reason = enum {
        stalled,
        timed_out,
        too_long,

        pub fn text(self: Reason) []const u8 {
            return switch (self) {
                .stalled => "the shell stopped reading",
                .timed_out => "it took too long",
                .too_long => "it is too long",
            };
        }
    };
    pub const Cut = struct { reason: Reason, sent: usize };

    /// More paste than this waiting for the PTY is cut, not buffered.
    pub const paste_max = 16 * 1024 * 1024;

    pub const Launch = struct {
        /// An absolute path (the caller resolved `$SHELL`, or the take-over
        /// command's `argv[0]` with `findExe`).
        shell: []const u8,
        /// Arguments after the program (the take-over command's argv[1..]).
        args: []const []const u8 = &.{},
        /// Set on top of the inherited environment (the take-over's env).
        extra_env: []const [2][]const u8 = &.{},
        cwd: []const u8,
        /// The environment the shell inherits; TERM is set on top.
        env: ?*const std.process.Environ.Map = null,
        /// Set as `VENOM_AGENT`, so scripts in the shell know the agent.
        agent: []const u8,
        /// What OSC 10/11 queries answer: the colours the shell is drawn on.
        colors: term.Vt.QueryColors = .{},
    };

    pub fn start(gpa: std.mem.Allocator, launch: Launch, size: pty.Size) !*Shell {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try a.dupeSentinel(u8, launch.shell, 0);
        const argv = try a.allocSentinel(?[*:0]const u8, 1 + launch.args.len, null);
        argv[0] = path;
        for (launch.args, argv[1..]) |arg, *slot| slot.* = try a.dupeSentinel(u8, arg, 0);
        var env: std.ArrayList(?[*:0]const u8) = .empty;
        if (launch.env) |map| {
            var it = map.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (std.mem.eql(u8, k, "TERM") or std.mem.eql(u8, k, "VENOM_AGENT") or std.mem.eql(u8, k, "PWD")) continue;
                // venom's own venomx identity is not this program's, and
                // neither are its credentials. What a
                // take-over needs arrives in `extra_env`.
                if (isVenomxIdentity(k) or @import("../harness/process.zig").credentialName(k)) continue;
                if (overridden(launch.extra_env, k)) continue;
                const entry = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, e.value_ptr.* }, 0);
                // venom's own tokens never reach a child.
                if (process.inheritedCredential(entry)) continue;
                try env.append(a, entry);
            }
        }
        try env.append(a, "TERM=xterm-256color");
        if (!overridden(launch.extra_env, "VENOM_AGENT")) try env.append(a, try std.fmt.allocPrintSentinel(a, "VENOM_AGENT={s}", .{launch.agent}, 0));
        try env.append(a, try std.fmt.allocPrintSentinel(a, "PWD={s}", .{launch.cwd}, 0));
        for (launch.extra_env) |e| try env.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ e[0], e[1] }, 0));
        const envp = try env.toOwnedSliceSentinel(a, null);

        const self = try gpa.create(Shell);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .pty = undefined, .vt = undefined, .size = size };
        self.vt = try term.Vt.init(gpa, .{ .cols = size.cols, .rows = size.rows, .scrollback_lines = 2000, .callbacks = .{ .context = self, .write_pty = writePty } });
        errdefer self.vt.deinit();
        self.vt.setQueryColors(launch.colors);
        self.pty = try pty.Pty.spawn(.{ .path = path, .argv = argv, .env = envp, .cwd = try a.dupeSentinel(u8, launch.cwd, 0) }, size);
        return self;
    }

    /// The terminal's answers to the shell's queries (DA, DSR, …).
    fn writePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Shell = @ptrCast(@alignCast(ctx.?));
        self.send(bytes) catch {};
    }

    /// Reads what the shell wrote; true when the screen changed.
    pub fn pump(self: *Shell) !bool {
        var buf: [16 * 1024]u8 = undefined;
        var changed = false;
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            const n = try self.pty.read(&buf);
            if (n == 0) break;
            try self.vt.feed(buf[0..n]);
            changed = true;
        }
        return changed;
    }

    /// A key typed while the shell split has focus.
    pub fn key(self: *Shell, k: term.Input.Key) !void {
        if (k.action == .release) return;
        const bytes = try self.vt.encodeKey(self.gpa, k);
        defer self.gpa.free(bytes);
        if (bytes.len > 0) try self.send(bytes);
        self.view.follow();
    }

    /// A bracketed paste starts: wrapped for the shell if it asked for that
    /// (DECSET 2004), as a terminal would.
    pub fn pasteStart(self: *Shell) !void {
        // The mode as the shell last set it.
        _ = try self.pump();
        self.bracketed = (try self.vt.inputModes()).bracketed_paste;
        self.last_cr = false;
        self.cut = false;
        if (self.pasteLeft() == 0) {
            const now = pty.nowMs();
            self.paste_sent = 0;
            self.stall_at = now + self.paste_stall_ms;
            self.give_up_at = now + self.paste_total_ms;
            self.q_bracketed = self.bracketed;
            if (self.bracketed) self.marker_left = start_marker.len;
        }
        if (self.bracketed) try self.paste_q.appendSlice(self.gpa, start_marker);
        try self.flush();
    }

    /// Pasted bytes, queued as they are. Without the markers a line break
    /// is one CR, what the Enter key sends. After a cut they are dropped: a
    /// paste with a hole could run spliced lines.
    pub fn paste(self: *Shell, text: []const u8) !void {
        self.view.follow();
        if (self.cut) return;
        if (self.pasteLeft() + text.len > paste_max) {
            try self.cutPaste(.too_long);
            return self.flush();
        }
        try self.compact();
        if (self.bracketed) {
            try self.paste_q.appendSlice(self.gpa, text);
        } else {
            try self.paste_q.ensureUnusedCapacity(self.gpa, text.len);
            for (text) |b| {
                const after_cr = self.last_cr;
                self.last_cr = b == '\r';
                if (b != '\n') {
                    self.paste_q.appendAssumeCapacity(b);
                } else if (!after_cr) self.paste_q.appendAssumeCapacity('\r');
            }
        }
        try self.flush();
    }

    pub fn pasteEnd(self: *Shell) !void {
        // A cut already queued the end marker.
        if (self.bracketed and !self.cut) try self.paste_q.appendSlice(self.gpa, end_marker);
        self.bracketed = false;
        try self.flush();
    }

    const start_marker = "\x1b[200~";
    const end_marker = "\x1b[201~";

    fn pasteLeft(self: *const Shell) usize {
        return self.paste_q.items.len - self.paste_head;
    }

    /// Bytes are waiting for the PTY to take them.
    pub fn pending(self: *const Shell) bool {
        return self.pasteLeft() > 0 or self.out_q.items.len > self.out_head;
    }

    /// The cut to tell the user about, once.
    pub fn takeCut(self: *Shell) ?Cut {
        defer self.cut_notice = null;
        return self.cut_notice;
    }

    /// Drops the paste's remaining text. What is already started gets its
    /// end marker, so the shell is not left inside a paste. A start marker
    /// nothing of which was written goes too, with its end.
    fn cutPaste(self: *Shell, reason: Reason) !void {
        const rest = self.marker_left;
        const started = rest < start_marker.len;
        const keep_markers = self.q_bracketed and started;
        self.paste_q.clearRetainingCapacity();
        self.paste_head = 0;
        if (keep_markers) {
            try self.paste_q.appendSlice(self.gpa, start_marker[start_marker.len - rest ..]);
            try self.paste_q.appendSlice(self.gpa, end_marker);
        } else self.marker_left = 0;
        self.cut = true;
        self.cut_notice = .{ .reason = reason, .sent = self.paste_sent };
        // One more wait, for the marker alone.
        self.stall_at = pty.nowMs() + self.paste_stall_ms;
        self.give_up_at = self.stall_at;
    }

    /// Writes what the PTY takes now, and never waits. A paste that stops
    /// moving, or runs out of time, is cut; output from the child doesn't
    /// count as moving (`yes` never reads, and never stops writing).
    pub fn flush(self: *Shell) !void {
        errdefer {
            self.paste_q.clearRetainingCapacity();
            self.paste_head = 0;
            self.marker_left = 0;
            self.out_q.clearRetainingCapacity();
            self.out_head = 0;
        }
        while (self.pasteLeft() > 0) {
            const n = try self.pty.writeSome(self.paste_q.items[self.paste_head..]);
            if (n == 0) break;
            self.paste_head += n;
            const marker = @min(n, self.marker_left);
            self.marker_left -= marker;
            self.paste_sent += n - marker;
            self.stall_at = pty.nowMs() + self.paste_stall_ms;
        }
        if (self.pasteLeft() > 0) {
            const now = pty.nowMs();
            if (now >= self.stall_at or now >= self.give_up_at) {
                if (!self.cut) {
                    try self.cutPaste(if (now >= self.give_up_at) .timed_out else .stalled);
                } else {
                    // Not even the end marker fits: stop owing it.
                    self.paste_q.clearRetainingCapacity();
                    self.paste_head = 0;
                    self.marker_left = 0;
                }
            }
            if (self.pasteLeft() > 0) return;
        }
        self.paste_q.clearRetainingCapacity();
        self.paste_head = 0;
        while (self.out_q.items.len > self.out_head) {
            const n = try self.pty.writeSome(self.out_q.items[self.out_head..]);
            if (n == 0) return;
            self.out_head += n;
        }
        self.out_q.clearRetainingCapacity();
        self.out_head = 0;
    }

    /// Keys and terminal answers: behind anything still queued. Past
    /// `out_max` they are refused whole (a child that floods queries and
    /// never reads must not grow this without bound): a key says so, and a
    /// terminal answer is dropped.
    fn send(self: *Shell, bytes: []const u8) !void {
        try self.flush();
        if (self.out_q.items.len - self.out_head + bytes.len > self.out_max) return error.PtyFull;
        if (self.out_head >= self.out_max) {
            const left = self.out_q.items.len - self.out_head;
            std.mem.copyForwards(u8, self.out_q.items[0..left], self.out_q.items[self.out_head..]);
            self.out_q.items.len = left;
            self.out_head = 0;
        }
        try self.out_q.appendSlice(self.gpa, bytes);
        try self.flush();
    }

    /// Reclaims written bytes, so a long paste's queue stays bounded.
    fn compact(self: *Shell) !void {
        if (self.paste_head < 1024 * 1024) return;
        const left = self.pasteLeft();
        std.mem.copyForwards(u8, self.paste_q.items[0..left], self.paste_q.items[self.paste_head..]);
        self.paste_q.items.len = left;
        self.paste_head = 0;
    }

    pub fn resize(self: *Shell, size: pty.Size) !void {
        if (size.cols == 0 or size.rows == 0) return;
        if (size.cols == self.size.cols and size.rows == self.size.rows) return;
        try self.vt.resize(size.cols, size.rows);
        self.pty.resize(size);
        self.size = size;
    }

    /// Ends the child (SIGHUP to its session, SIGKILL after a grace) and
    /// reaps it; true once it is gone. `deinit` still frees the shell.
    pub fn end(self: *Shell) bool {
        self.pty.deinit();
        return self.pty.reaped;
    }

    pub fn exited(self: *Shell) bool {
        return self.pty.exited();
    }

    pub fn pid(self: *const Shell) std.c.pid_t {
        return self.pty.pid;
    }

    pub fn deinit(self: *Shell) void {
        self.pty.deinit();
        self.paste_q.deinit(self.gpa);
        self.out_q.deinit(self.gpa);
        self.vt.deinit();
        self.gpa.destroy(self);
    }
};

pub fn isVenomxIdentity(name: []const u8) bool {
    for ([_][]const u8{ "VENOMX_TOKEN", "VENOMX_PRINCIPAL", "VENOMX_PANE", "VENOMX_SOCKET" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn overridden(extra: []const [2][]const u8, name: []const u8) bool {
    for (extra) |e| if (std.mem.eql(u8, e[0], name)) return true;
    return false;
}

/// `take_over`: the harness's own TUI on the agent's conversation, in a
/// PTY like the shell.
pub const Kind = enum { agent_view, shell, take_over };

/// The mid-turn question before a take-over.
pub const Ask = struct {
    agent: []u8,
    side: Side,
    cursor: usize = 0,

    pub const Choice = enum {
        /// Wait for the turn to end, then take over (the default).
        after_turn,
        /// Stop the turn (`agent.stop`), then take over.
        interrupt,
        cancel,

        pub fn title(self: Choice) []const u8 {
            return switch (self) {
                .after_turn => "After this turn",
                .interrupt => "Interrupt now",
                .cancel => "Cancel",
            };
        }
        pub fn description(self: Choice) []const u8 {
            return switch (self) {
                .after_turn => "Take over as soon as the running turn ends.",
                .interrupt => "Stop the turn now, then take over.",
                .cancel => "Leave the agent with venom.",
            };
        }
    };
    pub const choices = [_]Choice{ .after_turn, .interrupt, .cancel };
};

/// `name` as an absolute executable: itself when it has a `/`, else the
/// first match in `PATH`; null when there is none.
pub fn findExe(a: std.mem.Allocator, env: ?*const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    if (name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return if (executable(a, name)) name else null;
    const path = if (env) |m| m.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin" else "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
        if (executable(a, full)) return full;
    }
    return null;
}

fn executable(a: std.mem.Allocator, p: []const u8) bool {
    const z = a.dupeSentinel(u8, p, 0) catch return false;
    return std.c.access(z, std.c.X_OK) == 0;
}

pub const Split = struct {
    kind: Kind,
    agent: []u8,
    side: Side,
    /// Agent view: the agent as its own `agent.show` last returned it.
    detail: model.Detail = .{},
    scroll: w.ScrollView = .{},
    /// Agent view: its rows and the user's choices.
    rows: transcript.View = .{},
    show_inflight: bool = false,
    show_again: bool = false,
    /// Agent view: its input box, holding the agent's draft unless the main
    /// view has this agent selected or an earlier split has it (`App.boxOf`).
    input: ?w.TextInput = null,
    /// Agent view: focus is on the box, not the transcript.
    in_box: bool = false,
    /// Agent view: where the box was last drawn (for clicks).
    box_area: term.Region = .{ .width = 0, .height = 0 },
    /// Shell in worktree, or the take-over's harness TUI.
    shell: ?*Shell = null,
    /// Take-over: the harness it runs (for the title).
    harness: []u8 = &.{},
    /// Take-over: the model has shown the agent `handed_over` since the
    /// split opened (so a later other state means it was taken back).
    handed: bool = false,
    /// Its program is gone but the split had the focus, so it stays as
    /// `[process exited]` until esc or `ui.keys.leave_terminal` (`shell` null).
    exited: bool = false,
    /// The folder the shell runs in.
    cwd: []u8 = &.{},
    /// Where it was last drawn (for clicks).
    area: term.Region = .{ .width = 0, .height = 0 },

    pub fn deinit(self: *Split, gpa: std.mem.Allocator) void {
        if (self.shell) |s| s.deinit();
        if (self.input) |*i| i.deinit();
        self.detail.deinit(gpa);
        self.scroll.deinit(gpa);
        self.rows.deinit(gpa);
        gpa.free(self.agent);
        gpa.free(self.cwd);
        gpa.free(self.harness);
        self.* = undefined;
    }
};

/// `$SHELL` when it names an executable by absolute path, else `/bin/sh`.
pub fn resolveShell(env: ?*const std.process.Environ.Map) []const u8 {
    const fallback = "/bin/sh";
    const map = env orelse return fallback;
    const s = map.get("SHELL") orelse return fallback;
    if (!std.fs.path.isAbsolute(s) or s.len >= std.fs.max_path_bytes) return fallback;
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    if (std.c.access(&buf, std.c.X_OK) != 0) return fallback;
    return s;
}

test "options: take over only for an adapter with resume; a shell needs a folder" {
    const gpa = std.testing.allocator;
    var a: model.Agent = .{ .id = @constCast("a1"), .title = @constCast(""), .harness = @constCast("fake"), .workspace = @constCast("/w"), .cwd = @constCast("/w/venom-std-216"), .state = .running, .unread = false, .reason = @constCast("") };
    var o = options(&a, false);
    try std.testing.expectEqualSlices(Option, &.{ .agent_view, .shell }, o.slice());
    o = options(&a, true);
    try std.testing.expectEqualSlices(Option, &.{ .agent_view, .shell, .take_over }, o.slice());
    a.cwd = @constCast("");
    o = options(&a, false);
    try std.testing.expectEqualSlices(Option, &.{.agent_view}, o.slice());
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Take over in codex", try Option.take_over.title(arena.allocator(), "codex"));
}
