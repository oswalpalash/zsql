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
            .integer => |value| value != 0,
            .text => |text| {
                if (std.ascii.eqlIgnoreCase(text, "true") or
                    std.ascii.eqlIgnoreCase(text, "t") or
                    std.ascii.eqlIgnoreCase(text, "yes") or
                    std.ascii.eqlIgnoreCase(text, "y") or
                    std.ascii.eqlIgnoreCase(text, "on") or
                    std.mem.eql(u8, text, "1"))
                    return true;
                if (std.ascii.eqlIgnoreCase(text, "false") or
                    std.ascii.eqlIgnoreCase(text, "f") or
                    std.ascii.eqlIgnoreCase(text, "no") or
                    std.ascii.eqlIgnoreCase(text, "n") or
                    std.ascii.eqlIgnoreCase(text, "off") or
                    std.mem.eql(u8, text, "0"))
                    return false;
                return error.TypeMismatch;
            },
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

pub const OwnedValue = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []u8,
    blob: []u8,
    boolean: bool,

    pub fn from(allocator: std.mem.Allocator, value: Value) !OwnedValue {
        return switch (value) {
            .null => .{ .null = {} },
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .text => |v| .{ .text = try allocator.dupe(u8, v) },
            .blob => |v| .{ .blob = try allocator.dupe(u8, v) },
            .boolean => |v| .{ .boolean = v },
        };
    }

    pub fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |value| allocator.free(value),
            .blob => |value| allocator.free(value),
            else => {},
        }
        self.* = .{ .null = {} };
    }

    pub fn borrowed(self: OwnedValue) Value {
        return switch (self) {
            .null => .{ .null = {} },
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .text => |v| .{ .text = v },
            .blob => |v| .{ .blob = v },
            .boolean => |v| .{ .boolean = v },
        };
    }
};

test "Value exposes typed accessors" {
    try std.testing.expectEqual(@as(i64, 42), try (Value{ .integer = 42 }).asInt());
    try std.testing.expectEqual(@as(f64, 42.0), try (Value{ .integer = 42 }).asFloat());
    try std.testing.expectEqualStrings("zig", try (Value{ .text = "zig" }).asText());
    try std.testing.expect((Value{ .null = {} }).isNull());
    try std.testing.expectError(error.InvalidColumnType, (Value{ .text = "nope" }).asInt());
    try std.testing.expect(try (Value{ .integer = 1 }).asBool());
    try std.testing.expect(!try (Value{ .integer = 0 }).asBool());
    try std.testing.expect(try (Value{ .text = "Yes" }).asBool());
    try std.testing.expect(!try (Value{ .text = "off" }).asBool());
    try std.testing.expectError(error.TypeMismatch, (Value{ .text = "maybe" }).asBool());
}

test "Value compares owned by content" {
    try std.testing.expect((Value{ .text = "same" }).eql(.{ .text = "same" }));
    try std.testing.expect(!(Value{ .blob = "a" }).eql(.{ .blob = "b" }));
}

test "OwnedValue duplicates text and blob values" {
    var text = try OwnedValue.from(std.testing.allocator, .{ .text = "owned" });
    defer text.deinit(std.testing.allocator);
    var blob = try OwnedValue.from(std.testing.allocator, .{ .blob = "bytes" });
    defer blob.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("owned", try text.borrowed().asText());
    try std.testing.expectEqualStrings("bytes", try blob.borrowed().asBlob());
}
