//! Harness discovery: is a vendor CLI on `PATH`, which version, is it signed in, does
//! its protocol answer. `doctor` and `harness.list|show` report these facts.
//!
//! venom never handles vendor credentials. Sign-in state only ever comes
//! from the harness's own status command, and only a yes or no and a plan or
//! method word are kept: no email, organization, key or token from its
//! output is stored or shown (`account/read` is not even parsed beyond
//! "it answered"). Nothing here reads a vendor's files.
//!
//! Every command is read-only and starts no model turn or token spend. They
//! block, so this runs off the reactor (`harnesses.Discovery`), with each
//! command given `command_timeout_ms` and a harness `budget_ms` overall.
//! Test builds never run a real vendor CLI: the facts then stop at
//! `found`.
const std = @import("std");
const builtin = @import("builtin");
const supervisor = @import("supervisor");
const guard = @import("guard.zig");
const process = @import("process.zig");
const version = @import("version.zig");
const Process = process.Process;
const c = std.c;

pub const command_timeout_ms: u32 = 5_000;
pub const budget_ms: u32 = 10_000;

pub const Vendor = struct {
    /// The harness id.
    harness: []const u8,
    /// The executable, when `harness.<h>.path` does not name one.
    exe: []const u8,
    /// Install and update, from the vendor's docs. Fixes for `doctor`.
    install: []const u8,
    update: []const u8,
    /// Arguments of the harness's own commands: the read-only status
    /// command and the sign-in command the user runs.
    status: []const []const u8,
    sign_in: []const []const u8,
    parse_status: *const fn (Output) SignIn,
    protocol: *const fn (gpa: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, cancel: ?*const std.atomic.Value(bool)) anyerror!Protocol,
};

pub const claude: Vendor = .{
    .harness = "claude-code",
    .exe = "claude",
    .install = "curl -fsSL https://claude.ai/install.sh | bash",
    .update = "claude update",
    .status = &.{ "auth", "status", "--json" },
    .sign_in = &.{ "auth", "login" },
    .parse_status = claudeStatus,
    .protocol = claudeProtocol,
};

pub const codex: Vendor = .{
    .harness = "codex",
    .exe = "codex",
    .install = "npm install -g @openai/codex",
    .update = "npm install -g @openai/codex",
    .status = &.{ "login", "status" },
    .sign_in = &.{"login"},
    .parse_status = codexStatus,
    .protocol = codexProtocol,
};

/// What the harness's status command said. `signed_in` null: it could not
/// tell (it failed, or its output is not what the adapter knows). `detail` is
/// a plan or method word, static or checked by `word`, never an identity.
pub const SignIn = struct { signed_in: ?bool = null, detail: ?[]const u8 = null };

/// `problem` is static text.
pub const Protocol = union(enum) { not_checked, ok, failed: []const u8 };

pub const Facts = struct {
    /// The absolute path `exe` resolved to; null when it is not on `PATH`.
    path: ?[]const u8 = null,
    version: version.Detection = .missing,
    sign_in: SignIn = .{},
    protocol: Protocol = .not_checked,

    pub fn found(self: Facts) bool {
        return self.path != null;
    }
};

pub const Options = struct {
    /// What `harness.<h>.path` names, else `Vendor.exe`.
    exe: []const u8,
    /// What follows the executable in the harness's protocol command
    /// (`harness.<h>.extra_args` applies to it).
    protocol_args: []const []const u8 = &.{},
    /// The value of `PATH` to search.
    path_env: ?[]const u8,
    command_timeout_ms: u32 = command_timeout_ms,
    budget_ms: u32 = budget_ms,
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// Finds `exe` and asks it everything. Strings are in `out`. Blocks, at most
/// about `budget_ms`.
pub fn discover(gpa: std.mem.Allocator, out: std.mem.Allocator, vendor: Vendor, o: Options) !Facts {
    var facts: Facts = .{ .path = try resolve(out, o.exe, o.path_env) };
    const path = facts.path orelse return facts;
    if (builtin.is_test and !guard.spawnAllowed(path, guard.optedIn)) return facts;
    const deadline = supervisor.monotonicMs() + o.budget_ms;
    const left = struct {
        fn f(end: i64, most: u32) u32 {
            return @intCast(@max(0, @min(end - supervisor.monotonicMs(), most)));
        }
    }.f;

    facts.version = try version.detectCancellable(gpa, out, path, left(deadline, o.command_timeout_ms), o.cancel);

    facts.sign_in = try askSignIn(gpa, vendor, path, left(deadline, o.command_timeout_ms), o.cancel);

    const protocol_argv = try std.mem.concat(out, []const u8, &.{ &.{path}, o.protocol_args });
    facts.protocol = try vendor.protocol(gpa, protocol_argv, left(deadline, o.command_timeout_ms), o.cancel);
    return facts;
}

/// `agent.spawn`'s question: only the status command, not
/// the version and protocol checks of `discover`. `signed_in` null when the
/// harness is not on `PATH` or its status command cannot tell. Blocks, at most
/// about `command_timeout_ms`.
pub fn signIn(gpa: std.mem.Allocator, vendor: Vendor, o: Options) !SignIn {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const path = try resolve(scratch.allocator(), o.exe, o.path_env) orelse return .{};
    if (builtin.is_test and !guard.spawnAllowed(path, guard.optedIn)) return .{};
    return askSignIn(gpa, vendor, path, o.command_timeout_ms, o.cancel);
}

/// Runs the status command. Its output can name the account, so it lives in
/// a scratch arena gone by the return; `SignIn` holds static text only.
fn askSignIn(gpa: std.mem.Allocator, vendor: Vendor, path: []const u8, timeout_ms: u32, cancel: ?*const std.atomic.Value(bool)) !SignIn {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const argv = try std.mem.concat(a, []const u8, &.{ &.{path}, vendor.status });
    const got = (try capture(gpa, a, argv, timeout_ms, cancel)) orelse return .{};
    return vendor.parse_status(got);
}

/// Where `execvp` would find `exe`: on `path_env` for a bare name, else `exe`
/// itself. Null when it is not there, is a directory, or is not executable.
pub fn resolve(out: std.mem.Allocator, exe: []const u8, path_env: ?[]const u8) !?[]const u8 {
    if (exe.len == 0) return null;
    if (std.mem.indexOfScalar(u8, exe, '/') != null) return if (try runnable(out, exe)) try out.dupe(u8, exe) else null;
    var dirs = std.mem.tokenizeScalar(u8, path_env orelse return null, ':');
    while (dirs.next()) |dir| {
        const candidate = try std.fs.path.join(out, &.{ dir, exe });
        if (try runnable(out, candidate)) return candidate;
    }
    return null;
}

fn runnable(a: std.mem.Allocator, path: []const u8) !bool {
    const z = try a.dupeSentinel(u8, path, 0);
    if (c.access(z, c.X_OK) != 0) return false;
    const dir = c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir >= 0) {
        _ = c.close(dir);
        return false;
    }
    return true;
}

/// What a finished command printed. `exit` is null when it did not finish in
/// time.
pub const Output = struct { exit: ?process.Exit = null, stdout: []const u8 = "", stderr: []const u8 = "" };

/// Runs `argv` with no stdin until it exits or `timeout_ms` passes, then kills
/// its group, so a child it left behind holding the pipes neither delays the
/// answer nor outlives it. Null when it cannot be started.
fn capture(gpa: std.mem.Allocator, out: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, cancel: ?*const std.atomic.Value(bool)) !?Output {
    var leaders: supervisor.Leaders = .init(gpa, .{});
    defer leaders.deinit();
    var p = Process.spawn(gpa, &leaders, .{ .argv = argv }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer p.deinit();
    p.closeInput();
    const deadline = supervisor.monotonicMs() + timeout_ms;
    var finished = false;
    while (true) {
        const open = p.pump() catch break;
        if (!open) {
            finished = true;
            break;
        }
        if (cancel) |flag| if (flag.load(.acquire)) break;
        const left = deadline - supervisor.monotonicMs();
        if (left <= 0) break;
        var fds = [_]c.pollfd{
            .{ .fd = p.stdout, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = p.stderr, .events = c.POLL.IN, .revents = 0 },
            // Readable once it exited; not reaped yet, so `stop` can still
            // reach its group. Without pidfds (-1, ignored) this is the timeout.
            .{ .fd = p.leader.pollFd() orelse -1, .events = c.POLL.IN, .revents = 0 },
        };
        _ = c.poll(&fds, fds.len, @intCast(@min(left, 100)));
        if (fds[2].revents != 0) {
            // What it wrote before exiting is in the pipes.
            _ = p.pump() catch {};
            finished = true;
            break;
        }
    }
    try version.stop(&p, &leaders);
    var result: Output = .{ .stdout = try out.dupe(u8, p.out.items[p.out_head..]), .stderr = try out.dupe(u8, p.stderrTail()) };
    if (finished) if (p.leader.status) |st| {
        result.exit = process.exitOf(st);
    };
    return result;
}

/// `claude auth status --json`: `loggedIn`, whatever
/// the exit code says (1 when signed out). Reads `subscriptionType` or else
/// `authMethod` for the detail; the rest (email, organization) is dropped.
pub fn claudeStatus(got: Output) SignIn {
    var mem: [64 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    const root = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), got.stdout, .{}) catch return .{};
    if (root != .object) return .{};
    const logged_in = root.object.get("loggedIn") orelse return .{};
    if (logged_in != .bool) return .{};
    if (!logged_in.bool) return .{ .signed_in = false };
    for ([_][]const u8{ "subscriptionType", "authMethod" }) |key| {
        const v = root.object.get(key) orelse continue;
        if (v != .string) continue;
        if (word(v.string)) |known| return .{ .signed_in = true, .detail = known };
    }
    return .{ .signed_in = true };
}

/// The plan and method words `claude auth status` is known to print, as
/// static text: the parse buffer does not outlive `claudeStatus`, and an
/// unknown value is left out rather than echoed.
fn word(value: []const u8) ?[]const u8 {
    for ([_][]const u8{ "free", "pro", "max", "team", "enterprise", "claude.ai", "console", "api_key", "bedrock", "vertex", "foundry" }) |known| {
        if (std.mem.eql(u8, value, known)) return known;
    }
    return null;
}

/// `codex login status`: exit 0 and "Logged in using ...", or a non-zero exit
/// and "Not logged in"; it prints to stdout or stderr depending on version.
/// The line itself is never kept, since it can show a masked API key.
pub fn codexStatus(got: Output) SignIn {
    const exit = got.exit orelse return .{};
    for ([_][]const u8{ got.stdout, got.stderr }) |text| {
        if (says(text, "not logged in")) return .{ .signed_in = false };
    }
    if (!exit.ok()) return .{};
    for ([_][]const u8{ got.stdout, got.stderr }) |text| {
        if (!says(text, "logged in")) continue;
        const detail: ?[]const u8 = if (says(text, "chatgpt"))
            "ChatGPT"
        else if (says(text, "api key"))
            "API key"
        else
            null;
        return .{ .signed_in = true, .detail = detail };
    }
    return .{};
}

fn says(text: []const u8, phrase: []const u8) bool {
    if (text.len < phrase.len) return false;
    for (0..text.len - phrase.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(text[i..][0..phrase.len], phrase)) return true;
    }
    return false;
}

/// `claude --help` lists what the adapter passes.
/// `--permission-prompt-tool` is hidden from `--help`, so it is not required.
fn claudeProtocol(gpa: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, cancel: ?*const std.atomic.Value(bool)) anyerror!Protocol {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const got = (try capture(gpa, a, try std.mem.concat(a, []const u8, &.{ argv[0..1], &.{"--help"} }), timeout_ms, cancel)) orelse return .{ .failed = "--help could not be started" };
    const exit = got.exit orelse return .{ .failed = "--help did not finish in time" };
    if (!exit.ok()) return .{ .failed = "--help failed" };
    for ([_]struct { flag: []const u8, problem: []const u8 }{
        .{ .flag = "--input-format", .problem = "--help does not list --input-format" },
        .{ .flag = "--session-id", .problem = "--help does not list --session-id" },
        .{ .flag = "--permission-prompts", .problem = "--help does not list --permission-prompts" },
    }) |want| if (std.mem.indexOf(u8, got.stdout, want.flag) == null) return .{ .failed = want.problem };
    return .ok;
}

/// Starts `codex app-server`, `initialize`,
/// `account/read`, exit. Only "it answered without an error" is kept.
fn codexProtocol(gpa: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, cancel: ?*const std.atomic.Value(bool)) anyerror!Protocol {
    var leaders: supervisor.Leaders = .init(gpa, .{});
    defer leaders.deinit();
    var p = Process.spawn(gpa, &leaders, .{ .argv = argv }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .failed = "app-server could not be started" };
    };
    defer p.deinit();
    defer version.stop(&p, &leaders) catch {};
    p.write("{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"venom\",\"title\":\"venom\",\"version\":\"0.0.0\"}}}\n") catch return .{ .failed = "app-server exited at once" };
    const deadline = supervisor.monotonicMs() + timeout_ms;
    while (true) {
        const open = p.pump() catch return .{ .failed = "app-server printed an oversized line" };
        while (p.nextLine()) |line| switch (reply(gpa, line)) {
            .other => {},
            .failed => return .{ .failed = "app-server answered with an error" },
            .answered => |id| switch (id) {
                1 => p.write("{\"method\":\"initialized\"}\n{\"method\":\"account/read\",\"id\":2,\"params\":{\"refreshToken\":false}}\n") catch return .{ .failed = "app-server exited during its handshake" },
                2 => return .ok,
                else => {},
            },
        };
        if (!open) return .{ .failed = "app-server exited during its handshake" };
        if (cancel) |flag| if (flag.load(.acquire)) return .not_checked;
        const left = deadline - supervisor.monotonicMs();
        if (left <= 0) return .{ .failed = "app-server did not answer in time" };
        var fds = [_]c.pollfd{
            .{ .fd = p.stdout, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = p.stderr, .events = c.POLL.IN, .revents = 0 },
        };
        _ = c.poll(&fds, fds.len, @intCast(@min(left, 100)));
    }
}

const Reply = union(enum) { other, failed, answered: i64 };

/// A JSON-RPC response's id and outcome; anything else is `other`.
fn reply(gpa: std.mem.Allocator, line: []const u8) Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return .other;
    defer parsed.deinit();
    if (parsed.value != .object) return .other;
    const id = parsed.value.object.get("id") orelse return .other;
    if (id != .integer) return .other;
    if (parsed.value.object.get("error") != null) return .failed;
    return if (parsed.value.object.get("result") != null) .{ .answered = id.integer } else .other;
}

const testing = std.testing;

const Bin = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,

    fn init() !Bin {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator) };
    }

    fn deinit(self: *Bin) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn add(self: *Bin, name: []const u8, script: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = script });
        const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ self.dir, name }, 0);
        defer testing.allocator.free(path);
        if (c.chmod(path, 0o755) != 0) return error.ChmodFailed;
    }
};

test "discovery: resolve searches PATH like exec does" {
    var bin = try Bin.init();
    defer bin.deinit();
    try bin.add("tool", "#!/bin/sh\n");
    try bin.tmp.dir.writeFile(testing.io, .{ .sub_path = "plain", .data = "" });
    try bin.tmp.dir.createDir(testing.io, "folder", .default_dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool = try std.fmt.allocPrint(a, "{s}/tool", .{bin.dir});
    try testing.expectEqualStrings(tool, (try resolve(a, "tool", try std.fmt.allocPrint(a, "/nonexistent::{s}", .{bin.dir}))).?);
    try testing.expectEqualStrings(tool, (try resolve(a, tool, null)).?);
    try testing.expect((try resolve(a, "tool", "/nonexistent")) == null);
    try testing.expect((try resolve(a, "tool", null)) == null);
    // Not executable, and a directory that is.
    try testing.expect((try resolve(a, "plain", bin.dir)) == null);
    try testing.expect((try resolve(a, "folder", bin.dir)) == null);
    try testing.expect((try resolve(a, "", bin.dir)) == null);
}

test "discovery: sign-in state keeps a yes or no and a known word, never an identity" {
    const signed_in = claudeStatus(.{ .exit = .{ .code = 0 }, .stdout = "{\n \"loggedIn\": true, \"email\": \"me@example.com\", \"orgName\": \"Org\", \"authMethod\": \"claude.ai\", \"subscriptionType\": \"pro\"\n}\n" });
    try testing.expectEqual(@as(?bool, true), signed_in.signed_in);
    try testing.expectEqualStrings("pro", signed_in.detail.?);
    try testing.expectEqualStrings("claude.ai", claudeStatus(.{ .stdout = "{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}" }).detail.?);
    // An unknown value is not echoed: it could be anything.
    const unknown = claudeStatus(.{ .stdout = "{\"loggedIn\":true,\"subscriptionType\":\"me@example.com\"}" });
    try testing.expectEqual(@as(?bool, true), unknown.signed_in);
    try testing.expect(unknown.detail == null);
    // Exit 1 when signed out still says so.
    try testing.expectEqual(@as(?bool, false), claudeStatus(.{ .exit = .{ .code = 1 }, .stdout = "{\"loggedIn\":false}" }).signed_in);
    for ([_][]const u8{ "", "not json", "[]", "{}", "{\"loggedIn\":\"yes\"}" }) |text| {
        try testing.expect(claudeStatus(.{ .exit = .{ .code = 1 }, .stdout = text }).signed_in == null);
    }

    try testing.expectEqualStrings("ChatGPT", codexStatus(.{ .exit = .{ .code = 0 }, .stdout = "Logged in using ChatGPT\n" }).detail.?);
    const key = codexStatus(.{ .exit = .{ .code = 0 }, .stderr = "Logged in using an API key - sk-abc***xyz\n" });
    try testing.expectEqual(@as(?bool, true), key.signed_in);
    try testing.expectEqualStrings("API key", key.detail.?);
    try testing.expectEqual(@as(?bool, false), codexStatus(.{ .exit = .{ .code = 1 }, .stderr = "Not logged in\n" }).signed_in);
    // It failed, printed something else, or did not finish: unknown.
    try testing.expect(codexStatus(.{ .exit = .{ .code = 2 }, .stderr = "unknown command\n" }).signed_in == null);
    try testing.expect(codexStatus(.{ .exit = .{ .code = 0 }, .stdout = "0.167.0\n" }).signed_in == null);
    try testing.expect(codexStatus(.{ .stdout = "Logged in using ChatGPT\n" }).signed_in == null);
}

test "discovery: facts from fake binaries on a temp PATH, hangs bounded, nothing kept from the account" {
    process.ignoreSigpipe();
    var bin = try Bin.init();
    defer bin.deinit();
    try bin.add("claude", @embedFile("../testdata/harness-bin/claude"));
    try bin.add("codex", @embedFile("../testdata/harness-bin/codex"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cc = try discover(testing.allocator, a, claude, .{ .exe = claude.exe, .path_env = bin.dir });
    try testing.expect(cc.found());
    try testing.expect(std.mem.startsWith(u8, cc.path.?, bin.dir));
    try testing.expectEqualStrings("2.1.319", cc.version.found);
    try testing.expectEqual(@as(?bool, true), cc.sign_in.signed_in);
    try testing.expectEqualStrings("max", cc.sign_in.detail.?);
    try testing.expect(cc.protocol == .ok);

    const cx = try discover(testing.allocator, a, codex, .{ .exe = codex.exe, .protocol_args = &.{"app-server"}, .path_env = bin.dir });
    try testing.expectEqualStrings("0.167.0", cx.version.found);
    try testing.expectEqual(@as(?bool, true), cx.sign_in.signed_in);
    try testing.expectEqualStrings("API key", cx.sign_in.detail.?);
    try testing.expect(cx.protocol == .ok);

    // Not on PATH: nothing else is tried.
    const gone = try discover(testing.allocator, a, codex, .{ .exe = codex.exe, .path_env = "/nonexistent" });
    try testing.expect(!gone.found());
    try testing.expect(gone.sign_in.signed_in == null and gone.protocol == .not_checked);

    // claude: --permission-prompt-tool need not be listed; the others must.
    try bin.add("claude", "#!/bin/sh\necho '--input-format --session-id'\n");
    const old = try discover(testing.allocator, a, claude, .{ .exe = claude.exe, .path_env = bin.dir });
    try testing.expectEqualStrings("--help does not list --permission-prompts", old.protocol.failed);
    try testing.expect(old.sign_in.signed_in == null);

    // codex: an error answer, and a server that never answers.
    try bin.add("codex", "#!/bin/sh\nread -r line\necho '{\"id\":1,\"error\":{\"code\":-1,\"message\":\"no\"}}'\nread -r line\n");
    const refused = try discover(testing.allocator, a, codex, .{ .exe = codex.exe, .protocol_args = &.{"app-server"}, .path_env = bin.dir, .command_timeout_ms = 300 });
    try testing.expectEqualStrings("app-server answered with an error", refused.protocol.failed);

    try bin.add("codex", "#!/bin/sh\nexec sleep 30\n");
    const t0 = supervisor.monotonicMs();
    const hung = try discover(testing.allocator, a, codex, .{ .exe = codex.exe, .protocol_args = &.{"app-server"}, .path_env = bin.dir, .command_timeout_ms = 200, .budget_ms = 500 });
    try testing.expect(supervisor.monotonicMs() - t0 < 5_000);
    try testing.expect(hung.found());
    try testing.expect(hung.version == .unreadable);
    try testing.expect(hung.sign_in.signed_in == null);
    try testing.expectEqualStrings("app-server did not answer in time", hung.protocol.failed);
}

test "discovery: the status command's output is not kept" {
    process.ignoreSigpipe();
    var bin = try Bin.init();
    defer bin.deinit();
    try bin.add("claude", @embedFile("../testdata/harness-bin/claude"));
    try bin.add("codex", @embedFile("../testdata/harness-bin/codex"));
    var mem = std.mem.zeroes([64 * 1024]u8);
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    const cc = try discover(testing.allocator, fba.allocator(), claude, .{ .exe = claude.exe, .path_env = bin.dir });
    try testing.expectEqualStrings("max", cc.sign_in.detail.?);
    const cx = try discover(testing.allocator, fba.allocator(), codex, .{ .exe = codex.exe, .protocol_args = &.{"app-server"}, .path_env = bin.dir });
    try testing.expectEqualStrings("API key", cx.sign_in.detail.?);
    try testing.expect(std.mem.indexOf(u8, &mem, "fake-secret") == null);
}

test "discovery: a child left holding the status command's pipes neither delays it nor survives" {
    process.ignoreSigpipe();
    var bin = try Bin.init();
    defer bin.deinit();
    try bin.add("codex",
        \\#!/bin/sh
        \\case "$*" in
        \\'login status')
        \\    /bin/sleep 30 &
        \\    echo $! > "$0.pid"
        \\    echo 'Logged in using ChatGPT'
        \\    ;;
        \\esac
        \\
    );
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t0 = supervisor.monotonicMs();
    const facts = try discover(testing.allocator, arena.allocator(), codex, .{ .exe = codex.exe, .path_env = bin.dir });
    try testing.expect(supervisor.monotonicMs() - t0 < 3_000);
    try testing.expectEqual(@as(?bool, true), facts.sign_in.signed_in);
    try testing.expectEqualStrings("ChatGPT", facts.sign_in.detail.?);

    var buf: [32]u8 = undefined;
    const text = try bin.tmp.dir.readFile(testing.io, "codex.pid", &buf);
    const pid = try std.fmt.parseInt(c.pid_t, std.mem.trim(u8, text, " \n"), 10);
    // Killed; whoever inherited it may take a moment to reap it.
    const end = supervisor.monotonicMs() + 2_000;
    while (c.kill(pid, @fromBackingInt(@intCast(0))) == 0 and !isZombie(pid)) {
        if (supervisor.monotonicMs() > end) return error.ChildSurvived;
        _ = c.poll(&[_]c.pollfd{}, 0, 20);
    }
}

fn isZombie(pid: c.pid_t) bool {
    var path: [64]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&path, "/proc/{d}/stat", .{pid}, 0) catch return false;
    const fd = c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return true;
    defer _ = c.close(fd);
    var buf: [256]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return true;
    const close = std.mem.lastIndexOfScalar(u8, buf[0..@intCast(n)], ')') orelse return false;
    return close + 2 < n and buf[close + 2] == 'Z';
}

test "discovery: the fakes print the versions the adapters were tested with" {
    const claude_code = @import("claude_code.zig");
    const codex_adapter = @import("codex.zig");
    try testing.expect(std.mem.indexOf(u8, @embedFile("../testdata/harness-bin/claude"), "'" ++ claude_code.tested_version ++ " (Claude Code)'") != null);
    try testing.expect(std.mem.indexOf(u8, @embedFile("../testdata/harness-bin/codex"), "'codex-cli " ++ codex_adapter.tested_version ++ "'") != null);
}
