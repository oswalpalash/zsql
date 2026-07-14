const std = @import("std");
const core = @import("../../zsql.zig");
const conn_mod = @import("conn.zig");

pub const MigrationRecord = struct {
    version: u64,
    name: []u8,
    checksum: core.migrate.Checksum,
    applied_at: []u8,
    execution_ms: i64 = 0,
    dirty: bool,

    pub fn deinit(self: *MigrationRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.applied_at);
        self.* = undefined;
    }
};

pub const MigrationStatus = struct {
    allocator: std.mem.Allocator,
    records: []MigrationRecord,

    pub fn deinit(self: *MigrationStatus) void {
        for (self.records) |*record| record.deinit(self.allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

pub const ApplyResult = struct {
    applied: usize,
};

/// Session-level advisory lock key for zsql migrations.
/// Chosen as a fixed two-int key so concurrent migrators serialize applies
/// without blocking ordinary application traffic on `zsql_migrations` alone.
pub const advisory_lock_class: i32 = 0x7a73_716c; // "zsql"
pub const advisory_lock_id: i32 = 0x6d69_6772; // "migr"

/// PostgreSQL migrator bound to an open connection.
///
/// Uses the same Flyway-style files and checksum rules as SQLite. Concurrent
/// applies take `pg_advisory_lock` for the session, then run pending migrations
/// inside a single transaction with dirty markers.
pub const Migrator = struct {
    conn: *conn_mod.Conn,

    pub fn init(conn: *conn_mod.Conn) Migrator {
        return .{ .conn = conn };
    }

    pub fn ensureTable(self: Migrator) !void {
        _ = try self.conn.exec(
            \\create table if not exists zsql_migrations (
            \\  version bigint primary key,
            \\  name text not null,
            \\  checksum text not null,
            \\  applied_at timestamptz not null default now(),
            \\  execution_ms integer not null default 0,
            \\  dirty boolean not null default false
            \\)
        );
    }

    /// Acquire the session advisory lock used to serialize migration applies.
    /// Uses `queryParams` because `pg_advisory_lock` is invoked via SELECT.
    pub fn lock(self: Migrator) !void {
        // Once the query reaches PostgreSQL, a client-side allocation or
        // protocol failure can make lock ownership uncertain. Closing the
        // session is the only unconditional way to release a possibly-held
        // session advisory lock.
        errdefer self.conn.deinit();
        var rows = try self.conn.queryParams(
            "select pg_advisory_lock($1::int, $2::int)",
            &.{
                .{ .integer = advisory_lock_class },
                .{ .integer = advisory_lock_id },
            },
        );
        defer rows.deinit();
        // Function returns void; drain the single empty-ish result row if any.
        _ = rows.next() orelse return error.ProtocolError;
        if (rows.next() != null) return error.ProtocolError;
    }

    /// Release and verify the session advisory lock. Any failure closes the
    /// connection so uncertain ownership cannot strand the global lock.
    pub fn unlock(self: Migrator) !void {
        errdefer self.conn.deinit();
        var rows = try self.conn.queryParams(
            "select pg_advisory_unlock($1::int, $2::int) as unlocked",
            &.{
                .{ .integer = advisory_lock_class },
                .{ .integer = advisory_lock_id },
            },
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.ProtocolError;
        if (!try (try row.value("unlocked")).asBool()) return error.ProtocolError;
        if (rows.next() != null) return error.ProtocolError;
    }

    pub fn status(self: Migrator, allocator: std.mem.Allocator) !MigrationStatus {
        var rows = try self.conn.query(
            \\select version, name, checksum, applied_at::text as applied_at, dirty,
            \\  coalesce(execution_ms, 0) as execution_ms
            \\from zsql_migrations
            \\order by version
        );
        defer rows.deinit();

        var records: std.ArrayListUnmanaged(MigrationRecord) = .empty;
        errdefer {
            for (records.items) |*r| r.deinit(allocator);
            records.deinit(allocator);
        }

        while (rows.next()) |row| {
            const version = try unsignedVersion(try (try row.value("version")).asInt());
            const name = try allocator.dupe(u8, try (try row.value("name")).asText());
            errdefer allocator.free(name);
            const checksum = try parseChecksum(try (try row.value("checksum")).asText());
            const applied_at = try allocator.dupe(u8, try (try row.value("applied_at")).asText());
            errdefer allocator.free(applied_at);
            const dirty = try (try row.value("dirty")).asBool();
            const execution_ms = (try row.value("execution_ms")).asInt() catch 0;
            try records.append(allocator, .{
                .version = version,
                .name = name,
                .checksum = checksum,
                .applied_at = applied_at,
                .execution_ms = execution_ms,
                .dirty = dirty,
            });
        }

        return .{
            .allocator = allocator,
            .records = try records.toOwnedSlice(allocator),
        };
    }

    pub fn validate(self: Migrator, migrations: []const core.migrate.MigrationFile) !void {
        var st = try self.status(self.conn.allocator);
        defer st.deinit();
        for (st.records) |record| if (record.dirty) return error.MigrationDirty;
        try core.migrate.validatePlan(migrations, st.records);
        for (st.records, 0..) |record, index| {
            const migration = migrations[index];
            if (!std.mem.eql(u8, record.name, migration.id.name)) {
                return error.MigrationVersionConflict;
            }
            if (!std.mem.eql(u8, &record.checksum, &migration.checksum)) {
                return error.MigrationChecksumMismatch;
            }
        }
    }

    pub fn apply(self: Migrator, migrations: []const core.migrate.MigrationFile) !ApplyResult {
        try self.ensureTable();
        try self.lock();
        var lock_held = true;
        defer if (lock_held) self.unlock() catch {};

        // Re-validate under the lock so concurrent migrators see each other's work.
        try self.validate(migrations);

        var st = try self.status(self.conn.allocator);
        defer st.deinit();

        var active_migration: ?core.migrate.MigrationFile = null;
        const result = self.applyTransaction(migrations, st.records, &active_migration) catch |apply_err| {
            if (active_migration) |migration| {
                return core.migrate.dirtyFailure(
                    self,
                    migration,
                    apply_err,
                    Migrator.persistDirty,
                );
            }
            return apply_err;
        };
        self.unlock() catch |err| {
            lock_held = false;
            return err;
        };
        lock_held = false;
        return result;
    }

    fn applyTransaction(
        self: Migrator,
        migrations: []const core.migrate.MigrationFile,
        records: []const MigrationRecord,
        active_migration: *?core.migrate.MigrationFile,
    ) !ApplyResult {
        try self.conn.begin();
        errdefer self.conn.rollbackIfOpen();

        var applied: usize = 0;
        for (migrations) |migration| {
            if (findRecord(records, migration.id.version) != null) continue;
            active_migration.* = migration;
            if (std.mem.trim(u8, migration.sql, " \t\r\n").len == 0) return error.InvalidSql;

            // Mark dirty before executing migration SQL.
            _ = try self.conn.execParams(
                \\insert into zsql_migrations (version, name, checksum, dirty)
                \\values ($1, $2, $3, true)
            ,
                &.{
                    .{ .integer = try toI64(migration.id.version) },
                    .{ .text = migration.id.name },
                    .{ .text = &migration.checksum },
                },
            );

            // Migration SQL is trusted file content (not user values).
            const started_ms = nowMs(self.conn.io);
            _ = try self.conn.exec(migration.sql);
            const elapsed_ms: i64 = @max(0, nowMs(self.conn.io) - started_ms);

            _ = try self.conn.execParams(
                \\update zsql_migrations
                \\set dirty = false, applied_at = now(), execution_ms = $1
                \\where version = $2
            ,
                &.{
                    .{ .integer = elapsed_ms },
                    .{ .integer = try toI64(migration.id.version) },
                },
            );
            active_migration.* = null;
            applied += 1;
        }

        try self.conn.commit();
        return .{ .applied = applied };
    }

    fn persistDirty(self: Migrator, migration: core.migrate.MigrationFile) !void {
        _ = try self.conn.execParams(
            \\insert into zsql_migrations (version, name, checksum, dirty)
            \\values ($1, $2, $3, true)
            \\on conflict(version) do update set
            \\  name = excluded.name,
            \\  checksum = excluded.checksum,
            \\  dirty = true
        , &.{
            .{ .integer = try toI64(migration.id.version) },
            .{ .text = migration.id.name },
            .{ .text = &migration.checksum },
        });
    }

    /// Remove one dirty history row only when version and checksum match.
    /// This never marks a migration clean; callers must rerun repaired SQL.
    pub fn repairDirty(self: Migrator, version: u64, expected_checksum: core.migrate.Checksum) !void {
        try self.ensureTable();
        try self.lock();
        var lock_held = true;
        defer if (lock_held) self.unlock() catch {};

        try self.conn.begin();
        errdefer self.conn.rollbackIfOpen();

        var record = self.conn.queryOneParams(
            "select checksum, dirty from zsql_migrations where version = $1 for update",
            &.{.{ .integer = try toI64(version) }},
        ) catch |err| switch (err) {
            error.NoRows => return error.MigrationNotFound,
            else => return err,
        };
        defer record.deinit();
        const stored_checksum = try parseChecksum(try (try record.getName("checksum")).asText());
        if (!try (try record.getName("dirty")).asBool()) return error.MigrationNotDirty;
        if (!std.mem.eql(u8, &stored_checksum, &expected_checksum)) return error.MigrationChecksumMismatch;

        const result = try self.conn.execParams(
            "delete from zsql_migrations where version = $1 and checksum = $2 and dirty = true",
            &.{
                .{ .integer = try toI64(version) },
                .{ .text = &expected_checksum },
            },
        );
        if (result.rows_affected != 1) return error.MigrationVersionConflict;
        try self.conn.commit();
        self.unlock() catch |err| {
            lock_held = false;
            return err;
        };
        lock_held = false;
    }

    /// Alias for `apply` matching the public API target (`Migrator.up`).
    pub fn up(self: Migrator, migrations: []const core.migrate.MigrationFile) !ApplyResult {
        return self.apply(migrations);
    }
};

fn findMigration(migrations: []const core.migrate.MigrationFile, version: u64) ?core.migrate.MigrationFile {
    for (migrations) |m| {
        if (m.id.version == version) return m;
    }
    return null;
}

fn findRecord(records: []const MigrationRecord, version: u64) ?MigrationRecord {
    for (records) |r| {
        if (r.version == version) return r;
    }
    return null;
}

fn unsignedVersion(value: i64) !u64 {
    return std.math.cast(u64, value) orelse error.InvalidColumnType;
}

fn toI64(version: u64) !i64 {
    return std.math.cast(i64, version) orelse error.InvalidBindValue;
}

fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

fn parseChecksum(value: []const u8) !core.migrate.Checksum {
    if (value.len != @sizeOf(core.migrate.Checksum)) return error.InvalidColumnType;
    var checksum: core.migrate.Checksum = undefined;
    @memcpy(&checksum, value);
    return checksum;
}

test "postgres migrate checksum parse length" {
    const sql = "create table t (id int);\n";
    const checksum = core.migrate.checksumSql(sql);
    const parsed = try parseChecksum(&checksum);
    try std.testing.expectEqual(checksum, parsed);
}

test "advisory lock keys are stable non-zero" {
    try std.testing.expect(advisory_lock_class != 0);
    try std.testing.expect(advisory_lock_id != 0);
}
