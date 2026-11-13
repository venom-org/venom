//! Workspaces: folders the user adds to venom.
//! Each holds 0..n repos, the git roots discovery finds under it on
//! `workspace add` and `workspace scan`; repos are never configured. A
//! single repo is a workspace with one repo ("."); a folder without git is a
//! workspace with no repos, where agents run in place.
//!
//! Workspaces are durable: the verbs submit `workspace_*` commands to the
//! event log (`eventlog/workspaces.zig` holds the decider half and nesting).
//!
//! Discovery rules:
//! - A directory with a `.git` entry (directory, or file for a linked
//!   worktree) is a repo. Discovery does not descend into a repo, so
//!   submodules and clones vendored inside a repo are not separate repos.
//! - Linked worktrees count as repos, except venom's own: venom creates its
//!   agent worktrees locked with a reason starting `venom` (`git worktree
//!   add --lock --reason "venom: agent <id>"`), and discovery skips a
//!   worktree whose `<gitdir>/locked` file says so. Likewise a venom copy
//!   (isolation `copy`): a repo whose `.git/venom-copy` exists.
//! - At most `max_depth` directories below the workspace folder are
//!   searched, and at most `max_dirs` directories in all.
//! - Skipped: symlinks (never followed), hidden directories (`.*`), and
//!   `node_modules`, `zig-out`, `target`. Unreadable directories are skipped.
//! - Skipped too: a directory whose name is not UTF-8, and all below it. Its
//!   path cannot be a JSON string, so no verb or event could name such a repo.
const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const eventlog = @import("eventlog/root.zig");
const supervisor = @import("supervisor");
const rules = eventlog.workspaces;
const Engine = eventlog.Engine;

pub const validPath = rules.validPath;

pub const max_depth = 4;
pub const max_dirs = 20_000;
pub const ignored = [_][]const u8{ "node_modules", "zig-out", "target" };

fn skipped(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or !std.unicode.utf8ValidateSlice(name)) return true;
    for (ignored) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The git roots under the directory `root`, relative to it and sorted
/// ("." when `root` is itself a repo). Strings live in `a`.
pub fn discover(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var budget: usize = max_dirs;
    try walk(a, io, dir, "", 0, &budget, &found);
    std.mem.sort([]const u8, found.items, {}, lessThan);
    return found.items;
}

fn walk(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel: []const u8, depth: usize, budget: *usize, found: *std.ArrayList([]const u8)) !void {
    switch (try gitKind(a, io, dir)) {
        .repo => return found.append(a, if (rel.len == 0) "." else rel),
        .venom_worktree => return,
        .none => {},
    }
    if (depth == max_depth) return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or skipped(entry.name)) continue;
        if (budget.* == 0) return;
        budget.* -= 1;
        var sub = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer sub.close(io);
        const sub_rel = if (rel.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, entry.name });
        try walk(a, io, sub, sub_rel, depth + 1, budget, found);
    }
}

const GitKind = enum { none, repo, venom_worktree };

/// The file inside `.git` that marks a venom copy (`isolation.zig`).
pub const copy_marker = "venom-copy";

fn gitKind(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GitKind {
    const st = dir.statFile(io, ".git", .{ .follow_symlinks = false }) catch return .none;
    switch (st.kind) {
        .directory => {
            _ = dir.statFile(io, ".git/" ++ copy_marker, .{ .follow_symlinks = false }) catch return .repo;
            return .venom_worktree;
        },
        .file => {},
        else => return .none,
    }
    // A linked worktree: `.git` is `gitdir: <path>` (see gitrepository-layout(5)).
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const text = dir.readFile(io, ".git", &buf) catch return .repo;
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return .repo;
    const gitdir = std.mem.trim(u8, line["gitdir:".len..], " \t");
    if (gitdir.len == 0) return .repo;
    const locked = try std.fmt.allocPrint(a, "{s}/locked", .{gitdir});
    var reason_buf: [64]u8 = undefined;
    const base = if (gitdir[0] == '/') std.Io.Dir.cwd() else dir;
    // Only the start matters; a longer reason is read in part.
    const reason = base.readFile(io, locked, &reason_buf) catch return .repo;
    return if (std.mem.startsWith(u8, reason, "venom")) .venom_worktree else .repo;
}

/// One repo as the verbs show it.
pub const Repo = struct { name: []const u8, path: []const u8 };

fn repoItems(a: std.mem.Allocator, w: rules.Workspace) ![]Repo {
    const items = try a.alloc(Repo, w.repos.len);
    for (w.repos, items) |name, *item| item.* = .{
        .name = name,
        .path = if (std.mem.eql(u8, name, ".")) w.path else if (std.mem.eql(u8, w.path, "/")) try std.fmt.allocPrint(a, "/{s}", .{name}) else try std.fmt.allocPrint(a, "{s}/{s}", .{ w.path, name }),
    };
    return items;
}

/// One repo of `workspace.list`: the repo and what git says about it now.
/// A fact git cannot give (not a repo any more, no commit yet, a detached
/// HEAD) is left out.
pub const ListedRepo = struct {
    name: []const u8,
    path: []const u8,
    /// The checked-out branch.
    branch: ?[]const u8 = null,
    /// The working tree has changes (staged, unstaged or untracked).
    dirty: ?bool = null,
    /// Linked worktrees of the repo, venom's own included.
    worktrees: ?usize = null,
    /// The issue the branch is named for (`246-hello-caps` is 246).
    issue: ?[]const u8 = null,
};

/// The issue number a branch name starts with: digits, then `-`.
pub fn branchIssue(branch: []const u8) ?[]const u8 {
    var n: usize = 0;
    while (n < branch.len and std.ascii.isDigit(branch[n])) n += 1;
    if (n == 0 or n > 12 or n == branch.len or branch[n] != '-' or branch[0] == '0') return null;
    return branch[0..n];
}

/// One git command of `facts`.
pub const fact_timeout_ms = 300;
/// All of one `workspace.list`: repos reached after it are listed without
/// facts.
pub const list_deadline_ms = 2000;
/// Status output kept; more than this is a very dirty tree.
const status_limit = 1 << 16;

/// What git says about the repo at `path` (a git root found by discovery).
/// Reads only, with the repo's config pinned and every command cut off
/// (`safe_git.run`), since this runs on the reactor thread from a
/// read verb. A fact that git did not give in time is left out; past
/// `deadline_ms` (`supervisor.monotonicMs`) none is asked. Strings live in `a`.
pub fn facts(a: std.mem.Allocator, io: std.Io, repo: Repo, deadline_ms: i64) !ListedRepo {
    var out: ListedRepo = .{ .name = repo.name, .path = repo.path };
    const cleanup = @import("cleanup.zig");
    const safe_git = @import("safe_git.zig");
    if (supervisor.monotonicMs() > deadline_ms) return out;
    const head = try safe_git.run(a, io, repo.path, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, .{ .timeout_ms = fact_timeout_ms, .until_ms = deadline_ms, .stdout_limit = 4096, .reads_tree = false });
    if (head.ok) {
        const b = std.mem.trim(u8, head.stdout, " \t\r\n");
        if (b.len > 0) {
            out.branch = b;
            out.issue = branchIssue(b);
        }
    }
    if (supervisor.monotonicMs() > deadline_ms) return out;
    const st = try safe_git.run(a, io, repo.path, &.{ "--no-optional-locks", "status", "--porcelain=v1" }, .{ .timeout_ms = fact_timeout_ms, .until_ms = deadline_ms, .stdout_limit = status_limit, .config = &cleanup.pinned });
    if (st.ok) {
        out.dirty = std.mem.trim(u8, st.stdout, " \t\r\n").len > 0;
    } else if (std.mem.indexOf(u8, st.stderr, "StreamTooLong") != null) out.dirty = true;
    if (supervisor.monotonicMs() > deadline_ms) return out;
    const wl = try safe_git.run(a, io, repo.path, &.{ "worktree", "list", "--porcelain" }, .{ .timeout_ms = fact_timeout_ms, .until_ms = deadline_ms, .stdout_limit = 1 << 20, .reads_tree = false });
    if (wl.ok) {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, wl.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "worktree ")) n += 1;
        }
        out.worktrees = n -| 1;
    }
    return out;
}

/// The workspace verbs and doctor check over the durable event log.
/// `engine` must be open before the first call.
pub const Workspaces = struct {
    engine: *Engine,
    io: std.Io,

    pub const PathParams = struct { path: []const u8 };
    pub const ScanParams = struct { path: ?[]const u8 = null };

    pub fn state(self: *const Workspaces) *const eventlog.State {
        return &self.engine.state;
    }

    /// The workspace that owns `path` (nesting: the closest one), if any.
    pub fn owner(self: *const Workspaces, path: []const u8) ?*const rules.Workspace {
        return rules.owner(self.state(), path);
    }

    /// `workspace.list` (read).
    pub fn call(self: *Workspaces, c: *proto.Call) anyerror!void {
        const a = c.arena();
        const Item = struct { path: []const u8, repos: []ListedRepo };
        const ws = self.state().workspaces.values();
        const deadline = supervisor.monotonicMs() + list_deadline_ms;
        const items = try a.alloc(Item, ws.len);
        var n: usize = 0;
        for (ws) |w| {
            if (!@import("principals.zig").readable(c, .{ .kind = "workspace", .id = w.path })) continue;
            const plain = try repoItems(a, w);
            const listed = try a.alloc(ListedRepo, plain.len);
            for (plain, listed) |r, *l| l.* = try facts(a, self.io, r, deadline);
            items[n] = .{ .path = w.path, .repos = listed };
            n += 1;
        }
        try c.ok(.{ .workspaces = items[0..n] });
    }

    pub fn adder(self: *Workspaces) Add {
        return .{ .workspaces = self };
    }
    pub fn remover(self: *Workspaces) Remove {
        return .{ .workspaces = self };
    }
    pub fn scanner(self: *Workspaces) Scan {
        return .{ .workspaces = self };
    }

    /// Discovery for a known path, or the verb's error when the folder is
    /// missing or not a directory.
    fn find(c: *proto.Call, io: std.Io, path: []const u8) !?[]const []const u8 {
        return discover(c.arena(), io, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => {
                try c.fail("not_found.workspace_path", "workspace folder does not exist", .{ .path = path });
                return null;
            },
            error.NotDir => {
                try c.fail("invalid_params.workspace_path", "workspace path is not a directory", .{ .path = path });
                return null;
            },
            else => {
                try c.fail("unavailable.workspace_path", "workspace folder cannot be read", .{ .path = path, .reason = @errorName(err) });
                return null;
            },
        };
    }

    /// `workspace.add` (write).
    pub const Add = struct {
        workspaces: *Workspaces,
        pub fn call(self: *Add, c: *proto.Call, params: PathParams) anyerror!void {
            if (!validPath(params.path))
                return c.fail("invalid_params.workspace_path", "workspace path must be absolute and normalized", .{ .path = params.path });
            if (!try c.authorize(.write, .{ .kind = "workspace", .id = params.path })) return;
            const ws = self.workspaces;
            if (ws.state().workspaces.get(params.path)) |w|
                return c.ok(.{ .path = w.path, .added = false, .repos = try repoItems(c.arena(), w) });
            const repos = try find(c, ws.io, params.path) orelse return;
            _ = try ws.engine.submit(.{ .workspace_add = .{ .path = params.path, .repos = repos } });
            try c.ok(.{ .path = params.path, .added = true, .repos = try repoItems(c.arena(), .{ .path = params.path, .repos = repos }) });
        }
    };

    /// `workspace.remove` (write). Forgets the workspace; its folder and
    /// repos are untouched.
    pub const Remove = struct {
        workspaces: *Workspaces,
        pub fn call(self: *Remove, c: *proto.Call, params: PathParams) anyerror!void {
            if (!try c.authorize(.write, .{ .kind = "workspace", .id = params.path })) return;
            const n = self.workspaces.engine.submit(.{ .workspace_remove = .{ .path = params.path } }) catch |err| switch (err) {
                error.NotFound => 0,
                else => return err,
            };
            try c.ok(.{ .path = params.path, .removed = n != 0 });
        }
    };

    /// `workspace.scan` (write): runs discovery again for one workspace or
    /// all of them. A missing folder keeps its last repos (`missing`).
    pub const Scan = struct {
        workspaces: *Workspaces,
        pub fn call(self: *Scan, c: *proto.Call, params: ScanParams) anyerror!void {
            const ws = self.workspaces;
            const a = c.arena();
            const Item = struct { path: []const u8, repos: []Repo, changed: bool, missing: bool };
            var items: std.ArrayList(Item) = .empty;
            // Copy the paths first: a scan commit changes the state.
            var paths: std.ArrayList([]const u8) = .empty;
            if (params.path) |p| {
                if (!try c.authorize(.write, .{ .kind = "workspace", .id = p })) return;
                if (!ws.state().workspaces.contains(p)) return c.fail("not_found.workspace", "no such workspace", .{ .path = p });
                try paths.append(a, try a.dupe(u8, p));
            } else for (ws.state().workspaces.keys()) |p| {
                // A scan of all scans those the caller may write.
                const reg = c.conn.registry orelse continue;
                if (!reg.allows(c.conn.identity, .write, .{ .kind = "workspace", .id = p }, proto.grants.nowSeconds())) continue;
                try paths.append(a, try a.dupe(u8, p));
            }
            for (paths.items) |p| {
                const repos = discover(a, ws.io, p) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        if (params.path != null) return c.fail("not_found.workspace_path", "workspace folder does not exist or cannot be read", .{ .path = p, .reason = @errorName(err) });
                        const w = ws.state().workspaces.get(p).?;
                        try items.append(a, .{ .path = p, .repos = try repoItems(a, w), .changed = false, .missing = true });
                        continue;
                    },
                };
                const n = try ws.engine.submit(.{ .workspace_scan = .{ .path = p, .repos = repos } });
                try items.append(a, .{ .path = p, .repos = try repoItems(a, .{ .path = p, .repos = repos }), .changed = n != 0, .missing = false });
            }
            try c.ok(.{ .workspaces = items.items });
        }
    };

    /// Doctor: each workspace's folder
    /// exists, and its repos match what discovery finds now. Read-only.
    pub fn check(self: *Workspaces) Check {
        return .{ .workspaces = self };
    }

    pub const Check = struct {
        workspaces: *Workspaces,
        pub fn run(self: *Check, r: *cli.doctor.Report) anyerror!void {
            const ws = self.workspaces;
            const all = ws.state().workspaces.values();
            if (all.len == 0) return r.add("workspace.path", .ok, "no workspaces added yet", "venom workspace list --json");
            for (all) |w| {
                const now = discover(r.arena, ws.io, w.path) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try r.add("workspace.path", .fail, try r.print("workspace {s} cannot be opened ({s}); restore the folder or remove the workspace", .{ w.path, @errorName(err) }), try r.command("venom workspace remove --path={s} --json", w.path));
                    continue;
                };
                try r.add("workspace.path", .ok, try r.print("workspace {s} exists", .{w.path}), "venom workspace list --json");
                const scan = try r.command("venom workspace scan --path={s} --json", w.path);
                if (!sameRepos(now, w.repos)) {
                    try r.add("workspace.repos", .warn, try r.print("workspace {s}: repos changed since the last scan ({d} recorded, {d} found)", .{ w.path, w.repos.len, now.len }), scan);
                } else if (now.len == 0) {
                    try r.add("workspace.repos", .ok, try r.print("workspace {s} has no repos; agents run in place", .{w.path}), scan);
                } else {
                    try r.add("workspace.repos", .ok, try r.print("workspace {s} has {d} repo{s}", .{ w.path, now.len, if (now.len == 1) "" else "s" }), scan);
                }
            }
        }
    };
};

fn sameRepos(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}
