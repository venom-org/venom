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
    _ = try w.leader_popup.draw(surface, area, &app.theme, m, .{});
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
    const main: Region = .{ .width = W, .height = if (bare) H else H - 1 };
    if (app.screen == .inbox) {
        try inbox_view.render(app, surface, main);
        if (!bare) try bottomLine(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    if (app.screen == .workspaces) {
        try workspaces.render(app, surface, main);
        try statusBar(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
        if (app.dialog != null) try new_agent.draw(app, surface, main);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    if (app.screen == .usage) {
        try usage_view.render(app, surface, main);
        try statusBar(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
        if (app.context_panel.agent != null) try context_panel.draw(app, surface, main);
        if (app.help) try helpOverlay(app, surface, a);
        return;
    }
    if (app.screen == .settings) {
        try settings_view.render(app, surface, main);
        try statusBar(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
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
        const list_inner = try w.box.draw(surface, cols[0], theme, .{ .title = "Agents", .badge = try std.fmt.allocPrint(a, "{d} live", .{live}), .focused = app.area() == .list });
        var rows_area = list_inner;
        if ((app.filtering or app.filter_input.value().len > 0) and list_inner.height > 0) {
            try app.filter_input.draw(surface, .{ .x = list_inner.x + @min(list_inner.width, 1), .y = list_inner.y, .width = list_inner.width -| 1, .height = 1 }, theme, app.filtering);
            rows_area.y += 1;
            rows_area.height -= 1;
            if (r.rows.len == 0 and rows_area.height > 0) _ = try w.text.drawText(surface, rows_area.x + @min(rows_area.width, 1), rows_area.y, rows_area.width -| 1, "No agent matches.", .faint, theme, .{ .ellipsis = true });
        }
        if (r.rows.len > 0 or app.filter_input.value().len == 0) try app.list.draw(surface, rows_area, r, theme, app.area() == .list and !app.filtering);
    }
    if (list_only) {
        try statusBar(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
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

    // Selected agent: transcript, then the input box.
    const centre = w.layout.stacked(main_col, .{ .fixed = input_box.height });
    const sel = app.model.find(app.selected.items);
    const badge = if (sel) |s| try std.fmt.allocPrint(a, "{s} {s}", .{ s.state.glyph(), s.state.label() }) else "";
    const title = if (sel) |s| try fan_out.breadcrumb(app, a, s, centre[0].width -| w.text.width(badge) -| 8) else "No agent";
    const tx = try w.box.draw(surface, centre[0], theme, .{ .title = title, .badge = badge, .focused = app.area() == .transcript, .role = if (sel != null and sel.?.state.blocking() and app.area() != .transcript) .warn else null });
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
        const box = try w.box.draw(surface, centre[1], theme, .{ .title = p.mode.title(), .badge = if (sel) |s| s.id else "", .focused = true });
        try app.answer_input.draw(surface, box, theme, true);
    } else try input_box.draw(app, surface, a, centre[1], sel, &app.model.detail);

    if (insp_w > 0) try inspector(app, surface, a, cols[2]);
    if (!bare) try bottomLine(app, surface, .{ .y = H - 1, .width = W, .height = 1 });
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
    switch (sp.kind) {
        .agent_view => {
            const ag = app.model.find(sp.agent);
            const badge = if (ag) |s| try std.fmt.allocPrint(a, "{s} {s}", .{ s.state.glyph(), s.state.label() }) else "";
            const title = if (ag) |s| try fan_out.breadcrumb(app, a, s, region.width -| w.text.width(badge) -| 8) else sp.agent;
            // As the main view: the transcript, then the input box.
            sp.area = region;
            const parts = w.layout.stacked(region, .{ .fixed = input_box.height });
            const in_box = focused and sp.in_box;
            const inner = try w.box.draw(surface, parts[0], theme, .{ .title = title, .badge = badge, .focused = focused and !in_box, .clear = true });
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
                const box = try w.box.draw(surface, parts[1], theme, .{ .title = p.mode.title(), .badge = sp.agent, .focused = true, .clear = true });
                sp.box_area = box;
                try app.answer_input.draw(surface, box, theme, true);
            } else try input_box.drawFor(app, surface, a, parts[1], ag, &sp.detail, .{ .input = app.boxOf(sp.agent).?, .focused = in_box, .area = &sp.box_area });
        },
        .shell, .take_over => {
            if (sp.exited) {
                const inner = try w.box.draw(surface, region, theme, .{ .title = if (sp.kind == .shell) "Shell" else sp.harness, .badge = sp.agent, .focused = focused, .clear = true });
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
            const inner = try w.box.draw(surface, region, theme, .{ .title = title, .badge = if (waiting) "needs you" else badge, .focused = focused, .clear = true, .role = if (waiting) .warn else null });
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
    const inner = try w.box.draw(surface, main, &app.theme, .{ .title = pg.title, .badge = "esc closes", .focused = true, .clear = true });
    const pad: Region = .{ .x = inner.x + @min(inner.width, 1), .y = inner.y, .width = inner.width -| 2, .height = inner.height };
    try pg.scroll.draw(app.gpa, surface, pad, try pg.blocks(app.gpa), &app.theme, true);
}

/// The split menu, over the main view.
fn menuOverlay(app: *App, surface: *Surface, a: std.mem.Allocator, m: split.Menu, main: Region) !void {
    const theme = &app.theme;
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
        _ = try w.text.drawText(surface, inner.x + 1, y, 2, num, .accent, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 4, y, inner.width -| 14, try o.title(a, harness), if (on) .accent else .normal, theme, .{ .ellipsis = true, .overlay = .{ .bold = true, .reverse = on } });
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
    for (d.requests.items) |q| {
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
            const inbox_mod = @import("inbox.zig");
            app.drawn = .{ .item = inbox_mod.itemHash(it), .sig = inbox_mod.optionsSig(it) };
            const done = app.picks.count(it);
            for (try inbox_mod.optionRows(a, it, app.picks.chosen[0..done])) |row| try out.append(a, .{ .spans = try spans(a, &.{
                .{ .text = row.mark, .role = if (row.header) .muted else .accent },
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

fn inspector(app: *App, surface: *Surface, a: std.mem.Allocator, region: Region) !void {
    const theme = &app.theme;
    const inner = try w.box.draw(surface, region, theme, .{ .title = "Agent" });
    const s = app.model.find(app.selected.items) orelse return;
    const rows = [_][2][]const u8{
        .{ "agent", s.id },
        .{ "state", s.state.label() },
        .{ "harness", s.harness },
        .{ "turns", if (std.mem.eql(u8, app.model.detail.agent, s.id)) try std.fmt.allocPrint(a, "{d}", .{app.model.detail.turns}) else "" },
        .{ "workspace", try app.shortPath(a, s.workspace) },
        .{ "cwd", try app.shortPath(a, s.cwd) },
    };
    for (rows, 0..) |row, i| {
        if (i >= inner.height) break;
        const y = inner.y + @as(u16, @intCast(i));
        _ = try w.text.drawText(surface, inner.x + 1, y, 10, row[0], .muted, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 11, y, inner.width -| 12, row[1], .secondary, theme, .{ .ellipsis = true });
    }
}

/// venom's own status bar.
/// Take over mid-turn asks first.
fn askOverlay(app: *App, surface: *Surface, a: std.mem.Allocator, q: split.Ask, main: Region) !void {
    const theme = &app.theme;
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
        _ = try w.text.drawText(surface, inner.x + 1, y, 2, try std.fmt.allocPrint(a, "{d}", .{i + 1}), .accent, theme, .{});
        _ = try w.text.drawText(surface, inner.x + 4, y, inner.width -| 14, choice.title(), if (on) .accent else .normal, theme, .{ .ellipsis = true, .overlay = .{ .bold = true, .reverse = on } });
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

fn statusBar(app: *App, surface: *Surface, region: Region) !void {
    const a = app.frame.allocator();
    const chrome = app.chrome;
    const bar = chrome.statusBar();
    try surface.clear(region, bar);
    var x: u16 = region.x;
    const right = region.x + region.width;
    const blocking = app.model.count(model.State.blocking);
    const running = app.model.count(isRunning);
    const gold = blk: {
        var s = chrome.fill(chrome.theme.gold, chrome.theme.void);
        s.bold = true;
        break :blk s;
    };
    if (!app.connected) {
        // First, so it is never cut off: what follows is the last known state.
        var off = chrome.text(chrome.theme.danger);
        off.bg = bar.bg;
        off.bold = true;
        x = try put(surface, x, region.y, right, " ✕ daemon offline, reconnecting ", off);
    }
    x = try put(surface, x, region.y, right, try std.fmt.allocPrint(a, " ▲ {d} need you ", .{blocking}), if (blocking > 0) gold else bar);
    x = try put(surface, x, region.y, right, try std.fmt.allocPrint(a, "· ◆ {d} running ", .{running}), bar);
    const sel = app.model.find(app.selected.items);
    const place = try std.fmt.allocPrint(a, "│ {s} ", .{if (sel) |s| tail(try app.shortPath(a, s.workspace), 24) else "no agents"});
    const focused_kind: ?split.Kind = if (app.focusedSplit()) |i| app.splits.items[i].kind else null;
    const in_box = app.inFocusedBox();
    const shell_focused = focused_kind == .shell or focused_kind == .take_over;
    // The leader doesn't end Normal: it is what the next key does there.
    const mode_text = try std.fmt.allocPrint(a, "│ {s}{s} ", .{ app.keyMode().label(), if (app.leader.pending()) " · LEADER" else "" });
    // Right side: a message, or the key hints. A notice stands in for the hints
    // that are only reminders, not for those of a mode a key opened: it is back
    // when that mode ends, and no key clears it.
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
    const warned = app.message.items.len > 0 or noticed;
    // A notice or a message has to be read whole: the workspace gives way to it.
    if (!warned or w.text.width(place) + w.text.width(mode_text) + w.text.width(hint) + 1 <= right - x) x = try put(surface, x, region.y, right, place, bar);
    x = try put(surface, x, region.y, right, mode_text, bar);
    const hw: u16 = @intCast(@min(w.text.width(hint) + 1, right - x));
    if (hw > 1) _ = try put(surface, right - hw, region.y, right, hint, if (warned) blk: {
        var s = chrome.text(chrome.theme.warn);
        s.bg = bar.bg;
        break :blk s;
    } else bar);
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
    const theme = &app.theme;
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
        _ = try w.text.drawText(surface, inner.x + 1, y, key_w, shown_keys, .accent, theme, .{});
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
