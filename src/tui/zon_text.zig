//! Text operations on the ZON that `config get` returns: one value
//! per dotted key, the same text with a value replaced, an indented form to
//! read, and a line diff of two such forms. This is how the settings screen
//! previews a `config set` before it is applied: the daemon stays the only
//! thing that parses and validates values.
//!
//! Everything works on `normalize`d text, the form `config get` renders:
//! no whitespace outside strings and no trailing commas.
const std = @import("std");
const Allocator = std.mem.Allocator;

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn isPunctuation(ch: u8) bool {
    return ch == '{' or ch == '}' or ch == ',' or ch == '=';
}

/// `text` without comments and whitespace outside strings and without trailing
/// commas. A comment in a typed value is not part of it. Whitespace between two tokens stays, as one space: `1 6` is not `16`, and
/// the daemon refuses it.
pub fn normalize(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (std.mem.startsWith(u8, text[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            if (i == text.len) {
                // Spaces before a comment that ends the text were not tokens apart.
                while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                break;
            }
            continue;
        }
        switch (ch) {
            ' ', '\t', '\r', '\n' => {
                var next = i;
                while (next < text.len and isSpace(text[next])) next += 1;
                if (out.items.len > 0 and next < text.len and !isPunctuation(out.items[out.items.len - 1]) and !isPunctuation(text[next])) try out.append(a, ' ');
                i = next - 1;
            },
            '"' => {
                const end = stringEnd(text, i);
                try out.appendSlice(a, text[i..end]);
                i = end - 1;
            },
            '}' => {
                if (out.items.len > 0 and out.items[out.items.len - 1] == ',') out.items.len -= 1;
                try out.append(a, ch);
            },
            else => try out.append(a, ch),
        }
    }
    return out.items;
}

/// The index after the string starting at `start`.
fn stringEnd(t: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < t.len) : (i += 1) switch (t[i]) {
        '\\' => i += 1,
        '"' => return i + 1,
        else => {},
    };
    return t.len;
}

/// The index after the value starting at `start`.
fn valueEnd(t: []const u8, start: usize) usize {
    var i = start;
    var depth: usize = 0;
    while (i < t.len) {
        switch (t[i]) {
            '"' => {
                i = stringEnd(t, i);
                continue;
            },
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return i;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            ',' => if (depth == 0) return i,
            else => {},
        }
        i += 1;
    }
    return t.len;
}

const Field = struct { name: []const u8, start: usize, end: usize };

/// The field starting at `i` (`.name=value`), or null if there is none.
fn fieldAt(t: []const u8, i: usize) ?Field {
    if (i >= t.len or t[i] != '.') return null;
    var j = i + 1;
    while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_')) j += 1;
    if (j == i + 1 or j >= t.len or t[j] != '=') return null;
    return .{ .name = t[i + 1 .. j], .start = j + 1, .end = valueEnd(t, j + 1) };
}

/// A struct literal with named fields, not a tuple or an empty one.
fn isStruct(value: []const u8) bool {
    return std.mem.startsWith(u8, value, ".{") and fieldAt(value, 2) != null;
}

const Span = struct { start: usize, end: usize };

fn spanOf(t: []const u8, key: []const u8) ?Span {
    var span: Span = .{ .start = 0, .end = t.len };
    var parts = std.mem.splitScalar(u8, key, '.');
    next: while (parts.next()) |part| {
        if (!isStruct(t[span.start..span.end])) return null;
        var i = span.start + 2;
        while (fieldAt(t, i)) |f| {
            if (std.mem.eql(u8, f.name, part)) {
                span = .{ .start = f.start, .end = f.end };
                continue :next;
            }
            if (f.end >= t.len or t[f.end] != ',') return null;
            i = f.end + 1;
        }
        return null;
    }
    return span;
}

/// The value at dotted `key`, or null when there is no such field.
pub fn valueAt(t: []const u8, key: []const u8) ?[]const u8 {
    const s = spanOf(t, key) orelse return null;
    return t[s.start..s.end];
}

/// `t` with the value at `key` replaced; null when there is no such field.
pub fn replaced(a: Allocator, t: []const u8, key: []const u8, value: []const u8) !?[]u8 {
    const s = spanOf(t, key) orelse return null;
    return try std.mem.concat(a, u8, &.{ t[0..s.start], value, t[s.end..] });
}

fn indented(a: Allocator, out: *std.ArrayList([]const u8), t: []const u8, depth: usize) error{OutOfMemory}!void {
    const pad = try a.alloc(u8, depth * 4);
    @memset(pad, ' ');
    var i: usize = 2;
    while (fieldAt(t, i)) |f| {
        const value = t[f.start..f.end];
        if (isStruct(value)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}.{s} = .{{", .{ pad, f.name }));
            try indented(a, out, value, depth + 1);
            try out.append(a, try std.fmt.allocPrint(a, "{s}}},", .{pad}));
        } else try out.append(a, try std.fmt.allocPrint(a, "{s}.{s} = {s},", .{ pad, f.name, value }));
        if (f.end >= t.len or t[f.end] != ',') break;
        i = f.end + 1;
    }
}

/// Normalized ZON as lines, one field per line; tuples stay on theirs.
pub fn lines(a: Allocator, t: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (!isStruct(t)) {
        try out.append(a, t);
        return out.items;
    }
    try out.append(a, ".{");
    try indented(a, &out, t, 1);
    try out.append(a, "}");
    return out.items;
}

pub const DiffLine = struct {
    pub const Kind = enum { context, del, add, gap };
    kind: Kind,
    text: []const u8 = "",
};

/// The lines that differ between `before` and `after` with `context` lines
/// around each change; `.gap` stands for the lines left out. Empty when equal.
pub fn diff(a: Allocator, before: []const []const u8, after: []const []const u8, context: usize) ![]const DiffLine {
    // Longest common subsequence; config files are a few dozen lines.
    const w = after.len + 1;
    const table = try a.alloc(u32, (before.len + 1) * w);
    @memset(table, 0);
    var bi = before.len;
    while (bi > 0) {
        bi -= 1;
        var ai = after.len;
        while (ai > 0) {
            ai -= 1;
            table[bi * w + ai] = if (std.mem.eql(u8, before[bi], after[ai]))
                table[(bi + 1) * w + ai + 1] + 1
            else
                @max(table[(bi + 1) * w + ai], table[bi * w + ai + 1]);
        }
    }
    var all: std.ArrayList(DiffLine) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < before.len or j < after.len) {
        if (i < before.len and j < after.len and std.mem.eql(u8, before[i], after[j])) {
            try all.append(a, .{ .kind = .context, .text = before[i] });
            i += 1;
            j += 1;
        } else if (i < before.len and (j == after.len or table[(i + 1) * w + j] >= table[i * w + j + 1])) {
            try all.append(a, .{ .kind = .del, .text = before[i] });
            i += 1;
        } else {
            try all.append(a, .{ .kind = .add, .text = after[j] });
            j += 1;
        }
    }
    // Keep what is near a change.
    const keep = try a.alloc(bool, all.items.len);
    @memset(keep, false);
    for (all.items, 0..) |l, n| if (l.kind != .context) {
        for (n -| context..@min(n + context + 1, all.items.len)) |m| keep[m] = true;
    };
    var out: std.ArrayList(DiffLine) = .empty;
    var skipped = false;
    for (all.items, keep) |l, k| {
        if (!k) {
            skipped = true;
            continue;
        }
        if (skipped and out.items.len > 0) try out.append(a, .{ .kind = .gap });
        skipped = false;
        try out.append(a, l);
    }
    return out.items;
}

const testing = std.testing;

test "normalize drops whitespace outside strings and trailing commas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(".{.a=1,.b=\"x , y\",.c=.{\"p\",\"q\"}}", try normalize(a, ".{ .a = 1, .b = \"x , y\", .c = .{ \"p\", \"q\", }, }"));
    try testing.expectEqualStrings("\"a\\\" b\"", try normalize(a, " \"a\\\" b\" "));
    try testing.expectEqualStrings("1 6", try normalize(a, " 1 \t 6 "));
    try testing.expectEqualStrings("5", try normalize(a, "5 // why"));
    try testing.expectEqualStrings(".{1,2}", try normalize(a, ".{ 1, // one\n 2 }"));
    try testing.expectEqualStrings("\"a // b\"", try normalize(a, "\"a // b\""));
    try testing.expectEqualStrings(".{\"a\" \"b\"}", try normalize(a, ".{ \"a\"  \"b\" }"));
}

const sample = ".{.agents=.{.default=.claude_code,.spawn=.{.allow=true,.depth=2},.archive_after=\"3d, or so\"},.attention=.{.approval_timeout=null},.grants=.{.unknown=.{.{.right=.read,.scope=\"*\"}},.none=.{}}}";

test "valueAt walks dotted keys, past strings, tuples and tables" {
    try testing.expectEqualStrings(".claude_code", valueAt(sample, "agents.default").?);
    try testing.expectEqualStrings("2", valueAt(sample, "agents.spawn.depth").?);
    try testing.expectEqualStrings("\"3d, or so\"", valueAt(sample, "agents.archive_after").?);
    try testing.expectEqualStrings("null", valueAt(sample, "attention.approval_timeout").?);
    try testing.expectEqualStrings(".{.{.right=.read,.scope=\"*\"}}", valueAt(sample, "grants.unknown").?);
    try testing.expectEqualStrings(".{}", valueAt(sample, "grants.none").?);
    try testing.expect(valueAt(sample, "agents.nope") == null);
    try testing.expect(valueAt(sample, "agents.default.deeper") == null);
    try testing.expect(valueAt(sample, "grants.unknown.right") == null);
}

test "replaced splices one value; lines indent tables and keep tuples whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const after = (try replaced(a, sample, "agents.spawn.depth", "5")).?;
    try testing.expectEqualStrings("5", valueAt(after, "agents.spawn.depth").?);
    try testing.expectEqualStrings("true", valueAt(after, "agents.spawn.allow").?);
    try testing.expect((try replaced(a, sample, "agents.nope", "5")) == null);
    const got = try std.mem.join(a, "\n", try lines(a, after));
    try testing.expectEqualStrings(
        \\.{
        \\    .agents = .{
        \\        .default = .claude_code,
        \\        .spawn = .{
        \\            .allow = true,
        \\            .depth = 5,
        \\        },
        \\        .archive_after = "3d, or so",
        \\    },
        \\    .attention = .{
        \\        .approval_timeout = null,
        \\    },
        \\    .grants = .{
        \\        .unknown = .{.{.right=.read,.scope="*"}},
        \\        .none = .{},
        \\    },
        \\}
    , got);
}

test "diff shows the change with its context and marks what it leaves out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    const after = [_][]const u8{ "a", "b", "C", "d", "e", "f", "g", "H" };
    var out: std.ArrayList(u8) = .empty;
    for (try diff(a, &before, &after, 1)) |l| try out.print(a, "{s}{s} ", .{ switch (l.kind) {
        .context => " ",
        .del => "-",
        .add => "+",
        .gap => "…",
    }, l.text });
    try testing.expectEqualStrings(" b -c +C  d …  g -h +H ", out.items);
    try testing.expectEqual(@as(usize, 0), (try diff(a, &before, &before, 1)).len);
}
