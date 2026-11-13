//! Standing "allow always" decisions (inbox key `a`): the pure
//! part.
//!
//! **Narrowest grant.** Every approval is stamped with the narrowest grant
//! that covers it, from the tool call it belongs to (`call`):
//!
//! - an `exec` call: `exec:<program>`, the first word of its command
//!   (leading `NAME=value` assignments skipped), as in the inbox's
//!   "Bash wants `zig build test`; grant `exec:zig`", narrowed for risky
//!   commands (below);
//! - any other call with a title: `<kind>:<title>` (`edit:src/proto.zig`);
//! - any other call without a title: `tool:<name>`.
//!
//! A request with no known call has no grant, and neither has an `exec`
//! call with no command or a command the harness cut short (a title ending
//! in `…`, see `truncated`): it can be allowed once, not always.
//!
//! **Narrowing.** A program-level grant
//! must not approve arbitrary code or destruction later. So an `exec` grant
//! is the exact command, `exec:<command>` (trimmed, byte for byte), when:
//!
//! - the command has shell syntax that runs or redirects more than one
//!   program (`;`, `&`, `|`, `<`, `>`, `` ` ``, `$`, `(`, `)`, a newline),
//!   or a program word that is quoted, escaped or a path (`./x`, `/bin/rm`);
//! - a leading assignment sets a variable that changes what runs
//!   (`dangerous_vars`, `dangerous_var_prefixes`) or has a `/` in its value;
//! - the program runs code it is given (`code_running`: shells,
//!   interpreters, wrappers, `make`/`just`, package runners);
//! - the program destroys (`destructive`: `rm`, `dd`, `mv`, `chmod`…);
//! - it is `find` with an action that runs or deletes (`-exec`, `-delete`…).
//!
//! `git` has no program-level grant: it is `exec:git <subcommand>` for the
//! subcommands in `git_subcommands`, and the exact command for anything
//! else: global options (`-c`, `--config-env`, `-C`, `--git-dir`…), other
//! subcommands (an alias can run a shell) and destructive forms
//! (`push --force`, `reset --hard`, `clean`, `branch -D`, `stash drop`…).
//! Because a request's grant is computed from its own command, a risky
//! command never matches a coarser standing grant: `rm -rf ~` is not
//! covered by `exec:rm build/x`, nor `git push -f` by `exec:git push`.
//!
//! **Store.** `allow_always` logs `always.granted {workspace, grant}` (once
//! per workspace and grant) with the answer, so the decision is in the event
//! log and survives a daemon restart by replay. Grants are per workspace:
//! the agent's `workspace`. They are listed with `always.list` and dropped
//! with `always.revoke` (`always.revoked`). The shared `grant.*` verbs are
//! caller capability grants, a different thing.
//!
//! **Matching.** A new approval whose grant is standing in its agent's
//! workspace is answered at once, in the commit that logs it: `allow_once`
//! through the same `harness.respond` effect as a human answer, and
//! `request.resolved {by: venom, grant}`. No attention is raised, so
//! nothing is published for the request. A harness
//! that does not accept `allow_once` for the request is asked as usual.
const std = @import("std");
const ev = @import("events.zig");
const decider = @import("decider.zig");
const Event = ev.Event;
const State = decider.State;
const Agent = decider.Agent;

pub const Standing = struct {
    workspace: []const u8,
    grant: []const u8,
    agent: []const u8,
    request: []const u8,
    at: i64,
};

/// The narrowest grant for an approval on `call` (null: none), in `a`.
pub fn narrowest(a: std.mem.Allocator, agent: *const Agent, call: ?[]const u8) !?[]const u8 {
    const id = call orelse return null;
    var i = agent.transcript.items.len;
    const t = while (i > 0) {
        i -= 1;
        const e = agent.transcript.items[i];
        if (e == .tool_started and std.mem.eql(u8, e.tool_started.call, id)) break e.tool_started;
    } else return null;
    if (std.mem.eql(u8, t.kind, "exec")) return try execGrant(a, t.title);
    if (t.title.len > 0) return try std.fmt.allocPrint(a, "{s}:{s}", .{ t.kind, t.title });
    if (t.name.len > 0) return try std.fmt.allocPrint(a, "tool:{s}", .{t.name});
    return null;
}

/// What an allowed-always `exec` call of `command` may be granted: null
/// (once only), the exact command, `exec:git <sub>` or `exec:<program>`.
pub fn execGrant(a: std.mem.Allocator, command: []const u8) !?[]const u8 {
    const cmd = std.mem.trim(u8, command, " \t\r\n");
    if (cmd.len == 0 or truncated(cmd)) return null;
    return switch (classify(cmd)) {
        .exact => try std.fmt.allocPrint(a, "exec:{s}", .{cmd}),
        .program => |p| try std.fmt.allocPrint(a, "exec:{s}", .{p}),
        .git => |sub| try std.fmt.allocPrint(a, "exec:git {s}", .{sub}),
    };
}

/// A title the harness cut short (the Claude Code adapter shows the first
/// line of a multi-line command followed by ` …`): the full command is not
/// known, so there is nothing exact to keep.
pub fn truncated(command: []const u8) bool {
    return std.mem.endsWith(u8, command, "\u{2026}");
}

pub const Class = union(enum) {
    exact,
    program: []const u8,
    git: []const u8,
};

/// Shells, interpreters, wrappers and runners: their arguments are code.
pub const code_running = [_][]const u8{
    // shells
    "sh",     "bash",    "zsh",    "dash",      "ksh",    "mksh",       "fish",    "csh",     "tcsh",    "ash",      "busybox", "toybox",
    // interpreters (also `python3.12` etc., see `codeRunning`)
    "python", "node",    "nodejs", "deno",      "bun",    "perl",       "ruby",    "irb",     "php",     "lua",      "luajit",  "tclsh",
    "wish",   "Rscript", "julia",  "osascript", "pwsh",   "powershell", "awk",     "gawk",    "mawk",    "nawk",     "sed",     "vim",
    "vi",     "nvim",    "emacs",  "gdb",
    // wrappers: run the program they are given
          "env",    "sudo",       "doas",    "su",      "pkexec",  "runuser",  "xargs",   "nice",
    "ionice", "timeout", "nohup",  "setsid",    "stdbuf", "unbuffer",   "time",    "command", "builtin", "exec",     "eval",    "source",
    ".",      "strace",  "ltrace", "valgrind",  "chroot", "unshare",    "nsenter", "flock",   "watch",   "parallel", "entr",    "script",
    "ssh",    "docker",  "podman", "tar",       "rsync",  "!",
    // build/task runners with arbitrary targets, package runners
             "make",    "gmake",   "just",    "npx",      "bunx",    "pnpx",
    "uvx",    "pipx",    "uv",     "pip",       "pip3",
};

/// Programs whose effect cannot be undone: "always" keeps the exact command.
pub const destructive = [_][]const u8{
    "rm",    "rmdir", "unlink", "shred", "dd",      "wipefs",   "fdisk",  "sfdisk", "parted",   "truncate", "mv",        "chmod",
    "chown", "chgrp", "kill",   "pkill", "killall", "shutdown", "reboot", "halt",   "poweroff", "crontab",  "systemctl",
};

/// `find` actions that run a program or change the file system.
const find_actions = [_][]const u8{ "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls" };

/// Variables that change which code a program runs.
pub const dangerous_vars = [_][]const u8{ "PATH", "BASH_ENV", "ENV", "IFS", "SHELLOPTS", "BASHOPTS", "PS4", "PROMPT_COMMAND", "ZDOTDIR", "EDITOR", "VISUAL", "PAGER", "SHELL", "HOME", "MAKEFLAGS" };
pub const dangerous_var_prefixes = [_][]const u8{ "LD_", "DYLD_", "GIT_", "PYTHON", "NODE_", "PERL", "RUBY", "BASH_FUNC_" };

/// git subcommands that get `exec:git <sub>`; any other is exact.
pub const git_subcommands = [_][]const u8{
    "status",   "diff",    "log",   "show",   "rev-parse", "ls-files", "ls-tree", "blame", "grep",  "describe", "shortlog", "cat-file",
    "rev-list", "fetch",   "add",   "commit", "switch",    "checkout", "branch",  "tag",   "stash", "merge",    "pull",     "push",
    "remote",   "restore", "reset", "help",   "version",
};

/// How an `exec` command is granted (see the module doc).
pub fn classify(cmd: []const u8) Class {
    for (cmd) |ch| switch (ch) {
        ';', '&', '|', '<', '>', '`', '$', '(', ')', '\n', '\r' => return .exact,
        else => {},
    };
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const prog = while (it.next()) |word| {
        if (!assignment(word)) break word;
        const eq = std.mem.indexOfScalar(u8, word, '=').?;
        if (dangerousVar(word[0..eq]) or std.mem.indexOfScalar(u8, word[eq + 1 ..], '/') != null) return .exact;
    } else return .exact;
    for (prog) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '+' or ch == '-')) return .exact;
    if (codeRunning(prog) or oneOf(&destructive, prog) or std.mem.startsWith(u8, prog, "mkfs")) return .exact;
    if (std.mem.eql(u8, prog, "find")) {
        var rest = it;
        while (rest.next()) |w| if (oneOf(&find_actions, w)) return .exact;
    }
    if (std.mem.eql(u8, prog, "git")) return git(it);
    return .{ .program = prog };
}

fn codeRunning(prog: []const u8) bool {
    if (oneOf(&code_running, prog)) return true;
    // python3, python3.12, perl5.36, ruby3.2, node20…
    for ([_][]const u8{ "python", "perl", "ruby", "node", "php", "lua", "pip" }) |stem| {
        if (!std.mem.startsWith(u8, prog, stem)) continue;
        const tail = prog[stem.len..];
        for (tail) |ch| {
            if (!(std.ascii.isDigit(ch) or ch == '.')) break;
        } else return true;
    }
    return false;
}

fn dangerousVar(name: []const u8) bool {
    if (oneOf(&dangerous_vars, name)) return true;
    for (dangerous_var_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// `git` after its program word: `.git` with the subcommand, or `.exact`.
fn git(args: std.mem.TokenIterator(u8, .any)) Class {
    var it = args;
    const sub = while (it.next()) |w| {
        // --no-pager / -P are harmless; every other global option (-c,
        // --config-env, -C, --git-dir, --work-tree, --exec-path…) is exact.
        if (std.mem.eql(u8, w, "--no-pager") or std.mem.eql(u8, w, "-P")) continue;
        if (w.len > 0 and w[0] == '-') return .exact;
        break w;
    } else return .exact;
    if (!oneOf(&git_subcommands, sub)) return .exact;
    const Sub = enum { push, reset, checkout, switch_, branch, tag, stash, restore, other };
    const s: Sub = if (std.mem.eql(u8, sub, "switch")) .switch_ else std.meta.stringToEnum(Sub, sub) orelse .other;
    if (s == .restore) return .exact;
    var first = true;
    while (it.next()) |w| : (first = false) {
        const flags: []const []const u8 = switch (s) {
            .push => &.{ "-f", "--force", "--force-if-includes", "--mirror", "--delete", "-d", "--prune" },
            .reset => &.{ "--hard", "--merge", "--keep" },
            .checkout => &.{ "-f", "--force", "-B", "--", ".", "--overwrite-ignore", "--theirs", "--ours", "-p", "--patch" },
            .switch_ => &.{ "-f", "--force", "--discard-changes", "-C", "--force-create" },
            .branch => &.{ "-d", "-D", "--delete", "-f", "--force", "-M", "-m", "--move", "-C" },
            .tag => &.{ "-d", "--delete", "-f", "--force" },
            .stash => if (first) &.{ "drop", "clear", "pop" } else &.{},
            .restore, .other => &.{},
        };
        if (oneOf(flags, w)) return .exact;
        if (s == .push and (std.mem.startsWith(u8, w, "--force-with-lease") or std.mem.startsWith(u8, w, "--force") or (w.len > 0 and (w[0] == '+' or w[0] == ':')) or (w.len > 1 and w[0] == '-' and w[1] != '-' and std.mem.indexOfScalar(u8, w, 'f') != null))) return .exact;
        if (s == .branch and w.len > 1 and w[0] == '-' and w[1] != '-' and std.mem.indexOfAny(u8, w, "dDfMm") != null) return .exact;
    }
    return .{ .git = sub };
}

fn oneOf(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// The program a command line runs: its first word that is not a
/// `NAME=value` assignment.
pub fn program(command: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |word| {
        if (assignment(word)) continue;
        return word;
    }
    return null;
}

fn assignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0) return false;
    for (word[0..eq]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return !std.ascii.isDigit(word[0]);
}

pub fn find(state: *const State, workspace: []const u8, grant: []const u8) ?usize {
    for (state.standing.items, 0..) |s, i| if (std.mem.eql(u8, s.workspace, workspace) and std.mem.eql(u8, s.grant, grant)) return i;
    return null;
}

/// The standing grant that answers request `r` of agent `id` at once, if
/// any: an approval with a grant standing in the agent's workspace, whose
/// harness accepts `allow_once`.
pub fn autoAllow(state: *const State, id: []const u8, r: ev.Request) ?[]const u8 {
    if (!std.mem.eql(u8, r.kind, "approval")) return null;
    const grant = r.grant orelse return null;
    const agent = state.agents.getPtr(id) orelse return null;
    if (r.answers.len > 0) for (r.answers) |x| {
        if (std.mem.eql(u8, x, "allow_once")) break;
    } else return null;
    const i = find(state, agent.workspace, grant) orelse return null;
    return state.standing.items[i].grant;
}

/// The `always.granted` an `allow_always` answer to `asked` adds, if the
/// grant is not standing yet. `error.InvalidCommand` when the request has
/// no grant.
pub fn record(state: *const State, agent: *const Agent, id: []const u8, asked: decider.Request, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (decider.Rejection || error{OutOfMemory})!void {
    const grant = asked.grant orelse return error.InvalidCommand;
    if (find(state, agent.workspace, grant) != null) return;
    try out.append(a, .{ .always_granted = .{ .workspace = agent.workspace, .grant = grant, .agent = id, .request = asked.request, .at = now } });
}

pub fn decide(state: *const State, cmd: ev.Command, now: i64, a: std.mem.Allocator, out: *std.ArrayList(Event)) (decider.Rejection || error{OutOfMemory})!void {
    const r = cmd.revoke_always;
    _ = find(state, r.workspace, r.grant) orelse return error.NotFound;
    try out.append(a, .{ .always_revoked = .{ .workspace = r.workspace, .grant = r.grant, .at = now } });
}

pub fn evolve(state: *State, event: Event) error{OutOfMemory}!void {
    const a = state.arena.allocator();
    switch (event) {
        .always_granted => {
            const g = (try event.dupe(a)).always_granted;
            if (find(state, g.workspace, g.grant) != null) return;
            try state.standing.append(a, .{ .workspace = g.workspace, .grant = g.grant, .agent = g.agent, .request = g.request, .at = g.at });
        },
        .always_revoked => |r| if (find(state, r.workspace, r.grant)) |i| {
            _ = state.standing.orderedRemove(i);
        },
        else => unreachable,
    }
}

const testing = std.testing;

test "always: the narrowest grant of a call" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try decider.apply(&state, .{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } }, s);
    _ = try decider.apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    const calls = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "exec", "Bash", "CC=gcc ZIG_DEBUG=1 zig build test -Dmodule=proto" },
        .{ "edit", "Edit", "src/proto.zig" },
        .{ "mcp", "linear_get_issue", "" },
        .{ "exec", "Bash", "   " },
    };
    for (calls, 0..) |c, n| _ = try decider.apply(&state, .{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = try std.fmt.allocPrint(s, "c{d}", .{n + 1}), .kind = c[0], .name = c[1], .title = c[2] } } }, s);
    const agent = state.agents.getPtr("a1").?;
    try testing.expectEqualStrings("exec:zig", (try narrowest(s, agent, "c1")).?);
    try testing.expectEqualStrings("edit:src/proto.zig", (try narrowest(s, agent, "c2")).?);
    try testing.expectEqualStrings("tool:linear_get_issue", (try narrowest(s, agent, "c3")).?);
    // An exec call with no command has no grant (not `tool:Bash`, which
    // would cover every other such call).
    try testing.expect((try narrowest(s, agent, "c4")) == null);
    try testing.expect((try narrowest(s, agent, "c9")) == null);
    try testing.expect((try narrowest(s, agent, null)) == null);
    try testing.expectEqualStrings("=x", program("=x y").?);
}

test "always: allow_always records the grant once; a matching approval is answered at once; revoke" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const apply = decider.apply;
    for ([_][]const u8{ "a1", "a2" }, [_][]const u8{ "/w", "/other" }) |id, ws| {
        _ = try apply(&state, .{ .create = .{ .agent = id, .title = "t", .harness = "fake", .workspace = ws } }, s);
        _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = id, .turn = "t1", .origin = "user" } } }, s);
    }
    _ = try apply(&state, .{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build" } } }, s);
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "approval", .call = "c1", .reason = "Bash zig build" } } }, s);
    try testing.expectEqualStrings("exec:zig", state.agents.get("a1").?.requests.items[0].grant.?);
    // A question carries no grant; an approval without a call can't be "always".
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r2", .kind = "question", .call = "c1", .reason = "?" } } }, s);
    try testing.expect(state.agents.get("a1").?.requests.items[1].grant == null);
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r3", .kind = "approval", .reason = "?" } } }, s);
    try testing.expectError(error.InvalidCommand, apply(&state, .{ .answer = .{ .agent = "a1", .request = "r3", .decision = "allow_always" } }, s));

    var out: std.ArrayList(Event) = .empty;
    try decider.decide(&state, .{ .answer = .{ .agent = "a1", .request = "r1", .decision = "allow_always" } }, 7, s, &out);
    try testing.expect(out.items[0] == .always_granted);
    try testing.expectEqualStrings("/w", out.items[0].always_granted.workspace);
    for (out.items) |e| try decider.evolve(&state, e);
    try testing.expectEqual(@as(usize, 1), state.standing.items.len);

    // The next matching approval in /w: answered allow_once, no needs_you.
    _ = try apply(&state, .{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = "c2", .kind = "exec", .name = "Bash", .title = "zig fmt --check ." } } }, s);
    out = .empty;
    const req: ev.Request = .{ .agent = "a1", .request = "r4", .kind = "approval", .call = "c2", .reason = "Bash zig fmt" };
    try decider.decide(&state, .{ .record = .{ .request = req } }, 8, s, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("exec:zig", out.items[0].request.grant.?);
    try testing.expectEqualStrings("venom", out.items[1].request_resolved.by);
    try testing.expectEqualStrings("exec:zig", out.items[1].request_resolved.grant.?);
    try testing.expectEqualStrings("{\"agent\":\"a1\",\"request\":\"r4\",\"decision\":\"allow_once\",\"stale\":false}", out.items[2].effect_requested.payload);
    for (out.items) |e| try decider.evolve(&state, e);
    try testing.expect(state.agents.get("a1").?.pending("r4") == null);

    // Another workspace is not covered; a harness without allow_once neither.
    _ = try apply(&state, .{ .record = .{ .tool_started = .{ .agent = "a2", .turn = "t1", .call = "c1", .kind = "exec", .name = "Bash", .title = "zig build" } } }, s);
    _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a2", .request = "r1", .kind = "approval", .call = "c1", .reason = "x" } } }, s);
    try testing.expect(state.agents.get("a2").?.pending("r1") != null);
    try testing.expect(autoAllow(&state, "a1", .{ .agent = "a1", .request = "r9", .kind = "approval", .reason = "", .grant = "exec:zig", .answers = &.{"deny"} }) == null);

    // Revoke: gone; unknown: NotFound.
    _ = try apply(&state, .{ .revoke_always = .{ .workspace = "/w", .grant = "exec:zig" } }, s);
    try testing.expectEqual(@as(usize, 0), state.standing.items.len);
    try testing.expectError(error.NotFound, apply(&state, .{ .revoke_always = .{ .workspace = "/w", .grant = "exec:zig" } }, s));
}

test "always: risky commands are narrowed to the exact command" {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const cases = [_]struct { []const u8, ?[]const u8 }{
        // Plain programs keep the program-level grant.
        .{ "zig build test", "exec:zig" },
        .{ "  ls -la src  ", "exec:ls" },
        .{ "CC=gcc ZIG_DEBUG=1 zig build", "exec:zig" },
        .{ "find src -name '*.zig'", "exec:find" },
        // Shells, interpreters and wrappers: exact.
        .{ "bash -c 'zig build'", "exec:bash -c 'zig build'" },
        .{ "sh script.sh", "exec:sh script.sh" },
        .{ "python3 -c 'print(1)'", "exec:python3 -c 'print(1)'" },
        .{ "python3.12 tools/gen.py", "exec:python3.12 tools/gen.py" },
        .{ "node x.js", "exec:node x.js" },
        .{ "perl -e 1", "exec:perl -e 1" },
        .{ "env FOO=1 zig build", "exec:env FOO=1 zig build" },
        .{ "sudo zig build", "exec:sudo zig build" },
        .{ "xargs rm", "exec:xargs rm" },
        .{ "timeout 60 zig build test", "exec:timeout 60 zig build test" },
        .{ "nohup zig build", "exec:nohup zig build" },
        .{ "find . -name x -exec rm {} +", "exec:find . -name x -exec rm {} +" },
        .{ "find . -delete", "exec:find . -delete" },
        .{ "make test", "exec:make test" },
        .{ "just lint", "exec:just lint" },
        .{ "sed -i s/a/b/ f", "exec:sed -i s/a/b/ f" },
        .{ "npx some-pkg", "exec:npx some-pkg" },
        // Destructive programs: exact.
        .{ "rm build/x", "exec:rm build/x" },
        .{ "rm -rf ~", "exec:rm -rf ~" },
        .{ "dd if=/dev/zero of=x", "exec:dd if=/dev/zero of=x" },
        .{ "mkfs.ext4 /dev/sda1", "exec:mkfs.ext4 /dev/sda1" },
        // Shell syntax, odd program words, risky assignments: exact.
        .{ "zig build; rm -rf ~", "exec:zig build; rm -rf ~" },
        .{ "zig build && curl x | sh", "exec:zig build && curl x | sh" },
        .{ "zig build > /etc/passwd", "exec:zig build > /etc/passwd" },
        .{ "zig build $(rm -rf ~)", "exec:zig build $(rm -rf ~)" },
        .{ "zig build `id`", "exec:zig build `id`" },
        .{ "zig build\nrm -rf ~", "exec:zig build\nrm -rf ~" },
        .{ "./zig-out/bin/venom doctor", "exec:./zig-out/bin/venom doctor" },
        .{ "/bin/rm x", "exec:/bin/rm x" },
        .{ "'rm' x", "exec:'rm' x" },
        .{ "\\rm x", "exec:\\rm x" },
        .{ "LD_PRELOAD=x.so zig build", "exec:LD_PRELOAD=x.so zig build" },
        .{ "PATH=bin zig build", "exec:PATH=bin zig build" },
        .{ "CC=/tmp/cc zig build", "exec:CC=/tmp/cc zig build" },
        .{ "GIT_SSH_COMMAND=x git fetch", "exec:GIT_SSH_COMMAND=x git fetch" },
        .{ "A=1", "exec:A=1" },
        // git: per subcommand, exact for global options, aliases and
        // destructive forms.
        .{ "git status", "exec:git status" },
        .{ "git --no-pager log -5", "exec:git log" },
        .{ "git push origin HEAD", "exec:git push" },
        .{ "git branch feature", "exec:git branch" },
        .{ "git stash list", "exec:git stash" },
        .{ "git reset HEAD~1", "exec:git reset" },
        .{ "git push --force origin main", "exec:git push --force origin main" },
        .{ "git push -f", "exec:git push -f" },
        .{ "git push -uf origin x", "exec:git push -uf origin x" },
        .{ "git push --force-with-lease", "exec:git push --force-with-lease" },
        .{ "git push origin +main", "exec:git push origin +main" },
        .{ "git push origin :main", "exec:git push origin :main" },
        .{ "git push --delete origin x", "exec:git push --delete origin x" },
        .{ "git reset --hard", "exec:git reset --hard" },
        .{ "git clean -fdx", "exec:git clean -fdx" },
        .{ "git checkout -- .", "exec:git checkout -- ." },
        .{ "git restore src", "exec:git restore src" },
        .{ "git branch -D x", "exec:git branch -D x" },
        .{ "git branch -df x", "exec:git branch -df x" },
        .{ "git tag -d v1", "exec:git tag -d v1" },
        .{ "git stash drop", "exec:git stash drop" },
        .{ "git -c core.pager=sh status", "exec:git -c core.pager=sh status" },
        .{ "git -C /etc status", "exec:git -C /etc status" },
        .{ "git config core.hooksPath x", "exec:git config core.hooksPath x" },
        .{ "git yolo", "exec:git yolo" },
        .{ "git", "exec:git" },
        // Nothing exact to keep: once only.
        .{ "", null },
        .{ "  ", null },
        .{ "zig build \u{2026}", null },
    };
    for (cases) |c| {
        const got = try execGrant(s, c[0]);
        if (c[1]) |want| {
            testing.expectEqualStrings(want, got orelse "(null)") catch |err| {
                std.debug.print("command: {s}\n", .{c[0]});
                return err;
            };
        } else try testing.expect(got == null);
    }
}

test "always: a coarser standing grant never covers a risky command" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const apply = decider.apply;
    _ = try apply(&state, .{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } }, s);
    _ = try apply(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, s);
    const titles = [_][]const u8{ "rm build/x", "zig build", "git push origin HEAD", "rm -rf ~", "zig build; rm -rf ~", "git push --force", "rm build/x", "zig build \u{2026}" };
    for (titles, 0..) |title, n| {
        const call = try std.fmt.allocPrint(s, "c{d}", .{n});
        const request = try std.fmt.allocPrint(s, "r{d}", .{n});
        _ = try apply(&state, .{ .record = .{ .tool_started = .{ .agent = "a1", .turn = "t1", .call = call, .kind = "exec", .name = "Bash", .title = title } } }, s);
        _ = try apply(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = request, .kind = "approval", .call = call, .reason = title } } }, s);
        // Allow the first three always.
        if (n < 3) _ = try apply(&state, .{ .answer = .{ .agent = "a1", .request = request, .decision = "allow_always" } }, s);
    }
    try testing.expectEqual(@as(usize, 3), state.standing.items.len);
    try testing.expectEqualStrings("exec:rm build/x", state.standing.items[0].grant);
    const agent = state.agents.get("a1").?;
    // rm -rf ~, a compound command, a forced push: asked again.
    for ([_][]const u8{ "r3", "r4", "r5" }) |r| try testing.expect(agent.pending(r) != null);
    // The exact same command: answered at once.
    try testing.expect(agent.pending("r6") == null);
    // A cut-short command has no grant, so "always" is refused.
    try testing.expect(agent.requests.items[agent.pending("r7").?].grant == null);
    try testing.expectError(error.InvalidCommand, apply(&state, .{ .answer = .{ .agent = "a1", .request = "r7", .decision = "allow_always" } }, s));
}
