const std = @import("std");
const Value = @import("value.zig").Value;
const OwnedValue = @import("value.zig").OwnedValue;

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

pub const OwnedRow = struct {
    allocator: std.mem.Allocator,
    columns: [][]u8,
    values: []OwnedValue,

    pub fn init(allocator: std.mem.Allocator, row: Row) !OwnedRow {
        const columns = try allocator.alloc([]u8, row.columns.len);
        var initialized_columns: usize = 0;
        errdefer {
            for (columns[0..initialized_columns]) |column| {
                allocator.free(column);
            }
            allocator.free(columns);
        }

        for (row.columns, 0..) |column, index| {
            columns[index] = try allocator.dupe(u8, column);
            initialized_columns += 1;
        }

        const values = try allocator.alloc(OwnedValue, row.values.len);
        var initialized: usize = 0;
        errdefer {
            for (values[0..initialized]) |*item| {
                item.deinit(allocator);
            }
            allocator.free(values);
        }

        for (row.values, 0..) |item, index| {
            values[index] = try OwnedValue.from(allocator, item);
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .columns = columns,
            .values = values,
        };
    }

    pub fn deinit(self: *OwnedRow) void {
        for (self.values) |*item| {
            item.deinit(self.allocator);
        }
        self.allocator.free(self.values);
        for (self.columns) |column| {
            self.allocator.free(column);
        }
        self.allocator.free(self.columns);
        self.values = &.{};
        self.columns = &.{};
    }

    pub fn len(self: OwnedRow) usize {
        return self.values.len;
    }

    pub fn valueAt(self: OwnedRow, index: usize) !Value {
        if (index >= self.values.len) return error.InvalidColumn;
        return self.values[index].borrowed();
    }

    pub fn value(self: OwnedRow, column: []const u8) !Value {
        return self.valueAt(self.indexOf(column) orelse return error.InvalidColumn);
    }

    pub fn indexOf(self: OwnedRow, column: []const u8) ?usize {
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

test "OwnedRow duplicates text and blob values" {
    const row = try Row.init(&.{ "name", "payload" }, &.{
        .{ .text = "ada" },
        .{ .blob = "zig" },
    });
    var owned = try OwnedRow.init(std.testing.allocator, row);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.len());
    try std.testing.expectEqualStrings("ada", try (try owned.value("name")).asText());
    try std.testing.expectEqualStrings("zig", try (try owned.value("payload")).asBlob());
}
