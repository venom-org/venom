//! venom's typed configuration. Every settings
//! key is a field here with its default; venom-std's `cfg` store derives
//! `config get|set|check|reload|schema` from it. Enum-typed keys take ZON enum
//! literals (`.auto`, not `"auto"`). Durations are strings such as
//! `"3d"`, `"2m"` or `"5s"` (see `Duration`), checked by `validate`.
//! Readers take `Store.current()` each time they need a value, so a reload or
//! `config set` applies without a restart. Workspace and repo files above the
//! user file, and which keys each may set, are in scope.zig.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const log = @import("log");

/// Harnesses venom has (or is building) an adapter for. Values are
/// added as adapters land; ids match the `harness.<h>` config keys.
pub const Harness = enum { claude_code, codex };

/// venom's permission mode for a new agent; each adapter maps it to the
/// harness's own modes (its `permission_modes`). A child inherits its
/// parent's mode, never more.
pub const Mode = enum {
    /// Ask the human before edits and commands (the harness default).
    ask,
    /// Accept file edits in the agent's worktree; ask before commands.
    accept_edits,
    /// Plan first; the plan waits for approval before the agent acts.
    plan,
    /// The harness's own classifier approves routine, low-risk actions;
    /// risky or hard-to-undo ones still ask (Claude Code's `auto`).
    auto,
    /// Everything is approved with no prompts, venom's approvals and scope
    /// checks included (Claude Code's `bypassPermissions`). Only for
    /// sandboxed or throwaway environments.
    bypass_permissions,
};

/// How an agent's repos are isolated.
pub const Isolation = enum { worktree, in_place, copy };
/// `host` runs as a venomx control pane, `own` full screen,
/// `auto` picks `host` when a venomx daemon is reachable.
pub const Chrome = enum { auto, own, host };
/// Grouping of the agent list.
pub const GroupBy = enum { state, workspace, repo };
/// Sub-agent display.
pub const Children = enum { tree, folded, hidden };
/// Transcript density.
pub const Density = enum { compact, normal, verbose };

pub const Agents = struct {
    /// Harness for a new agent when none is named and no default
    /// provider is set.
    default: Harness = .claude_code,
    /// The default provider (`providers[].name`) for a new agent that names
    /// neither a provider nor a harness. Null: `default`, with the harness's
    /// own login, model and mode.
    provider: ?[]const u8 = null,
    mode: Mode = .ask,
    isolation: Isolation = .worktree,
    /// Live agents at once, children included. At least 1.
    max_concurrent: u16 = 6,
    spawn: struct {
        /// Agents may spawn agents through venom's MCP server.
        allow: bool = true,
        /// Maximum tree depth, counting the top-level agent as 1: the
        /// default 2 allows children and denies their children.
        depth: u8 = 2,
    } = .{},
    /// Settled agents are archived after this long.
    archive_after: []const u8 = "3d",
};

/// How the inbox gets a human's attention.
pub const Attention = struct {
    /// BEL for blocking attention kinds.
    bell: bool = true,
    /// `notify.post` after a blocking item waits this long unanswered.
    notify_after: []const u8 = "2m",
    /// Deny an unanswered approval with reason `timeout`; null waits forever.
    approval_timeout: ?[]const u8 = null,
};

/// A chord that can be `ui.keys.leader`. A plain key is safe, because Input and
/// Terminal never see the leader; `esc` and `backspace`
/// are what leader mode itself uses.
pub fn validLeader(text: []const u8) bool {
    const chord = @import("venom-term").chrome.keys;
    const c = chord.parseChord(text) orelse return false;
    return !c.eql(chord.parseChord("escape").?) and !c.eql(chord.parseChord("backspace").?);
}

pub const Ui = struct {
    chrome: Chrome = .auto,
    group_by: GroupBy = .state,
    children: Children = .tree,
    transcript: struct {
        density: Density = .normal,
        /// A running call opens (with a live tail) after this long.
        open_running_after: []const u8 = "5s",
    } = .{},
    context: struct {
        /// Percent of the context window above which the meter turns gold (0..100).
        warn_at: u8 = 80,
    } = .{},
    keys: struct {
        /// Opens the key tree in Normal mode.
        leader: []const u8 = "space",
        /// The chord that leaves Terminal mode.
        leave_terminal: []const u8 = "ctrl+]",
        /// How long after a leader key the popup appears; 0 shows it at once.
        popup_delay_ms: u32 = 200,
        /// How long the leader waits for a key; 0 waits forever.
        timeout_ms: u32 = 0,
    } = .{},
};

/// One harness's settings. They are read
/// when the daemon starts its harness host, so a change needs a restart.
pub const HarnessEntry = struct {
    /// Offer this harness: its adapter is registered with the host.
    enabled: bool = true,
    /// The harness binary; null finds it on `PATH`.
    path: ?[]const u8 = null,
    /// Appended after the adapter's own flags. `doctor` warns when one
    /// repeats an adapter flag.
    extra_args: []const []const u8 = &.{},
};

/// `harness.acp`: a `HarnessEntry` that is off by default.
pub const AcpEntry = struct {
    enabled: bool = false,
    /// The agent's command; required when enabled.
    path: ?[]const u8 = null,
    /// Its arguments, such as the flag that makes it speak ACP.
    extra_args: []const []const u8 = &.{},
};

/// A provider: a named instance of a harness with its own login, default
/// model and default permission mode. Several providers may share a
/// harness, such as a work and a personal Claude account.
pub const Provider = struct {
    /// How agents, the CLI and the TUI name it, such as `work` or
    /// `Personal Max`: 1 to 64 bytes of text with no control characters and
    /// no space at either end; unique.
    name: []const u8 = "",
    harness: Harness = .claude_code,
    /// The auth: the harness's config folder (`CLAUDE_CONFIG_DIR` for
    /// claude-code, `CODEX_HOME` for codex), which holds its login. A
    /// leading `~/` is the home folder. Null: the harness's default login.
    /// Sign in once with the harness's own command, e.g.
    /// `CLAUDE_CONFIG_DIR=~/.claude_personal claude auth login`.
    home: ?[]const u8 = null,
    /// The model for its agents when the spawn names none. Null: the
    /// harness's default.
    model: ?[]const u8 = null,
    /// The permission mode for its agents when the spawn names none. Null:
    /// `agents.mode`.
    mode: ?Mode = null,

    /// Whether `name` can name a provider.
    pub fn validName(name: []const u8) bool {
        if (name.len == 0 or name.len > 64) return false;
        if (name[0] == ' ' or name[name.len - 1] == ' ') return false;
        if (!std.unicode.utf8ValidateSlice(name)) return false;
        for (name) |ch| if (ch < 0x20 or ch == 0x7f) return false;
        return true;
    }

    /// The environment variable `home` sets for this provider's harness.
    pub fn homeEnv(h: Harness) []const u8 {
        return switch (h) {
            .claude_code => "CLAUDE_CONFIG_DIR",
            .codex => "CODEX_HOME",
        };
    }

    /// `home` with a leading `~` or `~/` made absolute with `user_home`.
    /// Null when `home` is null, or relative and cannot be made absolute.
    pub fn resolvedHome(self: Provider, gpa: std.mem.Allocator, user_home: ?[]const u8) !?[]const u8 {
        const h = self.home orelse return null;
        if (std.mem.eql(u8, h, "~") or std.mem.startsWith(u8, h, "~/")) {
            const base = user_home orelse return null;
            return try std.fs.path.join(gpa, &.{ base, h[1..] });
        }
        if (!std.fs.path.isAbsolute(h)) return null;
        return h;
    }
};

/// The provider named `name` in `list`, or null.
pub fn findProvider(list: []const Provider, name: []const u8) ?Provider {
    for (list) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// The harness host's settings.
pub const Harnesses = struct {
    claude_code: HarnessEntry = .{},
    codex: HarnessEntry = .{},
    /// One ACP agent, as harness `acp`: off until `path` names it,
    /// since no ACP agent is a default. There are no named agents yet.
    acp: AcpEntry = .{},
    /// How long a clean shutdown waits for running turns to end, and then
    /// for the processes to exit before SIGKILL.
    shutdown_grace: []const u8 = "5s",
    /// A harness that reports no `session` within this is stopped.
    start_timeout: []const u8 = "30s",
    /// Bytes of tool output or diff kept inline per call.
    body_max: u32 = 262_144,
    /// Sent by retry, and after a stale request is answered.
    resume_prompt: []const u8 = "Continue from where you stopped.",

    pub fn entry(self: Harnesses, h: Harness) HarnessEntry {
        return switch (h) {
            .claude_code => self.claude_code,
            .codex => self.codex,
        };
    }
};

pub const Config = struct {
    /// Grant policy for callers without a token; read-only by default.
    grants: proto.grants.Policy = .{},
    /// Log levels and formats; applied live on `config set` and reloads.
    log: log.Config = .{},
    agents: Agents = .{},
    attention: Attention = .{},
    ui: Ui = .{},
    harness: Harnesses = .{},
    /// Named instances of the harnesses, each with its own login, default
    /// model and permission mode. `agents.provider` picks the default.
    providers: []const Provider = &.{},
    /// Restart-only: whether a bare `venom` may start a missing daemon, and
    /// its startup budget.
    daemon: @import("lifecycle.zig").Settings = .{},
};

/// `harness.<h>.*` pick the adapters the host registers at start,
/// so they apply on the next `venom serve`; the other `harness.*` keys apply
/// live.
pub const Store = cfg.Store(Config, &([_]cfg.FieldPolicy{
    .{ .key = "harness.claude_code", .restart = true },
    .{ .key = "harness.codex", .restart = true },
    .{ .key = "harness.acp", .restart = true },
} ++ @import("lifecycle.zig").policies));

/// Rejects values the type alone allows but venom does not, naming the key.
pub fn validate(value: Config) ?cfg.Validation {
    value.grants.check() catch return .{ .key = "grants" };
    if (value.agents.max_concurrent == 0) return .{ .key = "agents.max_concurrent" };
    if (!Duration.valid(value.agents.archive_after)) return .{ .key = "agents.archive_after" };
    if (!Duration.valid(value.attention.notify_after)) return .{ .key = "attention.notify_after" };
    if (value.attention.approval_timeout) |t| if (!Duration.valid(t)) return .{ .key = "attention.approval_timeout" };
    if (!Duration.valid(value.ui.transcript.open_running_after)) return .{ .key = "ui.transcript.open_running_after" };
    if (value.ui.context.warn_at > 100) return .{ .key = "ui.context.warn_at" };
    // A plain key could never reach the program in Terminal mode.
    const leave = @import("venom-term").chrome.keys.parseChord(value.ui.keys.leave_terminal) orelse return .{ .key = "ui.keys.leave_terminal" };
    if (leave.plain()) return .{ .key = "ui.keys.leave_terminal" };
    if (!validLeader(value.ui.keys.leader)) return .{ .key = "ui.keys.leader" };
    if (!durationFits(u32, value.harness.shutdown_grace)) return .{ .key = "harness.shutdown_grace" };
    if (!durationFits(u32, value.harness.start_timeout)) return .{ .key = "harness.start_timeout" };
    if (value.harness.body_max == 0) return .{ .key = "harness.body_max" };
    value.daemon.check() catch return .{ .key = "daemon.startup_timeout_ms" };
    if (value.harness.resume_prompt.len == 0) return .{ .key = "harness.resume_prompt" };
    inline for (@typeInfo(Harness).@"enum".field_names) |name| {
        const e = @field(value.harness, name);
        if (e.path) |p| if (p.len == 0) return .{ .key = "harness." ++ name ++ ".path" };
        for (e.extra_args) |arg| if (arg.len == 0) return .{ .key = "harness." ++ name ++ ".extra_args" };
    }
    const acp = value.harness.acp;
    if (acp.path) |p| if (p.len == 0) return .{ .key = "harness.acp.path" };
    for (acp.extra_args) |arg| if (arg.len == 0) return .{ .key = "harness.acp.extra_args" };
    // Nothing to run otherwise: no ACP agent has a well-known name.
    if (acp.enabled and acp.path == null) return .{ .key = "harness.acp.path" };
    for (value.providers, 0..) |p, i| {
        if (!Provider.validName(p.name)) return .{ .key = "providers" };
        for (value.providers[0..i]) |q| if (std.mem.eql(u8, p.name, q.name)) return .{ .key = "providers" };
        if (p.home) |h| if (h.len == 0 or !(std.fs.path.isAbsolute(h) or std.mem.eql(u8, h, "~") or std.mem.startsWith(u8, h, "~/"))) return .{ .key = "providers" };
        if (p.model) |m| if (m.len == 0) return .{ .key = "providers" };
    }
    // `agents.provider` naming no provider is not refused: a rename or a
    // removal can then be saved one key at a time. A spawn falls back to
    // `agents.default`.
    if (value.agents.provider) |name| if (name.len == 0) return .{ .key = "agents.provider" };
    return null;
}

/// A valid duration whose milliseconds fit in `T` (the host keeps u32).
fn durationFits(comptime T: type, text: []const u8) bool {
    const ms = Duration.parseMs(text) catch return false;
    return ms <= std.math.maxInt(T);
}

/// A config duration: a positive whole number and one unit, `ms`, `s`, `m`,
/// `h` or `d` (`"500ms"`, `"5s"`, `"2m"`, `"3d"`). No sign, spaces, fractions
/// or compound forms; the value must fit in milliseconds as a u64.
pub const Duration = struct {
    pub fn parseMs(text: []const u8) error{InvalidDuration}!u64 {
        var i: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == 0 or i == text.len) return error.InvalidDuration;
        const n = std.fmt.parseInt(u64, text[0..i], 10) catch return error.InvalidDuration;
        if (n == 0) return error.InvalidDuration;
        const units = [_]struct { []const u8, u64 }{
            .{ "ms", 1 },
            .{ "s", std.time.ms_per_s },
            .{ "m", std.time.ms_per_min },
            .{ "h", std.time.ms_per_hour },
            .{ "d", std.time.ms_per_day },
        };
        for (units) |u| if (std.mem.eql(u8, text[i..], u[0])) {
            return std.math.mul(u64, n, u[1]) catch error.InvalidDuration;
        };
        return error.InvalidDuration;
    }
    pub fn valid(text: []const u8) bool {
        _ = parseMs(text) catch return false;
        return true;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const a = testing.allocator;

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    path: []u8,
    store: Store,
    arena: std.heap.ArenaAllocator,
    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        errdefer a.free(self.dir);
        self.path = try std.fmt.allocPrint(a, "{s}/config.zon", .{self.dir});
        errdefer a.free(self.path);
        self.store = try Store.init(a, .{ .io = testing.io, .path = self.path, .validate = validate });
        self.arena = .init(a);
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.store.deinit();
        a.free(self.path);
        a.free(self.dir);
        self.tmp.cleanup();
    }
    /// `config set` then `config reload`, as the daemon applies a change.
    fn apply(self: *Fixture, key: []const u8, value: []const u8) !void {
        _ = try self.store.set(key, value);
        const change = try self.store.reload();
        try testing.expect(!change.restart_required);
    }
    fn expectRejected(self: *Fixture, key: []const u8, value: []const u8, failing: []const u8) !void {
        const before = try self.store.get(self.arena.allocator(), key);
        try testing.expectError(error.InvalidConfig, self.store.set(key, value));
        try testing.expectEqualStrings(failing, self.store.failure.key());
        try testing.expectEqualStrings(before, try self.store.get(self.arena.allocator(), key));
    }
};

test "Duration parses ms, s, m, h and d and rejects anything else" {
    try testing.expectEqual(@as(u64, 500), try Duration.parseMs("500ms"));
    try testing.expectEqual(@as(u64, 5_000), try Duration.parseMs("5s"));
    try testing.expectEqual(@as(u64, 120_000), try Duration.parseMs("2m"));
    try testing.expectEqual(@as(u64, 3_600_000), try Duration.parseMs("1h"));
    try testing.expectEqual(@as(u64, 3 * 86_400_000), try Duration.parseMs("3d"));
    for ([_][]const u8{ "", "5", "s", "0s", "-5s", "+5s", "5 s", " 5s", "1.5s", "5S", "5sec", "1h30m", "5w", "99999999999999999999d", "18446744073709551615d" }) |bad| {
        if (Duration.valid(bad)) std.debug.print("accepted: {s}\n", .{bad});
        try testing.expect(!Duration.valid(bad));
    }
}

test "defaults match the documented ones" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = f.store.current();
    try testing.expectEqual(Harness.claude_code, c.agents.default);
    try testing.expectEqual(Mode.ask, c.agents.mode);
    try testing.expectEqual(Isolation.worktree, c.agents.isolation);
    try testing.expectEqual(@as(u16, 6), c.agents.max_concurrent);
    try testing.expect(c.agents.spawn.allow);
    try testing.expectEqual(@as(u8, 2), c.agents.spawn.depth);
    try testing.expectEqualStrings("3d", c.agents.archive_after);
    try testing.expect(c.attention.bell);
    try testing.expectEqualStrings("2m", c.attention.notify_after);
    try testing.expectEqual(@as(?[]const u8, null), c.attention.approval_timeout);
    try testing.expectEqual(Chrome.auto, c.ui.chrome);
    try testing.expectEqual(GroupBy.state, c.ui.group_by);
    try testing.expectEqual(Children.tree, c.ui.children);
    try testing.expectEqual(Density.normal, c.ui.transcript.density);
    try testing.expectEqualStrings("5s", c.ui.transcript.open_running_after);
    try testing.expectEqual(@as(u8, 80), c.ui.context.warn_at);
    // The documented settings, as a ZON file, are a valid config with the same values.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = @embedFile("testdata/documented-settings.zon") });
    try f.store.check();
    _ = try f.store.reload();
    try testing.expectEqualDeep(Config{}, f.store.current());
}

test "config schema lists every key with its type and default" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, try f.store.schema(f.arena.allocator()), .{});
    defer parsed.deinit();
    const Want = struct { key: []const u8, type: []const u8, default: []const u8 };
    const want = [_]Want{
        .{ .key = "agents.default", .type = "string", .default = "\"claude_code\"" },
        .{ .key = "agents.mode", .type = "string", .default = "\"ask\"" },
        .{ .key = "agents.isolation", .type = "string", .default = "\"worktree\"" },
        .{ .key = "agents.max_concurrent", .type = "integer", .default = "6" },
        .{ .key = "agents.spawn.allow", .type = "boolean", .default = "true" },
        .{ .key = "agents.spawn.depth", .type = "integer", .default = "2" },
        .{ .key = "agents.archive_after", .type = "string", .default = "\"3d\"" },
        .{ .key = "attention.bell", .type = "boolean", .default = "true" },
        .{ .key = "attention.notify_after", .type = "string", .default = "\"2m\"" },
        .{ .key = "attention.approval_timeout", .type = "", .default = "null" },
        .{ .key = "ui.chrome", .type = "string", .default = "\"auto\"" },
        .{ .key = "ui.group_by", .type = "string", .default = "\"state\"" },
        .{ .key = "ui.children", .type = "string", .default = "\"tree\"" },
        .{ .key = "ui.transcript.density", .type = "string", .default = "\"normal\"" },
        .{ .key = "ui.transcript.open_running_after", .type = "string", .default = "\"5s\"" },
        .{ .key = "ui.context.warn_at", .type = "integer", .default = "80" },
        .{ .key = "ui.keys.leader", .type = "string", .default = "\"space\"" },
        .{ .key = "ui.keys.leave_terminal", .type = "string", .default = "\"ctrl+]\"" },
        .{ .key = "ui.keys.popup_delay_ms", .type = "integer", .default = "200" },
        .{ .key = "ui.keys.timeout_ms", .type = "integer", .default = "0" },
    };
    for (want) |w| {
        var node = parsed.value;
        var it = std.mem.splitScalar(u8, w.key, '.');
        while (it.next()) |seg| node = node.object.get("properties").?.object.get(seg) orelse {
            std.debug.print("schema is missing {s}\n", .{w.key});
            return error.TestUnexpectedResult;
        };
        if (w.type.len > 0) {
            try testing.expectEqualStrings(w.type, node.object.get("type").?.string);
        } else {
            // Optional: anyOf [string, null].
            const any = node.object.get("anyOf").?.array.items;
            try testing.expectEqualStrings("string", any[0].object.get("type").?.string);
            try testing.expectEqualStrings("null", any[1].object.get("type").?.string);
        }
        const default = try std.json.Stringify.valueAlloc(f.arena.allocator(), node.object.get("default").?, .{});
        try testing.expectEqualStrings(w.default, default);
    }
    const choices = parsed.value.object.get("properties").?.object.get("ui").?.object.get("properties").?.object.get("chrome").?.object.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 3), choices.len);
}

test "agents.* keys: set and reload apply live; bad values name the key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.apply("agents.default", ".codex");
    try testing.expectEqual(Harness.codex, f.store.current().agents.default);
    try f.expectRejected("agents.default", ".gemini", "agents.default");
    try f.expectRejected("agents.default", "\"codex\"", "agents.default");

    try f.apply("agents.mode", ".plan");
    try testing.expectEqual(Mode.plan, f.store.current().agents.mode);
    try f.apply("agents.mode", ".accept_edits");
    try testing.expectEqual(Mode.accept_edits, f.store.current().agents.mode);
    try f.expectRejected("agents.mode", ".yolo", "agents.mode");

    try f.apply("agents.isolation", ".in_place");
    try testing.expectEqual(Isolation.in_place, f.store.current().agents.isolation);
    try f.apply("agents.isolation", ".copy");
    try testing.expectEqual(Isolation.copy, f.store.current().agents.isolation);
    try f.expectRejected("agents.isolation", ".container", "agents.isolation");

    try f.apply("agents.max_concurrent", "12");
    try testing.expectEqual(@as(u16, 12), f.store.current().agents.max_concurrent);
    try f.expectRejected("agents.max_concurrent", "0", "agents.max_concurrent");
    try f.expectRejected("agents.max_concurrent", "-1", "agents.max_concurrent");
    try f.expectRejected("agents.max_concurrent", "70000", "agents.max_concurrent");

    try f.apply("agents.spawn.allow", "false");
    try testing.expect(!f.store.current().agents.spawn.allow);
    try f.expectRejected("agents.spawn.allow", "1", "agents.spawn.allow");

    try f.apply("agents.spawn.depth", "4");
    try testing.expectEqual(@as(u8, 4), f.store.current().agents.spawn.depth);
    try f.expectRejected("agents.spawn.depth", "256", "agents.spawn.depth");

    try f.apply("agents.archive_after", "\"12h\"");
    try testing.expectEqualStrings("12h", f.store.current().agents.archive_after);
    try f.expectRejected("agents.archive_after", "\"soon\"", "agents.archive_after");
    try f.expectRejected("agents.archive_after", "3", "agents.archive_after");
}

test "attention.* keys: set and reload apply live; bad values name the key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.apply("attention.bell", "false");
    try testing.expect(!f.store.current().attention.bell);
    try f.expectRejected("attention.bell", "null", "attention.bell");

    try f.apply("attention.notify_after", "\"30s\"");
    try testing.expectEqualStrings("30s", f.store.current().attention.notify_after);
    try f.expectRejected("attention.notify_after", "\"0s\"", "attention.notify_after");

    try f.apply("attention.approval_timeout", "\"10m\"");
    try testing.expectEqualStrings("10m", f.store.current().attention.approval_timeout.?);
    try f.apply("attention.approval_timeout", "null");
    try testing.expectEqual(@as(?[]const u8, null), f.store.current().attention.approval_timeout);
    try f.expectRejected("attention.approval_timeout", "\"forever\"", "attention.approval_timeout");
}

test "ui.* keys: set and reload apply live; bad values name the key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.apply("ui.chrome", ".host");
    try testing.expectEqual(Chrome.host, f.store.current().ui.chrome);
    try f.apply("ui.chrome", ".own");
    try testing.expectEqual(Chrome.own, f.store.current().ui.chrome);
    try f.expectRejected("ui.chrome", "\"own\"", "ui.chrome");
    try f.expectRejected("ui.chrome", ".desk", "ui.chrome");

    try f.apply("ui.group_by", ".repo");
    try testing.expectEqual(GroupBy.repo, f.store.current().ui.group_by);
    try f.apply("ui.group_by", ".workspace");
    try testing.expectEqual(GroupBy.workspace, f.store.current().ui.group_by);
    try f.expectRejected("ui.group_by", ".harness", "ui.group_by");
    try f.apply("ui.keys.leave_terminal", "\"ctrl+g\"");
    try testing.expectEqualStrings("ctrl+g", f.store.current().ui.keys.leave_terminal);
    try f.expectRejected("ui.keys.leave_terminal", "\"ctrl+\"", "ui.keys.leave_terminal");
    try f.expectRejected("ui.keys.leave_terminal", "\"q\"", "ui.keys.leave_terminal");
    try f.apply("ui.keys.leader", "\"ctrl+x\"");
    try testing.expectEqualStrings("ctrl+x", f.store.current().ui.keys.leader);
    try f.expectRejected("ui.keys.leader", "\"ctrl+\"", "ui.keys.leader");
    try f.expectRejected("ui.keys.leader", "\"escape\"", "ui.keys.leader");
    try f.expectRejected("ui.keys.leader", "\"backspace\"", "ui.keys.leader");
    try f.apply("ui.keys.popup_delay_ms", "0");
    try testing.expectEqual(@as(u32, 0), f.store.current().ui.keys.popup_delay_ms);
    try f.apply("ui.keys.timeout_ms", "1500");
    try testing.expectEqual(@as(u32, 1500), f.store.current().ui.keys.timeout_ms);

    try f.apply("ui.children", ".folded");
    try testing.expectEqual(Children.folded, f.store.current().ui.children);
    try f.apply("ui.children", ".hidden");
    try testing.expectEqual(Children.hidden, f.store.current().ui.children);
    try f.expectRejected("ui.children", ".flat", "ui.children");

    try f.apply("ui.transcript.density", ".verbose");
    try testing.expectEqual(Density.verbose, f.store.current().ui.transcript.density);
    try f.apply("ui.transcript.density", ".compact");
    try testing.expectEqual(Density.compact, f.store.current().ui.transcript.density);
    try f.expectRejected("ui.transcript.density", ".dense", "ui.transcript.density");

    try f.apply("ui.transcript.open_running_after", "\"500ms\"");
    try testing.expectEqualStrings("500ms", f.store.current().ui.transcript.open_running_after);
    try f.expectRejected("ui.transcript.open_running_after", "\"5\"", "ui.transcript.open_running_after");

    try f.apply("ui.context.warn_at", "95");
    try testing.expectEqual(@as(u8, 95), f.store.current().ui.context.warn_at);
    try f.expectRejected("ui.context.warn_at", "101", "ui.context.warn_at");
}

test "an external edit with a bad value is not applied and names the key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = ".{ .ui = .{ .chrome = .host } }" });
    _ = try f.store.reload();
    try testing.expectEqual(Chrome.host, f.store.current().ui.chrome);
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data = ".{ .ui = .{ .chrome = .own }, .attention = .{ .notify_after = \"2 min\" } }" });
    try testing.expectError(error.InvalidConfig, f.store.reload());
    try testing.expectEqualStrings("attention.notify_after", f.store.failure.key());
    try testing.expectEqual(Chrome.host, f.store.current().ui.chrome);
}

test "harness.* defaults and schema" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const h = f.store.current().harness;
    for ([_]HarnessEntry{ h.claude_code, h.codex }) |e| {
        try testing.expect(e.enabled);
        try testing.expectEqual(@as(?[]const u8, null), e.path);
        try testing.expectEqual(@as(usize, 0), e.extra_args.len);
    }
    try testing.expectEqualStrings("5s", h.shutdown_grace);
    try testing.expectEqualStrings("30s", h.start_timeout);
    try testing.expectEqual(@as(u32, 262_144), h.body_max);
    try testing.expectEqualStrings("Continue from where you stopped.", h.resume_prompt);
    // The documented defaults, as a ZON file, are a valid config.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data =
        \\.{
        \\    .harness = .{
        \\        .claude_code = .{ .enabled = true, .path = null, .extra_args = .{} },
        \\        .codex = .{ .enabled = true, .path = null, .extra_args = .{} },
        \\        .shutdown_grace = "5s",
        \\        .start_timeout = "30s",
        \\        .body_max = 262144,
        \\        .resume_prompt = "Continue from where you stopped.",
        \\    },
        \\}
    });
    try f.store.check();
    _ = try f.store.reload();
    try testing.expectEqualDeep(Config{}, f.store.current());

    const parsed = try std.json.parseFromSlice(std.json.Value, a, try f.store.schema(f.arena.allocator()), .{});
    defer parsed.deinit();
    const Want = struct { key: []const u8, default: []const u8 };
    for ([_]Want{
        .{ .key = "harness.claude_code.enabled", .default = "true" },
        .{ .key = "harness.claude_code.path", .default = "null" },
        .{ .key = "harness.claude_code.extra_args", .default = "[]" },
        .{ .key = "harness.codex.enabled", .default = "true" },
        .{ .key = "harness.codex.path", .default = "null" },
        .{ .key = "harness.codex.extra_args", .default = "[]" },
        .{ .key = "harness.acp.enabled", .default = "false" },
        .{ .key = "harness.acp.path", .default = "null" },
        .{ .key = "harness.acp.extra_args", .default = "[]" },
        .{ .key = "harness.shutdown_grace", .default = "\"5s\"" },
        .{ .key = "harness.start_timeout", .default = "\"30s\"" },
        .{ .key = "harness.body_max", .default = "262144" },
        .{ .key = "harness.resume_prompt", .default = "\"Continue from where you stopped.\"" },
    }) |w| {
        var node = parsed.value;
        var it = std.mem.splitScalar(u8, w.key, '.');
        while (it.next()) |seg| node = node.object.get("properties").?.object.get(seg) orelse {
            std.debug.print("schema is missing {s}\n", .{w.key});
            return error.TestUnexpectedResult;
        };
        const default = try std.json.Stringify.valueAlloc(f.arena.allocator(), node.object.get("default").?, .{});
        try testing.expectEqualStrings(w.default, default);
    }
}

test "harness.* keys: host settings apply live, adapter settings on restart; bad values name the key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.apply("harness.shutdown_grace", "\"2s\"");
    try testing.expectEqualStrings("2s", f.store.current().harness.shutdown_grace);
    try f.expectRejected("harness.shutdown_grace", "\"later\"", "harness.shutdown_grace");
    try f.expectRejected("harness.shutdown_grace", "\"100d\"", "harness.shutdown_grace");
    try f.apply("harness.start_timeout", "\"1m\"");
    try testing.expectEqualStrings("1m", f.store.current().harness.start_timeout);
    try f.expectRejected("harness.start_timeout", "30", "harness.start_timeout");
    try f.apply("harness.body_max", "65536");
    try testing.expectEqual(@as(u32, 65_536), f.store.current().harness.body_max);
    try f.expectRejected("harness.body_max", "0", "harness.body_max");
    try f.apply("harness.resume_prompt", "\"Go on.\"");
    try testing.expectEqualStrings("Go on.", f.store.current().harness.resume_prompt);
    try f.expectRejected("harness.resume_prompt", "\"\"", "harness.resume_prompt");
    try f.expectRejected("harness.codex.path", "\"\"", "harness.codex.path");
    try f.expectRejected("harness.claude_code.extra_args", ".{\"\"}", "harness.claude_code.extra_args");
    // An ACP agent has no well-known name: it can't be on without a path.
    try f.expectRejected("harness.acp.enabled", "true", "harness.acp.path");
    try f.expectRejected("harness.acp.path", "\"\"", "harness.acp.path");

    // Adapter settings are persisted but wait for the next start.
    _ = try f.store.set("harness.codex.enabled", "false");
    const change = try f.store.reload();
    try testing.expect(change.restart_required);
    try testing.expect(f.store.current().harness.codex.enabled);
    _ = try f.store.set("harness.claude_code.extra_args", ".{ \"--verbose\" }");
    _ = try f.store.reload();
    try testing.expectEqual(@as(usize, 0), f.store.current().harness.claude_code.extra_args.len);
    try testing.expectEqualStrings(".{\"--verbose\"}", try f.store.get(f.arena.allocator(), "harness.claude_code.extra_args"));
}

test "providers: names, config folders and the default provider" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.apply("providers", ".{ .{ .name = \"work\" }, .{ .name = \"Personal Max\", .harness = .claude_code, .home = \"~/.claude_personal\", .model = \"opus\", .mode = .bypass_permissions }, .{ .name = \"cx\", .harness = .codex, .home = \"/opt/codex-home\" } }");
    try testing.expectEqual(@as(usize, 3), f.store.current().providers.len);
    try testing.expectEqual(Mode.bypass_permissions, f.store.current().providers[1].mode.?);
    // A default that names no provider is kept (a rename can be saved one
    // key at a time); an empty one is not.
    try f.apply("agents.provider", "\"gone\"");
    try f.expectRejected("agents.provider", "\"\"", "agents.provider");
    try f.expectRejected("providers", ".{ .{ .name = \"\" } }", "providers");
    try f.expectRejected("providers", ".{ .{ .name = \" work\" } }", "providers");
    try f.expectRejected("providers", ".{ .{ .name = \"a\" }, .{ .name = \"a\", .harness = .codex } }", "providers");
    try f.expectRejected("providers", ".{ .{ .name = \"a\", .home = \"relative/dir\" } }", "providers");
    try f.expectRejected("providers", ".{ .{ .name = \"a\", .model = \"\" } }", "providers");

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const p: Provider = .{ .name = "x", .home = "~/.claude_personal" };
    try testing.expectEqualStrings("/home/me/.claude_personal", (try p.resolvedHome(arena.allocator(), "/home/me")).?);
    try testing.expect((try p.resolvedHome(arena.allocator(), null)) == null);
    try testing.expectEqualStrings("/abs", (try (Provider{ .name = "x", .home = "/abs" }).resolvedHome(arena.allocator(), null)).?);
    try testing.expectEqualStrings("CODEX_HOME", Provider.homeEnv(.codex));
}
