//! The provider popup of Settings › Providers: configures a new provider, or
//! changes (or removes) one. It edits a copy; `Settings.saveProvider` turns
//! the result into `config set` of `providers` and `agents.provider`.
//!
//! ```text
//! ╭ New provider ──────────────────────────────────────────╮
//! │ Harness     ◉ Claude Code  ○ Codex                      │
//! │ Name        › personal                                  │
//! │ Config dir  › ~/.claude_personal                        │
//! │             sign in: CLAUDE_CONFIG_DIR=~/.claude_pers…  │
//! │ Model       › opus                                      │
//! │ Permission  ○ agents.mode  ○ Ask  ◉ Accept edits  ○ Plan │
//! │ Default     ☑ new agents use it                         │
//! │ ⇥ next  h l choose  ⏎ save  esc cancel                  │
//! ╰─────────────────────────────────────────────────────────╯
//! ```
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
    remove,

    fn label(self: Field) []const u8 {
        return switch (self) {
            .harness => "Harness",
            .name => "Name",
            .home => "Config dir",
            .model => "Model",
            .mode => "Permission",
            .default => "Default",
            .remove => "Remove",
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

    pub fn init(gpa: std.mem.Allocator, index: ?usize, p: config.Provider, is_default: bool) !Popup {
        var self: Popup = .{
            .gpa = gpa,
            .index = index,
            .harness = p.harness,
            .name = .init(gpa, .{ .prompt = "› ", .placeholder = "like Work or Personal Max" }),
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
            .claude_code => "empty: the default login (~/.claude); like ~/.claude_personal",
            .codex => "empty: the default login (~/.codex); like ~/.codex_work",
        };
    }

    pub fn setFailure(self: *Popup, comptime fmt: []const u8, args: anytype) void {
        self.failure.clearRetainingCapacity();
        self.failure.print(self.gpa, fmt, args) catch {};
    }

    /// The provider as the popup has it now (strings borrowed from it).
    pub fn provider(self: *const Popup) config.Provider {
        const trim = struct {
            fn f(box: *const w.TextInput) []const u8 {
                return std.mem.trim(u8, box.value(), " \t\r\n");
            }
        }.f;
        const home = trim(&self.home);
        const model = trim(&self.model);
        return .{ .name = trim(&self.name), .harness = self.harness, .home = if (home.len > 0) home else null, .model = if (model.len > 0) model else null, .mode = self.mode };
    }

    fn visible(self: *const Popup, out: *[7]Field) []const Field {
        var n: usize = 0;
        for (std.enums.values(Field)) |f| {
            if (f == .remove and self.index == null) continue;
            out[n] = f;
            n += 1;
        }
        return out[0..n];
    }

    fn move(self: *Popup, delta: isize) void {
        var buf: [7]Field = undefined;
        const fields = self.visible(&buf);
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
        if (k.named(key_, .escape) or k.ctrl(key_, 'c')) return .cancel;
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
        if (k.ctrl(key_, 's')) return .save;
        if (k.named(key_, .enter)) return if (self.field == .remove) .remove else .save;
        if (self.field.isText()) {
            const box = switch (self.field) {
                .name => &self.name,
                .home => &self.home,
                else => &self.model,
            };
            _ = try box.handleKey(key_);
            self.failure.clearRetainingCapacity();
            return .none;
        }
        const back = k.char(key_, 'h') or k.named(key_, .left);
        if (back or k.char(key_, 'l') or k.named(key_, .right) or k.char(key_, ' ')) self.step(back);
        if (k.char(key_, 'j')) self.move(1);
        if (k.char(key_, 'k')) self.move(-1);
        return .none;
    }

    /// A bracketed paste goes into the text field under the cursor.
    pub fn paste(self: *Popup, text: []const u8) !void {
        const box = switch (self.field) {
            .name => &self.name,
            .home => &self.home,
            .model => &self.model,
            else => return,
        };
        try box.insert(text);
    }

    pub fn draw(self: *Popup, surface: *Surface, main: Region, theme: *const w.Theme, a: std.mem.Allocator) !void {
        surface.setCursor(null);
        var buf: [7]Field = undefined;
        const fields = self.visible(&buf);
        // Fields, the sign-in and mode lines, the failure, the keys, the border.
        const want: u16 = @intCast(fields.len + 2 + @as(usize, if (self.failure.items.len > 0) 1 else 0) + 1 + 2);
        const bw: u16 = @min(main.width -| 4, 120);
        const bh: u16 = @min(main.height, want);
        const region: Region = .{ .x = main.x + (main.width -| bw) / 2, .y = main.y + (main.height -| bh) / 4, .width = bw, .height = bh };
        const title = if (self.index == null) "New provider" else "Provider";
        const inner = try w.box.draw(surface, region, theme, .{ .border = .rounded, .title = title, .badge = "Settings › Providers", .focused = true, .clear = true });
        if (inner.width < 16 or inner.height == 0) return;
        const label_w: u16 = 12;
        const vx = inner.x + 1 + label_w;
        const room = inner.width -| (label_w + 2);
        var y = inner.y;
        const bottom = inner.y + inner.height;
        for (fields) |f| {
            if (y >= bottom) return;
            const focused = f == self.field;
            _ = try w.text.drawText(surface, inner.x + 1, y, label_w, f.label(), if (focused) .accent else .muted, theme, .{ .overlay = .{ .bold = focused } });
            switch (f) {
                .harness => try chips(surface, theme, a, vx, y, room, &.{
                    .{ .label = "Claude Code", .on = self.harness == .claude_code },
                    .{ .label = "Codex", .on = self.harness == .codex },
                }, focused, radio),
                .name, .home, .model => {
                    const box = switch (f) {
                        .name => &self.name,
                        .home => &self.home,
                        else => &self.model,
                    };
                    try box.draw(surface, .{ .x = vx, .y = y, .width = room, .height = 1 }, theme, focused);
                },
                .mode => {
                    const order = providers.modeChoices(self.harness);
                    const items = try a.alloc(Chip, order.len);
                    for (order, items) |c, *it| it.* = .{ .label = c.label, .on = c.mode == self.mode };
                    try chips(surface, theme, a, vx, y, room, items, focused, radio);
                },
                .default => try chips(surface, theme, a, vx, y, room, &.{.{ .label = "new agents use it", .on = self.default }}, focused, check),
                .remove => _ = try w.text.drawText(surface, vx, y, room, "⏎ removes this provider", if (focused) .err else .muted, theme, .{ .overlay = .{ .reverse = focused } }),
            }
            y += 1;
            if (f == .mode and y < bottom) {
                for (providers.modeChoices(self.harness)) |c| if (c.mode == self.mode) {
                    _ = try w.text.drawText(surface, vx, y, room, c.help, if (c.risky) .warn else .muted, theme, .{ .ellipsis = true });
                };
                y += 1;
            }
            if (f == .home and y < bottom) {
                const p = self.provider();
                const line = try std.fmt.allocPrint(a, "{s} · sign in: {s}", .{ config.Provider.homeEnv(p.harness), try providers.signInCommand(a, p) });
                _ = try w.text.drawText(surface, vx, y, room, line, .muted, theme, .{ .ellipsis = true });
                y += 1;
            }
        }
        if (self.failure.items.len > 0 and y < bottom) {
            _ = try w.text.drawText(surface, inner.x + 1, y, inner.width -| 2, self.failure.items, .err, theme, .{ .ellipsis = true });
            y += 1;
        }
        if (y < bottom) _ = try w.text.drawText(surface, inner.x + 1, y, inner.width -| 2, "⇥ ↑↓ field  h l choose  ⏎ save  esc cancel", .muted, theme, .{ .ellipsis = true });
    }
};

const Chip = struct { label: []const u8, on: bool };
const radio = [2][]const u8{ "◉", "○" };
const check = [2][]const u8{ "☑", "☐" };

fn chips(surface: *Surface, theme: *const w.Theme, a: std.mem.Allocator, x: u16, y: u16, room: u16, items: []const Chip, focused: bool, glyphs: [2][]const u8) !void {
    var cx = x;
    const right = x + room;
    for (items) |c| {
        const label = try std.fmt.allocPrint(a, "{s} {s}", .{ if (c.on) glyphs[0] else glyphs[1], c.label });
        const cw: u16 = @intCast(@min(w.text.width(label), right -| cx));
        if (cw == 0) return;
        _ = try w.text.drawText(surface, cx, y, cw, label, if (c.on) .normal else .muted, theme, .{ .ellipsis = true, .overlay = .{ .bold = c.on, .reverse = focused and c.on } });
        cx += cw + 2;
    }
}
