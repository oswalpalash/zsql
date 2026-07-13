const std = @import("std");
const zsql = @import("zsql");

/// Offline-checked query example (no database connection required).
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    // The build gate validates the exact embedded artifact applications use.
    const schema = try zsql.inspect.parseSchemaZon(
        allocator,
        @embedFile("checked_queries_schema.zon"),
    );
    defer zsql.inspect.freeParsedSchemaZon(allocator, schema);

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
        .args = .{ .id = i64 },
        .row = struct { id: i64, email: []const u8, active: i64 },
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

    // Schema-known USING lists are checked on both join sides.
    const same_id = zsql.checkedQuery(.{
        .sql = "select u.id from users u join posts p using (id)",
        .row = struct { id: i64 },
        .check_join_on = true,
    });
    try same_id.validate(schema);

    // Portable aggregate inference is deliberately narrow: aliased COUNT is
    // non-null i64, while MIN/MAX preserve the source type and stay optional.
    const user_aggregates = zsql.checkedQuery(.{
        .sql =
        \\select count(distinct email) as total,
        \\       min(id) as first_id,
        \\       max(id) as last_id
        \\from users
        \\order by total
        ,
        .row = struct { total: i64, first_id: ?i64, last_id: ?i64 },
        .check_projections = true,
        .check_order_by = true,
    });
    try user_aggregates.validate(schema);

    const users_by_state = zsql.checkedQuery(.{
        .sql =
        \\select active as state, count(*) as total
        \\from users
        \\group by state
        \\order by state
        ,
        .row = struct { state: i64, total: i64 },
        .check_group_by = true,
        .check_order_by = true,
    });
    try users_by_state.validate(schema);

    // CTE bodies stay opaque, but outer projection/scope/clause discovery is
    // anchored at statement depth zero rather than the first nested SELECT.
    const after_cte = zsql.checkedQuery(.{
        .sql =
        \\with post_ids as (select user_id from posts where title is not null)
        \\select email from users where id > 0
        ,
        .row = struct { email: []const u8 },
        .check_where = true,
    });
    try after_cte.validate(schema);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try zsql.inspect.writeSchemaZon(&writer, schema);

    const out = std.Io.File.stdout();
    // Example process may not have Init.io; use debug print for simplicity.
    std.debug.print("checked query ok\n", .{});
    std.debug.print("{s}", .{writer.buffered()});
    _ = out;
}
