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
                if (!std.ascii.eqlIgnoreCase(want, col.type_name)) return error.TypeMismatch;
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
