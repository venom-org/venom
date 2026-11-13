//! The transcript's rows: prompts,
//! agent text and one row per tool call. `J` shows a
//! call's raw JSON, with the harness's own input (`raw_input`).
//!
//! ```text
//! ▸ Explored  6 reads · 2 searches · 1 list                         1.1s
//! ▾ Edit ×4   venom-std/src/proto/codec.zig                      +11 −11
//!     @@ -40,7 +40,7 @@
//! ▾ Bash      zig build -Dtarget=wasm32-wasi                 exit 1 · 2.0s
//!     src/proto/codec.zig:88:17: error: use of undeclared identifier 'Frame'
//! ```
//!
//! - **Rows** (`rows`): pure grouping of `agent.show`'s records. Consecutive
//!   reads, searches and listings merge into `Explored`; edits to one file
//!   in one turn merge into `Edit ×N` at the first edit's place; a
//!   sub-agent's calls (`parent_call`) fold into its `agent` row. A call that
//!   has to stay open (below) is never merged.
//! - **Density** (`View.defaultOpen`): `compact` shows one line per call,
//!   `normal` opens edit diffs with their first 6 lines, `verbose` opens
//!   every body in full.
//! - **Always open**, at any density: a call waiting for approval, a failed
//!   call, and a call running longer than `ui.transcript.open_running_after`
//!   (with a live tail).
//! - **In full**: `agent.show` carries the start of a long body. An open row
//!   that shows everything asks `agent.tool` for the rest (`View.nextWanted`,
//!   `View.setFull`); until the answer comes it says what is missing.
//! - `View` keeps the user's `⏎` / `E` / `C` choices per row. A choice lasts
//!   until the density changes or the row starts or stops having to be open,
//!   so a row collapsed earlier still opens when it comes to need you.
//! - **Wrap cache**: `ScrollView` keeps a block's wrapped lines while
//!   its revision and span slices stay the same. A rebuild formats every row
//!   again in `View.arena`, then keeps the previous copy of each block that
//!   came out the same (`View.kept`), so only what changed is wrapped again. A
//!   frame that reuses the blocks promises as much (`skipUnchanged`).
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const model = @import("model.zig");
const fan_out = @import("fan_out.zig");
const Tool = model.Tool;
const Record = model.Record;
const Request = model.Request;

pub const Density = enum {
    compact,
    normal,
    verbose,

    pub fn next(self: Density) Density {
        return switch (self) {
            .compact => .normal,
            .normal => .verbose,
            .verbose => .compact,
        };
    }
};

/// Lines of an edit diff `normal` shows, and of a running call's live tail.
const preview_lines = 6;
/// The verb column.
const verb_width = 10;

pub const Options = struct {
    density: Density = .normal,
    now_ms: i64 = 0,
    open_running_after_ms: u64 = 5000,
    /// The agent's children, at the tail.
    fan: fan_out.Block = .{},
};

/// One row of the transcript: text, or one or more tool calls.
pub const Row = struct {
    kind: enum { turn_started, prompt, text, turn_ended, call, explored, edits, agent, fan_header, card, fan_keys },
    /// Non-tool rows: the record.
    record: ?*const Record = null,
    /// `call`: one. `explored`, `edits`: the merged calls. `agent`: the
    /// starting call, then the sub-agent's calls.
    calls: []*const Tool = &.{},
    /// `card`: the child.
    card: ?*const fan_out.Card = null,

    pub fn isTool(self: *const Row) bool {
        return self.calls.len > 0;
    }

    /// `j` `k` can land on it, and it can be opened and closed.
    pub fn selectable(self: *const Row) bool {
        return self.isTool() or self.card != null;
    }

    /// Stable across refreshes: the first call's id, or the card's.
    pub fn id(self: *const Row) []const u8 {
        if (self.card) |c| return c.key;
        return if (self.isTool()) self.calls[0].call else "";
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn explores(t: *const Tool) bool {
    return eql(t.kind, "read") or eql(t.kind, "search") or eql(t.kind, "list");
}

/// The request waiting on this call, if any.
fn requestOf(t: *const Tool, requests: []const Request) ?*const Request {
    for (requests) |*r| if (r.call.len > 0 and eql(r.call, t.call)) return r;
    return null;
}

fn waiting(t: *const Tool, requests: []const Request) bool {
    return !t.ended() and (eql(t.status, "awaiting_approval") or requestOf(t, requests) != null);
}

fn runningLong(t: *const Tool, o: Options) bool {
    if (t.ended() or t.at <= 0) return false;
    return o.now_ms - t.at >= @as(i64, @intCast(o.open_running_after_ms));
}

/// The always-open rule for one call.
fn alwaysOpen(t: *const Tool, requests: []const Request, o: Options) bool {
    return waiting(t, requests) or t.failed() or runningLong(t, o);
}

/// Groups the records into rows.
pub fn rows(a: std.mem.Allocator, records: []const Record, requests: []const Request, o: Options) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    // Rows under construction: their calls grow until the end.
    var calls: std.ArrayList(std.ArrayList(*const Tool)) = .empty;
    // The open `Explored` run, an index in `out`.
    var run: ?usize = null;
    // This turn's edits: path → row.
    var edits: std.StringHashMapUnmanaged(usize) = .empty;
    for (records) |*r| {
        if (r.kind != .tool) {
            run = null;
            if (r.kind == .turn_started) edits.clearRetainingCapacity();
            try out.append(a, .{ .kind = switch (r.kind) {
                .turn_started => .turn_started,
                .prompt => .prompt,
                .text => .text,
                .turn_ended => .turn_ended,
                .tool => unreachable,
            }, .record = r });
            try calls.append(a, .empty);
            continue;
        }
        const t = &r.tool;
        // A sub-agent's call folds into the row that started it.
        if (t.parent_call.len > 0) {
            const parent = for (out.items, 0..) |row, i| {
                if (row.kind == .agent and calls.items[i].items.len > 0 and eql(calls.items[i].items[0].call, t.parent_call)) break i;
            } else null;
            if (parent) |i| {
                try calls.items[i].append(a, t);
                continue;
            }
        }
        const open = alwaysOpen(t, requests, o);
        if (eql(t.kind, "edit") and !open) {
            const path = if (t.path.len > 0) t.path else t.title;
            const gop = try edits.getOrPut(a, path);
            run = null;
            if (gop.found_existing) {
                out.items[gop.value_ptr.*].kind = .edits;
                try calls.items[gop.value_ptr.*].append(a, t);
                continue;
            }
            gop.value_ptr.* = out.items.len;
        } else if (explores(t) and !open) {
            if (run) |i| {
                out.items[i].kind = .explored;
                try calls.items[i].append(a, t);
                continue;
            }
            run = out.items.len;
            try appendCall(a, &out, &calls, .call, t);
            continue;
        } else run = null;
        try appendCall(a, &out, &calls, if (eql(t.kind, "agent")) .agent else .call, t);
    }
    for (out.items, calls.items) |*row, list| row.calls = list.items;
    return out.items;
}

fn appendCall(a: std.mem.Allocator, out: *std.ArrayList(Row), calls: *std.ArrayList(std.ArrayList(*const Tool)), kind: @FieldType(Row, "kind"), t: *const Tool) !void {
    var list: std.ArrayList(*const Tool) = .empty;
    try list.append(a, t);
    try out.append(a, .{ .kind = kind, .calls = &.{} });
    try calls.append(a, list);
}

/// Why a row has to stay open.
pub fn rowAlwaysOpen(row: *const Row, requests: []const Request, o: Options) bool {
    if (row.kind == .agent) {}
    for (row.calls) |t| if (alwaysOpen(t, requests, o)) return true;
    return false;
}

fn hasBody(row: *const Row) bool {
    for (row.calls) |t| if (t.body.len > 0 or t.bytes > 0) return true;
    return false;
}

/// `agent.show` left part of this body out.
fn isCut(t: *const Tool) bool {
    return t.truncated and t.bytes > t.body.len;
}

/// Whole bodies from `agent.tool`, by call; null while asked for.
const FullBodies = std.StringHashMapUnmanaged(?[]u8);

// ---- Text ------------------------------------------------------------

/// `s` without terminal escapes and control characters (harness output
/// goes to the screen): CSI and OSC sequences go, tabs become two spaces.
pub fn clean(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const dirty = for (s, 0..) |c, i| {
        if ((c < 0x20 and c != '\n') or c == 0x7f) break true;
        // C1 controls (U+0080-U+009F) act as escapes on some terminals.
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) break true;
    } else false;
    if (!dirty) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            i += 1;
            if (i >= s.len) break;
            if (s[i] == '[') {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
                i += 1;
            } else if (s[i] == ']') {
                while (i < s.len and s[i] != 0x07 and !(s[i] == 0x1b)) i += 1;
                if (i < s.len and s[i] == 0x1b) i += 1;
                i += 1;
            } else i += 1;
            continue;
        }
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) {
            i += 2;
            continue;
        }
        i += 1;
        if (c == '\t') {
            try out.appendSlice(a, "  ");
        } else if (c == '\n' or (c >= 0x20 and c != 0x7f)) try out.append(a, c);
    }
    return out.items;
}

/// One line of at most `max` cells, `…` at the end when cut.
pub fn fit(a: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    if (w.text.width(s) <= max) return s;
    if (max == 0) return "";
    var i: usize = 0;
    var used: usize = 0;
    while (i < s.len) {
        const n = w.text.nextGrapheme(s, i);
        const cells = w.text.graphemeWidth(s[i..n]);
        if (used + cells + 1 > max) break;
        used += cells;
        i = n;
    }
    return std.fmt.allocPrint(a, "{s}…", .{s[0..i]});
}

/// The row's one line: `title` with no line breaks.
pub fn oneLine(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const c = try clean(a, s);
    const trimmed = std.mem.trim(u8, c, " \n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return std.fmt.allocPrint(a, "{s} …", .{std.mem.trimEnd(u8, trimmed[0..end], " ")});
}

fn seconds(a: std.mem.Allocator, ms: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
}

/// `0:14`: how long a call has been running.
fn elapsed(a: std.mem.Allocator, ms: i64) ![]const u8 {
    const s: u64 = @intCast(@divFloor(@max(ms, 0), 1000));
    return std.fmt.allocPrint(a, "{d}:{d:0>2}", .{ s / 60, s % 60 });
}

fn plural(a: std.mem.Allocator, n: usize, one: []const u8, many: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{d} {s}", .{ n, if (n == 1) one else many });
}

/// What the row's middle column says about one call.
pub fn titleOf(a: std.mem.Allocator, t: *const Tool) ![]const u8 {
    if (t.title.len > 0 and !(eql(t.kind, "mcp") and t.server.len > 0)) return oneLine(a, t.title);
    if (t.server.len > 0) return std.fmt.allocPrint(a, "{s} · {s}", .{ t.server, t.tool });
    for ([_][]const u8{ t.path, t.command, t.query, t.url, t.child_ref }) |s| if (s.len > 0) return oneLine(a, s);
    return "";
}

pub const Meta = struct { text: []const u8, role: w.Role = .muted };

/// The right column for one call.
fn metaOf(a: std.mem.Allocator, t: *const Tool, requests: []const Request, o: Options) !Meta {
    if (waiting(t, requests)) {
        const kind = if (requestOf(t, requests)) |r| r.kind else "approval";
        return .{ .text = if (eql(kind, "approval")) "▲ needs approval" else try std.fmt.allocPrint(a, "▲ {s}", .{kind}), .role = .warn };
    }
    if (!t.ended()) {
        if (t.at <= 0) return .{ .text = "◐", .role = .info };
        return .{ .text = try std.fmt.allocPrint(a, "◐ {s}", .{try elapsed(a, o.now_ms - t.at)}), .role = .info };
    }
    const took: ?[]const u8 = if (t.duration_ms) |d| try seconds(a, d) else null;
    if (t.failed()) {
        const what = if (t.exit) |e| try std.fmt.allocPrint(a, "exit {d}", .{e}) else "error";
        return .{ .text = if (took) |x| try std.fmt.allocPrint(a, "{s} · {s}", .{ what, x }) else what, .role = .err };
    }
    if (!eql(t.status, "ok")) return .{ .text = if (took) |x| try std.fmt.allocPrint(a, "{s} · {s}", .{ t.status, x }) else t.status };
    if (eql(t.kind, "edit") and (t.added != null or t.removed != null))
        return .{ .text = try std.fmt.allocPrint(a, "+{d} −{d}", .{ t.added orelse 0, t.removed orelse 0 }) };
    if (t.exit) |e| return .{ .text = if (took) |x| try std.fmt.allocPrint(a, "exit {d} · {s}", .{ e, x }) else try std.fmt.allocPrint(a, "exit {d}", .{e}) };
    return .{ .text = took orelse "" };
}

/// The right column for a row of several calls.
fn metaOfRow(a: std.mem.Allocator, row: *const Row, requests: []const Request, o: Options) !Meta {
    switch (row.kind) {
        .explored => {
            var ms: u64 = 0;
            for (row.calls) |t| {
                if (!t.ended()) return .{ .text = "◐", .role = .info };
                ms += t.duration_ms orelse 0;
            }
            return .{ .text = if (ms > 0) try seconds(a, ms) else "" };
        },
        .edits => {
            var added: u64 = 0;
            var removed: u64 = 0;
            for (row.calls) |t| {
                if (!t.ended()) return .{ .text = "◐", .role = .info };
                added += t.added orelse 0;
                removed += t.removed orelse 0;
            }
            return .{ .text = try std.fmt.allocPrint(a, "+{d} −{d}", .{ added, removed }) };
        },
        .agent => {
            const t = row.calls[0];
            // The harness may not report a sub-agent's calls (codex).
            const n = if (row.calls.len > 1) try std.fmt.allocPrint(a, " · {s} · ] to open", .{try plural(a, row.calls.len - 1, "call", "calls")}) else " · ] to open";
            for (row.calls) |c| if (waiting(c, requests)) return metaOf(a, c, requests, o);
            var failed: usize = 0;
            for (row.calls[1..]) |c| failed += @intFromBool(c.failed());
            if (failed > 0 and !t.failed()) return .{ .text = try std.fmt.allocPrint(a, "✕ {d} failed{s}", .{ failed, n }), .role = .err };
            if (!t.ended()) return .{ .text = try std.fmt.allocPrint(a, "◆ running{s}", .{n}), .role = .info };
            if (t.failed()) return .{ .text = try std.fmt.allocPrint(a, "✕ error{s}", .{n}), .role = .err };
            return .{ .text = try std.fmt.allocPrint(a, "● {s}{s}", .{ if (eql(t.status, "ok")) "done" else t.status, n }) };
        },
        else => return metaOf(a, row.calls[0], requests, o),
    }
}

fn rowVerb(a: std.mem.Allocator, row: *const Row) ![]const u8 {
    return switch (row.kind) {
        .explored => "Explored",
        .edits => std.fmt.allocPrint(a, "Edit ×{d}", .{row.calls.len}),
        else => row.calls[0].name,
    };
}

fn rowTitle(a: std.mem.Allocator, row: *const Row) ![]const u8 {
    if (row.kind != .explored) return titleOf(a, row.calls[0]);
    var reads: usize = 0;
    var searches: usize = 0;
    var lists: usize = 0;
    for (row.calls) |t| {
        if (eql(t.kind, "read")) reads += 1;
        if (eql(t.kind, "search")) searches += 1;
        if (eql(t.kind, "list")) lists += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    for ([_]struct { usize, []const u8, []const u8 }{ .{ reads, "read", "reads" }, .{ searches, "search", "searches" }, .{ lists, "list", "lists" } }) |c| {
        if (c[0] == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, " · ");
        try out.appendSlice(a, try plural(a, c[0], c[1], c[2]));
    }
    return out.items;
}

/// One line, `width` cells: verb, title, and the meta at the right edge.
pub fn line(a: std.mem.Allocator, out: *std.ArrayList(w.Span), verb: []const u8, title: []const u8, meta: Meta, width: usize, verb_style: bool) !void {
    const vw = @max(w.text.width(verb) + 1, verb_width);
    const mw = w.text.width(meta.text);
    const shown_verb = try fit(a, verb, width);
    const room = width -| vw -| (if (mw > 0) mw + 2 else 0);
    const shown = try fit(a, title, room);
    const pad_verb = vw -| w.text.width(shown_verb);
    const pad_meta = room -| w.text.width(shown);
    try out.append(a, .{ .text = shown_verb, .style = if (verb_style) .{ .bold = true } else null, .role = if (verb_style) .normal else .secondary });
    if (width > w.text.width(shown_verb)) try out.append(a, .{ .text = try spaces(a, pad_verb) });
    try out.append(a, .{ .text = shown, .role = if (verb_style) .secondary else .muted });
    if (mw > 0 and width >= vw + mw + 2) {
        try out.append(a, .{ .text = try spaces(a, pad_meta + 2) });
        try out.append(a, .{ .text = meta.text, .role = meta.role });
    }
}

fn spaces(a: std.mem.Allocator, n: usize) ![]const u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

/// Appends `text`'s lines to the block's body, indented; `max` cuts them
/// with a `… N more lines` line. Diff lines are coloured when `diff`.
fn bodyLines(a: std.mem.Allocator, out: *std.ArrayList(w.Span), text: []const u8, max: ?usize, diff: bool, base: w.Role) !void {
    const c = try clean(a, std.mem.trimEnd(u8, text, "\n"));
    var it = std.mem.splitScalar(u8, c, '\n');
    var n: usize = 0;
    const total = std.mem.count(u8, c, "\n") + 1;
    while (it.next()) |l| {
        if (max) |m| if (n == m) {
            try note(a, out, try std.fmt.allocPrint(a, "… {d} more lines", .{total - n}));
            return;
        };
        n += 1;
        const role: w.Role = if (!diff) base else if (std.mem.startsWith(u8, l, "@@")) .faint else if (std.mem.startsWith(u8, l, "+")) .ok else if (std.mem.startsWith(u8, l, "-")) .err else base;
        try out.append(a, .{ .text = "\n  " });
        try out.append(a, .{ .text = l, .role = role });
    }
}

fn note(a: std.mem.Allocator, out: *std.ArrayList(w.Span), text: []const u8) !void {
    try out.append(a, .{ .text = "\n  " });
    try out.append(a, .{ .text = text, .role = .muted });
}

/// The end of a live tail: its last `max` lines.
fn lastLines(text: []const u8, max: usize) []const u8 {
    const t = std.mem.trimEnd(u8, text, "\n");
    var i = t.len;
    var n: usize = 0;
    while (i > 0) : (i -= 1) if (t[i - 1] == '\n') {
        n += 1;
        if (n == max) break;
    };
    return t[i..];
}

/// One call's body. `cut`: at most this many lines of output.
fn callBody(a: std.mem.Allocator, out: *std.ArrayList(w.Span), t: *const Tool, requests: []const Request, cut: ?usize, full: ?*const FullBodies) !void {
    if (requestOf(t, requests)) |r| if (!t.ended()) {
        try out.append(a, .{ .text = "\n  " });
        try out.append(a, .{ .text = try std.fmt.allocPrint(a, "▲ {s}: {s}", .{ r.kind, try clean(a, r.reason) }), .role = .warn });
        if (t.tail.len == 0) return;
    };
    if (!t.ended()) {
        if (t.tail.len > 0) return bodyLines(a, out, lastLines(t.tail, preview_lines), null, false, .normal);
        return note(a, out, "no output yet");
    }
    const whole: ?[]const u8 = if (full) |f| (if (f.get(t.call)) |x| x else null) else null;
    if (whole) |text| if (text.len > 0) return bodyLines(a, out, text, cut, eql(t.kind, "edit"), .normal);
    if (t.body.len > 0) try bodyLines(a, out, t.body, cut, eql(t.kind, "edit"), .normal);
    if (!isCut(t)) return;
    if (t.body.len == 0) return note(a, out, try std.fmt.allocPrint(a, "… {d} bytes of output are not loaded; p opens them", .{t.bytes}));
    try note(a, out, try std.fmt.allocPrint(a, "… cut at {d} of {d} bytes; p opens the whole body", .{ t.body.len, t.bytes }));
}

/// One line for a call inside `Explored` or a sub-agent's row.
fn childLine(a: std.mem.Allocator, out: *std.ArrayList(w.Span), t: *const Tool, requests: []const Request, o: Options, width: usize) !void {
    try out.append(a, .{ .text = "\n  " });
    try line(a, out, t.name, try titleOf(a, t), try metaOf(a, t, requests, o), width -| 2, false);
}

/// The row's spans: its line, then its body. `cut`: the normal density's
/// first lines of a diff; null shows the bodies whole.
fn rowSpans(a: std.mem.Allocator, row: *const Row, requests: []const Request, o: Options, width: usize, cut: ?usize, full: ?*const FullBodies) ![]const w.Span {
    var out: std.ArrayList(w.Span) = .empty;
    try line(a, &out, try rowVerb(a, row), try rowTitle(a, row), try metaOfRow(a, row, requests, o), width, true);
    switch (row.kind) {
        .explored => for (row.calls) |t| {
            try childLine(a, &out, t, requests, o, width);
            if (o.density == .verbose) try callBody(a, &out, t, requests, null, full);
        },
        .agent => {
            try callBody(a, &out, row.calls[0], requests, cut, full);
            // Its last calls, and whatever failed or waits (the always-open
            // rule holds inside a sub-agent too).
            const children = row.calls[1..];
            const recent = if (o.density == .verbose) 0 else children.len -| preview_lines;
            var hidden: usize = 0;
            for (children, 0..) |t, i| {
                const must = alwaysOpen(t, requests, o);
                if (i < recent and !must) {
                    hidden += 1;
                    continue;
                }
                if (hidden > 0) try note(a, &out, try std.fmt.allocPrint(a, "… {d} earlier calls", .{hidden}));
                hidden = 0;
                try childLine(a, &out, t, requests, o, width);
                if (must or o.density == .verbose) try callBody(a, &out, t, requests, null, full);
            }
        },
        else => {
            // The first lines are of the row as a whole.
            var left = cut;
            for (row.calls) |t| {
                if (left) |n| if (n == 0) {
                    try note(a, &out, "… more edits");
                    break;
                };
                try callBody(a, &out, t, requests, left, full);
                if (left) |n| left = n -| (std.mem.count(u8, std.mem.trimEnd(u8, t.body, "\n"), "\n") + 1);
            }
        },
    }
    if (out.items.len == 0) try out.append(a, .{ .text = "" });
    return out.items;
}

// ---- The view ----------------------------------------------------------

/// A row's `⏎` / `E` / `C`, and whether the row had to be open then.
const Choice = struct { open: bool, always: bool };

/// One transcript's state (the main view's, or an agent-view split's):
/// the built blocks, kept between frames, and the user's choices.
/// Keeps the lines on screen where they are when older records came in front
/// of them: the scroll position moves by the lines they added. Call it
/// with the blocks of the last build, before drawing them. `Home` stays at the
/// top, and following stays at the tail.
pub fn keepPlace(gpa: std.mem.Allocator, scroll: *w.ScrollView, view: *const View, d: *model.Detail, blocks: []const w.Block, width: u16) !void {
    const added = d.prepended;
    if (added == 0) return;
    d.prepended = 0;
    const top = scroll.top orelse return;
    if (d.to_start or added >= d.records.items.len) return;
    try scroll.layout(gpa, blocks, width);
    // The row of the record that was first; it may have merged into one above.
    const first = &d.records.items[added];
    for (view.rows, 0..) |row, i| {
        const here = row.record == first or for (row.calls) |t| {
            if (t == &first.tool) break true;
        } else false;
        if (!here) continue;
        scroll.top = top + scroll.starts.items[i];
        return;
    }
}

/// Promises `scroll` that the view's blocks are as it last laid them out, if
/// they are, so a frame with nothing new doesn't compare them. Call it
/// right before `scroll` draws `blocks`, which start with the view's blocks
/// unless the transcript is showing something else ("No agents yet"). A toggle
/// changes a block in place, but it also bumps `View.changed`, so the next
/// build is a new generation and no promise is made for it.
pub fn skipUnchanged(scroll: *w.ScrollView, view: *View, blocks: []const w.Block, region: term.Region) void {
    const n = view.blocks.len;
    const ours = n > 0 and blocks.len >= n and blocks[0].spans.ptr == view.blocks[0].spans.ptr;
    if (ours and view.laid == view.generation) scroll.assumeUnchanged(n);
    // A draw with no room lays nothing out.
    view.laid = if (ours and region.width > 0 and region.height > 0) view.generation else null;
}

/// A block's spans and their text in one allocation of its own, which outlives
/// the arena's resets: `ScrollView` knows a block by these addresses.
const Kept = struct {
    spans: []const w.Span,
    memory: []align(@alignOf(w.Span)) u8,
    /// The rebuild that last changed the block.
    revision: u32,

    fn init(gpa: std.mem.Allocator, spans: []const w.Span, revision: u32) !Kept {
        var size = spans.len * @sizeOf(w.Span);
        for (spans) |s| size += s.text.len;
        const memory = try gpa.alignedAlloc(u8, .of(w.Span), size);
        const copy: []w.Span = @alignCast(std.mem.bytesAsSlice(w.Span, memory[0 .. spans.len * @sizeOf(w.Span)]));
        var text = memory[spans.len * @sizeOf(w.Span) ..];
        for (spans, copy) |s, *c| {
            @memcpy(text[0..s.text.len], s.text);
            c.* = s;
            c.text = text[0..s.text.len];
            text = text[s.text.len..];
        }
        return .{ .spans = copy, .memory = memory, .revision = revision };
    }

    fn same(self: *const Kept, spans: []const w.Span) bool {
        if (self.spans.len != spans.len) return false;
        for (self.spans, spans) |x, y| {
            if (x.role != y.role or !std.meta.eql(x.style, y.style) or !eql(x.text, y.text)) return false;
        }
        return true;
    }
};

pub const View = struct {
    choices: std.StringHashMapUnmanaged(Choice) = .empty,
    /// The selected row's id; it survives rows moving.
    selected: []u8 = &.{},
    arena: ?std.heap.ArenaAllocator = null,
    blocks: []w.Block = &.{},
    /// Parallel to `blocks`: `rows` of the last build.
    rows: []Row = &.{},
    /// Rebuilds. A block's revision is the one that last changed it, so an
    /// address that a new block reuses still reads as new to the wrap cache.
    generation: u32 = 0,
    /// Parallel to `blocks`: what they point at.
    kept: std.ArrayList(Kept) = .empty,
    /// The generation its scroll view last laid out (`skipUnchanged`).
    laid: ?u32 = null,
    /// What the blocks were built from.
    key: ?Key = null,
    changed: u32 = 0,
    /// The agent the choices are for: call ids are per agent.
    agent: []u8 = &.{},
    /// The width of the last build.
    width: u16 = 80,
    full: FullBodies = .empty,
    full_gpa: ?std.mem.Allocator = null,
    /// Calls whose whole body the last build wants (in `arena`).
    wanted: std.ArrayList([]const u8) = .empty,

    const Key = struct { revision: u32, density: Density, changed: u32, width: u16, tick: i64, requests: usize, fan: u64 };

    pub fn deinit(self: *View, gpa: std.mem.Allocator) void {
        var it = self.choices.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.choices.deinit(gpa);
        gpa.free(self.selected);
        gpa.free(self.agent);
        self.dropFull(gpa);
        self.full.deinit(gpa);
        self.dropKept(gpa, 0);
        self.kept.deinit(gpa);
        if (self.arena) |*x| x.deinit();
        self.* = undefined;
    }

    fn defaultOpen(row: *const Row, density: Density) bool {
        if (row.kind == .card) return density != .compact;
        return switch (density) {
            .compact => false,
            .normal => (row.kind == .edits or (row.kind == .call and eql(row.calls[0].kind, "edit"))) and hasBody(row),
            .verbose => true,
        };
    }

    /// Builds the blocks if anything changed. They live until the next
    /// rebuild, so keys can act on what was last drawn.
    pub fn build(self: *View, gpa: std.mem.Allocator, d: *const model.Detail, o: Options, width: u16) ![]w.Block {
        if (!eql(self.agent, d.agent)) {
            const copy = try gpa.dupe(u8, d.agent);
            gpa.free(self.agent);
            self.agent = copy;
            self.reset(gpa);
            self.dropFull(gpa);
            gpa.free(self.selected);
            self.selected = &.{};
        }
        self.width = width;
        // A running call's clock and tail tick once a second.
        var running = false;
        for (d.records.items) |*r| if (r.kind == .tool and !r.tool.ended()) {
            running = true;
        };
        const key: Key = .{ .revision = d.revision, .density = o.density, .changed = self.changed, .width = width, .tick = if (running) @divFloor(o.now_ms, 1000) else 0, .requests = d.requests.items.len, .fan = o.fan.hash() };
        self.full_gpa = gpa;
        if (self.key) |k| if (std.meta.eql(k, key)) return self.blocks;
        // Only a finished build may be returned again.
        self.key = null;
        self.generation +%= 1;
        if (self.arena == null) self.arena = .init(gpa);
        _ = self.arena.?.reset(.retain_capacity);
        self.wanted = .empty;
        const a = self.arena.?.allocator();
        self.rows = try fan_out.appendRows(a, try rows(a, d.records.items, d.requests.items, o), o.fan);
        const blocks = try a.alloc(w.Block, self.rows.len);
        const row_w: usize = @max(width, 3) - 2;
        for (self.rows, blocks, 0..) |*row, *b, i| {
            b.* = try self.block(a, row, d.requests.items, o, row_w);
            try self.keep(gpa, i, b);
        }
        self.dropKept(gpa, blocks.len);
        self.blocks = blocks;
        self.key = key;
        return blocks;
    }

    /// Points block `i` at the previous build's copy if it came out the same,
    /// or at a new one. `ScrollView` caches by position, so position is enough.
    fn keep(self: *View, gpa: std.mem.Allocator, i: usize, b: *w.Block) !void {
        if (i < self.kept.items.len and self.kept.items[i].same(b.spans)) {
            b.spans = self.kept.items[i].spans;
            b.revision = self.kept.items[i].revision;
            return;
        }
        const copy = try Kept.init(gpa, b.spans, self.generation);
        errdefer gpa.free(copy.memory);
        if (i < self.kept.items.len) {
            gpa.free(self.kept.items[i].memory);
            self.kept.items[i] = copy;
        } else try self.kept.append(gpa, copy);
        b.spans = copy.spans;
        b.revision = copy.revision;
    }

    fn dropKept(self: *View, gpa: std.mem.Allocator, len: usize) void {
        if (self.kept.items.len <= len) return;
        for (self.kept.items[len..]) |k| gpa.free(k.memory);
        self.kept.items.len = len;
    }

    fn block(self: *View, a: std.mem.Allocator, row: *const Row, requests: []const Request, o: Options, width: usize) !w.Block {
        if (row.record) |r| return switch (row.kind) {
            .turn_started => .{ .spans = try dupe(a, &.{.{ .text = try std.fmt.allocPrint(a, "── turn {s}", .{r.turn}), .role = .muted }}) },
            .prompt => .{ .spans = try dupe(a, &.{ .{ .text = "› ", .role = .accent }, .{ .text = try clean(a, r.text) } }) },
            .text => .{ .spans = try dupe(a, &.{.{ .text = r.text }}), .indent = 2 },
            else => .{ .spans = try dupe(a, &.{.{ .text = try std.fmt.allocPrint(a, "turn {s} {s}", .{ r.turn, r.text }), .role = if (eql(r.text, "completed") or eql(r.text, "interrupted")) .muted else .err }}) },
        };
        switch (row.kind) {
            .fan_header => return .{ .spans = try fan_out.headerSpans(a, o.fan, width + 2) },
            .fan_keys => return .{ .spans = try fan_out.keySpans(a, o.fan), .indent = 2 },
            else => {},
        }
        const always = rowAlwaysOpen(row, requests, o);
        var open = always or defaultOpen(row, o.density);
        var chose = false;
        if (self.choices.get(row.id())) |c| if (c.always == always) {
            open = c.open;
            chose = true;
        };
        // `normal`'s edit diffs start with their first lines; a row the
        // user opened, or that has to be open, shows everything.
        const cut: ?usize = if (o.density == .normal and !chose and !always) preview_lines else null;
        // Showing it all: ask for what `agent.show` left out.
        if (open and cut == null) for (row.calls) |t| {
            if (!isCut(t) or !t.ended() or self.full.contains(t.call)) continue;
            if (row.kind == .explored and o.density != .verbose) continue;
            if (row.kind == .agent and t != row.calls[0] and !(t.failed() or o.density == .verbose)) continue;
            try self.wanted.append(a, t.call);
        };
        const spans = if (row.card) |c| try fan_out.cardSpans(a, c, width) else try rowSpans(a, row, requests, o, width, cut, &self.full);
        return .{ .spans = spans, .collapsible = true, .collapsed = !open, .preview = 1 };
    }

    fn dupe(a: std.mem.Allocator, s: []const w.Span) ![]const w.Span {
        return a.dupe(w.Span, s);
    }

    /// Builds again if the detail changed since the last draw. Rows point
    /// into the detail, so keys call this before they use them.
    pub fn refresh(self: *View, gpa: std.mem.Allocator, d: *const model.Detail, o: Options) !void {
        _ = try self.build(gpa, d, o, self.width);
    }

    /// The next whole body to ask for, marked as asked.
    pub fn nextWanted(self: *View) ?[]const u8 {
        const gpa = self.full_gpa orelse return null;
        while (self.wanted.pop()) |call| {
            if (self.full.contains(call)) continue;
            const key = gpa.dupe(u8, call) catch return null;
            self.full.put(gpa, key, null) catch {
                gpa.free(key);
                return null;
            };
            return call;
        }
        return null;
    }

    /// `agent.tool`'s answer for `call`; empty when it had nothing more,
    /// which also keeps it from being asked again.
    pub fn setFull(self: *View, gpa: std.mem.Allocator, agent: []const u8, call: []const u8, text: []const u8) !void {
        if (!eql(self.agent, agent)) return;
        const slot = self.full.getPtr(call) orelse return;
        const copy = try gpa.dupe(u8, text);
        if (slot.*) |old| gpa.free(old);
        slot.* = copy;
        self.changed +%= 1;
    }

    /// Unanswered requests went with the connection: ask again.
    pub fn forgetAsked(self: *View, gpa: std.mem.Allocator) void {
        var it = self.full.iterator();
        while (it.next()) |e| if (e.value_ptr.* == null) {
            const key = e.key_ptr.*;
            self.full.removeByPtr(e.key_ptr);
            gpa.free(key);
            it = self.full.iterator();
        };
        self.changed +%= 1;
    }

    fn dropFull(self: *View, gpa: std.mem.Allocator) void {
        var it = self.full.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| gpa.free(v);
        }
        self.full.clearRetainingCapacity();
    }

    /// The tool row or card at `index` of the last build.
    pub fn rowAt(self: *const View, index: usize) ?*const Row {
        if (index >= self.rows.len or !self.rows[index].selectable()) return null;
        return &self.rows[index];
    }

    /// The selected tool row or card, if it still exists.
    pub fn selectedRow(self: *const View) ?*const Row {
        const i = self.selectedIndex() orelse return null;
        return &self.rows[i];
    }

    pub fn selectedIndex(self: *const View) ?usize {
        if (self.selected.len == 0) return null;
        for (self.rows, 0..) |*row, i| if (eql(row.id(), self.selected)) return i;
        return null;
    }

    pub fn select(self: *View, gpa: std.mem.Allocator, index: usize) !void {
        const row = self.rowAt(index) orelse return;
        const copy = try gpa.dupe(u8, row.id());
        gpa.free(self.selected);
        self.selected = copy;
    }

    /// Records the choice for the row at `index`.
    pub fn choose(self: *View, gpa: std.mem.Allocator, index: usize, open: bool, requests: []const Request, o: Options) !void {
        const row = self.rowAt(index) orelse return;
        const always = rowAlwaysOpen(row, requests, o);
        const gop = try self.choices.getOrPut(gpa, row.id());
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, row.id()) catch |err| {
                self.choices.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = .{ .open = open, .always = always };
        self.changed +%= 1;
    }

    /// `E` / `C`: a choice for every row there is now.
    pub fn chooseAll(self: *View, gpa: std.mem.Allocator, open: bool, requests: []const Request, o: Options) !void {
        for (self.rows, 0..) |*row, i| if (row.selectable()) try self.choose(gpa, i, open, requests, o);
    }

    /// The density changed: the choices start over.
    pub fn reset(self: *View, gpa: std.mem.Allocator) void {
        var it = self.choices.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.choices.clearRetainingCapacity();
        self.changed +%= 1;
    }
};

// ---- Pager ---------------------------------------------------------------

/// `p` / `J`: a whole body, or the raw tool JSON, over
/// the main view. It opens with what the transcript has; `agent.tool` then
/// fills in each call, whole. Owned text only.
pub const Pager = struct {
    pub const Mode = enum { body, raw };

    mode: Mode,
    title: []u8,
    /// A generation the responses of `agent.tool` must match.
    id: u64,
    /// One part per call.
    parts: [][]u8,
    scroll: w.ScrollView = .{},
    revision: u32 = 0,
    spans: std.ArrayList(w.Span) = .empty,
    text: std.ArrayList(u8) = .empty,
    block: [1]w.Block = undefined,

    pub fn deinit(self: *Pager, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        for (self.parts) |p| gpa.free(p);
        gpa.free(self.parts);
        self.scroll.deinit(gpa);
        self.spans.deinit(gpa);
        self.text.deinit(gpa);
        self.* = undefined;
    }

    /// `agent.tool`'s answer for part `index`: its body, or its JSON.
    pub fn fill(self: *Pager, gpa: std.mem.Allocator, index: usize, ok: std.json.Value) !void {
        if (index >= self.parts.len) return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const part = switch (self.mode) {
            .raw => try std.json.Stringify.valueAlloc(gpa, try rawOf(arena.allocator(), ok), .{ .whitespace = .indent_2 }),
            .body => try gpa.dupe(u8, try bodyOf(arena.allocator(), ok)),
        };
        gpa.free(self.parts[index]);
        self.parts[index] = part;
        self.revision +%= 1;
    }

    /// `ok` for `J`: the harness's raw input as the JSON it is, not a string
    /// of it. A cut one stays as text, with what says it is cut.
    fn rawOf(a: std.mem.Allocator, ok: std.json.Value) !std.json.Value {
        if (ok != .object) return ok;
        const raw = ok.object.get("raw_input") orelse return ok;
        if (raw != .object) return ok;
        if (raw.object.get("truncated")) |t| if (t == .bool and t.bool) return ok;
        const text = raw.object.get("text") orelse return ok;
        if (text != .string) return ok;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text.string, .{}) catch return ok;
        var copy = try ok.object.clone(a);
        try copy.put(a, "raw_input", parsed);
        return .{ .object = copy };
    }

    /// `ok`'s body, headed by the call's line when the row has several.
    fn bodyOf(a: std.mem.Allocator, ok: std.json.Value) ![]const u8 {
        if (ok != .object) return "";
        const get = struct {
            fn s(v: std.json.Value, name: []const u8) []const u8 {
                const x = v.object.get(name) orelse return "";
                return if (x == .string) x.string else "";
            }
        }.s;
        var body: []const u8 = get(ok, "tail");
        var note_: []const u8 = "";
        if (ok.object.get("body")) |b| if (b == .object) {
            body = get(b, "text");
            if (b.object.get("truncated")) |t| if (t == .bool and t.bool) {
                note_ = "\n… cut by harness.body_max";
            };
        };
        return std.fmt.allocPrint(a, "{s}  {s}\n{s}{s}", .{ get(ok, "name"), get(ok, "title"), if (body.len > 0) body else "(no output)", note_ });
    }

    /// The pager's one block, rebuilt only when a part changed.
    pub fn blocks(self: *Pager, gpa: std.mem.Allocator) ![]const w.Block {
        self.text.clearRetainingCapacity();
        for (self.parts, 0..) |p, i| {
            if (i > 0) try self.text.appendSlice(gpa, "\n\n");
            try self.text.appendSlice(gpa, p);
        }
        // `clean` hands back its input or arena memory: keep a copy here.
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const c = try clean(arena.allocator(), self.text.items);
        if (c.ptr != self.text.items.ptr) {
            const copy = try gpa.dupe(u8, c);
            defer gpa.free(copy);
            self.text.clearRetainingCapacity();
            try self.text.appendSlice(gpa, copy);
        }
        self.spans.clearRetainingCapacity();
        try self.spans.append(gpa, .{ .text = self.text.items });
        self.block = .{.{ .spans = self.spans.items, .revision = self.revision }};
        return &self.block;
    }
};

/// What the pager opens with, before `agent.tool` answers: the row's own
/// text, one part per call. `parts` and its strings are owned by `gpa`.
pub fn pagerParts(gpa: std.mem.Allocator, row: *const Row, mode: Pager.Mode) ![][]u8 {
    const parts = try gpa.alloc([]u8, row.calls.len);
    var n: usize = 0;
    errdefer {
        for (parts[0..n]) |p| gpa.free(p);
        gpa.free(parts);
    }
    for (row.calls) |t| {
        parts[n] = switch (mode) {
            .raw => try std.fmt.allocPrint(gpa, "{s}  loading…", .{t.call}),
            .body => try std.fmt.allocPrint(gpa, "{s}  {s}\n{s}", .{ t.name, t.title, if (t.body.len > 0) t.body else if (t.tail.len > 0) t.tail else "(no output)" }),
        };
        n += 1;
    }
    return parts;
}

/// The pager's title.
pub fn pagerTitle(gpa: std.mem.Allocator, row: *const Row, mode: Pager.Mode) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    return std.fmt.allocPrint(gpa, "{s} · {s}{s}", .{ try rowVerb(a, row), try fit(a, try rowTitle(a, row), 60), if (mode == .raw) " · raw JSON" else "" });
}

const testing = std.testing;

test "clean drops escapes and control characters, and keeps clean text as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "ok\nline";
    try testing.expectEqual(plain.ptr, (try clean(a, plain)).ptr);
    try testing.expectEqualStrings("red done  tab", try clean(a, "\x1b[31mred\x1b[0m done\ttab\x07"));
    try testing.expectEqualStrings("title", try clean(a, "\x1b]0;x\x07title"));
}

test "fit and lastLines cut by cells and by lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("abc", try fit(a, "abc", 3));
    try testing.expectEqualStrings("ab…", try fit(a, "abcd", 3));
    try testing.expectEqualStrings("c\nd", lastLines("a\nb\nc\nd\n", 2));
    try testing.expectEqualStrings("a", lastLines("a", 2));
}

test "clean: C1 controls (CSI U+009B, OSC U+009D) are dropped like their escape forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ab31mc", try clean(a, "a\xc2\x9bb31m\xc2\x85c"));
    try std.testing.expectEqualStrings("é ©", try clean(a, "é \xc2\xa9"));
    // Already clean text comes back as it is.
    const plain = "plain \xc2\xa0 text";
    try std.testing.expectEqualStrings(plain, try clean(a, plain));
}
