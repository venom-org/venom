//! Escalation outside the terminal: a
//! venomx `notify.post` for a blocking inbox item left unanswered for
//! `attention.notify_after`, one per item, gone once the item is.
//!
//! Why the daemon and not the control pane. `notify.post` and a dismissal for
//! every client need `write` on `server:root`, which
//! covers every session, and no pane may hold that: the control pane has only
//! `write` on itself and its own panes (host.zig). A token handed to a pane
//! would not help either, since it is capped by the pane's rights. So the process that posts is the one outside venomx that
//! already watches the inbox, `venom serve`:
//!
//! - It reads venomx's owner file only to `grant.issue` a short token in the
//!   namespace `venom`, on a connection it closes at once. The token stays in
//!   memory for one connection, is never written down, and never reaches a
//!   harness or a pane (`harness/process.zig` strips `VENOM*_TOKEN`).
//! - `venom serve` started inside a pane has no way in. venomx refuses the owner
//!   token there (`owner_context`), and with a `VENOMX_TOKEN` from the pane the
//!   connection is the pane's, whose `grant.issue` is refused (`denied.namespace`).
//!   That is logged once, and items 1-4 and the BEL still work. Nothing widens
//!   to get around it.
//! - Only a connect, ever: venom never starts venomx.
//!   With `ui.chrome = own`, venom stays out of venomx altogether.
//!
//! `reconcile` is pure and takes the clock's value, so tests drive it directly;
//! `pump` is the only part that touches a socket.
const std = @import("std");
const proto = @import("proto");
const log = @import("log");
const supervisor = @import("supervisor");
const eventlog = @import("eventlog/root.zig");
const attention = eventlog.attention;
const ownerEnviron = @import("tui/host.zig").ownerEnviron;
const Value = std.json.Value;

/// A notification's text is at most this long.
const max_text = 512;
/// How long a client shows it, unless the answer dismisses it first. Long
/// enough to still be there when the human comes back.
const ttl_ms = 60 * 60 * 1000;
const token_ttl_s = 60 * 60;
const retry_every_ms = 30 * 1000;
const phase_timeout_ms = 5 * 1000;
const hello: proto.HelloOptions = .{ .identity = .{ .name = "venom", .version = "0.0.0" }, .caps = &.{} };
const Grant = struct { right: []const u8, scope: []const u8 };

/// `text` as venomx takes it (`validText`): valid UTF-8 with no control
/// characters, at most `max` bytes, cut on a character. Harnesses write these
/// reasons, and a multi-line command is an ordinary one. Owned by `a`.
pub fn cleanText(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const end = i + n;
        const cp: ?u21 = if (n > 0 and end <= text.len) std.unicode.utf8Decode(text[i..end]) catch null else null;
        const bytes: []const u8 = if (cp) |v|
            (if (v < 0x20 or (v >= 0x7f and v <= 0x9f)) " " else text[i..end])
        else
            "\u{FFFD}";
        if (out.items.len + bytes.len > max) break;
        try out.appendSlice(a, bytes);
        i = if (cp != null) end else i + 1;
    }
    return out.items;
}

/// A blocking item in the inbox right now.
pub const Open = struct {
    /// Agent, item and when it appeared: a new failure is a new item.
    key: []const u8,
    level: []const u8,
    text: []const u8,
    /// Unanswered for at least `attention.notify_after`.
    due: bool,
};

/// The blocking items of `state` at `now`. Snoozed ones are not in the inbox,
/// so a snooze also takes back the notification.
pub fn openItems(a: std.mem.Allocator, state: *const eventlog.decider.State, now: i64, after_ms: u64) ![]const Open {
    var out: std.ArrayList(Open) = .empty;
    for (try attention.inbox(a, state, now, false)) |it| {
        if (!it.kind.blocking()) continue;
        const title = if (state.agents.get(it.agent)) |ag| ag.title else "";
        try out.append(a, .{
            .key = try std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ it.agent, it.item, it.since }),
            .level = it.kind.level(),
            .text = try cleanText(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ if (title.len > 0) title else it.agent, it.reason }), max_text),
            .due = now - it.since >= std.math.cast(i64, after_ms) orelse std.math.maxInt(i64),
        });
    }
    return out.items;
}

const Tracked = struct {
    key: []u8,
    level: []u8,
    text: []u8,
    state: union(enum) {
        wanted,
        /// `notify.post`, this request id.
        posting: i64,
        /// Its id; empty when venomx refused the text, which is not retried.
        posted: []u8,
    } = .wanted,
    /// The item went while the post was on its way.
    gone: bool = false,
};

const Dismissal = struct { id: []u8, request: ?i64 = null };

pub const Escalation = struct {
    gpa: std.mem.Allocator,
    logger: ?*log.Logger = null,
    /// How to reach venomx, with and without the owner file.
    environ: std.process.Environ,
    owner_environ: std.process.Environ,
    arena: std.heap.ArenaAllocator,
    tracked: std.ArrayList(Tracked) = .empty,
    dismissals: std.ArrayList(Dismissal) = .empty,
    next_id: i64 = 1,
    phase: Phase = .down,
    client: ?proto.Client = null,
    phase_at: i64 = 0,
    retry_at: i64 = 0,
    /// A failure of the link was logged; quiet until the link works again, as
    /// it is retried for as long as an item waits.
    link_warned: bool = false,

    const Phase = enum { down, owner_hello, issuing, poster_hello, ready };
    const issue_id = 1;

    /// `environ` outlives this.
    pub fn init(self: *Escalation, gpa: std.mem.Allocator, environ: std.process.Environ, logger: ?*log.Logger) !void {
        self.* = .{ .gpa = gpa, .logger = logger, .environ = environ, .owner_environ = environ, .arena = .init(gpa) };
        self.owner_environ = try ownerEnviron(self.arena.allocator(), environ, "VENOMX_TOKEN");
    }

    pub fn deinit(self: *Escalation) void {
        self.disconnect();
        for (self.tracked.items) |t| self.freeTracked(t);
        self.tracked.deinit(self.gpa);
        for (self.dismissals.items) |d| self.gpa.free(d.id);
        self.dismissals.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    fn freeTracked(self: *Escalation, t: Tracked) void {
        self.gpa.free(t.key);
        self.gpa.free(t.level);
        self.gpa.free(t.text);
        if (t.state == .posted) self.gpa.free(t.state.posted);
    }

    fn find(open: []const Open, key: []const u8) bool {
        for (open) |o| if (std.mem.eql(u8, o.key, key)) return true;
        return false;
    }

    /// Brings what is wanted of venomx in line with the inbox. `enabled` is
    /// false with `ui.chrome = own`: nothing new is posted.
    pub fn reconcile(self: *Escalation, open: []const Open, enabled: bool) !void {
        var i: usize = 0;
        while (i < self.tracked.items.len) {
            const t = &self.tracked.items[i];
            if (find(open, t.key)) {
                i += 1;
                continue;
            }
            switch (t.state) {
                .posting => {
                    t.gone = true;
                    i += 1;
                },
                .wanted => self.freeTracked(self.tracked.orderedRemove(i)),
                .posted => |id| {
                    if (id.len > 0) try self.dismissals.append(self.gpa, .{ .id = try self.gpa.dupe(u8, id) });
                    self.freeTracked(self.tracked.orderedRemove(i));
                },
            }
        }
        if (!enabled) {
            // Not yet sent: stay out of venomx. Posted ones still go above.
            i = 0;
            while (i < self.tracked.items.len) {
                if (self.tracked.items[i].state == .wanted) self.freeTracked(self.tracked.orderedRemove(i)) else i += 1;
            }
            return;
        }
        next: for (open) |o| {
            if (!o.due) continue;
            for (self.tracked.items) |t| if (std.mem.eql(u8, t.key, o.key)) continue :next;
            const key = try self.gpa.dupe(u8, o.key);
            errdefer self.gpa.free(key);
            const level = try self.gpa.dupe(u8, o.level);
            errdefer self.gpa.free(level);
            const text = try self.gpa.dupe(u8, o.text);
            errdefer self.gpa.free(text);
            try self.tracked.append(self.gpa, .{ .key = key, .level = level, .text = text });
        }
    }

    /// Something needs venomx: a post or a dismissal, sent or to send.
    pub fn wantsLink(self: *const Escalation) bool {
        if (self.dismissals.items.len > 0) return true;
        for (self.tracked.items) |t| if (t.state != .posted) return true;
        return false;
    }

    /// The next requests as encoded lines, marked as sent. Owned by `a`.
    pub fn nextRequests(self: *Escalation, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.tracked.items) |*t| if (t.state == .wanted) {
            const id = self.next_id;
            self.next_id += 1;
            try out.append(a, try std.json.Stringify.valueAlloc(a, .{ .id = id, .verb = "notify.post", .params = .{ .text = t.text, .level = t.level, .ttl_ms = @as(u32, ttl_ms) } }, .{}));
            t.state = .{ .posting = id };
        };
        for (self.dismissals.items) |*d| if (d.request == null) {
            const id = self.next_id;
            self.next_id += 1;
            try out.append(a, try std.json.Stringify.valueAlloc(a, .{ .id = id, .verb = "notify.dismiss", .params = .{ .id = d.id, .all = true } }, .{}));
            d.request = id;
        };
        return out.items;
    }

    /// The connection went: what was on its way is sent again on the next.
    fn requeue(self: *Escalation) void {
        for (self.tracked.items) |*t| if (t.state == .posting) {
            t.state = .wanted;
        };
        for (self.dismissals.items) |*d| d.request = null;
    }

    fn warn(self: *Escalation, msg: []const u8, code: []const u8) void {
        if (self.logger) |l| l.warn(msg, .{ .code = code });
    }

    /// The final answer to a request of `nextRequests`. True when venomx
    /// refused this principal, so the link has to start over.
    pub fn onResponse(self: *Escalation, id: i64, body: proto.Response.Body) !bool {
        const denied = body == .@"error" and std.mem.startsWith(u8, body.@"error".code, "denied");
        for (self.tracked.items, 0..) |*t, i| {
            if (t.state != .posting or t.state.posting != id) continue;
            if (denied) {
                t.state = .wanted;
                return true;
            }
            var posted: []const u8 = "";
            if (body == .ok and body.ok == .object) if (body.ok.object.get("id")) |v| {
                if (v == .string) posted = v.string;
            };
            if (body == .@"error") self.warn("venomx refused a notification", body.@"error".code);
            if (t.gone) {
                if (posted.len > 0) try self.dismissals.append(self.gpa, .{ .id = try self.gpa.dupe(u8, posted) });
                self.freeTracked(self.tracked.orderedRemove(i));
                return false;
            }
            t.state = .{ .posted = try self.gpa.dupe(u8, posted) };
            return false;
        }
        for (self.dismissals.items, 0..) |*d, i| {
            if (d.request == null or d.request.? != id) continue;
            if (denied) {
                d.request = null;
                return true;
            }
            // `not_found`: it expired, or venomx restarted. Either way it is gone.
            if (body == .@"error" and !std.mem.startsWith(u8, body.@"error".code, "not_found")) self.warn("venomx refused a dismissal", body.@"error".code);
            self.gpa.free(self.dismissals.orderedRemove(i).id);
            return false;
        }
        return false;
    }

    // ---- The socket ------------------------------------------------------

    fn disconnect(self: *Escalation) void {
        if (self.client) |*c| c.deinit();
        self.client = null;
        self.phase = .down;
    }

    fn fail(self: *Escalation, now: i64) void {
        self.disconnect();
        self.requeue();
        self.retry_at = now + retry_every_ms;
    }

    /// One turn, never blocking. A venomx that is not there or goes away only
    /// delays what is wanted: the items stay open and it is tried again.
    pub fn pump(self: *Escalation) error{OutOfMemory}!void {
        const now = supervisor.monotonicMs();
        if (self.phase == .down and !self.wantsLink()) return;
        self.turn(now) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Nothing to connect to is the ordinary case: venomx is optional.
            error.NotRunning => self.fail(now),
            else => {
                _ = self.warnLink("the link to venomx failed; trying again", @errorName(err));
                self.fail(now);
            },
        };
    }

    fn turn(self: *Escalation, now: i64) !void {
        if (self.phase != .down and self.phase != .ready and now - self.phase_at > phase_timeout_ms) return error.Timeout;
        switch (self.phase) {
            .down => {
                if (now < self.retry_at) return;
                self.client = try proto.Client.init(self.gpa, .{ .tool = "venomx", .path = .{ .environ = self.owner_environ }, .hello = hello });
                self.enter(.owner_hello, now);
                try self.turn(now);
            },
            .owner_hello => {
                const done = self.client.?.pollHello(0) catch |err| {
                    if (self.client.?.token_failure != null) _ = self.warnLink("venomx refused venom's credential, so no notifications; run venom serve outside venomx", @errorName(err));
                    return err;
                };
                if (!done) return;
                try self.client.?.request(@as(i64, issue_id), "grant.issue", .{
                    .grants = &[_]Grant{.{ .right = "write", .scope = "server:root" }},
                    .namespace = "venom",
                    .ttl = @as(u32, token_ttl_s),
                    .label = "venom notifications",
                });
                self.enter(.issuing, now);
            },
            .issuing => {
                const msg = try self.client.?.receive(0) orelse return;
                if (msg != .ndjson) return error.InvalidResponse;
                var r = try proto.Response.parse(self.gpa, msg.ndjson);
                defer r.deinit();
                const id = r.id orelse return;
                if (id != .integer or id.integer != issue_id or !r.final()) return;
                if (r.body != .ok or r.body.ok != .object) {
                    if (r.body == .@"error") _ = self.warnLink("venomx refused venom's notification token, so no notifications; run venom serve outside venomx", r.body.@"error".code);
                    return error.Refused;
                }
                const token = r.body.ok.object.get("token") orelse return error.InvalidResponse;
                if (token != .string) return error.InvalidResponse;
                // Only this connection ever uses the token; `init` sends it.
                var poster = try proto.Client.init(self.gpa, .{ .tool = "venomx", .path = .{ .environ = self.environ }, .hello = hello, .token = token.string });
                errdefer poster.deinit();
                poster.options.token = null;
                std.crypto.secureZero(u8, @constCast(token.string));
                self.client.?.deinit();
                self.client = poster;
                self.enter(.poster_hello, now);
            },
            .poster_hello => {
                if (!try self.client.?.pollHello(0)) return;
                self.enter(.ready, now);
                self.link_warned = false;
                try self.exchange();
            },
            .ready => try self.exchange(),
        }
    }

    fn enter(self: *Escalation, phase: Phase, now: i64) void {
        self.phase = phase;
        self.phase_at = now;
    }

    /// True when this one was logged: once per outage, however often it is tried.
    fn warnLink(self: *Escalation, msg: []const u8, code: []const u8) bool {
        if (self.link_warned) return false;
        self.link_warned = true;
        self.warn(msg, code);
        return true;
    }

    fn exchange(self: *Escalation) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const c = &self.client.?;
        for (try self.nextRequests(arena.allocator())) |line| try c.connection.sendMessage(.{ .ndjson = line });
        try c.connection.flush();
        while (try c.receive(0)) |msg| {
            if (msg != .ndjson) return error.InvalidResponse;
            var r = try proto.Response.parse(self.gpa, msg.ndjson);
            defer r.deinit();
            const id = r.id orelse continue;
            if (id == .integer and r.final() and try self.onResponse(id.integer, r.body)) return error.Refused;
        }
        // Nothing on its way: no reason to hold a daemon-wide token open.
        if (!self.wantsLink()) self.disconnect();
    }
};

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    e: Escalation,

    fn init(self: *Fixture) !void {
        self.arena = .init(testing.allocator);
        try self.e.init(testing.allocator, .{ .block = .{ .slice = &.{} } }, null);
    }

    fn deinit(self: *Fixture) void {
        self.e.deinit();
        self.arena.deinit();
    }

    fn take(self: *Fixture) ![]Value {
        const a = self.arena.allocator();
        var out: std.ArrayList(Value) = .empty;
        for (try self.e.nextRequests(a)) |line| try out.append(a, try std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }));
        return out.items;
    }

    fn ok(self: *Fixture, request: Value, json: []const u8) !void {
        const v = try std.json.parseFromSliceLeaky(Value, self.arena.allocator(), json, .{ .allocate = .alloc_always });
        try testing.expect(!try self.e.onResponse(request.object.get("id").?.integer, .{ .ok = v }));
    }
};

const a1: Open = .{ .key = "a1/p1/1000", .level = "urgent", .text = "task: approve", .due = true };
const not_yet: Open = .{ .key = "a1/p1/1000", .level = "urgent", .text = "task: approve", .due = false };

test "one notification, once the item is due, and it goes with the item" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.e.reconcile(&.{not_yet}, true);
    try testing.expect(!f.e.wantsLink());
    try f.e.reconcile(&.{a1}, true);
    try testing.expect(f.e.wantsLink());
    const post = try f.take();
    try testing.expectEqual(@as(usize, 1), post.len);
    try testing.expectEqualStrings("notify.post", post[0].object.get("verb").?.string);
    const params = post[0].object.get("params").?.object;
    try testing.expectEqualStrings("task: approve", params.get("text").?.string);
    try testing.expectEqualStrings("urgent", params.get("level").?.string);
    try f.e.reconcile(&.{a1}, true);
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
    try f.ok(post[0], "{\"id\":\"n7\"}");
    try testing.expect(!f.e.wantsLink());
    try f.e.reconcile(&.{a1}, true);
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
    try f.e.reconcile(&.{}, true);
    const dismiss = try f.take();
    try testing.expectEqualStrings("notify.dismiss", dismiss[0].object.get("verb").?.string);
    try testing.expectEqualStrings("n7", dismiss[0].object.get("params").?.object.get("id").?.string);
    try testing.expect(dismiss[0].object.get("params").?.object.get("all").?.bool);
    try f.ok(dismiss[0], "{\"id\":\"n7\",\"all\":true}");
    try testing.expect(!f.e.wantsLink());
}

test "an item answered before its post went out is never posted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.e.reconcile(&.{a1}, true);
    try f.e.reconcile(&.{}, true);
    try testing.expect(!f.e.wantsLink());
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
}

test "an item answered while its post was on its way is dismissed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.e.reconcile(&.{a1}, true);
    const post = try f.take();
    try f.e.reconcile(&.{}, true);
    try f.ok(post[0], "{\"id\":\"n7\"}");
    const dismiss = try f.take();
    try testing.expectEqualStrings("n7", dismiss[0].object.get("params").?.object.get("id").?.string);
}

test "ui.chrome = own posts nothing, and still takes back what was posted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.e.reconcile(&.{a1}, false);
    try testing.expect(!f.e.wantsLink());
    try f.e.reconcile(&.{a1}, true);
    const post = try f.take();
    try f.ok(post[0], "{\"id\":\"n7\"}");
    try f.e.reconcile(&.{}, false);
    try testing.expectEqualStrings("notify.dismiss", (try f.take())[0].object.get("verb").?.string);
}

test "a refused principal starts the link over and loses nothing; lost requests go again" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.e.reconcile(&.{a1}, true);
    var post = try f.take();
    try testing.expect(try f.e.onResponse(post[0].object.get("id").?.integer, .{ .@"error" = .{ .code = "denied.write", .message = "", .data = .null } }));
    post = try f.take();
    try testing.expectEqual(@as(usize, 1), post.len);
    f.e.requeue();
    post = try f.take();
    try testing.expectEqual(@as(usize, 1), post.len);
}

test "venomx refusing the text is said and not retried" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.e.reconcile(&.{a1}, true);
    const post = try f.take();
    try testing.expect(!try f.e.onResponse(post[0].object.get("id").?.integer, .{ .@"error" = .{ .code = "invalid_params.notification", .message = "", .data = .null } }));
    try f.e.reconcile(&.{a1}, true);
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
    try f.e.reconcile(&.{}, true);
    try testing.expect(!f.e.wantsLink());
}

test "with no venomx to connect to, pump gives up without blocking and keeps the work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
    const entry = try std.fmt.allocPrintSentinel(arena.allocator(), "VENOMX_SOCKET={s}/none.sock", .{dir}, 0);
    const slice = try arena.allocator().allocSentinel(?[*:0]const u8, 1, null);
    slice[0] = entry;
    var e: Escalation = undefined;
    try e.init(testing.allocator, .{ .block = .{ .slice = slice } }, null);
    defer e.deinit();
    try e.pump();
    try testing.expectEqual(Escalation.Phase.down, e.phase);
    try e.reconcile(&.{a1}, true);
    try e.pump();
    try testing.expectEqual(Escalation.Phase.down, e.phase);
    try testing.expect(e.wantsLink());
    try testing.expect(e.retry_at > 0);
}

test "a link that keeps failing warns once, and again only after it worked" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expect(f.e.warnLink("refused", "denied.namespace"));
    try testing.expect(!f.e.warnLink("refused", "denied.namespace"));
    try testing.expect(!f.e.warnLink("failed", "Refused"));
}

test "cleanText: what venomx accepts, cut on a character" {
    const a = testing.allocator;
    const check = struct {
        fn f(x: std.mem.Allocator, text: []const u8, max: usize, want: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(x);
            defer arena.deinit();
            const got = try cleanText(arena.allocator(), text, max);
            try testing.expectEqualStrings(want, got);
            try testing.expect(got.len <= max);
            try testing.expect(std.unicode.utf8ValidateSlice(got));
        }
    }.f;
    try check(a, "plain", 10, "plain");
    try check(a, "zig build\n  && echo\t\x1b[31m", 40, "zig build   && echo  [31m");
    try check(a, "\x7f\u{9b}x", 10, "  x");
    try check(a, "ab\u{00e9}", 3, "ab");
    try check(a, "a\xffb", 10, "a\u{FFFD}b");
    try check(a, "a\xc3", 10, "a\u{FFFD}");
}
