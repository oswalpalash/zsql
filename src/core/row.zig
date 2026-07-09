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

    pub fn to(self: Row, comptime T: type) !T {
        return mapRow(T, self);
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

    pub fn to(self: OwnedRow, comptime T: type) !T {
        return mapOwnedRow(T, self);
    }
};

fn mapRow(comptime T: type, row: Row) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Row.to expects a struct type");

    var result: T = undefined;
    inline for (info.@"struct".fields, 0..) |field, ordinal| {
        const value = if (row.indexOf(field.name)) |index|
            try row.valueAt(index)
        else
            try row.valueAt(ordinal);
        @field(result, field.name) = try convertValue(field.type, value);
    }
    return result;
}

fn convertValue(comptime T: type, value: Value) !T {
    const info = @typeInfo(T);
    return switch (info) {
        .optional => |optional| {
            if (value.isNull()) return null;
            return try convertValue(optional.child, value);
        },
        .bool => switch (value) {
            .boolean => |v| v,
            .integer => |v| v != 0,
            else => error.InvalidColumnType,
        },
        .int => switch (value) {
            .integer => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
            else => error.InvalidColumnType,
        },
        .float => switch (value) {
            .real => |v| @as(T, @floatCast(v)),
            .integer => |v| @as(T, @floatFromInt(v)),
            else => error.InvalidColumnType,
        },
        .@"enum" => convertEnum(T, value),
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.child != u8) {
                @compileError("Row.to only supports []const u8 string/blob slices for pointer fields");
            }
            return switch (value) {
                .text => |v| v,
                .blob => |v| v,
                else => error.InvalidColumnType,
            };
        },
        else => @compileError("Row.to only supports scalar, optional scalar, enum, and []const u8 fields"),
    };
}

/// Map text (field name) or integer (tag value) into a Zig enum.
fn convertEnum(comptime T: type, value: Value) !T {
    return switch (value) {
        .text => |text| blk: {
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, field.name, text)) {
                    break :blk @field(T, field.name);
                }
            }
            break :blk error.TypeMismatch;
        },
        .integer => |int_value| blk: {
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const tag = std.math.cast(tag_type, int_value) orelse return error.TypeMismatch;
            inline for (std.meta.fields(T)) |field| {
                if (field.value == tag) break :blk @enumFromInt(tag);
            }
            if (@typeInfo(T).@"enum".is_exhaustive) return error.TypeMismatch;
            break :blk @enumFromInt(tag);
        },
        else => error.InvalidColumnType,
    };
}

fn mapOwnedRow(comptime T: type, row: OwnedRow) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("OwnedRow.to expects a struct type");

    var result: T = undefined;
    inline for (info.@"struct".fields, 0..) |field, ordinal| {
        const value = if (row.indexOf(field.name)) |index|
            try row.valueAt(index)
        else
            try row.valueAt(ordinal);
        @field(result, field.name) = try convertValue(field.type, value);
    }
    return result;
}

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

test "Row maps to struct by field name and ordinal fallback" {
    const User = struct {
        id: u32,
        name: []const u8,
        active: bool,
        score: ?f32,
    };
    const row = try Row.init(&.{ "name", "id", "active", "score" }, &.{
        .{ .text = "ada" },
        .{ .integer = 7 },
        .{ .integer = 1 },
        .{ .real = 2.5 },
    });

    const user = try row.to(User);
    try std.testing.expectEqual(@as(u32, 7), user.id);
    try std.testing.expectEqualStrings("ada", user.name);
    try std.testing.expect(user.active);
    try std.testing.expectEqual(@as(?f32, 2.5), user.score);

    const Pair = struct {
        first: i64,
        second: []const u8,
    };
    const ordinal_row = try Row.init(&.{ "a", "b" }, &.{
        .{ .integer = 1 },
        .{ .text = "two" },
    });
    const pair = try ordinal_row.to(Pair);
    try std.testing.expectEqual(@as(i64, 1), pair.first);
    try std.testing.expectEqualStrings("two", pair.second);
}

test "Row.to handles null optionals and rejects invalid field types" {
    const MaybeUser = struct {
        nickname: ?[]const u8,
    };
    const row = try Row.init(&.{"nickname"}, &.{.{ .null = {} }});
    const user = try row.to(MaybeUser);
    try std.testing.expectEqual(@as(?[]const u8, null), user.nickname);

    const Bad = struct {
        id: u8,
    };
    const bad_row = try Row.init(&.{"id"}, &.{.{ .integer = 300 }});
    try std.testing.expectError(error.IntegerOverflow, bad_row.to(Bad));
}

test "Row maps enum fields from text names and integer tags" {
    const Role = enum { admin, user, guest };
    const Status = enum(u8) { active = 1, inactive = 2 };

    const Account = struct {
        role: Role,
        status: Status,
        maybe_role: ?Role,
    };

    const row = try Row.init(&.{ "role", "status", "maybe_role" }, &.{
        .{ .text = "admin" },
        .{ .integer = 1 },
        .{ .null = {} },
    });
    const account = try row.to(Account);
    try std.testing.expect(account.role == .admin);
    try std.testing.expect(account.status == .active);
    try std.testing.expect(account.maybe_role == null);

    const bad = try Row.init(&.{"role"}, &.{.{ .text = "nope" }});
    const BadRole = struct { role: Role };
    try std.testing.expectError(error.TypeMismatch, bad.to(BadRole));
}
