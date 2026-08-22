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

/// Persist a dirty marker after a failed transactional migration.
///
/// The original migration error remains authoritative only after persistence
/// succeeds. If the marker cannot be recorded, return that error instead so a
/// caller never mistakes an untracked/uncertain failure for a durably guarded
/// dirty migration.
pub fn dirtyFailure(
    context: anytype,
    migration: MigrationFile,
    original: anyerror,
    comptime persist: fn (@TypeOf(context), MigrationFile) anyerror!void,
) anyerror {
    persist(context, migration) catch |err| return err;
    return original;
}

pub const Dialect = enum { sqlite, postgres };

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
            return error.MigrationVersionConflict;
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

/// Return true when SQL directly controls its surrounding transaction.
///
/// zsql owns each migration's transaction, so scripts may not issue transaction
/// commands. The scanner recognizes only command positions: occurrences inside
/// literals, comments, quoted identifiers, and dollar-quoted bodies do not
/// count. SQLite trigger bodies are exempt because `BEGIN ... END` is
/// procedural syntax rather than a transaction boundary.
pub fn containsTransactionControl(sql: []const u8, dialect: Dialect) bool {
    var index: usize = 0;
    var statement_start = true;
    var saw_create = false;
    var trigger_statement = false;
    var sqlite_trigger_body_depth: ?usize = null;

    while (index < sql.len) {
        const c = sql[index];

        if (isSpace(c)) {
            index += 1;
            continue;
        }
        if (c == '-' and lineCommentAt(sql, index)) {
            index = skipLineComment(sql, index);
            continue;
        }
        if (c == '/' and blockCommentAt(sql, index)) {
            index = skipBlockComment(sql, index, dialect == .postgres) orelse return false;
            continue;
        }
        if (c == ';') {
            // SQLite trigger statements contain separators inside BEGIN/END,
            // so body depth survives those inner semicolons.
            if (sqlite_trigger_body_depth == null) {
                statement_start = true;
                saw_create = false;
                trigger_statement = false;
            }
            index += 1;
            continue;
        }

        if (c == '\'') {
            index = skipSingleQuoted(sql, index);
            statement_start = false;
            continue;
        }
        if (c == '"') {
            index = skipDelimited(sql, index, '"');
            statement_start = false;
            continue;
        }
        if (c == '`') {
            index = skipDelimited(sql, index, '`');
            statement_start = false;
            continue;
        }
        if (c == '[') {
            index = skipBracketIdentifier(sql, index);
            statement_start = false;
            continue;
        }
        if (c == '$') {
            if (dollarQuoteTagAt(sql, index)) |tag_end| {
                index = skipDollarQuoted(sql, index, tag_end) orelse return false;
                statement_start = false;
                continue;
            }
        }
        if (!isIdentifierStart(c)) {
            statement_start = false;
            index += 1;
            continue;
        }

        const token_end = identifierEnd(sql, index);
        const word = sql[index..token_end];
        if (saw_create and eqlWord(word, "trigger")) trigger_statement = true;

        // PostgreSQL permits a backslash to escape the closing quote only in
        // explicitly prefixed escape strings; ordinary strings treat it literally.
        if (dialect == .postgres and eqlWord(word, "e") and
            token_end < sql.len and sql[token_end] == '\'')
        {
            index = skipPostgresEscapeString(sql, token_end);
            statement_start = false;
            continue;
        }

        if (sqlite_trigger_body_depth) |depth| {
            if (eqlWord(word, "begin") or eqlWord(word, "case")) {
                sqlite_trigger_body_depth = depth + 1;
            } else if (eqlWord(word, "end")) {
                sqlite_trigger_body_depth = if (depth == 1) null else depth - 1;
            }
        } else if (statement_start and !trigger_statement) {
            if (transactionCommandAt(sql, index)) return true;
            if (eqlWord(word, "create")) saw_create = true;
            if (saw_create and eqlWord(word, "trigger")) trigger_statement = true;
        } else if (dialect == .sqlite and trigger_statement and eqlWord(word, "begin")) {
            sqlite_trigger_body_depth = 1;
        }

        index = token_end;
        statement_start = false;
    }

    return false;
}

pub fn ensureNoTransactionControl(sql: []const u8, dialect: Dialect) !void {
    if (containsTransactionControl(sql, dialect)) {
        return error.MigrationTransactionControlNotAllowed;
    }
}

/// Validate that a migration plan is a strict, complete continuation of the
/// applied history. Plans must be sorted by increasing version with no
/// duplicates, every applied version must remain resolvable, and a pending
/// migration may not be inserted below the highest applied version.
///
/// `records` may be any slice whose elements expose a `version: u64` field.
pub fn validatePlan(migrations: []const MigrationFile, records: anytype) !void {
    var previous_migration: ?u64 = null;
    for (migrations) |migration| {
        if (previous_migration) |previous| {
            if (migration.id.version <= previous) return error.MigrationVersionConflict;
        }
        previous_migration = migration.id.version;
    }

    var previous_record: ?u64 = null;
    for (records, 0..) |record, index| {
        if (previous_record) |previous| {
            if (record.version <= previous) return error.MigrationVersionConflict;
        }
        // Applied history must be an exact prefix of the supplied plan. This
        // simultaneously rejects missing applied files and pending versions
        // inserted below already-applied history in O(plan + history) time.
        if (index >= migrations.len or migrations[index].id.version != record.version) {
            return error.MigrationVersionConflict;
        }
        previous_record = record.version;
    }
}

fn isValidName(name: []const u8) bool {
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn identifierEnd(sql: []const u8, start: usize) usize {
    var index = start;
    while (index < sql.len and isIdentifierChar(sql[index])) index += 1;
    return index;
}

fn eqlWord(word: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, expected);
}

fn startsKeyword(sql: []const u8, start: usize, keyword: []const u8) ?usize {
    const end = start + keyword.len;
    if (end > sql.len or !std.ascii.eqlIgnoreCase(sql[start..end], keyword)) return null;
    if (end < sql.len and isIdentifierChar(sql[end])) return null;
    return end;
}

fn separatorEnd(sql: []const u8, start: usize) ?usize {
    var index = start;
    while (index < sql.len) {
        const c = sql[index];
        if (isSpace(c)) {
            index += 1;
        } else if (c == '-' and lineCommentAt(sql, index)) {
            index = skipLineComment(sql, index);
        } else if (c == '/' and blockCommentAt(sql, index)) {
            index = skipBlockComment(sql, index, true) orelse return null;
        } else break;
    }
    if (index >= sql.len or index == start) return null;
    return index;
}

fn twoKeywordAt(sql: []const u8, start: usize, first: []const u8, second: []const u8) bool {
    const after_first = startsKeyword(sql, start, first) orelse return false;
    const after_separator = separatorEnd(sql, after_first) orelse return false;
    return startsKeyword(sql, after_separator, second) != null;
}

fn transactionCommandAt(sql: []const u8, start: usize) bool {
    const single_commands = [_][]const u8{
        "begin",   "commit", "rollback", "savepoint",
        "release", "abort",  "end",
    };
    for (single_commands) |command| {
        if (startsKeyword(sql, start, command) != null) return true;
    }
    if (twoKeywordAt(sql, start, "start", "transaction")) return true;
    return twoKeywordAt(sql, start, "prepare", "transaction");
}

fn lineCommentAt(sql: []const u8, start: usize) bool {
    return start + 1 < sql.len and sql[start + 1] == '-';
}

fn blockCommentAt(sql: []const u8, start: usize) bool {
    return start + 1 < sql.len and sql[start + 1] == '*';
}

fn skipLineComment(sql: []const u8, start: usize) usize {
    const newline = std.mem.indexOfScalarPos(u8, sql, start + 2, '\n') orelse return sql.len;
    return newline + 1;
}

fn skipBlockComment(sql: []const u8, start: usize, nested: bool) ?usize {
    var index = start + 2;
    var depth: usize = 1;
    while (index < sql.len) {
        if (nested and sql[index] == '/' and blockCommentAt(sql, index)) {
            depth += 1;
            index += 2;
        } else if (sql[index] == '*' and index + 1 < sql.len and sql[index + 1] == '/') {
            depth -= 1;
            index += 2;
            if (depth == 0) return index;
        } else {
            index += 1;
        }
    }
    return null;
}

fn skipSingleQuoted(sql: []const u8, start: usize) usize {
    return skipDelimited(sql, start, '\'');
}

fn skipDelimited(sql: []const u8, start: usize, delimiter: u8) usize {
    var index = start + 1;
    while (index < sql.len) {
        if (sql[index] != delimiter) {
            index += 1;
            continue;
        }
        if (index + 1 < sql.len and sql[index + 1] == delimiter) {
            index += 2;
            continue;
        }
        return index + 1;
    }
    return sql.len;
}

fn skipBracketIdentifier(sql: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < sql.len) {
        if (sql[index] != ']') {
            index += 1;
            continue;
        }
        if (index + 1 < sql.len and sql[index + 1] == ']') {
            index += 2;
            continue;
        }
        return index + 1;
    }
    return sql.len;
}

fn dollarQuoteTagAt(sql: []const u8, start: usize) ?usize {
    var index = start + 1;
    if (index < sql.len and sql[index] == '$') return index;
    if (index >= sql.len) return null;
    if (!isIdentifierStart(sql[index])) return null;
    while (index < sql.len and isDollarTagChar(sql[index])) index += 1;
    if (index < sql.len and sql[index] == '$') return index;
    return null;
}

fn isDollarTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipPostgresEscapeString(sql: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < sql.len) {
        if (sql[index] == '\'') {
            if (index + 1 < sql.len and sql[index + 1] == '\'') {
                index += 2;
                continue;
            }
            return index + 1;
        }
        if (sql[index] == '\\' and index + 1 < sql.len) {
            index += 2;
            continue;
        }
        index += 1;
    }
    return sql.len;
}

fn skipDollarQuoted(sql: []const u8, start: usize, tag_end: usize) ?usize {
    const opener = sql[start .. tag_end + 1];
    const closer_index = std.mem.indexOfPos(u8, sql, tag_end + 1, opener) orelse return null;
    return closer_index + opener.len;
}

fn migrationFileLessThan(_: void, lhs: MigrationFile, rhs: MigrationFile) bool {
    if (lhs.id.version != rhs.id.version) return lhs.id.version < rhs.id.version;
    return std.mem.lessThan(u8, lhs.id.filename, rhs.id.filename);
}

test "dirty failure preserves original only after marker persistence" {
    const Recorder = struct {
        called: bool = false,
        failure: ?anyerror = null,

        fn persist(self: *@This(), _: MigrationFile) !void {
            self.called = true;
            if (self.failure) |err| return err;
        }
    };
    const migration: MigrationFile = .{
        .id = .{ .version = 1, .name = "broken", .filename = "V0001__broken.sql" },
        .checksum = undefined,
    };

    var recorded: Recorder = .{};
    try std.testing.expect(dirtyFailure(
        &recorded,
        migration,
        error.InvalidSql,
        Recorder.persist,
    ) == error.InvalidSql);
    try std.testing.expect(recorded.called);

    var failed: Recorder = .{ .failure = error.OutOfMemory };
    try std.testing.expect(dirtyFailure(
        &failed,
        migration,
        error.InvalidSql,
        Recorder.persist,
    ) == error.OutOfMemory);
    try std.testing.expect(failed.called);
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

    try std.testing.expectError(error.MigrationVersionConflict, scanDir(std.testing.allocator, std.testing.io, tmp.dir));
}

test "migration plan requires ordered unique complete history" {
    const Record = struct { version: u64 };
    const files = [_]MigrationFile{
        .{ .id = .{ .version = 1, .name = "one", .filename = "V0001__one.sql" }, .checksum = undefined },
        .{ .id = .{ .version = 2, .name = "two", .filename = "V0002__two.sql" }, .checksum = undefined },
        .{ .id = .{ .version = 3, .name = "three", .filename = "V0003__three.sql" }, .checksum = undefined },
    };

    try validatePlan(&files, &[_]Record{});
    try validatePlan(&files, &[_]Record{ .{ .version = 1 }, .{ .version = 2 } });
    try validatePlan(&files, &[_]Record{ .{ .version = 1 }, .{ .version = 2 }, .{ .version = 3 } });

    const duplicate = [_]MigrationFile{ files[0], files[0] };
    try std.testing.expectError(error.MigrationVersionConflict, validatePlan(&duplicate, &[_]Record{}));
    const descending = [_]MigrationFile{ files[1], files[0] };
    try std.testing.expectError(error.MigrationVersionConflict, validatePlan(&descending, &[_]Record{}));
    try std.testing.expectError(
        error.MigrationVersionConflict,
        validatePlan(&files, &[_]Record{.{ .version = 2 }}),
    );
    try std.testing.expectError(
        error.MigrationVersionConflict,
        validatePlan(files[1..], &[_]Record{.{ .version = 1 }}),
    );
    try std.testing.expectError(
        error.MigrationVersionConflict,
        validatePlan(&files, &[_]Record{ .{ .version = 1 }, .{ .version = 3 } }),
    );
    try std.testing.expectError(
        error.MigrationVersionConflict,
        validatePlan(&files, &[_]Record{ .{ .version = 2 }, .{ .version = 1 } }),
    );
}

test "migration transaction scanner accepts ordinary scripts and quoted words" {
    const accepted = [_][]const u8{
        "",
        "create table users (id integer primary key);\ninsert into users values (1);",
        "beginning",
        "committed",
        "prepare data as select 1",
        "select 'commit it''s beginning', \"rollback\", [end], `abort` from savepoints",
        "select 1 -- commit\nfrom transactions\n/* rollback */",
        "/* begin */ select 1;",
        "do $body$ begin perform 1; end $body$;",
    };

    for (accepted) |sql| {
        try std.testing.expect(!containsTransactionControl(sql, .sqlite));
        try std.testing.expect(!containsTransactionControl(sql, .postgres));
    }
}

test "migration transaction scanner understands PostgreSQL lexical boundaries" {
    const accepted = [_][]const u8{
        "select $1, $body$ commit $body$",
        "select $$begin$$",
        "select $route_2$ rollback to savepoint $route_2$",
        "select e'commit\\'s beginning';",
        "select E'escaped \\' ; commit; select '''",
    };

    for (accepted) |sql| {
        try std.testing.expect(!containsTransactionControl(sql, .postgres));
    }
    const escaped = "select E'escaped \\' ; commit; select '''";
    try std.testing.expect(!containsTransactionControl(escaped, .postgres));
    try std.testing.expect(containsTransactionControl(escaped, .sqlite));
    try std.testing.expect(containsTransactionControl(
        "select e'ordinary quote' from t; commit",
        .sqlite,
    ));
}

test "migration transaction scanner accepts SQLite trigger bodies" {
    const sql =
        \\create trigger users_audit
        \\after insert on users
        \\begin
        \\  insert into audit (name) values (new.name);
        \\  insert into snapshots (value)
        \\  values (case when new.id > 0 then new.id else 0 end);
        \\end
    ;

    try std.testing.expect(!containsTransactionControl(sql, .sqlite));
    try std.testing.expect(containsTransactionControl(sql ++ "; commit;", .sqlite));
}

test "migration transaction scanner rejects leading command controls" {
    const rejected = [_]struct { sql: []const u8, dialect: Dialect }{
        .{ .sql = "begin", .dialect = .sqlite },
        .{ .sql = "BEGIN IMMEDIATE;", .dialect = .sqlite },
        .{ .sql = "start transaction", .dialect = .postgres },
        .{ .sql = "start /* dialect */ transaction", .dialect = .postgres },
        .{ .sql = "commit work", .dialect = .postgres },
        .{ .sql = "end transaction", .dialect = .sqlite },
        .{ .sql = "rollback to savepoint repair", .dialect = .postgres },
        .{ .sql = "savepoint before_change", .dialect = .sqlite },
        .{ .sql = "release savepoint before_change", .dialect = .postgres },
        .{ .sql = "abort", .dialect = .postgres },
        .{ .sql = "prepare transaction 'pending'", .dialect = .postgres },
        .{ .sql = "/* explain */ commit", .dialect = .sqlite },
        .{ .sql = "create table ready (id integer); commit;", .dialect = .sqlite },
        .{ .sql = "create table ready (id integer); rollback;", .dialect = .postgres },
    };

    for (rejected) |case| {
        try std.testing.expect(containsTransactionControl(case.sql, case.dialect));
        try std.testing.expectError(
            error.MigrationTransactionControlNotAllowed,
            ensureNoTransactionControl(case.sql, case.dialect),
        );
    }
}
