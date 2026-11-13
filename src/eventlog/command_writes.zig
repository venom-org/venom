//! Where a shell command writes, judged from its text: the `exec`
//! half of `agent_scope.outsideCall`.
//!
//! It answers one question for an approval on a command: does this command
//! visibly write outside the agent's writable folders? A yes stamps the
//! approval `outside_scope`, so it has no grant and is always asked. The
//! judge is pure and never runs anything, so it can only see what the text
//! says:
//!
//! - **Seen:** redirections, the path arguments of the usual file-writing
//!   programs (`writers` below), `sed -i`, `dd of=`, `find -delete|-exec`,
//!   `git -C <dir>`, `git clone|init|worktree`, `sort -o`, and any `cd` out
//!   of scope, through `;`, `&&`, `|`, wrappers (`sudo`, `env`, `timeout`…), shells
//!   (`bash -c '…'`, also how Codex wraps every command: `zsh -lc '…'`) and
//!   command substitutions.
//! - **Cannot be judged, so it counts as outside:** a target with a variable,
//!   a substitution or `~`, a relative target or unknown program where the
//!   folder is not known, a program named by a variable, `eval`, a shell
//!   reading its script from a pipe, process substitution, `xargs`/`parallel`
//!   running a writer or a shell, an unterminated quote.
//! - **Not seen**: what a program writes on its own
//!   account (`make`, `python x.py`, `zig build -p ../c`, a git hook, `curl
//!   -o`, `tar -C`), and a path through a symlink.
//!
//! **The folder.** A harness may keep its shell's folder between commands
//! (Claude Code's Bash does), so a command's folder is not always the one the
//! harness reports. `cwdsAfter` keeps the folders earlier commands may have
//! left it in, and a command must be in scope from each of them. A `cd` can
//! fail and a subshell's ends with it, so the folders only ever grow; a command
//! with two `cd`s, or one to an unknown place, makes the folder unknown.
//! Codex runs each command in a fresh `zsh -lc`, whose `cd` does not last.
//!
//! Temporary paths are not repos: `/tmp` and `/var/tmp` don't count, unless a
//! writable root is itself under one of them (then a sibling there may be an
//! out-of-scope repo). In `/dev` only `null`, `stdout`, `stderr` and `fd/*`
//! don't count.
const std = @import("std");
const rules = @import("workspaces.zig");

const Word = struct {
    text: []const u8,
    /// Its value is known only when the shell runs: `$x`, `` `x` ``, `~`.
    unknown: bool = false,
};

const Simple = struct {
    words: []const Word,
    /// Targets of `>`, `>>`, `>|`, `&>`.
    redirects: []const Word,
};

const Parsed = struct {
    commands: []const Simple,
    /// The text of `$(…)` and `` `…` ``: they run too.
    nested: []const []const u8,
};

const Program = enum {
    /// Every path argument is written.
    all,
    /// Every path argument but the first (a mode, an owner, `uniq`'s input).
    after_first,
    /// The last path argument (and `-t DIR`) is written.
    last,
    /// Every path argument is written, `-t DIR` too: the sources move.
    move,
    dd,
    sed,
    sort,
    find,
    git,
    shell,
    eval,
    cd,
    /// Runs a command read from its input.
    fan_out,
    reader,
    other,
};

/// Programs venom knows the writes of; also what the claude-code adapter's
/// Bash `ask` rules name (`writer_programs`).
const writers = std.StaticStringMap(Program).initComptime(.{
    .{ "rm", .all },            .{ "rmdir", .all },         .{ "unlink", .all },
    .{ "mkdir", .all },         .{ "touch", .all },         .{ "truncate", .all },
    .{ "shred", .all },         .{ "tee", .all },           .{ "chmod", .after_first },
    .{ "chown", .after_first }, .{ "chgrp", .after_first }, .{ "cp", .last },
    .{ "ln", .last },           .{ "install", .last },      .{ "rsync", .last },
    .{ "mv", .move },           .{ "dd", .dd },             .{ "sed", .sed },
    .{ "gsed", .sed },          .{ "uniq", .after_first },
});

/// The file-writing programs, for rules that name them.
pub const writer_programs = [_][]const u8{ "rm", "rmdir", "unlink", "mkdir", "touch", "truncate", "shred", "tee", "chmod", "chown", "chgrp", "cp", "ln", "install", "rsync", "mv", "dd", "sed" };

const others = std.StaticStringMap(Program).initComptime(.{
    .{ "find", .find },     .{ "git", .git },          .{ "sh", .shell },     .{ "bash", .shell },
    .{ "zsh", .shell },     .{ "dash", .shell },       .{ "ksh", .shell },    .{ "eval", .eval },
    .{ "cd", .cd },         .{ "popd", .cd },          .{ "sort", .sort },    .{ "pushd", .cd },
    .{ "xargs", .fan_out }, .{ "parallel", .fan_out }, .{ "ls", .reader },    .{ "cat", .reader },
    .{ "head", .reader },   .{ "tail", .reader },      .{ "wc", .reader },    .{ "grep", .reader },
    .{ "rg", .reader },     .{ "ag", .reader },        .{ "fd", .reader },    .{ "stat", .reader },
    .{ "file", .reader },   .{ "du", .reader },        .{ "df", .reader },    .{ "pwd", .reader },
    .{ "echo", .reader },   .{ "printf", .reader },    .{ "true", .reader },  .{ "false", .reader },
    .{ "test", .reader },   .{ "[", .reader },         .{ "which", .reader }, .{ "type", .reader },
    .{ "tree", .reader },   .{ "sort", .reader },      .{ "cut", .reader },   .{ "tr", .reader },
    .{ "diff", .reader },   .{ "cmp", .reader },       .{ "less", .reader },  .{ "more", .reader },
    .{ "jq", .reader },     .{ "date", .reader },      .{ "sleep", .reader },
});

const reserved = std.StaticStringMap(void).initComptime(.{
    .{ "if", {} }, .{ "then", {} }, .{ "else", {} },  .{ "elif", {} },  .{ "fi", {} },
    .{ "do", {} }, .{ "done", {} }, .{ "while", {} }, .{ "until", {} }, .{ "!", {} },
    .{ "{", {} },  .{ "}", {} },
});

const wrappers = std.StaticStringMap(void).initComptime(.{
    .{ "sudo", {} },    .{ "doas", {} },   .{ "env", {} },   .{ "command", {} }, .{ "builtin", {} },
    .{ "exec", {} },    .{ "time", {} },   .{ "nohup", {} }, .{ "nice", {} },    .{ "ionice", {} },
    .{ "timeout", {} }, .{ "stdbuf", {} },
});

/// `git` subcommands that only read.
const git_readers = std.StaticStringMap(void).initComptime(.{
    .{ "status", {} },   .{ "log", {} },       .{ "diff", {} },     .{ "show", {} },    .{ "blame", {} },
    .{ "grep", {} },     .{ "rev-parse", {} }, .{ "ls-files", {} }, .{ "ls-tree", {} }, .{ "shortlog", {} },
    .{ "describe", {} }, .{ "cat-file", {} },  .{ "rev-list", {} },
});

const git_worktree_readers = std.StaticStringMap(void).initComptime(.{
    .{ "list", {} }, .{ "prune", {} },
});

/// How deep `bash -c`, `eval` and substitutions are followed.
const max_depth = 8;

/// Whether `command`, run in `base`, visibly writes outside every folder of
/// `roots` (see the file comment).
pub fn writesOutside(a: std.mem.Allocator, roots: []const []const u8, base: []const u8, command: []const u8) error{OutOfMemory}!bool {
    return writesOutsideFrom(a, roots, base, &.{base}, command);
}

/// `writesOutside` from each of the folders the shell may be in (null: not
/// known). `start` is the agent's own folder, the one place outside its scope
/// a `cd` may go to without asking.
pub fn writesOutsideFrom(a: std.mem.Allocator, roots: []const []const u8, start: []const u8, bases: []const ?[]const u8, command: []const u8) error{OutOfMemory}!bool {
    for (bases) |base| {
        var cwd = base;
        if (try judge(a, roots, start, &cwd, command, 0)) return true;
    }
    return false;
}

/// How many folders are kept before the folder counts as unknown.
const max_cwds = 8;

/// Adds to `cwds` the folders `command` may leave a lasting shell in.
pub fn cwdsAfter(a: std.mem.Allocator, cwds: *std.ArrayList(?[]const u8), command: []const u8) error{OutOfMemory}!void {
    const parsed = try parse(a, command) orelse return unknownCwd(a, cwds);
    var moves: ?[]const Word = null;
    for (parsed.commands) |simple| {
        const w = program(simple.words);
        if (w.len == 0) continue;
        if (w[0].unknown) continue;
        if ((others.get(baseName(w[0].text)) orelse .other) != .cd) continue;
        if (moves != null) return unknownCwd(a, cwds);
        moves = w[1..];
    }
    const args = moves orelse return;
    if (args.len == 0 and cwds.items.len == 0) return;
    const before = try a.dupe(?[]const u8, cwds.items);
    for (before) |base| {
        const next = try enter(a, base, args) orelse return unknownCwd(a, cwds);
        var seen = false;
        for (cwds.items) |c| if (c) |x| {
            seen = seen or std.mem.eql(u8, x, next);
        };
        if (!seen) try cwds.append(a, next);
    }
    if (cwds.items.len > max_cwds) return unknownCwd(a, cwds);
}

fn unknownCwd(a: std.mem.Allocator, cwds: *std.ArrayList(?[]const u8)) error{OutOfMemory}!void {
    cwds.clearRetainingCapacity();
    try cwds.append(a, null);
}

fn judge(a: std.mem.Allocator, roots: []const []const u8, start: []const u8, cwd: *?[]const u8, command: []const u8, depth: u32) error{OutOfMemory}!bool {
    if (depth > max_depth) return true;
    const parsed = try parse(a, command) orelse return true;
    for (parsed.nested) |inner| {
        var sub = cwd.*;
        if (try judge(a, roots, start, &sub, inner, depth + 1)) return true;
    }
    for (parsed.commands) |simple| {
        for (simple.redirects) |t| if (try targetOutside(a, roots, cwd.*, t)) return true;
        if (try simpleOutside(a, roots, start, cwd, simple, depth)) return true;
    }
    return false;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0) return false;
    for (word[0..eq], 0..) |ch, i| {
        if (!(std.ascii.isAlphabetic(ch) or ch == '_' or (i > 0 and std.ascii.isDigit(ch)))) return false;
    }
    return true;
}

/// `words` without keywords, assignments and wrappers (with their flags): it
/// starts at the program that runs.
fn program(words: []const Word) []const Word {
    var w = words;
    while (w.len > 0) {
        const x = w[0].text;
        if (reserved.has(x) or isAssignment(x)) {
            w = w[1..];
            continue;
        }
        if (wrappers.has(baseName(x))) {
            w = w[1..];
            while (w.len > 0 and (w[0].text.len == 0 or w[0].text[0] == '-' or isAssignment(w[0].text) or std.ascii.isDigit(w[0].text[0]))) w = w[1..];
            // The value of a flag (`sudo -u root rm x`): skip it.
            if (w.len > 1 and !known(w[0].text) and known(w[1].text)) w = w[1..];
            continue;
        }
        break;
    }
    return w;
}

fn known(word: []const u8) bool {
    const name = baseName(word);
    return writers.has(name) or others.has(name);
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn simpleOutside(a: std.mem.Allocator, roots: []const []const u8, start: []const u8, cwd: *?[]const u8, simple: Simple, depth: u32) error{OutOfMemory}!bool {
    const w = program(simple.words);
    if (w.len == 0) return false;
    // `$RM c/x`: only the shell knows what runs.
    if (w[0].unknown) return true;
    const name = baseName(w[0].text);
    const args = w[1..];
    const kind = writers.get(name) orelse others.get(name) orelse .other;
    switch (kind) {
        .all, .after_first, .last, .move => return writeArgs(a, roots, cwd.*, name, kind, args),
        .dd => {
            for (args) |x| if (std.mem.startsWith(u8, x.text, "of=")) {
                if (try targetOutside(a, roots, cwd.*, .{ .text = x.text[3..], .unknown = x.unknown })) return true;
            };
            return false;
        },
        .sed => return sedOutside(a, roots, cwd.*, args),
        .sort => {
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const x = args[i];
                if (x.unknown or x.text.len < 2 or x.text[0] != '-') continue;
                if (std.mem.startsWith(u8, x.text, "--output=")) {
                    if (try targetOutside(a, roots, cwd.*, .{ .text = x.text["--output=".len..] })) return true;
                } else if (std.mem.eql(u8, x.text, "--output")) {
                    i += 1;
                    if (i < args.len and try targetOutside(a, roots, cwd.*, args[i])) return true;
                } else if (x.text[1] != '-') if (clusterValue(args, &i, 'o')) |t| {
                    if (try targetOutside(a, roots, cwd.*, t)) return true;
                };
            }
            return false;
        },
        .find => return findOutside(a, roots, start, cwd, args, depth),
        .git => return gitOutside(a, roots, start, cwd.*, args),
        .shell => {
            for (args, 0..) |x, i| {
                if (x.unknown) return true;
                if (x.text.len < 2 or x.text[0] != '-') {
                    // `sh script.sh`: the script's writes are not seen.
                    return leftScope(a, roots, start, cwd.*);
                }
                if (x.text[1] == '-') continue;
                if (std.mem.indexOfScalar(u8, x.text, 'c') == null) continue;
                if (i + 1 >= args.len or args[i + 1].unknown) return true;
                var sub = cwd.*;
                return judge(a, roots, start, &sub, args[i + 1].text, depth + 1);
            }
            // No script: it reads one from a pipe.
            return true;
        },
        .eval => return true,
        .cd => {
            cwd.* = try enter(a, cwd.*, args);
            const here = cwd.* orelse return true;
            if (std.mem.eql(u8, here, start)) return false;
            return outsideRoots(a, roots, here, here);
        },
        .fan_out => {
            for (args) |x| {
                const k = writers.get(baseName(x.text)) orelse others.get(baseName(x.text)) orelse .other;
                if (writers.has(baseName(x.text)) or k == .shell or k == .eval or k == .find) return true;
            }
            return leftScope(a, roots, start, cwd.*);
        },
        .reader => return false,
        .other => return leftScope(a, roots, start, cwd.*),
    }
}

/// The folder after `cd args`: null when only the shell can tell.
fn enter(a: std.mem.Allocator, cwd: ?[]const u8, args: []const Word) !?[]const u8 {
    for (args) |x| {
        if (x.text.len > 0 and x.text[0] == '-' and !x.unknown) continue;
        if (x.unknown) return null;
        if (x.text.len > 0 and x.text[0] == '/') return try std.fs.path.resolvePosix(a, &.{x.text});
        const here = cwd orelse return null;
        return try std.fs.path.resolvePosix(a, &.{ here, x.text });
    }
    return null; // `cd`: home
}

/// A command venom knows nothing about writes where it runs, as far as it
/// can tell: that counts only once a `cd` left the scope.
fn leftScope(a: std.mem.Allocator, roots: []const []const u8, start: []const u8, cwd: ?[]const u8) !bool {
    const here = cwd orelse return true;
    if (std.mem.eql(u8, here, start)) return false;
    return outsideRoots(a, roots, here, here);
}

/// A short-flag cluster with `letter` at `args[i.*]`: its value, the rest of
/// the cluster or the next word (`-tc`, `-t c`).
fn clusterValue(args: []const Word, i: *usize, letter: u8) ?Word {
    const text = args[i.*].text;
    const at = std.mem.indexOfScalar(u8, text, letter) orelse return null;
    if (at + 1 < text.len) return .{ .text = text[at + 1 ..] };
    i.* += 1;
    return if (i.* < args.len) args[i.*] else null;
}

/// `--target-directory`, or the abbreviation of it getopt accepts (`--t`).
fn longTarget(text: []const u8) bool {
    const name = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
    return name.len >= 3 and std.mem.startsWith(u8, "--target-directory", name);
}

/// `chmod -x file`: a mode that looks like a flag.
fn dashMode(text: []const u8) bool {
    if (text.len < 2 or text[0] != '-') return false;
    for (text[1..]) |ch| if (std.mem.indexOfScalar(u8, "rwxXstugoa+-=,01234567", ch) == null) return false;
    return true;
}

fn writeArgs(a: std.mem.Allocator, roots: []const []const u8, cwd: ?[]const u8, name: []const u8, kind: Program, args: []const Word) !bool {
    const target_flag = std.mem.eql(u8, name, "cp") or std.mem.eql(u8, name, "mv") or std.mem.eql(u8, name, "ln") or std.mem.eql(u8, name, "install");
    const modes = std.mem.eql(u8, name, "chmod");
    var skip_first = kind == .after_first;
    var target_given = false;
    var paths: std.ArrayList(Word) = .empty;
    var flags = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (flags and !x.unknown and std.mem.eql(u8, x.text, "--")) {
            flags = false;
            continue;
        }
        if (flags and !x.unknown and x.text.len > 1 and x.text[0] == '-') {
            // `--reference=f` and `-x` take the place of the mode or owner.
            if (std.mem.startsWith(u8, x.text, "--reference") or (modes and dashMode(x.text))) skip_first = false;
            // `-t DIR`, `-tDIR`, `--target-directory[=]DIR`: where they write.
            if (target_flag and longTarget(x.text)) {
                target_given = true;
                // `--target-directory=DIR` or `--target-directory DIR`.
                const value: ?Word = if (std.mem.indexOfScalar(u8, x.text, '=')) |eq| .{ .text = x.text[eq + 1 ..] } else blk: {
                    i += 1;
                    break :blk if (i < args.len) args[i] else null;
                };
                if (value) |t| if (try targetOutside(a, roots, cwd, t)) return true;
            } else if (target_flag and x.text[1] != '-') {
                if (clusterValue(args, &i, 't')) |t| {
                    target_given = true;
                    if (try targetOutside(a, roots, cwd, t)) return true;
                }
            }
            continue;
        }
        try paths.append(a, x);
    }
    const written: []const Word = switch (kind) {
        .after_first => if (skip_first and paths.items.len > 0) paths.items[1..] else paths.items,
        // With `-t` every path is a source.
        .last => if (target_given) paths.items[0..0] else if (paths.items.len > 0) paths.items[paths.items.len - 1 ..] else paths.items,
        else => paths.items,
    };
    for (written) |t| if (try targetOutside(a, roots, cwd, t)) return true;
    return false;
}

/// `sed -i`: every file named. Without `-i` it writes nothing itself.
fn sedOutside(a: std.mem.Allocator, roots: []const []const u8, cwd: ?[]const u8, args: []const Word) !bool {
    var in_place = false;
    var script_given = false;
    for (args) |x| {
        if (x.unknown or x.text.len < 2 or x.text[0] != '-') continue;
        if (std.mem.startsWith(u8, x.text, "--in-place")) in_place = true;
        if (x.text[1] == '-') continue;
        if (std.mem.indexOfScalar(u8, x.text, 'i') != null) in_place = true;
        if (x.text[x.text.len - 1] == 'e' or x.text[x.text.len - 1] == 'f') script_given = true;
    }
    if (!in_place) return false;
    var i: usize = 0;
    var skip_script = !script_given;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (!x.unknown and x.text.len > 1 and x.text[0] == '-') {
            const last = x.text[x.text.len - 1];
            if (x.text[1] != '-' and (last == 'e' or last == 'f')) i += 1;
            continue;
        }
        if (skip_script) {
            skip_script = false;
            continue;
        }
        if (try targetOutside(a, roots, cwd, x)) return true;
    }
    return false;
}

/// `find` with an action that writes: the folders it walks, and what
/// `-exec` runs.
fn findOutside(a: std.mem.Allocator, roots: []const []const u8, start: []const u8, cwd: *?[]const u8, args: []const Word, depth: u32) error{OutOfMemory}!bool {
    var acts = false;
    for (args, 0..) |x, i| {
        const t = x.text;
        if (std.mem.eql(u8, t, "-delete") or std.mem.startsWith(u8, t, "-fprint") or std.mem.eql(u8, t, "-fls")) acts = true;
        if (std.mem.startsWith(u8, t, "-exec") or std.mem.startsWith(u8, t, "-ok")) {
            acts = true;
            var words: std.ArrayList(Word) = .empty;
            for (args[i + 1 ..]) |y| {
                if (std.mem.eql(u8, y.text, ";") or std.mem.eql(u8, y.text, "+")) break;
                if (!std.mem.eql(u8, y.text, "{}")) try words.append(a, y);
            }
            if (try simpleOutside(a, roots, start, cwd, .{ .words = words.items, .redirects = &.{} }, depth + 1)) return true;
        }
    }
    if (!acts) return false;
    var walked = false;
    for (args) |x| {
        if (!x.unknown and x.text.len > 0 and (x.text[0] == '-' or x.text[0] == '(' or x.text[0] == '!')) break;
        walked = true;
        if (try targetOutside(a, roots, cwd.*, x)) return true;
    }
    if (walked) return false;
    return try targetOutside(a, roots, cwd.*, .{ .text = "." });
}

fn gitOutside(a: std.mem.Allocator, roots: []const []const u8, start: []const u8, cwd: ?[]const u8, args: []const Word) !bool {
    var here = cwd;
    var named = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (x.unknown) return true;
        if (std.mem.eql(u8, x.text, "-C")) {
            i += 1;
            if (i >= args.len) return false;
            here = try enter(a, here, args[i .. i + 1]);
            named = true;
            continue;
        }
        if (std.mem.eql(u8, x.text, "-c")) {
            i += 1;
            continue;
        }
        if (x.text.len > 0 and x.text[0] == '-') {
            // `--git-dir`, `--work-tree`: not the folder it seems.
            if (std.mem.startsWith(u8, x.text, "--git-dir") or std.mem.startsWith(u8, x.text, "--work-tree")) return true;
            continue;
        }
        if (git_readers.has(x.text)) return false;
        const rest = args[i + 1 ..];
        if (std.mem.eql(u8, x.text, "clone") or std.mem.eql(u8, x.text, "init")) {
            var paths: std.ArrayList(Word) = .empty;
            for (rest) |y| if (y.unknown or y.text.len == 0 or y.text[0] != '-') try paths.append(a, y);
            const needs = @as(usize, if (std.mem.eql(u8, x.text, "clone")) 2 else 1);
            // Without a folder it is made where git runs.
            const target: Word = if (paths.items.len >= needs) paths.items[paths.items.len - 1] else .{ .text = "." };
            return targetOutside(a, roots, here, target);
        }
        if (std.mem.eql(u8, x.text, "worktree")) {
            var paths: std.ArrayList(Word) = .empty;
            for (rest) |y| if (y.unknown or y.text.len == 0 or y.text[0] != '-') try paths.append(a, y);
            if (paths.items.len < 2 or git_worktree_readers.has(paths.items[0].text)) return false;
            const more = std.mem.eql(u8, paths.items[0].text, "move") and paths.items.len > 2;
            if (more and try targetOutside(a, roots, here, paths.items[2])) return true;
            return targetOutside(a, roots, here, paths.items[1]);
        }
        const dir = here orelse return true;
        if (!named and std.mem.eql(u8, dir, start)) return false;
        return outsideRoots(a, roots, dir, dir);
    }
    return false;
}

fn targetOutside(a: std.mem.Allocator, roots: []const []const u8, cwd: ?[]const u8, target: Word) !bool {
    if (target.unknown) return true;
    if (target.text.len == 0) return false;
    if (target.text[0] != '/' and cwd == null) return true;
    return outsideRoots(a, roots, cwd orelse "/", target.text);
}

fn outsideRoots(a: std.mem.Allocator, roots: []const []const u8, base: []const u8, path: []const u8) !bool {
    const abs = try std.fs.path.resolvePosix(a, &.{ base, path });
    for (roots) |root| if (rules.within(root, abs)) return false;
    if (std.mem.eql(u8, abs, "/dev/null") or std.mem.eql(u8, abs, "/dev/stdout") or std.mem.eql(u8, abs, "/dev/stderr") or rules.within("/dev/fd", abs)) return false;
    for ([_][]const u8{ "/tmp", "/var/tmp" }) |scratch| {
        if (!rules.within(scratch, abs)) continue;
        for (roots) |root| if (rules.within(scratch, root)) return true;
        return false;
    }
    return true;
}

/// A POSIX-shell reading of `command`, good enough to find words and
/// redirections. Null: it does not parse (an unterminated quote).
fn parse(a: std.mem.Allocator, command: []const u8) !?Parsed {
    var commands: std.ArrayList(Simple) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    var words: std.ArrayList(Word) = .empty;
    var redirects: std.ArrayList(Word) = .empty;
    var heredocs: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var unknown = false;
    const Next = enum { word, redirect, skip, heredoc };
    var next: Next = .word;

    const S = struct {
        fn flush(al: std.mem.Allocator, w: *std.ArrayList(u8), in: *bool, unk: *bool, n: *Next, ws: *std.ArrayList(Word), rs: *std.ArrayList(Word), hd: *std.ArrayList([]const u8)) !void {
            if (!in.*) return;
            const text = try al.dupe(u8, w.items);
            switch (n.*) {
                .word => try ws.append(al, .{ .text = text, .unknown = unk.* }),
                .redirect => try rs.append(al, .{ .text = text, .unknown = unk.* }),
                .skip => {},
                .heredoc => try hd.append(al, text),
            }
            n.* = .word;
            w.clearRetainingCapacity();
            in.* = false;
            unk.* = false;
        }
    };

    var i: usize = 0;
    while (i < command.len) {
        const ch = command[i];
        switch (ch) {
            ' ', '\t' => {
                try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
                i += 1;
            },
            '\n', '\r', ';', '|', '(', ')' => {
                try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
                if (words.items.len > 0 or redirects.items.len > 0) {
                    try commands.append(a, .{ .words = try words.toOwnedSlice(a), .redirects = try redirects.toOwnedSlice(a) });
                }
                i += 1;
                if (ch == '\n' and heredocs.items.len > 0) {
                    // The bodies are text, not commands.
                    for (heredocs.items) |delim| {
                        while (i < command.len) {
                            const end = std.mem.indexOfScalarPos(u8, command, i, '\n') orelse command.len;
                            const line = std.mem.trim(u8, command[i..end], " \t\r");
                            i = @min(end + 1, command.len);
                            if (std.mem.eql(u8, line, delim)) break;
                        }
                    }
                    heredocs.clearRetainingCapacity();
                }
            },
            '&' => {
                if (i + 1 < command.len and command[i + 1] == '>') {
                    // `&>x`, `&>>x`
                    try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
                    i += 2;
                    if (i < command.len and command[i] == '>') i += 1;
                    next = .redirect;
                    continue;
                }
                try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
                if (words.items.len > 0 or redirects.items.len > 0) {
                    try commands.append(a, .{ .words = try words.toOwnedSlice(a), .redirects = try redirects.toOwnedSlice(a) });
                }
                i += 1;
            },
            '>' => {
                // A number right before it is a file descriptor, not a word.
                if (in_word and !unknown and word.items.len > 0 and allDigits(word.items)) {
                    word.clearRetainingCapacity();
                    in_word = false;
                } else try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
                i += 1;
                // `>(…)`: process substitution, not judged.
                if (i < command.len and command[i] == '(') return null;
                if (i < command.len and (command[i] == '>' or command[i] == '|')) i += 1;
                if (i < command.len and command[i] == '&') {
                    i += 1;
                    // `2>&1`: a descriptor, nothing written. `>& file` is a file.
                    if (i < command.len and (std.ascii.isDigit(command[i]) or command[i] == '-')) next = .skip else next = .redirect;
                } else next = .redirect;
            },
            '<' => {
                try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
                i += 1;
                // `<(…)`: process substitution, not judged.
                if (i < command.len and command[i] == '(') return null;
                if (i + 1 < command.len and command[i] == '<' and command[i + 1] == '<') {
                    i += 2; // a here-string
                    next = .skip;
                } else if (i < command.len and command[i] == '<') {
                    i += 1;
                    if (i < command.len and command[i] == '-') i += 1;
                    next = .heredoc;
                } else next = .skip;
            },
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, command, i + 1, '\'') orelse return null;
                try word.appendSlice(a, command[i + 1 .. end]);
                in_word = true;
                i = end + 1;
            },
            '"' => {
                i += 1;
                in_word = true;
                while (true) {
                    if (i >= command.len) return null;
                    const q = command[i];
                    if (q == '"') {
                        i += 1;
                        break;
                    }
                    if (q == '\\' and i + 1 < command.len) {
                        try word.append(a, command[i + 1]);
                        i += 2;
                    } else if (q == '$' or q == '`') {
                        unknown = true;
                        i = try substitution(a, command, i, &nested) orelse return null;
                    } else {
                        try word.append(a, q);
                        i += 1;
                    }
                }
            },
            '\\' => {
                if (i + 1 < command.len and command[i + 1] != '\n') try word.append(a, command[i + 1]);
                in_word = true;
                i += 2;
            },
            '$', '`' => {
                unknown = true;
                in_word = true;
                i = try substitution(a, command, i, &nested) orelse return null;
            },
            '~' => {
                if (!in_word) unknown = true;
                try word.append(a, ch);
                in_word = true;
                i += 1;
            },
            else => {
                try word.append(a, ch);
                in_word = true;
                i += 1;
            },
        }
    }
    try S.flush(a, &word, &in_word, &unknown, &next, &words, &redirects, &heredocs);
    if (words.items.len > 0 or redirects.items.len > 0) {
        try commands.append(a, .{ .words = try words.toOwnedSlice(a), .redirects = try redirects.toOwnedSlice(a) });
    }
    return .{ .commands = commands.items, .nested = nested.items };
}

fn allDigits(text: []const u8) bool {
    for (text) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// At `$` or a backtick: where the expansion ends; `$(…)` and `` `…` `` go
/// to `nested`. Null: it never closes.
fn substitution(a: std.mem.Allocator, command: []const u8, at: usize, nested: *std.ArrayList([]const u8)) !?usize {
    if (command[at] == '`') {
        const end = std.mem.indexOfScalarPos(u8, command, at + 1, '`') orelse return null;
        try nested.append(a, command[at + 1 .. end]);
        return end + 1;
    }
    if (at + 1 >= command.len) return at + 1;
    const open = command[at + 1];
    if (open == '(' or open == '{') {
        const close: u8 = if (open == '(') ')' else '}';
        var depth: u32 = 1;
        var i = at + 2;
        while (i < command.len) : (i += 1) {
            if (command[i] == open) depth += 1;
            if (command[i] == close) depth -= 1;
            if (depth == 0) {
                if (open == '(') try nested.append(a, command[at + 2 .. i]);
                return i + 1;
            }
        }
        return null;
    }
    var i = at + 1;
    while (i < command.len and (std.ascii.isAlphanumeric(command[i]) or command[i] == '_')) i += 1;
    return if (i == at + 1) at + 2 else i;
}

const testing = std.testing;

fn judged(command: []const u8) !bool {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return writesOutside(arena.allocator(), &.{ "/org/a", "/org/b" }, "/org", command);
}

test "command_writes: writes outside the scope, by program and through the shell" {
    for ([_][]const u8{
        "rm c/x",
        "rm -rf /org/c",
        "rm -rf a/../c",
        "rm a/x c/y",
        "/bin/rm c/x",
        "sudo rm c/x",
        "env FOO=1 rm c/x",
        "timeout 5 rm c/x",
        "FOO=1 rm c/x",
        "touch README.md",
        "mkdir -p c/new",
        "tee c/log",
        "tee a/log c/log",
        "chmod +x c/run",
        "chown me c/run",
        "cp a/x c/y",
        "cp -t c a/x",
        "cp --target-directory=c a/x",
        "cp --target-directory c a/x",
        "cp --target c a/x",
        "mv --target-directory c a/x",
        "mv c/x a/y",
        "mv a/x c/y",
        "ln -s a/x c/y",
        "dd if=a/x of=c/y",
        "sed -i s/a/b/ c/x",
        "sed -i.bak -e s/a/b/ c/x",
        "sed -Ei s/a/b/ a/ok c/x",
        "sed --in-place s/a/b/ c/x",
        "find c -delete",
        "find c -name x -exec rm {} ;",
        "find . -delete",
        "echo x > c/y",
        "echo x >> c/y",
        "echo x >c/y",
        "echo x 2> c/log",
        "zig build &> c/log",
        "cat a/x | tee c/y",
        "true; rm c/x",
        "true && rm c/x",
        "false || rm c/x",
        "true\nrm c/x",
        "if true; then rm c/x; fi",
        "(rm c/x)",
        "bash -c 'rm c/x'",
        "/usr/bin/zsh -lc 'touch c/cmd.txt'",
        "sh -c \"echo x > c/y\"",
        "eval rm c/x",
        "eval true",
        "echo $(rm c/x)",
        "echo `rm c/x`",
        "cd c && rm x",
        "cd /org/c; touch y",
        "cd c && make",
        "cd c && zig build",
        "git -C c commit -m x",
        "git -C /org/c clean -fd",
        "cd c && git commit -m x",
        "cd c",
        "cd /org/c",
        "cd c && ls",
        "cd c && git log",
        "cd /",
        "cd",
        "cd -",
        "popd",
        "pushd c",
        "sudo -u root rm c/x",
        "echo x >& c/y",
        "cat <(rm c/x)",
        "cat <(echo x)",
        "zig build > >(tee log)",
        "echo 'rm c/x' | sh",
        "cat script | bash -s",
        "$RM c/x",
        "$(which rm) c/x",
        "cp -tc a/x",
        "cp -rt c a/x",
        "chmod -x c/run",
        "chmod --reference=a/run c/run",
        "chown --reference=a/run c/run",
        "sort -o c/x a/y",
        "sort -oc/x a/y",
        "sort --output=c/x a/y",
        "uniq a/y c/x",
        "git clone u c/new",
        "git clone u",
        "git init c/new",
        "git worktree add c/new",
        "find a -exec cp {} c/ +",
        "ls | xargs sh -c 'echo'",
        "echo x > /dev/sda",
        "dd if=a/x of=/dev/sda",
        "git --git-dir=c/.git commit",
        // Cannot be judged: outside.
        "rm $X",
        "rm \"$X/y\"",
        "rm `cat list`",
        "rm ~/x",
        "cd $X && rm y",
        "echo x > $OUT",
        "ls | xargs rm",
        "rm 'unterminated",
        "bash -c $SCRIPT",
    }) |command| {
        testing.expect(try judged(command)) catch |err| {
            std.debug.print("should be outside: {s}\n", .{command});
            return err;
        };
    }
}

test "command_writes: reads and in-scope writes are not outside" {
    for ([_][]const u8{
        "",
        "ls c",
        "cat c/x",
        "grep -r foo c",
        "rg foo c/",
        "cat c/x | wc -l",
        "rm a/x",
        "rm -rf /org/b/zig-out",
        "touch a/x b/y",
        "mkdir -p a/new",
        "cp c/x a/y",
        "ln -s /org/c/x a/y",
        "tee a/log",
        "chmod +x a/run",
        "chmod 644 a/run",
        "mv a/x b/y",
        "dd if=c/x of=a/y",
        "sed s/a/b/ c/x",
        "sed -n 1,5p c/x",
        "sed -i s/a/b/ a/x",
        "sed -i.bak -e s/c/d/ a/x",
        "find c -name x",
        "find a -delete",
        "echo x > a/y",
        "echo x > /dev/null",
        "zig build 2>&1 | tail",
        "zig build 2> /dev/null",
        "zig build > /tmp/log",
        "cd a && rm x",
        "cd a && make",
        "cd /org/b; touch y",
        "cd /org",
        "cd /org && ls",
        "git -C c log",
        "git -C c status --short",
        "git -C a commit -m x",
        "git status",
        "zig build test",
        "make",
        "python3 x.py",
        "bash scripts/check.sh",
        "sudo -u root ls c",
        "sort c/x",
        "sort -o a/x c/y",
        "uniq c/x",
        "uniq c/x a/y",
        "git clone u a/new",
        "git worktree list",
        "git worktree add a/new origin/main",
        "find a -name x -exec rm {} +",
        "echo x > /dev/stderr",
        "echo x >&2",
        "echo x > /dev/fd/3",
        "chmod -x a/run",
        "cp -t a c/x",
        "cp --target-directory a c/x",
        "cp --target-directory=a c/x",
        "/usr/bin/zsh -lc 'touch a/cmd.txt'",
        "bash -c 'rm a/x'",
        "cat > a/y <<EOF\nrm c/x\nEOF",
        "cat <<< 'rm c/x'",
        "echo 'rm c/x'",
        "echo \"> c/x\"",
    }) |command| {
        testing.expect(!try judged(command)) catch |err| {
            std.debug.print("should not be outside: {s}\n", .{command});
            return err;
        };
    }
}

test "command_writes: a writable root under /tmp keeps its siblings outside" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try writesOutside(a, &.{"/tmp/w/a"}, "/tmp/w", "rm c/x"));
    try testing.expect(!try writesOutside(a, &.{"/tmp/w/a"}, "/tmp/w", "rm a/x"));
    try testing.expect(!try writesOutside(a, &.{"/org/a"}, "/org", "rm /tmp/x"));
}

test "command_writes: the folders a lasting shell may be left in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots: []const []const u8 = &.{"/org/a"};
    var cwds: std.ArrayList(?[]const u8) = .empty;
    try cwds.append(a, "/org");

    // No `cd`, or one that does not last.
    try cwdsAfter(a, &cwds, "zig build");
    try cwdsAfter(a, &cwds, "bash -c 'cd c'");
    try cwdsAfter(a, &cwds, "echo $(cd c)");
    try testing.expectEqual(@as(usize, 1), cwds.items.len);

    // `cd c` may have failed: both folders stay, and `touch y` is outside
    // from c, though `touch a/y` from the start would not be.
    try cwdsAfter(a, &cwds, "cd c");
    try testing.expectEqual(@as(usize, 2), cwds.items.len);
    try testing.expectEqualStrings("/org/c", cwds.items[1].?);
    try testing.expect(try writesOutsideFrom(a, roots, "/org", cwds.items, "touch /org/a/ok; touch y"));
    try testing.expect(try writesOutsideFrom(a, roots, "/org", cwds.items, "zig build"));
    try testing.expect(!try writesOutsideFrom(a, roots, "/org", cwds.items, "touch /org/a/y"));
    try testing.expect(!try writesOutsideFrom(a, roots, "/org", cwds.items, "ls"));

    // In scope: a program may run from there, a relative write from the
    // start still may not be proven.
    var inside: std.ArrayList(?[]const u8) = .empty;
    try inside.append(a, "/org");
    try cwdsAfter(a, &inside, "cd a && zig build");
    try testing.expect(!try writesOutsideFrom(a, roots, "/org", inside.items, "zig build"));
    try testing.expect(try writesOutsideFrom(a, roots, "/org", inside.items, "touch y"));

    // Unknown from here on: relative writes and unknown programs ask.
    for ([_][]const u8{ "cd $X", "cd", "cd a; cd b", "popd", "cd 'x" }) |command| {
        var lost: std.ArrayList(?[]const u8) = .empty;
        try lost.append(a, "/org");
        try cwdsAfter(a, &lost, command);
        try testing.expectEqual(@as(?[]const u8, null), lost.items[0]);
        try testing.expect(try writesOutsideFrom(a, roots, "/org", lost.items, "touch a/y"));
        try testing.expect(try writesOutsideFrom(a, roots, "/org", lost.items, "make"));
        try testing.expect(!try writesOutsideFrom(a, roots, "/org", lost.items, "touch /org/a/y"));
        try testing.expect(!try writesOutsideFrom(a, roots, "/org", lost.items, "ls"));
    }
}
