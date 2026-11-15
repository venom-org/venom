const std = @import("std");

/// venom-std modules the daemon imports.
const shared_modules = [_][]const u8{ "proto", "cli", "cfg", "log", "supervisor", "xdg", "iface" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("venom_std", .{ .target = target, .optimize = optimize });
    // venom-term (`../venom-term`) draws the TUI (`venom`, `venom agent view`).
    // Its widgets render into a Surface, so the TUI's tests run
    // headless; the binary still serves and runs every verb without a TTY.
    const term = b.dependency("venom_term", .{ .target = target, .optimize = optimize });

    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    inline for (shared_modules) |name| root.addImport(name, shared.module(name));
    root.addImport("venom-term", term.module("venom-term"));

    // One binary: the daemon (`venom serve`) and its CLI.
    const exe = b.addExecutable(.{ .name = "venom", .root_module = root });
    b.installArtifact(exe);

    // The scripted fake harness: a real child process for tests,
    // so no vendor CLI is needed. Built for tests only, never installed.
    const fake = b.addExecutable(.{ .name = "venom-fake-harness", .root_module = b.createModule(.{ .root_source_file = b.path("src/harness/fake_main.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    const test_options = b.addOptions();
    test_options.addOptionPath("fake_harness", fake.getEmittedBin());
    // venom's own binary, as the `venom mcp` server agents get.
    test_options.addOptionPath("venom_exe", exe.getEmittedBin());

    // Unit tests use std.testing.allocator, so leaks fail the build. Same
    // sources as the binary, plus the test-only build options.
    const test_root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    inline for (shared_modules) |name| test_root.addImport(name, shared.module(name));
    test_root.addImport("venom-term", term.module("venom-term"));
    test_root.addImport("build_options", test_options.createModule());
    const tests = b.addTest(.{ .root_module = test_root });
    b.default_step.dependOn(&tests.step);
    const unit_step = b.step("test-unit", "Run unit and leak-checked tests");
    unit_step.dependOn(&b.addRunArtifact(tests).step);
    const test_step = b.step("test", "Run unit tests and the venom-std agent-contract conformance suite");
    test_step.dependOn(unit_step);

    // Agent-contract conformance: venom-std's packaged suite against venom.
    const conformance = @import("venom_std").addConformance(b, .{ .suite = shared.path("conformance/agent_contract.py"), .exe = exe, .profile = b.path("conformance/venom.json") });
    // `doctor` runs each enabled harness's status and protocol commands,
    // and the suite wants it green: fakes come first on its PATH,
    // so it never reaches a real claude or codex, installed or not.
    const fakes = b.pathResolve(&.{ b.fmt("{f}", .{b.root}), "src/testdata/harness-bin" });
    conformance.setEnvironmentVariable("PATH", if (b.graph.environ_map.get("PATH")) |path| b.fmt("{s}:{s}", .{ fakes, path }) else fakes);
    // The suite isolates the XDG directories, not these: run from a venomx
    // pane, the daemon under test would reach the real venomx (doctor's
    // venomx.isolation check) and present the pane's credentials.
    for ([_][]const u8{ "VENOMX_SOCKET", "VENOMX_TOKEN", "VENOMX_PANE", "VENOMX_PRINCIPAL", "VENOM_SOCKET", "VENOM_TOKEN", "VENOM_PRINCIPAL", "VENOM_AGENT" }) |name| conformance.removeEnvironmentVariable(name);
    b.step("test-conformance", "Run the venom-std agent-contract conformance suite against venom").dependOn(&conformance.step);
    test_step.dependOn(&conformance.step);

    // The end-to-end demo: this build's `venom serve` runs 3 agents
    // (claude-code, codex, claude-code) on 3 worktrees, each approved with
    // `venom inbox answer`. The harnesses are fakes driven by the real
    // adapters; `scripts/demo.py --real` runs the real claude and codex.
    const demo = b.addSystemCommand(&.{ "python3", "-I" });
    demo.addFileArg(b.path("scripts/demo.py"));
    demo.addArg("--venom");
    demo.addArtifactArg(exe);
    demo.addFileInput(b.path("src/testdata/fake_mcp_harness.py"));
    demo.has_side_effects = true;
    demo.expectExitCode(0);
    b.step("test-demo", "Run the end-to-end demo (3 agents, 3 worktrees, approved from the CLI) against fake harnesses").dependOn(&demo.step);
    test_step.dependOn(&demo.step);

    // `doctor --json` and `harness list --json` from this build's
    // daemon, with fake harnesses on a temp PATH.
    const discovery = b.addSystemCommand(&.{ "python3", "-I" });
    discovery.addFileArg(b.path("scripts/harness_discovery_test.py"));
    discovery.addArg("--venom");
    discovery.addArtifactArg(exe);
    discovery.addArg("--fakes");
    discovery.addDirectoryArg(b.path("src/testdata/harness-bin"));
    discovery.has_side_effects = true;
    discovery.expectExitCode(0);
    b.step("test-harness-discovery", "Run doctor and harness list against fake harnesses on a temp PATH").dependOn(&discovery.step);
    test_step.dependOn(&discovery.step);

    // The subreaper's orphans against a real `venom serve`.
    const orphan_reap = b.addSystemCommand(&.{ "python3", "-I" });
    orphan_reap.addFileArg(b.path("scripts/orphan_reap_test.py"));
    orphan_reap.addArg("--venom");
    orphan_reap.addArtifactArg(exe);
    orphan_reap.addFileInput(b.path("src/testdata/fake_mcp_harness.py"));
    orphan_reap.has_side_effects = true;
    orphan_reap.expectExitCode(0);
    b.step("test-orphan-reap", "Run a double-forked orphan against a real venom serve").dependOn(&orphan_reap.step);
    test_step.dependOn(&orphan_reap.step);

    // `ui.chrome` end to end. Needs a built `../venomx`, which venom
    // does not depend on to build, so it is not part of `zig build test`.
    const host_demo = b.addSystemCommand(&.{ "python3", "scripts/host_demo.py", "--venom" });
    host_demo.addArtifactArg(exe);
    const venomx_path = b.option([]const u8, "venomx", "The venomx binary for test-host (default ../venomx/zig-out/bin/venomx; a stale build fails)");
    if (venomx_path) |venomx| host_demo.addArgs(&.{ "--venomx", venomx });
    host_demo.has_side_effects = true;
    host_demo.expectExitCode(0);
    const test_host = b.step("test-host", "Run own and host chrome modes with two agents against a current venomx (-Dvenomx=<path>)");
    test_host.dependOn(&host_demo.step);

    // The owner-file chain from a real agent process,
    // with throwaway daemons. Part of test-host: it needs the same venomx.
    const owner_chain = b.addSystemCommand(&.{ "python3", "scripts/owner_chain_test.py", "--venom" });
    owner_chain.addArtifactArg(exe);
    if (venomx_path) |venomx| owner_chain.addArgs(&.{ "--venomx", venomx });
    owner_chain.has_side_effects = true;
    owner_chain.expectExitCode(0);
    test_host.dependOn(&owner_chain.step);
    const test_owner_chain = b.step("test-owner-chain", "Run the owner-file chain from an agent process against a current venomx (-Dvenomx=<path>)");
    test_owner_chain.dependOn(&owner_chain.step);

    // Escalation against a real venomx with the clock injected. The
    // same test skips itself in `zig build test`, which has no venomx.
    const escalation_tests = b.addTest(.{ .root_module = test_root, .filters = &.{"escalation against a real venomx"} });
    const run_escalation = b.addRunArtifact(escalation_tests);
    run_escalation.setEnvironmentVariable("VENOM_TEST_VENOMX", b.pathResolve(&.{ b.fmt("{f}", .{b.root}), venomx_path orelse "../venomx/zig-out/bin/venomx" }));
    run_escalation.has_side_effects = true;
    const test_escalation = b.step("test-escalation", "Run escalation against a current venomx with the clock injected (-Dvenomx=<path>)");
    test_escalation.dependOn(&run_escalation.step);
    test_host.dependOn(test_escalation);
}
