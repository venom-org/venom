//! Snapshot v2 is JSON of durable state, never allocator/container internals.
//! Maps are ordered key/value rows; lists are arrays; events use their log schema.
//! All fields are required: changing the projection requires a format migration.
//! v1 (before `Request.options`) is migrated on restore: see `migrateV1`.
const std = @import("std");
const Event = @import("events.zig").Event;
const State = @import("decider.zig").State;
const workspaces = @import("workspaces.zig");

pub fn encode(state: *const State, a: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try write(State, state.*, &w);
    return out.toOwnedSlice();
}

pub const version: u32 = 2;

pub fn restore(state: *State, bytes: []const u8, from_version: u32) !void {
    const a = state.arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (value != .object) return error.InvalidSnapshot;
    if (from_version == 1) try migrateV1(a, value);
    inline for (@typeInfo(State).@"struct".field_names, @typeInfo(State).@"struct".field_types) |name, T| {
        if (comptime !std.mem.eql(u8, name, "arena")) @field(state, name) = try read(T, a, value.object.get(name) orelse return error.InvalidSnapshot);
    }
    // A snapshot from before the state kept these out.
    for (state.workspaces.values()) |*w| w.repos = try workspaces.nameable(a, w.repos);
}

/// v1 -> v2: every pending request gains `options: []`.
fn migrateV1(a: std.mem.Allocator, root: std.json.Value) !void {
    const agents = root.object.get("agents") orelse return error.InvalidSnapshot;
    if (agents != .array) return error.InvalidSnapshot;
    for (agents.array.items) |row| {
        if (row != .object) return error.InvalidSnapshot;
        const agent = row.object.get("value") orelse return error.InvalidSnapshot;
        if (agent != .object) return error.InvalidSnapshot;
        const reqs = agent.object.get("requests") orelse return error.InvalidSnapshot;
        if (reqs != .array) return error.InvalidSnapshot;
        for (reqs.array.items) |*r| {
            if (r.* != .object) return error.InvalidSnapshot;
            if (r.object.get("options") == null) try r.object.put(a, "options", .null);
        }
    }
}

fn write(comptime T: type, value: T, w: *std.json.Stringify) anyerror!void {
    if (T == Event) return value.write(w);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (@hasDecl(T, "keys") and @hasDecl(T, "values")) {
                try w.beginArray();
                for (value.keys(), value.values()) |k, v| {
                    try w.beginObject();
                    try w.objectField("key");
                    try w.write(k);
                    try w.objectField("value");
                    try write(@TypeOf(v), v, w);
                    try w.endObject();
                }
                return w.endArray();
            }
            if (@hasField(T, "items") and @hasField(T, "capacity")) return write(@TypeOf(value.items), value.items, w);
            try w.beginObject();
            inline for (info.field_names, info.field_types) |name, F| {
                if (comptime !(T == State and std.mem.eql(u8, name, "arena"))) {
                    try w.objectField(name);
                    try write(F, @field(value, name), w);
                }
            }
            try w.endObject();
        },
        .pointer => |p| {
            if (p.child == u8) return w.write(value);
            try w.beginArray();
            for (value) |v| try write(p.child, v, w);
            try w.endArray();
        },
        .optional => |o| if (value) |v| {
            try write(o.child, v, w);
        } else {
            try w.write(null);
        },
        else => try w.write(value),
    }
}

fn read(comptime T: type, a: std.mem.Allocator, value: std.json.Value) anyerror!T {
    if (T == Event) return Event.parse(a, value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (@hasDecl(T, "keys") and @hasDecl(T, "values")) {
                if (value != .array) return error.InvalidSnapshot;
                var result: T = .empty;
                const V = @typeInfo(@TypeOf(result.values())).pointer.child;
                for (value.array.items) |row| {
                    if (row != .object) return error.InvalidSnapshot;
                    const key = try read([]const u8, a, row.object.get("key") orelse return error.InvalidSnapshot);
                    if (result.contains(key)) return error.InvalidSnapshot;
                    try result.put(a, key, try read(V, a, row.object.get("value") orelse return error.InvalidSnapshot));
                }
                return result;
            }
            if (@hasField(T, "items") and @hasField(T, "capacity")) {
                const items = try read(@FieldType(T, "items"), a, value);
                var result: T = .empty;
                result.items = items;
                result.capacity = items.len;
                return result;
            }
            if (value != .object) return error.InvalidSnapshot;
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, F| @field(result, name) = try read(F, a, value.object.get(name) orelse return error.InvalidSnapshot);
            return result;
        },
        .pointer => |p| {
            if (p.child == u8) {
                if (value == .array) return bytesOf(a, value.array.items);
                if (value != .string) return error.InvalidSnapshot;
                return a.dupe(u8, value.string);
            }
            if (value != .array) return error.InvalidSnapshot;
            const items = try a.alloc(p.child, value.array.items.len);
            for (items, value.array.items) |*item, v| item.* = try read(p.child, a, v);
            return items;
        },
        .optional => |o| return if (value == .null) null else try read(o.child, a, value),
        else => return std.json.parseFromValueLeaky(T, a, value, .{}),
    }
}

/// std.json writes a string that is not UTF-8 as an array of its bytes.
fn bytesOf(a: std.mem.Allocator, items: []const std.json.Value) ![]u8 {
    const out = try a.alloc(u8, items.len);
    for (out, items) |*byte, item| {
        if (item != .integer or item.integer < 0 or item.integer > 255) return error.InvalidSnapshot;
        byte.* = @intCast(item.integer);
    }
    return out;
}

const testing = std.testing;
const decider = @import("decider.zig");

test "snapshot: a v1 snapshot with a pending request restores (options default to none)" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    _ = try decider.applyAt(&state, .{ .create = .{ .agent = "a1", .title = "a1", .harness = "fake", .workspace = "/w" } }, 0, s);
    _ = try decider.applyAt(&state, .{ .record = .{ .turn_started = .{ .agent = "a1", .turn = "t1", .origin = "user" } } }, 1, s);
    const labels: []const []const u8 = &.{ "x", "y" };
    const opts: []const @import("events.zig").QuestionOptions = &.{.{ .id = "q1", .question = "Q?", .labels = labels }};
    _ = try decider.applyAt(&state, .{ .record = .{ .request = .{ .agent = "a1", .request = "r1", .kind = "question", .reason = "Q?", .options = opts } } }, 2, s);
    const v2 = try encode(&state, testing.allocator);
    defer testing.allocator.free(v2);

    // Current format round-trips, options included.
    var back = State.init(testing.allocator);
    defer back.deinit();
    try restore(&back, v2, version);
    const got = back.agents.getPtr("a1").?.requests.items[0];
    try testing.expectEqualStrings("y", got.options.?[0].labels[1]);

    // The same snapshot as v1 wrote it: no `options` on the request.
    const v1 = try std.mem.replaceOwned(u8, testing.allocator, v2, ",\"options\":[{\"id\":\"q1\",\"question\":\"Q?\",\"labels\":[\"x\",\"y\"],\"free_text\":false,\"labels_omitted\":false}]", "");
    defer testing.allocator.free(v1);
    try testing.expect(v1.len < v2.len);
    var old = State.init(testing.allocator);
    defer old.deinit();
    try testing.expectError(error.InvalidSnapshot, restore(&old, v1, version));
    var migrated = State.init(testing.allocator);
    defer migrated.deinit();
    try restore(&migrated, v1, 1);
    const r = migrated.agents.getPtr("a1").?.requests.items[0];
    try testing.expectEqualStrings("r1", r.request);
    try testing.expect(r.options == null);
}
