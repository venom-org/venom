//! The Codex adapter: drives `codex app-server`, JSON-RPC 2.0
//! over stdio with one object per line and no `"jsonrpc"` member, as mapped
//! here.
//!
//! One `codex app-server` process per agent, run in the agent's cwd. The
//! adapter is the JSON-RPC client:
//!
//! 1. `start` returns the argv and, as the handshake `Spawn.input`, the
//!    `initialize` request, so a restart (which sends nothing else) still
//!    reaches `session`.
//! 2. On its response: the `initialized` notification, then `thread/start`
//!    (`cwd`, `approvalPolicy`, `sandbox`, `model?`) or, with a stored
//!    `harness_session`, `thread/resume {threadId}`. Its response gives the
//!    thread id, which is the `harness_session`, and the model: `session`.
//! 3. Sends are queued until then, and while a turn runs (`turn` mode):
//!    each becomes `turn/start` once the conversation is between turns.
//!    `steer` mode is `turn/steer {expectedTurnId}`, falling back to
//!    `turn/start` when the turn has just ended (`steer = "inject"`).
//!
//! Notifications become normalized events: `turn/started`, `turn/completed`
//! (`failed` with `usageLimitExceeded`/`rateLimitExceeded` is `limit` with
//! `failed.usage_limit`, so the agent shows `failed` with `limit`
//! attention), `item/started`/`item/completed` (tool calls, agent messages),
//! deltas, `thread/tokenUsage/updated` (per-turn deltas of `total`),
//! `serverRequest/resolved`. Server requests
//! `item/commandExecution/requestApproval` and
//! `item/fileChange/requestApproval` become approvals; `respond` answers
//! them with the JSON-RPC id the harness used. Any other server request gets
//! a JSON-RPC error, so the harness never waits on venom for something it
//! cannot show. "Allow always" is venom's grant alone: codex gets
//! `accept`, never `acceptForSession` or an execpolicy amendment, whose prefix
//! rule would pass later commands without venom seeing them. Rules already in
//! the user's codex config are outside venom's control. Notifications for other
//! threads (native sub-agents) are ignored here.
//!
//! Scope. The app-server runs at the
//! workspace root, and Codex's `workspace-write` sandbox always makes the cwd
//! writable, so it cannot keep some repos under the cwd read-only. When the
//! scope leaves repos read-only the thread gets a permission profile instead
//! (`config` of `thread/start` and `thread/resume`, in place of `sandbox`):
//! `default_permissions: "venom_scope"`, the filesystem readable, the
//! writable roots and temp folders writable, the read-only repos read. The
//! sandbox holds it for commands and patches alike, so in-scope writes run
//! unasked as they do for a whole-workspace agent, and a patch outside asks.
//! Checked against 0.167.0, where profiles are beta: a codex that does not
//! report the profile as active (`activePermissionProfile`) would run with
//! whatever its own config says, so that thread fails to open
//! (`unsupported.harness_version`), rather than run unscoped.
//!
//! A `fileChange` item can touch several paths and `tool.title` is the first
//! one only, so the adapter judges all of them (and `move_path`, and the
//! request's `grantRoot`) and marks the approval `outside_scope`.
//! An approved command leaves the sandbox: venom judges its text (`command_writes.zig`),
//! and what a program then writes by itself is not visible.
//!
//! Permission mode (`permission_modes`): the only
//! one listed is `plan`, the same `sandbox: "read-only"` with
//! `approvalPolicy: "on-request"`: nothing is written unless a person allows
//! that write. Without it a thread may edit and run commands in the workspace
//! unasked, which is wider than `ask` or `accept_edits`, so a sub-agent of
//! another harness's agent runs here in `plan`.
//!
//! Tool `args` and `body`:
//! `commandExecution` → exec `{command, cwd}` (the item's `cwd`, else the
//! agent's), or read `{path}` / search `{query, path?}` / list `{path}` from
//! its first `commandActions` entry; body `aggregatedOutput`.
//! `fileChange` → edit `{path, change, added, removed}`: the first change's
//! path and kind (`add` → create, `delete` → delete, else modify), `+`/`-`
//! lines counted over every change's `diff`; body the diffs. `mcpToolCall`
//! → `{server, tool}`; `webSearch` → `{query}`; `collabAgentToolCall` →
//! `{child_ref?}` (`receiverThreadId`, `newThreadId`, or the first
//! `receiverThreadIds`); `dynamicToolCall` → `{}`. Bodies are capped at
//! `harness.body_max` by the conversation.
//!
//! `context` (`estimate`): the last call's `inputTokens` from
//! `thread/tokenUsage/updated`, over its `modelContextWindow`, logged at
//! turn end when it changed. A `limit` turn end carries `resets_at`:
//! the reset time of the most used window in the last
//! `account/rateLimits/updated` (sparse updates merge per window).
//! `plan_windows` (`stable`): after `session`, every
//! process sends `account/read` and `account/rateLimits/read`; both may fail
//! (an API key has no windows) and no turn waits on them. They feed the
//! adapter's one `Plan`, since windows are the account's, not an agent's: a
//! read replaces the windows, `account/rateLimits/updated` merges per window,
//! and a snapshot of another `limitId` than `codex` is ignored. It is logged
//! once both reads answered, also with no windows (so an API key's `billing`
//! is known), and then when it changed, so agents sharing an account do not
//! log it N times. `billing` comes from `account.type` (`chatgpt` →
//! subscription, `apiKey` → api_key, else unknown); the email is never read.
//!
//! Usage after `thread/resume`: a report that is not of a turn
//! this process runs is a replay of the thread's totals, and only re-bases
//! them. Whether and when 0.167.0 replays could not be checked without a real
//! resumed thread (its binary names a `token_usage_replay.rs`), so either
//! order counts the same: a first report inside the first turn re-bases on
//! `total - last`.
//!
//! `fork` (`at_turn`): `thread/fork {threadId, lastTurnId?,
//! excludeTurns}`, which must run in a live app-server (the host starts one
//! for an idle agent; it re-opens the thread first). The answer comes through
//! `decode`, so `fork` never waits: it returns `.pending` until the answer or
//! `fork_timeout_ms` (`timeout.harness_request`); a refusal is
//! `conflict.harness_fork_refused`. Neither changes the agent. A message sent
//! while the thread is still opening is the next turn, so the fork gives way
//! (`conflict.turn_running`). The new thread is then `thread/unsubscribe`d
//! here, also when its answer came too late: its agent opens it in a process
//! of its own with `thread/resume`, which is when its `session` is logged.
//! `thread/resume` also asks for `excludeTurns`: venom does not read the
//! history, and a long one could pass `process.line_max`, which ends the
//! process.
//!
//! `harness_version`: `codex --version`, run once on a thread of its own
//! after `startVersionDetect` (the daemon calls it; `probe` never waits and
//! reports null until it is known); each process's own version comes from
//! `initialize`'s `userAgent`.
//!
//! Take-over:
//! `resume_command` is `codex resume <thread>` in the agent's folder, which
//! runs outside venom's mode and scope, like Claude Code's. `catch_up` reads the
//! thread's record (`codex_record.zig`). `attention_away` is `turn_end`: when the
//! split can report, `-c notify=…` runs `venom agent hook` at each turn's end.
//! That override replaces a `notify` in the user's own config for that run: the
//! setting holds one program. It reports turn ends only, so approvals while
//! away are not seen.
//!
//! Not in this adapter yet (declared in the descriptor accordingly): native
//! sub-agents (`collabAgentToolCall` is shown as an `agent` call).
const std = @import("std");
const supervisor = @import("supervisor");
const contract = @import("contract.zig");
const mcp = @import("mcp.zig");
const version = @import("version.zig");
const record_ = @import("codex_record.zig");
const log = @import("log");
const agent_scope = @import("../eventlog/agent_scope.zig");
const Conversation = contract.Conversation;
const Value = std.json.Value;

pub const name = "codex";
/// The mapping was verified against this version.
pub const tested_version = "0.167.0";
/// The oldest version verified to report `activePermissionProfile`.
pub const min_version = "0.167.0";

pub const Codex = struct {
    gpa: std.mem.Allocator,
    /// The command; `codex app-server` unless a test replaces it.
    argv: []const []const u8 = &.{ "codex", "app-server" },
    env: []const contract.EnvVar = &.{},
    /// venom's MCP server for the agent: `-c mcp_servers.venom.*`
    /// overrides appended to `argv`, so the user's `config.toml` is never
    /// touched. Borrowed: it must outlive the adapter.
    mcp: ?mcp.Server = null,
    /// `thread/start` `approvalPolicy` and `sandbox`.
    approval_policy: []const u8 = "on-request",
    sandbox: []const u8 = "workspace-write",
    client_version: []const u8 = "0.1.0",
    /// `<argv[0]> --version` off the reactor (`startVersionDetect`; the
    /// daemon calls it, tests whose argv[0] is a fake do not).
    detector: ?version.Detector = null,
    /// How long `fork` waits for the app-server, reattach included.
    fork_timeout_ms: u32 = 30_000,
    /// The account's plan windows, across agents and processes.
    plan: Plan = .{},
    /// Warnings (a rollout catch-up cannot read). Borrowed.
    logger: ?*log.Logger = null,
    /// Per-agent protocol state, keyed by agent id.
    states: std.StringArrayHashMapUnmanaged(*State) = .empty,
    /// Owns `argv` when built by `initCommand`.
    owned: ?std.heap.ArenaAllocator = null,

    /// `argv` is borrowed; tests point it at a fake app-server.
    pub fn init(gpa: std.mem.Allocator) Codex {
        return .{ .gpa = gpa };
    }

    /// `<exe> app-server <extra_args…>` (`harness.codex.path`,
    /// `extra_args`), copied so config reloads cannot free them.
    pub fn initCommand(gpa: std.mem.Allocator, exe: []const u8, extra_args: []const []const u8) !Codex {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const argv = try a.alloc([]const u8, 2 + extra_args.len);
        argv[0] = try a.dupe(u8, exe);
        argv[1] = "app-server";
        for (argv[2..], extra_args) |*d, arg| d.* = try a.dupe(u8, arg);
        return .{ .gpa = gpa, .argv = argv, .owned = arena };
    }

    pub fn deinit(self: *Codex) void {
        // The detector's thread reads `argv`: join it first.
        if (self.detector) |*d| d.deinit();
        if (self.owned) |*o| o.deinit();
        if (self.plan.logged) |l| self.gpa.free(l);
        for (self.states.values()) |s| {
            s.deinit(self.gpa);
            self.gpa.destroy(s);
        }
        for (self.states.keys()) |k| self.gpa.free(k);
        self.states.deinit(self.gpa);
    }

    pub fn adapter(self: *Codex) contract.Adapter {
        return .init(self);
    }

    /// Starts `<argv[0]> --version` on its own thread. `argv` and the
    /// adapter must not move or be freed afterwards.
    pub fn startVersionDetect(self: *Codex, timeout_ms: u32) void {
        if (self.detector != null or self.argv.len == 0) return;
        self.detector = .{ .gpa = self.gpa, .exe = self.argv[0], .timeout_ms = timeout_ms };
        self.detector.?.start();
    }

    /// The detected version so far; never blocks (null while detecting).
    pub fn harnessVersion(self: *const Codex) ?[]const u8 {
        return if (self.detector) |*d| d.get() else null;
    }

    /// The version, waiting for the detector (doctor only); says why
    /// there is none (not installed, or unreadable).
    pub fn waitVersion(self: *Codex) version.Detection {
        return if (self.detector) |*d| d.waitResult() else .unreadable;
    }

    pub fn probe(self: *Codex, _: std.mem.Allocator) anyerror!contract.Descriptor {
        return .{
            .harness = name,
            .harness_version = self.harnessVersion(),
            .channel = "app-server",
            // Permission profiles were checked on this version (scope).
            .min_version = min_version,
            .tested_version = tested_version,
            .caps = self.caps(),
        };
    }

    pub fn caps(_: *Codex) contract.Caps {
        return .{
            .steer = .inject,
            .interrupt = true,
            // "always" is venom's grant; codex never gets a rule.
            .requests = .{ .approval = .{ .edit = false, .always = .none }, .question = .{ .free_text = true } },
            .fork = .at_turn,
            // Take-over: `resume_command`, `catch_up`, `notify`.
            .resume_tui = true,
            .release = true,
            .catch_up = .api,
            .attention_away = .turn_end,
            .usage = .{ .per_turn = true, .context = .estimate, .plan_windows = .stable },
            // `thread/compact/start`. No `mcp_off` yet.
            .compact = true,
            .permission_modes = &.{"plan"},
        };
    }

    /// `thread/compact/start`: its progress arrives as a turn. Asked once the
    /// thread is open and nothing runs, as a message would be (`pump`).
    pub fn compact(self: *Codex, conv: *Conversation) anyerror!void {
        const s = try self.state(conv.agent);
        s.compact_wanted = true;
        try self.pump(conv, s);
    }

    pub fn start(self: *Codex, a: std.mem.Allocator, params: contract.Start) anyerror!contract.Spawn {
        const s = try self.state(params.agent);
        s.reset(self.gpa);
        const l = s.life.allocator();
        s.resume_thread = if (params.harness_session) |h| try l.dupe(u8, h) else null;
        s.want_model = if (params.model) |m| try l.dupe(u8, m) else null;
        s.cwd = try l.dupe(u8, params.cwd);
        s.plan = if (params.permission_mode) |m| std.mem.eql(u8, m, "plan") else false;
        if (params.read_only.len > 0) s.scope = .{
            .writable = try dupeAll(l, params.writable),
            .read_only = try dupeAll(l, params.read_only),
            .slash_tmp = !agent_scope.withinPath("/tmp", params.cwd),
        };
        const id = try s.call(self.gpa, .initialize, null);
        const hello = try std.json.Stringify.valueAlloc(a, .{
            .method = "initialize",
            .id = id,
            .params = .{ .clientInfo = .{ .name = "venom", .title = "venom", .version = self.client_version } },
        }, .{});
        var argv: []const []const u8 = self.argv;
        var env: []const contract.EnvVar = try withHome(a, self.env, params.home);
        if (self.mcp) |m| {
            // Last on the command line, so `extra_args` cannot override them.
            argv = try std.mem.concat(a, []const u8, &.{ self.argv, try mcp.codexOverrides(a, m) });
            if (m.socket) |path| env = try std.mem.concat(a, contract.EnvVar, &.{ env, &.{.{ .name = mcp.socket_env, .value = path }} });
        }
        return .{
            .argv = argv,
            .cwd = params.cwd,
            .env = env,
            .harness_session = params.harness_session,
            .input = try std.mem.concat(a, u8, &.{ hello, "\n" }),
        };
    }

    pub fn send(self: *Codex, conv: *Conversation, text: []const u8, mode: contract.SendMode) anyerror!void {
        const s = try self.state(conv.agent);
        switch (mode) {
            .steer => if (conv.inTurn() and conv.harness_turn != null) {
                const id = try s.call(self.gpa, .steer, text);
                return conv.writeJson(.{ .method = "turn/steer", .id = id, .params = .{ .threadId = s.thread orelse "", .input = input(text), .expectedTurnId = conv.harness_turn.? } });
            },
            .interrupt_then_send => try self.interrupt(conv),
            .turn => {},
        }
        try s.queue.append(self.gpa, try self.gpa.dupe(u8, text));
        try self.pump(conv, s);
    }

    pub fn interrupt(self: *Codex, conv: *Conversation) anyerror!void {
        if (!conv.inTurn()) {
            // `turn/start` is on its way: interrupt once the turn starts.
            const s = try self.state(conv.agent);
            if (s.starting) s.interrupt_pending = true;
            return;
        }
        const s = try self.state(conv.agent);
        const turn = conv.harness_turn orelse {
            s.interrupt_pending = true;
            return;
        };
        const id = try s.call(self.gpa, .interrupt, null);
        try conv.writeJson(.{ .method = "turn/interrupt", .id = id, .params = .{ .threadId = s.thread orelse "", .turnId = turn } });
    }

    pub fn respond(self: *Codex, conv: *Conversation, request: contract.Pending, answer: contract.Answer) anyerror!void {
        const s = try self.state(conv.agent);
        const ask_ids = s.asks.get(request.harness_ref) orelse return error.RequestResolved;
        const ta = s.turn.allocator();
        if (eql(request.kind, "question")) {
            // Codex's answer: `{"answers":{"<codex id>":{"answers":[labels]}}}`.
            // The answer's `args` keys are positions (q1, q2, …); without
            // `args` the reply is the answer of every question.
            const picked: ?Value = if (answer.args_json) |j| std.json.parseFromSliceLeaky(Value, ta, j, .{}) catch return error.InvalidAnswer else null;
            var out: std.Io.Writer.Allocating = .init(ta);
            var w: std.json.Stringify = .{ .writer = &out.writer };
            try out.writer.print("{{\"id\":{s},\"result\":", .{request.harness_ref});
            try w.beginObject();
            try w.objectField("answers");
            try w.beginObject();
            for (ask_ids, 1..) |codex_id, n| {
                const sel: ?Value = if (picked) |pv| (field(pv, try std.fmt.allocPrint(ta, "q{d}", .{n})) orelse continue) else null;
                try w.objectField(codex_id);
                try w.beginObject();
                try w.objectField("answers");
                try w.beginArray();
                if (sel) |x| switch (x) {
                    .string => |l| try w.write(l),
                    .array => |list| for (list.items) |item| {
                        if (item != .string) return error.InvalidAnswer;
                        try w.write(item.string);
                    },
                    else => return error.InvalidAnswer,
                } else try w.write(answer.answer);
                try w.endArray();
                try w.endObject();
            }
            try w.endObject();
            try w.endObject();
            try out.writer.writeAll("}");
            try conv.writeLine(out.written());
            try s.answered.put(ta, try ta.dupe(u8, request.harness_ref), {});
            return;
        }
        const decision: []const u8 = if (eql(answer.answer, "allow_once"))
            "\"accept\""
        else if (eql(answer.answer, "allow_always"))
            // venom's grant is authoritative: codex runs this call once and
            // the standing grant answers later matching requests.
            "\"accept\""
        else if (eql(answer.answer, "deny"))
            "\"decline\""
        else if (eql(answer.answer, "cancel_turn"))
            "\"cancel\""
        else
            return error.InvalidAnswer;
        const line = try std.fmt.allocPrint(ta, "{{\"id\":{s},\"result\":{{\"decision\":{s}}}}}", .{ request.harness_ref, decision });
        try conv.writeLine(line);
        try s.answered.put(ta, try ta.dupe(u8, request.harness_ref), {});
        // A deny reason reaches the model as a steer.
        if (eql(answer.answer, "deny")) if (answer.reason) |r| if (r.len > 0) try self.send(conv, r, .steer);
    }

    pub fn decode(self: *Codex, conv: *Conversation, line: []const u8) anyerror!void {
        var arena: std.heap.ArenaAllocator = .init(conv.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // A line that is not JSON is skipped.
        const v = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch return;
        if (v != .object) return;
        const s = try self.state(conv.agent);
        if (str(v, "method")) |method| {
            if (v.object.get("id")) |id| return self.serverRequest(conv, s, a, method, id, field(v, "params"));
            return self.notification(conv, s, method, field(v, "params"));
        }
        const id = int(v, "id") orelse return;
        return self.response(conv, s, @intCast(@max(0, id)), field(v, "result"), field(v, "error"));
    }

    pub fn fork(self: *Codex, a: std.mem.Allocator, conv: *Conversation, harness_turn: ?[]const u8) anyerror!contract.ForkStep {
        const source = conv.harness_session orelse return error.HarnessSessionNotFound;
        if (conv.channel == null) return error.HarnessExited;
        const s = try self.state(conv.agent);
        if (s.fork == null) {
            if (conv.inTurn() or s.starting or s.queue.items.len > 0) return error.TurnRunning;
            s.fork = .{ .deadline_ms = supervisor.monotonicMs() + self.fork_timeout_ms };
        }
        // Anything but `.pending` ends this fork; an answer to a request it
        // sent is then late, and only lets the new thread go.
        errdefer s.fork = null;
        const f = &s.fork.?;
        if (f.id == null) {
            // A process the host just started is still opening the thread.
            if (s.phase == .failed) return if (s.resume_thread != null) error.HarnessSessionNotFound else error.HarnessProtocol;
            if (s.phase == .ready) {
                if (conv.inTurn() or s.starting or s.queue.items.len > 0) return error.TurnRunning;
                const id = try s.call(self.gpa, .fork, null);
                f.id = id;
                try conv.writeJson(.{ .method = "thread/fork", .id = id, .params = .{ .threadId = s.thread orelse source, .lastTurnId = harness_turn, .excludeTurns = true } });
            }
        }
        if (!f.done) {
            if (supervisor.monotonicMs() >= f.deadline_ms) return error.HarnessRequestTimeout;
            return .pending;
        }
        const thread = f.thread orelse return if (f.refused) error.HarnessForkRefused else error.HarnessProtocol;
        const new = try a.dupe(u8, thread);
        try self.unsubscribe(conv, s, thread);
        s.fork = null;
        return .{ .done = new };
    }

    /// The new thread is its own agent's, in a process of its own.
    fn unsubscribe(self: *Codex, conv: *Conversation, s: *State, thread: []const u8) !void {
        const id = try s.call(self.gpa, .ignored, null);
        try conv.writeJson(.{ .method = "thread/unsubscribe", .id = id, .params = .{ .threadId = thread } });
    }

    pub fn release(_: *Codex, conv: *Conversation) anyerror!void {
        if (conv.inTurn()) return error.TurnRunning;
        // The thread stays on disk; `reattach` resumes it.
        conv.closeInput();
        conv.signal(.TERM) catch {};
    }

    /// Take-over: `codex resume <thread>` in the agent's folder, with the
    /// adapter's env so the TUI uses the same `CODEX_HOME`. `VENOM_AGENT` names
    /// the agent; the env never carries a `VENOM_TOKEN`.
    /// `notify` goes in only when the split can be reported (`hooks`).
    pub fn resume_command(self: *Codex, a: std.mem.Allocator, record: contract.Resume) anyerror!contract.Spawn {
        if (self.argv.len == 0) return error.UnsupportedCapability;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ self.argv[0], "resume", record.harness_session });
        var env: std.ArrayList(contract.EnvVar) = .empty;
        try env.appendSlice(a, try withHome(a, self.env, record.home));
        if (record.agent.len > 0) try env.append(a, .{ .name = "VENOM_AGENT", .value = record.agent });
        if (record.hooks) {
            const venom = if (self.mcp) |m| m.command else "venom";
            try argv.appendSlice(a, &.{ "-c", try mcp.codexNotify(a, venom, record.agent) });
            if (self.mcp) |m| if (m.socket) |path| try env.append(a, .{ .name = mcp.socket_env, .value = path });
        }
        return .{ .argv = argv.items, .cwd = record.cwd, .env = env.items, .harness_session = record.harness_session };
    }

    /// `catch_up = api` (`codex_record.zig`).
    pub fn catch_up(self: *Codex, conv: *Conversation, record: contract.Resume) anyerror!u32 {
        return record_.catchUp(self, conv, record);
    }

    /// A tool item that has completed: `tool.started`, unless it already was,
    /// then `tool.ended`. Other items are ignored.
    pub fn toolCompleted(self: *Codex, conv: *Conversation, item: Value, cwd: []const u8) !void {
        var t = tool(item, cwd) orelse return;
        const kind = str(item, "type") orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        // An item that completes without `item/started` still gets one.
        if (!started(conv, t.harness_ref)) t.raw_input = try rawItem(arena.allocator(), item);
        conv.toolStarted(t) catch |err| switch (err) {
            error.HarnessProtocol => {},
            else => return err,
        };
        const ms = int(item, "durationMs");
        try conv.toolEnd(t.harness_ref, .{
            .status = endStatus(item),
            .exit = if (eql(kind, "commandExecution")) int(item, "exitCode") else null,
            .duration_ms = if (ms) |m| @intCast(@max(0, m)) else null,
            .body = try bodyOf(arena.allocator(), item),
        });
    }

    // ------------------------------------------------------------ internals

    fn state(self: *Codex, agent: []const u8) !*State {
        if (self.states.get(agent)) |s| return s;
        const s = try self.gpa.create(State);
        errdefer self.gpa.destroy(s);
        s.* = .{ .life = .init(self.gpa), .turn = .init(self.gpa) };
        const key = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(key);
        try self.states.put(self.gpa, key, s);
        return s;
    }

    /// Starts the next queued message when the conversation is between turns.
    fn pump(self: *Codex, conv: *Conversation, s: *State) !void {
        if (s.phase != .ready or conv.inTurn() or s.starting) return;
        if (s.compact_wanted) {
            s.compact_wanted = false;
            const id = try s.call(self.gpa, .compact, null);
            s.starting = true;
            conv.sending = true;
            return conv.writeJson(.{ .method = "thread/compact/start", .id = id, .params = .{ .threadId = s.thread orelse "" } });
        }
        if (s.queue.items.len == 0) return;
        const text = s.queue.orderedRemove(0);
        defer self.gpa.free(text);
        const id = try s.call(self.gpa, .turn_start, null);
        s.starting = true;
        conv.sending = true;
        try conv.writeJson(.{ .method = "turn/start", .id = id, .params = .{ .threadId = s.thread orelse "", .input = input(text) } });
    }

    fn openThread(self: *Codex, conv: *Conversation, s: *State) !void {
        const id = try s.call(self.gpa, .open, null);
        // A profile replaces `sandbox`: Codex says not to combine them.
        if (s.plan) {
            // `plan` asks for every write, in scope or not: narrower than any profile.
            if (s.resume_thread) |t| {
                try conv.writeJson(.{ .method = "thread/resume", .id = id, .params = .{ .threadId = t, .cwd = s.cwd, .model = s.want_model, .approvalPolicy = self.approval_policy, .sandbox = "read-only", .excludeTurns = true } });
            } else {
                try conv.writeJson(.{ .method = "thread/start", .id = id, .params = .{ .cwd = s.cwd, .model = s.want_model, .approvalPolicy = self.approval_policy, .sandbox = "read-only" } });
            }
        } else if (s.scope) |scope| {
            if (s.resume_thread) |t| {
                try conv.writeJson(.{ .method = "thread/resume", .id = id, .params = .{ .threadId = t, .cwd = s.cwd, .model = s.want_model, .approvalPolicy = self.approval_policy, .config = scope, .excludeTurns = true } });
            } else {
                try conv.writeJson(.{ .method = "thread/start", .id = id, .params = .{ .cwd = s.cwd, .model = s.want_model, .approvalPolicy = self.approval_policy, .config = scope } });
            }
        } else if (s.resume_thread) |t| {
            try conv.writeJson(.{ .method = "thread/resume", .id = id, .params = .{ .threadId = t, .cwd = s.cwd, .model = s.want_model, .approvalPolicy = self.approval_policy, .sandbox = self.sandbox, .excludeTurns = true } });
        } else {
            try conv.writeJson(.{ .method = "thread/start", .id = id, .params = .{ .cwd = s.cwd, .model = s.want_model, .approvalPolicy = self.approval_policy, .sandbox = self.sandbox } });
        }
    }

    fn response(self: *Codex, conv: *Conversation, s: *State, id: u64, result: ?Value, err: ?Value) !void {
        const kv = s.calls.fetchRemove(id) orelse return;
        const c = kv.value;
        defer if (c.text) |t| self.gpa.free(t);
        switch (c.purpose) {
            .initialize => {
                if (err != null) return self.failOpen(conv, s, "failed.harness_protocol");
                if (result) |r| if (str(r, "userAgent")) |ua| {
                    s.version = try s.life.allocator().dupe(u8, versionOf(ua));
                };
                try conv.writeJson(.{ .method = "initialized", .params = struct {}{} });
                s.phase = .opening;
                try self.openThread(conv, s);
            },
            .open => {
                const r = result orelse return self.failOpen(conv, s, if (s.resume_thread != null) "not_found.harness_session" else "failed.harness_protocol");
                if (s.scope != null and !s.plan and !profileActive(r)) return self.failOpen(conv, s, "unsupported.harness_version");
                const thread = str(field(r, "thread") orelse return error.HarnessProtocol, "id") orelse return error.HarnessProtocol;
                const l = s.life.allocator();
                s.thread = try l.dupe(u8, thread);
                if (str(r, "model")) |m| s.model = try l.dupe(u8, m);
                // A new thread starts at zero; a resumed one re-bases on
                // its first usage report.
                s.base = if (s.resume_thread == null) .{} else null;
                try conv.session(thread, if (s.model.len > 0) s.model else null, s.version);
                s.phase = .ready;
                const account = try s.call(self.gpa, .account, null);
                try conv.writeJson(.{ .method = "account/read", .id = account, .params = struct {}{} });
                const limits = try s.call(self.gpa, .rate_limits, null);
                try conv.writeJson(.{ .method = "account/rateLimits/read", .id = limits });
                s.plan_reads = 2;
                try self.pump(conv, s);
            },
            .turn_start, .compact => {
                if (err == null) return;
                s.starting = false;
                // The turn never started: log it as one that failed.
                if (!conv.inTurn()) {
                    try conv.turnStarted(null, "user");
                    try self.endFailed(conv, classify(errorInfo(err.?), "failed.harness_turn"));
                }
                try self.pump(conv, s);
            },
            .steer => if (err != null) {
                // The turn just ended (stale expectedTurnId): next turn instead.
                try s.queue.insert(self.gpa, 0, try self.gpa.dupe(u8, c.text orelse ""));
                try self.pump(conv, s);
            },
            .interrupt, .ignored => {},
            // Both are best effort: no sign-in or an API key has no windows.
            .account => {
                if (result) |r| self.plan.setAccount(if (field(r, "account")) |acc| str(acc, "type") else null);
                try self.planRead(conv, s);
            },
            .rate_limits => {
                if (result) |r| self.plan.replace(r);
                try self.planRead(conv, s);
            },
            .fork => {
                const thread = if (result) |r| (if (field(r, "thread")) |t| str(t, "id") else null) else null;
                // Not the one a fork still waits for: it gave up on this one,
                // so nothing else will let the new thread go.
                const f = if (s.fork) |*f| (if (f.id == id) f else null) else null;
                const waiting = f orelse return if (thread) |t| self.unsubscribe(conv, s, t);
                waiting.done = true;
                waiting.refused = err != null;
                if (thread) |t| waiting.thread = try s.life.allocator().dupe(u8, t);
            },
        }
    }

    /// The conversation could not be opened: whatever was sent fails, and
    /// the process is told to exit (end of input).
    fn failOpen(self: *Codex, conv: *Conversation, s: *State, code: []const u8) !void {
        s.phase = .failed;
        s.compact_wanted = false;
        if (s.queue.items.len > 0 or conv.sending) {
            for (s.queue.items) |t| self.gpa.free(t);
            s.queue.clearRetainingCapacity();
            if (!conv.inTurn()) try conv.turnStarted(null, "user");
            try conv.turnEnded("failed", code);
        }
        conv.closeInput();
    }

    fn notification(self: *Codex, conv: *Conversation, s: *State, method: []const u8, params: ?Value) !void {
        const p = params orelse return;
        // Native sub-agents run in their own threads.
        if (str(p, "threadId")) |t| if (s.thread) |mine| if (!eql(t, mine)) return;
        if (eql(method, "turn/started")) {
            const turn = field(p, "turn") orelse return error.HarnessProtocol;
            const origin = if (s.starting or conv.sending) "user" else "harness";
            s.starting = false;
            s.last_error = null;
            try conv.turnStarted(str(turn, "id"), origin);
            if (s.interrupt_pending) {
                s.interrupt_pending = false;
                try self.interrupt(conv);
            }
        } else if (eql(method, "turn/completed")) {
            if (!conv.inTurn()) return;
            const turn = field(p, "turn") orelse return error.HarnessProtocol;
            try self.reportUsage(conv, s);
            try reportContext(conv, s);
            const status = str(turn, "status") orelse "completed";
            if (eql(status, "interrupted")) {
                try conv.turnEnded("interrupted", null);
            } else if (eql(status, "failed")) {
                const info = if (field(turn, "error")) |e| errorInfo(e) else null;
                try self.endFailed(conv, classify(info orelse s.last_error, "failed.harness_turn"));
            } else try conv.turnEnded("completed", null);
            s.endTurn();
            try self.pump(conv, s);
        } else if (eql(method, "item/started")) {
            const item = field(p, "item") orelse return;
            try s.noteEdit(self.gpa, item);
            if (tool(item, s.cwd)) |found| {
                var t = found;
                t.raw_input = try rawItem(s.turn.allocator(), item);
                try conv.toolStarted(t);
            }
            // An approval names its item: keep what that item would do.
            if (str(item, "id")) |item_id| if (try itemInput(s.turn.allocator(), item)) |whole| try s.inputs.put(s.turn.allocator(), try s.turn.allocator().dupe(u8, item_id), whole);
        } else if (eql(method, "item/completed")) {
            const item = field(p, "item") orelse return;
            const kind = str(item, "type") orelse return;
            if (eql(kind, "agentMessage")) return conv.text(str(item, "text") orelse "", true);
            try self.toolCompleted(conv, item, s.cwd);
        } else if (eql(method, "item/agentMessage/delta")) {
            if (conv.inTurn()) try conv.text(str(p, "delta") orelse "", false);
        } else if (eql(method, "item/commandExecution/outputDelta")) {
            if (conv.inTurn()) conv.toolUpdated(str(p, "itemId") orelse "", str(p, "delta") orelse "") catch {};
        } else if (eql(method, "serverRequest/resolved")) {
            if (!conv.inTurn()) return;
            const id = p.object.get("requestId") orelse return;
            const key = try idKey(s.turn.allocator(), id);
            try conv.requestResolved(key, if (s.answered.contains(key)) "venom" else "harness");
            _ = s.asks.remove(key);
        } else if (eql(method, "thread/tokenUsage/updated")) {
            const usage = field(p, "tokenUsage") orelse return;
            const total = Tokens.of(field(usage, "total") orelse return);
            const last = field(usage, "last");
            // A replayed total re-bases; it is no turn's usage.
            const current = conv.inTurn() and (if (str(p, "turnId")) |t| (if (conv.harness_turn) |h| eql(t, h) else true) else true);
            if (s.resume_thread != null and !s.usage_live and !current) {
                s.base = total;
            } else {
                if (s.base == null) s.base = total.minus(Tokens.of(last orelse return));
                s.usage_live = true;
            }
            s.total = total;
            // The context estimate: the last call's input over the window.
            if (last) |l| s.context_used = count(l, "inputTokens");
            if (int(usage, "modelContextWindow")) |w| if (w > 0) {
                s.context_window = @intCast(w);
            };
        } else if (eql(method, "account/rateLimits/updated")) {
            self.plan.merge(field(p, "rateLimits") orelse return);
            if (s.plan_reads == 0) try self.reportPlan(conv);
        } else if (eql(method, "error")) {
            // Codex retries some errors itself; the last final one explains
            // a `failed` turn whose `turn.error` is empty.
            const retry = if (p.object.get("willRetry")) |w| w == .bool and w.bool else false;
            if (!retry) if (field(p, "error")) |e| if (errorInfo(e)) |info| {
                s.last_error = classifyTag(info);
            };
        }
        // Unknown methods are ignored.
    }

    /// Ends a failed turn; a `limit` gets the most used window's reset time.
    fn endFailed(self: *Codex, conv: *Conversation, end: End) !void {
        var buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const resets: ?[]const u8 = if (eql(end.reason, "limit")) (if (self.plan.resetsAt()) |r| try contract.rfc3339(fba.allocator(), r) else null) else null;
        try conv.turnEnd(.{ .reason = end.reason, .error_code = end.code, .resets_at = resets });
    }

    /// One of the two reads after `session` answered, either way.
    fn planRead(self: *Codex, conv: *Conversation, s: *State) !void {
        s.plan_reads -|= 1;
        if (s.plan_reads == 0) try self.reportPlan(conv);
    }

    /// Logs the plan when it is known and changed.
    fn reportPlan(self: *Codex, conv: *Conversation) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const report = try self.plan.report(arena.allocator()) orelse return;
        const line = try std.json.Stringify.valueAlloc(arena.allocator(), report, .{ .emit_null_optional_fields = false });
        if (self.plan.logged) |l| if (eql(l, line)) return;
        const kept = try self.gpa.dupe(u8, line);
        if (self.plan.logged) |l| self.gpa.free(l);
        self.plan.logged = kept;
        try conv.planWindows(report);
    }

    /// Logs the context estimate when it is known and changed.
    fn reportContext(conv: *Conversation, s: *State) !void {
        if (s.context_window == 0 or s.context_used == 0) return;
        if (s.context_logged) |l| if (l[0] == s.context_used and l[1] == s.context_window) return;
        s.context_logged = .{ s.context_used, s.context_window };
        try conv.context(s.context_used, s.context_window, "estimate");
    }

    /// Per-turn usage: the change of `tokenUsage.total` since the last turn.
    fn reportUsage(_: *Codex, conv: *Conversation, s: *State) !void {
        const base = s.base orelse s.total;
        const d = s.total.minus(base);
        s.base = s.total;
        try conv.usage(.{ .model = s.model, .tokens_in = d.input -| d.cached, .tokens_out = d.output, .cache_read = d.cached, .cache_write = d.cache_write });
    }

    /// `item/tool/requestUserInput`: a `question` request. The
    /// ids of its `questions` are kept for the answer; `options` are shown by
    /// position (q1, q2, …).
    fn userInput(_: *Codex, conv: *Conversation, s: *State, a: std.mem.Allocator, key: []const u8, params: ?Value) !void {
        const ta = s.turn.allocator();
        const p = params orelse Value{ .null = {} };
        const qs = field(p, "questions");
        // No questions to ask, or outside a turn: answer nothing.
        const empty = try std.fmt.allocPrint(a, "{{\"id\":{s},\"result\":{{\"answers\":{{}}}}}}", .{key});
        if (qs == null or qs.? != .array or qs.?.array.items.len == 0) return conv.writeLine(empty);
        var ids: std.ArrayList([]const u8) = .empty;
        for (qs.?.array.items, 0..) |q, n| try ids.append(ta, try ta.dupe(u8, str(q, "id") orelse try std.fmt.allocPrint(a, "q{d}", .{n + 1})));
        const first = qs.?.array.items[0];
        const reason = str(first, "question") orelse str(first, "header") orelse "Codex has a question.";
        const whole = try std.json.Stringify.valueAlloc(a, p, .{});
        conv.request(.{ .harness_ref = key, .kind = "question", .reason = reason, .input_json = whole, .options = try contract.questionOptions(a, qs.?, false) }) catch |err| switch (err) {
            error.HarnessProtocol => return conv.writeLine(empty),
            else => return err,
        };
        try s.asks.put(ta, key, ids.items);
    }

    fn serverRequest(self: *Codex, conv: *Conversation, s: *State, a: std.mem.Allocator, method: []const u8, id: Value, params: ?Value) !void {
        const key = try idKey(s.turn.allocator(), id);
        if (eql(method, "item/tool/requestUserInput")) return self.userInput(conv, s, a, key, params);
        const command = eql(method, "item/commandExecution/requestApproval");
        if (!command and !eql(method, "item/fileChange/requestApproval")) {
            const msg = try std.fmt.allocPrint(a, "venom does not handle {s}", .{method});
            const line = try std.json.Stringify.valueAlloc(a, .{ .id = id, .@"error" = .{ .code = -32601, .message = msg } }, .{});
            return conv.writeLine(line);
        }
        const p = params orelse Value{ .null = {} };
        const ta = s.turn.allocator();
        const reason = str(p, "reason") orelse if (command)
            (if (str(p, "command")) |cmd| try std.fmt.allocPrint(a, "Run {s}", .{cmd}) else "Run a command")
        else
            "Apply file changes";
        const item_input = if (str(p, "itemId")) |item_id| s.inputs.get(item_id) else null;
        const whole = try approvalInput(a, item_input, p);
        const outside = !command and try s.editOutside(self.gpa, p);
        conv.request(.{ .harness_ref = key, .kind = "approval", .call_ref = str(p, "itemId"), .reason = reason, .answers = &.{ "allow_once", "allow_always", "deny", "cancel_turn" }, .input_json = whole, .outside_scope = outside }) catch |err| switch (err) {
            // Outside a turn there is no one to ask: decline.
            error.HarnessProtocol => return conv.writeLine(try std.fmt.allocPrint(a, "{{\"id\":{s},\"result\":{{\"decision\":\"decline\"}}}}", .{key})),
            else => return err,
        };
        try s.asks.put(ta, key, &.{});
    }
};

/// What `notify` reports (`turn_end`): `agent-turn-complete` of
/// the agent's thread is the turn's end, up for review. Anything else raises
/// nothing: Codex 0.167.0 also reports its own background threads, such as the
/// one that writes the task's title.
pub fn parseNotify(a: std.mem.Allocator, input_json: []const u8, thread: []const u8) !contract.HookReport {
    const v = std.json.parseFromSliceLeaky(Value, a, input_json, .{}) catch return error.InvalidHook;
    if (v != .object) return error.InvalidHook;
    const kind = str(v, "type") orelse return error.InvalidHook;
    if (!eql(kind, "agent-turn-complete")) return .{};
    if (str(v, "thread-id")) |t| if (!eql(t, thread)) return .{};
    return .{ .kind = .review, .reason = "turn ended in " ++ name };
}

/// The error code of a `failed` turn's `error`, classified as a live one is.
pub fn failureCode(err: ?Value) []const u8 {
    return classify(if (err) |e| errorInfo(e) else null, "failed.harness_turn").code;
}

/// The `config` of a scoped thread: see the file comment.
const profile_id = "venom_scope";
const ScopeConfig = struct {
    writable: []const []const u8,
    read_only: []const []const u8,
    /// `/tmp`, unless the workspace itself is under it.
    slash_tmp: bool,

    pub fn jsonStringify(self: ScopeConfig, w: anytype) !void {
        try w.beginObject();
        try w.objectField("default_permissions");
        try w.write(profile_id);
        try w.objectField("permissions");
        try w.beginObject();
        try w.objectField(profile_id);
        try w.beginObject();
        try w.objectField("filesystem");
        try w.beginObject();
        try w.objectField(":root");
        try w.write("read");
        try w.objectField(":tmpdir");
        try w.write("write");
        if (self.slash_tmp) {
            try w.objectField(":slash_tmp");
            try w.write("write");
        }
        for (self.writable) |path| {
            try w.objectField(path);
            try w.write("write");
        }
        // The narrower path wins, so these hold under a writable temp folder.
        for (self.read_only) |path| {
            try w.objectField(path);
            try w.write("read");
        }
        try w.endObject();
        try w.endObject();
        try w.endObject();
        try w.endObject();
    }
};

/// Whether the thread runs under venom's profile.
fn profileActive(result: Value) bool {
    const active = field(result, "activePermissionProfile") orelse return false;
    return eql(str(active, "id") orelse "", profile_id);
}

fn dupeAll(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

const Purpose = enum { initialize, open, turn_start, compact, steer, interrupt, account, rate_limits, fork, ignored };
const Call = struct { purpose: Purpose, text: ?[]u8 = null };

pub const Tokens = struct {
    input: u64 = 0,
    cached: u64 = 0,
    cache_write: u64 = 0,
    output: u64 = 0,

    fn of(v: Value) Tokens {
        return .{ .input = count(v, "inputTokens"), .cached = count(v, "cachedInputTokens"), .cache_write = count(v, "cacheWriteInputTokens"), .output = count(v, "outputTokens") };
    }
    /// A rollout's `token_count` spells the same numbers in snake case.
    pub fn ofRollout(v: Value) Tokens {
        return .{ .input = count(v, "input_tokens"), .cached = count(v, "cached_input_tokens"), .cache_write = count(v, "cache_write_input_tokens"), .output = count(v, "output_tokens") };
    }
    pub fn minus(x: Tokens, y: Tokens) Tokens {
        return .{ .input = x.input -| y.input, .cached = x.cached -| y.cached, .cache_write = x.cache_write -| y.cache_write, .output = x.output -| y.output };
    }
    pub fn plus(x: Tokens, y: Tokens) Tokens {
        return .{ .input = x.input + y.input, .cached = x.cached + y.cached, .cache_write = x.cache_write + y.cache_write, .output = x.output + y.output };
    }
    pub fn isZero(x: Tokens) bool {
        return x.input == 0 and x.cached == 0 and x.cache_write == 0 and x.output == 0;
    }
};

/// The account's plan windows as app-server reports
/// them, sparse updates merged. `primary` and `secondary`, in that order.
const Plan = struct {
    account: []const u8 = "unknown",
    billing: []const u8 = "unknown",
    windows: [2]Window = .{ .{}, .{} },
    /// The last report logged, as JSON; gpa-owned.
    logged: ?[]u8 = null,

    const Window = struct { used_pct: ?i64 = null, resets_at: ?i64 = null, minutes: ?i64 = null };
    const ids = [_][]const u8{ "primary", "secondary" };

    /// `account.type`; `chatgpt` is a plan, `apiKey` bills per token, and
    /// anything else is not known to be either.
    fn setAccount(self: *Plan, kind: ?[]const u8) void {
        const k = kind orelse "";
        self.account = if (eql(k, "chatgpt")) "chatgpt" else if (eql(k, "apiKey")) "apiKey" else if (eql(k, "amazonBedrock")) "amazonBedrock" else if (eql(k, "gcp")) "gcp" else "unknown";
        self.billing = if (eql(k, "chatgpt")) "subscription" else if (eql(k, "apiKey")) "api_key" else "unknown";
    }

    /// One `RateLimitSnapshot`. Other buckets (`limitId`) have windows of
    /// their own, which must not overwrite the `codex` ones.
    fn merge(self: *Plan, limits: Value) void {
        if (str(limits, "limitId")) |id| if (!eql(id, "codex")) return;
        for (ids, &self.windows) |key, *w| if (field(limits, key)) |win| {
            if (int(win, "usedPercent")) |u| w.used_pct = u;
            if (int(win, "resetsAt")) |r| w.resets_at = r;
            if (int(win, "windowDurationMins")) |m| w.minutes = m;
        };
    }

    /// A full `account/rateLimits/read` answer: windows it leaves out are
    /// gone. An answer without the `codex` bucket changes nothing.
    fn replace(self: *Plan, read: Value) void {
        const by_id = if (field(read, "rateLimitsByLimitId")) |m| field(m, "codex") else null;
        const limits = by_id orelse field(read, "rateLimits") orelse return;
        if (str(limits, "limitId")) |id| if (!eql(id, "codex")) return;
        self.windows = .{ .{}, .{} };
        self.merge(limits);
    }

    /// When the most used window resets (unix seconds), if known.
    fn resetsAt(self: *const Plan) ?i64 {
        var best: ?Window = null;
        for (self.windows) |w| {
            if (w.resets_at == null) continue;
            if (best == null or (w.used_pct orelse 0) > (best.?.used_pct orelse 0)) best = w;
        }
        return if (best) |b| b.resets_at else null;
    }

    /// The plan windows object, or null while neither the account nor any
    /// window is known.
    fn report(self: *const Plan, a: std.mem.Allocator) !?contract.PlanReport {
        var out: std.ArrayList(contract.PlanWindow) = .empty;
        for (ids, self.windows) |id, w| {
            const used = w.used_pct orelse continue;
            try out.append(a, .{
                .id = id,
                .label = try windowLabel(a, w.minutes, id),
                .used_pct = @intCast(std.math.clamp(used, 0, std.math.maxInt(u32))),
                .resets_at = if (w.resets_at) |r| try contract.rfc3339(a, r) else null,
            });
        }
        if (out.items.len == 0 and eql(self.account, "unknown")) return null;
        return .{ .account = self.account, .billing = self.billing, .windows = out.items, .source = "stable" };
    }
};

/// The window's length as its label (`300` → `5h`, `10080` → `7d`); its id
/// when the harness gave no length.
fn windowLabel(a: std.mem.Allocator, minutes: ?i64, id: []const u8) ![]const u8 {
    const m = minutes orelse return id;
    if (m <= 0) return id;
    if (@rem(m, 1440) == 0) return std.fmt.allocPrint(a, "{d}d", .{@divTrunc(m, 1440)});
    if (@rem(m, 60) == 0) return std.fmt.allocPrint(a, "{d}h", .{@divTrunc(m, 60)});
    return std.fmt.allocPrint(a, "{d}m", .{m});
}

/// One agent's app-server connection. `life` lives as long as the process
/// (reset by `start`), `turn` as long as the open turn.
const State = struct {
    life: std.heap.ArenaAllocator,
    turn: std.heap.ArenaAllocator,
    phase: enum { initializing, opening, ready, failed } = .initializing,
    next_id: u64 = 0,
    /// Requests venom sent and still waits on, by JSON-RPC id.
    calls: std.AutoHashMapUnmanaged(u64, Call) = .empty,
    /// Messages waiting for the conversation to be between turns.
    queue: std.ArrayList([]u8) = .empty,
    cwd: []const u8 = "",
    /// The agent's narrowed scope, in place of the adapter's `sandbox`.
    scope: ?ScopeConfig = null,
    /// Permission mode `plan`: `sandbox: "read-only"`, whatever the scope.
    plan: bool = false,
    resume_thread: ?[]const u8 = null,
    want_model: ?[]const u8 = null,
    thread: ?[]const u8 = null,
    model: []const u8 = "",
    version: ?[]const u8 = null,
    /// `turn/start` sent, its `turn/started` not seen yet.
    starting: bool = false,
    /// `compact` waits for the thread to open.
    compact_wanted: bool = false,
    interrupt_pending: bool = false,
    /// The last final `error` notification of the turn, classified.
    last_error: ?[]const u8 = null,
    /// Pending approvals by JSON-RPC id (as JSON text), and the ones venom answered.
    /// For a question (`item/tool/requestUserInput`), its codex question ids in
    /// order (q1, q2, … are positions); an approval has none.
    asks: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// `itemInput` of the turn's items, by item id.
    inputs: std.StringHashMapUnmanaged([]const u8) = .empty,
    answered: std.StringHashMapUnmanaged(void) = .empty,
    /// `fileChange` items of the turn with a path outside the scope.
    outside_edits: std.StringHashMapUnmanaged(void) = .empty,
    total: Tokens = .{},
    base: ?Tokens = null,
    /// The context estimate: the last call's input tokens and the model's window.
    context_used: u64 = 0,
    context_window: u64 = 0,
    context_logged: ?[2]u64 = null,
    /// A usage report of a turn this process runs was seen: no more replays.
    usage_live: bool = false,
    /// `account/read` and `account/rateLimits/read` not answered yet.
    plan_reads: u8 = 0,
    /// The fork under way: `id` is its `thread/fork`, once sent.
    fork: ?Fork = null,

    /// `thread` is in `life`; `refused`: the harness answered with an error.
    const Fork = struct { deadline_ms: i64, id: ?u64 = null, done: bool = false, refused: bool = false, thread: ?[]const u8 = null };

    fn call(self: *State, gpa: std.mem.Allocator, purpose: Purpose, text: ?[]const u8) !u64 {
        const id = self.next_id;
        const owned = if (text) |t| try gpa.dupe(u8, t) else null;
        errdefer if (owned) |o| gpa.free(o);
        try self.calls.put(gpa, id, .{ .purpose = purpose, .text = owned });
        self.next_id += 1;
        return id;
    }

    /// Remembers a `fileChange` item that touches a path outside the scope.
    fn noteEdit(self: *State, gpa: std.mem.Allocator, item: Value) !void {
        const scope = self.scope orelse return;
        if (!eql(str(item, "type") orelse "", "fileChange")) return;
        const id = str(item, "id") orelse return;
        const changes = field(item, "changes") orelse return;
        if (changes != .array) return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        for (changes.array.items) |change| {
            const moved: ?[]const u8 = if (field(change, "kind")) |k| str(k, "move_path") else null;
            for ([_]?[]const u8{ str(change, "path"), moved }) |path| {
                if (try agent_scope.outsideRoots(a, scope.writable, self.cwd, path orelse continue)) {
                    const ta = self.turn.allocator();
                    return self.outside_edits.put(ta, try ta.dupe(u8, id), {});
                }
            }
        }
    }

    /// Whether a `fileChange` approval writes outside the scope: its item's
    /// paths, or the root it asks for.
    fn editOutside(self: *State, gpa: std.mem.Allocator, params: Value) !bool {
        const scope = self.scope orelse return false;
        if (str(params, "itemId")) |id| if (self.outside_edits.contains(id)) return true;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        return agent_scope.outsideRoots(arena.allocator(), scope.writable, self.cwd, str(params, "grantRoot") orelse "");
    }

    fn endTurn(self: *State) void {
        // These three live in the turn arena reset below.
        self.asks = .empty;
        self.answered = .empty;
        self.inputs = .empty;
        self.outside_edits = .empty;
        self.last_error = null;
        _ = self.turn.reset(.retain_capacity);
    }

    /// A new process: nothing of the previous one carries over.
    fn reset(self: *State, gpa: std.mem.Allocator) void {
        var it = self.calls.valueIterator();
        while (it.next()) |c| if (c.text) |t| gpa.free(t);
        self.calls.clearRetainingCapacity();
        for (self.queue.items) |t| gpa.free(t);
        self.queue.clearRetainingCapacity();
        self.endTurn();
        _ = self.life.reset(.retain_capacity);
        const life = self.life;
        const turn = self.turn;
        const calls = self.calls;
        const queue = self.queue;
        self.* = .{ .life = life, .turn = turn, .calls = calls, .queue = queue };
    }

    fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.reset(gpa);
        self.calls.deinit(gpa);
        self.queue.deinit(gpa);
        self.turn.deinit();
        self.life.deinit();
    }
};

const TextInput = struct { type: []const u8 = "text", text: []const u8, text_elements: [0]struct {} = .{} };

fn input(text: []const u8) [1]TextInput {
    return .{.{ .text = text }};
}

/// What an approved item would do, as JSON: a command and where it runs, or
/// every change of a patch with its diff. Null for other items, and for a
/// patch whose changes are not known. An approval's own params do not carry a
/// patch, and ids differ on every ask, so this is what identifies the call
/// for a one-shot decision.
pub fn itemInput(a: std.mem.Allocator, item: Value) !?[]const u8 {
    const t = str(item, "type") orelse return null;
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    if (eql(t, "commandExecution")) {
        const command = str(item, "command") orelse return null;
        return try std.json.Stringify.valueAlloc(a, .{ .command = command, .cwd = str(item, "cwd") }, options);
    }
    if (!eql(t, "fileChange")) return null;
    const changes = field(item, "changes") orelse return null;
    if (changes != .array or changes.array.items.len == 0) return null;
    return try std.json.Stringify.valueAlloc(a, .{ .changes = changes }, options);
}

/// A request's input: the item's, plus what the approval itself would allow
/// beyond it (`grantRoot` opens a folder for writing). Null without an item.
pub fn approvalInput(a: std.mem.Allocator, item_input: ?[]const u8, params: Value) !?[]const u8 {
    const item = item_input orelse return null;
    return try std.json.Stringify.valueAlloc(a, .{ .item = item, .command = str(params, "command"), .cwd = str(params, "cwd"), .grant_root = str(params, "grantRoot") }, .{ .emit_null_optional_fields = false });
}

fn started(conv: *const Conversation, harness_ref: []const u8) bool {
    for (conv.open_calls.items) |c| if (eql(c.harness_ref, harness_ref)) return true;
    return false;
}

/// A tool item as the harness sent it, for `J`. A completed item also holds
/// the output, which is the call's body: that stays out of its input.
fn rawItem(a: std.mem.Allocator, item: Value) !?[]const u8 {
    if (item != .object) return null;
    const output = item.object.get("aggregatedOutput") orelse return contract.rawJson(a, item);
    if (output == .null) return contract.rawJson(a, item);
    var kept = try item.object.clone(a);
    _ = kept.orderedRemove("aggregatedOutput");
    return contract.rawJson(a, .{ .object = kept });
}

/// A tool call from a thread item, or null for items that are not one.
/// `cwd` is the agent's, for an exec item without its own.
fn tool(item: Value, cwd: []const u8) ?contract.ToolReport {
    const t = str(item, "type") orelse return null;
    const id = str(item, "id") orelse return null;
    if (eql(t, "commandExecution")) {
        const kind = commandKind(item);
        const command = str(item, "command") orelse "";
        var args: contract.ToolArgs = .{ .command = command, .cwd = str(item, "cwd") orelse cwd };
        if (!eql(kind, "exec")) {
            const act = field(item, "commandActions").?.array.items[0];
            args = if (eql(kind, "search")) .{ .query = str(act, "query"), .path = str(act, "path") } else .{ .path = str(act, "path") };
        }
        return .{ .harness_ref = id, .kind = kind, .name = t, .title = command, .args = args };
    } else if (eql(t, "fileChange")) {
        var title: []const u8 = "";
        var args: contract.ToolArgs = .{ .change = "modify", .added = 0, .removed = 0 };
        if (field(item, "changes")) |ch| if (ch == .array and ch.array.items.len > 0) {
            const first = ch.array.items[0];
            title = str(first, "path") orelse "";
            args.path = title;
            args.change = changeOf(first);
            for (ch.array.items) |change| {
                const counts = diffLines(str(change, "diff") orelse "");
                args.added.? += counts[0];
                args.removed.? += counts[1];
            }
        };
        return .{ .harness_ref = id, .kind = "edit", .name = t, .title = title, .args = args };
    } else if (eql(t, "mcpToolCall")) {
        return .{ .harness_ref = id, .kind = "mcp", .name = t, .title = str(item, "tool") orelse "", .args = .{ .server = str(item, "server"), .tool = str(item, "tool") } };
    } else if (eql(t, "webSearch")) {
        return .{ .harness_ref = id, .kind = "fetch", .name = t, .title = str(item, "query") orelse "", .args = .{ .query = str(item, "query") } };
    } else if (eql(t, "collabAgentToolCall")) {
        return .{ .harness_ref = id, .kind = "agent", .name = t, .title = str(item, "tool") orelse "", .args = .{ .child_ref = childRef(item) } };
    } else if (eql(t, "dynamicToolCall")) {
        return .{ .harness_ref = id, .kind = "other", .name = t, .title = str(item, "tool") orelse "", .args = .{} };
    }
    return null;
}

/// A `fileChange` change's kind (a string, or `{type}`): add → create.
fn changeOf(change: Value) []const u8 {
    const k = field(change, "kind") orelse return "modify";
    const tag = switch (k) {
        .string => |x| x,
        else => str(k, "type") orelse "",
    };
    if (eql(tag, "add")) return "create";
    if (eql(tag, "delete")) return "delete";
    return "modify";
}

/// Added and removed lines of a unified diff (`+++`/`---` headers left out).
fn diffLines(diff: []const u8) [2]u64 {
    var out: [2]u64 = .{ 0, 0 };
    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) continue;
        if (std.mem.startsWith(u8, line, "+")) out[0] += 1;
        if (std.mem.startsWith(u8, line, "-")) out[1] += 1;
    }
    return out;
}

fn childRef(item: Value) ?[]const u8 {
    if (str(item, "receiverThreadId")) |x| return x;
    if (str(item, "newThreadId")) |x| return x;
    const ids = field(item, "receiverThreadIds") orelse return null;
    if (ids != .array or ids.array.items.len == 0 or ids.array.items[0] != .string) return null;
    return ids.array.items[0].string;
}

/// The tool `body`: a command's output, or a file change's diffs.
fn bodyOf(a: std.mem.Allocator, item: Value) !?[]const u8 {
    const t = str(item, "type") orelse return null;
    if (eql(t, "commandExecution")) return str(item, "aggregatedOutput");
    if (!eql(t, "fileChange")) return null;
    const ch = field(item, "changes") orelse return null;
    if (ch != .array) return null;
    var out: std.ArrayList(u8) = .empty;
    for (ch.array.items) |change| if (str(change, "diff")) |d| {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, d);
    };
    return if (out.items.len > 0) out.items else null;
}

/// `exec`, or `read`/`search`/`list` when every parsed action is one.
fn commandKind(item: Value) []const u8 {
    const actions = field(item, "commandActions") orelse return "exec";
    if (actions != .array or actions.array.items.len == 0) return "exec";
    var kind: ?[]const u8 = null;
    for (actions.array.items) |act| {
        const t = str(act, "type") orelse return "exec";
        const k: []const u8 = if (eql(t, "read")) "read" else if (eql(t, "search")) "search" else if (eql(t, "listFiles")) "list" else return "exec";
        if (kind) |prev| if (!eql(prev, k)) return "exec";
        kind = k;
    }
    return kind.?;
}

fn endStatus(item: Value) []const u8 {
    const status = str(item, "status") orelse "completed";
    if (eql(status, "declined")) return "declined";
    if (eql(status, "failed")) return "error";
    if (int(item, "exitCode")) |code| if (code != 0) return "error";
    if (field(item, "success")) |ok| if (ok == .bool and !ok.bool) return "error";
    return "ok";
}

const End = struct { reason: []const u8, code: []const u8 };

/// How a failed turn ends, from Codex's `codexErrorInfo` (or our tag of it).
fn classify(info: ?[]const u8, fallback: []const u8) End {
    const tag = classifyTag(info orelse return .{ .reason = "failed", .code = fallback });
    if (eql(tag, "failed.usage_limit")) return .{ .reason = "limit", .code = tag };
    return .{ .reason = "failed", .code = tag };
}

fn classifyTag(info: []const u8) []const u8 {
    if (eql(info, "usageLimitExceeded") or eql(info, "rateLimitExceeded") or eql(info, "failed.usage_limit")) return "failed.usage_limit";
    if (eql(info, "unauthorized") or eql(info, "unavailable.harness_not_signed_in")) return "unavailable.harness_not_signed_in";
    return "failed.harness_turn";
}

/// `codexErrorInfo` of a turn error or JSON-RPC error: a string, or the
/// single key of an object variant (`{"httpConnectionFailed": …}`).
fn errorInfo(err: Value) ?[]const u8 {
    const info = field(err, "codexErrorInfo") orelse (if (field(err, "data")) |d| field(d, "codexErrorInfo") else null) orelse return null;
    return switch (info) {
        .string => |s| s,
        .object => |o| if (o.count() > 0) o.keys()[0] else null,
        else => null,
    };
}

/// `codex_cli_rs/0.167.0 (Linux …) …` → `0.167.0`.
fn versionOf(user_agent: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, user_agent, '/') orelse return user_agent;
    const rest = user_agent[slash + 1 ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
}

/// A JSON-RPC id as JSON text: what `respond` writes back.
fn idKey(a: std.mem.Allocator, id: Value) ![]const u8 {
    return switch (id) {
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        else => std.json.Stringify.valueAlloc(a, id, .{}),
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn field(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .null) null else x;
}
fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return if (x == .string) x.string else null;
}
fn int(v: Value, key: []const u8) ?i64 {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}
fn count(v: Value, key: []const u8) u64 {
    return @intCast(@max(0, int(v, key) orelse 0));
}

comptime {
    @import("iface").assertImplements(contract.Adapter.VTable, Codex);
}

/// `env` with `CODEX_HOME` set to a provider's `home`, replacing any
/// `CODEX_HOME` already in it. No `home`: `env` as it is.
pub fn withHome(a: std.mem.Allocator, env: []const contract.EnvVar, home: ?[]const u8) ![]const contract.EnvVar {
    const h = home orelse return env;
    var out: std.ArrayList(contract.EnvVar) = .empty;
    for (env) |e| if (!std.mem.eql(u8, e.name, "CODEX_HOME")) try out.append(a, e);
    try out.append(a, .{ .name = "CODEX_HOME", .value = h });
    return out.items;
}

test {
    _ = @import("codex_tests.zig");
}

const testing = std.testing;

test "codex: thread items map to venom tool kinds and statuses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: std.mem.Allocator, s: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{});
        }
    }.f;
    const read = try parse(a, "{\"type\":\"commandExecution\",\"id\":\"i1\",\"command\":\"cat a b\",\"commandActions\":[{\"type\":\"read\",\"path\":\"a\"},{\"type\":\"read\",\"path\":\"b\"}],\"status\":\"completed\",\"exitCode\":0}");
    try testing.expectEqualStrings("read", tool(read, "/w").?.kind);
    try testing.expectEqualStrings("ok", endStatus(read));
    const mixed = try parse(a, "{\"type\":\"commandExecution\",\"id\":\"i2\",\"command\":\"x\",\"commandActions\":[{\"type\":\"read\"},{\"type\":\"search\"}],\"status\":\"completed\",\"exitCode\":2}");
    try testing.expectEqualStrings("exec", tool(mixed, "/w").?.kind);
    try testing.expectEqualStrings("error", endStatus(mixed));
    const list = try parse(a, "{\"type\":\"commandExecution\",\"id\":\"i3\",\"command\":\"ls\",\"commandActions\":[{\"type\":\"listFiles\"}],\"status\":\"declined\"}");
    try testing.expectEqualStrings("list", tool(list, "/w").?.kind);
    try testing.expectEqualStrings("declined", endStatus(list));
    const edit = try parse(a, "{\"type\":\"fileChange\",\"id\":\"i4\",\"changes\":[{\"path\":\"src/a.zig\",\"kind\":\"update\",\"diff\":\"\"}],\"status\":\"failed\"}");
    try testing.expectEqualStrings("edit", tool(edit, "/w").?.kind);
    try testing.expectEqualStrings("src/a.zig", tool(edit, "/w").?.title);
    try testing.expectEqualStrings("error", endStatus(edit));
    try testing.expectEqualStrings("mcp", tool(try parse(a, "{\"type\":\"mcpToolCall\",\"id\":\"i5\",\"server\":\"venom\",\"tool\":\"agent.list\"}"), "/w").?.kind);
    try testing.expectEqualStrings("fetch", tool(try parse(a, "{\"type\":\"webSearch\",\"id\":\"i6\",\"query\":\"zig\"}"), "/w").?.kind);
    try testing.expect(tool(try parse(a, "{\"type\":\"agentMessage\",\"id\":\"i7\",\"text\":\"hi\"}"), "/w") == null);
}

test "codex: tool args per kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { item: []const u8, args: []const u8 };
    for ([_]Case{
        .{ .item = "{\"type\":\"commandExecution\",\"id\":\"i1\",\"command\":\"zig build\"}", .args = "{\"command\":\"zig build\",\"cwd\":\"/w\"}" },
        .{ .item = "{\"type\":\"commandExecution\",\"id\":\"i1\",\"command\":\"cat a\",\"cwd\":\"/x\",\"commandActions\":[{\"type\":\"read\",\"path\":\"a\"}]}", .args = "{\"path\":\"a\"}" },
        .{ .item = "{\"type\":\"commandExecution\",\"id\":\"i1\",\"command\":\"rg x src\",\"commandActions\":[{\"type\":\"search\",\"query\":\"x\",\"path\":\"src\"}]}", .args = "{\"path\":\"src\",\"query\":\"x\"}" },
        .{ .item = "{\"type\":\"fileChange\",\"id\":\"i2\",\"changes\":[{\"path\":\"n.zig\",\"kind\":{\"type\":\"add\"},\"diff\":\"+a\\n+b\\n\"},{\"path\":\"o.zig\",\"kind\":\"update\",\"diff\":\"--- o.zig\\n+++ o.zig\\n@@\\n-x\\n+y\\n\"}]}", .args = "{\"path\":\"n.zig\",\"change\":\"create\",\"added\":3,\"removed\":1}" },
        .{ .item = "{\"type\":\"fileChange\",\"id\":\"i2\",\"changes\":[{\"path\":\"d.zig\",\"kind\":\"delete\"}]}", .args = "{\"path\":\"d.zig\",\"change\":\"delete\",\"added\":0,\"removed\":0}" },
        .{ .item = "{\"type\":\"mcpToolCall\",\"id\":\"i3\",\"server\":\"venom\",\"tool\":\"agent_list\"}", .args = "{\"server\":\"venom\",\"tool\":\"agent_list\"}" },
        .{ .item = "{\"type\":\"webSearch\",\"id\":\"i4\",\"query\":\"zig\"}", .args = "{\"query\":\"zig\"}" },
        .{ .item = "{\"type\":\"collabAgentToolCall\",\"id\":\"i5\",\"tool\":\"spawnAgent\",\"receiverThreadIds\":[\"thr_c\"]}", .args = "{\"child_ref\":\"thr_c\"}" },
        .{ .item = "{\"type\":\"dynamicToolCall\",\"id\":\"i6\",\"tool\":\"x\"}", .args = "{}" },
    }) |case| {
        const v = try std.json.parseFromSliceLeaky(Value, a, case.item, .{});
        const got = try std.json.Stringify.valueAlloc(a, tool(v, "/w").?.args.?, .{ .emit_null_optional_fields = false });
        try testing.expectEqualStrings(case.args, got);
    }
    const fc = try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"fileChange\",\"changes\":[{\"diff\":\"+a\"},{\"diff\":\"-b\\n\"}]}", .{});
    try testing.expectEqualStrings("+a\n-b\n", (try bodyOf(a, fc)).?);
}

test "codex: plan windows merge sparsely, keep to the codex bucket and label by length" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: std.mem.Allocator, s: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{});
        }
    }.f;
    var plan: Plan = .{};
    try testing.expect(try plan.report(a) == null);
    plan.merge(try parse(a, "{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":31,\"windowDurationMins\":300,\"resetsAt\":1794063600},\"secondary\":{\"usedPercent\":12,\"windowDurationMins\":10080}}"));
    plan.merge(try parse(a, "{\"primary\":{\"usedPercent\":40}}"));
    plan.merge(try parse(a, "{\"limitId\":\"other\",\"primary\":{\"usedPercent\":99}}"));
    plan.setAccount("chatgpt");
    const r = (try plan.report(a)).?;
    try testing.expectEqualStrings("subscription", r.billing);
    try testing.expectEqual(@as(u32, 40), r.windows[0].used_pct);
    try testing.expectEqualStrings("5h", r.windows[0].label);
    try testing.expectEqualStrings("2026-11-07T15:00:00Z", r.windows[0].resets_at.?);
    try testing.expectEqualStrings("7d", r.windows[1].label);
    try testing.expect(r.windows[1].resets_at == null);
    try testing.expectEqualStrings("90m", try windowLabel(a, 90, "primary"));
    try testing.expectEqualStrings("primary", try windowLabel(a, null, "primary"));
    // A full read replaces: the window it leaves out is gone.
    plan.replace(try parse(a, "{\"rateLimits\":{\"limitId\":\"codex\",\"secondary\":{\"usedPercent\":5}}}"));
    try testing.expect(plan.windows[0].used_pct == null);
    try testing.expectEqual(@as(?i64, 5), plan.windows[1].used_pct);
    // The multi-bucket view wins; a read of another bucket changes nothing.
    plan.replace(try parse(a, "{\"rateLimits\":{\"limitId\":\"other\",\"primary\":{\"usedPercent\":99}},\"rateLimitsByLimitId\":{\"codex\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":7}}}}"));
    try testing.expectEqual(@as(?i64, 7), plan.windows[0].used_pct);
    plan.replace(try parse(a, "{\"rateLimits\":{\"limitId\":\"other\",\"primary\":{\"usedPercent\":99}}}"));
    try testing.expectEqual(@as(?i64, 7), plan.windows[0].used_pct);
    plan.setAccount("apiKey");
    try testing.expectEqualStrings("api_key", plan.billing);
    // A known account reports even with no windows.
    plan.windows = .{ .{}, .{} };
    try testing.expectEqual(@as(usize, 0), (try plan.report(a)).?.windows.len);
    plan.setAccount("gcp");
    try testing.expectEqualStrings("unknown", plan.billing);
    plan.setAccount(null);
    try testing.expectEqualStrings("unknown", plan.account);
}

test "codex: errors classify into limit, sign-in and turn failures" {
    try testing.expectEqualStrings("limit", classify("usageLimitExceeded", "x").reason);
    try testing.expectEqualStrings("failed.usage_limit", classify("rateLimitExceeded", "x").code);
    try testing.expectEqualStrings("unavailable.harness_not_signed_in", classify("unauthorized", "x").code);
    try testing.expectEqualStrings("failed.harness_turn", classify("serverOverloaded", "x").code);
    try testing.expectEqualStrings("x", classify(null, "x").code);
    try testing.expectEqualStrings("0.167.0", versionOf("codex_cli_rs/0.167.0 (Linux 7.3; x86_64) xterm"));
    try testing.expectEqualStrings("0.167.0", versionOf("codex_cli_rs/0.167.0"));
}

test "codex: venom's MCP server goes last on the app-server command line, with its socket in the env" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx = try Codex.initCommand(testing.allocator, "/opt/codex", &.{ "-c", "model=\"o3\"" });
    defer cx.deinit();
    const bare = try cx.start(a, .{ .agent = "a1", .cwd = "/w" });
    try testing.expectEqual(@as(usize, 4), bare.argv.len);
    try testing.expectEqual(@as(usize, 0), bare.env.len);

    cx.mcp = .{ .command = "/usr/bin/venom", .socket = "/run/v.sock" };
    const s = try cx.start(a, .{ .agent = "a1", .cwd = "/w" });
    const want = [_][]const u8{ "/opt/codex", "app-server", "-c", "model=\"o3\"", "-c", "mcp_servers.venom.command=\"/usr/bin/venom\"", "-c", "mcp_servers.venom.args=[\"mcp\"]", "-c", "mcp_servers.venom.env={VENOM_SOCKET=\"/run/v.sock\"}", "-c", "mcp_servers.venom.env_vars=[\"VENOM_TOKEN\"]" };
    try testing.expectEqual(want.len, s.argv.len);
    for (want, s.argv) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(@as(usize, 1), s.env.len);
    try testing.expectEqualStrings("VENOM_SOCKET", s.env[0].name);
    for (s.argv) |arg| try testing.expect(std.mem.indexOf(u8, arg, "vnt1.") == null);
}
