const std = @import("std");
const url = @import("url.zig");

/// Frontend/backend message tags used by the PostgreSQL wire protocol.
/// Only the subset needed for startup, auth, simple query, and extended query
/// is listed here; additional tags land with the features that need them.
pub const FrontendTag = enum(u8) {
    bind = 'B',
    close = 'C',
    describe = 'D',
    execute = 'E',
    flush = 'H',
    parse = 'P',
    query = 'Q',
    sync = 'S',
    terminate = 'X',
    copy_data = 'd',
    copy_done = 'c',
    copy_fail = 'f',
    password = 'p',
};

pub const BackendTag = enum(u8) {
    authentication = 'R',
    backend_key_data = 'K',
    bind_complete = '2',
    close_complete = '3',
    command_complete = 'C',
    copy_data = 'd',
    copy_done = 'c',
    copy_in_response = 'G',
    copy_out_response = 'H',
    data_row = 'D',
    empty_query_response = 'I',
    error_response = 'E',
    no_data = 'n',
    notice_response = 'N',
    notification_response = 'A',
    parameter_description = 't',
    parameter_status = 'S',
    parse_complete = '1',
    portal_suspended = 's',
    ready_for_query = 'Z',
    row_description = 'T',
    negotiate_protocol_version = 'v',

    pub fn fromByte(byte: u8) !BackendTag {
        return enumFromInt(BackendTag, byte) orelse error.ProtocolError;
    }
};

/// Authentication request codes from Authentication* backend messages.
pub const AuthKind = enum(i32) {
    ok = 0,
    kerberos_v5 = 2,
    cleartext_password = 3,
    md5_password = 5,
    scm_credential = 6,
    gss = 7,
    gss_continue = 8,
    sspi = 9,
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,

    pub fn fromInt(value: i32) !AuthKind {
        return enumFromInt(AuthKind, value) orelse error.Unsupported;
    }
};

/// Protocol version 3.0 encoded as (3 << 16) | 0.
pub const protocol_version_3: i32 = 196608;

/// SSLRequest code used before startup when TLS may be negotiated.
pub const ssl_request_code: i32 = 80877103;

/// Build a StartupMessage payload (no type byte; length-prefixed only).
///
/// Format: Int32 len | Int32 protocol | (key\0 value\0)* | \0
pub fn buildStartupMessage(allocator: std.mem.Allocator, config: url.Config) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    // Placeholder for length; filled after the body is written.
    try list.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
    try appendI32(&list, allocator, protocol_version_3);

    try appendCString(&list, allocator, "user");
    try appendCString(&list, allocator, config.user);
    if (config.database.len > 0) {
        try appendCString(&list, allocator, "database");
        try appendCString(&list, allocator, config.database);
    }
    if (config.application_name.len > 0) {
        try appendCString(&list, allocator, "application_name");
        try appendCString(&list, allocator, config.application_name);
    }
    try appendCString(&list, allocator, "client_encoding");
    try appendCString(&list, allocator, "UTF8");

    // Terminator for the parameter list.
    try list.append(allocator, 0);

    writeI32(list.items[0..4], @intCast(list.items.len));
    return try list.toOwnedSlice(allocator);
}

/// Build an SSLRequest packet (8 bytes: length + code).
pub fn buildSslRequest(allocator: std.mem.Allocator) ![]u8 {
    var out = try allocator.alloc(u8, 8);
    writeI32(out[0..4], 8);
    writeI32(out[4..8], ssl_request_code);
    return out;
}

/// Build a typed frontend message: Byte tag | Int32 len | body.
/// `len` includes itself but not the tag.
pub fn buildMessage(allocator: std.mem.Allocator, tag: FrontendTag, body: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, 1 + 4 + body.len);
    out[0] = @intFromEnum(tag);
    writeI32(out[1..5], @intCast(4 + body.len));
    @memcpy(out[5..], body);
    return out;
}

/// Build a simple Query ('Q') message.
pub fn buildQueryMessage(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try appendCString(&body, allocator, sql);
    return buildMessage(allocator, .query, body.items);
}

/// Build a PasswordMessage ('p') for cleartext authentication.
pub fn buildPasswordMessage(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try appendCString(&body, allocator, password);
    return buildMessage(allocator, .password, body.items);
}

/// Build Parse ('P') for the unnamed statement with unspecified parameter types.
pub fn buildParseMessage(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try appendCString(&body, allocator, ""); // statement name
    try appendCString(&body, allocator, sql);
    try appendI16(&body, allocator, 0); // parameter type count
    return buildMessage(allocator, .parse, body.items);
}

/// Build Bind ('B') for the unnamed portal/statement using text-format values.
///
/// Each bind is either `null` (SQL NULL) or UTF-8 text bytes. Values are never
/// interpolated into SQL; they travel only in the bind payload.
pub fn buildBindMessage(allocator: std.mem.Allocator, binds: []const ?[]const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    try appendCString(&body, allocator, ""); // portal
    try appendCString(&body, allocator, ""); // statement
    try appendI16(&body, allocator, 0); // param format count (all text)
    try appendI16(&body, allocator, try castI16(binds.len));
    for (binds) |bind| {
        if (bind) |bytes| {
            try appendI32(&body, allocator, try castI32(bytes.len));
            try body.appendSlice(allocator, bytes);
        } else {
            try appendI32(&body, allocator, -1);
        }
    }
    try appendI16(&body, allocator, 0); // result format count (all text)
    return buildMessage(allocator, .bind, body.items);
}

/// Build Describe ('D') for the unnamed portal.
pub fn buildDescribePortalMessage(allocator: std.mem.Allocator) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try body.append(allocator, 'P');
    try appendCString(&body, allocator, "");
    return buildMessage(allocator, .describe, body.items);
}

/// Build Execute ('E') for the unnamed portal with no row limit.
pub fn buildExecuteMessage(allocator: std.mem.Allocator) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try appendCString(&body, allocator, "");
    try appendI32(&body, allocator, 0);
    return buildMessage(allocator, .execute, body.items);
}

/// Build Sync ('S').
pub fn buildSyncMessage(allocator: std.mem.Allocator) ![]u8 {
    return buildMessage(allocator, .sync, &.{});
}

fn castI16(value: usize) !i16 {
    return std.math.cast(i16, value) orelse error.InvalidBindValue;
}

fn castI32(value: usize) !i32 {
    return std.math.cast(i32, value) orelse error.InvalidBindValue;
}

/// Parse the common backend header: tag + length. `length` is the Int32 from
/// the wire (includes itself, excludes the tag). Body size is `length - 4`.
pub const MessageHeader = struct {
    tag: BackendTag,
    /// Full message length field from the wire (includes the 4-byte length).
    length: u32,

    pub fn bodyLen(self: MessageHeader) u32 {
        return self.length -| 4;
    }
};

pub fn parseMessageHeader(bytes: *const [5]u8) !MessageHeader {
    const tag = try BackendTag.fromByte(bytes[0]);
    const length = readU32(bytes[1..5]);
    if (length < 4) return error.ProtocolError;
    return .{
        .tag = tag,
        .length = length,
    };
}

/// Parse Authentication* body starting after the message header.
/// Returns the auth kind and any remaining payload (e.g. MD5 salt).
pub fn parseAuthenticationBody(body: []const u8) !struct { kind: AuthKind, payload: []const u8 } {
    if (body.len < 4) return error.ProtocolError;
    const kind = try AuthKind.fromInt(readI32(body[0..4]));
    return .{
        .kind = kind,
        .payload = body[4..],
    };
}

/// Parse ReadyForQuery body: single transaction status byte.
pub const TxStatus = enum(u8) {
    idle = 'I',
    in_transaction = 'T',
    failed = 'E',

    pub fn fromByte(byte: u8) !TxStatus {
        return enumFromInt(TxStatus, byte) orelse error.ProtocolError;
    }
};

fn enumFromInt(comptime E: type, value: anytype) ?E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (field.value == value) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseReadyForQuery(body: []const u8) !TxStatus {
    if (body.len != 1) return error.ProtocolError;
    return TxStatus.fromByte(body[0]);
}

/// Minimal ErrorResponse / NoticeResponse field map. Fields are borrowed from
/// the message body and valid only while that buffer lives.
pub const ErrorFields = struct {
    severity: ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    constraint: ?[]const u8 = null,
};

/// Field metadata from RowDescription. String slices borrow from the message body.
pub const FieldDescription = struct {
    name: []const u8,
    table_oid: i32,
    column_attr: i16,
    type_oid: i32,
    type_size: i16,
    type_modifier: i32,
    format: i16,
};

/// Parse RowDescription body into field metadata. Field names borrow from `body`.
pub fn parseRowDescription(body: []const u8, allocator: std.mem.Allocator) ![]FieldDescription {
    if (body.len < 2) return error.ProtocolError;
    const count_u = @as(u16, @bitCast(readI16(body[0..2])));
    const count: usize = count_u;

    const fields = try allocator.alloc(FieldDescription, count);
    errdefer allocator.free(fields);

    var offset: usize = 2;
    for (fields) |*field| {
        const zero = std.mem.indexOfScalarPos(u8, body, offset, 0) orelse return error.ProtocolError;
        const name = body[offset..zero];
        offset = zero + 1;
        if (offset + 18 > body.len) return error.ProtocolError;
        field.* = .{
            .name = name,
            .table_oid = readI32(body[offset..][0..4]),
            .column_attr = readI16(body[offset + 4 ..][0..2]),
            .type_oid = readI32(body[offset + 6 ..][0..4]),
            .type_size = readI16(body[offset + 10 ..][0..2]),
            .type_modifier = readI32(body[offset + 12 ..][0..4]),
            .format = readI16(body[offset + 16 ..][0..2]),
        };
        offset += 18;
    }
    return fields;
}

/// One column value from a DataRow. `bytes` is null for SQL NULL.
pub const DataColumn = struct {
    bytes: ?[]const u8,
};

/// Parse DataRow body. Column byte slices borrow from `body`.
pub fn parseDataRow(body: []const u8, allocator: std.mem.Allocator) ![]DataColumn {
    if (body.len < 2) return error.ProtocolError;
    const count_u = @as(u16, @bitCast(readI16(body[0..2])));
    const count: usize = count_u;

    const columns = try allocator.alloc(DataColumn, count);
    errdefer allocator.free(columns);

    var offset: usize = 2;
    for (columns) |*column| {
        if (offset + 4 > body.len) return error.ProtocolError;
        const len = readI32(body[offset..][0..4]);
        offset += 4;
        if (len < 0) {
            column.* = .{ .bytes = null };
            continue;
        }
        const ulen: usize = @intCast(len);
        if (offset + ulen > body.len) return error.ProtocolError;
        column.* = .{ .bytes = body[offset .. offset + ulen] };
        offset += ulen;
    }
    return columns;
}

/// Parse CommandComplete body: C-string tag.
pub fn parseCommandComplete(body: []const u8) ![]const u8 {
    if (body.len == 0) return error.ProtocolError;
    if (body[body.len - 1] != 0) {
        // Some servers may omit trailing NUL if length already bounds the tag.
        return body;
    }
    return body[0 .. body.len - 1];
}

pub fn parseErrorFields(body: []const u8) !ErrorFields {
    var fields: ErrorFields = .{};
    var rest = body;
    while (rest.len > 0) {
        const code = rest[0];
        if (code == 0) break;
        rest = rest[1..];
        const zero = std.mem.indexOfScalar(u8, rest, 0) orelse return error.ProtocolError;
        const value = rest[0..zero];
        rest = rest[zero + 1 ..];
        switch (code) {
            'S', 'V' => fields.severity = value,
            'C' => fields.code = value,
            'M' => fields.message = value,
            'D' => fields.detail = value,
            'H' => fields.hint = value,
            's' => fields.schema = value,
            't' => fields.table = value,
            'c' => fields.column = value,
            'n' => fields.constraint = value,
            else => {},
        }
    }
    return fields;
}

pub fn appendCString(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try list.appendSlice(allocator, value);
    try list.append(allocator, 0);
}

pub fn appendI32(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i32) !void {
    var buf: [4]u8 = undefined;
    writeI32(&buf, value);
    try list.appendSlice(allocator, &buf);
}

pub fn writeI32(dest: []u8, value: i32) void {
    std.debug.assert(dest.len >= 4);
    std.mem.writeInt(i32, dest[0..4], value, .big);
}

pub fn writeU32(dest: []u8, value: u32) void {
    std.debug.assert(dest.len >= 4);
    std.mem.writeInt(u32, dest[0..4], value, .big);
}

pub fn readI32(src: *const [4]u8) i32 {
    return std.mem.readInt(i32, src, .big);
}

pub fn readU32(src: *const [4]u8) u32 {
    return std.mem.readInt(u32, src, .big);
}

pub fn readI16(src: *const [2]u8) i16 {
    return std.mem.readInt(i16, src, .big);
}

test "build startup message encodes user database and encoding" {
    var config = try url.parse(std.testing.allocator, "postgres://ada@localhost:5432/appdb");
    defer config.deinit();

    const msg = try buildStartupMessage(std.testing.allocator, config);
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqual(@as(usize, readU32(msg[0..4])), msg.len);
    try std.testing.expectEqual(protocol_version_3, readI32(msg[4..8]));

    // Body after length+version should contain C-string pairs.
    try std.testing.expect(std.mem.indexOf(u8, msg, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "ada") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "database") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "appdb") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "client_encoding") != null);
    try std.testing.expectEqual(@as(u8, 0), msg[msg.len - 1]);
}

test "build and parse frontend query message" {
    const msg = try buildQueryMessage(std.testing.allocator, "select 1");
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqual(@as(u8, 'Q'), msg[0]);
    try std.testing.expectEqual(@as(u32, 4 + "select 1".len + 1), readU32(msg[1..5]));
    try std.testing.expectEqualStrings("select 1", msg[5 .. msg.len - 1]);
    try std.testing.expectEqual(@as(u8, 0), msg[msg.len - 1]);
}

test "parse authentication and ready for query bodies" {
    var auth_ok = [_]u8{ 0, 0, 0, 0 };
    const ok = try parseAuthenticationBody(&auth_ok);
    try std.testing.expect(ok.kind == .ok);
    try std.testing.expectEqual(@as(usize, 0), ok.payload.len);

    var md5 = [_]u8{ 0, 0, 0, 5, 1, 2, 3, 4 };
    const md5_auth = try parseAuthenticationBody(&md5);
    try std.testing.expect(md5_auth.kind == .md5_password);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, md5_auth.payload);

    try std.testing.expect((try parseReadyForQuery(&[_]u8{'I'})) == .idle);
    try std.testing.expect((try parseReadyForQuery(&[_]u8{'T'})) == .in_transaction);
    try std.testing.expectError(error.ProtocolError, parseReadyForQuery(&[_]u8{'X'}));
}

test "parse message header and error fields" {
    var header_bytes = [_]u8{ 'E', 0, 0, 0, 12 };
    const header = try parseMessageHeader(&header_bytes);
    try std.testing.expect(header.tag == .error_response);
    try std.testing.expectEqual(@as(u32, 12), header.length);
    try std.testing.expectEqual(@as(u32, 8), header.bodyLen());

    // Sseverity\0 C23505\0 Mduplicate\0 \0
    const body =
        "SERROR\x00C23505\x00Mduplicate key\x00Ddetail here\x00Hhint here\x00tusers\x00cemail\x00nusers_email_key\x00\x00";
    const fields = try parseErrorFields(body);
    try std.testing.expectEqualStrings("ERROR", fields.severity.?);
    try std.testing.expectEqualStrings("23505", fields.code.?);
    try std.testing.expectEqualStrings("duplicate key", fields.message.?);
    try std.testing.expectEqualStrings("detail here", fields.detail.?);
    try std.testing.expectEqualStrings("hint here", fields.hint.?);
    try std.testing.expectEqualStrings("users", fields.table.?);
    try std.testing.expectEqualStrings("email", fields.column.?);
    try std.testing.expectEqualStrings("users_email_key", fields.constraint.?);
}

test "ssl request is fixed 8-byte packet" {
    const msg = try buildSslRequest(std.testing.allocator);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqual(@as(usize, 8), msg.len);
    try std.testing.expectEqual(@as(u32, 8), readU32(msg[0..4]));
    try std.testing.expectEqual(ssl_request_code, readI32(msg[4..8]));
}

test "build extended query messages" {
    const parse_msg = try buildParseMessage(std.testing.allocator, "select $1::int");
    defer std.testing.allocator.free(parse_msg);
    try std.testing.expectEqual(@as(u8, 'P'), parse_msg[0]);

    const binds = [_]?[]const u8{ "42", null };
    const bind_msg = try buildBindMessage(std.testing.allocator, &binds);
    defer std.testing.allocator.free(bind_msg);
    try std.testing.expectEqual(@as(u8, 'B'), bind_msg[0]);
    try std.testing.expect(std.mem.indexOf(u8, bind_msg, "42") != null);

    const describe = try buildDescribePortalMessage(std.testing.allocator);
    defer std.testing.allocator.free(describe);
    try std.testing.expectEqual(@as(u8, 'D'), describe[0]);
    try std.testing.expectEqual(@as(u8, 'P'), describe[5]);

    const execute = try buildExecuteMessage(std.testing.allocator);
    defer std.testing.allocator.free(execute);
    try std.testing.expectEqual(@as(u8, 'E'), execute[0]);

    const sync = try buildSyncMessage(std.testing.allocator);
    defer std.testing.allocator.free(sync);
    try std.testing.expectEqual(@as(u8, 'S'), sync[0]);
    try std.testing.expectEqual(@as(usize, 5), sync.len);
}

test "parse row description and data row" {
    // name\0 table_oid=0 attr=0 type=25 size=-1 mod=-1 format=0
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    defer body_list.deinit(std.testing.allocator);
    try appendI16(&body_list, std.testing.allocator, 1);
    try appendCString(&body_list, std.testing.allocator, "name");
    try appendI32(&body_list, std.testing.allocator, 0);
    try appendI16(&body_list, std.testing.allocator, 0);
    try appendI32(&body_list, std.testing.allocator, 25);
    try appendI16(&body_list, std.testing.allocator, -1);
    try appendI32(&body_list, std.testing.allocator, -1);
    try appendI16(&body_list, std.testing.allocator, 0);

    const fields = try parseRowDescription(body_list.items, std.testing.allocator);
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("name", fields[0].name);
    try std.testing.expectEqual(@as(i32, 25), fields[0].type_oid);

    var data_list: std.ArrayListUnmanaged(u8) = .empty;
    defer data_list.deinit(std.testing.allocator);
    try appendI16(&data_list, std.testing.allocator, 2);
    try appendI32(&data_list, std.testing.allocator, 3);
    try data_list.appendSlice(std.testing.allocator, "ada");
    try appendI32(&data_list, std.testing.allocator, -1);

    const cols = try parseDataRow(data_list.items, std.testing.allocator);
    defer std.testing.allocator.free(cols);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("ada", cols[0].bytes.?);
    try std.testing.expect(cols[1].bytes == null);

    try std.testing.expectEqualStrings("SELECT 1", try parseCommandComplete("SELECT 1\x00"));
}

pub fn appendI16(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &buf, value, .big);
    try list.appendSlice(allocator, &buf);
}
