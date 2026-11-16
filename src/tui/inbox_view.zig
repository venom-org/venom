//! Draws the inbox screen ("Needs you"):
//!
//! ```text
//! ╭ Inbox ───────── 5 items ╮╭ title ───────── Question · 2 of 5 ╮
//! │ Blocking · agent stopped ││ Context · last turns              │
//! │ ▲ Approve: zig build  1m ││   agent text…                     │
//! │   title · a1 · exec:zig  ││ ▲ Question: keep varint framing?  │
//! │ Failed                   ││                                   │
//! │ To review · not blocking ││ 1–9 pick  ⏎ type an answer  …     │
//! ╰──────────────────────────╯╰───────────────────────────────────╯
//! ```
//!
//! The list is the daemon's `inbox.list` order; the right side is the item
//! under the cursor with its context and its keys, and the prompt box when
//! a key asked for text (deny reason, plan feedback, edited command,
//! question answer). The status bar (view.zig) stays at the bottom.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const pane = @import("pane.zig");
const Surface = term.Surface;
const Region = term.Region;
const App = @import("app.zig").App;
const kindRole = @import("app.zig").kindRole;
const keys = @import("keys.zig");
const inbox_mod = @import("inbox.zig");

pub fn render(app: *App, surface: *Surface, main: Region) !void {
    const a = app.frame.allocator();
    const theme = &app.theme;
    const W = main.width;
    const side_w: u16 = std.math.clamp(W * 40 / 100, @min(28, W), 56);
    const cols = w.layout.sideBySide(main, .{ .fixed = side_w });

    const g = try app.buildInboxGroups();
    try app.syncInbox(g);
    const items = try app.visibleItems();
    const list_inner = try pane.draw(surface, cols[0], theme, .{ .rule_right = true, .title = "INBOX", .badge = try std.fmt.allocPrint(a, "{d} item{s}", .{ items.len, if (items.len == 1) "" else "s" }), .focused = app.prompt == null });
    if (items.len == 0) {
        _ = try w.text.drawText(surface, list_inner.x + 1, list_inner.y, list_inner.width -| 2, if (app.inbox.loaded) "Nothing needs you." else "loading…", .faint, theme, .{});
    } else try app.inbox_list.draw(surface, list_inner, g.groups, theme, app.prompt == null);

    const current = try app.currentItem();
    const parts = if (app.prompt != null) w.layout.stacked(cols[1], .{ .fixed = 3 }) else [2]Region{ cols[1], .{ .width = 0, .height = 0 } };
    const it = current orelse {
        _ = try pane.draw(surface, parts[0], theme, .{ .title = "Needs you" });
        return;
    };
    var pos: usize = 0;
    for (items, 0..) |x, i| if (x == it) {
        pos = i + 1;
    };
    const detail = try pane.draw(surface, parts[0], theme, .{
        .title = if (it.title.len > 0) it.title else it.agent,
        .badge = try std.fmt.allocPrint(a, "{s} · {d} of {d}", .{ it.kind.label(), pos, items.len }),
        .role = if (it.kind.blocking()) kindRole(it.kind) else null,
    });
    const rev = app.inbox.revision +% @as(u32, @truncate(app.picks.n)) *% 131 +% @as(u32, @truncate(pos)) +% @as(u32, @truncate(app.marks.items.len)) *% 977;
    var blocks: std.ArrayList(w.Block) = .empty;
    if (it.context.len > 0) {
        try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = "Context · last turns", .role = .muted }}), .revision = rev });
        for (it.context) |c| try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = c.text }}), .indent = 2, .revision = rev });
        try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = "" }}), .revision = rev });
    }
    const resets = if (it.kind == .limit) try inbox_mod.resetsAtLabel(a, it.resets_at, app.utc_offset_override, @divFloor(app.now_ms, 1000)) else "";
    try blocks.append(a, .{ .spans = try spans(a, &.{
        .{ .text = it.kind.glyph(), .role = kindRole(it.kind) },
        .{ .text = " " },
        .{ .text = it.kind.label(), .role = kindRole(it.kind), .style = .{ .bold = true } },
        .{ .text = ": " },
        .{ .text = it.reason },
        .{ .text = if (resets.len > 0) "  · " else "", .role = .muted },
        .{ .text = resets, .role = .muted },
    }), .revision = rev });
    if (it.kind == .question) {
        app.drawn = .{ .item = inbox_mod.itemHash(it), .sig = inbox_mod.optionsSig(it) };
        const done = app.picks.count(it);
        for (try inbox_mod.optionRows(a, it, app.picks.chosen[0..done])) |row| {
            if (row.header) {
                try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = row.text, .role = .muted }}), .indent = 2, .revision = rev });
                continue;
            }
            try blocks.append(a, .{ .spans = try spans(a, &.{
                .{ .text = row.mark, .role = .accent },
                .{ .text = " " },
                .{ .text = row.text },
            }), .indent = 4, .revision = rev });
        }
    }
    if (it.grant.len > 0) try blocks.append(a, .{ .spans = try spans(a, &.{
        .{ .text = "grant ", .role = .muted },
        .{ .text = it.grant, .role = .accent },
        .{ .text = "  (a keeps it for the workspace)", .role = .muted },
    }), .indent = 2, .revision = rev });
    if (it.stale) try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = "its harness process is gone; answering resumes the agent", .role = .muted }}), .indent = 2, .revision = rev });
    try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = "" }}), .revision = rev });
    try blocks.append(a, .{ .spans = try spans(a, &.{
        .{ .text = if (app.single_view) keys.popupHints(it) else keys.itemHints(it), .role = .accent },
        .{ .text = if (app.single_view) "" else if (it.away) "  o open" else "  o open  \\ split", .role = .accent },
    }), .revision = rev });
    const batch = if (it.away)
        "Answer in the harness's own TUI; it clears when you take the agent back or it moves on."
    else if (app.marks.items.len > 0)
        try std.fmt.allocPrint(a, "{d} marked · Y allow marked · N deny marked (one grant only)", .{app.marks.items.len})
    else
        "m mark · Y / N answer marked approvals that share one grant";
    try blocks.append(a, .{ .spans = try spans(a, &.{.{ .text = batch, .role = .faint }}), .revision = rev });
    const pad: Region = .{ .x = detail.x + @min(detail.width, 1), .y = detail.y, .width = detail.width -| 2, .height = detail.height };
    try app.inbox_scroll.draw(app.gpa, surface, pad, blocks.items, theme, false);

    if (app.prompt) |p| {
        const box = try w.box.draw(surface, parts[1], theme, .{ .border = .single, .title = p.mode.title(), .badge = it.agent, .focused = true });
        try app.answer_input.draw(surface, box, theme, true);
    }
}

fn spans(a: std.mem.Allocator, s: []const w.Span) ![]const w.Span {
    return a.dupe(w.Span, s);
}
