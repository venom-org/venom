//! `tui.hold`: the streams venom's TUIs keep open on the daemon, and the
//! daemon's lifetime they drive. The daemon counts TUI clients, not
//! connections: only the owner and `person` principals may hold, so no
//! agent, hook, MCP adapter or script keeps an on-demand daemon alive.
//!
//! Each hold gets an item at once and another on every change of `phase`,
//! `clients` or `others`. A hold ends when its stream is cancelled, its
//! connection closes, or its principal is revoked or expires
//! (`denied.revoked`); while the daemon stops, every hold ends with
//! `unavailable.shutdown`.
const std = @import("std");
const proto = @import("proto");
const supervisor = @import("supervisor");
const lifecycle = @import("lifecycle.zig");
const g = proto.grants;

pub const Holds = struct {
    gpa: std.mem.Allocator,
    registry: *g.Registry,
    state: lifecycle.State = .{},
    /// Learned from the first hold: the owner of its tickets.
    dispatcher: ?*proto.Dispatcher = null,
    /// Run once, in the reactor turn that commits `stopping`: from then on
    /// nothing starts (no queued agent, no harness process).
    on_stopping: ?Hook = null,
    list: std.ArrayList(Hold) = .empty,
    /// The test clock; null reads the monotonic clock.
    clock: ?*const fn () i64 = null,
    stop_ran: bool = false,

    pub const Hook = struct { ctx: *anyopaque, run: *const fn (*anyopaque) void };
    const Hold = struct {
        ticket: proto.Ticket,
        identity: g.Identity,
        /// A `process` principal: the holds bound below it end with it.
        process: bool,
        sent: ?Sent = null,
    };
    const Sent = struct { phase: lifecycle.Phase, clients: usize, others: usize };

    pub fn deinit(self: *Holds) void {
        self.list.deinit(self.gpa);
    }

    fn now(self: *const Holds) i64 {
        return if (self.clock) |f| f() else supervisor.monotonicMs();
    }

    pub fn count(self: *const Holds) usize {
        return self.list.items.len;
    }

    /// Readiness: the reactor is about to dispatch its first request.
    pub fn ready(self: *Holds) void {
        self.state.ready(self.now());
    }

    /// The handler: the dispatch gate has already checked `read`.
    pub fn call(self: *Holds, c: *proto.Call) anyerror!void {
        self.dispatcher = c.dispatcher;
        if (self.state.stopping()) return c.fail("unavailable.shutdown", "the daemon is stopping", null);
        const principal = c.conn.identity.principal;
        const p = self.registry.get(principal);
        const person = principal != g.owner and p != null and std.mem.eql(u8, self.registry.namespaceOf(principal), "person");
        if (principal != g.owner and !person) return c.fail("denied.tui_hold", "only the owner and person principals may hold the daemon; agents never need to", null);
        try self.list.append(self.gpa, .{ .ticket = c.ticket, .identity = c.conn.identity, .process = p != null and p.?.kind == .process });
        self.state.held();
        try self.publish();
    }

    /// Whether hold `other` ends with hold `of`'s caller.
    fn endsWith(self: *const Holds, other: Hold, of: Hold) bool {
        if (other.ticket == of.ticket) return true;
        return of.process and self.registry.descendant(other.identity.principal, of.identity.principal);
    }

    fn othersOf(self: *const Holds, h: Hold) usize {
        var n: usize = 0;
        for (self.list.items) |o| n += @intFromBool(!self.endsWith(o, h));
        return n;
    }

    /// Sends an item to every hold whose view changed.
    fn publish(self: *Holds) !void {
        const d = self.dispatcher orelse return;
        var i: usize = 0;
        while (i < self.list.items.len) {
            const h = &self.list.items[i];
            const now_view: Sent = .{ .phase = self.state.phase, .clients = self.list.items.len, .others = self.othersOf(h.*) };
            if (h.sent) |s| if (std.meta.eql(s, now_view)) {
                i += 1;
                continue;
            };
            const c = d.get(h.ticket) orelse {
                _ = self.list.orderedRemove(i);
                continue;
            };
            c.item(.{ .lifetime = self.state.lifetime.name(), .origin = @tagName(self.state.origin), .phase = self.state.phaseName(), .clients = now_view.clients, .others = now_view.others }) catch |err| {
                if (err == error.OutOfMemory) return err;
                _ = self.list.orderedRemove(i);
                continue;
            };
            h.sent = now_view;
            i += 1;
        }
    }

    /// One reactor turn, before the dispatcher's own stream check: drops the
    /// holds that ended, ends revoked or expired ones with `denied.revoked`,
    /// then lets the lifetime move on.
    pub fn tick(self: *Holds) !void {
        const t = self.now();
        const seconds = g.nowSeconds();
        if (self.dispatcher) |d| {
            var i: usize = 0;
            var ended = false;
            while (i < self.list.items.len) {
                const h = self.list.items[i];
                const c = d.get(h.ticket) orelse {
                    _ = self.list.orderedRemove(i);
                    ended = true;
                    continue;
                };
                if (!self.registry.connectionLive(h.identity, seconds)) {
                    _ = self.list.orderedRemove(i);
                    ended = true;
                    c.fail("denied.revoked", "the holder's principal was revoked or expired", null) catch |err| if (err == error.OutOfMemory) return err;
                    continue;
                }
                i += 1;
            }
            if (ended) self.state.released(self.list.items.len, t);
        }
        self.state.tick(t);
        if (self.state.stopping()) return self.stopNow();
        try self.publish();
    }

    /// A signal, or the end of the lifetime: commit `stopping` and end every
    /// hold with `unavailable.shutdown`. Idempotent.
    pub fn stop(self: *Holds) !void {
        self.state.stop();
        return self.stopNow();
    }

    fn stopNow(self: *Holds) !void {
        if (!self.stop_ran) {
            self.stop_ran = true;
            if (self.on_stopping) |hook| hook.run(hook.ctx);
        }
        const d = self.dispatcher orelse {
            self.list.clearRetainingCapacity();
            return;
        };
        while (self.list.pop()) |h| {
            const c = d.get(h.ticket) orelse continue;
            c.fail("unavailable.shutdown", "the daemon is stopping", null) catch |err| if (err == error.OutOfMemory) return err;
        }
    }
};

/// The server's handler: the dispatcher, with the holds' turn run first, so
/// that a revoked holder's stream ends with `denied.revoked` rather than the
/// dispatcher's generic denial.
pub const Front = struct {
    dispatcher: *proto.Dispatcher,
    holds: *Holds,
    pub fn handler(self: *Front) proto.Handler {
        return proto.Handler.init(self);
    }
    pub fn message(self: *Front, conn: *proto.Connection, msg: proto.Message) anyerror!void {
        return self.dispatcher.message(conn, msg);
    }
    pub fn allowFrame(self: *Front, conn: *const proto.Connection, kind: u16) bool {
        return self.dispatcher.allowFrame(conn, kind);
    }
    pub fn closed(self: *Front, conn: *proto.Connection) void {
        self.dispatcher.closed(conn);
    }
    pub fn tick(self: *Front) anyerror!void {
        try self.holds.tick();
        try self.dispatcher.tick();
    }
};

/// A verb handler that refuses mutations while the daemon stops: after the
/// dispatch gate's authorization, with `unavailable.shutdown` and no effect.
/// Reads still answer.
pub const Gated = struct {
    inner: proto.VerbHandler,
    holds: *const Holds,
    pub fn call(self: *Gated, c: *proto.Call) anyerror!void {
        if (self.holds.state.stopping() and c.verb.grant != .read and c.verb.grant != .none)
            return c.fail("unavailable.shutdown", "the daemon is stopping", null);
        return self.inner.vtable.call(self.inner.ptr, c);
    }
};

/// Wraps every binding in `bindings` with `Gated`, into `out`.
pub fn gate(comptime n: usize, bindings: [n]proto.Binding, holds: *const Holds, gated: *[n]Gated) [n]proto.Binding {
    var out: [n]proto.Binding = undefined;
    for (bindings, 0..) |b, i| {
        gated[i] = .{ .inner = b.handler, .holds = holds };
        out[i] = .{ .verb = b.verb, .handler = proto.VerbHandler.init(&gated[i]) };
    }
    return out;
}
