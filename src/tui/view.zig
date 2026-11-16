//! Draws the main view into
//! a venom-term Surface with venom-term's widgets and the Venom theme:
//!
//! ```text
//! ╭ Agents ─── 3 live ╮╭ title ──────── ▲ needs you ╮╭ Agent ─────╮
//! │ grouped list      ││ transcript                 ││ inspector  │
//! │                   │╰────────────────────────────╯│ (≥120 cols)│
//! │                   │╭ Input ─────────────────────╮│            │
//! │                   ││ › input box                 ││            │
//! ╰───────────────────╯╰ mode, model, context meter ──╯╰────────────╯
//!  ▲ 1 need you · ◆ 1 running │ ~/venom-org │ NORMAL     i input  ? keys
//! ```
//!
//! venom's own status bar is the bottom row of the area venom draws, in
//! both chrome modes;
//! `▲ N need you` is filled gold while anything blocks.
//! The transcript's rows are transcript.zig's; the input box is
//! input_box.zig. The inspector's tabs fill in later.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const Surface = term.Surface;
const Region = term.Region;
const Style = term.Style;
const App = @import("app.zig").App;
const Area = @import("app.zig").Area;
const stateRole = @import("app.zig").stateRole;
const keys = @import("keys.zig");
const model = @import("model.zig");
const inbox_view = @import("inbox_view.zig");
const settings_view = @import("settings_view.zig");
const usage_view = @import("usage_view.zig");
const context_panel = @import("context_panel.zig");
const split = @import("split.zig");
const input_box = @import("input_box.zig");
const transcript_mod = @import("transcript.zig");
const workspaces = @import("workspaces.zig");
const new_agent = @import("new_agent.zig");
const fan_out = @import("fan_out.zig");
const inbox_mod = @import("inbox.zig");
const approval_card = @import("approval_card.zig");
const pane = @import("pane.zig");

/// Inspector column width, shown from `inspector_min` columns up.
const inspector_w = 34;
const inspector_min = 120;
/// Below this width a control pane shows only the list.
const control_min = 60;

pub fn render(app: *App, surface: *Surface) !void {
    // The theme's ground, not the terminal's: chrome styles and shell cells
    // leave their colours `.default`.
    surface.setDefaults(.{ .fg = app.chrome.foreground(), .bg = app.chrome.background() });
    try renderViews(app, surface);
    if (app.leader_timer.visible() and surface.height >= 2) try leaderPopup(app, surface);
    if (app.quit_prompt) try quitOverlay(app, surface);
}

/// The quit confirmation: what quitting this last TUI stops.
fn quitOverlay(app: *App, surface: *Surface) !void {
    const a = app.frame.allocator();
    const theme = &app.crypt;
    const text = try app.quitPromptText(a);
    const bw: u16 = @min(surface.width -| 4, 72);
    if (bw < 12 or surface.height < 6) return;
    // Word-wrapped into the box.
    var lines: std.ArrayList([]const u8) = .empty;
    var rest = text;
    const room = bw -| 4;
    while (rest.len > 0) {
        if (w.text.width(rest) <= room) {
            try lines.append(a, rest);
            break;
        }
        var cut: usize = 0;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (rest[i] == ' ') {
                if (w.text.width(rest[0..i]) > room) break;
                cut = i;
            }
        }
        if (cut == 0) cut = @min(rest.len, room);
        try lines.append(a, rest[0..cut]);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    const bh: u16 = @intCast(@min(surface.height -| 2, lines.items.len + 4));
    const region: Region = .{ .x = (surface.width -| bw) / 2, .y = (surface.height -| bh) / 3, .width = bw, .height = bh };
    const inner = try w.box.draw(surface, region, theme, .{ .title = "Quit venom", .focused = true, .role = .warn, .clear = true });
    for (lines.items, 0..) |line, i| {
        const y = inner.y + @as(u16, @intCast(i));
        if (y + 1 >= inner.y + inner.height) break;
        _ = try w.text.drawText(surface, inner.x + 1, y, inner.width -| 2, line, .normal, theme, .{ .ellipsis = true });
    }
    _ = try w.text.drawText(surface, inner.x + 1, inner.y + inner.height -| 1, inner.width -| 2, "⏎ quit    esc stay", .secondary, theme, .{});
}

/// The leader popup, over everything but the bar, with
/// the tree's own rows, so what it says is what the keys do.
fn leaderPopup(app: *App, surface: *Surface) !void {
    const a = app.frame.allocator();
    const bare = app.solo and app.connected and app.message.items.len == 0;
    const area: Region = .{ .width = surface.width, .height = if (bare) surface.height else surface.height - 1 };
    const popup = term.chrome.leader_popup;
    // `leader leader` gets its row with the switcher.
    const m = try popup.model(a, "venom", &app.leader, .{ .key = app.key_settings.leader });
    _ = try w.leader_popup.draw(surface, area, &app.crypt, m, .{});
}

fn renderViews(app: *App, surface: *Surface) !void {
    _ = app.frame.reset(.retain_capacity);
    const a = app.frame.allocator();
    const W = surface.width;
    const H = surface.height;
    const theme = &app.theme;
    try surface.clear(.{ .width = W, .height = H }, theme.style(.normal));
    surface.setCursor(null);
    if (H < 2) return statusBar(app, surface, .{ .width = W, .height = 1 });
    // An agent's pane has no bar, only a line while
    // there is something to say.
    const bare = app.solo and app.connected and app.message.items.len == 0;
    const main: Region = .{ .width = W, .height = H - chromeRows(app, H, bare) };
    if (app.screen == .inbox) {
        try inbox_view.render(app, surface, main);
        try bottomRows(app, surface, W, H, bare);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    if (app.screen == .workspaces) {
        try workspaces.render(app, surface, main);
        try bottomRows(app, surface, W, H, bare);
        if (app.dialog != null) try new_agent.draw(app, surface, main);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    if (app.screen == .usage) {
        try usage_view.render(app, surface, main);
        try bottomRows(app, surface, W, H, bare);
        if (app.context_panel.agent != null) try context_panel.draw(app, surface, main);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    if (app.screen == .settings) {
        try settings_view.render(app, surface, main);
        try bottomRows(app, surface, W, H, bare);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    // A narrow control pane is the list and the bar,
    // until a key moves focus to the input box or a split.
    const list_only = app.host != null and W < control_min and app.area() == .list and app.splits.items.len == 0;
    const side_w: u16 = if (app.solo) 0 else if (list_only) W else std.math.clamp(W * 30 / 100, @min(24, W), 44);
    // Own-mode splits take the inspector's room.
    const insp_w: u16 = if (!app.solo and !list_only and W >= inspector_min and app.splits.items.len == 0) inspector_w else 0;
    const cols = w.layout.splitN(3, main, .horizontal, .{ .{ .fixed = side_w }, .{ .fill = 1 }, .{ .fixed = insp_w } });

    // Agent list.
    if (!app.solo) {
        const r = try app.buildRows();
        try app.syncCursor(r);
        const live = app.model.agents.items.len - app.model.count(isArchived);
        const list_inner = try pane.draw(surface, cols[0], theme, .{ .title = "AGENTS", .focused = app.area() == .list, .rule_right = !list_only });
        try groupSwitch(app, surface, cols[0]);
        var rows_area = list_inner;
        if (list_inner.height > 0) {
            // The filter row: the filter while there is one, else what `/`
            // filters on and how many agents are live.
            const row: Region = .{ .x = list_inner.x + @min(list_inner.width, 1), .y = list_inner.y, .width = list_inner.width -| 2, .height = 1 };
            if (app.filtering or app.filter_input.value().len > 0) {
                try app.filter_input.draw(surface, row, theme, app.filtering);
            } else {
                const count = try std.fmt.allocPrint(a, "{d} live", .{live});
                const cw: u16 = @intCast(@min(w.text.width(count), row.width));
                _ = try w.text.drawSpans(surface, row.x, row.y, row.width -| (cw + 1), &.{
                    .{ .text = "/ ", .role = .normal, .style = .{ .bold = true } },
                    .{ .text = "filter: harness, repo, issue, text", .role = .muted },
                }, theme, .{ .ellipsis = true });
                _ = try w.text.drawText(surface, row.x + row.width - cw, row.y, cw, count, .muted, theme, .{});
            }
            rows_area.y += 1;
            rows_area.height -= 1;
            if (r.rows.len == 0 and app.filter_input.value().len > 0 and rows_area.height > 0) _ = try w.text.drawText(surface, rows_area.x + @min(rows_area.width, 1), rows_area.y, rows_area.width -| 1, "No agent matches.", .faint, theme, .{ .ellipsis = true });
        }
        if (r.rows.len > 0 or app.filter_input.value().len == 0) try app.list.draw(surface, rows_area, r, theme, app.area() == .list and !app.filtering);
    }
    if (list_only) {
        try bottomRows(app, surface, W, H, bare);
        if (app.menu) |m| try menuOverlay(app, surface, a, m, main);
        if (app.ask) |q| try askOverlay(app, surface, a, q, main);
        if (app.pager != null) try pagerOverlay(app, surface, a, main);
        if (app.dialog != null) try new_agent.draw(app, surface, main);
        if (app.context_panel.agent != null) try context_panel.draw(app, surface, main);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }

    // Splits beside the main view: left ones, the main view, right ones.
    var slots: [1 + split.max]Region = undefined;
    const main_col = blk: {
        const n = app.splits.items.len;
        if (n == 0) break :blk cols[1];
        const fill: [1 + split.max]w.layout.Constraint = @splat(.{ .fill = 1 });
        w.layout.split(cols[1], .horizontal, fill[0 .. n + 1], slots[0 .. n + 1]);
        var slot: usize = 0;
        for (app.splits.items) |sp| if (sp.side == .left) {
            slot += 1;
        };
        const main_slot = slot;
        var left: usize = 0;
        var right: usize = main_slot + 1;
        for (app.splits.items, 0..) |*sp, i| {
            const r = if (sp.side == .left) l: {
                left += 1;
                break :l slots[left - 1];
            } else r: {
                right += 1;
                break :r slots[right - 1];
            };
            try splitPane(app, surface, a, sp, r, app.focusedSplit() == i);
        }
        break :blk slots[main_slot];
    };

    // Selected agent: transcript, then the input box. A rule sets the
    // column off from the inspector or a split on its right.
    var centre_col = main_col;
    if (main_col.x + main_col.width < surface.width and centre_col.width > 1) {
        centre_col.width -= 1;
        for (centre_col.y..centre_col.y + centre_col.height) |y| try surface.put(centre_col.x + centre_col.width, @intCast(y), .{ .text = "│", .style = theme.style(.border) });
    }
    const centre = w.layout.stacked(centre_col, .{ .fixed = input_box.height });
    const sel = app.model.find(app.selected.items);
    const badge = if (sel) |s| try std.fmt.allocPrint(a, "{s} {s}", .{ s.state.glyph(), s.state.label() }) else "";
    const title = if (sel) |s| try fan_out.breadcrumb(app, a, s, centre[0].width -| w.text.width(badge) -| 8) else "No agent";
    const tx = try pane.draw(surface, centre[0], theme, .{ .title = title, .badge = badge, .focused = app.area() == .transcript, .role = if (sel != null and sel.?.state.blocking()) .warn else null });
    const pad: Region = .{ .x = tx.x + @min(tx.width, 1), .y = tx.y, .width = tx.width -| 2, .height = tx.height };
    const blocks = try transcript(app, a, &app.rows, &app.model.detail, app.selected.items, true, pad.width);
    app.scroll.selected = app.rows.selectedIndex();
    try app.fetchBodies(&app.rows, app.selected.items);
    try transcript_mod.keepPlace(app.gpa, &app.scroll, &app.rows, &app.model.detail, blocks, pad.width);
    transcript_mod.skipUnchanged(&app.scroll, &app.rows, blocks, pad);
    try app.scroll.draw(app.gpa, surface, pad, blocks, theme, app.area() == .transcript);
    try app.readOlder(&app.model.detail, &app.scroll, pad.height, null);
    const prompt_in_split = if (app.focusedSplit()) |i| app.splits.items[i].kind == .agent_view else false;
    if (app.prompt != null and !prompt_in_split) {
        // An inline attention key asked for text.
        const p = app.prompt.?;
        const box = try w.box.draw(surface, centre[1], theme, .{ .border = .single, .title = p.mode.title(), .badge = if (sel) |s| s.id else "", .focused = true });
        try app.answer_input.draw(surface, box, theme, true);
    } else try input_box.draw(app, surface, a, centre[1], sel, &app.model.detail);

    if (insp_w > 0) try inspector(app, surface, a, cols[2]);
    try bottomRows(app, surface, W, H, bare);
    if (app.menu) |m| try menuOverlay(app, surface, a, m, main);
    if (app.ask) |q| try askOverlay(app, surface, a, q, main);
    if (app.pager != null) try pagerOverlay(app, surface, a, main);
    if (app.dialog != null) try new_agent.draw(app, surface, main);
    if (app.context_panel.agent != null) try context_panel.draw(app, surface, main);
    if (app.help) try helpOverlay(app, surface, a);
    // A focused shell shows its own cursor.
    if (!app.help and app.pager == null and app.menu == null and app.ask == null and app.prompt == null and app.dialog == null) if (app.focusedSplit()) |i| if (app.splits.items[i].shell) |sh| {
        const cur = sh.vt.cursor();
        const inner = app.splits.items[i].area;
        if (cur.visible and cur.x < inner.width and cur.y < inner.height) surface.setCursor(.{ .x = inner.x + cur.x, .y = inner.y + cur.y });
    };
}

/// One split: an agent view of its agent, or the shell.
fn splitPane(app: *App, surface: *Surface, a: std.mem.Allocator, sp: *split.Split, region: Region, focused: bool) !void {
    const theme = &app.theme;
    // A rule on the right, unless the split is at the screen's edge.
    const edge = region.x + region.width < surface.width;
    switch (sp.kind) {
        .agent_view => {
            const ag = app.model.find(sp.agent);
            const badge = if (ag) |s| try std.fmt.allocPrint(a, "{s} {s}", .{ s.state.glyph(), s.state.label() }) else "";
            const title = if (ag) |s| try fan_out.breadcrumb(app, a, s, region.width -| w.text.width(badge) -| 8) else sp.agent;
            // As the main view: the transcript, then the input box.
            sp.area = region;
            const parts = w.layout.stacked(region, .{ .fixed = input_box.height });
            const in_box = focused and sp.in_box;
            const inner = try pane.draw(surface, parts[0], theme, .{ .title = title, .badge = badge, .focused = focused and !in_box, .clear = true, .rule_right = edge });
            const pad: Region = .{ .x = inner.x + @min(inner.width, 1), .y = inner.y, .width = inner.width -| 2, .height = inner.height };
            const blocks = try transcript(app, a, &sp.rows, &sp.detail, sp.agent, true, pad.width);
            sp.scroll.selected = sp.rows.selectedIndex();
            try app.fetchBodies(&sp.rows, sp.agent);
            try transcript_mod.keepPlace(app.gpa, &sp.scroll, &sp.rows, &sp.detail, blocks, pad.width);
            transcript_mod.skipUnchanged(&sp.scroll, &sp.rows, blocks, pad);
            try sp.scroll.draw(app.gpa, surface, pad, blocks, theme, focused and !in_box);
            try app.readOlder(&sp.detail, &sp.scroll, pad.height, sp);
            if (focused and app.prompt != null) {
                // An attention key here asked for text: it is answered here.
                const p = app.prompt.?;
                const box = try w.box.draw(surface, parts[1], &app.crypt, .{ .border = .single, .title = p.mode.title(), .badge = sp.agent, .focused = true, .clear = true });
                sp.box_area = box;
                try app.answer_input.draw(surface, box, &app.crypt, true);
            } else try input_box.drawFor(app, surface, a, parts[1], ag, &sp.detail, .{ .input = app.boxOf(sp.agent).?, .focused = in_box, .area = &sp.box_area });
        },
        .shell, .take_over => {
            if (sp.exited) {
                const inner = try pane.draw(surface, region, theme, .{ .title = if (sp.kind == .shell) "Shell" else sp.harness, .badge = sp.agent, .focused = focused, .clear = true, .rule_right = edge });
                sp.area = inner;
                _ = try w.text.drawText(surface, inner.x + 1, inner.y, inner.width -| 2, try std.fmt.allocPrint(a, "[process exited]  esc or {s} leaves", .{app.leaveTerminalText()}), .muted, theme, .{ .ellipsis = true });
                return;
            }
            const sh = sp.shell.?;
            // In own mode the split is marked; in
            // host mode venomx's pane.attention does it.
            const waiting = sp.kind == .take_over and if (app.itemOf(sp.agent)) |it| it.away and it.kind.blocking() else false;
            const title = if (sp.kind == .shell) "Shell" else try std.fmt.allocPrint(a, "{s}⇄ {s}", .{ if (waiting) "▲ " else "", sp.harness });
            const badge = if (sp.kind == .shell) tail(try app.shortPath(a, sp.cwd), region.width -| 12) else sp.agent;
            const inner = try pane.draw(surface, region, theme, .{ .title = title, .badge = if (waiting) "needs you" else badge, .focused = focused, .clear = true, .role = if (waiting) .warn else null, .rule_right = edge });
            sp.area = inner;
            if (inner.width == 0 or inner.height == 0) return;
            try sh.resize(.{ .cols = inner.width, .rows = inner.height });
            try sh.view.draw(sh.vt, surface, inner);
        },
    }
}

/// `p` / `J`: a body, or the raw tool JSON, over the
/// main view.
fn pagerOverlay(app: *App, surface: *Surface, a: std.mem.Allocator, main: Region) !void {
    _ = a;
    const pg = &app.pager.?;
    const inner = try w.box.draw(surface, main, &app.crypt, .{ .title = pg.title, .badge = "esc closes", .focused = true, .clear = true });
    const pad: Region = .{ .x = inner.x + @min(inner.width, 1), .y = inner.y, .width = inner.width -| 2, .height = inner.height };
    try pg.scroll.draw(app.gpa, surface, pad, try pg.blocks(app.gpa), &app.crypt, true);
}

/// The split menu, over the main view.
fn menuOverlay(app: *App, surface: *Surface, a: std.mem.Allocator, m: split.Menu, main: Region) !void {
    const theme = &app.crypt;
    const ag = app.model.find(m.agent);
    const harness = if (ag) |s| s.harness else "";
    const folder = if (ag) |s| std.fs.path.basename(s.cwd) else "";
    const title = if (ag) |s| (if (s.title.len > 0) s.title else s.id) else m.agent;
    const bw: u16 = @min(main.width -| 4, 72);
    const bh: u16 = @min(main.height, @as(u16, @intCast(m.opts.len * 3)) + 3);
    const region: Region = .{ .x = main.x + (main.width -| bw) / 2, .y = main.y + (main.height -| bh) / 3, .width = bw, .height = bh };
    const side = if (m.side == .right) "h l side: right" else "h l side: left";
    const inner = try w.box.draw(surface, region, theme, .{ .title = try std.fmt.allocPrint(a, "Split · {s}", .{title}), .badge = side, .focused = true, .clear = true });
    for (m.opts.slice(), 0..) |o, i| {
        const y = inner.y + 1 + @as(u16, @intCast(i * 3));
        if (y + 1 >= inner.y + inner.height) break;
        const on = i == m.cursor;
        const num = try std.fmt.allocPrint(a, "{d}", .{i + 1});
        _ = try w.text.drawText(surface, inner.x + 1, y, 2, num, .secondary, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 4, y, inner.width -| 14, try o.title(a, harness), .normal, theme, .{ .ellipsis = true, .overlay = .{ .bold = true, .reverse = on } });
        if (o == .agent_view) _ = try w.text.drawText(surface, inner.x + inner.width -| 9, y, 8, "default", .muted, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 4, y + 1, inner.width -| 5, try o.description(a, harness, folder), .muted, theme, .{ .ellipsis = true });
    }
}

fn isArchived(s: model.State) bool {
    return s == .archived;
}

/// The transcript of `d` (the main view's detail, or an agent-view
/// split's); `inline_attention` adds the agent's inbox item and its keys.
fn transcript(app: *App, a: std.mem.Allocator, rows: *transcript_mod.View, d: *const model.Detail, agent: []const u8, inline_attention: bool, width: u16) ![]const w.Block {
    var out: std.ArrayList(w.Block) = .empty;
    const rev = d.revision;
    if (app.model.agents.items.len == 0) {
        try out.append(a, .{ .spans = try spans(a, &.{.{ .text = "No agents yet. Start one with venom agent spawn --cwd=<folder> --task=<text>.", .role = .faint }}), .revision = rev });
        return out.items;
    }
    try fan_out.fetch(app, agent);
    try out.appendSlice(a, try rows.build(app.gpa, d, try app.optionsFor(agent), width));
    // An approval waiting here is asked as one card, after the rows.
    const approval: ?*const inbox_mod.Item = if (inline_attention) blk: {
        const it = app.itemOf(agent) orelse break :blk null;
        break :blk if (it.kind == .approval and !it.away and width >= approval_card.min_width) it else null;
    } else null;
    for (d.requests.items) |q| {
        if (approval != null) break;
        // Its call's row shows it, open.
        const on_row = q.call.len > 0 and for (d.records.items) |*r| {
            if (r.kind == .tool and std.mem.eql(u8, r.tool.call, q.call)) break true;
        } else false;
        if (on_row) continue;
        try out.append(a, .{ .spans = try spans(a, &.{
            .{ .text = "▲ ", .role = .warn },
            .{ .text = q.kind, .role = .warn, .style = .{ .bold = true } },
            .{ .text = ": " },
            .{ .text = q.reason },
            .{ .text = if (q.stale) "  (its harness process is gone)" else "", .role = .muted },
        }), .revision = rev });
    }
    // Inline attention: the agent's most urgent inbox item and
    // its keys, answered here with the transcript focused.
    if (if (inline_attention) app.itemOf(agent) else null) |it| {
        const inbox_rev = rev +% app.inbox.revision *% 31 +% @as(u32, @truncate(app.picks.n)) *% 131;
        const resets = if (it.kind == .limit) try @import("inbox.zig").resetsAtLabel(a, it.resets_at, app.utc_offset_override, @divFloor(app.now_ms, 1000)) else "";
        if (it.away or it.kind == .failed or it.kind == .limit or it.kind == .review) try out.append(a, .{ .spans = try spans(a, &.{
            .{ .text = it.kind.glyph(), .role = @import("app.zig").kindRole(it.kind) },
            .{ .text = " " },
            .{ .text = @tagName(it.kind), .role = @import("app.zig").kindRole(it.kind), .style = .{ .bold = true } },
            .{ .text = ": " },
            .{ .text = it.reason },
            .{ .text = if (resets.len > 0) "  · " else "", .role = .muted },
            .{ .text = resets, .role = .muted },
        }), .revision = inbox_rev });
        if (it.kind == .question and !it.away) {
            app.drawn = .{ .item = inbox_mod.itemHash(it), .sig = inbox_mod.optionsSig(it) };
            const done = app.picks.count(it);
            for (try inbox_mod.optionRows(a, it, app.picks.chosen[0..done])) |row| try out.append(a, .{ .spans = try spans(a, &.{
                .{ .text = row.mark, .role = if (row.header) .muted else .secondary },
                .{ .text = if (row.header) "" else " " },
                .{ .text = row.text, .role = if (row.header) .muted else .normal },
            }), .indent = if (row.header) 2 else 4, .revision = inbox_rev });
        }
        try out.append(a, .{ .spans = try spans(a, &.{
            .{ .text = keys.itemHints(it), .role = .accent },
            .{ .text = if (it.grant.len > 0) try std.fmt.allocPrint(a, "  · grant {s}", .{it.grant}) else "", .role = .muted },
            .{ .text = if (app.answersHere(agent) or it.away) "" else "  · ⇥ to answer here", .role = .muted },
        }), .indent = 2, .revision = inbox_rev });
    }
    if (out.items.len == 0) try out.append(a, .{ .spans = try spans(a, &.{.{ .text = if (d.stale) "loading…" else "No turns yet.", .role = .faint }}), .revision = rev });
    return out.items;
}

fn spans(a: std.mem.Allocator, s: []const w.Span) ![]const w.Span {
    return a.dupe(w.Span, s);
}

/// `STATE WORKSPACE REPO` at the right of the agents' header, the
/// current grouping (`g`) in `bone` bold; only the current one when the
/// header is short of room.
fn groupSwitch(app: *App, surface: *Surface, region: Region) !void {
    const theme = &app.theme;
    const names = [_][]const u8{ "STATE", "WORKSPACE", "REPO" };
    const current: usize = @backingInt(app.group_by);
    const right = region.x + region.width -| 2;
    const all_w: u16 = 5 + 9 + 4 + 2;
    const title_end = region.x + 1 + 6 + 2;
    if (right < title_end) return;
    if (right - title_end >= all_w) {
        var x = right - all_w;
        for (names, 0..) |n, i| {
            x += try w.text.drawText(surface, x, region.y, @intCast(n.len), n, if (i == current) .normal else .muted, theme, .{ .overlay = .{ .bold = true } });
            if (i + 1 < names.len) x += 1;
        }
    } else {
        const n = names[current];
        if (right - title_end >= n.len) _ = try w.text.drawText(surface, right - @as(u16, @intCast(n.len)), region.y, @intCast(n.len), n, .normal, theme, .{ .overlay = .{ .bold = true } });
    }
}

/// The selected agent beside the transcript: its tree, where it works, what
/// it has used and what it is linked to. Sections take the rows that fit.
fn inspector(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region) !void {
    const theme = &app.theme;
    const inner = try pane.draw(surface, region, theme, .{ .title = "AGENT" });
    const s = app.model.find(app.selected.items) orelse return;
    const Kv = struct { k: []const u8, v: []const u8, role: w.Role = .secondary };
    var y = inner.y;
    const bottom = inner.y + inner.height;
    const x = inner.x + 1;
    const width = inner.width -| 2;

    // Agent tree: the agent and its children.
    {
        if (y >= bottom) return;
        _ = try w.text.drawText(surface, x, y, width, "TREE", .muted, theme, .{ .overlay = .{ .bold = true } });
        y += 1;
        if (y >= bottom) return;
        _ = try w.text.drawSpans(surface, x, y, width, &.{
            .{ .text = s.state.glyph(), .role = @import("app.zig").stateRole(s.state) },
            .{ .text = " " },
            .{ .text = if (s.title.len > 0) s.title else s.id, .role = .normal },
        }, theme, .{ .ellipsis = true });
        y += 1;
        var kids: std.ArrayList(*const model.Agent) = .empty;
        for (app.model.agents.items) |*c| if (std.mem.eql(u8, c.parent, s.id)) try kids.append(a, c);
        for (kids.items, 0..) |c, i| {
            if (y >= bottom) return;
            _ = try w.text.drawSpans(surface, x, y, width, &.{
                .{ .text = if (i + 1 == kids.items.len) "└─ " else "├─ ", .role = .faint },
                .{ .text = c.state.glyph(), .role = @import("app.zig").stateRole(c.state) },
                .{ .text = " " },
                .{ .text = if (c.title.len > 0) c.title else c.id, .role = .secondary },
                .{ .text = if (c.native) "  native" else "", .role = .muted },
            }, theme, .{ .ellipsis = true });
            y += 1;
        }
    }
    const here = std.mem.eql(u8, app.model.detail.agent, s.id);
    const d = &app.model.detail;
    const context: []const u8 = if (here) if (d.context) |c| if (input_box.meter(c.used, c.window, d.warn_at)) |m| try std.fmt.allocPrint(a, "{d}% · {s} / {s}", .{ m.percent, try input_box.tokens(a, c.used), try input_box.tokens(a, c.window) }) else "" else "" else "";
    const sections = [_]struct { title: []const u8, rows: []const Kv }{
        .{ .title = "WORKTREE", .rows = &.{
            .{ .k = "cwd", .v = try app.shortPath(a, s.cwd) },
            .{ .k = "workspace", .v = try app.shortPath(a, s.workspace) },
            .{ .k = "repos", .v = if (s.repos.len > 0) s.repos else "whole workspace" },
        } },
        .{ .title = "THIS AGENT", .rows = &.{
            .{ .k = "id", .v = s.id },
            .{ .k = "state", .v = s.state.label(), .role = @import("app.zig").stateRole(s.state) },
            .{ .k = "harness", .v = s.harness },
            .{ .k = "model", .v = if (here) d.model else "" },
            .{ .k = "turns", .v = if (here) try std.fmt.allocPrint(a, "{d}", .{d.turns}) else "" },
            .{ .k = "context", .v = context },
        } },
        .{ .title = "LINKED", .rows = &.{
            .{ .k = "issue", .v = if (s.issue.len > 0) try std.fmt.allocPrint(a, "#{s}", .{s.issue}) else "none", .role = if (s.issue.len > 0) .secondary else .muted },
            .{ .k = "parent", .v = if (s.parent.len > 0) s.parent else "none", .role = if (s.parent.len > 0) .secondary else .muted },
        } },
    };
    for (sections) |sec| {
        // A hairline between sections, then the label.
        if (y >= bottom) return;
        for (inner.x..inner.x + inner.width) |cx| try surface.put(@intCast(cx), y, .{ .text = "─", .style = theme.style(.border) });
        y += 1;
        if (y >= bottom) return;
        _ = try w.text.drawText(surface, x, y, width, sec.title, .muted, theme, .{ .overlay = .{ .bold = true } });
        y += 1;
        for (sec.rows) |row| {
            if (row.v.len == 0) continue;
            if (y >= bottom) return;
            const vw: u16 = @intCast(@min(w.text.width(row.v), width -| 11));
            _ = try w.text.drawText(surface, x, y, width -| vw -| 1, row.k, .muted, theme, .{ .ellipsis = true });
            _ = try w.text.drawText(surface, x + width - vw, y, vw, row.v, row.role, theme, .{ .ellipsis = true });
            y += 1;
        }
    }
}

/// venom's own status bar.
/// Take over mid-turn asks first.
fn askOverlay(app: *App, surface: *Surface, a: std.mem.Allocator, q: split.Ask, main: Region) !void {
    const theme = &app.crypt;
    const ag = app.model.find(q.agent);
    const harness = if (ag) |s| s.harness else "";
    const title = if (ag) |s| (if (s.title.len > 0) s.title else s.id) else q.agent;
    const n = split.Ask.choices.len;
    const bw: u16 = @min(main.width -| 4, 72);
    const bh: u16 = @min(main.height, @as(u16, @intCast(n * 3)) + 4);
    const region: Region = .{ .x = main.x + (main.width -| bw) / 2, .y = main.y + (main.height -| bh) / 3, .width = bw, .height = bh };
    const inner = try w.box.draw(surface, region, theme, .{ .title = try std.fmt.allocPrint(a, "Take over in {s} · {s}", .{ harness, title }), .badge = "a turn is running", .focused = true, .role = .warn, .clear = true });
    _ = try w.text.drawText(surface, inner.x + 1, inner.y, inner.width -| 2, "Only one client can drive the agent. When should it move?", .muted, theme, .{ .ellipsis = true });
    for (split.Ask.choices, 0..) |choice, i| {
        const y = inner.y + 2 + @as(u16, @intCast(i * 3));
        if (y + 1 >= inner.y + inner.height) break;
        const on = i == q.cursor;
        _ = try w.text.drawText(surface, inner.x + 1, y, 2, try std.fmt.allocPrint(a, "{d}", .{i + 1}), .secondary, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 4, y, inner.width -| 14, choice.title(), .normal, theme, .{ .ellipsis = true, .overlay = .{ .bold = true, .reverse = on } });
        if (choice == .after_turn) _ = try w.text.drawText(surface, inner.x + inner.width -| 9, y, 8, "default", .muted, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 4, y + 1, inner.width -| 5, choice.description(), .muted, theme, .{ .ellipsis = true });
    }
}

/// The bar, or in an agent's pane just the message or the offline notice.
fn bottomLine(app: *App, surface: *Surface, region: Region) !void {
    if (!app.solo) return statusBar(app, surface, region);
    const text = if (app.message.items.len > 0) app.message.items else "✕ daemon offline, reconnecting";
    _ = try w.text.drawText(surface, region.x + 1, region.y, region.width -| 2, text, .warn, &app.theme, .{ .ellipsis = true });
}

/// Rows under the views: the key hints, then the status bar. An agent's
/// pane has neither, only a line while there is something to say.
fn chromeRows(app: *const App, H: u16, bare: bool) u16 {
    if (bare) return 0;
    if (app.solo or H < 4) return 1;
    return 2;
}

fn bottomRows(app: *App, surface: *Surface, W: u16, H: u16, bare: bool) !void {
    switch (chromeRows(app, H, bare)) {
        0 => {},
        1 => try bottomLine(app, surface, .{ .y = H - 1, .width = W, .height = 1 }),
        else => {
            try hintsRow(app, surface, .{ .y = H - 2, .width = W, .height = 1 });
            try statusBar(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
        },
    }
}

const Hint = struct { text: []const u8, warned: bool };

/// What the hint row says: a message or a notice, else the keys of what has
/// focus. A notice stands in for the hints that are only reminders, not for
/// those of a mode a key opened: it is back when that mode ends, and no key
/// clears it.
fn hintText(app: *App, a: std.mem.Allocator) !Hint {
    const focused_kind: ?split.Kind = if (app.focusedSplit()) |i| app.splits.items[i].kind else null;
    const in_box = app.inFocusedBox();
    const shell_focused = focused_kind == .shell or focused_kind == .take_over;
    const notice = if (app.host) |h| h.notice() else null;
    const hint = if (app.message.items.len > 0)
        app.message.items
    else if (app.context_panel.agent != null)
        try context_panel.hint(app, a)
    else if (app.screen == .usage)
        usage_view.hint(app)
    else if (app.filtering)
        "⏎ esc keep  ⌃c clear  ↑ ↓ move"
    else if (app.dialog != null)
        "⇥ next field  h l change  space pick  esc cancel"
    else if (app.screen == .workspaces)
        (if (app.panel.adding) "⏎ add  esc cancel" else "n new agent here  N pick workspace  R rescan repos  + add folder  esc back")
    else if (app.pager != null)
        "j k scroll  esc close"
    else if (notice == null and app.screen == .main and app.area() == .transcript and app.prompt == null and app.menu == null and app.ask == null and app.itemOf(app.selected.items) == null and hasFamily(app))
        "] child  [ parent  ⏎ open row  ? keys"
    else if (notice == null and app.screen == .main and app.area() == .transcript and app.prompt == null and app.menu == null and app.ask == null and app.itemOf(app.selected.items) == null)
        "⏎ open row  v density  E C all  p pager  J raw  ? keys"
    else if (app.prompt != null)
        "⏎ send  esc cancel"
    else if (app.menu) |m|
        try std.fmt.allocPrint(a, "1–{d} pick  j k move  ⏎ open  h l side  esc cancel", .{m.opts.len})
    else if (app.ask != null)
        "1–3 pick  j k move  ⏎ choose  esc cancel"
    else if (app.focusedSplit() != null and app.splits.items[app.focusedSplit().?].exited)
        try std.fmt.allocPrint(a, "esc or {s} leaves", .{app.leaveTerminalText()})
    else if (focused_kind == .take_over)
        try std.fmt.allocPrint(a, "{s} leaves, then T takes back", .{app.leaveTerminalText()})
    else if (shell_focused)
        try std.fmt.allocPrint(a, "{s} leaves", .{app.leaveTerminalText()})
    else if (app.screen == .settings)
        settings_view.hint(app)
    else if (app.screen == .inbox)
        (if (try app.currentItem()) |it| try std.fmt.allocPrint(a, "{s}  esc back  ? keys", .{if (app.single_view) keys.popupHints(it) else keys.itemHints(it)}) else "esc back  ? keys")
    else if (notice) |n|
        n
    else if (in_box)
        app.inputHint()
    else if (app.area() == .split)
        (if (app.itemOf(app.splits.items[app.focusedSplit().?].agent)) |it| try std.fmt.allocPrint(a, "{s}  ⇥ input  {s} v x close split", .{ keys.itemHints(it), app.leaderText() }) else try std.fmt.allocPrint(a, "⏎ open row  ⇥ input  {s} v x close split  \\ split  ? keys", .{app.leaderText()}))
    else if (app.splits.items.len > 0)
        try std.fmt.allocPrint(a, "⏎ open  i input  \\ split  {s} v x close split  ? keys", .{app.leaderText()})
    else
        try std.fmt.allocPrint(a, "⏎ open  i input  n new  d diff  ! next  {s} more  ? keys", .{app.leaderText()});
    const noticed = notice != null and hint.ptr == notice.?.ptr;
    return .{ .text = hint, .warned = app.message.items.len > 0 or noticed };
}

/// The key hints: each key in `bone` bold, its label in `muted`. A message
/// or a notice is read whole, in `warn`.
fn hintsRow(app: *App, surface: *Surface, region: Region) !void {
    const a = app.frame.allocator();
    const theme = &app.theme;
    try surface.clear(region, theme.style(.normal));
    const h = try hintText(app, a);
    const x0 = region.x + @min(region.width, 1);
    const room = region.width -| 2;
    if (h.warned) {
        _ = try w.text.drawText(surface, x0, region.y, room, h.text, .warn, theme, .{ .ellipsis = true });
        return;
    }
    var out: std.ArrayList(w.Span) = .empty;
    var items = std.mem.tokenizeSequence(u8, h.text, "  ");
    while (items.next()) |item| {
        if (out.items.len > 0) try out.append(a, .{ .text = "   " });
        var words = std.mem.tokenizeScalar(u8, std.mem.trim(u8, item, " "), ' ');
        var first = true;
        var in_label = false;
        while (words.next()) |word| {
            const key = !in_label and (first or (isKeyWord(word) and words.peek() != null));
            if (!first) try out.append(a, .{ .text = " " });
            first = false;
            if (!key) in_label = true;
            try out.append(a, if (key) .{ .text = word, .role = .normal, .style = .{ .bold = true } } else .{ .text = word, .role = .muted });
        }
    }
    _ = try w.text.drawSpans(surface, x0, region.y, room, out.items, theme, .{ .ellipsis = true });
}

/// A word of a hint that names a key rather than says what it does: one or
/// two cells, a named key, or anything with a symbol or a digit in it.
fn isKeyWord(word: []const u8) bool {
    if (w.text.width(word) <= 2) return true;
    for ([_][]const u8{ "esc", "space", "tab", "enter", "home", "end" }) |k| if (std.mem.eql(u8, word, k)) return true;
    for (word) |c| if (c >= 0x80 or std.ascii.isDigit(c)) return true;
    return false;
}

/// venom's status bar, one row on `grave`: the venom block in the signal
/// with the fang cut (`◤`), the views with `▸` before the active one, a
/// spacer, then segments split by `│` in `rule`. Short of room the
/// segments drop by priority, then the views but the active one.
fn statusBar(app: *App, surface: *Surface, region: Region) !void {
    const a = app.frame.allocator();
    const chrome = app.chrome;
    const bar = chrome.statusBar();
    try surface.clear(region, bar);
    const right = region.x + region.width;
    const on_bar = struct {
        fn of(c: term.theme.Chrome, b: Style, sw: term.theme.Swatch, bold: bool) Style {
            var s = c.text(sw);
            s.bg = b.bg;
            s.bold = bold;
            return s;
        }
    }.of;
    const muted = on_bar(chrome, bar, chrome.theme.muted, false);
    const active = on_bar(chrome, bar, chrome.theme.bone, true);
    const signal = on_bar(chrome, bar, chrome.edition.signal(chrome.theme), false);
    const rule = on_bar(chrome, bar, chrome.theme.rule, false);

    // Left: the block and its fang.
    var x = try put(surface, region.x, region.y, right, " venom ", chrome.sessionBlock());
    x = try put(surface, x, region.y, right, "◤", signal);

    // Right: segments, most important first; the last ones drop first.
    const Seg = struct { spans: [3]struct { text: []const u8 = "", style: Style = .{} } = .{ .{}, .{}, .{} } };
    var segs: std.ArrayList(Seg) = .empty;
    if (!app.connected) try segs.append(a, .{ .spans = .{ .{ .text = "✕ daemon offline, reconnecting", .style = on_bar(chrome, bar, chrome.theme.danger, true) }, .{}, .{} } });
    const blocking = app.model.count(model.State.blocking);
    const running = app.model.count(isRunning);
    {
        var mode: Style = .{ .fg = chrome.color(chrome.theme.bone), .bg = chrome.color(chrome.theme.ash), .bold = true };
        if (chrome.mode == .ansi16) mode = .{ .reverse = true, .bold = true };
        try segs.append(a, .{ .spans = .{
            .{ .text = try std.fmt.allocPrint(a, " {s} ", .{app.keyMode().label()}), .style = mode },
            .{ .text = if (app.leader.pending()) " " else "", .style = bar },
            .{ .text = if (app.leader.pending()) " LEADER " else "", .style = mode },
        } });
    }
    try segs.append(a, .{ .spans = .{
        .{ .text = "▲ ", .style = if (blocking > 0) on_bar(chrome, bar, chrome.theme.warn, true) else muted },
        .{ .text = try std.fmt.allocPrint(a, "{d} need you", .{blocking}), .style = if (blocking > 0) on_bar(chrome, bar, chrome.theme.warn, true) else bar },
        .{},
    } });
    try segs.append(a, .{ .spans = .{
        .{ .text = "◆ ", .style = on_bar(chrome, bar, chrome.theme.info, false) },
        .{ .text = try std.fmt.allocPrint(a, "{d} running", .{running}), .style = bar },
        .{},
    } });
    const sel = app.model.find(app.selected.items);
    if (sel) |s| try segs.append(a, .{ .spans = .{ .{ .text = tail(try app.shortPath(a, s.workspace), 24), .style = bar }, .{}, .{} } });
    if (app.now_ms > 0) try segs.append(a, .{ .spans = .{ .{ .text = try clock(a, app.now_ms, app.utc_offset_override), .style = bar }, .{}, .{} } });

    const segWidth = struct {
        fn of(sg: Seg) u16 {
            var n: usize = 0;
            for (sg.spans) |sp| n += w.text.width(sp.text);
            return @intCast(n);
        }
    }.of;
    // Views.
    const Screen = @import("app.zig").Screen;
    const views = [_]struct { screen: Screen, name: []const u8 }{
        .{ .screen = .main, .name = "agents" },
        .{ .screen = .inbox, .name = "inbox" },
        .{ .screen = .workspaces, .name = "workspaces" },
        .{ .screen = .usage, .name = "usage" },
        .{ .screen = .settings, .name = "settings" },
    };
    const inbox_n = app.inbox.items.items.len;
    var names: [views.len][]const u8 = undefined;
    var views_w: u16 = 0;
    var active_w: u16 = 0;
    for (views, 0..) |v, i| {
        names[i] = if (v.screen == .inbox and inbox_n > 0) try std.fmt.allocPrint(a, "inbox {d}", .{inbox_n}) else v.name;
        const vw: u16 = @intCast(w.text.width(names[i]) + 2);
        views_w += vw;
        if (v.screen == app.screen) active_w = vw;
    }
    var n = segs.items.len;
    const total = struct {
        fn of(list: []const Seg) u16 {
            var t: u16 = 0;
            for (list) |sg| t += segWidth(sg) + 3;
            return t;
        }
    }.of;
    const left_w = x - region.x;
    while (n > 1 and left_w + active_w + total(segs.items[0..n]) + 1 > region.width) n -= 1;
    const all_views = left_w + views_w + total(segs.items[0..n]) + 1 <= region.width;
    for (views, 0..) |v, i| {
        const on = v.screen == app.screen;
        if (!on and !all_views) continue;
        x = try put(surface, x, region.y, right, " ", bar);
        if (on) {
            x = try put(surface, x, region.y, right, "▸", signal);
            x = try put(surface, x, region.y, right, names[i], active);
        } else {
            x = try put(surface, x, region.y, right, names[i], muted);
        }
        x = try put(surface, x, region.y, right, " ", bar);
    }
    // Segments from the right edge.
    var rx: u16 = right -| 1;
    var i = n;
    while (i > 0) {
        i -= 1;
        const sg = segs.items[i];
        const sw = segWidth(sg);
        if (rx < x + sw + 3) break;
        rx -= sw;
        var cx = rx;
        for (sg.spans) |sp| cx = try put(surface, cx, region.y, right, sp.text, sp.style);
        rx -= 3;
        _ = try put(surface, rx, region.y, right, " │ ", rule);
    }
}

/// `14:32` in local time; `override` fixes the UTC offset (tests).
fn clock(a: std.mem.Allocator, now_ms: i64, override: ?i32) ![]const u8 {
    const now_s = @divFloor(now_ms, 1000);
    const off: i64 = override orelse @import("inbox.zig").localUtcOffset(now_s);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, now_s + off)) };
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
}

/// The last `max` columns of a path, with `…` in front when cut.
fn tail(path: []const u8, max: usize) []const u8 {
    if (w.text.width(path) <= max) return path;
    var start = path.len - max;
    while (start < path.len and (path[start] & 0xC0) == 0x80) start += 1;
    if (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| start = slash;
    return path[start..];
}

/// The selected agent has a parent or children, so `[` and `]` go somewhere.
fn hasFamily(app: *const App) bool {
    const sel = app.model.find(app.selected.items) orelse return false;
    if (sel.parent.len > 0) return true;
    for (app.model.agents.items) |*x| if (std.mem.eql(u8, x.parent, sel.id)) return true;
    return false;
}

fn isRunning(s: model.State) bool {
    return s == .running;
}

fn put(surface: *Surface, x: u16, y: u16, right: u16, value: []const u8, style: Style) !u16 {
    if (x >= right) return x;
    try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, value, style);
    return @intCast(@min(@as(usize, x) + w.text.width(value), right));
}

fn helpOverlay(app: *App, surface: *Surface, a: std.mem.Allocator) !void {
    const theme = &app.crypt;
    // Each screen's own keys.
    var shown: std.ArrayList(keys.Binding) = .empty;
    const tree_here = app.dialog == null and app.context_panel.agent == null and !(app.screen == .settings and app.settings.standalone) and !app.single_view;
    for (keys.table) |b| {
        const here = app.help_all or switch (b.context) {
            .any => true,
            .leader => tree_here,
            .leader_own => tree_here and app.host == null,
            .dialog => app.dialog != null,
            .inbox, .attention => app.dialog == null and app.screen == .inbox,
            .workspaces => app.dialog == null and app.screen == .workspaces,
            .settings => app.dialog == null and app.screen == .settings,
            .usage => app.dialog == null and app.screen == .usage and app.context_panel.agent == null,
            .context => app.context_panel.agent != null,
            else => app.dialog == null and app.screen == .main and app.context_panel.agent == null,
        };
        if (here and !(app.single_view and b.opensAgent())) try shown.append(a, b);
    }
    const bw: u16 = @min(surface.width -| 4, 76);
    const bh: u16 = @min(surface.height -| 2, @as(u16, @intCast(shown.items.len)) + 4);
    const region: Region = .{ .x = (surface.width - bw) / 2, .y = (surface.height -| bh) / 2, .width = bw, .height = bh };
    const inner = try w.box.draw(surface, region, theme, .{ .title = if (app.help_all) "All keys" else "Keys", .badge = "j k scroll, other keys close", .focused = true, .clear = true });
    // The leader rows are as long as the leader makes them.
    var key_w: u16 = 9;
    for (shown.items) |*b| key_w = @max(key_w, @as(u16, @intCast(w.text.width(try keys.shownKeys(a, b, app.leaderText())))) + 1);
    const rows_fit: usize = inner.height -| 1;
    app.help_top = @intCast(@min(app.help_top, shown.items.len -| rows_fit));
    for (shown.items[app.help_top..], 0..) |*b, i| {
        if (i + 1 >= inner.height) break;
        const y = inner.y + 1 + @as(u16, @intCast(i));
        const what = switch (b.action) {
            .verb => |v| try std.fmt.allocPrint(a, "venom {s}", .{try cliPath(a, v)}),
            .attention => |at| if (at.verb()) |v| try std.fmt.allocPrint(a, "venom {s}", .{try cliPath(a, v)}) else "local",
            .local => "local",
        };
        // The one rebindable key shows what it is bound to.
        const shown_keys = if (b.action == .local and b.action.local == .leave_terminal) app.leaveTerminalText() else try keys.shownKeys(a, b, app.leaderText());
        _ = try w.text.drawText(surface, inner.x + 1, y, key_w, shown_keys, .secondary, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 1 + key_w, y, inner.width -| (25 + key_w), b.label, .normal, theme, .{ .ellipsis = true });
        _ = try w.text.drawText(surface, inner.x + inner.width -| 23, y, 22, what, .muted, theme, .{ .ellipsis = true });
    }
}

/// `agent.stop` → `agent stop`.
fn cliPath(a: std.mem.Allocator, verb: []const u8) ![]const u8 {
    const out = try a.dupe(u8, verb);
    std.mem.replaceScalar(u8, out, '.', ' ');
    std.mem.replaceScalar(u8, out, '_', '-');
    return out;
}
