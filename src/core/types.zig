//! Explicit SQL-domain value wrappers. Text-backed values borrow unless copied
//! by the caller; they intentionally carry no hidden allocator.

const std = @import("std");

pub const Text = struct { bytes: []const u8 };
pub const Blob = struct { bytes: []const u8 };

pub const Date = struct { days_since_unix_epoch: i32 };
pub const Time = struct { ns_since_midnight: u64 };
pub const Timestamp = struct { unix_us: i64 };
pub const Numeric = struct { text: []const u8 };
pub const Uuid = struct { bytes: [16]u8 };

/// Parse canonical hyphenated UUID text without allocation.
pub fn parseUuid(text: []const u8) !Uuid {
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-')
        return error.TypeMismatch;
    var bytes: [16]u8 = undefined;
    var src: usize = 0;
    var dst: usize = 0;
    while (src < text.len) {
        if (text[src] == '-') {
            src += 1;
            continue;
        }
        if (src + 1 >= text.len or dst >= bytes.len) return error.TypeMismatch;
        bytes[dst] = (@as(u8, try hexNibble(text[src]) << 4)) | try hexNibble(text[src + 1]);
        src += 2;
        dst += 1;
    }
    if (dst != bytes.len) return error.TypeMismatch;
    return .{ .bytes = bytes };
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.TypeMismatch,
    };
}

pub const IsoTimeParts = struct {
    ns_since_midnight: u64,
    fraction_digits: u8,
};

fn isoParseDigits(text: []const u8) !u32 {
    if (text.len == 0 or text.len > 9) return error.TypeMismatch;
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return error.TypeMismatch;
        const next = std.math.mul(u32, value, 10) catch return error.TypeMismatch;
        value = next + (char - '0');
    }
    return value;
}

fn isoDaysFromCivilYear(year: i32, month: u8, day: u8) !i64 {
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.TypeMismatch;

    const is_leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    const days_in_month: u8 = switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (is_leap) 29 else 28,
        else => unreachable,
    };
    if (day > days_in_month) return error.TypeMismatch;

    // Howard Hinnant's civil-from-days algorithm, inverted. @divFloor keeps
    // the era calculation correct for pre-common-era years.
    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_index: i32 = if (month > 2) @as(i32, month) - 3 else @as(i32, month) + 9;
    const day_of_year = @divFloor(153 * month_index + 2, 5) + @as(i32, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn isoParseDateParts(text: []const u8) !struct { days: i64 } {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.TypeMismatch;
    const year_value = try isoParseDigits(text[0..4]);
    const month = std.math.cast(u8, try isoParseDigits(text[5..7])) orelse return error.TypeMismatch;
    const day = std.math.cast(u8, try isoParseDigits(text[8..10])) orelse return error.TypeMismatch;
    return .{ .days = try isoDaysFromCivilYear(@intCast(year_value), month, day) };
}

fn isoSplitTime(text: []const u8, max_fraction_digits: u8) !IsoTimeParts {
    if (text.len < 5 or text[2] != ':' or text[5] != ':') return error.TypeMismatch;
    const hour = try isoParseDigits(text[0..2]);
    const minute = try isoParseDigits(text[3..5]);
    if (hour > 23 or minute > 59) return error.TypeMismatch;

    var second_text = text[6..];
    var fraction: u64 = 0;
    var fraction_digits: u8 = 0;
    if (std.mem.indexOfScalar(u8, second_text, '.')) |dot| {
        const digits = second_text[dot + 1 ..];
        if (digits.len == 0 or digits.len > max_fraction_digits) return error.TypeMismatch;
        var multiplier: u64 = 100_000_000;
        for (digits) |char| {
            if (char < '0' or char > '9') return error.TypeMismatch;
            fraction += @as(u64, char - '0') * multiplier;
            multiplier /= 10;
            fraction_digits += 1;
        }
        second_text = second_text[0..dot];
    }
    const second = try isoParseDigits(second_text);
    if (second > 59) return error.TypeMismatch;

    const ns = (@as(u64, hour) * 3_600 + @as(u64, minute) * 60 + second) *
        1_000_000_000 + fraction;
    return .{ .ns_since_midnight = ns, .fraction_digits = fraction_digits };
}

fn isoSplitTimestamp(text: []const u8) !struct { date: []const u8, time: []const u8 } {
    if (text.len < 11) return error.TypeMismatch;
    if (text[10] != 'T' and text[10] != ' ' and text[10] != 't') return error.TypeMismatch;
    return .{ .date = text[0..10], .time = text[11..] };
}

fn isoOffsetMinutes(text: []const u8) !i16 {
    if (text.len == 0) return error.TypeMismatch;
    if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;

    const sign: i16 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.TypeMismatch,
    };
    const numeric = text[1..];
    if (numeric.len == 0 or numeric.len > 5) return error.TypeMismatch;

    var hours: u16 = 0;
    var minutes: u16 = 0;
    if (numeric.len <= 2) {
        hours = @intCast(try isoParseDigits(numeric));
    } else if (numeric.len == 4) {
        hours = @intCast(try isoParseDigits(numeric[0..2]));
        minutes = @intCast(try isoParseDigits(numeric[2..4]));
    } else if (numeric.len == 5 and numeric[2] == ':') {
        hours = @intCast(try isoParseDigits(numeric[0..2]));
        minutes = @intCast(try isoParseDigits(numeric[3..5]));
    } else {
        return error.TypeMismatch;
    }
    if (hours > 23 or minutes > 59) return error.TypeMismatch;
    return sign * @as(i16, @intCast(hours * 60 + minutes));
}

/// Parse an ISO-style `YYYY-MM-DD` date. This is the explicit opt-in path for
/// PostgreSQL's default ISO date output; ordinary row decoding remains raw text.
pub fn parseIsoDate(text: []const u8) !Date {
    const parsed = try isoParseDateParts(text);
    return .{ .days_since_unix_epoch = std.math.cast(i32, parsed.days) orelse return error.Overflow };
}

/// Parse an ISO-style time with at most nine fractional digits.
pub fn parseIsoTime(text: []const u8) !Time {
    const parsed = try isoSplitTime(text, 9);
    return .{ .ns_since_midnight = parsed.ns_since_midnight };
}

fn isoCombineDateAndTime(date_text: []const u8, time_text: []const u8) !Timestamp {
    const days = try isoParseDateParts(date_text);
    const time = try isoSplitTime(time_text, 6);
    const day_us = std.math.mul(i64, days.days, 86_400_000_000) catch return error.Overflow;
    const time_us = std.math.cast(i64, time.ns_since_midnight / 1000) orelse return error.Overflow;
    return .{ .unix_us = std.math.add(i64, day_us, time_us) catch return error.Overflow };
}

/// Parse a naive ISO timestamp (`YYYY-MM-DD[T ]HH:MM[:SS[.fraction]]`) as UTC.
/// At most six fractional digits are accepted because `Timestamp` has
/// microsecond precision; a date without a time means midnight.
pub fn parseIsoTimestamp(text: []const u8) !Timestamp {
    if (std.mem.indexOfScalar(u8, text, ' ') == null and
        std.mem.indexOfAny(u8, text, "Tt") == null)
    {
        const days = try isoParseDateParts(text);
        return .{ .unix_us = std.math.mul(i64, days.days, 86_400_000_000) catch return error.Overflow };
    }

    const parts = try isoSplitTimestamp(text);
    if (std.mem.indexOfAny(u8, parts.time, "+-Zz") != null) return error.TypeMismatch;
    return isoCombineDateAndTime(parts.date, parts.time);
}

/// Parse an ISO timestamp with a required UTC offset (`Z` or `±HH[:]MM`) and
/// normalize it to UTC in the returned `Timestamp`.
pub fn parseIsoTimestampTz(text: []const u8) !Timestamp {
    if (text.len < 12) return error.TypeMismatch;
    const separator = std.mem.indexOfScalarPos(u8, text, 0, ' ') orelse
        std.mem.indexOfScalarPos(u8, text, 0, 'T') orelse
        std.mem.indexOfScalarPos(u8, text, 0, 't') orelse return error.TypeMismatch;

    var search_from = separator + 1;
    var offset_start: ?usize = null;
    while (search_from < text.len) : (search_from += 1) {
        switch (text[search_from]) {
            '+', '-', 'Z', 'z' => {
                offset_start = search_from;
                break;
            },
            ':', '.', '0'...'9' => {},
            else => return error.TypeMismatch,
        }
    }
    const found_offset = offset_start orelse return error.TypeMismatch;
    const offset_minutes = try isoOffsetMinutes(text[found_offset..]);

    var naive = try isoCombineDateAndTime(
        text[0..separator],
        text[separator + 1 .. found_offset],
    );

    const offset_us = std.math.mul(i64, offset_minutes, 60_000_000) catch return error.Overflow;
    naive.unix_us = std.math.sub(i64, naive.unix_us, offset_us) catch return error.Overflow;
    return naive;
}

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

test "parse ISO temporal values with explicit precision policy" {
    const date = try parseIsoDate("1970-01-01");
    try std.testing.expectEqual(@as(i32, 0), date.days_since_unix_epoch);

    const leap_date = try parseIsoDate("2000-02-29");
    try std.testing.expectEqual(@as(i32, 11016), leap_date.days_since_unix_epoch);

    const time = try parseIsoTime("23:59:07.123456789");
    try std.testing.expectEqual(@as(u64, ((23 * 60 + 59) * 60 + 7) * 1_000_000_000 + 123_456_789), time.ns_since_midnight);

    const naive = try parseIsoTimestamp("1970-01-02T03:04:05.123456");
    try std.testing.expectEqual(@as(i64, ((86_400 + 3 * 3600 + 4 * 60 + 5) * 1_000_000) + 123_456), naive.unix_us);

    const date_only_midnight = try parseIsoTimestamp("1970-01-01");
    try std.testing.expectEqual(@as(i64, 0), date_only_midnight.unix_us);

    const positive_offset = try parseIsoTimestampTz("1970-01-01 01:00:00+01:00");
    try std.testing.expectEqual(@as(i64, 0), positive_offset.unix_us);

    const negative_short_offset = try parseIsoTimestampTz("1970-01-01 00:00:00-0100");
    try std.testing.expectEqual(@as(i64, 3_600_000_000), negative_short_offset.unix_us);

    try std.testing.expectError(error.TypeMismatch, parseIsoDate("2001-02-29"));
    try std.testing.expectError(error.TypeMismatch, parseIsoDate("2000-02-29x"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTime("24:00:00"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestamp("2000-01-01 00:00:00.1234567"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestamp("2000-01-01 00:00:00Z"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestampTz("2000-01-01 00:00:00"));
}

test "parseUuid accepts canonical text" {
    const uuid = try parseUuid("550e8400-e29b-41d4-a716-446655440000");
    try @import("std").testing.expectEqual(@as(u8, 0x55), uuid.bytes[0]);
    try @import("std").testing.expectEqual(@as(u8, 0), uuid.bytes[15]);
}
