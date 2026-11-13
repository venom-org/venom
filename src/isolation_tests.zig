//! Worktree isolation with the fake harness through
//! the generated CLI (`--json`), on real git repos made in the test's temp
//! dir (never the user's): spawn makes the right worktrees, names and
//! branches for a 2-repo scope; `--dry-run` lists exactly those and makes
//! nothing; a name collision fails with a stable error before anything is
//! made. Also: one repo (the agent starts in its worktree), `copy`,
//! `in_place`, and a folder that is not a git root of its own (refused, so
//! git never acts on an enclosing repo). Uses `agent_verbs_tests.zig`'s
//! daemon (real serve loop; vendor harnesses off, fake harness only).
const std = @import("std");
const Daemon = @import("agent_verbs_tests.zig").Daemon;
const testing = std.testing;
const ta = testing.allocator;
const Value = std.json.Value;

const script =
    \\{"turns":[{"match":"","steps":[{"text":"Done."}]}]}
;

pub fn str(v: Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
pub fn errorCode(v: Value) []const u8 {
    return v.object.get("error").?.object.get("code").?.string;
}
pub fn items(v: Value, key: []const u8) []const Value {
    return v.object.get(key).?.array.items;
}

/// Runs git with no user config that could sign, hook or prompt.
pub fn git(a: std.mem.Allocator, repo: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "-C", repo, "-c", "user.name=venom-test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" });
    try argv.appendSlice(a, args);
    const r = try std.process.run(a, testing.io, .{ .argv = argv.items });
    return r;
}

pub fn gitOk(a: std.mem.Allocator, repo: []const u8, args: []const []const u8) ![]const u8 {
    const r = try git(a, repo, args);
    if (!r.term.success()) {
        std.debug.print("git {s}: {s}\n", .{ args[0], r.stderr });
        return error.GitFailed;
    }
    return r.stdout;
}

pub fn hasGit(a: std.mem.Allocator) bool {
    const r = std.process.run(a, testing.io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    return r.term.success();
}

pub fn exists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(testing.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

pub fn branchExists(a: std.mem.Allocator, repo: []const u8, branch: []const u8) !bool {
    const r = try git(a, repo, &.{ "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch}) });
    return r.term.success();
}

/// `work/{a,b,c}`: real repos with one commit; `work` is the workspace.
pub fn tree(d: *Daemon, a: std.mem.Allocator) !void {
    for ([_][]const u8{ "a", "b", "c" }) |name| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ d.work, name });
        try std.Io.Dir.cwd().createDirPath(testing.io, path);
        _ = try gitOk(a, path, &.{ "init", "-q", "-b", "main" });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/README", .{path}), .data = name });
        _ = try gitOk(a, path, &.{ "add", "README" });
        _ = try gitOk(a, path, &.{ "commit", "-q", "-m", "init" });
    }
    const r = try d.run(a, &.{ "workspace", "add", try std.fmt.allocPrint(a, "--path={s}", .{d.work}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 3), items(r.json, "repos").len);
}

pub fn spawn(d: *Daemon, a: std.mem.Allocator, extra: []const []const u8) !Daemon.Out {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "agent", "spawn", "--task=work on it", "--harness=fake", try std.fmt.allocPrint(a, "--workspace={s}", .{d.work}) });
    try args.appendSlice(a, extra);
    return d.run(a, args.items);
}

fn expectSameStrings(want: []const Value, got: []const Value) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w.string, g.string);
}

test "isolation: a 2-repo scope gets one locked worktree per repo; the dry run lists exactly those and makes nothing" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try tree(&d, a);
    const ra = try std.fmt.allocPrint(a, "{s}/a", .{d.work});
    const rb = try std.fmt.allocPrint(a, "{s}/b", .{d.work});
    const wa = try std.fmt.allocPrint(a, "{s}/a-246", .{d.work});
    const wb = try std.fmt.allocPrint(a, "{s}/b-246", .{d.work});
    const linked = [_][]const u8{ "--repos=[\"b\",\"a\"]", "--issue=246", "--branch=246-hello-caps" };

    // Dry run: the "Will create" preview, nothing on disk or in git.
    const dry = try spawn(&d, a, &(linked ++ .{"--dry-run=true"}));
    try testing.expectEqual(@as(u8, 0), dry.status);
    try testing.expect(dry.json.object.get("dry_run").?.bool);
    try testing.expectEqualStrings("worktree", str(dry.json, "isolation"));
    try testing.expectEqualStrings("a1", str(dry.json, "agent"));
    const names = items(dry.json, "worktrees");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a-246", names[0].string);
    try testing.expectEqualStrings("b-246", names[1].string);
    const planned = items(dry.json, "checkouts");
    try testing.expectEqualStrings(wa, str(planned[0], "path"));
    try testing.expectEqualStrings("246-hello-caps", str(planned[1], "branch"));
    try testing.expect(planned[0].object.get("new_branch").?.bool);
    try testing.expect(!exists(wa) and !exists(wb));
    try testing.expect(!try branchExists(a, ra, "246-hello-caps"));
    var r = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqual(@as(usize, 0), items(r.json, "agents").len);

    // The spawn makes exactly what the dry run listed.
    r = try spawn(&d, a, &linked);
    try testing.expectEqual(@as(u8, 0), r.status);
    // The list reports the linked issue, for its filter.
    const listed = try d.run(a, &.{ "agent", "list" });
    try testing.expectEqualStrings("246", str(items(listed.json, "agents")[0], "issue"));
    try testing.expect(r.json.object.get("dry_run") == null);
    try testing.expectEqualStrings("a1", str(r.json, "agent"));
    try expectSameStrings(names, items(r.json, "worktrees"));
    for (planned, items(r.json, "checkouts")) |want, got| {
        try testing.expectEqualStrings(str(want, "repo"), str(got, "repo"));
        try testing.expectEqualStrings(str(want, "path"), str(got, "path"));
        try testing.expectEqualStrings(str(want, "branch"), str(got, "branch"));
    }
    // Several worktrees: the agent starts at the workspace root.
    try testing.expectEqualStrings(d.work, str(r.json, "cwd"));
    for ([_][]const u8{ wa, wb }) |w| {
        try testing.expect(exists(w));
        const head = try gitOk(a, w, &.{ "symbolic-ref", "--short", "HEAD" });
        try testing.expectEqualStrings("246-hello-caps\n", head);
    }
    // Locked with venom's reason, so discovery and `worktree prune` skip it.
    const list = try gitOk(a, ra, &.{ "worktree", "list", "--porcelain" });
    try testing.expect(std.mem.indexOf(u8, list, "locked venom: agent a1") != null);
    _ = try gitOk(a, rb, &.{ "worktree", "prune" });
    try testing.expect(exists(wb));
    // The originals stay on main, untouched.
    try testing.expectEqualStrings("main\n", try gitOk(a, ra, &.{ "symbolic-ref", "--short", "HEAD" }));
    _ = try d.waitState(a, "a1", "settled");
    r = try d.run(a, &.{ "workspace", "scan", try std.fmt.allocPrint(a, "--path={s}", .{d.work}) });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 3), items(items(r.json, "workspaces")[0], "repos").len);

    // No issue: `<repo>-<agent-id>` on `venom/<agent-id>`.
    r = try spawn(&d, a, &.{ "--repos=[\"a\",\"b\"]", "--dry-run=true" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("a-a2", items(r.json, "worktrees")[0].string);
    try testing.expectEqualStrings("venom/a2", str(items(r.json, "checkouts")[0], "branch"));
    r = try spawn(&d, a, &.{"--repos=[\"a\",\"b\"]"});
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("b-a2", items(r.json, "worktrees")[1].string);
    try testing.expect(try branchExists(a, rb, "venom/a2"));
    _ = try d.waitState(a, "a2", "settled");
}

test "isolation: a name collision fails with a stable error before anything is made" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try tree(&d, a);
    const ra = try std.fmt.allocPrint(a, "{s}/a", .{d.work});
    // b's target is taken; a's comes first and must not be made either.
    try std.Io.Dir.cwd().createDirPath(testing.io, try std.fmt.allocPrint(a, "{s}/b-7", .{d.work}));
    for ([_]bool{ true, false }) |dry| {
        var r = try spawn(&d, a, if (dry) &.{ "--repos=[\"a\",\"b\"]", "--issue=7", "--dry-run=true" } else &.{ "--repos=[\"a\",\"b\"]", "--issue=7" });
        try testing.expectEqual(@as(u8, 5), r.status);
        try testing.expectEqualStrings("conflict.worktree_exists", errorCode(r.json));
        const data = r.json.object.get("error").?.object.get("data").?;
        try testing.expectEqualStrings("b", str(data, "repo"));
        try testing.expect(!exists(try std.fmt.allocPrint(a, "{s}/a-7", .{d.work})));
        try testing.expect(!try branchExists(a, ra, "venom/a1"));
        r = try d.run(a, &.{ "agent", "list" });
        try testing.expectEqual(@as(usize, 0), items(r.json, "agents").len);
    }

    // The default branch taken: also a conflict, nothing made.
    _ = try gitOk(a, ra, &.{ "branch", "venom/a1" });
    var r = try spawn(&d, a, &.{"--repos=[\"b\",\"c\",\"a\"]"});
    try testing.expectEqualStrings("conflict.branch_exists", errorCode(r.json));
    try testing.expect(!exists(try std.fmt.allocPrint(a, "{s}/b-a1", .{d.work})));
    // An issue branch checked out elsewhere: a conflict; one that is free
    // is reused.
    r = try spawn(&d, a, &.{ "--repos=[\"a\"]", "--branch=main" });
    try testing.expectEqualStrings("conflict.branch_checked_out", errorCode(r.json));
    r = try spawn(&d, a, &.{ "--repos=[\"a\"]", "--issue=8", "--branch=venom/a1" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expect(!items(r.json, "checkouts")[0].object.get("new_branch").?.bool);
    _ = try d.waitState(a, str(r.json, "agent"), "settled");
    // Bad input.
    r = try spawn(&d, a, &.{ "--repos=[\"a\"]", "--branch=bad..name" });
    try testing.expectEqualStrings("invalid_params.branch", errorCode(r.json));
    for ([_][]const u8{ "--issue=../x", "--issue=ABC-246", "--issue=../x#1" }) |bad| {
        r = try spawn(&d, a, &.{ "--repos=[\"a\"]", bad });
        try testing.expectEqualStrings("invalid_params.issue", errorCode(r.json));
    }
    // Every form of an issue names the same folder.
    for ([_][]const u8{ "--issue=54", "--issue=#54", "--issue=acme/app#54" }) |good| {
        r = try spawn(&d, a, &.{ "--repos=[\"a\"]", good, "--dry-run=true" });
        try testing.expectEqualStrings("a-54", items(r.json, "worktrees")[0].string);
    }
}

test "isolation: one repo starts in its worktree; copy; in_place; a folder that is not its own git root is refused" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try tree(&d, a);

    // One repo: its worktree is the agent's cwd, and the fake runs there.
    var r = try spawn(&d, a, &.{"--repos=[\"c\"]"});
    try testing.expectEqual(@as(u8, 0), r.status);
    const wc = try std.fmt.allocPrint(a, "{s}/c-a1", .{d.work});
    try testing.expectEqualStrings(wc, str(r.json, "cwd"));
    _ = try d.waitState(a, "a1", "settled");

    // copy: a plain copy, marked so discovery skips it; no branch.
    r = try spawn(&d, a, &.{ "--repos=[\"b\"]", "--isolation=copy" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("copy", str(r.json, "isolation"));
    const cb = try std.fmt.allocPrint(a, "{s}/b-a2", .{d.work});
    try testing.expectEqualStrings(cb, str(r.json, "cwd"));
    const branch = items(r.json, "checkouts")[0].object.get("branch");
    try testing.expect(branch == null or branch.? == .null);
    try testing.expect(exists(try std.fmt.allocPrint(a, "{s}/README", .{cb})));
    try testing.expect(exists(try std.fmt.allocPrint(a, "{s}/.git/venom-copy", .{cb})));
    _ = try d.waitState(a, "a2", "settled");
    r = try d.run(a, &.{ "workspace", "scan", try std.fmt.allocPrint(a, "--path={s}", .{d.work}) });
    try testing.expectEqual(@as(usize, 3), items(items(r.json, "workspaces")[0], "repos").len);

    // in_place: nothing made.
    r = try spawn(&d, a, &.{ "--repos=[\"a\"]", "--isolation=in_place" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 0), items(r.json, "worktrees").len);
    try testing.expectEqualStrings(d.work, str(r.json, "cwd"));
    _ = try d.waitState(a, "a3", "settled");

    // `fake` has a `.git` folder but is no repo: git would find whatever
    // repo encloses the temp dir, so it is refused and nothing is made.
    try std.Io.Dir.cwd().createDirPath(testing.io, try std.fmt.allocPrint(a, "{s}/fake/.git", .{d.work}));
    r = try d.run(a, &.{ "workspace", "scan", try std.fmt.allocPrint(a, "--path={s}", .{d.work}) });
    try testing.expectEqual(@as(usize, 4), items(items(r.json, "workspaces")[0], "repos").len);
    r = try spawn(&d, a, &.{"--repos=[\"fake\"]"});
    try testing.expectEqualStrings("unavailable.git", errorCode(r.json));
    try testing.expect(!exists(try std.fmt.allocPrint(a, "{s}/fake-a4", .{d.work})));
}

test "workspace.list reports each repo's branch, changes, worktrees and issue; agent.spawn answers its mode and model" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try tree(&d, a);
    const rb = try std.fmt.allocPrint(a, "{s}/b", .{d.work});
    const rc = try std.fmt.allocPrint(a, "{s}/c", .{d.work});

    // b: on an issue branch with an untracked file; c: detached.
    _ = try gitOk(a, rb, &.{ "switch", "-q", "-c", "246-hello-caps" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/new", .{rb}), .data = "x" });
    _ = try gitOk(a, rc, &.{ "checkout", "-q", "--detach" });
    // And a linked worktree of a, made by hand.
    _ = try gitOk(a, try std.fmt.allocPrint(a, "{s}/a", .{d.work}), &.{ "worktree", "add", "-q", try std.fmt.allocPrint(a, "{s}/elsewhere", .{d.work}), "-b", "side" });

    const r = try d.run(a, &.{ "workspace", "list" });
    try testing.expectEqual(@as(u8, 0), r.status);
    const repos = items(items(r.json, "workspaces")[0], "repos");
    try testing.expectEqual(@as(usize, 3), repos.len);
    const ra = repos[0].object;
    try testing.expectEqualStrings("main", ra.get("branch").?.string);
    try testing.expect(!ra.get("dirty").?.bool);
    try testing.expectEqual(@as(i64, 1), ra.get("worktrees").?.integer);
    try testing.expect(ra.get("issue") == null or ra.get("issue").? == .null);
    const rb_ = repos[1].object;
    try testing.expectEqualStrings("246-hello-caps", rb_.get("branch").?.string);
    try testing.expect(rb_.get("dirty").?.bool);
    try testing.expectEqual(@as(i64, 0), rb_.get("worktrees").?.integer);
    try testing.expectEqualStrings("246", rb_.get("issue").?.string);
    const rc_ = repos[2].object;
    try testing.expect(rc_.get("branch") == null or rc_.get("branch").? == .null);

    // The spawn answer says the mode in effect and the model asked for.
    const dry = try spawn(&d, a, &.{ "--dry-run=true", "--mode=plan", "--model=opus" });
    try testing.expectEqual(@as(u8, 0), dry.status);
    try testing.expectEqualStrings("plan", str(dry.json, "permission_mode"));
    try testing.expectEqualStrings("opus", str(dry.json, "model"));
    const plain = try spawn(&d, a, &.{"--dry-run=true"});
    try testing.expectEqualStrings("ask", str(plain.json, "permission_mode"));
}

test "branchIssue: digits then a dash" {
    try testing.expectEqualStrings("246", @import("workspaces.zig").branchIssue("246-hello-caps").?);
    for ([_][]const u8{ "main", "246", "-246", "0-x", "v2-x", "venom/a1", "1234567890123-x" }) |b| try testing.expect(@import("workspaces.zig").branchIssue(b) == null);
}

test "workspace.list never runs a repo's configured commands, and a very dirty repo keeps its branch" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try tree(&d, a);
    const ra = try std.fmt.allocPrint(a, "{s}/a", .{d.work});
    const marker = try std.fmt.allocPrint(a, "{s}/fsmonitor-ran", .{d.work});
    _ = try gitOk(a, ra, &.{ "config", "core.fsmonitor", try std.fmt.allocPrint(a, "touch {s}; echo", .{marker}) });
    // More untracked files than the status output limit holds.
    const rb = try std.fmt.allocPrint(a, "{s}/b", .{d.work});
    var many: std.ArrayList(u8) = .empty;
    for (0..4000) |i| try many.print(a, "{s}-a-long-file-name-to-fill-the-status-output-{d}\n", .{ "untracked", i });
    var it = std.mem.splitScalar(u8, many.items, '\n');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ rb, name }), .data = "" });
    }

    const r = try d.run(a, &.{ "workspace", "list" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expect(!exists(marker));
    const repos = items(items(r.json, "workspaces")[0], "repos");
    try testing.expectEqualStrings("main", repos[0].object.get("branch").?.string);
    try testing.expectEqualStrings("main", repos[1].object.get("branch").?.string);
    try testing.expect(repos[1].object.get("dirty").?.bool);
}

test "workspace.list never runs a repo's clean filter" {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    if (!hasGit(a)) return error.SkipZigTest;
    var d: Daemon = undefined;
    try d.initWith(.{ .script = script });
    defer d.deinit();
    try tree(&d, a);
    const ra = try std.fmt.allocPrint(a, "{s}/a", .{d.work});
    const marker = try std.fmt.allocPrint(a, "{s}/filter-ran", .{d.work});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/.git/info/attributes", .{ra}), .data = "* filter=x\n" });
    _ = try gitOk(a, ra, &.{ "config", "filter.x.clean", try std.fmt.allocPrint(a, "touch {s}; cat", .{marker}) });
    // Same content, new mtime: git hashes the file again, which is when it
    // would run the filter.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/README", .{ra}), .data = "a" });

    const r = try d.run(a, &.{ "workspace", "list" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expect(!exists(marker));
    const repos = items(items(r.json, "workspaces")[0], "repos");
    try testing.expectEqualStrings("main", repos[0].object.get("branch").?.string);
}
