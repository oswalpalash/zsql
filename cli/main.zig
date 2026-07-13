const std = @import("std");
const zsql = @import("zsql");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // program name

    const command = args.next() orelse {
        try printHelp(io);
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        try printHelp(io);
        return;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        try cmdDoctor(io);
        return;
    }
    if (std.mem.eql(u8, command, "migrate")) {
        const sub = args.next() orelse {
            try printMigrateHelp(io);
            return error.InvalidArguments;
        };
        if (std.mem.eql(u8, sub, "new")) {
            const name = args.next() orelse {
                try writeOut(io, .stderr, "usage: zsql migrate new <name>\n");
                return error.InvalidArguments;
            };
            try cmdMigrateNew(init, name);
            return;
        }
        if (std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "up") or std.mem.eql(u8, sub, "repair")) {
            try cmdMigrateDb(init, sub, &args);
            return;
        }
        try printMigrateHelp(io);
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, command, "inspect")) {
        try cmdInspect(init, &args);
        return;
    }
    if (std.mem.eql(u8, command, "gen")) {
        const sub = args.next() orelse return error.InvalidArguments;
        if (!std.mem.eql(u8, sub, "structs")) return error.InvalidArguments;
        try cmdGenStructs(init, &args);
        return;
    }

    try writeOut(io, .stderr, "unknown command; try `zsql --help`\n");
    return error.InvalidArguments;
}

const Stream = enum { stdout, stderr };

fn writeOut(io: std.Io, stream: Stream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    try file.writeStreamingAll(io, bytes);
}

const AtomicWriteMode = enum {
    create,
    replace,
};

/// Writes a complete CLI artifact through a same-directory temporary file.
/// `create` preserves an existing destination; `replace` swaps it atomically.
fn writeFileAtomic(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    bytes: []const u8,
    mode: AtomicWriteMode,
) !void {
    const replace = mode == .replace;
    const permissions: std.Io.File.Permissions = if (replace) permissions: {
        const stat = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break :permissions .default_file,
            else => return err,
        };
        break :permissions if (stat.kind == .file) stat.permissions else .default_file;
    } else .default_file;
    var atomic_file = try dir.createFileAtomic(io, sub_path, .{
        .make_path = true,
        .permissions = permissions,
        .replace = replace,
    });
    defer atomic_file.deinit(io);

    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    if (replace) {
        try atomic_file.replace(io);
    } else {
        try atomic_file.link(io);
    }
    try syncPublishedDirectory(atomic_file.dir, io);
}

/// Persists the directory entry added or replaced by atomic publication on
/// platforms where directory handles support the same sync operation as files.
fn syncPublishedDirectory(dir: std.Io.Dir, io: std.Io) !void {
    switch (builtin.os.tag) {
        .linux,
        .macos,
        .freebsd,
        .openbsd,
        .netbsd,
        .dragonfly,
        .illumos,
        => {
            // Linux commonly represents non-iterable `Dir` values with
            // `O_PATH`, which rejects `fsync`. Reopen the same directory with
            // read/iteration rights before borrowing its handle as a File.
            const sync_dir = try dir.openDir(io, ".", .{ .iterate = true });
            defer sync_dir.close(io);
            const directory_file: std.Io.File = .{
                .handle = sync_dir.handle,
                .flags = .{ .nonblocking = false },
            };
            try directory_file.sync(io);
        },
        else => {},
    }
}

fn printHelp(io: std.Io) !void {
    try writeOut(io, .stdout,
        \\zsql — explicit SQL toolkit for Zig
        \\
        \\Usage:
        \\  zsql doctor
        \\  zsql migrate new <name>
        \\  zsql migrate status --database <path> [--dir migrations]
        \\  zsql migrate up --database <path> [--dir migrations]
        \\  zsql migrate repair --database <path> --version <n> [--dir migrations]
        \\  zsql migrate status --url <postgres-url> [--dir migrations]
        \\  zsql migrate up --url <postgres-url> [--dir migrations]
        \\  zsql migrate repair --url <postgres-url> --version <n> [--dir migrations]
        \\  zsql inspect --database <path> [--out schema.zon]
        \\  zsql inspect --url <postgres-url> [--out schema.zon]
        \\  zsql gen structs --schema <schema.zon> --out <schema.zig>
        \\  zsql --help
        \\
        \\SQLite migrate/inspect require -Denable-sqlite=true.
        \\Postgres migrate/inspect use --url (native driver, no libpq).
        \\zsql is not an ORM. Prefer prepared statements and bind parameters.
        \\
    );
}

fn printMigrateHelp(io: std.Io) !void {
    try writeOut(io, .stderr,
        \\usage:
        \\  zsql migrate new <name>
        \\  zsql migrate status --database <path> [--dir migrations]
        \\  zsql migrate up --database <path> [--dir migrations]
        \\  zsql migrate repair --database <path> --version <n> [--dir migrations]
        \\  zsql migrate status --url <postgres-url> [--dir migrations]
        \\  zsql migrate up --url <postgres-url> [--dir migrations]
        \\  zsql migrate repair --url <postgres-url> --version <n> [--dir migrations]
        \\
    );
}

fn cmdGenStructs(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var schema_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--schema")) {
            schema_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return error.InvalidArguments;
        } else return error.InvalidArguments;
    }
    const source_path = schema_path orelse return error.InvalidArguments;
    const dest_path = out_path orelse return error.InvalidArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const zon = try init.gpa.dupeZ(u8, bytes);
    defer init.gpa.free(zon);
    const schema = try zsql.inspect.parseSchemaZon(init.gpa, zon);
    defer zsql.inspect.freeParsedSchemaZon(init.gpa, schema);
    var growing: std.Io.Writer.Allocating = .init(init.gpa);
    defer growing.deinit();
    try zsql.codegen.writeStructs(&growing.writer, schema);
    try writeFileAtomic(std.Io.Dir.cwd(), init.io, dest_path, growing.written(), .replace);
}

fn cmdDoctor(io: std.Io) !void {
    try writeOut(io, .stdout, "zsql doctor\n");
    try writeOut(io, .stdout, "  package: zsql\n");
    try writeOut(io, .stdout, "  version: ");
    try writeOut(io, .stdout, zsql.version);
    try writeOut(io, .stdout, "\n");
    try writeOut(io, .stdout, "  sqlite driver: ");
    if (zsql.enable_sqlite) {
        if (zsql.sqlite_amalgamation) {
            try writeOut(io, .stdout, "enabled (bundled amalgamation)\n");
        } else {
            try writeOut(io, .stdout, "enabled (system libsqlite3)\n");
        }
    } else {
        try writeOut(io, .stdout, "available behind -Denable-sqlite=true\n");
    }
    try writeOut(io, .stdout, "  postgres driver: enabled (native protocol, no libpq)\n");
    try writeOut(io, .stdout, "  tls: std.crypto.tls (require/prefer/verify-*)\n");
    try writeOut(io, .stdout, "  migrate helpers: yes\n");
    try writeOut(io, .stdout, "  query builder: yes\n");
    try writeOut(io, .stdout, "  offline check helpers: yes\n");
    try writeOut(io, .stdout, "ok\n");
}

fn cmdMigrateNew(init: std.process.Init, name: []const u8) !void {
    const allocator = init.gpa;
    const io = init.io;
    if (!isValidMigrationName(name)) {
        try writeOut(io, .stderr, "invalid migration name; use letters, digits, and underscores\n");
        return error.InvalidArguments;
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "migrations");
    const path = try createNextMigrationFile(allocator, cwd, io, "migrations", name);
    defer allocator.free(path);

    const msg = try std.fmt.allocPrint(allocator, "created {s}\n", .{path});
    defer allocator.free(msg);
    try writeOut(io, .stdout, msg);
}

fn cmdMigrateDb(init: std.process.Init, sub: []const u8, args: *std.process.Args.Iterator) !void {
    var database_path: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var dir_path: []const u8 = "migrations";
    var repair_version: ?u64 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--database")) {
            database_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--url")) {
            url = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            dir_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--version")) {
            repair_version = try parseMigrationVersion(args.next() orelse return error.InvalidArguments);
        } else {
            try writeOut(init.io, .stderr, "unknown flag; use --database or --url and optional --dir\n");
            return error.InvalidArguments;
        }
    }

    if (database_path != null and url != null) {
        try writeOut(init.io, .stderr, "use either --database (sqlite) or --url (postgres), not both\n");
        return error.InvalidArguments;
    }
    const repairing = std.mem.eql(u8, sub, "repair");
    if (repairing != (repair_version != null)) {
        try writeOut(init.io, .stderr, "repair requires --version <n>; other migrate commands do not accept it\n");
        return error.InvalidArguments;
    }

    if (url) |pg_url| {
        return cmdMigratePostgres(init, sub, pg_url, dir_path, repair_version);
    }

    const db_path = database_path orelse {
        try writeOut(init.io, .stderr, "missing --database <path> or --url <postgres-url>\n");
        return error.InvalidArguments;
    };

    if (!zsql.enable_sqlite) {
        try writeOut(init.io, .stderr, "sqlite migrate commands require -Denable-sqlite=true\n");
        return error.Unsupported;
    }

    const allocator = init.gpa;
    const io = init.io;

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var migrations = try zsql.migrate.scanDir(allocator, io, dir);
    defer migrations.deinit();

    var db = try zsql.drivers.sqlite.Database.open(allocator, .{
        .mode = .file,
        .path = db_path,
    });
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();

    const migrator = zsql.drivers.sqlite.Migrator.init(&conn);
    try migrator.ensureTable();
    if (repair_version) |version| {
        const migration = findMigrationByVersion(migrations.files, version) orelse return error.MigrationNotFound;
        try migrator.repairDirty(version, migration.checksum);
        try printRepairResult(io, allocator, version);
        return;
    }
    try migrator.validate(migrations.files);

    if (std.mem.eql(u8, sub, "up")) {
        const result = try migrator.apply(migrations.files);
        const msg = try std.fmt.allocPrint(allocator, "applied {d} migration(s)\n", .{result.applied});
        defer allocator.free(msg);
        try writeOut(io, .stdout, msg);
    }

    var status = try migrator.status(allocator);
    defer status.deinit();
    try printMigrationStatus(io, allocator, status.records);
}

fn cmdMigratePostgres(
    init: std.process.Init,
    sub: []const u8,
    pg_url: []const u8,
    dir_path: []const u8,
    repair_version: ?u64,
) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pg = zsql.drivers.postgres;

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var migrations = try zsql.migrate.scanDir(allocator, io, dir);
    defer migrations.deinit();

    var config = try pg.parseUrl(allocator, pg_url);
    defer config.deinit();

    var conn = try pg.Conn.open(allocator, io, config);
    defer conn.deinit();

    const migrator = pg.Migrator.init(&conn);
    try migrator.ensureTable();
    if (repair_version) |version| {
        const migration = findMigrationByVersion(migrations.files, version) orelse return error.MigrationNotFound;
        try migrator.repairDirty(version, migration.checksum);
        try printRepairResult(io, allocator, version);
        return;
    }
    try migrator.validate(migrations.files);

    if (std.mem.eql(u8, sub, "up")) {
        const result = try migrator.apply(migrations.files);
        const msg = try std.fmt.allocPrint(allocator, "applied {d} migration(s)\n", .{result.applied});
        defer allocator.free(msg);
        try writeOut(io, .stdout, msg);
    }

    var status = try migrator.status(allocator);
    defer status.deinit();
    try printMigrationStatus(io, allocator, status.records);
}

fn parseMigrationVersion(value: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, value, 10) catch error.InvalidArguments;
}

fn findMigrationByVersion(migrations: []const zsql.migrate.MigrationFile, version: u64) ?zsql.migrate.MigrationFile {
    for (migrations) |migration| {
        if (migration.id.version == version) return migration;
    }
    return null;
}

fn printRepairResult(io: std.Io, allocator: std.mem.Allocator, version: u64) !void {
    const message = try std.fmt.allocPrint(allocator, "repaired dirty migration V{d}; edit if needed, then rerun migrate up\n", .{version});
    defer allocator.free(message);
    try writeOut(io, .stdout, message);
}

fn printMigrationStatus(io: std.Io, allocator: std.mem.Allocator, records: anytype) !void {
    const header = try std.fmt.allocPrint(allocator, "status: {d} recorded migration(s)\n", .{records.len});
    defer allocator.free(header);
    try writeOut(io, .stdout, header);
    for (records) |rec| {
        const exec_ms: i64 = if (@hasField(@TypeOf(rec), "execution_ms")) rec.execution_ms else 0;
        const line = try std.fmt.allocPrint(
            allocator,
            "  V{d} {s} dirty={s} execution_ms={d}\n",
            .{ rec.version, rec.name, if (rec.dirty) "true" else "false", exec_ms },
        );
        defer allocator.free(line);
        try writeOut(io, .stdout, line);
    }
}

fn cmdInspect(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var database_path: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var out_path: []const u8 = "schema.zon";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--database")) {
            database_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--url")) {
            url = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return error.InvalidArguments;
        } else {
            try writeOut(init.io, .stderr, "unknown flag; use --database or --url and optional --out\n");
            return error.InvalidArguments;
        }
    }

    if (database_path != null and url != null) {
        try writeOut(init.io, .stderr, "use either --database (sqlite) or --url (postgres), not both\n");
        return error.InvalidArguments;
    }

    const allocator = init.gpa;
    const io = init.io;

    var growing: std.Io.Writer.Allocating = .init(allocator);
    defer growing.deinit();

    if (url) |pg_url| {
        const pg = zsql.drivers.postgres;
        var config = try pg.parseUrl(allocator, pg_url);
        defer config.deinit();
        var conn = try pg.Conn.open(allocator, io, config);
        defer conn.deinit();
        const schema = try conn.inspectSchema(allocator);
        defer pg.freeInspectedSchema(allocator, schema);
        try zsql.inspect.writeSchemaZon(&growing.writer, schema);
    } else {
        const db_path = database_path orelse {
            try writeOut(init.io, .stderr, "usage: zsql inspect --database <path>|--url <postgres-url> [--out schema.zon]\n");
            return error.InvalidArguments;
        };
        if (!zsql.enable_sqlite) {
            try writeOut(init.io, .stderr, "sqlite inspect requires -Denable-sqlite=true\n");
            return error.Unsupported;
        }
        var db = try zsql.drivers.sqlite.Database.open(allocator, .{
            .mode = .file,
            .path = db_path,
        });
        defer db.deinit();
        var conn = try db.connect();
        defer conn.close();
        const schema = try conn.inspectSchema(allocator);
        defer zsql.drivers.sqlite.freeInspectedSchema(allocator, schema);
        try zsql.inspect.writeSchemaZon(&growing.writer, schema);
    }

    try writeFileAtomic(std.Io.Dir.cwd(), io, out_path, growing.written(), .replace);

    const msg = try std.fmt.allocPrint(allocator, "wrote {s}\n", .{out_path});
    defer allocator.free(msg);
    try writeOut(io, .stdout, msg);
}

fn isValidMigrationName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_';
        if (!ok) return false;
    }
    return true;
}

test "migration repair version parser is strict" {
    try std.testing.expectEqual(@as(u64, 42), try parseMigrationVersion("42"));
    try std.testing.expectError(error.InvalidArguments, parseMigrationVersion("-1"));
    try std.testing.expectError(error.InvalidArguments, parseMigrationVersion("abc"));
}

test "migration repair finds exact version" {
    const sql = "select 1";
    const migrations = [_]zsql.migrate.MigrationFile{.{
        .id = .{ .version = 7, .name = "seven", .filename = "V0007__seven.sql" },
        .sql = sql,
        .checksum = zsql.migrate.checksumSql(sql),
    }};
    try std.testing.expectEqual(@as(u64, 7), findMigrationByVersion(&migrations, 7).?.id.version);
    try std.testing.expect(findMigrationByVersion(&migrations, 8) == null);
}

test "atomic CLI artifact replacement swaps complete contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "schema.zon",
        .data = "old schema\n",
    });
    try writeFileAtomic(tmp.dir, std.testing.io, "schema.zon", "new schema\n", .replace);

    const contents = try tmp.dir.readFileAlloc(
        std.testing.io,
        "schema.zon",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("new schema\n", contents);
}

test "atomic CLI artifact replacement preserves existing file permissions" {
    if (!std.Io.File.Permissions.has_executable_bit) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = try tmp.dir.createFile(std.testing.io, "schema.zon", .{
        .permissions = .fromMode(0o600),
    });
    try original.writeStreamingAll(std.testing.io, "old schema\n");
    original.close(std.testing.io);

    const before = try tmp.dir.statFile(std.testing.io, "schema.zon", .{});
    try writeFileAtomic(tmp.dir, std.testing.io, "schema.zon", "new schema\n", .replace);
    const after = try tmp.dir.statFile(std.testing.io, "schema.zon", .{});

    try std.testing.expectEqual(before.permissions, after.permissions);
}

test "atomic CLI artifact publication creates missing output parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(
        tmp.dir,
        std.testing.io,
        "generated/db/schema.zon",
        "schema\n",
        .replace,
    );
    const contents = try tmp.dir.readFileAlloc(
        std.testing.io,
        "generated/db/schema.zon",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("schema\n", contents);
}

test "atomic CLI artifact creation preserves existing destination and cleans temporary file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "V0001__create_users.sql",
        .data = "existing migration\n",
    });
    try std.testing.expectError(
        error.PathAlreadyExists,
        writeFileAtomic(
            tmp.dir,
            std.testing.io,
            "V0001__create_users.sql",
            "replacement migration\n",
            .create,
        ),
    );

    const contents = try tmp.dir.readFileAlloc(
        std.testing.io,
        "V0001__create_users.sql",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("existing migration\n", contents);

    var entries = tmp.dir.iterate();
    var file_count: usize = 0;
    while (try entries.next(std.testing.io)) |entry| {
        if (entry.kind == .file) file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

const migration_template =
    \\-- Write forward-only migration SQL below.
    \\
;

const max_migration_create_attempts = 32;

fn createNextMigrationFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
) ![]u8 {
    return createNextMigrationFileWith(
        allocator,
        dir,
        io,
        dir_path,
        name,
        {},
        struct {
            fn create(_: void, target_dir: std.Io.Dir, target_io: std.Io, path: []const u8, bytes: []const u8) !void {
                try writeFileAtomic(target_dir, target_io, path, bytes, .create);
            }
        }.create,
    );
}

fn createNextMigrationFileWith(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
    context: anytype,
    comptime createFn: anytype,
) ![]u8 {
    for (0..max_migration_create_attempts) |_| {
        const version = try nextMigrationVersion(dir, io, dir_path);
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/V{d:0>4}__{s}.sql",
            .{ dir_path, version, name },
        );
        createFn(context, dir, io, path, migration_template) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        return path;
    }
    return error.MigrationVersionConflict;
}

test "migration creation retries when a concurrent creator wins the version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "migrations");

    const CollisionOnce = struct {
        collided: bool = false,

        fn create(
            self: *@This(),
            dir: std.Io.Dir,
            io: std.Io,
            path: []const u8,
            bytes: []const u8,
        ) !void {
            if (!self.collided) {
                self.collided = true;
                try writeFileAtomic(dir, io, path, "concurrent migration\n", .create);
            }
            try writeFileAtomic(dir, io, path, bytes, .create);
        }
    };
    var collision: CollisionOnce = .{};
    const path = try createNextMigrationFileWith(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        "migrations",
        "create_users",
        &collision,
        CollisionOnce.create,
    );
    defer std.testing.allocator.free(path);

    try std.testing.expect(collision.collided);
    try std.testing.expectEqualStrings("migrations/V0002__create_users.sql", path);
    const first = try tmp.dir.readFileAlloc(
        std.testing.io,
        "migrations/V0001__create_users.sql",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("concurrent migration\n", first);
    const second = try tmp.dir.readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(migration_template, second);
}

test "migration creation bounds repeated version collisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "migrations");

    const AlwaysCollide = struct {
        attempts: usize = 0,

        fn create(
            self: *@This(),
            _: std.Io.Dir,
            _: std.Io,
            _: []const u8,
            _: []const u8,
        ) anyerror!void {
            self.attempts += 1;
            return error.PathAlreadyExists;
        }
    };
    var collisions: AlwaysCollide = .{};
    try std.testing.expectError(
        error.MigrationVersionConflict,
        createNextMigrationFileWith(
            std.testing.allocator,
            tmp.dir,
            std.testing.io,
            "migrations",
            "create_users",
            &collisions,
            AlwaysCollide.create,
        ),
    );
    try std.testing.expectEqual(max_migration_create_attempts, collisions.attempts);
}

test "migration creation preserves versions wider than the minimum padding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "migrations");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "migrations/V9999__previous.sql",
        .data = migration_template,
    });

    const path = try createNextMigrationFile(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        "migrations",
        "wide_version",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("migrations/V10000__wide_version.sql", path);

    const id = try zsql.migrate.parseFilename(path);
    try std.testing.expectEqual(@as(u64, 10_000), id.version);
}

test "migration version discovery rejects u64 exhaustion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "migrations");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "migrations/V18446744073709551615__last.sql",
        .data = migration_template,
    });

    try std.testing.expectError(
        error.MigrationVersionConflict,
        nextMigrationVersion(tmp.dir, std.testing.io, "migrations"),
    );
}

fn nextMigrationVersion(root: std.Io.Dir, io: std.Io, dir_path: []const u8) !u64 {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch return 1;
    defer dir.close(io);

    var max_version: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = zsql.migrate.parseFilename(entry.name) catch continue;
        if (id.version > max_version) max_version = id.version;
    }
    return std.math.add(u64, max_version, 1) catch error.MigrationVersionConflict;
}
