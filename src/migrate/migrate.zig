const std = @import("std");

pub const Checksum = [64]u8;

pub const MigrationId = struct {
    version: u64,
    name: []const u8,
    filename: []const u8,
};

pub const MigrationFile = struct {
    id: MigrationId,
    sql: []const u8 = "",
    owned_sql: ?[]u8 = null,
    checksum: Checksum,

    pub fn deinit(self: *MigrationFile, allocator: std.mem.Allocator) void {
        allocator.free(self.id.name);
        allocator.free(self.id.filename);
        if (self.owned_sql) |sql| allocator.free(sql);
        self.* = undefined;
    }
};

pub const MigrationList = struct {
    allocator: std.mem.Allocator,
    files: []MigrationFile,

    pub fn deinit(self: *MigrationList) void {
        for (self.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

pub fn parseFilename(path_or_filename: []const u8) !MigrationId {
    const filename = std.fs.path.basename(path_or_filename);
    if (!std.mem.startsWith(u8, filename, "V")) return error.InvalidMigrationFilename;
    if (!std.mem.endsWith(u8, filename, ".sql")) return error.InvalidMigrationFilename;

    const stem = filename[0 .. filename.len - ".sql".len];
    const separator = std.mem.indexOf(u8, stem, "__") orelse return error.InvalidMigrationFilename;
    if (separator != std.mem.lastIndexOf(u8, stem, "__").?) return error.InvalidMigrationFilename;

    const version_text = stem[1..separator];
    const name = stem[separator + "__".len ..];
    if (version_text.len == 0 or name.len == 0) return error.InvalidMigrationFilename;
    if (!isValidName(name)) return error.InvalidMigrationFilename;

    for (version_text) |digit| {
        if (!std.ascii.isDigit(digit)) return error.InvalidMigrationFilename;
    }

    return .{
        .version = std.fmt.parseUnsigned(u64, version_text, 10) catch return error.InvalidMigrationFilename,
        .name = name,
        .filename = filename,
    };
}

pub fn scanDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !MigrationList {
    var list: std.ArrayListUnmanaged(MigrationFile) = .empty;
    errdefer {
        for (list.items) |*file| {
            file.deinit(allocator);
        }
        list.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const parsed = parseFilename(entry.name) catch continue;

        var sql: ?[]u8 = try dir.readFileAlloc(io, entry.name, allocator, .limited(16 * 1024 * 1024));
        errdefer if (sql) |owned| allocator.free(owned);

        var owned_name: ?[]u8 = try allocator.dupe(u8, parsed.name);
        errdefer if (owned_name) |owned| allocator.free(owned);
        var owned_filename: ?[]u8 = try allocator.dupe(u8, parsed.filename);
        errdefer if (owned_filename) |owned| allocator.free(owned);

        try list.append(allocator, .{
            .id = .{
                .version = parsed.version,
                .name = owned_name.?,
                .filename = owned_filename.?,
            },
            .sql = sql.?,
            .owned_sql = sql.?,
            .checksum = checksumSql(sql.?),
        });
        sql = null;
        owned_name = null;
        owned_filename = null;
    }

    std.mem.sort(MigrationFile, list.items, {}, migrationFileLessThan);
    for (list.items[1..], 1..) |file, index| {
        if (file.id.version == list.items[index - 1].id.version) {
            return error.DuplicateMigrationVersion;
        }
    }

    return .{
        .allocator = allocator,
        .files = try list.toOwnedSlice(allocator),
    };
}

pub fn checksumSql(sql: []const u8) Checksum {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sql, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn isValidName(name: []const u8) bool {
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

fn migrationFileLessThan(_: void, lhs: MigrationFile, rhs: MigrationFile) bool {
    if (lhs.id.version != rhs.id.version) return lhs.id.version < rhs.id.version;
    return std.mem.lessThan(u8, lhs.id.filename, rhs.id.filename);
}

test "migration filename parser accepts versioned sql filenames" {
    const id = try parseFilename("migrations/V0001__create_users.sql");

    try std.testing.expectEqual(@as(u64, 1), id.version);
    try std.testing.expectEqualStrings("create_users", id.name);
    try std.testing.expectEqualStrings("V0001__create_users.sql", id.filename);
}

test "migration filename parser accepts hyphenated names" {
    const id = try parseFilename("V42__add-account-index.sql");

    try std.testing.expectEqual(@as(u64, 42), id.version);
    try std.testing.expectEqualStrings("add-account-index", id.name);
}

test "migration filename parser rejects malformed filenames" {
    const invalid = [_][]const u8{
        "",
        "v0001__create_users.sql",
        "V__create_users.sql",
        "V0001.sql",
        "V0001__create_users",
        "V0001__create users.sql",
        "V0001__create/users.sql",
        "V0001__create__users.sql",
        "Vabc__create_users.sql",
    };

    for (invalid) |filename| {
        try std.testing.expectError(error.InvalidMigrationFilename, parseFilename(filename));
    }
}

test "migration checksum is deterministic sha256 hex" {
    const sql = "create table users (id integer primary key);\n";

    try std.testing.expectEqualStrings(
        "1c6771824cf03a1eaf811b3418f430f4ba6aee10d59bf8a02cc7cadfc067934a",
        &checksumSql(sql),
    );
    try std.testing.expectEqual(checksumSql(sql), checksumSql(sql));
}

test "migration directory scanner returns sorted migration files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "V0002__add_users.sql", .data = "alter table users add column name text;\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "README.md", .data = "ignored\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "V0001__create_users.sql", .data = "create table users (id integer primary key);\n" });

    var migrations = try scanDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer migrations.deinit();

    try std.testing.expectEqual(@as(usize, 2), migrations.files.len);
    try std.testing.expectEqual(@as(u64, 1), migrations.files[0].id.version);
    try std.testing.expectEqualStrings("create_users", migrations.files[0].id.name);
    try std.testing.expectEqualStrings("V0001__create_users.sql", migrations.files[0].id.filename);
    try std.testing.expectEqualStrings("create table users (id integer primary key);\n", migrations.files[0].sql);
    try std.testing.expectEqualStrings("1c6771824cf03a1eaf811b3418f430f4ba6aee10d59bf8a02cc7cadfc067934a", &migrations.files[0].checksum);

    try std.testing.expectEqual(@as(u64, 2), migrations.files[1].id.version);
    try std.testing.expectEqualStrings("add_users", migrations.files[1].id.name);
}

test "migration directory scanner rejects duplicate versions" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "V0001__create_users.sql", .data = "create table users (id integer);\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "V1__add_users.sql", .data = "alter table users add column name text;\n" });

    try std.testing.expectError(error.DuplicateMigrationVersion, scanDir(std.testing.allocator, std.testing.io, tmp.dir));
}
