//! `ui.chrome = host`: venom's TUI as a
//! control pane in venomx, with agents in sibling panes.
//!
//! - The TUI stays pane content: it draws only inside its own pane, with its
//!   own bar on the pane's bottom row. It publishes no
//!   `venom.*` segments.
//! - The control pane is tagged `role = control`. `⏎` on an agent opens a
//!   sibling pane tagged `role = agent`, `group = <agent>`, `on_exit = keep`,
//!   running `venom agent view <agent> --solo=true`. Closing it never stops
//!   the agent. No verb moves anyone's focus.
//! - The split menu (`\\`) opens the same kind of
//!   pane next to the agent's others (`near` its `group`): the agent view, a
//!   shell in its folder, or the harness's own TUI. `venom.split` tells them
//!   apart: only the agent view takes attention. `venom agent split` opens the
//!   first two from a script, with the caller's venomx credential.
//! - Items in the inbox set `pane.attention` on every live pane of the agent,
//!   or on the control pane while it has none; cleared when answered anywhere.
//!   An `away` item is waiting in the harness's own TUI,
//!   so it marks the take-over pane, where it is answered.
//!   A `notify.post` needs `write` on `server:root`, which no pane has, so the
//!   daemon posts those (`escalation.zig`).
//! - A BEL goes into this pane like any program's. venomx turns it
//!   into `info` attention on a pane that has none, which
//!   nothing else would clear, so `sync` clears it when nothing blocks.
//! - The `venom` key table lives under sub-prefix `v`, with no `when`, so it
//!   works from any pane. `keys.prefixes` can move it.
//!   Its rows come from `keys.table`, so `ctrl+a v X` is `space X`. It opens the
//!   popups with the presets `venom.settings` and `venom.diff`, and its
//!   `pane.popup` bindings make the client mint and use a ticket.
//!   A pane can't get a ticket, so `space s` in the control pane draws the settings
//!   there; `ctrl+a v s` is what opens them as a popup.
//!
//! Authority. No pane holds daemon-wide write: only the
//! process outside venomx registers the table, with the owner credentials it
//! already holds, before it becomes `venomx attach`. It issues no venomx
//! principal, and the table has no expiry. A pane can't read venom's owner file,
//! so that process also binds a venom principal to the
//! control pane's process (`bindControl`). That leaves nothing in the pane's
//! environment to steal, nothing to expire, and the daemon keeps it across a
//! restart. The control pane binds its agent views the same way, and
//! only those processes hold the rights: a solo view's own shell or take-over is
//! its child, and is `unknown`. `read` is all a popup gets. On venomx, the control pane has a pane's default rights
//! (read everywhere; write and spawn on itself and the panes it creates), given
//! explicitly so venomx's grants.isolation doesn't widen them, and
//! lives as long as the pane. A process in a pane has its pane's rights by
//! ancestry, with or without a token, so the control
//! pane runs no shell or harness itself. Each split is a pane of its own, with
//! `read` and nothing else, and its process starts without venomx's identity
//! variables or a venom credential (`SplitParams`). It holds no right to drive
//! any pane, its own included; the human's attached client does the typing.
//!
//! venom never starts venomx: `resolve` only connects,
//! and with nothing to connect to the TUI runs in own mode.
//!
//! Like `App`, `Host` queues encoded requests and is fed responses, so tests
//! drive it with JSON; `pump` is the only part that touches the socket.
const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const chord = @import("venom-term").chrome.keys;
const config_mod = @import("../config.zig");
const App = @import("app.zig").App;
const Kind = @import("inbox.zig").Kind;
const Item = @import("inbox.zig").Item;
const keys = @import("keys.zig");
const split = @import("split.zig");
const usage_view = @import("usage_view.zig");
const process = @import("../harness/process.zig");
const nowMs = @import("link.zig").nowMs;
const cleanText = @import("../escalation.zig").cleanText;
const Value = std.json.Value;

pub const Setting = enum { auto, own, host };

/// `ui.chrome` as `config get` shows it: `.host`, `"host"` or `host`.
pub fn parseSetting(text: []const u8) Setting {
    const bare = std.mem.trimStart(u8, std.mem.trim(u8, text, "\""), ".");
    return std.meta.stringToEnum(Setting, bare) orelse .auto;
}

/// `config.get`'s answer for `ui.chrome`.
pub fn settingOf(ok: Value) Setting {
    if (ok != .object) return .auto;
    const content = ok.object.get("content") orelse return .auto;
    return if (content == .string) parseSetting(content.string) else .auto;
}

const Tag = struct { key: []const u8, value: []const u8 };
/// Every pane of venom's has it. `owner` would be the namespace of whoever
/// created the pane, which is not `venom` (see the top).
const product_tag: Tag = .{ .key = "product", .value = "venom" };
const selected_tag = "venom.selected";
const open_agent_tag = "venom.open_agent";
const open_inbox_tag = "venom.open_inbox";
const open_usage_tag = "venom.open_usage";
/// `agent_view`, `shell` or `take_over`; a pane without it is an agent view.
const split_tag = "venom.split";
pub const EnvVar = struct { name: []const u8, value: []const u8 };
const Grant = struct { right: []const u8, scope: []const u8 };

pub const Binding = struct { key: []const u8, label: []const u8, verb: []const u8, args: []const u8 };

/// The `venom` key table, active from every pane, made from the rows of
/// `keys.table` that can run outside venom. `args` is a
/// JSON object in a string, as `keys.register` takes it. Every principal with
/// `read` can see it (`keys.list`), so it never holds a token, and a popup is a
/// pane, refused the owner file: its views connect as
/// `unknown` and only read. Answering and saving happen in the control pane.
pub fn keyTable(a: std.mem.Allocator, exe: []const u8, socket: []const u8) !struct {
    name: []const u8 = "venom",
    prefix: []const u8 = "v",
    label: []const u8 = "venom",
    bindings: []const Binding,
    bind: []const u8 = "daemon",
} {
    const sock = try std.fmt.allocPrint(a, "--socket={s}", .{socket});
    const Args = struct { preset: []const u8, argv: []const []const u8, on_exit: []const u8 };
    var bindings: std.ArrayList(Binding) = .empty;
    for (&keys.table) |*b| {
        const outside = b.outside orelse continue;
        const args: Args = switch (outside) {
            .inbox => .{ .preset = "venom.settings", .on_exit = "remove", .argv = &.{ exe, "agent", "view", "--inbox=true", "--solo=true", sock, "--no-owner=true" } },
            .settings => .{ .preset = "venom.settings", .on_exit = "remove", .argv = &.{ exe, "agent", "view", "--settings=true", "--solo=true", sock, "--no-owner=true" } },
            .usage => .{ .preset = "venom.settings", .on_exit = "remove", .argv = &.{ exe, "agent", "view", "--usage=true", "--solo=true", sock, "--no-owner=true" } },
            // With no agent in the pane it says so, and stays until dismissed.
            .diff => .{ .preset = "venom.diff", .on_exit = "keep", .argv = &.{ exe, "agent", "diff", "--pane", "{pane}", sock } },
        };
        try bindings.append(a, .{ .key = b.keys, .label = b.label, .verb = "pane.popup", .args = try std.json.Stringify.valueAlloc(a, args, .{}) });
    }
    return .{ .bindings = bindings.items };
}

/// The attention level of a kind.
pub fn level(kind: Kind) []const u8 {
    return switch (kind) {
        .approval, .question, .plan => "urgent",
        .failed, .limit => "warn",
        .review => "info",
    };
}

fn levelRank(l: []const u8) u8 {
    return if (std.mem.eql(u8, l, "urgent")) 3 else if (std.mem.eql(u8, l, "warn")) 2 else 1;
}

/// A reason is at most 256 bytes.
const max_reason = 256;

/// `pane` should show this item, unless it already shows a more urgent one.
fn addWant(want: *std.StringArrayHashMapUnmanaged(Want), a: std.mem.Allocator, app: *const App, pane: []const u8, l: []const u8, it: *const Item) !void {
    const slot = try want.getOrPut(a, pane);
    if (slot.found_existing and levelRank(l) <= levelRank(slot.value_ptr.level)) return;
    const reports: ?u32 = if (!it.away) null else if (app.model.find(it.agent)) |ag| ag.away_reports else null;
    slot.value_ptr.* = .{ .level = l, .reason = try cleanText(a, it.reason, max_reason), .reports = reports };
}

/// One agent's sibling pane.
pub const AgentPane = struct {
    agent: []u8,
    pane: []u8,
    exited: bool = false,
    kind: split.Kind = .agent_view,
    /// Take-over: opened here, and the model has not shown it handed over yet.
    fresh: bool = false,
    /// `pane.kill` was sent; it is not sent twice.
    closing: bool = false,
    /// venomx refused the kill: an earlier control pane's, which this one has
    /// no `write` on. Only asking again (`T`, `leader v x`) tries, and says so again.
    refused_kill: bool = false,
};

/// venomx sets these in every pane and reserves the names,
/// so a split starts through `env`, which is gone once it has exec'd. The pid
/// stays the pane's root. Rights never depend on this: they come from ancestry.
const scrub = [_][]const u8{ "/usr/bin/env", "-u", "VENOMX_TOKEN", "-u", "VENOMX_PRINCIPAL", "-u", "VENOMX_PANE", "-u", "VENOMX_SOCKET" };

/// A view or a shell needs to look, not to act: no `write` or `spawn`, so
/// nothing in it can send to, kill or split any pane.
/// It may read what a process outside every pane may: the default `read *` of
/// venomx's `grants.unknown`, and nothing if that is anything else (`.{}` means
/// nothing, and a narrower profile is not worked out here).
const read_all = [_]Grant{.{ .right = "read", .scope = "*" }};

/// `config.get`'s answer for venomx's `grants.unknown`: is it the default?
pub fn unknownReadsAll(ok: Value) bool {
    if (ok != .object) return false;
    const content = ok.object.get("content") orelse return false;
    if (content != .string) return false;
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (content.string) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        // ZON's trailing commas say nothing.
        if (ch == '}' and n > 0 and buf[n - 1] == ',') n -= 1;
        if (n == buf.len) return false;
        buf[n] = ch;
        n += 1;
    }
    return std.mem.eql(u8, buf[0..n], ".{.{.right=.read,.scope=\"*\"}}");
}

fn splitGrants(reads: bool) []const Grant {
    return if (reads) &read_all else &.{};
}

/// `pane.split`'s parameters for a split: one shape for the control pane and
/// for `venom agent split`.
pub const SplitParams = struct {
    pane: []const u8,
    axis: []const u8,
    argv: []const []const u8,
    tags: []const Tag,
    near: ?[]const Tag,
    on_exit: []const u8,
    cwd: ?[]const u8,
    env: []const EnvVar,
    grants: []const Grant,

    pub const Spec = struct {
        kind: split.Kind,
        agent: []const u8,
        source: []const u8,
        axis: []const u8,
        near: ?[]const Tag,
        /// The program and its arguments.
        argv: []const []const u8,
        cwd: ?[]const u8,
        /// Added to `VENOM_AGENT`; venom's credentials are dropped from it.
        env: []const EnvVar = &.{},
        /// The agent view only: it is a venom client (`passable`).
        token: ?[]const u8 = null,
        /// `unknownReadsAll`.
        reads: bool,
    };

    pub fn of(a: std.mem.Allocator, s: Spec) !SplitParams {
        const tags = try a.dupe(Tag, &.{ .{ .key = "role", .value = "agent" }, .{ .key = "group", .value = s.agent }, product_tag, .{ .key = split_tag, .value = @tagName(s.kind) } });
        const argv = try a.alloc([]const u8, scrub.len + s.argv.len);
        @memcpy(argv[0..scrub.len], &scrub);
        @memcpy(argv[scrub.len..], s.argv);
        var env: std.ArrayList(EnvVar) = .empty;
        try env.append(a, .{ .name = "VENOM_AGENT", .value = s.agent });
        for (s.env) |e| if (!process.credentialName(e.name) and !std.mem.eql(u8, e.name, "VENOM_AGENT")) try env.append(a, e);
        if (s.kind == .agent_view) if (s.token) |t| try env.append(a, .{ .name = "VENOM_TOKEN", .value = t });
        return .{
            .pane = s.source,
            .axis = s.axis,
            .argv = argv,
            .tags = tags,
            .near = s.near,
            // A view that ends says why; a shell or harness that ends is done.
            .on_exit = if (s.kind == .agent_view) "keep" else "remove",
            .cwd = if (s.cwd) |c| (if (std.fs.path.isAbsolute(c)) c else null) else null,
            .env = env.items,
            .grants = splitGrants(s.reads),
        };
    }
};

/// The control pane's venomx rights, given explicitly so they don't depend on
/// venomx's `grants.isolation`: what `grants.interactive`
/// gives by default, read everywhere and write and spawn on `self`.
const venomx_control_grants: []const Grant = &.{ .{ .right = "read", .scope = "*" }, .{ .right = "write", .scope = "self" }, .{ .right = "spawn", .scope = "self" } };

/// What this client last told venomx about a pane's attention. `reports` is the
/// agent's: a report replaces an away item, even in the same words, and it has
/// to show again on a pane whose client cleared it by focusing it.
const Mark = struct { pane: []u8, level: []u8, reason: []u8, reports: u32 = 0 };

/// The attention a pane should have.
const Want = struct { level: []const u8, reason: []const u8, reports: ?u32 = null };

const Purpose = union(enum) {
    /// Failures are only worth a line in the status bar.
    plain: []const u8,
    /// `keys.list`: is the `venom` table still there?
    keys,
    /// `pane.tag` when the process exits; nobody is left to care.
    quiet,
    list,
    /// `pane.list` before opening this agent's pane; owned.
    open: []u8,
    /// `pane.remove` of its exited pane, then a new one; owned.
    replace: []u8,
    /// `pane.split` for this agent; owned.
    split: Opening,
    /// `pane.kill` of this pane; owned. The list says what it did.
    closed: []u8,
    /// `config.get` of `grants.unknown`.
    unknown_grants,
    /// `pane.attention` on this pane; owned.
    attention: []u8,
};

const Opening = struct { agent: []u8, kind: split.Kind };

const list_every_ms = 1000;
const keys_every_ms = 30_000;
/// Fits an 80-column bar with the workspace dropped (`statusBar`). The table is
/// gone after `keys.unregister` or a daemon restart, or was never there; an
/// outside start registers it.
pub const keys_notice = "no venom keys: run venom outside venomx";

pub const Host = struct {
    gpa: std.mem.Allocator,
    /// Null in tests.
    client: ?proto.Client = null,
    outbox: std.ArrayList([]u8) = .empty,
    pending: std.AutoHashMapUnmanaged(i64, Purpose) = .empty,
    next_id: i64 = 1,
    /// This process's own pane.
    control: []u8,
    /// venom's absolute path, and the arguments every pane needs to reach
    /// this daemon: panes get venomx's environment, not this process's.
    exe: []u8,
    socket: []u8,
    /// `VENOM_TOKEN`, handed on so a pane is the same venom client.
    token: ?[]u8 = null,
    /// A principal is bound to this process (`awaitBinding`), so it binds its
    /// agent views too; they have no token to be handed.
    bound: bool = false,
    panes: std.ArrayList(AgentPane) = .empty,
    marks: std.ArrayList(Mark) = .empty,
    /// The selection last put in the control pane's `venom.selected` tag.
    selected: std.ArrayList(u8) = .empty,
    listed_at: i64 = 0,
    keys_at: i64 = 0,
    /// venomx's `grants.unknown` is its default (`unknownReadsAll`). False
    /// until it answers: nothing is the safe thing to hand out.
    unknown_reads: bool = false,
    /// The key table was seen missing: the bar says so until it is back.
    keys_missing: bool = false,
    /// Agent panes this principal may not write: an earlier control pane's.
    /// Their attention goes to the control pane.
    foreign: std.ArrayList([]u8) = .empty,
    /// venomx refused this pane's principal (revoked, or its parent's token
    /// expired). Said once; nothing is sent after that.
    refused: bool = false,
    /// A BEL went into this pane since nothing last blocked (`noteBell`).
    rang: bool = false,

    pub const Options = struct { control: []const u8, exe: []const u8, socket: []const u8, token: ?[]const u8 = null, bound: bool = false };

    pub fn init(gpa: std.mem.Allocator, o: Options) !Host {
        return .{
            .gpa = gpa,
            .control = try gpa.dupe(u8, o.control),
            .exe = try gpa.dupe(u8, o.exe),
            .socket = try gpa.dupe(u8, o.socket),
            .token = if (o.token) |t| try gpa.dupe(u8, t) else null,
            .bound = o.bound,
        };
    }

    pub fn deinit(self: *Host) void {
        if (self.client) |*c| c.deinit();
        for (self.outbox.items) |l| self.gpa.free(l);
        self.outbox.deinit(self.gpa);
        var it = self.pending.valueIterator();
        while (it.next()) |p| self.freePurpose(p.*);
        self.pending.deinit(self.gpa);
        for (self.panes.items) |p| self.freePane(p);
        self.panes.deinit(self.gpa);
        for (self.marks.items) |m| self.freeMark(m);
        self.marks.deinit(self.gpa);
        self.selected.deinit(self.gpa);
        for (self.foreign.items) |f| self.gpa.free(f);
        self.foreign.deinit(self.gpa);
        self.gpa.free(self.control);
        self.gpa.free(self.exe);
        self.gpa.free(self.socket);
        if (self.token) |t| {
            std.crypto.secureZero(u8, t);
            self.gpa.free(t);
        }
        self.* = undefined;
    }

    fn freePurpose(self: *Host, p: Purpose) void {
        switch (p) {
            .open, .replace, .attention, .closed => |v| self.gpa.free(v),
            .split => |o| self.gpa.free(o.agent),
            .plain, .keys, .quiet, .list, .unknown_grants => {},
        }
    }

    fn freePane(self: *Host, p: AgentPane) void {
        self.gpa.free(p.agent);
        self.gpa.free(p.pane);
    }

    fn freeMark(self: *Host, m: Mark) void {
        self.gpa.free(m.pane);
        self.gpa.free(m.level);
        self.gpa.free(m.reason);
    }

    fn request(self: *Host, purpose: Purpose, verb: []const u8, params: anytype) !void {
        const id = self.next_id;
        self.next_id += 1;
        const line = try std.json.Stringify.valueAlloc(self.gpa, .{ .id = id, .verb = verb, .params = params }, .{ .emit_null_optional_fields = false });
        errdefer self.gpa.free(line);
        try self.outbox.append(self.gpa, line);
        errdefer _ = self.outbox.pop();
        try self.pending.put(self.gpa, id, purpose);
    }

    /// The first requests: who this pane is, and what is already there.
    pub fn begin(self: *Host) !void {
        try self.request(.{ .plain = "pane tag" }, "pane.tag", .{ .pane = self.control, .set = &[_]Tag{ .{ .key = "role", .value = "control" }, product_tag } });
        try self.requestList(.list);
        try self.requestKeys();
    }

    pub fn requestKeys(self: *Host) !void {
        self.keys_at = nowMs();
        try self.request(.keys, "keys.list", struct {}{});
        try self.request(.unknown_grants, "config.get", .{ .key = "grants.unknown" });
    }

    pub fn requestList(self: *Host, purpose: Purpose) !void {
        self.listed_at = nowMs();
        try self.request(purpose, "pane.list", struct {}{});
    }

    /// This agent's view: the pane `⏎` shows and attention lands on.
    fn paneOf(self: *const Host, agent: []const u8) ?*AgentPane {
        for (self.panes.items) |*p| if (p.kind == .agent_view and std.mem.eql(u8, p.agent, agent)) return p;
        return null;
    }

    /// The live pane running this agent's harness TUI.
    pub fn takeoverPane(self: *const Host, agent: []const u8) ?*AgentPane {
        for (self.panes.items) |*p| if (p.kind == .take_over and !p.exited and std.mem.eql(u8, p.agent, agent)) return p;
        return null;
    }

    fn hasLivePane(self: *const Host, agent: []const u8) bool {
        for (self.panes.items) |p| if (!p.exited and std.mem.eql(u8, p.agent, agent)) return true;
        return false;
    }

    fn isForeign(self: *const Host, pane: []const u8) bool {
        for (self.foreign.items) |f| if (std.mem.eql(u8, f, pane)) return true;
        return false;
    }

    fn dropPane(self: *Host, pane: []const u8) void {
        // Marks first: `pane` may be the entry's own slice, freed below.
        for (self.marks.items, 0..) |m, i| if (std.mem.eql(u8, m.pane, pane)) {
            self.freeMark(self.marks.orderedRemove(i));
            break;
        };
        for (self.panes.items, 0..) |p, i| if (std.mem.eql(u8, p.pane, pane)) {
            self.freePane(self.panes.orderedRemove(i));
            break;
        };
    }

    /// `⏎` on an agent: its pane if it has a live one, else a new one. The
    /// list comes first: a pane may be gone or exited since the last look.
    pub fn openAgent(self: *Host, agent: []const u8) !void {
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        try self.requestList(.{ .open = id });
    }

    fn split_(self: *Host, app: *App, agent: []const u8) !void {
        const ag = app.model.find(agent) orelse return app.say("no agent {s}", .{agent});
        const a = app.frame.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ self.exe, "agent", "view", try std.fmt.allocPrint(a, "--agent={s}", .{agent}), "--solo=true", try std.fmt.allocPrint(a, "--socket={s}", .{self.socket}) });
        if (self.bindsViews()) try argv.appendSlice(a, &await_binding_args);
        try self.requestSplit(a, .agent_view, agent, argv.items, ag.cwd, &.{});
    }

    fn bindsViews(self: *const Host) bool {
        return self.bound and self.token == null;
    }

    /// The split menu's "Shell in worktree". Each pick is a new shell.
    pub fn openShell(self: *Host, app: *App, agent: []const u8) !void {
        const ag = app.model.find(agent) orelse return app.say("no agent {s}", .{agent});
        try self.requestSplit(app.frame.allocator(), .shell, agent, &.{app.shell_path}, ag.cwd, &.{});
    }

    /// `agent.takeover` answered: its command runs in a pane. When that pane
    /// ends, `applyList` takes the agent back.
    pub fn openTakeover(self: *Host, a: std.mem.Allocator, agent: []const u8, argv: []const []const u8, cwd: []const u8, env: []const EnvVar) !void {
        try self.requestSplit(a, .take_over, agent, argv, cwd, env);
    }

    fn requestSplit(self: *Host, a: std.mem.Allocator, kind: split.Kind, agent: []const u8, argv: []const []const u8, cwd: []const u8, env: []const EnvVar) !void {
        // Next to the agent's other panes. Its first: beside the control pane
        // if nothing else is there, else stacked with the other agents
        // (venomx picks the largest; the target is the fallback).
        const near_agent = [_]Tag{.{ .key = "group", .value = agent }};
        const near_any = [_]Tag{.{ .key = "role", .value = "agent" }};
        const mine = self.hasLivePane(agent);
        const first = self.panes.items.len == 0;
        const params = try SplitParams.of(a, .{
            .kind = kind,
            .agent = agent,
            .source = self.control,
            .axis = if (first) "cols" else "rows",
            .near = if (mine) &near_agent else if (first) null else &near_any,
            .argv = argv,
            .cwd = cwd,
            .env = env,
            .token = self.token,
            .reads = self.unknown_reads,
        });
        const id = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(id);
        try self.request(.{ .split = .{ .agent = id, .kind = kind } }, "pane.split", params);
    }

    /// `leader v x` in the control pane: closes the agent's newest split. The agent
    /// keeps running, unless that split is its take-over, which takes it back.
    pub fn closeNewest(self: *Host, app: *App, agent: []const u8) !void {
        var i = self.panes.items.len;
        while (i > 0) {
            i -= 1;
            const p = &self.panes.items[i];
            if (p.exited or !std.mem.eql(u8, p.agent, agent)) continue;
            return self.close(p);
        }
        app.say("{s} has no split open", .{agent});
    }

    /// Ends a pane's process and removes the pane; answered once it is reaped.
    pub fn close(self: *Host, p: *AgentPane) !void {
        if (p.closing) return;
        p.closing = true;
        const id = try self.gpa.dupe(u8, p.pane);
        errdefer self.gpa.free(id);
        try self.request(.{ .closed = id }, "pane.kill", .{ .pane = id, .remove = true });
    }

    /// A take-over pane whose agent is no longer handed over (taken back by
    /// the CLI or another client, or by a daemon restart) must not keep writing
    /// to the conversation venom drives again.
    fn syncTakeovers(self: *Host, app: *App) !void {
        for (self.panes.items) |*p| {
            if (p.kind != .take_over or p.exited or p.closing or p.refused_kill) continue;
            const ag = app.model.find(p.agent) orelse continue;
            if (ag.state == .handed_over) {
                p.fresh = false;
            } else if (!p.fresh) {
                app.say("{s} was taken back elsewhere; closing pane {s}", .{ p.agent, p.pane });
                try self.close(p);
            }
        }
    }

    /// Brings venomx in line with the TUI: the selection tag (the diff key's
    /// target while the control pane has focus) and attention. Only changes
    /// are sent, so a pane whose client cleared its attention by focusing it
    /// stays clear until the reason changes.
    pub fn sync(self: *Host, app: *App) !void {
        try self.syncTakeovers(app);
        if (app.selected.items.len > 0 and !std.mem.eql(u8, app.selected.items, self.selected.items)) {
            self.selected.clearRetainingCapacity();
            try self.selected.appendSlice(self.gpa, app.selected.items);
            try self.request(.{ .plain = "pane tag" }, "pane.tag", .{ .pane = self.control, .set = &[_]Tag{.{ .key = selected_tag, .value = self.selected.items }} });
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // pane → the most urgent item; the inbox is in urgency order.
        var want: std.StringArrayHashMapUnmanaged(Want) = .empty;
        var homeless: usize = 0;
        var homeless_level: []const u8 = "info";
        var blocking = false;
        for (app.inbox.items.items) |*it| {
            if (app.isHidden(it)) continue;
            blocking = blocking or it.kind.blocking();
            const l = level(it.kind);
            var homed = false;
            // Waiting in the harness's own TUI: that pane is where it is answered.
            if (it.away) if (self.takeoverPane(it.agent)) |p| if (!self.isForeign(p.pane)) {
                homed = true;
                try addWant(&want, a, app, p.pane, l, it);
            };
            // Else any agent view of it: a shell shows no attention, and an
            // exited pane shows nothing.
            if (!homed) for (self.panes.items) |*p| {
                if (p.kind != .agent_view or p.exited or !std.mem.eql(u8, p.agent, it.agent) or self.isForeign(p.pane)) continue;
                homed = true;
                try addWant(&want, a, app, p.pane, l, it);
            };
            if (!homed and it.kind.blocking()) {
                // A review can wait; the list shows it.
                homeless += 1;
                if (levelRank(l) > levelRank(homeless_level)) homeless_level = l;
            }
        }
        if (homeless > 0) try want.put(a, self.control, .{ .level = homeless_level, .reason = try std.fmt.allocPrint(a, "{d} in venom's inbox", .{homeless}) });
        // What a BEL left on this pane, which no mark of ours knows about.
        if (self.rang and !blocking) {
            self.rang = false;
            if (!self.isMarked(self.control)) try self.clearAttention(self.control);
        }
        // Clear what is no longer wanted.
        var i: usize = 0;
        while (i < self.marks.items.len) {
            const m = self.marks.items[i];
            if (want.contains(m.pane)) {
                i += 1;
                continue;
            }
            try self.clearAttention(m.pane);
            self.freeMark(self.marks.orderedRemove(i));
        }
        var it = want.iterator();
        next: while (it.next()) |e| {
            for (self.marks.items) |*m| if (std.mem.eql(u8, m.pane, e.key_ptr.*)) {
                const replaced = if (e.value_ptr.reports) |n| n != m.reports else false;
                if (e.value_ptr.reports) |n| m.reports = n;
                if (!replaced and std.mem.eql(u8, m.level, e.value_ptr.level) and std.mem.eql(u8, m.reason, e.value_ptr.reason)) continue :next;
                self.gpa.free(m.level);
                self.gpa.free(m.reason);
                m.level = try self.gpa.dupe(u8, e.value_ptr.level);
                m.reason = try self.gpa.dupe(u8, e.value_ptr.reason);
                try self.sendAttention(m.pane, m.level, m.reason);
                continue :next;
            };
            const mark: Mark = .{ .pane = try self.gpa.dupe(u8, e.key_ptr.*), .level = try self.gpa.dupe(u8, e.value_ptr.level), .reason = try self.gpa.dupe(u8, e.value_ptr.reason), .reports = e.value_ptr.reports orelse 0 };
            try self.marks.append(self.gpa, mark);
            try self.sendAttention(mark.pane, mark.level, mark.reason);
        }
    }

    /// A BEL just went into this pane (the TUI's terminal loop).
    pub fn noteBell(self: *Host) void {
        self.rang = true;
    }

    fn isMarked(self: *const Host, pane: []const u8) bool {
        for (self.marks.items) |m| if (std.mem.eql(u8, m.pane, pane)) return true;
        return false;
    }

    fn clearAttention(self: *Host, pane: []const u8) !void {
        const id = try self.gpa.dupe(u8, pane);
        errdefer self.gpa.free(id);
        try self.request(.{ .attention = id }, "pane.attention", .{ .pane = id, .clear = true });
    }

    fn sendAttention(self: *Host, pane: []const u8, l: []const u8, reason: []const u8) !void {
        const id = try self.gpa.dupe(u8, pane);
        errdefer self.gpa.free(id);
        try self.request(.{ .attention = id }, "pane.attention", .{ .pane = pane, .level = l, .reason = reason });
    }

    /// Replaces the known panes with `pane.list`'s agent panes.
    fn applyList(self: *Host, app: *App, ok: Value) !void {
        const panes = if (ok == .object) ok.object.get("panes") else null;
        var old = self.panes;
        self.panes = .empty;
        defer {
            for (old.items) |p| self.freePane(p);
            old.deinit(self.gpa);
        }
        if (panes == null or panes.? != .array) return;
        // Siblings only: another session's agent panes are not this pane's.
        var session: ?[]const u8 = null;
        for (panes.?.array.items) |p| {
            if (p != .object) continue;
            const id = p.object.get("pane") orelse continue;
            const sid = p.object.get("session") orelse continue;
            if (id == .string and sid == .string and std.mem.eql(u8, id.string, self.control)) session = sid.string;
            if (id == .string and std.mem.eql(u8, id.string, self.control)) try self.takeOpenTags(app, p);
        }
        for (panes.?.array.items) |p| {
            if (p != .object) continue;
            if (session) |want| if (p.object.get("session")) |sid| {
                if (sid == .string and !std.mem.eql(u8, sid.string, want)) continue;
            };
            const id = p.object.get("pane") orelse continue;
            if (id != .string or !std.mem.eql(u8, tagOf(p, "role") orelse "", "agent")) continue;
            const group = tagOf(p, "group") orelse continue;
            const exited = if (p.object.get("exited")) |x| x == .bool and x.bool else false;
            const kind = std.meta.stringToEnum(split.Kind, tagOf(p, split_tag) orelse "agent_view") orelse .agent_view;
            var entry: AgentPane = .{ .agent = try self.gpa.dupe(u8, group), .pane = try self.gpa.dupe(u8, id.string), .exited = exited, .kind = kind };
            errdefer self.freePane(entry);
            for (old.items) |o| if (std.mem.eql(u8, o.pane, entry.pane)) {
                entry.fresh = o.fresh;
                entry.closing = o.closing;
                entry.refused_kill = o.refused_kill;
            };
            try self.panes.append(self.gpa, entry);
        }
        // A take-over pane that ended gives its agent back: the
        // harness is gone, so venom is the only client again.
        for (old.items) |o| {
            if (o.kind != .take_over or o.exited) continue;
            var live = false;
            for (self.panes.items) |p| live = live or (!p.exited and std.mem.eql(u8, p.pane, o.pane));
            if (live) continue;
            if (app.model.find(o.agent)) |ag| if (ag.state == .handed_over) {
                try app.takebackPaneEnded(o.agent);
                app.say("taking {s} back: its pane {s} ended", .{ o.agent, o.pane });
            };
        }
        // Marks on panes that went are nobody's business any more.
        var i: usize = 0;
        while (i < self.marks.items.len) {
            const m = self.marks.items[i];
            var live = std.mem.eql(u8, m.pane, self.control);
            for (self.panes.items) |p| live = live or std.mem.eql(u8, p.pane, m.pane);
            if (live) i += 1 else self.freeMark(self.marks.orderedRemove(i));
        }
    }

    /// What a later `venom --agent`, `--inbox` or `--usage` asked of this running
    /// control pane (`createControl` tags it, then attaches).
    fn takeOpenTags(self: *Host, app: *App, control: Value) !void {
        const agent = tagOf(control, open_agent_tag);
        const inbox = tagOf(control, open_inbox_tag);
        const usage = tagOf(control, open_usage_tag);
        if (agent == null and inbox == null and usage == null) return;
        try self.request(.{ .plain = "pane tag" }, "pane.tag", .{ .pane = self.control, .unset = &[_][]const u8{ open_agent_tag, open_inbox_tag, open_usage_tag } });
        // Another pane asked; typing here keeps its place.
        const typing = app.keyMode() == .input;
        if (agent) |id| {
            if (!typing) {
                app.screen = .main;
                app.on_header = false;
                try app.setSelected(id);
            }
            try self.openAgent(id);
        }
        if (inbox != null and !typing) app.openInbox();
        if (usage != null and !typing) try usage_view.open(app);
    }

    /// The list was refused: this principal is gone. Says so, once.
    fn refuse(self: *Host, app: *App, code: []const u8) void {
        if (self.refused) return;
        self.refused = true;
        app.say("venomx refused this pane ({s}): no agent panes or attention until venom restarts", .{code});
    }

    fn isDenied(body: proto.Response.Body) bool {
        return body == .@"error" and std.mem.startsWith(u8, body.@"error".code, "denied");
    }

    /// What the bar says while the key table is missing.
    pub fn notice(self: *const Host) ?[]const u8 {
        return if (self.keys_missing) keys_notice else null;
    }

    fn applyKeys(self: *Host, ok: Value) void {
        const tables = if (ok == .object) ok.object.get("tables") else null;
        if (tables == null or tables.? != .array) return;
        var found = false;
        for (tables.?.array.items) |t| {
            if (t != .object) continue;
            const name = t.object.get("name") orelse continue;
            found = found or (name == .string and std.mem.eql(u8, name.string, "venom"));
        }
        self.keys_missing = !found;
    }

    pub fn onResponse(self: *Host, app: *App, id: i64, body: proto.Response.Body) !void {
        const entry = self.pending.fetchRemove(id) orelse return;
        defer self.freePurpose(entry.value);
        switch (entry.value) {
            .quiet => {},
            .plain => |what| if (body == .@"error" and what.len > 0) app.say("venomx {s}: {s}", .{ what, body.@"error".code }),
            .keys => if (body == .ok) self.applyKeys(body.ok),
            .list => {
                if (isDenied(body)) return self.refuse(app, body.@"error".code);
                if (body == .ok) try self.applyList(app, body.ok);
            },
            .open => |agent| {
                if (isDenied(body)) return self.refuse(app, body.@"error".code);
                if (body == .@"error") return app.say("venomx pane list: {s}", .{body.@"error".code});
                if (body != .ok) return;
                try self.applyList(app, body.ok);
                if (self.paneOf(agent)) |p| {
                    if (!p.exited) return app.say("{s} is in pane {s}", .{ agent, p.pane });
                    const again = try self.gpa.dupe(u8, agent);
                    errdefer self.gpa.free(again);
                    try self.request(.{ .replace = again }, "pane.remove", .{ .pane = p.pane });
                    return;
                }
                try self.split_(app, agent);
            },
            .replace => |agent| {
                if (body == .@"error") return app.say("venomx pane remove: {s}", .{body.@"error".code});
                if (self.paneOf(agent)) |p| self.dropPane(p.pane);
                try self.split_(app, agent);
            },
            .split => |o| {
                if (body == .@"error") {
                    app.say("venomx pane split: {s}", .{body.@"error".code});
                    // Nothing runs the harness, so nothing would ever end it.
                    if (o.kind == .take_over) try app.takebackPaneEnded(o.agent);
                    return;
                }
                if (body != .ok or body.ok != .object) return;
                const pane = body.ok.object.get("pane") orelse return;
                if (pane != .string) return;
                const entry_pane: AgentPane = .{ .agent = try self.gpa.dupe(u8, o.agent), .pane = try self.gpa.dupe(u8, pane.string), .kind = o.kind, .fresh = o.kind == .take_over };
                errdefer self.freePane(entry_pane);
                try self.panes.append(self.gpa, entry_pane);
                if (o.kind == .take_over) {
                    const pid = body.ok.object.get("pid");
                    try app.recordTakeoverPane(o.agent, pane.string, if (pid != null and pid.? == .integer) pid.?.integer else null);
                }
                if (o.kind == .agent_view and self.bindsViews()) if (body.ok.object.get("pid")) |pid| if (pid == .integer) {
                    // The view is waiting for this (`awaitBinding`). Under this
                    // principal, so it can do no more, and ends with it.
                    try app.request(.{ .action = try self.gpa.dupe(u8, "agent view binding") }, "grant.issue", .{ .grants = &control_grants, .label = "venom agent view", .namespace = "person", .pid = pid.integer });
                };
                switch (o.kind) {
                    .agent_view => app.say("{s} opened in pane {s}", .{ o.agent, pane.string }),
                    .shell => app.say("a shell for {s} is in pane {s}; the agent keeps running", .{ o.agent, pane.string }),
                    .take_over => app.say("{s} is in pane {s}; quit it there, or T, to take it back", .{ o.agent, pane.string }),
                }
            },
            .closed => |pane| {
                if (body == .@"error") {
                    const code = body.@"error".code;
                    for (self.panes.items) |*p| if (std.mem.eql(u8, p.pane, pane)) {
                        p.closing = false;
                        if (std.mem.startsWith(u8, code, "denied")) {
                            // No wider grant for this: the human can
                            // end it, and its end takes the agent back.
                            p.refused_kill = true;
                            if (p.kind == .take_over) {
                                app.say("cannot close pane {s}, an earlier venom's: quit {s}'s harness there, and venom takes it back", .{ pane, p.agent });
                            } else app.say("cannot close pane {s}, an earlier venom's: exit it there", .{pane});
                            return;
                        }
                    };
                    if (std.mem.startsWith(u8, code, "not_found")) return self.requestList(.list);
                    return app.say("venomx pane kill: {s}", .{code});
                }
                try self.requestList(.list);
            },
            .unknown_grants => self.unknown_reads = body == .ok and unknownReadsAll(body.ok),
            .attention => |pane| if (body == .@"error") {
                const code = body.@"error".code;
                if (std.mem.startsWith(u8, code, "not_found")) {
                    self.dropPane(pane);
                } else if (std.mem.eql(u8, pane, self.control)) {
                    if (std.mem.startsWith(u8, code, "denied")) self.refuse(app, code) else app.say("venomx pane attention: {s}", .{code});
                } else if (std.mem.startsWith(u8, code, "denied")) {
                    // An earlier control pane's: its attention comes here.
                    if (!self.isForeign(pane)) try self.foreign.append(self.gpa, try self.gpa.dupe(u8, pane));
                    for (self.marks.items, 0..) |m, i| if (std.mem.eql(u8, m.pane, pane)) {
                        self.freeMark(self.marks.orderedRemove(i));
                        break;
                    };
                } else app.say("venomx pane attention: {s}", .{code});
            },
        }
    }

    // ---- The socket ------------------------------------------------------

    pub fn fd(self: *const Host) ?std.c.fd_t {
        const c = self.client orelse return null;
        return c.connection.fd;
    }

    pub fn wantsWrite(self: *const Host) bool {
        const c = self.client orelse return false;
        return self.outbox.items.len > 0 or c.connection.output.items.len > 0;
    }

    /// One turn. A lost daemon ends host mode's extras; venom's own view
    /// and the agents do not depend on it. False once the link is gone.
    pub fn pump(self: *Host, app: *App) !bool {
        if (self.client == null) return false;
        self.turn(app) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.client.?.deinit();
            self.client = null;
            // No venomx, so no table to miss or to get back by starting venom.
            self.keys_missing = false;
            app.say("venomx went away; its panes are gone, the agents keep running", .{});
            return false;
        };
        return true;
    }

    fn turn(self: *Host, app: *App) !void {
        if (!self.refused) {
            if (nowMs() - self.listed_at >= list_every_ms) try self.requestList(.list);
            if (nowMs() - self.keys_at >= keys_every_ms) try self.requestKeys();
            try self.sync(app);
        }
        try self.flush();
        const c = &self.client.?;
        while (try c.receive(0)) |msg| {
            if (msg != .ndjson) return error.InvalidResponse;
            var r = try proto.Response.parse(self.gpa, msg.ndjson);
            defer r.deinit();
            const id = r.id orelse continue;
            if (id == .integer and r.final()) try self.onResponse(app, id.integer, r.body);
            try self.flush();
        }
    }

    fn flush(self: *Host) !void {
        const c = &self.client.?;
        for (self.outbox.items) |line| {
            defer self.gpa.free(line);
            try c.connection.sendMessage(.{ .ndjson = line });
        }
        self.outbox.clearRetainingCapacity();
    }

    /// The TUI is quitting: clear the attention only it could clear. Its key
    /// table and presets are connection-bound and go with the connection.
    pub fn finish(self: *Host, app: *App) void {
        if (self.client == null) return;
        if (self.rang and !self.isMarked(self.control)) self.clearAttention(self.control) catch return;
        for (self.marks.items) |m| {
            self.clearAttention(m.pane) catch return;
            self.freeMark(m);
        }
        self.marks.clearRetainingCapacity();
        // A pane the human opened goes back to being just theirs.
        self.request(.quiet, "pane.tag", .{ .pane = self.control, .unset = &[_][]const u8{ "role", "product", selected_tag, open_agent_tag, open_inbox_tag, open_usage_tag } }) catch return;
        self.flush() catch return;
        const until = nowMs() + 500;
        const c = &self.client.?;
        while (self.pending.count() > 0 and nowMs() < until) {
            const msg = (c.receive(50) catch return) orelse continue;
            if (msg != .ndjson) return;
            var r = proto.Response.parse(self.gpa, msg.ndjson) catch return;
            defer r.deinit();
            if (r.id) |id| if (id == .integer and r.final()) self.onResponse(app, id.integer, r.body) catch return;
        }
    }
};

/// A tag of a `pane.list` entry (`tags` is `[{key,value}]`).
fn tagOf(pane: Value, key: []const u8) ?[]const u8 {
    const tags = pane.object.get("tags") orelse return null;
    if (tags != .array) return null;
    for (tags.array.items) |t| {
        if (t != .object) continue;
        const k = t.object.get("key") orelse continue;
        const v = t.object.get("value") orelse continue;
        if (k == .string and v == .string and std.mem.eql(u8, k.string, key)) return v.string;
    }
    return null;
}

// ---- Choosing the mode ---------------------------------------------------

const hello: proto.HelloOptions = .{ .identity = .{ .name = "venom", .version = "0.0.0" }, .caps = &.{} };

/// Connects to venomx and finishes hello; null when it is not reachable.
/// Only ever a connect: this is what keeps `auto` from starting a daemon.
fn connect(gpa: std.mem.Allocator, environ: std.process.Environ, token: ?[]const u8) ?proto.Client {
    var client = proto.Client.init(gpa, .{ .tool = "venomx", .path = .{ .environ = environ }, .hello = hello, .token = token }) catch return null;
    const until = nowMs() + 2000;
    while (nowMs() < until) {
        if (client.pollHello(100) catch break) return client;
    }
    client.deinit();
    return null;
}

/// What the last failed `call` said, for the message that follows it.
var failed_buf: [128]u8 = undefined;
var failed: []const u8 = "";

/// One blocking request, before the TUI takes the terminal.
fn call(a: std.mem.Allocator, client: *proto.Client, id: i64, verb: []const u8, params: anytype) !Value {
    try client.request(id, verb, params);
    const until = nowMs() + 5000;
    while (nowMs() < until) {
        const msg = try client.receive(100) orelse continue;
        if (msg != .ndjson) return error.InvalidResponse;
        const r = try proto.Response.parse(a, msg.ndjson);
        const rid = r.id orelse continue;
        if (rid != .integer or rid.integer != id or !r.final()) continue;
        return switch (r.body) {
            .ok => |v| v,
            .@"error" => |e| {
                failed = std.fmt.bufPrint(&failed_buf, "{s}: {s}", .{ verb, e.code }) catch verb;
                return error.VerbFailed;
            },
            else => error.VerbFailed,
        };
    }
    return error.Timeout;
}

/// A TUI outside every managed tree reads the owner
/// file, unless the user chose a token. Same as `venomx attach`.
pub fn ownerEnviron(a: std.mem.Allocator, environ: std.process.Environ, comptime name: []const u8) !std.process.Environ {
    if (environ.getPosix(name) != null) return environ;
    const old = environ.block.view().slice;
    const slice = try a.allocSentinel(?[*:0]const u8, old.len + 1, null);
    for (old, 0..) |entry, i| slice[i] = entry;
    slice[old.len] = name ++ "=@owner";
    return .{ .block = .{ .slice = slice } };
}

pub const Start = struct {
    setting: Setting,
    environ: std.process.Environ,
    env_map: ?*const std.process.Environ.Map,
    exe: []const u8,
    /// venom's own socket, passed on to its panes.
    socket: []const u8,
    /// Passed on to the control pane when venom has to create one.
    agent: ?[]const u8 = null,
    inbox: bool = false,
    usage: bool = false,
    cols: u16 = 80,
    rows: u16 = 24,
    /// This process waited for its binding and got it (`awaitBinding`).
    bound: bool = false,
    /// Run once the control pane exists, before this process becomes
    /// `venomx attach`: it waits until the control pane holds the daemon.
    handoff: ?Handoff = null,
};

pub const Handoff = struct { ctx: *anyopaque, wait: *const fn (*anyopaque) void };

pub const Resolved = union(enum) {
    /// Own mode; a reason worth showing, if any.
    own: ?[]const u8,
    host: *Host,
};

/// What `ui.chrome` means here. Inside a venomx pane
/// that pane is the control pane. Outside, with a daemon reachable, venom
/// creates the control pane (or finds the one it made) and this terminal
/// becomes `venomx attach` on it: on success this does not return.
pub fn resolve(gpa: std.mem.Allocator, a: std.mem.Allocator, s: Start) !Resolved {
    if (s.setting == .own) return .{ .own = null };
    if (s.environ.getPosix("VENOMX_PANE")) |pane| {
        const client = connect(gpa, s.environ, null) orelse return .{ .own = "venomx is not reachable from this pane; running on our own" };
        return .{ .host = try newHost(gpa, s, pane, client) };
    }
    var owner = connect(gpa, try ownerEnviron(a, s.environ, "VENOMX_TOKEN"), null) orelse return .{ .own = null };
    defer owner.deinit();
    const attach = try split.findExe(a, s.env_map, "venomx") orelse return .{ .own = "venomx is running but not in PATH; running on our own" };
    const session = createControl(gpa, a, &owner, s) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .own = try std.fmt.allocPrint(a, "no control pane in venomx ({s}); running on our own", .{if (failed.len > 0) failed else @errorName(err)}) };
    };
    if (s.handoff) |h| h.wait(h.ctx);
    execAttach(a, attach, session, s.environ) catch {};
    return .{ .own = "could not attach to venomx; running on our own" };
}

/// A `VENOM_TOKEN` a pane may be given. Owner credentials never enter children,
/// and venom in a pane is refused the owner file: without one it connects as `unknown`.
pub fn passable(token: ?[]const u8) ?[]const u8 {
    const t = token orelse return null;
    if (!std.mem.startsWith(u8, t, "vnt1.venom.") or std.mem.startsWith(u8, t, "vnt1.venom.owner.")) return null;
    return t;
}

fn newHost(gpa: std.mem.Allocator, s: Start, pane: []const u8, client: proto.Client) !*Host {
    const h = try gpa.create(Host);
    errdefer gpa.destroy(h);
    h.* = try .init(gpa, .{ .control = pane, .exe = s.exe, .socket = s.socket, .token = passable(s.environ.getPosix("VENOM_TOKEN")), .bound = s.bound });
    h.client = client;
    try h.begin();
    return h;
}

pub fn destroy(gpa: std.mem.Allocator, h: *Host) void {
    h.deinit();
    gpa.destroy(h);
}

/// The session holding a live control pane: session `venom`, made if need
/// be. Owner credentials stay in this process, which is about to become
/// `venomx attach`. On venomx the pane gets a pane's default rights and its
/// lifetime; on venom, a principal bound to its process.
fn createControl(gpa: std.mem.Allocator, a: std.mem.Allocator, owner: *proto.Client, s: Start) ![]const u8 {
    const listed = try call(a, owner, 1, "session.list", struct {}{});
    var session: ?[]const u8 = null;
    for (listed.object.get("sessions").?.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, "venom")) session = item.object.get("session").?.string;
    }
    var running: ?[]const u8 = null;
    if (session) |sid| {
        const panes = try call(a, owner, 2, "pane.list", .{ .session = sid });
        for (panes.object.get("panes").?.array.items) |p| {
            const exited = if (p.object.get("exited")) |x| x == .bool and x.bool else false;
            if (!exited and std.mem.eql(u8, tagOf(p, "role") orelse "", "control")) running = p.object.get("pane").?.string;
        }
    } else {
        const made = try call(a, owner, 3, "session.create", .{ .name = "venom", .on_empty = "remove" });
        session = made.object.get("session").?.string;
    }
    const sid = session.?;
    // Failing here costs only the keys; the control pane's bar says so while
    // the table is missing.
    registerKeys(a, owner, s) catch |err| if (err == error.OutOfMemory) return err;
    if (running) |pane| {
        // The running control pane acts on these (`takeOpenTags`).
        var tags: std.ArrayList(Tag) = .empty;
        if (s.agent) |id| try tags.append(a, .{ .key = open_agent_tag, .value = id });
        if (s.inbox) try tags.append(a, .{ .key = open_inbox_tag, .value = "true" });
        if (s.usage) try tags.append(a, .{ .key = open_usage_tag, .value = "true" });
        if (tags.items.len > 0) _ = try call(a, owner, 5, "pane.tag", .{ .pane = pane, .set = tags.items });
        return sid;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ s.exe, "agent", "view", try std.fmt.allocPrint(a, "--socket={s}", .{s.socket}) });
    if (s.agent) |id| try argv.append(a, try std.fmt.allocPrint(a, "--agent={s}", .{id}));
    if (s.inbox) try argv.append(a, "--inbox=true");
    if (s.usage) try argv.append(a, "--usage=true");
    var env: std.ArrayList(EnvVar) = .empty;
    // A token the human chose goes in as they asked. Otherwise the pane holds
    // no credential: its process is bound, once it has one. Connect first, so
    // a daemon that refuses this process costs no pane.
    const chosen = passable(s.environ.getPosix("VENOM_TOKEN"));
    var venom_owner: ?proto.Client = null;
    defer if (venom_owner) |*c| c.deinit();
    if (chosen) |t| {
        try env.append(a, .{ .name = "VENOM_TOKEN", .value = t });
    } else {
        venom_owner = try ownerOnVenom(gpa, a, s);
        try argv.appendSlice(a, &await_binding_args);
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else null;
    const made = try call(a, owner, 6, "window.create", .{
        .session = sid,
        .name = "venom",
        .argv = argv.items,
        .cols = s.cols,
        .rows = s.rows,
        .cwd = cwd,
        .env = if (env.items.len > 0) @as(?[]const EnvVar, env.items) else null,
        .tags = &[_]Tag{ .{ .key = "role", .value = "control" }, product_tag },
        .on_exit = "remove",
        .grants = venomx_control_grants,
    });
    if (venom_owner) |*c| bindControl(a, c, made) catch |err| {
        // A pane that can only read, and would wait to find that out, helps
        // nobody: the caller falls back with the reason.
        if (made.object.get("pane")) |pane| _ = call(a, owner, 10, "pane.kill", .{ .pane = pane.string, .remove = true }) catch {};
        return err;
    };
    return sid;
}

/// What a person does in the control pane and its agent views, and no `admin`: no config changes,
/// audit or shutdown.
pub const control_grants = [_]struct { right: []const u8, scope: []const u8 }{
    .{ .right = "read", .scope = "*" },
    .{ .right = "write", .scope = "*" },
    .{ .right = "respond", .scope = "*" },
    .{ .right = "files", .scope = "*" },
    .{ .right = "spawn", .scope = "*" },
};

/// A view started with these connects as `unknown` until it is bound, and holds
/// no credential: `venom agent view` waits for that before it starts.
const await_binding_args = [_][]const u8{ "--await-binding=true", "--no-owner=true" };

/// venom's owner connection, while this process is still outside venomx.
fn ownerOnVenom(gpa: std.mem.Allocator, a: std.mem.Allocator, s: Start) !proto.Client {
    var client = try proto.Client.init(gpa, .{
        .tool = "venom",
        .path = .{ .socket = s.socket, .environ = try ownerEnviron(a, s.environ, "VENOM_TOKEN") },
        .hello = hello,
    });
    errdefer client.deinit();
    const until = nowMs() + 2000;
    while (!try client.pollHello(100)) if (nowMs() > until) return error.Timeout;
    return client;
}

/// The pane's process gets its own principal: no token,
/// no expiry, and it lasts as long as the process, a daemon restart included.
fn bindControl(a: std.mem.Allocator, venom: *proto.Client, made: Value) !void {
    const pid = (made.object.get("pid") orelse return error.InvalidResponse);
    if (pid != .integer) return error.InvalidResponse;
    _ = try call(a, venom, 1, "grant.issue", .{ .grants = &control_grants, .label = "venom control pane", .namespace = "person", .pid = pid.integer });
}

/// Polls until the process that started this one has bound it, since a
/// connection's principal is resolved once, at `accept`. False when no one did
/// in time: the view then runs as `unknown`, and says so.
pub fn awaitBinding(gpa: std.mem.Allocator, a: std.mem.Allocator, path: proto.os.SocketOptions) bool {
    const pause: std.c.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
    const until = nowMs() + await_binding_ms;
    while (nowMs() < until) {
        if (boundNow(gpa, a, path)) return true;
        _ = std.c.nanosleep(&pause, null);
    }
    return false;
}

const await_binding_ms = 5000;

fn boundNow(gpa: std.mem.Allocator, a: std.mem.Allocator, path: proto.os.SocketOptions) bool {
    var client = proto.Client.init(gpa, .{ .tool = "venom", .path = path, .hello = hello }) catch return false;
    defer client.deinit();
    const until = nowMs() + 1000;
    while (!(client.pollHello(50) catch return false)) if (nowMs() > until) return false;
    const me = call(a, &client, 1, "whoami", struct {}{}) catch return false;
    const principal = me.object.get("principal") orelse return false;
    return principal == .string and !std.mem.eql(u8, principal.string, "unknown");
}

/// Registers the `venom` table and presets on the owner connection: this
/// process is outside every managed tree and about to
/// exec, so it keeps nothing. With `bind = daemon` they last until the daemon
/// stops or `keys.unregister`.
fn registerKeys(a: std.mem.Allocator, owner: *proto.Client, s: Start) !void {
    _ = try call(a, owner, 7, "floats.register", .{ .name = "venom.settings", .width = "80%", .height = "80%", .anchor = "center", .title = "venom settings", .bind = "daemon" });
    _ = try call(a, owner, 8, "floats.register", .{ .name = "venom.diff", .width = "100%", .height = "70%", .anchor = "bottom", .title = "venom diff", .bind = "daemon" });
    _ = try call(a, owner, 9, "keys.register", try keyTable(a, s.exe, s.socket));
}

/// This terminal becomes the presentation client (a
/// terminal has one; venom draws only in its pane).
fn execAttach(a: std.mem.Allocator, exe: []const u8, session: []const u8, environ: std.process.Environ) !void {
    const path = try a.dupeSentinel(u8, exe, 0);
    const argv = try a.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = path;
    argv[1] = "attach";
    argv[2] = try std.fmt.allocPrintSentinel(a, "--session={s}", .{session}, 0);
    const old = environ.block.view().slice;
    const envp = try a.allocSentinel(?[*:0]const u8, old.len, null);
    for (old, 0..) |entry, i| envp[i] = entry;
    _ = std.c.execve(path, argv, envp);
    return error.ExecFailed;
}

// ---- `venom agent diff` -----------------------------------------------------

/// The agent a pane of venom's belongs to: its `group`, or the control pane's
/// selection. The table works from any pane, and in another's `group` means
/// something else.
pub fn agentOfPane(pane: Value) ?[]const u8 {
    const product = tagOf(pane, product_tag.key) orelse return null;
    if (!std.mem.eql(u8, product, product_tag.value)) return null;
    return tagOf(pane, "group") orelse tagOf(pane, "venom.selected");
}

/// The folders whose diff is the agent's: its checkouts, else where it runs.
pub fn diffFolders(a: std.mem.Allocator, show: Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (show.object.get("checkouts")) |c| if (c == .array) for (c.array.items) |item| {
        if (item != .object) continue;
        const p = item.object.get("path") orelse continue;
        if (p == .string) try out.append(a, p.string);
    };
    if (out.items.len == 0) if (show.object.get("cwd")) |c| if (c == .string) try out.append(a, c.string);
    return out.items;
}

/// `doctor`: venomx takes its own leader first, so a `ui.keys.leader` equal to
/// it could never open venom's tree in host mode.
pub const LeaderCheck = struct {
    config: *config_mod.Store,
    /// venomx's `keys.leader`, or null when it isn't up.
    read: *const fn (ctx: *const anyopaque, a: std.mem.Allocator) ?[]const u8 = readVenomxLeader,
    ctx: *const anyopaque = undefined,

    pub fn run(self: *LeaderCheck, r: *cli.doctor.Report) anyerror!void {
        const ui = self.config.current().ui;
        const fix = try r.print("{s} config set --key=ui.keys.leader --value='\"space\"'", .{r.tool});
        if (ui.chrome == .own) return r.add("ui.keys.leader", .ok, try r.print("leader {s}; ui.chrome is own, so venomx takes no key first", .{ui.keys.leader}), fix);
        const theirs = self.read(self.ctx, r.arena) orelse return r.add("ui.keys.leader", .ok, try r.print("leader {s}; venomx is not running", .{ui.keys.leader}), fix);
        if (leadersClash(ui.keys.leader, theirs))
            return r.add("ui.keys.leader", .warn, try r.print("ui.keys.leader is {s}, which is venomx's keys.leader: venomx takes it first, so venom's key tree can't open from it in host mode", .{ui.keys.leader}), fix);
        try r.add("ui.keys.leader", .ok, try r.print("leader {s}; venomx's is {s}", .{ ui.keys.leader, theirs }), fix);
    }
};

/// What `grants.isolation` venomx runs with.
pub const Isolation = enum { down, on, off };

/// `doctor`: with isolation off, venomx trusts every process of the user, so
/// an agent that escapes its pane's tree may write anywhere in venomx.
/// venom's own panes stay capped by its token.
pub const IsolationCheck = struct {
    read: *const fn (ctx: *const anyopaque, a: std.mem.Allocator) Isolation = readVenomxIsolation,
    ctx: *const anyopaque = undefined,

    pub fn run(self: *IsolationCheck, r: *cli.doctor.Report) anyerror!void {
        const fix = "VENOMX_TOKEN=@owner venomx config set --key grants.isolation --value true && VENOMX_TOKEN=@owner venomx config reload";
        switch (self.read(self.ctx, r.arena)) {
            .down => try r.add("venomx.isolation", .ok, "venomx is not running", "venomx config get --key grants.isolation --json"),
            .on => try r.add("venomx.isolation", .ok, "venomx keeps its callers apart (grants.isolation is on)", "venomx config get --key grants.isolation --json"),
            .off => try r.add("venomx.isolation", .warn, "venomx has grants.isolation off: any process of yours, an agent that escapes its pane included, may write and spawn anywhere in venomx. Turn it on when agents run there", fix),
        }
    }
};

/// `grants.isolation` from venomx's `config.get`, as the owner when it can.
/// A venomx without the key predates the switch and always kept callers apart.
fn readVenomxIsolation(ctx: *const anyopaque, a: std.mem.Allocator) Isolation {
    const environ: *const std.process.Environ = @ptrCast(@alignCast(ctx));
    const owner = ownerEnviron(a, environ.*, "VENOMX_TOKEN") catch return .down;
    var client = connect(a, owner, null) orelse connect(a, environ.*, null) orelse return .down;
    defer client.deinit();
    const got = call(a, &client, 1, "config.get", .{ .key = "grants.isolation" }) catch return if (std.mem.endsWith(u8, failed, "invalid_params.config_key")) .on else .down;
    return isolationOf(got);
}

/// `true`/`false` from a `config.get` result; anything else reads as on.
pub fn isolationOf(got: Value) Isolation {
    if (got != .object) return .on;
    const content = got.object.get("content") orelse return .on;
    if (content != .string) return .on;
    return if (std.mem.eql(u8, std.mem.trim(u8, content.string, " \n"), "false")) .off else .on;
}

/// The same chord, however it is written.
pub fn leadersClash(ours: []const u8, theirs: []const u8) bool {
    const x = chord.parseChord(ours) orelse return false;
    const y = chord.parseChord(theirs) orelse return false;
    return x.eql(y);
}

/// `leader` of venomx's `keys.list`. As the owner when it can (outside venomx),
/// and as itself inside a pane, where the owner token is refused.
fn readVenomxLeader(ctx: *const anyopaque, a: std.mem.Allocator) ?[]const u8 {
    const environ: *const std.process.Environ = @ptrCast(@alignCast(ctx));
    const owner = ownerEnviron(a, environ.*, "VENOMX_TOKEN") catch return null;
    var client = connect(a, owner, null) orelse connect(a, environ.*, null) orelse return null;
    defer client.deinit();
    const listed = call(a, &client, 1, "keys.list", struct {}{}) catch return null;
    if (listed != .object) return null;
    const leader = listed.object.get("leader") orelse return null;
    return if (leader == .string) leader.string else null;
}

/// `venom agent diff --pane <p>`: what the `venom.diff` popup runs. It finds
/// the pane's agent through venomx, its folders through venom, then prints
/// `git diff` for each. The popup keeps the output until it is dismissed.
pub fn diffCommand(gpa: std.mem.Allocator, a: std.mem.Allocator, path: proto.SocketOptions, environ: std.process.Environ, agent_param: ?[]const u8, pane_param: ?[]const u8, out: *std.Io.Writer) !?[]const u8 {
    const agent = agent_param orelse blk: {
        const pane = pane_param orelse return "give --agent, or --pane inside venomx";
        var vx = connect(gpa, environ, null) orelse return "venomx is not reachable";
        defer vx.deinit();
        const listed = call(a, &vx, 1, "pane.list", struct {}{}) catch return "venomx pane list failed";
        for (listed.object.get("panes").?.array.items) |p| {
            if (!std.mem.eql(u8, p.object.get("pane").?.string, pane)) continue;
            break :blk agentOfPane(p) orelse return "that pane shows no agent; select one first";
        }
        return "no such pane";
    };
    var venom = proto.Client.init(gpa, .{ .tool = "venom", .path = path, .hello = hello }) catch return @import("startup.zig").not_running_message;
    defer venom.deinit();
    const until = nowMs() + 2000;
    while (!(venom.pollHello(100) catch return "the venom daemon did not answer")) {
        if (nowMs() > until) return "the venom daemon did not answer";
    }
    const show = call(a, &venom, 1, "agent.show", .{ .agent = agent }) catch return "no such agent; see venom agent list";
    for (try diffFolders(a, show)) |folder| {
        try out.print("── {s} ({s})\n", .{ folder, agent });
        try out.flush();
        runGit(a, folder);
    }
    return null;
}

// ---- `venom agent split` ----------------------------------------------------

pub const SplitOutcome = union(enum) {
    ok: Value,
    failure: struct { code: []const u8, message: []const u8 },
};

/// `venom agent split`: a split from a script, in the caller's name. venom's
/// daemon has no link to venomx and acts for nobody there, so this
/// runs in the caller and venomx checks the caller's own rights:
/// a pane may split only what it has `spawn` on, and a read-only split nothing.
pub fn splitCommand(gpa: std.mem.Allocator, a: std.mem.Allocator, path: proto.SocketOptions, environ: std.process.Environ, o: struct {
    agent: []const u8,
    kind: split.Kind,
    pane: ?[]const u8,
    exe: []const u8,
    socket: []const u8,
    shell: []const u8,
}) !SplitOutcome {
    const failure = struct {
        fn of(code: []const u8, message: []const u8) SplitOutcome {
            return .{ .failure = .{ .code = code, .message = message } };
        }
    }.of;
    const source = o.pane orelse environ.getPosix("VENOMX_PANE") orelse return failure("invalid_params.pane", "give --pane, or run it inside a venomx pane");
    var venom = proto.Client.init(gpa, .{ .tool = "venom", .path = path, .hello = hello }) catch return failure("unavailable.not_running", @import("startup.zig").not_running_message);
    defer venom.deinit();
    const until = nowMs() + 2000;
    while (!(venom.pollHello(100) catch return failure("unavailable", "the venom daemon did not answer"))) {
        if (nowMs() > until) return failure("unavailable", "the venom daemon did not answer");
    }
    const show = call(a, &venom, 1, "agent.show", .{ .agent = o.agent }) catch return failure("not_found.agent", "no such agent; see venom agent list");
    const cwd = if (show.object.get("cwd")) |c| (if (c == .string) c.string else "") else "";
    if (o.kind == .shell and !std.fs.path.isAbsolute(cwd)) return failure("unavailable.folder", "the agent has no folder yet");
    var argv: std.ArrayList([]const u8) = .empty;
    switch (o.kind) {
        .shell => try argv.append(a, o.shell),
        .agent_view => {
            try argv.appendSlice(a, &.{ o.exe, "agent", "view", try std.fmt.allocPrint(a, "--agent={s}", .{o.agent}), "--solo=true", try std.fmt.allocPrint(a, "--socket={s}", .{o.socket}) });
            // A view reads the owner file by default; from the CLI that takes
            // asking, since the caller can type into
            // what it creates.
            const token = environ.getPosix("VENOM_TOKEN");
            if (token == null or !std.mem.eql(u8, token.?, "@owner")) try argv.append(a, "--no-owner=true");
        },
        .take_over => return failure("invalid_params.kind", "take over from the TUI: it needs to see the harness end"),
    }
    var vx = connect(gpa, environ, null) orelse return failure("unavailable.venomx", "venomx is not reachable");
    defer vx.deinit();
    const near = [_]Tag{.{ .key = "group", .value = o.agent }};
    const reads = if (call(a, &vx, 2, "config.get", .{ .key = "grants.unknown" })) |ok| unknownReadsAll(ok) else |err| if (err == error.OutOfMemory) return err else false;
    const params = try SplitParams.of(a, .{
        .kind = o.kind,
        .agent = o.agent,
        .source = source,
        .axis = "cols",
        .near = &near,
        .argv = argv.items,
        .cwd = cwd,
        .token = passable(environ.getPosix("VENOM_TOKEN")),
        .reads = reads,
    });
    const made = call(a, &vx, 1, "pane.split", params) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err != error.VerbFailed) return failure("unavailable.venomx", "venomx did not answer");
        const code = if (std.mem.indexOf(u8, failed, ": ")) |i| try a.dupe(u8, failed[i + 2 ..]) else "unavailable.venomx";
        return failure(code, "venomx refused the split");
    };
    if (made != .object) return failure("unavailable.venomx", "venomx gave an unexpected answer");
    var out = made;
    try out.object.put(a, "agent", .{ .string = o.agent });
    try out.object.put(a, "kind", .{ .string = @tagName(o.kind) });
    return .{ .ok = out };
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

fn runGit(a: std.mem.Allocator, folder: []const u8) void {
    const z = a.dupeSentinel(u8, folder, 0) catch return;
    const pid = std.c.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "git", "-C", z, "--no-pager", "diff", "--color=always", "HEAD" };
        _ = execvp("git", &argv);
        std.c._exit(127);
    }
    if (pid > 0) {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
    }
}
