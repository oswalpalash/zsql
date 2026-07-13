const std = @import("std");

/// Identifier lookup semantics carried by an offline schema artifact.
/// `.unknown` preserves exact matching for legacy or hand-authored artifacts.
pub const Dialect = enum {
    unknown,
    sqlite,
    postgres,
};

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
    /// Owning database schema/namespace when the driver exposes one.
    /// SQLite and legacy artifacts leave this null. PostgreSQL inspection
    /// always records the exact schema name, including `public`.
    schema: ?[]const u8 = null,
    name: []const u8,
    columns: []const Column,
    indexes: []const Index = &.{},
};

pub const Schema = struct {
    dialect: Dialect = .unknown,
    tables: []const Table,
};

/// Free a fully allocator-owned schema graph produced by driver inspection.
pub fn freeSchema(allocator: std.mem.Allocator, schema: Schema) void {
    for (schema.tables) |table| {
        if (table.schema) |schema_name| allocator.free(schema_name);
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
    try writer.print("    .dialect = .{s},\n", .{@tagName(schema.dialect)});
    try writer.writeAll("    .tables = .{\n");
    for (schema.tables) |table| {
        try writer.writeAll("        .{ ");
        if (table.schema) |schema_name| {
            try writer.print(".schema = \"{s}\", ", .{schema_name});
        }
        try writer.print(".name = \"{s}\", .columns = .{{\n", .{table.name});
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

/// Parse a ZON schema artifact produced by `writeSchemaZon`.
///
/// The returned graph is allocator-owned. Release it with
/// `freeParsedSchemaZon` using the same allocator. `source` is sentinel
/// terminated so callers can pass `@embedFile("db/schema.zon")` directly.
pub fn parseSchemaZon(allocator: std.mem.Allocator, source: [:0]const u8) !Schema {
    return std.zon.parse.fromSliceAlloc(Schema, allocator, source, null, .{});
}

/// Free a schema returned by `parseSchemaZon`.
///
/// This is distinct from `freeSchema`, which frees driver-inspected schemas
/// assembled by zsql rather than the standard ZON parser.
pub fn freeParsedSchemaZon(allocator: std.mem.Allocator, schema: Schema) void {
    std.zon.parse.free(allocator, schema);
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
        .dialect = .sqlite,
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
        \\    .dialect = .sqlite,
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

test "parseSchemaZon loads an embedded artifact" {
    const schema = try parseSchemaZon(std.testing.allocator, @embedFile("testdata/users_schema.zon"));
    defer freeParsedSchemaZon(std.testing.allocator, schema);

    try std.testing.expectEqual(Dialect.unknown, schema.dialect);
    try std.testing.expectEqual(@as(usize, 1), schema.tables.len);
    try std.testing.expectEqualStrings("users", schema.tables[0].name);
    try std.testing.expectEqual(@as(usize, 4), schema.tables[0].columns.len);
    try std.testing.expect(schema.tables[0].columns[0].primary_key);
    try std.testing.expect(schema.tables[0].columns[3].nullable);
}

test "parseSchemaZon defaults legacy artifacts to unknown dialect" {
    const schema = try parseSchemaZon(std.testing.allocator, ".{ .tables = .{} }");
    defer freeParsedSchemaZon(std.testing.allocator, schema);

    try std.testing.expectEqual(Dialect.unknown, schema.dialect);
    try std.testing.expectEqual(@as(usize, 0), schema.tables.len);
}

test "writeSchemaZon preserves structured PostgreSQL table identity" {
    const original = Schema{ .dialect = .postgres, .tables = &.{.{
        .schema = "audit",
        .name = "events",
        .columns = &.{.{ .name = "id", .type_name = "int8", .nullable = false }},
    }} };
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSchemaZon(&writer, original);

    const source = try std.testing.allocator.dupeZ(u8, writer.buffered());
    defer std.testing.allocator.free(source);
    const parsed = try parseSchemaZon(std.testing.allocator, source);
    defer freeParsedSchemaZon(std.testing.allocator, parsed);

    try std.testing.expectEqual(Dialect.postgres, parsed.dialect);
    try std.testing.expectEqualStrings("audit", parsed.tables[0].schema.?);
    try std.testing.expectEqualStrings("events", parsed.tables[0].name);
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

test "postgres inspection SQL is parameterized and catalog-safe" {
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_tables_sql, "information_schema.tables") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_tables_sql, "pg_catalog") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_columns_sql, "$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_columns_sql, "$2") != null);
    // Values never concatenated; only placeholders for schema/table names.
    try std.testing.expect(std.mem.indexOf(u8, postgres_list_columns_sql, "PRIMARY KEY") != null);
}
