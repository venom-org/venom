//! Pane frames for venom's own views: square and borderless. A pane is a
//! header row (title on the left, a badge on the right) over a hairline in
//! `rule`, with an optional `│` in `rule` down its right edge to set it off
//! from the pane beside it:
//!
//! ```text
//!  AGENTS            3 live │ venom-echo conformance     ▲ needs you
//! ──────────────────────────│───────────────────────────────────────
//!  ▲ Needs you  1 ───────── │ › Add the conformance suite.
//! ```
//!
//! Focus is not a coloured border: the focused pane's title is `bone` bold
//! and its hairline is `rule_strong`; other titles are `muted`. A `role`
//! (e.g. `warn` for an agent that waits) colours the title instead.
//! Floating surfaces (popups, dialogs) keep venom-term's boxes.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const Surface = term.Surface;
const Region = term.Region;

pub const Options = struct {
    title: []const u8 = "",
    /// Right-aligned in the header, `muted`.
    badge: []const u8 = "",
    focused: bool = false,
    /// Colours the title, e.g. `warn` for an attention marker.
    role: ?w.Role = null,
    /// A number before the title, in the signal (`02 Agents`).
    number: []const u8 = "",
    /// Draws a `│` down the right edge.
    rule_right: bool = false,
    /// Blanks the inner region.
    clear: bool = false,
};

/// Draws the frame and returns the inner region (below the hairline, left
/// of the right rule).
pub fn draw(surface: *Surface, region: Region, theme: *const w.Theme, opts: Options) !Region {
    if (region.width == 0 or region.height == 0) return .{ .x = region.x, .y = region.y, .width = 0, .height = 0 };
    const rule = theme.style(.border);
    var width = region.width;
    if (opts.rule_right) {
        width -= 1;
        for (region.y..region.y + region.height) |y| try surface.put(region.x + width, @intCast(y), .{ .text = "│", .style = rule });
    }
    if (width == 0) return .{ .x = region.x, .y = region.y, .width = 0, .height = 0 };
    const blank = theme.style(.normal);
    // Header.
    try surface.clear(.{ .x = region.x, .y = region.y, .width = width, .height = 1 }, blank);
    var badge_w: u16 = 0;
    if (opts.badge.len > 0 and width > 8) {
        badge_w = @intCast(@min(w.text.width(opts.badge), width / 2));
        _ = try w.text.drawText(surface, region.x + width - badge_w - 1, region.y, badge_w, opts.badge, .muted, theme, .{ .ellipsis = true });
    }
    var x = region.x + 1;
    const title_end = region.x + width -| (if (badge_w > 0) badge_w + 2 else 1);
    if (opts.number.len > 0 and x + opts.number.len + 1 < title_end) {
        x += try w.text.drawText(surface, x, region.y, title_end - x, opts.number, .secondary, theme, .{});
        x += 1;
    }
    if (opts.title.len > 0 and x < title_end) {
        const role: w.Role = opts.role orelse if (opts.focused) .normal else .muted;
        _ = try w.text.drawText(surface, x, region.y, title_end - x, opts.title, role, theme, .{ .ellipsis = true, .overlay = .{ .bold = true } });
    }
    if (region.height < 2) return .{ .x = region.x, .y = region.y + 1, .width = width, .height = 0 };
    // Hairline.
    // The focused pane's hairline is the focus border, which venom sets to
    // `rule_strong` (app.zig `setTheme`).
    const line = if (opts.focused) theme.style(.border_focus) else rule;
    for (region.x..region.x + width) |cx| try surface.put(@intCast(cx), region.y + 1, .{ .text = "─", .style = line });
    const inner: Region = .{ .x = region.x, .y = region.y + 2, .width = width, .height = region.height - 2 };
    if (opts.clear) try surface.clear(inner, blank);
    return inner;
}

/// A group header inside a pane: `LABEL  n ─────` in `muted`, the rule in
/// `rule`, filling `width`.
pub fn groupHeader(surface: *Surface, x: u16, y: u16, width: u16, label: []const u8, count: []const u8, theme: *const w.Theme, opts: w.text.DrawOptions) !void {
    // Without the fill: drawn with it, the spans would take the whole width.
    var spans_opts = opts;
    spans_opts.fill = null;
    var used = try w.text.drawSpans(surface, x, y, width, &.{
        .{ .text = label, .role = .muted, .style = .{ .bold = true } },
        .{ .text = if (count.len > 0) "  " else "", .role = .muted },
        .{ .text = count, .role = .muted },
        .{ .text = " " },
    }, theme, spans_opts);
    var rule = theme.style(.border);
    if (opts.fill) |f| rule.bg = f.bg;
    while (used < width) : (used += 1) try surface.put(x + used, y, .{ .text = "─", .style = rule });
}

test "a pane draws its header, hairline and right rule" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 20, 4);
    defer surface.deinit(&discard.writer);
    const theme: w.Theme = .default;
    const inner = try draw(&surface, .{ .width = 20, .height = 4 }, &theme, .{ .title = "Agents", .badge = "3", .rule_right = true });
    try std.testing.expectEqual(Region{ .x = 0, .y = 2, .width = 19, .height = 2 }, inner);
    const top = try w.text.rowText(a, &surface, 0);
    defer a.free(top);
    try std.testing.expectEqualStrings(" Agents          3 │", top);
    const line = try w.text.rowText(a, &surface, 1);
    defer a.free(line);
    try std.testing.expectEqualStrings("───────────────────│", line);
}
