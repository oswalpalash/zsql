const std = @import("std");
const zsql = @import("zsql");
const public_api = @import("public_api.zig");

pub fn main() !void {
    public_api.validate();

    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var db = try zsql.drivers.sqlite.Database.open(allocator, .{});
    errdefer db.deinit();
    var conn = try db.connect();
    errdefer conn.close();

    _ = try conn.exec(
        "create table smoke (id integer primary key, label text not null unique, payload blob not null)",
        &.{},
    );
    const result = try conn.exec(
        "insert into smoke (id, label, payload) values (?, ?, ?)",
        &.{ .{ .integer = 1 }, .{ .text = "durable" }, .{ .blob = "owned-bytes" } },
    );
    if (result.rows_affected != 1) return error.InvalidInsert;

    var owned = owned: {
        var rows = try conn.query("select id, label, payload from smoke", &.{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingRow;
        break :owned try row.getOwned(allocator);
    };
    defer owned.deinit();

    const duplicate_sql = "insert into smoke (id, label, payload) values (?, ?, ?)";
    const duplicate_result = conn.exec(
        duplicate_sql,
        &.{ .{ .integer = 2 }, .{ .text = "durable" }, .{ .blob = "private-bind" } },
    );
    if (duplicate_result) |_| {
        return error.ExpectedUniqueViolation;
    } else |err| {
        if (err != error.UniqueViolation) return err;
    }
    var owned_error = (try conn.lastErrorOwned(allocator)) orelse return error.MissingDbError;
    defer owned_error.deinit(allocator);

    conn.close();
    db.deinit();

    if (try owned.asName(i64, "id") != 1) return error.InvalidOwnedId;
    if (!std.mem.eql(u8, try owned.asName([]const u8, "label"), "durable"))
        return error.InvalidOwnedText;
    if (!std.mem.eql(u8, try owned.asName([]const u8, "payload"), "owned-bytes"))
        return error.InvalidOwnedBlob;
    const db_error = owned_error.view();
    if (!std.mem.eql(u8, db_error.code.?, "2067")) return error.InvalidDbErrorCode;
    if (!std.mem.eql(u8, db_error.sql.?, duplicate_sql)) return error.InvalidDbErrorSql;
    if (std.mem.indexOf(u8, db_error.message, "private-bind") != null)
        return error.DbErrorStoredBind;
}
