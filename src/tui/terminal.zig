//! `venom agent view` and bare `venom` (a product-local command): the
//! full-screen TUI on a real terminal. Everything it shows
//! comes from the daemon's verbs and events (link.zig); this file only owns
//! the terminal: raw mode, the alternate screen, resize and the loop.
//! With no daemon running, a bare `venom` starts an on-demand one
//! (startup.zig) before anything else; that daemon stops once its last TUI
//! quits, so quitting then asks first while agents still work.
const std = @import("std");
const posix = std.posix;
const cli = @import("cli");
const term = @import("venom-term");
const App = @import("app.zig").App;
const Link = @import("link.zig").Link;
const view = @import("view.zig");
const host_mod = @import("host.zig");
const usage_view = @import("usage_view.zig");

/// The local command declaration (compiled bootstrap extension, not verbs.zon).
pub const local_commands = .{ .{
    .name = "agent.view",
    .summary = "Open venom's TUI on the agents (bare `venom` does the same); --agent selects one, --inbox opens the inbox (`venom inbox`), --settings the settings (`venom settings`), --usage the usage",
    .interactive = true,
    .params = .{
        .{ .name = "agent", .summary = "Agent ID to select", .type = .{ .kind = .string } },
        .{ .name = "inbox", .summary = "Open on the inbox screen", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "no_owner", .summary = "Never read the owner file: connect with VENOM_TOKEN or as unknown", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "await_binding", .summary = "Wait for whoever started this view to bind a principal to its process, with `grant issue --pid`: what venom passes to the panes it makes", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "solo", .summary = "Draw only this view, with no list and no status bar, and never as a control pane: what venom runs in an agent's venomx pane", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "settings", .summary = "Open on the settings screen; leaving it leaves the TUI", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "usage", .summary = "Open on the usage screen", .type = .{ .kind = .boolean }, .default = false },
    },
    .result = .{ .kind = .object, .fields = .{} },
    .errors = .{
        .{ .code = "not_found.agent", .summary = "No agent with this ID" },
        .{ .code = "unavailable.not_running", .summary = "No daemon, and this view may not start one (a pane view, a VENOM_TOKEN, or daemon.interactive_start false)" },
        .{ .code = "denied.startup_context", .summary = "No daemon, and venom runs inside a venomx pane, an agent or below a process manager: start it in a terminal outside venomx" },
        .{ .code = "invalid_params.startup_config", .summary = "No daemon, and the persisted config is invalid, so none was started" },
        .{ .code = "unavailable.startup_failed", .summary = "The daemon venom started failed, and no other became ready" },
        .{ .code = "unavailable.startup_deadline", .summary = "No daemon became ready within daemon.startup_timeout_ms" },
    },
}, .{
    .name = "agent.diff",
    .summary = "Print `git diff` for an agent's folders; the venom.diff popup runs it with --pane",
    .interactive = true,
    .params = .{
        .{ .name = "agent", .summary = "Agent ID", .type = .{ .kind = .string } },
        .{ .name = "pane", .summary = "A venomx pane: the agent it shows, or the control pane's selected agent", .type = .{ .kind = .string } },
    },
    .result = .{ .kind = .object, .fields = .{} },
}, .{
    .name = "agent.split",
    .summary = "Open a read-only venomx pane next to an agent's other panes, in the caller's name: its view, or a shell in its folder. Closing it never stops the agent",
    .params = .{
        .{ .name = "agent", .summary = "Agent ID", .type = .{ .kind = .string }, .required = true },
        .{ .name = "kind", .summary = "What the pane runs", .type = .{ .kind = .string, .choices = .{ "agent_view", "shell" } }, .default = "agent_view" },
        .{ .name = "pane", .summary = "The pane to split when the agent has none; default: the caller's own", .type = .{ .kind = .string } },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "agent", .summary = "Agent ID", .type = .{ .kind = .string }, .required = true },
        .{ .name = "kind", .summary = "What the pane runs", .type = .{ .kind = .string }, .required = true },
        .{ .name = "pane", .summary = "The new pane", .type = .{ .kind = .string }, .required = true },
        .{ .name = "window", .summary = "Its window", .type = .{ .kind = .string }, .required = true },
        .{ .name = "session", .summary = "Its venomx session", .type = .{ .kind = .string }, .required = true },
        .{ .name = "principal", .summary = "The pane's principal", .type = .{ .kind = .string }, .required = true },
        .{ .name = "pid", .summary = "The pane's root process", .type = .{ .kind = .integer }, .required = true },
    } },
    .errors = .{
        .{ .code = "not_found.agent", .summary = "No agent with this ID" },
        .{ .code = "invalid_params.pane", .summary = "No --pane, and the caller is not in a venomx pane" },
        .{ .code = "unavailable.venomx", .summary = "venomx is not reachable" },
        .{ .code = "unavailable.not_running", .summary = "The venom daemon is not running; these never start one" },
        .{ .code = "unavailable.folder", .summary = "A shell was asked for and the agent has no folder yet" },
        .{ .code = "denied.spawn", .summary = "The caller's venomx rights do not let it split that pane" },
    },
} };

/// Argv shortcuts for the shared parser: bare `venom` is
/// `venom agent view`, `venom agent view <id>` is `--agent=<id>`, bare
/// `venom inbox` is `venom agent view --inbox`, and bare
/// `venom settings` (venomx's settings popup command) is
/// `venom agent view --settings`.
pub fn rewriteArgs(a: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    if (args.len == 0) return &.{ "agent", "view" };
    for ([_][2][]const u8{ .{ "inbox", "--inbox=true" }, .{ "settings", "--settings=true" } }) |shortcut| {
        if (!std.mem.eql(u8, args[0], shortcut[0])) continue;
        // Only flags follow: `venom inbox [--socket=…]`, not `inbox list`.
        for (args[1..]) |x| if (!std.mem.startsWith(u8, x, "-")) return args;
        const out = try a.alloc([]const u8, args.len + 2);
        out[0] = "agent";
        out[1] = "view";
        out[2] = shortcut[1];
        @memcpy(out[3..], args[1..]);
        return out;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[0], "agent") and std.mem.eql(u8, args[1], "view") and !std.mem.startsWith(u8, args[2], "-")) {
        const out = try a.alloc([]const u8, args.len);
        out[0] = "agent";
        out[1] = "view";
        out[2] = try std.fmt.allocPrint(a, "--agent={s}", .{args[2]});
        @memcpy(out[3..], args[3..]);
        return out;
    }
    return args;
}

/// The local handler `main.zig` registers.
pub const Command = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*std.process.Environ.Map = null,
    stopped: ?*const std.atomic.Value(bool) = null,

    pub const commands = .{ "agent.view", "agent.diff", "agent.split" };

    pub fn call(self: *Command, ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        if (std.mem.eql(u8, ctx.name, "agent.diff")) return self.diff(ctx);
        if (std.mem.eql(u8, ctx.name, "agent.split")) return self.splitPane(ctx);
        var app = App.init(self.gpa);
        defer app.deinit();
        var user_path: []const u8 = "";
        defer self.gpa.free(user_path);
        // The TUI reads the owner file by default. In a
        // venomx pane that is refused and it runs as `unknown`,
        // with the VENOM_TOKEN it was given, or as the principal bound to it.
        var link: Link = .{ .gpa = self.gpa, .path = ctx.path };
        defer link.deinit();
        const no_owner = if (ctx.params.object.get("no_owner")) |v| v == .bool and v.bool else false;
        if (ctx.path.environ) |e| if (!no_owner) link.useOwner(try host_mod.ownerEnviron(ctx.allocator, e, "VENOM_TOKEN"));
        if (self.environ_map) |env| {
            app.home = env.get("HOME") orelse "";
            app.setTheme(.{ .mode = term.theme.Mode.detect(env) });
            user_path = try userConfigPath(self.gpa, env);
            app.settings.user_path = user_path;
        }
        // Own-mode splits: shells inherit venom's environment,
        // and take-over is offered for adapters that provide resume.
        app.env = self.environ_map;
        app.io = self.io;
        app.shell_path = @import("split.zig").resolveShell(self.environ_map);
        app.resumes = @import("../harnesses.zig").resumesTui;
        // Identity is resolved at `accept`, so this comes before the connection
        // the TUI keeps.
        const await_binding = if (ctx.params.object.get("await_binding")) |v| v == .bool and v.bool else false;
        const solo_view = if (ctx.params.object.get("solo")) |v| v == .bool and v.bool else false;
        // No daemon: a terminal outside every managed tree starts one, before
        // this process sets the subreaper, writes its marker or starts any
        // child, so the daemon never ends up below it.
        if (ctx.path.environ) |environ| {
            var connect_err: anyerror = error.NotRunning;
            const started = @import("startup.zig").ensure(.{
                .gpa = self.gpa,
                .a = ctx.allocator,
                .socket = try absoluteSocket(ctx.allocator, ctx.path),
                .environ = environ,
                .connect_environ = link.path.environ,
                .pane_view = no_owner or solo_view or await_binding,
                .stopped = self.stopped,
            }, &connect_err) catch |err| {
                if (err != error.Connect) return err;
                return .{ .failure = try connectFailure(ctx, connect_err) };
            };
            if (started) |f| return .{ .failure = .{ .code = f.code, .message = f.message } };
        }
        const bound = await_binding and host_mod.awaitBinding(self.gpa, ctx.allocator, ctx.path);
        // Report a missing daemon or agent before taking the terminal,
        // so scripts get the standard error object.
        link.connect() catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .failure = try connectFailure(ctx, err) };
        };
        const deadline = @import("link.zig").nowMs() + 5000;
        // A refused owner token reconnects inside `pump` (`Link.plain`).
        while (!link.ready) {
            try link.pump(&app, 100);
            if (link.client == null or @import("link.zig").nowMs() > deadline)
                return .{ .failure = .{ .code = "unavailable.not_running", .message = "the venom daemon did not answer" } };
        }
        if (ctx.params.object.get("agent")) |v| if (v == .string) {
            if (!try agentExists(&link, &app, v.string)) return .{ .failure = .{ .code = "not_found.agent", .message = "no such agent; see venom agent list", .data = try dataAgent(ctx.allocator, v.string) } };
            try app.preselect(v.string);
        };
        const inbox = if (ctx.params.object.get("inbox")) |v| v == .bool and v.bool else false;
        if (inbox) app.openInbox();
        // `venom settings` is the view itself, also in a venom.settings popup.
        const settings = if (ctx.params.object.get("settings")) |v| v == .bool and v.bool else false;
        if (settings) {
            app.settings.standalone = true;
            try app.openSettings();
        }
        const usage = if (ctx.params.object.get("usage")) |v| v == .bool and v.bool else false;
        if (usage) try usage_view.open(&app);
        try app.requestTranscriptConfig();
        try app.requestListConfig();
        try app.requestKeysConfig();
        const solo = if (ctx.params.object.get("solo")) |v| v == .bool and v.bool else false;
        if (solo) app.setSolo();
        if (solo and (inbox or usage)) app.setSingleView();
        app.rings = !solo;
        // An agent's pane is never a control pane.
        var host: ?*host_mod.Host = null;
        defer if (host) |h| host_mod.destroy(self.gpa, h);
        var handoff: Handoff = .{ .link = &link, .app = &app };
        if (!solo and !settings) switch (try self.chrome(&link, &app, ctx, inbox, usage, bound, &handoff)) {
            .own => |why| if (why) |text| app.say("{s}", .{text}),
            .host => |h| {
                host = h;
                app.host = h;
            },
        };
        defer if (host) |h| h.finish(&app);
        if (await_binding and !bound) app.say("no venom rights in this pane, read-only: quit, then start venom outside venomx", .{});
        // No pane manager above this TUI's shells and
        // harnesses, so they are kept from the owner files by this marker. The
        // subreaper keeps a job whose parent shell exited below it. Children
        // are still waited for by pid, so such a job stays a zombie until this
        // TUI exits.
        var marker: ?@import("proto").managers.Held = null;
        defer if (marker) |m| m.release();
        if (host == null) {
            @import("proto").process.subreaper() catch |err| app.say("a job that outlives its shell here can read the owner file: {s}", .{@errorName(err)});
            const socket = try @import("proto").os.socketPath(ctx.allocator, "venom", ctx.path);
            marker = @import("proto").managers.Held.acquire(self.gpa, socket) catch |err| blk: {
                app.say("splits here can read the owner file: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
        try self.loop(&app, &link);
        // Quitting with a take-over split open: its harness TUI ends with
        // this process, so give the agent back to venom first.
        try app.releaseTakeovers();
        const until = @import("link.zig").nowMs() + 3000;
        while (app.owesTakeback() and @import("link.zig").nowMs() < until) try link.pump(&app, 50);
        return .{ .status = 0 };
    }

    /// `ui.chrome` from the daemon's config, then what it means here.
    fn chrome(self: *Command, link: *Link, app: *App, ctx: cli.Local.Context, inbox: bool, usage: bool, bound: bool, handoff: *Handoff) !host_mod.Resolved {
        const environ = ctx.path.environ orelse return .{ .own = null };
        const setting = try chromeSetting(link, app);
        const a = ctx.allocator;
        const size = hostSize();
        return host_mod.resolve(self.gpa, a, .{
            .setting = setting,
            .environ = environ,
            .env_map = self.environ_map,
            .exe = try selfExe(a),
            .socket = try @import("proto").os.socketPath(a, "venom", ctx.path),
            .agent = if (ctx.params.object.get("agent")) |v| (if (v == .string) v.string else null) else null,
            .inbox = inbox,
            .usage = usage,
            .cols = size.cols,
            .rows = size.rows,
            .bound = bound,
            .handoff = handoff.hook(),
        });
    }

    fn diff(self: *Command, ctx: cli.Local.Context) !cli.Local.Outcome {
        const environ = ctx.path.environ orelse return .{ .failure = .{ .code = "unavailable", .message = "no environment" } };
        const param = struct {
            fn str(c: cli.Local.Context, name: []const u8) ?[]const u8 {
                const v = c.params.object.get(name) orelse return null;
                return if (v == .string) v.string else null;
            }
        }.str;
        if (try host_mod.diffCommand(self.gpa, ctx.allocator, ctx.path, environ, param(ctx, "agent"), param(ctx, "pane"), ctx.stdout)) |why|
            return .{ .failure = .{ .code = "unavailable", .message = why } };
        return .{ .status = 0 };
    }

    fn splitPane(self: *Command, ctx: cli.Local.Context) !cli.Local.Outcome {
        const environ = ctx.path.environ orelse return .{ .failure = .{ .code = "unavailable", .message = "no environment" } };
        const a = ctx.allocator;
        const str = struct {
            fn of(c: cli.Local.Context, name: []const u8) ?[]const u8 {
                const v = c.params.object.get(name) orelse return null;
                return if (v == .string) v.string else null;
            }
        }.of;
        const kind = std.meta.stringToEnum(@import("split.zig").Kind, str(ctx, "kind") orelse "agent_view") orelse .agent_view;
        const got = try host_mod.splitCommand(self.gpa, a, ctx.path, environ, .{
            .agent = str(ctx, "agent").?,
            .kind = kind,
            .pane = str(ctx, "pane"),
            .exe = try selfExe(a),
            .socket = try @import("proto").os.socketPath(a, "venom", ctx.path),
            .shell = @import("split.zig").resolveShell(self.environ_map),
        });
        return switch (got) {
            .ok => |v| .{ .result = v },
            .failure => |f| .{ .failure = .{ .code = f.code, .message = f.message } },
        };
    }

    fn loop(self: *Command, app: *App, link: *Link) !void {
        var tty = try Tty.enter();
        defer tty.leave();
        var surface = try term.Surface.init(self.gpa, 80, 24);
        var out_buf: [64 * 1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const out = &stdout.interface;
        defer {
            surface.deinit(out);
            out.writeAll(Tty.restore_sequence) catch {};
            out.flush() catch {};
        }
        try out.writeAll(Tty.enter_sequence);
        var size = hostSize();
        try surface.resize(size.cols, size.rows);
        var env = if (self.environ_map) |e| e.* else std.process.Environ.Map.init(self.gpa);
        var in_buf: [4096]u8 = undefined;
        var in_len: usize = 0;
        var cursor_input = false;
        while (!(app.quit and app.confirmQuit())) {
            if (self.stopped) |s| if (s.load(.monotonic)) break;
            app.now_ms = wallMs(self.io);
            app.syncLeader();
            try app.tick();
            try view.render(app, &surface);
            try surface.present(self.io, &env, out);
            if ((app.keyMode() == .input) != cursor_input) {
                cursor_input = !cursor_input;
                try out.writeAll(app.keyMode().cursorSequence());
            }
            if (app.takeBell()) {
                try out.writeAll("\x07");
                if (app.host) |h| h.noteBell();
            }
            try out.flush();
            const split = @import("split.zig");
            // Host mode's venomx link (`-1` is ignored by poll).
            var fds: [4 + split.max]posix.pollfd = undefined;
            fds[0..3].* = .{
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = link.fd() orelse -1, .events = posix.POLL.IN | (if (link.wantsWrite() or app.outbox.items.len > 0) posix.POLL.OUT else @as(i16, 0)), .revents = 0 },
            };
            // Shell splits' PTY masters.
            var shell_fds: [split.max]std.c.fd_t = undefined;
            const shells = app.shellFds(&shell_fds);
            var writing = false;
            for (shells, 0..) |fd, i| {
                const wants = app.shellWantsWrite(fd);
                writing = writing or wants;
                fds[3 + i] = .{ .fd = fd, .events = posix.POLL.IN | (if (wants) posix.POLL.OUT else @as(i16, 0)), .revents = 0 };
            }
            fds[3 + shells.len] = .{ .fd = if (app.host) |h| h.fd() orelse -1 else -1, .events = posix.POLL.IN | (if (app.host != null and app.host.?.wantsWrite()) posix.POLL.OUT else @as(i16, 0)), .revents = 0 };
            // A queued paste's deadlines pass even if the PTY stays full.
            var timeout: i32 = @intCast(@min(link.retryIn() orelse 1000, if (writing) @as(u32, 250) else 1000));
            // The leader popup's delay and `ui.keys.timeout_ms`.
            if (app.leaderWake()) |at| timeout = @intCast(std.math.clamp(at - app.now_ms, 0, timeout));
            _ = posix.poll(fds[0 .. 4 + shells.len], timeout) catch |err| if (err != error.Interrupted) return err;
            _ = try app.pumpShells();
            if (fds[1].revents != 0) {
                var drop: [64]u8 = undefined;
                while (std.c.read(winch_pipe[0], &drop, drop.len) > 0) {}
                size = hostSize();
                try surface.resize(size.cols, size.rows);
            }
            if (fds[0].revents != 0) {
                const n = std.c.read(posix.STDIN_FILENO, in_buf[in_len..].ptr, in_buf.len - in_len);
                if (n == 0) break;
                if (n > 0) {
                    in_len += @intCast(n);
                    // The poll may have slept a long time since the last turn.
                    app.now_ms = wallMs(self.io);
                    const used = try app.feed(in_buf[0..in_len]);
                    std.mem.copyForwards(u8, in_buf[0 .. in_len - used], in_buf[used..in_len]);
                    in_len -= used;
                    // A full buffer of junk must not wedge the loop.
                    if (in_len == in_buf.len) in_len = 0;
                }
            }
            try link.pump(app, 0);
            if (app.host) |h| _ = try h.pump(app);
        }
    }
};

/// The user layer's file for the settings screen's title.
fn userConfigPath(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| if (dir.len > 0) return std.fs.path.join(a, &.{ dir, "venom", "config.zon" });
    return std.fs.path.join(a, &.{ env.get("HOME") orelse "", ".config", "venom", "config.zon" });
}

/// `ui.chrome` as the daemon has it; `auto` when it will not say.
fn chromeSetting(link: *Link, app: *App) !host_mod.Setting {
    const proto = @import("proto");
    var c = &link.client.?;
    try c.request(@as(i64, 3), "config.get", .{ .key = "ui.chrome" });
    const deadline = @import("link.zig").nowMs() + 5000;
    while (@import("link.zig").nowMs() < deadline) {
        const msg = try c.receive(100) orelse continue;
        if (msg != .ndjson) return error.InvalidResponse;
        var r = try proto.Response.parse(app.gpa, msg.ndjson);
        defer r.deinit();
        const rid = r.id orelse continue;
        if (!rid.eql(.{ .integer = 3 })) {
            if (rid.eql(.{ .integer = 1 }) and r.body == .item) try app.onEvent(r.body.item);
            if (rid.eql(.{ .integer = @import("link.zig").hold_id }) and r.body == .item) app.onHold(r.body.item);
            continue;
        }
        return if (r.body == .ok) host_mod.settingOf(r.body.ok) else .auto;
    }
    return .auto;
}

/// This binary's absolute path, for argv in panes and key bindings.
fn selfExe(a: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return "venom";
    return a.dupe(u8, buf[0..@intCast(n)]);
}

/// The outside process of host mode keeps its hold until the control pane
/// holds too (an item with `others` above 0), bounded by the binding wait,
/// before it becomes `venomx attach`; the linger covers the rest.
const Handoff = struct {
    link: *Link,
    app: *App,
    fn hook(self: *Handoff) host_mod.Handoff {
        return .{ .ctx = self, .wait = wait };
    }
    fn wait(ctx: *anyopaque) void {
        const self: *Handoff = @ptrCast(@alignCast(ctx));
        const until = @import("link.zig").nowMs() + 5000;
        while (@import("link.zig").nowMs() < until) {
            if (self.app.hold) |h| if (h.others > 0) return;
            self.link.pump(self.app, 50) catch return;
        }
    }
};

/// The selected socket, made absolute: the daemon gets it as `--socket`.
fn absoluteSocket(a: std.mem.Allocator, path: @import("proto").SocketOptions) ![]const u8 {
    const selected = try @import("proto").os.socketPath(a, "venom", path);
    if (std.fs.path.isAbsolute(selected)) return selected;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return selected;
    return std.fs.path.join(a, &.{ std.mem.span(@as([*:0]const u8, @ptrCast(cwd))), selected });
}

/// Why `venom` could not connect. Only no socket means no daemon.
fn connectFailure(ctx: cli.Local.Context, err: anyerror) !cli.Local.Failure {
    const proto = @import("proto");
    const a = ctx.allocator;
    const socket = try proto.os.socketPath(a, "venom", ctx.path);
    const exists = std.c.access(socket, std.c.F_OK) == 0;
    if (err == error.NotRunning or !exists) return .{ .code = "unavailable.not_running", .message = @import("startup.zig").not_running_message };
    return .{ .code = "unavailable", .message = try std.fmt.allocPrint(a, "cannot read venom's owner file next to {s} ({s}); fix it, or set VENOM_TOKEN", .{ socket, @errorName(err) }) };
}

fn dataAgent(a: std.mem.Allocator, id: []const u8) !std.json.Value {
    var data: std.json.Value = .{ .object = .empty };
    try data.object.put(a, "agent", .{ .string = id });
    return data;
}

/// Asks `agent.show` once (before the UI starts) whether `id` exists.
fn agentExists(link: *Link, app: *App, id: []const u8) !bool {
    const proto = @import("proto");
    var c = &link.client.?;
    try c.request(@as(i64, 2), "agent.show", .{ .agent = id });
    const deadline = @import("link.zig").nowMs() + 5000;
    while (@import("link.zig").nowMs() < deadline) {
        const msg = try c.receive(100) orelse continue;
        if (msg != .ndjson) return error.InvalidResponse;
        var r = try proto.Response.parse(app.gpa, msg.ndjson);
        defer r.deinit();
        const rid = r.id orelse continue;
        if (!rid.eql(.{ .integer = 2 })) {
            // An events item that raced ahead: apply it.
            if (rid.eql(.{ .integer = 1 }) and r.body == .item) try app.onEvent(r.body.item);
            if (rid.eql(.{ .integer = @import("link.zig").hold_id }) and r.body == .item) app.onHold(r.body.item);
            continue;
        }
        return r.body == .ok;
    }
    return error.Timeout;
}

fn wallMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

var winch_pipe: [2]posix.fd_t = .{ -1, -1 };
fn onWinch(_: posix.SIG) callconv(.c) void {
    const byte = [_]u8{1};
    _ = std.c.write(winch_pipe[1], &byte, 1);
}

const Tty = struct {
    saved: posix.termios,
    /// Alternate screen, SGR mouse, bracketed paste, Kitty keyboard flags.
    const enter_sequence = "\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[>1u";
    const restore_sequence = "\x1b[0 q\x1b[<u\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l";

    fn enter() !Tty {
        if (std.c.pipe2(&winch_pipe, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return error.PipeFailed;
        var act: posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
        posix.sigaction(.WINCH, &act, null);
        const saved = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = saved;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
        return .{ .saved = saved };
    }

    fn leave(self: *Tty) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.WINCH, &act, null);
        for (winch_pipe) |p| if (p >= 0) {
            _ = std.c.close(p);
        };
        winch_pipe = .{ -1, -1 };
    }
};

fn ioctlRequest(comptime value: anytype) c_int {
    return @bitCast(@as(u32, @intCast(value)));
}

fn hostSize() struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(posix.STDOUT_FILENO, ioctlRequest(posix.T.IOCGWINSZ), @intFromPtr(&ws)) != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

test "rewriteArgs: bare venom is agent view; a positional agent becomes --agent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bare = try rewriteArgs(a, &.{});
    try std.testing.expectEqualStrings("view", bare[1]);
    const pos = try rewriteArgs(a, &.{ "agent", "view", "a3", "--json" });
    try std.testing.expectEqualStrings("--agent=a3", pos[2]);
    try std.testing.expectEqualStrings("--json", pos[3]);
    const inbox = try rewriteArgs(a, &.{"inbox"});
    try std.testing.expectEqualStrings("--inbox=true", inbox[2]);
    const flags = try rewriteArgs(a, &.{ "inbox", "--json" });
    try std.testing.expectEqualStrings("--json", flags[3]);
    try std.testing.expectEqual(@as(usize, 2), (try rewriteArgs(a, &.{ "inbox", "list" })).len);
    const settings = try rewriteArgs(a, &.{ "settings", "--json" });
    try std.testing.expectEqualStrings("--settings=true", settings[2]);
    try std.testing.expectEqualStrings("--json", settings[3]);
    const same = try rewriteArgs(a, &.{ "agent", "list" });
    try std.testing.expectEqual(@as(usize, 2), same.len);
}
