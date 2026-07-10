//! Explicit SQL-domain value wrappers. Text-backed values borrow unless copied
//! by the caller; they intentionally carry no hidden allocator.

pub const Text = struct { bytes: []const u8 };
pub const Blob = struct { bytes: []const u8 };

pub const Date = struct { days_since_unix_epoch: i32 };
pub const Time = struct { ns_since_midnight: u64 };
pub const Timestamp = struct { unix_us: i64 };
pub const Numeric = struct { text: []const u8 };
pub const Uuid = struct { bytes: [16]u8 };

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
