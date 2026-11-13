//! Settings scope: venom's config resolves per
//! workspace and repo from three files, the narrowest winning per key:
//!
//!   user       `$XDG_CONFIG_HOME/venom/config.zon` (the cfg user file)
//!   workspace  `<workspace>/.venom/workspace.zon`
//!   repo       `<repo>/.venom/repo.zon`
//!
//! They are venom-std cfg overlay layers above the user file. A
//! missing file is an empty layer.
//!
//! `config get` and `config set` take optional `--workspace` and `--repo`:
//! `get` reads the value in effect there and reports, per value, the layer
//! and file it comes from; `set` writes only the narrowest named file (the
//! repo file when `--repo` is given, else the workspace file). Without
//! either flag both verbs work on the user file exactly as before.
//!
//! - `--workspace` is the path of a workspace venom knows (`workspace add`).
//! - `--repo` is a repo path, absolute or relative to `--workspace` (`.`
//!   for a workspace that is itself a repo). It must be one of the repos
//!   discovery found; its workspace is the closest one holding it
//!   (nesting), or `--workspace` when given.
//!
//! Keys per layer (`scoped_keys`): workspace and repo files may set only
//! what an agent's work in that folder should change:
//!
//!   agents.default, agents.mode, agents.isolation, agents.spawn.*,
//!   agents.archive_after, attention.*
//!
//! Everything else is user-only: `grants` (a cloned repo must never widen
//! what callers may do), `log`, `ui.*` (one TUI per user) and
//! `agents.max_concurrent` (a daemon-wide limit). A workspace or repo file
//! that sets a user-only key is rejected with `invalid_params.config_scope`,
//! naming the key and file, and so is `config set` of one with a scope flag.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const config = @import("config.zig");
const eventlog = @import("eventlog/root.zig");
const rules = eventlog.workspaces;
const s = proto.schema;

pub const workspace_file = ".venom/workspace.zon";
pub const repo_file = ".venom/repo.zon";

/// Keys (and the subtrees under them) a workspace or repo file may set.
pub const scoped_keys = [_][]const u8{
    "agents.default",
    "agents.mode",
    "agents.isolation",
    "agents.spawn",
    "agents.archive_after",
    "attention",
};

/// Whether `key` (a dotted path) may be set in a workspace or repo file.
pub fn allowedInScope(key: []const u8) bool {
    for (scoped_keys) |k| {
        if (std.mem.eql(u8, key, k)) return true;
        if (std.mem.startsWith(u8, key, k) and key.len > k.len and key[k.len] == '.') return true;
    }
    return false;
}

// ------------------------------------------------------------ verb schema

const string: s.Type = .{ .kind = .string };
const scope_data: s.Type = .{ .kind = .object, .fields = &.{
    .{ .name = "param", .summary = "Parameter name", .type = string, .required = true },
    .{ .name = "key", .summary = "Dotted config key", .type = string },
    .{ .name = "source", .summary = "Layer: workspace or repo", .type = string },
    .{ .name = "path", .summary = "The workspace, repo or config file path", .type = string },
} };

/// Added to `config.get` and `config.set`.
pub const params = [_]s.Field{
    .{ .name = "workspace", .summary = "Workspace path: get reads the value in effect there; set writes its .venom/workspace.zon", .type = string },
    .{ .name = "repo", .summary = "Repo path, absolute or relative to --workspace: get reads the value in effect there; set writes its .venom/repo.zon", .type = string },
};

pub const errors = [_]s.ErrorDecl{
    .{ .code = "invalid_params.config_scope", .summary = "User-only key in a workspace or repo file: those may set agents.default, agents.mode, agents.isolation, agents.spawn.*, agents.archive_after and attention.*", .data = scope_data },
    .{ .code = "not_found.workspace", .summary = "--workspace is not a workspace venom knows", .data = scope_data },
    .{ .code = "not_found.repo", .summary = "--repo is not a repo found in a known workspace", .data = scope_data },
};

fn scoped(name: []const u8) bool {
    return std.mem.eql(u8, name, "config.get") or std.mem.eql(u8, name, "config.set");
}

/// The merged schema (`cfg.merge`) with `--workspace` and `--repo` on
/// `config get|set`, so the CLI, MCP tools and docs carry them.
pub fn extend(comptime model: s.Schema) s.Schema {
    comptime {
        var verbs = model.verbs[0..model.verbs.len].*;
        var found: usize = 0;
        for (&verbs) |*v| if (scoped(v.name)) {
            const p = v.params[0..v.params.len].* ++ params;
            const e = v.errors[0..v.errors.len].* ++ errors;
            v.params = &p;
            v.errors = &e;
            found += 1;
        };
        if (found != 2) @compileError("scope: config.get and config.set must be in the model");
        const final = verbs;
        return .{ .format = model.format, .tool = model.tool, .summary = model.summary, .verbs = &final };
    }
}

// ------------------------------------------------------------ resolution

/// Where config resolves: user only (both null), a workspace, or a repo in
/// its workspace. Paths are absolute.
pub const Scope = struct {
    workspace: ?[]const u8 = null,
    repo: ?[]const u8 = null,
};

/// Why `resolve` failed, as the verb error reports it.
pub const Problem = struct { code: []const u8, message: []const u8, param: []const u8, path: []const u8 };

/// Resolves the `--workspace` / `--repo` values against the known
/// workspaces. Strings live in `a`.
pub fn resolve(a: std.mem.Allocator, state: *const eventlog.State, workspace: ?[]const u8, repo: ?[]const u8, problem: *Problem) error{ InvalidScope, OutOfMemory }!Scope {
    var ws: ?*const rules.Workspace = null;
    if (workspace) |w| {
        ws = state.workspaces.getPtr(w) orelse {
            problem.* = .{ .code = "not_found.workspace", .message = "no such workspace; add it with workspace add", .param = "workspace", .path = w };
            return error.InvalidScope;
        };
    }
    const r = repo orelse return .{ .workspace = if (ws) |w| try a.dupe(u8, w.path) else null };
    const abs = if (r.len > 0 and r[0] == '/') r else if (ws) |w| blk: {
        if (std.mem.eql(u8, r, ".")) break :blk w.path;
        break :blk if (std.mem.eql(u8, w.path, "/")) try std.fmt.allocPrint(a, "/{s}", .{r}) else try std.fmt.allocPrint(a, "{s}/{s}", .{ w.path, r });
    } else {
        problem.* = .{ .code = "not_found.repo", .message = "a relative repo path needs --workspace", .param = "repo", .path = r };
        return error.InvalidScope;
    };
    const not_found: Problem = .{ .code = "not_found.repo", .message = "not a repo of a known workspace; check workspace list, or run workspace scan", .param = "repo", .path = abs };
    if (!rules.validPath(abs)) {
        problem.* = not_found;
        return error.InvalidScope;
    }
    const owner = ws orelse rules.owner(state, abs) orelse {
        problem.* = not_found;
        return error.InvalidScope;
    };
    if (!rules.within(owner.path, abs)) {
        problem.* = not_found;
        return error.InvalidScope;
    }
    const rel = if (abs.len == owner.path.len) "." else if (std.mem.eql(u8, owner.path, "/")) abs[1..] else abs[owner.path.len + 1 ..];
    for (owner.repos) |name| if (std.mem.eql(u8, name, rel)) {
        return .{ .workspace = try a.dupe(u8, owner.path), .repo = try a.dupe(u8, abs) };
    };
    problem.* = not_found;
    return error.InvalidScope;
}

fn filePath(a: std.mem.Allocator, dir: []const u8, file: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, dir, "/")) std.fmt.allocPrint(a, "/{s}", .{file}) else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, file });
}

/// The overlay files of `scope`, broadest first.
pub fn overlays(a: std.mem.Allocator, scope: Scope) ![]const cfg.Overlay {
    var list: std.ArrayList(cfg.Overlay) = .empty;
    if (scope.workspace) |w| try list.append(a, .{ .name = "workspace", .path = try filePath(a, w, workspace_file) });
    if (scope.repo) |r| try list.append(a, .{ .name = "repo", .path = try filePath(a, r, repo_file) });
    return list.items;
}

/// What every scoped store shares with the daemon's user-level store.
pub const Layers = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The user's config.zon.
    user: []const u8,
    defaults: []const []const u8 = &.{},
    events: ?*proto.events.Log = null,

    fn options(self: *const Layers, layers: []const cfg.Overlay) config.Store.Options {
        return .{
            .io = self.io,
            .path = self.user,
            .defaults = self.defaults,
            .overlays = layers,
            // `config set` writes the narrowest file.
            .write = if (layers.len == 0) .user else cfg.Source.overlay(layers.len - 1),
            .validate = config.validate,
            .events = self.events,
        };
    }

    /// A store over the user file and `scope`'s files: its `current()` is the
    /// config in effect there (e.g. for an agent spawned in that repo), and
    /// `set` writes the narrowest file. `scratch` holds the overlay paths
    /// only until init returns. Fails with error.InvalidConfig when a file
    /// is invalid (see `failing`) or sets a user-only key (`checkKeys`).
    pub fn open(self: *const Layers, scratch: std.mem.Allocator, scope: Scope) !config.Store {
        return config.Store.init(self.gpa, self.options(try overlays(scratch, scope)));
    }

    /// After `open` failed with error.InvalidConfig: the layer whose file
    /// does not load (the broadest one that breaks it).
    pub fn failing(self: *const Layers, scratch: std.mem.Allocator, scope: Scope) !cfg.Overlay {
        const all = try overlays(scratch, scope);
        for (0..all.len + 1) |n| {
            var store = config.Store.init(self.gpa, self.options(all[0..n])) catch |err| switch (err) {
                error.InvalidConfig => return if (n == 0) .{ .name = "user", .path = self.user } else all[n - 1],
                else => return err,
            };
            store.deinit();
        }
        return .{ .name = "user", .path = self.user };
    }
};

/// A value from a workspace or repo file under a user-only key.
pub const Misplaced = struct { key: []const u8, source: cfg.Source };

/// The first user-only key a workspace or repo file of `store` sets.
pub fn checkKeys(a: std.mem.Allocator, store: *config.Store) !?Misplaced {
    const found = try store.lookup(a, "");
    for (found.sources) |e| {
        if (e.source.overlayIndex() == null) continue;
        if (!allowedInScope(e.key)) return .{ .key = e.key, .source = e.source };
    }
    return null;
}

// ------------------------------------------------------------ verbs

/// `config.get` and `config.set` with `--workspace` / `--repo`; without
/// them (and for the other config verbs) the daemon's user-level store
/// answers as before. `engine` must be open before the first call.
pub const Config = struct {
    store: *config.Store,
    engine: *eventlog.Engine,
    layers: Layers,

    /// The store's five bindings, with get and set routed here.
    pub fn bindings(self: *Config) [5]proto.Binding {
        var out = self.store.bindings();
        for (&out) |*b| if (scoped(b.verb)) {
            b.handler = proto.VerbHandler.init(self);
        };
        return out;
    }

    fn param(c: *proto.Call, name: []const u8) ?[]const u8 {
        if (c.params != .object) return null;
        const v = c.params.object.get(name) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn call(self: *Config, c: *proto.Call) anyerror!void {
        const workspace = param(c, "workspace");
        const repo = param(c, "repo");
        if (workspace == null and repo == null) return self.store.call(c);
        const set = std.mem.eql(u8, c.verb.name, "config.set");
        if (!try c.authorize(if (set) .admin else .read, .{ .kind = "config", .id = "root" })) return;
        const a = c.arena();
        var problem: Problem = undefined;
        const scope = resolve(a, &self.engine.state, workspace, repo, &problem) catch |err| switch (err) {
            error.InvalidScope => return c.fail(problem.code, problem.message, .{ .param = problem.param, .path = problem.path }),
            else => return err,
        };
        var store = self.layers.open(a, scope) catch |err| switch (err) {
            error.InvalidConfig => {
                const bad = try self.layers.failing(a, scope);
                return c.fail("invalid_params.config_value", "a config file in this scope is invalid", .{ .param = "", .key = "", .source = bad.name, .path = bad.path });
            },
            else => return err,
        };
        defer store.deinit();
        self.run(c, &store, set) catch |err| switch (err) {
            error.InvalidConfig => {
                const param_name = if (set) (if (std.mem.eql(u8, store.failure.code, "invalid_params.config_key")) "key" else "value") else "key";
                if (store.failure.source) |source| return c.fail(store.failure.code, "configuration operation failed", .{ .param = param_name, .key = store.failure.key(), .source = store.sourceName(source), .path = store.sourcePath(source) });
                return c.fail(store.failure.code, "configuration operation failed", .{ .param = param_name, .key = store.failure.key() });
            },
            else => return err,
        };
    }

    fn run(_: *Config, c: *proto.Call, store: *config.Store, set: bool) !void {
        const a = c.arena();
        if (try checkKeys(a, store)) |m| return c.fail("invalid_params.config_scope", "a workspace or repo file sets a user-only key", .{ .param = "", .key = m.key, .source = store.sourceName(m.source), .path = store.sourcePath(m.source) });
        const key = c.params.object.get("key").?.string;
        if (set) {
            // An unknown key fails as config_key before the scope check.
            _ = try store.lookup(a, key);
            const target = store.options.write;
            if (!allowedInScope(key)) return c.fail("invalid_params.config_scope", "this key is user-only; set it without --workspace or --repo", .{ .param = "key", .key = key, .source = store.sourceName(target), .path = store.sourcePath(target) });
            return c.ok(try store.set(key, c.params.object.get("value").?.string));
        }
        const found = try store.lookup(a, key);
        const Item = struct { key: []const u8, source: []const u8, path: ?[]const u8 };
        const items = try a.alloc(Item, found.sources.len);
        for (found.sources, items) |e, *item| item.* = .{ .key = e.key, .source = store.sourceName(e.source), .path = store.sourcePath(e.source) };
        return c.ok(.{ .content = found.content, .source = store.sourceName(found.source), .path = store.sourcePath(found.source), .sources = items });
    }
};
