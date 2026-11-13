//! The claude-code adapter.
//!
//! Channel: Claude Code's print mode with streaming JSON both ways, the
//! documented CLI form of the Agent SDK. Only documented flags are used:
//!
//! ```bash
//! claude -p --input-format stream-json --output-format stream-json --verbose \
//!   --session-id <uuid>                       # new conversation, id chosen by venom
//!   --resume <id>                             # reattach
//!   --resume <src> --fork-session --session-id <new>   # first start of a fork
//!   --mcp-config '{"mcpServers":{"venom":…,"venom-permissions":…}}'  # venom's MCP servers (mcp.zig)
//!   --permission-prompt-tool mcp__venom-permissions__permission_prompt   # with a replier
//!   --model <m> --permission-mode <mode>
//!   --add-dir <root>…                         # in-scope roots outside the cwd
//!   --settings '{"permissions":{"ask":["Edit(//<repo>/**)","Bash(rm *<repo>/*)",…]}}'   # out-of-scope repos
//! ```
//!
//! Scope. The agent runs at its workspace root, so
//! every repo is under Claude Code's working directory. Out-of-scope repos
//! get a session-only `permissions.ask` rule (`--settings`, never the
//! user's settings files): `Edit(//<abs repo>/**)` covers every built-in
//! file-editing tool (Edit, MultiEdit, Write, NotebookEdit), and an `ask`
//! rule prompts even in `acceptEdits`, so the edit reaches venom's
//! permission prompt tool as an approval. In-scope roots outside the cwd
//! (worktrees, later) are added with `--add-dir`.
//!
//! Bash: `Edit` rules do not see commands, and `acceptEdits`
//! allows `rm`, `mv`, `touch`… under the cwd by itself. So the same setting
//! has `ask` rules for the file-writing programs naming the repo
//! (`Bash(rm *<repo>/*)`, `Bash(rm *<repo>)`, `Bash(rm *<repo> *)`) and for `cd` into it, so they
//! are not allowed unasked (checked in `acceptEdits` on 2.1.319). venom then judges the command
//! (`command_writes.zig`): one that writes outside the scope gets no grant,
//! so no "allow always" answers it. What this cannot enforce:
//! redirections (Claude Code matches rules without them, so
//! `echo x > c/y` is judged only when it is asked anyway), a relative write
//! after an approved `cd` (the shell keeps its folder, and `acceptEdits`
//! allows it by itself), and what any other program writes by itself. The Claude Code sandbox would hold those
//! but also cuts the network, so it is not turned on here.
//!
//! No SDK internals, no undocumented control messages:
//! `interrupt` is SIGINT, approvals come through
//! the permission prompt MCP tool.
//!
//! Output mapping (`decode`, one stdout line at a time):
//!
//! | claude stream-json | normalized |
//! |---|---|
//! | `system`/`init` | `session` (`session_id`, `model`, `claude_code_version`) |
//! | first line after a `send` | `turn.started {origin: user}`; output with no send pending is `origin: harness` |
//! | `assistant` `text` block | `text {final: true}` (sub-agent text, `parent_tool_use_id` set, is skipped) |
//! | `assistant` `tool_use` block | `tool.started` (`pending`), kind from the tool name, `parent_call` from `parent_tool_use_id`, `args` from `input` (below) |
//! | `user` `tool_result` block | `tool.ended`: `ok`, `error` (`is_error`), `declined` (venom denied it); `exit` only from a structured `tool_use_result` (Claude Code 2.1.319 sends none for Bash); `duration_ms` measured; `body` the diff from `tool_use_result.structuredPatch` (or a created file's `content`), else its text `content` |
//! | `result` | `usage` per model (deltas of the cumulative `modelUsage`), `context` when it changed, then `turn.ended` |
//! | `rate_limit_event` rejected | remembered: the turn ends `limit` with `failed.usage_limit` and its `resetsAt` as `resets_at` |
//!
//! Tool `args` from `tool_use.input`:
//! `Bash` `{command, cwd}` (the agent's cwd); `Edit`/`MultiEdit` `{path,
//! change: modify, added, removed}` with line counts of `new_string` and
//! `old_string`; `Write` `{path, change: create, added}` (Claude Code
//! does not say whether the file existed); `NotebookEdit` `{path, change}`
//! from `edit_mode`; `Read`, `LS` `{path}`; `Glob` `{path}` (its `path`, or
//! the pattern); `Grep` `{query, path?}`; `WebFetch` `{url}`; `WebSearch`
//! `{query}`; `mcp__<server>__<tool>` `{server, tool}`; `{}` for the rest,
//! none for questions and plans.
//!
//! `context` (`estimate`): input plus cache tokens of the last
//! main-agent `assistant` message's `usage`, over the main model's
//! `modelUsage.contextWindow`; logged at the turn's `result` when both are
//! known and the value changed.
//!
//! `harness_version`: configured, else `claude --version`, run once on a
//! thread of its own after `startVersionDetect` (the daemon calls it);
//! `probe` never waits for it and reports null until it is known.
//! | anything else | ignored |
//!
//! `result` reasons: `success` → `completed`; after an `interrupt` →
//! `interrupted`; HTTP 429, a rejected rate limit or a usage-limit error →
//! `limit` (`failed.usage_limit`); any other error → `failed`
//! (`failed.harness_turn`).
//!
//! Requests: Claude Code calls the `permission_prompt` tool of
//! venom's `venom-permissions` MCP server (`permission_server.zig`, a
//! stdio child of Claude Code) with `{tool_name, input, tool_use_id}` and
//! waits. That server forwards it to the daemon as `harness.permission_prompt`
//! (`permissions.zig`), which finds the caller's agent by its token and
//! hands it to `permissionPrompt` with the open call's ticket; the request
//! is raised on the conversation (`AskUserQuestion` → `question`,
//! `ExitPlanMode` → `plan`, anything else → `approval`) and the call stays
//! open. `respond` turns venom's answer into Claude Code's permission
//! result JSON and gives it to the `Replier` with the ticket; the daemon
//! finishes the call with it and the server returns it as the tool result
//! text. `--permission-prompt-tool` is documented in the CLI reference
//! (code.claude.com/docs/en/cli-reference) but, in 2.1.319, hidden from
//! `claude --help`; it is passed, and `probe` declares requests, only when
//! both the MCP server and a replier are configured.
const std = @import("std");
const builtin = @import("builtin");
const supervisor = @import("supervisor");
const log = @import("log");
const contract = @import("contract.zig");
const mcp = @import("mcp.zig");
const version = @import("version.zig");
const transcript = @import("claude_transcript.zig");
const writer_programs = @import("../eventlog/command_writes.zig").writer_programs;
const Conversation = contract.Conversation;

pub const name = "claude-code";

/// The Claude Code version this mapping was checked against
/// (`claude --help` of 2.1.319).
pub const tested_version = "2.1.319";
/// The oldest version the adapter can drive: `--permission-mode manual`
/// exists since 2.1.200.
pub const min_version = "2.1.200";

/// The flags the adapter passes itself; `harness.claude_code.extra_args`
/// must not repeat them (doctor).
pub const flags = [_][]const u8{ "-p", "--print", "--input-format", "--output-format", "--verbose", "--session-id", "--resume", "--fork-session", "--mcp-config", "--permission-prompt-tool", "--model", "--permission-mode" };

/// The MCP tool name Claude Code calls for permission prompts.
pub const prompt_tool = "mcp__" ++ mcp.permissions_server_name ++ "__" ++ mcp.permission_tool;

/// Where permission results go: the daemon side of venom's permission
/// prompt server, which finishes the open call `ticket` (the prompt's) with
/// `result` as its text. `error.RequestResolved` when that call is gone.
pub const Replier = struct {
    ptr: *anyopaque,
    reply: *const fn (ptr: *anyopaque, agent: []const u8, tool_use_id: []const u8, ticket: u64, result: []const u8) anyerror!void,
};

/// venom's MCP server as Claude Code should start it (`mcp.zig`).
pub const Mcp = mcp.Server;

/// One permission prompt as the MCP server received it.
pub const Prompt = struct {
    tool_name: []const u8,
    /// The tool's `input`, as JSON.
    input_json: []const u8,
    tool_use_id: []const u8,
    /// The replier's handle for the open MCP call (the daemon's call ticket).
    ticket: u64 = 0,
};

/// The context estimate (`source: estimate`): the last main-agent model
/// call's input plus cache tokens, and the model's context window.
pub const ContextEstimate = struct { used: u64, window: ?u64 = null };

pub const approval_answers = [_][]const u8{ "allow_once", "allow_always", "allow_edited", "deny", "cancel_turn" };
pub const plan_answers = [_][]const u8{ "approve", "reject" };

/// What the adapter remembers per agent, beside the `Conversation`.
const AgentState = struct {
    /// Sends written while a turn ran; each starts the next turn
    /// (`steer: queue`).
    queued: u32 = 0,
    interrupting: bool = false,
    /// A rejected rate limit was reported during the open turn.
    limited: bool = false,
    /// Unix seconds, when the harness said.
    resets_at: ?i64 = null,
    context: ?ContextEstimate = null,
    /// The last context logged, so an unchanged one is not logged again.
    context_logged: ?ContextEstimate = null,
    /// The model `system/init` reported, for usage without `modelUsage`.
    model: []const u8 = "",
    /// Cumulative `modelUsage` per model at the previous turn's end;
    /// re-based on every process start.
    totals: std.StringHashMapUnmanaged(Totals) = .empty,
    /// Per open turn (reset at its end): tool start times, prompts waiting
    /// for an answer, calls venom declined.
    turn: std.heap.ArenaAllocator,
    started: std.StringHashMapUnmanaged(i64) = .empty,
    prompts: std.StringHashMapUnmanaged(Prompt) = .empty,
    declined: std.StringHashMapUnmanaged(void) = .empty,

    fn endTurn(self: *AgentState) void {
        self.interrupting = false;
        self.limited = false;
        self.started = .empty;
        self.prompts = .empty;
        self.declined = .empty;
        _ = self.turn.reset(.retain_capacity);
    }
};

const Totals = struct { in: u64 = 0, out: u64 = 0, cache_read: u64 = 0, cache_write: u64 = 0 };

/// The `--settings` JSON of the attention hooks: every hook runs `venom agent hook`.
pub fn hookSettings(a: std.mem.Allocator, venom: []const u8, agent: []const u8) ![]const u8 {
    const command = try std.fmt.allocPrint(a, "{s} agent hook --agent {s}", .{ try shellWord(a, venom), try shellWord(a, agent) });
    const Run = struct { type: []const u8 = "command", command: []const u8 };
    const Matcher = struct { matcher: []const u8, hooks: []const Run };
    const Plain = struct { hooks: []const Run };
    const run: []const Run = &.{.{ .command = command }};
    return std.json.Stringify.valueAlloc(a, .{ .hooks = .{
        .Notification = &[_]Matcher{.{ .matcher = "permission_prompt|idle_prompt", .hooks = run }},
        .Stop = &[_]Plain{.{ .hooks = run }},
        .SessionEnd = &[_]Plain{.{ .hooks = run }},
    } }, .{});
}

/// `s` as one word of a shell command.
fn shellWord(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const plain = for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "/._-+", ch) == null) break false;
    } else s.len > 0;
    if (plain) return s;
    return std.fmt.allocPrint(a, "'{s}'", .{try std.mem.replaceOwned(u8, a, s, "'", "'\\''")});
}

/// What one hook says (`attention_away`).
pub const HookReport = contract.HookReport;

const hook_reason_max = 200;

/// Reads a hook's JSON from stdin: `Notification` with `notification_type`
/// `permission_prompt` is an approval, `idle_prompt` a question; `Stop` the
/// turn's end, up for review. Hooks venom did not ask for raise nothing.
pub fn parseHook(a: std.mem.Allocator, input: []const u8) !HookReport {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}) catch return error.InvalidHook;
    if (v != .object) return error.InvalidHook;
    const event = strField(v, "hook_event_name") orelse return error.InvalidHook;
    var report: HookReport = .{ .transcript = strField(v, "transcript_path") };
    if (std.mem.eql(u8, event, "Notification")) {
        const kind = strField(v, "notification_type") orelse "";
        if (std.mem.eql(u8, kind, "permission_prompt")) {
            report.kind = .approval;
        } else if (std.mem.eql(u8, kind, "idle_prompt")) {
            report.kind = .question;
        } else return report;
        report.reason = cutReason(strField(v, "message") orelse "waiting in " ++ name);
    } else if (std.mem.eql(u8, event, "Stop")) {
        report.kind = .review;
        report.reason = "turn ended in " ++ name;
    }
    return report;
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn cutReason(text: []const u8) []const u8 {
    if (text.len <= hook_reason_max) return text;
    var end: usize = hook_reason_max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// Whether a hook's `transcript_path` is the agent's conversation: catch-up
/// reads it, and the user may have switched conversation inside the TUI.
pub fn isTranscriptOf(path: []const u8, session: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or session.len == 0) return false;
    const base = std.fs.path.basename(path);
    return std.mem.endsWith(u8, base, ".jsonl") and std.mem.eql(u8, base[0 .. base.len - ".jsonl".len], session);
}

pub const ClaudeCode = struct {
    gpa: std.mem.Allocator,
    /// The `claude` binary (looked up in `PATH`).
    exe: []const u8 = "claude",
    /// venom's MCP server for the agent; null leaves Claude
    /// Code without it. Borrowed: it must outlive the adapter.
    mcp: ?Mcp = null,
    /// Answers permission prompts; with `mcp`, the approvals path.
    replier: ?Replier = null,
    /// The configured version; else the detector's.
    harness_version: ?[]const u8 = null,
    /// `claude --version` off the reactor (`startVersionDetect`).
    detector: ?version.Detector = null,
    /// Appended to every start (e.g. `--add-dir`).
    extra_args: []const []const u8 = &.{},
    /// Claude Code's config dir (`CLAUDE_CONFIG_DIR`, else `~/.claude`),
    /// where catch-up finds session transcripts. Null: no
    /// catch-up (`catch_up = none`).
    config_dir: ?[]const u8 = null,
    /// Warnings (a torn transcript line at catch-up). Borrowed.
    logger: ?*log.Logger = null,
    /// Agent ids and states; lives as long as the adapter.
    life: std.heap.ArenaAllocator,
    agents: std.StringHashMapUnmanaged(*AgentState) = .empty,

    pub const Options = struct { exe: []const u8 = "claude", mcp: ?Mcp = null, replier: ?Replier = null, harness_version: ?[]const u8 = null, extra_args: []const []const u8 = &.{}, config_dir: ?[]const u8 = null };

    /// Copies `exe`, `extra_args` and `config_dir`, so config reloads
    /// cannot free them.
    pub fn init(gpa: std.mem.Allocator, options: Options) !ClaudeCode {
        var self: ClaudeCode = .{ .gpa = gpa, .mcp = options.mcp, .replier = options.replier, .harness_version = options.harness_version, .life = .init(gpa) };
        errdefer self.life.deinit();
        const a = self.life.allocator();
        self.exe = try a.dupe(u8, options.exe);
        const extra = try a.alloc([]const u8, options.extra_args.len);
        for (extra, options.extra_args) |*d, arg| d.* = try a.dupe(u8, arg);
        self.extra_args = extra;
        if (options.config_dir) |d| self.config_dir = try a.dupe(u8, d);
        return self;
    }

    pub fn deinit(self: *ClaudeCode) void {
        if (self.detector) |*d| d.deinit();
        var it = self.agents.valueIterator();
        while (it.next()) |s| s.*.turn.deinit();
        self.life.deinit();
    }

    pub fn adapter(self: *ClaudeCode) contract.Adapter {
        return .init(self);
    }

    /// The claude-code adapter behind `a`, if it is one.
    pub fn of(a: contract.Adapter) ?*ClaudeCode {
        const mine = contract.Adapter.init(@as(*ClaudeCode, @ptrFromInt(@alignOf(ClaudeCode))));
        return if (a.vtable == mine.vtable) @ptrCast(@alignCast(a.ptr)) else null;
    }

    fn state(self: *ClaudeCode, agent: []const u8) !*AgentState {
        if (self.agents.get(agent)) |s| return s;
        const a = self.life.allocator();
        const s = try a.create(AgentState);
        s.* = .{ .turn = .init(self.gpa) };
        try self.agents.put(a, try a.dupe(u8, agent), s);
        return s;
    }

    /// The context estimate of the agent's last model call, if any.
    pub fn contextOf(self: *ClaudeCode, agent: []const u8) ?ContextEstimate {
        const s = self.agents.get(agent) orelse return null;
        return s.context;
    }

    /// When the last usage limit resets (unix seconds), if the harness said.
    pub fn resetsAt(self: *ClaudeCode, agent: []const u8) ?i64 {
        const s = self.agents.get(agent) orelse return null;
        return s.resets_at;
    }

    // ------------------------------------------------------- operations

    /// Starts `claude --version` on its own thread, unless a version is
    /// configured. The adapter must not move afterwards.
    pub fn startVersionDetect(self: *ClaudeCode, timeout_ms: u32) void {
        if (self.harness_version != null or self.detector != null) return;
        self.detector = .{ .gpa = self.gpa, .exe = self.exe, .timeout_ms = timeout_ms };
        self.detector.?.start();
    }

    /// The harness's version as known now: configured, or detected. Never
    /// blocks (null while detecting).
    pub fn harnessVersion(self: *const ClaudeCode) ?[]const u8 {
        if (self.harness_version) |v| return v;
        return if (self.detector) |*d| d.get() else null;
    }

    /// The version, waiting for the detector (doctor only); says why
    /// there is none (not installed, or unreadable).
    pub fn waitVersion(self: *ClaudeCode) version.Detection {
        if (self.harness_version) |v| return .{ .found = v };
        return if (self.detector) |*d| d.waitResult() else .unreadable;
    }

    pub fn probe(self: *ClaudeCode, _: std.mem.Allocator) anyerror!contract.Descriptor {
        return .{
            .harness = name,
            .harness_version = self.harnessVersion(),
            .channel = "stream-json",
            .min_version = min_version,
            .tested_version = tested_version,
            .caps = self.caps(),
        };
    }

    pub fn caps(self: *ClaudeCode) contract.Caps {
        const prompts = self.mcp != null and self.replier != null;
        return .{
            .steer = .queue,
            .interrupt = true,
            .requests = if (prompts) .{ .approval = .{ .edit = true, .always = .session_rule }, .question = .{ .multi = true, .free_text = true }, .plan = true } else .{},
            .fork = .head,
            // Take-over: `resume_command` and transcript
            // catch-up, with hooks for attention while away.
            .resume_tui = true,
            .attention_away = .hooks,
            .release = true,
            .catch_up = if (self.config_dir != null) .transcript_file else .none,
            .usage = .{ .per_turn = true, .context = .estimate },
            // `/compact` as a message; `--disallowedTools mcp__<server>`.
            .compact = true,
            .mcp_off = true,
            // The `--permission-mode` choices of 2.1.319, without
            // `bypassPermissions`.
            .permission_modes = &.{ "manual", "acceptEdits", "plan", "dontAsk", "auto" },
        };
    }

    /// The SDK's documented way to compact: `/compact` as a user message. It
    /// runs as a turn and ends with its own `result`.
    pub fn compact(_: *ClaudeCode, conv: *Conversation) anyerror!void {
        try conv.writeJson(.{ .type = "user", .message = .{ .role = "user", .content = "/compact" } });
    }

    /// `--resume <id>`, or, for a fork whose conversation does not exist yet,
    /// `--resume <source> --fork-session --session-id <id>`: the one place
    /// the copy is made, for `start` and `resume_command`. When the copy is
    /// already there (an earlier take-over made it) it is
    /// resumed instead of copied again.
    fn appendResume(self: *ClaudeCode, a: std.mem.Allocator, argv: *std.ArrayList([]const u8), id: []const u8, fork_source: ?[]const u8, cwd: []const u8, transcript_ref: ?[]const u8) !void {
        if (fork_source) |source| if (!self.copyExists(a, id, cwd, transcript_ref)) {
            try argv.appendSlice(a, &.{ "--resume", source, "--fork-session", "--session-id", id });
            return;
        };
        try argv.appendSlice(a, &.{ "--resume", id });
    }

    /// Where `catch_up` would find the copy: the recorded
    /// `transcript_ref` when it names `<id>.jsonl`, else the file under
    /// `<config_dir>/projects/<encoded cwd>/`. Without a `config_dir` there is
    /// nothing to look in.
    fn copyExists(self: *ClaudeCode, a: std.mem.Allocator, id: []const u8, cwd: []const u8, transcript_ref: ?[]const u8) bool {
        const dir = self.config_dir orelse return false;
        const file = std.fmt.allocPrint(a, "{s}.jsonl", .{id}) catch return false;
        if (transcript_ref) |ref| if (std.mem.eql(u8, std.fs.path.basename(ref), file) and transcript.isTranscript(a, dir, ref)) return true;
        const direct = transcript.path(a, dir, cwd, id) catch return false;
        return transcript.isTranscript(a, dir, direct);
    }

    pub fn start(self: *ClaudeCode, a: std.mem.Allocator, params: contract.Start) anyerror!contract.Spawn {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ self.exe, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose" });
        var session: []const u8 = undefined;
        if (params.harness_session) |id| {
            session = id;
            try self.appendResume(a, &argv, id, params.fork_source, params.cwd, params.transcript_ref);
        } else {
            session = try newUuid(a);
            try argv.appendSlice(a, &.{ "--session-id", session });
        }
        if (self.mcp) |m| {
            try argv.appendSlice(a, &.{ "--mcp-config", try mcp.claudeConfig(a, m, self.replier != null) });
            if (self.replier != null) try argv.appendSlice(a, &.{ "--permission-prompt-tool", prompt_tool });
        }
        if (params.model) |m| try argv.appendSlice(a, &.{ "--model", m });
        if (params.permission_mode) |m| try argv.appendSlice(a, &.{ "--permission-mode", m });
        try appendScope(a, &argv, params);
        // A server's rule covers all its tools, and takes them out of the
        // model's context.
        for (params.mcp_off) |server| try argv.appendSlice(a, &.{ "--disallowedTools", try std.fmt.allocPrint(a, "mcp__{s}", .{server}) });
        try argv.appendSlice(a, self.extra_args);
        // A new process: its `modelUsage` totals start again.
        const s = try self.state(params.agent);
        s.totals = .empty;
        s.queued = 0;
        s.endTurn();
        var env: std.ArrayList(contract.EnvVar) = .empty;
        try env.append(a, .{ .name = "VENOM_AGENT", .value = params.agent });
        if (self.mcp) |m| if (m.socket) |path| try env.append(a, .{ .name = mcp.socket_env, .value = path });
        return .{ .argv = argv.items, .cwd = params.cwd, .env = env.items, .harness_session = session };
    }

    pub fn send(self: *ClaudeCode, conv: *Conversation, text: []const u8, mode: contract.SendMode) anyerror!void {
        const s = try self.state(conv.agent);
        const busy = conv.inTurn() or conv.sending;
        if (mode == .interrupt_then_send and conv.inTurn()) {
            s.interrupting = true;
            try conv.signal(.INT);
        }
        try conv.writeJson(.{ .type = "user", .message = .{ .role = "user", .content = text } });
        if (busy) s.queued += 1;
    }

    pub fn interrupt(self: *ClaudeCode, conv: *Conversation) anyerror!void {
        if (!conv.inTurn()) return;
        (try self.state(conv.agent)).interrupting = true;
        try conv.signal(.INT);
    }

    pub fn respond(self: *ClaudeCode, conv: *Conversation, request: contract.Pending, answer: contract.Answer) anyerror!void {
        const s = try self.state(conv.agent);
        const p = s.prompts.get(request.harness_ref) orelse return error.RequestResolved;
        const replier = self.replier orelse return error.UnsupportedCapability;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try permissionResult(a, request.kind, p, answer);
        try replier.reply(replier.ptr, conv.agent, p.tool_use_id, p.ticket, r.json);
        if (r.declined) try s.declined.put(s.turn.allocator(), p.tool_use_id, {});
        _ = s.prompts.remove(request.harness_ref);
    }

    /// A permission prompt from venom's MCP server (see the file comment):
    /// raises the request, starting its turn and tool call first if the
    /// prompt overtook the stdout lines that announce them.
    pub fn permissionPrompt(self: *ClaudeCode, conv: *Conversation, p: Prompt) !void {
        const s = try self.state(conv.agent);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const input = std.json.parseFromSliceLeaky(std.json.Value, a, p.input_json, .{}) catch return error.InvalidAnswer;
        try self.ensureTurn(conv);
        if (!isOpen(conv, p.tool_use_id)) try self.startTool(conv, s, p.tool_use_id, p.tool_name, input, null);
        const ta = s.turn.allocator();
        const kept: Prompt = .{ .tool_name = try ta.dupe(u8, p.tool_name), .input_json = try ta.dupe(u8, p.input_json), .tool_use_id = try ta.dupe(u8, p.tool_use_id), .ticket = p.ticket };
        try s.prompts.put(ta, kept.tool_use_id, kept);
        const kind = requestKind(p.tool_name);
        const reason: []const u8 = if (eql(kind, "plan"))
            str(input, "plan") orelse "Approve the plan?"
        else if (eql(kind, "question"))
            firstQuestion(input) orelse "Claude Code has a question."
        else
            try std.fmt.allocPrint(a, "{s} {s}", .{ p.tool_name, try title(a, p.tool_name, input) });
        const answers: []const []const u8 = if (eql(kind, "approval")) &approval_answers else if (eql(kind, "plan")) &plan_answers else &.{};
        try conv.request(.{ .harness_ref = kept.tool_use_id, .kind = kind, .call_ref = kept.tool_use_id, .reason = reason, .answers = answers, .input_json = kept.input_json, .options = if (eql(kind, "question")) (if (field(input, "questions")) |qs| try contract.questionOptions(a, qs, true) else &.{}) else &.{} });
    }

    pub fn decode(self: *ClaudeCode, conv: *Conversation, line: []const u8) anyerror!void {
        var arena: std.heap.ArenaAllocator = .init(conv.gpa);
        defer arena.deinit();
        // A line that is not JSON is skipped.
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return;
        const t = str(v, "type") orelse return;
        const s = try self.state(conv.agent);
        if (eql(t, "system")) {
            if (!eql(str(v, "subtype") orelse "", "init")) return;
            const session = str(v, "session_id") orelse return error.HarnessProtocol;
            const model = str(v, "model");
            if (model) |m| if (!eql(m, s.model)) {
                s.model = try self.life.allocator().dupe(u8, m);
            };
            try conv.session(session, model, str(v, "claude_code_version"));
            if (field(v, "mcp_servers")) |list| if (list == .array) {
                var servers: std.ArrayList([]const u8) = .empty;
                for (list.array.items) |item| if (str(item, "name")) |n| try servers.append(arena.allocator(), n);
                try conv.mcpServers(servers.items);
            };
            if (conv.sending and !conv.inTurn()) try self.ensureTurn(conv);
        } else if (eql(t, "assistant")) {
            try self.ensureTurn(conv);
            const parent = str(v, "parent_tool_use_id");
            const msg = field(v, "message") orelse return;
            if (parent == null) if (field(msg, "usage")) |u| {
                const used = count(u, "input_tokens") + count(u, "cache_read_input_tokens") + count(u, "cache_creation_input_tokens");
                // Read first: the result location is `s.context` itself.
                const window = if (s.context) |c| c.window else null;
                s.context = .{ .used = used, .window = window };
            };
            const content = field(msg, "content") orelse return;
            if (content != .array) return;
            for (content.array.items) |block| {
                const bt = str(block, "type") orelse continue;
                if (eql(bt, "text")) {
                    if (parent == null) try conv.text(str(block, "text") orelse "", true);
                } else if (eql(bt, "tool_use")) {
                    const id = str(block, "id") orelse continue;
                    if (isOpen(conv, id)) continue; // a prompt announced it first
                    try self.startTool(conv, s, id, str(block, "name") orelse "", field(block, "input") orelse .null, parent);
                }
                // `thinking` and unknown blocks: not logged.
            }
        } else if (eql(t, "user")) {
            const msg = field(v, "message") orelse return;
            const content = field(msg, "content") orelse return;
            if (content != .array) return;
            for (content.array.items) |block| {
                if (!eql(str(block, "type") orelse "", "tool_result")) continue;
                const id = str(block, "tool_use_id") orelse continue;
                if (!conv.inTurn() or !isOpen(conv, id)) continue;
                // The harness settled a prompt venom did not answer.
                if (s.prompts.remove(id)) try conv.requestResolved(id, "harness");
                const status: []const u8 = if (s.declined.contains(id)) "declined" else if (boolean(block, "is_error")) "error" else "ok";
                const t0 = s.started.get(id);
                const ms: ?u64 = if (t0) |x| @intCast(@max(0, supervisor.monotonicMs() - x)) else null;
                try conv.toolEnd(id, .{ .status = status, .exit = exitCode(field(v, "tool_use_result")), .duration_ms = ms, .body = try editDiff(arena.allocator(), field(v, "tool_use_result")) orelse try resultText(arena.allocator(), block) });
            }
        } else if (eql(t, "rate_limit_event")) {
            const info = field(v, "rate_limit_info") orelse return;
            if (eql(str(info, "status") orelse "", "rejected")) {
                s.limited = true;
                if (int(info, "resetsAt")) |r| s.resets_at = r;
            }
        } else if (eql(t, "result")) {
            try self.ensureTurn(conv);
            try self.reportUsage(conv, s, v);
            try reportContext(conv, s);
            const reason, const code = endReason(s, v);
            const resets: ?[]const u8 = if (eql(reason, "limit")) (if (s.resets_at) |r| try contract.rfc3339(arena.allocator(), r) else null) else null;
            try conv.turnEnd(.{ .reason = reason, .error_code = code, .resets_at = resets });
            // A turn that ran means the limit is over.
            if (eql(reason, "completed")) s.resets_at = null;
            s.endTurn();
            if (s.queued > 0) {
                s.queued -= 1;
                conv.sending = true;
            }
        }
        // Unknown types (`stream_event`, hook events, …) are ignored.
    }

    pub fn fork(_: *ClaudeCode, a: std.mem.Allocator, conv: *Conversation, _: ?[]const u8) anyerror!contract.ForkStep {
        if (conv.inTurn()) return error.TurnRunning;
        if (conv.harness_session == null) return error.HarnessSessionNotFound;
        // `head`: the new conversation's id is chosen now. Its first start
        // runs `--resume <source> --fork-session --session-id <id>`, the source
        // coming from the log through `Start.fork_source`.
        return .{ .done = try newUuid(a) };
    }

    pub fn release(_: *ClaudeCode, conv: *Conversation) anyerror!void {
        if (conv.inTurn()) return error.TurnRunning;
        conv.closeInput(); // print mode exits after its last turn at end of input
    }

    /// Take-over: `claude --resume <id> --settings <hooks>` in the agent's
    /// folder. The interactive TUI uses the user's own settings, plus venom's
    /// attention hooks (`venom agent hook`); `CLAUDE_CONFIG_DIR` is
    /// set when venom's differs from the default, so the TUI writes the
    /// transcript catch-up reads. `VENOM_AGENT` names the agent; the env
    /// never carries a `VENOM_TOKEN`: the hooks are
    /// whoever the ancestry walk says. The hooks go in only when the split
    /// can be reported (`hooks`); otherwise each would end in a refusal,
    /// which Claude Code shows as a hook error.
    pub fn resume_command(self: *ClaudeCode, a: std.mem.Allocator, record: contract.Resume) anyerror!contract.Spawn {
        // A fork that has not started has no conversation yet: this command
        // makes it, as `start` would. Take-back could not see the
        // copy without `catch_up`, and the copy would not stop at `fork_at`.
        if (record.fork_source != null and (self.config_dir == null or record.fork_at != null)) return error.UnsupportedCapability;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, self.exe);
        try self.appendResume(a, &argv, record.harness_session, record.fork_source, record.cwd, record.transcript_ref);
        var env: std.ArrayList(contract.EnvVar) = .empty;
        if (self.config_dir) |d| try env.append(a, .{ .name = "CLAUDE_CONFIG_DIR", .value = d });
        if (record.agent.len > 0) try env.append(a, .{ .name = "VENOM_AGENT", .value = record.agent });
        if (record.hooks) {
            const venom = if (self.mcp) |m| m.command else "venom";
            try argv.appendSlice(a, &.{ "--settings", try hookSettings(a, venom, record.agent) });
            if (self.mcp) |m| if (m.socket) |path| try env.append(a, .{ .name = mcp.socket_env, .value = path });
        }
        return .{ .argv = argv.items, .cwd = record.cwd, .env = env.items, .harness_session = record.harness_session };
    }

    /// `catch_up = transcript_file` (`claude_transcript.zig`).
    pub fn catch_up(self: *ClaudeCode, conv: *Conversation, record: contract.Resume) anyerror!u32 {
        const dir = self.config_dir orelse return error.UnsupportedCapability;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // What a hook named, if it holds up; else where venom expects it.
        var file: []const u8 = record.transcript_ref orelse "";
        const bytes = reported: {
            if (record.transcript_ref) |ref| {
                if (transcript.read(a, dir, ref)) |b| break :reported b else |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => if (self.logger) |l| l.warn("refused the transcript a hook named", .{ .agent = conv.agent, .transcript = ref }),
                }
            }
            // A fork that has not started has no conversation until a take-over
            // makes it: none found is not a failure.
            file = (try transcript.find(a, dir, record.cwd, record.harness_session)) orelse
                return if (record.fork_source != null) error.NoConversation else error.HarnessCatchUp;
            break :reported try transcript.read(a, dir, file);
        };
        const r = try transcript.replay(conv, bytes, record.since_ms, record.harness_last_turn);
        if (r.torn_tail) if (self.logger) |l| l.warn("the transcript's last line is not JSON yet; skipped it", .{ .agent = conv.agent, .transcript = file });
        return r.turns;
    }

    // -------------------------------------------------------- internals

    fn ensureTurn(_: *ClaudeCode, conv: *Conversation) !void {
        if (conv.inTurn()) return;
        try conv.turnStarted(null, if (conv.sending) "user" else "harness");
    }

    fn startTool(_: *ClaudeCode, conv: *Conversation, s: *AgentState, id: []const u8, tool: []const u8, input: std.json.Value, parent: ?[]const u8) !void {
        const ta = s.turn.allocator();
        try s.started.put(ta, try ta.dupe(u8, id), supervisor.monotonicMs());
        try conv.toolStarted(.{ .harness_ref = id, .kind = kindOf(tool), .name = tool, .title = try title(ta, tool, input), .status = "pending", .parent_ref = parent, .args = argsOf(tool, input, conv.cwd), .raw_input = try contract.rawJson(ta, input) });
    }

    /// Per-turn values from the cumulative `modelUsage`, one
    /// `usage` per model; `usage` (no model split) when it is missing.
    fn reportUsage(self: *ClaudeCode, conv: *Conversation, s: *AgentState, v: std.json.Value) !void {
        if (field(v, "modelUsage")) |mu| if (mu == .object and mu.object.count() > 0) {
            if (contextWindow(mu, s.model)) |w| {
                const used = if (s.context) |c| c.used else 0;
                s.context = .{ .used = used, .window = w };
            }
            var it = mu.object.iterator();
            while (it.next()) |e| {
                const m = e.value_ptr.*;
                const now: Totals = .{ .in = count(m, "inputTokens"), .out = count(m, "outputTokens"), .cache_read = count(m, "cacheReadInputTokens"), .cache_write = count(m, "cacheCreationInputTokens") };
                const l = self.life.allocator();
                const gop = try s.totals.getOrPut(l, e.key_ptr.*);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try l.dupe(u8, e.key_ptr.*);
                    gop.value_ptr.* = .{};
                }
                const prev = gop.value_ptr.*;
                gop.value_ptr.* = now;
                // Totals that went down mean a new count: take them whole.
                const d: Totals = if (now.in < prev.in or now.out < prev.out or now.cache_read < prev.cache_read or now.cache_write < prev.cache_write)
                    now
                else
                    .{ .in = now.in - prev.in, .out = now.out - prev.out, .cache_read = now.cache_read - prev.cache_read, .cache_write = now.cache_write - prev.cache_write };
                if (d.in == 0 and d.out == 0 and d.cache_read == 0 and d.cache_write == 0) continue;
                try conv.usage(.{ .model = e.key_ptr.*, .tokens_in = d.in, .tokens_out = d.out, .cache_read = d.cache_read, .cache_write = d.cache_write, .includes_subagents = true });
            }
            return;
        };
        const u = field(v, "usage") orelse return;
        try conv.usage(.{ .model = s.model, .tokens_in = count(u, "input_tokens"), .tokens_out = count(u, "output_tokens"), .cache_read = count(u, "cache_read_input_tokens"), .cache_write = count(u, "cache_creation_input_tokens"), .includes_subagents = true });
    }
};

/// The main model's `contextWindow` from `modelUsage`: the entry whose
/// model is `main` (the `system/init` model; a `[1m]`-style suffix and a
/// prefix match count), else the entry with the most tokens that has one
/// (a sub-agent's smaller model rarely wins that).
fn contextWindow(mu: std.json.Value, main: []const u8) ?u64 {
    var best: ?u64 = null;
    var best_tokens: u64 = 0;
    var it = mu.object.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr.*;
        const w = int(m, "contextWindow") orelse continue;
        if (w <= 0) continue;
        if (main.len > 0 and sameModel(e.key_ptr.*, main)) return @intCast(w);
        const tokens = count(m, "inputTokens") + count(m, "outputTokens") + count(m, "cacheReadInputTokens") + count(m, "cacheCreationInputTokens");
        if (best == null or tokens > best_tokens) {
            best = @intCast(w);
            best_tokens = tokens;
        }
    }
    return best;
}

/// `claude-opus-4-7[1m]` is `claude-opus-4-7`; a dated id
/// (`claude-haiku-4-5-20251001`) matches its alias by prefix.
fn sameModel(a: []const u8, b: []const u8) bool {
    const x = baseModel(a);
    const y = baseModel(b);
    return std.mem.startsWith(u8, x, y) or std.mem.startsWith(u8, y, x);
}

fn baseModel(m: []const u8) []const u8 {
    return m[0 .. std.mem.indexOfScalar(u8, m, '[') orelse m.len];
}

/// Logs the context estimate when it is complete and changed.
fn reportContext(conv: *Conversation, s: *AgentState) !void {
    const ctx = s.context orelse return;
    const window = ctx.window orelse return;
    if (ctx.used == 0 or window == 0) return;
    if (s.context_logged) |l| if (l.used == ctx.used and l.window == ctx.window) return;
    s.context_logged = ctx;
    try conv.context(ctx.used, window, "estimate");
}

fn endReason(s: *const AgentState, v: std.json.Value) struct { []const u8, ?[]const u8 } {
    const subtype = str(v, "subtype") orelse "";
    const failed = boolean(v, "is_error") or !eql(subtype, "success");
    if (s.interrupting) return .{ "interrupted", null };
    if (s.limited or int(v, "api_error_status") == 429) return .{ "limit", "failed.usage_limit" };
    if (!failed) return .{ "completed", null };
    if (str(v, "result")) |text| if (containsIgnoreCase(text, "usage limit") or containsIgnoreCase(text, "rate limit")) return .{ "limit", "failed.usage_limit" };
    return .{ "failed", "failed.harness_turn" };
}

const PermissionResult = struct { json: []const u8, declined: bool = false };

/// `respond`: venom's answer as Claude Code's permission
/// result (the permission prompt tool's result text).
fn permissionResult(a: std.mem.Allocator, kind: []const u8, p: Prompt, answer: contract.Answer) !PermissionResult {
    const input = std.json.parseFromSliceLeaky(std.json.Value, a, p.input_json, .{}) catch return error.HarnessProtocol;
    const ans = answer.answer;
    if (eql(kind, "question")) {
        return .{ .json = try std.fmt.allocPrint(a, "{{\"behavior\":\"allow\",\"updatedInput\":{f}}}", .{std.json.fmt(try questionInput(a, input, answer), .{})}) };
    }
    if (eql(kind, "plan")) {
        if (eql(ans, "approve")) return .{ .json = try allow(a, input, null) };
        if (eql(ans, "reject")) return .{ .json = try deny(a, answer.reason orelse "The user rejected the plan in venom.", false) };
        return error.InvalidAnswer;
    }
    if (eql(ans, "allow_once")) return .{ .json = try allow(a, input, null) };
    if (eql(ans, "allow_edited")) {
        const edited = std.json.parseFromSliceLeaky(std.json.Value, a, answer.args_json orelse return error.InvalidAnswer, .{}) catch return error.InvalidAnswer;
        if (edited != .object) return error.InvalidAnswer;
        return .{ .json = try allow(a, edited, null) };
    }
    if (eql(ans, "allow_always")) return .{ .json = try allow(a, input, try sessionRule(a, p.tool_name, input)) };
    if (eql(ans, "deny")) return .{ .json = try deny(a, answer.reason orelse "The user denied this in venom.", false), .declined = true };
    if (eql(ans, "cancel_turn")) return .{ .json = try deny(a, answer.reason orelse "The user cancelled the turn in venom.", true), .declined = true };
    return error.InvalidAnswer;
}

fn allow(a: std.mem.Allocator, input: std.json.Value, rule: ?[]const u8) ![]const u8 {
    if (rule) |r| return std.fmt.allocPrint(a, "{{\"behavior\":\"allow\",\"updatedInput\":{f},\"updatedPermissions\":[{s}]}}", .{ std.json.fmt(input, .{}), r });
    return std.fmt.allocPrint(a, "{{\"behavior\":\"allow\",\"updatedInput\":{f}}}", .{std.json.fmt(input, .{})});
}

fn deny(a: std.mem.Allocator, message: []const u8, stop: bool) ![]const u8 {
    if (stop) return std.fmt.allocPrint(a, "{{\"behavior\":\"deny\",\"message\":{f},\"interrupt\":true}}", .{std.json.fmt(message, .{})});
    return std.fmt.allocPrint(a, "{{\"behavior\":\"deny\",\"message\":{f}}}", .{std.json.fmt(message, .{})});
}

/// "Allow always" on the harness side: a session-scoped rule, the narrowest
/// that matches this call (never the user's settings
/// files).
fn sessionRule(a: std.mem.Allocator, tool: []const u8, input: std.json.Value) ![]const u8 {
    const content: ?[]const u8 = if (eql(tool, "Bash")) str(input, "command") else str(input, "file_path") orelse str(input, "notebook_path");
    const rule = if (content) |c|
        try std.fmt.allocPrint(a, "{{\"toolName\":{f},\"ruleContent\":{f}}}", .{ std.json.fmt(tool, .{}), std.json.fmt(c, .{}) })
    else
        try std.fmt.allocPrint(a, "{{\"toolName\":{f}}}", .{std.json.fmt(tool, .{})});
    return std.fmt.allocPrint(a, "{{\"type\":\"addRules\",\"rules\":[{s}],\"behavior\":\"allow\",\"destination\":\"session\"}}", .{rule});
}

/// `AskUserQuestion` answers: `{questions, answers}` with answers keyed by
/// question text. `args_json` may carry `{"q1":["label"]}`
/// keyed by the derived ids `q1`, `q2`, …; otherwise `answer` is the
/// free-text reply to every question.
fn questionInput(a: std.mem.Allocator, input: std.json.Value, answer: contract.Answer) !std.json.Value {
    const questions = field(input, "questions") orelse return error.InvalidAnswer;
    if (questions != .array) return error.InvalidAnswer;
    const picked: ?std.json.Value = if (answer.args_json) |j| std.json.parseFromSliceLeaky(std.json.Value, a, j, .{}) catch return error.InvalidAnswer else null;
    var answers: std.json.ObjectMap = .empty;
    for (questions.array.items, 1..) |q, i| {
        const text = str(q, "question") orelse continue;
        const qid = try std.fmt.allocPrint(a, "q{d}", .{i});
        const value: []const u8 = if (picked) |pv| blk: {
            const sel = field(pv, qid) orelse continue;
            if (sel == .string) break :blk sel.string;
            if (sel != .array) return error.InvalidAnswer;
            var joined: std.ArrayList(u8) = .empty;
            for (sel.array.items, 0..) |item, n| {
                if (item != .string) return error.InvalidAnswer;
                if (n > 0) try joined.appendSlice(a, ", ");
                try joined.appendSlice(a, item.string);
            }
            break :blk joined.items;
        } else answer.answer;
        try answers.put(a, text, .{ .string = value });
    }
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "questions", questions);
    try out.put(a, "answers", .{ .object = answers });
    return .{ .object = out };
}

fn requestKind(tool: []const u8) []const u8 {
    if (eql(tool, "AskUserQuestion")) return "question";
    if (eql(tool, "ExitPlanMode")) return "plan";
    return "approval";
}

/// Claude Code's tool kinds.
pub fn kindOf(tool: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "Bash", "exec" },      .{ "Edit", "edit" },                .{ "MultiEdit", "edit" },
        .{ "Write", "edit" },     .{ "NotebookEdit", "edit" },        .{ "Read", "read" },
        .{ "Grep", "search" },    .{ "Glob", "list" },                .{ "LS", "list" },
        .{ "WebFetch", "fetch" }, .{ "WebSearch", "fetch" },          .{ "Agent", "agent" },
        .{ "Task", "agent" },     .{ "AskUserQuestion", "question" }, .{ "ExitPlanMode", "plan" },
    };
    for (map) |m| if (eql(m[0], tool)) return m[1];
    if (std.mem.startsWith(u8, tool, "mcp__")) return "mcp";
    return "other";
}

/// One line for the call's row. A multi-line value keeps its
/// first line followed by ` …`, so "allow always" knows the command was cut
/// short and keeps no grant for it (`eventlog/always.zig`).
pub fn title(a: std.mem.Allocator, tool: []const u8, input: std.json.Value) ![]const u8 {
    const keys: []const []const u8 = switch (std.meta.stringToEnum(enum { Bash, Edit, MultiEdit, Write, Read, NotebookEdit, Grep, Glob, LS, WebFetch, WebSearch, Agent, Task }, tool) orelse return "") {
        .Bash => &.{"command"},
        .Edit, .MultiEdit, .Write, .Read => &.{"file_path"},
        .NotebookEdit => &.{"notebook_path"},
        .Grep, .Glob => &.{"pattern"},
        .LS => &.{"path"},
        .WebFetch => &.{"url"},
        .WebSearch => &.{"query"},
        .Agent, .Task => &.{"description"},
    };
    for (keys) |k| if (str(input, k)) |s| {
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
        return try std.fmt.allocPrint(a, "{s} \u{2026}", .{std.mem.trimEnd(u8, s[0..nl], " \t\r")});
    };
    return "";
}

/// The tool `args` for the call (see the file comment). Strings point
/// into `input`.
pub fn argsOf(tool: []const u8, input: std.json.Value, cwd: []const u8) ?contract.ToolArgs {
    const kind = kindOf(tool);
    if (eql(kind, "question") or eql(kind, "plan")) return null;
    if (eql(kind, "mcp")) {
        const rest = tool["mcp__".len..];
        const sep = std.mem.indexOf(u8, rest, "__") orelse return .{ .server = rest };
        return .{ .server = rest[0..sep], .tool = rest[sep + 2 ..] };
    }
    const T = enum { Bash, Edit, MultiEdit, Write, NotebookEdit, Read, Grep, Glob, LS, WebFetch, WebSearch };
    return switch (std.meta.stringToEnum(T, tool) orelse return .{}) {
        .Bash => .{ .command = str(input, "command") orelse "", .cwd = cwd },
        .Edit => .{ .path = str(input, "file_path"), .change = "modify", .added = lines(str(input, "new_string")), .removed = lines(str(input, "old_string")) },
        .MultiEdit => blk: {
            var added: u64 = 0;
            var removed: u64 = 0;
            if (field(input, "edits")) |edits| if (edits == .array) for (edits.array.items) |e| {
                added += lines(str(e, "new_string"));
                removed += lines(str(e, "old_string"));
            };
            break :blk .{ .path = str(input, "file_path"), .change = "modify", .added = added, .removed = removed };
        },
        .Write => .{ .path = str(input, "file_path"), .change = "create", .added = lines(str(input, "content")) },
        .NotebookEdit => .{ .path = str(input, "notebook_path"), .change = if (eql(str(input, "edit_mode") orelse "", "delete")) "delete" else "modify" },
        .Read, .LS => .{ .path = str(input, "file_path") orelse str(input, "path") },
        .Glob => .{ .path = str(input, "path") orelse str(input, "pattern") },
        .Grep => .{ .query = str(input, "pattern"), .path = str(input, "path") },
        .WebFetch => .{ .url = str(input, "url") },
        .WebSearch => .{ .query = str(input, "query") },
    };
}

/// Lines of `text` (a last line without a newline counts).
fn lines(text: ?[]const u8) u64 {
    const t = text orelse return 0;
    if (t.len == 0) return 0;
    return std.mem.count(u8, t, "\n") + @intFromBool(t[t.len - 1] != '\n');
}

/// A `tool_result`'s text: its string `content`, or its `text` blocks
/// joined by newlines (images and other blocks are left out).
/// The diff of an edit: `content` of an Edit's result is only prose ("The
/// file … has been updated"). `structuredPatch` holds the hunks; a created
/// file has none, and its `content` is all added lines.
fn editDiff(a: std.mem.Allocator, result: ?std.json.Value) !?[]const u8 {
    const r = result orelse return null;
    var out: std.ArrayList(u8) = .empty;
    if (field(r, "structuredPatch")) |patch| if (patch == .array) for (patch.array.items) |hunk| {
        try out.print(a, "@@ -{d},{d} +{d},{d} @@\n", .{ int(hunk, "oldStart") orelse 0, int(hunk, "oldLines") orelse 0, int(hunk, "newStart") orelse 0, int(hunk, "newLines") orelse 0 });
        const hunk_lines = field(hunk, "lines") orelse continue;
        if (hunk_lines != .array) continue;
        for (hunk_lines.array.items) |l| if (l == .string) {
            try out.appendSlice(a, l.string);
            try out.append(a, '\n');
        };
    };
    if (out.items.len > 0) return out.items;
    if (!eql(str(r, "type") orelse "", "create")) return null;
    const content = str(r, "content") orelse return null;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
    while (it.next()) |l| try out.print(a, "+{s}\n", .{l});
    return out.items;
}

fn resultText(a: std.mem.Allocator, block: std.json.Value) !?[]const u8 {
    const content = field(block, "content") orelse return null;
    switch (content) {
        .string => |text| return text,
        .array => |items| {
            var out: std.ArrayList(u8) = .empty;
            var any = false;
            for (items.items) |b| {
                if (!eql(str(b, "type") orelse "", "text")) continue;
                if (any) try out.append(a, '\n');
                try out.appendSlice(a, str(b, "text") orelse "");
                any = true;
            }
            return if (any) out.items else null;
        },
        else => return null,
    }
}

fn firstQuestion(input: std.json.Value) ?[]const u8 {
    const qs = field(input, "questions") orelse return null;
    if (qs != .array or qs.array.items.len == 0) return null;
    return str(qs.array.items[0], "question");
}

/// `exit` only when the structured tool result carries one.
fn exitCode(result: ?std.json.Value) ?i64 {
    const r = result orelse return null;
    return int(r, "exitCode") orelse int(r, "exit_code");
}

fn isOpen(conv: *const Conversation, harness_ref: []const u8) bool {
    for (conv.open_calls.items) |c| if (eql(c.harness_ref, harness_ref)) return true;
    return false;
}

/// The scope flags (see the file comment): `--add-dir` for writable roots
/// outside the cwd, and `ask` rules for the read-only repos' edits and for
/// the commands that name them.
fn appendScope(a: std.mem.Allocator, argv: *std.ArrayList([]const u8), params: contract.Start) !void {
    for (params.writable) |w| if (!within(params.cwd, w)) try argv.appendSlice(a, &.{ "--add-dir", w });
    if (params.read_only.len == 0) return;
    var rules: std.ArrayList([]const u8) = .empty;
    // `//` starts an absolute path in a permission rule.
    for (params.read_only) |r| try rules.append(a, try std.fmt.allocPrint(a, "Edit(/{s}/**)", .{r}));
    for (params.read_only) |r| {
        // Relative to the cwd where it can be: that spelling is also the
        // tail of the absolute one, so one pattern covers both. The repo at
        // the cwd itself has no name to look for.
        const repo = if (within(params.cwd, r)) (if (r.len == params.cwd.len) continue else if (eql(params.cwd, "/")) r[1..] else r[params.cwd.len + 1 ..]) else r;
        for (writer_programs ++ [_][]const u8{"cd"}) |prog| {
            try rules.append(a, try std.fmt.allocPrint(a, "Bash({s} *{s}/*)", .{ prog, repo }));
            try rules.append(a, try std.fmt.allocPrint(a, "Bash({s} *{s})", .{ prog, repo }));
            try rules.append(a, try std.fmt.allocPrint(a, "Bash({s} *{s} *)", .{ prog, repo }));
        }
    }
    try argv.appendSlice(a, &.{ "--settings", try std.json.Stringify.valueAlloc(a, .{ .permissions = .{ .ask = rules.items } }, .{}) });
}

fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or eql(root, "/") or path[root.len] == '/';
}

/// A random (version 4) UUID, as `--session-id` wants.
pub fn newUuid(a: std.mem.Allocator) ![]const u8 {
    var b: [16]u8 = undefined;
    if (builtin.os.tag == .linux) {
        var got: usize = 0;
        while (got < b.len) {
            const n = std.os.linux.getrandom(b[got..].ptr, b.len - got, 0);
            if (@as(isize, @bitCast(n)) <= 0) return error.EntropyUnavailable;
            got += n;
        }
    } else std.c.arc4random_buf(&b, b.len);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}
fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .null) null else x;
}
fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return if (x == .string) x.string else null;
}
fn int(v: std.json.Value, key: []const u8) ?i64 {
    const x = field(v, key) orelse return null;
    return if (x == .integer) x.integer else null;
}
fn boolean(v: std.json.Value, key: []const u8) bool {
    const x = field(v, key) orelse return false;
    return x == .bool and x.bool;
}
fn count(v: std.json.Value, key: []const u8) u64 {
    return @intCast(@max(0, int(v, key) orelse 0));
}

comptime {
    @import("iface").assertImplements(contract.Adapter.VTable, ClaudeCode);
}
