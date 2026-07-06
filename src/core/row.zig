const std = @import("std");
const Value = @import("value.zig").Value;

pub const Row = struct {
    columns: []const []const u8,
    values: []const Value,

    pub fn init(columns: []const []const u8, values: []const Value) !Row {
        if (columns.len != values.len) return error.InvalidColumn;
        return .{
            .columns = columns,
            .values = values,
        };
    }

    pub fn len(self: Row) usize {
        return self.values.len;
    }

    pub fn valueAt(self: Row, index: usize) !Value {
        if (index >= self.values.len) return error.InvalidColumn;
        return self.values[index];
    }

    pub fn value(self: Row, column: []const u8) !Value {
        return self.valueAt(self.indexOf(column) orelse return error.InvalidColumn);
    }

    pub fn indexOf(self: Row, column: []const u8) ?usize {
        for (self.columns, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, column)) return index;
        }
        return null;
    }
};

test "Row reads values by index and column name" {
    const row = try Row.init(&.{ "id", "name" }, &.{
        .{ .integer = 7 },
        .{ .text = "ada" },
    });

    try std.testing.expectEqual(@as(usize, 2), row.len());
    try std.testing.expectEqual(@as(i64, 7), try (try row.valueAt(0)).asInt());
    try std.testing.expectEqualStrings("ada", try (try row.value("name")).asText());
    try std.testing.expectError(error.InvalidColumn, row.value("missing"));
}

test "Row rejects mismatched column and value lengths" {
    try std.testing.expectError(error.InvalidColumn, Row.init(&.{"id"}, &.{}));
}
