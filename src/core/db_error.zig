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
/// the caller.
///
/// Never includes bind parameter values.
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
            error.InvalidArguments, error.InvalidBindValue, error.InvalidUrl => .invalid_arguments,
            error.TypeMismatch, error.InvalidColumnType, error.InvalidColumn, error.UnexpectedNull, error.IntegerOverflow => .type_mismatch,
            error.ConnectionClosed, error.ConnectionBusy, error.ConnectionTimeout => .connection,
            error.AuthFailed, error.TlsFailed => .auth,
            error.ProtocolError => .protocol,
            error.ConstraintViolation => .constraint,
            error.TransactionClosed, error.SavepointClosed => .transaction,
            error.MigrationChecksumMismatch, error.DirtyMigration, error.DuplicateMigrationVersion => .migration,
            error.PoolClosed, error.PoolExhausted, error.PoolTimeout, error.LeaseClosed => .pool,
            error.Unsupported => .unsupported,
            error.DriverUnavailable, error.DriverError, error.UnexpectedRow, error.StatementClosed, error.NoRows, error.TooManyRows => .driver,
            else => .other,
        };
    }

    /// Map a PostgreSQL SQLSTATE to a zsql error.
    pub fn errorFromSqlState(code: []const u8) anyerror {
        if (code.len < 2) return error.DriverError;
        // Class-based mapping with common specific codes first.
        if (std.mem.eql(u8, code, "23505") or
            std.mem.eql(u8, code, "23503") or
            std.mem.eql(u8, code, "23502") or
            std.mem.eql(u8, code, "23514"))
            return error.ConstraintViolation;
        if (std.mem.eql(u8, code, "28P01") or std.mem.eql(u8, code, "28000")) return error.AuthFailed;
        if (std.mem.eql(u8, code, "42601") or std.mem.eql(u8, code, "42P01") or std.mem.eql(u8, code, "42703"))
            return error.InvalidSql;
        if (std.mem.eql(u8, code, "08000") or std.mem.eql(u8, code, "08003") or std.mem.eql(u8, code, "08006"))
            return error.ConnectionClosed;
        if (std.mem.eql(u8, code, "57P01")) return error.ConnectionClosed;
        if (std.mem.eql(u8, code, "40001") or std.mem.eql(u8, code, "40P01")) return error.DriverError;
        if (std.mem.eql(u8, code, "53300")) return error.PoolExhausted;
        // Class 22: data exception
        if (std.mem.startsWith(u8, code, "22")) return error.TypeMismatch;
        // Class 23: integrity constraint
        if (std.mem.startsWith(u8, code, "23")) return error.ConstraintViolation;
        // Class 08: connection
        if (std.mem.startsWith(u8, code, "08")) return error.ConnectionClosed;
        // Class 28: invalid auth
        if (std.mem.startsWith(u8, code, "28")) return error.AuthFailed;
        // Class 42: syntax/access
        if (std.mem.startsWith(u8, code, "42")) return error.InvalidSql;
        return error.DriverError;
    }
};

test "category mapping covers core errors" {
    try std.testing.expect(DbError.categoryOf(error.ConstraintViolation) == .constraint);
    try std.testing.expect(DbError.categoryOf(error.AuthFailed) == .auth);
    try std.testing.expect(DbError.categoryOf(error.PoolTimeout) == .pool);
}

test "sqlstate mapping" {
    try std.testing.expect(DbError.errorFromSqlState("23505") == error.ConstraintViolation);
    try std.testing.expect(DbError.errorFromSqlState("28P01") == error.AuthFailed);
    try std.testing.expect(DbError.errorFromSqlState("42601") == error.InvalidSql);
    try std.testing.expect(DbError.errorFromSqlState("22003") == error.TypeMismatch);
    try std.testing.expect(DbError.errorFromSqlState("08006") == error.ConnectionClosed);
}

// Keep Error import used for documentation of the dual error surface.
comptime {
    _ = Error;
}
