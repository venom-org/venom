//! The approval decision card in the transcript: one bordered block on the
//! `crypt` ground with a `warn` border.
//!
//! ```text
//! ┌ ▲ approval ─────────────────────────────────┐
//! │ Run `zig build test` in the worktree?       │
//! │ grant   bash:zig build *                    │
//! │ agent   fix the frame limit                 │
//! │ y once  a always  e edit  n no  esc back    │
//! └─────────────────────────────────────────────┘
//! ```
//!
//! A transcript block only holds spans, so the card draws its own border
//! and pads every line to the block's width.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;

pub const Fact = struct { label: []const u8, value: []const u8 };

pub const Content = struct {
    /// What is being asked, in bone bold.
    question: []const u8,
    /// Muted key, `bone_dim` value.
    facts: []const Fact = &.{},
    /// The answers, as key hints.
    answers: []const Answer = default_answers,
};

pub const Answer = struct { key: []const u8, label: []const u8 };

pub const default_answers = &[_]Answer{
    .{ .key = "y", .label = "once" },
    .{ .key = "a", .label = "always" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "n", .label = "no" },
    .{ .key = "esc", .label = "back" },
};

/// Narrower than this the card does not fit: callers draw a plain line.
pub const min_width = 24;

const Builder = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(w.Span) = .empty,
    /// Applied to every span: the `crypt` ground.
    ground: term.Style,
    width: usize,
    /// Cells used on the current line, inside the borders.
    used: usize = 0,

    fn style(self: *const Builder, extra: term.Style) term.Style {
        return w.theme.overlay(self.ground, extra);
    }

    fn put(self: *Builder, text: []const u8, role: w.Role, extra: term.Style) !void {
        try self.out.append(self.a, .{ .text = text, .role = role, .style = self.style(extra) });
        self.used += w.text.width(text);
    }

    fn open(self: *Builder) !void {
        if (self.out.items.len > 0) try self.out.append(self.a, .{ .text = "\n" });
        try self.out.append(self.a, .{ .text = "│ ", .role = .warn, .style = self.style(.{}) });
        self.used = 0;
    }

    fn close(self: *Builder) !void {
        const inner = self.width - 4;
        const pad = try self.a.alloc(u8, inner -| self.used);
        @memset(pad, ' ');
        try self.out.append(self.a, .{ .text = pad, .style = self.style(.{}) });
        try self.out.append(self.a, .{ .text = " │", .role = .warn, .style = self.style(.{}) });
    }
};

/// Where `text` breaks to fit `room` cells: at a space when there is one.
fn cutAt(text: []const u8, room: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    var space: ?usize = null;
    while (i < text.len) {
        const next = w.text.nextGrapheme(text, i);
        const cells = w.text.graphemeWidth(text[i..next]);
        if (used + cells > room) break;
        if (text[i] == ' ') space = i;
        used += cells;
        i = next;
    }
    if (i == text.len) return text.len;
    if (space) |s| if (s > 0) return s;
    return @max(i, @min(text.len, w.text.nextGrapheme(text, 0)));
}

/// The card's spans for a block `width` cells wide (at least `min_width`).
/// `ground` is the style that puts every cell on `crypt`.
pub fn spans(a: std.mem.Allocator, c: Content, width: usize, ground: term.Style) ![]const w.Span {
    std.debug.assert(width >= min_width);
    var b: Builder = .{ .a = a, .ground = ground, .width = width };
    const inner = width - 4;

    // Top border with the title.
    const title = " ▲ approval ";
    try b.out.append(a, .{ .text = "┌", .role = .warn, .style = b.style(.{}) });
    try b.out.append(a, .{ .text = title, .role = .warn, .style = b.style(.{ .bold = true }) });
    try b.out.append(a, .{ .text = try repeat(a, "─", width -| 2 -| w.text.width(title)), .role = .warn, .style = b.style(.{}) });
    try b.out.append(a, .{ .text = "┐", .role = .warn, .style = b.style(.{}) });

    // The question.
    var rest = std.mem.trim(u8, c.question, " \n");
    if (rest.len == 0) rest = "Allow this?";
    while (rest.len > 0) {
        const cut = cutAt(rest, inner);
        try b.open();
        try b.put(std.mem.trimEnd(u8, rest[0..cut], " "), .normal, .{ .bold = true });
        try b.close();
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }

    // Facts: a muted key column, then the value.
    var key_w: usize = 0;
    for (c.facts) |f| key_w = @max(key_w, w.text.width(f.label));
    key_w = @min(key_w, inner / 3);
    for (c.facts) |f| {
        const room = inner -| (key_w + 2);
        var value = f.value;
        var first = true;
        while (first or value.len > 0) {
            const cut = cutAt(value, room);
            try b.open();
            const label = if (first) f.label else "";
            try b.put(label, .muted, .{});
            try b.put(try repeat(a, " ", key_w + 2 -| w.text.width(label)), .normal, .{});
            try b.put(std.mem.trimEnd(u8, value[0..cut], " "), .secondary, .{});
            try b.close();
            value = std.mem.trimStart(u8, value[cut..], " ");
            first = false;
        }
    }

    // The answers, wrapped between hints.
    try b.open();
    for (c.answers, 0..) |ans, i| {
        const need = w.text.width(ans.key) + 1 + w.text.width(ans.label) + (if (i > 0) @as(usize, 2) else 0);
        if (b.used > 0 and b.used + need > inner) {
            try b.close();
            try b.open();
        } else if (i > 0) try b.put("  ", .normal, .{});
        try b.put(ans.key, .normal, .{ .bold = true });
        try b.put(" ", .normal, .{});
        try b.put(ans.label, .muted, .{});
    }
    try b.close();

    // Bottom border.
    try b.out.append(a, .{ .text = "\n" });
    try b.out.append(a, .{ .text = "└", .role = .warn, .style = b.style(.{}) });
    try b.out.append(a, .{ .text = try repeat(a, "─", width - 2), .role = .warn, .style = b.style(.{}) });
    try b.out.append(a, .{ .text = "┘", .role = .warn, .style = b.style(.{}) });
    return b.out.items;
}

fn repeat(a: std.mem.Allocator, glyph: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| try out.appendSlice(a, glyph);
    return out.items;
}

test "the card is a bordered block of equal-width lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const width = 60;
    const sp = try spans(a, .{
        .question = "Run a very long command that has to wrap over more than one line?",
        .facts = &.{ .{ .label = "grant", .value = "bash:zig build *" }, .{ .label = "agent", .value = "fix the frame limit" } },
    }, width, .{});
    var text: std.ArrayList(u8) = .empty;
    for (sp) |s| try text.appendSlice(a, s.text);
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    var n: usize = 0;
    var last: []const u8 = "";
    while (lines.next()) |l| : (n += 1) {
        try std.testing.expectEqual(@as(usize, width), w.text.width(l));
        if (n == 0) try std.testing.expect(std.mem.startsWith(u8, l, "┌ ▲ approval "));
        last = l;
    }
    try std.testing.expect(n >= 7);
    // The transcript's wrapper keeps each line whole.
    var wrapped: w.text.Wrapped = .{};
    defer wrapped.deinit(std.testing.allocator);
    try w.text.wrap(std.testing.allocator, &wrapped, sp, width);
    try std.testing.expectEqual(n, wrapped.lines.items.len);
    try std.testing.expect(std.mem.startsWith(u8, last, "└"));
    try std.testing.expect(std.mem.indexOf(u8, text.items, "y once  a always  e edit  n no  esc back") != null);
}
