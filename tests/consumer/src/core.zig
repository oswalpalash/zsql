const std = @import("std");
const zsql = @import("zsql");
const public_api = @import("public_api.zig");

pub fn main() !void {
    public_api.validate();

    const result = zsql.ExecResult{ .rows_affected = 3 };
    if (result.rows_affected != 3) return error.InvalidResult;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var config = try zsql.drivers.postgres.parseUrl(
        gpa.allocator(),
        "postgres://app:secret@localhost:5432/example?sslmode=disable",
    );
    defer config.deinit();
    if (!std.mem.eql(u8, config.database, "example")) return error.InvalidPostgresConfig;

    const query = zsql.checkedQuery(.{
        .sql = "select id from users where id = :id",
        .args = .{ .id = i64 },
        .row = struct { id: i64 },
        .from_table = "users",
    });
    try query.validate(.{ .tables = &.{.{
        .name = "users",
        .columns = &.{.{ .name = "id", .type_name = "INTEGER", .nullable = false }},
    }} });
}
