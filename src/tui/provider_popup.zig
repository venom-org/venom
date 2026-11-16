//! The provider popup of Settings › Providers: configures a new provider, or
//! changes (or removes) one. It edits a copy; `Settings.saveProvider` turns
//! the result into `config set` of `providers` and `agents.provider`.
//!
//! ```text
//! ╭ New provider ──────────────────────────────── Settings › Providers ╮
//! │▌Harness     ◉ Claude Code  ○ Codex                                 │
//! │ Name        › personal                                             │
//! │ Config dir  › ~/.claude_personal                                   │
//! │ Model       › opus                                                 │
//! │ Permission  ○ venom's default  ○ default  ◉ acceptEdits  ○ plan    │
//! │             ○ auto  ○ bypassPermissions                            │
//! │ Default     ☑ new agents use it                                    │
//! │                                                                    │
//! │ Which agent CLI it runs: Claude Code or Codex. h l switches.       │
//! │ ────────────────────────────────────────────────────────────────── │
//! │ WRITES TO providers                                                │
//! │ .{ .name = "personal", .harness = .claude_code, .home = "~/.cl… }  │
//! │ SIGN IN ONCE, FROM A SHELL                                         │
//! │ CLAUDE_CONFIG_DIR=~/.claude_personal claude auth login             │
//! │                                                                    │
//! │ ⏎ Save  esc Cancel                                     ⌃d Remove   │
//! ╰────────────────────────────────────────────────────────────────────╯
//! ```
//!
//! The field under the cursor has the selection bar; only its help shows.
//! Whatever would stop a save shows as you type.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const k = w.keys;
const Surface = term.Surface;
const Region = term.Region;
const config = @import("../config.zig");
const providers = @import("providers.zig");

pub const Field = enum {
    harness,
    name,
    home,
    model,
    mode,
    default,

    fn label(self: Field) []const u8 {
        return switch (self) {
            .harness => "Harness",
            .name => "Name",
            .home => "Config dir",
            .model => "Model",
            .mode => "Permission",
            .default => "Default",
        };
    }

    fn isText(self: Field) bool {
        return self == .name or self == .home or self == .model;
    }
};

/// What a key did to the popup.
pub const Outcome = enum { none, cancel, save, remove };

pub const Popup = struct {
    gpa: std.mem.Allocator,
    /// The provider being changed, by its index in `providers`; null: a new one.
    index: ?usize,
    harness: config.Harness,
    name: w.TextInput,
    home: w.TextInput,
    model: w.TextInput,
    mode: ?config.Mode,
    default: bool,
    field: Field,
    /// Why the last save was refused; empty when it was not.
    failure: std.ArrayList(u8) = .empty,
    /// ⌃d was pressed once: a second ⌃d removes the provider.
    remove_armed: bool = false,

    pub fn init(gpa: std.mem.Allocator, index: ?usize, p: config.Provider, is_default: bool) !Popup {
        var self: Popup = .{
            .gpa = gpa,
            .index = index,
            .harness = p.harness,
            .name = .init(gpa, .{ .prompt = "› ", .placeholder = "like work or personal max" }),
            .home = .init(gpa, .{ .prompt = "› " }),
            .model = .init(gpa, .{ .prompt = "› ", .placeholder = "empty: the harness's default model" }),
            .mode = p.mode,
            .default = is_default,
            .field = if (index == null) .harness else .name,
        };
        errdefer self.deinit();
        try self.name.setText(p.name);
        try self.home.setText(p.home orelse "");
        try self.model.setText(p.model orelse "");
        self.placeholders();
        return self;
    }

    pub fn deinit(self: *Popup) void {
        self.name.deinit();
        self.home.deinit();
        self.model.deinit();
        self.failure.deinit(self.gpa);
    }

    fn placeholders(self: *Popup) void {
        self.home.opts.placeholder = switch (self.harness) {
            .claude_code => "empty: the default login, ~/.claude",
            .codex => "empty: the default login, ~/.codex",
        };
    }

    pub fn setFailure(self: *Popup, comptime fmt: []const u8, args: anytype) void {
        self.failure.clearRetainingCapacity();
        self.failure.print(self.gpa, fmt, args) catch {};
    }

    /// The provider as the popup has it now (strings borrowed from it).
    pub fn provider(self: *const Popup) config.Provider {
        const trim = struct {
            fn f(input: *const w.TextInput) []const u8 {
                return std.mem.trim(u8, input.value(), " \t\r\n");
            }
        }.f;
        const home = trim(&self.home);
        const model = trim(&self.model);
        return .{ .name = trim(&self.name), .harness = self.harness, .home = if (home.len > 0) home else null, .model = if (model.len > 0) model else null, .mode = self.mode };
    }

    fn move(self: *Popup, delta: isize) void {
        const fields = std.enums.values(Field);
        const at = std.mem.indexOfScalar(Field, fields, self.field) orelse 0;
        const n: isize = @intCast(fields.len);
        self.field = fields[@intCast(@mod(@as(isize, @intCast(at)) + delta, n))];
    }

    fn step(self: *Popup, back: bool) void {
        switch (self.field) {
            .harness => {
                self.harness = if (self.harness == .claude_code) .codex else .claude_code;
                self.placeholders();
                // A mode the other harness does not have goes back to unset.
                var kept = false;
                for (providers.modeChoices(self.harness)) |c| kept = kept or c.mode == self.mode;
                if (!kept) self.mode = null;
            },
            .mode => {
                const order = providers.modeChoices(self.harness);
                var at: usize = 0;
                for (order, 0..) |c, i| if (c.mode == self.mode) {
                    at = i;
                };
                self.mode = order[(if (back) at + order.len - 1 else at + 1) % order.len].mode;
            },
            .default => self.default = !self.default,
            else => {},
        }
    }

    pub fn key(self: *Popup, key_: term.Input.Key) !Outcome {
        if (!k.pressed(key_)) return .none;
        const armed = self.remove_armed;
        self.remove_armed = false;
        if (k.named(key_, .escape) or k.ctrl(key_, 'c')) return .cancel;
        if (k.ctrl(key_, 'd') and self.index != null) {
            if (armed) return .remove;
            self.remove_armed = true;
            return .none;
        }
        if (k.namedAny(key_, .tab)) {
            self.move(if (key_.mods.shift) -1 else 1);
            return .none;
        }
        if (k.named(key_, .down)) {
            self.move(1);
            return .none;
        }
        if (k.named(key_, .up)) {
            self.move(-1);
            return .none;
        }
        if (k.ctrl(key_, 's') or k.named(key_, .enter)) return .save;
        self.failure.clearRetainingCapacity();
        if (self.field.isText()) {
            _ = try self.box(self.field).?.handleKey(key_);
            return .none;
        }
        const back = k.char(key_, 'h') or k.named(key_, .left);
        if (back or k.char(key_, 'l') or k.named(key_, .right) or k.char(key_, ' ')) self.step(back);
        if (k.char(key_, 'j')) self.move(1);
        if (k.char(key_, 'k')) self.move(-1);
        return .none;
    }

    fn box(self: *Popup, f: Field) ?*w.TextInput {
        return switch (f) {
            .name => &self.name,
            .home => &self.home,
            .model => &self.model,
            else => null,
        };
    }

    /// A bracketed paste goes into the text field under the cursor.
    pub fn paste(self: *Popup, text: []const u8) !void {
        try (self.box(self.field) orelse return).insert(text);
    }

    /// What the line under the fields says of the field under the cursor.
    fn help(self: *const Popup, a: std.mem.Allocator) ![]const u8 {
        const env = config.Provider.homeEnv(self.harness);
        return switch (self.field) {
            .harness => "Which agent CLI it runs. venom drives it through its own protocol; h l switches.",
            .name => "How spawns, the CLI and the agent list name it: 1 to 64 characters, unique.",
            .home => try std.fmt.allocPrint(a, "Its own login: the folder venom sets as {s}. Several logins of one harness each get a folder.", .{env}),
            .model => "For its agents when a spawn names no model. Empty: whatever the harness picks.",
            .mode => for (providers.modeChoices(self.harness)) |c| {
                if (c.mode == self.mode) break c.help;
            } else "",
            .default => "New agents run with it unless they name another provider. There is one default.",
        };
    }

    /// Draws the popup over `main`. `problem` is what would stop a save
    /// (`Settings.popupProblem`); null when nothing would.
    pub fn draw(self: *Popup, surface: *Surface, main: Region, theme: *const w.Theme, a: std.mem.Allocator, problem: ?[]const u8) !void {
        surface.setCursor(null);
        const bw: u16 = @min(main.width -| 4, 96);
        if (bw < 24 or main.height < 8) return;
        const label_w: u16 = 12;
        // Inside the border: a column of space, the label, then the value.
        const room = (bw -| 2) -| (label_w + 3);
        const choices = providers.modeChoices(self.harness);
        const mode_items = try a.alloc(Chip, choices.len);
        for (choices, mode_items) |c, *it| it.* = .{ .label = c.label, .on = c.mode == self.mode };
        const mode_lines = chipLines(mode_items, room);
        const fields_h: u16 = 5 + mode_lines;

        // Under the fields: the help (or the problem), the config it writes,
        // the sign-in command, then the actions. The preview goes first when
        // there is no room.
        const p = self.provider();
        const entry = try providers.entryZon(a, p);
        const sign_in = try providers.signInCommand(a, p);
        const risky = for (choices) |c| {
            if (c.mode == self.mode) break c.risky;
        } else false;
        // Fields, a blank, two lines of help, the risk line, the rule and
        // the preview, a blank, the actions, the border.
        const full: u16 = fields_h + 1 + 2 + @as(u16, if (risky and self.field != .mode) 1 else 0) + 1 + 4 + 1 + 1 + 2;
        const bh: u16 = @min(main.height, full);
        const show_preview = bh == full;
        const region: Region = .{ .x = main.x + (main.width -| bw) / 2, .y = main.y + (main.height -| bh) / 2, .width = bw, .height = bh };
        const title = if (self.index == null) "New provider" else try std.fmt.allocPrint(a, "Provider {s}", .{p.name});
        const inner = try w.box.draw(surface, region, theme, .{ .border = .rounded, .title = title, .badge = "Settings › Providers", .focused = true, .clear = true });
        if (inner.width < 16 or inner.height < 3) return;
        const bottom = inner.y + inner.height;
        const lx = inner.x + 1;
        const vx = lx + label_w + 1;
        const text_w = inner.width -| 2;
        var y = inner.y;
        for (std.enums.values(Field)) |f| {
            if (y + 1 >= bottom) break;
            const focused = f == self.field;
            const h: u16 = if (f == .mode) mode_lines else 1;
            const rows = @min(h, bottom - 1 - y);
            const fill = if (focused) w.theme.overlay(theme.style(.normal), theme.style(.selection)) else theme.style(.normal);
            const sel: ?term.Style = if (focused) theme.style(.selection) else null;
            try surface.clear(.{ .x = inner.x, .y = y, .width = inner.width, .height = rows }, fill);
            if (focused) for (0..rows) |dy| try surface.put(inner.x, y + @as(u16, @intCast(dy)), .{ .text = "▌", .style = w.theme.overlay(theme.style(.accent), theme.style(.selection)) });
            _ = try w.text.drawText(surface, lx, y, label_w, f.label(), if (focused) .normal else .muted, theme, .{ .overlay = w.theme.overlay(sel orelse .{}, .{ .bold = focused }), .fill = fill });
            switch (f) {
                .harness => _ = try chips(surface, theme, a, vx, y, room, rows, &.{
                    .{ .label = "Claude Code", .on = self.harness == .claude_code },
                    .{ .label = "Codex", .on = self.harness == .codex },
                }, focused, radio, sel),
                .name, .home, .model => try self.box(f).?.draw(surface, .{ .x = vx, .y = y, .width = room, .height = 1 }, theme, focused),
                .mode => _ = try chips(surface, theme, a, vx, y, room, rows, mode_items, focused, radio, sel),
                .default => _ = try chips(surface, theme, a, vx, y, room, rows, &.{.{ .label = "new agents use it", .on = self.default }}, focused, check, sel),
            }
            y += rows;
        }
        // The actions keep the last line, whatever else fits.
        const actions_y = bottom - 1;
        y += 1;
        var lines: std.ArrayList(Line) = .empty;
        // Two lines, whatever says them, so the popup does not jump.
        const about: Line = if (self.remove_armed)
            .{ .text = try std.fmt.allocPrint(a, "⌃d again removes {s}; any other key keeps it.", .{p.name}), .role = .err }
        else if (problem) |why|
            .{ .text = try std.fmt.allocPrint(a, "{s} {s}", .{ if (self.failure.items.len > 0) "✕" else "▲", why }), .role = if (self.failure.items.len > 0) .err else .warn }
        else
            .{ .text = try self.help(a), .role = if (self.field == .mode and risky) .warn else .muted };
        const wrapped = try wrap(a, about.text, text_w, 2);
        for (0..2) |i| try lines.append(a, .{ .text = if (i < wrapped.len) wrapped[i] else "", .role = about.role });
        if (risky and self.field != .mode) try lines.append(a, .{ .text = "▲ bypassPermissions approves everything, venom's approvals included.", .role = .warn });
        if (show_preview) {
            try lines.append(a, .{ .rule = true });
            try lines.append(a, .{ .text = if (self.default) "WRITES providers AND agents.provider" else "WRITES TO providers", .role = .muted, .bold = true });
            try lines.append(a, .{ .text = entry, .role = .secondary });
            try lines.append(a, .{ .text = "SIGN IN ONCE, FROM A SHELL", .role = .muted, .bold = true });
            try lines.append(a, .{ .text = sign_in, .role = .normal });
        }
        for (lines.items) |line| {
            if (y >= actions_y) break;
            if (line.rule) {
                for (lx..lx + text_w) |cx| try surface.put(@intCast(cx), y, .{ .text = "─", .style = theme.style(.border) });
            } else _ = try w.text.drawText(surface, lx, y, text_w, line.text, line.role, theme, .{ .ellipsis = true, .overlay = .{ .bold = line.bold } });
            y += 1;
        }
        // Actions, as buttons: the key in `bone` bold, its label after it.
        // Left to right while they fit inside the popup; ⌃d Remove at the
        // right edge when there is room for it too.
        const save_label: []const u8 = if (self.index == null) "Add provider" else "Save";
        const end = lx + text_w;
        const remove_w: u16 = if (self.index != null) @intCast(w.text.width("⌃d Remove") + 2) else 0;
        var ax = lx;
        for ([_][2][]const u8{ .{ "⏎", save_label }, .{ "esc", "Cancel" }, .{ "⇥", "Next field" } }, 0..) |b, n| {
            const bw_: u16 = @intCast(w.text.width(b[0]) + 1 + w.text.width(b[1]));
            if (ax + bw_ > end -| (if (n == 0) 0 else remove_w)) break;
            ax += try button(surface, theme, ax, actions_y, b[0], b[1], n != 0 or problem == null) + 2;
        }
        if (self.index != null and ax + remove_w <= end) _ = try button(surface, theme, end - (remove_w - 2), actions_y, "⌃d", "Remove", !self.remove_armed);
    }
};

const Line = struct { text: []const u8 = "", role: w.Role = .normal, bold: bool = false, rule: bool = false };

/// `⏎ Save`: the key bold in `bone`, the label in `secondary` (both `faint`
/// when the action would do nothing). Returns the columns drawn.
fn button(surface: *Surface, theme: *const w.Theme, x: u16, y: u16, key_: []const u8, label: []const u8, live: bool) !u16 {
    return w.text.drawSpans(surface, x, y, surface.width -| x, &.{
        .{ .text = key_, .role = if (live) .normal else .faint, .style = .{ .bold = true } },
        .{ .text = " ", .role = .muted },
        .{ .text = label, .role = if (live) .secondary else .faint },
    }, theme, .{});
}

const Chip = struct { label: []const u8, on: bool };
const radio = [2][]const u8{ "◉", "○" };
const check = [2][]const u8{ "☑", "☐" };
const chip_gap: u16 = 2;

fn chipWidth(c: Chip) u16 {
    return @intCast(2 + w.text.width(c.label));
}

/// The lines `items` take at `room` columns, wrapped between chips.
fn chipLines(items: []const Chip, room: u16) u16 {
    var lines: u16 = 1;
    var used: u16 = 0;
    for (items) |c| {
        const cw = chipWidth(c);
        if (used > 0 and used + chip_gap + cw > room) {
            lines += 1;
            used = 0;
        }
        used += (if (used > 0) chip_gap else 0) + cw;
    }
    return lines;
}

/// Draws `items` from (`x`, `y`), wrapping onto at most `max_lines` lines.
fn chips(surface: *Surface, theme: *const w.Theme, a: std.mem.Allocator, x: u16, y: u16, room: u16, max_lines: u16, items: []const Chip, focused: bool, glyphs: [2][]const u8, sel: ?term.Style) !u16 {
    var cx = x;
    var cy = y;
    const right = x + room;
    for (items) |c| {
        const cw = chipWidth(c);
        if (cx > x and cx + cw > right) {
            if (cy + 1 >= y + max_lines) return cy - y + 1;
            cy += 1;
            cx = x;
        }
        const label = try std.fmt.allocPrint(a, "{s} {s}", .{ if (c.on) glyphs[0] else glyphs[1], c.label });
        const fit: u16 = @min(cw, right -| cx);
        if (fit == 0) break;
        const base = w.theme.overlay(sel orelse .{}, .{ .bold = c.on, .reverse = focused and c.on });
        _ = try w.text.drawText(surface, cx, cy, fit, label, if (c.on) .normal else .muted, theme, .{ .ellipsis = true, .overlay = base });
        cx += cw + chip_gap;
    }
    return cy - y + 1;
}

/// `text` cut at spaces into at most `max` lines of `width` columns; the
/// last one ends in an ellipsis when it does not fit.
fn wrap(a: std.mem.Allocator, text: []const u8, width: u16, max: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = std.mem.trim(u8, text, " ");
    while (rest.len > 0 and out.items.len < max) {
        if (w.text.width(rest) <= width or out.items.len + 1 == max) {
            try out.append(a, rest);
            break;
        }
        var cut: usize = 0;
        var it = std.mem.splitScalar(u8, rest, ' ');
        var at: usize = 0;
        while (it.next()) |word| {
            const end = at + word.len;
            if (w.text.width(rest[0..end]) > width) break;
            cut = end;
            at = end + 1;
        }
        if (cut == 0) {
            // One word wider than the line: cut it, on a character boundary.
            cut = @max(@min(rest.len, width), 1);
            while (cut < rest.len and cut > 1 and (rest[cut] & 0xC0) == 0x80) cut -= 1;
        }
        try out.append(a, rest[0..cut]);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    return out.items;
}
