//! Caller grants for venom's verbs and a principal per agent.
//!
//! **Resources and containment.** venom's grant scopes name `workspace:<path>`
//! and `agent:<id>`, and `config:root` for `config get|set`. An agent is
//! contained in its parent agent if it has one, else in its workspace (its
//! folder when it is in none), so a grant on a workspace or an agent covers
//! the agents below it, now and later.
//!
//! **The grant table.** The dispatch gate checks each verb's schema right;
//! the handlers then check the resource:
//!
//! | Verb | Right | Resource |
//! |---|---|---|
//! | `workspace.list`, `agent.list`, `inbox.list` | `read` | each item (lists are filtered) |
//! | `agent.show` | `read` | `agent:<id>` |
//! | `harness.list|show` | `read` | none: installed CLIs, no vendor identity |
//! | `workspace.add|remove|scan` | `write` | `workspace:<path>` (each one, for a scan of all) |
//! | `agent.spawn` | `write` and `spawn` | `workspace:<ws>` |
//! | `agent.send|stop|archive|compact|mcp_off` | `write` | `agent:<id>` |
//! | `agent.fork` | `write` and `spawn` | `agent:<id>`; `workspace:<ws>` (the new agent is issued from the log, with the source's grants narrowed to itself; an agent asking is held to `agents.spawn.*`, with the source setting the depth) |
//! | `agent.context` | `read` | `agent:<id>` |
//! | `agent.wait` | `read` | `agent:<id>` |
//! | `agent.promote` | `write` | `agent:<id>`, never by an agent (`denied.promote`) |
//! | `inbox.answer` (`authorizeAnswer`), `inbox.snooze` | `write` | `agent:<id>`, never by the agent itself or a descendant (`denied.self_approval`); an agent may not allow or approve at all (`denied.agent_approval`) |
//! | `config set` | `admin` | (`grants` is user-only) |
//!
//! **A principal per agent.** `agent.spawn` issues the new agent a
//! principal (`kind = agent`) under the caller's, attenuated from the
//! caller's effective grants: the spawn `grants`
//! param when given, otherwise the least-privilege profile `read *`, `write
//! agent:<id>` (its own sub-agents and itself), plus always `spawn
//! agent:<id>`, which lets it start its own harness processes and nothing
//! else (spawning a new agent needs `spawn` on the workspace). A sub-agent
//! spawned by an agent is issued under that agent's principal, so it is one
//! of its descendants; without a `grants` param it inherits its parent's
//! grants, never more, with the parent's scope on itself
//! (`agent:<parent>`) narrowed to the child's own. `agent.promote` moves a
//! sub-agent's principal up to the tree's issuer, out of reach of its former
//! parent's revocation.
//!
//! The agent principal is unbound and does not expire; it lives until the
//! agent is archived, which revokes it and everything below it. Each
//! harness process gets its own child principal, bound to the process
//! with the agent's grants: its token goes into the
//! process's environment as `VENOM_TOKEN` (and the informational
//! `VENOM_PRINCIPAL`), never into argv or a log, and it is revoked when the
//! process exits. A harness is a child of the daemon, so without the
//! binding its calls would resolve to ORPHAN (read-only).
//!
//! A token an agent issues (`grant.issue`) or a process below its harness
//! still counts as that agent (`callerAgent`): every sub-agent limit traces
//! back to it. A sub-agent spawned with such a token is issued under the
//! token, so it holds no more than the token does, and dies with it.
//!
//! The registry lives in memory, the grants do not: `agent.created` logs each
//! agent's, and after a daemon restart it gets exactly those again on its next
//! harness start, under its parent agent's principal (or the owner's). A
//! sub-agent whose grants cannot be restored (its parent is archived or
//! revoked, or it was logged without them) does not start, and neither does
//! an agent whose principal was revoked, which `recordRevoked` logs:
//! `unavailable.agent_grants`. Only a top-level agent logged without grants
//! falls back to the default profile.
const std = @import("std");
const proto = @import("proto");
const log = @import("log");
const eventlog = @import("eventlog/root.zig");
const harness = @import("harness/root.zig");
const grants = proto.grants;

/// `grant.issue --namespace=person`: only the owner or an admin can give it.
pub const person_namespace = "person";

pub const Principals = struct {
    gpa: std.mem.Allocator,
    registry: *grants.Registry,
    engine: *eventlog.Engine,
    logger: ?*log.Logger = null,
    /// Agent ID (owned) → its principals.
    agents: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// The agent being issued, before `agent.created` is in the state.
    pending: ?Pending = null,

    pub const Entry = struct {
        /// The agent's own principal.
        principal: grants.Id,
        /// Its current harness process's principal, if one runs.
        process: ?grants.Id = null,
    };
    const Pending = struct { agent: []const u8, parent: grants.Resource };

    pub fn deinit(self: *Principals) void {
        for (self.agents.keys()) |k| self.gpa.free(k);
        self.agents.deinit(self.gpa);
    }

    /// Installs the containment relation in the registry. `self` must not
    /// move afterwards.
    pub fn install(self: *Principals) void {
        self.registry.containment = .init(self);
    }

    /// The credentials hook for the harness host. `self` must not move.
    pub fn credentials(self: *Principals) harness.host.Credentials {
        return .init(self);
    }

    // ---------------------------------------------------- containment

    pub fn parentOf(self: *Principals, r: grants.Resource) ?grants.Resource {
        if (!std.mem.eql(u8, r.kind, "agent")) return null;
        if (self.pending) |p| if (std.mem.eql(u8, p.agent, r.id)) return p.parent;
        const x = self.engine.state.agents.getPtr(r.id) orelse return null;
        return parentResource(x);
    }

    pub fn ownerOf(_: *Principals, _: grants.Resource) ?grants.Id {
        // venom's grants never use `self`: agents hold `agent:<id>` scopes.
        return null;
    }

    fn parentResource(x: *const eventlog.decider.Agent) grants.Resource {
        return if (x.parent) |p| .{ .kind = "agent", .id = p } else .{ .kind = "workspace", .id = x.workspace };
    }

    // ------------------------------------------------------- lookups

    /// The agent whose principal (or harness process principal) is exactly
    /// `id`: what a harness itself calls with.
    pub fn ownAgentOf(self: *const Principals, id: grants.Id) ?[]const u8 {
        for (self.agents.keys(), self.agents.values()) |k, e| {
            if (e.principal == id) return k;
            if (e.process) |p| if (p == id) return k;
        }
        return null;
    }

    /// Whether `identity` acts for some agent: its principal, or the floor
    /// it runs under, is an agent's, a harness process's, or issued below
    /// one. Humans and the owner are not.
    pub fn actsForAgent(self: *const Principals, identity: grants.Identity) bool {
        return self.callerAgent(identity) != null;
    }

    /// The nearest agent at or above `id`: a token an agent issued still is
    /// that agent, for every limit.
    pub fn agentOf(self: *const Principals, id: grants.Id) ?[]const u8 {
        var next: ?grants.Id = id;
        while (next) |n| {
            if (self.ownAgentOf(n)) |k| return k;
            next = (self.registry.get(n) orelse return null).parent;
        }
        return null;
    }

    /// The agent a caller acts for: by its principal, else by the harness
    /// process it runs under (a token from elsewhere does not get it out).
    pub fn callerAgent(self: *const Principals, identity: grants.Identity) ?[]const u8 {
        if (self.agentOf(identity.principal)) |k| return k;
        return switch (identity.floor) {
            .bound => |id| self.agentOf(id),
            else => null,
        };
    }

    /// The grants the agent's principal holds now.
    pub fn grantsOf(self: *const Principals, agent: []const u8) ?[]const grants.Grant {
        const e = self.agents.get(agent) orelse return null;
        return (self.registry.get(e.principal) orelse return null).grants;
    }

    /// Whether the agent has a principal and it was revoked or expired.
    pub fn dead(self: *const Principals, agent: []const u8) bool {
        const e = self.agents.get(agent) orelse return false;
        return !self.registry.live(e.principal, grants.nowSeconds());
    }

    /// The agent's own principal, if it has one now.
    pub fn principalOf(self: *const Principals, agent: []const u8) ?grants.Id {
        const e = self.agents.get(agent) orelse return null;
        return e.principal;
    }

    /// The identity new principals are issued under for `caller`: an
    /// agent's harness process issues under the agent's own principal (its
    /// parent, with the same grants), so what it creates outlives the
    /// process. Any other caller, a token an agent issued included, issues
    /// as itself, so it delegates no more than it holds.
    fn issuer(self: *const Principals, caller: grants.Identity) grants.Identity {
        const name = self.ownAgentOf(caller.principal) orelse return caller;
        return .{ .principal = self.agents.get(name).?.principal, .floor = .outside };
    }

    // ------------------------------------------------------- issuance

    /// Issues agent `agent`'s principal under `caller`, within
    /// the caller's own grants. `parent` is the agent's containment parent; `requested` the
    /// spawn's `grants` param. Call before `agent.created` is logged, so a
    /// denied delegation creates nothing; `forget` undoes it.
    pub fn issue(self: *Principals, caller: grants.Identity, agent: []const u8, parent: grants.Resource, requested: ?[]const grants.Grant) !grants.Id {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const own = try std.fmt.allocPrint(a, "agent:{s}", .{agent});
        const by = self.issuer(caller);
        const inherits = requested == null and std.mem.eql(u8, parent.kind, "agent");
        var list: std.ArrayList(grants.Grant) = .empty;
        if (requested) |r| {
            try list.appendSlice(a, r);
        } else if (inherits) {
            const self_scope = try std.fmt.allocPrint(a, "agent:{s}", .{parent.id});
            for (self.registry.get(by.principal).?.grants) |g| {
                const on_self = std.mem.eql(u8, g.scope, self_scope);
                if (on_self and g.right == .spawn) continue;
                try list.append(a, .{ .right = g.right, .scope = if (on_self) own else g.scope });
            }
        } else try list.appendSlice(a, &.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = own } });
        try list.append(a, .{ .right = .spawn, .scope = own });
        self.pending = .{ .agent = agent, .parent = parent };
        defer self.pending = null;
        const id = self.issueAs(by, agent, list.items) catch |err| blk: {
            if (err != error.Delegation or requested != null or inherits) return err;
            // A caller without `read *` gives what it can read: the parent.
            list.items[0].scope = try std.fmt.allocPrint(a, "{s}:{s}", .{ parent.kind, parent.id });
            break :blk try self.issueAs(by, agent, list.items);
        };
        errdefer self.revoke(id);
        // A principal the owner issued for the person,
        // such as a control pane's: what it starts is covered by it now and
        // belongs to the owner, so the agent outlives it. Any other token's
        // expiry bounds its agents.
        if (std.mem.eql(u8, self.registry.namespaceOf(caller.principal), person_namespace) and self.callerAgent(caller) == null) {
            const p = &self.registry.entries.items[@intCast(id)];
            p.parent = grants.owner;
            p.expires = null;
        }
        const key = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(key);
        try self.agents.put(self.gpa, key, .{ .principal = id });
        return id;
    }

    fn issueAs(self: *Principals, by: grants.Identity, agent: []const u8, gs: []const grants.Grant) !grants.Id {
        const now = grants.nowSeconds();
        const issued = try self.registry.issueChild(by, .{ .kind = .agent, .grants = gs, .label = agent }, now);
        // The agent principal's token is never handed out: only its
        // processes' tokens are. Unbound, it would expire after
        // grants.max_token_ttl; it lives until the agent is archived.
        burn(self.gpa, issued.token);
        const p = &self.registry.entries.items[@intCast(issued.principal)];
        p.expires = self.registry.get(by.principal).?.expires;
        return issued.principal;
    }

    /// Undoes `issue` when the agent could not be created.
    pub fn forget(self: *Principals, agent: []const u8) void {
        const kv = self.agents.fetchSwapRemove(agent) orelse return;
        self.gpa.free(kv.key);
        self.revoke(kv.value.principal);
    }

    /// The agent's principal, issued again after a daemon restart (the
    /// registry is in memory). Null: archived, or it cannot be issued.
    fn ensure(self: *Principals, agent: []const u8, depth: usize) !?grants.Id {
        const now = grants.nowSeconds();
        if (self.agents.get(agent)) |e| return if (self.registry.live(e.principal, now)) e.principal else null;
        const x = self.engine.state.agents.getPtr(agent) orelse return null;
        if (x.state == .archived or x.revoked or depth > 64) return null;
        const parent = parentResource(x);
        const by: grants.Identity = if (x.parent) |p| .{ .principal = (try self.ensure(p, depth + 1)) orelse return null, .floor = .outside } else .{ .principal = grants.owner };
        // Never guess a sub-agent's grants.
        if (x.grants == null and x.parent != null) {
            self.warn("the sub-agent's grants were not logged", .{ .agent = agent });
            return null;
        }
        if (x.grants) |gs| return self.restore(by, agent, parent, gs) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.warn("cannot restore the agent's grants", .{ .agent = agent, .@"error" = err });
            return null;
        };
        return self.issue(by, agent, parent, null) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.warn("cannot issue the agent's principal", .{ .agent = agent, .@"error" = err });
            return null;
        };
    }

    /// The agent's logged grants, exactly, after a restart.
    fn restore(self: *Principals, by: grants.Identity, agent: []const u8, parent: grants.Resource, gs: []const grants.Grant) !grants.Id {
        self.pending = .{ .agent = agent, .parent = parent };
        defer self.pending = null;
        const id = try self.issueAs(by, agent, gs);
        errdefer self.revoke(id);
        const key = try self.gpa.dupe(u8, agent);
        errdefer self.gpa.free(key);
        try self.agents.put(self.gpa, key, .{ .principal = id });
        return id;
    }

    // ------------------------------------------- harness credentials

    /// A token for a new harness process of `agent` (gpa-owned; the host
    /// zeroes and frees it). Null: the process runs without one. An agent
    /// whose grants cannot be restored does not start: `GrantsUnavailable`.
    pub fn token(self: *Principals, agent: []const u8) anyerror!?[]u8 {
        const x = self.engine.state.agents.getPtr(agent) orelse return null;
        if (x.state == .archived) return null;
        const id = (try self.ensure(agent, 0)) orelse return error.GrantsUnavailable;
        const e = self.agents.getPtr(agent).?;
        if (e.process) |old| self.revoke(old);
        e.process = null;
        const issued = self.registry.issueChild(.{ .principal = id, .floor = .outside }, .{ .kind = .agent, .label = agent }, grants.nowSeconds()) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.warn("cannot issue a harness token", .{ .agent = agent, .@"error" = err });
            return null;
        };
        e.process = issued.principal;
        return @constCast(issued.token);
    }

    /// Binds the process principal to the started process;
    /// a process already gone revokes it.
    pub fn bind(self: *Principals, agent: []const u8, pid: std.c.pid_t) void {
        const e = self.agents.getPtr(agent) orelse return;
        const id = e.process orelse return;
        const ref = (proto.process.stat(pid) catch return self.release(agent)).ref;
        const p = &self.registry.entries.items[@intCast(id)];
        p.root = ref;
        p.expires = self.registry.get(e.principal).?.expires;
    }

    /// The harness process is gone (or never started): revoke its token.
    pub fn release(self: *Principals, agent: []const u8) void {
        const e = self.agents.getPtr(agent) orelse return;
        const id = e.process orelse return;
        e.process = null;
        self.revoke(id);
    }

    /// The sub-agent was promoted (`agent.promote`): its principal moves up
    /// to the tree's issuer, the non-agent above its former parents, so
    /// archiving them no longer revokes it. Its grants stay as they are.
    pub fn promoted(self: *Principals, agent: []const u8) void {
        const e = self.agents.get(agent) orelse return;
        var up = self.registry.get(e.principal).?.parent;
        while (up) |u| {
            if (self.agentOf(u) == null) break;
            up = self.registry.get(u).?.parent;
        }
        self.registry.entries.items[@intCast(e.principal)].parent = up orelse grants.owner;
    }

    /// Logs agents whose principal was revoked since the last turn
    /// (`grant.revoke`, cascades, an expired issuer): the registry forgets on
    /// a restart, the log does not.
    pub fn recordRevoked(self: *Principals) !void {
        for (self.agents.keys(), self.agents.values()) |id, e| {
            const p = self.registry.get(e.principal) orelse continue;
            if (!p.revoked) continue;
            const x = self.engine.state.agents.getPtr(id) orelse continue;
            if (!x.revoked) _ = try self.engine.submit(.{ .revoked = .{ .agent = id } });
        }
    }

    /// The agent was archived: revoke its principal and every one below it
    /// (its processes and its sub-agents').
    pub fn archived(self: *Principals, agent: []const u8) void {
        const e = self.agents.getPtr(agent) orelse return;
        e.process = null;
        self.revoke(e.principal);
    }

    fn revoke(self: *Principals, id: grants.Id) void {
        const p = self.registry.get(id) orelse return;
        if (p.revoked) return;
        self.registry.revoke(.{ .principal = grants.owner }, id, grants.nowSeconds()) catch |err|
            self.warn("cannot revoke a principal", .{ .@"error" = err });
    }

    fn warn(self: *Principals, msg: []const u8, fields: anytype) void {
        if (self.logger) |l| l.warn(msg, fields);
    }

    // ------------------------------------------------- authorization

    /// `inbox.answer`: `write` on
    /// the agent, and never by the agent being answered or one of its
    /// descendants. false means the call has ended with `denied.*`.
    pub fn authorizeAnswer(self: *const Principals, c: *proto.Call, agent: []const u8) !bool {
        if (!try c.authorize(.write, .{ .kind = "agent", .id = agent })) return false;
        if (self.mayAnswer(c.conn.identity.principal, agent)) return true;
        var buf: [24]u8 = undefined;
        c.audit_resource = try std.fmt.allocPrint(c.arena(), "agent:{s}", .{agent});
        try c.fail("denied.self_approval", "an agent cannot answer itself or its descendants", .{ .right = "write", .resource = c.audit_resource.?, .principal = grants.name(c.conn.identity.principal, &buf) });
        return false;
    }

    /// The self-approval rule for `responder` and agent `raiser`. Checked
    /// both on the principal tree (`canRespond`) and on the agent tree, so
    /// it holds when the raiser has no principal yet.
    pub fn mayAnswer(self: *const Principals, responder: grants.Id, raiser: []const u8) bool {
        if (self.principalOf(raiser)) |r| if (!self.registry.canRespond(responder, r)) return false;
        var next: ?[]const u8 = self.agentOf(responder);
        var depth: usize = 0;
        while (next) |a| : (depth += 1) {
            if (std.mem.eql(u8, a, raiser) or depth > 64) return false;
            next = (self.engine.state.agents.getPtr(a) orelse return true).parent;
        }
        return true;
    }
};

/// Whether the caller may read `r` (for filtering lists; never fails the
/// call). Without a registry callers are read-only, which includes this.
pub fn readable(c: *const proto.Call, r: grants.Resource) bool {
    const reg = c.conn.registry orelse return true;
    return reg.allows(c.conn.identity, .read, r, grants.nowSeconds());
}

fn burn(gpa: std.mem.Allocator, secret: []const u8) void {
    std.crypto.secureZero(u8, @constCast(secret));
    gpa.free(secret);
}
