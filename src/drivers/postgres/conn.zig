const std = @import("std");
const url = @import("url.zig");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");

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
