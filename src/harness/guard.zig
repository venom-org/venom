//! The test guard: no venom test may start a real `claude` or
//! `codex`. Both vendor harnesses are enabled by default, so a test that
//! builds a daemon from default config would otherwise spend the user's
//! quota and depend on their sign-in.
//!
//! In test builds (`builtin.is_test`) two checks refuse loudly, with
//! `error.RealHarnessInTest` and a message on stderr:
//!
//! - `check` (from `harnesses.Runner.init`): a vendor adapter built from
//!   `harness.*` config must run an exe under a test's temp root
//!   (`.zig-cache/tmp/`) or a `testdata/` directory.
//! - `checkSpawn` (from `process.Process.spawn`): `argv[0]` must not be a
//!   vendor CLI (`claude`, `codex`) outside those roots, whoever built the
//!   argv.
//!
//! The opt-in end-to-end tests are the only way past it: a vendor is let
//! through when one of its `opt_in` variables is `1` (`VENOM_CLAUDE_E2E`,
//! `VENOM_CODEX_E2E`, or `VENOM_MCP_E2E` for both). Outside test builds
//! both checks compile to nothing.
const std = @import("std");
const builtin = @import("builtin");

pub const Vendor = struct {
    /// The CLI's executable name.
    exe: []const u8,
    /// The harness id, for messages.
    harness: []const u8,
    /// Environment variables that opt a test run into the real CLI.
    opt_in: []const []const u8,
};

pub const claude: Vendor = .{ .exe = "claude", .harness = "claude-code", .opt_in = &.{ "VENOM_CLAUDE_E2E", "VENOM_MCP_E2E" } };
pub const codex: Vendor = .{ .exe = "codex", .harness = "codex", .opt_in = &.{ "VENOM_CODEX_E2E", "VENOM_MCP_E2E" } };
pub const vendors = [_]Vendor{ claude, codex };

/// Path fragments a test's own executables live under: `testing.tmpDir`
/// (`.zig-cache/tmp/<random>`) and the repo's `testdata/` directories.
/// Tests of the guard itself set this so a deliberate refusal does not
/// print (zig build shows any test stderr as a failed command).
pub var quiet: bool = false;

const roots = [_][]const u8{ ".zig-cache/tmp/", "testdata/" };

pub fn underTestRoot(exe: []const u8) bool {
    for (roots) |r| if (std.mem.indexOf(u8, exe, r) != null) return true;
    return false;
}

/// The vendor whose CLI `exe` names (by basename), if any.
pub fn vendorOf(exe: []const u8) ?Vendor {
    const base = std.fs.path.basename(exe);
    for (vendors) |v| if (std.mem.eql(u8, base, v.exe)) return v;
    return null;
}

/// One of `v`'s opt-in variables is `1`.
pub fn optedIn(v: Vendor) bool {
    for (v.opt_in) |name| {
        var buf: [32:0]u8 = undefined;
        if (name.len >= buf.len) continue;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const value = std.c.getenv(&buf) orelse continue;
        if (std.mem.eql(u8, std.mem.sliceTo(value, 0), "1")) return true;
    }
    return false;
}

/// What `check` decides, without the build or environment: whether a
/// vendor adapter may run `exe`.
pub fn allowed(exe: []const u8, opted_in: bool) bool {
    return opted_in or underTestRoot(exe);
}

/// What `checkSpawn` decides: whether a test may exec `argv0`.
pub fn spawnAllowed(argv0: []const u8, opted_in: fn (Vendor) bool) bool {
    const v = vendorOf(argv0) orelse return true;
    return underTestRoot(argv0) or opted_in(v);
}

/// In a test build, refuses `v`'s adapter running `exe`, unless `exe` is
/// under a test root or the test run opted in.
pub fn check(v: Vendor, exe: []const u8) error{RealHarnessInTest}!void {
    if (!builtin.is_test) return;
    if (allowed(exe, optedIn(v))) return;
    if (!quiet) std.debug.print(
        \\
        \\test guard: refusing to register the real {s} harness (exe '{s}') in a test.
        \\  Tests must not start a real `{s}`. Start the test daemon from config with the vendor
        \\  harnesses off (`harnesses.test_vendors_off`), or point harness.{s}.path at a fake
        \\  under the test's temp dir. Opt-in e2e runs set {s}=1.
        \\
    , .{ v.harness, exe, v.exe, if (std.mem.eql(u8, v.exe, "claude")) "claude_code" else "codex", v.opt_in[0] });
    return error.RealHarnessInTest;
}

/// In a test build, refuses to exec a vendor CLI outside the test roots,
/// unless the test run opted in.
pub fn checkSpawn(argv0: []const u8) error{RealHarnessInTest}!void {
    if (!builtin.is_test) return;
    if (spawnAllowed(argv0, optedIn)) return;
    const v = vendorOf(argv0).?;
    if (!quiet) std.debug.print(
        \\
        \\test guard: refusing to start the real `{s}` ('{s}') in a test.
        \\  Point the adapter at a fake harness under the test's temp dir. Opt-in e2e runs set {s}=1.
        \\
    , .{ v.exe, argv0, v.opt_in[0] });
    return error.RealHarnessInTest;
}

const testing = std.testing;

fn never(_: Vendor) bool {
    return false;
}

fn always(_: Vendor) bool {
    return true;
}

test "vendor CLIs are refused outside the test roots unless opted in" {
    try testing.expect(!allowed("claude", false));
    try testing.expect(!allowed("/usr/local/bin/codex", false));
    try testing.expect(!allowed("/opt/codex", false));
    try testing.expect(allowed("/home/u/venom/.zig-cache/tmp/abc/codex", false));
    try testing.expect(allowed("/home/u/venom/src/testdata/fake_mcp_harness.py", false));
    try testing.expect(allowed("claude", true));

    try testing.expect(!spawnAllowed("claude", never));
    try testing.expect(!spawnAllowed("/usr/bin/codex", never));
    try testing.expect(spawnAllowed("codex", always));
    try testing.expect(spawnAllowed("/x/.zig-cache/tmp/abc/claude", never));
    // Anything that is not a vendor CLI runs: the fake harness, python3, sh.
    try testing.expect(spawnAllowed("python3", never));
    try testing.expect(spawnAllowed("/x/zig-out/venom-fake-harness", never));
    try testing.expect(spawnAllowed("claude-wrapper", never));
}
