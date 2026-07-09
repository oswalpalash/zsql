const std = @import("std");

/// Simple SQL → prepared-name cache for connection-local statement reuse.
///
/// Ownership:
/// - Cache owns duplicated SQL keys and statement names.
/// - Callers pass borrowed SQL to `get` / `put`; names returned by `get` are
///   borrowed from the cache and valid until the entry is evicted or `deinit`.
///
/// Eviction is LRU by last-hit order (move-to-end on hit/put). This is not a
/// concurrent structure; protect with an external mutex if shared across threads.
pub const StmtCache = struct {
    allocator: std.mem.Allocator,
    max_entries: usize,
    /// Oldest at index 0, newest at end.
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        sql: []u8,
        name: []u8,
        hits: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) !StmtCache {
        if (max_entries == 0) return error.InvalidArguments;
        return .{
            .allocator = allocator,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *StmtCache) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.sql);
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Look up a cached prepared name for `sql`. On hit, bumps LRU and hit count.
    pub fn get(self: *StmtCache, sql: []const u8) ?[]const u8 {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.sql, sql)) {
                self.entries.items[i].hits += 1;
                if (i + 1 != self.entries.items.len) {
                    const moved = self.entries.orderedRemove(i);
                    self.entries.append(self.allocator, moved) catch {
                        // Restore on OOM so the entry is not lost.
                        self.entries.insert(self.allocator, i, moved) catch {};
                        return moved.name;
                    };
                    return self.entries.items[self.entries.items.len - 1].name;
                }
                return entry.name;
            }
        }
        return null;
    }

    /// Insert or refresh a mapping. Evicts the least-recently-used entry when full.
    pub fn put(self: *StmtCache, sql: []const u8, name: []const u8) !void {
        // Refresh existing.
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.sql, sql)) {
                if (!std.mem.eql(u8, entry.name, name)) {
                    const new_name = try self.allocator.dupe(u8, name);
                    self.allocator.free(entry.name);
                    self.entries.items[i].name = new_name;
                }
                self.entries.items[i].hits += 1;
                if (i + 1 != self.entries.items.len) {
                    const moved = self.entries.orderedRemove(i);
                    try self.entries.append(self.allocator, moved);
                }
                return;
            }
        }

        while (self.entries.items.len >= self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.sql);
            self.allocator.free(old.name);
        }

        const owned_sql = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(owned_sql);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.entries.append(self.allocator, .{
            .sql = owned_sql,
            .name = owned_name,
            .hits = 1,
        });
    }

    pub fn len(self: *const StmtCache) usize {
        return self.entries.items.len;
    }

    pub fn contains(self: *const StmtCache, sql: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.sql, sql)) return true;
        }
        return false;
    }
};

/// Generate a stable, ASCII-safe prepared statement name from a counter.
pub fn formatStmtName(buf: []u8, id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "zsql_ps_{d}", .{id});
}

test "StmtCache get miss and put hit" {
    var cache = try StmtCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    try std.testing.expect(cache.get("select 1") == null);
    try cache.put("select 1", "zsql_ps_0");
    try std.testing.expectEqualStrings("zsql_ps_0", cache.get("select 1").?);
    try std.testing.expectEqual(@as(usize, 1), cache.len());
}

test "StmtCache LRU eviction" {
    var cache = try StmtCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    try cache.put("a", "n0");
    try cache.put("b", "n1");
    // Touch a so b becomes older? put order: a then b → a oldest, b newest.
    // Hit a → a becomes newest, b oldest.
    _ = cache.get("a");
    try cache.put("c", "n2"); // evicts b
    try std.testing.expect(cache.contains("a"));
    try std.testing.expect(cache.contains("c"));
    try std.testing.expect(!cache.contains("b"));
    try std.testing.expectEqual(@as(usize, 2), cache.len());
}

test "StmtCache put refresh updates name" {
    var cache = try StmtCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    try cache.put("q", "old");
    try cache.put("q", "new");
    try std.testing.expectEqualStrings("new", cache.get("q").?);
    try std.testing.expectEqual(@as(usize, 1), cache.len());
}

test "StmtCache rejects zero capacity" {
    try std.testing.expectError(error.InvalidArguments, StmtCache.init(std.testing.allocator, 0));
}

test "formatStmtName is deterministic" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("zsql_ps_7", try formatStmtName(&buf, 7));
}
