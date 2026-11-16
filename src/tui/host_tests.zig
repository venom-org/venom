//! `ui.chrome` modes: the control pane's requests, driven with
//! JSON. `scripts/host_demo.py` runs both modes against a real venomx.
const std = @import("std");
const testing = std.testing;
const term = @import("venom-term");
const App = @import("app.zig").App;
const view = @import("view.zig");
const host_mod = @import("host.zig");
const keys = @import("keys.zig");
const chord = term.chrome.keys;
const tests = @import("tests.zig");
const Host = host_mod.Host;
const Value = std.json.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    host: Host,

    fn init(self: *Fixture) !void {
        self.arena = .init(testing.allocator);
        self.app = .init(testing.allocator);
        self.host = try .init(testing.allocator, .{ .control = "p1", .exe = "/bin/venom", .socket = "/run/venom.sock" });
        self.app.host = &self.host;
        try tests.fixtureApp(&self.app, self.arena.allocator());
        try self.app.preselect("a1");
    }

    fn deinit(self: *Fixture) void {
        self.host.deinit();
        self.app.deinit();
        self.arena.deinit();
    }

    /// Takes the queued requests as parsed JSON.
    fn take(self: *Fixture) ![]Value {
        const a = self.arena.allocator();
        var out: std.ArrayList(Value) = .empty;
        for (self.host.outbox.items) |line| {
            defer testing.allocator.free(line);
            try out.append(a, try std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }));
        }
        self.host.outbox.clearRetainingCapacity();
        return out.items;
    }

    fn reply(self: *Fixture, request: Value, ok: []const u8) !void {
        const v = try std.json.parseFromSliceLeaky(Value, self.arena.allocator(), ok, .{ .allocate = .alloc_always });
        try self.host.onResponse(&self.app, request.object.get("id").?.integer, .{ .ok = v });
    }

    fn inbox(self: *Fixture, json: []const u8) !void {
        const v = try std.json.parseFromSliceLeaky(Value, self.arena.allocator(), json, .{ .allocate = .alloc_always });
        try self.app.inbox.apply(v);
    }
};

fn verb(r: Value) []const u8 {
    return r.object.get("verb").?.string;
}

fn params(r: Value) std.json.ObjectMap {
    return r.object.get("params").?.object;
}

fn hasTag(p: std.json.ObjectMap, field: []const u8, key: []const u8, value: []const u8) bool {
    for (p.get(field).?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("key").?.string, key) and std.mem.eql(u8, t.object.get("value").?.string, value)) return true;
    }
    return false;
}

const one_approval =
    \\{"items":[{"agent":"a1","item":"r1","request":"r1","kind":"approval","reason":"approve: zig build test","age_s":3}]}
;
const no_items =
    \\{"items":[]}
;

test "setting: every spelling, and an unknown one is auto" {
    try testing.expectEqual(host_mod.Setting.host, host_mod.parseSetting(".host"));
    try testing.expectEqual(host_mod.Setting.own, host_mod.parseSetting("\"own\""));
    try testing.expectEqual(host_mod.Setting.auto, host_mod.parseSetting("auto"));
    try testing.expectEqual(host_mod.Setting.auto, host_mod.parseSetting(".desk"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ok = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"content\":\".own\",\"source\":\"user\"}", .{});
    try testing.expectEqual(host_mod.Setting.own, host_mod.settingOf(ok));
    try testing.expectEqual(host_mod.Setting.auto, host_mod.settingOf(.null));
}

test "begin: tags role = control and asks; a pane never registers anything" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.host.begin();
    const reqs = try f.take();
    try testing.expectEqualStrings("pane.tag", verb(reqs[0]));
    try testing.expectEqualStrings("p1", params(reqs[0]).get("pane").?.string);
    try testing.expect(hasTag(params(reqs[0]), "set", "role", "control"));
    try testing.expect(hasTag(params(reqs[0]), "set", "product", "venom"));
    for (reqs) |r| {
        try testing.expect(!std.mem.startsWith(u8, verb(r), "status."));
        try testing.expect(!std.mem.eql(u8, verb(r), "keys.register"));
        try testing.expect(!std.mem.eql(u8, verb(r), "floats.register"));
    }
}

test "key table: under v from any pane, from the tree's rows, no token in it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const table = try host_mod.keyTable(a, "/bin/venom", "/s");
    try testing.expectEqualStrings("venom", table.name);
    try testing.expectEqualStrings("v", table.prefix);
    try testing.expectEqualStrings("venom", table.label);
    // No `when`: the keys work from any pane, so `keys.register` gets none.
    const sent = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, table, .{}), .{});
    try testing.expect(sent.object.get("when") == null);
    // In v1 these four, and `ctrl+a v X` equals `space X`.
    const want = [_]struct { key: []const u8, preset: []const u8, flag: []const u8 }{
        .{ .key = "i", .preset = "venom.settings", .flag = "--inbox=true" },
        .{ .key = "s", .preset = "venom.settings", .flag = "--settings=true" },
        .{ .key = "d", .preset = "venom.diff", .flag = "{pane}" },
        .{ .key = "u", .preset = "venom.settings", .flag = "--usage=true" },
    };
    try testing.expectEqual(want.len, table.bindings.len);
    const tree = try keys.K.resolve(a, keys.treeTables(true), null);
    for (table.bindings, want) |b, w| {
        try testing.expectEqualStrings(w.key, b.key);
        try testing.expectEqualStrings("pane.popup", b.verb);
        const m = tree.lookup((chord.parseSequence(b.key).?).slice());
        try testing.expectEqualStrings(m.exact.binding.label.?, b.label);
        const args = try std.json.parseFromSliceLeaky(Value, a, b.args, .{});
        try testing.expectEqualStrings(w.preset, args.object.get("preset").?.string);
        try testing.expect(std.mem.indexOf(u8, b.args, w.flag) != null);
        // A popup is a pane: it is refused the owner file.
        if (!std.mem.eql(u8, w.key, "d")) try testing.expect(std.mem.indexOf(u8, b.args, "--no-owner=true") != null);
    }
}

test "the key table going is said once, and again only after it came back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.host.begin();
    const reqs = try f.take();
    f.app.message.clearRetainingCapacity();
    for (reqs) |r| if (std.mem.eql(u8, verb(r), "keys.list")) try f.reply(r, "{\"tables\":[{\"name\":\"venomx\"}]}");
    // On the bar, not in the message a key press clears.
    try testing.expectEqualStrings(host_mod.keys_notice, f.host.notice().?);
    try testing.expectEqual(@as(usize, 0), f.app.message.items.len);
    try f.host.requestKeys();
    try f.reply((try f.take())[0], "{\"tables\":[]}");
    try testing.expect(f.host.notice() != null);
    try f.host.requestKeys();
    try f.reply((try f.take())[0], "{\"tables\":[{\"name\":\"venom\"}]}");
    try testing.expect(f.host.notice() == null);
}

test "the missing-keys notice fits an 80-column hint row whole and survives keys" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // A long workspace in the bar: the notice is on the hint row, so it
    // never competes with it.
    const agent = f.app.model.find(f.app.selected.items).?;
    testing.allocator.free(agent.workspace);
    agent.workspace = try testing.allocator.dupe(u8, "/somewhere/quite/deep/in/a/rather/long/workspace/path");
    var surface = try term.Surface.init(testing.allocator, 80, 24);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 23), "path") != null);

    f.host.keys_missing = true;
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), host_mod.keys_notice) != null);
    // A move, then a message: gone with the next key, and the notice is back.
    try f.app.handleKey(term.widgets.keys.testKey('j', .{}));
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), host_mod.keys_notice) != null);
    f.app.say("something else", .{});
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), "something else") != null);
    try f.app.handleKey(term.widgets.keys.testKey('k', .{}));
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), host_mod.keys_notice) != null);
    // Also from the other areas of the main screen.
    for (0..3) |i| {
        f.app.focus.set(i);
        try view.render(&f.app, &surface);
        try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), host_mod.keys_notice) != null);
    }
    // A mode's own hints go first, and the notice comes back after it.
    f.app.focus.set(0);
    f.app.filtering = true;
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), host_mod.keys_notice) == null);
    f.app.filtering = false;
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 22), host_mod.keys_notice) != null);
}

test "a refused pane says so once and stops asking" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.host.onResponse(&f.app, list[0].object.get("id").?.integer, .{ .@"error" = .{ .code = "denied.read", .message = "", .data = .null } });
    try testing.expect(f.host.refused);
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "denied.read") != null);
}

test "an earlier control pane's agent pane: attention comes to the control pane" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    _ = try f.take();
    try f.inbox(one_approval);
    try f.host.sync(&f.app);
    var set: ?Value = null;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        set = r;
    };
    try f.host.onResponse(&f.app, set.?.object.get("id").?.integer, .{ .@"error" = .{ .code = "denied.write", .message = "", .data = .null } });
    try testing.expect(!f.host.refused);
    try f.host.sync(&f.app);
    var next: ?Value = null;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        next = r;
    };
    try testing.expectEqualStrings("p1", params(next.?).get("pane").?.string);
}

test "a later venom's --usage reaches the running control pane" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0],
        \\{"panes":[{"pane":"p1","session":"s0","exited":false,"tags":[{"key":"venom.open_usage","value":"true"}]}]}
    );
    try testing.expectEqual(@import("app.zig").Screen.usage, f.app.screen);
    var cleared = false;
    for (try f.take()) |r| {
        if (std.mem.eql(u8, verb(r), "pane.tag") and params(r).get("unset") != null) cleared = true;
    }
    try testing.expect(cleared);
}

test "a later venom's --agent and --inbox reach the running control pane" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0],
        \\{"panes":[{"pane":"p1","session":"s0","exited":false,"tags":[{"key":"venom.open_agent","value":"a3"},{"key":"venom.open_inbox","value":"true"}]}]}
    );
    try testing.expectEqualStrings("a3", f.app.selected.items);
    try testing.expectEqual(@import("app.zig").Screen.inbox, f.app.screen);
    var cleared = false;
    for (try f.take()) |r| {
        if (std.mem.eql(u8, verb(r), "pane.tag") and params(r).get("unset") != null) cleared = true;
    }
    try testing.expect(cleared);
}

const default_unknown = "{\"content\":\".{.{.right=.read,.scope=\\\"*\\\"}}\"}";

fn resumes(_: []const u8) bool {
    return true;
}

fn hasArg(p: std.json.ObjectMap, want: []const u8) bool {
    for (p.get("argv").?.array.items) |x| if (std.mem.eql(u8, x.string, want)) return true;
    return false;
}

fn envOf(p: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const env = p.get("env") orelse return null;
    for (env.array.items) |e| if (std.mem.eql(u8, e.object.get("name").?.string, name)) return e.object.get("value").?.string;
    return null;
}

/// What a split may hold, whatever it runs.
fn expectReadOnlyAndClean(p: std.json.ObjectMap) !void {
    const grants = p.get("grants").?.array.items;
    try testing.expectEqual(@as(usize, 1), grants.len);
    try testing.expectEqualStrings("read", grants[0].object.get("right").?.string);
    try testing.expectEqualStrings("*", grants[0].object.get("scope").?.string);
    const argv = p.get("argv").?.array.items;
    try testing.expectEqualStrings("/usr/bin/env", argv[0].string);
    for ([_][]const u8{ "VENOMX_TOKEN", "VENOMX_PRINCIPAL", "VENOMX_PANE", "VENOMX_SOCKET" }) |name| try testing.expect(hasArg(p, name));
}

test "host: the split menu offers all three; none runs in the control pane" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.resumes = resumes;
    try f.app.openMenu("a1");
    const split = @import("split.zig");
    try testing.expectEqualSlices(split.Option, &.{ .agent_view, .shell, .take_over }, f.app.menu.?.opts.slice());
    // Nothing of the control pane's: `pick` asks venomx, not a local PTY.
    _ = try f.take();
    try f.app.handleKey(term.widgets.keys.testKey('2', .{}));
    try testing.expectEqual(@as(usize, 0), f.app.splits.items.len);
    const reqs = try f.take();
    try testing.expectEqualStrings("pane.split", verb(reqs[0]));
}

test "grants.unknown: only the default reads; empty, narrower or unanswered give nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const of = struct {
        fn reads(x: std.mem.Allocator, content: []const u8) !bool {
            const json = try std.json.Stringify.valueAlloc(x, .{ .content = content }, .{});
            return host_mod.unknownReadsAll(try std.json.parseFromSliceLeaky(Value, x, json, .{}));
        }
    }.reads;
    try testing.expect(try of(a, ".{.{.right=.read,.scope=\"*\"}}"));
    try testing.expect(try of(a, ".{ .{ .right = .read, .scope = \"*\" }, }"));
    try testing.expect(!try of(a, ".{}"));
    try testing.expect(!try of(a, ".{.{.right=.read,.scope=\"config:root\"}}"));
    try testing.expect(!host_mod.unknownReadsAll(.null));

    // Asked with the keys; nothing is handed out until it answers.
    _ = try f.take();
    try f.host.openShell(&f.app, "a1");
    var reqs = try f.take();
    try testing.expectEqual(@as(usize, 0), params(reqs[0]).get("grants").?.array.items.len);
    try f.host.requestKeys();
    reqs = try f.take();
    try testing.expectEqualStrings("config.get", verb(reqs[1]));
    try f.reply(reqs[1], "{\"content\":\".{}\"}");
    try f.host.openShell(&f.app, "a1");
    try testing.expectEqual(@as(usize, 0), params((try f.take())[0]).get("grants").?.array.items.len);
    try f.host.requestKeys();
    reqs = try f.take();
    try f.reply(reqs[1], default_unknown);
    try f.host.openShell(&f.app, "a1");
    try expectReadOnlyAndClean(params((try f.take())[0]));
}

test "a shell split: read only, no credential, in the agent's folder, next to its panes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A narrow token this TUI holds never reaches a shell.
    f.host.token = try testing.allocator.dupe(u8, "vnt1.venom.g7.narrow");
    f.host.unknown_reads = true;
    f.app.shell_path = "/bin/zsh";
    _ = try f.take();
    try f.host.openShell(&f.app, "a1");
    var reqs = try f.take();
    var p = params(reqs[0]);
    try testing.expectEqualStrings("p1", p.get("pane").?.string);
    try testing.expectEqualStrings("/home/me/venom-org/venom-std", p.get("cwd").?.string);
    try testing.expectEqualStrings("remove", p.get("on_exit").?.string);
    try testing.expect(hasTag(p, "tags", "role", "agent"));
    try testing.expect(hasTag(p, "tags", "group", "a1"));
    try testing.expect(hasTag(p, "tags", "venom.split", "shell"));
    try testing.expect(hasArg(p, "/bin/zsh"));
    try testing.expectEqualStrings("a1", envOf(p, "VENOM_AGENT").?);
    try testing.expect(envOf(p, "VENOM_TOKEN") == null);
    try expectReadOnlyAndClean(p);
    try f.reply(reqs[0], "{\"pane\":\"p4\"}");
    try testing.expectEqual(@import("split.zig").Kind.shell, f.host.panes.items[0].kind);

    // The next lands near it, by `group`, even with another agent's pane about.
    try f.host.openShell(&f.app, "a1");
    reqs = try f.take();
    p = params(reqs[0]);
    try testing.expect(hasTag(p, "near", "group", "a1"));
    // A shell is not its view: the view still opens, also beside it.
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"shell\"}]}]}");
    const opened = try f.take();
    p = params(opened[0]);
    try testing.expectEqualStrings("pane.split", verb(opened[0]));
    try testing.expect(hasTag(p, "near", "group", "a1"));
    try testing.expect(hasTag(p, "tags", "venom.split", "agent_view"));
    try testing.expectEqualStrings("keep", p.get("on_exit").?.string);
    // That one is a venom client, with the TUI's own narrow token.
    try testing.expectEqualStrings("vnt1.venom.g7.narrow", envOf(p, "VENOM_TOKEN").?);
    try expectReadOnlyAndClean(p);
}

test "a bound control pane: its view holds no credential, waits, and is bound to the pid of the split" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.host.bound = true;
    f.host.unknown_reads = true;
    _ = try f.take();
    const before = f.app.outbox.items.len;
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[]}");
    const opened = try f.take();
    const p = params(opened[0]);
    try testing.expect(envOf(p, "VENOM_TOKEN") == null);
    try testing.expect(hasArg(p, "--await-binding=true"));
    try testing.expect(hasArg(p, "--no-owner=true"));
    try testing.expectEqual(before, f.app.outbox.items.len);
    try f.reply(opened[0], "{\"pane\":\"p4\",\"pid\":4242}");
    try testing.expectEqual(before + 1, f.app.outbox.items.len);
    const a = f.arena.allocator();
    const req = try std.json.parseFromSliceLeaky(Value, a, f.app.outbox.items[before], .{ .allocate = .alloc_always });
    try testing.expectEqualStrings("grant.issue", verb(req));
    const q = params(req);
    try testing.expectEqual(@as(i64, 4242), q.get("pid").?.integer);
    try testing.expectEqualStrings("person", q.get("namespace").?.string);
    for (q.get("grants").?.array.items) |g| try testing.expect(!std.mem.eql(u8, g.object.get("right").?.string, "admin"));

    // A shell is not a venom client, and is never bound.
    f.app.shell_path = "/bin/zsh";
    try f.host.openShell(&f.app, "a1");
    const shell = try f.take();
    try testing.expect(!hasArg(params(shell[0]), "--await-binding=true"));
    try f.reply(shell[0], "{\"pane\":\"p5\",\"pid\":4243}");
    try testing.expectEqual(before + 1, f.app.outbox.items.len);
}

test "a control pane that is not bound asks no one to bind its views" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.host.unknown_reads = true;
    _ = try f.take();
    const before = f.app.outbox.items.len;
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[]}");
    const opened = try f.take();
    try testing.expect(!hasArg(params(opened[0]), "--await-binding=true"));
    try f.reply(opened[0], "{\"pane\":\"p4\",\"pid\":4242}");
    try testing.expectEqual(before, f.app.outbox.items.len);
}

test "attention skips a shell: its agent's mark goes to the control pane" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openShell(&f.app, "a1");
    try f.reply((try f.take())[0], "{\"pane\":\"p4\"}");
    try f.inbox(one_approval);
    try f.host.sync(&f.app);
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        try testing.expectEqualStrings("p1", params(r).get("pane").?.string);
    };
}

test "`leader v x` in the control pane closes the agent's newest split, and only that" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openShell(&f.app, "a1");
    try f.reply((try f.take())[0], "{\"pane\":\"p4\"}");
    try f.host.openShell(&f.app, "a1");
    try f.reply((try f.take())[0], "{\"pane\":\"p5\"}");
    _ = try f.take();
    for (" vx") |key| try f.app.handleKey(term.widgets.keys.testKey(key, .{}));
    const reqs = try f.take();
    try testing.expectEqual(@as(usize, 1), reqs.len);
    try testing.expectEqualStrings("pane.kill", verb(reqs[0]));
    try testing.expectEqualStrings("p5", params(reqs[0]).get("pane").?.string);
    try testing.expect(params(reqs[0]).get("remove").?.bool);
    // No agent verb: closing a split never stops the agent.
    try testing.expectEqual(@as(usize, 0), f.app.outbox.items.len);
}

fn handOver(f: *Fixture) !void {
    f.host.unknown_reads = true;
    f.app.model.find("a1").?.state = .handed_over;
    const a = f.arena.allocator();
    const env = [_]host_mod.EnvVar{ .{ .name = "CLAUDE_CONFIG_DIR", .value = "/c" }, .{ .name = "VENOM_TOKEN", .value = "vnt1.venom.g9.x" }, .{ .name = "VENOMX_TOKEN", .value = "y" } };
    try f.host.openTakeover(a, "a1", &.{ "/bin/claude", "--resume", "s1" }, "/w", &env);
}

test "take-over runs in a read-only pane; venom's credentials stay out of it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try handOver(&f);
    const reqs = try f.take();
    const p = params(reqs[0]);
    try expectReadOnlyAndClean(p);
    try testing.expect(hasTag(p, "tags", "venom.split", "take_over"));
    try testing.expectEqualStrings("remove", p.get("on_exit").?.string);
    try testing.expectEqualStrings("/w", p.get("cwd").?.string);
    try testing.expectEqualStrings("/c", envOf(p, "CLAUDE_CONFIG_DIR").?);
    try testing.expect(envOf(p, "VENOM_TOKEN") == null);
    try testing.expect(envOf(p, "VENOMX_TOKEN") == null);
}

test "the take-over's pane ending before its report says nothing more; a real failure does" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try handOver(&f);
    try f.reply((try f.take())[0], "{\"pane\":\"p4\",\"pid\":4242}");
    // What the split's answer said is not what this is about.
    f.app.message.clearRetainingCapacity();
    var ids: [2]i64 = undefined;
    var n: usize = 0;
    var it = f.app.pending.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .action) {
        ids[n] = e.key_ptr.*;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    try f.app.onResponse(ids[0], .{ .@"error" = .{ .code = "conflict.takeover_pane_gone", .message = "", .data = null } });
    try testing.expectEqualStrings("", f.app.message.items);
    try f.app.onResponse(ids[1], .{ .@"error" = .{ .code = "unavailable.takeover_pane", .message = "", .data = null } });
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "unavailable.takeover_pane") != null);
}

const takeover_listed = "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"take_over\"}]}]}";

fn takebacks(f: *Fixture) usize {
    var n: usize = 0;
    for (f.app.outbox.items) |l| {
        if (std.mem.indexOf(u8, l, "agent.takeback") != null) n += 1;
    }
    return n;
}

fn listReply(f: *Fixture, json: []const u8) !void {
    _ = try f.take();
    try f.host.requestList(.list);
    try f.reply((try f.take())[0], json);
}

test "the take-over pane ending takes the agent back, once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try handOver(&f);
    try f.reply((try f.take())[0], "{\"pane\":\"p4\"}");
    try listReply(&f, takeover_listed);
    try testing.expectEqual(@as(usize, 0), takebacks(&f));
    try listReply(&f, "{\"panes\":[]}");
    try testing.expectEqual(@as(usize, 1), takebacks(&f));
    try listReply(&f, "{\"panes\":[]}");
    try testing.expectEqual(@as(usize, 1), takebacks(&f));
}

test "the pane's ID goes to the daemon; a pane that ended takes back with force" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try handOver(&f);
    try f.reply((try f.take())[0], "{\"pane\":\"p4\",\"pid\":4242}");
    // The pane first: the daemon asks venomx about it, to check the pid.
    var named: ?usize = null;
    var reported: ?usize = null;
    for (f.app.outbox.items, 0..) |l, i| {
        if (std.mem.indexOf(u8, l, "agent.takeover_pane") != null and std.mem.indexOf(u8, l, "p4") != null) named = i;
        if (std.mem.indexOf(u8, l, "agent.takeover_split") != null and std.mem.indexOf(u8, l, "4242") != null) reported = i;
    }
    try testing.expect(named.? < reported.?);
    try listReply(&f, "{\"panes\":[]}");
    var forced = false;
    for (f.app.outbox.items) |l| forced = forced or (std.mem.indexOf(u8, l, "agent.takeback") != null and std.mem.indexOf(u8, l, "\"force\":true") != null);
    try testing.expect(forced);
}

test "an earlier venom's take-over pane: T says what to do, every time, and its end still takes back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try listReply(&f, takeover_listed);
    f.app.model.find("a1").?.state = .handed_over;
    for (0..2) |_| {
        f.app.message.clearRetainingCapacity();
        try f.app.takeBack("a1");
        const kill = (try f.take())[0];
        try testing.expectEqualStrings("pane.kill", verb(kill));
        try f.host.onResponse(&f.app, kill.object.get("id").?.integer, .{ .@"error" = .{ .code = "denied.write", .message = "", .data = null } });
        try testing.expect(std.mem.indexOf(u8, f.app.message.items, "quit") != null);
        // Not retried behind the human's back.
        f.app.model.find("a1").?.state = .settled;
        try f.host.sync(&f.app);
        for (try f.take()) |r| try testing.expect(!std.mem.eql(u8, verb(r), "pane.kill"));
        f.app.model.find("a1").?.state = .handed_over;
    }
    try listReply(&f, "{\"panes\":[]}");
    try testing.expectEqual(@as(usize, 1), takebacks(&f));
}

test "T closes the pane first; the take-back follows its end" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try handOver(&f);
    try f.reply((try f.take())[0], "{\"pane\":\"p4\"}");
    try f.app.takeBack("a1");
    const reqs = try f.take();
    try testing.expectEqualStrings("pane.kill", verb(reqs[0]));
    try testing.expectEqual(@as(usize, 0), takebacks(&f));
    // It stays "closing" across a list, so it is not killed twice.
    try listReply(&f, takeover_listed);
    try f.app.takeBack("a1");
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
    try listReply(&f, "{\"panes\":[]}");
    try testing.expectEqual(@as(usize, 1), takebacks(&f));
}

test "a take-over pane split failing gives the agent back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try handOver(&f);
    const r = (try f.take())[0];
    try f.host.onResponse(&f.app, r.object.get("id").?.integer, .{ .@"error" = .{ .code = "unavailable.spawn", .message = "", .data = null } });
    try testing.expectEqual(@as(usize, 1), takebacks(&f));
}

test "an agent taken back elsewhere: its harness pane is closed, not left writing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try handOver(&f);
    try f.reply((try f.take())[0], "{\"pane\":\"p4\"}");
    // Fresh and not yet shown handed over: left alone.
    f.app.model.find("a1").?.state = .settled;
    try f.host.sync(&f.app);
    for (try f.take()) |r| try testing.expect(!std.mem.eql(u8, verb(r), "pane.kill"));
    // Seen handed over, then not: closed.
    f.app.model.find("a1").?.state = .handed_over;
    try f.host.sync(&f.app);
    f.app.model.find("a1").?.state = .settled;
    try f.host.sync(&f.app);
    var kills: usize = 0;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.kill")) {
        kills += 1;
    };
    try testing.expectEqual(@as(usize, 1), kills);
    try f.host.sync(&f.app);
    for (try f.take()) |r| try testing.expect(!std.mem.eql(u8, verb(r), "pane.kill"));
}

test "enter opens a sibling pane: tags, on_exit keep, cwd, --solo; focus stays" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.take();
    const was = f.app.area();
    try f.app.handleKey(term.widgets.keys.testNamed(.enter));
    try testing.expectEqual(was, f.app.area());
    const list = try f.take();
    try testing.expectEqualStrings("pane.list", verb(list[0]));
    try f.reply(list[0], "{\"panes\":[]}");
    const reqs = try f.take();
    try testing.expectEqualStrings("pane.split", verb(reqs[0]));
    const p = params(reqs[0]);
    try testing.expectEqualStrings("p1", p.get("pane").?.string);
    try testing.expectEqualStrings("cols", p.get("axis").?.string);
    try testing.expectEqualStrings("keep", p.get("on_exit").?.string);
    try testing.expectEqualStrings("/home/me/venom-org/venom-std", p.get("cwd").?.string);
    try testing.expect(hasTag(p, "tags", "role", "agent"));
    try testing.expect(hasTag(p, "tags", "group", "a1"));
    var argv: std.ArrayList(u8) = .empty;
    for (p.get("argv").?.array.items) |x| try argv.print(a, "{s} ", .{x.string});
    try testing.expectEqualStrings("/usr/bin/env -u VENOMX_TOKEN -u VENOMX_PRINCIPAL -u VENOMX_PANE -u VENOMX_SOCKET /bin/venom agent view --agent=a1 --solo=true --socket=/run/venom.sock ", argv.items);
    try f.reply(reqs[0], "{\"pane\":\"p4\",\"window\":\"w0\",\"session\":\"s0\",\"principal\":\"g9\",\"pid\":1}");
    try testing.expectEqualStrings("p4", f.host.panes.items[0].pane);

    // Again: it has a live pane, so nothing new; the second agent stacks.
    try f.host.openAgent("a1");
    const again = try f.take();
    try f.reply(again[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
    try testing.expect(std.mem.indexOf(u8, f.app.message.items, "p4") != null);
    try f.host.openAgent("a3");
    const second = try f.take();
    try f.reply(second[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    const stacked = try f.take();
    try testing.expectEqualStrings("rows", params(stacked[0]).get("axis").?.string);
    try testing.expect(hasTag(params(stacked[0]), "near", "role", "agent"));
}

test "an exited pane (on_exit keep) is replaced on enter" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    // With a mark from while it was live: dropping the pane must not read its freed ID.
    try f.host.openAgent("a1");
    var list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    _ = try f.take();
    try f.inbox(one_approval);
    try f.host.sync(&f.app);
    try testing.expectEqual(@as(usize, 1), f.host.marks.items.len);
    _ = try f.take();
    try f.host.openAgent("a1");
    list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":true,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    const rm = try f.take();
    try testing.expectEqualStrings("pane.remove", verb(rm[0]));
    try f.reply(rm[0], "{}");
    try testing.expectEqual(@as(usize, 0), f.host.marks.items.len);
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.split")) return;
    return error.NoSplit;
}

test "another session's agent panes are not this control pane's" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0],
        \\{"panes":[{"pane":"p1","session":"s1","exited":false,"tags":[]},
        \\{"pane":"p9","session":"s0","exited":false,"tags":[{"key":"role","value":"agent"},{"key":"group","value":"a1"}]}]}
    );
    try testing.expectEqual(@as(usize, 0), f.host.panes.items.len);
    try testing.expectEqualStrings("pane.split", verb((try f.take())[0]));
}

fn attentionOf(reqs: []Value) ?Value {
    var set: ?Value = null;
    for (reqs) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        set = r;
    };
    return set;
}

const away_item = "{{\"items\":[{{\"agent\":\"a1\",\"kind\":\"approval\",\"age_s\":{d},\"reason\":\"Claude needs your permission\",\"item\":\"away\",\"title\":\"t\",\"stale\":false,\"away\":true,\"context\":[]}}]}}";

test "an away item marks the take-over pane, not the view; a new report shows again" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.connected = true;
    _ = try f.take();
    try handOver(&f);
    try f.reply((try f.take())[0], "{\"pane\":\"p5\",\"pid\":4242}");
    try listReply(&f, "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]},{\"pane\":\"p5\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.split\",\"value\":\"take_over\"}]}]}");
    const a = f.arena.allocator();
    try f.inbox(try std.fmt.allocPrint(a, away_item, .{5}));
    try f.host.sync(&f.app);
    var set = attentionOf(try f.take()).?;
    try testing.expectEqualStrings("p5", params(set).get("pane").?.string);
    try testing.expectEqualStrings("urgent", params(set).get("level").?.string);
    try testing.expectEqualStrings("Claude needs your permission", params(set).get("reason").?.string);
    // Nothing new: nothing sent, so a client's focus clear stands.
    try f.inbox(try std.fmt.allocPrint(a, away_item, .{9}));
    try f.host.sync(&f.app);
    try testing.expect(attentionOf(try f.take()) == null);
    // A new prompt, in the same words: a hook fires once per prompt.
    f.app.model.find("a1").?.away_reports += 1;
    try f.host.sync(&f.app);
    set = attentionOf(try f.take()).?;
    try testing.expectEqualStrings("p5", params(set).get("pane").?.string);
    try f.host.sync(&f.app);
    try testing.expect(attentionOf(try f.take()) == null);
    // Gone: cleared on that pane.
    try f.inbox(no_items);
    try f.host.sync(&f.app);
    set = attentionOf(try f.take()).?;
    try testing.expectEqualStrings("p5", params(set).get("pane").?.string);
    try testing.expect(params(set).get("clear").?.bool);
}

test "attention follows the inbox: the agent's pane, cleared when answered, sent once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    _ = try f.take();
    try f.inbox(one_approval);
    try f.host.sync(&f.app);
    var reqs = try f.take();
    var set: ?Value = null;
    for (reqs) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        set = r;
    };
    try testing.expectEqualStrings("p4", params(set.?).get("pane").?.string);
    try testing.expectEqualStrings("urgent", params(set.?).get("level").?.string);
    try testing.expectEqualStrings("approve: zig build test", params(set.?).get("reason").?.string);
    // Nothing changed, nothing sent: a client's focus clear is not undone.
    try f.host.sync(&f.app);
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
    try f.inbox(no_items);
    try f.host.sync(&f.app);
    reqs = try f.take();
    try testing.expectEqualStrings("p4", params(reqs[0]).get("pane").?.string);
    try testing.expect(params(reqs[0]).get("clear").?.bool);
}

test "an item whose agent has no pane marks the control pane" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.inbox(one_approval);
    try f.host.sync(&f.app);
    var set: ?Value = null;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        set = r;
    };
    try testing.expectEqualStrings("p1", params(set.?).get("pane").?.string);
    try testing.expectEqualStrings("urgent", params(set.?).get("level").?.string);
}

test "a pane that went loses its attention mark" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    _ = try f.take();
    try f.inbox(one_approval);
    try f.host.sync(&f.app);
    var set: ?Value = null;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        set = r;
    };
    try f.host.onResponse(&f.app, 999, .{ .ok = .null }); // an unknown id: ignored
    try f.host.onResponse(&f.app, set.?.object.get("id").?.integer, .{ .@"error" = .{ .code = "not_found.pane", .message = "", .data = .null } });
    try testing.expectEqual(@as(usize, 0), f.host.panes.items.len);
    try testing.expectEqual(@as(usize, 0), f.host.marks.items.len);
}

test "own: auto with no venomx daemon falls back and starts nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runtime = try std.fmt.allocPrintSentinel(a, "XDG_RUNTIME_DIR={s}", .{buf[0..n]}, 0);
    const block = try a.allocSentinel(?[*:0]const u8, 1, null);
    block[0] = runtime;
    const r = try host_mod.resolve(testing.allocator, a, .{ .setting = .auto, .environ = .{ .block = .{ .slice = block } }, .env_map = null, .exe = "/bin/venom", .socket = "/s" });
    try testing.expect(r == .own);
    try testing.expect(r.own == null);
    // No socket, no lock: nothing was started.
    var it = tmp.dir.iterate();
    try testing.expect(try it.next(testing.io) == null);
}

test "a pane gets a venom token only when it is not the owner's" {
    try testing.expect(host_mod.passable(null) == null);
    try testing.expect(host_mod.passable("@owner") == null);
    try testing.expect(host_mod.passable("vnt1.venom.owner.abc") == null);
    try testing.expect(host_mod.passable("vnt1.venomx.g1.abc") == null);
    try testing.expectEqualStrings("vnt1.venom.g2.abc", host_mod.passable("vnt1.venom.g2.abc").?);
}

test "own is own without looking for venomx" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const block = try arena.allocator().allocSentinel(?[*:0]const u8, 0, null);
    const r = try host_mod.resolve(testing.allocator, arena.allocator(), .{ .setting = .own, .environ = .{ .block = .{ .slice = block } }, .env_map = null, .exe = "/bin/venom", .socket = "/s" });
    try testing.expect(r == .own);
}

/// One row of the surface, from the tests' own dump.
fn rowText(a: std.mem.Allocator, surface: *const term.Surface, y: u16) ![]const u8 {
    var rows = std.mem.splitScalar(u8, try tests.dump(a, surface), '\n');
    var i: u16 = 0;
    while (rows.next()) |row| : (i += 1) if (i == y) return row;
    return "";
}

test "host: venom's bar is the bottom row of its pane; a narrow one is list and bar" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var surface = try term.Surface.init(testing.allocator, 58, 12);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    try view.render(&f.app, &surface);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 11), "need you") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, 0), "AGENTS") != null);
    // No input box in a list-only pane.
    for (0..11) |y| try testing.expect(std.mem.indexOf(u8, try rowText(a, &surface, @intCast(y)), "Input") == null);
    // i moves focus to the input box: the full view again.
    f.app.focus.set(2);
    try view.render(&f.app, &surface);
    var seen = false;
    for (0..11) |y| seen = seen or std.mem.indexOf(u8, try rowText(a, &surface, @intCast(y)), "Input") != null;
    try testing.expect(seen);
}

test "host: `space s` draws the settings in the control pane and asks venomx for nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    f.app.focus.set(0);
    try f.app.handleKey(term.widgets.keys.testKey(' ', .{}));
    try f.app.handleKey(term.widgets.keys.testKey('s', .{}));
    try testing.expectEqual(@import("app.zig").Screen.settings, f.app.screen);
    // A pane has no popup ticket; `ctrl+a v s` has one.
    for (try f.take()) |r| {
        try testing.expect(!std.mem.eql(u8, verb(r), "pane.popup"));
        try testing.expect(!std.mem.eql(u8, verb(r), "popup.ticket"));
    }
    // Esc goes back to the list: this is no standalone `venom settings`.
    try f.app.handleKey(term.widgets.keys.testNamed(.escape));
    try testing.expectEqual(@import("app.zig").Screen.main, f.app.screen);
    try testing.expect(!f.app.quit);
}

test "solo: no list and no bar; Tab never lands on the hidden list" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    f.app.host = null;
    f.app.setSolo();
    var surface = try term.Surface.init(testing.allocator, 60, 12);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    f.app.message.clearRetainingCapacity();
    try view.render(&f.app, &surface);
    for (0..12) |y| {
        const row = try rowText(a, &surface, @intCast(y));
        try testing.expect(std.mem.indexOf(u8, row, "need you") == null);
        try testing.expect(std.mem.indexOf(u8, row, "Agents") == null);
    }
    const tab = term.widgets.keys.testNamed(.tab);
    for (0..5) |_| {
        try f.app.handleKey(tab);
        try testing.expect(f.app.area() != .list);
    }
}

test "diff: a pane's agent is its group, else the control pane's selection; checkouts first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(x: std.mem.Allocator, s: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, x, s, .{});
        }
    }.f;
    try testing.expectEqualStrings("a1", host_mod.agentOfPane(try parse(a, "{\"tags\":[{\"key\":\"product\",\"value\":\"venom\"},{\"key\":\"group\",\"value\":\"a1\"},{\"key\":\"venom.selected\",\"value\":\"a2\"}]}")).?);
    try testing.expectEqualStrings("a2", host_mod.agentOfPane(try parse(a, "{\"tags\":[{\"key\":\"product\",\"value\":\"venom\"},{\"key\":\"venom.selected\",\"value\":\"a2\"}]}")).?);
    try testing.expect(host_mod.agentOfPane(try parse(a, "{\"tags\":[]}")) == null);
    // Another product's `group` is not an agent.
    try testing.expect(host_mod.agentOfPane(try parse(a, "{\"tags\":[{\"key\":\"group\",\"value\":\"a1\"}]}")) == null);
    try testing.expect(host_mod.agentOfPane(try parse(a, "{\"tags\":[{\"key\":\"product\",\"value\":\"other\"},{\"key\":\"group\",\"value\":\"a1\"}]}")) == null);
    const two = try host_mod.diffFolders(a, try parse(a, "{\"cwd\":\"/w\",\"checkouts\":[{\"path\":\"/w/x\"},{\"path\":\"/w/y\"}]}"));
    try testing.expectEqualStrings("/w/y", two[1]);
    const one = try host_mod.diffFolders(a, try parse(a, "{\"cwd\":\"/w\",\"checkouts\":[]}"));
    try testing.expectEqualStrings("/w", one[0]);
}

test "attention reaches every live pane of the agent, with a reason venomx accepts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    const agent_tags = "\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]";
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false," ++ agent_tags ++ "},{\"pane\":\"p5\",\"exited\":false," ++ agent_tags ++ "},{\"pane\":\"p6\",\"exited\":true," ++ agent_tags ++ "}]}");
    _ = try f.take();
    try f.inbox("{\"items\":[{\"agent\":\"a1\",\"item\":\"p1\",\"request\":\"p1\",\"kind\":\"approval\",\"reason\":\"run\\n\\u001b[31mthis\",\"title\":\"t\",\"age_s\":1,\"context\":[]}]}");
    try f.host.sync(&f.app);
    var panes: std.ArrayList([]const u8) = .empty;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) {
        try panes.append(f.arena.allocator(), params(r).get("pane").?.string);
        try testing.expectEqualStrings("run  [31mthis", params(r).get("reason").?.string);
    };
    try testing.expectEqual(@as(usize, 2), panes.items.len);
    try testing.expectEqualStrings("p4", panes.items[0]);
    try testing.expectEqualStrings("p5", panes.items[1]);
}

test "a BEL's info attention on the control pane clears when nothing blocks, and not before" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    _ = try f.take();
    try f.inbox(one_approval);
    f.host.noteBell();
    try f.host.sync(&f.app);
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention")) try testing.expectEqualStrings("p4", params(r).get("pane").?.string);
    try f.inbox(no_items);
    try f.host.sync(&f.app);
    var cleared: usize = 0;
    for (try f.take()) |r| if (std.mem.eql(u8, verb(r), "pane.attention") and std.mem.eql(u8, params(r).get("pane").?.string, "p1")) {
        try testing.expect(params(r).get("clear").?.bool);
        cleared += 1;
    };
    try testing.expectEqual(@as(usize, 1), cleared);
    // Once: a later focus clear or a human's program is not ours to undo.
    try f.host.sync(&f.app);
    try testing.expectEqual(@as(usize, 0), (try f.take()).len);
}

test "quit: a control pane with agent views open still asks, and says detaching keeps the agents" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.take();
    try f.host.openAgent("a1");
    const list = try f.take();
    try f.reply(list[0], "{\"panes\":[{\"pane\":\"p4\",\"exited\":false,\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"a1\"}]}]}");
    _ = try f.take();
    f.app.model.agents.items[1].state = .queued;
    // The views' holds end with the control pane: four clients, nobody else.
    f.app.onHold(try std.json.parseFromSliceLeaky(Value, a, "{\"lifetime\":\"on-demand\",\"origin\":\"interactive\",\"phase\":\"active\",\"clients\":4,\"others\":0}", .{}));
    try testing.expect(f.app.quitNeedsConfirm());
    const text = try f.app.quitPromptText(a);
    try testing.expect(std.mem.indexOf(u8, text, "2 agents are running, 1 is queued.") != null);
    try testing.expect(std.mem.endsWith(u8, text, "Detaching venomx (its leader, then d) keeps the control pane, and so the agents, running."));
    f.app.quit = true;
    try testing.expect(!f.app.confirmQuit());
    try testing.expect(f.app.quit_prompt and !f.app.quit);
    // esc stays.
    _ = try f.app.feed("\x1b");
    try testing.expect(!f.app.quit_prompt and !f.app.quit);
    // A TUI outside this control pane also holds: quit does not ask.
    f.app.onHold(try std.json.parseFromSliceLeaky(Value, a, "{\"lifetime\":\"on-demand\",\"origin\":\"interactive\",\"phase\":\"active\",\"clients\":5,\"others\":1}", .{}));
    try testing.expect(!f.app.quitNeedsConfirm());
    f.app.quit = true;
    try testing.expect(f.app.confirmQuit());
}
