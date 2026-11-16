//! The settings screen's state. Every field
//! is a config key: an edit becomes a pending
//! change, shown as a ZON diff with the equivalent `venom config set` command,
//! and ⌃s sends exactly those `config.set` requests, then `config.reload`.
//! The daemon validates; the screen shows the key it names when it refuses.
//!
//! The layer picker (`S`) walks user → each workspace → its repos;
//! `config.get` and `config.set` then carry `--workspace` and
//! `--repo`, so the values and the writes are those of that layer's file.
const std = @import("std");
const term = @import("venom-term");
const log = @import("log");
const config = @import("../config.zig");
const scope = @import("../scope.zig");
const zon_text = @import("zon_text.zig");
const providers_mod = @import("providers.zig");
const provider_popup = @import("provider_popup.zig");
const keys = @import("keys.zig");
const App = @import("app.zig").App;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const k = term.widgets.keys;

/// How a field is edited.
pub const Kind = union(enum) {
    /// `⏎`, `h` or `l` flips it.
    toggle,
    /// `⏎` and `l` step through these enum literals, and `h` steps back.
    choice: []const []const u8,
    /// `⏎` asks for a ZON value (a number, a tuple).
    zon,
    /// `⏎` asks for text; it is written as a ZON string. `optional`: an
    /// empty answer writes `null`.
    text: struct { optional: bool = false },
};

pub const Field = struct {
    key: []const u8,
    label: []const u8,
    help: []const u8 = "",
    kind: Kind,
};

/// A row of the Providers section: one configured provider, or (`index`
/// null) the empty state, whose ⏎ configures the first. ⏎ opens the popup.
pub const ProviderRow = struct {
    index: ?usize = null,
    name: []const u8 = "",
    harness: []const u8 = "",
    /// The config dir, or "default login".
    login: []const u8 = "",
    model: []const u8 = "",
    permission: []const u8 = "",
    /// Plan · signed in, or what is wrong.
    status: []const u8 = "",
    default: bool = false,
    mark: ?enum { ok, warn } = null,
};

/// A row of a section: a field, or a line to read (no config key behind it).
pub const Row = union(enum) {
    field: Field,
    info: struct { title: []const u8, detail: []const u8 = "", mark: ?enum { ok, warn } = null },
    provider: ProviderRow,
};

pub const Section = struct {
    name: []const u8,
    fields: []const Field = &.{},
};

fn choicesOf(comptime E: type) []const []const u8 {
    const names = comptime std.meta.fieldNames(E);
    const out = comptime blk: {
        var list: [names.len][]const u8 = undefined;
        for (names, &list) |n, *l| l.* = "." ++ n;
        const final = list;
        break :blk final;
    };
    return &out;
}

fn choice(comptime E: type) Kind {
    return .{ .choice = comptime choicesOf(E) };
}

const duration: Kind = .{ .text = .{} };

// Shared by several sections.
const f_mode: Field = .{ .key = "agents.mode", .label = "Permission mode", .help = "Ask, accept edits or plan first. Grants always apply.", .kind = choice(config.Mode) };
const f_isolation: Field = .{ .key = "agents.isolation", .label = "Isolation", .help = "A worktree per agent per repo, in place, or a copy.", .kind = choice(config.Isolation) };
const f_max: Field = .{ .key = "agents.max_concurrent", .label = "Max concurrent agents", .help = "Extra spawns queue; children count.", .kind = .zon };
const f_children: Field = .{ .key = "ui.children", .label = "Child agents in the list", .help = "Tree, folded to one line, or hidden.", .kind = choice(config.Children) };
const f_archive: Field = .{ .key = "agents.archive_after", .label = "Archive settled agents after", .help = "Archived agents keep transcript and worktree until cleaned.", .kind = duration };
const f_group: Field = .{ .key = "ui.group_by", .label = "Group the agent list by", .kind = choice(config.GroupBy) };
const f_warn: Field = .{ .key = "ui.context.warn_at", .label = "Context meter warns at", .help = "Percent of the context window, 0 to 100.", .kind = .zon };

fn harnessFields(comptime name: []const u8, comptime label: []const u8) [3]Field {
    return .{
        .{ .key = "harness." ++ name ++ ".enabled", .label = label ++ " enabled", .help = "Applies when the daemon next starts.", .kind = .toggle },
        .{ .key = "harness." ++ name ++ ".path", .label = label ++ " binary", .help = "Empty finds it on PATH.", .kind = .{ .text = .{ .optional = true } } },
        .{ .key = "harness." ++ name ++ ".extra_args", .label = label ++ " extra arguments", .help = "A ZON tuple of strings.", .kind = .zon },
    };
}

/// The screen's sections, in order. A test checks that every
/// key is one venom's config has, and that every key venom's config has is
/// in a section.
pub const sections = [_]Section{
    // The providers come first; their rows and popup are their own
    // (`providerRows`, provider_popup.zig). The raw values are under Integrations.
    .{ .name = "Providers" },
    .{ .name = "General", .fields = &.{
        .{ .key = "log.level", .label = "Log level", .help = "Records less severe are dropped from every sink.", .kind = choice(log.Level) },
        .{ .key = "log.stderr_level", .label = "Log level on stderr", .kind = choice(log.Level) },
        .{ .key = "log.stderr_format", .label = "Log format on stderr", .kind = choice(log.Format) },
        .{ .key = "log.file_format", .label = "Log format in the file", .kind = choice(log.Format) },
        .{ .key = "daemon.interactive_start", .label = "Start the daemon from venom", .help = "A bare venom starts a missing daemon, which stops after the last TUI quits.", .kind = .toggle },
        .{ .key = "daemon.startup_timeout_ms", .label = "Daemon startup budget", .help = "Milliseconds, 100 to 60000.", .kind = .zon },
    } },
    .{ .name = "Workspaces", .fields = &.{f_group} },
    .{ .name = "Agents", .fields = &.{
        .{ .key = "agents.default", .label = "Harness", .help = "For a new agent when neither a harness nor a provider is named, and no default provider is set.", .kind = choice(config.Harness) },
        f_mode,
        f_isolation,
        f_max,
        .{ .key = "agents.spawn.allow", .label = "Allow agents to spawn agents", .help = "Through venom's MCP server.", .kind = .toggle },
        .{ .key = "agents.spawn.depth", .label = "Max tree depth", .help = "Below a top-level agent.", .kind = .zon },
        f_children,
        f_archive,
    } },
    .{ .name = "Models and limits", .fields = &[_]Field{
        f_max,
        .{ .key = "harness.start_timeout", .label = "Harness start timeout", .help = "A harness that reports no session in this is stopped.", .kind = duration },
        .{ .key = "harness.shutdown_grace", .label = "Shutdown grace", .help = "Waits for running turns, then for exit before SIGKILL.", .kind = duration },
        .{ .key = "harness.body_max", .label = "Inline tool output", .help = "Bytes kept per call.", .kind = .zon },
        .{ .key = "harness.resume_prompt", .label = "Resume prompt", .help = "Sent by retry and after a stale request is answered.", .kind = .{ .text = .{} } },
    } },
    .{ .name = "Permissions and grants", .fields = &.{
        f_mode,
        .{ .key = "grants.unknown", .label = "Callers without a token", .help = "A ZON tuple of grants; read-only rights only.", .kind = .zon },
        .{ .key = "grants.interactive", .label = "Interactive callers", .help = "A ZON tuple of grants.", .kind = .zon },
        .{ .key = "grants.max_token_ttl", .label = "Longest token lifetime", .help = "Seconds.", .kind = .zon },
        .{ .key = "grants.isolation", .label = "Keep callers apart", .help = "On in venom. Off trusts every process of yours.", .kind = .toggle },
    } },
    .{ .name = "Worktrees", .fields = &.{ f_isolation, f_archive } },
    .{ .name = "Attention", .fields = &.{
        .{ .key = "attention.bell", .label = "Bell", .help = "BEL for blocking kinds.", .kind = .toggle },
        .{ .key = "attention.notify_after", .label = "Notify after", .help = "A blocking item unanswered this long posts a notification.", .kind = duration },
        .{ .key = "attention.approval_timeout", .label = "Approval timeout", .help = "Denies an unanswered approval. Empty waits forever.", .kind = .{ .text = .{ .optional = true } } },
    } },
    .{ .name = "Transcript", .fields = &.{
        .{ .key = "ui.transcript.density", .label = "Density", .kind = choice(config.Density) },
        .{ .key = "ui.transcript.open_running_after", .label = "Open a running call after", .help = "With a live tail.", .kind = duration },
    } },
    .{ .name = "Usage and budgets", .fields = &.{f_warn} },
    .{ .name = "Appearance", .fields = &.{
        .{ .key = "ui.chrome", .label = "Chrome", .help = "Own full screen, or a venomx control pane.", .kind = choice(config.Chrome) },
        f_group,
        f_children,
    } },
    .{ .name = "Keys", .fields = &.{
        .{ .key = "ui.keys.leader", .label = "Leader", .help = "Opens the key tree in Normal mode, such as space or ctrl+x. Applies when the TUI next starts.", .kind = .{ .text = .{} } },
        .{ .key = "ui.keys.popup_delay_ms", .label = "Key popup delay", .help = "Milliseconds after a leader key; 0 shows it at once. Applies when the TUI next starts.", .kind = .zon },
        .{ .key = "ui.keys.timeout_ms", .label = "Leader timeout", .help = "Milliseconds without a key before the leader gives up; 0 waits. Applies when the TUI next starts.", .kind = .zon },
        .{ .key = "ui.keys.leave_terminal", .label = "Leave Terminal mode", .help = "A key with a modifier, such as ctrl+]. Applies when the TUI next starts.", .kind = .{ .text = .{} } },
    } },
    .{ .name = "Integrations", .fields = &([_]Field{
        .{ .key = "agents.provider", .label = "Default provider (by name)", .help = "Empty: agents.default, with the harness's own login. Settings › Providers sets it.", .kind = .{ .text = .{ .optional = true } } },
        .{ .key = "providers", .label = "Providers as ZON", .help = "A ZON tuple of .{ .name, .harness, .home, .model, .mode }. Settings › Providers edits it.", .kind = .zon },
    } ++ harnessFields("claude_code", "claude-code") ++ harnessFields("codex", "codex") ++ harnessFields("acp", "ACP agent")) },
    .{ .name = "Raw config" },
};

pub const providers_section = 0;
pub const keys_section = 11;
pub const integrations_section = 12;
pub const raw_section = sections.len - 1;
pub const workspaces_section = 2;
pub const agents_section = 3;

/// A config layer: `workspace` and `repo` are what
/// `config.get` and `config.set` then carry.
pub const Layer = struct {
    workspace: ?[]u8 = null,
    repo: ?[]u8 = null,
    /// The file it writes; for the user file, `Settings.user_path`.
    file: ?[]u8 = null,

    pub fn name(self: Layer) []const u8 {
        return if (self.repo != null) "repo" else if (self.workspace != null) "workspace" else "user";
    }

    fn deinit(self: Layer, gpa: Allocator) void {
        if (self.workspace) |p| gpa.free(p);
        if (self.repo) |p| gpa.free(p);
        if (self.file) |p| gpa.free(p);
    }

    fn same(self: Layer, other: Layer) bool {
        return eqlOpt(self.workspace, other.workspace) and eqlOpt(self.repo, other.repo);
    }
};

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const Pending = struct { key: []u8, value: []u8 };

/// What the daemon refused: the code and the key it named.
pub const Failure = struct {
    /// What failed, and so what clears it: values that load again clear
    /// `load`, undoing the change clears `set`, the next save clears them all.
    kind: enum { load, set, reload },
    code: []u8,
    key: []u8,
    path: []u8,

    fn deinit(self: Failure, gpa: Allocator) void {
        gpa.free(self.code);
        gpa.free(self.key);
        gpa.free(self.path);
    }
};

/// Why a request was sent (`app.Purpose.settings`).
pub const Request = union(enum) {
    workspaces,
    harnesses,
    providers,
    /// A `config.get`; only the newest one (`values_request`) counts.
    get: u32,
    set,
    reload,
};

/// One value and where it comes from, from `config.get`'s `sources`.
pub const Source = struct { key: []u8, source: []u8 };

/// One `harness.list` entry, as a line to read: venom shows how to sign in
/// with the harness's own command and never handles vendor credentials.
pub const HarnessRow = struct {
    ok: bool,
    title: []u8,
    detail: []u8,
};

pub const Focus = enum { sections, rows, preview };

/// One `provider.list` entry.
pub const ProviderStatus = struct {
    name: []u8,
    available: bool,
    signed_in: ?bool,
    plan: ?[]u8,
    sign_in: []u8,
};

pub const Settings = struct {
    gpa: Allocator,
    section: usize = 0,
    /// The cursor in each section is reset on moving between them.
    row: usize = 0,
    /// First row drawn; the view keeps the cursor in sight.
    top: usize = 0,
    /// First preview line drawn, and the lines one page of it showed last.
    preview_top: usize = 0,
    preview_page: usize = 8,
    focus: Focus = .sections,
    /// The user layer first, always.
    layers: std.ArrayList(Layer) = .empty,
    layer: usize = 0,
    /// The newest `config.get` sent.
    values_request: u32 = 0,
    /// `$XDG_CONFIG_HOME/venom/config.zon`, for the user layer's title.
    user_path: []const u8 = "config.zon",
    /// The effective config of the layer, normalized; null until loaded.
    effective: ?[]u8 = null,
    sources: std.ArrayList(Source) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    harnesses: std.ArrayList(HarnessRow) = .empty,
    /// The request for `pending[0]` is out (or the reload after the last).
    /// Nothing can be edited meanwhile: an edit could go unsent.
    applying: bool = false,
    /// Changes the running save got into the file.
    applied: usize = 0,
    failure: ?Failure = null,
    /// The last apply changed a setting that needs a daemon restart.
    restart_required: bool = false,
    /// The field the prompt is editing; its key and label are owned (a Raw
    /// config field's point into `sources`, which any `config.get` replaces).
    editing: ?Field = null,
    /// The provider popup, while open.
    popup: ?provider_popup.Popup = null,
    /// `provider.list`: sign-in state and plan per provider name.
    statuses: std.ArrayList(ProviderStatus) = .empty,
    input: term.widgets.TextInput,
    /// `venom settings`: leaving the screen leaves the TUI.
    standalone: bool = false,
    /// `ui.keys.leader` as the Keys section prints it.
    leader: []const u8 = "space",
    /// Leaving was refused once because of unsaved changes.
    leave_armed: bool = false,
    /// `x` was pressed once on the provider with this name: a second `x`
    /// on it removes it. By name, so a reload in between cannot point it
    /// at another provider.
    remove_armed: ?[]u8 = null,

    pub fn init(gpa: Allocator) Settings {
        return .{ .gpa = gpa, .input = .init(gpa, .{ .prompt = "› " }) };
    }

    pub fn deinit(self: *Settings) void {
        if (self.remove_armed) |n| self.gpa.free(n);
        for (self.layers.items) |l| l.deinit(self.gpa);
        self.layers.deinit(self.gpa);
        if (self.effective) |e| self.gpa.free(e);
        self.clearSources();
        self.sources.deinit(self.gpa);
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.clearFailure();
        self.clearHarnesses();
        self.harnesses.deinit(self.gpa);
        self.clearStatuses();
        self.statuses.deinit(self.gpa);
        self.closePopup();
        self.stopEditing();
        self.input.deinit();
    }

    fn clearSources(self: *Settings) void {
        for (self.sources.items) |s| {
            self.gpa.free(s.key);
            self.gpa.free(s.source);
        }
        self.sources.clearRetainingCapacity();
    }

    fn startEditing(self: *Settings, f: Field) !void {
        self.stopEditing();
        const key = try self.gpa.dupe(u8, f.key);
        errdefer self.gpa.free(key);
        const label = try self.gpa.dupe(u8, f.label);
        var owned = f;
        owned.key = key;
        owned.label = label;
        self.editing = owned;
    }

    fn stopEditing(self: *Settings) void {
        if (self.editing) |f| {
            self.gpa.free(f.key);
            self.gpa.free(f.label);
        }
        self.editing = null;
    }

    fn clearHarnesses(self: *Settings) void {
        for (self.harnesses.items) |h| {
            self.gpa.free(h.title);
            self.gpa.free(h.detail);
        }
        self.harnesses.clearRetainingCapacity();
    }

    fn clearPending(self: *Settings) void {
        for (self.pending.items) |p| {
            self.gpa.free(p.key);
            self.gpa.free(p.value);
        }
        self.pending.clearRetainingCapacity();
    }

    fn clearFailure(self: *Settings) void {
        if (self.failure) |f| f.deinit(self.gpa);
        self.failure = null;
    }

    pub fn currentLayer(self: *const Settings) Layer {
        return if (self.layer < self.layers.items.len) self.layers.items[self.layer] else .{};
    }

    /// The file `config set` writes in the current layer.
    pub fn filePath(self: *const Settings) []const u8 {
        return self.currentLayer().file orelse self.user_path;
    }

    // ---- Requests ------------------------------------------------------

    /// Fetches the workspaces (for the picker) and the layer's values.
    pub fn refresh(self: *Settings, app: *App) !void {
        if (!app.connected) return;
        try app.request(.{ .settings = .workspaces }, "workspace.list", struct {}{});
        try app.request(.{ .settings = .harnesses }, "harness.list", struct {}{});
        try self.requestStatuses(app);
        try self.requestValues(app);
    }

    /// Asks each provider's harness whether it is signed in.
    pub fn requestStatuses(self: *Settings, app: *App) !void {
        _ = self;
        if (!app.connected) return;
        try app.request(.{ .settings = .providers }, "provider.list", struct {}{});
    }

    fn requestValues(self: *Settings, app: *App) !void {
        if (!app.connected) return;
        const l = self.currentLayer();
        self.values_request +%= 1;
        try app.request(.{ .settings = .{ .get = self.values_request } }, "config.get", ScopedGet{ .key = "", .workspace = l.workspace, .repo = l.repo });
    }

    const ScopedGet = struct { key: []const u8, workspace: ?[]const u8 = null, repo: ?[]const u8 = null };
    const ScopedSet = struct { key: []const u8, value: []const u8, workspace: ?[]const u8 = null, repo: ?[]const u8 = null };

    fn sendNext(self: *Settings, app: *App) !void {
        const l = self.currentLayer();
        if (self.pending.items.len > 0) {
            const p = self.pending.items[0];
            return app.request(.{ .settings = .set }, "config.set", ScopedSet{ .key = p.key, .value = p.value, .workspace = l.workspace, .repo = l.repo });
        }
        try app.request(.{ .settings = .reload }, "config.reload", struct {}{});
    }

    /// ⌃s: sends the pending changes in order, one at a time; the first the
    /// daemon refuses stops the rest, which stay pending.
    pub fn apply(self: *Settings, app: *App) !void {
        if (self.applying) return;
        if (self.pending.items.len == 0) return app.say("nothing to save", .{});
        if (!app.connected) return app.say("config set: the daemon is not connected", .{});
        self.clearFailure();
        self.restart_required = false;
        self.applying = true;
        self.applied = 0;
        try self.sendNext(app);
    }

    pub fn onDisconnected(self: *Settings) void {
        self.applying = false;
    }

    pub fn onResponse(self: *Settings, app: *App, request: Request, body: @import("proto").Response.Body) !void {
        switch (request) {
            .workspaces => if (body == .ok) try self.setLayers(app, body.ok),
            .harnesses => if (body == .ok) try self.setHarnesses(body.ok),
            .providers => if (body == .ok) try self.setStatuses(body.ok),
            .get => |sent| {
                // Answered after a newer request, or for a layer since left.
                if (sent != self.values_request) return;
                if (body == .ok) {
                    if (self.failure) |f| if (f.kind == .load) self.clearFailure();
                    return self.setValues(body.ok);
                }
                if (body == .@"error") {
                    self.clearValues();
                    try self.fail(.load, body.@"error", "");
                }
            },
            .set => {
                // The layer went while this was out, and the save with it.
                if (!self.applying) return;
                if (body == .@"error") {
                    const key = if (self.pending.items.len > 0) self.pending.items[0].key else "";
                    try self.fail(.set, body.@"error", key);
                    if (std.mem.eql(u8, body.@"error".code, "denied.admin"))
                        app.say("{s}: this pane can't change settings; run `venom settings` outside venomx", .{self.failure.?.key})
                    else
                        app.say("{s}: {s}", .{ self.failure.?.key, body.@"error".code });
                    // What went through before it is in the file now: make
                    // the daemon run it too, then show what is in effect.
                    if (self.applied > 0) return app.request(.{ .settings = .reload }, "config.reload", struct {}{});
                    self.applying = false;
                    return self.requestValues(app);
                }
                if (body == .ok) {
                    if (changeNeedsRestart(body.ok)) self.restart_required = true;
                    self.applied += 1;
                    if (self.pending.items.len > 0) {
                        const p = self.pending.orderedRemove(0);
                        self.gpa.free(p.key);
                        self.gpa.free(p.value);
                    }
                    try self.sendNext(app);
                }
            },
            .reload => {
                self.applying = false;
                if (body == .@"error") {
                    try self.fail(.reload, body.@"error", "");
                    app.say("config reload: {s}", .{body.@"error".code});
                } else if (body == .ok) {
                    if (changeNeedsRestart(body.ok)) self.restart_required = true;
                    if (self.failure) |f| {
                        app.say("{s}: {s}; {d} saved before it and reloaded", .{ f.key, f.code, self.applied });
                    } else if (self.restart_required) {
                        // An on-demand daemon restarts when venom does.
                        if (app.hold != null and app.hold.?.on_demand) app.say("saved; quit every venom and start venom again for it to apply", .{}) else app.say("saved; restart the daemon (venom serve) for it to apply", .{});
                    } else app.say("saved and reloaded", .{});
                }
                try self.requestStatuses(app);
                try self.requestValues(app);
            },
        }
    }

    fn clearValues(self: *Settings) void {
        if (self.effective) |e| self.gpa.free(e);
        self.effective = null;
        self.clearSources();
    }

    fn changeNeedsRestart(ok: Value) bool {
        if (ok != .object) return false;
        const v = ok.object.get("restart_required") orelse return false;
        return v == .bool and v.bool;
    }

    fn fail(self: *Settings, kind: @FieldType(Failure, "kind"), e: @import("proto").Response.Error, fallback_key: []const u8) !void {
        self.clearFailure();
        // `fallback_key` may be a pending entry's, and the old failure's key
        // is not used below.
        var key = fallback_key;
        var path: []const u8 = "";
        if (e.data) |d| if (d == .object) {
            if (d.object.get("key")) |v| if (v == .string and v.string.len > 0) {
                key = v.string;
            };
            if (d.object.get("path")) |v| if (v == .string) {
                path = v.string;
            };
        };
        const code = try self.gpa.dupe(u8, e.code);
        errdefer self.gpa.free(code);
        const key_owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(key_owned);
        const path_owned = try self.gpa.dupe(u8, path);
        self.failure = .{ .kind = kind, .code = code, .key = key_owned, .path = path_owned };
    }

    fn setValues(self: *Settings, ok: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const R = struct { content: []const u8, sources: []const struct { key: []const u8, source: []const u8 } = &.{} };
        const r = std.json.parseFromValueLeaky(R, arena.allocator(), ok, .{ .ignore_unknown_fields = true }) catch return;
        const text = try self.gpa.dupe(u8, try zon_text.normalize(arena.allocator(), r.content));
        if (self.effective) |e| self.gpa.free(e);
        self.effective = text;
        self.clearSources();
        for (r.sources) |s| {
            const key = try self.gpa.dupe(u8, s.key);
            errdefer self.gpa.free(key);
            const source = try self.gpa.dupe(u8, s.source);
            errdefer self.gpa.free(source);
            try self.sources.append(self.gpa, .{ .key = key, .source = source });
        }
    }

    /// `harness.list` answered: found, version, signed in, what to run next.
    fn setHarnesses(self: *Settings, ok: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const R = struct { harnesses: []const struct {
            harness: []const u8,
            enabled: bool = true,
            found: bool = false,
            version: ?[]const u8 = null,
            signed_in: ?bool = null,
            sign_in_detail: ?[]const u8 = null,
            fix: ?[]const u8 = null,
        } = &.{} };
        const r = std.json.parseFromValueLeaky(R, a, ok, .{ .ignore_unknown_fields = true }) catch return;
        self.clearHarnesses();
        for (r.harnesses) |h| {
            const signed = if (h.signed_in) |in| (if (in) "signed in" else "not signed in") else "sign-in unknown";
            const state = if (!h.found) "not found" else signed;
            const title = try std.fmt.allocPrint(self.gpa, "{s}  {s}{s}{s}{s}", .{ h.harness, h.version orelse "", if (h.version != null) " · " else "", state, if (h.enabled) "" else " · disabled" });
            errdefer self.gpa.free(title);
            const detail = try self.gpa.dupe(u8, h.fix orelse h.sign_in_detail orelse "");
            errdefer self.gpa.free(detail);
            try self.harnesses.append(self.gpa, .{ .ok = h.found and h.signed_in != false, .title = title, .detail = detail });
        }
    }

    fn clearStatuses(self: *Settings) void {
        for (self.statuses.items) |x| {
            self.gpa.free(x.name);
            if (x.plan) |p| self.gpa.free(p);
            self.gpa.free(x.sign_in);
        }
        self.statuses.clearRetainingCapacity();
    }

    fn setStatuses(self: *Settings, ok: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const R = struct { providers: []const struct { name: []const u8, available: bool = false, signed_in: ?bool = null, plan: ?[]const u8 = null, sign_in: []const u8 = "" } = &.{} };
        const r = std.json.parseFromValueLeaky(R, arena.allocator(), ok, .{ .ignore_unknown_fields = true }) catch return;
        self.clearStatuses();
        for (r.providers) |x| {
            const name = try self.gpa.dupe(u8, x.name);
            errdefer self.gpa.free(name);
            const plan = if (x.plan) |p| try self.gpa.dupe(u8, p) else null;
            errdefer if (plan) |p| self.gpa.free(p);
            const sign_in = try self.gpa.dupe(u8, x.sign_in);
            errdefer self.gpa.free(sign_in);
            try self.statuses.append(self.gpa, .{ .name = name, .available = x.available, .signed_in = x.signed_in, .plan = plan, .sign_in = sign_in });
        }
    }

    pub fn statusOf(self: *const Settings, name: []const u8) ?ProviderStatus {
        for (self.statuses.items) |x| if (std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    /// `workspace.list` answered: user, then each workspace and its repos.
    /// The picker stays on its layer, by identity. When that layer is gone
    /// its unsaved changes go too, and the screen says so: a change never
    /// moves to another layer's file.
    fn setLayers(self: *Settings, app: *App, ok: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const R = struct { workspaces: []const struct { path: []const u8, repos: []const struct { name: []const u8, path: []const u8 } = &.{} } = &.{} };
        const r = std.json.parseFromValueLeaky(R, a, ok, .{ .ignore_unknown_fields = true }) catch return;
        var next: std.ArrayList(Layer) = .empty;
        errdefer {
            for (next.items) |l| l.deinit(self.gpa);
            next.deinit(self.gpa);
        }
        try next.append(self.gpa, .{});
        for (r.workspaces) |ws| {
            try next.append(self.gpa, .{
                .workspace = try self.gpa.dupe(u8, ws.path),
                .file = try std.fs.path.join(self.gpa, &.{ ws.path, scope.workspace_file }),
            });
            for (ws.repos) |repo| try next.append(self.gpa, .{
                .workspace = try self.gpa.dupe(u8, ws.path),
                .repo = try self.gpa.dupe(u8, repo.name),
                .file = try std.fs.path.join(self.gpa, &.{ repo.path, scope.repo_file }),
            });
        }
        const current = self.currentLayer();
        var at: ?usize = null;
        for (next.items, 0..) |l, i| if (l.same(current)) {
            at = i;
        };
        const gone_name = current.name();
        const dropped = self.pending.items.len;
        if (at == null) {
            self.clearPending();
            self.stopEditing();
            self.clearFailure();
            self.clearValues();
            self.applying = false;
            if (dropped > 0) {
                app.say("the {s} layer is gone: {d} unsaved change{s} dropped; showing the user layer", .{ gone_name, dropped, if (dropped == 1) "" else "s" });
            } else app.say("the {s} layer is gone; showing the user layer", .{gone_name});
        }
        for (self.layers.items) |l| l.deinit(self.gpa);
        self.layers.deinit(self.gpa);
        self.layers = next;
        self.layer = at orelse 0;
        if (at == null) try self.requestValues(app);
    }

    // ---- Values --------------------------------------------------------

    /// The value `key` has now: pending if edited, else the effective one.
    pub fn value(self: *const Settings, key: []const u8) ?[]const u8 {
        for (self.pending.items) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
        return zon_text.valueAt(self.effective orelse return null, key);
    }

    pub fn isPending(self: *const Settings, key: []const u8) bool {
        for (self.pending.items) |p| if (std.mem.eql(u8, p.key, key)) return true;
        return false;
    }

    /// Which layer the key's value comes from (`builtin`, `user`, `repo`…).
    pub fn sourceOf(self: *const Settings, key: []const u8) []const u8 {
        for (self.sources.items) |s| if (std.mem.eql(u8, s.key, key)) return s.source;
        return "";
    }

    /// Whether the current layer's file may set `key`.
    pub fn editable(self: *const Settings, key: []const u8) bool {
        return self.currentLayer().workspace == null or scope.allowedInScope(key);
    }

    /// Makes `value` (ZON) the pending value of `key`. Back to the value in
    /// effect, nothing is pending for it any more.
    pub fn queue(self: *Settings, app: *App, key: []const u8, raw: []const u8) !void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        self.preview_top = 0;
        if (!self.editable(key)) return app.say("{s} is user-only; S switches to the user layer", .{key});
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const normal = try zon_text.normalize(arena.allocator(), raw);
        const effective = if (self.effective) |e| zon_text.valueAt(e, key) else null;
        const same = effective != null and std.mem.eql(u8, effective.?, normal);
        for (self.pending.items, 0..) |*p, i| if (std.mem.eql(u8, p.key, key)) {
            if (same) {
                self.gpa.free(p.key);
                self.gpa.free(p.value);
                _ = self.pending.orderedRemove(i);
                return;
            }
            const v = try self.gpa.dupe(u8, normal);
            self.gpa.free(p.value);
            p.value = v;
            return;
        };
        if (same) return;
        const key_owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(key_owned);
        const value_owned = try self.gpa.dupe(u8, normal);
        errdefer self.gpa.free(value_owned);
        try self.pending.append(self.gpa, .{ .key = key_owned, .value = value_owned });
    }

    /// `u`: drops the newest pending change.
    pub fn undo(self: *Settings, app: *App) void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        const p = self.pending.pop() orelse return app.say("nothing to undo", .{});
        self.gpa.free(p.key);
        self.gpa.free(p.value);
        self.preview_top = 0;
        if (self.failure) |f| if (f.kind == .set) self.clearFailure();
    }

    // ---- What the screen previews --------------------------------------

    /// The effective config once the pending changes are applied.
    pub fn after(self: *const Settings, a: Allocator) ![]const u8 {
        var text: []const u8 = self.effective orelse return "";
        for (self.pending.items) |p| text = (try zon_text.replaced(a, text, p.key, p.value)) orelse text;
        return text;
    }

    /// The pending ZON diff against the effective config.
    pub fn pendingDiff(self: *const Settings, a: Allocator) ![]const zon_text.DiffLine {
        const before = self.effective orelse return &.{};
        return zon_text.diff(a, try zon_text.lines(a, before), try zon_text.lines(a, try self.after(a)), 2);
    }

    /// The `venom config set` argv of a pending change in this layer.
    pub fn argv(self: *const Settings, a: Allocator, p: Pending) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(a, &.{ "venom", "config", "set", try std.fmt.allocPrint(a, "--key={s}", .{p.key}), try std.fmt.allocPrint(a, "--value={s}", .{p.value}) });
        const l = self.currentLayer();
        if (l.workspace) |w| try out.append(a, try std.fmt.allocPrint(a, "--workspace={s}", .{w}));
        if (l.repo) |r| try out.append(a, try std.fmt.allocPrint(a, "--repo={s}", .{r}));
        return out.items;
    }

    /// The same, as a line for a POSIX shell.
    pub fn command(self: *const Settings, a: Allocator, p: Pending) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (try self.argv(a, p), 0..) |arg, i| {
            if (i > 0) try out.append(a, ' ');
            // `--name='value'`: only the value needs quoting.
            const eq = if (std.mem.startsWith(u8, arg, "--")) std.mem.indexOfScalar(u8, arg, '=') else null;
            if (eq) |e| try out.appendSlice(a, arg[0 .. e + 1]);
            try shellQuote(a, &out, if (eq) |e| arg[e + 1 ..] else arg);
        }
        return out.items;
    }

    // ---- Rows ----------------------------------------------------------

    /// The rows of the current section (allocated in `a`).
    pub fn rows(self: *const Settings, a: Allocator) ![]const Row {
        var out: std.ArrayList(Row) = .empty;
        const n = self.section;
        if (n == providers_section) try self.providerRows(a, &out);
        for (sections[n].fields) |f| try out.append(a, .{ .field = f });
        if (n == integrations_section) {
            for (self.harnesses.items) |h| try out.append(a, .{ .info = .{ .title = h.title, .detail = h.detail, .mark = if (h.ok) .ok else .warn } });
        } else if (n == workspaces_section) {
            for (self.layers.items) |l| {
                const w = l.workspace orelse continue;
                if (l.repo) |r| {
                    try out.append(a, .{ .info = .{ .title = try std.fmt.allocPrint(a, "  repo {s}", .{r}), .detail = l.file orelse "" } });
                } else try out.append(a, .{ .info = .{ .title = try std.fmt.allocPrint(a, "Workspace {s}", .{w}), .detail = "Add one with venom workspace add; S picks it as the layer." } });
            }
        } else if (n == keys_section) {
            try out.append(a, .{ .info = .{ .title = "The rest are read-only: no config keys for them yet.", .detail = "These are the bindings in effect." } });
            for (&keys.table) |*b| try out.append(a, .{ .info = .{ .title = try keys.shownKeys(a, b, self.leader), .detail = b.label } });
        } else if (n == raw_section) {
            // Every value in the config, whichever section shows it.
            for (self.sources.items) |s| try out.append(a, .{ .field = .{ .key = s.key, .label = s.key, .kind = .zon } });
        }
        return out.items;
    }

    /// The providers in effect, pending edits included (allocated in `a`).
    pub fn providerList(self: *const Settings, a: Allocator) []const config.Provider {
        return providers_mod.parse(a, self.value("providers"));
    }

    /// `agents.provider` in effect, pending edits included.
    pub fn defaultProvider(self: *const Settings) ?[]const u8 {
        const v = self.value("agents.provider") orelse return null;
        const shown = displayValue(v);
        return if (shown.len == 0) null else shown;
    }

    fn providerRows(self: *const Settings, a: Allocator, out: *std.ArrayList(Row)) !void {
        // Not loaded yet: no rows, and the view says loading.
        if (self.effective == null) return;
        const list = self.providerList(a);
        if (list.len == 0) try out.append(a, .{ .provider = .{} });
        const default = self.defaultProvider();
        for (list, 0..) |p, i| {
            const st = self.statusOf(p.name);
            var status: std.ArrayList(u8) = .empty;
            if (st) |x| {
                try status.appendSlice(a, if (!x.available) "harness off" else if (x.signed_in) |in| (if (in) "signed in" else "not signed in: run its sign-in command") else "sign-in unknown");
                if (x.plan) |plan| if (x.signed_in == true) try status.print(a, ", {s} plan", .{plan});
            } else try status.appendSlice(a, "checking sign-in…");
            try out.append(a, .{ .provider = .{
                .index = i,
                .name = p.name,
                .harness = providers_mod.harnessName(p.harness),
                .login = p.home orelse "default login",
                .model = p.model orelse "default",
                .permission = providers_mod.modeLabel(p.harness, p.mode),
                .status = status.items,
                .default = if (default) |d| std.mem.eql(u8, d, p.name) else false,
                .mark = if (st) |x| (if (x.available and x.signed_in == true) .ok else .warn) else null,
            } });
        }
        if (default) |d| if (config.findProvider(list, d) == null)
            try out.append(a, .{ .info = .{ .title = try std.fmt.allocPrint(a, "Default provider {s} does not exist", .{d}), .detail = "New agents use agents.default until it names a provider.", .mark = .warn } });
    }

    /// The provider under the cursor, when the Providers section shows one.
    pub fn selectedProvider(self: *const Settings, a: Allocator) !?ProviderRow {
        if (self.section != providers_section) return null;
        const rs = try self.rows(a);
        if (self.row >= rs.len or rs[self.row] != .provider) return null;
        const r = rs[self.row].provider;
        return if (r.index == null) null else r;
    }

    fn queueProviders(self: *Settings, app: *App, a: Allocator, list: []const config.Provider) !void {
        try self.queue(app, "providers", try providers_mod.serialize(a, list));
    }

    fn queueDefault(self: *Settings, app: *App, a: Allocator, name: ?[]const u8) !void {
        try self.queue(app, "agents.provider", if (name) |n| try encode(a, .{ .text = .{} }, n) else "null");
    }

    /// ⏎ on a Providers row: the popup, for a new provider or this one.
    fn openPopup(self: *Settings, app: *App, r: ProviderRow) !void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        if (!self.editable("providers")) return app.say("providers are user-only; S switches to the user layer", .{});
        if (self.effective == null) return app.say("providers: not loaded yet", .{});
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = self.providerList(a);
        self.closePopup();
        if (r.index) |i| {
            if (i >= list.len) return;
            const is_default = if (self.defaultProvider()) |d| std.mem.eql(u8, d, list[i].name) else false;
            self.popup = try .init(self.gpa, i, list[i], is_default);
        } else {
            self.popup = try .init(self.gpa, null, .{ .name = try providers_mod.freeName(a, list, "claude"), .harness = .claude_code }, list.len == 0);
        }
    }

    fn closePopup(self: *Settings) void {
        if (self.popup) |*p| p.deinit();
        self.popup = null;
    }

    pub fn popupKey(self: *Settings, app: *App, key: term.Input.Key) !void {
        const p = &self.popup.?;
        switch (try p.key(key)) {
            .none => {},
            .cancel => self.closePopup(),
            .save => try self.savePopup(app),
            .remove => try self.removePopup(app),
        }
    }

    /// The popup's provider into `providers` (and `agents.provider`), saved
    /// at once.
    fn savePopup(self: *Settings, app: *App) !void {
        const pop = &self.popup.?;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(config.Provider) = .empty;
        try list.appendSlice(a, self.providerList(a));
        const p = pop.provider();
        if (try self.popupProblem(a)) |why| return pop.setFailure("{s}", .{why});
        const default = self.defaultProvider();
        var was_default = false;
        if (pop.index) |i| {
            if (i >= list.items.len) return self.closePopup();
            was_default = if (default) |d| std.mem.eql(u8, d, list.items[i].name) else false;
            list.items[i] = p;
        } else try list.append(a, p);
        try self.queueProviders(app, a, list.items);
        if (pop.default) {
            if (!was_default or !std.mem.eql(u8, default.?, p.name)) try self.queueDefault(app, a, p.name);
        } else if (was_default) try self.queueDefault(app, a, null);
        const name = try a.dupe(u8, p.name);
        const new = pop.index == null;
        self.closePopup();
        try self.apply(app);
        if (new) app.say("{s} added; sign in with the command on its row if it says not signed in", .{name});
    }

    /// Why the popup's provider cannot be saved as it is; null when it can.
    /// The popup shows it as you type; a save is refused with it.
    pub fn popupProblem(self: *const Settings, a: Allocator) !?[]const u8 {
        const pop = if (self.popup) |*x| x else return null;
        const p = pop.provider();
        if (p.name.len == 0) return "name it: spawns and the CLI pick a provider by name";
        if (!config.Provider.validName(p.name)) return "the name is 1 to 64 characters, with no space at either end";
        for (self.providerList(a), 0..) |q, i| if (std.mem.eql(u8, q.name, p.name) and (pop.index == null or pop.index.? != i))
            return try std.fmt.allocPrint(a, "another provider is named {s}", .{p.name});
        if (p.home) |h| if (!(std.fs.path.isAbsolute(h) or std.mem.eql(u8, h, "~") or std.mem.startsWith(u8, h, "~/")))
            return "the config dir is absolute or starts with ~/";
        return null;
    }

    fn removePopup(self: *Settings, app: *App) !void {
        const i = self.popup.?.index orelse return;
        self.closePopup();
        try self.removeAt(app, i);
    }

    /// Removes provider `i` (and the default, when it was), saved at once.
    fn removeAt(self: *Settings, app: *App, i: usize) !void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        if (!self.editable("providers")) return app.say("providers are user-only; S switches to the user layer", .{});
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = self.providerList(a);
        if (i >= list.len) return;
        const next = try std.mem.concat(a, config.Provider, &.{ list[0..i], list[i + 1 ..] });
        try self.queueProviders(app, a, next);
        if (self.defaultProvider()) |d| if (std.mem.eql(u8, d, list[i].name)) try self.queueDefault(app, a, null);
        self.row -|= 1;
        try self.apply(app);
        // apply says why when it did not start (no daemon): keep that.
        if (self.applying) app.say("{s} removed", .{list[i].name});
    }

    /// `d` on a provider: it becomes the default for new agents, or stops
    /// being it. Saved at once, as the popup saves.
    fn toggleDefault(self: *Settings, app: *App, i: usize) !void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        if (!self.editable("agents.provider")) return app.say("the default provider is user-only; S switches to the user layer", .{});
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = self.providerList(a);
        if (i >= list.len) return;
        const name = list[i].name;
        const was = if (self.defaultProvider()) |d| std.mem.eql(u8, d, name) else false;
        try self.queueDefault(app, a, if (was) null else name);
        try self.apply(app);
        if (!self.applying) return;
        if (was) app.say("no default provider: new agents use agents.default", .{}) else app.say("{s} is the default provider", .{name});
    }

    // ---- Keys ----------------------------------------------------------

    /// A key from inside a bracketed paste: text for a prompt, nothing else.
    /// A paste never saves, toggles or submits.
    pub fn pasted(self: *Settings, key: term.Input.Key) !void {
        if ((self.editing == null and self.popup == null) or !k.pressed(key)) return;
        if (keys.pastedBreak(key)) return if (self.popup) |*p| p.paste(" ") else self.input.insert(" ");
        if (key.mods.ctrl or key.mods.alt or key.codepoint < 0x20 or key.codepoint == 0x7f) return;
        // Private use: functional keys, not text.
        if (key.codepoint >= 0xE000 and key.codepoint <= 0xF8FF) return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(key.codepoint, &buf) catch return;
        if (self.popup) |*p| return p.paste(buf[0..n]);
        try self.input.insert(buf[0..n]);
    }

    pub fn handleKey(self: *Settings, app: *App, key: term.Input.Key) !void {
        if (!k.pressed(key)) return;
        if (self.popup != null) return self.popupKey(app, key);
        if (self.editing != null) return self.promptKey(app, key);
        const ctrl_c = k.ctrl(key, 'c');
        const leaving = ctrl_c or k.char(key, 'q') or k.named(key, .escape);
        if (!leaving) self.leave_armed = false;
        const arming = self.remove_armed;
        self.remove_armed = null;
        defer if (arming) |n| self.gpa.free(n);
        if (leaving) return self.leave(app, ctrl_c or k.char(key, 'q') or self.standalone);
        if (k.char(key, '?')) {
            app.help = true;
            return;
        }
        app.message.clearRetainingCapacity();
        if (k.ctrl(key, 's')) return self.apply(app);
        if (k.char(key, 'u')) return self.undo(app);
        if (k.char(key, 'S')) return self.nextLayer(app);
        if (self.section == providers_section and k.char(key, 'n')) return self.openPopup(app, .{});
        if (k.named(key, .page_down)) {
            self.preview_top += self.preview_page;
            return;
        }
        if (k.named(key, .page_up)) {
            self.preview_top -|= self.preview_page;
            return;
        }
        const a = app.frame.allocator();
        const rs = try self.rows(a);
        // sections ↔ rows ↔ preview; a section with no rows is skipped.
        if (k.namedAny(key, .tab)) {
            const back = key.mods.shift;
            self.focus = switch (self.focus) {
                .sections => if (back) .preview else if (rs.len > 0) .rows else .preview,
                .rows => if (back) .sections else .preview,
                .preview => if (!back) .sections else if (rs.len > 0) .rows else .sections,
            };
            return;
        }
        // On a toggle or a choice `h l` step the value;
        // on anything else they go to the next pane, as ⇥ does.
        const step_back = k.char(key, 'h') or k.named(key, .left);
        const step_on = k.char(key, 'l') or k.named(key, .right);
        if ((step_back or step_on) and self.focus == .rows and self.row < rs.len and rs[self.row] == .field) {
            const f = rs[self.row].field;
            if (f.kind == .toggle or f.kind == .choice) return self.edit(app, f, step_back);
        }
        if (k.char(key, 'l') or k.named(key, .right)) {
            self.focus = switch (self.focus) {
                .sections => if (rs.len > 0) .rows else .preview,
                .rows, .preview => .preview,
            };
            return;
        }
        if (k.char(key, 'h') or k.named(key, .left)) {
            self.focus = switch (self.focus) {
                .preview => if (rs.len > 0) .rows else .sections,
                .rows, .sections => .sections,
            };
            return;
        }
        const down = k.char(key, 'j') or k.named(key, .down);
        const up = k.char(key, 'k') or k.named(key, .up);
        if (self.focus == .preview) {
            if (down) self.preview_top += 1 else if (up) self.preview_top -|= 1;
            return;
        }
        if (self.focus == .sections) {
            if (down or up) {
                self.section = if (down) @min(self.section + 1, sections.len - 1) else self.section -| 1;
                self.row = 0;
                self.top = 0;
            } else if (k.named(key, .enter) and rs.len > 0) self.focus = .rows;
            return;
        }
        if (down or up) {
            self.row = if (down) @min(self.row + 1, rs.len -| 1) else self.row -| 1;
            return;
        }
        if (self.row >= rs.len) return;
        const row = rs[self.row];
        if (row == .provider) {
            const r = row.provider;
            if (k.named(key, .enter)) return self.openPopup(app, r);
            const i = r.index orelse return;
            if (k.char(key, 'd')) return self.toggleDefault(app, i);
            if (k.char(key, 'x')) {
                if (arming) |n| if (std.mem.eql(u8, n, r.name)) return self.removeAt(app, i);
                self.remove_armed = try self.gpa.dupe(u8, r.name);
                return app.say("x again removes {s}; any other key keeps it", .{r.name});
            }
            return;
        }
        if (row != .field) return;
        if (k.named(key, .enter)) return self.edit(app, row.field, false);
    }

    /// ⏎ on a field, or `h l` on one that steps; `back` steps a choice back.
    fn edit(self: *Settings, app: *App, f: Field, back: bool) !void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        if (!self.editable(f.key)) return app.say("{s} is user-only; S switches to the user layer", .{f.key});
        const now = self.value(f.key) orelse return app.say("{s}: not loaded yet", .{f.key});
        switch (f.kind) {
            .toggle => try self.queue(app, f.key, if (std.mem.eql(u8, now, "true")) "false" else "true"),
            .choice => |names| {
                var at: usize = 0;
                for (names, 0..) |n, i| if (std.mem.eql(u8, n, now)) {
                    at = if (back) i + names.len - 1 else i + 1;
                };
                try self.queue(app, f.key, names[at % names.len]);
            },
            .zon, .text => {
                try self.input.setText(if (f.kind == .text) displayValue(now) else now);
                self.input.opts.placeholder = if (f.kind == .text and f.kind.text.optional) "empty for none" else "";
                try self.startEditing(f);
            },
        }
    }

    fn promptKey(self: *Settings, app: *App, key: term.Input.Key) !void {
        if (k.ctrl(key, 'c')) return self.input.clear();
        if (k.named(key, .escape)) return self.stopEditing();
        if (!k.named(key, .enter)) {
            _ = try self.input.handleKey(key);
            return;
        }
        const f = self.editing.?;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const encoded = try encode(arena.allocator(), f.kind, self.input.value());
        if (encoded.len == 0) return app.say("{s}: write a value, or esc", .{f.key});
        defer self.stopEditing();
        try self.queue(app, f.key, encoded);
    }

    fn nextLayer(self: *Settings, app: *App) !void {
        if (self.applying) return app.say("saving: wait for it to finish", .{});
        if (self.pending.items.len > 0) return app.say("{d} unsaved in this layer: ⌃s saves, u undoes", .{self.pending.items.len});
        if (self.layers.items.len < 2) return app.say("only the user layer: add a workspace with venom workspace add", .{});
        self.layer = (self.layer + 1) % self.layers.items.len;
        self.clearFailure();
        self.clearValues();
        try self.requestValues(app);
    }

    /// Leaves the screen; `quit` leaves the TUI. Unsaved changes ask once.
    pub fn leave(self: *Settings, app: *App, quit: bool) !void {
        if (self.applying and !quit) return app.say("saving: wait for it to finish", .{});
        if ((self.pending.items.len > 0 or self.applying) and !self.leave_armed) {
            self.leave_armed = true;
            // Short, and the words that matter first: a popup's bar is narrow.
            return app.say("{d} unsaved: again drops, ⌃s saves", .{self.pending.items.len});
        }
        self.leave_armed = false;
        self.clearPending();
        self.clearFailure();
        if (quit) {
            app.quit = true;
            return;
        }
        app.screen = .main;
    }
};

/// A ZON value as the field shows it: a string without its quotes.
pub fn displayValue(v: []const u8) []const u8 {
    if (std.mem.eql(u8, v, "null")) return "";
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"' and std.mem.indexOfScalar(u8, v, '\\') == null) return v[1 .. v.len - 1];
    return v;
}

/// What the prompt's text means as a ZON value of this field; empty when it
/// has none (a ZON field left blank).
pub fn encode(a: Allocator, kind: Kind, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    return switch (kind) {
        .text => |o| blk: {
            if (t.len == 0 or std.mem.eql(u8, t, "null")) {
                if (o.optional) break :blk "null";
            }
            if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') break :blk t;
            var out: std.Io.Writer.Allocating = .init(a);
            std.zon.stringify.serialize(t, .{ .whitespace = false }, &out.writer) catch return error.OutOfMemory;
            break :blk out.written();
        },
        else => t,
    };
}

fn shellQuote(a: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    const safe = arg.len > 0 and for (arg) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "._-/=:,@%+", ch) == null) break false;
    } else true;
    if (safe) return out.appendSlice(a, arg);
    try out.append(a, '\'');
    for (arg) |ch| if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    try out.append(a, '\'');
}

const testing = std.testing;

test "the sections are in order, and every config value is in one" {
    const names = [_][]const u8{ "Providers", "General", "Workspaces", "Agents", "Models and limits", "Permissions and grants", "Worktrees", "Attention", "Transcript", "Usage and budgets", "Appearance", "Keys", "Integrations", "Raw config" };
    for (names, sections) |n, s| try testing.expectEqualStrings(n, s.name);
    try testing.expectEqualStrings("Keys", sections[keys_section].name);
    try testing.expectEqualStrings("Workspaces", sections[workspaces_section].name);
    try testing.expectEqualStrings("Agents", sections[agents_section].name);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var store = try config.Store.init(testing.allocator, .{ .io = testing.io, .path = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir}), .validate = config.validate });
    defer store.deinit();
    // Every field names a value the config has…
    const found = try store.lookup(a, "");
    const effective = try zon_text.normalize(a, found.content);
    for (sections) |s| for (s.fields) |f| {
        if (zon_text.valueAt(effective, f.key) == null) std.debug.print("no such key: {s}\n", .{f.key});
        try testing.expect(zon_text.valueAt(effective, f.key) != null);
        switch (f.kind) {
            // …and a choice's names are the type's: the value in effect is one.
            .choice => |names_| {
                const now = zon_text.valueAt(effective, f.key).?;
                var known = false;
                for (names_) |n| known = known or std.mem.eql(u8, n, now);
                try testing.expect(known);
            },
            .toggle => try testing.expect(std.mem.eql(u8, zon_text.valueAt(effective, f.key).?, "true") or std.mem.eql(u8, zon_text.valueAt(effective, f.key).?, "false")),
            else => {},
        }
    };
    // …and every value is on a field of some section.
    for (found.sources) |e| {
        var shown = false;
        for (sections) |s| for (s.fields) |f| {
            shown = shown or std.mem.eql(u8, f.key, e.key);
        };
        if (!shown) std.debug.print("in no section: {s}\n", .{e.key});
        try testing.expect(shown);
    }
}

test "encode: strings get quoted, an empty optional is null, ZON stays as typed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\"2m\"", try encode(a, .{ .text = .{} }, " 2m "));
    try testing.expectEqualStrings("\"2m\"", try encode(a, .{ .text = .{} }, "\"2m\""));
    try testing.expectEqualStrings("null", try encode(a, .{ .text = .{ .optional = true } }, ""));
    try testing.expectEqualStrings("\"\"", try encode(a, .{ .text = .{} }, ""));
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", try encode(a, .{ .text = .{} }, "say \"hi\""));
    try testing.expectEqualStrings("7", try encode(a, .zon, " 7"));
    try testing.expectEqualStrings("", try encode(a, .zon, " "));
    try testing.expectEqualStrings("2m", displayValue("\"2m\""));
    try testing.expectEqualStrings("", displayValue("null"));
    try testing.expectEqualStrings(".ask", displayValue(".ask"));
}

test "shell quoting: plain words stay, anything else is one quoted word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ ".ask", "\"2m\"", "it's", "" }) |arg| {
        try shellQuote(a, &out, arg);
        try out.append(a, ' ');
    }
    try testing.expectEqualStrings(".ask '\"2m\"' 'it'\\''s' '' ", out.items);
}
