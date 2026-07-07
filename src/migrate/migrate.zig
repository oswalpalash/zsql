const std = @import("std");

pub const Checksum = [64]u8;

pub const MigrationId = struct {
    version: u64,
    name: []const u8,
    filename: []const u8,
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
