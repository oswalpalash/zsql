const std = @import("std");
const Value = @import("value.zig").Value;
const OwnedValue = @import("value.zig").OwnedValue;
const types = @import("types.zig");

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

    /// Alias for `valueAt` — ordinal access matching the public API target.
    pub fn get(self: Row, index: usize) !Value {
        return self.valueAt(index);
    }

    /// Alias for `value` — named column access matching the public API target.
    pub fn getName(self: Row, column: []const u8) !Value {
        return self.value(column);
    }

    /// Typed ordinal decode using the same conversion rules as `to`.
    ///
    /// ```zig
    /// const id = try row.as(i64, 0);
    /// const email = try row.as([]const u8, 1); // borrowed until next row/deinit
    /// ```
    pub fn as(self: Row, comptime T: type, index: usize) !T {
        return decode(T, try self.valueAt(index));
    }

    /// Typed named-column decode using the same conversion rules as `to`.
    pub fn asName(self: Row, comptime T: type, column: []const u8) !T {
        return decode(T, try self.value(column));
    }

    /// Copy this borrowed row into an allocator-owned `OwnedRow`.
    pub fn getOwned(self: Row, allocator: std.mem.Allocator) !OwnedRow {
        return OwnedRow.init(allocator, self);
    }

    /// Copy one text/blob column into an allocator-owned buffer.
    /// Caller must free with `allocator.free`. Non-text/blob values error.
    pub fn asOwned(self: Row, allocator: std.mem.Allocator, index: usize) ![]u8 {
        return ownedBytes(allocator, try self.valueAt(index));
    }

    /// Named-column variant of `asOwned`.
    pub fn asNameOwned(self: Row, allocator: std.mem.Allocator, column: []const u8) ![]u8 {
        return ownedBytes(allocator, try self.value(column));
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

    /// Free a slice of `OwnedRow` values produced by driver `queryAll` helpers.
    pub fn freeSlice(allocator: std.mem.Allocator, rows: []OwnedRow) void {
        for (rows) |*row| row.deinit();
        allocator.free(rows);
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

    pub fn get(self: OwnedRow, index: usize) !Value {
        return self.valueAt(index);
    }

    pub fn getName(self: OwnedRow, column: []const u8) !Value {
        return self.value(column);
    }

    /// Typed ordinal decode (same rules as `Row.as` / `to`).
    pub fn as(self: OwnedRow, comptime T: type, index: usize) !T {
        return decode(T, try self.valueAt(index));
    }

    /// Typed named-column decode (same rules as `Row.asName` / `to`).
    pub fn asName(self: OwnedRow, comptime T: type, column: []const u8) !T {
        return decode(T, try self.value(column));
    }

    /// Duplicate a text/blob column. Caller frees with `self.allocator.free`.
    pub fn asOwned(self: OwnedRow, index: usize) ![]u8 {
        return ownedBytes(self.allocator, try self.valueAt(index));
    }

    /// Named-column variant of `asOwned`.
    pub fn asNameOwned(self: OwnedRow, column: []const u8) ![]u8 {
        return ownedBytes(self.allocator, try self.value(column));
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

/// Decode a single SQL `Value` into Zig type `T`.
///
/// Same conversion rules as `Row.to` field mapping: nullability, overflow-safe
/// integers, bool mapping (including text forms), enums, and borrowed `[]const u8`.
pub fn decode(comptime T: type, value: Value) !T {
    return convertValue(T, value);
}

fn ownedBytes(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .text => |t| try allocator.dupe(u8, t),
        .blob => |b| try allocator.dupe(u8, b),
        .null => error.UnexpectedNull,
        else => error.InvalidColumnType,
    };
}

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
    if (info == .optional) {
        if (value.isNull()) return null;
        return try convertValue(info.optional.child, value);
    }
    // Non-optional fields must not be SQL NULL.
    if (value.isNull()) return error.UnexpectedNull;

    if (T == types.Text) return .{ .bytes = switch (value) {
        .text => |v| v,
        else => return error.InvalidColumnType,
    } };
    if (T == types.Blob) return .{ .bytes = switch (value) {
        .blob => |v| v,
        else => return error.InvalidColumnType,
    } };
    if (T == types.Numeric) return .{ .text = switch (value) {
        .text => |v| v,
        else => return error.InvalidColumnType,
    } };

    return switch (info) {
        .bool => convertBool(value),
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

fn convertBool(value: Value) !bool {
    return switch (value) {
        .boolean => |v| v,
        .integer => |v| v != 0,
        .text => |text| blk: {
            if (std.ascii.eqlIgnoreCase(text, "true") or
                std.ascii.eqlIgnoreCase(text, "t") or
                std.ascii.eqlIgnoreCase(text, "yes") or
                std.ascii.eqlIgnoreCase(text, "y") or
                std.ascii.eqlIgnoreCase(text, "on") or
                std.mem.eql(u8, text, "1"))
            {
                break :blk true;
            }
            if (std.ascii.eqlIgnoreCase(text, "false") or
                std.ascii.eqlIgnoreCase(text, "f") or
                std.ascii.eqlIgnoreCase(text, "no") or
                std.ascii.eqlIgnoreCase(text, "n") or
                std.ascii.eqlIgnoreCase(text, "off") or
                std.mem.eql(u8, text, "0"))
            {
                break :blk false;
            }
            break :blk error.TypeMismatch;
        },
        else => error.InvalidColumnType,
    };
}

/// Map text (field name, case-insensitive) or integer (tag value) into a Zig enum.
fn convertEnum(comptime T: type, value: Value) !T {
    return switch (value) {
        .text => |text| blk: {
            inline for (std.meta.fields(T)) |field| {
                if (std.ascii.eqlIgnoreCase(field.name, text)) {
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
    try std.testing.expectEqual(@as(i64, 7), try (try row.get(0)).asInt());
    try std.testing.expectEqualStrings("ada", try (try row.getName("name")).asText());
    try std.testing.expectError(error.InvalidColumn, row.value("missing"));

    var owned = try row.getOwned(std.testing.allocator);
    defer owned.deinit();
    try std.testing.expectEqualStrings("ada", try (try owned.getName("name")).asText());
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

test "decode supports borrowed SQL domain wrappers" {
    try std.testing.expectEqualStrings("hello", (try decode(types.Text, .{ .text = "hello" })).bytes);
    try std.testing.expectEqualStrings("\x00\x01", (try decode(types.Blob, .{ .blob = "\x00\x01" })).bytes);
    try std.testing.expectEqualStrings("12.30", (try decode(types.Numeric, .{ .text = "12.30" })).text);
    try std.testing.expectError(error.InvalidColumnType, decode(types.Text, .{ .blob = "nope" }));
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

    // Case-insensitive enum text (common for Postgres enums / CHECK labels).
    const mixed = try Row.init(&.{"role"}, &.{.{ .text = "Admin" }});
    const OnlyRole = struct { role: Role };
    try std.testing.expect((try mixed.to(OnlyRole)).role == .admin);

    const bad = try Row.init(&.{"role"}, &.{.{ .text = "nope" }});
    try std.testing.expectError(error.TypeMismatch, bad.to(OnlyRole));
}

test "Row.to rejects UnexpectedNull and accepts text bools" {
    const Required = struct { name: []const u8 };
    const null_row = try Row.init(&.{"name"}, &.{.{ .null = {} }});
    try std.testing.expectError(error.UnexpectedNull, null_row.to(Required));

    const Flag = struct { active: bool };
    const text_true = try Row.init(&.{"active"}, &.{.{ .text = "TRUE" }});
    try std.testing.expect((try text_true.to(Flag)).active);
    const text_false = try Row.init(&.{"active"}, &.{.{ .text = "f" }});
    try std.testing.expect(!(try text_false.to(Flag)).active);
}

test "Row.as and asName decode typed columns" {
    const row = try Row.init(&.{ "id", "name", "active" }, &.{
        .{ .integer = 42 },
        .{ .text = "ada" },
        .{ .boolean = true },
    });

    try std.testing.expectEqual(@as(i64, 42), try row.as(i64, 0));
    try std.testing.expectEqual(@as(u32, 42), try row.asName(u32, "id"));
    try std.testing.expectEqualStrings("ada", try row.as([]const u8, 1));
    try std.testing.expectEqualStrings("ada", try row.asName([]const u8, "name"));
    try std.testing.expect(try row.as(bool, 2));
    try std.testing.expectEqual(@as(u8, 42), try row.as(u8, 0));
    try std.testing.expectError(error.InvalidColumn, row.as(i64, 9));
    // Overflow: 300 into u8
    const big = try Row.init(&.{"n"}, &.{.{ .integer = 300 }});
    try std.testing.expectError(error.IntegerOverflow, big.as(u8, 0));

    const owned_name = try row.asOwned(std.testing.allocator, 1);
    defer std.testing.allocator.free(owned_name);
    try std.testing.expectEqualStrings("ada", owned_name);

    const owned_by_name = try row.asNameOwned(std.testing.allocator, "name");
    defer std.testing.allocator.free(owned_by_name);
    try std.testing.expectEqualStrings("ada", owned_by_name);

    try std.testing.expectError(error.InvalidColumnType, row.asOwned(std.testing.allocator, 0));

    var owned_row = try row.getOwned(std.testing.allocator);
    defer owned_row.deinit();
    try std.testing.expectEqual(@as(i64, 42), try owned_row.as(i64, 0));
    try std.testing.expectEqualStrings("ada", try owned_row.asName([]const u8, "name"));
    const copy = try owned_row.asNameOwned("name");
    defer owned_row.allocator.free(copy);
    try std.testing.expectEqualStrings("ada", copy);
}
