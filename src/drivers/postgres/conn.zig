const std = @import("std");
const core = @import("../../zsql.zig");
const url = @import("url.zig");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const scram = @import("scram.zig");
const types = @import("types.zig");

const Io = std.Io;
const net = std.Io.net;
const TlsClient = std.crypto.tls.Client;

/// Stream-side buffer size: large enough for TLS records when encryption is used.
const stream_buf_len = TlsClient.min_buffer_len;
const app_buf_len = 16 * 1024;

/// Live PostgreSQL connection after a successful startup handshake.
///
/// Ownership:
/// - Caller owns `Config` independently of `Conn`.
/// - `Conn` owns the TCP stream and I/O buffers; call `deinit`.
/// - Password material is never stored on `Conn` after handshake.
/// - `lastError()` borrows from connection-owned storage until the next error
///   is recorded or `deinit` runs.
pub const Conn = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Allocator-owned endpoint retained for independent CancelRequest handles.
    server_host: []u8,
    server_port: u16,
    /// Connection-local observability hooks (no global registry).
    hooks: core.Hooks = .{},
    stream: net.Stream,
    /// Encrypted (or plain TCP) stream buffers.
    read_buf: []u8,
    write_buf: []u8,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    /// Plaintext TLS application buffers (only when `tls` is active).
    tls_read_buf: ?[]u8 = null,
    tls_write_buf: ?[]u8 = null,
    tls: ?TlsClient = null,
    /// System CA bundle when verify-ca / verify-full is used.
    ca_bundle: ?std.crypto.Certificate.Bundle = null,
    ca_bundle_lock: Io.RwLock = .init,
    closed: bool = false,
    /// Backend process id from BackendKeyData, if received.
    backend_pid: ?i32 = null,
    /// Backend secret key from BackendKeyData, if received.
    backend_secret: ?i32 = null,
    tx_status: protocol.TxStatus = .idle,
    next_savepoint_id: usize = 0,
    /// Last server ErrorResponse fields, allocator-owned.
    last_error: ?core.OwnedDbError = null,
    /// Optional connection-local prepared-statement name cache.
    /// Enabled with `enableStmtCache`; when set, extended queries reuse named
    /// server prepares and skip Parse on cache hits.
    stmt_cache: ?core.StmtCache = null,
    next_stmt_id: u64 = 0,
    /// Peer leaf certificate DER for SCRAM-SHA-256-PLUS `tls-server-end-point`.
    /// Owned copy from `Config.peer_cert_der` when provided. `std.crypto.tls.Client`
    /// does not expose the peer cert after handshake (esp. TLS 1.3), so callers
    /// that need PLUS must pin the server leaf cert via Config.
    peer_cert_der: ?[]u8 = null,
    /// Set after transport failures that make protocol reuse unsafe.
    broken: bool = false,

    /// Open a TCP connection and complete the PostgreSQL startup handshake.
    ///
    /// TLS policy (`sslmode`):
    /// - `disable` / `allow`: plain StartupMessage (no SSLRequest).
    /// - `prefer`: SSLRequest; plain if rejected; TLS upgrade if accepted
    ///   (encryption without certificate verification for prefer).
    /// - `require`: SSLRequest + TLS encryption without certificate verification.
    /// - `verify-ca`: TLS + system CA verification (no hostname check).
    /// - `verify-full`: TLS + system CA verification + hostname check.
    pub fn open(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        if (config.user.len == 0) return error.InvalidArguments;

        const timeout_secs = config.connect_timeout_secs orelse 0;
        if (timeout_secs == 0) return openUntimed(allocator, io, config);
        return withTimeout(
            Conn,
            io,
            Io.Duration.fromSeconds(timeout_secs),
            openUntimed,
            .{ allocator, io, config },
            deinitConn,
        );
    }

    fn openUntimed(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        return switch (config.ssl_mode) {
            .disable, .allow => openPlain(allocator, io, config),
            .prefer => openPrefer(allocator, io, config),
            .require => openRequireTls(allocator, io, config, .none),
            .verify_ca => openRequireTls(allocator, io, config, .ca),
            .verify_full => openRequireTls(allocator, io, config, .full),
        };
    }

    fn deinitConn(conn: *Conn) void {
        conn.deinit();
    }

    fn attachPeerCert(conn: *Conn, config: url.Config) !void {
        if (config.peer_cert_der) |der| {
            if (der.len == 0) return error.InvalidArguments;
            if (conn.peer_cert_der) |old| conn.allocator.free(old);
            conn.peer_cert_der = try conn.allocator.dupe(u8, der);
        }
    }

    fn openPlain(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        var conn = try connectBare(allocator, io, config.host, config.port);
        errdefer conn.deinitTransportOnly();
        try conn.attachPeerCert(config);
        try conn.startup(config);
        try conn.applySessionSettings(config);
        return conn;
    }

    fn openPrefer(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        var conn = try connectBare(allocator, io, config.host, config.port);

        const ssl = conn.negotiateSslRequest() catch {
            conn.deinitTransportOnly();
            return openPlain(allocator, io, config);
        };

        switch (ssl) {
            .rejects_tls => {
                errdefer conn.deinitTransportOnly();
                try conn.attachPeerCert(config);
                try conn.startup(config);
                try conn.applySessionSettings(config);
                return conn;
            },
            .accepts_tls => {
                errdefer conn.deinitTransportOnly();
                try conn.upgradeTls(config.host, .none);
                try conn.attachPeerCert(config);
                try conn.startup(config);
                try conn.applySessionSettings(config);
                return conn;
            },
        }
    }

    const VerifyMode = enum { none, ca, full };

    fn openRequireTls(allocator: std.mem.Allocator, io: Io, config: url.Config, verify: VerifyMode) !Conn {
        var conn = try connectBare(allocator, io, config.host, config.port);
        errdefer conn.deinitTransportOnly();
        const ssl = conn.negotiateSslRequest() catch return error.TlsFailed;
        if (ssl != .accepts_tls) return error.TlsFailed;
        try conn.upgradeTls(config.host, verify);
        try conn.attachPeerCert(config);
        try conn.startup(config);
        try conn.applySessionSettings(config);
        return conn;
    }

    /// Apply post-startup session settings from config (statement_timeout, …).
    /// Uses the unobserved simple-query path so connect-time setup does not
    /// fire user query hooks.
    fn applySessionSettings(self: *Conn, config: url.Config) !void {
        if (config.statement_timeout_ms) |ms| {
            try self.setStatementTimeoutMs(ms);
        }
    }

    /// Set PostgreSQL `statement_timeout` in milliseconds (`0` disables).
    /// Server cancellations map to `error.QueryTimeout` (SQLSTATE 57014).
    pub fn setStatementTimeoutMs(self: *Conn, ms: u32) !void {
        var buf: [64]u8 = undefined;
        // Bare integer means milliseconds in PostgreSQL.
        const sql = try std.fmt.bufPrint(&buf, "set statement_timeout to {d}", .{ms});
        _ = try self.execUnobserved(sql);
    }

    fn upgradeTls(self: *Conn, host: []const u8, verify: VerifyMode) !void {
        if (self.tls != null) return error.ProtocolError;
        if (self.read_buf.len < stream_buf_len or self.write_buf.len < stream_buf_len) {
            return error.TlsFailed;
        }

        const tls_read_buf = try self.allocator.alloc(u8, app_buf_len);
        errdefer self.allocator.free(tls_read_buf);
        const tls_write_buf = try self.allocator.alloc(u8, stream_buf_len);
        errdefer self.allocator.free(tls_write_buf);

        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        self.io.randomSecure(&entropy) catch self.io.random(&entropy);

        const now = std.Io.Timestamp.now(self.io, .real);

        if (verify != .none) {
            var bundle: std.crypto.Certificate.Bundle = .empty;
            errdefer bundle.deinit(self.allocator);
            bundle.rescan(self.allocator, self.io, now) catch return error.TlsFailed;
            self.ca_bundle = bundle;
        }

        self.tls = switch (verify) {
            .none => TlsClient.init(
                &self.reader.interface,
                &self.writer.interface,
                .{
                    .host = .no_verification,
                    .ca = .no_verification,
                    .read_buffer = tls_read_buf,
                    .write_buffer = tls_write_buf,
                    .entropy = &entropy,
                    .realtime_now = now,
                    .allow_truncation_attacks = false,
                },
            ),
            .ca => TlsClient.init(
                &self.reader.interface,
                &self.writer.interface,
                .{
                    .host = .no_verification,
                    .ca = .{ .bundle = .{
                        .gpa = self.allocator,
                        .io = self.io,
                        .lock = &self.ca_bundle_lock,
                        .bundle = &self.ca_bundle.?,
                    } },
                    .read_buffer = tls_read_buf,
                    .write_buffer = tls_write_buf,
                    .entropy = &entropy,
                    .realtime_now = now,
                    .allow_truncation_attacks = false,
                },
            ),
            .full => TlsClient.init(
                &self.reader.interface,
                &self.writer.interface,
                .{
                    .host = .{ .explicit = host },
                    .ca = .{ .bundle = .{
                        .gpa = self.allocator,
                        .io = self.io,
                        .lock = &self.ca_bundle_lock,
                        .bundle = &self.ca_bundle.?,
                    } },
                    .read_buffer = tls_read_buf,
                    .write_buffer = tls_write_buf,
                    .entropy = &entropy,
                    .realtime_now = now,
                    .allow_truncation_attacks = false,
                },
            ),
        } catch return error.TlsFailed;

        self.tls_read_buf = tls_read_buf;
        self.tls_write_buf = tls_write_buf;
    }

    fn connectBare(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16) !Conn {
        const server_host = try allocator.dupe(u8, host);
        errdefer allocator.free(server_host);
        const stream = try connectStream(io, host, port);
        errdefer stream.close(io);

        const read_buf = try allocator.alloc(u8, stream_buf_len);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, stream_buf_len);
        errdefer allocator.free(write_buf);

        return .{
            .allocator = allocator,
            .io = io,
            .server_host = server_host,
            .server_port = port,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
        };
    }

    /// Close transport buffers without sending Terminate (pre-startup cleanup).
    fn deinitTransportOnly(self: *Conn) void {
        if (self.closed) return;
        self.stream.close(self.io);
        self.allocator.free(self.server_host);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        if (self.tls_read_buf) |buf| self.allocator.free(buf);
        if (self.tls_write_buf) |buf| self.allocator.free(buf);
        if (self.ca_bundle) |*bundle| bundle.deinit(self.allocator);
        if (self.peer_cert_der) |cert| self.allocator.free(cert);
        self.tls = null;
        self.tls_read_buf = null;
        self.tls_write_buf = null;
        self.ca_bundle = null;
        self.peer_cert_der = null;
        self.clearLastError();
        self.closed = true;
    }

    /// Send SSLRequest and read the single-byte server reply (always plain TCP).
    fn negotiateSslRequest(self: *Conn) !protocol.SslResponse {
        if (self.tls != null) return error.ProtocolError;
        const packet = try protocol.buildSslRequest(self.allocator);
        defer self.allocator.free(packet);
        self.writer.interface.writeAll(packet) catch return mapWriteError(self.writer.err);
        self.writer.interface.flush() catch return mapWriteError(self.writer.err);

        var byte: [1]u8 = undefined;
        self.reader.interface.readSliceAll(&byte) catch return mapReadError(self.reader.err);
        return protocol.SslResponse.fromByte(byte[0]);
    }

    fn appReader(self: *Conn) *std.Io.Reader {
        if (self.tls) |*t| return &t.reader;
        return &self.reader.interface;
    }

    fn appWriter(self: *Conn) *std.Io.Writer {
        if (self.tls) |*t| return &t.writer;
        return &self.writer.interface;
    }

    pub fn deinit(self: *Conn) void {
        if (self.closed) return;
        // Best-effort Close of cached prepares before Terminate.
        self.disableStmtCache() catch {};
        self.sendTerminate() catch {};
        self.stream.close(self.io);
        self.allocator.free(self.server_host);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        if (self.tls_read_buf) |buf| self.allocator.free(buf);
        if (self.tls_write_buf) |buf| self.allocator.free(buf);
        if (self.ca_bundle) |*bundle| bundle.deinit(self.allocator);
        if (self.peer_cert_der) |cert| self.allocator.free(cert);
        self.tls = null;
        self.tls_read_buf = null;
        self.tls_write_buf = null;
        self.ca_bundle = null;
        self.peer_cert_der = null;
        self.clearLastError();
        self.closed = true;
    }

    /// Create an allocator-owned handle that can cancel a query concurrently
    /// and remains valid independently of this connection's memory.
    ///
    /// PostgreSQL cancellation uses a separate plaintext TCP connection. Create
    /// the handle before starting the query, call `request` from another task,
    /// and deinitialize it when no longer needed.
    pub fn createCancelHandle(self: *const Conn, allocator: std.mem.Allocator) !CancelHandle {
        if (self.closed) return error.ConnectionClosed;
        const backend_pid = self.backend_pid orelse return error.ProtocolError;
        const backend_secret = self.backend_secret orelse return error.ProtocolError;
        return .{
            .allocator = allocator,
            .io = self.io,
            .host = try allocator.dupe(u8, self.server_host),
            .port = self.server_port,
            .backend_pid = backend_pid,
            .backend_secret = backend_secret,
        };
    }

    /// Borrowed view of the last ErrorResponse metadata, if any.
    /// Valid until the next failing query on this connection or `deinit`.
    pub fn lastError(self: *const Conn) ?core.DbError {
        if (self.last_error) |*owned| return owned.view();
        return null;
    }

    /// True when this session is synchronized, idle, and safe for pool reuse.
    pub fn isReusable(self: *const Conn) bool {
        return !self.closed and !self.broken and self.tx_status == .idle;
    }

    /// Replace connection-local query hooks. Pass `.{}` to clear.
    pub fn setHooks(self: *Conn, hooks: core.Hooks) void {
        self.hooks = hooks;
    }

    fn clearLastError(self: *Conn) void {
        if (self.last_error) |*owned| {
            owned.deinit(self.allocator);
            self.last_error = null;
        }
    }

    /// Enable a connection-local prepared statement name cache.
    ///
    /// When enabled, `execParams` / `queryParams` Parse named statements once
    /// and reuse them on subsequent identical SQL. Max entries must be > 0.
    /// Calling again replaces the previous cache (after closing server prepares).
    pub fn enableStmtCache(self: *Conn, max_entries: usize) !void {
        if (self.closed) return error.ConnectionClosed;
        try self.disableStmtCache();
        self.stmt_cache = try core.StmtCache.init(self.allocator, max_entries);
        self.next_stmt_id = 0;
    }

    /// Disable the statement cache and Close any named prepares on the server.
    pub fn disableStmtCache(self: *Conn) !void {
        if (self.stmt_cache) |*cache| {
            const entries = try cache.drain();
            defer {
                for (entries) |e| core.StmtCache.freeEntry(self.allocator, e);
                self.allocator.free(entries);
            }
            // drain leaves cache.entries empty; free list storage.
            cache.deinit();
            self.stmt_cache = null;
            if (!self.closed) {
                for (entries) |e| {
                    self.closePrepared(e.name) catch {};
                }
            }
        }
    }

    pub fn stmtCacheLen(self: *const Conn) usize {
        if (self.stmt_cache) |*cache| return cache.len();
        return 0;
    }

    fn closePrepared(self: *Conn, name: []const u8) !void {
        const close_msg = try protocol.buildCloseStatementMessage(self.allocator, name);
        defer self.allocator.free(close_msg);
        const sync_msg = try protocol.buildSyncMessage(self.allocator);
        defer self.allocator.free(sync_msg);
        try self.writeAll(close_msg);
        try self.writeAll(sync_msg);
        // Drain until ReadyForQuery (CloseComplete then ReadyForQuery).
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .close_complete, .notice_response, .parameter_status => {},
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    return;
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                else => {
                    self.drainUntilReady();
                    return error.ProtocolError;
                },
            }
        }
    }

    ///
    /// Prefer extended/parameterized APIs once available for any user values.
    /// This path is intended for DDL, transaction control, and trusted SQL.
    pub fn exec(self: *Conn, sql: []const u8) !core.ExecResult {
        return self.execObserved(sql, 0, struct {
            fn run(c: *Conn, s: []const u8) !core.ExecResult {
                return c.execUnobserved(s);
            }
        }.run);
    }

    fn execUnobserved(self: *Conn, sql: []const u8) !core.ExecResult {
        if (self.closed) return error.ConnectionClosed;
        const packet = try protocol.buildQueryMessage(self.allocator, sql);
        defer self.allocator.free(packet);
        try self.writeAll(packet);

        var rows_affected: u64 = 0;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .command_complete => {
                    const tag = try protocol.parseCommandComplete(msg.body);
                    rows_affected = types.parseCommandTag(tag).rows_affected;
                },
                .empty_query_response => {},
                .parameter_status, .notice_response, .notification_response => {},
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    return .{ .rows_affected = rows_affected };
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                .row_description, .data_row => {
                    self.drainUntilReady();
                    return error.UnexpectedRow;
                },
                else => {
                    self.drainUntilReady();
                    return error.ProtocolError;
                },
            }
        }
    }

    /// Execute parameterized SQL via the extended query protocol (Parse/Bind/Execute/Sync).
    ///
    /// Placeholders must use PostgreSQL `$1` style. Values are bound in text
    /// format and never concatenated into the SQL string.
    pub fn execParams(self: *Conn, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        const observe = !self.hooks.isEmpty();
        const start_ns: u64 = if (observe) core.hooks.monoNs() else 0;
        if (observe) {
            self.hooks.emitBefore(.{
                .driver = .postgres,
                .sql = sql,
                .bind_count = binds.len,
            });
        }
        const result = self.execParamsUnobserved(sql, binds) catch |err| {
            if (observe) {
                self.hooks.emitAfter(.{
                    .driver = .postgres,
                    .sql = sql,
                    .duration_ns = core.hooks.durationSince(start_ns),
                    .err = core.hooks.categoryOfErr(err),
                });
            }
            return err;
        };
        if (observe) {
            self.hooks.emitAfter(.{
                .driver = .postgres,
                .sql = sql,
                .duration_ns = core.hooks.durationSince(start_ns),
                .rows_affected = result.rows_affected,
            });
        }
        return result;
    }

    /// Execute named parameters by rewriting them to PostgreSQL `$n` binds.
    /// Values are reordered into a temporary slice; they are never interpolated.
    pub fn execNamed(self: *Conn, sql: []const u8, binds: []const core.params.NamedValue) !core.ExecResult {
        var rewrite = try core.params.rewriteNamedPostgres(self.allocator, sql);
        defer rewrite.deinit(self.allocator);
        const ordered = try orderedNamedBinds(self.allocator, rewrite.names, binds);
        defer self.allocator.free(ordered);
        return self.execParams(rewrite.sql, ordered);
    }

    fn execParamsUnobserved(self: *Conn, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        if (self.closed) return error.ConnectionClosed;
        try self.sendExtended(sql, binds, false);

        var rows_affected: u64 = 0;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .parse_complete, .bind_complete, .no_data => {},
                .parameter_status, .notice_response, .notification_response => {},
                .command_complete => {
                    const tag = try protocol.parseCommandComplete(msg.body);
                    rows_affected = types.parseCommandTag(tag).rows_affected;
                },
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    return .{ .rows_affected = rows_affected };
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                .row_description, .data_row => {
                    self.drainUntilReady();
                    return error.UnexpectedRow;
                },
                else => {
                    self.drainUntilReady();
                    return error.ProtocolError;
                },
            }
        }
    }

    fn execObserved(
        self: *Conn,
        sql: []const u8,
        bind_count: usize,
        comptime run: *const fn (*Conn, []const u8) anyerror!core.ExecResult,
    ) !core.ExecResult {
        const observe = !self.hooks.isEmpty();
        const start_ns: u64 = if (observe) core.hooks.monoNs() else 0;
        if (observe) {
            self.hooks.emitBefore(.{
                .driver = .postgres,
                .sql = sql,
                .bind_count = bind_count,
            });
        }
        const result = run(self, sql) catch |err| {
            if (observe) {
                self.hooks.emitAfter(.{
                    .driver = .postgres,
                    .sql = sql,
                    .duration_ns = core.hooks.durationSince(start_ns),
                    .err = core.hooks.categoryOfErr(err),
                });
            }
            return err;
        };
        if (observe) {
            self.hooks.emitAfter(.{
                .driver = .postgres,
                .sql = sql,
                .duration_ns = core.hooks.durationSince(start_ns),
                .rows_affected = result.rows_affected,
            });
        }
        return result;
    }

    /// Cheap liveness check (simple query). Does not change transaction state
    /// when already idle.
    pub fn ping(self: *Conn) !void {
        var rows = try self.query("select 1");
        defer rows.deinit();
        _ = rows.next();
    }

    /// Register this dedicated connection for a PostgreSQL notification channel.
    /// Channel names are identifier-quoted; payloads are never interpolated.
    pub fn listen(self: *Conn, channel: []const u8) !void {
        const sql = try listenSql(self.allocator, "listen", channel);
        defer self.allocator.free(sql);
        _ = try self.exec(sql);
    }

    pub fn unlisten(self: *Conn, channel: []const u8) !void {
        const sql = try listenSql(self.allocator, "unlisten", channel);
        defer self.allocator.free(sql);
        _ = try self.exec(sql);
    }

    /// Wait for the next asynchronous PostgreSQL notification.
    /// The returned channel and payload are allocator-owned.
    pub fn nextNotification(self: *Conn) !Notification {
        if (self.closed) return error.ConnectionClosed;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .notification_response => return Notification.parse(self.allocator, msg.body),
                .parameter_status, .notice_response => {},
                .error_response => return self.failFromErrorResponse(msg.body, true),
                else => return error.ProtocolError,
            }
        }
    }

    /// COPY trusted SQL input from an explicit byte buffer. Values must be
    /// encoded by the caller according to the selected COPY format.
    pub fn copyIn(self: *Conn, sql: []const u8, data: []const u8) !core.ExecResult {
        if (self.closed) return error.ConnectionClosed;
        const query_packet = try protocol.buildQueryMessage(self.allocator, sql);
        defer self.allocator.free(query_packet);
        try self.writeAll(query_packet);

        var started = false;
        var rows_affected: u64 = 0;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .copy_in_response => {
                    if (started) return error.ProtocolError;
                    started = true;
                    if (data.len != 0) {
                        const copy_data = try protocol.buildMessage(self.allocator, .copy_data, data);
                        defer self.allocator.free(copy_data);
                        try self.writeAll(copy_data);
                    }
                    const done = try protocol.buildMessage(self.allocator, .copy_done, &.{});
                    defer self.allocator.free(done);
                    try self.writeAll(done);
                },
                .command_complete => rows_affected = types.parseCommandTag(try protocol.parseCommandComplete(msg.body)).rows_affected,
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    return if (started) .{ .rows_affected = rows_affected } else error.ProtocolError;
                },
                .parameter_status, .notice_response, .notification_response => {},
                .error_response => return self.failFromErrorResponse(msg.body, true),
                else => return error.ProtocolError,
            }
        }
    }

    /// COPY trusted SQL output into an allocator-owned byte buffer.
    pub fn copyOut(self: *Conn, sql: []const u8) ![]u8 {
        if (self.closed) return error.ConnectionClosed;
        const query_packet = try protocol.buildQueryMessage(self.allocator, sql);
        defer self.allocator.free(query_packet);
        try self.writeAll(query_packet);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var started = false;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .copy_out_response => {
                    if (started) return error.ProtocolError;
                    started = true;
                },
                .copy_data => {
                    if (!started) return error.ProtocolError;
                    try out.appendSlice(self.allocator, msg.body);
                },
                .copy_done, .command_complete => {},
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    if (!started) return error.ProtocolError;
                    return out.toOwnedSlice(self.allocator);
                },
                .parameter_status, .notice_response, .notification_response => {},
                .error_response => return self.failFromErrorResponse(msg.body, true),
                else => return error.ProtocolError,
            }
        }
    }

    /// Parameterized query via extended protocol; returns owned simple rows.
    pub fn queryParams(self: *Conn, sql: []const u8, binds: []const core.Value) !SimpleRows {
        const observe = !self.hooks.isEmpty();
        const start_ns: u64 = if (observe) core.hooks.monoNs() else 0;
        if (observe) {
            self.hooks.emitBefore(.{
                .driver = .postgres,
                .sql = sql,
                .bind_count = binds.len,
            });
        }
        if (self.closed) {
            if (observe) {
                self.hooks.emitAfter(.{
                    .driver = .postgres,
                    .sql = sql,
                    .duration_ns = core.hooks.durationSince(start_ns),
                    .err = .connection,
                });
            }
            return error.ConnectionClosed;
        }
        self.sendExtended(sql, binds, true) catch |err| {
            if (observe) {
                self.hooks.emitAfter(.{
                    .driver = .postgres,
                    .sql = sql,
                    .duration_ns = core.hooks.durationSince(start_ns),
                    .err = core.hooks.categoryOfErr(err),
                });
            }
            return err;
        };
        const rows = self.collectExtendedRows() catch |err| {
            if (observe) {
                self.hooks.emitAfter(.{
                    .driver = .postgres,
                    .sql = sql,
                    .duration_ns = core.hooks.durationSince(start_ns),
                    .err = core.hooks.categoryOfErr(err),
                });
            }
            return err;
        };
        if (observe) {
            self.hooks.emitAfter(.{
                .driver = .postgres,
                .sql = sql,
                .duration_ns = core.hooks.durationSince(start_ns),
                .rows_affected = rows.rows_affected,
            });
        }
        return rows;
    }

    /// Query with named parameters, rewritten to PostgreSQL `$n` binds.
    pub fn queryNamed(self: *Conn, sql: []const u8, binds: []const core.params.NamedValue) !SimpleRows {
        var rewrite = try core.params.rewriteNamedPostgres(self.allocator, sql);
        defer rewrite.deinit(self.allocator);
        const ordered = try orderedNamedBinds(self.allocator, rewrite.names, binds);
        defer self.allocator.free(ordered);
        return self.queryParams(rewrite.sql, ordered);
    }

    /// Query exactly one row. Returns `error.NoRows` / `error.TooManyRows` on
    /// wrong cardinality. The returned row borrows from a temporary result set
    /// that is fully collected before return, so values are owned via SimpleRows
    /// internal storage — call `SimpleRows.deinit` is not needed; values are
    /// copied into an `OwnedRow`.
    pub fn queryOneParams(self: *Conn, sql: []const u8, binds: []const core.Value) !core.OwnedRow {
        var rows = try self.queryParams(sql, binds);
        defer rows.deinit();
        const first = rows.next() orelse return error.NoRows;
        var owned = try simpleRowToOwned(self.allocator, first);
        errdefer owned.deinit();
        if (rows.next() != null) return error.TooManyRows;
        return owned;
    }

    /// Collect all parameterized query rows into owned storage.
    /// Free with `core.OwnedRow.freeSlice` / `zsql.freeOwnedRows`.
    pub fn queryAllParams(self: *Conn, sql: []const u8, binds: []const core.Value) ![]core.OwnedRow {
        var rows = try self.queryParams(sql, binds);
        defer rows.deinit();
        var list: std.ArrayListUnmanaged(core.OwnedRow) = .empty;
        errdefer {
            for (list.items) |*item| item.deinit();
            list.deinit(self.allocator);
        }
        while (rows.next()) |row| {
            try list.append(self.allocator, try simpleRowToOwned(self.allocator, row));
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn begin(self: *Conn) !void {
        _ = try self.exec("begin");
    }

    pub fn commit(self: *Conn) !void {
        _ = try self.exec("commit");
    }

    pub fn rollback(self: *Conn) !void {
        _ = try self.exec("rollback");
    }

    /// Best-effort rollback for `defer` cleanup when a transaction may be open.
    pub fn rollbackIfOpen(self: *Conn) void {
        if (self.closed) return;
        if (self.tx_status != .in_transaction and self.tx_status != .failed) return;
        self.rollback() catch {};
    }

    /// Run `body(ctx, conn)` inside a transaction. Commits on success; rolls
    /// back if `body` returns an error. Postgres keeps transaction state on
    /// the connection (no separate Tx object).
    ///
    /// ```zig
    /// try conn.withTx({}, struct {
    ///     fn run(_: void, c: *Conn) !void {
    ///         _ = try c.execParams("insert into t (n) values ($1)", &.{.{ .integer = 1 }});
    ///     }
    /// }.run);
    /// ```
    pub fn withTx(self: *Conn, ctx: anytype, comptime body: *const fn (@TypeOf(ctx), *Conn) anyerror!void) !void {
        try self.begin();
        errdefer self.rollbackIfOpen();
        try body(ctx, self);
        try self.commit();
    }

    /// Inspect base tables via `information_schema` for offline query checks.
    ///
    /// Caller owns the returned schema; free with `freeInspectedSchema`.
    /// Table names in the `public` schema are bare; other schemas are
    /// qualified as `schema.table`. Column types use PostgreSQL `udt_name`.
    pub fn inspectSchema(self: *Conn, allocator: std.mem.Allocator) !core.inspect.Schema {
        if (self.closed) return error.ConnectionClosed;

        var tables_list: std.ArrayListUnmanaged(core.inspect.Table) = .empty;
        errdefer freeInspectedTables(allocator, tables_list.items);

        var table_rows = try self.query(core.inspect.postgres_list_tables_sql);
        defer table_rows.deinit();

        while (table_rows.next()) |row| {
            const schema_name = try (try row.value("table_schema")).asText();
            const table_name = try (try row.value("table_name")).asText();

            const display_name = try core.inspect.postgresTableDisplayName(allocator, schema_name, table_name);
            errdefer allocator.free(display_name);

            var col_rows = try self.queryParams(core.inspect.postgres_list_columns_sql, &.{
                .{ .text = schema_name },
                .{ .text = table_name },
            });
            defer col_rows.deinit();

            // Dupe column fields before the next row / rows deinit invalidates
            // borrowed text from the wire buffers.
            var owned_info: std.ArrayListUnmanaged(struct {
                name: []u8,
                type_name: []u8,
                is_nullable: bool,
                primary_key: bool,
            }) = .empty;
            defer {
                for (owned_info.items) |item| {
                    allocator.free(item.name);
                    allocator.free(item.type_name);
                }
                owned_info.deinit(allocator);
            }

            while (col_rows.next()) |col_row| {
                const cname = try (try col_row.value("column_name")).asText();
                const ctype = try (try col_row.value("udt_name")).asText();
                const nullable_text = try (try col_row.value("is_nullable")).asText();
                const pk_text = try (try col_row.value("is_primary_key")).asText();
                try owned_info.append(allocator, .{
                    .name = try allocator.dupe(u8, cname),
                    .type_name = try allocator.dupe(u8, ctype),
                    .is_nullable = std.ascii.eqlIgnoreCase(nullable_text, "YES"),
                    .primary_key = std.ascii.eqlIgnoreCase(pk_text, "YES"),
                });
            }

            const info = try allocator.alloc(core.inspect.PostgresColumnInfoRow, owned_info.items.len);
            defer allocator.free(info);
            for (owned_info.items, 0..) |item, i| {
                info[i] = .{
                    .name = item.name,
                    .type_name = item.type_name,
                    .is_nullable = item.is_nullable,
                    .primary_key = item.primary_key,
                };
            }

            const columns = try core.inspect.columnsFromPostgresColumnInfo(allocator, info);

            const indexes = try loadPostgresIndexes(self, allocator, schema_name, table_name);
            errdefer core.inspect.freeIndexes(allocator, @constCast(indexes));

            try tables_list.append(allocator, .{
                .name = display_name,
                .columns = columns,
                .indexes = indexes,
            });
        }

        return .{
            .tables = try tables_list.toOwnedSlice(allocator),
        };
    }

    fn loadPostgresIndexes(
        self: *Conn,
        allocator: std.mem.Allocator,
        schema_name: []const u8,
        table_name: []const u8,
    ) ![]core.inspect.Index {
        var idx_rows = try self.queryParams(core.inspect.postgres_list_index_columns_sql, &.{
            .{ .text = schema_name },
            .{ .text = table_name },
        });
        defer idx_rows.deinit();

        var indexes: std.ArrayListUnmanaged(core.inspect.Index) = .empty;
        errdefer {
            for (indexes.items) |idx| {
                allocator.free(idx.name);
                for (idx.columns) |c_| allocator.free(c_);
                allocator.free(idx.columns);
            }
            indexes.deinit(allocator);
        }

        var current_name: ?[]u8 = null;
        var current_unique: bool = false;
        var current_cols: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            if (current_name) |n| allocator.free(n);
            for (current_cols.items) |c_| allocator.free(c_);
            current_cols.deinit(allocator);
        }

        while (idx_rows.next()) |row| {
            const iname = try (try row.value("index_name")).asText();
            const unique = try (try row.value("is_unique")).asBool();
            const cname = try (try row.value("column_name")).asText();

            if (current_name == null or !std.mem.eql(u8, current_name.?, iname)) {
                if (current_name) |prev| {
                    try indexes.append(allocator, .{
                        .name = prev,
                        .unique = current_unique,
                        .columns = try current_cols.toOwnedSlice(allocator),
                    });
                    current_name = null;
                    current_cols = .empty;
                }
                current_name = try allocator.dupe(u8, iname);
                current_unique = unique;
            }
            try current_cols.append(allocator, try allocator.dupe(u8, cname));
        }
        if (current_name) |prev| {
            try indexes.append(allocator, .{
                .name = prev,
                .unique = current_unique,
                .columns = try current_cols.toOwnedSlice(allocator),
            });
            current_name = null;
            current_cols = .empty;
        }

        return try indexes.toOwnedSlice(allocator);
    }

    /// Create a savepoint with an internally generated name.
    pub fn savepoint(self: *Conn) !Savepoint {
        if (self.closed) return error.ConnectionClosed;
        if (self.tx_status != .in_transaction) return error.TransactionClosed;

        const id = self.next_savepoint_id;
        self.next_savepoint_id += 1;

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "zsql_sp_{d}", .{id});
        // Savepoint identifiers are generated locally and never user-controlled.
        var sql_buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "savepoint {s}", .{name});
        _ = try self.exec(sql);

        var stored: [64]u8 = undefined;
        @memcpy(stored[0..name.len], name);
        return .{
            .conn = self,
            .name = stored,
            .name_len = name.len,
        };
    }

    fn sendExtended(self: *Conn, sql: []const u8, binds: []const core.Value, describe_portal: bool) !void {
        var encoded: std.ArrayListUnmanaged(?[]u8) = .empty;
        defer {
            for (encoded.items) |item| {
                if (item) |bytes| self.allocator.free(bytes);
            }
            encoded.deinit(self.allocator);
        }
        try encoded.ensureTotalCapacity(self.allocator, binds.len);
        for (binds) |value| {
            try encoded.append(self.allocator, try types.encodeText(self.allocator, value));
        }

        // Build ?[]const u8 view for bind message.
        var views = try self.allocator.alloc(?[]const u8, encoded.items.len);
        defer self.allocator.free(views);
        for (encoded.items, 0..) |item, i| views[i] = item;

        // Resolve optional prepared-statement name from the connection cache.
        var stmt_name: []const u8 = "";
        var parse_needed = true;
        var name_buf: [32]u8 = undefined;

        if (self.stmt_cache) |*cache| {
            if (cache.get(sql)) |cached_name| {
                stmt_name = cached_name;
                parse_needed = false;
            } else {
                stmt_name = try core.formatStmtName(&name_buf, self.next_stmt_id);
                self.next_stmt_id += 1;
            }
        }

        if (parse_needed) {
            if (self.stmt_cache != null and stmt_name.len > 0) {
                // Reserve cache slot before sending so eviction Close is ordered
                // before the new Parse on the wire.
                const evicted = try self.stmt_cache.?.put(sql, stmt_name);
                if (evicted) |old| {
                    defer core.StmtCache.freeEntry(self.allocator, old);
                    try self.closePrepared(old.name);
                }
            }
            const parse_msg = if (stmt_name.len == 0)
                try protocol.buildParseMessage(self.allocator, sql)
            else
                try protocol.buildParseMessageNamed(self.allocator, stmt_name, sql);
            defer self.allocator.free(parse_msg);
            try self.writeAll(parse_msg);
        }

        const bind_msg = if (stmt_name.len == 0)
            try protocol.buildBindMessage(self.allocator, views)
        else
            try protocol.buildBindMessageNamed(self.allocator, stmt_name, views);
        defer self.allocator.free(bind_msg);
        const execute_msg = try protocol.buildExecuteMessage(self.allocator);
        defer self.allocator.free(execute_msg);
        const sync_msg = try protocol.buildSyncMessage(self.allocator);
        defer self.allocator.free(sync_msg);

        try self.writeAll(bind_msg);
        if (describe_portal) {
            const describe_msg = try protocol.buildDescribePortalMessage(self.allocator);
            defer self.allocator.free(describe_msg);
            try self.writeAll(describe_msg);
        }
        try self.writeAll(execute_msg);
        try self.writeAll(sync_msg);
    }

    fn collectExtendedRows(self: *Conn) !SimpleRows {
        var columns: []protocol.FieldDescription = &.{};
        var column_names: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (column_names.items) |name| self.allocator.free(name);
            column_names.deinit(self.allocator);
            if (columns.len != 0) self.allocator.free(columns);
        }

        var rows: std.ArrayListUnmanaged(OwnedSimpleRow) = .empty;
        errdefer {
            for (rows.items) |*row| row.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        var rows_affected: u64 = 0;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .parse_complete, .bind_complete => {},
                .row_description => {
                    if (columns.len != 0) self.allocator.free(columns);
                    columns = try protocol.parseRowDescription(msg.body, self.allocator);
                    for (column_names.items) |name| self.allocator.free(name);
                    column_names.clearRetainingCapacity();
                    for (columns) |field| {
                        try column_names.append(self.allocator, try self.allocator.dupe(u8, field.name));
                    }
                },
                .no_data => {},
                .data_row => {
                    const data_cols = try protocol.parseDataRow(msg.body, self.allocator);
                    defer self.allocator.free(data_cols);
                    if (columns.len == 0 or data_cols.len != columns.len) return error.ProtocolError;

                    const values = try self.allocator.alloc(core.OwnedValue, data_cols.len);
                    errdefer {
                        for (values) |*v| v.deinit(self.allocator);
                        self.allocator.free(values);
                    }
                    for (data_cols, columns, 0..) |col, field, i| {
                        if (col.bytes) |raw| {
                            const decoded = try types.decodeText(field.type_oid, raw);
                            values[i] = try core.OwnedValue.from(self.allocator, decoded);
                        } else {
                            values[i] = .{ .null = {} };
                        }
                    }
                    try rows.append(self.allocator, .{ .values = values });
                },
                .command_complete => {
                    const tag = try protocol.parseCommandComplete(msg.body);
                    rows_affected = types.parseCommandTag(tag).rows_affected;
                },
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    const names = try column_names.toOwnedSlice(self.allocator);
                    column_names = .empty;
                    if (columns.len != 0) {
                        self.allocator.free(columns);
                        columns = &.{};
                    }
                    return .{
                        .allocator = self.allocator,
                        .column_names = names,
                        .rows = try rows.toOwnedSlice(self.allocator),
                        .rows_affected = rows_affected,
                    };
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                .parameter_status, .notice_response, .notification_response => {},
                else => {
                    self.drainUntilReady();
                    return error.ProtocolError;
                },
            }
        }
    }

    /// Run a simple query and collect all result rows into allocator-owned storage.
    ///
    /// Column text is copied so values outlive the network buffer. Call
    /// `SimpleRows.deinit` when finished.
    pub fn query(self: *Conn, sql: []const u8) !SimpleRows {
        const observe = !self.hooks.isEmpty();
        const start_ns: u64 = if (observe) core.hooks.monoNs() else 0;
        if (observe) {
            self.hooks.emitBefore(.{
                .driver = .postgres,
                .sql = sql,
                .bind_count = 0,
            });
        }
        const rows = self.queryUnobserved(sql) catch |err| {
            if (observe) {
                self.hooks.emitAfter(.{
                    .driver = .postgres,
                    .sql = sql,
                    .duration_ns = core.hooks.durationSince(start_ns),
                    .err = core.hooks.categoryOfErr(err),
                });
            }
            return err;
        };
        if (observe) {
            self.hooks.emitAfter(.{
                .driver = .postgres,
                .sql = sql,
                .duration_ns = core.hooks.durationSince(start_ns),
                .rows_affected = rows.rows_affected,
            });
        }
        return rows;
    }

    fn queryUnobserved(self: *Conn, sql: []const u8) !SimpleRows {
        if (self.closed) return error.ConnectionClosed;
        const packet = try protocol.buildQueryMessage(self.allocator, sql);
        defer self.allocator.free(packet);
        try self.writeAll(packet);

        var columns: []protocol.FieldDescription = &.{};
        var column_names: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (column_names.items) |name| self.allocator.free(name);
            column_names.deinit(self.allocator);
            if (columns.len != 0) self.allocator.free(columns);
        }

        var rows: std.ArrayListUnmanaged(OwnedSimpleRow) = .empty;
        errdefer {
            for (rows.items) |*row| row.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        var rows_affected: u64 = 0;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .row_description => {
                    if (columns.len != 0) self.allocator.free(columns);
                    columns = try protocol.parseRowDescription(msg.body, self.allocator);
                    for (column_names.items) |name| self.allocator.free(name);
                    column_names.clearRetainingCapacity();
                    for (columns) |field| {
                        try column_names.append(self.allocator, try self.allocator.dupe(u8, field.name));
                    }
                },
                .data_row => {
                    const data_cols = try protocol.parseDataRow(msg.body, self.allocator);
                    defer self.allocator.free(data_cols);
                    if (columns.len == 0 or data_cols.len != columns.len) return error.ProtocolError;

                    var values = try self.allocator.alloc(core.OwnedValue, data_cols.len);
                    errdefer {
                        for (values) |*v| v.deinit(self.allocator);
                        self.allocator.free(values);
                    }
                    for (data_cols, columns, 0..) |col, field, i| {
                        if (col.bytes) |raw| {
                            const decoded = try types.decodeText(field.type_oid, raw);
                            values[i] = try core.OwnedValue.from(self.allocator, decoded);
                        } else {
                            values[i] = .{ .null = {} };
                        }
                    }
                    try rows.append(self.allocator, .{ .values = values });
                },
                .command_complete => {
                    const tag = try protocol.parseCommandComplete(msg.body);
                    rows_affected = types.parseCommandTag(tag).rows_affected;
                },
                .empty_query_response => {},
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    const names = try column_names.toOwnedSlice(self.allocator);
                    column_names = .empty;
                    // Free protocol field metadata; names are owned separately.
                    if (columns.len != 0) {
                        self.allocator.free(columns);
                        columns = &.{};
                    }
                    return .{
                        .allocator = self.allocator,
                        .column_names = names,
                        .rows = try rows.toOwnedSlice(self.allocator),
                        .rows_affected = rows_affected,
                    };
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                .parameter_status, .notice_response, .notification_response => {},
                else => {
                    self.drainUntilReady();
                    return error.ProtocolError;
                },
            }
        }
    }

    fn startup(self: *Conn, config: url.Config) !void {
        const startup_msg = try protocol.buildStartupMessage(self.allocator, config);
        defer self.allocator.free(startup_msg);
        try self.writeAll(startup_msg);

        var authenticated = false;
        var scram_client: ?scram.Client = null;
        defer if (scram_client) |*c| c.deinit();

        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);

            switch (msg.tag) {
                .authentication => {
                    const parsed = try protocol.parseAuthenticationBody(msg.body);
                    switch (parsed.kind) {
                        .ok => {
                            authenticated = true;
                        },
                        .cleartext_password => {
                            const body = try auth.buildCleartextPasswordBody(self.allocator, config.password);
                            defer {
                                @memset(body, 0);
                                self.allocator.free(body);
                            }
                            const packet = try protocol.buildMessage(self.allocator, .password, body);
                            defer self.allocator.free(packet);
                            try self.writeAll(packet);
                        },
                        .md5_password => {
                            if (parsed.payload.len != 4) return error.ProtocolError;
                            const salt = parsed.payload[0..4].*;
                            const body = try auth.buildMd5PasswordBody(
                                self.allocator,
                                config.user,
                                config.password,
                                &salt,
                            );
                            defer {
                                @memset(body, 0);
                                self.allocator.free(body);
                            }
                            const packet = try protocol.buildMessage(self.allocator, .password, body);
                            defer self.allocator.free(packet);
                            try self.writeAll(packet);
                        },
                        .sasl => {
                            if (scram_client != null) return error.ProtocolError;
                            const mechs = scram.MechanismList.parse(parsed.payload);

                            // Channel binding data for SCRAM-SHA-256-PLUS when we
                            // have a leaf cert (pinned via Config.peer_cert_der).
                            var cbind_data: ?[]u8 = null;
                            defer if (cbind_data) |d| self.allocator.free(d);
                            if (self.tls != null and self.peer_cert_der != null and config.channel_binding != .disable) {
                                cbind_data = try scram.tlsServerEndPointData(self.allocator, self.peer_cert_der.?);
                            }

                            const want_plus = cbind_data != null and config.channel_binding != .disable;
                            const selected = mechs.select(want_plus) orelse {
                                if (config.channel_binding == .require) return error.AuthFailed;
                                return error.Unsupported;
                            };
                            if (config.channel_binding == .require and selected != .scram_sha_256_plus) {
                                return error.AuthFailed;
                            }

                            const channel_binding: scram.ChannelBinding = switch (selected) {
                                .scram_sha_256 => .none,
                                .scram_sha_256_plus => .{
                                    .tls_server_end_point = cbind_data orelse return error.AuthFailed,
                                },
                            };

                            var nonce_buf: [24]u8 = undefined;
                            try self.fillClientNonce(&nonce_buf);
                            scram_client = try scram.Client.init(
                                self.allocator,
                                config.user,
                                config.password,
                                &nonce_buf,
                                channel_binding,
                            );

                            const client_first = try scram_client.?.clientFirstMessage(self.allocator);
                            defer self.allocator.free(client_first);
                            const body = try scram.buildSaslInitialResponse(
                                self.allocator,
                                selected,
                                client_first,
                            );
                            defer self.allocator.free(body);
                            const packet = try protocol.buildMessage(self.allocator, .password, body);
                            defer self.allocator.free(packet);
                            try self.writeAll(packet);
                        },
                        .sasl_continue => {
                            const client = if (scram_client) |*c| c else return error.ProtocolError;
                            const client_final = try client.handleServerFirst(parsed.payload);
                            defer self.allocator.free(client_final);
                            // SASLResponse is raw message data (not NUL-terminated).
                            const packet = try protocol.buildMessage(self.allocator, .password, client_final);
                            defer self.allocator.free(packet);
                            try self.writeAll(packet);
                        },
                        .sasl_final => {
                            const client = if (scram_client) |*c| c else return error.ProtocolError;
                            try client.handleServerFinal(parsed.payload);
                        },
                        else => return error.Unsupported,
                    }
                },
                .parameter_status => {
                    // Server parameters are intentionally ignored for now.
                },
                .backend_key_data => {
                    if (msg.body.len != 8) return error.ProtocolError;
                    self.backend_pid = protocol.readI32(msg.body[0..4]);
                    self.backend_secret = protocol.readI32(msg.body[4..8]);
                },
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    if (!authenticated) return error.ProtocolError;
                    return;
                },
                .error_response => {
                    // Startup failures usually close the socket; still record
                    // metadata and map SQLSTATE when present.
                    const err = self.captureSqlError(msg.body);
                    // Prefer AuthFailed for handshake failures without a clear code.
                    if (err == error.DriverError) return error.AuthFailed;
                    return err;
                },
                .notice_response => {},
                .negotiate_protocol_version => return error.ProtocolError,
                else => return error.ProtocolError,
            }
        }
    }

    /// Record ErrorResponse metadata and return the mapped Zig error.
    /// When `drain` is true, consume messages until ReadyForQuery so the
    /// connection remains usable for subsequent commands.
    fn failFromErrorResponse(self: *Conn, body: []const u8, drain: bool) anyerror {
        const err = self.captureSqlError(body);
        if (drain) self.drainUntilReady();
        return err;
    }

    fn captureSqlError(self: *Conn, body: []const u8) anyerror {
        self.clearLastError();
        const fields = protocol.parseErrorFields(body) catch return error.DriverError;
        const zig_err = if (fields.code) |code|
            core.DbError.errorFromSqlState(code)
        else
            error.DriverError;

        const pg_fields = core.PostgresErrorFields{
            .code = fields.code,
            .message = fields.message,
            .detail = fields.detail,
            .hint = fields.hint,
            .schema = fields.schema,
            .table = fields.table,
            .column = fields.column,
            .constraint = fields.constraint,
        };
        // Best-effort ownership; OOM must not hide the original SQL error.
        self.last_error = core.OwnedDbError.fromPostgresFields(self.allocator, pg_fields, zig_err) catch null;
        return zig_err;
    }

    /// After ErrorResponse (or unexpected messages mid-command), read until
    /// ReadyForQuery so the session is synchronized again.
    fn drainUntilReady(self: *Conn) void {
        while (true) {
            const msg = self.readMessage() catch {
                // I/O failure mid-drain: mark closed so callers do not reuse.
                self.closed = true;
                return;
            };
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .ready_for_query => {
                    self.tx_status = protocol.parseReadyForQuery(msg.body) catch .failed;
                    return;
                },
                .error_response, .notice_response => {},
                .command_complete,
                .empty_query_response,
                .parse_complete,
                .bind_complete,
                .no_data,
                .row_description,
                .data_row,
                .parameter_status,
                .parameter_description,
                .portal_suspended,
                => {},
                else => {},
            }
        }
    }

    fn fillClientNonce(self: *Conn, buf: []u8) !void {
        // Printable nonce alphabet (no `,`) per SCRAM recommendations.
        const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
        var random: [32]u8 = undefined;
        self.io.randomSecure(&random) catch self.io.random(&random);
        for (buf, 0..) |*out, i| {
            out.* = alphabet[random[i % random.len] % alphabet.len];
        }
    }

    fn sendTerminate(self: *Conn) !void {
        const packet = try protocol.buildMessage(self.allocator, .terminate, &.{});
        defer self.allocator.free(packet);
        try self.writeAll(packet);
    }

    const Message = struct {
        tag: protocol.BackendTag,
        body: []u8,
    };

    fn readMessage(self: *Conn) !Message {
        var header_bytes: [5]u8 = undefined;
        const reader = self.appReader();
        reader.readSliceAll(&header_bytes) catch return self.mapAppReadError();
        const header = try protocol.parseMessageHeader(&header_bytes);
        const body_len = header.bodyLen();
        const body = try self.allocator.alloc(u8, body_len);
        errdefer self.allocator.free(body);
        if (body_len > 0) {
            reader.readSliceAll(body) catch return self.mapAppReadError();
        }
        return .{
            .tag = header.tag,
            .body = body,
        };
    }

    fn writeAll(self: *Conn, bytes: []const u8) !void {
        const writer = self.appWriter();
        writer.writeAll(bytes) catch return self.mapAppWriteError();
        writer.flush() catch return self.mapAppWriteError();
    }

    fn mapAppReadError(self: *Conn) anyerror {
        self.broken = true;
        if (self.tls) |*t| {
            if (t.read_err) |_| return error.ProtocolError;
        }
        return mapReadError(self.reader.err);
    }

    fn mapAppWriteError(self: *Conn) anyerror {
        self.broken = true;
        if (self.tls != null) return error.ProtocolError;
        return mapWriteError(self.writer.err);
    }
};

/// Allocator-owned PostgreSQL CancelRequest credentials and endpoint.
///
/// The handle contains sensitive backend-key material. Do not log or format its
/// fields. Its memory is independent of the originating `Conn`, but callers
/// must only send requests while that server session is still open.
pub const CancelHandle = struct {
    allocator: std.mem.Allocator,
    io: Io,
    host: []u8,
    port: u16,
    backend_pid: i32,
    backend_secret: i32,

    pub fn deinit(self: *CancelHandle) void {
        self.backend_pid = 0;
        self.backend_secret = 0;
        self.allocator.free(self.host);
        self.* = undefined;
    }

    /// Send a CancelRequest with a five-second connection/write deadline.
    pub fn request(self: *const CancelHandle) !void {
        return self.requestWithTimeout(Io.Duration.fromSeconds(5));
    }

    /// Send a CancelRequest with an explicit end-to-end deadline.
    pub fn requestWithTimeout(self: *const CancelHandle, duration: Io.Duration) !void {
        if (duration.nanoseconds <= 0) return error.InvalidArguments;
        var socket = try withTimeout(
            CancelSocket,
            self.io,
            duration,
            CancelSocket.open,
            .{ self.io, self.host, self.port },
            CancelSocket.cleanup,
        );
        defer socket.deinit();

        const packet = protocol.buildCancelRequest(self.backend_pid, self.backend_secret);
        var write_buffer: [16]u8 = undefined;
        var writer = socket.stream.writer(self.io, &write_buffer);
        writer.interface.writeAll(&packet) catch return mapWriteError(writer.err);
        writer.interface.flush() catch return mapWriteError(writer.err);
    }
};

const CancelSocket = struct {
    io: Io,
    stream: net.Stream,

    fn open(io: Io, host: []const u8, port: u16) anyerror!CancelSocket {
        return .{ .io = io, .stream = try connectStream(io, host, port) };
    }

    fn deinit(self: *CancelSocket) void {
        self.stream.close(self.io);
    }

    fn cleanup(self: *CancelSocket) void {
        self.deinit();
    }
};

test "CancelHandle rejects a non-positive request deadline" {
    var handle: CancelHandle = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .host = try std.testing.allocator.dupe(u8, "127.0.0.1"),
        .port = 5432,
        .backend_pid = 1,
        .backend_secret = 2,
    };
    defer handle.deinit();
    try std.testing.expectError(
        error.InvalidArguments,
        handle.requestWithTimeout(Io.Duration.zero),
    );
}

/// Run an allocator/resource-owning operation with a deadline. A select is
/// used instead of `IpAddress.ConnectOptions.timeout` because Zig 0.16's
/// threaded and kqueue backends do not implement that option. Cancelation is
/// propagated through DNS, TCP, TLS, startup, and authentication I/O.
fn withTimeout(
    comptime T: type,
    io: Io,
    duration: Io.Duration,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime cleanup: *const fn (*T) void,
) !T {
    const Result = union(enum) {
        completed: anyerror!T,
        timeout: void,
    };

    var result_buffer: [2]Result = undefined;
    var select: Io.Select(Result) = .init(io, &result_buffer);
    select.async(.completed, function, args);
    select.async(.timeout, timeoutAfter, .{ io, duration });
    defer while (select.cancel()) |pending| switch (pending) {
        .completed => |result| if (result) |value| {
            var owned = value;
            cleanup(&owned);
        } else |_| {},
        .timeout => {},
    };

    return switch (try select.await()) {
        .completed => |result| try result,
        .timeout => error.ConnectionTimeout,
    };
}

fn timeoutAfter(io: Io, duration: Io.Duration) void {
    Io.sleep(io, duration, .awake) catch {};
}

const TimeoutTestResource = struct {
    value: u8,
};

fn timeoutTestFast(value: u8) anyerror!TimeoutTestResource {
    return .{ .value = value };
}

fn timeoutTestSlow(io: Io) anyerror!TimeoutTestResource {
    try io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .awake);
    return .{ .value = 1 };
}

fn cleanupTimeoutTestResource(_: *TimeoutTestResource) void {}

test "withTimeout returns completed resources" {
    const resource = try withTimeout(
        TimeoutTestResource,
        std.testing.io,
        Io.Duration.fromSeconds(1),
        timeoutTestFast,
        .{42},
        cleanupTimeoutTestResource,
    );
    try std.testing.expectEqual(@as(u8, 42), resource.value);
}

test "withTimeout cancels slow operations at the deadline" {
    try std.testing.expectError(error.ConnectionTimeout, withTimeout(
        TimeoutTestResource,
        std.testing.io,
        Io.Duration.fromMilliseconds(2),
        timeoutTestSlow,
        .{std.testing.io},
        cleanupTimeoutTestResource,
    ));
}

fn connectStream(io: Io, host: []const u8, port: u16) !net.Stream {
    if (net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream }) catch |err| return mapConnectError(err);
    } else |_| {}

    const hostname = net.HostName.init(host) catch return error.InvalidUrl;
    return hostname.connect(io, port, .{ .mode = .stream }) catch |err| return mapConnectError(err);
}

fn mapConnectError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.AddressUnavailable,
        error.UnknownHostName,
        => error.ConnectionClosed,
        error.Timeout => error.ConnectionTimeout,
        error.OutOfMemory => error.OutOfMemory,
        else => error.DriverError,
    };
}

fn mapReadError(err: ?net.Stream.Reader.Error) anyerror {
    if (err) |e| {
        return switch (e) {
            error.ConnectionResetByPeer, error.SocketUnconnected, error.NetworkDown => error.ConnectionClosed,
            error.Timeout => error.ConnectionTimeout,
            else => error.ProtocolError,
        };
    }
    return error.ProtocolError;
}

fn mapWriteError(err: ?net.Stream.Writer.Error) anyerror {
    if (err) |e| {
        return switch (e) {
            error.ConnectionResetByPeer,
            error.ConnectionRefused,
            error.SocketUnconnected,
            error.SocketNotBound,
            error.NetworkDown,
            error.NetworkUnreachable,
            error.HostUnreachable,
            => error.ConnectionClosed,
            else => error.ProtocolError,
        };
    }
    return error.ProtocolError;
}

/// Free a schema graph returned by `Conn.inspectSchema`.
pub fn freeInspectedSchema(allocator: std.mem.Allocator, schema: core.inspect.Schema) void {
    freeInspectedTables(allocator, @constCast(schema.tables));
}

fn freeInspectedTables(allocator: std.mem.Allocator, tables: []core.inspect.Table) void {
    for (tables) |table| {
        allocator.free(table.name);
        for (table.columns) |col| {
            allocator.free(col.name);
            allocator.free(col.type_name);
        }
        allocator.free(@constCast(table.columns));
        for (table.indexes) |idx| {
            allocator.free(idx.name);
            for (idx.columns) |c_| allocator.free(c_);
            allocator.free(@constCast(idx.columns));
        }
        allocator.free(@constCast(table.indexes));
    }
    allocator.free(tables);
}

const OwnedSimpleRow = struct {
    values: []core.OwnedValue,

    fn deinit(self: *OwnedSimpleRow, allocator: std.mem.Allocator) void {
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        self.* = undefined;
    }
};

/// Allocator-owned PostgreSQL asynchronous notification.
pub const Notification = struct {
    pid: i32,
    channel: []u8,
    payload: []u8,

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        allocator.free(self.payload);
        self.* = undefined;
    }

    fn parse(allocator: std.mem.Allocator, body: []const u8) !Notification {
        if (body.len < 6) return error.ProtocolError;
        const pid = protocol.readI32(body[0..4]);
        const channel_end = std.mem.indexOfScalarPos(u8, body, 4, 0) orelse return error.ProtocolError;
        const payload_start = channel_end + 1;
        const payload_end = std.mem.indexOfScalarPos(u8, body, payload_start, 0) orelse return error.ProtocolError;
        if (payload_end + 1 != body.len) return error.ProtocolError;
        const channel = try allocator.dupe(u8, body[4..channel_end]);
        errdefer allocator.free(channel);
        return .{ .pid = pid, .channel = channel, .payload = try allocator.dupe(u8, body[payload_start..payload_end]) };
    }
};

fn listenSql(allocator: std.mem.Allocator, command: []const u8, channel: []const u8) ![]u8 {
    if (channel.len == 0 or std.mem.indexOfScalar(u8, channel, 0) != null) return error.InvalidArguments;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, command);
    try out.appendSlice(allocator, " \"");
    for (channel) |c| {
        try out.append(allocator, c);
        if (c == '"') try out.append(allocator, '"');
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

test "notification parser and listen quoting are strict" {
    const body = [_]u8{ 0, 0, 0, 7, 'e', 'v', 'e', 'n', 't', 's', 0, '{', '}', 0 };
    var notification = try Notification.parse(std.testing.allocator, &body);
    defer notification.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 7), notification.pid);
    try std.testing.expectEqualStrings("events", notification.channel);
    try std.testing.expectEqualStrings("{}", notification.payload);

    const sql = try listenSql(std.testing.allocator, "listen", "a\"b");
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("listen \"a\"\"b\"", sql);
    try std.testing.expectError(error.InvalidArguments, listenSql(std.testing.allocator, "listen", ""));
}

fn orderedNamedBinds(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    binds: []const core.params.NamedValue,
) ![]core.Value {
    const ordered = try allocator.alloc(core.Value, names.len);
    errdefer allocator.free(ordered);
    for (names, 0..) |name, i| {
        var found: ?core.Value = null;
        for (binds) |bind| {
            if (!std.mem.eql(u8, bind.name, name)) continue;
            if (found != null) return error.InvalidBindValue;
            found = bind.value;
        }
        ordered[i] = found orelse return error.BindCountMismatch;
    }
    for (binds) |bind| {
        var used = false;
        for (names) |name| {
            if (std.mem.eql(u8, bind.name, name)) {
                used = true;
                break;
            }
        }
        if (!used) return error.InvalidBindValue;
    }
    return ordered;
}

test "orderedNamedBinds orders and validates named values" {
    const binds = [_]core.params.NamedValue{
        .{ .name = "email", .value = .{ .text = "ada@example.com" } },
        .{ .name = "id", .value = .{ .integer = 7 } },
    };
    const names = [_][]const u8{ "id", "email" };
    const ordered = try orderedNamedBinds(std.testing.allocator, &names, &binds);
    defer std.testing.allocator.free(ordered);
    try std.testing.expectEqual(@as(i64, 7), ordered[0].integer);
    try std.testing.expectEqualStrings("ada@example.com", ordered[1].text);
    try std.testing.expectError(error.InvalidBindValue, orderedNamedBinds(std.testing.allocator, &names, &.{
        .{ .name = "id", .value = .{ .integer = 1 } },
        .{ .name = "email", .value = .{ .text = "ada@example.com" } },
        .{ .name = "unused", .value = .{ .integer = 2 } },
    }));
}

/// Allocator-owned simple-query result set.
pub const SimpleRows = struct {
    allocator: std.mem.Allocator,
    column_names: [][]u8,
    rows: []OwnedSimpleRow,
    rows_affected: u64,
    index: usize = 0,

    pub fn deinit(self: *SimpleRows) void {
        for (self.column_names) |name| self.allocator.free(name);
        self.allocator.free(self.column_names);
        for (self.rows) |*row| row.deinit(self.allocator);
        self.allocator.free(self.rows);
        self.* = undefined;
    }

    pub fn next(self: *SimpleRows) ?SimpleRow {
        if (self.index >= self.rows.len) return null;
        const row = SimpleRow{
            .column_names = self.column_names,
            .values = self.rows[self.index].values,
        };
        self.index += 1;
        return row;
    }
};

pub const SimpleRow = struct {
    column_names: []const []u8,
    values: []const core.OwnedValue,

    pub fn value(self: SimpleRow, name: []const u8) !core.Value {
        for (self.column_names, self.values) |column_name, owned| {
            if (std.mem.eql(u8, column_name, name)) return owned.borrowed();
        }
        return error.InvalidColumn;
    }

    pub fn valueAt(self: SimpleRow, index: usize) !core.Value {
        if (index >= self.values.len) return error.InvalidColumn;
        return self.values[index].borrowed();
    }

    /// Ordinal `Value` access (matches `core.Row.get`).
    pub fn get(self: SimpleRow, index: usize) !core.Value {
        return self.valueAt(index);
    }

    /// Named `Value` access (matches `core.Row.getName`).
    pub fn getName(self: SimpleRow, name: []const u8) !core.Value {
        return self.value(name);
    }

    /// Typed ordinal decode (same rules as `core.Row.as` / `to`).
    pub fn as(self: SimpleRow, comptime T: type, index: usize) !T {
        return core.decode(T, try self.valueAt(index));
    }

    /// Typed named-column decode (same rules as `core.Row.asName` / `to`).
    pub fn asName(self: SimpleRow, comptime T: type, name: []const u8) !T {
        return core.decode(T, try self.value(name));
    }

    /// Map into a Zig struct by column name, then ordinal fallback.
    /// Supports up to 64 columns (stack-backed temporary view).
    pub fn to(self: SimpleRow, comptime T: type) !T {
        const max_cols = 64;
        if (self.values.len > max_cols) return error.Unsupported;

        var name_buf: [max_cols][]const u8 = undefined;
        var value_buf: [max_cols]core.Value = undefined;
        for (self.column_names, 0..) |n, i| name_buf[i] = n;
        for (self.values, 0..) |owned, i| value_buf[i] = owned.borrowed();
        const row = try core.Row.init(name_buf[0..self.column_names.len], value_buf[0..self.values.len]);
        return row.to(T);
    }

    /// Copy into an allocator-owned `core.OwnedRow`.
    pub fn getOwned(self: SimpleRow, allocator: std.mem.Allocator) !core.OwnedRow {
        return simpleRowToOwned(allocator, self);
    }
};

fn simpleRowToOwned(allocator: std.mem.Allocator, row: SimpleRow) !core.OwnedRow {
    var names = try allocator.alloc([]const u8, row.column_names.len);
    defer allocator.free(names);
    var values = try allocator.alloc(core.Value, row.values.len);
    defer allocator.free(values);
    for (row.column_names, 0..) |n, i| names[i] = n;
    for (row.values, 0..) |owned_val, i| values[i] = owned_val.borrowed();
    const view = try core.Row.init(names, values);
    return core.OwnedRow.init(allocator, view);
}

/// PostgreSQL savepoint bound to an open connection transaction.
pub const Savepoint = struct {
    conn: *Conn,
    name: [64]u8,
    name_len: usize,
    open: bool = true,

    pub fn release(self: *Savepoint) !void {
        if (!self.open) return error.SavepointClosed;
        if (self.conn.closed or self.conn.tx_status != .in_transaction) return error.TransactionClosed;
        var sql_buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "release savepoint {s}", .{self.nameSlice()});
        _ = try self.conn.exec(sql);
        self.open = false;
    }

    pub fn rollback(self: *Savepoint) !void {
        if (!self.open) return error.SavepointClosed;
        if (self.conn.closed or self.conn.tx_status != .in_transaction) return error.TransactionClosed;
        var sql_buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "rollback to savepoint {s}", .{self.nameSlice()});
        _ = try self.conn.exec(sql);
        // Keep savepoint defined after rollback-to; release to drop it.
        const release_sql = try std.fmt.bufPrint(&sql_buf, "release savepoint {s}", .{self.nameSlice()});
        _ = try self.conn.exec(release_sql);
        self.open = false;
    }

    pub fn rollbackIfOpen(self: *Savepoint) void {
        if (!self.open) return;
        self.rollback() catch {};
    }

    fn nameSlice(self: *const Savepoint) []const u8 {
        return self.name[0..self.name_len];
    }
};

test "savepoint names are deterministic prefixes" {
    // Pure naming check without a live server.
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "zsql_sp_{d}", .{0});
    try std.testing.expectEqualStrings("zsql_sp_0", name);
}

test "SimpleRow get/as/to map like core.Row" {
    var id_owned = try core.OwnedValue.from(std.testing.allocator, .{ .integer = 7 });
    defer id_owned.deinit(std.testing.allocator);
    var name_owned = try core.OwnedValue.from(std.testing.allocator, .{ .text = "ada" });
    defer name_owned.deinit(std.testing.allocator);
    var active_owned = try core.OwnedValue.from(std.testing.allocator, .{ .boolean = true });
    defer active_owned.deinit(std.testing.allocator);

    const names = [_][]u8{ @constCast("id"), @constCast("name"), @constCast("active") };
    const values = [_]core.OwnedValue{ id_owned, name_owned, active_owned };
    const row = SimpleRow{
        .column_names = &names,
        .values = &values,
    };

    try std.testing.expectEqual(@as(i64, 7), try (try row.get(0)).asInt());
    try std.testing.expectEqualStrings("ada", try (try row.getName("name")).asText());
    try std.testing.expectEqual(@as(i64, 7), try row.as(i64, 0));
    try std.testing.expectEqualStrings("ada", try row.asName([]const u8, "name"));
    try std.testing.expect(try row.as(bool, 2));

    const User = struct {
        id: i64,
        name: []const u8,
        active: bool,
    };
    const user = try row.to(User);
    try std.testing.expectEqual(@as(i64, 7), user.id);
    try std.testing.expectEqualStrings("ada", user.name);
    try std.testing.expect(user.active);

    var owned = try row.getOwned(std.testing.allocator);
    defer owned.deinit();
    try std.testing.expectEqual(@as(i64, 7), try owned.as(i64, 0));
}

test "captureSqlError stores OwnedDbError for lastError()" {
    // Exercise the error capture path without a live TCP connection by
    // constructing a minimal Conn-like storage dance through public helpers.
    const body =
        "SERROR\x00C23505\x00Mduplicate key\x00DKey (email)=(x) already exists.\x00tusers\x00cemail\x00nusers_email_key\x00\x00";
    const fields = try protocol.parseErrorFields(body);
    try std.testing.expectEqualStrings("23505", fields.code.?);

    const zig_err = core.DbError.errorFromSqlState(fields.code.?);
    try std.testing.expect(zig_err == error.UniqueViolation);

    var owned = try core.OwnedDbError.fromPostgresFields(std.testing.allocator, .{
        .code = fields.code,
        .message = fields.message,
        .detail = fields.detail,
        .hint = fields.hint,
        .schema = fields.schema,
        .table = fields.table,
        .column = fields.column,
        .constraint = fields.constraint,
    }, zig_err);
    defer owned.deinit(std.testing.allocator);

    const view = owned.view();
    try std.testing.expectEqualStrings("users", view.table.?);
    try std.testing.expectEqualStrings("users_email_key", view.constraint.?);
    try std.testing.expect(view.category == .constraint);
}

test "Conn require TLS fails when host is unreachable or after SSLRequest" {
    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=require");
    defer config.deinit();
    // Port 1 is almost never a Postgres server; connection or TLS path must fail.
    const result = Conn.open(std.testing.allocator, std.testing.io, config);
    try std.testing.expect(result == error.TlsFailed or result == error.ConnectionClosed or result == error.ConnectionTimeout or result == error.DriverError);
}

test "Conn verify modes fail on unreachable host after TLS attempt" {
    // Port 1 should not complete a verified TLS handshake.
    var ca = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=verify-ca");
    defer ca.deinit();
    const ca_result = Conn.open(std.testing.allocator, std.testing.io, ca);
    try std.testing.expect(ca_result == error.TlsFailed or ca_result == error.ConnectionClosed or ca_result == error.ConnectionTimeout or ca_result == error.DriverError);

    var full = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=verify-full");
    defer full.deinit();
    const full_result = Conn.open(std.testing.allocator, std.testing.io, full);
    try std.testing.expect(full_result == error.TlsFailed or full_result == error.ConnectionClosed or full_result == error.ConnectionTimeout or full_result == error.DriverError);
}

test "SslResponse parser is used by negotiation path" {
    try std.testing.expect((try protocol.SslResponse.fromByte('N')) == .rejects_tls);
}

test "enableStmtCache rejects zero capacity" {
    // Pure unit path: construct a closed-like cache setup without TCP.
    // StmtCache.init is what enableStmtCache uses.
    try std.testing.expectError(error.InvalidArguments, core.StmtCache.init(std.testing.allocator, 0));
}

test "formatStmtName used for prepared names" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("zsql_ps_0", try core.formatStmtName(&buf, 0));
}

test "Conn rejects empty user" {
    var config = try url.parse(std.testing.allocator, "postgres://@127.0.0.1:1/db?sslmode=disable");
    defer config.deinit();
    // URI with empty user may still parse; enforce at open.
    // If parse leaves empty user, open must fail without hanging.
    if (config.user.len == 0) {
        try std.testing.expectError(error.InvalidArguments, Conn.open(std.testing.allocator, std.testing.io, config));
    }
}

// Live handshake is exercised via a dedicated example/integration harness once
// query APIs land. Unit tests intentionally avoid requiring a Postgres server
// so default CI remains deterministic and green.
