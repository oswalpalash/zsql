const std = @import("std");
const zsql = @import("zsql");

const User = struct {
    id: i64,
    name: []const u8,
    active: bool,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var db = try zsql.drivers.sqlite.Database.open(allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec(
        "create table users (id integer primary key, name text not null, active integer not null)",
        &.{},
    );

    var tx = try conn.begin();
    defer tx.rollbackIfOpen();

    _ = try tx.exec(
        "insert into users (id, name, active) values (?, ?, ?)",
        &.{
            .{ .integer = 1 },
            .{ .text = "ada" },
            .{ .boolean = true },
        },
    );

    var sp = try tx.savepoint();
    defer sp.rollbackIfOpen();
    _ = try tx.exec(
        "insert into users (id, name, active) values (?, ?, ?)",
        &.{
            .{ .integer = 2 },
            .{ .text = "temporary" },
            .{ .boolean = false },
        },
    );
    try sp.rollback();

    try tx.commit();

    var rows = try conn.query("select id, name, active from users where id = ?", &.{.{ .integer = 1 }});
    defer rows.deinit();

    const row = (try rows.next()) orelse return error.MissingUser;
    var owned = try zsql.OwnedRow.init(allocator, row);
    defer owned.deinit();

    const user = try owned.to(User);
    if (user.id != 1 or !std.mem.eql(u8, user.name, "ada") or !user.active) {
        return error.InvalidUser;
    }

    if (try rows.next() != null) return error.UnexpectedRow;
}
