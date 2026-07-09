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

    /// Quote each path segment separately: `identSegments(&.{ "public", "users" })`
    /// → `"public"."users"`. Prefer this when segments are already split.
    pub fn identSegments(self: *QueryBuilder, segments: []const []const u8) !void {
        if (segments.len == 0) return error.InvalidArguments;
        for (segments, 0..) |part, i| {
            if (part.len == 0) return error.InvalidArguments;
            if (i != 0) try self.sql.append(self.allocator, '.');
            try quoteIdent(&self.sql, self.allocator, part);
        }
    }

    /// Bind a parameter. Accepts `Value` or common Zig scalars (`bool`, integers,
    /// floats, `[]const u8` text, optionals, and `null`). Values are never
    /// concatenated into the SQL string.
    pub fn bind(self: *QueryBuilder, value: anytype) !void {
        const coerced = try coerceValue(value);
        const stored = try self.storeValue(coerced);
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

/// Convert a common Zig value into a `Value` for binding.
///
/// Accepts:
/// - `Value` and anonymous Value literals (`.{ .integer = 7 }`)
/// - `null` / optionals
/// - `bool`, integers, floats
/// - `[]const u8` / string arrays as text
pub fn coerceValue(value: anytype) !Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (T == @TypeOf(null)) return .{ .null = {} };

    const info = @typeInfo(T);
    return switch (info) {
        .null => .{ .null = {} },
        .optional => {
            if (value) |inner| return coerceValue(inner);
            return .{ .null = {} };
        },
        .bool => .{ .boolean = value },
        .int, .comptime_int => .{
            .integer = std.math.cast(i64, value) orelse return error.IntegerOverflow,
        },
        .float, .comptime_float => .{ .real = @floatCast(value) },
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                return .{ .text = value };
            }
            if (pointer.size == .one) {
                return coerceValue(value.*);
            }
            @compileError("QueryBuilder.bind does not support " ++ @typeName(T));
        },
        .array => |array| {
            if (array.child == u8) {
                return .{ .text = value[0..] };
            }
            @compileError("QueryBuilder.bind does not support " ++ @typeName(T));
        },
        .@"struct" => blk: {
            // Anonymous Value-like literals: .{ .integer = 7 }, .{ .null = {} }, ...
            if (comptime isValueLiteralStruct(T)) {
                break :blk valueLiteralToValue(value);
            }
            @compileError("QueryBuilder.bind does not support " ++ @typeName(T) ++ "; use zsql.Value for blobs/custom");
        },
        .@"union" => {
            if (T == Value) return value;
            @compileError("QueryBuilder.bind does not support " ++ @typeName(T));
        },
        else => @compileError("QueryBuilder.bind does not support " ++ @typeName(T) ++ "; use zsql.Value for blobs/custom"),
    };
}

fn isValueLiteralStruct(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (info.@"struct".fields.len != 1) return false;
    const name = info.@"struct".fields[0].name;
    inline for (.{ "null", "integer", "real", "text", "blob", "boolean" }) |tag| {
        if (std.mem.eql(u8, name, tag)) return true;
    }
    return false;
}

fn valueLiteralToValue(value: anytype) Value {
    const T = @TypeOf(value);
    const name = @typeInfo(T).@"struct".fields[0].name;
    if (comptime std.mem.eql(u8, name, "null")) return .{ .null = {} };
    if (comptime std.mem.eql(u8, name, "integer")) return .{ .integer = @field(value, "integer") };
    if (comptime std.mem.eql(u8, name, "real")) return .{ .real = @field(value, "real") };
    if (comptime std.mem.eql(u8, name, "text")) return .{ .text = @field(value, "text") };
    if (comptime std.mem.eql(u8, name, "blob")) return .{ .blob = @field(value, "blob") };
    if (comptime std.mem.eql(u8, name, "boolean")) return .{ .boolean = @field(value, "boolean") };
    unreachable;
}

fn quoteIdent(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    if (name.len == 0) return error.InvalidArguments;
    // Identifiers must not embed NUL; drivers and protocol frames treat NUL as terminator.
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidArguments;
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

test "QueryBuilder.identSegments quotes each segment" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    defer qb.deinit();
    try qb.identSegments(&.{ "public", "users", "email" });
    try std.testing.expectEqualStrings("\"public\".\"users\".\"email\"", qb.sqlSlice());
    try std.testing.expectError(error.InvalidArguments, qb.identSegments(&.{}));
    try std.testing.expectError(error.InvalidArguments, qb.identSegments(&.{ "ok", "" }));
}

test "QueryBuilder.ident rejects embedded NUL" {
    var qb = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer qb.deinit();
    try std.testing.expectError(error.InvalidArguments, qb.ident("bad\x00name"));
    try std.testing.expectError(error.InvalidArguments, qb.identPath("ok.bad\x00x"));
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

test "QueryBuilder.bind coerces Zig scalars and optionals" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    defer qb.deinit();

    try qb.appendTrustedSql("values (");
    try qb.bind(@as(i32, 42));
    try qb.appendTrustedSql(", ");
    try qb.bind(true);
    try qb.appendTrustedSql(", ");
    try qb.bind(@as([]const u8, "hello"));
    try qb.appendTrustedSql(", ");
    try qb.bind(@as(?i64, null));
    try qb.appendTrustedSql(", ");
    try qb.bind(@as(f64, 1.5));
    try qb.appendTrustedSql(", ");
    try qb.bind(Value{ .blob = "\x00\x01" });
    try qb.appendTrustedSql(")");

    try std.testing.expectEqualStrings("values ($1, $2, $3, $4, $5, $6)", qb.sqlSlice());
    try std.testing.expectEqual(@as(i64, 42), qb.bindsSlice()[0].integer);
    try std.testing.expect(qb.bindsSlice()[1].boolean);
    try std.testing.expectEqualStrings("hello", qb.bindsSlice()[2].text);
    try std.testing.expect(qb.bindsSlice()[3].isNull());
    try std.testing.expectEqual(@as(f64, 1.5), qb.bindsSlice()[4].real);
    try std.testing.expectEqualStrings("\x00\x01", qb.bindsSlice()[5].blob);
    try std.testing.expect(std.mem.indexOf(u8, qb.sqlSlice(), "hello") == null);
}

test "coerceValue rejects integer overflow into i64" {
    // u64 max does not fit i64.
    try std.testing.expectError(error.IntegerOverflow, coerceValue(@as(u64, std.math.maxInt(u64))));
}
