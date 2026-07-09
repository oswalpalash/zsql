const std = @import("std");
const zsql = @import("zsql");

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
        if (std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "up")) {
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

fn printHelp(io: std.Io) !void {
    try writeOut(io, .stdout,
        \\zsql — explicit SQL toolkit for Zig
        \\
        \\Usage:
        \\  zsql doctor
        \\  zsql migrate new <name>
        \\  zsql migrate status --database <path> [--dir migrations]
        \\  zsql migrate up --database <path> [--dir migrations]
        \\  zsql migrate status --url <postgres-url> [--dir migrations]
        \\  zsql migrate up --url <postgres-url> [--dir migrations]
        \\  zsql inspect --database <path> [--out schema.zon]
        \\  zsql inspect --url <postgres-url> [--out schema.zon]
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
        \\  zsql migrate status --url <postgres-url> [--dir migrations]
        \\  zsql migrate up --url <postgres-url> [--dir migrations]
        \\
    );
}

fn cmdDoctor(io: std.Io) !void {
    try writeOut(io, .stdout, "zsql doctor\n");
    try writeOut(io, .stdout, "  package: zsql\n");
    try writeOut(io, .stdout, "  version: ");
    try writeOut(io, .stdout, zsql.version);
    try writeOut(io, .stdout, "\n");
    try writeOut(io, .stdout, "  sqlite driver: ");
    if (zsql.enable_sqlite) {
        try writeOut(io, .stdout, "enabled\n");
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

    const version = try nextMigrationVersion(io, "migrations");
    const filename = try std.fmt.allocPrint(allocator, "V{d:0>4}__{s}.sql", .{ version, name });
    defer allocator.free(filename);

    const path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{filename});
    defer allocator.free(path);

    const file = try cwd.createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io,
        \\-- Write forward-only migration SQL below.
        \\
    );

    const msg = try std.fmt.allocPrint(allocator, "created {s}\n", .{path});
    defer allocator.free(msg);
    try writeOut(io, .stdout, msg);
}

fn cmdMigrateDb(init: std.process.Init, sub: []const u8, args: *std.process.Args.Iterator) !void {
    var database_path: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var dir_path: []const u8 = "migrations";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--database")) {
            database_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--url")) {
            url = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            dir_path = args.next() orelse return error.InvalidArguments;
        } else {
            try writeOut(init.io, .stderr, "unknown flag; use --database or --url and optional --dir\n");
            return error.InvalidArguments;
        }
    }

    if (database_path != null and url != null) {
        try writeOut(init.io, .stderr, "use either --database (sqlite) or --url (postgres), not both\n");
        return error.InvalidArguments;
    }

    if (url) |pg_url| {
        return cmdMigratePostgres(init, sub, pg_url, dir_path);
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

fn cmdMigratePostgres(init: std.process.Init, sub: []const u8, pg_url: []const u8, dir_path: []const u8) !void {
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

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, growing.written());

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

fn nextMigrationVersion(io: std.Io, dir_path: []const u8) !u64 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 1;
    defer dir.close(io);

    var max_version: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = zsql.migrate.parseFilename(entry.name) catch continue;
        if (id.version > max_version) max_version = id.version;
    }
    return max_version + 1;
}
