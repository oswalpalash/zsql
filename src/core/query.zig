const std = @import("std");
const Value = @import("value.zig").Value;

/// Safe dynamic SQL builder for identifiers and bound values.
///
/// - `appendTrustedSql` / `rawUnsafe` append SQL text as-is (caller is responsible).
/// - `ident` / `identPath` quote identifiers so values cannot inject SQL.
/// - `bind` records a parameter and appends a dialect placeholder; values are
///   never concatenated into the SQL string.
pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    sql: std.ArrayListUnmanaged(u8) = .empty,
    binds: std.ArrayListUnmanaged(Value) = .empty,
    /// Owned copies of bound text/blob payloads.
    owned: std.ArrayListUnmanaged([]u8) = .empty,
    /// Placeholder dialect for positional parameters.
    dialect: Dialect = .postgres,
    next_index: usize = 1,

    pub const Dialect = enum {
        /// `$1`, `$2`, ...
        postgres,
        /// `?` for each bind
        sqlite,
    };

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect) QueryBuilder {
        return .{
            .allocator = allocator,
            .dialect = dialect,
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        self.sql.deinit(self.allocator);
        self.binds.deinit(self.allocator);
        for (self.owned.items) |buf| self.allocator.free(buf);
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendTrustedSql(self: *QueryBuilder, sql: []const u8) !void {
        try self.sql.appendSlice(self.allocator, sql);
    }

    /// Visibly unsafe: appends raw SQL without validation. Prefer
    /// `appendTrustedSql` for fixed fragments and `ident`/`bind` for inputs.
    pub fn rawUnsafe(self: *QueryBuilder, sql: []const u8) !void {
        try self.appendTrustedSql(sql);
    }

    pub fn ident(self: *QueryBuilder, name: []const u8) !void {
        try quoteIdent(&self.sql, self.allocator, name);
    }

    /// Quote a dotted path such as `schema.table.column`.
    pub fn identPath(self: *QueryBuilder, path: []const u8) !void {
        var first = true;
        var iter = std.mem.splitScalar(u8, path, '.');
        while (iter.next()) |part| {
            if (part.len == 0) return error.InvalidArguments;
            if (!first) try self.sql.append(self.allocator, '.');
            first = false;
            try quoteIdent(&self.sql, self.allocator, part);
        }
    }

    pub fn bind(self: *QueryBuilder, value: Value) !void {
        const stored = try self.storeValue(value);
        try self.binds.append(self.allocator, stored);
        switch (self.dialect) {
            .postgres => {
                var buf: [32]u8 = undefined;
                const placeholder = try std.fmt.bufPrint(&buf, "${d}", .{self.next_index});
                self.next_index += 1;
                try self.sql.appendSlice(self.allocator, placeholder);
            },
            .sqlite => {
                try self.sql.append(self.allocator, '?');
            },
        }
    }

    pub fn sqlSlice(self: *const QueryBuilder) []const u8 {
        return self.sql.items;
    }

    pub fn bindsSlice(self: *const QueryBuilder) []const Value {
        return self.binds.items;
    }

    fn storeValue(self: *QueryBuilder, value: Value) !Value {
        return switch (value) {
            .null => .{ .null = {} },
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .boolean => |v| .{ .boolean = v },
            .text => |t| blk: {
                const owned = try self.allocator.dupe(u8, t);
                try self.owned.append(self.allocator, owned);
                break :blk .{ .text = owned };
            },
            .blob => |b| blk: {
                const owned = try self.allocator.dupe(u8, b);
                try self.owned.append(self.allocator, owned);
                break :blk .{ .blob = owned };
            },
        };
    }
};

fn quoteIdent(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    if (name.len == 0) return error.InvalidArguments;
    try list.append(allocator, '"');
    for (name) |c| {
        if (c == '"') {
            try list.appendSlice(allocator, "\"\"");
        } else {
            try list.append(allocator, c);
        }
    }
    try list.append(allocator, '"');
}

test "QueryBuilder quotes identifiers and never inlines binds" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    defer qb.deinit();

    try qb.appendTrustedSql("select ");
    try qb.ident("email");
    try qb.appendTrustedSql(" from ");
    try qb.identPath("public.users");
    try qb.appendTrustedSql(" where ");
    try qb.ident("id");
    try qb.appendTrustedSql(" = ");
    try qb.bind(.{ .integer = 7 });
    try qb.appendTrustedSql(" and ");
    try qb.ident("name");
    try qb.appendTrustedSql(" = ");
    try qb.bind(.{ .text = "ada\"; drop table users;--" });

    try std.testing.expectEqualStrings(
        \\select "email" from "public"."users" where "id" = $1 and "name" = $2
    ,
        qb.sqlSlice(),
    );
    try std.testing.expectEqual(@as(usize, 2), qb.bindsSlice().len);
    try std.testing.expectEqual(@as(i64, 7), qb.bindsSlice()[0].integer);
    try std.testing.expectEqualStrings("ada\"; drop table users;--", qb.bindsSlice()[1].text);
    // Bound text must not appear in the SQL string.
    try std.testing.expect(std.mem.indexOf(u8, qb.sqlSlice(), "drop table") == null);
}

test "QueryBuilder escapes embedded quotes in identifiers" {
    var qb = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer qb.deinit();
    try qb.ident("weird\"name");
    try qb.appendTrustedSql(" = ");
    try qb.bind(.{ .boolean = true });
    try std.testing.expectEqualStrings("\"weird\"\"name\" = ?", qb.sqlSlice());
}

test "rawUnsafe is explicit and appends as-is" {
    var qb = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer qb.deinit();
    try qb.rawUnsafe("/* trusted fragment */ ");
    try qb.appendTrustedSql("select 1");
    try std.testing.expectEqualStrings("/* trusted fragment */ select 1", qb.sqlSlice());
}
