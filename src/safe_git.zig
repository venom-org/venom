//! Running git on a repo the daemon does not trust.
//!
//! A repo an agent can write to controls its own `.git/config`,
//! `.git/info/attributes`, `.gitattributes`, hooks and submodules. Plain
//! `git status` on it can run commands as the daemon user: a clean, smudge
//! or process filter (`filter.<x>.clean` with `* filter=x` in the
//! attributes) runs whenever git re-hashes a stat-dirty or racy-clean
//! tracked file, `core.fsmonitor` runs its hook, and a submodule's own
//! config does the same for the status git runs inside it.
//!
//! `run` is the one way the daemon runs git on such a repo. Every command
//! gets:
//!
//! - **No filters.** `core.attributesFile` and `--attr-source` cannot switch
//!   attributes off (`.git/info/attributes` still applies), so each filter
//!   the repo's config defines, and each its submodules' configs define, has
//!   its `clean`, `smudge` and `process` command emptied and `required`
//!   turned off with `-c` (an emptied required filter would make git fail).
//!   Git hands `-c` on to the status it runs in a submodule, and to the
//!   status that `git worktree remove` runs. A file's content then compares
//!   as it is on disk: a repo that needs a filter (git-lfs) reports its
//!   filtered files as changed, which for a safety check is the way to be
//!   wrong. The scan covers `dir`, `Options.also` (the work tree a
//!   `worktree remove` removes has its own config: `config.worktree`,
//!   `includeIf "gitdir:"`) and every populated submodule. It runs only for
//!   commands that read the work tree (`Options.reads_tree`). The config is
//!   read just before the command, so a write in between is the one thing
//!   this does not close.
//! - **Locked transport** for `lsRemoteHeads`: a repo's `core.sshCommand`,
//!   `core.gitProxy`, `remote.<n>.uploadpack`, `credential.helper` and
//!   `core.askPass` do not apply (environment
//!   and `--upload-pack`), and only the plain protocols are allowed, which
//!   also stops `remote.<n>.vcs` and `url.<x>.insteadOf` from reaching a
//!   remote helper such as `ext::`.
//! - **An explicit environment.** The daemon's own, minus every `GIT_*`
//!   variable (`GIT_DIR`, `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`,
//!   `GIT_CONFIG_PARAMETERS`, `GIT_EXTERNAL_DIFF`, ...) except the ssh
//!   program's, plus `GIT_TERMINAL_PROMPT=0`.
//! - **Hooks, fsmonitor, attributes file, auto-gc off** (`pins`), and
//!   `--no-replace-objects`.
//! - **An absolute deadline.** `std.process.run` restarts a duration
//!   timeout on every read, so a child that keeps printing is never cut off.
//!   Here the deadline is computed once, and a child past it is killed.
//!
//! A failure of any of that is a failed command (`ok == false`), never a
//! command run without the protection.
const std = @import("std");
const supervisor = @import("supervisor");
const isolation = @import("isolation.zig");

/// Settings a repo's config must not change for the daemon. All of them
/// turn something off or fix it to git's default.
pub const pins = [_][]const u8{
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.attributesFile=/dev/null",
    "-c", "diff.ignoreSubmodules=none",
    "-c", "gc.auto=0",
    "-c", "maintenance.auto=false",
    "-c", "protocol.ext.allow=never",
};

pub const Options = struct {
    /// This command's budget.
    timeout_ms: i64,
    /// `supervisor.monotonicMs()` the command must not outlive, if sooner.
    until_ms: ?i64 = null,
    /// The command reads files of the work tree (`status`, `worktree
    /// remove`), so git may run a filter on them: the filter scan is made.
    /// Leave it off for the rest (refs, config, `worktree list`), which
    /// spares them the scan's processes.
    reads_tree: bool = true,
    /// More directories the command works in besides `dir`, scanned too:
    /// the worktree `git worktree remove` removes.
    also: []const []const u8 = &.{},
    /// Transport commands of the repo do not apply (`lsRemoteHeads`).
    lock_transport: bool = false,
    /// More `-c key=value` pairs and the like, after `pins`: what the
    /// caller's answers depend on.
    config: []const []const u8 = &.{},
    stdout_limit: usize = 1 << 24,
    stderr_limit: usize = 1 << 16,
};

/// Runs `git <args>` in `dir`. Only an out-of-memory is an error.
pub fn run(a: std.mem.Allocator, io: std.Io, dir: []const u8, args: []const []const u8, o: Options) error{OutOfMemory}!isolation.Ran {
    const now = supervisor.monotonicMs();
    var left = o.timeout_ms;
    if (o.until_ms) |u| left = @min(left, u - now);
    if (left <= 0) return failed(a, "Timeout");
    const deadline: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(left), .clock = .awake }) };

    var env = try childEnv(a);
    defer env.deinit();
    if (o.lock_transport) try lockTransport(a, &env);

    var filters: std.ArrayList([]const u8) = .empty;
    if (o.reads_tree) {
        if (try filterOverrides(a, io, &env, dir, deadline, &filters, 0)) |why| return failed(a, why);
        for (o.also) |more| if (try filterOverrides(a, io, &env, more, deadline, &filters, 0)) |why| return failed(a, why);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "--no-replace-objects", "-C", dir });
    try argv.appendSlice(a, &pins);
    try argv.appendSlice(a, filters.items);
    if (o.lock_transport) try argv.appendSlice(a, &transport_pins);
    try argv.appendSlice(a, o.config);
    try argv.appendSlice(a, args);
    return exec(a, io, &env, argv.items, deadline, o.stdout_limit, o.stderr_limit);
}

/// What a remote may be reached by: the plain transports. Everything else
/// (`ext::`, remote helpers) is off, whatever `url.<x>.insteadOf` says.
const transport_pins = [_][]const u8{
    "-c", "protocol.allow=never",
    "-c", "protocol.file.allow=always",
    "-c", "protocol.ssh.allow=always",
    "-c", "protocol.https.allow=always",
    "-c", "protocol.http.allow=always",
    "-c", "protocol.git.allow=always",
    // Empty resets the helper list, `credential.<url>.helper` included.
    "-c", "credential.helper=",
    "-c", "core.askPass=",
    "-c", "credential.interactive=never",
};

/// Environment settings win over `core.sshCommand` and `core.gitProxy`:
/// the daemon's own ssh command (else `ssh`), and no proxy command.
fn lockTransport(a: std.mem.Allocator, env: *std.process.Environ.Map) error{OutOfMemory}!void {
    if (env.get("GIT_SSH_COMMAND") == null) {
        if (env.get("GIT_SSH")) |prog| {
            const quoted = try std.fmt.allocPrint(a, "'{s}'", .{prog});
            defer a.free(quoted);
            try env.put("GIT_SSH_COMMAND", quoted);
        } else try env.put("GIT_SSH_COMMAND", "ssh");
    }
    try env.put("GIT_PROXY_COMMAND", "");
    // Overrides every `protocol.<x>.allow` of the repo's config, which the
    // `-c` pins below cannot (the repo's `always` would beat `never`).
    try env.put("GIT_ALLOW_PROTOCOL", "file:ssh:https:http:git");
    try env.put("GIT_ASKPASS", "");
    try env.put("SSH_ASKPASS", "");
}

/// `git ls-remote --heads -- <remote>` of the repo in `dir`, with the
/// transport locked (`Options.lock_transport` is set here).
pub fn lsRemoteHeads(a: std.mem.Allocator, io: std.Io, dir: []const u8, remote: []const u8, o: Options) error{OutOfMemory}!isolation.Ran {
    var opts = o;
    opts.reads_tree = false;
    opts.lock_transport = true;
    return run(a, io, dir, &.{ "ls-remote", "--upload-pack=git-upload-pack", "--heads", "--", remote }, opts);
}

fn failed(a: std.mem.Allocator, why: []const u8) error{OutOfMemory}!isolation.Ran {
    return .{ .ok = false, .stdout = "", .stderr = try std.fmt.allocPrint(a, "git: {s}", .{why}) };
}

fn exec(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, deadline: std.Io.Timeout, stdout_limit: usize, stderr_limit: usize) error{OutOfMemory}!isolation.Ran {
    return (try execCode(a, io, env, argv, deadline, stdout_limit, stderr_limit)).ran;
}

const Coded = struct {
    ran: isolation.Ran,
    /// Null: it did not exit (timeout, signal, not started).
    code: ?u8,
};

fn execCode(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, deadline: std.Io.Timeout, stdout_limit: usize, stderr_limit: usize) error{OutOfMemory}!Coded {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .environ_map = env,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(stderr_limit),
        .timeout = deadline,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .ran = try failed(a, @errorName(err)), .code = null },
    };
    return .{ .ran = .{ .ok = r.term.success(), .stdout = r.stdout, .stderr = r.stderr }, .code = switch (r.term) {
        .exited => |c| c,
        else => null,
    } };
}

/// The environment of every git child: the daemon's without `GIT_*`
/// (bar the ssh program's, which is the user's own choice of transport),
/// and with prompts off. Caller deinits.
pub fn childEnv(a: std.mem.Allocator) error{OutOfMemory}!std.process.Environ.Map {
    var env = std.process.Environ.Map.init(a);
    errdefer env.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const kv = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        if (std.mem.startsWith(u8, key, "GIT_") and !std.mem.eql(u8, key, "GIT_SSH") and !std.mem.eql(u8, key, "GIT_SSH_COMMAND")) continue;
        try env.put(key, kv[eq + 1 ..]);
    }
    try env.put("GIT_TERMINAL_PROMPT", "0");
    return env;
}

const max_submodule_depth = 8;

/// Appends to `out` the `-c` that turn off every filter `dir`'s config
/// (system, global, repo, worktree) and, recursively, its populated
/// submodules' configs define. A reason if that could not be established:
/// the command then does not run.
fn filterOverrides(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8, deadline: std.Io.Timeout, out: *std.ArrayList([]const u8), depth: usize) error{OutOfMemory}!?[]const u8 {
    if (depth > max_submodule_depth) return "submodules nested too deep";
    const base = [_][]const u8{ "git", "-C", dir, "-c", "core.fsmonitor=false" };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &base);
    try argv.appendSlice(a, &.{ "config", "--name-only", "--get-regexp", "^filter\\..+\\.(clean|smudge|process|required)$" });
    const cfg = try execCode(a, io, env, argv.items, deadline, 1 << 20, 1 << 16);
    // Exit 1 alone is "no such key". Anything else, a timeout or a crash
    // included, leaves the filters unknown.
    if (!cfg.ran.ok and cfg.code != 1) return "could not read the filter config";
    var keys = std.mem.tokenizeScalar(u8, cfg.ran.stdout, '\n');
    while (keys.next()) |key| {
        if (std.mem.indexOfScalar(u8, key, '=') != null) return "a filter name git cannot override";
        const dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse return "a filter name git cannot override";
        const name = key["filter.".len..dot];
        const first = try std.fmt.allocPrint(a, "filter.{s}.clean=", .{name});
        if (contains(out.items, first)) continue;
        try out.appendSlice(a, &.{ "-c", first });
        for ([_][]const u8{ "smudge=", "process=", "required=false" }) |tail|
            try out.appendSlice(a, &.{ "-c", try std.fmt.allocPrint(a, "filter.{s}.{s}", .{ name, tail }) });
    }

    // Is `dir` a work tree? A bare repo has nothing to descend into; if git
    // cannot say, nothing is known.
    argv.clearRetainingCapacity();
    try argv.appendSlice(a, &base);
    try argv.appendSlice(a, &.{ "rev-parse", "--is-inside-work-tree" });
    const inside = try exec(a, io, env, argv.items, deadline, 1 << 10, 1 << 16);
    if (!inside.ok) return "could not tell whether this is a work tree";
    const answer = std.mem.trim(u8, inside.stdout, " \n");
    if (std.mem.eql(u8, answer, "false")) return null;
    if (!std.mem.eql(u8, answer, "true")) return "could not tell whether this is a work tree";

    var subs: std.ArrayList([]const u8) = .empty;
    if (try gitlinks(a, io, env, dir, deadline, &subs)) |why| return why;
    for (subs.items) |rel| {
        const sub = try std.fs.path.join(a, &.{ dir, rel });
        const marker = try std.fs.path.join(a, &.{ sub, ".git" });
        std.Io.Dir.cwd().access(io, marker, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return "could not look for a submodule",
        };
        if (try filterOverrides(a, io, env, sub, deadline, out, depth + 1)) |why| return why;
    }
    return null;
}

/// The paths of `dir`'s gitlinks (mode 160000), from the index read as a
/// stream: an index of any size costs only the paths found. A reason if
/// the list is not complete.
fn gitlinks(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8, deadline: std.Io.Timeout, out: *std.ArrayList([]const u8)) error{OutOfMemory}!?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "-C", dir, "-c", "core.fsmonitor=false", "ls-files", "--stage", "-z" },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return "could not list the index";
    defer child.kill(io);

    var buf: std.Io.File.MultiReader.Buffer(1) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, buf.toStreams(), &.{child.stdout.?});
    defer mr.deinit();
    const r = mr.reader(0);

    while (mr.fill(4096, deadline)) |_| {
        while (std.mem.indexOfScalar(u8, r.buffered(), 0)) |end| {
            const line = r.buffered()[0..end];
            if (std.mem.startsWith(u8, line, "160000 ")) {
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return "could not read the index";
                try out.append(a, try a.dupe(u8, line[tab + 1 ..]));
            }
            r.toss(end + 1);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return "could not list the index",
    }
    mr.checkAnyError() catch return "could not list the index";
    if (r.bufferedLen() != 0) return "could not read the index";
    const term = child.wait(io) catch return "could not list the index";
    if (!term.success()) return "could not list the index";
    return null;
}

fn contains(list: []const []const u8, want: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, want)) return true;
    return false;
}
