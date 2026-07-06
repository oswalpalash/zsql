const std = @import("std");

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
    boolean: bool,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn asInt(self: Value) !i64 {
        return switch (self) {
            .integer => |value| value,
            else => error.InvalidColumnType,
        };
    }

    pub fn asFloat(self: Value) !f64 {
        return switch (self) {
            .real => |value| value,
            .integer => |value| @floatFromInt(value),
            else => error.InvalidColumnType,
        };
    }

    pub fn asText(self: Value) ![]const u8 {
        return switch (self) {
            .text => |value| value,
            else => error.InvalidColumnType,
        };
    }

    pub fn asBlob(self: Value) ![]const u8 {
        return switch (self) {
            .blob => |value| value,
            else => error.InvalidColumnType,
        };
    }

    pub fn asBool(self: Value) !bool {
        return switch (self) {
            .boolean => |value| value,
            else => error.InvalidColumnType,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .null => true,
            .integer => |value| value == b.integer,
            .real => |value| value == b.real,
            .text => |value| std.mem.eql(u8, value, b.text),
            .blob => |value| std.mem.eql(u8, value, b.blob),
            .boolean => |value| value == b.boolean,
        };
    }
};

test "Value exposes typed accessors" {
    try std.testing.expectEqual(@as(i64, 42), try (Value{ .integer = 42 }).asInt());
    try std.testing.expectEqual(@as(f64, 42.0), try (Value{ .integer = 42 }).asFloat());
    try std.testing.expectEqualStrings("zig", try (Value{ .text = "zig" }).asText());
    try std.testing.expect((Value{ .null = {} }).isNull());
    try std.testing.expectError(error.InvalidColumnType, (Value{ .text = "nope" }).asInt());
}

test "Value compares owned by content" {
    try std.testing.expect((Value{ .text = "same" }).eql(.{ .text = "same" }));
    try std.testing.expect(!(Value{ .blob = "a" }).eql(.{ .blob = "b" }));
}
