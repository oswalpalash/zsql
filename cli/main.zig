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
            try writeOut(io, .stderr,
                \\zsql migrate status|up requires a database connection.
                \\Use the library Migrator API (SQLite) for apply/status today.
                \\
            );
            return error.Unsupported;
        }
        try printMigrateHelp(io);
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, command, "inspect")) {
        try writeOut(io, .stderr,
            \\zsql inspect is a placeholder until live schema export is wired to drivers.
            \\Library helpers: zsql.inspect.writeSchemaZon / columnsFromSqliteTableInfo.
            \\
        );
        return error.Unsupported;
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
        \\  zsql migrate status   (requires DB; library API preferred for now)
        \\  zsql migrate up       (requires DB; library API preferred for now)
        \\  zsql inspect          (placeholder)
        \\  zsql --help
        \\
        \\zsql is not an ORM. Prefer prepared statements and bind parameters.
        \\
    );
}

fn printMigrateHelp(io: std.Io) !void {
    try writeOut(io, .stderr,
        \\usage:
        \\  zsql migrate new <name>
        \\  zsql migrate status
        \\  zsql migrate up
        \\
    );
}

fn cmdDoctor(io: std.Io) !void {
    try writeOut(io, .stdout, "zsql doctor\n");
    try writeOut(io, .stdout, "  package: zsql\n");
    try writeOut(io, .stdout, "  sqlite driver: ");
    if (@hasDecl(zsql.drivers.sqlite, "enabled") and zsql.drivers.sqlite.enabled) {
        try writeOut(io, .stdout, "enabled\n");
    } else {
        try writeOut(io, .stdout, "available behind -Denable-sqlite=true\n");
    }
    try writeOut(io, .stdout, "  postgres driver: enabled (native protocol, no libpq)\n");
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
