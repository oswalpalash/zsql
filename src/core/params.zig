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

pub const Summary = struct {
    total: usize = 0,
    positional: usize = 0,
    indexed: usize = 0,
    named: usize = 0,
    highest_index: usize = 0,

    pub fn observe(self: *Summary, placeholder: Placeholder) void {
        self.total += 1;
        switch (placeholder.style) {
            .positional => self.positional += 1,
            .indexed => {
                self.indexed += 1;
                self.highest_index = @max(self.highest_index, placeholder.index.?);
            },
            .named => self.named += 1,
        }
    }
};

pub fn summarize(sql: []const u8) !Summary {
    var iter = Iterator.init(sql);
    var summary: Summary = .{};
    while (try iter.next()) |placeholder| {
        summary.observe(placeholder);
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
                '\'' => try self.skipQuoted('\''),
                '"' => try self.skipQuoted('"'),
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
                ':', '@', '$' => if (try self.parseNamed(start, c)) |placeholder| return placeholder,
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

    fn skipQuoted(self: *Iterator, quote: u8) !void {
        self.index += 1;
        while (self.index < self.sql.len) {
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
        while (self.index + 1 < self.sql.len) {
            if (self.sql[self.index] == '*' and self.sql[self.index + 1] == '/') {
                self.index += 2;
                return;
            }
            self.index += 1;
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
    var iter = Iterator.init("select :id, ?42, $name");

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

    try std.testing.expectEqual(@as(?Placeholder, null), try iter.next());
}

test "parser rejects invalid terminated sql fragments" {
    try std.testing.expectError(error.InvalidSql, summarize("select 'unterminated"));
    try std.testing.expectError(error.InvalidSql, summarize("select /* missing close"));
    try std.testing.expectError(error.InvalidSql, summarize("select ?0"));
}

test "postgres casts are not named parameters" {
    const summary = try summarize("select $id, value::text from t where id = :id");
    try std.testing.expectEqual(@as(usize, 2), summary.total);
    try std.testing.expectEqual(@as(usize, 2), summary.named);
}
