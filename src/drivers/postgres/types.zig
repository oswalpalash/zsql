const std = @import("std");
const core = @import("../../zsql.zig");

/// Common PostgreSQL type OIDs used for decoding.
pub const TypeOid = enum(i32) {
    bool = 16,
    bytea = 17,
    int8 = 20,
    int2 = 21,
    int4 = 23,
    text = 25,
    float4 = 700,
    float8 = 701,
    varchar = 1043,
    date = 1082,
    timestamp = 1114,
    timestamptz = 1184,
    numeric = 1700,
    _,
};

/// Decode a text-format field into a `core.Value`.
///
/// - bool / int / float map to typed values
/// - text / varchar / unknown map to `.text` borrowing `raw`
/// - bytea maps to `.text` of the wire form for now (hex/escape); binary decode later
/// - date/timestamp map to `.text` until a dedicated temporal type exists
///
/// `raw` must outlive the returned `Value` for text/blob variants.
pub fn decodeText(oid: i32, raw: []const u8) !core.Value {
    return switch (@as(TypeOid, @enumFromInt(oid))) {
        .bool => .{ .boolean = try parseBool(raw) },
        .int2, .int4, .int8 => .{ .integer = try parseInt(raw) },
        .float4, .float8 => .{ .real = try parseFloat(raw) },
        .text, .varchar => .{ .text = raw },
        .bytea => .{ .blob = try decodeBytea(raw) },
        .date, .timestamp, .timestamptz, .numeric => .{ .text = raw },
        _ => .{ .text = raw },
    };
}

fn parseBool(raw: []const u8) !bool {
    if (raw.len == 1) {
        return switch (raw[0]) {
            't', 'T', '1' => true,
            'f', 'F', '0' => false,
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return error.TypeMismatch;
}

fn parseInt(raw: []const u8) !i64 {
    return std.fmt.parseInt(i64, raw, 10) catch error.TypeMismatch;
}

fn parseFloat(raw: []const u8) !f64 {
    return std.fmt.parseFloat(f64, raw) catch error.TypeMismatch;
}

/// Decode PostgreSQL text-format bytea.
/// Supports hex form `\xDEADBEEF` only for now; other forms return TypeMismatch.
/// Returns a slice into `raw` after the `\x` prefix (hex digits), not decoded binary.
/// Callers that need binary should use a future owned decoder.
fn decodeBytea(raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '\\' and (raw[1] == 'x' or raw[1] == 'X')) {
        return raw[2..];
    }
    return error.TypeMismatch;
}

/// Parse rows-affected from a CommandComplete tag such as `INSERT 0 1` or `UPDATE 3`.
pub fn parseCommandTag(tag: []const u8) struct { command: []const u8, rows_affected: u64 } {
    var iter = std.mem.tokenizeAny(u8, tag, " \t");
    const command = iter.next() orelse return .{ .command = tag, .rows_affected = 0 };

    var last_number: ?u64 = null;
    while (iter.next()) |part| {
        if (std.fmt.parseUnsigned(u64, part, 10)) |n| {
            last_number = n;
        } else |_| {}
    }
    return .{
        .command = command,
        .rows_affected = last_number orelse 0,
    };
}

test "decode text primitives" {
    try std.testing.expectEqual(true, (try decodeText(@intFromEnum(TypeOid.bool), "t")).boolean);
    try std.testing.expectEqual(false, (try decodeText(@intFromEnum(TypeOid.bool), "f")).boolean);
    try std.testing.expectEqual(@as(i64, 42), (try decodeText(@intFromEnum(TypeOid.int4), "42")).integer);
    try std.testing.expectEqual(@as(i64, -7), (try decodeText(@intFromEnum(TypeOid.int8), "-7")).integer);
    try std.testing.expectEqual(@as(f64, 1.5), (try decodeText(@intFromEnum(TypeOid.float8), "1.5")).real);
    try std.testing.expectEqualStrings("hello", (try decodeText(@intFromEnum(TypeOid.text), "hello")).text);
}

test "parse command complete tags" {
    try std.testing.expectEqual(@as(u64, 1), parseCommandTag("INSERT 0 1").rows_affected);
    try std.testing.expectEqual(@as(u64, 3), parseCommandTag("UPDATE 3").rows_affected);
    try std.testing.expectEqual(@as(u64, 0), parseCommandTag("CREATE TABLE").rows_affected);
    try std.testing.expectEqualStrings("SELECT", parseCommandTag("SELECT 2").command);
}
