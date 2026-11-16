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
const config = @import("../config.zig");
const providers = @import("providers.zig");

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
        const box = try w.box.draw(surface, parts[1], &app.crypt, .{ .border = .single, .title = f.label, .badge = f.key, .focused = true, .clear = true });
        try s.input.draw(surface, box, &app.crypt, true);
    }
    try rows(app, surface, a, center);
    try preview(app, surface, a, preview_region);
    if (s.popup) |*p| try p.draw(surface, main, &app.crypt, a, try s.popupProblem(a));
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
        // and its name in `bone`.
        const fill = if (on) w.theme.overlay(theme.style(.normal), theme.style(.selection)) else theme.style(.normal);
        const opts: w.text.DrawOptions = .{ .ellipsis = true, .fill = fill, .overlay = if (on) theme.style(.selection) else null };
        try surface.clear(.{ .x = inner.x, .y = y, .width = inner.width, .height = 1 }, fill);
        if (on) try surface.put(inner.x, y, .{ .text = "▌", .style = w.theme.overlay(theme.style(.accent), theme.style(.selection)) });
        const num = try std.fmt.allocPrint(a, "{d:0>2}", .{i});
        _ = try w.text.drawText(surface, inner.x + 2, y, 2, num, if (on) .normal else .muted, theme, opts);
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
    if (s.section == settings.providers_section) return providerTable(app, surface, a, inner, list);
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
            // Only the Providers section has these, and `providerTable` draws it.
            .provider => {},
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

/// The Providers section: a header with its action, then a card a
/// provider, or what a provider is when there is none.
///
/// ```text
///  PROVIDERS  named logins of claude-code and codex ──────── n New provider
///
///  ┌──────────────────────────────────────────────────────────────────────┐
///  │ ● claude     claude-code · signed in, max plan   default  ⏎ Configure │
///  │              default login · model default · permission venom's def… │
///  └──────────────────────────────────────────────────────────────────────┘
/// ```
///
/// The card under the cursor has a border in the signal and the selection
/// fill; one marked for removal (`x`) a border in `err` and its name struck.
fn providerTable(app: *App, surface: *Surface, a: std.mem.Allocator, inner: Region, list: []const settings.Row) !void {
    const theme = &app.theme;
    const s = &app.settings;
    const x0 = inner.x + 1;
    const right = inner.x + inner.width -| 1;
    const room = right -| x0;
    var y = inner.y;
    const bottom = inner.y + inner.height;
    // Header: the group label, what it holds, a rule, the action.
    {
        const action_w: u16 = @intCast(w.text.width("n New provider"));
        var x = x0;
        x += try w.text.drawText(surface, x, y, room, "PROVIDERS", .muted, theme, .{ .overlay = .{ .bold = true } });
        x += 2;
        const about_w = right -| (action_w + 2) -| x;
        x += try w.text.drawText(surface, x, y, about_w, "named logins of claude-code and codex", .faint, theme, .{ .ellipsis = true });
        if (x + 1 < right -| (action_w + 1)) {
            for (x + 1..right -| (action_w + 1)) |cx| try surface.put(@intCast(cx), y, .{ .text = "─", .style = theme.style(.border) });
        }
        if (room > action_w + 8) _ = try w.text.drawSpans(surface, right -| action_w, y, action_w, &.{
            .{ .text = "n", .role = .accent, .style = .{ .bold = true } },
            .{ .text = " New provider", .role = .normal },
        }, theme, .{});
        y += 2;
    }
    if (y >= bottom) return;
    const empty = list.len > 0 and list[0] == .provider and list[0].provider.index == null;
    if (empty) {
        const on = s.focus == .rows;
        const lines = [_]struct { []const u8, w.Role }{
            .{ "No providers yet.", .normal },
            .{ "A provider is a named login of claude-code or codex: its own config dir,", .secondary },
            .{ "default model and permission, like work and personal Max accounts side by side.", .secondary },
            .{ "Until there is one, agents run agents.default with the harness's own login.", .muted },
            .{ "", .muted },
        };
        for (lines) |l| {
            if (y >= bottom) return;
            _ = try w.text.drawText(surface, x0 + 2, y, room -| 2, l[0], l[1], theme, .{ .ellipsis = true, .overlay = .{ .bold = l[1] == .normal } });
            y += 1;
        }
        if (y < bottom) _ = try w.text.drawSpans(surface, x0 + 2, y, room -| 2, &.{
            .{ .text = "⏎", .role = if (on) .accent else .normal, .style = .{ .bold = true } },
            .{ .text = " or ", .role = .muted },
            .{ .text = "n", .role = if (on) .accent else .normal, .style = .{ .bold = true } },
            .{ .text = "  configure the first provider", .role = .secondary },
        }, theme, .{ .ellipsis = true });
        // A warning row after it (the default names no provider).
        y += 2;
        for (list[1..], 1..) |row, i| {
            if (y >= bottom) return;
            if (row == .info) try infoLine(app, surface, a, inner, y, row.info.title, row.info.detail, i == s.row and on);
            y += 1;
        }
        return;
    }
    var name_w: u16 = 8;
    for (list) |row| if (row == .provider) {
        name_w = @max(name_w, @as(u16, @intCast(@min(w.text.width(row.provider.name), 24))));
    };
    // Four lines a card, cards edge to edge: keep the cursor in sight.
    const card_h: u16 = 4;
    const fit: usize = @max((bottom - y) / card_h, 1);
    if (s.row >= list.len) s.row = list.len - 1;
    if (s.row < s.top) s.top = s.row;
    if (s.row >= s.top + fit) s.top = s.row + 1 - fit;
    for (list[s.top..@min(s.top + fit, list.len)], s.top..) |row, i| {
        if (y >= bottom) break;
        const on = i == s.row and s.focus == .rows;
        switch (row) {
            .provider => |r| {
                const armed = if (s.remove_armed) |n| std.mem.eql(u8, n, r.name) else false;
                const card: Region = .{ .x = x0, .y = y, .width = room, .height = @min(card_h, bottom - y) };
                const body = try w.box.draw(surface, card, theme, .{ .border = .single, .role = if (armed) .err else if (on) .accent else .border, .clear = true });
                if (body.width < 8 or body.height == 0) {
                    y += card.height;
                    continue;
                }
                const fill = if (on) w.theme.overlay(theme.style(.normal), theme.style(.selection)) else theme.style(.normal);
                const sel: ?term.Style = if (on) theme.style(.selection) else null;
                try surface.clear(body, fill);
                const opts: w.text.DrawOptions = .{ .ellipsis = true, .overlay = sel, .fill = fill };
                const bx = body.x + 1;
                const bright = body.x + body.width -| 1;
                if (r.mark) |m| _ = try w.text.drawText(surface, bx, body.y, 1, if (m == .ok) "●" else "▲", if (m == .ok) .ok else .warn, theme, opts);
                const nx = bx + 2;
                const nw = @min(name_w, bright -| nx);
                _ = try w.text.drawText(surface, nx, body.y, nw, r.name, if (armed) .err else .normal, theme, .{ .ellipsis = true, .overlay = w.theme.overlay(sel orelse .{}, .{ .bold = true, .strikethrough = armed }), .fill = fill });
                const dx = nx + nw + 3;
                // Right of the first line: the pill, then the action.
                const pill: []const u8 = if (r.default) "default" else if (r.mark == .warn) "needs sign-in" else "enabled";
                const pill_role: w.Role = if (r.default) .accent else if (r.mark == .warn) .muted else .secondary;
                const action = "⏎ Configure";
                const right_w: u16 = @intCast(w.text.width(pill) + 2 + w.text.width(action));
                var line_end = bright;
                if (bright > dx + right_w + 16) {
                    line_end = bright -| (right_w + 2);
                    var px = line_end + 2;
                    const pw: u16 = @intCast(w.text.width(pill));
                    _ = try w.text.drawText(surface, px, body.y, pw, pill, pill_role, theme, .{ .overlay = w.theme.overlay(sel orelse .{}, .{ .bold = r.default }) });
                    px += pw + 2;
                    _ = try w.text.drawSpans(surface, px, body.y, bright -| px, &.{
                        .{ .text = "⏎", .role = if (on) .normal else .muted, .style = .{ .bold = true } },
                        .{ .text = " Configure", .role = if (on) .normal else .muted },
                    }, theme, opts);
                }
                if (dx < line_end) {
                    _ = try w.text.drawSpans(surface, dx, body.y, line_end - dx, &.{
                        .{ .text = r.harness, .role = .secondary },
                        .{ .text = " · ", .role = .muted },
                        .{ .text = r.status, .role = if (r.mark == .warn) .warn else .muted },
                    }, theme, opts);
                    if (body.height > 1) {
                        const detail = try std.fmt.allocPrint(a, "{s} · model {s} · permission {s}", .{ r.login, r.model, r.permission });
                        const risky = std.mem.eql(u8, r.permission, "bypassPermissions");
                        _ = try w.text.drawText(surface, dx, body.y + 1, bright -| dx, detail, if (risky) .warn else .muted, theme, opts);
                    }
                }
                y += card.height;
            },
            .info => |info| {
                try infoLine(app, surface, a, inner, y, info.title, info.detail, on);
                y += 2;
            },
            .field => {},
        }
    }
}

/// A warning line of the Providers section, with the selection when `on`.
fn infoLine(app: *App, surface: *Surface, a: std.mem.Allocator, inner: Region, y: u16, title: []const u8, detail: []const u8, on: bool) !void {
    const theme = &app.theme;
    const sel: ?term.Style = if (on) theme.style(.selection) else null;
    const fill = if (on) w.theme.overlay(theme.style(.normal), theme.style(.selection)) else theme.style(.normal);
    try surface.clear(.{ .x = inner.x, .y = y, .width = inner.width, .height = 1 }, fill);
    if (on) try surface.put(inner.x, y, .{ .text = "▌", .style = w.theme.overlay(theme.style(.accent), theme.style(.selection)) });
    _ = try w.text.drawText(surface, inner.x + 2, y, inner.width -| 3, try std.fmt.allocPrint(a, "▲ {s}. {s}", .{ title, detail }), .warn, theme, .{ .ellipsis = true, .overlay = sel, .fill = fill });
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

/// A preview line; with a `label`, the label in `muted` and the text after
/// it in a column.
const Line = struct { text: []const u8 = "", role: w.Role = .normal, label: []const u8 = "" };

const kv_label_w = 12;

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

/// The provider under the cursor, for the inspector: what it is, how to
/// sign it in, how to use it from a shell.
fn providerLines(app: *App, a: std.mem.Allocator, out: *std.ArrayList(Line), r: settings.ProviderRow, width: u16) !void {
    const s = &app.settings;
    const list = s.providerList(a);
    const i = r.index orelse return;
    if (i >= list.len) return;
    const p = list[i];
    const st = s.statusOf(p.name);
    try out.append(a, .{ .text = try std.fmt.allocPrint(a, "PROVIDER {s}{s}", .{ p.name, if (r.default) "  · default" else "" }), .role = .muted });
    const kv = struct {
        fn f(al: std.mem.Allocator, o: *std.ArrayList(Line), label: []const u8, text: []const u8, role: w.Role) !void {
            try o.append(al, .{ .label = label, .text = text, .role = role });
        }
    }.f;
    try kv(a, out, "harness", providers.harnessName(p.harness), .normal);
    const env = config.Provider.homeEnv(p.harness);
    try kv(a, out, "login", p.home orelse switch (p.harness) {
        .claude_code => "~/.claude (default)",
        .codex => "~/.codex (default)",
    }, .normal);
    try kv(a, out, "sets", env, .secondary);
    try kv(a, out, "model", p.model orelse "the harness's default", if (p.model == null) .muted else .normal);
    const choice = for (providers.modeChoices(p.harness)) |c| {
        if (c.mode == p.mode) break c;
    } else null;
    try kv(a, out, "permission", providers.modeLabel(p.harness, p.mode), if (choice != null and choice.?.risky) .warn else .normal);
    if (st) |x| {
        if (x.plan) |plan| try kv(a, out, "plan", plan, .normal);
        const signed: []const u8 = if (!x.available) "▲ harness off" else if (x.signed_in) |in| (if (in) "● signed in" else "▲ not signed in") else "▲ unknown";
        try kv(a, out, "status", signed, if (x.available and x.signed_in == true) .ok else .warn);
    } else try kv(a, out, "status", "checking…", .muted);
    try out.append(a, .{});
    const signed_out = if (st) |x| x.signed_in != true else true;
    try out.append(a, .{ .text = if (signed_out) "SIGN IN, FROM A SHELL" else "SIGN IN AGAIN, FROM A SHELL", .role = .muted });
    const cmd = if (st) |x| (if (x.sign_in.len > 0) x.sign_in else try providers.signInCommand(a, p)) else try providers.signInCommand(a, p);
    try addWrapped(a, out, cmd, if (signed_out) .warn else .normal, width);
    try out.append(a, .{});
    try out.append(a, .{ .text = "AN AGENT ON IT", .role = .muted });
    try addWrapped(a, out, try std.fmt.allocPrint(a, "venom agent spawn --provider={s} --task='…'", .{try shellWord(a, p.name)}), .normal, width);
    try out.append(a, .{ .text = "⏎ edit  d default  x remove", .role = .faint });
}

/// `name` as one shell word: as is when it is safe, else in single quotes.
fn shellWord(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) {
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '\'');
        for (name) |ch| if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
        try out.append(a, '\'');
        return out.items;
    };
    return name;
}

/// Everything the preview says, wrapped to `width`.
fn previewLines(app: *App, a: std.mem.Allocator, width: u16) ![]const Line {
    const s = &app.settings;
    var out: std.ArrayList(Line) = .empty;
    if (try s.selectedProvider(a)) |r| {
        try providerLines(app, a, &out, r, width);
        try out.append(a, .{});
    }
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
        for (s.pending.items) |p| try addWrapped(a, &out, try s.command(a, p), .normal, width);
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
        try out.append(a, .{ .text = if (s.applying) "saving…" else "u undo  ⌃s save and reload", .role = .secondary });
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
        const y = inner.y + @as(u16, @intCast(i));
        if (line.label.len > 0 and width > kv_label_w + 4) {
            _ = try w.text.drawText(surface, x, y, kv_label_w, line.label, .muted, theme, .{});
            _ = try w.text.drawText(surface, x + kv_label_w, y, width - kv_label_w, line.text, line.role, theme, .{ .ellipsis = true });
        } else _ = try w.text.drawText(surface, x, y, width, line.text, line.role, theme, .{});
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
    const s = &app.settings;
    if (s.popup) |p| return if (p.index == null) "⇥ ↑↓ field  h l choose  ⏎ add  esc cancel" else "⇥ ↑↓ field  h l choose  ⏎ save  ⌃d remove  esc cancel";
    if (s.editing == null and s.section == settings.providers_section and s.focus == .rows)
        return "j k move  ⏎ edit  n new  d default  x remove  ⇥ next pane  ⌃s save  esc back  ? keys";
    if (s.editing == null and s.section == settings.providers_section)
        return "j k move  n new provider  ⇥ next pane  S layer  ⌃s save  esc back  ? keys";
    if (app.settings.editing != null) return "⏎ keep  esc cancel";
    return "j k move  ⇥ next pane  ⏎ edit  h l step  S layer  u undo  ⌃s save  esc back  ? keys";
}
