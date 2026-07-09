const std = @import("std");
const inspect = @import("inspect.zig");
const params = @import("../core/params.zig");

pub const CheckError = error{
    PlaceholderCountMismatch,
    UnknownNamedParameter,
    ExtraNamedParameter,
    UnknownTable,
    UnknownColumn,
    TypeMismatch,
    NullabilityMismatch,
    InvalidSql,
};

pub const ArgSpec = struct {
    name: []const u8,
};

pub const FieldSpec = struct {
    name: []const u8,
    /// Optional: when set, must match a schema column type name (case-insensitive).
    type_name: ?[]const u8 = null,
    nullable: bool = false,
};

/// Lightweight offline SQL check against a schema artifact and parameter/row specs.
///
/// Validates named placeholders and that each result field exists on the named
/// table when `from_table` is provided. Values are never required at check time.
pub fn checkQuery(options: struct {
    sql: []const u8,
    schema: inspect.Schema,
    args: []const ArgSpec = &.{},
    row: []const FieldSpec = &.{},
    from_table: ?[]const u8 = null,
}) CheckError!void {
    const summary = params.summarize(options.sql) catch return error.InvalidSql;

    if (summary.named > 0) {
        var it = params.Iterator.init(options.sql);
        while (it.next() catch return error.InvalidSql) |ph| {
            if (ph.style != .named) continue;
            const name = stripMarker(ph.name);
            var found = false;
            for (options.args) |arg| {
                if (std.mem.eql(u8, arg.name, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownNamedParameter;
        }
        for (options.args) |arg| {
            var used = false;
            var it2 = params.Iterator.init(options.sql);
            while (it2.next() catch return error.InvalidSql) |ph| {
                if (ph.style != .named) continue;
                if (std.mem.eql(u8, stripMarker(ph.name), arg.name)) {
                    used = true;
                    break;
                }
            }
            if (!used) return error.ExtraNamedParameter;
        }
    } else if (options.args.len != 0) {
        if (summary.expectedBindCount() != options.args.len) return error.PlaceholderCountMismatch;
    }

    if (options.from_table) |table_name| {
        const table = findTable(options.schema, table_name) orelse return error.UnknownTable;
        for (options.row) |field| {
            const col = findColumn(table, field.name) orelse return error.UnknownColumn;
            if (field.type_name) |want| {
                if (!typesCompatible(want, col.type_name)) return error.TypeMismatch;
            }
            if (!field.nullable and col.nullable) return error.NullabilityMismatch;
        }
    } else if (options.row.len != 0 and options.schema.tables.len == 1) {
        const table = options.schema.tables[0];
        for (options.row) |field| {
            _ = findColumn(table, field.name) orelse return error.UnknownColumn;
        }
    }
}

fn stripMarker(name: []const u8) []const u8 {
    if (name.len == 0) return name;
    return switch (name[0]) {
        ':', '@', '$' => name[1..],
        else => name,
    };
}

fn findTable(schema: inspect.Schema, name: []const u8) ?inspect.Table {
    for (schema.tables) |table| {
        if (std.mem.eql(u8, table.name, name)) return table;
    }
    return null;
}

fn findColumn(table: inspect.Table, name: []const u8) ?inspect.Column {
    for (table.columns) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

/// Loose type compatibility for offline checks across SQLite / Postgres names.
/// Exact match (case-insensitive) always succeeds; common aliases also match.
fn typesCompatible(want: []const u8, have: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(want, have)) return true;
    const a = normalizeTypeName(want);
    const b = normalizeTypeName(have);
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    // Integer family
    if (isIntegerType(a) and isIntegerType(b)) return true;
    // Text family
    if (isTextType(a) and isTextType(b)) return true;
    // Float family
    if (isFloatType(a) and isFloatType(b)) return true;
    // Bool family
    if (isBoolType(a) and isBoolType(b)) return true;
    // Blob family
    if (isBlobType(a) and isBlobType(b)) return true;
    return false;
}

fn normalizeTypeName(name: []const u8) []const u8 {
    // Strip common modifiers: "character varying", "timestamp without time zone"
    if (std.ascii.eqlIgnoreCase(name, "character varying")) return "varchar";
    if (std.ascii.eqlIgnoreCase(name, "double precision")) return "float8";
    if (std.ascii.indexOfIgnoreCase(name, "timestamp") != null) return "timestamp";
    return name;
}

fn isIntegerType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "integer") or
        std.ascii.eqlIgnoreCase(name, "int") or
        std.ascii.eqlIgnoreCase(name, "int2") or
        std.ascii.eqlIgnoreCase(name, "int4") or
        std.ascii.eqlIgnoreCase(name, "int8") or
        std.ascii.eqlIgnoreCase(name, "smallint") or
        std.ascii.eqlIgnoreCase(name, "bigint") or
        std.ascii.eqlIgnoreCase(name, "serial") or
        std.ascii.eqlIgnoreCase(name, "bigserial");
}

fn isTextType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "text") or
        std.ascii.eqlIgnoreCase(name, "varchar") or
        std.ascii.eqlIgnoreCase(name, "character") or
        std.ascii.eqlIgnoreCase(name, "char") or
        std.ascii.eqlIgnoreCase(name, "name") or
        std.ascii.eqlIgnoreCase(name, "citext");
}

fn isFloatType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "real") or
        std.ascii.eqlIgnoreCase(name, "float") or
        std.ascii.eqlIgnoreCase(name, "float4") or
        std.ascii.eqlIgnoreCase(name, "float8") or
        std.ascii.eqlIgnoreCase(name, "double") or
        std.ascii.eqlIgnoreCase(name, "numeric");
}

fn isBoolType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "bool") or
        std.ascii.eqlIgnoreCase(name, "boolean");
}

fn isBlobType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "blob") or
        std.ascii.eqlIgnoreCase(name, "bytea") or
        std.ascii.eqlIgnoreCase(name, "bytes");
}

/// Build a checked-query type from options. Prefer this for stable embed sites:
///
/// ```zig
/// const q = zsql.checkedQuery(.{
///     .sql = "select id from users where id = :id",
///     .args = &.{.{ .name = "id" }},
///     .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
///     .from_table = "users",
/// });
/// try q.validate(schema);
/// ```
///
/// Call `validate()` at comptime or runtime against a schema artifact. This is
/// the ergonomic surface toward the target API shape; it does not invent ORM
/// behavior — only offline validation of placeholders and row/arg shapes.
pub fn checkedQuery(comptime options: anytype) type {
    const sql_value: []const u8 = options.sql;
    const from_table_value: ?[]const u8 = if (@hasField(@TypeOf(options), "from_table")) options.from_table else null;

    const args_value: []const ArgSpec = comptime blk: {
        if (!@hasField(@TypeOf(options), "args")) break :blk &.{};
        const raw = options.args;
        var out: [raw.len]ArgSpec = undefined;
        for (raw, 0..) |item, i| {
            out[i] = .{ .name = item.name };
        }
        const frozen = out;
        break :blk &frozen;
    };

    const row_value: []const FieldSpec = comptime blk: {
        if (!@hasField(@TypeOf(options), "row")) break :blk &.{};
        const raw = options.row;
        var out: [raw.len]FieldSpec = undefined;
        for (raw, 0..) |item, i| {
            out[i] = .{
                .name = item.name,
                .type_name = if (@hasField(@TypeOf(item), "type_name")) item.type_name else null,
                .nullable = if (@hasField(@TypeOf(item), "nullable")) item.nullable else false,
            };
        }
        const frozen = out;
        break :blk &frozen;
    };

    return struct {
        pub const sql = sql_value;
        pub const args = args_value;
        pub const row = row_value;
        pub const from_table = from_table_value;

        pub fn validate(schema: inspect.Schema) CheckError!void {
            try checkQuery(.{
                .sql = sql,
                .schema = schema,
                .args = args,
                .row = row,
                .from_table = from_table,
            });
        }
    };
}

test "checkQuery validates named params and columns" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                    .{ .name = "bio", .type_name = "TEXT", .nullable = true },
                },
            },
        },
    };

    try checkQuery(.{
        .sql = "select id, email from users where id = :id",
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "id", .type_name = "INTEGER" },
            .{ .name = "email", .type_name = "TEXT" },
        },
        .from_table = "users",
    });

    try std.testing.expectError(error.UnknownNamedParameter, checkQuery(.{
        .sql = "select id from users where id = :id",
        .schema = schema,
        .args = &.{.{ .name = "nope" }},
        .from_table = "users",
        .row = &.{.{ .name = "id" }},
    }));

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select missing from users",
        .schema = schema,
        .from_table = "users",
        .row = &.{.{ .name = "missing" }},
    }));

    try std.testing.expectError(error.NullabilityMismatch, checkQuery(.{
        .sql = "select bio from users",
        .schema = schema,
        .from_table = "users",
        .row = &.{.{ .name = "bio", .nullable = false }},
    }));
}

test "typesCompatible accepts common cross-driver aliases" {
    try std.testing.expect(typesCompatible("INTEGER", "int4"));
    try std.testing.expect(typesCompatible("bigint", "INTEGER"));
    try std.testing.expect(typesCompatible("TEXT", "varchar"));
    try std.testing.expect(typesCompatible("BOOLEAN", "bool"));
    try std.testing.expect(typesCompatible("BLOB", "bytea"));
    try std.testing.expect(!typesCompatible("TEXT", "INTEGER"));
}

test "checkQuery accepts integer alias against int8 column" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "int8", .nullable = false, .primary_key = true },
                },
            },
        },
    };
    try checkQuery(.{
        .sql = "select id from users",
        .schema = schema,
        .from_table = "users",
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
    });
}

test "checkedQuery type validates against schema" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    const get_user = checkedQuery(.{
        .sql = "select id, email from users where id = :id",
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "id", .type_name = "INTEGER" },
            .{ .name = "email", .type_name = "TEXT" },
        },
        .from_table = "users",
    });
    try get_user.validate(schema);
    try std.testing.expectEqualStrings("select id, email from users where id = :id", get_user.sql);
}
