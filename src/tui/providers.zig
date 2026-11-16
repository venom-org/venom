//! The `providers` config value as the TUI reads and edits it: parsed from
//! the ZON `config get` renders, written back as ZON for `config set`, and
//! the harness's own sign-in command for a provider. The daemon validates
//! whatever is sent.
const std = @import("std");
const config = @import("../config.zig");
const Provider = config.Provider;
const Allocator = std.mem.Allocator;

/// The providers in `zon` (a `providers` value); empty when it does not parse.
pub fn parse(a: Allocator, zon: ?[]const u8) []const Provider {
    const text = zon orelse return &.{};
    const source = a.dupeSentinel(u8, text, 0) catch return &.{};
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice([]const Provider, .{ .gpa = a, .arena = a, .source = source, .diagnostics = &diag, .ignore_unknown_fields = true }) catch &.{};
}

/// `list` as one line of ZON, every field written.
pub fn serialize(a: Allocator, list: []const Provider) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const wr = &out.writer;
    try wr.writeAll(".{");
    for (list, 0..) |p, i| {
        if (i > 0) try wr.writeAll(",");
        try wr.writeAll(".{.name=");
        try str(wr, p.name);
        try wr.print(",.harness=.{s},.home=", .{@tagName(p.harness)});
        try optStr(wr, p.home);
        try wr.writeAll(",.model=");
        try optStr(wr, p.model);
        try wr.writeAll(",.mode=");
        if (p.mode) |m| try wr.print(".{s}", .{@tagName(m)}) else try wr.writeAll("null");
        try wr.writeAll("}");
    }
    try wr.writeAll("}");
    return out.written();
}

fn str(wr: *std.Io.Writer, s: []const u8) !void {
    std.zon.stringify.serialize(s, .{ .whitespace = false }, wr) catch return error.OutOfMemory;
}

fn optStr(wr: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |x| try str(wr, x) else try wr.writeAll("null");
}

/// The harness id agents carry for `h`.
pub fn harnessName(h: config.Harness) []const u8 {
    return switch (h) {
        .claude_code => "claude-code",
        .codex => "codex",
    };
}

/// A permission mode a provider of a harness can default to, in the
/// harness's own words. `mode` null: `agents.mode`.
pub const ModeChoice = struct { mode: ?config.Mode, label: []const u8, help: []const u8, risky: bool = false };

const unset: ModeChoice = .{ .mode = null, .label = "venom's default", .help = "agents.mode in effect when the agent starts." };

/// The modes the harness's adapter can run, first `unset`.
pub fn modeChoices(h: config.Harness) []const ModeChoice {
    return switch (h) {
        .claude_code => &.{
            unset,
            .{ .mode = .ask, .label = "default", .help = "Asks you to approve each file edit, shell command and network call unless your settings already allow it." },
            .{ .mode = .accept_edits, .label = "acceptEdits", .help = "Approves file edits automatically. Shell commands and other actions still ask." },
            .{ .mode = .plan, .label = "plan", .help = "Read-only. It looks around and writes a plan, and you approve it before anything changes." },
            .{ .mode = .auto, .label = "auto", .help = "A classifier approves routine, low-risk actions. Risky or hard-to-undo actions still come to you." },
            .{ .mode = .bypass_permissions, .label = "bypassPermissions", .help = "Approves everything with no prompts, venom's approvals included. Only in sandboxed or throwaway environments.", .risky = true },
        },
        .codex => &.{
            unset,
            .{ .mode = .ask, .label = "default", .help = "Works in the workspace sandbox; asks before anything outside it." },
            .{ .mode = .plan, .label = "read-only", .help = "Read-only sandbox: nothing is written unless you allow it." },
        },
    };
}

/// How the provider list names `mode` for harness `h`.
pub fn modeLabel(h: config.Harness, mode: ?config.Mode) []const u8 {
    for (modeChoices(h)) |c| if (c.mode == mode) return c.label;
    return if (mode) |m| @tagName(m) else unset.label;
}

/// The harness's own sign-in command for this provider's login, as a shell
/// line: `CLAUDE_CONFIG_DIR=~/.claude_personal claude auth login`.
pub fn signInCommand(a: Allocator, p: Provider) ![]const u8 {
    const cmd: []const u8 = switch (p.harness) {
        .claude_code => "claude auth login",
        .codex => "codex login",
    };
    const home = p.home orelse return cmd;
    return std.fmt.allocPrint(a, "{s}={s} {s}", .{ Provider.homeEnv(p.harness), home, cmd });
}

/// A name no provider in `list` has: `base`, else `base-2`, `base-3`…
pub fn freeName(a: Allocator, list: []const Provider, base: []const u8) ![]const u8 {
    if (config.findProvider(list, base) == null) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const name = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
        if (config.findProvider(list, name) == null) return name;
    }
}

const testing = std.testing;

test "providers: serialize and parse round-trip; sign-in commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]Provider{
        .{ .name = "work", .harness = .claude_code },
        .{ .name = "personal", .harness = .claude_code, .home = "~/.claude_personal", .model = "opus", .mode = .accept_edits },
        .{ .name = "codex", .harness = .codex, .home = "~/.codex_work" },
    };
    const text = try serialize(a, &list);
    const back = parse(a, text);
    try testing.expectEqual(@as(usize, 3), back.len);
    try testing.expectEqualStrings("personal", back[1].name);
    try testing.expectEqualStrings("opus", back[1].model.?);
    try testing.expectEqual(config.Mode.accept_edits, back[1].mode.?);
    try testing.expectEqual(config.Harness.codex, back[2].harness);
    try testing.expectEqualStrings("claude auth login", try signInCommand(a, list[0]));
    try testing.expectEqualStrings("CLAUDE_CONFIG_DIR=~/.claude_personal claude auth login", try signInCommand(a, list[1]));
    try testing.expectEqualStrings("CODEX_HOME=~/.codex_work codex login", try signInCommand(a, list[2]));
    try testing.expectEqualStrings("codex-2", try freeName(a, &list, "codex"));
    try testing.expectEqual(@as(usize, 0), parse(a, ".{}").len);
    try testing.expectEqual(@as(usize, 0), parse(a, null).len);
}
