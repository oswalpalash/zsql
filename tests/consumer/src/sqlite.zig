const std = @import("std");
const zsql = @import("zsql");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var db = try zsql.drivers.sqlite.Database.open(gpa.allocator(), .{});
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table smoke (id integer primary key)", &.{});
    const result = try conn.exec("insert into smoke (id) values (?)", &.{.{ .integer = 1 }});
    if (result.rows_affected != 1) return error.InvalidInsert;
}
