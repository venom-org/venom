//! Worktree cleanup with the fake harness through the
//! generated CLI (`--json`), on real git repos, bare remotes and worktrees
//! made in the test's temp dir (never the user's): explicit clean, a
//! merged-PR clean including a real squash merge with a stubbed `gh`, and
//! the core safety property: work that exists nowhere else is kept and
//! reported, whichever way it got there and whatever `gh` says.
//!
//! The daemon's `gh` is `<temp>/gh`: absent unless a test writes it, so the
//! real one never runs.
const std = @import("std");
const agents = @import("agents.zig");
const eventlog = @import("eventlog/root.zig");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const iso = @import("isolation_tests.zig");
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;
const items = iso.items;
const str = iso.str;
const gitOk = iso.gitOk;
const exists = iso.exists;

const script =
    \\{"turns":[{"match":"slow","steps":[{"text":"working"},{"sleep_ms":20000}]},
    \\{"match":"","steps":[{"text":"Done."}]}]}
;

const Fixture = struct {
    d: Daemon = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    a: std.mem.Allocator = undefined,
    /// `<work>/a`, whose `origin` is a bare repo beside the workspace.
    repo: []const u8 = "",

    fn init(self: *Fixture, options: Daemon.Options) !void {
        self.arena = .init(ta);
        errdefer self.arena.deinit();
        self.a = self.arena.allocator();
        if (!iso.hasGit(self.a)) return error.SkipZigTest;
        var o = options;
        o.script = script;
        try self.d.initWith(o);
        errdefer self.d.deinit();
        try iso.tree(&self.d, self.a);
        self.repo = try self.fmt("{s}/a", .{self.d.work});
        const bare = try self.origin();
        _ = try gitOk(self.a, self.d.dir, &.{ "init", "-q", "--bare", "-b", "main", bare });
        _ = try gitOk(self.a, self.repo, &.{ "remote", "add", "origin", bare });
        _ = try gitOk(self.a, self.repo, &.{ "push", "-q", "origin", "main" });
    }

    fn deinit(self: *Fixture) void {
        self.d.deinit();
        self.arena.deinit();
    }

    fn fmt(self: *Fixture, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.a, f, args);
    }

    fn origin(self: *Fixture) ![]const u8 {
        return self.fmt("{s}/origin.git", .{self.d.dir});
    }

    /// Spawns on repo `a` and waits for it to settle: the worktree's path.
    fn spawned(self: *Fixture, id: []const u8) ![]const u8 {
        return self.spawnedIn("a", id);
    }

    fn spawnedIn(self: *Fixture, repo: []const u8, id: []const u8) ![]const u8 {
        const r = try iso.spawn(&self.d, self.a, &.{try self.fmt("--repos=[\"{s}\"]", .{repo})});
        try testing.expectEqual(@as(u8, 0), r.status);
        try testing.expectEqualStrings(id, str(r.json, "agent"));
        _ = try self.d.waitState(self.a, id, "settled");
        return str(r.json, "cwd");
    }

    fn archive(self: *Fixture, id: []const u8) !void {
        const r = try self.d.run(self.a, &.{ "agent", "archive", try self.fmt("--agent={s}", .{id}) });
        try testing.expectEqual(@as(u8, 0), r.status);
        try testing.expectEqualStrings("archived", str(r.json, "state"));
    }

    fn file(self: *Fixture, dir: []const u8, name: []const u8, data: []const u8) !void {
        _ = self;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
        if (std.fs.path.dirnamePosix(path)) |up| try std.Io.Dir.cwd().createDirPath(testing.io, up);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    /// A commit in `dir`: its id.
    fn commit(self: *Fixture, dir: []const u8, name: []const u8) ![]const u8 {
        try self.file(dir, name, name);
        _ = try gitOk(self.a, dir, &.{ "add", name });
        _ = try gitOk(self.a, dir, &.{ "commit", "-q", "-m", name });
        return std.mem.trimEnd(u8, try gitOk(self.a, dir, &.{ "rev-parse", "HEAD" }), "\n");
    }

    /// `agent clean` of one agent: its one worktree's entry.
    fn clean(self: *Fixture, id: []const u8, merged: bool) !Value {
        const flag = try self.fmt("--agent={s}", .{id});
        const r = try self.d.run(self.a, if (merged) &.{ "agent", "clean", flag, "--merged=true" } else &.{ "agent", "clean", flag });
        try testing.expectEqual(@as(u8, 0), r.status);
        const list = items(r.json, "worktrees");
        try testing.expectEqual(@as(usize, 1), list.len);
        return list[0];
    }

    /// The worktree is still there with its contents and lock, its branch
    /// too, and the entry says why.
    fn expectKept(self: *Fixture, e: Value, id: []const u8, path: []const u8, reason: []const u8) !void {
        try testing.expectEqualStrings("kept", str(e, "outcome"));
        try testing.expectEqualStrings(reason, str(e, "reason"));
        try testing.expect(!e.object.get("branch_deleted").?.bool);
        try testing.expect(exists(path));
        try testing.expect(try iso.branchExists(self.a, self.repo, try self.fmt("venom/{s}", .{id})));
        const list = try gitOk(self.a, self.repo, &.{ "worktree", "list", "--porcelain" });
        try testing.expect(std.mem.indexOf(u8, list, try self.fmt("locked venom: agent {s}", .{id})) != null);
    }

    fn expectRemoved(self: *Fixture, e: Value, id: []const u8, path: []const u8) !void {
        try testing.expectEqualStrings("removed", str(e, "outcome"));
        try testing.expect(e.object.get("branch_deleted").?.bool);
        try testing.expect(!exists(path));
        try testing.expect(!try iso.branchExists(self.a, self.repo, try self.fmt("venom/{s}", .{id})));
        const list = try gitOk(self.a, self.repo, &.{ "worktree", "list", "--porcelain" });
        try testing.expect(std.mem.indexOf(u8, list, path) == null);
    }

    /// Replaces `<temp>/gh`; `body` is a shell script.
    fn gh(self: *Fixture, body: []const u8) !void {
        const tmp = try self.fmt("{s}/gh.new", .{self.d.dir});
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = tmp, .data = try self.fmt("#!/bin/sh\nprintf '%s\\n' \"$*\" >> {s}/gh.log\n{s}\n", .{ self.d.dir, body }) });
        _ = try self.sh(&.{ "chmod", "+x", tmp });
        _ = try self.sh(&.{ "mv", "-f", tmp, try self.fmt("{s}/gh", .{self.d.dir}) });
    }

    fn sh(self: *Fixture, argv: []const []const u8) !void {
        const r = try std.process.run(self.a, testing.io, .{ .argv = argv });
        try testing.expect(r.term.success());
    }

    /// A stub that says `oid` is the head of a merged PR.
    fn ghMerged(self: *Fixture, oid: []const u8) !void {
        try self.gh(try self.fmt("echo '{s}'", .{try prList(self.a, oid, "MERGED", false)}));
    }

    fn ghLog(self: *Fixture) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, try self.fmt("{s}/gh.log", .{self.d.dir}), self.a, .limited(1 << 16));
    }

    /// Merges `branch` as a host's squash button does: a new commit on the
    /// remote's main, the head branch deleted, and the deletion fetched
    /// with `--prune`, so the branch's commits are on no ref of the repo.
    fn squashMerge(self: *Fixture, branch: []const u8) !void {
        const clone = try self.fmt("{s}/host", .{self.d.dir});
        _ = try gitOk(self.a, self.d.dir, &.{ "clone", "-q", try self.origin(), clone });
        _ = try gitOk(self.a, clone, &.{ "merge", "-q", "--squash", try self.fmt("origin/{s}", .{branch}) });
        _ = try gitOk(self.a, clone, &.{ "commit", "-q", "-m", "squashed" });
        _ = try gitOk(self.a, clone, &.{ "push", "-q", "origin", "main" });
        _ = try gitOk(self.a, clone, &.{ "push", "-q", "origin", "--delete", branch });
        _ = try gitOk(self.a, self.repo, &.{ "fetch", "-q", "--prune", "origin" });
        // The commit is really on no ref but the local branch.
        const left = try gitOk(self.a, self.repo, &.{ "rev-list", "--count", try self.fmt("refs/heads/{s}", .{branch}), "--not", "--remotes" });
        try testing.expect(!std.mem.eql(u8, left, "0\n"));
    }
};

fn prList(a: std.mem.Allocator, oid: []const u8, state: []const u8, cross: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "[{{\"url\":\"https://example.invalid/pr/1\",\"state\":\"{s}\",\"headRefOid\":\"{s}\",\"isCrossRepository\":{}}}]", .{ state, oid, cross });
}

test "cleanup: explicit clean removes a pushed worktree and its branch; archive --clean; errors" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;

    // agent clean: only archived agents.
    const w1 = try f.spawned("a1");
    var r = try f.d.run(a, &.{ "agent", "clean", "--agent=a1" });
    try testing.expectEqual(@as(u8, 5), r.status);
    try testing.expectEqualStrings("conflict.agent_not_archived", iso.errorCode(r.json));
    try testing.expect(exists(w1));
    r = try f.d.run(a, &.{ "agent", "clean", "--agent=nope" });
    try testing.expectEqual(@as(u8, 3), r.status);
    try testing.expectEqualStrings("not_found.agent", iso.errorCode(r.json));
    r = try f.d.run(a, &.{ "agent", "clean" });
    try testing.expectEqualStrings("invalid_params.agent", iso.errorCode(r.json));

    // Archiving alone keeps the worktree.
    try f.archive("a1");
    try testing.expect(exists(w1));
    _ = try gitOk(a, w1, &.{ "push", "-q", "origin", "venom/a1" });
    _ = try f.commit(w1, "work");
    _ = try gitOk(a, w1, &.{ "push", "-q", "origin", "venom/a1" });
    // Ignored files (build output) do not hold a worktree back.
    try f.file(f.repo, ".git/info/exclude", "zig-out/\n");
    try f.file(w1, "zig-out/bin", "x");
    const e = try f.clean("a1", false);
    try f.expectRemoved(e, "a1", w1);
    // The remote branch is never touched.
    try testing.expect(try iso.branchExists(a, try f.origin(), "venom/a1"));
    // Again: nothing there any more.
    try testing.expectEqualStrings("gone", str(try f.clean("a1", false), "outcome"));

    // agent archive --clean, on a repo with no remote at all: a worktree
    // with no commit of its own holds nothing.
    const w2 = try f.spawnedIn("b", "a2");
    r = try f.d.run(a, &.{ "agent", "archive", "--agent=a2", "--clean=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("archived", str(r.json, "state"));
    try testing.expectEqualStrings("removed", str(items(r.json, "worktrees")[0], "outcome"));
    try testing.expect(!exists(w2));
    const rb = try f.fmt("{s}/b", .{f.d.work});
    try testing.expect(!try iso.branchExists(a, rb, "venom/a2"));

    // No remote, but the work is merged into a local branch: safe. The
    // repo's own commits were never in danger.
    const w3 = try f.spawnedIn("b", "a3");
    const oid = try f.commit(w3, "local");
    _ = try gitOk(a, rb, &.{ "merge", "-q", "--ff-only", oid });
    r = try f.d.run(a, &.{ "agent", "archive", "--agent=a3", "--clean=true" });
    try testing.expectEqualStrings("removed", str(items(r.json, "worktrees")[0], "outcome"));
    try testing.expect(!exists(w3));
    try testing.expect(exists(try f.fmt("{s}/local", .{rb})));

    // Without --clean the result is as before.
    _ = try f.spawned("a4");
    r = try f.d.run(a, &.{ "agent", "archive", "--agent=a4" });
    try testing.expect(r.json.object.get("worktrees") == null);
    // Nothing ever ran the real gh: this test has no stub, and no gh.log.
    try testing.expect(!exists(try f.fmt("{s}/gh.log", .{f.d.dir})));
}

test "cleanup: a fork shares its source's worktree: cleaning the fork leaves it to the source" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const path = try f.spawned("a1");
    var r = try f.d.run(a, &.{ "agent", "fork", "--agent=a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    // No task: it idles, and its folder is its source's.
    _ = try f.d.waitState(a, "a2", "settled");
    r = try f.d.run(a, &.{ "agent", "show", "--agent=a2" });
    try testing.expectEqualStrings(path, str(r.json, "cwd"));
    r = try f.d.run(a, &.{ "agent", "archive", "--agent=a2", "--clean=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 0), r.json.object.get("worktrees").?.array.items.len);
    _ = try std.Io.Dir.cwd().statFile(testing.io, path, .{});
}

test "cleanup: uncommitted changes of every kind are kept and reported, whatever gh says" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    const head = std.mem.trimEnd(u8, try gitOk(a, w, &.{ "rev-parse", "HEAD" }), "\n");
    try f.ghMerged(head);

    // Modified tracked file.
    try f.file(w, "README", "changed");
    for ([_]bool{ false, true }) |merged| try f.expectKept(try f.clean("a1", merged), "a1", w, "uncommitted");
    var r = try f.d.run(a, &.{ "agent", "archive", "--agent=a1", "--clean=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try f.expectKept(items(r.json, "worktrees")[0], "a1", w, "uncommitted");
    // A sweep too.
    r = try f.d.run(a, &.{ "agent", "clean", "--merged=true" });
    try f.expectKept(items(r.json, "worktrees")[0], "a1", w, "uncommitted");
    try testing.expectEqualStrings("changed", try std.Io.Dir.cwd().readFileAlloc(testing.io, try f.fmt("{s}/README", .{w}), a, .limited(64)));
    _ = try gitOk(a, w, &.{ "checkout", "--", "README" });

    // Untracked file.
    try f.file(w, "new.txt", "new");
    try f.expectKept(try f.clean("a1", true), "a1", w, "uncommitted");
    try testing.expect(exists(try f.fmt("{s}/new.txt", .{w})));
    // Staged file.
    _ = try gitOk(a, w, &.{ "add", "new.txt" });
    const e = try f.clean("a1", false);
    try f.expectKept(e, "a1", w, "uncommitted");
    try testing.expectEqualStrings("1 paths with uncommitted changes", str(e, "detail"));
    _ = try gitOk(a, w, &.{ "rm", "-q", "-f", "new.txt" });

    // Clean again: it goes, so the kept ones were kept for that reason alone.
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: unpushed commits are kept: on the branch, on a detached HEAD, on another branch" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");

    // On the agent's branch; no gh: explicit clean cannot do better.
    const oid = try f.commit(w, "one");
    const e = try f.clean("a1", false);
    try f.expectKept(e, "a1", w, "unpushed");
    try testing.expect(std.mem.startsWith(u8, str(e, "detail"), "1 commits"));
    // Pushed, then one more.
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    _ = try f.commit(w, "two");
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
    _ = try gitOk(a, w, &.{ "reset", "-q", "--hard", oid });

    // On a detached HEAD: the branch is pushed, HEAD is not.
    _ = try gitOk(a, w, &.{ "checkout", "-q", "--detach" });
    const detached = try f.commit(w, "three");
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
    try testing.expectEqualStrings(detached, std.mem.trimEnd(u8, try gitOk(a, w, &.{ "rev-parse", "HEAD" }), "\n"));

    // On a branch the agent switched to.
    _ = try gitOk(a, w, &.{ "checkout", "-q", "-b", "other" });
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
    _ = try gitOk(a, w, &.{ "checkout", "-q", "venom/a1" });
    _ = try gitOk(a, f.repo, &.{ "branch", "-D", "other" });

    // Back on the pushed branch: nothing holds it back.
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: a rebase or merge under way is kept even when every commit is pushed" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    _ = try f.commit(w, "one");
    _ = try f.commit(w, "two");
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    // An `edit` stop: the tree is clean, HEAD is on a pushed commit.
    const edit = [_][]const u8{ "-c", "sequence.editor=sed -i 1s/^pick/edit/", "rebase", "-i", "HEAD~1" };
    _ = try gitOk(a, w, &edit);
    try testing.expectEqualStrings("", try gitOk(a, w, &.{ "status", "--porcelain" }));
    try f.expectKept(try f.clean("a1", false), "a1", w, "operation_in_progress");
    _ = try gitOk(a, w, &.{ "rebase", "--abort" });
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: a squash-merged PR (stubbed gh): the worktree and branch go, with any later work kept" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    const head = try f.commit(w, "feature");
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    try f.squashMerge("venom/a1");

    // gh missing: --merged removes nothing, explicit cannot prove it either.
    var e = try f.clean("a1", true);
    try f.expectKept(e, "a1", w, "gh_unavailable");
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");

    try f.ghMerged(head);
    // Dirty beats merged.
    try f.file(w, "scratch", "x");
    try f.expectKept(try f.clean("a1", true), "a1", w, "uncommitted");
    _ = try gitOk(a, w, &.{ "clean", "-q", "-f" });
    // A commit after the merged head beats merged.
    const later = try f.commit(w, "later");
    e = try f.clean("a1", true);
    try f.expectKept(e, "a1", w, "unpushed");
    try testing.expectEqualStrings("1 commits came after the merged PR", str(e, "detail"));
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
    try testing.expectEqualStrings(later, std.mem.trimEnd(u8, try gitOk(a, w, &.{ "rev-parse", "HEAD" }), "\n"));
    _ = try gitOk(a, w, &.{ "reset", "-q", "--hard", head });

    // Exactly the merged head: gone, and gh was asked about this branch.
    e = try f.clean("a1", true);
    try f.expectRemoved(e, "a1", w);
    try testing.expectEqualStrings("https://example.invalid/pr/1", str(e, "pr"));
    const log = try f.ghLog();
    try testing.expect(std.mem.indexOf(u8, log, "pr list --head venom/a1 --state merged") != null);
    // The squash commit is what remains on the remote.
    _ = try gitOk(a, f.repo, &.{ "rev-parse", "--verify", "origin/main^{commit}" });
    try testing.expect(!try iso.branchExists(a, f.repo, "venom/a1"));
}

test "cleanup: explicit clean also accepts a squash merge; gh is not asked when nothing is unpushed" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    const head = try f.commit(w, "feature");
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    try f.squashMerge("venom/a1");
    try f.ghMerged(head);
    try f.expectRemoved(try f.clean("a1", false), "a1", w);

    const w2 = try f.spawned("a2");
    try f.archive("a2");
    try f.gh("exit 1");
    const before = (try f.ghLog()).len;
    try f.expectRemoved(try f.clean("a2", false), "a2", w2);
    try testing.expectEqual(before, (try f.ghLog()).len);
}

test "cleanup: --merged trusts only a merged PR of this repo that contains the head" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    const head = try f.commit(w, "feature");
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });

    // Pushed but no merged PR: --merged keeps it; explicit would remove it.
    try f.gh("echo '[]'");
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    // Not merged, or from a fork with the same branch name.
    try f.gh(try f.fmt("echo '{s}'", .{try prList(a, head, "OPEN", false)}));
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    try f.gh(try f.fmt("echo '{s}'", .{try prList(a, head, "MERGED", true)}));
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    // A merged PR of the same branch name holding other commits: an old
    // one, or a head this clone does not have.
    try f.ghMerged("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    const base = std.mem.trimEnd(u8, try gitOk(a, w, &.{ "rev-parse", "HEAD~1" }), "\n");
    try f.ghMerged(base);
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    // gh failing or printing nonsense says nothing.
    for ([_][]const u8{ "echo oops >&2; exit 1", "echo 'not json'", "echo '{}'" }) |body| {
        try f.gh(body);
        try f.expectKept(try f.clean("a1", true), "a1", w, "gh_unavailable");
    }
    // A true answer: it goes.
    try f.ghMerged(head);
    try f.expectRemoved(try f.clean("a1", true), "a1", w);
}

test "cleanup: the merged sweep takes only archived agents with a merged PR" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const merged = try f.spawned("a1");
    try f.archive("a1");
    const head = try f.commit(merged, "merged");
    _ = try gitOk(a, merged, &.{ "push", "-q", "origin", "venom/a1" });
    const open = try f.spawned("a2");
    try f.archive("a2");
    _ = try f.commit(open, "open");
    _ = try gitOk(a, open, &.{ "push", "-q", "origin", "venom/a2" });
    // Settled, not archived: left alone even if its PR is merged.
    const settled = try f.spawned("a3");
    const settled_head = try f.commit(settled, "settled");
    _ = try gitOk(a, settled, &.{ "push", "-q", "origin", "venom/a3" });
    try f.gh(try f.fmt(
        \\case "$*" in
        \\*venom/a1*) echo '{s}';;
        \\*venom/a3*) echo '{s}';;
        \\*) echo '[]';;
        \\esac
    , .{ try prList(a, head, "MERGED", false), try prList(a, settled_head, "MERGED", false) }));

    var r = try f.d.run(a, &.{ "agent", "clean", "--merged=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const list = items(r.json, "worktrees");
    try testing.expectEqual(@as(usize, 2), list.len);
    try f.expectRemoved(list[0], "a1", merged);
    try f.expectKept(list[1], "a2", open, "not_merged");
    try testing.expect(exists(settled));
    // A later sweep does not bring up what is long gone.
    r = try f.d.run(a, &.{ "agent", "clean", "--merged=true" });
    try testing.expectEqual(@as(usize, 1), items(r.json, "worktrees").len);
    try testing.expectEqualStrings("a2", str(items(r.json, "worktrees")[0], "agent"));
}

test "cleanup: a gh that hangs is cut off, and not asked again in the same sweep" {
    var f: Fixture = .{};
    try f.init(.{ .gh_timeout_ms = 300 });
    defer f.deinit();
    const a = f.a;
    const w1 = try f.spawned("a1");
    try f.archive("a1");
    const w2 = try f.spawned("a2");
    try f.archive("a2");
    try f.gh("exec sleep 30");
    const r = try f.d.run(a, &.{ "agent", "clean", "--merged=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const list = items(r.json, "worktrees");
    try f.expectKept(list[0], "a1", w1, "gh_unavailable");
    try f.expectKept(list[1], "a2", w2, "gh_unavailable");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try f.ghLog(), "\n"));
}

test "cleanup: a folder that is no longer the agent's is left alone" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");

    // Lock taken over, or lifted.
    _ = try gitOk(a, f.repo, &.{ "worktree", "unlock", w });
    var e = try f.clean("a1", false);
    try testing.expectEqualStrings("not_ours", str(e, "reason"));
    try testing.expect(exists(w));
    _ = try gitOk(a, f.repo, &.{ "worktree", "lock", "--reason", "venom: agent a9", w });
    e = try f.clean("a1", false);
    try testing.expectEqualStrings("not_ours", str(e, "reason"));
    try testing.expect(exists(w));
    try testing.expect(try iso.branchExists(a, f.repo, "venom/a1"));

    // Removed by hand and the path now holds something else entirely.
    _ = try gitOk(a, f.repo, &.{ "worktree", "unlock", w });
    _ = try gitOk(a, f.repo, &.{ "worktree", "remove", w });
    try f.file(w, "precious", "x");
    e = try f.clean("a1", false);
    try testing.expectEqualStrings("kept", str(e, "outcome"));
    try testing.expectEqualStrings("not_ours", str(e, "reason"));
    try testing.expect(exists(try f.fmt("{s}/precious", .{w})));
}

test "cleanup: a missing folder: an explicit clean clears only that entry, once its commits are safe" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    // Someone else's worktree, also missing and unlocked: not ours to prune.
    const other = try f.fmt("{s}/other", .{f.d.dir});
    _ = try gitOk(a, f.repo, &.{ "worktree", "add", "-q", "-b", "other", other });
    try std.Io.Dir.cwd().deleteTree(testing.io, other);
    try std.Io.Dir.cwd().deleteTree(testing.io, w);
    const e = try f.clean("a1", false);
    try testing.expectEqualStrings("gone", str(e, "outcome"));
    try testing.expect(e.object.get("branch_deleted").?.bool);
    try testing.expect(!try iso.branchExists(a, f.repo, "venom/a1"));
    const list = try gitOk(a, f.repo, &.{ "worktree", "list", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, list, w) == null);
    try testing.expect(std.mem.indexOf(u8, list, other) != null);
}

test "cleanup: a missing folder whose commits are nowhere else keeps its registration" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;

    // On the branch.
    const w1 = try f.spawned("a1");
    try f.archive("a1");
    _ = try f.commit(w1, "only here");
    try std.Io.Dir.cwd().deleteTree(testing.io, w1);
    var e = try f.clean("a1", false);
    try testing.expectEqualStrings("kept", str(e, "outcome"));
    try testing.expectEqualStrings("unpushed", str(e, "reason"));
    try testing.expect(try iso.branchExists(a, f.repo, "venom/a1"));
    var list = try gitOk(a, f.repo, &.{ "worktree", "list", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, list, w1) != null);
    try testing.expect(std.mem.indexOf(u8, list, "locked venom: agent a1") != null);

    // On a detached HEAD: only the registration holds the commit.
    const w2 = try f.spawned("a2");
    try f.archive("a2");
    _ = try gitOk(a, w2, &.{ "checkout", "-q", "--detach" });
    const oid = try f.commit(w2, "detached");
    try std.Io.Dir.cwd().deleteTree(testing.io, w2);
    e = try f.clean("a2", false);
    try testing.expectEqualStrings("kept", str(e, "outcome"));
    try testing.expectEqualStrings("unpushed", str(e, "reason"));
    list = try gitOk(a, f.repo, &.{ "worktree", "list", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, list, oid) != null);
}

test "cleanup: a folder only temporarily absent survives a merged clean and works when it returns" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    try f.gh("echo '[]'");
    const away = try f.fmt("{s}.away", .{w});
    try f.sh(&.{ "mv", w, away });
    const e = try f.clean("a1", true);
    try testing.expectEqualStrings("kept", str(e, "outcome"));
    try testing.expectEqualStrings("folder_missing", str(e, "reason"));
    try f.sh(&.{ "mv", away, w });
    try testing.expectEqualStrings("", try gitOk(a, w, &.{ "status", "--porcelain" }));
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: an empty folder at a registered path is not the worktree, and git never walks up from it" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    try std.Io.Dir.cwd().deleteTree(testing.io, w);
    try std.Io.Dir.cwd().createDirPath(testing.io, w);
    const e = try f.clean("a1", false);
    try testing.expectEqualStrings("kept", str(e, "outcome"));
    try testing.expectEqualStrings("not_ours", str(e, "reason"));
    try testing.expect(exists(w));
    try testing.expect(try iso.branchExists(a, f.repo, "venom/a1"));
}

test "cleanup: config cannot hide changes from the checks" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    // git worktree remove honours this one too, so nothing else would stop it.
    _ = try gitOk(a, f.repo, &.{ "config", "status.showUntrackedFiles", "no" });
    try f.file(w, "untracked.txt", "work");
    try f.expectKept(try f.clean("a1", false), "a1", w, "uncommitted");
    try testing.expect(exists(try f.fmt("{s}/untracked.txt", .{w})));
    try f.sh(&.{ "rm", try f.fmt("{s}/untracked.txt", .{w}) });

    // Told to ignore a tracked file's changes.
    _ = try gitOk(a, w, &.{ "update-index", "--assume-unchanged", "README" });
    try f.file(w, "README", "hidden");
    try f.expectKept(try f.clean("a1", false), "a1", w, "uncommitted");
    _ = try gitOk(a, w, &.{ "update-index", "--no-assume-unchanged", "README" });
    _ = try gitOk(a, w, &.{ "checkout", "--", "README" });

    // Replace refs cannot make a commit look like a pushed one.
    const pushed = std.mem.trimEnd(u8, try gitOk(a, w, &.{ "rev-parse", "HEAD" }), "\n");
    const work = try f.commit(w, "work");
    _ = try gitOk(a, f.repo, &.{ "replace", work, pushed });
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
}

test "cleanup: a stale remote-tracking ref does not count as pushed" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    const oid = try f.commit(w, "feature");
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    // Deleted on the remote, unmerged, and not pruned here.
    _ = try gitOk(a, try f.origin(), &.{ "branch", "-D", "venom/a1" });
    _ = try gitOk(a, f.repo, &.{ "rev-parse", "--verify", "origin/venom/a1" });
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
    try f.gh("echo '[]'");
    try f.expectKept(try f.clean("a1", true), "a1", w, "not_merged");
    // So the later prune loses nothing.
    _ = try gitOk(a, f.repo, &.{ "fetch", "-q", "--prune", "origin" });
    try testing.expectEqualStrings(oid, std.mem.trimEnd(u8, try gitOk(a, f.repo, &.{ "rev-parse", "refs/heads/venom/a1" }), "\n"));
    // Pushed again: it goes.
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: a remote that cannot be reached proves nothing" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    _ = try f.commit(w, "feature");
    _ = try gitOk(a, w, &.{ "push", "-q", "origin", "venom/a1" });
    const away = try f.fmt("{s}.away", .{try f.origin()});
    try f.sh(&.{ "mv", try f.origin(), away });
    try f.expectKept(try f.clean("a1", false), "a1", w, "remote_unavailable");
    try f.sh(&.{ "mv", away, try f.origin() });
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: a stale remote-tracking ref does not save a copy either" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const r = try iso.spawn(&f.d, a, &.{ "--repos=[\"a\"]", "--isolation=copy" });
    const c = str(r.json, "cwd");
    _ = try f.d.waitState(a, "a1", "settled");
    try f.archive("a1");
    _ = try f.commit(c, "feature");
    _ = try gitOk(a, c, &.{ "push", "-q", "origin", "HEAD:refs/heads/copied" });
    _ = try gitOk(a, c, &.{ "fetch", "-q", "origin" });
    _ = try gitOk(a, try f.origin(), &.{ "branch", "-D", "copied" });
    const e = try f.clean("a1", false);
    try testing.expectEqualStrings("unpushed", str(e, "reason"));
    try testing.expect(exists(c));
}

test "cleanup: a per-worktree ref holding the only copy of a commit keeps the worktree" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    const oid = try f.commit(w, "kept by a ref");
    _ = try gitOk(a, w, &.{ "update-ref", "refs/worktree/keep", oid });
    _ = try gitOk(a, w, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try f.expectKept(try f.clean("a1", false), "a1", w, "unpushed");
    _ = try gitOk(a, w, &.{ "update-ref", "-d", "refs/worktree/keep" });
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: gh failing for one repo says nothing about another" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const wa = try f.spawned("a1");
    try f.archive("a1");
    const wb = try f.spawnedIn("b", "a2");
    try f.archive("a2");
    const oid = try f.commit(wb, "merged");
    try f.gh(try f.fmt(
        \\case "$PWD" in
        \\*/a) echo 'not a GitHub repo' >&2; exit 1;;
        \\*) echo '{s}';;
        \\esac
    , .{try prList(a, oid, "MERGED", false)}));
    const r = try f.d.run(a, &.{ "agent", "clean", "--merged=true" });
    const list = items(r.json, "worktrees");
    try f.expectKept(list[0], "a1", wa, "gh_unavailable");
    try testing.expectEqualStrings("removed", str(list[1], "outcome"));
    try testing.expect(!exists(wb));
}

test "cleanup: a call out of time keeps what it has not reached" {
    var f: Fixture = .{};
    try f.init(.{ .clean_budget_ms = -1 });
    defer f.deinit();
    const w = try f.spawned("a1");
    try f.archive("a1");
    try f.expectKept(try f.clean("a1", false), "a1", w, "timed_out");
}

test "cleanup: a copy goes on an explicit clean unless it holds its own commits or changes" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    var r = try iso.spawn(&f.d, a, &.{ "--repos=[\"a\"]", "--isolation=copy" });
    const c = str(r.json, "cwd");
    _ = try f.d.waitState(a, "a1", "settled");
    try f.archive("a1");

    // No branch, so no PR.
    var e = try f.clean("a1", true);
    try testing.expectEqualStrings("not_merged", str(e, "reason"));
    try f.file(c, "new.txt", "x");
    e = try f.clean("a1", false);
    try testing.expectEqualStrings("uncommitted", str(e, "reason"));
    _ = try f.commit(c, "new.txt");
    e = try f.clean("a1", false);
    try testing.expectEqualStrings("unpushed", str(e, "reason"));
    try testing.expect(exists(c));
    // A stash lives in the copy alone too.
    _ = try gitOk(a, c, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try f.file(c, "README", "stashed");
    _ = try gitOk(a, c, &.{ "stash", "-q" });
    e = try f.clean("a1", false);
    try testing.expectEqualStrings("unpushed", str(e, "reason"));
    _ = try gitOk(a, c, &.{ "stash", "drop", "-q" });
    e = try f.clean("a1", false);
    try testing.expectEqualStrings("removed", str(e, "outcome"));
    try testing.expect(!exists(c));

    // Not venom's copy any more: the marker is another agent's.
    r = try iso.spawn(&f.d, a, &.{ "--repos=[\"a\"]", "--isolation=copy" });
    const c2 = str(r.json, "cwd");
    _ = try f.d.waitState(a, "a2", "settled");
    try f.archive("a2");
    try f.file(c2, ".git/venom-copy", "venom: agent a9\n");
    e = try f.clean("a2", false);
    try testing.expectEqualStrings("not_ours", str(e, "reason"));
    try testing.expect(exists(c2));
}

test "cleanup: archive --clean of a running agent leaves the worktree until it has stopped" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    var r = try f.d.run(a, &.{ "agent", "spawn", "--task=slow", "--harness=fake", try f.fmt("--workspace={s}", .{f.d.work}), "--repos=[\"a\"]" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const w = str(r.json, "cwd");
    _ = try f.d.waitState(a, "a1", "running");
    r = try f.d.run(a, &.{ "agent", "archive", "--agent=a1", "--clean=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const e = items(r.json, "worktrees")[0];
    try testing.expectEqualStrings("kept", str(e, "outcome"));
    try testing.expectEqualStrings("agent_active", str(e, "reason"));
    try testing.expect(exists(w));
    _ = try f.d.waitState(a, "a1", "archived");
    try f.expectRemoved(try f.clean("a1", false), "a1", w);
}

test "cleanup: an agent with a sub-agent that is not archived counts as active" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", ta);
    defer ta.free(dir);
    const path = try std.fmt.allocPrint(ta, "{s}/{s}", .{ dir, eventlog.file_name });
    defer ta.free(path);
    var engine = try eventlog.Engine.open(ta, path, .{});
    defer engine.deinit();
    try engine.start();
    _ = try engine.submit(.{ .create = .{ .agent = "a1", .title = "t", .harness = "fake", .workspace = "/w" } });
    _ = try engine.submit(.{ .create = .{ .agent = "a2", .title = "t", .harness = "fake", .workspace = "/w", .parent = "a1" } });
    _ = try engine.submit(.{ .create = .{ .agent = "a3", .title = "t", .harness = "fake", .workspace = "/w", .parent = "a2" } });
    for ([_][]const u8{ "a1", "a2" }) |id| _ = try engine.submit(.{ .archive = .{ .agent = id } });
    try testing.expect(agents.activeDescendant(&engine.state, "a1"));
    try testing.expect(agents.activeDescendant(&engine.state, "a2"));
    try testing.expect(!agents.activeDescendant(&engine.state, "a3"));
    _ = try engine.submit(.{ .archive = .{ .agent = "a3" } });
    try testing.expect(!agents.activeDescendant(&engine.state, "a1"));
}

test "cleanup: a repo's clean filter never runs, in the checks or in git worktree remove" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    _ = try gitOk(a, f.repo, &.{ "push", "-q", "origin", "venom/a1" });
    const marker = try f.fmt("{s}/filter-ran", .{f.d.dir});
    // Clean only: nothing else could be what is neutralised.
    _ = try gitOk(a, f.repo, &.{ "config", "filter.x.clean", try f.fmt("touch {s}; cat", .{marker}) });
    try f.file(f.repo, ".git/info/attributes", "* filter=x\n");
    // Stat-dirty tracked file: git has to look at its content.
    try f.sh(&.{ "touch", try f.fmt("{s}/README", .{w}) });

    // The fixture works: plain git runs the filter here.
    const plain = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", w, "status", "--porcelain" } });
    try testing.expect(plain.term.success());
    try testing.expect(exists(marker));
    try f.sh(&.{ "rm", marker });
    try f.sh(&.{ "touch", try f.fmt("{s}/README", .{w}) });

    const e = try f.clean("a1", false);
    try f.expectRemoved(e, "a1", w);
    try testing.expect(!exists(marker));
}

test "cleanup: a filter only the removed worktree's own config defines never runs" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const a = f.a;
    const w = try f.spawned("a1");
    try f.archive("a1");
    _ = try gitOk(a, f.repo, &.{ "push", "-q", "origin", "venom/a1" });
    const marker = try f.fmt("{s}/filter-ran", .{f.d.dir});
    _ = try gitOk(a, f.repo, &.{ "config", "extensions.worktreeConfig", "true" });
    _ = try gitOk(a, w, &.{ "config", "--worktree", "filter.x.clean", try f.fmt("touch {s}; cat", .{marker}) });
    try f.file(f.repo, ".git/info/attributes", "* filter=x\n");
    try f.sh(&.{ "touch", try f.fmt("{s}/README", .{w}) });

    // The main repo's config does not know the filter; the worktree's does.
    const plain = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", w, "status", "--porcelain" } });
    try testing.expect(plain.term.success());
    try testing.expect(exists(marker));
    try f.sh(&.{ "rm", marker });
    try f.sh(&.{ "touch", try f.fmt("{s}/README", .{w}) });

    const e = try f.clean("a1", false);
    try f.expectRemoved(e, "a1", w);
    try testing.expect(!exists(marker));
}
