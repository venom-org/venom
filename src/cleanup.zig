//! Worktree cleanup: archiving keeps an agent's
//! worktrees; they go when their PR is merged or by an explicit clean.
//!
//! The rule everything here serves: a worktree or copy holding work that
//! exists nowhere else is never removed. It is kept and reported. Whenever
//! that cannot be established (git failed, `gh` said something odd, the
//! folder is not what the log says) the answer is to keep it.
//!
//! A worktree goes only if all of these hold, checked in this order:
//!
//! 1. It is still ours: git lists it at that path, locked with the reason
//!    `venom: agent <id>` (a later agent can reuse the path; a copy carries
//!    the same reason in its marker). Otherwise `not_ours`.
//! 2. Nothing uncommitted: `git status --porcelain` is empty (`uncommitted`).
//!    Ignored files do not count: they are build output and the like, and
//!    `git worktree remove` does not count them either.
//! 3. No merge, rebase, cherry-pick, revert or bisect is under way
//!    (`operation_in_progress`).
//! 4. Nothing unpushed: every commit of `HEAD` (which may be detached, or on
//!    a branch the agent switched to), of the agent's branch and of refs only
//!    this worktree has (`refs/worktree/*`) is on another local branch, on a
//!    branch a remote has right now (`git ls-remote`), or in the head of a
//!    merged PR. Remote-tracking refs prove nothing: one can outlive its
//!    branch until the next `fetch --prune`, which would then drop the
//!    commits. A remote that cannot be reached is `remote_unavailable`. A
//!    remote head this clone has not fetched proves nothing either: the
//!    commits stay `unpushed` until a fetch. The merged PR is what makes
//!    squash merges work: the squash is a new commit and the host usually
//!    deletes the head branch, so the branch's commits are on no ref at all;
//!    a merged PR whose `headRefOid` contains them says they arrived. A
//!    commit made after that head is still `unpushed`.
//!
//! The checks run with their config pinned (`pinned`), since
//! `status.showUntrackedFiles=no` and the like would hide changes from them
//! and from `git worktree remove` alike; paths marked assume-unchanged or
//! skip-worktree count as uncommitted.
//!
//! Every git command goes through `safe_git.run`, since the repo is the
//! agent's to write: no filter, hook or fsmonitor command of the repo's
//! runs, the daemon's `GIT_*` environment is not inherited, and a command
//! is cut off at one absolute deadline.
//!
//! The removal itself is `git worktree unlock` then `git worktree remove`
//! without `--force`, so git refuses on its own if the tree changed; the
//! lock is put back if it does. Only this worktree's entry goes, and only the
//! local branch is deleted, never a remote one.
//!
//! A registered folder that is missing is checked the same way from what git
//! keeps for it, before anything is touched. It may only be out of reach for
//! now, holding uncommitted work: `merged` leaves it (`folder_missing`), and
//! only an explicit clean lifts the registration, once its commits are safe.
//!
//! `explicit` removes whatever passes these. `merged` also needs a merged
//! PR whose head contains `HEAD` and the branch (`not_merged`); without a
//! working `gh` nothing is removed (`gh_unavailable`), and explicit clean
//! still works for anything pushed.
//!
//! All of it runs on the reactor thread, so every git and `gh` command has a
//! timeout (a timeout is a failure, so the worktree stays), `gh` and the
//! remotes are asked only when their answer matters and once per repo per
//! call when they fail, and a call past `Cleaner.deadline_ms` starts on no
//! more worktrees (`timed_out`).
//!
//! Tests point this only at repos they made in temp dirs (cleanup_tests.zig).
const std = @import("std");
const supervisor = @import("supervisor");
const isolation = @import("isolation.zig");
const safe_git = @import("safe_git.zig");
const eventlog = @import("eventlog/root.zig");
const agent_scope = eventlog.agent_scope;
const copy_marker = @import("workspaces.zig").copy_marker;
const Worktree = eventlog.events.Worktree;

pub const Mode = enum { explicit, merged };

/// Why a worktree was kept. The tag is the stable `reason` of the verbs.
pub const Reason = enum {
    uncommitted,
    unpushed,
    operation_in_progress,
    not_ours,
    agent_active,
    not_merged,
    gh_unavailable,
    remote_unavailable,
    folder_missing,
    timed_out,
    git,
};

/// What happened to one worktree or copy.
pub const Entry = struct {
    agent: []const u8,
    repo: []const u8,
    path: []const u8,
    branch: ?[]const u8 = null,
    /// `removed`, `kept`, or `gone` (the folder was already not there).
    outcome: []const u8,
    /// Why it was kept.
    reason: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    branch_deleted: bool = false,
    /// The merged PR that contains the work, if one was needed or asked for.
    pr: ?[]const u8 = null,

    pub fn kept(self: Entry) bool {
        return std.mem.eql(u8, self.outcome, "kept");
    }
};

/// The operations git keeps a state file for, per worktree.
const operations = [_][]const u8{ "rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG" };

/// Config that would change what the checks see. Set to what git does
/// when none is given. `core.fileMode=true` may report changes on a
/// filesystem without modes: kept, which is the safe way to be wrong.
pub const pinned = [_][]const u8{
    "-c", "status.showUntrackedFiles=normal",
    "-c", "status.branch=false",
    "-c", "core.untrackedCache=false",
    "-c", "core.fileMode=true",
    "-c", "core.ignoreStat=false",
    "-c", "core.checkStat=default",
    "-c", "core.trustctime=true",
};

/// What a repo's remotes have now.
const Remotes = struct {
    /// Remote branch heads this clone has as ref tips, deduplicated.
    oids: []const []const u8 = &.{},
    /// Why a remote did not answer (the last one, if several).
    down: ?[]const u8 = null,
};

pub const Cleaner = struct {
    /// Everything returned lives here.
    a: std.mem.Allocator,
    io: std.Io,
    /// The `gh` program.
    gh: []const u8 = "gh",
    gh_timeout_ms: i64 = 15_000,
    /// One local git command.
    git_timeout_ms: i64 = 30_000,
    /// `git worktree remove`, which deletes the tree: cutting it short
    /// would leave half a worktree.
    remove_timeout_ms: i64 = 120_000,
    /// `git ls-remote`, per remote.
    remote_timeout_ms: i64 = 15_000,
    /// No worktree is started on after this (`supervisor.monotonicMs`).
    deadline_ms: i64 = std.math.maxInt(i64),
    /// Why `gh` failed earlier in this call, per repo.
    gh_down: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// What the remotes said earlier in this call, per repo.
    remotes: std.StringHashMapUnmanaged(Remotes) = .empty,

    /// The entry for a worktree that was left alone because its agent still
    /// runs (or a sub-agent does).
    pub fn active(agent: []const u8, w: Worktree) Entry {
        return .{ .agent = agent, .repo = w.repo, .path = w.path, .branch = w.branch, .outcome = "kept", .reason = @tagName(Reason.agent_active), .detail = "the agent or a sub-agent has not stopped; run agent clean once it is archived" };
    }

    /// Cleans one worktree or copy of `agent` if that is safe.
    pub fn clean(self: *Cleaner, agent: []const u8, workspace: []const u8, w: Worktree, mode: Mode) !Entry {
        const source = try agent_scope.repoPath(self.a, workspace, w.repo);
        const base: Entry = .{ .agent = agent, .repo = w.repo, .path = w.path, .branch = w.branch, .outcome = "kept" };
        if (supervisor.monotonicMs() > self.deadline_ms) return keep(base, .timed_out, "this call ran out of time; run it again");
        const reason = try std.fmt.allocPrint(self.a, "venom: agent {s}", .{agent});
        if (w.branch) |b| return self.cleanWorktree(base, source, b, reason, mode);
        return self.cleanCopy(base, source, reason, mode);
    }

    fn cleanWorktree(self: *Cleaner, base: Entry, source: []const u8, branch: []const u8, lock: []const u8, mode: Mode) !Entry {
        const a = self.a;
        const list = try self.git(source, &.{ "worktree", "list", "--porcelain" });
        if (!list.ok) return keep(base, .git, list.reason());
        const here = try self.canonical(base.path);
        const entry = findWorktree(list.stdout, here);
        // Listed with no lock, or another's: not the worktree this agent made.
        if (entry) |e| if (!std.mem.eql(u8, e.lock orelse "", lock))
            return keep(base, .not_ours, "the worktree is not locked for this agent");

        if (!isolation.exists(self.io, base.path)) return self.cleanGone(base, source, branch, entry, here, lock, mode);
        if (entry == null) return keep(base, .not_ours, "the folder is not a worktree of the repo");

        if (try self.blocked(base, base.path)) |e| return e;

        // What must survive: HEAD, its branch, the agent's branch, and refs
        // only this worktree has, which go with it.
        const current = try self.git(base.path, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" });
        const on: ?[]const u8 = if (current.ok) std.mem.trimEnd(u8, current.stdout, "\n") else null;
        var revs: std.ArrayList([]const u8) = .empty;
        try revs.append(a, "HEAD");
        if (try self.hasBranch(source, branch)) try revs.append(a, try refOf(a, branch));
        const own = try self.git(base.path, &.{ "for-each-ref", "--format=%(objectname)", "refs/worktree", "refs/bisect", "refs/rewritten" });
        if (!own.ok) return keep(base, .git, own.reason());
        var tips = std.mem.tokenizeScalar(u8, own.stdout, '\n');
        while (tips.next()) |tip| try revs.append(a, tip);
        const verdict = try self.judge(base, base.path, source, revs.items, branch, on, mode);
        if (verdict.refuse) |e| return e;

        if (try self.unregister(base, source, lock)) |e| return e;
        var out = base;
        out.outcome = "removed";
        out.pr = verdict.pr;
        try self.dropBranch(&out, source, branch);
        return out;
    }

    /// `git worktree unlock` then `git worktree remove` without `--force`:
    /// git checks the tree once more, and removes this entry alone. The
    /// lock is put back if it refuses. An entry to report if it did.
    fn unregister(self: *Cleaner, base: Entry, source: []const u8, lock: []const u8) !?Entry {
        const unlocked = try self.git(source, &.{ "worktree", "unlock", base.path });
        if (!unlocked.ok) return keep(base, .git, unlocked.reason());
        // The folder's own config counts (config.worktree, includeIf gitdir:).
        const here: []const []const u8 = if (isolation.exists(self.io, base.path)) &.{base.path} else &.{};
        const removed = try self.gitIn(source, &.{ "worktree", "remove", base.path }, self.remove_timeout_ms, here);
        if (removed.ok) return null;
        _ = try self.git(source, &.{ "worktree", "lock", "--reason", lock, base.path });
        return keep(base, .git, removed.reason());
    }

    /// The folder is not there: removed by hand, by an earlier clean, or
    /// only out of reach for now (an unmounted disk). Nothing is touched
    /// until the checks pass, and a registered folder's own HEAD counts,
    /// which is otherwise held by nothing but the registration. What it
    /// held uncommitted cannot be known, so only an explicit clean, which
    /// someone asked of this agent, ever lifts the registration.
    fn cleanGone(self: *Cleaner, base: Entry, source: []const u8, branch: []const u8, entry: ?Listed, here: []const u8, lock: []const u8, mode: Mode) !Entry {
        const a = self.a;
        var revs: std.ArrayList([]const u8) = .empty;
        var on: ?[]const u8 = null;
        if (entry) |e| {
            if (mode == .merged) return keep(base, .folder_missing, "the folder is missing and may hold uncommitted work; an explicit clean clears it if its commits are safe");
            if (try self.blockedAdmin(base, source, here)) |refused| return refused;
            if (e.head) |h| try revs.append(a, h);
            on = e.branch;
        }
        const has_branch = try self.hasBranch(source, branch);
        if (has_branch) try revs.append(a, try refOf(a, branch));
        var verdict: Verdict = .{};
        if (revs.items.len > 0) verdict = try self.judge(base, source, source, revs.items, branch, on, mode);
        if (verdict.refuse) |e| return e;
        if (entry != null) if (try self.unregister(base, source, lock)) |e| return e;
        var out = base;
        out.outcome = "gone";
        out.pr = verdict.pr;
        try self.dropBranch(&out, source, branch);
        return out;
    }

    /// `blocked` for a registered worktree whose folder is missing, from
    /// what git keeps for it in the repo.
    fn blockedAdmin(self: *Cleaner, base: Entry, source: []const u8, here: []const u8) !?Entry {
        const a = self.a;
        const common = try self.git(source, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
        if (!common.ok) return keep(base, .git, common.reason());
        const root = try std.fmt.allocPrint(a, "{s}/worktrees", .{std.mem.trimEnd(u8, common.stdout, "\n")});
        var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch |err| return keep(base, .git, @errorName(err));
        defer dir.close(self.io);
        const want = try std.fmt.allocPrint(a, "{s}/.git", .{here});
        var it = dir.iterate();
        while (it.next(self.io) catch |err| return keep(base, .git, @errorName(err))) |item| {
            const gitdir = try std.fmt.allocPrint(a, "{s}/{s}/gitdir", .{ root, item.name });
            const text = std.Io.Dir.cwd().readFileAlloc(self.io, gitdir, a, .limited(1 << 16)) catch continue;
            if (!std.mem.eql(u8, std.mem.trimEnd(u8, text, "\n"), want)) continue;
            const admin = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, item.name });
            if (try self.operationIn(base, admin)) |e| return e;
            if (isolation.exists(self.io, try std.fmt.allocPrint(a, "{s}/refs/worktree", .{admin})))
                return keep(base, .unpushed, "the missing worktree has refs of its own");
            return null;
        }
        return keep(base, .git, "git's record of the missing worktree was not found");
    }

    fn cleanCopy(self: *Cleaner, base: Entry, source: []const u8, lock: []const u8, mode: Mode) !Entry {
        const a = self.a;
        if (!isolation.exists(self.io, base.path)) {
            var out = base;
            out.outcome = "gone";
            return out;
        }
        const marker_path = try std.fmt.allocPrint(a, "{s}/.git/{s}", .{ base.path, copy_marker });
        const marker = std.Io.Dir.cwd().readFileAlloc(self.io, marker_path, a, .limited(4096)) catch
            return keep(base, .not_ours, "the folder has no venom copy marker");
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, marker, "\n"), lock)) return keep(base, .not_ours, "the copy was made for another agent");
        if (try self.blocked(base, base.path)) |e| return e;
        // A copy has no branch or PR to match.
        if (mode == .merged) return keep(base, .not_merged, "a copy has no branch, so no PR; use an explicit clean");
        const lost = self.copyUnsaved(base.path, source) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.GitFailed => return keep(base, .git, "cannot compare the copy with its repo"),
        };
        if (lost > 0) {
            const live = try self.liveRemotes(base.path);
            if (live.down) |why| return keep(base, .remote_unavailable, try std.fmt.allocPrint(a, "{d} refs have commits not found in the repo, and a remote cannot say: {s}", .{ lost, why }));
            return keep(base, .unpushed, try std.fmt.allocPrint(a, "{d} refs have commits found neither on a remote nor in the repo", .{lost}));
        }
        std.Io.Dir.cwd().deleteTree(self.io, base.path) catch |err| return keep(base, .git, @errorName(err));
        var out = base;
        out.outcome = "removed";
        return out;
    }

    /// The refs of a copy (all but its remote-tracking ones: only what the
    /// remote says now counts) whose commits exist nowhere else: neither on
    /// a branch of its remotes nor reachable from a local ref of the repo
    /// it was copied from.
    fn copyUnsaved(self: *Cleaner, copy: []const u8, source: []const u8) error{ OutOfMemory, GitFailed }!usize {
        const a = self.a;
        const refs = try self.git(copy, &.{ "for-each-ref", "--format=%(objectname) %(refname)" });
        if (!refs.ok) return error.GitFailed;
        var tips: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, refs.stdout, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.GitFailed;
            if (!std.mem.startsWith(u8, line[space + 1 ..], "refs/remotes/")) try tips.append(a, line[0..space]);
        }
        const head = try self.git(copy, &.{ "rev-parse", "--verify", "--quiet", "HEAD^{commit}" });
        if (head.ok) try tips.append(a, std.mem.trimEnd(u8, head.stdout, "\n"));
        var lost: usize = 0;
        for (tips.items) |tip| {
            if (try self.inLocalRefs(source, tip)) continue;
            const live = try self.liveRemotes(copy);
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, &.{ tip, "--not" });
            try args.appendSlice(a, live.oids);
            const left = try self.count(copy, args.items) orelse return error.GitFailed;
            if (left > 0) lost += 1;
        }
        return lost;
    }

    /// `tip` is reachable from a ref of `source` other than a
    /// remote-tracking one.
    fn inLocalRefs(self: *Cleaner, source: []const u8, tip: []const u8) !bool {
        const there = try self.git(source, &.{ "for-each-ref", "--format=%(refname)", "--contains", tip });
        if (!there.ok) return false;
        var it = std.mem.tokenizeScalar(u8, there.stdout, '\n');
        while (it.next()) |name| if (!std.mem.startsWith(u8, name, "refs/remotes/")) return true;
        return false;
    }

    /// Not the folder git says, uncommitted changes, or an operation under
    /// way, as the entry to report. The first matters because git walks up
    /// from a folder that is no repo: an empty mount point would report on
    /// whatever repo encloses it.
    fn blocked(self: *Cleaner, base: Entry, dir: []const u8) !?Entry {
        const a = self.a;
        const top = try self.git(dir, &.{ "rev-parse", "--show-toplevel" });
        const real = try self.canonical(dir);
        if (!top.ok or !std.mem.eql(u8, std.mem.trimEnd(u8, top.stdout, "\n"), real))
            return keep(base, .not_ours, "the folder is not a checkout of its own");
        const status = try self.git(dir, &.{ "status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none" });
        if (!status.ok) return keep(base, .git, status.reason());
        if (std.mem.trim(u8, status.stdout, " \n").len > 0) {
            const n = std.mem.count(u8, std.mem.trimEnd(u8, status.stdout, "\n"), "\n") + 1;
            return keep(base, .uncommitted, try std.fmt.allocPrint(a, "{d} paths with uncommitted changes", .{n}));
        }
        // Index bits make status look away from a tracked file: lowercase
        // is assume-unchanged, S skip-worktree.
        const files = try self.git(dir, &.{ "ls-files", "-v" });
        if (!files.ok) return keep(base, .git, files.reason());
        var hidden: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, files.stdout, '\n');
        while (lines.next()) |line| {
            if (std.ascii.isLower(line[0]) or line[0] == 'S') hidden += 1;
        }
        if (hidden > 0) return keep(base, .uncommitted, try std.fmt.allocPrint(a, "{d} paths are marked assume-unchanged or skip-worktree, so their changes cannot be seen", .{hidden}));
        const admin = try self.git(dir, &.{ "rev-parse", "--absolute-git-dir" });
        if (!admin.ok) return keep(base, .git, admin.reason());
        return self.operationIn(base, std.mem.trimEnd(u8, admin.stdout, "\n"));
    }

    fn operationIn(self: *Cleaner, base: Entry, admin: []const u8) !?Entry {
        for (operations) |name| {
            if (isolation.exists(self.io, try std.fmt.allocPrint(self.a, "{s}/{s}", .{ admin, name })))
                return keep(base, .operation_in_progress, try std.fmt.allocPrint(self.a, "{s} is present: finish or abort it first", .{name}));
        }
        return null;
    }

    const Verdict = struct { refuse: ?Entry = null, pr: ?[]const u8 = null };

    /// The commit checks for `revs` in `dir`. `on` is the branch checked
    /// out there, which goes with neither side: only other branches count
    /// as a place the commits survive on. The network is asked only when
    /// local branches do not settle it.
    fn judge(self: *Cleaner, base: Entry, dir: []const u8, source: []const u8, revs: []const []const u8, branch: []const u8, on: ?[]const u8, mode: Mode) !Verdict {
        const a = self.a;
        const failed: Verdict = .{ .refuse = keep(base, .git, "cannot list the commits") };
        const local = try self.countUnsaved(dir, revs, branch, on, &.{}) orelse return failed;
        if (mode == .explicit and local == 0) return .{};

        if (mode == .explicit) {
            const live = try self.liveRemotes(source);
            const left = try self.countUnsaved(dir, revs, branch, on, live.oids) orelse return failed;
            if (left == 0) return .{};
        }
        const prs = try self.mergedPrs(source, branch);
        if (prs == null and mode == .merged) return .{ .refuse = keep(base, .gh_unavailable, self.gh_down.get(source)) };
        // A head that is not here cannot prove anything about what is.
        var boundary: std.ArrayList([]const u8) = .empty;
        var covering: ?[]const u8 = null;
        for (prs orelse &.{}) |pr| {
            const known = try self.git(dir, &.{ "cat-file", "-e", try std.fmt.allocPrint(a, "{s}^{{commit}}", .{pr.oid}) });
            if (!known.ok) continue;
            try boundary.append(a, pr.oid);
            if (covering != null) continue;
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, revs);
            try args.appendSlice(a, &.{ "--not", pr.oid });
            if ((try self.count(dir, args.items) orelse continue) == 0) covering = pr.url;
        }
        if (mode == .merged and covering != null) return .{ .pr = covering };
        const live = try self.liveRemotes(source);
        try boundary.appendSlice(a, live.oids);
        const left = try self.countUnsaved(dir, revs, branch, on, boundary.items) orelse return failed;
        if (mode == .explicit and left == 0) return .{ .pr = covering };
        if (left > 0) if (live.down) |why|
            return .{ .refuse = keep(base, .remote_unavailable, try std.fmt.allocPrint(a, "{d} commits are on no other branch and no merged PR, and a remote cannot say: {s}", .{ left, why })) };
        if (mode == .explicit) {
            if (prs == null) return .{ .refuse = keep(base, .unpushed, try std.fmt.allocPrint(a, "{d} commits are on no remote branch and no other branch, and gh cannot say whether a PR has them", .{left})) };
            return .{ .refuse = keep(base, .unpushed, try std.fmt.allocPrint(a, "{d} commits are on no remote branch, no other branch and no merged PR (if the remote moved, git fetch)", .{left})) };
        }
        if (prs.?.len > 0 and left > 0) return .{ .refuse = keep(base, .unpushed, try std.fmt.allocPrint(a, "{d} commits came after the merged PR", .{left})) };
        return .{ .refuse = keep(base, .not_merged, if (prs.?.len > 0) "the merged PRs of this branch do not contain its head" else "no merged PR for this branch") };
    }

    /// Commits of `revs` on no local branch but `branch` and `on`, and not
    /// behind `oids`. Remote-tracking refs do not count: they say what the
    /// remote had at the last fetch (`liveRemotes` says what it has).
    fn countUnsaved(self: *Cleaner, dir: []const u8, revs: []const []const u8, branch: []const u8, on: ?[]const u8, oids: []const []const u8) !?u64 {
        const a = self.a;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, revs);
        try args.appendSlice(a, &.{ "--not", try std.fmt.allocPrint(a, "--exclude={s}", .{branch}) });
        if (on) |b| try args.append(a, try std.fmt.allocPrint(a, "--exclude={s}", .{b}));
        try args.append(a, "--branches");
        try args.appendSlice(a, oids);
        return self.count(dir, args.items);
    }

    /// `git rev-list --count <args>`; null if git failed or said nonsense.
    fn count(self: *Cleaner, dir: []const u8, args: []const []const u8) error{OutOfMemory}!?u64 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a, &.{ "rev-list", "--count" });
        try argv.appendSlice(self.a, args);
        const r = try self.git(dir, argv.items);
        if (!r.ok) return null;
        return std.fmt.parseInt(u64, std.mem.trimEnd(u8, r.stdout, "\n"), 10) catch null;
    }

    /// What `dir`'s remotes have now, asked once per call.
    fn liveRemotes(self: *Cleaner, dir: []const u8) error{OutOfMemory}!Remotes {
        if (self.remotes.get(dir)) |known| return known;
        const out = try self.askRemotes(dir);
        try self.remotes.put(self.a, dir, out);
        return out;
    }

    fn askRemotes(self: *Cleaner, dir: []const u8) error{OutOfMemory}!Remotes {
        const a = self.a;
        const names = try self.git(dir, &.{"remote"});
        if (!names.ok) return .{ .down = names.reason() };
        // Local ref tips only: git cannot use a commit it does not have.
        const refs = try self.git(dir, &.{ "for-each-ref", "--format=%(objectname)" });
        if (!refs.ok) return .{ .down = refs.reason() };
        var have: std.StringHashMapUnmanaged(void) = .empty;
        var tips = std.mem.tokenizeScalar(u8, refs.stdout, '\n');
        while (tips.next()) |tip| try have.put(a, tip, {});

        var oids: std.ArrayList([]const u8) = .empty;
        var down: ?[]const u8 = null;
        var it = std.mem.tokenizeScalar(u8, names.stdout, '\n');
        while (it.next()) |name| {
            const r = try safe_git.lsRemoteHeads(a, self.io, dir, name, .{ .timeout_ms = self.remote_timeout_ms, .config = &pinned });
            if (!r.ok) {
                down = try std.fmt.allocPrint(a, "{s}: {s}", .{ name, r.reason() });
                continue;
            }
            var lines = std.mem.tokenizeScalar(u8, r.stdout, '\n');
            while (lines.next()) |line| {
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                const oid = line[0..tab];
                if (!isOid(oid) or !have.contains(oid)) continue;
                if (have.fetchRemove(oid) != null) try oids.append(a, oid);
            }
        }
        return .{ .oids = oids.items, .down = down };
    }

    fn git(self: *Cleaner, dir: []const u8, args: []const []const u8) error{OutOfMemory}!isolation.Ran {
        return self.gitWithin(dir, args, self.git_timeout_ms);
    }

    /// Runs git on the reactor thread (`safe_git.run`: no repo-defined
    /// filters, hooks or fsmonitor, no inherited `GIT_*`, cut off at an
    /// absolute deadline `timeout_ms` from now); a failure, as anything
    /// else that goes wrong is, so the worktree stays. `pinned` fixes what
    /// config would otherwise change in the answers. `git worktree remove`
    /// hands both on to the status it runs itself.
    fn gitWithin(self: *Cleaner, dir: []const u8, args: []const []const u8, timeout_ms: i64) error{OutOfMemory}!isolation.Ran {
        return self.gitIn(dir, args, timeout_ms, &.{});
    }

    /// `gitWithin`, also scanning `also` for filters: the work tree a
    /// `git worktree remove` removes has config of its own.
    fn gitIn(self: *Cleaner, dir: []const u8, args: []const []const u8, timeout_ms: i64, also: []const []const u8) error{OutOfMemory}!isolation.Ran {
        return safe_git.run(self.a, self.io, dir, args, .{ .timeout_ms = timeout_ms, .reads_tree = readsTree(args), .also = also, .config = &pinned });
    }

    /// Only these hash files of the work tree, which is when git applies a
    /// filter; the scan for them is spared to the rest.
    fn readsTree(args: []const []const u8) bool {
        if (args.len > 0 and std.mem.eql(u8, args[0], "status")) return true;
        return args.len > 1 and std.mem.eql(u8, args[0], "worktree") and std.mem.eql(u8, args[1], "remove");
    }

    const Pr = struct { url: []const u8, oid: []const u8 };

    /// The merged PRs from this repo with `branch` as head. Null if `gh`
    /// did not give a usable answer; `gh_down` then says why, for this repo.
    fn mergedPrs(self: *Cleaner, source: []const u8, branch: []const u8) !?[]const Pr {
        if (self.gh_down.contains(source)) return null;
        const a = self.a;
        const r = std.process.run(a, self.io, .{
            .argv = &.{ self.gh, "pr", "list", "--head", branch, "--state", "merged", "--limit", "30", "--json", "url,state,headRefOid,isCrossRepository" },
            .cwd = .{ .path = source },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 16),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(self.gh_timeout_ms), .clock = .awake } },
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try self.gh_down.put(a, source, try std.fmt.allocPrint(a, "gh: {s}", .{@errorName(err)}));
                return null;
            },
        };
        if (!r.term.success()) {
            const said = std.mem.trim(u8, r.stderr, " \t\r\n");
            try self.gh_down.put(a, source, try std.fmt.allocPrint(a, "gh failed: {s}", .{said}));
            return null;
        }
        return try parsePrs(a, r.stdout) orelse {
            try self.gh_down.put(a, source, "gh printed something other than the PR list");
            return null;
        };
    }

    fn hasBranch(self: *Cleaner, source: []const u8, branch: []const u8) !bool {
        return (try self.git(source, &.{ "rev-parse", "--verify", "--quiet", try refOf(self.a, branch) })).ok;
    }

    fn dropBranch(self: *Cleaner, out: *Entry, source: []const u8, branch: []const u8) !void {
        if (!try self.hasBranch(source, branch)) return;
        const r = try self.git(source, &.{ "branch", "-D", branch });
        out.branch_deleted = r.ok;
        // Checked out in another worktree, say: the branch simply stays.
        if (!r.ok) out.detail = try self.a.dupe(u8, r.reason());
    }

    /// `path` as git prints it: symlinks resolved, also when the last
    /// component does not exist.
    fn canonical(self: *Cleaner, path: []const u8) ![]const u8 {
        const cwd = std.Io.Dir.cwd();
        if (cwd.realPathFileAlloc(self.io, path, self.a)) |real| return real else |_| {}
        const dir = std.fs.path.dirnamePosix(path) orelse return path;
        const real = cwd.realPathFileAlloc(self.io, dir, self.a) catch return path;
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ real, std.fs.path.basenamePosix(path) });
    }
};

fn keep(base: Entry, reason: Reason, detail: ?[]const u8) Entry {
    var out = base;
    out.outcome = "kept";
    out.reason = @tagName(reason);
    out.detail = detail;
    return out;
}

fn refOf(a: std.mem.Allocator, branch: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "refs/heads/{s}", .{branch});
}

/// An entry of `git worktree list --porcelain`.
const Listed = struct {
    lock: ?[]const u8 = null,
    head: ?[]const u8 = null,
    /// Short name of the branch checked out there.
    branch: ?[]const u8 = null,
};

/// The entry for `path`, if git knows it.
fn findWorktree(porcelain: []const u8, path: []const u8) ?Listed {
    var found = false;
    var out: Listed = .{};
    var it = std.mem.splitScalar(u8, porcelain, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (found) break;
            found = std.mem.eql(u8, line["worktree ".len..], path);
        } else if (!found) {
            continue;
        } else if (std.mem.startsWith(u8, line, "locked ")) {
            out.lock = line["locked ".len..];
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            out.head = line["HEAD ".len..];
        } else if (std.mem.startsWith(u8, line, "branch refs/heads/")) {
            out.branch = line["branch refs/heads/".len..];
        }
    }
    return if (found) out else null;
}

/// `gh pr list --json url,state,headRefOid,isCrossRepository`, keeping what
/// is provably a merged PR from this repo. Null if it is not such a list.
fn parsePrs(a: std.mem.Allocator, text: []const u8) !?[]const Cleaner.Pr {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (v != .array) return null;
    var out: std.ArrayList(Cleaner.Pr) = .empty;
    for (v.array.items) |pr| {
        if (pr != .object) return null;
        const url = pr.object.get("url") orelse continue;
        const state = pr.object.get("state") orelse continue;
        const oid = pr.object.get("headRefOid") orelse continue;
        const cross = pr.object.get("isCrossRepository") orelse continue;
        if (url != .string or state != .string or oid != .string or cross != .bool) continue;
        if (cross.bool or !std.mem.eql(u8, state.string, "MERGED") or !isOid(oid.string)) continue;
        try out.append(a, .{ .url = url.string, .oid = oid.string });
    }
    return out.items;
}

/// A full SHA-1 or SHA-256 name; anything else never reaches git's argv.
fn isOid(s: []const u8) bool {
    if (s.len != 40 and s.len != 64) return false;
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

const testing = std.testing;

test "cleanup: only a merged PR of this repo with a real commit name counts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const merged = try std.fmt.allocPrint(a, "[{{\"url\":\"u\",\"state\":\"MERGED\",\"headRefOid\":\"{s}\",\"isCrossRepository\":false}}]", .{oid});
    try testing.expectEqualStrings(oid, (try parsePrs(a, merged)).?[0].oid);
    for ([_][]const u8{
        "[{\"url\":\"u\",\"state\":\"OPEN\",\"headRefOid\":\"" ++ oid ++ "\",\"isCrossRepository\":false}]",
        "[{\"url\":\"u\",\"state\":\"MERGED\",\"headRefOid\":\"" ++ oid ++ "\",\"isCrossRepository\":true}]",
        "[{\"url\":\"u\",\"state\":\"MERGED\",\"headRefOid\":\"--all\",\"isCrossRepository\":false}]",
        "[{\"url\":\"u\",\"state\":\"MERGED\",\"headRefOid\":\"" ++ oid ++ "\"}]",
        "[]",
    }) |no| try testing.expectEqual(@as(usize, 0), (try parsePrs(a, no)).?.len);
    for ([_][]const u8{ "", "not json", "{}", "[1]" }) |bad| try testing.expect(try parsePrs(a, bad) == null);
}

test "cleanup: the porcelain worktree list gives the lock reason of the right entry" {
    const list =
        \\worktree /r/a
        \\HEAD 1111
        \\branch refs/heads/main
        \\
        \\worktree /r/a-a1
        \\HEAD 2222
        \\branch refs/heads/venom/a1
        \\locked venom: agent a1
        \\
        \\worktree /r/a-a2
        \\HEAD 3333
        \\detached
        \\locked
        \\
    ;
    try testing.expectEqualStrings("venom: agent a1", findWorktree(list, "/r/a-a1").?.lock.?);
    try testing.expect(findWorktree(list, "/r/a").?.lock == null);
    // `locked` alone (no reason) is not one of ours either.
    try testing.expect(findWorktree(list, "/r/a-a2").?.lock == null);
    try testing.expect(findWorktree(list, "/r/a-a3") == null);
}
