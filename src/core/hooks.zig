const std = @import("std");
const DriverKind = @import("db_error.zig").DriverKind;
const ErrorCategory = @import("db_error.zig").ErrorCategory;
const DbError = @import("db_error.zig").DbError;

/// Emitted immediately before a statement is sent to the driver.
///
/// `sql` is the statement text only — never bind parameter values.
pub const QueryStart = struct {
    driver: DriverKind,
    sql: []const u8,
    /// Number of bind slots the caller supplied (0 for non-parameterized paths).
    bind_count: usize = 0,
};

/// Emitted after a statement finishes (success or failure).
///
/// `sql` is never redacted beyond excluding bind values (binds are never present).
pub const QueryEnd = struct {
    driver: DriverKind,
    sql: []const u8,
    duration_ns: u64 = 0,
    rows_affected: ?u64 = null,
    /// Set when the operation returned an error; never includes bind values.
    err: ?ErrorCategory = null,
};

/// Optional, connection-local observability hooks.
///
/// There is no global registry. Callers attach hooks to a connection (or copy
/// them into pool-created connections). Hooks must not panic, block indefinitely,
/// or throw Zig errors.
pub const Hooks = struct {
    /// Opaque user context passed to every callback.
    ctx: ?*anyopaque = null,
    before_query: ?*const fn (ctx: ?*anyopaque, start: QueryStart) void = null,
    after_query: ?*const fn (ctx: ?*anyopaque, end: QueryEnd) void = null,

    pub fn isEmpty(self: Hooks) bool {
        return self.before_query == null and self.after_query == null;
    }

    pub fn emitBefore(self: Hooks, start: QueryStart) void {
        if (self.before_query) |f| f(self.ctx, start);
    }

    pub fn emitAfter(self: Hooks, end: QueryEnd) void {
        if (self.after_query) |f| f(self.ctx, end);
    }
};

/// Best-effort monotonic nanoseconds for duration measurement.
/// Avoids libc; may report 0 under constrained hosts.
pub fn monoNs() u64 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(0, ts.nanoseconds));
}

pub fn durationSince(start_ns: u64) u64 {
    const now = monoNs();
    if (now < start_ns) return 0;
    return now - start_ns;
}

pub fn categoryOfErr(err: anyerror) ErrorCategory {
    return DbError.categoryOf(err);
}

test "Hooks isEmpty and no-op callbacks" {
    const empty: Hooks = .{};
    try std.testing.expect(empty.isEmpty());
    empty.emitBefore(.{ .driver = .sqlite, .sql = "select 1" });
    empty.emitAfter(.{ .driver = .sqlite, .sql = "select 1" });

    const State = struct {
        before: usize = 0,
        after: usize = 0,
        last_sql: []const u8 = "",
        last_binds: usize = 0,
    };
    var state: State = .{};
    const hooks = Hooks{
        .ctx = &state,
        .before_query = struct {
            fn f(ctx: ?*anyopaque, start: QueryStart) void {
                const s: *State = @ptrCast(@alignCast(ctx.?));
                s.before += 1;
                s.last_sql = start.sql;
                s.last_binds = start.bind_count;
            }
        }.f,
        .after_query = struct {
            fn f(ctx: ?*anyopaque, end: QueryEnd) void {
                const s: *State = @ptrCast(@alignCast(ctx.?));
                s.after += 1;
                _ = end;
            }
        }.f,
    };
    try std.testing.expect(!hooks.isEmpty());
    hooks.emitBefore(.{ .driver = .postgres, .sql = "select $1", .bind_count = 1 });
    hooks.emitAfter(.{ .driver = .postgres, .sql = "select $1", .duration_ns = 10, .rows_affected = 0 });
    try std.testing.expectEqual(@as(usize, 1), state.before);
    try std.testing.expectEqual(@as(usize, 1), state.after);
    try std.testing.expectEqualStrings("select $1", state.last_sql);
    try std.testing.expectEqual(@as(usize, 1), state.last_binds);
}

test "categoryOfErr maps known errors" {
    try std.testing.expect(categoryOfErr(error.UniqueViolation) == .constraint);
    try std.testing.expect(categoryOfErr(error.QueryTimeout) == .connection);
}
