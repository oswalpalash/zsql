const std = @import("std");
const core = @import("../../zsql.zig");

/// Common PostgreSQL type OIDs used for decoding.
pub const TypeOid = enum(u32) {
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

/// Encode a bind `Value` as PostgreSQL text-format bytes, or null.
///
/// Allocator-owned text is returned for non-null values (including booleans and
/// numbers). Callers must free each non-null slice.
pub fn encodeText(allocator: std.mem.Allocator, value: core.Value) !?[]u8 {
    const len = (try encodedTextLen(value)) orelse return null;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try encodeTextInto(out, value);
    return out;
}

/// Exact PostgreSQL text-format byte count, or null for SQL NULL.
pub fn encodedTextLen(value: core.Value) !?usize {
    return switch (value) {
        .null => null,
        .boolean => 1,
        .integer => |n| blk: {
            var scratch: [32]u8 = undefined;
            break :blk (try std.fmt.bufPrint(&scratch, "{d}", .{n})).len;
        },
        .real => |n| blk: {
            var scratch: [128]u8 = undefined;
            break :blk (try std.fmt.bufPrint(&scratch, "{d}", .{n})).len;
        },
        .text => |text| text.len,
        .blob => |blob| std.math.add(
            usize,
            2,
            std.math.mul(usize, blob.len, 2) catch return error.InvalidBindValue,
        ) catch return error.InvalidBindValue,
    };
}

/// Encode one non-null value into an exactly-sized caller buffer.
/// Passing SQL NULL requires an empty destination and writes no bytes.
pub fn encodeTextInto(dest: []u8, value: core.Value) !void {
    const expected = (try encodedTextLen(value)) orelse {
        if (dest.len != 0) return error.InvalidArguments;
        return;
    };
    if (dest.len != expected) return error.InvalidArguments;

    switch (value) {
        .null => unreachable,
        .boolean => |boolean| dest[0] = if (boolean) 't' else 'f',
        .integer => |integer| _ = std.fmt.bufPrint(dest, "{d}", .{integer}) catch return error.InvalidArguments,
        .real => |real| _ = std.fmt.bufPrint(dest, "{d}", .{real}) catch return error.InvalidArguments,
        .text => |text| @memcpy(dest, text),
        .blob => |blob| {
            dest[0] = '\\';
            dest[1] = 'x';
            const hex_charset = "0123456789abcdef";
            for (blob, 0..) |byte, index| {
                dest[2 + index * 2] = hex_charset[byte >> 4];
                dest[2 + index * 2 + 1] = hex_charset[byte & 15];
            }
        },
    }
}

/// Decode a text-format field into a `core.Value`.
///
/// - bool / int / float map to typed values
/// - text / varchar / unknown map to `.text` borrowing `raw`
/// - bytea requires allocator-owned decoding via `decodeTextOwned`
/// - date/timestamp map to `.text` until a dedicated temporal type exists
///
/// `raw` must outlive the returned `Value` for text variants.
pub fn decodeText(oid: u32, raw: []const u8) !core.Value {
    return switch (@as(TypeOid, @enumFromInt(oid))) {
        .bool => .{ .boolean = try parseBool(raw) },
        .int2, .int4, .int8 => .{ .integer = try parseInt(raw) },
        .float4, .float8 => .{ .real = try parseFloat(raw) },
        .text, .varchar => .{ .text = raw },
        .bytea => error.Unsupported,
        .date, .timestamp, .timestamptz, .numeric => .{ .text = raw },
        _ => .{ .text = raw },
    };
}

/// Decode one text-format field into allocator-owned storage.
/// PostgreSQL bytea hex and escape output are converted to the original bytes.
pub fn decodeTextOwned(allocator: std.mem.Allocator, oid: u32, raw: []const u8) !core.OwnedValue {
    if (@as(TypeOid, @enumFromInt(oid)) == .bytea) {
        return .{ .blob = try decodeByteaOwned(allocator, raw) };
    }
    return core.OwnedValue.from(allocator, try decodeText(oid, raw));
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

fn decodeByteaOwned(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const len = try decodedByteaLen(raw);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try decodeByteaInto(out, raw);
    return out;
}

fn decodedByteaLen(raw: []const u8) !usize {
    if (isHexBytea(raw)) {
        const hex = raw[2..];
        if (hex.len % 2 != 0) return error.TypeMismatch;
        for (hex) |char| _ = try hexNibble(char);
        return hex.len / 2;
    }

    var input_index: usize = 0;
    var output_len: usize = 0;
    while (input_index < raw.len) {
        if (raw[input_index] != '\\') {
            input_index += 1;
        } else if (input_index + 1 < raw.len and raw[input_index + 1] == '\\') {
            input_index += 2;
        } else {
            _ = try parseOctalByte(raw, input_index);
            input_index += 4;
        }
        output_len += 1;
    }
    return output_len;
}

fn decodeByteaInto(out: []u8, raw: []const u8) !void {
    if (out.len != try decodedByteaLen(raw)) return error.InvalidArguments;
    if (isHexBytea(raw)) {
        const hex = raw[2..];
        for (out, 0..) |*byte, index| {
            byte.* = (try hexNibble(hex[index * 2])) << 4 |
                try hexNibble(hex[index * 2 + 1]);
        }
        return;
    }

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < raw.len) : (output_index += 1) {
        if (raw[input_index] != '\\') {
            out[output_index] = raw[input_index];
            input_index += 1;
        } else if (input_index + 1 < raw.len and raw[input_index + 1] == '\\') {
            out[output_index] = '\\';
            input_index += 2;
        } else {
            out[output_index] = try parseOctalByte(raw, input_index);
            input_index += 4;
        }
    }
}

fn isHexBytea(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '\\' and (raw[1] == 'x' or raw[1] == 'X');
}

fn hexNibble(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.TypeMismatch,
    };
}

fn parseOctalByte(raw: []const u8, slash_index: usize) !u8 {
    if (slash_index + 4 > raw.len or raw[slash_index] != '\\') return error.TypeMismatch;
    const a = raw[slash_index + 1];
    const b = raw[slash_index + 2];
    const c = raw[slash_index + 3];
    if (a < '0' or a > '3' or b < '0' or b > '7' or c < '0' or c > '7') {
        return error.TypeMismatch;
    }
    return (a - '0') * 64 + (b - '0') * 8 + (c - '0');
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
    try std.testing.expectEqualStrings("extension", (try decodeText(0xf0000001, "extension")).text);
    try std.testing.expectError(error.Unsupported, decodeText(@intFromEnum(TypeOid.bytea), "\\x00"));
}

test "decode owned bytea hex and escape formats" {
    const oid = @intFromEnum(TypeOid.bytea);
    var hex = try decodeTextOwned(std.testing.allocator, oid, "\\x00ff5c41");
    defer hex.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\x00\xff\\A", hex.blob);

    const escaped_wire = [_]u8{ 'A', '\\', '\\', '\\', '0', '0', '0', '\\', '3', '7', '7' };
    var escaped = try decodeTextOwned(std.testing.allocator, oid, &escaped_wire);
    defer escaped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A\\\x00\xff", escaped.blob);

    try std.testing.expectError(error.TypeMismatch, decodeTextOwned(std.testing.allocator, oid, "\\x0"));
    try std.testing.expectError(error.TypeMismatch, decodeTextOwned(std.testing.allocator, oid, "\\xgg"));
    try std.testing.expectError(error.TypeMismatch, decodeTextOwned(std.testing.allocator, oid, "\\9"));
}

test "parse command complete tags" {
    try std.testing.expectEqual(@as(u64, 1), parseCommandTag("INSERT 0 1").rows_affected);
    try std.testing.expectEqual(@as(u64, 3), parseCommandTag("UPDATE 3").rows_affected);
    try std.testing.expectEqual(@as(u64, 0), parseCommandTag("CREATE TABLE").rows_affected);
    try std.testing.expectEqualStrings("SELECT", parseCommandTag("SELECT 2").command);
}

test "encode text binds" {
    const t = (try encodeText(std.testing.allocator, .{ .boolean = true })).?;
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("t", t);

    const n = (try encodeText(std.testing.allocator, .{ .integer = 42 })).?;
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("42", n);

    try std.testing.expect((try encodeText(std.testing.allocator, .{ .null = {} })) == null);

    const blob = (try encodeText(std.testing.allocator, .{ .blob = "A" })).?;
    defer std.testing.allocator.free(blob);
    try std.testing.expectEqualStrings("\\x41", blob);

    var into: [4]u8 = undefined;
    try encodeTextInto(&into, .{ .blob = "A" });
    try std.testing.expectEqualStrings("\\x41", &into);
    try std.testing.expectEqual(@as(?usize, 4), try encodedTextLen(.{ .blob = "A" }));
    try std.testing.expect((try encodedTextLen(.{ .null = {} })) == null);
    try std.testing.expectError(error.InvalidArguments, encodeTextInto(into[0..3], .{ .blob = "A" }));
}
