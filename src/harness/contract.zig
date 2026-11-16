//! The harness adapter contract, as venom's Zig interface.
//!
//! An adapter is venom code, compiled in, that drives one harness kind
//! (`claude-code`, `codex`, the fake harness) through its official
//! channel. It is a vtable whose implementations are checked at compile
//! time (`iface.assertImplements`, the nullclaw pattern): a missing or
//! mistyped operation is a compile error naming it.
//!
//! What an adapter does and does not do:
//! - It turns venom operations into harness input (`start` returns the
//!   command to spawn; `send`, `interrupt`, `respond`, `release` write to
//!   the harness through the `Conversation`'s channel).
//! - It turns harness output into normalized events (`decode` gets one line
//!   at a time and calls the `Conversation` helpers, which assign venom's
//!   `t<n>`/`c<n>`/`r<n>`/`m<n>` ids and keep the harness-id mapping).
//! - It never changes agent state and never spawns or reaps processes:
//!   `host.zig` owns the processes (supervision, backoff, exits) and logs the
//!   normalized events, from which the decider derives agent state.
//!
//! Decisions:
//! - Claude Code control channel: the interface needs no control
//!   channel beyond documented ones. `Conversation.signal` delivers a signal
//!   to the harness's process group (Claude Code's documented SIGINT
//!   interrupt), and approvals come back through `respond`, which an adapter
//!   may route through any channel it owns (Claude Code: venom's MCP
//!   permission prompt tool). Undocumented stream-json control messages are
//!   not used and no SDK sidecar is bundled.
//! - Durable requests: `Caps.durable_requests` stays false for every v1
//!   adapter. A stale request (its harness process gone) is not delivered to
//!   a new process: the one-shot-decision path answers the
//!   call when the resumed harness asks for it again
//!   (`eventlog/oneshot.zig`).
const std = @import("std");
const iface = @import("iface");
const supervisor = @import("supervisor");
const records = @import("../eventlog/events.zig");

/// Tool-call `args` and `body`, as the log keeps them.
pub const ToolArgs = records.ToolArgs;
pub const ToolBody = records.ToolBody;
/// Plan windows, as the log keeps them.
pub const PlanWindow = records.PlanWindow;

/// The adapter contract version.
pub const version: u32 = 1;

pub const Steer = enum { none, queue, inject };
pub const ForkLevel = enum { none, head, at_turn };
pub const CatchUp = enum { none, api, transcript_file };
pub const AttentionAway = enum { none, turn_end, hooks };
pub const NativeSubagents = enum { none, observe, stop };
pub const Always = enum { session_rule, harness_rule, none };
pub const Context = enum { none, estimate, exact };
pub const PlanWindows = enum { none, experimental, stable };
pub const Liveness = enum { none, api };

pub const Approval = struct { edit: bool = false, always: Always = .none };
pub const Question = struct { multi: bool = false, free_text: bool = false };

/// `approval` and `question` are an object or `false` on the wire.
pub const Requests = struct {
    approval: ?Approval = null,
    question: ?Question = null,
    plan: bool = false,

    pub fn jsonStringify(self: Requests, w: anytype) !void {
        try w.beginObject();
        try w.objectField("approval");
        if (self.approval) |v| try w.write(v) else try w.write(false);
        try w.objectField("question");
        if (self.question) |v| try w.write(v) else try w.write(false);
        try w.objectField("plan");
        try w.write(self.plan);
        try w.endObject();
    }
};

pub const UsageCaps = struct { per_turn: bool = false, context: Context = .none, plan_windows: PlanWindows = .none };

/// What a harness can do. A missing capability means its most restrictive
/// value, which is each field's default; `send` and `idle_boundary` are
/// required and checked by `Descriptor.valid`.
pub const Caps = struct {
    send: bool = true,
    steer: Steer = .none,
    interrupt: bool = false,
    requests: Requests = .{},
    fork: ForkLevel = .none,
    resume_tui: bool = false,
    idle_boundary: bool = true,
    release: bool = false,
    catch_up: CatchUp = .none,
    attention_away: AttentionAway = .none,
    native_subagents: NativeSubagents = .none,
    usage: UsageCaps = .{},
    durable_requests: bool = false,
    liveness: Liveness = .none,
    set_model: bool = false,
    /// `compact`: the harness can shrink the conversation on request.
    compact: bool = false,
    /// `Start.mcp_off`: the harness can start without named MCP
    /// servers, and reports the ones it has (`Conversation.mcpServers`).
    mcp_off: bool = false,
    permission_modes: []const []const u8 = &.{},
};

/// What `probe` returns.
pub const Descriptor = struct {
    harness: []const u8,
    adapter: u32 = version,
    harness_version: ?[]const u8 = null,
    channel: []const u8,
    min_version: ?[]const u8 = null,
    tested_version: ?[]const u8 = null,
    caps: Caps = .{},

    pub fn valid(self: Descriptor) bool {
        return self.caps.send and self.caps.idle_boundary and self.adapter == version;
    }
};

/// Adapter errors, reported with their error codes.
pub const Error = error{
    HarnessNotFound,
    HarnessNotSignedIn,
    UnsupportedHarnessVersion,
    UnsupportedCapability,
    TurnRunning,
    HandedOver,
    RequestResolved,
    HarnessSessionLive,
    HarnessSessionNotFound,
    InvalidAnswer,
    HarnessExited,
    HarnessProtocol,
    HarnessTurn,
    UsageLimit,
    HarnessCatchUp,
    DaemonRestart,
    HarnessStartTimeout,
    HarnessForkRefused,
    HarnessRequestTimeout,
};

pub const Failure = struct { code: []const u8, exit: u8 };

/// The error code and exit code of an adapter error; null for
/// errors that are not adapter errors (allocation, I/O).
pub fn failure(err: anyerror) ?Failure {
    return switch (err) {
        error.HarnessNotFound => .{ .code = "unavailable.harness_not_found", .exit = 6 },
        error.HarnessNotSignedIn => .{ .code = "unavailable.harness_not_signed_in", .exit = 6 },
        error.UnsupportedHarnessVersion => .{ .code = "unsupported.harness_version", .exit = 10 },
        error.UnsupportedCapability => .{ .code = "unsupported.harness_capability", .exit = 10 },
        error.TurnRunning => .{ .code = "conflict.turn_running", .exit = 5 },
        error.HandedOver => .{ .code = "conflict.handed_over", .exit = 5 },
        error.RequestResolved => .{ .code = "conflict.request_resolved", .exit = 5 },
        error.HarnessSessionLive => .{ .code = "conflict.harness_session_live", .exit = 5 },
        error.HarnessSessionNotFound => .{ .code = "not_found.harness_session", .exit = 3 },
        error.InvalidAnswer => .{ .code = "invalid_params.answer", .exit = 2 },
        error.GrantsUnavailable => .{ .code = "unavailable.agent_grants", .exit = 6 },
        error.HarnessExited => .{ .code = "failed.harness_exited", .exit = 1 },
        error.HarnessProtocol => .{ .code = "failed.harness_protocol", .exit = 1 },
        error.HarnessTurn => .{ .code = "failed.harness_turn", .exit = 1 },
        error.UsageLimit => .{ .code = "failed.usage_limit", .exit = 1 },
        error.HarnessCatchUp => .{ .code = "failed.harness_catch_up", .exit = 1 },
        error.DaemonRestart => .{ .code = "failed.daemon_restart", .exit = 1 },
        error.HarnessStartTimeout => .{ .code = "timeout.harness_start", .exit = 7 },
        // Neither changes the agent, unlike `failed.*` and
        // `timeout.harness_start`. These error codes have no rows yet.
        error.HarnessForkRefused => .{ .code = "conflict.harness_fork_refused", .exit = 5 },
        error.HarnessRequestTimeout => .{ .code = "timeout.harness_request", .exit = 7 },
        else => null,
    };
}

pub const SendMode = enum { turn, steer, interrupt_then_send };

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// A harness process to start (`start`, `reattach`) or to run in a
/// take-over split (`resume_command`). `argv[0]` is looked up in `PATH`.
pub const Spawn = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Added to (or replacing in) venom's own environment.
    env: []const EnvVar = &.{},
    /// Set when the adapter chose the conversation id up front,
    /// so the binding is durable before the first output.
    harness_session: ?[]const u8 = null,
    /// Written to the harness's stdin as soon as it starts, before any
    /// `send`: a protocol handshake (Codex app-server `initialize`). Also
    /// sent on a restart, which sends nothing else.
    input: ?[]const u8 = null,
};

/// `start` params. `harness_session` set opens an
/// existing conversation: that is `reattach`.
pub const Start = struct {
    agent: []const u8,
    cwd: []const u8,
    harness_session: ?[]const u8 = null,
    /// With `harness_session`: the agent is a fork that has not started yet,
    /// and this is the conversation it copies (from the log, so it survives a
    /// restart). For a harness that copies at the first start; one
    /// whose `fork` already made the conversation ignores it.
    fork_source: ?[]const u8 = null,
    /// The recorded transcript of `harness_session`, if a hook named one: with
    /// `fork_source`, where an adapter looks for a copy that already exists.
    transcript_ref: ?[]const u8 = null,
    model: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    /// The provider's config folder for the harness (Claude Code's
    /// `CLAUDE_CONFIG_DIR`, Codex's `CODEX_HOME`): the login and settings the
    /// agent runs with. Absolute. Null: the adapter's own default.
    home: ?[]const u8 = null,
    /// The agent's scope: the folders it may write
    /// (absolute; its repos, or the workspace root for a whole-workspace
    /// scope) and the workspace's repos outside the scope, which are
    /// read-only to it. Each adapter maps them onto the harness's own
    /// mechanism and says in its file comment what that can enforce.
    /// Empty `writable`: no scope known (write anywhere the harness allows).
    writable: []const []const u8 = &.{},
    read_only: []const []const u8 = &.{},
    /// MCP servers this process must not offer the model (`Caps.mcp_off`).
    mcp_off: []const []const u8 = &.{},
};

/// A venom mode (`config.Mode`) as named in `Caps.permission_modes`.
pub fn modeName(mode: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, mode, "ask")) return "manual";
    if (std.mem.eql(u8, mode, "accept_edits")) return "acceptEdits";
    if (std.mem.eql(u8, mode, "plan")) return "plan";
    if (std.mem.eql(u8, mode, "auto")) return "auto";
    if (std.mem.eql(u8, mode, "bypass_permissions")) return "bypassPermissions";
    return null;
}

/// The mode a harness listing `known` can hold an agent to when the agent
/// must not exceed `mode`: `mode` itself, else `plan`, the narrowest. Null:
/// it can enforce neither.
pub fn enforceableMode(known: []const []const u8, mode: []const u8) ?[]const u8 {
    const lists = struct {
        fn has(list: []const []const u8, name: ?[]const u8) bool {
            for (list) |k| if (std.mem.eql(u8, k, name orelse return false)) return true;
            return false;
        }
    }.has;
    if (lists(known, modeName(mode))) return mode;
    if (lists(known, "plan")) return "plan";
    return null;
}

test "enforceableMode: the mode if the harness has it, else plan, else none" {
    const claude: []const []const u8 = &.{ "manual", "acceptEdits", "plan" };
    const codex: []const []const u8 = &.{"plan"};
    try std.testing.expectEqualStrings("accept_edits", enforceableMode(claude, "accept_edits").?);
    try std.testing.expectEqualStrings("ask", enforceableMode(claude, "ask").?);
    try std.testing.expectEqualStrings("plan", enforceableMode(codex, "ask").?);
    try std.testing.expectEqualStrings("plan", enforceableMode(codex, "accept_edits").?);
    try std.testing.expectEqualStrings("plan", enforceableMode(codex, "plan").?);
    try std.testing.expect(enforceableMode(&.{}, "plan") == null);
}

/// What a report from the harness's own TUI says.
pub const HookReport = struct {
    /// The attention it raises. Null: none (`SessionEnd` is advisory:
    /// venom still waits for the split to exit).
    kind: ?enum { approval, question, review } = null,
    reason: []const u8 = "",
    /// `transcript_path`, when it gave one.
    transcript: ?[]const u8 = null,
};

/// The resume record.
pub const Resume = struct {
    /// venom's agent id.
    agent: []const u8 = "",
    /// Add the attention hooks: whoever runs the command can report its
    /// process (`agent.takeover_split`).
    hooks: bool = false,
    harness: []const u8,
    harness_session: []const u8,
    /// Set while the conversation does not exist yet: a fork that has not
    /// started. The command then forks it.
    fork_source: ?[]const u8 = null,
    /// With `fork_source`: the point the copy stops at.
    /// An adapter that cannot take over such a fork refuses.
    fork_at: ?[]const u8 = null,
    cwd: []const u8,
    last_turn: ?[]const u8 = null,
    harness_last_turn: ?[]const u8 = null,
    transcript_ref: ?[]const u8 = null,
    /// When venom handed the conversation over (ms since the Unix epoch):
    /// `catch_up` imports what the harness recorded from then on.
    since_ms: ?i64 = null,
    /// The agent's provider config folder, as in `Start.home`.
    home: ?[]const u8 = null,
};

/// An answer to a request: `answer` is `allow_once`,
/// `allow_always`, `allow_edited`, `deny`, `cancel_turn`, `approve` or
/// `reject`; `reason` (deny), `feedback` (reject) and edited `args_json`
/// are optional.
pub const Answer = struct {
    answer: []const u8,
    reason: ?[]const u8 = null,
    args_json: ?[]const u8 = null,
};

/// A pending request as the adapter knows it: venom's id and the harness's.
pub const Pending = struct { request: []const u8, harness_ref: []const u8, kind: []const u8 };

/// Normalized events with venom's ids. Built by the
/// `Conversation` helpers, never by hand.
pub const Normalized = union(enum) {
    session: struct { harness_session: []const u8, model: ?[]const u8 = null, harness_version: ?[]const u8 = null, cwd: ?[]const u8 = null },
    turn_started: struct { turn: []const u8, origin: []const u8, harness_turn: ?[]const u8 = null },
    /// A prompt that reached the harness: the one that started `turn`, or one
    /// steered into it.
    prompt: struct { turn: []const u8, text: []const u8 },
    text: struct { turn: []const u8, message: []const u8, text: []const u8, final: bool },
    tool_started: struct { turn: []const u8, call: []const u8, kind: []const u8, name: []const u8, title: []const u8, status: []const u8, parent_call: ?[]const u8 = null, harness_ref: ?[]const u8 = null, args: ?ToolArgs = null, raw_input: ?ToolBody = null },
    tool_updated: struct { turn: []const u8, call: []const u8, body_delta: []const u8 },
    tool_ended: struct { turn: []const u8, call: []const u8, kind: []const u8, name: []const u8, title: []const u8, status: []const u8, exit: ?i64 = null, duration_ms: ?u64 = null, body: ?ToolBody = null },
    request: struct { turn: []const u8, request: []const u8, kind: []const u8, call: ?[]const u8 = null, reason: []const u8, answers: []const []const u8 = &.{}, input_digest: ?[]const u8 = null, outside_scope: ?bool = null, options: ?[]const records.QuestionOptions = null },
    request_resolved: struct { turn: []const u8, request: []const u8, by: []const u8 },
    usage: struct { turn: []const u8, model: []const u8 = "", tokens_in: u64 = 0, tokens_out: u64 = 0, cache_read: u64 = 0, cache_write: u64 = 0, includes_subagents: bool = false, source: []const u8 = "exact" },
    /// The context size; not turn-scoped. `source`: `exact` or `estimate`.
    context: struct { used: u64, window: u64, source: []const u8 = "estimate", system: ?u64 = null, tools: ?u64 = null },
    /// The MCP servers this process has; not turn-scoped.
    mcp_servers: struct { servers: []const []const u8 },
    /// Plan windows; per harness and account, not turn-scoped.
    plan_windows: PlanReport,
    /// `resets_at`: for `limit`, RFC 3339 UTC.
    turn_ended: struct { turn: []const u8, reason: []const u8, error_code: ?[]const u8 = null, resets_at: ?[]const u8 = null },
};

/// Usage numbers as an adapter reports them, already per turn.
pub const UsageReport = struct {
    model: []const u8 = "",
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    includes_subagents: bool = false,
    source: []const u8 = "exact",
};

/// Plan windows, as an adapter reports it; the host adds the harness.
pub const PlanReport = struct {
    account: []const u8 = "unknown",
    billing: []const u8 = "unknown",
    windows: []const PlanWindow = &.{},
    source: []const u8 = "stable",
};

pub const ToolReport = struct {
    harness_ref: []const u8,
    kind: []const u8,
    name: []const u8,
    title: []const u8 = "",
    status: []const u8 = "running",
    parent_ref: ?[]const u8 = null,
    /// Tool `args`, normalized for `kind`.
    args: ?ToolArgs = null,
    /// The harness's own input for the call, as JSON (`rawJson`). The
    /// conversation keeps at most `body_max` bytes of it, for `J`.
    raw_input: ?[]const u8 = null,
};

/// `input` as JSON text for `ToolReport.raw_input`, in `a`. Null: no input.
pub fn rawJson(a: std.mem.Allocator, input: std.json.Value) !?[]const u8 {
    if (input == .null) return null;
    return try std.json.Stringify.valueAlloc(a, input, .{});
}

/// How a tool call ended. `body` is the call's whole output or diff; the
/// conversation keeps at most `body_max` bytes of it.
pub const ToolEnd = struct {
    status: []const u8,
    exit: ?i64 = null,
    duration_ms: ?u64 = null,
    body: ?[]const u8 = null,
};

/// How a turn ended: `resets_at` only for `limit`.
pub const TurnEnd = struct {
    reason: []const u8,
    error_code: ?[]const u8 = null,
    resets_at: ?[]const u8 = null,
};

/// `text` as a tool body: at most `max` bytes of its start, cut at
/// a UTF-8 boundary.
pub fn capBody(text: []const u8, max: u32) ToolBody {
    if (text.len <= max) return .{ .text = text, .bytes = text.len };
    var end: usize = max;
    // Back up over continuation bytes (10xxxxxx) to a character start.
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return .{ .text = text[0..end], .truncated = true, .bytes = text.len };
}

/// Unix seconds as an RFC 3339 UTC time (`2026-11-07T15:00:00Z`), for
/// `resets_at`.
pub fn rfc3339(a: std.mem.Allocator, unix_s: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, unix_s)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

pub const max_questions = records.max_questions;
pub const max_labels = records.max_labels;
pub const max_question_text = records.max_question_text;
pub const max_label_text = records.max_label_text;
pub const max_options_bytes = records.max_options_bytes;

/// `s` as one printable line of at most `max` bytes, in `a`: escape
/// sequences and control characters go, a newline or tab is a space, and a
/// cut falls on a UTF-8 boundary.
pub fn cleanLine(a: std.mem.Allocator, s: []const u8, max: usize) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            i += 1;
            if (i >= s.len) break;
            if (s[i] == '[') {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
                i += 1;
            } else if (s[i] == ']') {
                while (i < s.len and s[i] != 0x07 and s[i] != 0x1b) i += 1;
                if (i < s.len and s[i] == 0x1b) i += 1;
                i += 1;
            } else i += 1;
            continue;
        }
        if (c >= 0x80) {
            // A whole, valid sequence or nothing: invalid bytes are dropped.
            const n = std.unicode.utf8ByteSequenceLength(c) catch {
                i += 1;
                continue;
            };
            if (i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                i += 1;
                continue;
            }
            // C1 controls (U+0080-U+009F) act as escapes on some terminals.
            if (c == 0xC2 and s[i + 1] <= 0x9F) {
                i += 2;
                continue;
            }
            if (out.items.len + n > max) break;
            try out.appendSlice(a, s[i .. i + n]);
            i += n;
            continue;
        }
        i += 1;
        const keep: u8 = if (c == '\n' or c == '\t') ' ' else if (c >= 0x20 and c != 0x7f) c else continue;
        if (out.items.len + 1 > max) break;
        try out.append(a, keep);
    }
    return out.items;
}

/// The options of an `AskUserQuestion`-shaped `questions` array:
/// per question, its id by position (`q1`, `q2`, …), its text and
/// the labels of its `options` (a string, or an object with a `label`).
/// `free_text` is whether a question takes a typed answer: its own
/// `isOther` / `free_text` if it has one, else `free_text_default`. A
/// question without options is kept, with no labels. Anything else in
/// `value` is skipped: it is a hint for the inbox, not the call.
///
/// Questions past `max_questions` are dropped, except that the first of them
/// that takes no typed answer stays as one more bare entry (so at most
/// `max_questions + 1` entries): the daemon refuses an answer to it.
///
/// A question the harness gave no options at all takes a typed answer.
///
/// A question whose labels were not all offered has `labels_omitted`: the
/// harness knows labels the daemon cannot check a pick against. A question
/// the budget has no room for stays as a bare entry (id and `free_text`).
///
/// A label is offered only as it is (`events.plainLabel`): a label that is
/// too long, empty or holds control characters is left out, never cleaned or
/// cut, because a pick sends it back and the harness must know it. Question
/// text is cleaned and cut for display. The total is bounded the same way
/// the TUI bounds it: each field is checked against what is left.
/// `a` must be an arena (or otherwise freed as a whole): nothing is freed
/// one by one, also on error.
pub fn questionOptions(a: std.mem.Allocator, value: std.json.Value, free_text_default: bool) std.mem.Allocator.Error![]const records.QuestionOptions {
    var out: std.ArrayList(records.QuestionOptions) = .empty;
    if (value != .array) return out.items;
    var total: usize = 0;
    for (value.array.items, 1..) |q, i| {
        if (q != .object) continue;
        if (i > max_questions) {
            // Past the bound: one bare entry stands for the first such
            // question that takes no typed answer, so the daemon knows
            // there is one it cannot check an answer against. The rest is
            // dropped.
            if (!takesTyped(q, free_text_default)) {
                try out.append(a, .{ .id = try std.fmt.allocPrint(a, "q{d}", .{i}), .labels_omitted = true });
                break;
            }
            continue;
        }
        const free = takesTyped(q, free_text_default);
        const id = try std.fmt.allocPrint(a, "q{d}", .{i});
        const text: []const u8 = if (q.object.get("question")) |t| (if (t == .string) try cleanLine(a, t.string, max_question_text) else "") else "";
        // The budget is spent: the question stays as a bare entry (its id and
        // `free_text`), so it can still be answered, with a typed answer.
        if (total + text.len > max_options_bytes) {
            try out.append(a, .{ .id = id, .free_text = free, .labels_omitted = true });
            continue;
        }
        total += text.len;
        var labels: std.ArrayList([]const u8) = .empty;
        var omitted = false;
        if (q.object.get("options")) |opts| if (opts == .array) for (opts.array.items) |o| {
            const label: ?[]const u8 = switch (o) {
                .string => |t| t,
                .object => |ob| if (ob.get("label")) |l| (if (l == .string) l.string else null) else null,
                else => null,
            };
            const l = label orelse continue;
            if (labels.items.len >= max_labels) {
                omitted = true;
                break;
            }
            if (!records.plainLabel(l)) {
                omitted = true;
                continue;
            }
            if (total + l.len > max_options_bytes) {
                omitted = true;
                break;
            }
            total += l.len;
            try labels.append(a, l);
        };
        try out.append(a, .{ .id = id, .question = text, .labels = labels.items, .free_text = free, .labels_omitted = omitted });
    }
    return out.items;
}

/// Whether a question takes a typed answer: always when the harness gave no
/// options at all (missing, null or empty: Codex shows "Type your answer"),
/// else its own `isOther` / `free_text`, else `free_text_default`.
fn takesTyped(q: std.json.Value, free_text_default: bool) bool {
    const none = if (q.object.get("options")) |o| (o != .array or o.array.items.len == 0) else true;
    if (none) return true;
    return flag(q, "isOther") orelse flag(q, "free_text") orelse free_text_default;
}

fn flag(v: std.json.Value, key: []const u8) ?bool {
    const x = v.object.get(key) orelse return null;
    return if (x == .bool) x.bool else null;
}

test "questionOptions: ids by position, labels from strings or objects, free_text from the question or the default" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"question\":\"A?\",\"options\":[{\"label\":\"x\"},\"y\",{\"description\":\"none\"}],\"isOther\":true},{\"question\":\"B?\"},3,{\"question\":\"C?\",\"options\":[\"z\"],\"free_text\":false}]", .{});
    const got = try questionOptions(a, v, true);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("q1", got[0].id);
    try std.testing.expectEqualStrings("A?", got[0].question);
    try std.testing.expectEqual(@as(usize, 2), got[0].labels.len);
    try std.testing.expectEqualStrings("y", got[0].labels[1]);
    try std.testing.expect(got[0].free_text);
    try std.testing.expectEqualStrings("q2", got[1].id);
    try std.testing.expectEqual(@as(usize, 0), got[1].labels.len);
    try std.testing.expect(got[1].free_text);
    try std.testing.expectEqualStrings("q4", got[2].id);
    try std.testing.expect(!got[2].free_text);
    const none = try questionOptions(a, v, false);
    // No options at all: a typed answer, whatever the default.
    try std.testing.expect(none[0].free_text and none[1].free_text and !none[2].free_text);
}

test "questionOptions: a label is offered as it is or not at all; text is cleaned; C1 controls go" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("red ok", try cleanLine(a, "\x1b[31mred\x1b[0m\x07 o\x00k", 100));
    try std.testing.expectEqualStrings("a b", try cleanLine(a, "a\nb", 100));
    try std.testing.expectEqualStrings("aé", try cleanLine(a, "aéé", 3));
    try std.testing.expectEqualStrings("a", try cleanLine(a, "aéé", 2));
    // U+009B (CSI) and U+009D (OSC) are two bytes: C2 9B, C2 9D.
    try std.testing.expectEqualStrings("a31mb", try cleanLine(a, "a\xc2\x9b31mb\xc2\x9d", 100));

    const long_a = try a.alloc(u8, 201);
    @memset(long_a, 'x');
    const json = try std.fmt.allocPrint(a, "[{{\"question\":\"Q\\u001b[0m\\u0085?\",\"options\":[\"ok\",\"bad\\u001bseq\",\"c1\\u009bx\",\"  \",\"\",\"{s}\",\"{s}y\",\"fine too\"]}}]", .{ long_a, long_a });
    const got = try questionOptions(a, try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}), false);
    try std.testing.expectEqualStrings("Q?", got[0].question);
    // Only labels that are plain survive, untouched: the long ones (which
    // would collide once cut) are left out, not truncated.
    try std.testing.expectEqual(@as(usize, 2), got[0].labels.len);
    try std.testing.expectEqualStrings("ok", got[0].labels[0]);
    try std.testing.expectEqualStrings("fine too", got[0].labels[1]);
}

test "questionOptions: counts and the 8 KiB total are bounded, field by field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(a, "[");
    for (0..20) |q| {
        if (q > 0) try json.appendSlice(a, ",");
        try json.appendSlice(a, "{\"question\":\"");
        try json.appendNTimes(a, 'q', 500);
        try json.appendSlice(a, "\",\"options\":[");
        for (0..30) |n| {
            if (n > 0) try json.appendSlice(a, ",");
            try json.print(a, "\"{d:0>3}", .{n});
            try json.appendNTimes(a, 'x', 190);
            try json.appendSlice(a, "\"");
        }
        try json.appendSlice(a, "]}");
    }
    try json.appendSlice(a, "]");
    const got = try questionOptions(a, try std.json.parseFromSliceLeaky(std.json.Value, a, json.items, .{}), false);
    try std.testing.expect(got.len <= max_questions + 1);
    var total: usize = 0;
    for (got) |q| {
        try std.testing.expect(q.labels.len <= max_labels);
        total += q.question.len;
        for (q.labels) |l| {
            try std.testing.expect(l.len <= max_label_text);
            total += l.len;
        }
    }
    // Never over, and the fields that fit are in.
    try std.testing.expect(total <= max_options_bytes);
    try std.testing.expect(total > max_options_bytes - 700);
}

pub const RequestReport = struct {
    harness_ref: []const u8,
    kind: []const u8,
    call_ref: ?[]const u8 = null,
    reason: []const u8 = "",
    answers: []const []const u8 = &.{},
    /// The call's whole input, as the harness asked for it. Without it the
    /// call cannot be identified, so a one-shot decision never answers it:
    /// pass it whenever the harness gives it.
    input_json: ?[]const u8 = null,
    /// The adapter knows this approval writes outside the agent's scope,
    /// beyond what the call's title says.
    outside_scope: bool = false,
    /// A question's options per question (`q1`, `q2`, …), copied into the
    /// log with the request.
    options: []const records.QuestionOptions = &.{},
};

/// Where a `Conversation` writes to the harness (the host's process).
pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// Writes `bytes` to the harness's stdin.
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
        /// Sends `sig` to the harness's process group.
        signal: *const fn (ptr: *anyopaque, sig: std.posix.SIG) anyerror!void,
        /// Closes the harness's stdin (end of input).
        close_input: *const fn (ptr: *anyopaque) void,
    };
};

/// Where normalized events go (the host, which logs them).
pub const Sink = struct {
    ptr: *anyopaque,
    emit: *const fn (ptr: *anyopaque, conv: *Conversation, event: Normalized) anyerror!void,
};

/// One binding's live conversation: what an adapter sees of an agent. It
/// keeps venom's id counters (started from the agent's history, so ids never
/// repeat), the harness-to-venom id maps of the open turn, and the turn
/// rules every adapter shares: tool calls still open when a turn ends are
/// closed as `interrupted` first.
pub const Conversation = struct {
    /// The daemon's clean shutdown interrupts this conversation's turn.
    shutting_down: bool = false,
    gpa: std.mem.Allocator,
    /// Strings that live as long as the binding.
    life: std.heap.ArenaAllocator,
    /// Strings and maps of the open turn; reset when it ends.
    turn_arena: std.heap.ArenaAllocator,
    agent: []const u8,
    harness: []const u8,
    cwd: []const u8,
    harness_session: ?[]const u8 = null,
    channel: ?Channel = null,
    sink: Sink,
    /// `harness.body_max`: bytes of a tool call's body kept inline
    /// (the host sets it from its options).
    body_max: u32 = 262_144,
    turns: u32 = 0,
    calls: u32 = 0,
    raised: u32 = 0,
    messages: u32 = 0,
    /// venom's id of the open turn.
    turn: ?[]const u8 = null,
    last_turn: ?[]const u8 = null,
    harness_turn: ?[]const u8 = null,
    /// A `send` was written and its `turn.started` has not arrived yet.
    sending: bool = false,
    /// `turnStartedBySend` opened the turn: the `promptSent` that follows is
    /// its prompt.
    prompt_due: bool = false,
    /// What was sent and has no turn yet, oldest first (gpa-owned): the next
    /// turns are these, whichever origin the adapter gives them.
    prompts: std.ArrayList([]u8) = .empty,
    open_calls: std.ArrayList(Call) = .empty,
    open_requests: std.ArrayList(Pending) = .empty,

    pub const Call = struct { call: []const u8, harness_ref: []const u8, kind: []const u8, name: []const u8, title: []const u8, ended: bool = false };

    pub const Counters = struct { turns: u32 = 0, calls: u32 = 0, raised: u32 = 0, messages: u32 = 0 };

    /// Initializes in place: the arenas must not move once used.
    pub fn init(self: *Conversation, gpa: std.mem.Allocator, agent: []const u8, harness: []const u8, cwd: []const u8, counters: Counters, sink: Sink) !void {
        self.* = .{
            .gpa = gpa,
            .life = .init(gpa),
            .turn_arena = .init(gpa),
            .agent = "",
            .harness = "",
            .cwd = "",
            .sink = sink,
            .turns = counters.turns,
            .calls = counters.calls,
            .raised = counters.raised,
            .messages = counters.messages,
        };
        errdefer self.deinit();
        const a = self.life.allocator();
        self.agent = try a.dupe(u8, agent);
        self.harness = try a.dupe(u8, harness);
        self.cwd = try a.dupe(u8, cwd);
    }

    pub fn deinit(self: *Conversation) void {
        self.dropPrompts();
        self.prompts.deinit(self.gpa);
        self.turn_arena.deinit();
        self.life.deinit();
    }

    /// Writes one line (a newline is added) to the harness.
    pub fn writeLine(self: *Conversation, bytes: []const u8) !void {
        const ch = self.channel orelse return error.HarnessExited;
        try ch.vtable.write(ch.ptr, bytes);
        try ch.vtable.write(ch.ptr, "\n");
    }

    /// Writes `value` as one line of compact JSON.
    pub fn writeJson(self: *Conversation, value: anytype) !void {
        const line = try std.json.Stringify.valueAlloc(self.gpa, value, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(line);
        try self.writeLine(line);
    }

    pub fn signal(self: *Conversation, sig: std.posix.SIG) !void {
        const ch = self.channel orelse return error.HarnessExited;
        try ch.vtable.signal(ch.ptr, sig);
    }

    pub fn closeInput(self: *Conversation) void {
        if (self.channel) |ch| ch.vtable.close_input(ch.ptr);
    }

    pub fn inTurn(self: *const Conversation) bool {
        return self.turn != null;
    }

    fn emit(self: *Conversation, event: Normalized) !void {
        try self.sink.emit(self.sink.ptr, self, event);
    }

    fn openTurn(self: *Conversation) ![]const u8 {
        return self.turn orelse error.HarnessProtocol;
    }

    fn ta(self: *Conversation) std.mem.Allocator {
        return self.turn_arena.allocator();
    }

    // ---- helpers adapters call from `decode` ----

    pub fn session(self: *Conversation, harness_session: []const u8, model: ?[]const u8, harness_version: ?[]const u8) !void {
        if (self.harness_session == null or !std.mem.eql(u8, self.harness_session.?, harness_session))
            self.harness_session = try self.life.allocator().dupe(u8, harness_session);
        try self.emit(.{ .session = .{ .harness_session = harness_session, .model = model, .harness_version = harness_version, .cwd = self.cwd } });
    }

    pub fn turnStarted(self: *Conversation, harness_turn: ?[]const u8, origin: []const u8) !void {
        if (self.turn != null) return error.HarnessProtocol;
        self.turns += 1;
        const id = try std.fmt.allocPrint(self.ta(), "t{d}", .{self.turns});
        self.turn = id;
        self.harness_turn = if (harness_turn) |h| try self.ta().dupe(u8, h) else null;
        self.sending = false;
        try self.emit(.{ .turn_started = .{ .turn = id, .origin = origin, .harness_turn = harness_turn } });
        if (std.mem.eql(u8, origin, "catch_up") or self.prompts.items.len == 0) return;
        const sent = self.prompts.orderedRemove(0);
        defer self.gpa.free(sent);
        try self.prompt(sent);
    }

    /// A turn the adapter opens inside its own `send`, for a harness that does
    /// not report turn starts. The host logs the prompt once `send` returns.
    pub fn turnStartedBySend(self: *Conversation, harness_turn: ?[]const u8) !void {
        try self.turnStarted(harness_turn, "user");
        self.prompt_due = true;
    }

    /// The open turn's prompt. An adapter calls it when it reads one from the
    /// harness (catch-up); what venom sent comes through `promptSent`.
    pub fn prompt(self: *Conversation, body: []const u8) !void {
        try self.emit(.{ .prompt = .{ .turn = try self.openTurn(), .text = body } });
    }

    /// `body` was written to the harness. Steered into the open turn it shows
    /// there at once; otherwise it waits for the turn it starts.
    pub fn promptSent(self: *Conversation, body: []const u8, mode: SendMode) !void {
        if (mode == .steer and self.inTurn()) return self.prompt(body);
        if (self.prompt_due and self.inTurn()) {
            self.prompt_due = false;
            return self.prompt(body);
        }
        const copy = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(copy);
        try self.prompts.append(self.gpa, copy);
    }

    /// The process is gone, and with it anything it had not started.
    pub fn dropPrompts(self: *Conversation) void {
        for (self.prompts.items) |p| self.gpa.free(p);
        self.prompts.clearRetainingCapacity();
    }

    /// Agent prose; deltas (`final = false`) are not logged.
    pub fn text(self: *Conversation, body: []const u8, final: bool) !void {
        const turn = try self.openTurn();
        if (final) self.messages += 1;
        const id = try std.fmt.allocPrint(self.ta(), "m{d}", .{self.messages + @intFromBool(!final)});
        try self.emit(.{ .text = .{ .turn = turn, .message = id, .text = body, .final = final } });
    }

    pub fn toolStarted(self: *Conversation, r: ToolReport) !void {
        const turn = try self.openTurn();
        if (self.findCall(r.harness_ref) != null) return error.HarnessProtocol;
        self.calls += 1;
        const a = self.ta();
        const c: Call = .{ .call = try std.fmt.allocPrint(a, "c{d}", .{self.calls}), .harness_ref = try a.dupe(u8, r.harness_ref), .kind = try a.dupe(u8, r.kind), .name = try a.dupe(u8, r.name), .title = try a.dupe(u8, r.title) };
        try self.open_calls.append(a, c);
        const parent = if (r.parent_ref) |p| if (self.findCall(p)) |i| self.open_calls.items[i].call else null else null;
        try self.emit(.{ .tool_started = .{ .turn = turn, .call = c.call, .kind = c.kind, .name = c.name, .title = c.title, .status = r.status, .parent_call = parent, .harness_ref = c.harness_ref, .args = r.args, .raw_input = if (r.raw_input) |whole| capBody(whole, self.body_max) else null } });
    }

    pub fn toolUpdated(self: *Conversation, harness_ref: []const u8, body_delta: []const u8) !void {
        const turn = try self.openTurn();
        const i = self.findCall(harness_ref) orelse return error.HarnessProtocol;
        try self.emit(.{ .tool_updated = .{ .turn = turn, .call = self.open_calls.items[i].call, .body_delta = body_delta } });
    }

    pub fn toolEnded(self: *Conversation, harness_ref: []const u8, status: []const u8, exit: ?i64, duration_ms: ?u64) !void {
        return self.toolEnd(harness_ref, .{ .status = status, .exit = exit, .duration_ms = duration_ms });
    }

    /// `toolEnded` with a body, capped at `body_max`.
    pub fn toolEnd(self: *Conversation, harness_ref: []const u8, end: ToolEnd) !void {
        const turn = try self.openTurn();
        const i = self.findCall(harness_ref) orelse return error.HarnessProtocol;
        const c = &self.open_calls.items[i];
        if (c.ended) return error.HarnessProtocol;
        c.ended = true;
        const b: ?ToolBody = if (end.body) |whole| capBody(whole, self.body_max) else null;
        try self.emit(.{ .tool_ended = .{ .turn = turn, .call = c.call, .kind = c.kind, .name = c.name, .title = c.title, .status = end.status, .exit = end.exit, .duration_ms = end.duration_ms, .body = b } });
    }

    /// The agent's context size. Needs no open turn.
    pub fn context(self: *Conversation, used: u64, window: u64, source: []const u8) !void {
        try self.emit(.{ .context = .{ .used = used, .window = window, .source = source } });
    }

    /// `context` with what the harness knows of the window's fixed part: the
    /// tokens of its system prompt and instructions and of its tool definitions.
    pub fn contextFill(self: *Conversation, used: u64, window: u64, source: []const u8, system: ?u64, tools: ?u64) !void {
        try self.emit(.{ .context = .{ .used = used, .window = window, .source = source, .system = system, .tools = tools } });
    }

    /// The MCP servers this process has. Needs no open turn.
    pub fn mcpServers(self: *Conversation, servers: []const []const u8) !void {
        try self.emit(.{ .mcp_servers = .{ .servers = servers } });
    }

    /// The account's plan windows. Needs no open turn.
    pub fn planWindows(self: *Conversation, report: PlanReport) !void {
        try self.emit(.{ .plan_windows = report });
    }

    pub fn request(self: *Conversation, r: RequestReport) !void {
        const turn = try self.openTurn();
        for (self.open_requests.items) |p| if (std.mem.eql(u8, p.harness_ref, r.harness_ref)) return error.HarnessProtocol;
        self.raised += 1;
        const a = self.ta();
        const p: Pending = .{ .request = try std.fmt.allocPrint(a, "r{d}", .{self.raised}), .harness_ref = try a.dupe(u8, r.harness_ref), .kind = try a.dupe(u8, r.kind) };
        try self.open_requests.append(a, p);
        const call = if (r.call_ref) |ref| if (self.findCall(ref)) |i| self.open_calls.items[i].call else null else null;
        const digest = if (r.input_json) |input| try records.inputDigest(a, input) else null;
        // A question's text comes from the harness and reaches every screen:
        // one clean, bounded line.
        const reason = if (std.mem.eql(u8, r.kind, "question")) try cleanLine(a, r.reason, max_question_text) else r.reason;
        try self.emit(.{ .request = .{ .turn = turn, .request = p.request, .kind = p.kind, .call = call, .reason = reason, .answers = r.answers, .input_digest = digest, .outside_scope = if (r.outside_scope) true else null, .options = if (r.options.len > 0) r.options else null } });
    }

    /// The harness withdrew or resolved a request (`by` is `venom` when it
    /// confirms an answer venom sent; the host then logs nothing new).
    pub fn requestResolved(self: *Conversation, harness_ref: []const u8, by: []const u8) !void {
        const turn = try self.openTurn();
        const i = self.findRequest(harness_ref) orelse return;
        const p = self.open_requests.orderedRemove(i);
        try self.emit(.{ .request_resolved = .{ .turn = turn, .request = p.request, .by = by } });
    }

    pub fn usage(self: *Conversation, u: UsageReport) !void {
        const turn = try self.openTurn();
        try self.emit(.{ .usage = .{ .turn = turn, .model = u.model, .tokens_in = u.tokens_in, .tokens_out = u.tokens_out, .cache_read = u.cache_read, .cache_write = u.cache_write, .includes_subagents = u.includes_subagents, .source = u.source } });
    }

    /// The idle boundary. Open tool calls are closed as `interrupted` first;
    /// the decider closes pending requests (`by: turn_end`).
    /// Set by the host's clean shutdown: an interrupted turn ends with
    /// detail `daemon_shutdown`.
    pub fn markShutdown(self: *Conversation) void {
        self.shutting_down = true;
    }

    pub fn turnEnded(self: *Conversation, reason: []const u8, error_code: ?[]const u8) !void {
        return self.turnEnd(.{ .reason = reason, .error_code = error_code });
    }

    /// `turnEnded` with the `resets_at` of a `limit`.
    pub fn turnEnd(self: *Conversation, end_: TurnEnd) !void {
        var end = end_;
        // A turn the daemon's shutdown interrupted says so.
        if (self.shutting_down and end.error_code == null and std.mem.eql(u8, end.reason, "interrupted")) end.error_code = "daemon_shutdown";
        const turn = try self.openTurn();
        for (self.open_calls.items) |*c| if (!c.ended) {
            c.ended = true;
            try self.emit(.{ .tool_ended = .{ .turn = turn, .call = c.call, .kind = c.kind, .name = c.name, .title = c.title, .status = "interrupted" } });
        };
        try self.emit(.{ .turn_ended = .{ .turn = turn, .reason = end.reason, .error_code = end.error_code, .resets_at = end.resets_at } });
        self.last_turn = try self.life.allocator().dupe(u8, turn);
        self.turn = null;
        self.harness_turn = null;
        self.prompt_due = false;
        self.open_calls = .empty;
        self.open_requests = .empty;
        _ = self.turn_arena.reset(.retain_capacity);
    }

    /// Ends whatever the harness left open because its process is gone:
    /// a send that never started a turn gets a `turn.started` first, so the
    /// agent leaves `queued`/`settled` for `failed`.
    pub fn abandon(self: *Conversation, error_code: []const u8) !void {
        if (self.turn == null and self.sending) try self.turnStarted(null, "user");
        self.sending = false;
        self.dropPrompts();
        if (self.turn != null) try self.turnEnded("failed", error_code);
    }

    /// The pending request venom calls `request`, if this process raised it.
    pub fn pending(self: *const Conversation, req: []const u8) ?Pending {
        for (self.open_requests.items) |p| if (std.mem.eql(u8, p.request, req)) return p;
        return null;
    }

    /// Drops a request venom answered (its `request.resolved` is already
    /// logged by the decider).
    pub fn answered(self: *Conversation, req: []const u8) void {
        for (self.open_requests.items, 0..) |p, i| if (std.mem.eql(u8, p.request, req)) {
            _ = self.open_requests.orderedRemove(i);
            return;
        };
    }

    fn findCall(self: *const Conversation, harness_ref: []const u8) ?usize {
        for (self.open_calls.items, 0..) |c, i| if (std.mem.eql(u8, c.harness_ref, harness_ref)) return i;
        return null;
    }
    fn findRequest(self: *const Conversation, harness_ref: []const u8) ?usize {
        for (self.open_requests.items, 0..) |p, i| if (std.mem.eql(u8, p.harness_ref, harness_ref)) return i;
        return null;
    }
};

/// One call of `Adapter.fork`: it never waits for the harness.
pub const ForkStep = union(enum) {
    /// The harness has not answered: the host calls again on a later reactor
    /// turn, with the same arguments.
    pending,
    /// The new conversation's id, in the call's allocator.
    done: []const u8,
};

/// The adapter interface. `probe`, `start` (which is
/// also `reattach`), `send`, `interrupt`, `respond`, `fork`, `release`,
/// `resume_command` and `catch_up` are the adapter operations; `decode`
/// is the output half. `stop` is generic and lives in the host: it ends the
/// process group. Operations the descriptor does not declare return
/// `error.UnsupportedCapability`.
pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        probe: *const fn (ptr: *anyopaque, a: std.mem.Allocator) anyerror!Descriptor,
        /// What `probe` declares, known without running the harness: a client
        /// can ask for it on the reactor.
        caps: *const fn (ptr: *anyopaque) Caps,
        /// Compacts the conversation (`Caps.compact`), between
        /// turns; it arrives as a turn, like a `send` of `.turn`. Must not wait.
        compact: *const fn (ptr: *anyopaque, conv: *Conversation) anyerror!void,
        start: *const fn (ptr: *anyopaque, a: std.mem.Allocator, params: Start) anyerror!Spawn,
        send: *const fn (ptr: *anyopaque, conv: *Conversation, text: []const u8, mode: SendMode) anyerror!void,
        interrupt: *const fn (ptr: *anyopaque, conv: *Conversation) anyerror!void,
        respond: *const fn (ptr: *anyopaque, conv: *Conversation, request: Pending, answer: Answer) anyerror!void,
        decode: *const fn (ptr: *anyopaque, conv: *Conversation, line: []const u8) anyerror!void,
        /// `fork`: the new conversation's id. `harness_turn` is the
        /// harness's id of the turn to fork through (only with `fork =
        /// at_turn`; the host checks); null is the latest turn. It runs on the
        /// reactor and must not wait: an adapter that needs the harness's
        /// answer returns `.pending` and bounds the wait itself
        /// (`error.HarnessRequestTimeout`). `error.HarnessExited` from a
        /// conversation with no process asks the host to start one and call
        /// again.
        fork: *const fn (ptr: *anyopaque, a: std.mem.Allocator, conv: *Conversation, harness_turn: ?[]const u8) anyerror!ForkStep,
        release: *const fn (ptr: *anyopaque, conv: *Conversation) anyerror!void,
        resume_command: *const fn (ptr: *anyopaque, a: std.mem.Allocator, record: Resume) anyerror!Spawn,
        /// `catch_up`, emitting through `conv` (so imported turns get
        /// venom's ids, `origin: catch_up`); returns the turns imported.
        catch_up: *const fn (ptr: *anyopaque, conv: *Conversation, record: Resume) anyerror!u32,
    };

    pub fn init(impl: anytype) Adapter {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        iface.assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{
                .probe = probeThunk,
                .caps = capsThunk,
                .compact = compactThunk,
                .start = startThunk,
                .send = sendThunk,
                .interrupt = interruptThunk,
                .respond = respondThunk,
                .decode = decodeThunk,
                .fork = forkThunk,
                .release = releaseThunk,
                .resume_command = resumeCommandThunk,
                .catch_up = catchUpThunk,
            };
            fn probeThunk(ptr: *anyopaque, a: std.mem.Allocator) anyerror!Descriptor {
                return iface.cast(T, ptr).probe(a);
            }
            fn capsThunk(ptr: *anyopaque) Caps {
                return iface.cast(T, ptr).caps();
            }
            fn compactThunk(ptr: *anyopaque, conv: *Conversation) anyerror!void {
                return iface.cast(T, ptr).compact(conv);
            }
            fn startThunk(ptr: *anyopaque, a: std.mem.Allocator, params: Start) anyerror!Spawn {
                return iface.cast(T, ptr).start(a, params);
            }
            fn sendThunk(ptr: *anyopaque, conv: *Conversation, text: []const u8, mode: SendMode) anyerror!void {
                return iface.cast(T, ptr).send(conv, text, mode);
            }
            fn interruptThunk(ptr: *anyopaque, conv: *Conversation) anyerror!void {
                return iface.cast(T, ptr).interrupt(conv);
            }
            fn respondThunk(ptr: *anyopaque, conv: *Conversation, request: Pending, answer: Answer) anyerror!void {
                return iface.cast(T, ptr).respond(conv, request, answer);
            }
            fn decodeThunk(ptr: *anyopaque, conv: *Conversation, line: []const u8) anyerror!void {
                return iface.cast(T, ptr).decode(conv, line);
            }
            fn forkThunk(ptr: *anyopaque, a: std.mem.Allocator, conv: *Conversation, harness_turn: ?[]const u8) anyerror!ForkStep {
                return iface.cast(T, ptr).fork(a, conv, harness_turn);
            }
            fn releaseThunk(ptr: *anyopaque, conv: *Conversation) anyerror!void {
                return iface.cast(T, ptr).release(conv);
            }
            fn resumeCommandThunk(ptr: *anyopaque, a: std.mem.Allocator, record: Resume) anyerror!Spawn {
                return iface.cast(T, ptr).resume_command(a, record);
            }
            fn catchUpThunk(ptr: *anyopaque, conv: *Conversation, record: Resume) anyerror!u32 {
                return iface.cast(T, ptr).catch_up(conv, record);
            }
        }.vt };
    }

    pub fn probe(self: Adapter, a: std.mem.Allocator) !Descriptor {
        return self.vtable.probe(self.ptr, a);
    }
    pub fn caps(self: Adapter) Caps {
        return self.vtable.caps(self.ptr);
    }
    pub fn compact(self: Adapter, conv: *Conversation) !void {
        return self.vtable.compact(self.ptr, conv);
    }
    pub fn start(self: Adapter, a: std.mem.Allocator, params: Start) !Spawn {
        return self.vtable.start(self.ptr, a, params);
    }
    pub fn send(self: Adapter, conv: *Conversation, text: []const u8, mode: SendMode) !void {
        return self.vtable.send(self.ptr, conv, text, mode);
    }
    pub fn interrupt(self: Adapter, conv: *Conversation) !void {
        return self.vtable.interrupt(self.ptr, conv);
    }
    pub fn respond(self: Adapter, conv: *Conversation, request: Pending, answer: Answer) !void {
        return self.vtable.respond(self.ptr, conv, request, answer);
    }
    pub fn decode(self: Adapter, conv: *Conversation, line: []const u8) !void {
        return self.vtable.decode(self.ptr, conv, line);
    }
    pub fn fork(self: Adapter, a: std.mem.Allocator, conv: *Conversation, harness_turn: ?[]const u8) !ForkStep {
        return self.vtable.fork(self.ptr, a, conv, harness_turn);
    }
    pub fn release(self: Adapter, conv: *Conversation) !void {
        return self.vtable.release(self.ptr, conv);
    }
    pub fn resumeCommand(self: Adapter, a: std.mem.Allocator, record: Resume) !Spawn {
        return self.vtable.resume_command(self.ptr, a, record);
    }
    pub fn catchUp(self: Adapter, conv: *Conversation, record: Resume) !u32 {
        return self.vtable.catch_up(self.ptr, conv, record);
    }
};

/// Checks a send against the descriptor (the preconditions of `send`).
pub fn checkSend(caps: Caps, mode: SendMode, turn_running: bool) Error!void {
    switch (mode) {
        .turn => if (turn_running and caps.steer == .none) return error.TurnRunning,
        .steer => if (caps.steer != .inject) return error.UnsupportedCapability,
        .interrupt_then_send => if (!caps.interrupt) return error.UnsupportedCapability,
    }
}

const testing = std.testing;

test "contract: descriptor JSON has the expected shape" {
    const d: Descriptor = .{ .harness = "fake", .channel = "ndjson", .caps = .{ .steer = .queue, .interrupt = true, .requests = .{ .approval = .{ .always = .session_rule }, .plan = true } } };
    try testing.expect(d.valid());
    const json = try std.json.Stringify.valueAlloc(testing.allocator, d, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"requests\":{\"approval\":{\"edit\":false,\"always\":\"session_rule\"},\"question\":false,\"plan\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"adapter\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"steer\":\"queue\"") != null);
    try testing.expect(!(Descriptor{ .harness = "x", .channel = "y", .caps = .{ .idle_boundary = false } }).valid());
}

test "contract: error codes and send preconditions" {
    try testing.expectEqualStrings("failed.harness_exited", failure(error.HarnessExited).?.code);
    try testing.expectEqual(@as(u8, 10), failure(error.UnsupportedCapability).?.exit);
    try testing.expectEqual(@as(u8, 7), failure(error.HarnessStartTimeout).?.exit);
    try testing.expectEqualStrings("conflict.harness_fork_refused", failure(error.HarnessForkRefused).?.code);
    try testing.expectEqualStrings("timeout.harness_request", failure(error.HarnessRequestTimeout).?.code);
    try testing.expect(failure(error.OutOfMemory) == null);
    try checkSend(.{ .steer = .queue }, .turn, true);
    try testing.expectError(error.TurnRunning, checkSend(.{}, .turn, true));
    try testing.expectError(error.UnsupportedCapability, checkSend(.{ .steer = .queue }, .steer, true));
    try testing.expectError(error.UnsupportedCapability, checkSend(.{}, .interrupt_then_send, false));
}

const Recorder = struct {
    events: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,
    fn emit(ptr: *anyopaque, _: *Conversation, e: Normalized) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const a = self.arena.allocator();
        const line = switch (e) {
            inline else => |p, tag| try std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(tag), try std.json.Stringify.valueAlloc(a, p, .{ .emit_null_optional_fields = false }) }),
        };
        try self.events.append(a, line);
    }
};

test "contract: bodies are capped at body_max on a UTF-8 boundary; resets_at is RFC 3339" {
    const whole = capBody("hello", 5);
    try testing.expect(!whole.truncated);
    try testing.expectEqual(@as(u64, 5), whole.bytes);
    // "h\u{e9}llo": the cut at 2 would split \u{e9} (2 bytes), so it backs up.
    const cut = capBody("h\u{e9}llo", 2);
    try testing.expectEqualStrings("h", cut.text);
    try testing.expect(cut.truncated);
    try testing.expectEqual(@as(u64, 6), cut.bytes);
    try testing.expectEqualStrings("h\u{e9}", capBody("h\u{e9}llo", 3).text);
    const t = try rfc3339(testing.allocator, 1794067200);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("2026-11-07T16:00:00Z", t);
}

test "contract: conversation numbers ids from the agent's history and closes open calls at turn end" {
    var rec: Recorder = .{ .arena = .init(testing.allocator) };
    defer rec.arena.deinit();
    var conv: Conversation = undefined;
    try conv.init(testing.allocator, "a1", "fake", "/w", .{ .turns = 2, .calls = 4, .raised = 1, .messages = 3 }, .{ .ptr = &rec, .emit = Recorder.emit });
    defer conv.deinit();
    try testing.expectError(error.HarnessProtocol, conv.text("early", true));
    try conv.turnStarted("ht1", "user");
    try testing.expectError(error.HarnessProtocol, conv.turnStarted("ht2", "user"));
    try conv.text("hi", true);
    try conv.toolStarted(.{ .harness_ref = "tu1", .kind = "exec", .name = "Bash", .title = "ls" });
    try conv.toolStarted(.{ .harness_ref = "tu2", .kind = "read", .name = "Read", .title = "a.zig" });
    try conv.request(.{ .harness_ref = "p1", .kind = "approval", .call_ref = "tu1", .reason = "ls?", .answers = &.{ "allow_once", "deny" } });
    try testing.expectEqualStrings("p1", conv.pending("r2").?.harness_ref);
    try conv.toolEnded("tu2", "ok", null, 3);
    try testing.expectError(error.HarnessProtocol, conv.toolEnded("tu2", "ok", null, null));
    try conv.turnEnded("completed", null);
    try testing.expect(conv.pending("r2") == null);
    const want = [_][]const u8{
        "turn_started {\"turn\":\"t3\",\"origin\":\"user\",\"harness_turn\":\"ht1\"}",
        "text {\"turn\":\"t3\",\"message\":\"m4\",\"text\":\"hi\",\"final\":true}",
        "tool_started {\"turn\":\"t3\",\"call\":\"c5\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"ls\",\"status\":\"running\",\"harness_ref\":\"tu1\"}",
        "tool_started {\"turn\":\"t3\",\"call\":\"c6\",\"kind\":\"read\",\"name\":\"Read\",\"title\":\"a.zig\",\"status\":\"running\",\"harness_ref\":\"tu2\"}",
        "request {\"turn\":\"t3\",\"request\":\"r2\",\"kind\":\"approval\",\"call\":\"c5\",\"reason\":\"ls?\",\"answers\":[\"allow_once\",\"deny\"]}",
        "tool_ended {\"turn\":\"t3\",\"call\":\"c6\",\"kind\":\"read\",\"name\":\"Read\",\"title\":\"a.zig\",\"status\":\"ok\",\"duration_ms\":3}",
        "tool_ended {\"turn\":\"t3\",\"call\":\"c5\",\"kind\":\"exec\",\"name\":\"Bash\",\"title\":\"ls\",\"status\":\"interrupted\"}",
        "turn_ended {\"turn\":\"t3\",\"reason\":\"completed\"}",
    };
    try testing.expectEqual(want.len, rec.events.items.len);
    for (want, rec.events.items) |w, got| try testing.expectEqualStrings(w, got);
    // A send that never started a turn still ends as a failed turn.
    conv.sending = true;
    try conv.abandon("failed.harness_exited");
    try testing.expectEqualStrings("turn_ended {\"turn\":\"t4\",\"reason\":\"failed\",\"error_code\":\"failed.harness_exited\"}", rec.events.items[rec.events.items.len - 1]);
}

test "questionOptions: a question the budget has no room for stays, bare, and labels left out are flagged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(a, "[");
    // Four questions of 500 bytes of text; the first two hold 16 labels of 200.
    for (0..4) |q| {
        if (q > 0) try json.appendSlice(a, ",");
        try json.appendSlice(a, "{\"isOther\":false,\"question\":\"");
        try json.appendNTimes(a, 'q', 500);
        try json.appendSlice(a, "\",\"options\":[");
        const n: usize = if (q < 2) 16 else 2;
        for (0..n) |i| {
            if (i > 0) try json.appendSlice(a, ",");
            try json.print(a, "\"{d}{d:0>3}", .{ q, i });
            try json.appendNTimes(a, 'x', 196);
            try json.appendSlice(a, "\"");
        }
        try json.appendSlice(a, "]}");
    }
    try json.appendSlice(a, "]");
    const got = try questionOptions(a, try std.json.parseFromSliceLeaky(std.json.Value, a, json.items, .{}), false);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expect(!got[0].labels_omitted and got[0].labels.len == 16);
    // q3 got its text and one more label than fits; q4 is cut whole.
    try std.testing.expectEqualStrings("q4", got[3].id);
    try std.testing.expectEqual(@as(usize, 0), got[3].question.len);
    try std.testing.expectEqual(@as(usize, 0), got[3].labels.len);
    try std.testing.expect(got[3].labels_omitted and !got[3].free_text);
    try std.testing.expect(got[2].labels_omitted);

    // Labels the filter leaves out, or past 16, set the flag.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"options\":[\"Yes\",\"bad\\u001bseq\"]},{\"options\":[\"a\",\"b\"]}]", .{});
    const f = try questionOptions(a, v, false);
    try std.testing.expect(f[0].labels_omitted and f[0].labels.len == 1);
    try std.testing.expect(!f[1].labels_omitted);
}

test "questionOptions: past the eighth, the first question without a typed answer stays as a bare marker" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(a, "[");
    for (0..10) |q| {
        if (q > 0) try json.appendSlice(a, ",");
        try json.print(a, "{{\"question\":\"Q{d}\",\"options\":[\"a\"],\"isOther\":{s}}}", .{ q, if (q == 8) "true" else "false" });
    }
    try json.appendSlice(a, "]");
    const got = try questionOptions(a, try std.json.parseFromSliceLeaky(std.json.Value, a, json.items, .{}), false);
    // q9 takes a typed answer and is dropped; q10 does not: it is the marker.
    try std.testing.expectEqual(@as(usize, 9), got.len);
    try std.testing.expectEqualStrings("q10", got[8].id);
    try std.testing.expect(!got[8].free_text and got[8].labels_omitted and got[8].labels.len == 0);
    // All dropped ones take a typed answer: nothing is added.
    const plain = "[{},{},{},{},{},{},{},{},{},{}]";
    const free = try questionOptions(a, try std.json.parseFromSliceLeaky(std.json.Value, a, plain, .{}), true);
    try std.testing.expectEqual(@as(usize, 8), free.len);
    // Questions without options take a typed answer: no marker either.
    const bare = "[{},{},{},{},{},{},{},{},{},{\"options\":null}]";
    const typed = try questionOptions(a, try std.json.parseFromSliceLeaky(std.json.Value, a, bare, .{}), false);
    try std.testing.expectEqual(@as(usize, 8), typed.len);
    for (typed) |q| try std.testing.expect(q.free_text);
}
