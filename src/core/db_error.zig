const std = @import("std");
const Error = @import("error.zig").Error;

pub const DriverKind = enum {
    sqlite,
    postgres,
    unknown,
};

pub const ErrorCategory = enum {
    driver,
    invalid_sql,
    invalid_arguments,
    type_mismatch,
    connection,
    auth,
    protocol,
    constraint,
    transaction,
    migration,
    pool,
    unsupported,
    other,
};

/// Rich database error metadata. String fields are borrowed and valid only for
/// the lifetime of the owning connection/message buffer unless duplicated by
/// the caller (see `OwnedDbError`).
///
/// zsql never copies bind arguments into this object. Database-provided
/// diagnostic fields such as `detail` may themselves quote stored/input data.
pub const DbError = struct {
    category: ErrorCategory,
    driver: DriverKind,
    code: ?[]const u8 = null,
    message: []const u8 = "",
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    constraint: ?[]const u8 = null,
    sql: ?[]const u8 = null,

    /// Default formatter suitable for logs. This intentionally omits
    /// `message`, `detail`, `hint`, and `sql`: databases may echo stored or
    /// bound data in diagnostics, and SQL text may contain caller-written
    /// literals. Use `formatSensitive` only at an explicit trusted boundary.
    pub fn format(self: DbError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.formatSafe(writer);
    }

    /// Write a redacted diagnostic summary. Retained metadata is escaped so a
    /// server-controlled identifier cannot inject extra log lines.
    pub fn formatSafe(self: DbError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "DbError{{ driver={s}, category={s}",
            .{ @tagName(self.driver), @tagName(self.category) },
        );
        try writeOptionalField(writer, "code", self.code);
        try writeOptionalField(writer, "schema", self.schema);
        try writeOptionalField(writer, "table", self.table);
        try writeOptionalField(writer, "column", self.column);
        try writeOptionalField(writer, "constraint", self.constraint);
        try writer.writeAll(" }");
    }

    /// Write all available diagnostics, including fields that may contain
    /// stored/input data or SQL literals. The output is escaped for one-line
    /// logging, but it is not redacted.
    pub fn formatSensitive(self: DbError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "DbError{{ driver={s}, category={s}",
            .{ @tagName(self.driver), @tagName(self.category) },
        );
        try writeOptionalField(writer, "code", self.code);
        try writeField(writer, "message", self.message);
        try writeOptionalField(writer, "detail", self.detail);
        try writeOptionalField(writer, "hint", self.hint);
        try writeOptionalField(writer, "schema", self.schema);
        try writeOptionalField(writer, "table", self.table);
        try writeOptionalField(writer, "column", self.column);
        try writeOptionalField(writer, "constraint", self.constraint);
        try writeOptionalField(writer, "sql", self.sql);
        try writer.writeAll(" }");
    }

    pub fn fromZigError(err: anyerror, driver: DriverKind) DbError {
        return .{
            .category = categoryOf(err),
            .driver = driver,
            .message = @errorName(err),
        };
    }

    pub fn categoryOf(err: anyerror) ErrorCategory {
        return switch (err) {
            error.InvalidSql, error.InvalidMigrationFilename => .invalid_sql,
            error.InvalidArguments, error.InvalidBindValue, error.BindCountMismatch, error.InvalidUrl => .invalid_arguments,
            error.TypeMismatch, error.InvalidColumnType, error.InvalidColumn, error.UnexpectedNull, error.IntegerOverflow => .type_mismatch,
            error.ConnectionClosed, error.ConnectionBusy, error.ConnectionTimeout, error.QueryTimeout => .connection,
            error.AuthFailed, error.TlsFailed => .auth,
            error.ProtocolError => .protocol,
            error.ConstraintViolation,
            error.UniqueViolation,
            error.ForeignKeyViolation,
            error.NotNullViolation,
            error.CheckViolation,
            => .constraint,
            error.TransactionClosed,
            error.TransactionAborted,
            error.SavepointClosed,
            error.SerializationFailure,
            error.DeadlockDetected,
            => .transaction,
            error.MigrationChecksumMismatch, error.MigrationDirty, error.MigrationNotFound, error.MigrationNotDirty, error.DirtyMigration, error.MigrationVersionConflict, error.DuplicateMigrationVersion => .migration,
            error.PoolClosed, error.PoolExhausted, error.PoolTimeout, error.LeaseClosed => .pool,
            error.Busy, error.Locked => .connection,
            error.Unsupported => .unsupported,
            error.DriverUnavailable, error.DriverError, error.UnexpectedRow, error.StatementClosed, error.NoRows, error.TooManyRows => .driver,
            else => .other,
        };
    }

    /// Map a PostgreSQL SQLSTATE to a zsql error.
    pub fn errorFromSqlState(code: []const u8) anyerror {
        if (code.len < 2) return error.DriverError;
        // Specific codes first.
        if (std.mem.eql(u8, code, "23505")) return error.UniqueViolation;
        if (std.mem.eql(u8, code, "23503")) return error.ForeignKeyViolation;
        if (std.mem.eql(u8, code, "23502")) return error.NotNullViolation;
        if (std.mem.eql(u8, code, "23514")) return error.CheckViolation;
        if (std.mem.eql(u8, code, "25P02")) return error.TransactionAborted;
        if (std.mem.eql(u8, code, "40001")) return error.SerializationFailure;
        if (std.mem.eql(u8, code, "40P01")) return error.DeadlockDetected;
        if (std.mem.eql(u8, code, "55P03")) return error.Locked;
        if (std.mem.eql(u8, code, "28P01") or std.mem.eql(u8, code, "28000")) return error.AuthFailed;
        if (std.mem.eql(u8, code, "42601") or std.mem.eql(u8, code, "42P01") or std.mem.eql(u8, code, "42703"))
            return error.InvalidSql;
        if (std.mem.eql(u8, code, "08000") or std.mem.eql(u8, code, "08003") or std.mem.eql(u8, code, "08006"))
            return error.ConnectionClosed;
        if (std.mem.eql(u8, code, "57P01")) return error.ConnectionClosed;
        // query_canceled / statement_timeout
        if (std.mem.eql(u8, code, "57014")) return error.QueryTimeout;
        if (std.mem.eql(u8, code, "53300")) return error.PoolExhausted;
        // Class 22: data exception
        if (std.mem.startsWith(u8, code, "22")) return error.TypeMismatch;
        // Class 23: integrity constraint
        if (std.mem.startsWith(u8, code, "23")) return error.ConstraintViolation;
        // Class 08: connection
        if (std.mem.startsWith(u8, code, "08")) return error.ConnectionClosed;
        // Class 28: invalid auth
        if (std.mem.startsWith(u8, code, "28")) return error.AuthFailed;
        // Class 40: transaction rollback
        if (std.mem.startsWith(u8, code, "40")) return error.SerializationFailure;
        // Class 42: syntax/access
        if (std.mem.startsWith(u8, code, "42")) return error.InvalidSql;
        // Class 55: object not in prerequisite state (lock not available, etc.)
        if (std.mem.startsWith(u8, code, "55")) return error.Busy;
        return error.DriverError;
    }
};

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try writer.print(", {s}=\"{f}\"", .{ name, std.zig.fmtString(value) });
}

fn writeOptionalField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: ?[]const u8,
) std.Io.Writer.Error!void {
    if (value) |present| try writeField(writer, name, present);
}

/// Allocator-owned copy of `DbError` string fields for connection-level storage.
///
/// Connections use this for their diagnostic storage. `Conn.lastError()`
/// returns a borrowed view; callers that need an independent lifetime can use
/// `Conn.lastErrorOwned()` or `OwnedDbError.from()`. zsql never copies bind
/// arguments into this storage; database-provided diagnostic text may itself
/// quote stored/input data.
pub const OwnedDbError = struct {
    category: ErrorCategory,
    driver: DriverKind,
    code: ?[]u8 = null,
    message: []u8,
    detail: ?[]u8 = null,
    hint: ?[]u8 = null,
    schema: ?[]u8 = null,
    table: ?[]u8 = null,
    column: ?[]u8 = null,
    constraint: ?[]u8 = null,
    sql: ?[]u8 = null,

    /// Default redacted formatter; equivalent to formatting `view()`.
    pub fn format(self: *const OwnedDbError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.view().formatSafe(writer);
    }

    pub fn formatSafe(self: *const OwnedDbError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.view().formatSafe(writer);
    }

    /// Explicitly include all owned diagnostic fields. See
    /// `DbError.formatSensitive` for the sensitivity contract.
    pub fn formatSensitive(self: *const OwnedDbError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.view().formatSensitive(writer);
    }

    pub fn deinit(self: *OwnedDbError, allocator: std.mem.Allocator) void {
        if (self.code) |v| allocator.free(v);
        allocator.free(self.message);
        if (self.detail) |v| allocator.free(v);
        if (self.hint) |v| allocator.free(v);
        if (self.schema) |v| allocator.free(v);
        if (self.table) |v| allocator.free(v);
        if (self.column) |v| allocator.free(v);
        if (self.constraint) |v| allocator.free(v);
        if (self.sql) |v| allocator.free(v);
        self.* = undefined;
    }

    /// Borrowed view valid until the next error is stored or this is deinited.
    pub fn view(self: *const OwnedDbError) DbError {
        return .{
            .category = self.category,
            .driver = self.driver,
            .code = self.code,
            .message = self.message,
            .detail = self.detail,
            .hint = self.hint,
            .schema = self.schema,
            .table = self.table,
            .column = self.column,
            .constraint = self.constraint,
            .sql = self.sql,
        };
    }

    /// Deep-copy borrowed database diagnostics with an explicit allocator.
    /// The returned value is independent of the originating connection and
    /// must be released with `deinit` using the same allocator.
    pub fn from(allocator: std.mem.Allocator, source: DbError) !OwnedDbError {
        var owned: OwnedDbError = .{
            .category = source.category,
            .driver = source.driver,
            .message = try allocator.dupe(u8, source.message),
        };
        errdefer owned.deinit(allocator);

        if (source.code) |v| owned.code = try allocator.dupe(u8, v);
        if (source.detail) |v| owned.detail = try allocator.dupe(u8, v);
        if (source.hint) |v| owned.hint = try allocator.dupe(u8, v);
        if (source.schema) |v| owned.schema = try allocator.dupe(u8, v);
        if (source.table) |v| owned.table = try allocator.dupe(u8, v);
        if (source.column) |v| owned.column = try allocator.dupe(u8, v);
        if (source.constraint) |v| owned.constraint = try allocator.dupe(u8, v);
        if (source.sql) |v| owned.sql = try allocator.dupe(u8, v);
        return owned;
    }

    /// Duplicate optional string fields from a PostgreSQL ErrorResponse map.
    pub fn fromPostgresFields(
        allocator: std.mem.Allocator,
        fields: PostgresErrorFields,
        zig_err: anyerror,
        sql: ?[]const u8,
    ) !OwnedDbError {
        return from(allocator, .{
            .category = DbError.categoryOf(zig_err),
            .driver = .postgres,
            .code = fields.code,
            .message = fields.message orelse @errorName(zig_err),
            .detail = fields.detail,
            .hint = fields.hint,
            .schema = fields.schema,
            .table = fields.table,
            .column = fields.column,
            .constraint = fields.constraint,
            .sql = sql,
        });
    }
};

/// Duck-typed field map matching `protocol.ErrorFields` without importing the driver.
pub const PostgresErrorFields = struct {
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    constraint: ?[]const u8 = null,
};

test "category mapping covers core errors" {
    try std.testing.expect(DbError.categoryOf(error.ConstraintViolation) == .constraint);
    try std.testing.expect(DbError.categoryOf(error.UniqueViolation) == .constraint);
    try std.testing.expect(DbError.categoryOf(error.DeadlockDetected) == .transaction);
    try std.testing.expect(DbError.categoryOf(error.TransactionAborted) == .transaction);
    try std.testing.expect(DbError.categoryOf(error.AuthFailed) == .auth);
    try std.testing.expect(DbError.categoryOf(error.PoolTimeout) == .pool);
    try std.testing.expect(DbError.categoryOf(error.QueryTimeout) == .connection);
}

test "sqlstate mapping" {
    try std.testing.expect(DbError.errorFromSqlState("23505") == error.UniqueViolation);
    try std.testing.expect(DbError.errorFromSqlState("23503") == error.ForeignKeyViolation);
    try std.testing.expect(DbError.errorFromSqlState("23502") == error.NotNullViolation);
    try std.testing.expect(DbError.errorFromSqlState("23514") == error.CheckViolation);
    try std.testing.expect(DbError.errorFromSqlState("25P02") == error.TransactionAborted);
    try std.testing.expect(DbError.errorFromSqlState("40001") == error.SerializationFailure);
    try std.testing.expect(DbError.errorFromSqlState("40P01") == error.DeadlockDetected);
    try std.testing.expect(DbError.errorFromSqlState("28P01") == error.AuthFailed);
    try std.testing.expect(DbError.errorFromSqlState("42601") == error.InvalidSql);
    try std.testing.expect(DbError.errorFromSqlState("22003") == error.TypeMismatch);
    try std.testing.expect(DbError.errorFromSqlState("08006") == error.ConnectionClosed);
    try std.testing.expect(DbError.errorFromSqlState("57014") == error.QueryTimeout);
}

test "OwnedDbError duplicates postgres fields without secrets" {
    const fields = PostgresErrorFields{
        .code = "23505",
        .message = "duplicate key value violates unique constraint",
        .detail = "Key (email)=(ada@example.com) already exists.",
        .hint = null,
        .table = "users",
        .column = "email",
        .constraint = "users_email_key",
    };
    var owned = try OwnedDbError.fromPostgresFields(
        std.testing.allocator,
        fields,
        error.UniqueViolation,
        "insert into users (email) values ($1)",
    );
    defer owned.deinit(std.testing.allocator);

    const view = owned.view();
    try std.testing.expect(view.category == .constraint);
    try std.testing.expect(view.driver == .postgres);
    try std.testing.expectEqualStrings("23505", view.code.?);
    try std.testing.expectEqualStrings("users", view.table.?);
    try std.testing.expectEqualStrings("users_email_key", view.constraint.?);
    try std.testing.expectEqualStrings("insert into users (email) values ($1)", view.sql.?);
    // Message and detail are preserved verbatim and may echo a bound/stored
    // value; zsql itself never copies the caller's bind array into metadata.
    try std.testing.expect(std.mem.indexOf(u8, view.message, "duplicate") != null);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{&owned});
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "ada@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insert into") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "users_email_key") != null);
}

fn copyCompleteDbError(allocator: std.mem.Allocator) !void {
    const source: DbError = .{
        .category = .constraint,
        .driver = .sqlite,
        .code = "2067",
        .message = "UNIQUE constraint failed: users.email",
        .detail = "detail",
        .hint = "hint",
        .schema = "main",
        .table = "users",
        .column = "email",
        .constraint = "users_email_key",
        .sql = "insert into users (email) values (?)",
    };
    var owned = try OwnedDbError.from(allocator, source);
    defer owned.deinit(allocator);
}

test "OwnedDbError deep-copies borrowed diagnostics and cleans up on OOM" {
    var message = [_]u8{ 'd', 'u', 'p', 'l', 'i', 'c', 'a', 't', 'e' };
    var sql = [_]u8{ 's', 'e', 'l', 'e', 'c', 't', ' ', '?' };
    const source: DbError = .{
        .category = .constraint,
        .driver = .sqlite,
        .code = "2067",
        .message = &message,
        .table = "users",
        .column = "email",
        .sql = &sql,
    };
    var owned = try OwnedDbError.from(std.testing.allocator, source);
    defer owned.deinit(std.testing.allocator);

    message[0] = 'X';
    sql[0] = 'X';
    const view = owned.view();
    try std.testing.expectEqualStrings("duplicate", view.message);
    try std.testing.expectEqualStrings("select ?", view.sql.?);
    try std.testing.expectEqualStrings("users", view.table.?);
    try std.testing.expectEqualStrings("email", view.column.?);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyCompleteDbError, .{});
}

test "DbError default and safe formatting omit sensitive diagnostics" {
    const db_err: DbError = .{
        .category = .constraint,
        .driver = .postgres,
        .code = "23505",
        .message = "duplicate value super-secret",
        .detail = "Key (email)=(ada@example.com) already exists.",
        .hint = "retry with another secret",
        .table = "users\nforged-log-line",
        .constraint = "users_email_key",
        .sql = "insert into users values ('super-secret')",
    };

    var default_buffer: [512]u8 = undefined;
    var default_writer = std.Io.Writer.fixed(&default_buffer);
    try default_writer.print("{f}", .{db_err});
    const default_text = default_writer.buffered();

    try std.testing.expectEqualStrings(
        "DbError{ driver=postgres, category=constraint, code=\"23505\", table=\"users\\nforged-log-line\", constraint=\"users_email_key\" }",
        default_text,
    );
    try std.testing.expect(std.mem.indexOf(u8, default_text, "super-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_text, "ada@example.com") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, default_text, '\n') == null);

    var safe_buffer: [512]u8 = undefined;
    var safe_writer = std.Io.Writer.fixed(&safe_buffer);
    try db_err.formatSafe(&safe_writer);
    try std.testing.expectEqualStrings(default_text, safe_writer.buffered());
}

test "DbError sensitive formatting is explicit and escaped" {
    const db_err: DbError = .{
        .category = .invalid_sql,
        .driver = .sqlite,
        .code = "1",
        .message = "near secret\nsecond line",
        .sql = "select 'secret'",
    };

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try db_err.formatSensitive(&writer);
    const text = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "near secret\\nsecond line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "select 'secret'") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
}

// Keep Error import used for documentation of the dual error surface.
comptime {
    _ = Error;
}
