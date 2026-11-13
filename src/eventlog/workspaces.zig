//! The pure half of workspaces: the decider and
//! evolve rules for the `workspace.*` records, and nesting (which workspace
//! owns a path). Discovery and the verbs are in `../workspaces.zig`.
const std = @import("std");
const ev = @import("events.zig");
const decider = @import("decider.zig");
const Event = ev.Event;
const Command = ev.Command;
const State = decider.State;

pub const Workspace = struct {
    path: []const u8,
    /// Git roots relative to `path`, sorted; "." when `path` is a repo.
    /// Empty for a folder without git: agents there run in place.
    repos: []const []const u8 = &.{},
};

/// Absolute, with no empty, `.` or `..` components and no trailing slash
/// (except the root itself), so one folder has exactly one spelling.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or path.len > std.fs.max_path_bytes) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (path.len == 1) return true;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Whether `path` is `root` or inside it (component-wise, both valid paths).
pub fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return std.mem.eql(u8, root, "/") or path[root.len] == '/';
}

/// Nesting: the workspace closest to `path`, i.e. the
/// deepest workspace that contains it, or null when none does. An agent
/// belongs to the owner of its scope root.
pub fn owner(state: *const State, path: []const u8) ?*const Workspace {
    var best: ?*const Workspace = null;
    for (state.workspaces.values()) |*w| {
        if (!within(w.path, path)) continue;
        if (best == null or w.path.len > best.?.path.len) best = w;
    }
    return best;
}

fn sameRepos(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// The names in `repos` that can be shown: one that is not UTF-8 cannot be a
/// JSON string, and a verb result holding it fails the result schema. Discovery
/// skips such folders, but logs and snapshots written before it did still hold
/// them, so the state never takes them in. `repos` itself when all
/// of them can be shown.
pub fn nameable(a: std.mem.Allocator, repos: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var kept: usize = 0;
    for (repos) |r| kept += @intFromBool(std.unicode.utf8ValidateSlice(r));
    if (kept == repos.len) return repos;
    const out = try a.alloc([]const u8, kept);
    var n: usize = 0;
    for (repos) |r| if (std.unicode.utf8ValidateSlice(r)) {
        out[n] = r;
        n += 1;
    };
    return out;
}

pub fn decide(state: *const State, cmd: Command, a: std.mem.Allocator, out: *std.ArrayList(Event)) (decider.Rejection || error{OutOfMemory})!void {
    switch (cmd) {
        .workspace_add => |w| {
            if (!validPath(w.path)) return error.InvalidCommand;
            if (state.workspaces.contains(w.path)) return;
            try out.append(a, .{ .workspace_added = .{ .path = w.path, .repos = try nameable(a, w.repos) } });
        },
        .workspace_scan => |w| {
            const current = state.workspaces.get(w.path) orelse return error.NotFound;
            const repos = try nameable(a, w.repos);
            if (sameRepos(current.repos, repos)) return;
            try out.append(a, .{ .workspace_scanned = .{ .path = w.path, .repos = repos } });
        },
        .workspace_remove => |w| {
            const current = state.workspaces.get(w.path) orelse return error.NotFound;
            try out.append(a, .{ .workspace_removed = .{ .path = w.path, .repos = current.repos } });
        },
        else => unreachable,
    }
}

pub fn evolve(state: *State, event: Event) error{OutOfMemory}!void {
    const a = state.arena.allocator();
    switch (event) {
        .workspace_added => {
            const copy = (try event.dupe(a)).workspace_added;
            try state.workspaces.put(a, copy.path, .{ .path = copy.path, .repos = try nameable(a, copy.repos) });
        },
        .workspace_scanned => |w| if (state.workspaces.getPtr(w.path)) |current| {
            current.repos = try nameable(a, (try event.dupe(a)).workspace_scanned.repos);
        },
        .workspace_removed => |w| _ = state.workspaces.orderedRemove(w.path),
        else => unreachable,
    }
}

const testing = std.testing;

test "workspaces: validPath accepts one spelling per folder" {
    try testing.expect(validPath("/"));
    try testing.expect(validPath("/home/me/venom-org"));
    try testing.expect(!validPath(""));
    try testing.expect(!validPath("relative"));
    try testing.expect(!validPath("/home/"));
    try testing.expect(!validPath("/home//me"));
    try testing.expect(!validPath("/home/./me"));
    try testing.expect(!validPath("/home/../me"));
    try testing.expect(!validPath("/home/\x00"));
}

test "workspaces: add is idempotent, scan replaces repos, remove keeps order" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    try testing.expectEqual(@as(usize, 1), try decider.apply(&state, .{ .workspace_add = .{ .path = "/b", .repos = &.{"r"} } }, s));
    try testing.expectEqual(@as(usize, 1), try decider.apply(&state, .{ .workspace_add = .{ .path = "/a" } }, s));
    try testing.expectEqual(@as(usize, 1), try decider.apply(&state, .{ .workspace_add = .{ .path = "/c" } }, s));
    try testing.expectEqual(@as(usize, 0), try decider.apply(&state, .{ .workspace_add = .{ .path = "/b" } }, s));
    try testing.expectError(error.InvalidCommand, decider.apply(&state, .{ .workspace_add = .{ .path = "x/../y" } }, s));
    // Records are facts from the log, never commands.
    try testing.expectError(error.InvalidCommand, decider.apply(&state, .{ .record = .{ .workspace_removed = .{ .path = "/a" } } }, s));

    try testing.expectEqual(@as(usize, 0), try decider.apply(&state, .{ .workspace_scan = .{ .path = "/b", .repos = &.{"r"} } }, s));
    try testing.expectEqual(@as(usize, 1), try decider.apply(&state, .{ .workspace_scan = .{ .path = "/b", .repos = &.{ "q", "r" } } }, s));
    try testing.expectEqual(@as(usize, 2), state.workspaces.get("/b").?.repos.len);
    try testing.expectError(error.NotFound, decider.apply(&state, .{ .workspace_scan = .{ .path = "/nope" } }, s));

    try testing.expectEqual(@as(usize, 1), try decider.apply(&state, .{ .workspace_remove = .{ .path = "/a" } }, s));
    try testing.expectError(error.NotFound, decider.apply(&state, .{ .workspace_remove = .{ .path = "/a" } }, s));
    try testing.expectEqualStrings("/b", state.workspaces.keys()[0]);
    try testing.expectEqualStrings("/c", state.workspaces.keys()[1]);
}

test "workspaces: an agent belongs to the closest workspace" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try decider.apply(&state, .{ .workspace_add = .{ .path = "/home/me/org/team" } }, s);
    _ = try decider.apply(&state, .{ .workspace_add = .{ .path = "/home/me/org" } }, s);
    try testing.expectEqualStrings("/home/me/org", owner(&state, "/home/me/org").?.path);
    try testing.expectEqualStrings("/home/me/org", owner(&state, "/home/me/org/venom").?.path);
    try testing.expectEqualStrings("/home/me/org/team", owner(&state, "/home/me/org/team/repo/src").?.path);
    // Component-wise: `/home/me/org-x` is not inside `/home/me/org`.
    try testing.expect(owner(&state, "/home/me/org-x") == null);
    try testing.expect(owner(&state, "/home/me") == null);
    _ = try decider.apply(&state, .{ .workspace_add = .{ .path = "/" } }, s);
    try testing.expectEqualStrings("/", owner(&state, "/etc").?.path);
}
