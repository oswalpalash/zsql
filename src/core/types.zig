//! Explicit SQL-domain value wrappers. Text-backed values borrow unless copied
//! by the caller; they intentionally carry no hidden allocator.

pub const Text = struct { bytes: []const u8 };
pub const Blob = struct { bytes: []const u8 };

pub const Date = struct { days_since_unix_epoch: i32 };
pub const Time = struct { ns_since_midnight: u64 };
pub const Timestamp = struct { unix_us: i64 };
pub const Numeric = struct { text: []const u8 };
pub const Uuid = struct { bytes: [16]u8 };

/// Parse canonical hyphenated UUID text without allocation.
pub fn parseUuid(text: []const u8) !Uuid {
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-')
        return error.TypeMismatch;
    var bytes: [16]u8 = undefined;
    var src: usize = 0;
    var dst: usize = 0;
    while (src < text.len) {
        if (text[src] == '-') {
            src += 1;
            continue;
        }
        if (src + 1 >= text.len or dst >= bytes.len) return error.TypeMismatch;
        bytes[dst] = (@as(u8, try hexNibble(text[src]) << 4)) | try hexNibble(text[src + 1]);
        src += 2;
        dst += 1;
    }
    if (dst != bytes.len) return error.TypeMismatch;
    return .{ .bytes = bytes };
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.TypeMismatch,
    };
}

/// JSON is represented as validated-by-the-database text/bytes interpreted by
/// the caller's chosen Zig type; zsql never performs hidden runtime reflection.
pub fn Json(comptime T: type) type {
    return struct {
        bytes: []const u8,
        pub const Value = T;
    };
}

test "sql domain wrappers retain explicit representations" {
    const payload = Json(struct { ok: bool }){ .bytes = "{\"ok\":true}" };
    try @import("std").testing.expectEqualStrings("{\"ok\":true}", payload.bytes);
}

test "parseUuid accepts canonical text" {
    const uuid = try parseUuid("550e8400-e29b-41d4-a716-446655440000");
    try @import("std").testing.expectEqual(@as(u8, 0x55), uuid.bytes[0]);
    try @import("std").testing.expectEqual(@as(u8, 0), uuid.bytes[15]);
}
