//! The TUI's copy of the inbox: the items
//! of the last `inbox.list`, in the daemon's order (blocking kinds first in
//! urgency order, oldest first within a kind, then `review`). Pure data, no
//! I/O, so it is tested by feeding it JSON. The inbox screen and the inline
//! attention in the agent view both draw from it.
const std = @import("std");
const Value = std.json.Value;

/// Attention kinds, in urgency order.
pub const Kind = enum {
    approval,
    question,
    plan,
    failed,
    limit,
    review,

    pub fn blocking(self: Kind) bool {
        return self != .review;
    }

    pub fn glyph(self: Kind) []const u8 {
        return switch (self) {
            .approval, .question, .plan => "▲",
            .failed, .limit => "✕",
            .review => "●",
        };
    }

    /// The row's lead word, e.g. "Approve: zig build test".
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .approval => "Approve",
            .question => "Question",
            .plan => "Plan",
            .failed => "Failed",
            .limit => "Limit",
            .review => "Review",
        };
    }

    /// The inbox screen's group: blocking requests, failures,
    /// then what is only waiting to be read.
    pub fn group(self: Kind) usize {
        return switch (self) {
            .approval, .question, .plan => 0,
            .failed, .limit => 1,
            .review => 2,
        };
    }
};

pub const max_questions = 8;
pub const max_labels = 16;
pub const max_question_text = 500;
pub const max_label_text = 200;
pub const max_options_bytes = 8 * 1024;

pub fn freeOptions(gpa: std.mem.Allocator, options: []Question) void {
    for (options) |*q| q.deinit(gpa);
    gpa.free(options);
}

/// `s` as one printable line of at most `max` bytes in `gpa`: the daemon
/// cleans what the harness sent, this does it again for a daemon that does
/// not (escape sequences and control characters would reach the screen).
fn lineOf(gpa: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const clean = try @import("transcript.zig").clean(arena.allocator(), s);
    var end = @min(clean.len, max);
    while (end > 0 and end < clean.len and clean[end] & 0xC0 == 0x80) end -= 1;
    const out = try gpa.dupe(u8, clean[0..end]);
    for (out) |*c| if (c.* == '\n') {
        c.* = ' ';
    };
    return out;
}

/// A label the daemon offers as it is (a pick sends it back unchanged): the
/// same rule as `events.plainLabel`, kept equal by a test.
pub fn plainLabel(s: []const u8) bool {
    if (s.len == 0 or s.len > max_label_text or !std.unicode.utf8ValidateSlice(s)) return false;
    if (std.mem.trim(u8, s, " ").len == 0) return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < 0x20 or c == 0x7f) return false;
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) return false;
    }
    return true;
}

fn parseQuestion(gpa: std.mem.Allocator, q: Value, total: *usize) !?Question {
    if (q != .object) return null;
    const raw_id = str(q.object.get("id")) orelse return null;
    if (raw_id.len == 0 or raw_id.len > 16) return null;
    const id = try lineOf(gpa, raw_id, 16);
    errdefer gpa.free(id);
    var text = try lineOf(gpa, str(q.object.get("question")) orelse "", max_question_text);
    errdefer gpa.free(text);
    // The same budget rule as the daemon: each field against what is left.
    // A question with no room stays as a bare entry (no text, no labels): it
    // is answered with a typed answer.
    if (total.* + text.len > max_options_bytes) {
        gpa.free(text);
        text = try gpa.alloc(u8, 0);
        const none = try gpa.alloc([]u8, 0);
        const free0 = if (q.object.get("free_text")) |f| f == .bool and f.bool else false;
        return .{ .id = id, .text = text, .labels = none, .free_text = free0 };
    }
    total.* += text.len;
    var labels: std.ArrayList([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    if (q.object.get("labels")) |lv| if (lv == .array) for (lv.array.items) |l| {
        if (l != .string) continue;
        if (labels.items.len >= max_labels) break;
        // Never cleaned or cut: it is what a pick sends.
        if (!plainLabel(l.string)) continue;
        if (total.* + l.string.len > max_options_bytes) break;
        const copy = try gpa.dupe(u8, l.string);
        errdefer gpa.free(copy);
        total.* += copy.len;
        try labels.append(gpa, copy);
    };
    const owned = try labels.toOwnedSlice(gpa);
    const free = if (q.object.get("free_text")) |f| f == .bool and f.bool else false;
    return .{ .id = id, .text = text, .labels = owned, .free_text = free };
}

/// The `options` of an `inbox.list` item (`[{id, question, labels, free_text}]`),
/// copied into `gpa`. Malformed parts are skipped, the rest is bounded. The
/// caller frees with `freeOptions`.
pub fn parseOptions(gpa: std.mem.Allocator, v: ?Value) std.mem.Allocator.Error![]Question {
    var opts: std.ArrayList(Question) = .empty;
    errdefer {
        for (opts.items) |*q| q.deinit(gpa);
        opts.deinit(gpa);
    }
    const list = v orelse return opts.toOwnedSlice(gpa);
    if (list != .array) return opts.toOwnedSlice(gpa);
    var total: usize = 0;
    for (list.array.items) |qv| {
        if (opts.items.len > max_questions) break;
        const q = (try parseQuestion(gpa, qv, &total)) orelse continue;
        var owned = q;
        errdefer owned.deinit(gpa);
        // Past `max_questions` only the daemon's marker is kept: a bare
        // question that takes no typed answer (and the list ends there).
        if (opts.items.len == max_questions and (owned.labels.len > 0 or owned.free_text)) {
            owned.deinit(gpa);
            break;
        }
        try opts.append(gpa, owned);
    }
    return opts.toOwnedSlice(gpa);
}

/// A hash of what an item offers (its question ids, texts and labels): what
/// the screen drew is what a key picks from only while this is unchanged.
pub fn optionsSig(it: *const Item) u64 {
    var h = std.hash.Wyhash.init(0);
    for (it.options) |q| {
        h.update(q.id);
        h.update("\x00");
        h.update(q.text);
        for (q.labels) |l| {
            h.update("\x01");
            h.update(l);
        }
        h.update("\x02");
    }
    return h.final();
}

pub fn itemHash(it: *const Item) u64 {
    var h = std.hash.Wyhash.init(1);
    h.update(it.agent);
    h.update("/");
    h.update(it.item);
    return h.final();
}

/// The picks made so far on one item with several questions: one option
/// index per question, in order. They belong to that item as drawn
/// (`optionsSig`): another item, or other options, start over.
pub const Picks = struct {
    key: u64 = 0,
    sig: u64 = 0,
    n: usize = 0,
    chosen: [max_questions]u8 = @splat(0),

    pub fn count(self: *Picks, it: *const Item) usize {
        if (self.n > 0 and (self.key != itemHash(it) or self.sig != optionsSig(it))) self.n = 0;
        return self.n;
    }

    pub fn push(self: *Picks, it: *const Item, option: usize) void {
        _ = self.count(it);
        self.key = itemHash(it);
        self.sig = optionsSig(it);
        if (self.n < self.chosen.len) {
            self.chosen[self.n] = @intCast(option);
            self.n += 1;
        }
    }
};

/// One drawn line of a question's options.
pub const OptionRow = struct {
    /// The key (`1`–`9`), `✓` for a picked one, `·` for one not pickable yet.
    mark: []const u8,
    text: []const u8,
    /// A question's own text line: `mark` is empty.
    header: bool = false,
};

/// The option lines of a `question` item, with `picks` already made (one
/// index per question, in order): the first unanswered question's options
/// carry the keys, answered ones show their pick.
pub fn optionRows(a: std.mem.Allocator, it: *const Item, picks: []const u8) ![]const OptionRow {
    var out: std.ArrayList(OptionRow) = .empty;
    for (it.options, 0..) |q, qi| {
        if (it.options.len > 1 or (q.text.len > 0 and !std.mem.eql(u8, q.text, it.reason)))
            if (q.text.len > 0) try out.append(a, .{ .mark = "", .text = q.text, .header = true });
        if (qi < picks.len) {
            if (picks[qi] < q.labels.len) try out.append(a, .{ .mark = "✓", .text = q.labels[picks[qi]] });
            continue;
        }
        for (q.labels, 1..) |label, n| {
            const live = qi == picks.len and n <= 9;
            try out.append(a, .{ .mark = if (live) try std.fmt.allocPrint(a, "{d}", .{n}) else "·", .text = label });
        }
    }
    return out.items;
}

pub const group_names = [_][]const u8{ "Blocking · agent stopped", "Failed", "To review · not blocking" };

pub const Context = struct { turn: []u8, text: []u8 };

/// One question of a `question` item with its options (`inbox.list`
/// `options`): `id` is `q1`, `q2`, … (the key of the answer's `args`).
pub const Question = struct {
    id: []u8,
    text: []u8,
    labels: [][]u8,
    /// A typed answer is taken besides the labels.
    free_text: bool = false,

    fn deinit(self: *Question, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.text);
        for (self.labels) |l| gpa.free(l);
        gpa.free(self.labels);
    }
};

fn digits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Seconds since the epoch of an RFC 3339 timestamp (`2026-11-07T15:00:00Z`,
/// or with a `+hh:mm` offset; fractions are ignored); null when it is not one.
pub fn parseRfc3339(text: []const u8) ?i64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != 't') or text[13] != ':' or text[16] != ':') return null;
    for ([_][]const u8{ text[0..4], text[5..7], text[8..10], text[11..13], text[14..16], text[17..19] }) |d| if (!digits(d)) return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or hour > 23 or minute > 59 or second > 60) return null;
    if (day < 1 or day > std.time.epoch.getDaysInMonth(std.math.cast(std.time.epoch.Year, year) orelse return null, @fromBackingInt(@intCast(month)))) return null;
    var i: usize = 19;
    if (text[i] == '.') {
        const start = i + 1;
        i = start;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start or i >= text.len) return null;
    }
    var offset: i64 = 0;
    if (text[i] == 'Z' or text[i] == 'z') {
        if (i + 1 != text.len) return null;
    } else if (text[i] == '+' or text[i] == '-') {
        if (text.len != i + 6 or text[i + 3] != ':') return null;
        if (!digits(text[i + 1 .. i + 3]) or !digits(text[i + 4 .. i + 6])) return null;
        const oh = std.fmt.parseInt(i64, text[i + 1 .. i + 3], 10) catch return null;
        const om = std.fmt.parseInt(i64, text[i + 4 .. i + 6], 10) catch return null;
        if (oh > 23 or om > 59) return null;
        offset = (oh * 60 + om) * 60;
        if (text[i] == '-') offset = -offset;
    } else return null;
    // Days from the civil date (Hinnant's algorithm).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (month + (if (month > 2) @as(i64, -3) else 9)) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second - offset;
}

/// The offset of the local time zone from UTC, in seconds, at `unix_s`.
/// Falls back to UTC (0) when the C library cannot say.
pub fn localUtcOffset(unix_s: i64) i32 {
    const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
    const c = struct {
        extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;
    };
    const t: c_long = std.math.cast(c_long, unix_s) orelse return 0;
    var tm: Tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return 0;
    return std.math.cast(i32, tm.gmtoff) orelse 0;
}

/// "resets at 15:00" for a limit item's `resets_at`,
/// in local time. `override` fixes the UTC offset (tests); null asks the
/// system per instant, so a reset across a DST change shows the right
/// clock time. A reset on another day than `now_s`'s (or with `now_s`
/// unknown, 0) adds the date ("resets at 11-08 15:00"); one already past
/// reads "reset at ...". Empty when `resets_at` is empty or not RFC 3339.
pub fn resetsAtLabel(a: std.mem.Allocator, resets_at: []const u8, override: ?i32, now_s: i64) std.mem.Allocator.Error![]const u8 {
    return resetsAtLabelWith(a, resets_at, override, now_s, localUtcOffset);
}

pub fn resetsAtLabelWith(a: std.mem.Allocator, resets_at: []const u8, override: ?i32, now_s: i64, offset_at: *const fn (i64) i32) std.mem.Allocator.Error![]const u8 {
    const at = parseRfc3339(resets_at) orelse return "";
    const at_off: i64 = override orelse offset_at(at);
    const now_off: i64 = override orelse offset_at(now_s);
    const local: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, at + at_off)) };
    const now: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, now_s + now_off)) };
    const ds = local.getDaySeconds();
    const hm = .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour() };
    const verb = if (now_s != 0 and at <= now_s) "reset" else "resets";
    if (now_s != 0 and local.getEpochDay().day == now.getEpochDay().day)
        return std.fmt.allocPrint(a, "{s} at {d:0>2}:{d:0>2}", .{verb} ++ hm);
    const md = local.getEpochDay().calculateYearDay().calculateMonthDay();
    return std.fmt.allocPrint(a, "{s} at {d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ verb, md.month.numeric(), md.day_index + 1 } ++ hm);
}

pub const Item = struct {
    agent: []u8,
    /// The request id, or the kind's name for `failed`, `limit`, `review`.
    item: []u8,
    /// Empty for state items.
    request: []u8,
    kind: Kind,
    reason: []u8,
    /// The agent's title.
    title: []u8,
    /// The narrowest grant `allow_always` records (approvals); empty: none.
    grant: []u8,
    /// A `limit` item's `resets_at` (RFC 3339 UTC);
    /// empty: the harness did not say.
    resets_at: []u8 = &.{},
    age_s: u64,
    stale: bool,
    /// Waiting in the harness's own TUI: answered
    /// there, so the item offers *Focus split* instead of the keys.
    away: bool = false,
    /// What a question offers, per question; empty: not known.
    options: []Question = &.{},
    context: []Context,

    fn deinit(self: *Item, gpa: std.mem.Allocator) void {
        for ([_][]u8{ self.agent, self.item, self.request, self.reason, self.title, self.grant, self.resets_at }) |s| gpa.free(s);
        for (self.context) |c| {
            gpa.free(c.turn);
            gpa.free(c.text);
        }
        gpa.free(self.context);
        freeOptions(gpa, self.options);
        self.* = undefined;
    }

    pub fn is(self: *const Item, agent: []const u8, item: []const u8) bool {
        return std.mem.eql(u8, self.agent, agent) and std.mem.eql(u8, self.item, item);
    }
};

/// Which blocking items this TUI has seen, for the BEL: one per item, when
/// it first shows. Items already there when the
/// TUI starts are on the screen in front of the human, so they do not ring.
pub const BellWatch = struct {
    seen: std.StringArrayHashMapUnmanaged(void) = .empty,
    started: bool = false,

    pub fn deinit(self: *BellWatch, gpa: std.mem.Allocator) void {
        for (self.seen.keys()) |k| gpa.free(k);
        self.seen.deinit(gpa);
    }

    /// Takes a new inbox; true when it holds a blocking item not seen before.
    /// An item that went (answered, snoozed) rings again if it comes back.
    pub fn update(self: *BellWatch, gpa: std.mem.Allocator, items: []const Item) !bool {
        var next: std.StringArrayHashMapUnmanaged(void) = .empty;
        errdefer {
            for (next.keys()) |k| gpa.free(k);
            next.deinit(gpa);
        }
        var fresh = false;
        for (items) |*it| {
            if (!it.kind.blocking()) continue;
            const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ it.agent, it.item });
            errdefer gpa.free(key);
            const slot = try next.getOrPut(gpa, key);
            if (slot.found_existing) {
                gpa.free(key);
                continue;
            }
            fresh = fresh or !self.seen.contains(key);
        }
        self.deinit(gpa);
        self.seen = next;
        defer self.started = true;
        return fresh and self.started;
    }
};

pub const Inbox = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    /// Bumped on every change, for the detail's wrap cache.
    revision: u32 = 0,
    /// An `inbox.list` answer arrived at least once.
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator) Inbox {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Inbox) void {
        self.clear();
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    fn clear(self: *Inbox) void {
        for (self.items.items) |*it| it.deinit(self.gpa);
        self.items.clearRetainingCapacity();
    }

    /// Replaces the items with an `inbox.list` result.
    pub fn apply(self: *Inbox, ok: Value) !void {
        if (ok != .object) return;
        const list = ok.object.get("items") orelse return;
        if (list != .array) return;
        self.clear();
        self.loaded = true;
        self.revision +%= 1;
        for (list.array.items) |v| {
            if (v != .object) continue;
            const o = v.object;
            const kind = std.meta.stringToEnum(Kind, str(o.get("kind")) orelse continue) orelse continue;
            var it = try self.newItem(o, kind);
            errdefer it.deinit(self.gpa);
            try self.items.append(self.gpa, it);
        }
    }

    fn newItem(self: *Inbox, o: std.json.ObjectMap, kind: Kind) !Item {
        const gpa = self.gpa;
        var parts: [7][]u8 = undefined;
        var n: usize = 0;
        errdefer for (parts[0..n]) |p| gpa.free(p);
        for ([_][]const u8{ "agent", "item", "request", "reason", "title", "grant", "resets_at" }) |name| {
            parts[n] = try gpa.dupe(u8, str(o.get(name)) orelse "");
            n += 1;
        }
        var ctx: std.ArrayList(Context) = .empty;
        errdefer {
            for (ctx.items) |c| {
                gpa.free(c.turn);
                gpa.free(c.text);
            }
            ctx.deinit(gpa);
        }
        if (o.get("context")) |cv| if (cv == .array) for (cv.array.items) |c| {
            if (c != .object) continue;
            const turn = try gpa.dupe(u8, str(c.object.get("turn")) orelse "");
            errdefer gpa.free(turn);
            const text = try gpa.dupe(u8, str(c.object.get("text")) orelse "");
            errdefer gpa.free(text);
            try ctx.append(gpa, .{ .turn = turn, .text = text });
        };
        const options = try parseOptions(gpa, o.get("options"));
        errdefer freeOptions(gpa, options);
        const age: u64 = if (o.get("age_s")) |x| (if (x == .integer and x.integer >= 0) @intCast(x.integer) else 0) else 0;
        return .{
            .agent = parts[0],
            .item = parts[1],
            .request = parts[2],
            .reason = parts[3],
            .title = parts[4],
            .grant = parts[5],
            .resets_at = parts[6],
            .kind = kind,
            .age_s = age,
            .stale = if (o.get("stale")) |s| s == .bool and s.bool else false,
            .away = if (o.get("away")) |s| s == .bool and s.bool else false,
            .options = options,
            .context = try ctx.toOwnedSlice(gpa),
        };
    }

    pub fn find(self: *const Inbox, agent: []const u8, item: []const u8) ?*Item {
        for (self.items.items) |*it| if (it.is(agent, item)) return it;
        return null;
    }
};

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// `1m`, `12m`, `3h`, `2d` for an age in seconds.
pub fn ageText(a: std.mem.Allocator, s: u64) ![]const u8 {
    if (s < 60) return std.fmt.allocPrint(a, "{d}s", .{s});
    if (s < 3600) return std.fmt.allocPrint(a, "{d}m", .{s / 60});
    if (s < 48 * 3600) return std.fmt.allocPrint(a, "{d}h", .{s / 3600});
    return std.fmt.allocPrint(a, "{d}d", .{s / 86400});
}

test "inbox: apply keeps the daemon's order and every field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ib = Inbox.init(std.testing.allocator);
    defer ib.deinit();
    try ib.apply(try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"items":[{"agent":"a3","kind":"approval","age_s":70,"reason":"Run zig build?","item":"p1","request":"p1","grant":"exec:zig","title":"build","stale":false,"context":[{"turn":"t1","text":"hi"}]},
        \\{"agent":"a4","kind":"failed","age_s":5,"reason":"oops","item":"failed","title":"x","stale":true,"context":[]},{"kind":"nope"}]}
    , .{}));
    try std.testing.expectEqual(@as(usize, 2), ib.items.items.len);
    const first = ib.items.items[0];
    try std.testing.expectEqual(Kind.approval, first.kind);
    try std.testing.expectEqualStrings("exec:zig", first.grant);
    try std.testing.expectEqualStrings("hi", first.context[0].text);
    try std.testing.expect(ib.find("a4", "failed").?.stale);
    try std.testing.expectEqualStrings("", ib.find("a4", "failed").?.request);
}

test "options: malformed parts are skipped, text is cleaned, labels are kept as they are or left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\[{"question":"no id","labels":["x"]},
        \\ {"id":"q1","question":"A\u001b[31m?\n\u009b","free_text":true,"labels":["one\u001b]0;title\u0007","two","",5,null,{"label":"nope"},"c1\u009bx","  ","three"]},
        \\ {"id":"q2"},
        \\ "not an object",
        \\ {"id":"","labels":["dropped"]},
        \\ {"id":"q3","labels":"not a list"}]
    ;
    const got = try parseOptions(std.testing.allocator, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    defer freeOptions(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("q1", got[0].id);
    try std.testing.expectEqualStrings("A? ", got[0].text);
    try std.testing.expect(got[0].free_text and !got[1].free_text);
    // A label is never cleaned: one with a control character is not offered.
    try std.testing.expectEqual(@as(usize, 2), got[0].labels.len);
    try std.testing.expectEqualStrings("two", got[0].labels[0]);
    try std.testing.expectEqualStrings("three", got[0].labels[1]);
    try std.testing.expectEqual(@as(usize, 0), got[1].labels.len);
    try std.testing.expectEqual(@as(usize, 0), got[2].labels.len);

    // Absent, null or of the wrong type: no options.
    for ([_][]const u8{ "null", "{}", "\"x\"", "[]" }) |bad| {
        const none = try parseOptions(std.testing.allocator, try std.json.parseFromSliceLeaky(Value, a, bad, .{}));
        defer freeOptions(std.testing.allocator, none);
        try std.testing.expectEqual(@as(usize, 0), none.len);
    }
    const absent = try parseOptions(std.testing.allocator, null);
    defer freeOptions(std.testing.allocator, absent);
    try std.testing.expectEqual(@as(usize, 0), absent.len);
}

test "options: the limits are the daemon's, and a label is plain by the same rule" {
    const events = @import("../eventlog/events.zig");
    try std.testing.expectEqual(events.max_questions, max_questions);
    try std.testing.expectEqual(events.max_labels, max_labels);
    try std.testing.expectEqual(events.max_question_text, max_question_text);
    try std.testing.expectEqual(events.max_label_text, max_label_text);
    try std.testing.expectEqual(events.max_options_bytes, max_options_bytes);
    const long: [201]u8 = @splat('x');
    for ([_][]const u8{ "", " ", "ok", "tab\there", "esc\x1b[0m", "c1\xc2\x9b", "c1 ok \xc2\xa0", "bad\xff", "é", &long, long[0..200] }) |label| {
        try std.testing.expectEqual(events.plainLabel(label), plainLabel(label));
    }
}

test "options: the daemon's options reach the screen as they are, also at the 8 KiB boundary" {
    const contract = @import("../harness/contract.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 16 + 16 labels of 200 bytes, then 8 of 200, one of 192 (8,192 in all)
    // and one more byte, which does not fit.
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "[");
    const counts = [_]usize{ 16, 16, 8 };
    for (counts, 0..) |n, q| {
        if (q > 0) try src.appendSlice(a, ",");
        try src.appendSlice(a, "{\"options\":[");
        for (0..n) |i| {
            if (i > 0) try src.appendSlice(a, ",");
            try src.print(a, "\"{d:0>3}", .{q * 100 + i});
            try src.appendNTimes(a, 'x', 197);
            try src.appendSlice(a, "\"");
        }
        if (q == 2) {
            try src.appendSlice(a, ",\"");
            try src.appendNTimes(a, 'y', 192);
            try src.appendSlice(a, "\",\"z\"");
        }
        try src.appendSlice(a, "]}");
    }
    try src.appendSlice(a, "]");
    const daemon = try contract.questionOptions(a, try std.json.parseFromSliceLeaky(Value, a, src.items, .{}), false);
    try std.testing.expectEqual(@as(usize, 3), daemon.len);
    try std.testing.expectEqual(@as(usize, 9), daemon[2].labels.len);
    var total: usize = 0;
    for (daemon) |q| for (q.labels) |l| {
        total += l.len;
    };
    try std.testing.expectEqual(@as(usize, 8192), total);

    const wire = try std.json.Stringify.valueAlloc(a, daemon, .{});
    const tui = try parseOptions(std.testing.allocator, try std.json.parseFromSliceLeaky(Value, a, wire, .{}));
    defer freeOptions(std.testing.allocator, tui);
    try std.testing.expectEqual(daemon.len, tui.len);
    for (daemon, tui) |d, t| {
        try std.testing.expectEqualStrings(d.id, t.id);
        try std.testing.expectEqual(d.labels.len, t.labels.len);
        for (d.labels, t.labels) |dl, tl| try std.testing.expectEqualStrings(dl, tl);
    }
}

test "options: parsing leaks nothing and survives every allocation failure" {
    const json =
        \\[{"id":"q1","question":"Which?\u001b[0m","labels":["one","two","three"]},{"id":"q2","question":"Next","labels":["a"]},{"labels":[]}]
    ;
    const Run = struct {
        fn run(gpa: std.mem.Allocator, src: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), src, .{});
            const got = try parseOptions(gpa, v);
            freeOptions(gpa, got);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{json});
    // A question the budget has no room for: kept bare, nothing leaks.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "[");
    for (1..4) |q| {
        try src.print(std.testing.allocator, "{{\"id\":\"q{d}\",\"question\":\"x\",\"labels\":[", .{q});
        for (0..16) |i| {
            if (i > 0) try src.append(std.testing.allocator, ',');
            try src.print(std.testing.allocator, "\"{d:0>3}", .{i});
            try src.appendNTimes(std.testing.allocator, 'x', 190);
            try src.append(std.testing.allocator, '"');
        }
        try src.appendSlice(std.testing.allocator, "]},");
    }
    try src.appendSlice(std.testing.allocator, "{\"id\":\"q4\",\"question\":\"");
    try src.appendNTimes(std.testing.allocator, 'a', 500);
    try src.appendSlice(std.testing.allocator, "\",\"labels\":[\"a\"]}]");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{src.items});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try parseOptions(std.testing.allocator, try std.json.parseFromSliceLeaky(Value, arena.allocator(), src.items, .{}));
    defer freeOptions(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqual(@as(usize, 0), got[3].text.len);
    try std.testing.expectEqual(@as(usize, 0), got[3].labels.len);
}

test "options: a ninth entry is kept only as the daemon's marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "[");
    for (1..9) |q| try src.print(a, "{{\"id\":\"q{d}\",\"question\":\"Q\",\"labels\":[\"a\"]}},", .{q});
    try src.appendSlice(a, "{\"id\":\"q9\",\"question\":\"\",\"labels\":[],\"free_text\":false,\"labels_omitted\":true},{\"id\":\"q10\",\"question\":\"Q\",\"labels\":[\"a\"]}]");
    const got = try parseOptions(std.testing.allocator, try std.json.parseFromSliceLeaky(Value, a, src.items, .{}));
    defer freeOptions(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 9), got.len);
    try std.testing.expectEqualStrings("q9", got[8].id);
    try std.testing.expect(got[8].labels.len == 0 and !got[8].free_text);
    // A ninth entry with labels would not fit the picks: dropped.
    const with_labels = try std.mem.replaceOwned(u8, a, src.items, "\"labels\":[],\"free_text\":false", "\"labels\":[\"x\"],\"free_text\":false");
    const cut = try parseOptions(std.testing.allocator, try std.json.parseFromSliceLeaky(Value, a, with_labels, .{}));
    defer freeOptions(std.testing.allocator, cut);
    try std.testing.expectEqual(@as(usize, 8), cut.len);
    try std.testing.expectEqual(@as(usize, max_questions), (Picks{}).chosen.len);
}

test "options: picks belong to their item and options; optionRows numbers the open question" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ib = Inbox.init(std.testing.allocator);
    defer ib.deinit();
    try ib.apply(try std.json.parseFromSliceLeaky(Value, a,
        \\{"items":[{"agent":"a1","kind":"question","item":"r1","request":"r1","reason":"Two things","title":"t","context":[],
        \\ "options":[{"id":"q1","question":"First?","labels":["a","b"]},{"id":"q2","question":"Second?","labels":["c","d","e"]}]}]}
    , .{}));
    const it = &ib.items.items[0];
    var picks: Picks = .{};
    try std.testing.expectEqual(@as(usize, 0), picks.count(it));
    const rows0 = try optionRows(a, it, picks.chosen[0..0]);
    try std.testing.expectEqualStrings("1", rows0[1].mark);
    try std.testing.expectEqualStrings("·", rows0[4].mark);
    picks.push(it, 1);
    try std.testing.expectEqual(@as(usize, 1), picks.count(it));
    const rows1 = try optionRows(a, it, picks.chosen[0..1]);
    try std.testing.expectEqualStrings("✓", rows1[1].mark);
    try std.testing.expectEqualStrings("b", rows1[1].text);
    try std.testing.expectEqualStrings("1", rows1[3].mark);
    // Other options for the same item: the picks start over.
    try ib.apply(try std.json.parseFromSliceLeaky(Value, a,
        \\{"items":[{"agent":"a1","kind":"question","item":"r1","request":"r1","reason":"Two things","title":"t","context":[],
        \\ "options":[{"id":"q1","question":"First?","labels":["a","z"]},{"id":"q2","question":"Second?","labels":["c"]}]}]}
    , .{}));
    try std.testing.expectEqual(@as(usize, 0), picks.count(&ib.items.items[0]));
}
