const std = @import("std");

/// Minimal schema model for offline query checking artifacts.
pub const Column = struct {
    name: []const u8,
    type_name: []const u8,
    nullable: bool,
    primary_key: bool = false,
};

pub const Table = struct {
    name: []const u8,
    columns: []const Column,
};

pub const Schema = struct {
    tables: []const Table,
};

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
        try writer.writeAll("        } },\n");
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
        \\        } },
        \\    },
        \\}
        \\
    ,
        writer.buffered(),
    );
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
