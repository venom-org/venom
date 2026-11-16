//! The input box at the bottom of the agent view (the composer):
//!
//! ```text
//! ╭ Input ──────────────────────────────────────────── claude-code ╮
//! │› Write a prompt; enter sends it (agent send)                   │
//! │ ask mode  opus 5.5     context ▰▰▰▰▰▰▱▱▱▱ 62% · 124k / 200k    │
//! ╰────────────────────────────────────────────────────────────────╯
//! ```
//!
//! **Drafts.** The box's text belongs to the selected agent: switching agents
//! keeps it with that agent (`App.drafts`), and a prompt that fails, or whose
//! connection is lost, returns to its own agent's draft, in front of anything
//! written since.
//!
//! **Sending.** Between turns every send is a plain `agent.send`. During a
//! turn (`running`, `needs_you`) what a key does follows the adapter's
//! `steer` and `interrupt` capabilities, which
//! `agent.show` reports. `⏎` does the most direct thing the harness can
//! (`steer` where it injects, a queued `turn` where it queues), `⇧⏎` always
//! queues, and `⌥⏎` is `interrupt_then_send`. A key the harness cannot honour
//! is refused here, keeping the text. Until the harness is probed the
//! capabilities are unknown, and the daemon decides.
//!
//! **Context meter.** `used / window` as the harness last reported them,
//! which are already what fills the window: nothing is summed here. The
//! percent and the ten cells round to nearest (one cell at least once
//! anything is used). The meter goes gold strictly above `warn_at`, compared
//! on the exact numbers rather than the rounded percent.
//!
//! **Handed over.** The box is disabled: a banner says
//! who has the agent and how to get it back, and text does not go anywhere:
//! only esc, tab and ⌃c act, and never from a paste. `T` and `\\` wait for esc,
//! since the hand-over can arrive mid-word.
//!
//! An agent-view split draws the same box (`drawFor`) on its agent
//! and that agent's draft: an agent has one draft wherever its box is drawn.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const Surface = term.Surface;
const Region = term.Region;
const Style = term.Style;
const model = @import("model.zig");
const App = @import("app.zig").App;

/// The `agent.send` modes (`src/verbs.zon`).
pub const SendMode = enum { turn, steer, interrupt_then_send };

/// Which key asked for the send.
pub const Press = enum {
    enter,
    shift_enter,
    alt_enter,

    pub fn of(key: term.Input.Key) Press {
        if (key.mods.alt) return .alt_enter;
        if (key.mods.shift) return .shift_enter;
        return .enter;
    }
};

pub const Refusal = enum {
    cannot_queue,
    cannot_interrupt,

    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .cannot_queue => "takes prompts only between turns",
            .cannot_interrupt => "cannot interrupt a turn",
        };
    }
};

pub const Choice = union(enum) { send: SendMode, refuse: Refusal };

/// A turn is open: a send now steers, queues or interrupts.
pub fn midTurn(state: model.State) bool {
    return state == .running or state == .needs_you;
}

/// What `press` does for an agent in `state` with these capabilities.
pub fn choose(press: Press, state: model.State, steer: model.Steer, interrupt: ?bool) Choice {
    if (!midTurn(state)) return .{ .send = .turn };
    return switch (press) {
        .enter => switch (steer) {
            .inject => .{ .send = .steer },
            .queue, .unknown => .{ .send = .turn },
            .none => .{ .refuse = .cannot_queue },
        },
        .shift_enter => if (steer == .none) .{ .refuse = .cannot_queue } else .{ .send = .turn },
        .alt_enter => if (interrupt == false) .{ .refuse = .cannot_interrupt } else .{ .send = .interrupt_then_send },
    };
}

const idle_placeholder = "Write a prompt; enter sends it (agent send)";

/// The empty box's text: what `⏎` does now.
pub fn placeholder(state: model.State, steer: model.Steer, interrupt: ?bool) []const u8 {
    if (!midTurn(state)) return idle_placeholder;
    const can_interrupt = interrupt != false;
    return switch (steer) {
        .inject => if (can_interrupt) "Enter steers, ⇧⏎ queues, ⌥⏎ interrupts and sends" else "Enter steers, ⇧⏎ queues",
        .queue, .unknown => if (can_interrupt) "Enter queues it, ⌥⏎ interrupts and sends" else "Enter queues it after this turn",
        .none => if (can_interrupt) "⌥⏎ interrupts the turn and sends" else "This harness takes prompts between turns",
    };
}

/// The status bar's keys while the box has focus.
pub fn hint(state: model.State, steer: model.Steer, interrupt: ?bool) []const u8 {
    if (!midTurn(state)) return "⏎ send  esc back  ⌃c clear";
    const can_interrupt = interrupt != false;
    return switch (steer) {
        .inject => if (can_interrupt) "⏎ steer  ⇧⏎ queue  ⌥⏎ interrupt and send  esc back" else "⏎ steer  ⇧⏎ queue  esc back",
        .queue, .unknown => if (can_interrupt) "⏎ queue  ⌥⏎ interrupt and send  esc back" else "⏎ queue  esc back",
        .none => if (can_interrupt) "⌥⏎ interrupt and send  esc back" else "esc back",
    };
}

// ---- Context meter ---------------------------------------------------------

pub const cells = 10;
/// However absurd the report, the percent stays short.
pub const max_percent = 999;

pub const Meter = struct {
    /// Rounded; above 100 when the harness reports more than the window,
    /// up to `max_percent`.
    percent: u64,
    /// How many of the ten cells are on.
    on: u8,
    /// Above `warn_at`: gold.
    hot: bool,
};

/// Null while the window is unknown.
pub fn meter(used: u64, window: u64, warn_at: u8) ?Meter {
    if (window == 0) return null;
    const u: u128 = used;
    const n: u128 = window;
    const on: u128 = @min((u * cells + n / 2) / n, cells);
    return .{
        .percent = @intCast(@min((u * 100 + n / 2) / n, max_percent)),
        .on = if (used > 0 and on == 0) 1 else @intCast(on),
        .hot = u * 100 > n * warn_at,
    };
}

/// `950`, `8.8k`, `124k`, `1.2M`.
pub fn tokens(a: std.mem.Allocator, n: u64) ![]const u8 {
    if (n < 1000) return std.fmt.allocPrint(a, "{d}", .{n});
    if (n < 10_000) return tenths(a, (n + 50) / 100, "k");
    const k = (n +| 500) / 1000;
    if (k < 1000) return std.fmt.allocPrint(a, "{d}k", .{k});
    return tenths(a, (n +| 50_000) / 100_000, "M");
}

fn tenths(a: std.mem.Allocator, t: u64, unit: []const u8) ![]const u8 {
    if (t % 10 == 0) return std.fmt.allocPrint(a, "{d}{s}", .{ t / 10, unit });
    return std.fmt.allocPrint(a, "{d}.{d}{s}", .{ t / 10, t % 10, unit });
}

/// `ask mode`, `accept edits mode`, `plan mode`.
fn modeLabel(a: std.mem.Allocator, mode: []const u8) ![]const u8 {
    const out = try std.fmt.allocPrint(a, "{s} mode", .{mode});
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

// ---- Drawing ---------------------------------------------------------------

/// Rows the box takes: its borders, the text and the footer.
pub const height = 4;

/// Draws the box for `sel` with `detail` (its last `agent.show`).
pub fn draw(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region, sel: ?*const model.Agent, detail: *const model.Detail) !void {
    try drawFor(app, surface, a, region, sel, detail, .{ .input = &app.input, .focused = app.area() == .input, .area = &app.input_area });
}

/// Which box is drawn: the main view's or a split's.
pub const Target = struct {
    input: *w.TextInput,
    focused: bool,
    /// Set to where it was drawn (for clicks).
    area: *Region,
};

pub fn drawFor(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region, sel: ?*const model.Agent, detail: *const model.Detail, target: Target) !void {
    const theme = &app.crypt;
    const focused = target.focused;
    if (sel) |s| if (s.state == .handed_over) {
        const banner = try w.box.draw(surface, region, theme, .{ .border = .single, .title = try std.fmt.allocPrint(a, "⇄ in {s}", .{s.harness}), .badge = s.id, .focused = focused, .clear = true });
        target.area.* = banner;
        // Focused, the box is Input: its keys wait until esc has left it.
        const has_split = app.takeoverSplit(s.id) != null;
        const text = if (focused)
            (if (has_split) "esc first, then \\ focus split  ·  T take back" else "esc first, then T take back")
        else if (has_split) "Its own TUI has the agent.  \\ focus split  ·  T take back" else "Its own TUI has the agent.  T take back";
        _ = try w.text.drawText(surface, banner.x + 1, banner.y, banner.width -| 2, text, .muted, theme, .{ .ellipsis = true });
        if (banner.height > 1) _ = try w.text.drawText(surface, banner.x + 1, banner.y + 1, banner.width -| 2, try std.fmt.allocPrint(a, "Input is in {s} while it has this agent.", .{s.harness}), .faint, theme, .{ .ellipsis = true });
        return;
    };
    // The harness's own sub-agent takes no prompt.
    if (sel) |s| if (s.native) {
        const banner = try w.box.draw(surface, region, theme, .{ .border = .single, .title = try std.fmt.allocPrint(a, "Owned by {s}", .{s.harness}), .badge = s.id, .focused = focused, .clear = true });
        target.area.* = banner;
        _ = try w.text.drawText(surface, banner.x + 1, banner.y, banner.width -| 2, "Message the parent to steer it.", .muted, theme, .{ .ellipsis = true });
        if (banner.height > 1) _ = try w.text.drawText(surface, banner.x + 1, banner.y + 1, banner.width -| 2, "[ goes to the parent", .faint, theme, .{ .ellipsis = true });
        return;
    };
    const box = try w.box.draw(surface, region, theme, .{ .border = .single, .title = "Input", .badge = if (sel) |s| s.harness else "", .focused = focused, .clear = true });
    target.area.* = box;
    target.input.opts.placeholder = if (sel) |s| placeholder(s.state, detail.steer, detail.interrupt) else idle_placeholder;
    // A spawned child between turns: the human may prompt it, and its parent sees that.
    if (sel) |s| if (s.parent.len > 0 and !midTurn(s.state)) {
        target.input.opts.placeholder = try std.fmt.allocPrint(a, "Prompt {s} directly. The parent sees it.", .{if (s.title.len > 0) s.title else s.id});
    };
    try target.input.draw(surface, .{ .x = box.x, .y = box.y, .width = box.width, .height = @min(box.height, 1) }, theme, focused);
    if (box.height > 1) try footer(app, surface, a, .{ .x = box.x + @min(box.width, 1), .y = box.y + 1, .width = box.width -| 2, .height = 1 }, detail);
}

/// The permission mode and model on the left, the context meter on the
/// right. Short of room, the meter's label goes first (the mode and
/// model matter more; the label only names the meter), then the left side
/// is cut, then the cells, then the counts.
fn footer(app: *App, surface: *Surface, a: std.mem.Allocator, row: Region, d: *const model.Detail) !void {
    const theme = &app.crypt;
    if (row.width == 0) return;
    const used_text: []const u8, const m: ?Meter = blk: {
        const c = d.context orelse break :blk .{ "", null };
        const got = meter(c.used, c.window, d.warn_at) orelse break :blk .{ "", null };
        break :blk .{ try std.fmt.allocPrint(a, "{d}% · {s} / {s}", .{ got.percent, try tokens(a, c.used), try tokens(a, c.window) }), got };
    };
    const percent_only: []const u8 = if (m) |got| try std.fmt.allocPrint(a, "{d}%", .{got.percent}) else "";
    const counts = if (m != null) used_text else "—";
    const counts_w: u16 = @intCast(w.text.width(counts));
    var left: std.ArrayList(u8) = .empty;
    if (d.permission_mode.len > 0) try left.appendSlice(a, try modeLabel(a, d.permission_mode));
    if (d.model.len > 0) {
        if (left.items.len > 0) try left.appendSlice(a, "  ");
        try left.appendSlice(a, d.model);
    }
    const left_w = w.text.width(left.items);
    const gap: u16 = 2;
    const label = "context ";
    const label_w: u16 = label.len;
    const room = row.width;
    const with_cells = cells + 1 + counts_w;
    const show_cells = room >= with_cells;
    const show_label = room >= label_w + with_cells + (if (left_w > 0) left_w + gap else 0);
    const right_w: u16 = if (show_label) label_w + with_cells else if (show_cells) with_cells else if (room >= counts_w) counts_w else @intCast(@min(w.text.width(percent_only), room));
    var x = row.x + room - right_w;

    if (left_w > 0 and room > right_w + gap) _ = try w.text.drawText(surface, row.x, row.y, room - right_w - gap, left.items, .muted, theme, .{ .ellipsis = true });

    const hot = if (m) |got| got.hot else false;
    const role: w.Role = if (hot) .warn else .secondary;
    const overlay: Style = .{ .bold = hot };
    if (show_label) {
        _ = try w.text.drawText(surface, x, row.y, label_w, label, .muted, theme, .{});
        x += label_w;
    }
    if (show_cells) {
        const on: u8 = if (m) |got| got.on else 0;
        for (0..cells) |i| {
            if (i < on) {
                _ = try w.text.drawText(surface, x, row.y, 1, "▰", role, theme, .{ .overlay = overlay });
            } else _ = try w.text.drawText(surface, x, row.y, 1, "▱", .faint, theme, .{});
            x += 1;
        }
        x += 1;
    }
    const shown = if (show_cells or room >= counts_w) counts else percent_only;
    _ = try w.text.drawText(surface, x, row.y, row.x + room - x, shown, if (m != null) role else .faint, theme, .{ .overlay = overlay });
}

const testing = std.testing;

test "meter: rounding, cells, and gold only strictly above warn_at" {
    const below = meter(124_000, 200_000, 80).?;
    try testing.expectEqual(@as(u64, 62), below.percent);
    try testing.expectEqual(@as(u8, 6), below.on);
    try testing.expect(!below.hot);
    // Exactly at warn_at is not above it; a token more is, though both round
    // to the same percent.
    try testing.expect(!meter(160_000, 200_000, 80).?.hot);
    const above = meter(160_001, 200_000, 80).?;
    try testing.expectEqual(@as(u64, 80), above.percent);
    try testing.expect(above.hot);
    // warn_at comes from config.
    try testing.expect(meter(124_000, 200_000, 50).?.hot);
    try testing.expect(!meter(200_000, 200_000, 100).?.hot);
    // Empty, a sliver, full and over.
    try testing.expectEqual(@as(u8, 0), meter(0, 200_000, 80).?.on);
    try testing.expectEqual(@as(u8, 1), meter(10, 200_000, 80).?.on);
    try testing.expectEqual(@as(u8, 10), meter(200_000, 200_000, 80).?.on);
    const over = meter(210_000, 200_000, 80).?;
    try testing.expectEqual(@as(u64, 105), over.percent);
    try testing.expectEqual(@as(u8, 10), over.on);
    // An absurd report neither panics nor grows the footer.
    const absurd = meter(std.math.maxInt(u64), 1, 80).?;
    try testing.expectEqual(@as(u64, max_percent), absurd.percent);
    try testing.expectEqual(@as(u8, 10), absurd.on);
    try testing.expect(absurd.hot);
    // No window, no meter.
    try testing.expect(meter(5, 0, 80) == null);
}

test "tokens: compact counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0" },            .{ 950, "950" },    .{ 1000, "1k" },
        .{ 8800, "8.8k" },      .{ 9999, "10k" },   .{ 124_000, "124k" },
        .{ 200_000, "200k" },   .{ 999_999, "1M" }, .{ 1_000_000, "1M" },
        .{ 1_250_000, "1.3M" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try tokens(a, c[0]));
    _ = try tokens(a, std.math.maxInt(u64));
}

test "choose: between turns always a turn; mid-turn by capability" {
    const T = SendMode.turn;
    // Between turns nothing is steered or interrupted.
    for ([_]model.State{ .settled, .failed, .queued }) |s| for (std.enums.values(Press)) |p| {
        try testing.expectEqual(Choice{ .send = T }, choose(p, s, .none, false));
    };
    for ([_]model.State{ .running, .needs_you }) |s| {
        // codex: steer = inject.
        try testing.expectEqual(Choice{ .send = .steer }, choose(.enter, s, .inject, true));
        try testing.expectEqual(Choice{ .send = T }, choose(.shift_enter, s, .inject, true));
        try testing.expectEqual(Choice{ .send = .interrupt_then_send }, choose(.alt_enter, s, .inject, true));
        // claude-code, fake: steer = queue.
        try testing.expectEqual(Choice{ .send = T }, choose(.enter, s, .queue, true));
        try testing.expectEqual(Choice{ .send = T }, choose(.shift_enter, s, .queue, true));
        // A harness that can do neither: refused here, the text stays.
        try testing.expectEqual(Choice{ .refuse = .cannot_queue }, choose(.enter, s, .none, false));
        try testing.expectEqual(Choice{ .refuse = .cannot_queue }, choose(.shift_enter, s, .none, false));
        try testing.expectEqual(Choice{ .refuse = .cannot_interrupt }, choose(.alt_enter, s, .none, false));
        // Unknown (not probed yet): the daemon decides.
        try testing.expectEqual(Choice{ .send = T }, choose(.enter, s, .unknown, null));
        try testing.expectEqual(Choice{ .send = .interrupt_then_send }, choose(.alt_enter, s, .unknown, null));
    }
}
