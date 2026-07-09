const std = @import("std");
const zsql = @import("zsql");

/// Offline-checked query example (no database connection required).
pub fn main() !void {
    const schema = zsql.inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                    .{ .name = "active", .type_name = "INTEGER", .nullable = false },
                },
            },
            .{
                .name = "posts",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "user_id", .type_name = "INTEGER", .nullable = false },
                    .{ .name = "title", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    try zsql.check.checkQuery(.{
        .sql =
        \\select id, email, active
        \\from users
        \\where id = :id
        ,
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "id", .type_name = "INTEGER" },
            .{ .name = "email", .type_name = "TEXT" },
            .{ .name = "active", .type_name = "INTEGER" },
        },
        .from_table = "users",
    });

    // Typed checked-query descriptor (comptime options, runtime/comptime validate).
    const get_user = zsql.checkedQuery(.{
        .sql =
        \\select id, email, active
        \\from users
        \\where id = :id
        ,
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "id", .type_name = "INTEGER" },
            .{ .name = "email", .type_name = "TEXT" },
            .{ .name = "active", .type_name = "INTEGER" },
        },
        .from_table = "users",
    });
    try get_user.validate(schema);

    // JOIN + projection/WHERE/ON checks: qualified columns, multi-table scope.
    const user_posts = zsql.checkedQuery(.{
        .sql =
        \\select u.email, p.title
        \\from users u
        \\join posts p on p.user_id = u.id
        \\where u.id = :id and lower(u.email) is not null
        ,
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "u.email", .type_name = "TEXT" },
            .{ .name = "p.title", .type_name = "TEXT" },
        },
        .check_projections = true,
        .check_where = true,
        .check_join_on = true,
    });
    try user_posts.validate(schema);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try zsql.inspect.writeSchemaZon(&writer, schema);

    const out = std.Io.File.stdout();
    // Example process may not have Init.io; use debug print for simplicity.
    std.debug.print("checked query ok\n", .{});
    std.debug.print("{s}", .{writer.buffered()});
    _ = out;
}
