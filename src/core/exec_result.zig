const std = @import("std");

pub const ExecResult = struct {
    rows_affected: u64 = 0,
    last_insert_id: ?i64 = null,
};

test "ExecResult defaults to no affected rows and no insert id" {
    const result: ExecResult = .{};
    try std.testing.expectEqual(@as(u64, 0), result.rows_affected);
    try std.testing.expectEqual(@as(?i64, null), result.last_insert_id);
}
