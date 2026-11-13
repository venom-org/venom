//! The durable, append-only event log file.
//!
//! Format: one NDJSON line per **commit**, all events a command decided:
//!
//!     {"commit":3,"ts":"2026-11-07T12:00:00.000Z","events":[{"type":"request.resolved","data":{…}},{"type":"effect.requested","data":{…}}]}
//!
//! A commit is one `write(2)` to a file opened with `O_APPEND`, so a commit
//! (domain events plus their outbox effects) is on disk entirely or not at
//! all. Commit numbers start at 1 and are contiguous.
//!
//! **fsync policy:** every commit is `fsync(2)`ed before `commit` returns,
//! i.e. before the state changes in memory, before the events are
//! published on `venom events`, before a verb reports success and before
//! any effect of that commit runs. Creating the file also syncs its
//! directory. There is no batching window: an acknowledged change is
//! durable, at the cost of one fsync per command.
//!
//! **Recovery:** restore a versioned, checksummed `.snapshot` when present,
//! then read the log, skipping commits covered by that snapshot. A `.tmp`
//! snapshot is never authoritative. Unsupported/corrupt snapshots fail closed.
//! Compaction publishes and directory-syncs the snapshot before truncating
//! the locked log inode; a crash may leave a covered prefix, safely skipped.
//! Without a snapshot the file is read from the start. A last line that
//! is incomplete (no trailing newline) or unparsable is a torn write from a
//! crash before its fsync returned, so nothing depended on it: it is cut
//! off with `ftruncate(2)`. Any other bad line, a gap in commit numbers or
//! an unknown record type fails with `error.CorruptLog`; venom then refuses
//! to start rather than rebuild a wrong state. The file is held with an
//! exclusive `flock(2)`: a second daemon on the same state directory fails
//! with `error.LogLocked`.
const std = @import("std");
const c = std.c;
const log = @import("log");
const ev = @import("events.zig");
const Event = ev.Event;

pub const Store = struct {
    gpa: std.mem.Allocator,
    path: [:0]u8,
    snapshot_commit: u64 = 0,
    /// Fault-injection hook, compiled out of production.
    test_hook: ?*const fn (u8) void = null,
    replay_ms: u64 = 0,
    fd: c.fd_t,
    /// The last commit number on disk; 0 for an empty log.
    commits: u64 = 0,
    /// File size after the last good commit.
    size: u64 = 0,
    /// Bytes cut from a torn tail on open (0 when the log was clean).
    truncated: u64 = 0,

    /// Opens (creating it if needed) the log at `path` and feeds every
    /// committed event, oldest first, to `sink.replay(event)`. Event strings
    /// are only valid during the call.
    pub fn open(gpa: std.mem.Allocator, path: []const u8, sink: anytype) !Store {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
        const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
        try log.makeDirs(gpa, dir);
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        var created = false;
        var fd = c.open(z, .{ .ACCMODE = .RDWR, .APPEND = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd < 0) {
            fd = c.open(z, .{ .ACCMODE = .RDWR, .APPEND = true, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
            if (fd < 0) return error.OpenFailed;
            created = true;
        }
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK.EX | c.LOCK.NB) != 0) return error.LogLocked;
        if (created) try syncDir(gpa, dir);
        var self: Store = .{ .gpa = gpa, .fd = fd, .path = try gpa.dupeSentinel(u8, path, 0) };
        errdefer gpa.free(self.path);
        const began = milliseconds();
        try self.loadSnapshot(sink);
        try self.replay(sink);
        self.replay_ms = milliseconds() -| began;
        return self;
    }

    pub fn close(self: *Store) void {
        _ = c.close(self.fd);
        self.fd = -1;
        self.gpa.free(self.path);
    }

    fn replay(self: *Store, sink: anytype) !void {
        const bytes = try readAll(self.gpa, self.fd);
        defer self.gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var offset: usize = 0;
        var previous: ?u64 = null;
        while (offset < bytes.len) {
            _ = arena.reset(.retain_capacity);
            const nl = std.mem.indexOfScalarPos(u8, bytes, offset, '\n');
            const end = nl orelse bytes.len;
            const line = bytes[offset..end];
            const last = nl == null or end + 1 == bytes.len;
            const number = lineNumber(arena.allocator(), line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            const want = if (previous) |p| p + 1 else if (number != null and number.? <= self.snapshot_commit) number.? else self.commits + 1;
            const events = parseLine(arena.allocator(), line, want) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (!last or err == error.UnknownRecord or err == error.CommitGap) return error.CorruptLog;
                break; // torn tail
            };
            if (nl == null) break; // complete JSON without its newline: never fsynced as a commit
            previous = want;
            if (want > self.snapshot_commit) {
                if (want != self.commits + 1) return error.CorruptLog;
                for (events) |e| try sink.replay(e);
                self.commits = want;
            }
            offset = end + 1;
        }
        self.size = offset;
        if (offset < bytes.len) {
            self.truncated = bytes.len - offset;
            if (c.ftruncate(self.fd, @intCast(offset)) != 0) return error.TruncateFailed;
            if (c.fsync(self.fd) != 0) return error.SyncFailed;
        }
    }

    fn loadSnapshot(self: *Store, sink: anytype) !void {
        const path = try std.fmt.allocPrintSentinel(self.gpa, "{s}.snapshot", .{self.path}, 0);
        defer self.gpa.free(path);
        const fd = c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd < 0) {
            if (c.errno(fd) == .NOENT) return;
            return error.OpenFailed;
        }
        defer _ = c.close(fd);
        const bytes = try readAll(self.gpa, fd);
        defer self.gpa.free(bytes);
        const parsed = std.json.parseFromSlice(struct { version: u32, commit: u64, state: []const u8, sha256: [64]u8 }, self.gpa, bytes, .{}) catch return error.CorruptSnapshot;
        defer parsed.deinit();
        const v = parsed.value;
        if (v.version != 1 and v.version != 2) return error.UnsupportedSnapshot;
        var digest: [32]u8 = undefined;
        snapshotHash(v.commit, v.state, &digest);
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), &v.sha256)) return error.CorruptSnapshot;
        try sink.restore(v.state, v.version);
        self.snapshot_commit = v.commit;
        self.commits = v.commit;
    }

    /// Runs on the reactor with no concurrent commits. The log inode stays
    /// locked throughout. Until snapshot rename + directory fsync, the old
    /// log is authoritative; afterwards it is safe to truncate its prefix.
    pub fn compact(self: *Store, state: []const u8) !void {
        const tmp = try std.fmt.allocPrintSentinel(self.gpa, "{s}.snapshot.tmp", .{self.path}, 0);
        defer self.gpa.free(tmp);
        const path = try std.fmt.allocPrintSentinel(self.gpa, "{s}.snapshot", .{self.path}, 0);
        defer self.gpa.free(path);
        var digest: [32]u8 = undefined;
        snapshotHash(self.commits, state, &digest);
        const bytes = try std.json.Stringify.valueAlloc(self.gpa, .{ .version = @as(u32, 2), .commit = self.commits, .state = state, .sha256 = std.fmt.bytesToHex(digest, .lower) }, .{});
        defer self.gpa.free(bytes);
        const fd = c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var done: usize = 0;
        while (done < bytes.len) {
            const n = c.write(fd, bytes[done..].ptr, @min(bytes.len - done, 64 * 1024));
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.WriteFailed;
            done += @intCast(n);
            if (@import("builtin").is_test) if (self.test_hook) |hook| hook(0);
        }
        if (c.fsync(fd) != 0) return error.SyncFailed;
        if (c.rename(tmp, path) != 0) return error.RenameFailed;
        try syncDir(self.gpa, std.fs.path.dirname(self.path).?);
        if (@import("builtin").is_test) if (self.test_hook) |hook| hook(1);
        self.snapshot_commit = self.commits;
        if (c.ftruncate(self.fd, 0) != 0) return error.TruncateFailed;
        self.size = 0;
        if (@import("builtin").is_test) if (self.test_hook) |hook| hook(2);
        if (c.fsync(self.fd) != 0) return error.SyncFailed;
    }

    /// Durably appends one commit holding `events` (at least one) and
    /// returns its number. On failure the file is cut back to the previous
    /// commit and nothing is committed.
    pub fn commit(self: *Store, events: []const Event, ts: []const u8) !u64 {
        std.debug.assert(events.len > 0);
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
        try w.beginObject();
        try w.objectField("commit");
        try w.write(self.commits + 1);
        try w.objectField("ts");
        try w.write(ts);
        try w.objectField("events");
        try w.beginArray();
        for (events) |e| try e.write(&w);
        try w.endArray();
        try w.endObject();
        try out.writer.writeByte('\n');
        const line = out.written();
        errdefer {
            _ = c.ftruncate(self.fd, @intCast(self.size));
            _ = c.fsync(self.fd);
        }
        var done: usize = 0;
        while (done < line.len) {
            const n = c.write(self.fd, line[done..].ptr, line.len - done);
            if (n < 0) {
                if (c.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            done += @intCast(n);
        }
        if (c.fsync(self.fd) != 0) return error.SyncFailed;
        self.size += line.len;
        self.commits += 1;
        return self.commits;
    }
};

fn parseLine(a: std.mem.Allocator, line: []const u8, want: u64) ![]Event {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidRecord;
    };
    if (value != .object) return error.InvalidRecord;
    const number = value.object.get("commit") orelse return error.InvalidRecord;
    const list = value.object.get("events") orelse return error.InvalidRecord;
    if (number != .integer or list != .array or list.array.items.len == 0) return error.InvalidRecord;
    if (number.integer != want) return error.CommitGap;
    const events = try a.alloc(Event, list.array.items.len);
    for (list.array.items, events) |item, *e| e.* = try Event.parse(a, item);
    return events;
}

fn readAll(gpa: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.ReadFailed;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    while (true) {
        try list.ensureUnusedCapacity(gpa, 64 * 1024);
        const spare = list.unusedCapacitySlice();
        const n = c.read(fd, spare.ptr, spare.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        list.items.len += @intCast(n);
    }
    return list.toOwnedSlice(gpa);
}

fn syncDir(gpa: std.mem.Allocator, dir: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(z);
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.fsync(fd) != 0) return error.SyncFailed;
}

fn lineNumber(a: std.mem.Allocator, line: []const u8) !u64 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    if (v != .object) return error.InvalidRecord;
    const n = v.object.get("commit") orelse return error.InvalidRecord;
    if (n != .integer or n.integer < 1) return error.InvalidRecord;
    return @intCast(n.integer);
}
fn milliseconds() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn snapshotHash(commit: u64, state: []const u8, out: *[32]u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, commit, .little);
    hash.update("venom.snapshot.v1");
    hash.update(&number);
    hash.update(state);
    hash.final(out);
}
