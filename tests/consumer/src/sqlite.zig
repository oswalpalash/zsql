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
        "create table smoke (id integer primary key, label text not null, payload blob not null)",
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

    conn.close();
    db.deinit();

    if (try owned.asName(i64, "id") != 1) return error.InvalidOwnedId;
    if (!std.mem.eql(u8, try owned.asName([]const u8, "label"), "durable"))
        return error.InvalidOwnedText;
    if (!std.mem.eql(u8, try owned.asName([]const u8, "payload"), "owned-bytes"))
        return error.InvalidOwnedBlob;
}
