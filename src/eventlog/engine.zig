//! The impure shell around the decider: command in, decide,
//! durable commit (store.zig), fold into the state, publish on `venom
//! events`, and an effect worker that drains the outbox.
//!
//! Effects are at least once: an `effect.requested` record is committed in
//! the same commit as the events that caused it, and only a later
//! `effect.completed` commit retires it. A crash between running an effect
//! and committing its completion runs it again after the restart, with the
//! same idempotency key, so every executor MUST be idempotent per key.
//! All methods run on the daemon's reactor thread.
const std = @import("std");
const proto = @import("proto");
const ev = @import("events.zig");
const decider = @import("decider.zig");
const Store = @import("store.zig").Store;
const catalog = @import("catalog.zig");
const attention = @import("attention.zig");
const agent_model = @import("agent.zig");
const Event = ev.Event;
const Command = ev.Command;

/// Runs one kind of effect. `run` gets the idempotency key and the payload
/// and returns the outcome to record; an error is recorded as `ok=false`
/// with the error name, except `error.Retry`, which leaves the effect
/// pending for the next `runEffects`.
pub const Executor = struct {
    kind: []const u8,
    ptr: *anyopaque,
    run: *const fn (ptr: *anyopaque, key: []const u8, payload: []const u8) anyerror!Outcome,
    pub const Outcome = struct { ok: bool = true, detail: []const u8 = "" };

    pub fn init(kind: []const u8, impl: anytype) Executor {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        return .{ .kind = kind, .ptr = impl, .run = struct {
            fn run(ptr: *anyopaque, key: []const u8, payload: []const u8) anyerror!Outcome {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.run(key, payload);
            }
        }.run };
    }
};

/// Where the decider's `now` comes from: wall-clock milliseconds since the
/// Unix epoch. Tests inject their own.
pub const Clock = struct {
    ptr: ?*anyopaque = null,
    nowFn: *const fn (?*anyopaque) i64 = realNow,

    pub fn now(self: Clock) i64 {
        return self.nowFn(self.ptr);
    }
    fn realNow(_: ?*anyopaque) i64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
        return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    }
};

pub const Options = struct {
    /// Committed events with a published form are appended here.
    events: ?*proto.events.Log = null,
    executors: []const Executor = &.{},
    clock: Clock = .{},
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    store: Store,
    state: decider.State,
    options: Options,

    /// Opens the log at `path` and rebuilds the state from it. Nothing is
    /// published for replayed events: they belong to earlier epochs,
    /// and reconnecting clients get a snapshot.
    pub fn open(gpa: std.mem.Allocator, path: []const u8, options: Options) !Engine {
        var state = decider.State.init(gpa);
        errdefer state.deinit();
        var sink: Replay = .{ .state = &state };
        const store = try Store.open(gpa, path, &sink);
        return .{ .gpa = gpa, .store = store, .state = state, .options = options };
    }

    pub fn deinit(self: *Engine) void {
        self.store.close();
        self.state.deinit();
    }

    const Replay = struct {
        state: *decider.State,
        pub fn restore(self: *Replay, bytes: []const u8, version: u32) !void {
            try @import("snapshot.zig").restore(self.state, bytes, version);
        }
        pub fn replay(self: *Replay, e: Event) !void {
            try decider.evolve(self.state, e);
        }
    };

    pub fn compact(self: *Engine) !void {
        const bytes = try @import("snapshot.zig").encode(&self.state, self.gpa);
        defer self.gpa.free(bytes);
        try self.store.compact(bytes);
    }

    /// Logs the daemon start.
    pub fn start(self: *Engine) !void {
        return self.startWith(&.{});
    }

    /// `start` with the venomx panes still running:
    /// `handed_over` agents whose take-over pane is not among them are
    /// taken back. Take-over splits a venom TUI runs itself (own mode,
    /// pane `tui:<pid>`) are its children, not the daemon's, and
    /// outlive a daemon restart: they count as running while that TUI
    /// process is alive.
    pub fn startWith(self: *Engine, live_panes: []const []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var panes: std.ArrayList([]const u8) = .empty;
        try panes.appendSlice(a, live_panes);
        for (self.state.agents.values()) |agent| {
            if (agent.state != .handed_over) continue;
            const pane = agent.pane orelse continue;
            const pid = agent_model.clientPanePid(pane) orelse continue;
            if (agent_model.processAlive(pid)) try panes.append(a, pane);
        }
        _ = try self.submit(.{ .start = .{ .pid = std.c.getpid(), .panes = panes.items } });
    }

    /// Decides `cmd`, commits the events durably, then applies and
    /// publishes them. Returns the number of events (0: nothing changed).
    /// A rejected command returns its `decider.Rejection` and logs nothing.
    pub fn submit(self: *Engine, cmd: Command) !usize {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var out: std.ArrayList(Event) = .empty;
        try decider.decide(&self.state, cmd, self.options.clock.now(), a, &out);
        if (out.items.len == 0) return 0;
        var stamp: [32]u8 = undefined;
        _ = try self.store.commit(out.items, try timestamp(&stamp));
        // Durable from here on. An allocation failure below leaves memory
        // behind the log; the next start rebuilds it from the log.
        // Attention changes are read from the state before each record.
        const changes = try a.alloc(?attention.Change, out.items.len);
        for (out.items, changes) |e, *ch| {
            ch.* = attention.change(&self.state, e);
            try decider.evolve(&self.state, e);
        }
        if (self.options.events) |log| for (out.items, changes) |e, ch| try catalog.publish(log, a, e, ch);
        if (self.store.commits - self.store.snapshot_commit >= 4096 or self.store.size >= 16 * 1024 * 1024) self.compact() catch {};
        return out.items.len;
    }

    /// Archives agents settled for at least `archive_after_ms` (config
    /// `agents.archive_after`). Returns how many events
    /// were committed; 0 commits nothing.
    pub fn sweep(self: *Engine, archive_after_ms: u64) !usize {
        return self.submit(.{ .sweep = .{ .archive_after_ms = archive_after_ms } });
    }

    /// Denies approvals unanswered for `approval_timeout_ms` (config
    /// `attention.approval_timeout`).
    pub fn expireApprovals(self: *Engine, approval_timeout_ms: u64) !usize {
        return self.submit(.{ .expire = .{ .approval_timeout_ms = approval_timeout_ms } });
    }

    /// The effect worker: runs every pending effect that has an executor,
    /// oldest first, and commits each completion. Returns how many
    /// completed. Effects without an executor stay pending.
    pub fn runEffects(self: *Engine) !usize {
        if (self.state.pendingEffects() == 0) return 0;
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        // Copy first: completing an effect changes the map.
        var todo: std.ArrayList(decider.Effect) = .empty;
        for (self.state.effects.values()) |e| if (!e.done) try todo.append(a, e);
        var completed: usize = 0;
        for (todo.items) |e| {
            const executor = for (self.options.executors) |x| {
                if (std.mem.eql(u8, x.kind, e.kind)) break x;
            } else continue;
            const outcome = executor.run(executor.ptr, e.key, e.payload) catch |err| switch (err) {
                error.Retry => continue,
                else => Executor.Outcome{ .ok = false, .detail = @errorName(err) },
            };
            completed += try self.submit(.{ .complete = .{ .key = e.key, .ok = outcome.ok, .detail = outcome.detail } });
        }
        return completed;
    }
};

/// UTC RFC 3339 with milliseconds, as the events wire uses for `ts`.
pub fn timestamp(buf: []u8) ![]const u8 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return error.ClockUnavailable;
    const secs: u64 = @intCast(ts.sec);
    const day = std.time.epoch.EpochSeconds{ .secs = secs };
    const ymd = day.getEpochDay().calculateYearDay();
    const md = ymd.calculateMonthDay();
    const hms = day.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ ymd.year, md.month.numeric(), md.day_index + 1, hms.getHoursIntoDay(), hms.getMinutesIntoHour(), hms.getSecondsIntoMinute(), @as(u32, @intCast(@divTrunc(ts.nsec, 1_000_000))) });
}
