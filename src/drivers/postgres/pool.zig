const std = @import("std");
const core = @import("../../zsql.zig");
const url = @import("url.zig");
const conn_mod = @import("conn.zig");

const Io = std.Io;

pub const PoolConfig = struct {
    database: url.Config,
    max_open: usize = 4,
    max_idle: usize = 4,
    /// Nanoseconds to wait when the pool is exhausted before `PoolTimeout`.
    /// Zero means non-blocking `PoolExhausted`. Waiters poll in ≤1ms slices so
    /// a concurrent release unblocks them promptly.
    acquire_timeout_ns: u64 = 0,
};

pub const PoolStats = struct {
    open: usize,
    idle: usize,
    leased: usize,
    max_open: usize,
    max_idle: usize,
    acquire_timeout_ns: u64,
};

/// Thread-safe PostgreSQL connection pool.
///
/// Connections are established with `Conn.open` using the pool's `Io` and
/// config. Leases must be released or discarded before `Pool.deinit`.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: PoolConfig,
    idle: std.ArrayListUnmanaged(conn_mod.Conn) = .empty,
    open_count: usize = 0,
    closed: bool = false,
    mutex: Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: PoolConfig) !Pool {
        if (config.max_open == 0) return error.InvalidArguments;
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        std.debug.assert(self.open_count == self.idle.items.len);
        for (self.idle.items) |*c| c.deinit();
        self.idle.deinit(self.allocator);
        self.open_count = 0;
        self.closed = true;
    }

    pub fn acquire(self: *Pool) !Lease {
        return self.acquireWithTimeout(self.config.acquire_timeout_ns);
    }

    pub fn acquireWithTimeout(self: *Pool, timeout_ns: u64) !Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const deadline: ?Io.Clock.Timestamp = if (timeout_ns == 0)
            null
        else
            Io.Clock.Timestamp.fromNow(self.io, .{
                .raw = .{ .nanoseconds = @intCast(timeout_ns) },
                .clock = .awake,
            });

        while (true) {
            if (self.closed) return error.PoolClosed;

            if (self.idle.pop()) |idle_conn| {
                return .{
                    .pool = self,
                    .conn_value = idle_conn,
                };
            }

            if (self.open_count < self.config.max_open) {
                // Unlock around TCP handshake so other waiters are not stalled.
                self.open_count += 1;
                self.mutex.unlock(self.io);
                const opened = conn_mod.Conn.open(self.allocator, self.io, self.config.database) catch |err| {
                    self.mutex.lockUncancelable(self.io);
                    self.open_count -|= 1;
                    return err;
                };
                self.mutex.lockUncancelable(self.io);
                if (self.closed) {
                    var doomed = opened;
                    doomed.deinit();
                    self.open_count -|= 1;
                    return error.PoolClosed;
                }
                return .{
                    .pool = self,
                    .conn_value = opened,
                };
            }

            if (deadline) |dl| {
                const remaining = dl.durationFromNow(self.io);
                if (remaining.raw.nanoseconds <= 0) return error.PoolTimeout;
                const slice_ns: i96 = @min(remaining.raw.nanoseconds, @as(i96, std.time.ns_per_ms));
                self.mutex.unlock(self.io);
                self.io.sleep(.{ .nanoseconds = slice_ns }, .awake) catch {};
                self.mutex.lockUncancelable(self.io);
            } else {
                return error.PoolExhausted;
            }
        }
    }

    pub fn exec(self: *Pool, sql: []const u8) !core.ExecResult {
        var lease = try self.acquire();
        errdefer lease.discard() catch {};
        const result = try (try lease.conn()).exec(sql);
        try lease.release();
        return result;
    }

    pub fn execParams(self: *Pool, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        var lease = try self.acquire();
        errdefer lease.discard() catch {};
        const result = try (try lease.conn()).execParams(sql, binds);
        try lease.release();
        return result;
    }

    /// Holds a lease until `PooledRows.deinit`.
    pub fn queryParams(self: *Pool, sql: []const u8, binds: []const core.Value) !PooledRows {
        var lease = try self.acquire();
        errdefer lease.discard() catch {};
        const rows = try (try lease.conn()).queryParams(sql, binds);
        return .{
            .lease = lease,
            .rows = rows,
        };
    }

    pub fn stats(self: *Pool) PoolStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idle_count = self.idle.items.len;
        return .{
            .open = self.open_count,
            .idle = idle_count,
            .leased = self.open_count - idle_count,
            .max_open = self.config.max_open,
            .max_idle = self.effectiveMaxIdle(),
            .acquire_timeout_ns = self.config.acquire_timeout_ns,
        };
    }

    fn effectiveMaxIdle(self: *const Pool) usize {
        return @min(self.config.max_idle, self.config.max_open);
    }
};

pub const Lease = struct {
    pool: *Pool,
    conn_value: conn_mod.Conn,
    open: bool = true,

    pub fn conn(self: *Lease) !*conn_mod.Conn {
        if (!self.open) return error.LeaseClosed;
        return &self.conn_value;
    }

    pub fn release(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        if (self.pool.closed) {
            self.conn_value.deinit();
            self.pool.open_count -|= 1;
            self.open = false;
            return error.PoolClosed;
        }

        if (self.pool.idle.items.len < self.pool.effectiveMaxIdle()) {
            try self.pool.idle.append(self.pool.allocator, self.conn_value);
        } else {
            self.conn_value.deinit();
            self.pool.open_count -|= 1;
        }
        self.open = false;
    }

    pub fn discard(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        self.conn_value.deinit();
        self.pool.open_count -|= 1;
        self.open = false;
    }
};

pub const PooledRows = struct {
    lease: Lease,
    rows: conn_mod.SimpleRows,
    closed: bool = false,

    pub fn next(self: *PooledRows) ?conn_mod.SimpleRow {
        if (self.closed) return null;
        return self.rows.next();
    }

    pub fn deinit(self: *PooledRows) void {
        if (self.closed) return;
        self.rows.deinit();
        self.lease.release() catch {
            self.lease.discard() catch {};
        };
        self.closed = true;
    }
};

test "postgres pool rejects zero max_open" {
    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=disable");
    defer config.deinit();
    try std.testing.expectError(
        error.InvalidArguments,
        Pool.init(std.testing.allocator, std.testing.io, .{
            .database = config,
            .max_open = 0,
        }),
    );
}

test "postgres pool stats start empty" {
    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=disable");
    defer config.deinit();
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{
        .database = config,
        .max_open = 2,
        .max_idle = 1,
    });
    defer pool.deinit();
    try std.testing.expectEqualDeep(PoolStats{
        .open = 0,
        .idle = 0,
        .leased = 0,
        .max_open = 2,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());
}
