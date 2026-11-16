//! Draws the settings screen:
//!
//! ```text
//! ╭ Settings ─╮╭ 02 Agents ──────── ╮╭ ~/.config/venom/config.zon ─ 1 unsaved ╮
//! │ 00 General││ Harness     codex ▾││       .default = .claude_code,         │
//! │ 01 Worksp…││   for a new agent  ││ -     .max_concurrent = 4,             │
//! │ 02 Agents ││ ● Max agents     6 ││ +     .max_concurrent = 6,             │
//! │           ││                    ││ Same change from a shell               │
//! │ Layer user││                    ││   venom config set --key=agents…        │
//! ╰───────────╯╰────────────────────╯╰────────────────────────────────────────╯
//! ```
//!
//! Below `preview_min` columns the preview sits under the rows. It scrolls.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const Surface = term.Surface;
const Region = term.Region;
const App = @import("app.zig").App;
const settings = @import("settings.zig");
const zon_text = @import("zon_text.zig");
const pane = @import("pane.zig");

const nav_w = 28;
const preview_w = 52;
const preview_min = 110;

pub fn render(app: *App, surface: *Surface, main: Region) !void {
    const a = app.frame.allocator();
    const s = &app.settings;
    const left_w: u16 = @min(nav_w, main.width / 3);
    const cols = w.layout.sideBySide(main, .{ .fixed = left_w });
    try nav(app, surface, a, cols[0]);
    var center = cols[1];
    var preview_region: Region = .{ .width = 0, .height = 0 };
    if (main.width >= preview_min) {
        const parts = w.layout.splitN(2, cols[1], .horizontal, .{ .{ .fill = 1 }, .{ .fixed = preview_w } });
        center = parts[0];
        preview_region = parts[1];
    } else {
        const parts = w.layout.stacked(cols[1], .{ .fixed = @min(cols[1].height / 2, 14) });
        center = parts[0];
        preview_region = parts[1];
    }
    if (s.editing != null) {
        const parts = w.layout.stacked(center, .{ .fixed = 3 });
        center = parts[0];
        const f = s.editing.?;
        const box = try w.box.draw(surface, parts[1], &app.theme, .{ .border = .single, .title = f.label, .badge = f.key, .focused = true });
        try s.input.draw(surface, box, &app.theme, true);
    }
    try rows(app, surface, a, center);
    try preview(app, surface, a, preview_region);
}

fn nav(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region) !void {
    const theme = &app.theme;
    const s = &app.settings;
    const focused = s.focus == .sections and s.editing == null;
    const inner = try pane.draw(surface, region, theme, .{ .title = "SETTINGS", .focused = focused, .rule_right = true });
    if (inner.width < 6) return;
    for (settings.sections, 0..) |sec, i| {
        if (i >= inner.height) break;
        const y = inner.y + @as(u16, @intCast(i));
        const on = i == s.section;
        // The selected section: `grave`, `▌` in the signal, its number
        // in the signal and its name in `bone`.
        const fill = if (on) w.theme.overlay(theme.style(.normal), theme.style(.selection)) else theme.style(.normal);
        const opts: w.text.DrawOptions = .{ .ellipsis = true, .fill = fill, .overlay = if (on) theme.style(.selection) else null };
        try surface.clear(.{ .x = inner.x, .y = y, .width = inner.width, .height = 1 }, fill);
        if (on) try surface.put(inner.x, y, .{ .text = "▌", .style = w.theme.overlay(theme.style(.accent), theme.style(.selection)) });
        const num = try std.fmt.allocPrint(a, "{d:0>2}", .{i});
        _ = try w.text.drawText(surface, inner.x + 2, y, 2, num, if (on) .accent else .muted, theme, opts);
        _ = try w.text.drawText(surface, inner.x + 5, y, inner.width -| 6, sec.name, if (on) .normal else .secondary, theme, opts);
    }
    const n: u16 = settings.sections.len;
    if (inner.height < n + 6) return;
    const l = s.currentLayer();
    const y = inner.y + n + 1;
    for (inner.x..inner.x + inner.width) |cx| try surface.put(@intCast(cx), y, .{ .text = "─", .style = theme.style(.border) });
    _ = try w.text.drawSpans(surface, inner.x + 2, y + 1, inner.width -| 3, &.{
        .{ .text = "SCOPE  ", .role = .muted, .style = .{ .bold = true } },
        .{ .text = l.name(), .role = .normal, .style = .{ .bold = true } },
        .{ .text = "  S", .role = .muted },
    }, theme, .{ .ellipsis = true });
    const where: []const u8 = if (l.repo) |r| r else if (l.workspace) |p| std.fs.path.basename(p) else "";
    _ = try w.text.drawText(surface, inner.x + 2, y + 2, inner.width -| 3, where, .muted, theme, .{ .ellipsis = true });
    _ = try w.text.drawText(surface, inner.x + 2, y + 3, inner.width -| 3, "user → workspace → repo.", .muted, theme, .{ .ellipsis = true });
    _ = try w.text.drawText(surface, inner.x + 2, y + 4, inner.width -| 3, "The narrower file wins;", .muted, theme, .{ .ellipsis = true });
    if (inner.height >= n + 7) _ = try w.text.drawText(surface, inner.x + 2, y + 5, inner.width -| 3, "● set in this layer.", .muted, theme, .{ .ellipsis = true });
}

fn rows(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region) !void {
    const theme = &app.theme;
    const s = &app.settings;
    const sec = settings.sections[s.section];
    var title_buf: [96]u8 = undefined;
    const title = std.ascii.upperString(title_buf[0..@min(sec.name.len, title_buf.len)], sec.name[0..@min(sec.name.len, title_buf.len)]);
    const number = try std.fmt.allocPrint(a, "{d:0>2}", .{s.section});
    const inner = try pane.draw(surface, region, theme, .{ .title = title, .number = number, .focused = s.focus == .rows and s.editing == null, .rule_right = region.x + region.width < surface.width });
    const list = try s.rows(a);
    if (list.len == 0) {
        const text: []const u8 = if (s.effective == null) "loading…" else "No values.";
        _ = try w.text.drawText(surface, inner.x + 1, inner.y, inner.width -| 2, text, .faint, theme, .{});
        return;
    }
    if (inner.width < 4 or inner.height == 0) return;
    // Two lines a row: keep the cursor in sight.
    const fit: usize = @max(inner.height / 2, 1);
    if (s.row >= list.len) s.row = list.len - 1;
    if (s.row < s.top) s.top = s.row;
    if (s.row >= s.top + fit) s.top = s.row + 1 - fit;
    const layer = s.currentLayer();
    for (list[s.top..@min(s.top + fit, list.len)], s.top..) |row, i| {
        const y = inner.y + @as(u16, @intCast((i - s.top) * 2));
        const on = i == s.row and s.focus == .rows;
        // The row under the cursor: `grave` on both its lines, `▌` in the
        // signal.
        const fill = if (on) w.theme.overlay(theme.style(.normal), theme.style(.selection)) else theme.style(.normal);
        const sel: ?term.Style = if (on) theme.style(.selection) else null;
        const two: u16 = if (inner.height > y - inner.y + 1) 2 else 1;
        try surface.clear(.{ .x = inner.x, .y = y, .width = inner.width, .height = two }, fill);
        if (on) for (0..two) |dy| try surface.put(inner.x, y + @as(u16, @intCast(dy)), .{ .text = "▌", .style = w.theme.overlay(theme.style(.accent), theme.style(.selection)) });
        switch (row) {
            .info => |info| {
                if (info.mark) |m| _ = try w.text.drawText(surface, inner.x + 2, y, 1, if (m == .ok) "●" else "▲", if (m == .ok) .ok else .warn, theme, .{ .overlay = sel });
                _ = try w.text.drawText(surface, inner.x + 4, y, inner.width -| 5, info.title, if (on) .normal else .secondary, theme, .{ .ellipsis = true, .overlay = sel, .fill = fill });
                if (inner.height > y - inner.y + 1) _ = try w.text.drawText(surface, inner.x + 4, y + 1, inner.width -| 5, info.detail, .muted, theme, .{ .ellipsis = true, .overlay = sel, .fill = fill });
            },
            .field => |f| {
                const editable = s.editable(f.key);
                const failed = if (s.failure) |x| std.mem.eql(u8, x.key, f.key) else false;
                const pending = s.isPending(f.key);
                // ● the current layer sets it; ✕ the daemon refused it.
                const source = s.sourceOf(f.key);
                const here = std.mem.eql(u8, source, layer.name());
                if (failed) {
                    _ = try w.text.drawText(surface, inner.x + 2, y, 1, "✕", .err, theme, .{ .overlay = sel });
                } else if (here) _ = try w.text.drawText(surface, inner.x + 2, y, 1, "●", .secondary, theme, .{ .overlay = sel });
                const shown = try valueText(a, f, s.value(f.key));
                const vw: u16 = @min(@as(u16, @intCast(@min(w.text.width(shown), 200))), inner.width / 2);
                const label_w = inner.width -| (vw + 6);
                const bold: ?term.Style = if (pending) w.theme.overlay(sel orelse .{}, .{ .bold = true }) else sel;
                _ = try w.text.drawText(surface, inner.x + 4, y, label_w -| 1, f.label, if (on) .normal else if (editable) .secondary else .faint, theme, .{ .ellipsis = true, .overlay = bold });
                _ = try w.text.drawText(surface, inner.x + inner.width -| (vw + 2), y, vw, shown, if (failed) .err else if (pending) .warn else if (editable) .normal else .faint, theme, .{ .ellipsis = true, .overlay = bold });
                if (inner.height <= y - inner.y + 1) continue;
                const detail = if (!editable)
                    try std.fmt.allocPrint(a, "user-only · {s}", .{f.key})
                else if (f.help.len > 0)
                    try std.fmt.allocPrint(a, "{s} · {s}", .{ f.key, f.help })
                else
                    f.key;
                _ = try w.text.drawText(surface, inner.x + 4, y + 1, inner.width -| 6, detail, .muted, theme, .{ .ellipsis = true, .overlay = sel, .fill = fill });
            },
        }
    }
}

/// A field's value as its row shows it.
fn valueText(a: std.mem.Allocator, f: settings.Field, value: ?[]const u8) ![]const u8 {
    const v = value orelse return "…";
    return switch (f.kind) {
        .toggle => if (std.mem.eql(u8, v, "true")) "[on]" else "[off]",
        .choice => try std.fmt.allocPrint(a, "{s} ▾", .{v[1..]}),
        .text => if (v.len == 0 or std.mem.eql(u8, v, "null")) "none" else settings.displayValue(v),
        .zon => v,
    };
}

const Line = struct { text: []const u8 = "", role: w.Role = .normal };

/// Appends `text` wrapped to `width`, at spaces where it can: nothing is cut.
fn addWrapped(a: std.mem.Allocator, out: *std.ArrayList(Line), text: []const u8, role: w.Role, width: u16) !void {
    var rest = text;
    if (rest.len == 0) return out.append(a, .{ .role = role });
    while (rest.len > 0) {
        var cut = cutAt(rest, @max(width, 1));
        if (cut < rest.len) if (std.mem.lastIndexOfScalar(u8, rest[0..cut], ' ')) |space| {
            // Not in the indentation: that would make no progress on the text.
            if (std.mem.trim(u8, rest[0..space], " ").len > 0) cut = space + 1;
        };
        try out.append(a, .{ .text = rest[0..cut], .role = role });
        rest = rest[cut..];
    }
}

/// Everything the preview says, wrapped to `width`.
fn previewLines(app: *App, a: std.mem.Allocator, width: u16) ![]const Line {
    const s = &app.settings;
    var out: std.ArrayList(Line) = .empty;
    if (s.pending.items.len == 0) {
        try addWrapped(a, &out, "No pending changes. Every field here is a config key.", .faint, width);
    } else {
        for (try s.pendingDiff(a)) |line| {
            const mark: []const u8 = switch (line.kind) {
                .context => "  ",
                .del => "- ",
                .add => "+ ",
                .gap => "  …",
            };
            const role: w.Role = switch (line.kind) {
                .context => .secondary,
                .del => .err,
                .add => .ok,
                .gap => .muted,
            };
            try addWrapped(a, &out, try std.fmt.allocPrint(a, "{s}{s}", .{ mark, line.text }), role, width);
        }
        try out.append(a, .{});
        try out.append(a, .{ .text = "SAME CHANGE FROM A SHELL", .role = .muted });
        for (s.pending.items) |p| try addWrapped(a, &out, try s.command(a, p), .accent, width);
    }
    try out.append(a, .{});
    try out.append(a, .{ .text = "CHECKS", .role = .muted });
    if (s.failure) |f| {
        try addWrapped(a, &out, try std.fmt.allocPrint(a, "✕ {s}", .{if (f.key.len > 0) f.key else "config"}), .err, width);
        try addWrapped(a, &out, try std.fmt.allocPrint(a, "  {s}", .{f.code}), .err, width);
        if (f.path.len > 0) try addWrapped(a, &out, try std.fmt.allocPrint(a, "  {s}", .{try app.shortPath(a, f.path)}), .muted, width);
    } else if (s.effective != null) try out.append(a, .{ .text = "● config valid", .role = .ok });
    if (s.restart_required) try addWrapped(a, &out, "▲ restart the daemon for it to apply", .warn, width);
    if (s.pending.items.len > 0) {
        try out.append(a, .{});
        try out.append(a, .{ .text = if (s.applying) "saving…" else "u undo  ⌃s save and reload", .role = .accent });
    }
    return out.items;
}

fn preview(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region) !void {
    if (region.width == 0 or region.height == 0) return;
    const theme = &app.theme;
    const s = &app.settings;
    const n = s.pending.items.len;
    const inner = try pane.draw(surface, region, theme, .{
        .title = tail(try app.shortPath(a, s.filePath()), region.width -| 16),
        .badge = if (n > 0) try std.fmt.allocPrint(a, "{d} unsaved", .{n}) else "saved",
        .focused = s.focus == .preview and s.editing == null,
        .role = if (s.failure != null) .err else null,
    });
    if (inner.width < 4 or inner.height == 0) return;
    const x = inner.x + 1;
    const width = inner.width -| 2;
    const lines = try previewLines(app, a, width);
    // It scrolls: nobody should approve a change they cannot see. The last
    // row then says there is more.
    const clipped = lines.len > inner.height;
    const page: usize = if (clipped) inner.height -| 1 else inner.height;
    s.preview_page = @max(page, 1);
    s.preview_top = @min(s.preview_top, lines.len -| page);
    for (lines[s.preview_top..@min(s.preview_top + page, lines.len)], 0..) |line, i| {
        _ = try w.text.drawText(surface, x, inner.y + @as(u16, @intCast(i)), width, line.text, line.role, theme, .{});
    }
    if (clipped) {
        const below = lines.len - s.preview_top - page;
        const more = if (below > 0)
            try std.fmt.allocPrint(a, "↓ {d} more: ⇟, or ⇥ then j", .{below})
        else
            "↑ top: ⇞, or ⇥ then k";
        _ = try w.text.drawText(surface, x, inner.y + inner.height - 1, width, more, .warn, theme, .{ .ellipsis = true });
    }
}

/// The end of `path` that fits in `max` columns: the file's name matters most.
fn tail(path: []const u8, max: usize) []const u8 {
    if (w.text.width(path) <= max) return path;
    var start = path.len -| max;
    while (start < path.len and (path[start] & 0xC0) == 0x80) start += 1;
    return path[start..];
}

/// The bytes of `text` that fit in `width` columns, on a character boundary.
fn cutAt(text: []const u8, width: u16) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const next = w.text.nextGrapheme(text, i);
        used += w.text.graphemeWidth(text[i..next]);
        if (used > width) return @max(i, 1);
        i = next;
    }
    return text.len;
}

pub fn hint(app: *const App) []const u8 {
    if (app.settings.editing != null) return "⏎ keep  esc cancel";
    return "j k move  ⇥ next pane  ⏎ edit  h l step  S layer  u undo  ⌃s save  esc back  ? keys";
}
