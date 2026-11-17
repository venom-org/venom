//! A bare `venom` with no daemon: start one. Only the TUI does this, only at
//! its own start, and only from a terminal outside every managed tree. The
//! daemon it starts is on-demand: it stops 5 s after its last TUI quits.
//!
//! The first connect decides: only a missing socket or a refused connection
//! is a missing daemon. A daemon whose `tui.hold` answers
//! `unavailable.shutdown` is stopping, and is waited for the same way. The
//! launcher then spawns at most one candidate, never while another process
//! holds the socket's lock, within one deadline of
//! `daemon.startup_timeout_ms`, extended once by `harness.shutdown_grace`
//! plus the cleanup allowance when it finds a daemon starting or stopping.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const lifecycle = @import("../lifecycle.zig");
const config = @import("../config.zig");
const nowMs = @import("link.zig").nowMs;

pub const Failure = struct { code: []const u8, message: []const u8 };

/// What the first connect found.
const Probe = enum { ready, missing, stopping };

pub const Options = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    /// The absolute socket.
    socket: []const u8,
    /// The caller's own environment, as given.
    environ: std.process.Environ,
    /// What the TUI connects with (the owner token, unless it chose one).
    connect_environ: ?std.process.Environ,
    /// A pane view (`--solo`, `--no-owner`, `--await-binding`): never starts one.
    pane_view: bool,
    stopped: ?*const std.atomic.Value(bool) = null,
};

/// The message every caller that may not start a daemon gets.
pub const not_running_message = "the venom daemon is not running; start it by running `venom`";

/// Returns once a daemon answers at the socket (the caller then connects as
/// usual), or the failure to report. Errors other than a missing daemon on
/// the first connect come back as `error.Connect`, with `connect_error` set.
pub fn ensure(o: Options, connect_error: *anyerror) !?Failure {
    const first = probe(o) catch |err| {
        connect_error.* = err;
        return error.Connect;
    };
    if (first == .ready) return null;
    if (try refusal(o)) |f| return f;
    const settings = readSettings(o) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .code = "invalid_params.startup_config", .message = "venom's configuration could not be read, so no daemon was started; fix it, or start one with `venom serve`" };
    };
    if (!settings.daemon.interactive_start) return .{ .code = "unavailable.not_running", .message = "the venom daemon is not running, and daemon.interactive_start is false" };
    return wait(o, first, settings);
}

/// The eligibility rules after the terminal check, in order: the first that
/// fails decides the error.
fn refusal(o: Options) !?Failure {
    if (o.pane_view) return .{ .code = "unavailable.not_running", .message = not_running_message };
    if (o.environ.getPosix("VENOM_TOKEN")) |t| if (!std.mem.eql(u8, t, "@owner"))
        return .{ .code = "unavailable.not_running", .message = "the venom daemon is not running, and a token works only on the daemon that issued it; start `venom` without VENOM_TOKEN" };
    if (lifecycle.contextMarker(o.environ)) |name|
        return .{ .code = "denied.startup_context", .message = try std.fmt.allocPrint(o.a, "venom is not running, and can't be started by an agent ({s} is set); a human starts it by running `venom`", .{name}) };
    const marker = lifecycle.managerMarker(o.a, o.socket) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .code = "denied.startup_context", .message = "venom is not running, and the directory of its socket can't be checked for a manager's marker" };
    };
    if (marker) |m| return .{ .code = "denied.startup_context", .message = try lifecycle.managerDenial(o.a, m) };
    return null;
}

const Read = struct { daemon: lifecycle.Settings, grace_ms: u32 };

/// The persisted config, through the daemon's own parser, defaults and checks.
fn readSettings(o: Options) !Read {
    const path = try cfg.configPath(o.a, "venom", o.environ);
    try lifecycle.regularOrMissing(o.a, path);
    const defaults = try cfg.defaultsPaths(o.a, "venom", o.environ);
    var store = try config.Store.init(o.gpa, .{ .io = std.Io.Threaded.global_single_threaded.io(), .path = path, .defaults = defaults, .validate = config.validate });
    defer store.deinit();
    const current = store.current();
    return .{ .daemon = current.daemon, .grace_ms = @intCast(config.Duration.parseMs(current.harness.shutdown_grace) catch 5000) };
}

/// Waits for a daemon at the socket, launching one candidate when no other
/// process holds the lock.
fn wait(o: Options, first: Probe, settings: Read) !?Failure {
    var launcher: lifecycle.Launcher = .{ .gpa = o.gpa };
    defer launcher.deinit();
    var deadline = nowMs() + settings.daemon.startup_timeout_ms;
    var extended = false;
    var found = first;
    var delay: i64 = 5;
    while (true) {
        if (o.stopped) |s| if (s.load(.monotonic)) return .{ .code = "cancelled", .message = "interrupted while starting the venom daemon" };
        switch (found) {
            .ready => return null,
            .missing, .stopping => {
                const held = found == .stopping or lifecycle.lockHeld(o.a, o.socket);
                // A daemon starting or stopping: its turns get one grace, and
                // its cleanup the allowance, before this launcher gives up.
                if (held and !launcher.launched and !extended) {
                    deadline += @as(i64, settings.grace_ms) + lifecycle.cleanup_allowance_ms;
                    extended = true;
                }
                if (!held and !launcher.launched) launcher.launch(o.a, o.socket, o.environ) catch |err| if (err == error.OutOfMemory) return err;
            },
        }
        const failed = launcher.launched and launcher.failed();
        if (nowMs() >= deadline) return if (failed)
            .{ .code = "unavailable.startup_failed", .message = try std.fmt.allocPrint(o.a, "the venom daemon failed to start ({s})", .{launcher.failure}) }
        else
            .{ .code = "unavailable.startup_deadline", .message = "the venom daemon did not become ready within daemon.startup_timeout_ms" };
        var pause: std.c.timespec = .{ .sec = 0, .nsec = @intCast(@min(delay, @max(1, deadline - nowMs())) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&pause, &pause);
        delay = @min(delay * 2, 100);
        found = probe(o) catch .missing;
        // A failed candidate with no winner ready: report it now.
        if (found != .ready and failed and !lifecycle.lockHeld(o.a, o.socket)) return .{ .code = "unavailable.startup_failed", .message = try std.fmt.allocPrint(o.a, "the venom daemon failed to start ({s})", .{launcher.failure}) };
    }
}

/// One connect: hello (with the TUI's credentials), `ping`, then `tui.hold`,
/// whose first answer says whether the daemon is stopping. The connection
/// is closed again; the TUI's own connection holds.
fn probe(o: Options) !Probe {
    var client = proto.Client.init(o.gpa, .{
        .tool = "venom",
        .path = .{ .socket = o.socket, .environ = o.connect_environ },
        .hello = .{ .identity = .{ .name = "venom", .version = "0.0.0" }, .caps = &.{"cancel"} },
    }) catch |err| return if (err == error.NotRunning) .missing else err;
    defer client.deinit();
    const until = nowMs() + 2000;
    while (!(client.pollHello(50) catch |err| return switch (err) {
        error.Disconnected => .missing,
        // A daemon answered, and refused the token: the TUI's own connection
        // falls back to its own rights, as it always has.
        error.DeniedToken => .ready,
        else => err,
    })) {
        if (nowMs() > until) return .missing;
    }
    try client.request(@as(i64, 1), "ping", struct {}{});
    try client.request(@as(i64, 2), "tui.hold", struct {}{});
    while (nowMs() < until) {
        const msg = (client.receive(50) catch return .missing) orelse continue;
        if (msg != .ndjson) return error.InvalidResponse;
        var r = try proto.Response.parse(o.gpa, msg.ndjson);
        defer r.deinit();
        const id = r.id orelse continue;
        if (!id.eql(.{ .integer = 2 })) continue;
        if (r.body == .@"error" and std.mem.eql(u8, r.body.@"error".code, "unavailable.shutdown")) return .stopping;
        // An item, or a refusal (`denied.tui_hold` for a view that only
        // reads): either way a daemon answers.
        return .ready;
    }
    return .missing;
}
