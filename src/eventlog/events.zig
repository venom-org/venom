//! Durable log records and the commands the decider accepts.
//!
//! A record type is a dotted name (as verbs are). The turn,
//! transcript and request records are the adapter
//! events, keyed by venom's agent id; `effect.*` records are the
//! transactional outbox; `daemon.started` marks each daemon start so that
//! replay knows which requests became stale (so does a
//! `turn.ended` with `failed.harness_exited`, `oneshot.zig`).
//! Only some records are published on `venom events` (see `catalog.zig`).
const std = @import("std");
const proto = @import("proto");
const AgentState = @import("agent.zig").State;

/// `harness_turn`: the harness's id for the turn, when
/// it has one; a fork through this turn names it.
pub const TurnStarted = struct { agent: []const u8, turn: []const u8, origin: []const u8, harness_turn: ?[]const u8 = null };
/// A prompt that reached the harness (the transcript shows
/// prompts): right after the `turn.started` of the turn it starts, or inside a
/// running turn when it was steered in. Older logs have none.
/// Internal: `agent.show` returns it, `venom events` does not.
pub const TurnPrompt = struct { agent: []const u8, turn: []const u8, text: []const u8 };
pub const Text = struct { agent: []const u8, turn: []const u8, message: []const u8, text: []const u8 };
/// `reason`: completed, interrupted, failed, limit.
/// `error_code` is the failure code, e.g. `failed.daemon_restart`.
/// `resets_at`: for `limit`, when the
/// harness said the limit resets, as an RFC 3339 UTC time
/// (`2026-11-07T15:00:00Z`); null when it did not say.
pub const TurnEnded = struct { agent: []const u8, turn: []const u8, reason: []const u8, error_code: ?[]const u8 = null, resets_at: ?[]const u8 = null };
/// The subset of the adapter's request object venom core needs
/// to keep an inbox item: adapters add the rest with their own issues.
/// `call` is the tool call it belongs to; `answers` (for approvals) are the
/// answers this harness accepts. Empty means any.
/// `at` (ms since the Unix epoch) is stamped by the decider: the inbox's
/// age and oldest-first order. `grant` (approvals) is
/// the narrowest grant "allow always" would record (`always.zig`),
/// also stamped by the decider. `outside_scope` (stamped by the decider;
/// an adapter may set it too): a write outside the agent's
/// scope, by an edit or a command (`agent_scope.zig`); it has no grant, so
/// it is always asked. `tool` (stamped by the decider):
/// the call the request belongs to, which is what a one-shot decision matches
/// (`oneshot.zig`). `one_shot` (also stamped): the stale request whose decision
/// answers this one at once, so no attention is raised. `input_digest`, from
/// the adapter: `inputDigest` of the call's whole input; null when the adapter
/// does not have it, which means the call can never be auto-answered.
/// `options` (questions): what the harness offers per question.
pub const Request = struct { agent: []const u8, request: []const u8, kind: []const u8, reason: []const u8, call: ?[]const u8 = null, answers: []const []const u8 = &.{}, at: i64 = 0, grant: ?[]const u8 = null, outside_scope: bool = false, tool: ?RequestTool = null, one_shot: ?[]const u8 = null, input_digest: ?[]const u8 = null, options: ?[]const QuestionOptions = null };
/// The options of one question of a `question` request:
/// `id` is `q1`, `q2`, … by position, which is also the key of the answer's
/// `args` (`{"q1":["label"]}`); `question` is its text; `labels` the options
/// in the order the harness lists them (`1`–`9` pick one).
pub const QuestionOptions = struct {
    id: []const u8,
    question: []const u8 = "",
    labels: []const []const u8 = &.{},
    /// The harness takes a typed answer besides the labels (`isOther`; Claude
    /// Code always does), so an answer to this question may be any one string.
    free_text: bool = false,
    /// Some labels of the harness were not kept (too many, not plain, past the
    /// budget), or the whole question was cut by it. A pick cannot be checked
    /// against the labels then: the harness knows them.
    labels_omitted: bool = false,
};

/// Bounds on a question's options (they are persisted, kept in state and sent
/// in every `inbox.list` and `agent.show`). The TUI applies the same ones.
pub const max_questions = 8;
pub const max_labels = 16;
pub const max_question_text = 500;
pub const max_label_text = 200;
pub const max_options_bytes = 8 * 1024;

/// A label that can be offered as it is: it is what a pick sends back to the
/// harness, so it is never cleaned or cut. Not empty (or only spaces), at most
/// `max_label_text` bytes, valid UTF-8, no control character (C0, DEL, C1).
pub fn plainLabel(s: []const u8) bool {
    if (s.len == 0 or s.len > max_label_text or !std.unicode.utf8ValidateSlice(s)) return false;
    if (std.mem.trim(u8, s, " ").len == 0) return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < 0x20 or c == 0x7f) return false;
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) return false;
    }
    return true;
}
/// The request's `tool`, from the call's `tool.started`.
pub const RequestTool = struct { kind: []const u8, name: []const u8, title: []const u8 = "", args: ?ToolArgs = null };
/// `by`: venom, harness or turn_end, stop, or
/// timeout (`attention.approval_timeout`). `grant` is set when a
/// standing "allow always" decision answered the request (`by:
/// venom`): no attention was raised for it. `one_shot` is the same
/// for a one-shot decision: the stale request that decided it.
pub const RequestResolved = struct { agent: []const u8, request: []const u8, by: []const u8, grant: ?[]const u8 = null, one_shot: ?[]const u8 = null };
/// An answer to stale request `request` becomes a one-shot decision for the
/// agent's next turn (`oneshot.zig`). `key` is the
/// normalized args; `kind` the request's kind. Internal.
pub const DecisionRecorded = struct { agent: []const u8, request: []const u8, kind: []const u8, key: []const u8, cwd: []const u8, decision: []const u8, reason: ?[]const u8 = null, args_json: ?[]const u8 = null, at: i64 = 0, effect: []const u8 = "" };
/// `by`: `consumed` (it answered the re-asked call), `expired` (its turn ended
/// first, or a daemon start found its turn never began) or `resume_failed`.
/// Internal.
pub const DecisionClosed = struct { agent: []const u8, request: []const u8, by: []const u8 };
/// "Allow always" (inbox key `a`): a standing decision that approvals in `workspace` whose
/// narrowest grant is `grant` are allowed. `agent` and `request` are the
/// answer that recorded it; `at` is ms since the Unix epoch. Internal.
pub const AlwaysGranted = struct { workspace: []const u8, grant: []const u8, agent: []const u8 = "", request: []const u8 = "", at: i64 = 0 };
/// `always.revoke`: the standing decision is gone. Internal.
pub const AlwaysRevoked = struct { workspace: []const u8, grant: []const u8, at: i64 = 0 };
/// Outbox entry: `key` is the idempotency key the executor receives; it is
/// unique for the life of the log. `payload` is compact JSON for the executor.
pub const EffectRequested = struct { key: []const u8, kind: []const u8, payload: []const u8 };
pub const EffectCompleted = struct { key: []const u8, ok: bool, detail: []const u8 = "" };
/// `panes`: the venomx panes that were still running at this start
/// (`pane.list` with `exited: false`), as the caller found them.
/// The decider takes every `handed_over` agent whose take-over pane is not
/// among them back. Empty when venomx is not
/// reachable or not used.
pub const DaemonStarted = struct { pid: i64 = 0, panes: []const []const u8 = &.{} };
/// A new agent. `state` is its initial state:
/// `queued` for `create` (an import may start elsewhere later). `at` is milliseconds
/// since the Unix epoch, from the decider's caller. `harness_session` is the
/// harness's own id for resume and log matching: an attribute, never the
/// agent's name. `repos` empty means the whole workspace.
pub const AgentCreated = struct {
    agent: []const u8,
    title: []const u8,
    harness: []const u8,
    workspace: []const u8,
    repos: []const []const u8 = &.{},
    parent: ?[]const u8 = null,
    /// The linked issue's number (`--issue`), for the list's filter.
    issue: ?[]const u8 = null,
    harness_session: ?[]const u8 = null,
    /// A fork's source conversation, for a harness that copies it at the
    /// fork's first start (claude-code). A protocol `agent.binding`
    /// ends it: the copy exists by then. Internal.
    fork_source: ?[]const u8 = null,
    state: AgentState = .queued,
    /// `worktrees` are its parent's: a fork runs in its source's folder, the
    /// only place its harness can resume the copied conversation.
    /// Cleaning this agent leaves them to the parent. Internal.
    borrowed: bool = false,
    /// The folder the harness runs in when it is not the workspace root
    /// (an in-place agent spawned in a sub-folder, or the agent's
    /// one worktree). Internal.
    cwd: ?[]const u8 = null,
    /// The worktrees or copies venom made for the agent, one per repo in
    /// scope; empty in place. Internal.
    worktrees: []const Worktree = &.{},
    /// The first prompt, held until the agent gets a concurrency slot
    /// (`agents.max_concurrent`), so it survives a
    /// restart. Null: the caller drives the agent itself. Internal.
    task: ?[]const u8 = null,
    /// venom's permission mode (`config.Mode`), for each harness process.
    /// Null: the harness default. Internal.
    mode: ?[]const u8 = null,
    /// The model asked for at spawn (or inherited). Null: the
    /// harness's default. Internal.
    spawn_model: ?[]const u8 = null,
    /// The grants of the agent's principal, so that a restart restores
    /// exactly these. Null: no principal was issued.
    /// Internal.
    grants: ?[]const proto.grants.Grant = null,
    at: i64 = 0,
};
/// The agent's principal was revoked (`grant.revoke`, or its issuer's end),
/// so that a restart does not issue it again. Internal.
pub const AgentRevoked = struct { agent: []const u8 };
/// The agent got a slot: its held task is being sent. A restart before its
/// turn starts sends it again (the process that had it is gone). Internal.
pub const AgentDispatched = struct { agent: []const u8 };
/// `agent.promote`: the sub-agent is top-level now;
/// `parent` is who it belonged to. Published as `agent.promoted`.
pub const AgentPromoted = struct { agent: []const u8, parent: []const u8, at: i64 = 0 };
/// Someone other than the parent prompted spawned sub-agent `child`
/// ("the parent sees the message"). `agent` is the parent.
/// Published as `agent.child_prompted`; `agent.show` of the parent lists it.
pub const ChildPrompted = struct { agent: []const u8, child: []const u8, text: []const u8, at: i64 = 0 };
/// One isolated checkout of a repo for an agent (`isolation.zig`).
pub const Worktree = struct {
    /// The repo, relative to the agent's workspace ("." for its root).
    repo: []const u8,
    /// Absolute path of the worktree (or copy), a sibling of the repo.
    path: []const u8,
    /// The worktree's branch; null for a copy.
    branch: ?[]const u8 = null,
};
/// One agent state transition. Published as `agent.state_changed
/// {agent, from, to}`.
pub const AgentStateChanged = struct { agent: []const u8, from: AgentState, to: AgentState, at: i64 = 0 };
/// The user opened a settled agent: it is no longer unread.
pub const AgentOpened = struct { agent: []const u8 };
/// `stop` or `archive` of a `running|needs_you` agent:
/// `turn` is being interrupted; with `archive`, the agent is archived once
/// that turn has ended. Internal.
pub const AgentStopRequested = struct { agent: []const u8, turn: []const u8, archive: bool = false };
/// `inbox.snooze`: the agent's inbox item
/// `item` (a request id, or `failed`, `limit`, `review`) is hidden until
/// `until`. `at` is when it was snoozed: a state item that changed since is
/// a new item. Internal.
pub const AttentionSnoozed = struct { agent: []const u8, item: []const u8, until: i64, at: i64 = 0 };
/// Workspace records (see `workspaces.zig`). `repos`
/// are the git roots discovery found under `path`, relative to it ("." when
/// the folder is itself a repo), sorted. Discovery is I/O, so it runs before
/// the command and its result is part of the fact.
pub const WorkspaceAdded = struct { path: []const u8, repos: []const []const u8 = &.{} };
pub const WorkspaceScanned = struct { path: []const u8, repos: []const []const u8 = &.{} };
/// `repos` repeats what the workspace last had, so that it is published
/// without a lookup. The decider fills it in; older records
/// have none.
pub const WorkspaceRemoved = struct { path: []const u8, repos: []const []const u8 = &.{} };
/// Harness records (decider half in
/// `harness.zig`). A tool call is venom's `c<n>`; `kind` is the
/// normalized kind (`exec`, `edit`, `read`, …) and `name` the harness's own
/// tool name, shown as the row's verb. `tool.ended` repeats kind, name and
/// title so that it is published without a lookup.
pub const ToolStarted = struct {
    agent: []const u8,
    turn: []const u8,
    call: []const u8,
    kind: []const u8,
    name: []const u8,
    title: []const u8 = "",
    status: []const u8 = "running",
    parent_call: ?[]const u8 = null,
    harness_ref: ?[]const u8 = null,
    args: ?ToolArgs = null,
    /// The harness's own input for the call, as JSON
    /// text, kept for `J` (`agent.tool`). At most `harness.body_max` bytes,
    /// like a body. Null when the harness gave none, and in older logs.
    raw_input: ?ToolBody = null,
    /// Stamped by the decider, ms since the Unix epoch (a call
    /// running longer than `ui.transcript.open_running_after` opens).
    at: i64 = 0,
};
/// The call's `args`, normalized per kind. Only the
/// members of the call's kind are set; the log leaves out the rest:
///
/// | kind | members |
/// |---|---|
/// | `exec` | `command`, `cwd` |
/// | `edit` | `path`, `change` (`modify`, `create`, `delete`), `added?`, `removed?` |
/// | `read`, `list` | `path` |
/// | `search` | `query`, `path?` |
/// | `fetch` | `url?`, `query?` |
/// | `mcp` | `server`, `tool` |
/// | `agent` | `child_ref?` |
/// | others | none (`{}`) |
pub const ToolArgs = struct {
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    path: ?[]const u8 = null,
    change: ?[]const u8 = null,
    added: ?u64 = null,
    removed: ?u64 = null,
    query: ?[]const u8 = null,
    url: ?[]const u8 = null,
    server: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    child_ref: ?[]const u8 = null,
};
/// The call's `body`: a call's output or diff. `text` holds at
/// most `harness.body_max` bytes (the start of the output, cut at a UTF-8
/// boundary); `bytes` is the whole size and `truncated` says text is cut.
pub const ToolBody = struct { text: []const u8, truncated: bool = false, bytes: u64 = 0 };
/// `status`: ok, error, declined, interrupted. `exit` only when the harness
/// reported one, never guessed.
pub const ToolEnded = struct {
    agent: []const u8,
    turn: []const u8,
    call: []const u8,
    status: []const u8,
    kind: []const u8 = "",
    name: []const u8 = "",
    title: []const u8 = "",
    exit: ?i64 = null,
    duration_ms: ?u64 = null,
    body: ?ToolBody = null,
};
/// Per-turn usage: already deltas, never totals.
pub const Usage = struct {
    agent: []const u8,
    turn: []const u8,
    model: []const u8 = "",
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    includes_subagents: bool = false,
    source: []const u8 = "exact",
};
/// `context {used, window, source}`: the
/// agent's context size as the harness last reported it, not turn-scoped.
/// `source` is `exact` or `estimate`. `at` (ms since the Unix epoch) is
/// stamped by the decider. Published as `agent.context {agent, used,
/// window}`.
pub const Context = struct {
    agent: []const u8,
    used: u64,
    window: u64,
    source: []const u8 = "estimate",
    at: i64 = 0,
    /// Tokens of the system prompt and instructions, and of the tool
    /// definitions, when the harness says. Null: unknown, and the
    /// context panel never guesses them.
    system: ?u64 = null,
    tools: ?u64 = null,
};
/// The MCP servers the harness's process has configured, as it
/// reported them at its start; the latest report wins. Internal.
pub const McpServers = struct { agent: []const u8, servers: []const []const u8 = &.{} };
/// `agent.mcp_off`: the harness's next process
/// starts without these MCP servers. Adds to what is already off. Internal.
pub const McpOff = struct { agent: []const u8, servers: []const []const u8 = &.{} };
/// A `harness.fork` effect ended. `key` is the effect's. `fork` is
/// the new agent, or `code` the refusal code (no agent was made,
/// and the source did not change). Published as `agent.fork_ended`.
pub const ForkEnded = struct { agent: []const u8, key: []const u8, ok: bool, fork: ?[]const u8 = null, code: ?[]const u8 = null };
/// One plan window: `label` comes from the harness, `resets_at`
/// is RFC 3339 UTC.
pub const PlanWindow = struct { id: []const u8, label: []const u8, used_pct: u32 = 0, resets_at: ?[]const u8 = null };
/// `plan_windows`: per harness and account,
/// not per agent or turn; the latest report wins. `billing` is
/// `subscription`, `api_key` or `unknown`, from the harness's own auth status;
/// `source` is the descriptor's `stable` or `experimental`. `at` (ms since the
/// Unix epoch) is stamped by the decider. Internal for now: it has no
/// published name.
pub const PlanWindows = struct {
    harness: []const u8,
    account: []const u8 = "unknown",
    billing: []const u8 = "unknown",
    windows: []const PlanWindow = &.{},
    source: []const u8 = "stable",
    at: i64 = 0,
};
/// The durable tie between an agent and its harness conversation, logged on every `session` the harness reports. `mode` is
/// `protocol` (venom drives it) or `tui` (taken over). In `tui` mode,
/// `pane` is the venomx pane of the take-over split (host mode; null in own
/// mode), so that a restarted daemon can check it;
/// `root` is the process that runs the take-over split, reported once it
/// started (`agent.takeover_split`), which is what a hook call must
/// descend from; `transcript_ref` is the session file a hook named, for
/// catch-up.
pub const AgentBinding = struct {
    agent: []const u8,
    harness: []const u8,
    harness_session: ?[]const u8 = null,
    cwd: []const u8 = "",
    mode: []const u8 = "protocol",
    harness_version: ?[]const u8 = null,
    model: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    root: ?PaneRoot = null,
    transcript_ref: ?[]const u8 = null,
};
/// A process identity: never the pid alone, so a dead
/// split's pid reused by something else matches nothing.
pub const PaneRoot = struct { pid: i64, start: u64 };
/// `attention.away`: the harness's own TUI is
/// waiting for the human. `kind` is `approval`, `question` or `review` (its
/// turn ended). The agent stays `handed_over`; the answer happens in the
/// harness's TUI, so the inbox item only points at the split. `at` is
/// stamped by the decider. At most one per agent.
pub const AttentionAway = struct { agent: []const u8, kind: []const u8, reason: []const u8, at: i64 = 0 };
/// The away item is gone: replaced by a newer report (`by: "harness"`), or
/// the agent was taken back (`by: "takeback"`).
pub const AttentionAwayCleared = struct { agent: []const u8, by: []const u8 };

/// SHA-256 (hex) of a call's input: JSON with its object keys sorted, so that
/// key order is not a different call, and otherwise byte for byte (numbers
/// keep their text). Input that is not JSON is hashed as it is. In `a`.
pub fn inputDigest(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var bytes = input;
    if (std.json.parseFromSliceLeaky(std.json.Value, a, input, .{ .parse_numbers = false })) |value| {
        var out: std.Io.Writer.Allocating = .init(a);
        var w: std.json.Stringify = .{ .writer = &out.writer };
        writeCanonical(a, &w, value) catch return error.OutOfMemory;
        bytes = out.written();
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    return a.dupe(u8, &hex);
}

fn writeCanonical(a: std.mem.Allocator, w: *std.json.Stringify, value: std.json.Value) anyerror!void {
    switch (value) {
        .object => |o| {
            const keys = try a.dupe([]const u8, o.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: void, l: []const u8, r: []const u8) bool {
                    return std.mem.order(u8, l, r) == .lt;
                }
            }.lessThan);
            try w.beginObject();
            for (keys) |k| {
                try w.objectField(k);
                try writeCanonical(a, w, o.get(k).?);
            }
            try w.endObject();
        },
        .array => |list| {
            try w.beginArray();
            for (list.items) |item| try writeCanonical(a, w, item);
            try w.endArray();
        },
        else => try w.write(value),
    }
}

pub const Event = union(enum) {
    daemon_started: DaemonStarted,
    turn_started: TurnStarted,
    turn_prompt: TurnPrompt,
    text: Text,
    turn_ended: TurnEnded,
    request: Request,
    request_resolved: RequestResolved,
    effect_requested: EffectRequested,
    effect_completed: EffectCompleted,
    agent_created: AgentCreated,
    agent_state_changed: AgentStateChanged,
    agent_opened: AgentOpened,
    workspace_added: WorkspaceAdded,
    workspace_scanned: WorkspaceScanned,
    workspace_removed: WorkspaceRemoved,
    tool_started: ToolStarted,
    tool_ended: ToolEnded,
    usage: Usage,
    context: Context,
    plan_windows: PlanWindows,
    agent_binding: AgentBinding,
    mcp_servers: McpServers,
    agent_mcp_off: McpOff,
    agent_fork_ended: ForkEnded,
    agent_stop_requested: AgentStopRequested,
    attention_snoozed: AttentionSnoozed,
    attention_away: AttentionAway,
    attention_away_cleared: AttentionAwayCleared,
    always_granted: AlwaysGranted,
    always_revoked: AlwaysRevoked,
    decision_recorded: DecisionRecorded,
    decision_closed: DecisionClosed,
    /// The stale request comes back: the answer's resume failed. Internal
    /// record, published as `agent.attention`.
    request_reopened: Request,
    agent_dispatched: AgentDispatched,
    agent_revoked: AgentRevoked,
    agent_promoted: AgentPromoted,
    child_prompted: ChildPrompted,

    pub const Tag = std.meta.Tag(Event);

    /// The record type written to the log.
    pub fn typeName(tag: Tag) []const u8 {
        return switch (tag) {
            .daemon_started => "daemon.started",
            .turn_started => "turn.started",
            .turn_prompt => "turn.prompt",
            .text => "text",
            .turn_ended => "turn.ended",
            .request => "request",
            .request_resolved => "request.resolved",
            .effect_requested => "effect.requested",
            .effect_completed => "effect.completed",
            .agent_created => "agent.created",
            .agent_state_changed => "agent.state_changed",
            .agent_opened => "agent.opened",
            .workspace_added => "workspace.added",
            .workspace_scanned => "workspace.scanned",
            .workspace_removed => "workspace.removed",
            .tool_started => "tool.started",
            .tool_ended => "tool.ended",
            .usage => "usage",
            .context => "context",
            .plan_windows => "plan_windows",
            .agent_binding => "agent.binding",
            .mcp_servers => "mcp.servers",
            .agent_mcp_off => "agent.mcp_off",
            .agent_fork_ended => "agent.fork_ended",
            .agent_stop_requested => "agent.stop_requested",
            .attention_snoozed => "attention.snoozed",
            .attention_away => "attention.away",
            .attention_away_cleared => "attention.away_cleared",
            .always_granted => "always.granted",
            .always_revoked => "always.revoked",
            .decision_recorded => "decision.recorded",
            .decision_closed => "decision.closed",
            .request_reopened => "request.reopened",
            .agent_dispatched => "agent.dispatched",
            .agent_revoked => "agent.revoked",
            .agent_promoted => "agent.promoted",
            .child_prompted => "agent.child_prompted",
        };
    }

    pub fn fromTypeName(name: []const u8) ?Tag {
        inline for (comptime std.enums.values(Tag)) |tag| {
            if (std.mem.eql(u8, typeName(tag), name)) return tag;
        }
        return null;
    }

    /// Writes `{"type":…,"data":{…}}`.
    pub fn write(self: Event, w: *std.json.Stringify) !void {
        try w.beginObject();
        try w.objectField("type");
        try w.write(typeName(self));
        try w.objectField("data");
        switch (self) {
            inline else => |payload| try w.write(payload),
        }
        try w.endObject();
    }

    /// Parses one `{"type":…,"data":{…}}` value. Strings live in `a`.
    pub fn parse(a: std.mem.Allocator, value: std.json.Value) !Event {
        if (value != .object) return error.InvalidRecord;
        const kind = value.object.get("type") orelse return error.InvalidRecord;
        const data = value.object.get("data") orelse return error.InvalidRecord;
        if (kind != .string) return error.InvalidRecord;
        const tag = fromTypeName(kind.string) orelse return error.UnknownRecord;
        switch (tag) {
            inline else => |t| {
                const Payload = @FieldType(Event, @tagName(t));
                const payload = std.json.parseFromValueLeaky(Payload, a, data, .{ .ignore_unknown_fields = true }) catch return error.InvalidRecord;
                return @unionInit(Event, @tagName(t), payload);
            },
        }
    }

    /// A deep copy whose strings live in `a`.
    pub fn dupe(self: Event, a: std.mem.Allocator) !Event {
        switch (self) {
            inline else => |payload, t| return @unionInit(Event, @tagName(t), try deepCopy(@TypeOf(payload), a, payload)),
        }
    }
};

/// Copies every string (and slice and nested struct) of `value` into `a`.
fn deepCopy(comptime T: type, a: std.mem.Allocator, value: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .optional => |o| return if (value) |v| try deepCopy(o.child, a, v) else null,
        .@"struct" => |info| {
            var copy = value;
            inline for (info.field_names, info.field_types) |name, F| @field(copy, name) = try deepCopy(F, a, @field(value, name));
            return copy;
        },
        .pointer => |p| {
            if (p.size != .slice) return value;
            if (p.child == u8) return a.dupe(u8, value);
            const list = try a.alloc(p.child, value.len);
            for (list, value) |*d, s| d.* = try deepCopy(p.child, a, s);
            return list;
        },
        else => return value,
    }
}

/// Decider input. Commands are validated against the current state; events
/// are facts. `record` carries an adapter event.
pub const Command = union(enum) {
    /// The daemon started: logs `daemon.started`, ends every open turn with
    /// `failed.daemon_restart` and keeps pending
    /// requests as stale inbox items.
    start: DaemonStarted,
    /// An adapter event for one agent. Effect and daemon records are refused.
    record: Event,
    /// A human (or a granted caller) answers a pending request. Resolves it
    /// and puts a `harness.respond` effect in the outbox in the same commit.
    /// `reason` (deny, reject) and `args_json` (allow_edited, question
    /// picks) are the answer's optional members; they go into the
    /// effect payload with the decision. `by` is the `request.resolved` by.
    /// `grant` is set only by the decider itself, when a standing decision
    /// answers a new request (it ends up on `request.resolved`), `one_shot`
    /// when a one-shot decision does. Answering a
    /// stale request records that decision and resumes the agent.
    answer: struct { agent: []const u8, request: []const u8, decision: []const u8, reason: ?[]const u8 = null, args_json: ?[]const u8 = null, by: []const u8 = "venom", grant: ?[]const u8 = null, one_shot: ?[]const u8 = null },
    /// `attention.approval_timeout`: every live approval
    /// older than `approval_timeout_ms` is answered `deny` with reason
    /// `timeout` (`by: "timeout"`).
    expire: struct { approval_timeout_ms: u64 },
    /// `inbox.snooze`: hides an existing inbox item until `until`.
    snooze: struct { agent: []const u8, item: []const u8, until: i64 },
    /// `always.revoke`: drops a standing "allow always" decision; `NotFound`
    /// when there is none.
    revoke_always: struct { workspace: []const u8, grant: []const u8 },
    /// The effect worker finished an effect. Idempotent: completing an
    /// already completed effect decides nothing.
    complete: EffectCompleted,
    /// Creates an agent in `queued`. `at` is set by the decider.
    create: AgentCreated,
    /// `agent.stop`: `queued → settled`; a
    /// `running|needs_you` agent's pending requests are cleared
    /// (`by: "stop"`) and a `harness.stop` effect interrupts its turn;
    /// `settled|failed|archived` decide nothing; `handed_over` is
    /// `HandedOver`.
    stop: struct { agent: []const u8 },
    /// `agent.archive`: a stop, then `settled|failed → archived` (for a
    /// running turn, once it has ended). `handed_over` is `HandedOver`.
    archive: struct { agent: []const u8 },
    /// Asks for a transition that is not driven by turn records:
    /// `settled|failed → archived`, `settled → handed_over`,
    /// `handed_over → settled` (see `agent.zig`).
    transition: struct { agent: []const u8, to: AgentState },
    /// `agent.takeover`: a `settled` agent's
    /// conversation goes to the harness's own TUI. Logs a `tui` binding
    /// (`pane`: the take-over split's venomx pane, null in own mode), then
    /// `settled → handed_over`. Mid-turn (`queued|running|needs_you`) it is
    /// `TurnRunning`; `handed_over` is `HandedOver`.
    takeover: struct { agent: []const u8, pane: ?[]const u8 = null },
    /// `agent.takeback`: `handed_over → settled`, and a `harness.takeback`
    /// effect imports what ran meanwhile (`since`: when it was handed over).
    /// A `settled` agent decides nothing (the split's exit and `T` may both
    /// ask); any other state is `InvalidTransition`.
    takeback: struct { agent: []const u8 },
    /// `fork`: a `harness.fork` effect asks the
    /// harness for a copy of the conversation, through `through_turn` or the
    /// latest turn. Its completion carries the new conversation's id in
    /// `detail`, or the refusal code. `archived` is `InvalidTransition`,
    /// `handed_over` is `HandedOver`, mid-turn is `TurnRunning`.
    fork: struct {
        agent: []const u8,
        through_turn: ?[]const u8 = null,
        /// The first prompt of the agent the fork becomes.
        task: ?[]const u8 = null,
    },
    /// `agent.mcp_off`, between turns.
    mcp_off: struct { agent: []const u8, servers: []const []const u8 },
    /// `agent.takeover_split`: the process running the take-over
    /// split of a `handed_over` agent. Logs the binding again with `root`.
    takeover_split: struct { agent: []const u8, root: PaneRoot },
    /// `agent.takeover_pane`: the venomx pane running the take-over.
    /// Logs the binding again with its ID.
    takeover_pane: struct { agent: []const u8, pane: []const u8 },
    /// `harness.hook`, `handed_over` agents
    /// only. `kind` set: raises the away item, replacing any before it, also
    /// one in the same words (a new prompt, snoozed or not). `transcript_ref`
    /// set: recorded on the binding for catch-up.
    away: struct { agent: []const u8, kind: ?[]const u8 = null, reason: []const u8 = "", transcript_ref: ?[]const u8 = null },
    /// A waiting agent got a slot: logs `agent.dispatched`. Only a `queued`
    /// agent with a held, unsent task.
    dispatch: struct { agent: []const u8 },
    /// Records that the agent's principal was revoked.
    revoked: struct { agent: []const u8 },
    /// `agent.promote`: a sub-agent becomes top-level. A
    /// top-level agent decides nothing; an archived one is `InvalidTransition`.
    promote: struct { agent: []const u8 },
    /// A prompt reached sub-agent `child` from someone other than `parent`.
    child_prompted: struct { parent: []const u8, child: []const u8, text: []const u8 },
    /// The user opened the agent; clears its unread flag.
    open: struct { agent: []const u8 },
    /// Archives every agent that has been `settled` for at least
    /// `archive_after_ms` (config `agents.archive_after`).
    sweep: struct { archive_after_ms: u64 },
    /// Workspace commands; the decider half is in
    /// `workspaces.zig`. Adding a known path decides nothing; a scan that
    /// finds the same repos decides nothing; removing or scanning an unknown
    /// path is `NotFound`.
    workspace_add: WorkspaceAdded,
    workspace_scan: WorkspaceScanned,
    workspace_remove: WorkspaceRemoved,
};

test "events: every record type round-trips through JSON" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const samples = [_]Event{
        .{ .daemon_started = .{ .pid = 7 } },
        .{ .daemon_started = .{ .pid = 8, .panes = &.{ "p3", "p9" } } },
        .{ .agent_stop_requested = .{ .agent = "a1", .turn = "t2", .archive = true } },
        .{ .attention_snoozed = .{ .agent = "a1", .item = "r1", .until = 900_000, .at = 5 } },
        .{ .attention_away = .{ .agent = "a1", .kind = "approval", .reason = "waiting in claude-code", .at = 5 } },
        .{ .attention_away_cleared = .{ .agent = "a1", .by = "takeback" } },
        .{ .agent_binding = .{ .agent = "a1", .harness = "claude-code", .mode = "tui", .pane = "tui:7", .root = .{ .pid = 8, .start = 9 }, .transcript_ref = "/c/s1.jsonl" } },
        .{ .always_granted = .{ .workspace = "/w", .grant = "exec:zig", .agent = "a1", .request = "r1", .at = 5 } },
        .{ .always_revoked = .{ .workspace = "/w", .grant = "exec:zig", .at = 6 } },
        .{ .decision_recorded = .{ .agent = "a1", .request = "r1", .kind = "approval", .key = "{}", .cwd = "/w", .decision = "deny", .reason = "no", .at = 7 } },
        .{ .decision_closed = .{ .agent = "a1", .request = "r1", .by = "expired" } },
        .{ .request_reopened = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "x", .input_digest = "ab", .options = &.{.{ .id = "q1", .labels = &.{"a"} }} } },
        .{ .request = .{ .agent = "a1", .request = "r4", .kind = "approval", .reason = "x", .call = "c2", .one_shot = "r1", .tool = .{ .kind = "exec", .name = "Bash", .title = "make", .args = .{ .command = "make" } } } },
        .{ .request_resolved = .{ .agent = "a1", .request = "r4", .by = "venom", .one_shot = "r1" } },
        .{ .request = .{ .agent = "a1", .request = "r3", .kind = "approval", .reason = "x", .call = "c1", .grant = "exec:zig" } },
        .{ .request_resolved = .{ .agent = "a1", .request = "r3", .by = "venom", .grant = "exec:zig" } },
        .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } },
        .{ .turn_prompt = .{ .agent = "a1", .turn = "t1", .text = "Rename proto.Frame" } },
        .{ .text = .{ .agent = "a1", .turn = "t1", .message = "m1", .text = "hi \"there\"" } },
        .{ .turn_ended = .{ .agent = "a1", .turn = "t1", .reason = "failed", .error_code = "failed.daemon_restart" } },
        .{ .turn_ended = .{ .agent = "a1", .turn = "t2", .reason = "completed" } },
        .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .reason = "run zig build?" } },
        .{ .request_resolved = .{ .agent = "a1", .request = "r1", .by = "venom" } },
        .{ .effect_requested = .{ .key = "k", .kind = "harness.respond", .payload = "{}" } },
        .{ .effect_completed = .{ .key = "k", .ok = true } },
        .{ .agent_created = .{ .agent = "a1", .title = "Add hello", .harness = "claude-code", .workspace = "/w", .repos = &.{ "venom-term", "venom-std" }, .parent = "a0", .harness_session = "6f1c", .fork_source = "5e0b", .at = 5 } },
        .{ .agent_created = .{ .agent = "a2", .title = "t", .harness = "codex", .workspace = "/w" } },
        .{ .agent_created = .{ .agent = "a3", .title = "t", .harness = "codex", .workspace = "/w", .repos = &.{"x"}, .cwd = "/w/x-a3", .worktrees = &.{.{ .repo = "x", .path = "/w/x-a3", .branch = "venom/a3" }} } },
        .{ .agent_state_changed = .{ .agent = "a1", .from = .needs_you, .to = .running, .at = 9 } },
        .{ .agent_opened = .{ .agent = "a1" } },
        .{ .agent_created = .{ .agent = "a4", .title = "t", .harness = "codex", .workspace = "/w", .task = "do it", .mode = "plan", .spawn_model = "m", .grants = &.{.{ .right = .read, .scope = "agent:a4" }} } },
        .{ .agent_dispatched = .{ .agent = "a4" } },
        .{ .agent_revoked = .{ .agent = "a4" } },
        .{ .agent_promoted = .{ .agent = "a4", .parent = "a1", .at = 3 } },
        .{ .child_prompted = .{ .agent = "a1", .child = "a4", .text = "hey", .at = 3 } },
        .{ .workspace_added = .{ .path = "/w", .repos = &.{ ".", "a/b" } } },
        .{ .workspace_scanned = .{ .path = "/w", .repos = &.{} } },
        .{ .workspace_removed = .{ .path = "/w", .repos = &.{"a/b"} } },
        .{ .request = .{ .agent = "a1", .request = "r2", .kind = "approval", .reason = "x", .call = "c1", .answers = &.{ "allow_once", "deny" } } },
        .{ .request = .{ .agent = "a1", .request = "r3", .kind = "question", .reason = "Which?", .options = &.{.{ .id = "q1", .question = "Which?", .labels = &.{ "a", "b" } }} } },
        .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build test", .harness_ref = "toolu_1" } },
        .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c1", .status = "ok", .kind = "exec", .name = "Bash", .exit = 0, .duration_ms = 4210 } },
        .{ .usage = .{ .agent = "a1", .turn = "t1", .model = "m", .tokens_in = 1, .tokens_out = 2, .cache_read = 3, .cache_write = 4, .includes_subagents = true } },
        .{ .agent_binding = .{ .agent = "a1", .harness = "fake", .harness_session = "s1", .cwd = "/w", .harness_version = "0.1.0" } },
        .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c2", .kind = "edit", .name = "Edit", .title = "a.zig", .args = .{ .path = "/w/a.zig", .change = "modify", .added = 6, .removed = 4 } } },
        .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c3", .kind = "other", .name = "X", .args = .{} } },
        .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c4", .kind = "exec", .name = "Bash", .raw_input = .{ .text = "{\"command\":\"ls\"}", .bytes = 16 } } },
        .{ .tool_ended = .{ .agent = "a1", .turn = "t1", .call = "c2", .status = "ok", .body = .{ .text = "ok\n", .truncated = true, .bytes = 9000 } } },
        .{ .turn_ended = .{ .agent = "a1", .turn = "t3", .reason = "limit", .error_code = "failed.usage_limit", .resets_at = "2026-11-07T15:00:00Z" } },
        .{ .context = .{ .agent = "a1", .used = 124_000, .window = 200_000, .at = 5 } },
        .{ .plan_windows = .{ .harness = "codex", .account = "chatgpt", .billing = "subscription", .windows = &.{.{ .id = "primary", .label = "5h", .used_pct = 31, .resets_at = "2026-11-07T15:00:00Z" }}, .at = 6 } },
        .{ .agent_binding = .{ .agent = "a1", .harness = "claude-code", .harness_session = "s1", .mode = "tui", .pane = "p3" } },
    };
    for (samples) |ev| {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
        try ev.write(&w);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out.written(), .{});
        const back = try Event.parse(arena.allocator(), value);
        try std.testing.expectEqual(std.meta.activeTag(ev), std.meta.activeTag(back));
        var again: std.Io.Writer.Allocating = .init(a);
        defer again.deinit();
        var w2: std.json.Stringify = .{ .writer = &again.writer, .options = .{ .emit_null_optional_fields = false } };
        try back.write(&w2);
        try std.testing.expectEqualStrings(out.written(), again.written());
    }
    try std.testing.expectError(error.UnknownRecord, Event.parse(arena.allocator(), try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"nope\",\"data\":{}}", .{})));
}
