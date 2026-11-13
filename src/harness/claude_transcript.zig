//! claude-code catch-up (`catch_up = transcript_file`):
//! reads the turns Claude Code's own TUI ran from the session
//! transcript and replays them into the agent's conversation, so they are
//! logged like any other turn (`turn.started {origin: catch_up}`, text, tool
//! calls, usage, `turn.ended`) with venom's own ids.
//!
//! The transcript is the session's JSONL file,
//! `<config dir>/projects/<cwd, every non-alphanumeric byte as '-'>/<session>.jsonl`
//! (the config dir is `CLAUDE_CONFIG_DIR`, else `~/.claude`); when that
//! name does not exist (long paths are shortened by Claude Code), every
//! `projects/*/<session>.jsonl` is tried. It is read tolerantly:
//! lines that are not JSON, line types other than `user` and
//! `assistant`, sidechain (sub-agent) lines and meta lines are skipped.
//!
//! Mapping:
//!
//! | transcript line | normalized |
//! |---|---|
//! | `user` whose content is a prompt (a string or text blocks) | ends the open turn; `turn.started {origin: catch_up}` (`harness_turn`: the line's `uuid`) |
//! | `user` text `[Request interrupted by user…]` | the open turn ends `interrupted` |
//! | `user` local-command echo (`<command-name>`, `<local-command-stdout>`, …) | skipped: not a turn |
//! | `assistant` `text` block | `text {final: true}` |
//! | `assistant` `tool_use` block | `tool.started` (kind from the tool name) |
//! | `user` `tool_result` block | `tool.ended` (`ok`, or `error` for `is_error`) |
//! | `assistant` `message.usage` | `usage` per model at the turn's end, one value per API message id (Claude Code writes one line per content block, each repeating the message's usage) |
//!
//! Only lines stamped at or after `since_ms` (the hand-over) count, so the
//! turns venom already logged in protocol mode are not imported twice.
const std = @import("std");
const contract = @import("contract.zig");
const claude_code = @import("claude_code.zig");
const Conversation = contract.Conversation;
const c = std.c;

/// The transcript file of `session`, or null when there is none.
pub fn find(a: std.mem.Allocator, config_dir: []const u8, cwd: []const u8, session: []const u8) !?[]const u8 {
    const direct = try path(a, config_dir, cwd, session);
    if (exists(a, direct)) return direct;
    const projects = try std.fmt.allocPrintSentinel(a, "{s}/projects", .{config_dir}, 0);
    const dir = c.opendir(projects) orelse return null;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        const candidate = try std.fmt.allocPrint(a, "{s}/{s}/{s}.jsonl", .{ projects, name, session });
        if (exists(a, candidate)) return candidate;
    }
    return null;
}

/// Where Claude Code keeps the transcript of `session` run in `cwd`.
pub fn path(a: std.mem.Allocator, config_dir: []const u8, cwd: []const u8, session: []const u8) ![]const u8 {
    // Claude Code files a session under the physical cwd, symlinks resolved.
    const project = physical(a, cwd) orelse try a.dupe(u8, cwd);
    for (project) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
        ch.* = '-';
    };
    return std.fmt.allocPrint(a, "{s}/projects/{s}/{s}.jsonl", .{ config_dir, project, session });
}

fn physical(a: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, cwd, 0) catch return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = c.realpath(z, &buf) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(r, 0)) catch null;
}

pub fn exists(a: std.mem.Allocator, p: []const u8) bool {
    const z = a.dupeSentinel(u8, p, 0) catch return false;
    return c.access(z, c.F_OK) == 0;
}

/// The largest transcript catch-up reads; it runs on the daemon's reactor.
pub const max_bytes: u64 = 256 * 1024 * 1024;

/// Reads transcript `p`, which must be a regular file, not a symlink, in a
/// folder under `<config_dir>/projects`, of at most `max_bytes`. The path may
/// come from a hook, which anything in the take-over split can forge: a
/// FIFO must not hang the daemon, a device must not read for ever, and
/// another folder is not a session of this harness.
pub fn read(a: std.mem.Allocator, config_dir: []const u8, p: []const u8) ![]u8 {
    if (!underProjects(a, config_dir, p)) return error.HarnessCatchUp;
    return readRegular(a, p);
}

/// Reads `p`, which must be a regular file, not a symlink, of at most
/// `max_bytes`, without ever blocking on what it turns out to be.
pub fn readRegular(a: std.mem.Allocator, p: []const u8) ![]u8 {
    const fd = c.open(try a.dupeSentinel(u8, p, 0), .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
    if (fd < 0) return error.HarnessCatchUp;
    defer _ = c.close(fd);
    const st = try fileInfo(fd);
    if (st.mode & c.S.IFMT != c.S.IFREG or st.size > max_bytes) return error.HarnessCatchUp;
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.HarnessCatchUp;
        if (n == 0) break;
        // Still being written: never more than the cap.
        if (list.items.len + @as(usize, @intCast(n)) > max_bytes) return error.HarnessCatchUp;
        try list.appendSlice(a, buf[0..@intCast(n)]);
    }
    return list.items;
}

/// Whether `p` is a transcript `read` would open: a regular file, not a
/// symlink, in a folder under `<config_dir>/projects`. Opens it the way `read`
/// does (no follow, non-blocking), so a FIFO cannot hang the caller.
pub fn isTranscript(a: std.mem.Allocator, config_dir: []const u8, p: []const u8) bool {
    if (!underProjects(a, config_dir, p)) return false;
    const z = a.dupeSentinel(u8, p, 0) catch return false;
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const st = fileInfo(fd) catch return false;
    return st.mode & c.S.IFMT == c.S.IFREG;
}

/// The type and size of the open file `fd`.
fn fileInfo(fd: c.fd_t) !struct { mode: u32, size: u64 } {
    if (@import("builtin").os.tag == .linux) {
        var st: std.os.linux.Statx = undefined;
        if (c.statx(fd, "", c.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .SIZE = true }, &st) < 0) return error.HarnessCatchUp;
        return .{ .mode = st.mode, .size = st.size };
    }
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.HarnessCatchUp;
    return .{ .mode = st.mode, .size = @intCast(@max(st.size, 0)) };
}

/// Whether `p`'s folder, symlinks resolved, is under `<config_dir>/projects`.
fn underProjects(a: std.mem.Allocator, config_dir: []const u8, p: []const u8) bool {
    const parent = std.fs.path.dirname(p) orelse return false;
    var root_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const projects = std.fmt.allocPrintSentinel(a, "{s}/projects", .{config_dir}, 0) catch return false;
    const dir_z = a.dupeSentinel(u8, parent, 0) catch return false;
    const root = std.mem.sliceTo(c.realpath(projects, &root_buf) orelse return false, 0);
    const dir = std.mem.sliceTo(c.realpath(dir_z, &dir_buf) orelse return false, 0);
    return std.mem.startsWith(u8, dir, root) and dir.len > root.len and dir[root.len] == '/';
}

const Usage = struct { model: []const u8, in: u64, out: u64, cache_read: u64, cache_write: u64 };

/// What the turn being imported has gathered so far.
const Turn = struct {
    interrupted: bool = false,
    /// API message id → its usage (the last line of each message wins).
    usage: std.StringArrayHashMapUnmanaged(Usage) = .empty,
};

pub const Replayed = struct {
    /// Turns imported.
    turns: u32 = 0,
    /// The last line was not JSON: a write still in progress, or a torn
    /// file. It is skipped; the caller should say so.
    torn_tail: bool = false,
};

/// Replays the transcript `bytes` into `conv` (see the file comment).
/// `conv` must be between turns.
///
/// `known` is the harness id of the newest turn venom already has (the line
/// `uuid` of its start). When that line is in the transcript, everything up
/// to the end of that turn is skipped, so a catch-up that runs twice (a
/// crash after some turns were committed) imports each turn once.
pub fn replay(conv: *Conversation, bytes: []const u8, since_ms: ?i64, known: ?[]const u8) !Replayed {
    if (conv.inTurn()) return error.TurnRunning;
    var arena: std.heap.ArenaAllocator = .init(conv.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var turn: Turn = .{};
    var imported: u32 = 0;
    var torn = false;
    var skipping = false;
    var seen = false;
    if (known) |k| skipping = try holds(conv.gpa, bytes, since_ms, k);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        torn = false;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch {
            torn = true;
            continue;
        };
        const t = str(v, "type") orelse continue;
        const user = eql(t, "user");
        if (!user and !eql(t, "assistant")) continue;
        if (boolean(v, "isSidechain") or boolean(v, "isMeta") or boolean(v, "isCompactSummary")) continue;
        if (skipping) if (known) |k| if (eql(str(v, "uuid") orelse "", k)) {
            seen = true;
        };
        if (since_ms) |since| {
            const at = timestampMs(str(v, "timestamp") orelse continue) orelse continue;
            if (at < since) continue;
        }
        const msg = field(v, "message") orelse continue;
        const content = field(msg, "content") orelse continue;
        if (skipping) {
            // Resume at the first prompt after the known turn.
            const starts = user and !eql(str(v, "uuid") orelse "", known.?) and if (prompt(content)) |text|
                !std.mem.startsWith(u8, text, "[Request interrupted by user") and !notPrompt(text)
            else
                false;
            if (!(seen and starts)) continue;
            skipping = false;
        }
        if (user) {
            // Tool results end their calls; text in the same message (an
            // interrupt marker, a prompt) still counts.
            if (content == .array and conv.inTurn()) for (content.array.items) |block| {
                if (!eql(str(block, "type") orelse "", "tool_result")) continue;
                const id = str(block, "tool_use_id") orelse continue;
                if (!isOpen(conv, id)) continue;
                try conv.toolEnded(id, if (boolean(block, "is_error")) "error" else "ok", null, null);
            };
            const text = prompt(content) orelse continue;
            if (std.mem.startsWith(u8, text, "[Request interrupted by user")) {
                // Only a turn that is open can have been interrupted.
                if (conv.inTurn()) turn.interrupted = true;
                continue;
            }
            if (notPrompt(text)) continue;
            if (conv.inTurn()) try finish(conv, &turn, a);
            try conv.turnStarted(str(v, "uuid"), "catch_up");
            try conv.prompt(text);
            imported += 1;
            continue;
        }
        // Assistant output with no prompt before it (the TUI resumed into
        // an unfinished turn): it still is a turn.
        if (!conv.inTurn()) {
            try conv.turnStarted(str(v, "uuid"), "catch_up");
            imported += 1;
        }
        const model = str(msg, "model") orelse "";
        if (field(msg, "usage")) |u| if (!eql(model, "<synthetic>")) {
            const id = str(msg, "id") orelse str(v, "uuid") orelse "";
            try turn.usage.put(a, try a.dupe(u8, id), .{ .model = try a.dupe(u8, model), .in = count(u, "input_tokens"), .out = count(u, "output_tokens"), .cache_read = count(u, "cache_read_input_tokens"), .cache_write = count(u, "cache_creation_input_tokens") });
        };
        if (content != .array) continue;
        for (content.array.items) |block| {
            const bt = str(block, "type") orelse continue;
            if (eql(bt, "text")) {
                const text = str(block, "text") orelse continue;
                if (std.mem.trim(u8, text, " \t\r\n").len > 0) try conv.text(text, true);
            } else if (eql(bt, "tool_use")) {
                const id = str(block, "id") orelse continue;
                if (isOpen(conv, id)) continue;
                const name = str(block, "name") orelse "";
                try conv.toolStarted(.{ .harness_ref = id, .kind = claude_code.kindOf(name), .name = name, .title = try claude_code.title(a, name, field(block, "input") orelse .null), .status = "running", .raw_input = try contract.rawJson(a, field(block, "input") orelse .null) });
            }
        }
    }
    if (conv.inTurn()) try finish(conv, &turn, a);
    return .{ .turns = imported, .torn_tail = torn };
}

/// Whether the transcript holds line `uuid` as the replay below would see it
/// (a user or assistant line of the main chain, stamped at or after `since_ms`).
/// Each line is parsed in a scratch arena, and only those naming the id.
fn holds(gpa: std.mem.Allocator, bytes: []const u8, since_ms: ?i64, uuid: []const u8) !bool {
    var needle: std.ArrayList(u8) = .empty;
    defer needle.deinit(gpa);
    try needle.print(gpa, "\"{s}\"", .{uuid});
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle.items) == null) continue;
        _ = scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch continue;
        if (!eql(str(v, "uuid") orelse "", uuid)) continue;
        const t = str(v, "type") orelse continue;
        if (!eql(t, "user") and !eql(t, "assistant")) continue;
        if (boolean(v, "isSidechain") or boolean(v, "isMeta") or boolean(v, "isCompactSummary")) continue;
        if (since_ms) |since| {
            const at = timestampMs(str(v, "timestamp") orelse continue) orelse continue;
            if (at < since) continue;
        }
        return true;
    }
    return false;
}

/// Usage per model, then the turn's end.
fn finish(conv: *Conversation, turn: *Turn, a: std.mem.Allocator) !void {
    var per_model: std.StringArrayHashMapUnmanaged(Usage) = .empty;
    for (turn.usage.values()) |u| {
        const gop = try per_model.getOrPut(a, u.model);
        if (!gop.found_existing) gop.value_ptr.* = .{ .model = u.model, .in = 0, .out = 0, .cache_read = 0, .cache_write = 0 };
        gop.value_ptr.in += u.in;
        gop.value_ptr.out += u.out;
        gop.value_ptr.cache_read += u.cache_read;
        gop.value_ptr.cache_write += u.cache_write;
    }
    for (per_model.values()) |u| {
        if (u.in == 0 and u.out == 0 and u.cache_read == 0 and u.cache_write == 0) continue;
        try conv.usage(.{ .model = u.model, .tokens_in = u.in, .tokens_out = u.out, .cache_read = u.cache_read, .cache_write = u.cache_write });
    }
    try conv.turnEnded(if (turn.interrupted) "interrupted" else "completed", null);
    turn.* = .{};
}

/// The text of a user message: the string, or its first text block (tool
/// results beside it are handled by the caller).
fn prompt(content: std.json.Value) ?[]const u8 {
    if (content == .string) return content.string;
    if (content != .array) return null;
    for (content.array.items) |block| {
        if (eql(str(block, "type") orelse "", "text")) if (str(block, "text")) |t| return t;
    }
    return null;
}

/// Text that is not a prompt: echoes of slash commands and `!` shell
/// commands typed in the TUI, and reminders Claude Code adds itself.
fn notPrompt(text: []const u8) bool {
    const tags = [_][]const u8{ "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<system-reminder>" };
    const t = std.mem.trimStart(u8, text, " \t\r\n");
    for (tags) |tag| if (std.mem.startsWith(u8, t, tag)) return true;
    return false;
}

/// `2026-11-07T21:06:05.047Z` (UTC, as Claude Code writes it) in ms since
/// the Unix epoch; null for anything else.
pub fn timestampMs(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    var ms: i64 = 0;
    var i: usize = 19;
    if (s[i] == '.') {
        i += 1;
        var digits: u8 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            if (digits < 3) ms = ms * 10 + (s[i] - '0');
            digits += 1;
        }
        while (digits < 3) : (digits += 1) ms *= 10;
    }
    if (i >= s.len or s[i] != 'Z') return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi) * 60_000 + sec * 1000 + ms;
}

fn isOpen(conv: *const Conversation, harness_ref: []const u8) bool {
    for (conv.open_calls.items) |x| if (eql(x.harness_ref, harness_ref)) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .null) null else x;
}
fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return if (x == .string) x.string else null;
}
fn boolean(v: std.json.Value, key: []const u8) bool {
    const x = field(v, key) orelse return false;
    return x == .bool and x.bool;
}
fn count(v: std.json.Value, key: []const u8) u64 {
    const x = field(v, key) orelse return 0;
    return if (x == .integer and x.integer > 0) @intCast(x.integer) else 0;
}

const testing = std.testing;

test "timestampMs: Claude Code's UTC stamps" {
    try testing.expectEqual(@as(?i64, 0), timestampMs("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1_794_085_565_047), timestampMs("2026-11-07T21:06:05.047Z"));
    try testing.expectEqual(@as(?i64, 1_794_085_565_000), timestampMs("2026-11-07T21:06:05Z"));
    try testing.expectEqual(@as(?i64, 951_782_400_500), timestampMs("2000-02-29T00:00:00.5Z"));
    try testing.expect(timestampMs("2026-11-07 21:06:05Z") == null);
    try testing.expect(timestampMs("yesterday") == null);
}

test "path: the cwd's non-alphanumeric bytes become '-'" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/h/.claude/projects/-home-u-venom-org-venom-std-246/s1.jsonl", try path(arena.allocator(), "/h/.claude", "/home/u/venom-org/venom_std.246", "s1"));
}
