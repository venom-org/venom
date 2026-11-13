//! Tests for safe_git.zig. Each filter test first proves its
//! fixture: plain git does run the repo's command there, so the marker's
//! absence after `safe_git.run` means something.
const std = @import("std");
const supervisor = @import("supervisor");
const safe_git = @import("safe_git.zig");
const iso = @import("isolation_tests.zig");
const testing = std.testing;
const ta = testing.allocator;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Dir = struct {
    tmp: testing.TmpDir,
    path: []const u8,

    fn init(a: std.mem.Allocator) !Dir {
        var t = testing.tmpDir(.{});
        errdefer t.cleanup();
        const real = try t.dir.realPathFileAlloc(testing.io, ".", a);
        defer a.free(real);
        const path = try a.dupe(u8, real);
        return .{ .tmp = t, .path = path };
    }

    fn deinit(self: *Dir, a: std.mem.Allocator) void {
        a.free(self.path);
        self.tmp.cleanup();
    }

    fn sh(self: *Dir, a: std.mem.Allocator, script: []const u8) !void {
        const r = try std.process.run(a, testing.io, .{ .argv = &.{ "sh", "-ec", script }, .cwd = .{ .path = self.path } });
        defer a.free(r.stdout);
        defer a.free(r.stderr);
        if (!r.term.success()) {
            std.debug.print("{s}\n", .{r.stderr});
            return error.ScriptFailed;
        }
    }

    fn has(self: *Dir, a: std.mem.Allocator, name: []const u8) bool {
        const p = std.fmt.allocPrint(a, "{s}/{s}", .{ self.path, name }) catch return false;
        defer a.free(p);
        return iso.exists(p);
    }
};

const setup =
    \\git init -q repo && cd repo
    \\git config user.email a@b && git config user.name n && git config commit.gpgsign false
    \\echo hi > f && git add f && git commit -qm i
;

fn gitAvailable() !void {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    if (!iso.hasGit(arena.allocator())) return error.SkipZigTest;
}

/// Plain `git status`, as the daemon used to run it.
fn plainStatus(a: std.mem.Allocator, dir: []const u8) !void {
    const r = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", dir, "status", "--porcelain", "--ignore-submodules=none" } });
    a.free(r.stdout);
    a.free(r.stderr);
}

/// A repo whose tracked files `filter_config` (shell lines run in it) puts
/// under filters; `f` is stat-dirty. Proves plain git runs one of the
/// commands (`marker` appears), then that `safe_git.run` does not.
fn expectNoFilter(filter_config: []const u8, marker: []const u8) !void {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a, "{s}\n{s}\necho '* filter=x' > .git/info/attributes\ntouch f", .{ setup, filter_config }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    const ran = try std.fmt.allocPrint(a, "{s}/{s}", .{ d.path, marker });
    _ = ran;

    // The fixture works: git itself runs the command on this tree.
    try plainStatus(a, repo);
    try testing.expect(d.has(a, marker));
    try d.sh(a, try std.fmt.allocPrint(a, "rm -f {s}; touch repo/f", .{marker}));

    const r = try safe_git.run(a, testing.io, repo, &.{ "status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none" }, .{ .timeout_ms = 10_000 });
    try testing.expect(r.ok);
    try testing.expect(!d.has(a, marker));
}

test "safe_git: status never runs a repo's clean filter" {
    // Clean only: nothing else could be the one that is neutralised.
    try expectNoFilter("git config filter.x.clean 'touch $PWD/../clean-ran; cat'", "clean-ran");
}

test "safe_git: status never runs a repo's process filter" {
    try expectNoFilter("git config filter.x.process 'touch $PWD/../process-ran'", "process-ran");
}

test "safe_git: a required filter does not make status fail, and does not run" {
    // git-lfs sets required=true globally; emptied, git would die on it.
    try expectNoFilter("git config filter.x.clean 'touch $PWD/../clean-ran; cat'\ngit config filter.x.required true", "clean-ran");
}

test "safe_git: a submodule's own clean filter does not run either" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a,
        \\git init -q sub && cd sub
        \\git config user.email a@b && git config user.name n && git config commit.gpgsign false
        \\echo s > g && git add g && git commit -qm s && cd ..
        \\{s}
        \\git -c protocol.file.allow=always submodule add -q ../sub sm
        \\git commit -qm sm
        \\cd sm
        \\git config filter.z.clean 'touch {s}/sub-ran; cat'
        \\mkdir -p "$(git rev-parse --git-dir)/info"
        \\echo '* filter=z' > "$(git rev-parse --git-dir)/info/attributes"
        \\touch g
    , .{ setup, d.path }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});

    try plainStatus(a, repo);
    try testing.expect(d.has(a, "sub-ran"));
    try d.sh(a, "rm -f sub-ran; touch repo/sm/g");

    const r = try safe_git.run(a, testing.io, repo, &.{ "status", "--porcelain", "--ignore-submodules=none" }, .{ .timeout_ms = 10_000 });
    try testing.expect(r.ok);
    try testing.expect(!d.has(a, "sub-ran"));
}

test "safe_git: an index the scan cannot read fails the command, it does not skip the submodules" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, setup);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    const ok = try safe_git.run(a, testing.io, repo, &.{"status"}, .{ .timeout_ms = 10_000 });
    try testing.expect(ok.ok);
    try d.sh(a, "echo garbage > repo/.git/index");
    const r = try safe_git.run(a, testing.io, repo, &.{"status"}, .{ .timeout_ms = 10_000 });
    try testing.expect(!r.ok);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "git:") != null);
    // A command that reads no files of the tree is not held up by the scan.
    const refs = try safe_git.run(a, testing.io, repo, &.{"for-each-ref"}, .{ .timeout_ms = 10_000, .reads_tree = false });
    try testing.expect(refs.ok);
}

test "safe_git: a big index is streamed, not capped" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a,
        \\git init -q sub && cd sub
        \\git config user.email a@b && git config user.name n && git config commit.gpgsign false
        \\echo s > g && git add g && git commit -qm s && cd ..
        \\{s}
        \\git -c protocol.file.allow=always submodule add -q ../sub sm
        \\i=0; while [ $i -lt 3000 ]; do printf "100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 0\tpad/%0200d\n" $i; i=$((i+1)); done | git update-index --index-info
        \\cd sm
        \\git config filter.z.clean 'touch {s}/sub-ran; cat'
        \\mkdir -p "$(git rev-parse --git-dir)/info"
        \\echo '* filter=z' > "$(git rev-parse --git-dir)/info/attributes"
        \\touch g
    , .{ setup, d.path }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    const r = try safe_git.run(a, testing.io, repo, &.{ "status", "--porcelain", "--ignore-submodules=none" }, .{ .timeout_ms = 30_000 });
    try testing.expect(r.ok);
    try testing.expect(!d.has(a, "sub-ran"));
}

test "safe_git: hooks, fsmonitor and attributes file come from the pins, not the repo" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a,
        \\{s}
        \\git config core.hooksPath /nonexistent
        \\git config core.fsmonitor 'touch {s}/fsmonitor-ran; false'
        \\git config diff.ignoreSubmodules all
        \\git config gc.auto 1
    , .{ setup, d.path }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    for ([_][2][]const u8{
        .{ "core.hooksPath", "/dev/null" },
        .{ "core.fsmonitor", "false" },
        .{ "core.attributesFile", "/dev/null" },
        .{ "diff.ignoreSubmodules", "none" },
        .{ "gc.auto", "0" },
    }) |kv| {
        const r = try safe_git.run(a, testing.io, repo, &.{ "config", "--get", kv[0] }, .{ .timeout_ms = 10_000 });
        try testing.expect(r.ok);
        try testing.expectEqualStrings(kv[1], std.mem.trimEnd(u8, r.stdout, "\n"));
    }
    const s = try safe_git.run(a, testing.io, repo, &.{ "status", "--porcelain" }, .{ .timeout_ms = 10_000 });
    try testing.expect(s.ok);
    try testing.expect(!d.has(a, "fsmonitor-ran"));
}

test "safe_git: the deadline is absolute: a child that keeps writing is cut off" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, setup);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    // An alias is a shell command of the test's own, not the repo's. It
    // writes a byte every 100 ms, which restarted an idle timeout each time.
    const trickle: []const []const u8 = &.{ "-c", "alias.trickle=!while :; do printf x >&2; sleep 0.1; done" };
    const t0 = supervisor.monotonicMs();
    const r = try safe_git.run(a, testing.io, repo, &.{"trickle"}, .{ .timeout_ms = 400, .config = trickle });
    const took = supervisor.monotonicMs() - t0;
    try testing.expect(!r.ok);
    try testing.expect(took < 2500);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Timeout") != null);

    // The caller's own limit cuts it short too.
    const t1 = supervisor.monotonicMs();
    const r2 = try safe_git.run(a, testing.io, repo, &.{"trickle"}, .{ .timeout_ms = 60_000, .until_ms = t1 + 300, .config = trickle });
    try testing.expect(!r2.ok);
    try testing.expect(supervisor.monotonicMs() - t1 < 2500);

    // Already past: not even started.
    const r3 = try safe_git.run(a, testing.io, repo, &.{"status"}, .{ .timeout_ms = 60_000, .until_ms = t1 - 1 });
    try testing.expect(!r3.ok);
}

test "safe_git: the daemon's GIT_* environment is not inherited" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a, "{s}\ngit config venom.probe real", .{setup}));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});

    const vars = [_][:0]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS", "GIT_EXTERNAL_DIFF", "GIT_INDEX_FILE" };
    defer for (vars) |v| {
        _ = unsetenv(v);
    };
    _ = setenv("GIT_DIR", "/nonexistent/.git", 1);
    _ = setenv("GIT_WORK_TREE", "/nonexistent", 1);
    _ = setenv("GIT_CONFIG_COUNT", "1", 1);
    _ = setenv("GIT_CONFIG_KEY_0", "venom.probe", 1);
    _ = setenv("GIT_CONFIG_VALUE_0", "injected", 1);
    _ = setenv("GIT_CONFIG_PARAMETERS", "'venom.probe=injected'", 1);
    _ = setenv("GIT_EXTERNAL_DIFF", "/bin/false", 1);
    _ = setenv("GIT_INDEX_FILE", "/nonexistent/index", 1);

    // The fixture works: given to git, these change its answer.
    var dirty = std.process.Environ.Map.init(a);
    try dirty.put("PATH", "/usr/bin:/bin");
    try dirty.put("GIT_CONFIG_COUNT", "1");
    try dirty.put("GIT_CONFIG_KEY_0", "venom.probe");
    try dirty.put("GIT_CONFIG_VALUE_0", "injected");
    const plain = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", repo, "config", "--get", "venom.probe" }, .environ_map = &dirty });
    try testing.expectEqualStrings("injected", std.mem.trimEnd(u8, plain.stdout, "\n"));

    var env = try safe_git.childEnv(a);
    defer env.deinit();
    for (vars) |v| try testing.expect(env.get(v) == null);
    try testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try testing.expect(env.get("PATH") != null);

    const r = try safe_git.run(a, testing.io, repo, &.{ "config", "--get", "venom.probe" }, .{ .timeout_ms = 10_000 });
    try testing.expect(r.ok);
    try testing.expectEqualStrings("real", std.mem.trimEnd(u8, r.stdout, "\n"));
    const top = try safe_git.run(a, testing.io, repo, &.{ "rev-parse", "--show-toplevel" }, .{ .timeout_ms = 10_000 });
    try testing.expect(top.ok);
    try testing.expectEqualStrings(repo, std.mem.trimEnd(u8, top.stdout, "\n"));
}

/// `url` is the origin; `config` shell lines set the repo's transport
/// command, which touches `marker`. Plain `git ls-remote` runs it; the
/// locked one does not.
fn expectNoTransportCommand(url: []const u8, config: []const u8) !void {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a,
        \\git init -q --bare origin.git
        \\printf '#!/bin/sh\ntouch {s}/transport-ran\nexec "$@"\n' > wrap && chmod +x wrap
        \\printf '#!/bin/sh\ntouch {s}/transport-ran\nexit 1\n' > fail && chmod +x fail
        \\{s}
        \\git remote add origin '{s}'
        \\{s}
    , .{ d.path, d.path, setup, url, config }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});

    const plain = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", repo, "ls-remote", "--heads", "origin" } });
    _ = plain;
    try testing.expect(d.has(a, "transport-ran"));
    try d.sh(a, "rm -f transport-ran");

    _ = try safe_git.lsRemoteHeads(a, testing.io, repo, "origin", .{ .timeout_ms = 10_000 });
    try testing.expect(!d.has(a, "transport-ran"));
}

test "safe_git: ls-remote ignores the repo's core.sshCommand" {
    try expectNoTransportCommand("ssh://localhost/x", "git config core.sshCommand \"$PWD/../fail\"");
}

test "safe_git: ls-remote ignores the repo's core.gitProxy" {
    try expectNoTransportCommand("git://127.0.0.1:9/x", "git config core.gitProxy \"$PWD/../fail\"");
}

test "safe_git: ls-remote ignores the repo's remote.<n>.uploadpack" {
    const url = "../origin.git";
    try expectNoTransportCommand(url, "git config remote.origin.uploadpack \"$PWD/../wrap git-upload-pack\"");
}

test "safe_git: ls-remote still lists the heads of a plain remote" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a, "git init -q --bare origin.git\n{s}\ngit remote add origin ../origin.git\ngit push -q origin HEAD:refs/heads/main", .{setup}));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    const r = try safe_git.lsRemoteHeads(a, testing.io, repo, "origin", .{ .timeout_ms = 10_000 });
    try testing.expect(r.ok);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "refs/heads/main") != null);
}

test "safe_git: ls-remote over http runs no credential helper or askpass of the repo" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    // A server that answers every request 401, on a port it picks.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/srv.py", .{d.path}), .data =
        \\import http.server
        \\class H(http.server.BaseHTTPRequestHandler):
        \\    def do_GET(s):
        \\        s.send_response(401); s.send_header("WWW-Authenticate", 'Basic realm="x"'); s.send_header("Content-Length", "0"); s.end_headers()
        \\    def log_message(*a): pass
        \\h = http.server.HTTPServer(("127.0.0.1", 0), H)
        \\print(h.server_port, flush=True)
        \\h.serve_forever()
        \\
    });
    d.sh(a, "python3 srv.py > port 2>/dev/null < /dev/null & echo $! > pid\nfor i in $(seq 50); do [ -s port ] && break; sleep 0.1; done\n[ -s port ]") catch return error.SkipZigTest;
    defer d.sh(a, "kill $(cat pid)") catch {};
    const port = std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/port", .{d.path}), a, .limited(64)), " \n");
    try d.sh(a, try std.fmt.allocPrint(a,
        \\printf '#!/bin/sh\ntouch {s}/askpass-ran\necho x\n' > ask && chmod +x ask
        \\{s}
        \\git remote add origin http://127.0.0.1:{s}/r.git
        \\git config credential.helper '!touch {s}/helper-ran; true'
        \\git config credential.http://127.0.0.1:{s}.helper '!touch {s}/url-helper-ran; true'
        \\git config core.askPass "$PWD/../ask"
    , .{ d.path, setup, port, d.path, port, d.path }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});

    // The fixture works: plain git runs all three when the server says 401.
    _ = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", repo, "ls-remote", "--heads", "origin" } });
    try testing.expect(d.has(a, "helper-ran"));
    try testing.expect(d.has(a, "url-helper-ran"));
    try testing.expect(d.has(a, "askpass-ran"));
    try d.sh(a, "rm -f helper-ran url-helper-ran askpass-ran");

    const r = try safe_git.lsRemoteHeads(a, testing.io, repo, "origin", .{ .timeout_ms = 10_000 });
    try testing.expect(!r.ok);
    try testing.expect(!d.has(a, "helper-ran"));
    try testing.expect(!d.has(a, "url-helper-ran"));
    try testing.expect(!d.has(a, "askpass-ran"));
}

test "safe_git: ls-remote reaches no remote helper through remote.<n>.vcs, whatever protocol.<x>.allow says" {
    try gitAvailable();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try Dir.init(ta);
    defer d.deinit(ta);
    try d.sh(a, try std.fmt.allocPrint(a,
        \\mkdir bin
        \\printf '#!/bin/sh\ntouch {s}/helper-ran\nexit 1\n' > bin/git-remote-evil && chmod +x bin/git-remote-evil
        \\{s}
        \\git remote add o ../x
        \\git config remote.o.vcs evil
        \\git config protocol.evil.allow always
    , .{ d.path, setup }));
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{d.path});
    // A stub helper on PATH, for the children of this test only.
    var env = std.process.Environ.Map.init(a);
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}/bin:/usr/bin:/bin", .{d.path}));
    _ = try std.process.run(a, testing.io, .{ .argv = &.{ "git", "-C", repo, "ls-remote", "o" }, .environ_map = &env });
    try testing.expect(d.has(a, "helper-ran"));
    try d.sh(a, "rm -f helper-ran");

    const old = std.c.getenv("PATH");
    const path = try std.fmt.allocPrintSentinel(a, "{s}/bin:{s}", .{ d.path, if (old) |o| std.mem.span(o) else "/usr/bin:/bin" }, 0);
    _ = setenv("PATH", path, 1);
    defer if (old) |o| {
        _ = setenv("PATH", o, 1);
    };
    _ = try safe_git.lsRemoteHeads(a, testing.io, repo, "o", .{ .timeout_ms = 10_000 });
    try testing.expect(!d.has(a, "helper-ran"));
}

test "safe_git: ls-remote ignores a url.<x>.insteadOf rewrite to a command" {
    // The repo allows ext:: itself, so only the lock keeps it out.
    try expectNoTransportCommand("https://rewrite.invalid/", "git config protocol.ext.allow always\ngit config \"url.ext::$PWD/../fail.insteadOf\" https://rewrite.invalid/");
}
