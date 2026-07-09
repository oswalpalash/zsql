const std = @import("std");
const protocol = @import("protocol.zig");

/// Build the MD5 password response body used by AuthenticationMD5Password.
///
/// PostgreSQL computes:
///   "md5" || hex(md5( hex(md5(password || user)) || salt ))
///
/// Returns an allocator-owned C-string body (including trailing NUL) suitable
/// for `protocol.buildMessage(.password, body)`.
pub fn buildMd5PasswordBody(
    allocator: std.mem.Allocator,
    user: []const u8,
    password: []const u8,
    salt: *const [4]u8,
) ![]u8 {
    var inner_input = try std.ArrayListUnmanaged(u8).initCapacity(allocator, password.len + user.len);
    defer inner_input.deinit(allocator);
    try inner_input.appendSlice(allocator, password);
    try inner_input.appendSlice(allocator, user);

    var inner_digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(inner_input.items, &inner_digest, .{});
    const inner_hex = std.fmt.bytesToHex(inner_digest, .lower);

    var outer_input: [36]u8 = undefined;
    @memcpy(outer_input[0..32], &inner_hex);
    @memcpy(outer_input[32..36], salt);

    var outer_digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(&outer_input, &outer_digest, .{});
    const outer_hex = std.fmt.bytesToHex(outer_digest, .lower);

    var body: [36]u8 = undefined;
    @memcpy(body[0..3], "md5");
    @memcpy(body[3..35], &outer_hex);
    body[35] = 0;

    return try allocator.dupe(u8, body[0..]);
}

/// Build a cleartext PasswordMessage payload (password + NUL), owned.
pub fn buildCleartextPasswordBody(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try protocol.appendCString(&body, allocator, password);
    return try body.toOwnedSlice(allocator);
}

test "md5 password body matches known vector" {
    // password="secret", user="user", salt=0x01020304
    // computed offline with PostgreSQL algorithm.
    const salt = [_]u8{ 1, 2, 3, 4 };
    const body = try buildMd5PasswordBody(std.testing.allocator, "user", "secret", &salt);
    defer std.testing.allocator.free(body);

    try std.testing.expect(body.len == 36);
    try std.testing.expectEqual(@as(u8, 0), body[body.len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, body, "md5"));
    // Full digest must be stable for the same inputs.
    try std.testing.expectEqualStrings(
        "md5fccef98e4f1cf6cbe96b743fad4e8bd0",
        body[0 .. body.len - 1],
    );
}

test "cleartext password body is NUL terminated" {
    const body = try buildCleartextPasswordBody(std.testing.allocator, "s3cret");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("s3cret\x00", body);
}
