//! `git diff` for the pager (`d`): the same diff as
//! `venom agent diff`, read into memory. The TUI's loop waits for it, so it is
//! bounded in time and in size, and what is cut says so.
const std = @import("std");
const posix = std.posix;

/// Most of a diff anyone reads in a pager.
pub const max_bytes = 4 * 1024 * 1024;
/// The longest the TUI stops drawing for one folder.
pub const budget_ms = 2000;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Appends `git diff HEAD` of `folder` to `out`, with what git says on stderr
/// (not a repository, no commits yet).
pub fn capture(gpa: std.mem.Allocator, folder: []const u8, out: *std.ArrayList(u8)) !void {
    const z = try gpa.dupeSentinel(u8, folder, 0);
    defer gpa.free(z);
    var pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe2(&pipe, .{ .CLOEXEC = true }) != 0) return out.appendSlice(gpa, "(no pipe for git)\n");
    const pid = std.c.fork();
    if (pid == 0) {
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (devnull >= 0) _ = std.c.dup2(devnull, 0);
        _ = std.c.dup2(pipe[1], 1);
        _ = std.c.dup2(pipe[1], 2);
        const argv = [_:null]?[*:0]const u8{ "git", "-C", z, "--no-pager", "diff", "--no-color", "--no-ext-diff", "HEAD" };
        _ = execvp("git", &argv);
        std.c._exit(127);
    }
    _ = std.c.close(pipe[1]);
    defer _ = std.c.close(pipe[0]);
    if (pid < 0) return out.appendSlice(gpa, "(could not start git)\n");
    const until = nowMs() + budget_ms;
    const start = out.items.len;
    const cut: ?[]const u8 = while (true) {
        if (out.items.len - start >= max_bytes) break "too long";
        const left = until - nowMs();
        if (left <= 0) break "git took too long";
        var fds = [_]posix.pollfd{.{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&fds, @intCast(left)) catch |err| {
            if (err == error.Interrupted) continue;
            break "git took too long";
        };
        if (fds[0].revents == 0) continue;
        var buf: [64 * 1024]u8 = undefined;
        const n = std.c.read(pipe[0], &buf, buf.len);
        if (n == 0) break null;
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            break null;
        }
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    };
    if (cut != null) _ = std.c.kill(pid, .KILL);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    if (cut) |why| try out.print(gpa, "\n… cut: {s}\n", .{why});
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

const testing = std.testing;

fn git(dir: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t" });
    try argv.appendSlice(testing.allocator, args);
    var child = try std.process.spawn(testing.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    _ = try child.wait(testing.io);
}

test "capture: a change, no change, and what git says outside a repository" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    // Under the test's tmp folder, which may itself be in a repository, so
    // only that git spoke is certain before `init`.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "one\n" });
    try git(dir, &.{"init"});
    try capture(testing.allocator, dir, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "HEAD") != null);

    out.clearRetainingCapacity();
    try git(dir, &.{ "add", "f.txt" });
    try git(dir, &.{ "commit", "-m", "x" });
    try capture(testing.allocator, dir, &out);
    try testing.expectEqualStrings("", out.items);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "two\n" });
    try capture(testing.allocator, dir, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "+two") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b") == null);
}
