//! The TUI's connection to the venom daemon: a plain wire-protocol
//! client of the daemon's socket, like `venom agent …`. It subscribes to
//! `events` (types `agent.*`) from the model's cursor and sends the App's
//! verb requests. When the daemon goes away it keeps the App's state and
//! reconnects with backoff; the new subscription resumes from the saved
//! cursor, which after a daemon restart (a new epoch) falls back to a
//! `source_changed` snapshot, so nothing is lost.
//!
//! Single-threaded and non-blocking: `pump` does one turn of work.
const std = @import("std");
const proto = @import("proto");
const App = @import("app.zig").App;

/// The `events` subscription's request id; the App's ids start above it.
const events_id: i64 = 1;
const backoff_min_ms = 100;
const backoff_max_ms = 1000;

pub const Link = struct {
    gpa: std.mem.Allocator,
    path: proto.SocketOptions,
    client: ?proto.Client = null,
    ready: bool = false,
    retry_at: i64 = 0,
    backoff_ms: i64 = backoff_min_ms,
    /// Successful connections so far (tests watch it across a restart).
    connects: u32 = 0,
    /// Bytes of the verb responses received (tests measure a refresh with it).
    response_bytes: u64 = 0,
    /// The environment without the owner token, while the owner file is in
    /// use: a process inside a managed tree is refused it and falls back
    /// to its own rights, as `venomx attach` does.
    plain: ?std.process.Environ = null,
    /// The note about a token that no longer works has been shown.
    token_ended: bool = false,

    pub fn deinit(self: *Link) void {
        if (self.client) |*c| c.deinit();
        self.* = undefined;
    }

    /// The TUI presents the owner token by default.
    pub fn useOwner(self: *Link, environ: std.process.Environ) void {
        self.plain = self.path.environ;
        self.path.environ = environ;
    }

    /// The socket to poll, while connected.
    pub fn fd(self: *const Link) ?std.c.fd_t {
        const c = self.client orelse return null;
        return c.connection.fd;
    }

    /// Whether output is queued (poll for writability too).
    pub fn wantsWrite(self: *const Link) bool {
        const c = self.client orelse return false;
        return c.connection.output.items.len > 0 or c.connecting;
    }

    /// Milliseconds until the next reconnect attempt, if disconnected.
    pub fn retryIn(self: *const Link) ?i64 {
        if (self.client != null) return null;
        return @max(0, self.retry_at - nowMs());
    }

    /// Tries to connect now; error.NotRunning (and friends) when the daemon
    /// is not there. Used once before the TUI takes the terminal.
    pub fn connect(self: *Link) !void {
        if (self.client != null) return;
        self.client = try proto.Client.init(self.gpa, .{
            .tool = "venom",
            .path = self.path,
            .hello = .{ .identity = .{ .name = "venom", .version = "0.0.0" }, .caps = &.{"cancel"} },
        });
        self.ready = false;
    }

    /// One turn: (re)connect, finish hello, send queued requests, and hand
    /// every complete message to the App. Waits at most `timeout_ms`.
    pub fn pump(self: *Link, app: *App, timeout_ms: i32) !void {
        if (self.client == null) {
            if (nowMs() < self.retry_at) return;
            self.connect() catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.scheduleRetry();
            };
        }
        self.turn(app, timeout_ms) catch |err| {
            if (err == error.OutOfMemory) return err;
            const refused = err == error.DeniedToken and self.client.?.token_failure == .owner_context;
            // A token dies with the daemon that issued it, or at its expiry.
            if (err == error.DeniedToken and !refused and !self.token_ended) {
                self.token_ended = true;
                app.say("this pane's venom token ended: quit, then start venom outside venomx", .{});
            }
            try self.drop(app);
            if (refused) if (self.plain) |env| {
                app.say("read-only in a venomx pane: start venom outside venomx, or set VENOM_TOKEN to a token you issued there", .{});
                self.path.environ = env;
                self.plain = null;
                self.retry_at = 0;
                self.backoff_ms = backoff_min_ms;
                self.connect() catch |e| if (e == error.OutOfMemory) return e;
            };
        };
    }

    fn turn(self: *Link, app: *App, timeout_ms: i32) !void {
        var c = &self.client.?;
        if (!self.ready) {
            if (!try c.pollHello(timeout_ms)) return;
            self.ready = true;
            self.connects += 1;
            self.backoff_ms = backoff_min_ms;
            try self.subscribe(app);
            try app.onConnected();
        }
        for (app.outbox.items) |line| {
            defer app.gpa.free(line);
            try c.connection.sendMessage(.{ .ndjson = line });
        }
        app.outbox.clearRetainingCapacity();
        var wait = timeout_ms;
        while (try c.receive(wait)) |msg| {
            wait = 0;
            if (msg != .ndjson) return error.InvalidResponse;
            var r = try proto.Response.parse(self.gpa, msg.ndjson);
            defer r.deinit();
            // The token ended under an open connection. Every later request
            // would say the same, so reconnect: `hello` then says why.
            if (r.body == .@"error" and std.mem.eql(u8, r.body.@"error".code, "denied.revoked")) return error.TokenEnded;
            const id = r.id orelse return error.InvalidResponse;
            const n: i64 = switch (id) {
                .integer => |v| v,
                else => continue,
            };
            if (n != events_id) self.response_bytes += msg.ndjson.len;
            if (n == events_id) {
                switch (r.body) {
                    .item => |item| try app.onEvent(item),
                    // A cursor the daemon cannot resume from, or a gap:
                    // start over from a snapshot. A finished stream (it
                    // follows, so only on shutdown) is resubscribed.
                    .@"error" => {
                        app.model.cursor.clearRetainingCapacity();
                        try self.subscribe(app);
                    },
                    .ok => try self.subscribe(app),
                }
            } else if (r.final()) try app.onResponse(n, r.body);
            // Requests the App queued while handling this message.
            for (app.outbox.items) |line| {
                defer app.gpa.free(line);
                try c.connection.sendMessage(.{ .ndjson = line });
            }
            app.outbox.clearRetainingCapacity();
        }
    }

    fn subscribe(self: *Link, app: *App) !void {
        try self.client.?.request(events_id, "events", .{ .after = app.model.cursor.items, .types = &[_][]const u8{"agent.*"}, .follow = true });
    }

    fn drop(self: *Link, app: *App) !void {
        if (self.client) |*c| c.deinit();
        self.client = null;
        self.ready = false;
        defer self.scheduleRetry();
        try app.onDisconnected();
    }

    fn scheduleRetry(self: *Link) void {
        self.retry_at = nowMs() + self.backoff_ms;
        self.backoff_ms = @min(self.backoff_ms * 2, backoff_max_ms);
    }
};

pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
