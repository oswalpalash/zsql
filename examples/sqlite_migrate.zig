const std = @import("std");
const zsql = @import("zsql");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();
    const io = std.Options.debug_io;

    const cwd = std.Io.Dir.cwd();
    const migration_dir = ".zig-cache/zsql-migrate-example";
    try cwd.deleteTree(io, migration_dir);
    defer cwd.deleteTree(io, migration_dir) catch {};

    try cwd.createDirPath(io, migration_dir);
    var dir = try cwd.openDir(io, migration_dir, .{ .iterate = true });
    defer dir.close(io);

    try dir.writeFile(io, .{
        .sub_path = "V0002__seed_users.sql",
        .data =
        \\insert into users (id, name) values (1, 'ada');
        \\insert into users (id, name) values (2, 'grace');
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "V0001__create_users.sql",
        .data =
        \\create table users (
        \\  id integer primary key,
        \\  name text not null
        \\);
        ,
    });

    var migrations = try zsql.migrate.scanDir(allocator, io, dir);
    defer migrations.deinit();

    var db = try zsql.drivers.sqlite.Database.open(allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const migrator = zsql.drivers.sqlite.Migrator.init(&conn);
    const result = try migrator.apply(migrations.files);
    if (result.applied != 2) return error.UnexpectedMigrationCount;

    var rows = try conn.query("select name from users order by id", &.{});
    defer rows.deinit();

    const first = (try rows.next()) orelse return error.MissingUser;
    if (!std.mem.eql(u8, try (try first.value("name")).asText(), "ada")) return error.InvalidUser;
    const second = (try rows.next()) orelse return error.MissingUser;
    if (!std.mem.eql(u8, try (try second.value("name")).asText(), "grace")) return error.InvalidUser;
    if (try rows.next() != null) return error.UnexpectedRow;

    var status = try migrator.status(allocator);
    defer status.deinit();
    if (status.records.len != 2) return error.UnexpectedMigrationCount;
    if (status.records[0].dirty or status.records[1].dirty) return error.DirtyMigration;
}
