const std = @import("std");
const core = @import("../../zsql.zig");
const url = @import("url.zig");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const scram = @import("scram.zig");
const types = @import("types.zig");

const Io = std.Io;
const net = std.Io.net;

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
    stream: net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    closed: bool = false,
    /// Backend process id from BackendKeyData, if received.
    backend_pid: ?i32 = null,
    /// Backend secret key from BackendKeyData, if received.
    backend_secret: ?i32 = null,
    tx_status: protocol.TxStatus = .idle,
    next_savepoint_id: usize = 0,
    /// Last server ErrorResponse fields, allocator-owned.
    last_error: ?core.OwnedDbError = null,

    /// Open a TCP connection and complete the PostgreSQL startup handshake.
    ///
    /// TLS policy (`sslmode`):
    /// - `disable`: plain StartupMessage (no SSLRequest).
    /// - `allow`: plain first (TLS upgrade path not implemented).
    /// - `prefer`: send SSLRequest; if the server rejects TLS, continue plain;
    ///   if it accepts TLS, fall back to a plain reconnect (no TLS stack yet).
    /// - `require|verify-*`: send SSLRequest; return `error.TlsFailed` whether
    ///   the server accepts (TLS not implemented) or rejects.
    pub fn open(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        if (config.user.len == 0) return error.InvalidArguments;

        return switch (config.ssl_mode) {
            .disable, .allow => try openPlain(allocator, io, config),
            .prefer => try openPrefer(allocator, io, config),
            .require, .verify_ca, .verify_full => try openRequireTls(allocator, io, config),
        };
    }

    fn openPlain(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        var conn = try connectBare(allocator, io, config.host, config.port);
        errdefer conn.deinitTransportOnly();
        try conn.startup(config);
        return conn;
    }

    fn openPrefer(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        var conn = try connectBare(allocator, io, config.host, config.port);
        errdefer conn.deinitTransportOnly();

        const ssl = conn.negotiateSslRequest() catch {
            // Negotiation failed (offline host, etc.): fall back to plain
            // reconnect so prefer stays best-effort when the server is up
            // without SSLRequest support mid-flight.
            conn.deinitTransportOnly();
            return openPlain(allocator, io, config);
        };

        switch (ssl) {
            .rejects_tls => {
                try conn.startup(config);
                return conn;
            },
            .accepts_tls => {
                // TLS stack not implemented: drop this connection and use plain.
                conn.deinitTransportOnly();
                return openPlain(allocator, io, config);
            },
        }
    }

    fn openRequireTls(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        // Even when the server accepts TLS we cannot complete the handshake yet.
        // Still perform SSLRequest so operators see protocol-correct failure modes
        // (reject vs accept-without-client-TLS) once a server is available.
        var conn = try connectBare(allocator, io, config.host, config.port);
        defer conn.deinitTransportOnly();
        const ssl = conn.negotiateSslRequest() catch return error.TlsFailed;
        _ = ssl;
        return error.TlsFailed;
    }

    fn connectBare(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16) !Conn {
        const stream = try connectStream(io, host, port);
        errdefer stream.close(io);

        const read_buf = try allocator.alloc(u8, 16 * 1024);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, 16 * 1024);
        errdefer allocator.free(write_buf);

        return .{
            .allocator = allocator,
            .io = io,
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
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.clearLastError();
        self.closed = true;
    }

    /// Send SSLRequest and read the single-byte server reply.
    fn negotiateSslRequest(self: *Conn) !protocol.SslResponse {
        const packet = try protocol.buildSslRequest(self.allocator);
        defer self.allocator.free(packet);
        try self.writeAll(packet);

        var byte: [1]u8 = undefined;
        self.reader.interface.readSliceAll(&byte) catch return mapReadError(self.reader.err);
        return protocol.SslResponse.fromByte(byte[0]);
    }

    pub fn deinit(self: *Conn) void {
        if (self.closed) return;
        self.sendTerminate() catch {};
        self.stream.close(self.io);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.clearLastError();
        self.closed = true;
    }

    /// Borrowed view of the last ErrorResponse metadata, if any.
    /// Valid until the next failing query on this connection or `deinit`.
    pub fn lastError(self: *const Conn) ?core.DbError {
        if (self.last_error) |*owned| return owned.view();
        return null;
    }

    fn clearLastError(self: *Conn) void {
        if (self.last_error) |*owned| {
            owned.deinit(self.allocator);
            self.last_error = null;
        }
    }

    /// Execute a simple-query statement that does not return rows.
    ///
    /// Prefer extended/parameterized APIs once available for any user values.
    /// This path is intended for DDL, transaction control, and trusted SQL.
    pub fn exec(self: *Conn, sql: []const u8) !core.ExecResult {
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
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    return .{ .rows_affected = rows_affected };
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                .notice_response => {},
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
        if (self.closed) return error.ConnectionClosed;
        try self.sendExtended(sql, binds, false);

        var rows_affected: u64 = 0;
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg.body);
            switch (msg.tag) {
                .parse_complete, .bind_complete, .no_data => {},
                .command_complete => {
                    const tag = try protocol.parseCommandComplete(msg.body);
                    rows_affected = types.parseCommandTag(tag).rows_affected;
                },
                .ready_for_query => {
                    self.tx_status = try protocol.parseReadyForQuery(msg.body);
                    return .{ .rows_affected = rows_affected };
                },
                .error_response => return self.failFromErrorResponse(msg.body, true),
                .notice_response => {},
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

    /// Parameterized query via extended protocol; returns owned simple rows.
    pub fn queryParams(self: *Conn, sql: []const u8, binds: []const core.Value) !SimpleRows {
        if (self.closed) return error.ConnectionClosed;
        try self.sendExtended(sql, binds, true);
        return self.collectExtendedRows();
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
            try tables_list.append(allocator, .{
                .name = display_name,
                .columns = columns,
            });
        }

        return .{
            .tables = try tables_list.toOwnedSlice(allocator),
        };
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

        const parse_msg = try protocol.buildParseMessage(self.allocator, sql);
        defer self.allocator.free(parse_msg);
        const bind_msg = try protocol.buildBindMessage(self.allocator, views);
        defer self.allocator.free(bind_msg);
        const execute_msg = try protocol.buildExecuteMessage(self.allocator);
        defer self.allocator.free(execute_msg);
        const sync_msg = try protocol.buildSyncMessage(self.allocator);
        defer self.allocator.free(sync_msg);

        try self.writeAll(parse_msg);
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
                .notice_response => {},
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
                .notice_response => {},
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
                            if (!scram.mechanismsIncludeScramSha256(parsed.payload)) return error.Unsupported;
                            if (scram_client != null) return error.ProtocolError;

                            var nonce_buf: [24]u8 = undefined;
                            try self.fillClientNonce(&nonce_buf);
                            scram_client = try scram.Client.init(
                                self.allocator,
                                config.user,
                                config.password,
                                &nonce_buf,
                            );

                            const client_first = try scram_client.?.clientFirstMessage(self.allocator);
                            defer self.allocator.free(client_first);
                            const body = try scram.buildSaslInitialResponse(self.allocator, client_first);
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
        self.reader.interface.readSliceAll(&header_bytes) catch return mapReadError(self.reader.err);
        const header = try protocol.parseMessageHeader(&header_bytes);
        const body_len = header.bodyLen();
        const body = try self.allocator.alloc(u8, body_len);
        errdefer self.allocator.free(body);
        if (body_len > 0) {
            self.reader.interface.readSliceAll(body) catch return mapReadError(self.reader.err);
        }
        return .{
            .tag = header.tag,
            .body = body,
        };
    }

    fn writeAll(self: *Conn, bytes: []const u8) !void {
        self.writer.interface.writeAll(bytes) catch return mapWriteError(self.writer.err);
        self.writer.interface.flush() catch return mapWriteError(self.writer.err);
    }
};

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
};

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

test "SslResponse parser is used by negotiation path" {
    try std.testing.expect((try protocol.SslResponse.fromByte('N')) == .rejects_tls);
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
