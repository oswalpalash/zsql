const std = @import("std");
const core = @import("../../zsql.zig");
const url = @import("url.zig");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const types = @import("types.zig");

const Io = std.Io;
const net = std.Io.net;

/// Live PostgreSQL connection after a successful startup handshake.
///
/// Ownership:
/// - Caller owns `Config` independently of `Conn`.
/// - `Conn` owns the TCP stream and I/O buffers; call `deinit`.
/// - Password material is never stored on `Conn` after handshake.
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

    /// Open a TCP connection and complete the PostgreSQL startup handshake.
    ///
    /// TLS is not implemented yet:
    /// - `sslmode=disable|allow|prefer` connects in plain text.
    /// - `sslmode=require|verify-ca|verify-full` returns `error.TlsFailed`.
    pub fn open(allocator: std.mem.Allocator, io: Io, config: url.Config) !Conn {
        switch (config.ssl_mode) {
            .disable, .allow, .prefer => {},
            .require, .verify_ca, .verify_full => return error.TlsFailed,
        }
        if (config.user.len == 0) return error.InvalidArguments;

        const stream = try connectStream(io, config.host, config.port);
        errdefer stream.close(io);

        const read_buf = try allocator.alloc(u8, 16 * 1024);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, 16 * 1024);
        errdefer allocator.free(write_buf);

        var conn: Conn = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
        };

        try conn.startup(config);
        return conn;
    }

    pub fn deinit(self: *Conn) void {
        if (self.closed) return;
        self.sendTerminate() catch {};
        self.stream.close(self.io);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.closed = true;
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
                .error_response => return mapSqlError(msg.body),
                .notice_response => {},
                .row_description, .data_row => return error.UnexpectedRow,
                else => return error.ProtocolError,
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
                .error_response => return mapSqlError(msg.body),
                .notice_response => {},
                .row_description, .data_row => return error.UnexpectedRow,
                else => return error.ProtocolError,
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
                .error_response => return mapSqlError(msg.body),
                .notice_response => {},
                else => return error.ProtocolError,
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
                .error_response => return mapSqlError(msg.body),
                .notice_response => {},
                else => return error.ProtocolError,
            }
        }
    }

    fn startup(self: *Conn, config: url.Config) !void {
        const startup_msg = try protocol.buildStartupMessage(self.allocator, config);
        defer self.allocator.free(startup_msg);
        try self.writeAll(startup_msg);

        var authenticated = false;
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
                        .sasl, .sasl_continue, .sasl_final => return error.Unsupported,
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
                    const fields = try protocol.parseErrorFields(msg.body);
                    // Prefer auth-ish failures when a SQLSTATE is present.
                    if (fields.code) |code| {
                        if (std.mem.eql(u8, code, "28P01") or std.mem.eql(u8, code, "28000")) {
                            return error.AuthFailed;
                        }
                    }
                    return error.AuthFailed;
                },
                .notice_response => {},
                .negotiate_protocol_version => return error.ProtocolError,
                else => return error.ProtocolError,
            }
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

fn mapSqlError(body: []const u8) anyerror {
    const fields = protocol.parseErrorFields(body) catch return error.DriverError;
    if (fields.code) |code| {
        if (std.mem.eql(u8, code, "23505")) return error.ConstraintViolation;
        if (std.mem.eql(u8, code, "23503")) return error.ConstraintViolation;
        if (std.mem.eql(u8, code, "23502")) return error.ConstraintViolation;
        if (std.mem.eql(u8, code, "23514")) return error.ConstraintViolation;
        if (std.mem.eql(u8, code, "40P01")) return error.DriverError;
        if (std.mem.eql(u8, code, "40001")) return error.DriverError;
        if (std.mem.eql(u8, code, "28P01") or std.mem.eql(u8, code, "28000")) return error.AuthFailed;
        if (std.mem.eql(u8, code, "42601")) return error.InvalidSql;
        if (std.mem.eql(u8, code, "42P01")) return error.InvalidSql;
    }
    return error.DriverError;
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

test "Conn rejects TLS-required configs before connecting" {
    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=require");
    defer config.deinit();
    try std.testing.expectError(error.TlsFailed, Conn.open(std.testing.allocator, std.testing.io, config));
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
