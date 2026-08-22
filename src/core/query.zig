const std = @import("std");
const Value = @import("value.zig").Value;
const params = @import("params.zig");
const types = @import("types.zig");

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

    /// Clear SQL, binds, and owned payloads so the builder can build another
    /// statement. Allocator and dialect remain configured; backing storage may
    /// be retained to make repeated dynamic queries allocation-friendly.
    pub fn reset(self: *QueryBuilder) void {
        self.sql.clearRetainingCapacity();
        self.binds.clearRetainingCapacity();
        for (self.owned.items) |buf| self.allocator.free(buf);
        self.owned.clearRetainingCapacity();
        self.next_index = 1;
    }

    /// Deep-copy SQL and bind state into an independent builder. Borrowed
    /// text/blob payloads are duplicated immediately, so either builder can be
    /// mutated or reset without affecting the other.
    pub fn clone(
        self: *const QueryBuilder,
        allocator: std.mem.Allocator,
    ) !QueryBuilder {
        var cloned = QueryBuilder.init(allocator, self.dialect);
        errdefer cloned.deinit();

        try cloned.sql.appendSlice(allocator, self.sql.items);
        try cloned.binds.ensureTotalCapacityPrecise(allocator, self.binds.items.len);
        for (self.binds.items) |value| {
            const stored = try cloned.storeValue(value);
            cloned.binds.appendAssumeCapacity(stored);
        }
        cloned.next_index = self.next_index;
        return cloned;
    }

    /// Append another builder's SQL and binds, renumbering PostgreSQL
    /// placeholders into this builder's sequence. The other builder is not
    /// modified; owned text/blob payloads are copied through the normal atomic
    /// ownership path.
    pub fn appendBuilder(self: *QueryBuilder, other: *const QueryBuilder) !void {
        if (self.dialect != other.dialect) return error.InvalidArguments;

        const sql_len = self.sql.items.len;
        const binds_len = self.binds.items.len;
        const owned_len = self.owned.items.len;
        const next_index = self.next_index;
        errdefer self.rollbackBind(sql_len, binds_len, owned_len, next_index);

        var composed_sql: std.ArrayListUnmanaged(u8) = .empty;
        defer composed_sql.deinit(self.allocator);
        var cursor: usize = 0;

        if (self.dialect == .postgres) {
            const shift = next_index - 1;
            var iter = params.Iterator.init(other.sql.items);
            while (try iter.next()) |placeholder| {
                if (placeholder.style != .indexed) return error.InvalidArguments;
                try composed_sql.appendSlice(self.allocator, other.sql.items[cursor..placeholder.offset]);
                cursor = placeholder.offset + placeholder.len;

                const shifted_index = std.math.add(usize, placeholder.index.?, shift) catch
                    return error.IntegerOverflow;
                var number_buf: [32]u8 = undefined;
                const marker = try std.fmt.bufPrint(&number_buf, "${d}", .{shifted_index});
                try composed_sql.appendSlice(self.allocator, marker);
            }
        }

        try composed_sql.appendSlice(self.allocator, other.sql.items[cursor..]);
        for (other.binds.items) |value| {
            const stored = try self.storeValue(value);
            try self.binds.append(self.allocator, stored);
        }
        try self.sql.appendSlice(self.allocator, composed_sql.items);
        self.next_index = std.math.add(usize, next_index, other.next_index - 1) catch
            return error.IntegerOverflow;
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
        const sql_len = self.sql.items.len;
        errdefer self.sql.shrinkRetainingCapacity(sql_len);
        try quoteIdent(&self.sql, self.allocator, name);
    }

    /// Quote a dotted path such as `schema.table.column`.
    pub fn identPath(self: *QueryBuilder, path: []const u8) !void {
        const sql_len = self.sql.items.len;
        errdefer self.sql.shrinkRetainingCapacity(sql_len);
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
        const sql_len = self.sql.items.len;
        errdefer self.sql.shrinkRetainingCapacity(sql_len);
        if (segments.len == 0) return error.InvalidArguments;
        for (segments, 0..) |part, i| {
            if (part.len == 0) return error.InvalidArguments;
            if (i != 0) try self.sql.append(self.allocator, '.');
            try quoteIdent(&self.sql, self.allocator, part);
        }
    }

    /// Quote every name in a slice and join the quoted identifiers with
    /// `separator`. The separator is trusted caller input and is appended
    /// verbatim. An invalid or failed later identifier rolls back the entire
    /// operation.
    pub fn identJoined(
        self: *QueryBuilder,
        names: []const []const u8,
        separator: []const u8,
    ) !void {
        const sql_len = self.sql.items.len;
        errdefer self.sql.shrinkRetainingCapacity(sql_len);

        for (names, 0..) |name, index| {
            if (index != 0) try self.sql.appendSlice(self.allocator, separator);
            try self.ident(name);
        }
    }

    /// Bind a parameter. Accepts `Value`, common Zig scalars (`bool`, integers,
    /// floats, `[]const u8`, optionals, and `null`), and explicit SQL-domain
    /// wrappers. Values are never concatenated into the SQL string.
    pub fn bind(self: *QueryBuilder, value: anytype) !void {
        const sql_len = self.sql.items.len;
        const binds_len = self.binds.items.len;
        const owned_len = self.owned.items.len;
        const next_index = self.next_index;
        errdefer self.rollbackBind(sql_len, binds_len, owned_len, next_index);

        const stored = try self.prepareStoredValue(value);
        try self.binds.append(self.allocator, stored);
        switch (self.dialect) {
            .postgres => {
                var buf: [32]u8 = undefined;
                const placeholder = try std.fmt.bufPrint(&buf, "${d}", .{self.next_index});
                try self.sql.appendSlice(self.allocator, placeholder);
                self.next_index = std.math.add(usize, self.next_index, 1) catch
                    return error.IntegerOverflow;
            },
            .sqlite => {
                try self.sql.append(self.allocator, '?');
            },
        }
    }

    /// Bind every element of a slice, array, or tuple as an all-or-nothing
    /// operation. Each element accepts the same values as `bind`; if any later
    /// element fails, SQL, bind order, ownership, and placeholder indexes are
    /// restored to their state before this call.
    pub fn bindAll(self: *QueryBuilder, values: anytype) !void {
        const sql_len = self.sql.items.len;
        const binds_len = self.binds.items.len;
        const owned_len = self.owned.items.len;
        const next_index = self.next_index;
        errdefer self.rollbackBind(sql_len, binds_len, owned_len, next_index);

        switch (@typeInfo(@TypeOf(values))) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => for (values) |value| try self.bind(value),
                .one => for (values) |value| try self.bind(value),
                else => @compileError("QueryBuilder.bindAll supports slices, arrays, and tuples"),
            },
            .array => for (values) |value| try self.bind(value),
            .@"struct" => |structure| {
                if (!structure.is_tuple) {
                    @compileError("QueryBuilder.bindAll supports slices, arrays, and tuples");
                }
                inline for (values) |value| try self.bind(value);
            },
            else => @compileError("QueryBuilder.bindAll supports slices, arrays, and tuples"),
        }
    }

    /// Bind every element of a slice, array, or tuple, appending `separator`
    /// between adjacent placeholders. This is the delimiter-aware form of
    /// `bindAll`; like that operation, binding is all-or-nothing. The separator
    /// is trusted caller input and is appended verbatim.
    pub fn bindJoined(
        self: *QueryBuilder,
        values: anytype,
        separator: []const u8,
    ) !void {
        const sql_len = self.sql.items.len;
        const binds_len = self.binds.items.len;
        const owned_len = self.owned.items.len;
        const next_index = self.next_index;
        errdefer self.rollbackBind(sql_len, binds_len, owned_len, next_index);

        switch (@typeInfo(@TypeOf(values))) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => for (values, 0..) |value, index| {
                    if (index != 0) try self.sql.appendSlice(self.allocator, separator);
                    try self.bind(value);
                },
                .one => for (values, 0..) |value, index| {
                    if (index != 0) try self.sql.appendSlice(self.allocator, separator);
                    try self.bind(value);
                },
                else => @compileError("QueryBuilder.bindJoined supports slices, arrays, and tuples"),
            },
            .array => for (values, 0..) |value, index| {
                if (index != 0) try self.sql.appendSlice(self.allocator, separator);
                try self.bind(value);
            },
            .@"struct" => |structure| {
                if (!structure.is_tuple) {
                    @compileError("QueryBuilder.bindJoined supports slices, arrays, and tuples");
                }
                inline for (values, 0..) |value, index| {
                    if (index != 0) try self.sql.appendSlice(self.allocator, separator);
                    try self.bind(value);
                }
            },
            else => @compileError("QueryBuilder.bindJoined supports slices, arrays, and tuples"),
        }
    }

    pub fn sqlSlice(self: *const QueryBuilder) []const u8 {
        return self.sql.items;
    }

    pub fn bindsSlice(self: *const QueryBuilder) []const Value {
        return self.binds.items;
    }

    /// Bind a typed UUID as canonical lowercase text. The formatted value is
    /// copied by the normal bind ownership path, so callers may reuse stack
    /// storage immediately. Optional UUIDs bind SQL null when empty.
    pub fn bindUuid(self: *QueryBuilder, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == @TypeOf(null)) return self.bind(.{ .null = {} });

        const info = @typeInfo(T);
        if (info == .optional) {
            if (value) |uuid| return self.bindUuid(uuid);
            return self.bind(.{ .null = {} });
        }
        if (T != types.Uuid) {
            @compileError("QueryBuilder.bindUuid accepts zsql.types.Uuid or ?zsql.types.Uuid");
        }

        return self.bind(value);
    }

    /// Bind a typed date as ISO calendar text. Optional empty values bind SQL
    /// null. Formatting uses a fixed stack buffer before the normal owned-copy
    /// bind path.
    pub fn bindDate(self: *QueryBuilder, value: anytype) !void {
        return self.bindTemporal(value, types.Date, "Date");
    }

    /// Bind a typed time as ISO text with nanosecond precision when present.
    /// Optional empty values bind SQL null.
    pub fn bindTime(self: *QueryBuilder, value: anytype) !void {
        return self.bindTemporal(value, types.Time, "Time");
    }

    /// Bind a typed UTC timestamp as ISO text ending in `Z`. Optional empty
    /// values bind SQL null.
    pub fn bindTimestampUtc(self: *QueryBuilder, value: anytype) !void {
        return self.bindTemporal(
            value,
            types.Timestamp,
            "Timestamp",
        );
    }

    fn bindTemporal(
        self: *QueryBuilder,
        value: anytype,
        comptime expected: type,
        comptime type_name: []const u8,
    ) !void {
        const T = @TypeOf(value);
        if (T == @TypeOf(null)) return self.bind(.{ .null = {} });

        const info = @typeInfo(T);
        if (info == .optional) {
            if (value) |temporal| return self.bindTemporal(temporal, expected, type_name);
            return self.bind(.{ .null = {} });
        }
        if (T != expected) {
            @compileError("QueryBuilder accepts zsql.types." ++ type_name ++
                " or its optional");
        }

        return self.bind(value);
    }

    fn prepareStoredValue(self: *QueryBuilder, value: anytype) !Value {
        const T = @TypeOf(value);
        if (T == @TypeOf(null)) return .{ .null = {} };

        const info = @typeInfo(T);
        if (info == .optional) {
            if (value) |inner| return self.prepareStoredValue(inner);
            return .{ .null = {} };
        }

        if (T == types.Text) return self.storeValue(.{ .text = value.bytes });
        if (T == types.Blob) return self.storeValue(.{ .blob = value.bytes });
        if (T == types.Numeric) return self.storeValue(.{ .text = value.text });

        if (T == types.Uuid) {
            var buffer: [36]u8 = undefined;
            const formatted = try value.formatCanonical(&buffer);
            return self.storeValue(.{ .text = formatted });
        }

        if (T == types.Date or T == types.Time or T == types.Timestamp) {
            var buffer: [types.Timestamp.iso_buffer_len]u8 = undefined;
            const formatted = if (T == types.Date)
                try value.formatIso(&buffer)
            else if (T == types.Time)
                try value.formatIso(&buffer)
            else
                try value.formatIsoUtc(&buffer);
            return self.storeValue(.{ .text = formatted });
        }

        return self.storeValue(try coerceValue(value));
    }

    fn rollbackBind(
        self: *QueryBuilder,
        sql_len: usize,
        binds_len: usize,
        owned_len: usize,
        next_index: usize,
    ) void {
        self.sql.shrinkRetainingCapacity(sql_len);
        self.binds.shrinkRetainingCapacity(binds_len);
        while (self.owned.items.len > owned_len) {
            self.allocator.free(self.owned.pop().?);
        }
        self.next_index = next_index;
    }

    fn storeValue(self: *QueryBuilder, value: Value) !Value {
        return switch (value) {
            .null => .{ .null = {} },
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .boolean => |v| .{ .boolean = v },
            .text => |t| blk: {
                const owned = try self.allocator.dupe(u8, t);
                errdefer self.allocator.free(owned);
                try self.owned.append(self.allocator, owned);
                break :blk .{ .text = owned };
            },
            .blob => |b| blk: {
                const owned = try self.allocator.dupe(u8, b);
                errdefer self.allocator.free(owned);
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

test "QueryBuilder.bindUuid formats typed values canonically" {
    const uuid = try types.parseUuid("550E8400-E29B-41D4-A716-4466554400FF");

    var postgres = QueryBuilder.init(std.testing.allocator, .postgres);
    defer postgres.deinit();
    try postgres.appendTrustedSql("values (");
    try postgres.bindUuid(uuid);
    try postgres.appendTrustedSql(", ");
    try postgres.bindUuid(@as(?types.Uuid, uuid));
    try postgres.appendTrustedSql(", ");
    try postgres.bindUuid(null);
    try postgres.appendTrustedSql(")");

    try std.testing.expectEqualStrings("values ($1, $2, $3)", postgres.sqlSlice());
    try std.testing.expectEqualStrings(
        "550e8400-e29b-41d4-a716-4466554400ff",
        postgres.bindsSlice()[0].text,
    );
    try std.testing.expectEqualStrings(
        "550e8400-e29b-41d4-a716-4466554400ff",
        postgres.bindsSlice()[1].text,
    );
    try std.testing.expect(postgres.bindsSlice()[2].isNull());
    try std.testing.expectEqual(@as(usize, 2), postgres.owned.items.len);

    var sqlite = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer sqlite.deinit();
    try sqlite.bindUuid(null);
    try std.testing.expectEqualStrings("?", sqlite.sqlSlice());
    try std.testing.expect(sqlite.bindsSlice()[0].isNull());
}

fn exerciseQueryBuilderBindUuidAllocations(allocator: std.mem.Allocator) !void {
    var qb = QueryBuilder.init(allocator, .postgres);
    defer qb.deinit();
    const uuid = try types.parseUuid("550e8400-e29b-41d4-a716-4466554400ff");
    try qb.bindUuid(uuid);
}

test "QueryBuilder.bindUuid cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderBindUuidAllocations,
        .{},
    );
}

test "QueryBuilder binds typed temporal values without allocation" {
    const date = try types.parseIsoDate("2024-02-29");
    const time = try types.parseIsoTime("04:05:06.007000000");
    const timestamp = try types.parseIsoTimestamp("1969-12-31 23:59:59.999999");

    var postgres = QueryBuilder.init(std.testing.allocator, .postgres);
    defer postgres.deinit();
    try postgres.appendTrustedSql("values (");
    try postgres.bindDate(date);
    try postgres.appendTrustedSql(", ");
    try postgres.bindTime(time);
    try postgres.appendTrustedSql(", ");
    try postgres.bindTimestampUtc(timestamp);
    try postgres.appendTrustedSql(", ");
    try postgres.bindDate(null);
    try postgres.appendTrustedSql(", ");
    try postgres.bindTime(@as(?types.Time, time));
    try postgres.appendTrustedSql(")");

    try std.testing.expectEqualStrings(
        "values ($1, $2, $3, $4, $5)",
        postgres.sqlSlice(),
    );
    try std.testing.expectEqualStrings("2024-02-29", postgres.bindsSlice()[0].text);
    try std.testing.expectEqualStrings("04:05:06.007", postgres.bindsSlice()[1].text);
    try std.testing.expectEqualStrings(
        "1969-12-31T23:59:59.999999Z",
        postgres.bindsSlice()[2].text,
    );
    try std.testing.expect(postgres.bindsSlice()[3].isNull());
    try std.testing.expectEqualStrings("04:05:06.007", postgres.bindsSlice()[4].text);
    try std.testing.expectEqual(@as(usize, 4), postgres.owned.items.len);

    var sqlite = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer sqlite.deinit();
    try sqlite.bindTimestampUtc(timestamp);
    try sqlite.bindDate(@as(?types.Date, null));
    try std.testing.expectEqualStrings("??", sqlite.sqlSlice());
    try std.testing.expectEqualStrings(
        "1969-12-31T23:59:59.999999Z",
        sqlite.bindsSlice()[0].text,
    );
    try std.testing.expect(sqlite.bindsSlice()[1].isNull());
}

test "QueryBuilder rejects an invalid typed time before mutation" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    defer qb.deinit();
    try qb.appendTrustedSql("x");
    const invalid = types.Time{ .ns_since_midnight = 86_400_000_000_000 };

    try std.testing.expectEqual(
        error.InvalidArguments,
        qb.bindTime(invalid),
    );
    try std.testing.expectEqualStrings("x", qb.sqlSlice());
    try std.testing.expectEqual(@as(usize, 0), qb.bindsSlice().len);
    try std.testing.expectEqual(@as(usize, 0), qb.owned.items.len);
    try std.testing.expectEqual(@as(usize, 1), qb.next_index);
}

fn exerciseQueryBuilderTemporalAllocations(allocator: std.mem.Allocator) !void {
    var qb = QueryBuilder.init(allocator, .postgres);
    defer qb.deinit();
    try qb.bindDate(try types.parseIsoDate("2024-02-29"));
    try qb.bindTime(try types.parseIsoTime("04:05:06.007"));
    try qb.bindTimestampUtc(try types.parseIsoTimestamp("1969-12-31 23:59:59.999999"));
}

test "QueryBuilder temporal bindings clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderTemporalAllocations,
        .{},
    );
}

fn exerciseQueryBuilderBindAllocations(
    allocator: std.mem.Allocator,
    dialect: QueryBuilder.Dialect,
) !void {
    var qb = QueryBuilder.init(allocator, dialect);
    defer qb.deinit();
    try qb.appendTrustedSql("values (");
    try qb.bind(@as([]const u8, "owned text"));
    try qb.appendTrustedSql(", ");
    try qb.bind(Value{ .blob = "\x00\x01" });
    try qb.appendTrustedSql(")");
}

test "QueryBuilder.reset enables leak-free reuse with fresh placeholders" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    defer qb.deinit();

    try qb.appendTrustedSql("select \"value\" from \"items\" where \"id\" = ");
    try qb.bind(@as([]const u8, "first"));
    const first_sql = try std.testing.allocator.dupe(u8, qb.sqlSlice());
    defer std.testing.allocator.free(first_sql);
    try std.testing.expectEqualStrings(
        "select \"value\" from \"items\" where \"id\" = $1",
        first_sql,
    );

    qb.reset();
    try std.testing.expectEqual(@as(usize, 0), qb.sqlSlice().len);
    try std.testing.expectEqual(@as(usize, 0), qb.bindsSlice().len);
    try std.testing.expectEqual(@as(usize, 0), qb.owned.items.len);
    try std.testing.expectEqual(@as(usize, 1), qb.next_index);

    try qb.appendTrustedSql("select \"name\" from \"users\" where \"id\" = ");
    try qb.bind(@as([]const u8, "second"));
    try std.testing.expectEqualStrings(
        "select \"name\" from \"users\" where \"id\" = $1",
        qb.sqlSlice(),
    );
    try std.testing.expectEqualStrings("second", qb.bindsSlice()[0].text);
}

test "QueryBuilder clone creates an independent owned builder" {
    const uuid = try types.parseUuid("550E8400-E29B-41D4-A716-4466554400FF");
    var cloned = blk: {
        var source = QueryBuilder.init(std.testing.allocator, .postgres);
        errdefer source.deinit();
        try source.appendTrustedSql("select ");
        try source.ident("payload");
        try source.appendTrustedSql(" where id = ");
        try source.bind(@as([]const u8, "owned payload"));
        try source.appendTrustedSql(" and external_id = ");
        try source.bind(uuid);

        const result = try source.clone(std.testing.allocator);
        source.deinit();
        break :blk result;
    };
    defer cloned.deinit();

    try std.testing.expectEqualStrings(
        "select \"payload\" where id = $1 and external_id = $2",
        cloned.sqlSlice(),
    );
    try std.testing.expectEqualStrings("owned payload", cloned.bindsSlice()[0].text);
    try std.testing.expectEqualStrings(
        "550e8400-e29b-41d4-a716-4466554400ff",
        cloned.bindsSlice()[1].text,
    );
    try std.testing.expectEqual(@as(usize, 3), cloned.next_index);
}

fn exerciseQueryBuilderCloneAllocations(allocator: std.mem.Allocator) !void {
    var source = QueryBuilder.init(allocator, .sqlite);
    defer source.deinit();
    const uuid = try types.parseUuid("550e8400-e29b-41d4-a716-4466554400ff");
    try source.appendTrustedSql("values (");
    try source.bind(@as([]const u8, "owned"));
    try source.bind(Value{ .blob = "\x00" });
    try source.bind(uuid);
    var cloned = try source.clone(allocator);
    defer cloned.deinit();
}

test "QueryBuilder clone cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderCloneAllocations,
        .{},
    );
}

test "QueryBuilder.appendBuilder composes placeholders and owns payloads" {
    const date = try types.parseIsoDate("2024-02-29");

    var postgres = QueryBuilder.init(std.testing.allocator, .postgres);
    defer postgres.deinit();
    try postgres.appendTrustedSql("select \"id\" from \"items\" where status = ");
    try postgres.bind(@as([]const u8, "active"));
    try postgres.appendTrustedSql(" and created_at >= ");

    var filter = QueryBuilder.init(std.testing.allocator, .postgres);
    defer filter.deinit();
    try filter.bind(date);
    try filter.appendTrustedSql(" and external_id = ");
    const uuid = try types.parseUuid("550E8400-E29B-41D4-A716-4466554400FF");
    try filter.bind(uuid);
    try postgres.appendBuilder(&filter);

    try std.testing.expectEqualStrings(
        "select \"id\" from \"items\" where status = $1 and created_at >= $2 and external_id = $3",
        postgres.sqlSlice(),
    );
    try std.testing.expectEqualStrings("active", postgres.bindsSlice()[0].text);
    try std.testing.expectEqualStrings("2024-02-29", postgres.bindsSlice()[1].text);
    try std.testing.expectEqualStrings(
        "550e8400-e29b-41d4-a716-4466554400ff",
        postgres.bindsSlice()[2].text,
    );
    try std.testing.expectEqual(@as(usize, 4), postgres.next_index);

    var sqlite = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer sqlite.deinit();
    try sqlite.appendTrustedSql("where id = ");
    try sqlite.bind(@as(i64, 7));
    var extra = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer extra.deinit();
    try extra.appendTrustedSql(" or email = ");
    try extra.bind(@as([]const u8, "ada@example.test"));
    try sqlite.appendBuilder(&extra);
    try std.testing.expectEqualStrings("where id = ? or email = ?", sqlite.sqlSlice());
    try std.testing.expectEqualStrings("ada@example.test", sqlite.bindsSlice()[1].text);
}

test "QueryBuilder.appendBuilder rejects dialect mismatch atomically" {
    var postgres = QueryBuilder.init(std.testing.allocator, .postgres);
    defer postgres.deinit();
    try postgres.appendTrustedSql("select 1 where name = ");
    try postgres.bind(@as([]const u8, "kept"));

    var sqlite = QueryBuilder.init(std.testing.allocator, .sqlite);
    defer sqlite.deinit();
    try sqlite.bind(@as([]const u8, "ignored"));

    try std.testing.expectError(error.InvalidArguments, postgres.appendBuilder(&sqlite));
    try std.testing.expectEqualStrings("select 1 where name = $1", postgres.sqlSlice());
    try std.testing.expectEqual(@as(usize, 1), postgres.bindsSlice().len);
}

fn exerciseQueryBuilderAppendAllocations(allocator: std.mem.Allocator) !void {
    var base = QueryBuilder.init(allocator, .postgres);
    defer base.deinit();
    var extra = QueryBuilder.init(allocator, .postgres);
    defer extra.deinit();
    try base.appendTrustedSql("where name = ");
    try base.bind(@as([]const u8, "first"));
    try extra.appendTrustedSql("or note = ");
    try extra.bind(types.Text{ .bytes = "second" });
    try base.appendBuilder(&extra);
}

test "QueryBuilder.appendBuilder cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderAppendAllocations,
        .{},
    );
}

test "QueryBuilder.identJoined quotes a dynamic identifier list" {
    inline for (.{ QueryBuilder.Dialect.postgres, QueryBuilder.Dialect.sqlite }) |dialect| {
        var qb = QueryBuilder.init(std.testing.allocator, dialect);
        defer qb.deinit();

        try qb.appendTrustedSql("select ");
        try qb.identJoined(&.{ "id", "public users", "weird\"name" }, ", ");
        try qb.appendTrustedSql(" from t");
        try std.testing.expectEqualStrings(
            "select \"id\", \"public users\", \"weird\"\"name\" from t",
            qb.sqlSlice(),
        );

        try qb.appendTrustedSql(" where ");
        const before = qb.sqlSlice().len;
        try std.testing.expectError(error.InvalidArguments, qb.identJoined(&.{ "ok", "" }, ", "));
        try std.testing.expectEqual(before, qb.sqlSlice().len);
    }
}

fn exerciseIdentJoinedAllocations(allocator: std.mem.Allocator) !void {
    var qb = QueryBuilder.init(allocator, .postgres);
    defer qb.deinit();
    try qb.appendTrustedSql("x");
    try qb.identJoined(&.{ "first", "second" }, ", ");
}

test "QueryBuilder.identJoined cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseIdentJoinedAllocations,
        .{},
    );
}

test "QueryBuilder.bindAll binds tuples, arrays, and slices atomically" {
    inline for (.{ QueryBuilder.Dialect.postgres, QueryBuilder.Dialect.sqlite }) |dialect| {
        var qb = QueryBuilder.init(std.testing.allocator, dialect);
        defer qb.deinit();

        try qb.appendTrustedSql("values (");
        try qb.bindAll(.{ 1, "owned text", Value{ .blob = "\x00\x01" }, null });
        try qb.appendTrustedSql(")");
        try std.testing.expectEqualStrings(
            if (dialect == .postgres)
                "values ($1$2$3$4)"
            else
                "values (????)",
            qb.sqlSlice(),
        );
        try std.testing.expectEqual(@as(usize, 4), qb.bindsSlice().len);
        try std.testing.expectEqualStrings("owned text", qb.bindsSlice()[1].text);

        qb.reset();
        try qb.appendTrustedSql("values (");
        const values = [_]Value{ .{ .integer = 7 }, .null };
        try qb.bindAll(&values);
        try qb.appendTrustedSql(")");
        try std.testing.expectEqualStrings(
            if (dialect == .postgres)
                "values ($1$2)"
            else
                "values (??)",
            qb.sqlSlice(),
        );
        try std.testing.expectEqual(@as(usize, 2), qb.bindsSlice().len);
    }
}

test "QueryBuilder.bindAll accepts explicit SQL domain wrappers" {
    inline for (.{ QueryBuilder.Dialect.postgres, QueryBuilder.Dialect.sqlite }) |dialect| {
        var qb = QueryBuilder.init(std.testing.allocator, dialect);
        defer qb.deinit();

        const uuid = try types.parseUuid("550E8400-E29B-41D4-A716-4466554400FF");
        const values = .{
            types.Text{ .bytes = "explicit text" },
            types.Blob{ .bytes = "\x00\x01" },
            types.Numeric{ .text = "-12.3400" },
            uuid,
            try types.parseIsoDate("2024-02-29"),
            try types.parseIsoTime("04:05:06.007000000"),
            try types.parseIsoTimestamp("1969-12-31 23:59:59.999999"),
        };
        try qb.appendTrustedSql("values (");
        try qb.bindJoined(values, ", ");
        try qb.appendTrustedSql(")");

        try std.testing.expectEqual(@as(usize, 7), qb.bindsSlice().len);
        try std.testing.expectEqualStrings(
            if (dialect == .postgres)
                "values ($1, $2, $3, $4, $5, $6, $7)"
            else
                "values (?, ?, ?, ?, ?, ?, ?)",
            qb.sqlSlice(),
        );
        try std.testing.expectEqualStrings("explicit text", qb.bindsSlice()[0].text);
        try std.testing.expectEqualStrings("\x00\x01", qb.bindsSlice()[1].blob);
        try std.testing.expectEqualStrings("-12.3400", qb.bindsSlice()[2].text);
        try std.testing.expectEqualStrings(
            "550e8400-e29b-41d4-a716-4466554400ff",
            qb.bindsSlice()[3].text,
        );
        try std.testing.expectEqualStrings("2024-02-29", qb.bindsSlice()[4].text);
        try std.testing.expectEqualStrings("04:05:06.007", qb.bindsSlice()[5].text);
        try std.testing.expectEqualStrings(
            "1969-12-31T23:59:59.999999Z",
            qb.bindsSlice()[6].text,
        );
        try std.testing.expectEqual(@as(usize, 7), qb.owned.items.len);
    }
}

fn exerciseQueryBuilderDomainWrapperAllocations(allocator: std.mem.Allocator) !void {
    var qb = QueryBuilder.init(allocator, .postgres);
    defer qb.deinit();
    const uuid = try types.parseUuid("550e8400-e29b-41d4-a716-4466554400ff");
    try qb.bindAll(.{
        types.Text{ .bytes = "owned" },
        types.Blob{ .bytes = "\x00" },
        types.Numeric{ .text = "1.2" },
        uuid,
        try types.parseIsoDate("2024-02-29"),
        try types.parseIsoTime("04:05:06.007"),
        try types.parseIsoTimestamp("1969-12-31 23:59:59.999999"),
    });
}

test "QueryBuilder typed wrapper batches clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderDomainWrapperAllocations,
        .{},
    );
}

test "QueryBuilder.bindJoined emits delimited atomic placeholders" {
    inline for (.{ QueryBuilder.Dialect.postgres, QueryBuilder.Dialect.sqlite }) |dialect| {
        var qb = QueryBuilder.init(std.testing.allocator, dialect);
        defer qb.deinit();

        try qb.appendTrustedSql("values (");
        try qb.bindJoined(.{ 1, "owned text", Value{ .blob = "\x00\x01" }, null }, ", ");
        try qb.appendTrustedSql(")");
        try std.testing.expectEqualStrings(
            if (dialect == .postgres)
                "values ($1, $2, $3, $4)"
            else
                "values (?, ?, ?, ?)",
            qb.sqlSlice(),
        );
        try std.testing.expectEqual(@as(usize, 4), qb.bindsSlice().len);
        try std.testing.expectEqualStrings("owned text", qb.bindsSlice()[1].text);

        qb.reset();
        try qb.appendTrustedSql("values (");
        try qb.bindJoined(.{}, ", ");
        try qb.appendTrustedSql(")");
        try std.testing.expectEqualStrings("values ()", qb.sqlSlice());
        try std.testing.expectEqual(@as(usize, 0), qb.bindsSlice().len);
    }
}

fn exerciseQueryBuilderBindJoined(allocator: std.mem.Allocator) !void {
    var qb = QueryBuilder.init(allocator, .postgres);
    defer qb.deinit();

    try qb.appendTrustedSql("x");
    if (qb.bindJoined(.{ "first", "second" }, ", ")) |_| {
        try std.testing.expectEqualStrings("x$1, $2", qb.sqlSlice());
        try std.testing.expectEqual(@as(usize, 2), qb.bindsSlice().len);
        try std.testing.expectEqual(@as(usize, 2), qb.owned.items.len);
        try std.testing.expectEqual(@as(usize, 3), qb.next_index);
    } else |err| {
        if (err != error.OutOfMemory) return err;
        try std.testing.expectEqualStrings("x", qb.sqlSlice());
        try std.testing.expectEqual(@as(usize, 0), qb.bindsSlice().len);
        try std.testing.expectEqual(@as(usize, 0), qb.owned.items.len);
        try std.testing.expectEqual(@as(usize, 1), qb.next_index);
        return error.OutOfMemory;
    }
}

test "QueryBuilder.bindJoined cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderBindJoined,
        .{},
    );
}

test "QueryBuilder.bindAll restores the complete prior operation on failure" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    try qb.appendTrustedSql("x");
    defer qb.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    qb.allocator = failing.allocator();

    const initial_sql = try std.testing.allocator.dupe(u8, qb.sqlSlice());
    defer std.testing.allocator.free(initial_sql);

    var saw_oom = false;
    if (qb.bindAll(.{ "first", "second" })) |_| {
        return error.TestExpectedError;
    } else |err| {
        if (err != error.OutOfMemory) return err;
        saw_oom = true;
    }

    qb.allocator = std.testing.allocator;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(saw_oom);
    try std.testing.expectEqualStrings("x", qb.sqlSlice());
    try std.testing.expectEqual(@as(usize, 0), qb.bindsSlice().len);
    try std.testing.expectEqual(@as(usize, 0), qb.owned.items.len);
    try std.testing.expectEqual(@as(usize, 1), qb.next_index);

    try qb.bindAll(.{ "first", "second" });
    try std.testing.expectEqualStrings("x$1$2", qb.sqlSlice());
}

test "QueryBuilder.bind cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderBindAllocations,
        .{QueryBuilder.Dialect.postgres},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseQueryBuilderBindAllocations,
        .{QueryBuilder.Dialect.sqlite},
    );
}

test "QueryBuilder.bind is failure-atomic and retryable" {
    inline for (.{ QueryBuilder.Dialect.postgres, QueryBuilder.Dialect.sqlite }) |dialect| {
        for (0..5) |fail_index| {
            var qb = QueryBuilder.init(std.testing.allocator, dialect);
            try qb.sql.ensureTotalCapacityPrecise(std.testing.allocator, 1);
            qb.sql.appendAssumeCapacity('x');

            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
            });
            qb.allocator = failing.allocator();
            defer {
                qb.allocator = std.testing.allocator;
                qb.deinit();
            }

            const result = qb.bind(@as([]const u8, "payload"));
            if (fail_index < 4) {
                try std.testing.expectError(error.OutOfMemory, result);
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqualStrings("x", qb.sqlSlice());
                try std.testing.expectEqual(@as(usize, 0), qb.bindsSlice().len);
                try std.testing.expectEqual(@as(usize, 0), qb.owned.items.len);
                try std.testing.expectEqual(@as(usize, 1), qb.next_index);

                failing.fail_index = std.math.maxInt(usize);
                try qb.bind(@as([]const u8, "payload"));
            } else {
                try result;
                try std.testing.expect(!failing.has_induced_failure);
            }

            try std.testing.expectEqualStrings(
                if (dialect == .postgres) "x$1" else "x?",
                qb.sqlSlice(),
            );
            try std.testing.expectEqual(@as(usize, 1), qb.bindsSlice().len);
            try std.testing.expectEqualStrings("payload", qb.bindsSlice()[0].text);
            try std.testing.expectEqual(@as(usize, 1), qb.owned.items.len);
            try std.testing.expectEqual(
                @as(usize, if (dialect == .postgres) 2 else 1),
                qb.next_index,
            );
        }
    }
}

const IdentifierOperation = enum { single, path, segments };

const long_identifier = "a\"bcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const quoted_long_identifier = "\"a\"\"bcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\"";

fn appendTestIdentifier(qb: *QueryBuilder, operation: IdentifierOperation) !void {
    switch (operation) {
        .single => try qb.ident(long_identifier),
        .path => try qb.identPath("public." ++ long_identifier),
        .segments => try qb.identSegments(&.{ "public", long_identifier }),
    }
}

fn expectedTestIdentifier(operation: IdentifierOperation) []const u8 {
    return switch (operation) {
        .single => "x" ++ quoted_long_identifier,
        .path, .segments => "x\"public\"." ++ quoted_long_identifier,
    };
}

test "QueryBuilder identifier writes are failure-atomic and retryable" {
    inline for (.{ IdentifierOperation.single, .path, .segments }) |operation| {
        var saw_allocation_failure = false;
        for (0..16) |fail_index| {
            var qb = QueryBuilder.init(std.testing.allocator, .postgres);
            try qb.sql.ensureTotalCapacityPrecise(std.testing.allocator, 1);
            qb.sql.appendAssumeCapacity('x');

            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
            });
            qb.allocator = failing.allocator();
            defer {
                qb.allocator = std.testing.allocator;
                qb.deinit();
            }

            if (appendTestIdentifier(&qb, operation)) |_| {
                try std.testing.expect(!failing.has_induced_failure);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
                saw_allocation_failure = true;
                try std.testing.expectEqualStrings("x", qb.sqlSlice());

                failing.fail_index = std.math.maxInt(usize);
                try appendTestIdentifier(&qb, operation);
            }
            try std.testing.expectEqualStrings(expectedTestIdentifier(operation), qb.sqlSlice());
        }
        try std.testing.expect(saw_allocation_failure);
    }
}

test "QueryBuilder invalid identifier paths leave SQL unchanged" {
    var qb = QueryBuilder.init(std.testing.allocator, .postgres);
    defer qb.deinit();
    try qb.appendTrustedSql("select ");

    try std.testing.expectError(error.InvalidArguments, qb.identPath("valid."));
    try std.testing.expectEqualStrings("select ", qb.sqlSlice());
    try std.testing.expectError(error.InvalidArguments, qb.identPath("valid.bad\x00name"));
    try std.testing.expectEqualStrings("select ", qb.sqlSlice());
    try std.testing.expectError(error.InvalidArguments, qb.identSegments(&.{ "valid", "" }));
    try std.testing.expectEqualStrings("select ", qb.sqlSlice());

    try qb.identSegments(&.{ "valid", "name" });
    try std.testing.expectEqualStrings("select \"valid\".\"name\"", qb.sqlSlice());
}
