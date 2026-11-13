//! `venom agent hook --agent <id>`:
//! the command Claude Code's hooks and Codex's `notify` run while they have an
//! agent in their own TUI. It takes the report's JSON from stdin (Claude Code)
//! or `--input` (Codex, which appends it to the command line) and forwards it
//! to the daemon as `harness.hook`, on a connection of its own.
//!
//! It presents no token, even one it inherited: the daemon goes by its
//! process ancestry, accepting only a process inside
//! the agent's take-over split. In own mode no pane principal exists: the
//! caller is `unknown` with `read`, and the check on its chain is the only
//! thing that lets it report. So anything in the split can forge a report,
//! the model's Bash included; this attention is never trusted.
//!
//! A hook must not get in the harness's way. Success prints nothing (Claude
//! Code reads a `Stop` hook's stdout as instructions), everything is bounded
//! in time, and every failure, a refusal included, is exit 1 with the error
//! code on stderr: exit 2 would tell Claude Code to block what the hook
//! reports on, which is why this does not use venom's usual exit codes.
//! Diagnostics only: the TUI still works without attention.
const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const c = std.c;
const Value = std.json.Value;

pub const local_commands = .{.{
    .name = "agent.hook",
    .summary = "Report a harness hook for a handed-over agent, read from stdin or --input (its hooks and notify program run this inside the take-over split; not for people)",
    .params = .{
        .{ .name = "agent", .summary = "Agent ID", .type = .{ .kind = .string }, .required = true },
        .{ .name = "input", .summary = "The report's JSON, instead of stdin", .type = .{ .kind = .string } },
    },
    .result = .{ .kind = .object, .fields = .{} },
}};

const max_input = 1024 * 1024;
const stdin_ms = 2_000;
const daemon_ms = 3_000;

/// Reads `fd` to its end, within `stdin_ms`. A hook's JSON is small and
/// written at once; on a terminal this gives up instead of hanging.
fn readInput(gpa: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const deadline = monotonicMs() + stdin_ms;
    while (true) {
        const left = deadline - monotonicMs();
        if (left <= 0) return error.Timeout;
        var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        const ready = c.poll(&fds, 1, @intCast(left));
        if (ready < 0) {
            if (c.errno(ready) == .INTR) continue;
            return error.ReadFailed;
        }
        if (ready == 0) return error.Timeout;
        var chunk: [16 * 1024]u8 = undefined;
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return out.toOwnedSlice(gpa);
        if (out.items.len + @as(usize, @intCast(n)) > max_input) return error.TooLarge;
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
}

fn monotonicMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Forwards the hook; empty on success, else the error to print.
fn forward(gpa: std.mem.Allocator, a: std.mem.Allocator, path: proto.SocketOptions, agent: []const u8, input: []const u8) ![]const u8 {
    var client = proto.Client.init(gpa, .{
        .tool = "venom",
        .path = path,
        .hello = .{ .identity = .{ .name = "venom-agent-hook", .version = "0.0.0" }, .caps = &.{} },
    }) catch |err| return std.fmt.allocPrint(a, "unavailable.daemon: {s}", .{@errorName(err)});
    defer client.deinit();
    const deadline = monotonicMs() + daemon_ms;
    while (!(client.pollHello(50) catch |err| return std.fmt.allocPrint(a, "unavailable.daemon: {s}", .{@errorName(err)}))) {
        if (monotonicMs() > deadline) return "unavailable.daemon: no hello";
    }
    client.request(@as(i64, 2), "harness.hook", .{ .agent = agent, .input = input }) catch |err| return std.fmt.allocPrint(a, "unavailable.daemon: {s}", .{@errorName(err)});
    while (monotonicMs() <= deadline) {
        const msg = (client.receive(50) catch |err| return std.fmt.allocPrint(a, "unavailable.daemon: {s}", .{@errorName(err)})) orelse continue;
        if (msg != .ndjson) return "internal: unexpected frame from the daemon";
        var response = proto.Response.parse(gpa, msg.ndjson) catch return "internal: invalid response from the daemon";
        defer response.deinit();
        return switch (response.body) {
            .item => continue,
            .@"error" => |e| std.fmt.allocPrint(a, "{s}: {s}", .{ e.code, e.message }),
            .ok => "",
        };
    }
    return "unavailable.daemon: no answer";
}

/// `environ` without `VENOM_TOKEN`, which `proto.Client` would present. An
/// inherited token (a plain take-over from a shell that has one) must not
/// change who the hook is: it goes by its ancestry.
fn withoutToken(a: std.mem.Allocator, environ: std.process.Environ) !std.process.Environ {
    const old = environ.block.view().slice;
    const slice = try a.allocSentinel(?[*:0]const u8, old.len, null);
    var n: usize = 0;
    for (old) |entry| {
        if (std.mem.startsWith(u8, std.mem.span(entry), "VENOM_TOKEN=")) continue;
        slice[n] = entry;
        n += 1;
    }
    slice[n] = null;
    return .{ .block = .{ .slice = slice[0..n :null] } };
}

/// The local handler for `agent.hook`.
pub fn serve(gpa: std.mem.Allocator, ctx: cli.Local.Context) !cli.Local.Outcome {
    const a = ctx.allocator;
    const agent: []const u8 = blk: {
        if (ctx.params == .object) if (ctx.params.object.get("agent")) |v| if (v == .string) break :blk v.string;
        return fail(ctx, "invalid_params: --agent is required");
    };
    const given: ?[]const u8 = if (ctx.params == .object) (if (ctx.params.object.get("input")) |v| (if (v == .string) v.string else null) else null) else null;
    const input = if (given) |g| try gpa.dupe(u8, g) else readInput(gpa, 0) catch |err| return fail(ctx, try std.fmt.allocPrint(a, "invalid_params.input: {s}", .{@errorName(err)}));
    defer gpa.free(input);
    var path = ctx.path;
    if (path.environ) |environ| path.environ = try withoutToken(a, environ);
    const why = try forward(gpa, a, path, agent, input);
    if (why.len > 0) return fail(ctx, why);
    return .{ .status = 0 };
}

fn fail(ctx: cli.Local.Context, why: []const u8) !cli.Local.Outcome {
    try ctx.stderr.print("venom agent hook: {s}\n", .{why});
    try ctx.stderr.flush();
    return .{ .status = 1 };
}
