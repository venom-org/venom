//! The new-agent dialog, opened with `n` (here) or
//! `leader a N` (pick the workspace):
//!
//! ```text
//! ╭ New agent ───────────────────────────────────── in venom-org ╮
//! │ Task       › Add hello capability bits to proto v2           │
//! │ Workspace  ◉ venom-org  ○ scratch                            │
//! │ Scope      ○ Whole workspace  ◉ Pick repos · 2  ○ One repo   │
//! │ Repos      ☑ venom-docs  ☑ venom-std  ☐ venom-term  +5       │
//! │ Isolation  ◉ Worktree per repo  ○ In place  ○ Sandbox copy   │
//! │ Harness    ◉ claude-code  ○ codex                            │
//! │ Mode       ◉ Ask  ○ Accept edits  ○ Plan                     │
//! │ Model      › opus                                            │
//! │ Issue      › 246                                             │
//! │ Branch     › 246-hello-caps                         │
//! │ Will create                                                  │
//! │ + ~/venom-org/venom-docs-246/   branch 246-hello-caps        │
//! │ $ venom agent spawn --workspace=/home/me/venom-org --repos=… │
//! │ esc Cancel  ⇧⏎ Run in background  ⌃⏎ Start in split  ⏎ Start │
//! ╰──────────────────────────────────────────────────────────────╯
//! ```
//!
//! **One set of params.** `Dialog.params` is what both the preview and the
//! start send, and `Dialog.args` is the same thing as a command line, so the
//! preview cannot drift from the spawn. "Will create" is drawn only from the
//! daemon's `agent.spawn` `dry_run` answer; nothing here guesses a path. What
//! the user has not chosen is left out, so the folder's `agents.default`, `agents.isolation` and
//! `agents.mode` apply, and the chips show what the daemon says they are. `⌃c`
//! on a choice goes back to that default; on a text field it empties it.
//!
//! **Start keys**, from any field: `⏎` starts the agent
//! and shows it in the main view, `⇧⏎` starts it with no view (it appears in
//! the list), and `⌃⏎` starts it and opens the split menu for it. A failed
//! start keeps the dialog and its text open, with the daemon's reason.
//!
//! **Paste.** Pasted text is never a command: in a text field it is text (a
//! pasted line break does not start the agent, a pasted tab does not change
//! field), and on any other field it is dropped.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const Surface = term.Surface;
const Region = term.Region;
const Value = std.json.Value;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Area = app_mod.Area;
const keys = @import("keys.zig");
const workspaces = @import("workspaces.zig");
const Workspace = workspaces.Workspace;
const Body = @import("proto").Response.Body;

pub const Field = enum {
    task,
    workspace,
    scope,
    repos,
    isolation,
    harness,
    mode,
    model,
    issue,
    branch,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .task => "Task",
            .workspace => "Workspace",
            .scope => "Scope",
            .repos => "Repos",
            .isolation => "Isolation",
            .harness => "Harness",
            .mode => "Mode",
            .model => "Model",
            .issue => "Issue",
            .branch => "Branch",
        };
    }

    fn isText(self: Field) bool {
        return self == .task or self == .model or self == .issue or self == .branch;
    }
};

pub const Scope = enum { whole, pick, one };

/// The `agent.spawn` `isolation` choices.
pub const Isolation = enum {
    worktree,
    in_place,
    copy,

    fn label(self: Isolation) []const u8 {
        return switch (self) {
            .worktree => "Worktree per repo",
            .in_place => "In place",
            .copy => "Sandbox copy",
        };
    }
};

/// The `agent.spawn` `mode` choices (`agents.mode`).
pub const Mode = enum {
    ask,
    accept_edits,
    plan,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .ask => "Ask",
            .accept_edits => "Accept edits",
            .plan => "Plan",
        };
    }
};

/// The three start keys.
pub const Start = enum {
    /// `⏎`: show it in the main view.
    show,
    /// `⇧⏎`: no view; it appears in the list.
    background,
    /// `⌃⏎`: open the split menu for it.
    split,

    pub fn of(k: term.Input.Key) Start {
        if (k.mods.ctrl) return .split;
        if (k.mods.shift) return .background;
        return .show;
    }
};

/// A started agent whose view opens once the model knows it: the answer can
/// come before its `agent.created` event.
pub const Follow = struct { agent: []u8, start: Start };

/// The `agent.spawn` params. Nulls are left out of the request.
pub const Params = struct {
    task: []const u8,
    workspace: []const u8,
    repos: ?[]const []const u8 = null,
    isolation: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    model: ?[]const u8 = null,
    issue: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    dry_run: ?bool = null,
};

/// One checkout of a `dry_run` answer.
pub const Checkout = struct { path: []const u8, branch: ?[]const u8, new_branch: bool };

/// A `dry_run` answer, as "Will create" needs it.
pub const Plan = struct {
    harness: []const u8 = "",
    isolation: []const u8 = "",
    /// The permission mode in effect; empty when the daemon did not say.
    permission_mode: []const u8 = "",
    cwd: []const u8 = "",
    checkouts: []const Checkout = &.{},

    /// Strings are copied into `a`.
    pub fn parse(a: std.mem.Allocator, ok: Value) !Plan {
        const o = if (ok == .object) ok.object else return .{};
        const dupe = struct {
            fn s(al: std.mem.Allocator, v: ?Value) ![]const u8 {
                const x = v orelse return "";
                return if (x == .string) al.dupe(u8, x.string) else "";
            }
        }.s;
        var out: std.ArrayList(Checkout) = .empty;
        if (o.get("checkouts")) |list| if (list == .array) for (list.array.items) |c| {
            if (c != .object) continue;
            const br = c.object.get("branch");
            const nb = c.object.get("new_branch");
            try out.append(a, .{
                .path = try dupe(a, c.object.get("path")),
                .branch = if (br != null and br.? == .string) try a.dupe(u8, br.?.string) else null,
                .new_branch = nb != null and nb.? == .bool and nb.?.bool,
            });
        };
        return .{ .harness = try dupe(a, o.get("harness")), .isolation = try dupe(a, o.get("isolation")), .permission_mode = try dupe(a, o.get("permission_mode")), .cwd = try dupe(a, o.get("cwd")), .checkouts = out.items };
    }

    /// The lines under "Will create", allocated in `a`.
    /// `short` is `App.shortPath` for the current frame's `$HOME`.
    pub fn lines(self: Plan, a: std.mem.Allocator, home: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (self.checkouts.len == 0) {
            try out.append(a, try std.fmt.allocPrint(a, "  nothing: the agent runs in place in {s}", .{try shorten(a, self.cwd, home)}));
            return out.items;
        }
        var width: usize = 0;
        for (self.checkouts) |c| width = @max(width, w.text.width(try shorten(a, c.path, home)));
        for (self.checkouts) |c| {
            const path = try shorten(a, c.path, home);
            const pad = try a.alloc(u8, width - w.text.width(path));
            @memset(pad, ' ');
            const what = if (c.branch) |b|
                try std.fmt.allocPrint(a, "branch {s}{s}", .{ b, if (c.new_branch) "" else " (existing)" })
            else
                "copy";
            try out.append(a, try std.fmt.allocPrint(a, "+ {s}/{s}   {s}", .{ path, pad, what }));
        }
        return out.items;
    }
};

fn shorten(a: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/'))
        return std.fmt.allocPrint(a, "~{s}", .{path[home.len..]});
    return path;
}

/// What the preview area says.
pub const Shown = union(enum) {
    /// A static reason there is no preview, or nothing yet.
    note: []const u8,
    plan: Plan,
    /// The daemon refused the dry run: the start would fail the same way.
    failed: struct { code: []const u8, message: []const u8, fix: []const u8 = "" },
};

pub const Dialog = struct {
    gpa: std.mem.Allocator,
    task: w.TextInput,
    model: w.TextInput,
    issue: w.TextInput,
    branch: w.TextInput,
    /// The workspace's path; empty until the list has one.
    workspace: std.ArrayList(u8) = .empty,
    /// The workspace to prefer when the list arrives ("new agent here").
    here: std.ArrayList(u8) = .empty,
    scope: Scope = .whole,
    /// Scope `pick`: the picked repos' names (owned).
    picked: std.ArrayList([]u8) = .empty,
    /// The repo the cursor is on: the one repo of scope `one`.
    repo_cursor: usize = 0,
    /// Null: the folder's `agents.isolation`.
    isolation: ?Isolation = null,
    /// Empty: the folder's `agents.default`.
    harness: std.ArrayList(u8) = .empty,
    /// Null: the folder's `agents.mode`.
    mode: ?Mode = null,
    field: Field = .task,
    arena: std.heap.ArenaAllocator,
    shown: Shown = .{ .note = "" },
    /// What the last good dry run said (for the chips the user has not set).
    effective_harness: std.ArrayList(u8) = .empty,
    effective_isolation: ?Isolation = null,
    effective_mode: ?Mode = null,
    /// The request id of the dry run in flight.
    preview_id: ?i64 = null,
    preview_again: bool = false,
    /// A start is in flight; keys wait for its answer.
    starting: ?Start = null,
    /// Why the last start failed (or cannot go yet).
    failure: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Dialog {
        return .{
            .gpa = gpa,
            .task = .init(gpa, .{ .prompt = "› ", .placeholder = "What should the agent do?" }),
            .model = .init(gpa, .{ .prompt = "› ", .placeholder = "Optional, like opus: the harness's default when empty" }),
            .issue = .init(gpa, .{ .prompt = "› ", .placeholder = "Optional, like 246 or #246: names its worktrees" }),
            .branch = .init(gpa, .{ .prompt = "› ", .placeholder = "Optional: the issue's branch; venom/<agent> when empty" }),
            .arena = .init(gpa),
        };
    }

    pub fn deinit(self: *Dialog) void {
        self.task.deinit();
        self.model.deinit();
        self.issue.deinit();
        self.branch.deinit();
        self.workspace.deinit(self.gpa);
        self.here.deinit(self.gpa);
        self.clearPicked();
        self.picked.deinit(self.gpa);
        self.harness.deinit(self.gpa);
        self.arena.deinit();
        self.effective_harness.deinit(self.gpa);
        self.failure.deinit(self.gpa);
        self.* = undefined;
    }

    fn clearPicked(self: *Dialog) void {
        for (self.picked.items) |p| self.gpa.free(p);
        self.picked.clearRetainingCapacity();
    }

    pub fn isPicked(self: *const Dialog, name: []const u8) bool {
        for (self.picked.items) |p| if (std.mem.eql(u8, p, name)) return true;
        return false;
    }

    fn togglePicked(self: *Dialog, name: []const u8) !void {
        for (self.picked.items, 0..) |p, i| if (std.mem.eql(u8, p, name)) {
            self.gpa.free(p);
            _ = self.picked.orderedRemove(i);
            return;
        };
        const copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(copy);
        try self.picked.append(self.gpa, copy);
    }

    /// The fields on show, in tab order.
    pub fn visible(self: *const Dialog, out: *[10]Field) []const Field {
        var n: usize = 0;
        for (std.enums.values(Field)) |f| {
            if (f == .repos and self.scope == .whole) continue;
            out[n] = f;
            n += 1;
        }
        return out[0..n];
    }

    fn move(self: *Dialog, delta: isize) void {
        var buf: [10]Field = undefined;
        const fields = self.visible(&buf);
        const at = std.mem.indexOfScalar(Field, fields, self.field) orelse 0;
        const n: isize = @intCast(fields.len);
        self.field = fields[@intCast(@mod(@as(isize, @intCast(at)) + delta, n))];
    }

    /// The repos in scope, in the workspace's order; null: the whole
    /// workspace (`repos` left out). A `pick` with none is an empty list,
    /// which is never sent: to the daemon "no repos" means all of them.
    pub fn repos(self: *const Dialog, a: std.mem.Allocator, ws: ?*const Workspace) !?[]const []const u8 {
        const list = (ws orelse return null).repos;
        switch (self.scope) {
            .whole => return null,
            .one => {
                if (list.len == 0) return null;
                const out = try a.alloc([]const u8, 1);
                out[0] = list[@min(self.repo_cursor, list.len - 1)].name;
                return out;
            },
            .pick => {
                var out: std.ArrayList([]const u8) = .empty;
                for (list) |r| if (self.isPicked(r.name)) try out.append(a, r.name);
                return out.items;
            },
        }
    }

    fn trimmed(box: *const w.TextInput) ?[]const u8 {
        const t = std.mem.trim(u8, box.value(), " \t\r\n");
        return if (t.len > 0) t else null;
    }

    /// The params for the chosen options; the one thing the preview and the
    /// start both send.
    pub fn params(self: *const Dialog, a: std.mem.Allocator, ws: ?*const Workspace, dry_run: bool) !Params {
        return .{
            .task = trimmed(&self.task) orelse preview_task,
            .workspace = self.workspace.items,
            .repos = try self.repos(a, ws),
            // A plain folder has nothing to isolate: it runs in place.
            .isolation = if (self.isolation != null and !isPlain(ws)) @tagName(self.isolation.?) else null,
            .harness = if (self.harness.items.len > 0) self.harness.items else null,
            .mode = if (self.mode) |m| @tagName(m) else null,
            .model = trimmed(&self.model),
            .issue = trimmed(&self.issue),
            .branch = trimmed(&self.branch),
            .dry_run = if (dry_run) true else null,
        };
    }

    /// The same options as `venom agent spawn` arguments, task excluded.
    pub fn args(self: *const Dialog, a: std.mem.Allocator, ws: ?*const Workspace) ![]const []const u8 {
        const p = try self.params(a, ws, false);
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(a, &.{ "agent", "spawn" });
        try out.append(a, try std.fmt.allocPrint(a, "--workspace={s}", .{p.workspace}));
        if (p.repos) |r| try out.append(a, try std.fmt.allocPrint(a, "--repos={f}", .{std.json.fmt(r, .{})}));
        if (p.isolation) |x| try out.append(a, try std.fmt.allocPrint(a, "--isolation={s}", .{x}));
        if (p.harness) |x| try out.append(a, try std.fmt.allocPrint(a, "--harness={s}", .{x}));
        if (p.mode) |x| try out.append(a, try std.fmt.allocPrint(a, "--mode={s}", .{x}));
        if (p.model) |x| try out.append(a, try std.fmt.allocPrint(a, "--model={s}", .{x}));
        if (p.issue) |x| try out.append(a, try std.fmt.allocPrint(a, "--issue={s}", .{x}));
        if (p.branch) |x| try out.append(a, try std.fmt.allocPrint(a, "--branch={s}", .{x}));
        return out.items;
    }

    fn setFailure(self: *Dialog, comptime fmt: []const u8, a: anytype) void {
        self.failure.clearRetainingCapacity();
        self.failure.print(self.gpa, fmt, a) catch {};
    }

    /// A dry run on its way no longer answers what is on show: its late
    /// answer is dropped, and the next one need not wait for it.
    fn forgetPreview(self: *Dialog) void {
        self.preview_id = null;
        self.preview_again = false;
    }

    fn setNote(self: *Dialog, note: []const u8) void {
        self.shown = .{ .note = note };
    }
};

/// A dry run with no task yet: the task only has to be non-empty for it, and
/// nothing in "Will create" depends on it.
const preview_task = "(preview)";

fn quoted(a: std.mem.Allocator, arg: []const u8) ![]const u8 {
    for (arg) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_=./:,~", c) == null) break;
    } else return arg;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (arg) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.items;
}

/// `$ venom agent spawn …`, the command the dialog stands for.
pub fn commandLine(a: std.mem.Allocator, d: *const Dialog, ws: ?*const Workspace) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "$ venom");
    for (try d.args(a, ws)) |arg| {
        try out.append(a, ' ');
        try out.appendSlice(a, try quoted(a, arg));
    }
    if (Dialog.trimmed(&d.task)) |task| {
        try out.append(a, ' ');
        try out.appendSlice(a, try quoted(a, try std.fmt.allocPrint(a, "--task={s}", .{task})));
    }
    return out.items;
}

// ---- Opening and the daemon's answers -----------------------------------------

/// Opens the dialog. `here`: the workspace to start in; `pick`: start on the
/// workspace field (`leader a N`) rather than the task.
pub fn open(app: *App, here: []const u8, pick: bool) !void {
    if (app.dialog) |*d| d.deinit();
    app.dialog = Dialog.init(app.gpa);
    const d = &app.dialog.?;
    try d.here.appendSlice(app.gpa, here);
    if (pick) d.field = .workspace;
    app.message.clearRetainingCapacity();
    try workspaces.requestHarnesses(app);
    try workspaces.requestList(app);
    if (app.panel.loaded) try onWorkspaces(app) else d.setNote("loading…");
}

pub fn close(app: *App) void {
    if (app.dialog) |*d| d.deinit();
    app.dialog = null;
}

/// The list changed: keep the dialog's workspace if it is still there.
pub fn onWorkspaces(app: *App) !void {
    const d = &(app.dialog orelse return);
    const items = app.panel.items;
    if (app.panel.find(d.workspace.items) == null) {
        const want = if (app.panel.find(d.here.items)) |h| h.path else if (items.len > 0) items[0].path else "";
        try setWorkspace(d, want);
    }
    try requestPreview(app);
}

fn setWorkspace(d: *Dialog, path: []const u8) !void {
    d.workspace.clearRetainingCapacity();
    try d.workspace.appendSlice(d.gpa, path);
    d.scope = .whole;
    d.clearPicked();
    d.repo_cursor = 0;
}

/// Asks the daemon what the chosen options would create; one at a time, and
/// the last options win.
pub fn requestPreview(app: *App) !void {
    const d = &(app.dialog orelse return);
    const ws = app.panel.find(d.workspace.items);
    if (ws == null) {
        d.forgetPreview();
        d.setNote(if (app.panel.loaded) "No workspace yet: esc, then w and + to add a folder." else "loading…");
        return;
    }
    const a = app.frame.allocator();
    if (d.scope == .pick) if (try d.repos(a, ws)) |r| if (r.len == 0) {
        d.forgetPreview();
        d.setNote("Pick at least one repo: space picks the one under the cursor.");
        return;
    };
    if (!app.connected) {
        d.forgetPreview();
        d.setNote("The daemon is not connected.");
        return;
    }
    if (d.preview_id != null) {
        d.preview_again = true;
        return;
    }
    d.preview_id = app.next_id;
    try app.request(.preview, "agent.spawn", try d.params(a, ws, true));
}

/// The failure's rows: its text, and the fix on a row of its own.
fn failureRows(d: *const Dialog) usize {
    if (d.failure.items.len == 0) return 0;
    return if (std.mem.indexOfScalar(u8, d.failure.items, 0x0a) != null) 2 else 1;
}

fn errorFix(data: ?Value) ?[]const u8 {
    const value = data orelse return null;
    if (value != .object) return null;
    const fix = value.object.get("fix") orelse return null;
    return if (fix == .string) fix.string else null;
}

pub fn onPreview(app: *App, id: i64, body: Body) !void {
    const d = &(app.dialog orelse return);
    // An answer for a dialog that has since closed.
    if (d.preview_id != id) return;
    d.preview_id = null;
    if (d.preview_again) {
        // Stale already: only the next answer is shown.
        d.preview_again = false;
        return requestPreview(app);
    }
    _ = d.arena.reset(.retain_capacity);
    const a = d.arena.allocator();
    switch (body) {
        .ok => |ok| {
            const plan = try Plan.parse(a, ok);
            d.shown = .{ .plan = plan };
            d.effective_harness.clearRetainingCapacity();
            try d.effective_harness.appendSlice(d.gpa, plan.harness);
            d.effective_isolation = std.meta.stringToEnum(Isolation, plan.isolation);
            d.effective_mode = std.meta.stringToEnum(Mode, plan.permission_mode);
        },
        .@"error" => |e| d.shown = .{ .failed = .{ .code = try a.dupe(u8, e.code), .message = try a.dupe(u8, e.message), .fix = if (errorFix(e.data)) |fix| try a.dupe(u8, try app.shortPath(a, fix)) else "" } },
        .item => {},
    }
}

/// The start's answer.
pub fn onSpawned(app: *App, which: Start, body: Body) !void {
    if (app.dialog) |*d| d.starting = null;
    switch (body) {
        .@"error" => |e| {
            // The dialog stays, with everything typed in it.
            if (app.dialog) |*d| {
                // The fix sits on its own row, after a newline.
                if (errorFix(e.data)) |fix| {
                    d.setFailure("{s}: {s}\nrun: {s}", .{ e.code, e.message, try app.shortPath(d.arena.allocator(), fix) });
                } else d.setFailure("{s}: {s}", .{ e.code, e.message });
            } else app.say("agent spawn: {s}", .{e.code});
        },
        .ok => |ok| {
            const agent = if (ok == .object) if (ok.object.get("agent")) |v| (if (v == .string) v.string else "") else "" else "";
            close(app);
            // `agent.created` does not carry where the agent runs.
            try app.requestAgents();
            if (which == .background) return app.say("{s} runs in the background; it is in the list", .{agent});
            if (app.follow) |f| app.gpa.free(f.agent);
            app.follow = .{ .agent = try app.gpa.dupe(u8, agent), .start = which };
            try followSpawn(app);
        },
        .item => {},
    }
}

/// Opens the view of a started agent once the model knows it.
pub fn followSpawn(app: *App) !void {
    const f = app.follow orelse return;
    if (app.model.find(f.agent) == null) return;
    app.follow = null;
    defer app.gpa.free(f.agent);
    // The model learned it with no key pressed: Input keeps its place.
    if (app.keyMode() == .input) return app.say("{s} started; it is in the list", .{f.agent});
    app.screen = .main;
    switch (f.start) {
        .show => {
            app.on_header = false;
            try app.setSelected(f.agent);
            app.focus.set(@backingInt(Area.transcript));
            app.scroll.follow();
        },
        .split => try app.openMenu(f.agent),
        .background => {},
    }
}

/// The connection went: what was asked of it will not be answered.
pub fn onDisconnected(app: *App) void {
    const d = &(app.dialog orelse return);
    d.preview_id = null;
    d.preview_again = false;
    d.setNote("The daemon is not connected.");
    if (d.starting != null) {
        d.starting = null;
        d.setFailure("the daemon went away; check the agent list before starting again", .{});
    }
}

// ---- Keys ------------------------------------------------------------------

fn input(d: *Dialog) ?*w.TextInput {
    return switch (d.field) {
        .task => &d.task,
        .model => &d.model,
        .issue => &d.issue,
        .branch => &d.branch,
        else => null,
    };
}

pub fn key(app: *App, k: term.Input.Key) !void {
    const kk = w.keys;
    const d = &app.dialog.?;
    if (!kk.pressed(k)) return;
    if (app.pasting) {
        const box = input(d) orelse return;
        if (keys.pastedBreak(k)) {
            try box.insert(" ");
        } else _ = try box.handleKey(k);
        return textChanged(app);
    }
    if (d.starting != null) {
        // Nothing is being typed, and the daemon may never answer.
        if (kk.ctrl(k, 'c')) app.quit = true;
        return;
    }
    // Input mode: ⌃c clears the field, and esc leaves.
    if (kk.ctrl(k, 'c')) {
        // A text field empties; a choice goes back to the folder's default.
        const box = input(d) orelse return resetChoice(app);
        box.clear();
        return textChanged(app);
    }
    if (kk.named(k, .escape)) return close(app);
    if (kk.namedAny(k, .enter) and !k.mods.alt) return start(app, Start.of(k));
    if (kk.namedAny(k, .tab) and !k.mods.ctrl and !k.mods.alt) return d.move(if (k.mods.shift) -1 else 1);
    if (kk.named(k, .up)) return d.move(-1);
    if (kk.named(k, .down)) return d.move(1);
    if (input(d)) |box| {
        if (try box.handleKey(k)) |action| if (action == .edited) try textChanged(app);
        return;
    }
    if (kk.char(k, 'j')) return d.move(1);
    if (kk.char(k, 'k')) return d.move(-1);
    if (kk.char(k, '?')) {
        app.help = true;
        return;
    }
    if (kk.char(k, 'h') or kk.named(k, .left)) return change(app, -1);
    if (kk.char(k, 'l') or kk.named(k, .right)) return change(app, 1);
    if (kk.char(k, ' ')) return pickRepo(app);
}

fn isPlain(ws: ?*const Workspace) bool {
    return ws != null and ws.?.repos.len == 0;
}

/// The chip that is on: what a plain folder must do, else the choice, else
/// the daemon's answer.
fn shownIsolation(d: *const Dialog, ws: ?*const Workspace) Isolation {
    if (isPlain(ws)) return .in_place;
    return d.isolation orelse d.effective_isolation orelse .worktree;
}

/// The mode chip that is on: the choice, else the daemon's answer.
fn shownMode(d: *const Dialog) Mode {
    return d.mode orelse d.effective_mode orelse .ask;
}

fn textChanged(app: *App) !void {
    const d = &app.dialog.?;
    d.failure.clearRetainingCapacity();
    // Nothing in "Will create" depends on the task.
    if (d.field != .task) try requestPreview(app);
}

/// ⌃c on a choice: isolation, harness and mode go back to what the folder's
/// config says (they are left out of the request again).
fn resetChoice(app: *App) !void {
    const d = &app.dialog.?;
    d.failure.clearRetainingCapacity();
    switch (d.field) {
        .isolation => d.isolation = null,
        .harness => d.harness.clearRetainingCapacity(),
        .mode => d.mode = null,
        else => return,
    }
    try requestPreview(app);
}

fn step(i: usize, n: usize, delta: isize) usize {
    return @intCast(@mod(@as(isize, @intCast(i)) + delta, @as(isize, @intCast(n))));
}

/// `h` / `l` on a field of options.
fn change(app: *App, delta: isize) !void {
    const d = &app.dialog.?;
    const ws = app.panel.find(d.workspace.items);
    d.failure.clearRetainingCapacity();
    switch (d.field) {
        .workspace => {
            const items = app.panel.items;
            if (items.len == 0) return;
            const at = for (items, 0..) |x, i| {
                if (std.mem.eql(u8, x.path, d.workspace.items)) break i;
            } else 0;
            try setWorkspace(d, items[step(at, items.len, delta)].path);
        },
        .scope => {
            // A plain folder has no repos to scope to.
            if (ws == null or ws.?.repos.len == 0) return;
            const modes = std.enums.values(Scope);
            d.scope = modes[step(@backingInt(d.scope), modes.len, delta)];
        },
        .repos => {
            const n = if (ws) |x| x.repos.len else 0;
            if (n == 0) return;
            d.repo_cursor = step(@min(d.repo_cursor, n - 1), n, delta);
            // In `pick` the cursor only moves; in `one` it is the choice.
            if (d.scope != .one) return;
        },
        .isolation => {
            // A plain folder only runs in place.
            if (isPlain(ws)) return;
            const modes = std.enums.values(Isolation);
            const cur = shownIsolation(d, ws);
            d.isolation = modes[step(@backingInt(cur), modes.len, delta)];
        },
        .harness => {
            const names = try harnessNames(app);
            if (names.len == 0) return;
            const cur = if (d.harness.items.len > 0) d.harness.items else d.effective_harness.items;
            const at = for (names, 0..) |n, i| {
                if (std.mem.eql(u8, n, cur)) break i;
            } else null;
            const next = if (at) |i| names[step(i, names.len, delta)] else names[0];
            const copy = try app.frame.allocator().dupe(u8, next);
            d.harness.clearRetainingCapacity();
            try d.harness.appendSlice(d.gpa, copy);
        },
        .mode => {
            const cur = shownMode(d);
            d.mode = std.enums.values(Mode)[step(@backingInt(cur), std.enums.values(Mode).len, delta)];
        },
        .task, .model, .issue, .branch => return,
    }
    try requestPreview(app);
}

fn pickRepo(app: *App) !void {
    const d = &app.dialog.?;
    if (d.field != .repos or d.scope != .pick) return;
    const ws = app.panel.find(d.workspace.items) orelse return;
    if (ws.repos.len == 0) return;
    d.failure.clearRetainingCapacity();
    try d.togglePicked(ws.repos[@min(d.repo_cursor, ws.repos.len - 1)].name);
    try requestPreview(app);
}

/// What the harness field offers: the daemon's enabled harnesses, and any a
/// test registered.
fn harnessNames(app: *App) ![]const []const u8 {
    const a = app.frame.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, app.panel.harnesses);
    try out.appendSlice(a, app.extra_harnesses);
    return out.items;
}

fn start(app: *App, which: Start) !void {
    const d = &app.dialog.?;
    const a = app.frame.allocator();
    if (!app.connected) return d.setFailure("the daemon is not connected", .{});
    if (Dialog.trimmed(&d.task) == null) {
        d.field = .task;
        return d.setFailure("write a task first", .{});
    }
    const ws = app.panel.find(d.workspace.items) orelse return d.setFailure("no workspace yet: esc, then w and + to add a folder", .{});
    if (try d.repos(a, ws)) |r| if (r.len == 0) {
        d.field = .repos;
        return d.setFailure("pick at least one repo, or scope the whole workspace", .{});
    };
    d.failure.clearRetainingCapacity();
    d.starting = which;
    try app.request(.{ .spawn = which }, "agent.spawn", try d.params(a, ws, false));
}

// ---- Drawing ---------------------------------------------------------------

const Chip = struct { label: []const u8, on: bool };

/// A row of choices; a glyph tells which are on, so colour is never alone.
/// Past the width: a window around the cursor, and `+N` for the rest.
fn chips(app: *App, surface: *Surface, a: std.mem.Allocator, x: u16, y: u16, room: u16, items: []const Chip, cursor: ?usize, focused: bool, glyphs: [2][]const u8) !void {
    const theme = &app.theme;
    const widths = try a.alloc(u16, items.len);
    for (items, widths) |c, *cw| cw.* = @intCast(@min(w.text.width(c.label) + 2, room));
    var first: usize = 0;
    if (cursor) |c| {
        const upto = @min(c, items.len -| 1);
        while (first < upto) : (first += 1) {
            var used: usize = 4; // room for `+N`
            for (widths[first .. upto + 1]) |cw| used += cw + 2;
            if (used <= room) break;
        }
    }
    var cx = x;
    const right = x + room;
    for (items[first..], widths[first..], first..) |c, cw, i| {
        const last = i + 1 == items.len;
        if (cx + cw + (if (last) @as(u16, 0) else 4) > right) {
            _ = try w.text.drawText(surface, cx, y, right -| cx, try std.fmt.allocPrint(a, "+{d}", .{items.len - i}), .muted, theme, .{});
            return;
        }
        const here = focused and cursor != null and cursor.? == i;
        const label = try std.fmt.allocPrint(a, "{s} {s}", .{ if (c.on) glyphs[0] else glyphs[1], c.label });
        _ = try w.text.drawText(surface, cx, y, cw, label, if (c.on) .accent else .muted, theme, .{ .ellipsis = true, .overlay = .{ .bold = c.on, .reverse = here } });
        cx += cw + 2;
    }
}

const radio = [2][]const u8{ "◉", "○" };
const check = [2][]const u8{ "☑", "☐" };
const label_w = 11;

pub fn draw(app: *App, surface: *Surface, main: Region) !void {
    const a = app.frame.allocator();
    const theme = &app.theme;
    const d = &app.dialog.?;
    const ws = app.panel.find(d.workspace.items);
    surface.setCursor(null);

    const plan_lines: []const []const u8 = switch (d.shown) {
        .plan => |p| try p.lines(a, app.home),
        .note => |n| blk: {
            const one = try a.alloc([]const u8, 1);
            one[0] = n;
            break :blk one;
        },
        .failed => |f| blk: {
            const one = try a.alloc([]const u8, if (f.fix.len > 0) 2 else 1);
            one[0] = try std.fmt.allocPrint(a, "{s}: {s}", .{ f.code, f.message });
            if (f.fix.len > 0) one[1] = try std.fmt.allocPrint(a, "run: {s}", .{f.fix});
            break :blk one;
        },
    };
    var buf: [10]Field = undefined;
    const fields = d.visible(&buf);
    // Fields, the scope's sentence, "Will create" and its lines, the failure,
    // the command, the keys, and the border.
    const want: usize = fields.len + 1 + 1 + plan_lines.len + failureRows(d) + 1 + 1 + 2;
    const bw: u16 = @min(main.width -| 4, 100);
    const bh: u16 = @min(main.height, @as(u16, @intCast(@min(want, std.math.maxInt(u16)))));
    const region: Region = .{ .x = main.x + (main.width -| bw) / 2, .y = main.y + (main.height -| bh) / 4, .width = bw, .height = bh };
    const badge = if (ws) |x| try std.fmt.allocPrint(a, "in {s}", .{x.name()}) else "";
    const inner = try w.box.draw(surface, region, theme, .{ .title = "New agent", .badge = badge, .focused = true, .clear = true });
    if (inner.width == 0 or inner.height == 0) return;

    var y = inner.y;
    const bottom = inner.y + inner.height;
    // The last two rows are the command and the keys, whatever else fits.
    const fields_end = bottom -| (2 + @as(u16, @intCast(failureRows(d))));
    const vx = inner.x + 1 + label_w;
    const room = inner.width -| (label_w + 2);
    for (fields) |f| {
        if (y >= fields_end) break;
        const focused = d.field == f;
        _ = try w.text.drawText(surface, inner.x + 1, y, label_w, f.label(), if (focused) .accent else .muted, theme, .{ .overlay = .{ .bold = focused } });
        const row: Region = .{ .x = vx, .y = y, .width = room, .height = 1 };
        switch (f) {
            .task => try d.task.draw(surface, row, theme, focused),
            .model => try d.model.draw(surface, row, theme, focused),
            .issue => try d.issue.draw(surface, row, theme, focused),
            .branch => try d.branch.draw(surface, row, theme, focused),
            .workspace => {
                const items = try a.alloc(Chip, app.panel.items.len);
                var cur: ?usize = null;
                for (app.panel.items, items, 0..) |x, *c, i| {
                    const on = std.mem.eql(u8, x.path, d.workspace.items);
                    if (on) cur = i;
                    c.* = .{ .label = x.name(), .on = on };
                }
                try chips(app, surface, a, vx, y, room, items, cur orelse 0, focused, radio);
            },
            .scope => {
                const n = d.picked.items.len;
                const none = ws == null or ws.?.repos.len == 0;
                const items = [_]Chip{
                    .{ .label = "Whole workspace", .on = d.scope == .whole },
                    .{ .label = if (d.scope == .pick) try std.fmt.allocPrint(a, "Pick repos · {d}", .{n}) else "Pick repos", .on = d.scope == .pick },
                    .{ .label = "One repo", .on = d.scope == .one },
                };
                try chips(app, surface, a, vx, y, room, if (none) items[0..1] else &items, @backingInt(d.scope), focused, radio);
            },
            .repos => {
                const list: []const workspaces.Repo = if (ws) |x| x.repos else &.{};
                const items = try a.alloc(Chip, list.len);
                const cur = @min(d.repo_cursor, list.len -| 1);
                for (list, items, 0..) |r, *c, i| c.* = .{ .label = r.label(), .on = if (d.scope == .one) i == cur else d.isPicked(r.name) };
                try chips(app, surface, a, vx, y, room, items, cur, focused, if (d.scope == .one) radio else check);
            },
            .isolation => {
                const cur = shownIsolation(d, ws);
                var items: [3]Chip = undefined;
                for (std.enums.values(Isolation), &items) |m, *c| c.* = .{ .label = m.label(), .on = m == cur };
                try chips(app, surface, a, vx, y, room, &items, @backingInt(cur), focused, radio);
            },
            .mode => {
                const cur = shownMode(d);
                var items: [3]Chip = undefined;
                for (std.enums.values(Mode), &items) |m, *c| c.* = .{ .label = m.label(), .on = m == cur };
                try chips(app, surface, a, vx, y, room, &items, @backingInt(cur), focused, radio);
            },
            .harness => {
                const cur = if (d.harness.items.len > 0) d.harness.items else d.effective_harness.items;
                var names: std.ArrayList([]const u8) = .empty;
                try names.appendSlice(a, try harnessNames(app));
                // The daemon's default, before `harness.list` has answered.
                var known = false;
                for (names.items) |n| known = known or std.mem.eql(u8, n, cur);
                if (!known and cur.len > 0) try names.append(a, cur);
                const items = try a.alloc(Chip, names.items.len);
                var at: usize = 0;
                for (names.items, items, 0..) |n, *c, i| {
                    const on = std.mem.eql(u8, n, cur);
                    if (on) at = i;
                    c.* = .{ .label = n, .on = on };
                }
                if (items.len == 0) {
                    _ = try w.text.drawText(surface, vx, y, room, "the folder's default", .muted, theme, .{});
                } else try chips(app, surface, a, vx, y, room, items, at, focused, radio);
            },
        }
        y += 1;
    }

    if (y < fields_end) {
        // Where it really starts: one checkout moves it there.
        const start_dir = if (d.shown == .plan and d.shown.plan.cwd.len > 0) d.shown.plan.cwd else if (ws) |x| x.path else "";
        const where = try app.shortPath(a, start_dir);
        const sentence = if (ws != null and ws.?.repos.len == 0)
            try std.fmt.allocPrint(a, "A plain folder: the agent runs in place in {s}.", .{where})
        else if (d.scope == .whole)
            try std.fmt.allocPrint(a, "The agent starts at {s}, with every repo in scope.", .{where})
        else
            try std.fmt.allocPrint(a, "The agent starts at {s} and asks before writing elsewhere (best effort).", .{where});
        _ = try w.text.drawText(surface, vx, y, room, sentence, .faint, theme, .{ .ellipsis = true });
        y += 1;
    }
    if (y < fields_end) {
        _ = try w.text.drawText(surface, inner.x + 1, y, inner.width -| 2, "Will create", .muted, theme, .{ .overlay = .{ .bold = true } });
        y += 1;
    }
    const role: w.Role = if (d.shown == .failed) .err else if (d.shown == .note) .muted else .secondary;
    // Out of rows: the last one says what did not fit.
    const rows_left: usize = fields_end -| y;
    const cut = plan_lines.len > rows_left;
    const fit = if (cut) rows_left -| 1 else plan_lines.len;
    for (plan_lines[0..fit]) |line| {
        _ = try w.text.drawText(surface, inner.x + 1, y, inner.width -| 2, line, role, theme, .{ .ellipsis = true });
        y += 1;
    }
    if (cut and rows_left > 0) {
        _ = try w.text.drawText(surface, inner.x + 1, y, inner.width -| 2, try std.fmt.allocPrint(a, "… and {d} more", .{plan_lines.len - fit}), .muted, theme, .{});
    }
    var rows = std.mem.splitScalar(u8, d.failure.items, '\n');
    var fy = fields_end;
    while (d.failure.items.len > 0) : (fy += 1) {
        const row = rows.next() orelse break;
        _ = try w.text.drawText(surface, inner.x + 1, fy, inner.width -| 2, row, .err, theme, .{ .ellipsis = true });
    }
    if (inner.height >= 2) _ = try w.text.drawText(surface, inner.x + 1, bottom - 2, inner.width -| 2, try commandLine(a, d, ws), .faint, theme, .{ .ellipsis = true });
    const hint = if (d.starting != null) "starting…" else "esc Cancel  ⇧⏎ Run in background  ⌃⏎ Start in split  ⏎ Start";
    _ = try w.text.drawText(surface, inner.x + 1, bottom - 1, inner.width -| 2, hint, .accent, theme, .{ .ellipsis = true });
}
