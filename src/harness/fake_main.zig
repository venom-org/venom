//! `venom-fake-harness`: a scripted stand-in for a coding-agent harness, so
//! that venom's adapter plumbing, supervision and every later test run
//! deterministically without any vendor CLI. It is a real child process
//! speaking NDJSON on stdin and stdout; `fake.zig` is its venom adapter.
//!
//! ```text
//! venom-fake-harness (--session ID | --resume ID) [--script JSON] [--state DIR] [--writable DIR]...
//! ```
//!
//! `--writable` (repeatable, absolute) is the agent's scope: a
//! `tool` step of kind `edit` whose title (the path, absolute or relative to
//! the cwd) is outside every writable folder first raises an approval
//! `ask {id: "scope-<tool id>", call: <tool id>}` and waits for it, as a
//! harness's sandbox or permission rules would; a denied one ends
//! `declined`. Without `--writable` nothing is asked.
//!
//! `--permission-mode` is what a real harness would obey; the fake
//! only records it, appending `<session> <mode>` to `<state>/modes`.
//!
//! `--mcp-off` (repeatable) leaves that server out of `init`'s `mcp`
//! (the script's `mcp_servers`) and is recorded as `<session> <server>` in
//! `<state>/mcp_off`.
//!
//! venom → fake (one JSON object per line):
//!
//! | Line | Meaning |
//! |---|---|
//! | `{"op":"send","text":…}` | Start a turn. While a turn runs it is queued (`steer: queue`). |
//! | `{"op":"respond","id":…,"answer":…,"reason"?:…,"args"?:…}` | Answer the open `ask` with that id (`args`: a JSON object as a string). |
//! | `{"op":"fork"}` | Reply `{"t":"forked","session":…}` (between turns). |
//! | `{"op":"compact"}` | A turn that says `compacted`, recorded as `<session>` in `<state>/compacts`, with the script's `compact_context` as its `context`. |
//!
//! SIGINT interrupts the running turn (`end` with `interrupted`), as Claude
//! Code's documented headless interrupt does. End of stdin exits 0.
//!
//! fake → venom: `{"t":"init","session","version","model","cwd"}` on start, then per
//! turn `turn {id}`, `text {id,text}`, `tool {id,name,kind,title}`,
//! `tool_end {id,status,exit?,ms?,body?}`, `ask {id,kind,call?,reason,answers,questions?}`,
//! `resolved {id,answer}`, `usage {in,out,cache_read,cache_write,model}`,
//! `context {used,window}` and `end {reason,resets_at?}`.
//!
//! The script is a JSON object:
//!
//! ```json
//! {"turns":[{"match":"crash","steps":[{"text":"hm"},{"crash":3}]},
//!           {"match":"","steps":[{"tool":{"id":"tu1","name":"Bash","kind":"exec","title":"zig build"}},
//!                                {"ask":{"id":"p1","kind":"approval","call":"tu1","reason":"Run zig build?"}},
//!                                {"tool_end":{"id":"tu1","status":"ok","exit":0}},
//!                                {"usage":{"in":10,"out":5}},{"text":"done"}]}],
//!  "crash_on_resume":2}
//! ```
//!
//! A turn runs the steps of the first entry whose `match` is a substring of
//! the message (`""` matches anything); no match is an empty, completed
//! turn. Steps: `text`, `tool`, `tool_end` (a denied call ends `declined`),
//! `ask` (waits for its answer; `cancel_turn` ends the turn `interrupted`;
//! with `"echo":true` a `text` repeats what arrived: `answer=… reason=…
//! args=…`; `input` is the call's raw input, passed on as the harness's
//! own request would carry it; `questions`, `[{"question":…,"options":[labels]}]`,
//! is what a question offers, as `AskUserQuestion` does),
//! `usage`, `context` (`{used, window}`), `sleep_ms` (interruptible),
//! `crash` (exit with that code at once) and `end` (the reason; default
//! `completed`; `resets_at`, unix seconds, beside it for a `limit`). `crash_on_resume`: the
//! first N starts with `--resume` exit 3 before `init`, counted in
//! `<state>/resumes`.
const std = @import("std");
const c = std.c;

var interrupted: std.atomic.Value(bool) = .init(false);

fn onInterrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const Fake = struct {
    a: std.mem.Allocator,
    script: std.json.Value,
    session: []const u8,
    inbuf: std.ArrayList(u8) = .empty,
    queue: std.ArrayList([]const u8) = .empty,
    eof: bool = false,
    turns: u32 = 0,
    messages: u32 = 0,
    forks: u32 = 0,
    cwd: []const u8 = "",
    writable: []const []const u8 = &.{},
    state_dir: ?[]const u8 = null,

    /// Whether an edit of `path` is outside the writable folders.
    fn outside(self: *Fake, path: []const u8) bool {
        if (self.writable.len == 0 or path.len == 0) return false;
        const abs = std.fs.path.resolvePosix(self.a, &.{ self.cwd, path }) catch c._exit(70);
        for (self.writable) |w| {
            if (std.mem.startsWith(u8, abs, w) and (abs.len == w.len or std.mem.eql(u8, w, "/") or abs[w.len] == '/')) return false;
        }
        return true;
    }

    /// Emits an `ask` and waits for its answer: false when the turn must
    /// end (`interrupted` already sent).
    fn ask(self: *Fake, id: []const u8, kind: []const u8, call: ?[]const u8, reason: []const u8, input: ?[]const u8, questions: ?std.json.Value, echo: bool, denied: *std.ArrayList([]const u8)) bool {
        const answers: []const []const u8 = if (std.mem.eql(u8, kind, "approval")) &.{ "allow_once", "allow_always", "allow_edited", "deny", "cancel_turn" } else &.{};
        self.emit(.{ .t = "ask", .id = id, .kind = kind, .call = call, .reason = reason, .answers = answers, .input = input, .questions = questions });
        const got = self.await(id) orelse {
            if (self.eof) c._exit(0); // venom closed our input: stop
            self.end("interrupted");
            return false;
        };
        const answer = str(got, "answer") orelse "allow_once";
        self.emit(.{ .t = "resolved", .id = id, .answer = answer });
        if (echo) {
            self.messages += 1;
            const text = std.fmt.allocPrint(self.a, "answer={s} reason={s} args={s}", .{ answer, str(got, "reason") orelse "", str(got, "args") orelse "" }) catch c._exit(70);
            self.emit(.{ .t = "text", .id = std.fmt.allocPrint(self.a, "hm{d}", .{self.messages}) catch c._exit(70), .text = text });
        }
        if (std.mem.eql(u8, answer, "cancel_turn")) {
            self.end("interrupted");
            return false;
        }
        if (std.mem.eql(u8, answer, "deny")) if (call) |x| denied.append(self.a, x) catch c._exit(70);
        return true;
    }

    fn emit(self: *Fake, value: anytype) void {
        const line = std.json.Stringify.valueAlloc(self.a, value, .{ .emit_null_optional_fields = false }) catch c._exit(70);
        writeAll(line);
        writeAll("\n");
    }

    /// The next stdin line, waiting up to `timeout_ms` (-1: forever). Null
    /// on timeout, on SIGINT or at end of input.
    fn readLine(self: *Fake, timeout_ms: i32) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.inbuf.items, '\n')) |i| {
                const line = self.a.dupe(u8, self.inbuf.items[0..i]) catch c._exit(70);
                const rest = self.inbuf.items[i + 1 ..];
                std.mem.copyForwards(u8, self.inbuf.items, rest);
                self.inbuf.shrinkRetainingCapacity(rest.len);
                return line;
            }
            if (self.eof or interrupted.load(.acquire)) return null;
            var fds = [_]c.pollfd{.{ .fd = 0, .events = c.POLL.IN }};
            const r = c.poll(&fds, 1, timeout_ms);
            if (r < 0) return null; // EINTR: SIGINT
            if (r == 0) return null;
            var buf: [4096]u8 = undefined;
            const n = c.read(0, &buf, buf.len);
            if (n < 0) {
                if (c.errno(n) == .INTR) return null;
                self.eof = true;
                continue;
            }
            if (n == 0) {
                self.eof = true;
                continue;
            }
            self.inbuf.appendSlice(self.a, buf[0..@intCast(n)]) catch c._exit(70);
        }
    }

    fn serve(self: *Fake) void {
        while (true) {
            const line = if (self.queue.items.len > 0) self.queue.orderedRemove(0) else self.readLine(-1) orelse {
                if (self.eof) return;
                interrupted.store(false, .release); // no turn to interrupt
                continue;
            };
            const msg = std.json.parseFromSliceLeaky(std.json.Value, self.a, line, .{}) catch continue;
            const op = str(msg, "op") orelse continue;
            if (std.mem.eql(u8, op, "send")) {
                self.turn(str(msg, "text") orelse "");
            } else if (std.mem.eql(u8, op, "compact")) {
                self.compact();
            } else if (std.mem.eql(u8, op, "fork")) {
                self.forks += 1;
                self.emit(.{ .t = "forked", .session = std.fmt.allocPrint(self.a, "{s}-fork{d}", .{ self.session, self.forks }) catch c._exit(70) });
            }
            // A respond outside a turn has nothing to answer.
        }
    }

    /// `{"op":"compact"}`: a turn of its own, as a harness's compaction is.
    fn compact(self: *Fake) void {
        self.turns += 1;
        interrupted.store(false, .release);
        if (self.state_dir) |dir| record(self.a, dir, "compacts", self.session, null);
        self.emit(.{ .t = "turn", .id = std.fmt.allocPrint(self.a, "ht{d}", .{self.turns}) catch c._exit(70) });
        self.messages += 1;
        self.emit(.{ .t = "text", .id = std.fmt.allocPrint(self.a, "hm{d}", .{self.messages}) catch c._exit(70), .text = "compacted" });
        if (self.script.object.get("compact_context")) |x| self.emit(.{ .t = "context", .used = int(x, "used") orelse 0, .window = int(x, "window") orelse 0 });
        self.end("completed");
    }

    fn turn(self: *Fake, message: []const u8) void {
        self.turns += 1;
        interrupted.store(false, .release);
        self.emit(.{ .t = "turn", .id = std.fmt.allocPrint(self.a, "ht{d}", .{self.turns}) catch c._exit(70) });
        const steps = self.pick(message);
        var denied: std.ArrayList([]const u8) = .empty;
        for (steps) |step| {
            if (interrupted.load(.acquire)) return self.end("interrupted");
            if (step != .object) continue;
            const s = step.object;
            if (s.get("text")) |t| {
                self.messages += 1;
                self.emit(.{ .t = "text", .id = std.fmt.allocPrint(self.a, "hm{d}", .{self.messages}) catch c._exit(70), .text = if (t == .string) t.string else "" });
            } else if (s.get("tool")) |t| {
                const id = str(t, "id") orelse "";
                const kind = str(t, "kind") orelse "exec";
                const title = str(t, "title") orelse "";
                self.emit(.{ .t = "tool", .id = id, .name = str(t, "name") orelse "Bash", .kind = kind, .title = title, .input = t.object.get("input") orelse .null, .server = str(t, "server") });
                if (std.mem.eql(u8, kind, "edit") and self.outside(title)) {
                    const ask_id = std.fmt.allocPrint(self.a, "scope-{s}", .{id}) catch c._exit(70);
                    const reason = std.fmt.allocPrint(self.a, "Edit {s} (outside the agent's scope)", .{title}) catch c._exit(70);
                    if (!self.ask(ask_id, "approval", id, reason, null, null, false, &denied)) return;
                }
            } else if (s.get("tool_end")) |t| {
                const id = str(t, "id") orelse "";
                var status = str(t, "status") orelse "ok";
                for (denied.items) |d| if (std.mem.eql(u8, d, id)) {
                    status = "declined";
                };
                self.emit(.{ .t = "tool_end", .id = id, .status = status, .exit = int(t, "exit"), .ms = int(t, "ms"), .body = str(t, "body") });
            } else if (s.get("ask")) |t| {
                const echo = if (t.object.get("echo")) |e| e == .bool and e.bool else false;
                if (!self.ask(str(t, "id") orelse "p", str(t, "kind") orelse "approval", str(t, "call"), str(t, "reason") orelse "", str(t, "input"), t.object.get("questions"), echo, &denied)) return;
            } else if (s.get("usage")) |u| {
                self.emit(.{ .t = "usage", .in = int(u, "in") orelse 0, .out = int(u, "out") orelse 0, .cache_read = int(u, "cache_read") orelse 0, .cache_write = int(u, "cache_write") orelse 0, .model = str(u, "model") orelse "fake-model" });
            } else if (s.get("context")) |x| {
                self.emit(.{ .t = "context", .used = int(x, "used") orelse 0, .window = int(x, "window") orelse 0, .system = int(x, "system"), .tools = int(x, "tools") });
            } else if (s.get("sleep_ms")) |ms| {
                const deadline = monotonicMs() + (if (ms == .integer) ms.integer else 0);
                while (monotonicMs() < deadline) {
                    if (interrupted.load(.acquire)) return self.end("interrupted");
                    // Lines arriving now are queued for after the turn.
                    if (self.readLine(@intCast(@max(1, deadline - monotonicMs())))) |l| self.queue.append(self.a, l) catch c._exit(70);
                }
            } else if (s.get("crash")) |code| {
                c._exit(if (code == .integer) @intCast(code.integer) else 1);
            } else if (s.get("end")) |reason| {
                const r = if (reason == .string) reason.string else "completed";
                if (s.get("resets_at")) |at| if (at == .integer) {
                    interrupted.store(false, .release);
                    return self.emit(.{ .t = "end", .reason = r, .resets_at = at.integer });
                };
                return self.end(r);
            }
        }
        self.end("completed");
    }

    /// Waits for the respond line with `id` and returns it; other lines are
    /// queued.
    fn await(self: *Fake, id: []const u8) ?std.json.Value {
        while (true) {
            const line = self.readLine(-1) orelse return null;
            const msg = std.json.parseFromSliceLeaky(std.json.Value, self.a, line, .{}) catch continue;
            const op = str(msg, "op") orelse continue;
            if (std.mem.eql(u8, op, "respond")) {
                if (std.mem.eql(u8, str(msg, "id") orelse "", id)) return msg;
                continue;
            }
            self.queue.append(self.a, line) catch c._exit(70);
        }
    }

    fn end(self: *Fake, reason: []const u8) void {
        interrupted.store(false, .release);
        self.emit(.{ .t = "end", .reason = reason });
    }

    fn pick(self: *Fake, message: []const u8) []const std.json.Value {
        const turns = (if (self.script == .object) self.script.object.get("turns") else null) orelse return &.{};
        if (turns != .array) return &.{};
        for (turns.array.items) |t| {
            const m = str(t, "match") orelse "";
            if (std.mem.indexOf(u8, message, m) == null) continue;
            const steps = (if (t == .object) t.object.get("steps") else null) orelse return &.{};
            return if (steps == .array) steps.array.items else &.{};
        }
        return &.{};
    }
};

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(1, rest.ptr, rest.len);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) c._exit(0); // venom is gone
        rest = rest[@intCast(n)..];
    }
}

fn monotonicMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Counts `--resume` starts in `<dir>/resumes`; returns the new count.
fn countResume(a: std.mem.Allocator, dir: []const u8) u32 {
    const path = std.fmt.allocPrintSentinel(a, "{s}/resumes", .{dir}, 0) catch c._exit(70);
    var n: u32 = 0;
    const rfd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (rfd >= 0) {
        var buf: [32]u8 = undefined;
        const got = c.read(rfd, &buf, buf.len);
        _ = c.close(rfd);
        if (got > 0) n = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..@intCast(got)], " \n"), 10) catch 0;
    }
    n += 1;
    const wfd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (wfd >= 0) {
        const text = std.fmt.allocPrint(a, "{d}\n", .{n}) catch c._exit(70);
        _ = c.write(wfd, text.ptr, text.len);
        _ = c.close(wfd);
    }
    return n;
}

/// Appends `<session>` or `<session> <value>` to `<dir>/<name>`.
fn record(a: std.mem.Allocator, dir: []const u8, name: []const u8, session: []const u8, value: ?[]const u8) void {
    const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0) catch c._exit(70);
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    const line = (if (value) |v| std.fmt.allocPrint(a, "{s} {s}\n", .{ session, v }) else std.fmt.allocPrint(a, "{s}\n", .{session})) catch c._exit(70);
    _ = c.write(fd, line.ptr, line.len);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var session: ?[]const u8 = null;
    var resumed = false;
    var script_text: []const u8 = "{}";
    var state_dir: ?[]const u8 = null;
    var writable: std.ArrayList([]const u8) = .empty;
    var permission_mode: ?[]const u8 = null;
    var mcp_off: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--session")) {
            session = value;
        } else if (std.mem.eql(u8, flag, "--resume")) {
            session = value;
            resumed = true;
        } else if (std.mem.eql(u8, flag, "--script")) {
            script_text = value;
        } else if (std.mem.eql(u8, flag, "--state")) {
            state_dir = value;
        } else if (std.mem.eql(u8, flag, "--writable")) {
            try writable.append(a, value);
        } else if (std.mem.eql(u8, flag, "--permission-mode")) {
            permission_mode = value;
        } else if (std.mem.eql(u8, flag, "--mcp-off")) {
            try mcp_off.append(a, value);
        }
    }
    if (permission_mode) |m| if (state_dir) |dir| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/modes", .{dir}, 0);
        const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd >= 0) {
            const line = try std.fmt.allocPrint(a, "{s} {s}\n", .{ session orelse "", m });
            _ = c.write(fd, line.ptr, line.len);
            _ = c.close(fd);
        }
    };
    if (state_dir) |dir| for (mcp_off.items) |m| record(a, dir, "mcp_off", session orelse "", m);
    const script = std.json.parseFromSliceLeaky(std.json.Value, a, script_text, .{}) catch {
        writeAll("{\"t\":\"fatal\",\"error\":\"bad --script\"}\n");
        c._exit(2);
    };
    if (resumed) if (state_dir) |dir| {
        const limit = int(script, "crash_on_resume") orelse 0;
        if (countResume(a, dir) <= limit) c._exit(3);
    };
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onInterrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);

    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else "";
    var fake: Fake = .{ .a = a, .script = script, .session = session orelse "fake-session", .cwd = cwd, .writable = writable.items, .state_dir = state_dir };
    // The script's MCP servers, without the ones turned off.
    var servers: ?[]const []const u8 = null;
    if (script.object.get("mcp_servers")) |list| if (list == .array) {
        var left: std.ArrayList([]const u8) = .empty;
        for (list.array.items) |item| {
            if (item != .string) continue;
            for (mcp_off.items) |off| {
                if (std.mem.eql(u8, off, item.string)) break;
            } else try left.append(a, item.string);
        }
        servers = left.items;
    };
    fake.emit(.{ .t = "init", .session = fake.session, .version = "0.1.0", .model = "fake-model", .cwd = cwd, .mcp = servers });
    fake.serve();
}
