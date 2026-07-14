const std = @import("std");

pub const PlaceholderStyle = enum {
    positional,
    indexed,
    named,
};

pub const Placeholder = struct {
    offset: usize,
    len: usize,
    style: PlaceholderStyle,
    index: ?usize = null,
    name: []const u8 = "",
};

/// A named value used by drivers that expose named bind APIs.
pub const NamedValue = struct {
    name: []const u8,
    value: @import("value.zig").Value,
};

/// Allocator-owned PostgreSQL rewrite result. Names borrow from the input SQL.
pub const PostgresRewrite = struct {
    sql: []u8,
    names: []const []const u8,

    pub fn deinit(self: *PostgresRewrite, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        allocator.free(self.names);
        self.* = undefined;
    }
};

/// Rewrite `:name`, `@name`, or `$name` placeholders to PostgreSQL `$n`.
/// Repeated names share an index; mixed positional/indexed styles are rejected.
pub fn rewriteNamedPostgres(allocator: std.mem.Allocator, sql: []const u8) !PostgresRewrite {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer names.deinit(allocator);

    var cursor: usize = 0;
    var iter = Iterator.init(sql);
    while (try iter.next()) |placeholder| {
        try out.appendSlice(allocator, sql[cursor..placeholder.offset]);
        cursor = placeholder.offset + placeholder.len;
        if (placeholder.style != .named) return error.InvalidSql;

        var index: ?usize = null;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, placeholder.name)) {
                index = i + 1;
                break;
            }
        }
        const bind_index = index orelse blk: {
            try names.append(allocator, placeholder.name);
            break :blk names.items.len;
        };
        var number_buf: [20]u8 = undefined;
        const number = try std.fmt.bufPrint(&number_buf, "${d}", .{bind_index});
        try out.appendSlice(allocator, number);
    }
    try out.appendSlice(allocator, sql[cursor..]);
    const owned_sql = try out.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sql);
    const owned_names = try names.toOwnedSlice(allocator);
    return .{ .sql = owned_sql, .names = owned_names };
}

pub const Summary = struct {
    total: usize = 0,
    positional: usize = 0,
    indexed: usize = 0,
    named: usize = 0,
    highest_index: usize = 0,
    bind_count_overflow: bool = false,

    pub fn observe(self: *Summary, placeholder: Placeholder) void {
        self.total += 1;
        switch (placeholder.style) {
            .positional => {
                self.positional += 1;
                // Anonymous parameters receive the next index after every
                // explicit index observed so far (SQLite's wire semantics).
                self.highest_index = std.math.add(usize, self.highest_index, 1) catch blk: {
                    self.bind_count_overflow = true;
                    break :blk std.math.maxInt(usize);
                };
            },
            .indexed => {
                self.indexed += 1;
                self.highest_index = @max(self.highest_index, placeholder.index.?);
            },
            .named => self.named += 1,
        }
    }

    pub fn expectedBindCount(self: Summary) usize {
        // Named parameters need name-aware de-duplication and are validated by
        // the caller; retain the historical occurrence count for summaries
        // containing names. For anonymous / indexed parameters, highest_index
        // is the actual number of bind slots, including gaps and repeats.
        if (self.named != 0) return @max(self.total, self.highest_index);
        return self.highest_index;
    }
};

pub fn summarize(sql: []const u8) !Summary {
    var iter = Iterator.init(sql);
    var summary: Summary = .{};
    while (try iter.next()) |placeholder| {
        summary.observe(placeholder);
        if (summary.bind_count_overflow) return error.InvalidSql;
    }
    return summary;
}

pub const Iterator = struct {
    sql: []const u8,
    index: usize = 0,

    pub fn init(sql: []const u8) Iterator {
        return .{ .sql = sql };
    }

    pub fn next(self: *Iterator) !?Placeholder {
        while (self.index < self.sql.len) {
            const start = self.index;
            const c = self.sql[self.index];

            switch (c) {
                '\'' => try self.skipQuoted('\'', self.isPostgresEscapeString(start)),
                '"' => try self.skipQuoted('"', false),
                '[' => try self.skipBracketedIdent(),
                '-' => {
                    if (self.peek(1) == '-') {
                        self.skipLineComment();
                    } else {
                        self.index += 1;
                    }
                },
                '/' => {
                    if (self.peek(1) == '*') {
                        try self.skipBlockComment();
                    } else {
                        self.index += 1;
                    }
                },
                '?' => return try self.parseQuestion(start),
                '$' => {
                    // PostgreSQL dollar-quoted string literals can legally
                    // contain text that looks like bind markers. Recognize
                    // them before considering `$1` indexed or `$name` named.
                    if (try self.skipDollarQuoted()) continue;
                    if (self.peek(1)) |next_byte| {
                        if (std.ascii.isDigit(next_byte)) return try self.parseDollarIndexed(start);
                    }
                    if (try self.parseNamed(start, c)) |placeholder| return placeholder;
                },
                ':', '@' => if (try self.parseNamed(start, c)) |placeholder| return placeholder,
                else => self.index += 1,
            }
        }
        return null;
    }

    fn parseQuestion(self: *Iterator, start: usize) !Placeholder {
        self.index += 1;

        const digits_start = self.index;
        while (self.index < self.sql.len and std.ascii.isDigit(self.sql[self.index])) {
            self.index += 1;
        }

        if (self.index == digits_start) {
            return .{
                .offset = start,
                .len = 1,
                .style = .positional,
            };
        }

        const text = self.sql[digits_start..self.index];
        const index = try std.fmt.parseInt(usize, text, 10);
        if (index == 0) return error.InvalidSql;

        return .{
            .offset = start,
            .len = self.index - start,
            .style = .indexed,
            .index = index,
        };
    }

    fn parseDollarIndexed(self: *Iterator, start: usize) !Placeholder {
        self.index += 1;
        const digits_start = self.index;
        while (self.index < self.sql.len and std.ascii.isDigit(self.sql[self.index])) {
            self.index += 1;
        }
        const index = try std.fmt.parseInt(usize, self.sql[digits_start..self.index], 10);
        if (index == 0) return error.InvalidSql;
        return .{
            .offset = start,
            .len = self.index - start,
            .style = .indexed,
            .index = index,
        };
    }

    fn parseNamed(self: *Iterator, start: usize, marker: u8) !?Placeholder {
        if (marker == ':' and self.peek(1) == ':') {
            self.index += 2;
            return null;
        }

        const name_start = start + 1;
        if (name_start >= self.sql.len or !isIdentStart(self.sql[name_start])) {
            self.index += 1;
            return null;
        }

        self.index = name_start + 1;
        while (self.index < self.sql.len and isIdentContinue(self.sql[self.index])) {
            self.index += 1;
        }

        return .{
            .offset = start,
            .len = self.index - start,
            .style = .named,
            .name = self.sql[name_start..self.index],
        };
    }

    fn isPostgresEscapeString(self: Iterator, quote_start: usize) bool {
        if (quote_start == 0) return false;
        const prefix = self.sql[quote_start - 1];
        if (prefix != 'E' and prefix != 'e') return false;
        return quote_start == 1 or !isIdentContinue(self.sql[quote_start - 2]);
    }

    fn skipQuoted(self: *Iterator, quote: u8, backslash_escapes: bool) !void {
        self.index += 1;
        while (self.index < self.sql.len) {
            if (backslash_escapes and self.sql[self.index] == '\\') {
                if (self.index + 1 >= self.sql.len) return error.InvalidSql;
                self.index += 2;
                continue;
            }
            if (self.sql[self.index] == quote) {
                self.index += 1;
                if (self.index < self.sql.len and self.sql[self.index] == quote) {
                    self.index += 1;
                    continue;
                }
                return;
            }
            self.index += 1;
        }
        return error.InvalidSql;
    }

    /// Skip a PostgreSQL dollar-quoted string (`$$...$$` or `$tag$...$tag$`).
    /// Returns false without consuming input when the current `$` is not a
    /// valid opening delimiter, so `$name` remains a named bind parameter.
    fn skipDollarQuoted(self: *Iterator) !bool {
        const start = self.index;
        std.debug.assert(self.sql[start] == '$');

        var tag_end = start + 1;
        if (tag_end < self.sql.len and self.sql[tag_end] != '$') {
            if (!isIdentStart(self.sql[tag_end])) return false;
            tag_end += 1;
            while (tag_end < self.sql.len and isIdentContinue(self.sql[tag_end])) {
                tag_end += 1;
            }
        }
        if (tag_end >= self.sql.len or self.sql[tag_end] != '$') return false;

        const delimiter = self.sql[start .. tag_end + 1];
        const content_start = tag_end + 1;
        const close_start = std.mem.indexOfPos(u8, self.sql, content_start, delimiter) orelse
            return error.InvalidSql;
        self.index = close_start + delimiter.len;
        return true;
    }

    fn skipBracketedIdent(self: *Iterator) !void {
        self.index += 1;
        while (self.index < self.sql.len) {
            if (self.sql[self.index] == ']') {
                self.index += 1;
                return;
            }
            self.index += 1;
        }
        return error.InvalidSql;
    }

    fn skipLineComment(self: *Iterator) void {
        self.index += 2;
        while (self.index < self.sql.len and self.sql[self.index] != '\n') {
            self.index += 1;
        }
    }

    fn skipBlockComment(self: *Iterator) !void {
        self.index += 2;
        var depth: usize = 1;
        while (self.index + 1 < self.sql.len) {
            if (self.sql[self.index] == '/' and self.sql[self.index + 1] == '*') {
                depth += 1;
                self.index += 2;
            } else if (self.sql[self.index] == '*' and self.sql[self.index + 1] == '/') {
                depth -= 1;
                self.index += 2;
                if (depth == 0) return;
            } else {
                self.index += 1;
            }
        }
        return error.InvalidSql;
    }

    fn peek(self: Iterator, offset: usize) ?u8 {
        const target = self.index + offset;
        if (target >= self.sql.len) return null;
        return self.sql[target];
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

test "summarize counts placeholders outside quotes and comments" {
    const summary = try summarize(
        \\select ?, ?2, :name, @other, $third,
        \\  '?', "?", [??]
        \\-- ? ignored
        \\/* :ignored */
    );

    try std.testing.expectEqual(@as(usize, 5), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.positional);
    try std.testing.expectEqual(@as(usize, 1), summary.indexed);
    try std.testing.expectEqual(@as(usize, 3), summary.named);
    try std.testing.expectEqual(@as(usize, 2), summary.highest_index);
}

test "iterator exposes placeholder slices" {
    var iter = Iterator.init("select :id, ?42, $name, $7");

    const first = (try iter.next()).?;
    try std.testing.expectEqual(@as(usize, 7), first.offset);
    try std.testing.expectEqual(PlaceholderStyle.named, first.style);
    try std.testing.expectEqualStrings("id", first.name);

    const second = (try iter.next()).?;
    try std.testing.expectEqual(PlaceholderStyle.indexed, second.style);
    try std.testing.expectEqual(@as(?usize, 42), second.index);

    const third = (try iter.next()).?;
    try std.testing.expectEqual(PlaceholderStyle.named, third.style);
    try std.testing.expectEqualStrings("name", third.name);

    const fourth = (try iter.next()).?;
    try std.testing.expectEqual(PlaceholderStyle.indexed, fourth.style);
    try std.testing.expectEqual(@as(?usize, 7), fourth.index);

    try std.testing.expectEqual(@as(?Placeholder, null), try iter.next());
}

test "summary models repeated and mixed indexed bind slots" {
    const sqlite = try summarize("select ?3, ?, ?3");
    try std.testing.expectEqual(@as(usize, 3), sqlite.total);
    try std.testing.expectEqual(@as(usize, 1), sqlite.positional);
    try std.testing.expectEqual(@as(usize, 2), sqlite.indexed);
    try std.testing.expectEqual(@as(usize, 4), sqlite.expectedBindCount());

    const postgres = try summarize("select $1, $1, $3");
    try std.testing.expectEqual(@as(usize, 3), postgres.total);
    try std.testing.expectEqual(@as(usize, 3), postgres.indexed);
    try std.testing.expectEqual(@as(usize, 3), postgres.expectedBindCount());

    var sql_buf: [64]u8 = undefined;
    const overflow_sql = try std.fmt.bufPrint(&sql_buf, "select ?{d}, ?", .{std.math.maxInt(usize)});
    try std.testing.expectError(error.InvalidSql, summarize(overflow_sql));
}

test "parser rejects invalid terminated sql fragments" {
    try std.testing.expectError(error.InvalidSql, summarize("select 'unterminated"));
    try std.testing.expectError(error.InvalidSql, summarize("select /* missing close"));
    try std.testing.expectError(error.InvalidSql, summarize("select ?0"));
    try std.testing.expectError(error.InvalidSql, summarize("select $0"));
}

test "postgres casts are not named parameters" {
    const summary = try summarize("select $id, value::text from t where id = :id");
    try std.testing.expectEqual(@as(usize, 2), summary.total);
    try std.testing.expectEqual(@as(usize, 2), summary.named);
}

test "postgres dollar-quoted strings do not expose false bind markers" {
    const summary = try summarize(
        "select $$ :ignored, $also_ignored, ? $$, $tag$ @ignored $tag$, $actual",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.named);

    try std.testing.expectError(error.InvalidSql, summarize("select $tag$ unterminated"));
}

test "postgres escape strings do not expose false bind markers" {
    const summary = try summarize("select E'it\\'s :ignored', :actual");
    try std.testing.expectEqual(@as(usize, 1), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.named);
}

test "nested block comments do not expose false bind markers" {
    const summary = try summarize("select /* outer :ignored /* inner ? */ $also_ignored */ @actual");
    try std.testing.expectEqual(@as(usize, 1), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.named);

    try std.testing.expectError(error.InvalidSql, summarize("select /* outer /* inner */"));
}

test "rewriteNamedPostgres preserves lexical SQL and reuses names" {
    var rewrite = try rewriteNamedPostgres(std.testing.allocator, "select :id, :id, '@nope', $tag$ :also_nope $tag$ from t where n = @name");
    defer rewrite.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("select $1, $1, '@nope', $tag$ :also_nope $tag$ from t where n = $2", rewrite.sql);
    try std.testing.expectEqual(@as(usize, 2), rewrite.names.len);
    try std.testing.expectEqualStrings("id", rewrite.names[0]);
    try std.testing.expectEqualStrings("name", rewrite.names[1]);
    try std.testing.expectError(error.InvalidSql, rewriteNamedPostgres(std.testing.allocator, "select :id, ?"));
}

fn exerciseRewriteNamedPostgresAllocationFailures(allocator: std.mem.Allocator) !void {
    var rewrite = try rewriteNamedPostgres(
        allocator,
        "select :account_id, :account_id, @tenant_id, $region from accounts where owner_id = :owner_id",
    );
    defer rewrite.deinit(allocator);

    try std.testing.expectEqualStrings(
        "select $1, $1, $2, $3 from accounts where owner_id = $4",
        rewrite.sql,
    );
    try std.testing.expectEqual(@as(usize, 4), rewrite.names.len);
}

test "rewriteNamedPostgres cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRewriteNamedPostgresAllocationFailures,
        .{},
    );

    // ArrayList can normally shrink in place, so force both ownership
    // transfers down their allocate-and-copy path and fail each allocation in
    // turn. The final failure occurs after SQL ownership has transferred but
    // before the names slice can transfer.
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .resize_fail_index = 0,
    });
    try exerciseRewriteNamedPostgresAllocationFailures(baseline.allocator());
    try std.testing.expect(baseline.alloc_index >= 2);

    for (0..baseline.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        try std.testing.expectError(
            error.OutOfMemory,
            exerciseRewriteNamedPostgresAllocationFailures(failing.allocator()),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
