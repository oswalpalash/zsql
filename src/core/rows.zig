const std = @import("std");
const Row = @import("row.zig").Row;

pub const Rows = struct {
    items: []const Row,
    index: usize = 0,

    pub fn init(items: []const Row) Rows {
        return .{ .items = items };
    }

    pub fn next(self: *Rows) ?Row {
        if (self.index >= self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }

    pub fn reset(self: *Rows) void {
        self.index = 0;
    }
};

test "Rows iterates without allocation" {
    const first = try Row.init(&.{"id"}, &.{.{ .integer = 1 }});
    const second = try Row.init(&.{"id"}, &.{.{ .integer = 2 }});
    var rows = Rows.init(&.{ first, second });

    try std.testing.expectEqual(@as(i64, 1), try (try rows.next().?.value("id")).asInt());
    try std.testing.expectEqual(@as(i64, 2), try (try rows.next().?.value("id")).asInt());
    try std.testing.expectEqual(@as(?Row, null), rows.next());
}
