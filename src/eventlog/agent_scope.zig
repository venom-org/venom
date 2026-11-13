//! Agent scope: the pure part.
//!
//! An agent's scope is the whole workspace (`repos` empty), a set of its
//! repos, or one repo. It always belongs to the workspace closest to its
//! scope root (nested workspaces resolve to the innermost), and it starts
//! at that workspace's root. Repos of the workspace outside the scope are
//! read-only to it.
//!
//! Enforcement has two halves:
//!
//! - **Harness side.** The host hands each adapter the scope's writable
//!   roots and the read-only repos at `start` (`contract.Start`); each
//!   adapter maps them onto the harness's own documented mechanism
//!   (claude-code: `--add-dir` and `permissions.ask` rules; codex: a permission
//!   profile; the fake harness: `--writable`). A write the harness itself
//!   would let through is outside venom's reach; what each harness can and
//!   cannot enforce is listed in the adapters' file comments.
//! - **venom side** (`outsideCall`, used by the decider). An approval for an
//!   edit whose path is outside the scope, or for a command that visibly
//!   writes outside it (`command_writes.zig`), is stamped
//!   `outside_scope` and gets no narrowest grant, so a standing "allow
//!   always" never answers it and "allow always" cannot be recorded for it:
//!   such a write is always asked, and is allowed once at most.
const std = @import("std");
const decider = @import("decider.zig");
const events = @import("events.zig");
const rules = @import("workspaces.zig");
const command_writes = @import("command_writes.zig");
const State = decider.State;
const Agent = decider.Agent;

/// The absolute path of repo `name` (relative, "." for the root itself) of
/// the workspace at `ws`.
pub fn repoPath(a: std.mem.Allocator, ws: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, ".")) return ws;
    if (std.mem.eql(u8, ws, "/")) return std.fmt.allocPrint(a, "/{s}", .{name});
    return std.fmt.allocPrint(a, "{s}/{s}", .{ ws, name });
}

/// The folders an agent may write: its repos, or its workspace when the
/// scope is the whole workspace.
pub fn writable(a: std.mem.Allocator, workspace: []const u8, repos: []const []const u8) ![]const []const u8 {
    if (repos.len == 0) return a.dupe([]const u8, &.{workspace});
    const out = try a.alloc([]const u8, repos.len);
    for (repos, out) |r, *o| o.* = try repoPath(a, workspace, r);
    return out;
}

/// The folders `agent` may write: its worktrees (or copies) when it has
/// any, else `writable` of its scope.
pub fn writableOf(a: std.mem.Allocator, agent: *const Agent) ![]const []const u8 {
    if (agent.worktrees.len == 0) return writable(a, agent.workspace, agent.repos);
    const out = try a.alloc([]const u8, agent.worktrees.len);
    for (agent.worktrees, out) |w, *o| o.* = w.path;
    return out;
}

/// The folders read-only to `agent`: `readOnly` of its scope, plus, when
/// it has worktrees, the repos they were made from.
pub fn readOnlyOf(a: std.mem.Allocator, state: *const State, agent: *const Agent) ![]const []const u8 {
    const base = try readOnly(a, state, agent.workspace, agent.repos);
    if (agent.worktrees.len == 0) return base;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, base);
    for (agent.worktrees) |w| try out.append(a, try repoPath(a, agent.workspace, w.repo));
    return out.items;
}

/// The repos of the agent's workspace that are outside its scope
/// (absolute), i.e. read-only to it. Empty for a whole-workspace scope.
pub fn readOnly(a: std.mem.Allocator, state: *const State, workspace: []const u8, repos: []const []const u8) ![]const []const u8 {
    if (repos.len == 0) return &.{};
    const w = state.workspaces.get(workspace) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (w.repos) |r| {
        if (contains(repos, r)) continue;
        // A repo nested in an in-scope repo is part of it.
        const p = try repoPath(a, workspace, r);
        var inside = false;
        for (repos) |s| inside = inside or rules.within(try repoPath(a, workspace, s), p);
        if (!inside) try out.append(a, p);
    }
    return out.items;
}

/// Whether writing `path` (absolute, or relative to `base`) falls outside
/// the scope. A whole-workspace scope has no outside; an empty path cannot
/// be judged.
pub fn outside(a: std.mem.Allocator, workspace: []const u8, repos: []const []const u8, base: []const u8, path: []const u8) !bool {
    if (repos.len == 0) return false;
    return outsideRoots(a, try writable(a, workspace, repos), base, path);
}

/// Whether writing `path` (absolute, or relative to `base`) falls outside
/// every folder of `roots`. An empty path cannot be judged.
pub fn outsideRoots(a: std.mem.Allocator, roots: []const []const u8, base: []const u8, path: []const u8) !bool {
    if (path.len == 0) return false;
    const abs = try std.fs.path.resolvePosix(a, &.{ base, path });
    for (roots) |root| if (rules.within(root, abs)) return false;
    return true;
}

/// Whether `path` is `root` or under it.
pub const withinPath = rules.within;

/// Whether the approval for tool call `call` of `agent` is a write outside
/// its scope: an `edit` call whose title (the path)
/// is outside, or an `exec` call whose command visibly writes outside
/// (`command_writes.zig`; a program's own writes are not visible).
pub fn outsideCall(a: std.mem.Allocator, agent: *const Agent, call: ?[]const u8) !bool {
    // A whole-workspace scope in place has no outside; with worktrees
    // only they are writable.
    if (agent.repos.len == 0 and agent.worktrees.len == 0) return false;
    const id = call orelse return false;
    var i = agent.transcript.items.len;
    while (i > 0) {
        i -= 1;
        const e = agent.transcript.items[i];
        if (e != .tool_started or !std.mem.eql(u8, e.tool_started.call, id)) continue;
        const t = e.tool_started;
        const args = t.args orelse events.ToolArgs{};
        if (std.mem.eql(u8, t.kind, "exec")) {
            const start = agent.cwd orelse agent.workspace;
            const given = args.cwd orelse start;
            // A folder of its own is what the harness says for this call;
            // otherwise the shell may have moved since.
            const bases = if (std.mem.eql(u8, given, start)) try shellCwds(a, agent, start, i) else try a.dupe(?[]const u8, &.{given});
            return command_writes.writesOutsideFrom(a, try writableOf(a, agent), start, bases, args.command orelse t.title);
        }
        if (!std.mem.eql(u8, t.kind, "edit")) return false;
        return outsideRoots(a, try writableOf(a, agent), agent.cwd orelse agent.workspace, t.title);
    }
    return false;
}

/// The folders the agent's shell may be in before transcript item `upto`
/// (`command_writes.cwdsAfter`): every earlier command that was not declined
/// may have moved it.
fn shellCwds(a: std.mem.Allocator, agent: *const Agent, start: []const u8, upto: usize) ![]const ?[]const u8 {
    var cwds: std.ArrayList(?[]const u8) = .empty;
    try cwds.append(a, start);
    const items = agent.transcript.items;
    for (items[0..upto], 0..) |e, n| {
        if (e != .tool_started or !std.mem.eql(u8, e.tool_started.kind, "exec")) continue;
        const t = e.tool_started;
        const declined = for (items[n + 1 ..]) |later| {
            if (later == .tool_ended and std.mem.eql(u8, later.tool_ended.call, t.call)) break std.mem.eql(u8, later.tool_ended.status, "declined");
        } else false;
        if (declined) continue;
        const args = t.args orelse events.ToolArgs{};
        try command_writes.cwdsAfter(a, &cwds, args.command orelse t.title);
    }
    return cwds.items;
}

pub const Resolved = struct {
    /// The workspace the agent belongs to (its folder when there is none).
    workspace: []const u8,
    /// Relative to `workspace`, sorted; empty: the whole workspace.
    repos: []const []const u8,
};

pub const Failure = union(enum) {
    /// `repos` were named but no workspace holds them.
    no_workspace,
    /// A repo name is not relative and normalized.
    invalid_repo: []const u8,
    /// A repo is not one of the workspace's discovered repos.
    unknown_repo: []const u8,
    /// A folder inside a workspace that holds none of its repos: it is
    /// neither a workspace nor a repo scope.
    not_a_scope,
};

/// Resolves `agent.spawn`'s `--workspace base [--repos …]` to a scope:
///
/// - repos named: they are relative to `base`; the scope root is their
///   deepest common folder, and the agent belongs to the closest workspace
///   holding it; the names are re-expressed relative to that workspace and
///   each must be one of its discovered repos;
/// - no repos, `base` a workspace: the whole workspace;
/// - no repos, `base` inside a workspace: the workspace's repos under
///   `base` (one repo when `base` is a repo);
/// - no repos, `base` in no workspace: an in-place folder, its own scope.
///
/// Null on success; otherwise `fail` says why.
pub fn resolve(a: std.mem.Allocator, state: *const State, base: []const u8, repos: []const []const u8, fail: *Failure) !?Resolved {
    if (repos.len == 0) {
        const w = rules.owner(state, base) orelse return .{ .workspace = base, .repos = &.{} };
        if (std.mem.eql(u8, w.path, base)) return .{ .workspace = w.path, .repos = &.{} };
        var under: std.ArrayList([]const u8) = .empty;
        for (w.repos) |r| {
            const p = try repoPath(a, w.path, r);
            if (rules.within(base, p)) try under.append(a, r);
        }
        // `base` inside a repo (not at its root): that repo.
        if (under.items.len == 0) for (w.repos) |r| {
            if (rules.within(try repoPath(a, w.path, r), base)) try under.append(a, r);
        };
        if (under.items.len == 0) {
            fail.* = .not_a_scope;
            return null;
        }
        return .{ .workspace = w.path, .repos = try minimal(a, w.path, under.items) };
    }
    const abs = try a.alloc([]const u8, repos.len);
    for (repos, abs) |r, *o| {
        if (!validRepo(r)) {
            fail.* = .{ .invalid_repo = r };
            return null;
        }
        o.* = try repoPath(a, base, r);
    }
    var root = abs[0];
    for (abs[1..]) |p| root = common(root, p);
    const w = rules.owner(state, root) orelse {
        fail.* = .no_workspace;
        return null;
    };
    var names: std.ArrayList([]const u8) = .empty;
    for (abs, repos) |p, given| {
        const rel = relative(w.path, p);
        if (!contains(w.repos, rel)) {
            fail.* = .{ .unknown_repo = given };
            return null;
        }
        if (!contains(names.items, rel)) try names.append(a, rel);
    }
    // Every repo of the workspace in scope: the whole workspace.
    if (names.items.len == w.repos.len) return .{ .workspace = w.path, .repos = &.{} };
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return .{ .workspace = w.path, .repos = names.items };
}

/// `repos` without the ones nested in another of them, sorted.
fn minimal(a: std.mem.Allocator, ws: []const u8, repos: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (repos) |r| {
        const p = try repoPath(a, ws, r);
        var nested = false;
        for (repos) |s| if (!std.mem.eql(u8, r, s) and rules.within(try repoPath(a, ws, s), p)) {
            nested = true;
        };
        if (!nested) try out.append(a, r);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Relative, with no empty, `.` (except the lone ".") or `..` components.
fn validRepo(name: []const u8) bool {
    if (std.mem.eql(u8, name, ".")) return true;
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, 0) != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// The deepest folder holding both valid paths.
fn common(x: []const u8, y: []const u8) []const u8 {
    var end: usize = 0;
    var i: usize = 0;
    while (i < x.len and i < y.len and x[i] == y[i]) : (i += 1) {
        if (x[i] == '/') end = i;
    }
    if (i == x.len and (i == y.len or y[i] == '/')) return x;
    if (i == y.len and x[i] == '/') return y;
    return if (end == 0) "/" else x[0..end];
}

/// `path` relative to `root` (which holds it); "." for `root` itself.
fn relative(root: []const u8, path: []const u8) []const u8 {
    if (path.len == root.len) return ".";
    return if (std.mem.eql(u8, root, "/")) path[1..] else path[root.len + 1 ..];
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

const testing = std.testing;

test {
    _ = command_writes;
}

fn fixture(state: *State, s: std.mem.Allocator) !void {
    _ = try decider.apply(state, .{ .workspace_add = .{ .path = "/org", .repos = &.{ "a", "b", "c", "team/x", "team/y" } } }, s);
    _ = try decider.apply(state, .{ .workspace_add = .{ .path = "/org/team", .repos = &.{ "x", "y" } } }, s);
}

test "agent_scope: resolve a workspace, a set of repos, one repo; nested workspaces resolve to the closest" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try fixture(&state, s);
    var fail: Failure = undefined;

    const whole = (try resolve(s, &state, "/org", &.{}, &fail)).?;
    try testing.expectEqualStrings("/org", whole.workspace);
    try testing.expectEqual(@as(usize, 0), whole.repos.len);

    const set = (try resolve(s, &state, "/org", &.{ "b", "a", "a" }, &fail)).?;
    try testing.expectEqualStrings("/org", set.workspace);
    try testing.expectEqual(@as(usize, 2), set.repos.len);
    try testing.expectEqualStrings("a", set.repos[0]);
    try testing.expectEqualStrings("b", set.repos[1]);

    // A repo folder named as the workspace: that one repo.
    const one = (try resolve(s, &state, "/org/c", &.{}, &fail)).?;
    try testing.expectEqualStrings("/org", one.workspace);
    try testing.expectEqualStrings("c", one.repos[0]);

    // Repos of a nested workspace: they belong to the closest one.
    const nested = (try resolve(s, &state, "/org", &.{"team/x"}, &fail)).?;
    try testing.expectEqualStrings("/org/team", nested.workspace);
    try testing.expectEqualStrings("x", nested.repos[0]);
    const inner = (try resolve(s, &state, "/org/team", &.{}, &fail)).?;
    try testing.expectEqualStrings("/org/team", inner.workspace);
    // Repos spanning both: the outer workspace.
    const span = (try resolve(s, &state, "/org", &.{ "a", "team/y" }, &fail)).?;
    try testing.expectEqualStrings("/org", span.workspace);
    try testing.expectEqualStrings("team/y", span.repos[1]);
    // Every repo named: the whole workspace.
    try testing.expectEqual(@as(usize, 0), (try resolve(s, &state, "/org/team", &.{ "x", "y" }, &fail)).?.repos.len);

    try testing.expect((try resolve(s, &state, "/org", &.{"nope"}, &fail)) == null);
    try testing.expectEqualStrings("nope", fail.unknown_repo);
    try testing.expect((try resolve(s, &state, "/org", &.{"../a"}, &fail)) == null);
    try testing.expect(fail == .invalid_repo);
    try testing.expect((try resolve(s, &state, "/elsewhere", &.{"a"}, &fail)) == null);
    try testing.expect(fail == .no_workspace);
    _ = try decider.apply(&state, .{ .workspace_add = .{ .path = "/org2", .repos = &.{"a"} } }, s);
    try testing.expect((try resolve(s, &state, "/org2/docs", &.{}, &fail)) == null);
    try testing.expect(fail == .not_a_scope);
    // A folder in no workspace: in place, its own scope.
    const loose = (try resolve(s, &state, "/tmp/x", &.{}, &fail)).?;
    try testing.expectEqualStrings("/tmp/x", loose.workspace);
}

test "agent_scope: writes outside the scope; read-only repos" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try fixture(&state, s);
    const repos: []const []const u8 = &.{ "a", "b" };
    try testing.expect(!try outside(s, "/org", repos, "/org", "/org/a/src/x.zig"));
    try testing.expect(!try outside(s, "/org", repos, "/org", "b/x.zig"));
    try testing.expect(try outside(s, "/org", repos, "/org", "/org/c/x.zig"));
    try testing.expect(try outside(s, "/org", repos, "/org", "c/x.zig"));
    try testing.expect(try outside(s, "/org", repos, "/org", "a/../c/x.zig"));
    try testing.expect(try outside(s, "/org", repos, "/org", "/org/README.md"));
    try testing.expect(try outside(s, "/org", repos, "/org", "/org/a-x/y"));
    try testing.expect(!try outside(s, "/org", &.{}, "/org", "/anything"));
    try testing.expect(!try outside(s, "/org", repos, "/org", ""));

    const ro = try readOnly(s, &state, "/org", repos);
    try testing.expectEqual(@as(usize, 3), ro.len);
    try testing.expectEqualStrings("/org/c", ro[0]);
    try testing.expectEqualStrings("/org/team/y", ro[2]);
    try testing.expectEqual(@as(usize, 0), (try readOnly(s, &state, "/org", &.{})).len);
    const w = try writable(s, "/org", repos);
    try testing.expectEqualStrings("/org/b", w[1]);
    try testing.expectEqualStrings("/org", (try writable(s, "/org", &.{}))[0]);
}

test "agent_scope: common folder" {
    try testing.expectEqualStrings("/org", common("/org/a", "/org/b"));
    try testing.expectEqualStrings("/org/a", common("/org/a", "/org/a/x"));
    try testing.expectEqualStrings("/org/a", common("/org/a/x", "/org/a"));
    try testing.expectEqualStrings("/org", common("/org/ab", "/org/ac"));
    try testing.expectEqualStrings("/", common("/x", "/y"));
    try testing.expectEqualStrings("/org/a", common("/org/a", "/org/a"));
}
