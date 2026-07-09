const std = @import("std");

/// Minimal schema model for offline query checking artifacts.
pub const Column = struct {
    name: []const u8,
    type_name: []const u8,
    nullable: bool,
    primary_key: bool = false,
};

pub const Index = struct {
    name: []const u8,
    unique: bool = false,
    /// Ordered column names participating in the index.
    columns: []const []const u8 = &.{},
};

pub const Table = struct {
    name: []const u8,
    columns: []const Column,
    indexes: []const Index = &.{},
};

pub const Schema = struct {
    tables: []const Table,
};

/// Free a fully allocator-owned schema graph produced by driver inspection.
pub fn freeSchema(allocator: std.mem.Allocator, schema: Schema) void {
    for (schema.tables) |table| {
        allocator.free(table.name);
        freeColumns(allocator, @constCast(table.columns));
        freeIndexes(allocator, @constCast(table.indexes));
    }
    allocator.free(schema.tables);
}

pub fn freeIndexes(allocator: std.mem.Allocator, indexes: []Index) void {
    for (indexes) |idx| {
        allocator.free(idx.name);
        for (idx.columns) |col| allocator.free(col);
        allocator.free(idx.columns);
    }
    allocator.free(indexes);
}

/// Render a Zig-friendly ZON-like schema document for embedding / offline checks.
///
/// Output is deterministic and intentionally simple (not a full ZON encoder).
pub fn writeSchemaZon(writer: *std.Io.Writer, schema: Schema) !void {
    try writer.writeAll(".{\n");
    try writer.writeAll("    .tables = .{\n");
    for (schema.tables) |table| {
        try writer.print("        .{{ .name = \"{s}\", .columns = .{{\n", .{table.name});
        for (table.columns) |col| {
            try writer.print(
                "            .{{ .name = \"{s}\", .type_name = \"{s}\", .nullable = {}, .primary_key = {} }},\n",
                .{ col.name, col.type_name, col.nullable, col.primary_key },
            );
        }
        if (table.indexes.len == 0) {
            try writer.writeAll("        }, .indexes = .{} },\n");
        } else {
            try writer.writeAll("        }, .indexes = .{\n");
            for (table.indexes) |idx| {
                try writer.print("            .{{ .name = \"{s}\", .unique = {}, .columns = .{{", .{ idx.name, idx.unique });
                for (idx.columns, 0..) |col, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{col});
                }
                try writer.writeAll("} },\n");
            }
            try writer.writeAll("        } },\n");
        }
    }
    try writer.writeAll("    },\n");
    try writer.writeAll("}\n");
}

/// Parse SQLite `PRAGMA table_info` style rows into columns.
/// Each row is `(cid, name, type, notnull, dflt_value, pk)`.
pub const SqliteTableInfoRow = struct {
    name: []const u8,
    type_name: []const u8,
    notnull: bool,
    pk: bool,
};

pub fn columnsFromSqliteTableInfo(allocator: std.mem.Allocator, rows: []const SqliteTableInfoRow) ![]Column {
    const columns = try allocator.alloc(Column, rows.len);
    errdefer allocator.free(columns);
    for (rows, 0..) |row, i| {
        columns[i] = .{
            .name = try allocator.dupe(u8, row.name),
            .type_name = try allocator.dupe(u8, row.type_name),
            .nullable = !row.notnull and !row.pk,
            .primary_key = row.pk,
        };
    }
    return columns;
}

/// One column row from PostgreSQL `information_schema.columns` (+ PK flag).
pub const PostgresColumnInfoRow = struct {
    name: []const u8,
    /// Prefer `udt_name` (e.g. `int4`, `text`) when available; otherwise `data_type`.
    type_name: []const u8,
    /// True when `is_nullable = 'YES'`.
    is_nullable: bool,
    primary_key: bool,
};

pub fn columnsFromPostgresColumnInfo(allocator: std.mem.Allocator, rows: []const PostgresColumnInfoRow) ![]Column {
    const columns = try allocator.alloc(Column, rows.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(columns[i].name);
            allocator.free(columns[i].type_name);
        }
        allocator.free(columns);
    }
    for (rows, 0..) |row, i| {
        const name = try allocator.dupe(u8, row.name);
        errdefer allocator.free(name);
        const type_name = try allocator.dupe(u8, row.type_name);
        columns[i] = .{
            .name = name,
            .type_name = type_name,
            .nullable = row.is_nullable and !row.primary_key,
            .primary_key = row.primary_key,
        };
        initialized = i + 1;
    }
    return columns;
}

/// Build a stable offline-check table name from PostgreSQL schema + table.
///
/// - `public` tables use the bare table name (`users`) so app SQL matches.
/// - Other schemas are qualified (`audit.events`).
pub fn postgresTableDisplayName(allocator: std.mem.Allocator, schema_name: []const u8, table_name: []const u8) ![]u8 {
    if (std.mem.eql(u8, schema_name, "public")) {
        return try allocator.dupe(u8, table_name);
    }
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ schema_name, table_name });
}

/// Trusted SQL used by the Postgres driver to list base tables.
/// Excluded catalogs: pg_catalog, information_schema.
pub const postgres_list_tables_sql =
    \\select table_schema, table_name
    \\from information_schema.tables
    \\where table_type = 'BASE TABLE'
    \\  and table_schema not in ('pg_catalog', 'information_schema')
    \\order by table_schema, table_name
;

/// Trusted SQL to list columns for one table. Placeholders: $1 schema, $2 table.
pub const postgres_list_columns_sql =
    \\select
    \\  c.column_name,
    \\  c.udt_name,
    \\  c.is_nullable,
    \\  case when pk.column_name is null then 'NO' else 'YES' end as is_primary_key
    \\from information_schema.columns c
    \\left join (
    \\  select kcu.column_name
    \\  from information_schema.table_constraints tc
    \\  join information_schema.key_column_usage kcu
    \\    on tc.constraint_name = kcu.constraint_name
    \\   and tc.table_schema = kcu.table_schema
    \\   and tc.table_name = kcu.table_name
    \\  where tc.constraint_type = 'PRIMARY KEY'
    \\    and tc.table_schema = $1
    \\    and tc.table_name = $2
    \\) pk on pk.column_name = c.column_name
    \\where c.table_schema = $1
    \\  and c.table_name = $2
    \\order by c.ordinal_position
;

/// List indexes for one table. Placeholders: $1 schema, $2 table.
/// Returns one row per index column (ordered); callers group by index_name.
pub const postgres_list_index_columns_sql =
    \\select
    \\  i.relname as index_name,
    \\  ix.indisunique as is_unique,
    \\  a.attname as column_name
    \\from pg_class t
    \\join pg_namespace n on n.oid = t.relnamespace
    \\join pg_index ix on t.oid = ix.indrelid
    \\join pg_class i on i.oid = ix.indexrelid
    \\join pg_attribute a on a.attrelid = t.oid and a.attnum = any(ix.indkey)
    \\where n.nspname = $1
    \\  and t.relname = $2
    \\  and t.relkind = 'r'
    \\order by i.relname, array_position(ix.indkey, a.attnum)
;

pub fn freeColumns(allocator: std.mem.Allocator, columns: []Column) void {
    for (columns) |col| {
        allocator.free(col.name);
        allocator.free(col.type_name);
    }
    allocator.free(columns);
}

test "writeSchemaZon is deterministic" {
    const schema = Schema{
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

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSchemaZon(&writer, schema);
    try std.testing.expectEqualStrings(
        \\.{
        \\    .tables = .{
        \\        .{ .name = "users", .columns = .{
        \\            .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
        \\            .{ .name = "email", .type_name = "TEXT", .nullable = false, .primary_key = false },
        \\        }, .indexes = .{} },
        \\    },
        \\}
        \\
    ,
        writer.buffered(),
    );
}

test "writeSchemaZon matches golden users_schema.zon" {
    const schema = Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false, .primary_key = false },
                    .{ .name = "active", .type_name = "BOOLEAN", .nullable = false, .primary_key = false },
                    .{ .name = "note", .type_name = "TEXT", .nullable = true, .primary_key = false },
                },
            },
        },
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSchemaZon(&writer, schema);
    try std.testing.expectEqualStrings(@embedFile("testdata/users_schema.zon"), writer.buffered());
}

test "columnsFromSqliteTableInfo maps nullability and pk" {
    const rows = [_]SqliteTableInfoRow{
        .{ .name = "id", .type_name = "INTEGER", .notnull = false, .pk = true },
        .{ .name = "note", .type_name = "TEXT", .notnull = false, .pk = false },
    };
    const columns = try columnsFromSqliteTableInfo(std.testing.allocator, &rows);
    defer freeColumns(std.testing.allocator, columns);
    try std.testing.expect(columns[0].primary_key);
    try std.testing.expect(!columns[0].nullable);
    try std.testing.expect(columns[1].nullable);
}

test "columnsFromPostgresColumnInfo maps nullability and pk" {
    const rows = [_]PostgresColumnInfoRow{
        .{ .name = "id", .type_name = "int8", .is_nullable = false, .primary_key = true },
        .{ .name = "email", .type_name = "text", .is_nullable = false, .primary_key = false },
        .{ .name = "note", .type_name = "text", .is_nullable = true, .primary_key = false },
    };
    const columns = try columnsFromPostgresColumnInfo(std.testing.allocator, &rows);
    defer freeColumns(std.testing.allocator, columns);
    try std.testing.expect(columns[0].primary_key);
    try std.testing.expect(!columns[0].nullable);
    try std.testing.expect(!columns[1].nullable);
    try std.testing.expect(columns[2].nullable);
    try std.testing.expectEqualStrings("int8", columns[0].type_name);
}

test "postgresTableDisplayName qualifies non-public schemas" {
    const public_name = try postgresTableDisplayName(std.testing.allocator, "public", "users");
    defer std.testing.allocator.free(public_name);
    try std.testing.expectEqualStrings("users", public_name);

    const other = try postgresTableDisplayName(std.testing.allocator, "audit", "events");
    defer std.testing.allocator.free(other);
    try std.testing.expectEqualStrings("audit.events", other);
}

test "postgres inspection SQL is parameterized and catalog-safe" {
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_tables_sql, "information_schema.tables") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_tables_sql, "pg_catalog") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_columns_sql, "$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_columns_sql, "$2") != null);
    // Values never concatenated; only placeholders for schema/table names.
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_columns_sql, "PRIMARY KEY") != null);
}
