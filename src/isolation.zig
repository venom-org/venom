//! Agent isolation: what `agent.spawn` makes so an
//! agent does not work in the user's checkout.
//!
//! - `worktree` (default, `agents.isolation`): one git worktree per repo in
//!   scope, a sibling of the repo: `<repo>-<n>` (e.g. `venom-std-246`) when the
//!   agent is linked to issue `<n>`, the hub convention, else
//!   `<repo>-<agent-id>`; on the given branch or `venom/<agent-id>`, started
//!   from the repo's `HEAD`. Worktrees are added locked, with the reason
//!   `venom: agent <id>`, so workspace discovery skips them and
//!   `git worktree prune` leaves them alone; cleanup unlocks them.
//! - `in_place`: nothing is made; the agent works in the repos themselves.
//! - `copy`: a plain copy (`cp -a`) of each repo, named like a worktree,
//!   marked with `.git/venom-copy` so discovery skips it. Limits: the whole
//!   folder is copied (untracked and ignored files, build output, the full
//!   `.git`), so it is slow and large for big repos; the copy is an
//!   independent repo on whatever was checked out (no branch is made, and
//!   commits reach the original only by push or fetch); a repo that is
//!   itself a linked worktree (`.git` file) cannot be copied.
//!
//! `plan` checks everything (targets free, repos usable, branches free)
//! before `create` makes anything, so a collision fails with a stable error
//! and leaves nothing behind; `create` undoes what it made if a later repo
//! fails. `spawn --dry-run` returns the plan alone.
//!
//! Tests point git only at repos they made in temp dirs. `plan` refuses a
//! folder that is not itself a git root, so git never walks up into an
//! enclosing repo. git runs synchronously on the caller's (reactor) thread.
const std = @import("std");
const config = @import("config.zig");
const eventlog = @import("eventlog/root.zig");
const copy_marker = @import("workspaces.zig").copy_marker;
const agent_scope = eventlog.agent_scope;

pub const Mode = config.Isolation;
pub const Worktree = eventlog.events.Worktree;

/// One worktree or copy to make.
pub const Planned = struct {
    /// Relative to the workspace ("." for its root).
    repo: []const u8,
    /// The repo's absolute path.
    source: []const u8,
    /// The new folder's absolute path.
    path: []const u8,
    /// Relative to the workspace when inside it, else absolute (the
    /// `worktrees` list).
    name: []const u8,
    /// Null for a copy.
    branch: ?[]const u8,
    /// The branch is made from `HEAD` (false: an existing branch is
    /// checked out).
    new_branch: bool,
};

/// Why `plan` or `create` failed. Strings live in the caller's arena.
pub const Failure = union(enum) {
    /// The target folder already exists.
    exists: struct { repo: []const u8, path: []const u8 },
    /// `venom/<id>` already exists in the repo.
    branch_exists: struct { repo: []const u8, branch: []const u8 },
    /// The branch is checked out in another worktree.
    checked_out: struct { repo: []const u8, branch: []const u8, path: []const u8 },
    /// Not a branch name git accepts.
    invalid_branch: []const u8,
    /// The repo cannot be copied (a linked worktree).
    linked_copy: []const u8,
    /// git (or cp) failed, or the folder is not a usable repo.
    git: struct { repo: []const u8, reason: []const u8 },
};

/// The number that names a linked issue's folders, from `<n>`, `#<n>` or
/// `owner/repo#<n>`. Null when it is malformed.
pub fn issueSuffix(a: std.mem.Allocator, issue: []const u8) !?[]const u8 {
    var num = issue;
    if (std.mem.lastIndexOfScalar(u8, issue, '#')) |hash| {
        const repo = issue[0..hash];
        if (repo.len != 0 and !validRepoRef(repo)) return null;
        num = issue[hash + 1 ..];
    }
    if (num.len == 0 or num.len > 12 or num[0] == '0') return null;
    for (num) |ch| if (!std.ascii.isDigit(ch)) return null;
    return try a.dupe(u8, num);
}

/// `owner/repo`, in the characters GitHub allows.
fn validRepoRef(ref: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, ref, '/') orelse return false;
    const owner = ref[0..slash];
    const repo = ref[slash + 1 ..];
    if (owner.len == 0 or owner.len > 39 or owner[0] == '-') return false;
    for (owner) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    if (repo.len == 0 or repo.len > 100 or repo[0] == '.') return false;
    for (repo) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}

/// The default branch of an agent: `venom/<agent-id>`.
pub fn defaultBranch(a: std.mem.Allocator, agent: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "venom/{s}", .{agent});
}

pub const Request = struct {
    mode: Mode,
    agent: []const u8,
    workspace: []const u8,
    /// Relative to `workspace`.
    repos: []const []const u8,
    /// Issue number (`issueSuffix`), if linked.
    issue: ?[]const u8 = null,
    /// Explicit branch; existing branches are
    /// reused when no other worktree has them checked out.
    branch: ?[]const u8 = null,
};

/// What `create` would make for `r`, checked against the disk and git;
/// nothing is changed. Null on failure, with `fail` set. `in_place`: empty.
pub fn plan(a: std.mem.Allocator, io: std.Io, r: Request, fail: *Failure) !?[]const Planned {
    if (r.mode == .in_place) return &.{};
    const suffix = r.issue orelse r.agent;
    const branch: ?[]const u8 = if (r.mode == .worktree) r.branch orelse try defaultBranch(a, r.agent) else null;
    if (branch) |b| if (!try validBranch(a, io, b)) {
        fail.* = .{ .invalid_branch = b };
        return null;
    };
    const out = try a.alloc(Planned, r.repos.len);
    for (r.repos, out) |repo, *p| {
        const source = try agent_scope.repoPath(a, r.workspace, repo);
        const dir = std.fs.path.dirnamePosix(source) orelse {
            fail.* = .{ .git = .{ .repo = repo, .reason = "the filesystem root cannot have a sibling" } };
            return null;
        };
        const path = try std.fmt.allocPrint(a, "{s}{s}{s}-{s}", .{ dir, if (std.mem.eql(u8, dir, "/")) "" else "/", std.fs.path.basenamePosix(source), suffix });
        if (exists(io, path)) {
            fail.* = .{ .exists = .{ .repo = repo, .path = path } };
            return null;
        }
        const name = if (eventlog.workspaces.within(r.workspace, path)) path[r.workspace.len + @intFromBool(!std.mem.eql(u8, r.workspace, "/")) ..] else path;
        p.* = .{ .repo = repo, .source = source, .path = path, .name = name, .branch = branch, .new_branch = false };
        switch (r.mode) {
            .in_place => unreachable,
            .copy => {
                const st = std.Io.Dir.cwd().statFile(io, try std.fmt.allocPrint(a, "{s}/.git", .{source}), .{ .follow_symlinks = false }) catch |err| {
                    fail.* = .{ .git = .{ .repo = repo, .reason = @errorName(err) } };
                    return null;
                };
                if (st.kind != .directory) {
                    fail.* = .{ .linked_copy = repo };
                    return null;
                }
            },
            .worktree => if (!try checkRepo(a, io, p, r.branch == null, fail)) return null,
        }
    }
    return out;
}

/// The worktree checks for one repo: a git root of its own with a commit,
/// and the branch free. Sets `p.new_branch`.
fn checkRepo(a: std.mem.Allocator, io: std.Io, p: *Planned, default_branch: bool, fail: *Failure) !bool {
    // A folder that is not itself a git root would make git act on an
    // enclosing repo: refuse it.
    const top = try git(a, io, p.source, &.{ "rev-parse", "--show-toplevel" });
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, p.source, a) catch |err| {
        fail.* = .{ .git = .{ .repo = p.repo, .reason = @errorName(err) } };
        return false;
    };
    if (!top.ok or !std.mem.eql(u8, std.mem.trimEnd(u8, top.stdout, "\n"), real)) {
        fail.* = .{ .git = .{ .repo = p.repo, .reason = if (top.ok) "not a git root" else top.reason() } };
        return false;
    }
    const head = try git(a, io, p.source, &.{ "rev-parse", "--verify", "--quiet", "HEAD^{commit}" });
    if (!head.ok) {
        fail.* = .{ .git = .{ .repo = p.repo, .reason = "the repo has no commit" } };
        return false;
    }
    const b = p.branch.?;
    const ref = try std.fmt.allocPrint(a, "refs/heads/{s}", .{b});
    const known = try git(a, io, p.source, &.{ "rev-parse", "--verify", "--quiet", ref });
    if (!known.ok) {
        // git keeps branches as paths, so `foo/bar` and `foo` cannot both be:
        // `worktree add -b` would fail. Said here, so a dry run reports it.
        if (try refConflict(a, io, p.source, b)) |other| {
            fail.* = .{ .git = .{ .repo = p.repo, .reason = try std.fmt.allocPrint(a, "branch {s} conflicts with existing branch {s}", .{ b, other }) } };
            return false;
        }
        p.new_branch = true;
        return true;
    }
    if (default_branch) {
        fail.* = .{ .branch_exists = .{ .repo = p.repo, .branch = b } };
        return false;
    }
    // An existing branch (an issue's, being resumed) is reused unless a
    // worktree has it checked out.
    const list = try git(a, io, p.source, &.{ "worktree", "list", "--porcelain" });
    if (!list.ok) {
        fail.* = .{ .git = .{ .repo = p.repo, .reason = list.reason() } };
        return false;
    }
    var path: []const u8 = "";
    var it = std.mem.splitScalar(u8, list.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) path = line["worktree ".len..];
        if (std.mem.startsWith(u8, line, "branch ") and std.mem.eql(u8, line["branch ".len..], ref)) {
            fail.* = .{ .checked_out = .{ .repo = p.repo, .branch = b, .path = path } };
            return false;
        }
    }
    return true;
}

/// The existing branch that a new branch `name` cannot live beside: one of
/// its parents (`foo` for `foo/bar`), or one under it (`foo/bar` for `foo`).
fn refConflict(a: std.mem.Allocator, io: std.Io, repo: []const u8, name: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, i, '/')) |slash| : (i = slash + 1) {
        const parent = name[0..slash];
        const r = try git(a, io, repo, &.{ "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(a, "refs/heads/{s}", .{parent}) });
        if (r.ok) return parent;
    }
    const under = try git(a, io, repo, &.{ "for-each-ref", "--count=1", "--format=%(refname:short)", try std.fmt.allocPrint(a, "refs/heads/{s}/", .{name}) });
    const found = std.mem.trimEnd(u8, under.stdout, "\n");
    return if (under.ok and found.len > 0) found else null;
}

/// Makes every planned worktree or copy, in order. On failure the ones
/// already made are removed again (and branches it made deleted), `fail`
/// is set and false returned.
pub fn create(a: std.mem.Allocator, io: std.Io, agent: []const u8, planned: []const Planned, fail: *Failure) !bool {
    const reason = try std.fmt.allocPrint(a, "venom: agent {s}", .{agent});
    for (planned, 0..) |p, i| {
        const made = if (p.branch) |b| blk: {
            const r = if (p.new_branch)
                try git(a, io, p.source, &.{ "worktree", "add", "--quiet", "--lock", "--reason", reason, "-b", b, p.path, "HEAD" })
            else
                try git(a, io, p.source, &.{ "worktree", "add", "--quiet", "--lock", "--reason", reason, p.path, b });
            break :blk r;
        } else try copy(a, io, p, reason);
        if (!made.ok) {
            fail.* = .{ .git = .{ .repo = p.repo, .reason = made.reason() } };
            // A failed `worktree add` may leave a half-made folder or
            // branch; undo this one too.
            remove(a, io, planned[0 .. i + 1]);
            return false;
        }
    }
    return true;
}

/// Removes planned worktrees or copies that `create` made (best effort).
pub fn remove(a: std.mem.Allocator, io: std.Io, planned: []const Planned) void {
    var i = planned.len;
    while (i > 0) {
        i -= 1;
        const p = planned[i];
        if (p.branch) |b| {
            _ = git(a, io, p.source, &.{ "worktree", "remove", "--force", "--force", p.path }) catch {};
            _ = git(a, io, p.source, &.{ "worktree", "prune" }) catch {};
            if (p.new_branch) _ = git(a, io, p.source, &.{ "branch", "-D", b }) catch {};
        } else std.Io.Dir.cwd().deleteTree(io, p.path) catch {};
    }
}

/// The worktree records the agent keeps (`agent.created`).
pub fn records(a: std.mem.Allocator, planned: []const Planned) ![]const Worktree {
    const out = try a.alloc(Worktree, planned.len);
    for (planned, out) |p, *o| o.* = .{ .repo = p.repo, .path = p.path, .branch = p.branch };
    return out;
}

/// Where an agent starts once isolated: `cwd` moved into the worktree of
/// the repo holding it (the deepest), or the one worktree when the scope
/// has a single repo and `cwd` is the workspace root; else `cwd`.
pub fn mapCwd(a: std.mem.Allocator, workspace: []const u8, planned: []const Planned, cwd: []const u8) ![]const u8 {
    var best: ?Planned = null;
    for (planned) |p| {
        if (!eventlog.workspaces.within(p.source, cwd)) continue;
        if (best == null or p.source.len > best.?.source.len) best = p;
    }
    if (best) |p| {
        if (cwd.len == p.source.len) return p.path;
        const rest = cwd[p.source.len + @intFromBool(!std.mem.eql(u8, p.source, "/")) ..];
        return std.fmt.allocPrint(a, "{s}/{s}", .{ p.path, rest });
    }
    if (planned.len == 1 and std.mem.eql(u8, cwd, workspace)) return planned[0].path;
    return cwd;
}

pub fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| return err != error.FileNotFound;
    return true;
}

fn validBranch(a: std.mem.Allocator, io: std.Io, name: []const u8) !bool {
    if (name.len == 0 or name[0] == '-' or std.mem.indexOf(u8, name, "@{") != null) return false;
    // git refuses `HEAD` as a branch; `@` and `refs/...` it takes, and makes
    // refs nobody means (`refs/heads/refs/heads/z`).
    if (std.mem.eql(u8, name, "HEAD") or std.mem.eql(u8, name, "@") or std.mem.startsWith(u8, name, "refs/")) return false;
    const r = try run(a, io, &.{ "git", "check-ref-format", try std.fmt.allocPrint(a, "refs/heads/{s}", .{name}) });
    return r.ok;
}

fn copy(a: std.mem.Allocator, io: std.Io, p: Planned, reason: []const u8) !Ran {
    const r = try run(a, io, &.{ "cp", "-a", "--", p.source, p.path });
    if (!r.ok) return r;
    const marker = try std.fmt.allocPrint(a, "{s}/.git/{s}", .{ p.path, copy_marker });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = try std.fmt.allocPrint(a, "{s}\n", .{reason}) }) catch |err|
        return .{ .ok = false, .stdout = "", .stderr = @errorName(err) };
    return r;
}

pub const Ran = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,

    pub fn reason(self: Ran) []const u8 {
        const t = std.mem.trim(u8, self.stderr, " \t\r\n");
        return if (t.len > 0) t else "failed";
    }
};

fn git(a: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) !Ran {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "-C", repo });
    try argv.appendSlice(a, args);
    return run(a, io, argv.items);
}

/// Runs `argv`; a missing program is a failure, not an error.
fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Ran {
    const r = std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 16) }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .ok = false, .stdout = "", .stderr = try std.fmt.allocPrint(a, "{s}: {s}", .{ argv[0], @errorName(err) }) },
    };
    return .{ .ok = r.term.success(), .stdout = r.stdout, .stderr = r.stderr };
}

const testing = std.testing;

test "isolation: issue suffix and cwd mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "246", "#246", "acme/app#246", "a/b.c_d-e#246" }) |good| try testing.expectEqualStrings("246", (try issueSuffix(a, good)).?);
    for ([_][]const u8{ "", "#", "0", "012", "-12", "1a", "12 ", "ABC-246", "abc-246", "app#246", "/app#1", "a/#1", "a/b/c#1", "../x#1", "a/..#1", "-a/b#1", "a/b#", "a/b#1#2", "1234567890123" }) |bad| try testing.expect(try issueSuffix(a, bad) == null);
    const planned = [_]Planned{
        .{ .repo = "a", .source = "/w/a", .path = "/w/a-a1", .name = "a-a1", .branch = "venom/a1", .new_branch = true },
        .{ .repo = "b", .source = "/w/b", .path = "/w/b-a1", .name = "b-a1", .branch = "venom/a1", .new_branch = true },
    };
    try testing.expectEqualStrings("/w", try mapCwd(a, "/w", &planned, "/w"));
    try testing.expectEqualStrings("/w/b-a1", try mapCwd(a, "/w", &planned, "/w/b"));
    try testing.expectEqualStrings("/w/a-a1/src/x", try mapCwd(a, "/w", &planned, "/w/a/src/x"));
    try testing.expectEqualStrings("/w/a-a1", try mapCwd(a, "/w", planned[0..1], "/w"));
    const root = [_]Planned{.{ .repo = ".", .source = "/w", .path = "/w-a1", .name = "/w-a1", .branch = "venom/a1", .new_branch = true }};
    try testing.expectEqualStrings("/w-a1/src", try mapCwd(a, "/w", &root, "/w/src"));
}
