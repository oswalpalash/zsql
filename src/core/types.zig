//! Explicit SQL-domain value wrappers. Text-backed values borrow unless copied
//! by the caller; they intentionally carry no hidden allocator.

const std = @import("std");

pub const Text = struct { bytes: []const u8 };
pub const Blob = struct { bytes: []const u8 };

pub const Date = struct {
    days_since_unix_epoch: i32,

    /// Combine a UTC calendar date with nanoseconds since midnight.
    pub fn toUtcDateTime(self: Date, time: Time) !Timestamp {
        if (time.ns_since_midnight >= 86_400_000_000_000) return error.InvalidArguments;

        const day_us: i128 = @as(i128, self.days_since_unix_epoch) * 86_400_000_000;
        const time_us: i128 = @intCast(time.ns_since_midnight / 1_000);
        const total_us: i128 = day_us + time_us;
        const unix_us = std.math.cast(i64, total_us) orelse return error.Overflow;
        return .{ .unix_us = unix_us };
    }

    /// Exact buffer length required by `formatIso` for every representable date.
    pub const iso_buffer_len: usize = 17;

    /// Format as `YYYY-MM-DD` without allocation. Years wider than four digits
    /// are emitted in full.
    pub fn formatIso(self: Date, buffer: []u8) ![]const u8 {
        if (buffer.len < iso_buffer_len) return error.NoSpaceLeft;
        const civil = isoCivilFromDays(self.days_since_unix_epoch);
        var cursor = try isoWriteSignedFourDigits(buffer, civil.year);
        cursor += try isoWriteByteAndTwoDigits(buffer[cursor..], '-', civil.month);
        cursor += try isoWriteByteAndTwoDigits(buffer[cursor..], '-', civil.day);
        return buffer[0..cursor];
    }
};
pub const Time = struct {
    ns_since_midnight: u64,

    /// Exact buffer length required by `formatIso` for every valid time.
    pub const iso_buffer_len: usize = 18;

    /// Format as ISO time, omitting an all-zero fractional part and trailing
    /// fraction zeroes.
    pub fn formatIso(self: Time, buffer: []u8) ![]const u8 {
        if (buffer.len < iso_buffer_len) return error.NoSpaceLeft;
        if (self.ns_since_midnight >= 86_400_000_000_000) return error.InvalidArguments;

        var remaining = self.ns_since_midnight;
        const hour: u8 = @intCast(remaining / 3_600_000_000_000);
        remaining %= 3_600_000_000_000;
        const minute: u8 = @intCast(remaining / 60_000_000_000);
        remaining %= 60_000_000_000;
        const second: u8 = @intCast(remaining / 1_000_000_000);
        const nanoseconds: u32 = @intCast(remaining % 1_000_000_000);

        const formatted = try std.fmt.bufPrint(
            buffer,
            "{d:0>2}:{d:0>2}:{d:0>2}",
            .{ hour, minute, second },
        );
        var total_len = formatted.len;
        if (nanoseconds != 0) {
            var fraction = try std.fmt.bufPrint(
                buffer[total_len..],
                ".{d:0>9}",
                .{nanoseconds},
            );
            while (fraction.len > 0 and fraction[fraction.len - 1] == '0') {
                fraction.len -= 1;
            }
            total_len += fraction.len;
        }
        return buffer[0..total_len];
    }
};
pub const TimeTz = struct {
    /// Local wall-clock nanoseconds since midnight.
    nanos_since_midnight: u64,
    /// UTC offset east of UTC in seconds.
    offset_seconds: i32,

    /// Exact buffer length required by `formatIso` for every valid value.
    pub const iso_buffer_len: usize = 27;

    /// UTC nanoseconds since midnight, wrapping across the date boundary.
    pub fn utcNanosSinceMidnight(self: TimeTz) u64 {
        const local: i128 = @intCast(self.nanos_since_midnight);
        const offset: i128 = @as(i128, self.offset_seconds) * 1_000_000_000;
        return @intCast(@mod(local - offset, 86_400_000_000_000));
    }

    /// Combine this timezone-aware time with a calendar date and normalize the
    /// result to UTC. The wall-clock date may shift when the offset crosses
    /// midnight.
    pub fn utcTimestamp(self: TimeTz, date: Date) !Timestamp {
        if (self.nanos_since_midnight >= 86_400_000_000_000) return error.InvalidArguments;
        if (self.offset_seconds < -86_400 or self.offset_seconds > 86_400) {
            return error.InvalidArguments;
        }

        const day_us = std.math.mul(i64, date.days_since_unix_epoch, 86_400_000_000) catch
            return error.Overflow;
        const local_us: i128 = @intCast(self.nanos_since_midnight / 1_000);
        const offset_us: i128 = @as(i128, self.offset_seconds) * 1_000_000;
        const total_us: i128 = @as(i128, day_us) + local_us - offset_us;
        return .{ .unix_us = std.math.cast(i64, total_us) orelse return error.Overflow };
    }

    /// Format the local time plus an explicit numeric UTC offset. A zero offset
    /// remains `+00:00` so the original timezone policy stays visible.
    pub fn formatIso(self: TimeTz, buffer: []u8) ![]const u8 {
        if (buffer.len < iso_buffer_len) return error.NoSpaceLeft;
        if (self.nanos_since_midnight >= 86_400_000_000_000) return error.InvalidArguments;
        if (self.offset_seconds < -86_400 or self.offset_seconds > 86_400) {
            return error.InvalidArguments;
        }

        const local = try (Time{ .ns_since_midnight = self.nanos_since_midnight }).formatIso(buffer[0..Time.iso_buffer_len]);
        var cursor: usize = local.len;

        var offset: i32 = self.offset_seconds;
        buffer[cursor] = if (offset < 0) '-' else '+';
        cursor += 1;
        if (offset < 0) offset = -offset;
        const hours: u8 = @intCast(@divTrunc(offset, 3_600));
        const minutes: u8 = @intCast(@divTrunc(@mod(offset, 3_600), 60));
        const seconds: u8 = @intCast(@mod(offset, 60));

        const rendered = try std.fmt.bufPrint(
            buffer[cursor..],
            "{d:0>2}:{d:0>2}",
            .{ hours, minutes },
        );
        cursor += rendered.len;
        if (seconds != 0) {
            const rendered_seconds = try std.fmt.bufPrint(
                buffer[cursor..],
                ":{d:0>2}",
                .{seconds},
            );
            cursor += rendered_seconds.len;
        }
        return buffer[0..cursor];
    }
};
pub const Timestamp = struct {
    unix_us: i64,

    /// Exact buffer length required by `formatIsoUtc` for every representable
    /// timestamp.
    pub const iso_buffer_len: usize = 32;

    /// A UTC timestamp decomposed into explicit calendar and wall-clock parts.
    pub const UtcDateTime = struct {
        date: Date,
        time: Time,
    };

    /// A timestamp decomposed into an explicit calendar date and a local time
    /// that carries its UTC offset.
    pub const OffsetDateTime = struct {
        date: Date,
        time: TimeTz,

        /// Normalize this wall-clock date/time back to the same UTC instant.
        pub fn utcTimestamp(self: OffsetDateTime) !Timestamp {
            return self.time.utcTimestamp(self.date);
        }
    };

    /// Decompose into a UTC calendar date and nanosecond-precision time.
    pub fn toUtcDateTime(self: Timestamp) !UtcDateTime {
        const seconds = @divFloor(self.unix_us, 1_000_000);
        const microseconds: u32 = @intCast(@mod(self.unix_us, 1_000_000));
        const days_i64 = @divFloor(seconds, 86_400);
        const days = std.math.cast(i32, days_i64) orelse return error.Overflow;
        const second_of_day_i64 = @mod(seconds, 86_400);
        const second_of_day: u32 = @intCast(second_of_day_i64);

        return .{
            .date = .{ .days_since_unix_epoch = days },
            .time = .{
                .ns_since_midnight = @as(u64, second_of_day) * 1_000_000_000 +
                    @as(u64, microseconds) * 1_000,
            },
        };
    }

    /// Decompose into local calendar and timezone-aware time parts using an
    /// explicit UTC offset in seconds.
    pub fn toOffsetDateTime(self: Timestamp, offset_seconds: i32) !OffsetDateTime {
        if (offset_seconds < -86_400 or offset_seconds > 86_400) return error.InvalidArguments;

        const total_seconds = @divFloor(self.unix_us, 1_000_000);
        const microseconds: u32 = @intCast(@mod(self.unix_us, 1_000_000));
        const shifted_seconds = std.math.add(i64, total_seconds, offset_seconds) catch
            return error.Overflow;
        const days_i64 = @divFloor(shifted_seconds, 86_400);
        const seconds_of_day_i64 = @mod(shifted_seconds, 86_400);
        const days = std.math.cast(i32, days_i64) orelse return error.Overflow;
        const seconds_of_day: u32 = @intCast(seconds_of_day_i64);

        return .{
            .date = .{ .days_since_unix_epoch = days },
            .time = .{
                .nanos_since_midnight = @as(u64, seconds_of_day) * 1_000_000_000 +
                    @as(u64, microseconds) * 1_000,
                .offset_seconds = offset_seconds,
            },
        };
    }

    /// Format as an ISO UTC timestamp ending in `Z`, omitting an all-zero or
    /// trailing-zero fractional part.
    pub fn formatIsoUtc(self: Timestamp, buffer: []u8) ![]const u8 {
        if (buffer.len < iso_buffer_len) return error.NoSpaceLeft;
        const seconds = @divFloor(self.unix_us, 1_000_000);
        const microseconds: u32 = @intCast(@mod(self.unix_us, 1_000_000));
        const days_i64 = @divFloor(seconds, 86_400);
        const days: i32 = std.math.cast(i32, days_i64) orelse return error.Overflow;
        var second_of_day: u32 = @intCast(@mod(seconds, 86_400));

        const hour: u8 = @intCast(second_of_day / 3_600);
        second_of_day %= 3_600;
        const minute: u8 = @intCast(second_of_day / 60);
        const second: u8 = @intCast(second_of_day % 60);

        var date_buffer: [Date.iso_buffer_len]u8 = undefined;
        const date = try (Date{
            .days_since_unix_epoch = days,
        }).formatIso(&date_buffer);

        var cursor = (try isoCopy(buffer, date)).len;
        cursor += try isoWriteByte(buffer[cursor..], 'T');
        const formatted = try std.fmt.bufPrint(
            buffer[cursor..],
            "{d:0>2}:{d:0>2}:{d:0>2}",
            .{ hour, minute, second },
        );
        var time_len = formatted.len;
        if (microseconds != 0) {
            var fraction = try std.fmt.bufPrint(
                buffer[cursor + time_len ..],
                ".{d:0>6}",
                .{microseconds},
            );
            while (fraction.len > 0 and fraction[fraction.len - 1] == '0') {
                fraction.len -= 1;
            }
            time_len += fraction.len;
        }
        cursor += time_len;
        cursor += try isoWriteByte(buffer[cursor..], 'Z');
        return buffer[0..cursor];
    }
};
pub const Numeric = struct { text: []const u8 };
pub const Uuid = struct {
    bytes: [16]u8,

    /// Format as canonical lowercase hyphenated UUID text without allocation.
    pub fn formatCanonical(self: Uuid, buffer: []u8) ![]const u8 {
        if (buffer.len < 36) return error.NoSpaceLeft;

        const digits = "0123456789abcdef";
        var cursor: usize = 0;
        for (self.bytes, 0..) |byte, index| {
            if (index == 4 or index == 6 or index == 8 or index == 10) {
                buffer[cursor] = '-';
                cursor += 1;
            }
            buffer[cursor] = digits[byte >> 4];
            buffer[cursor + 1] = digits[byte & 0x0f];
            cursor += 2;
        }
        return buffer[0..cursor];
    }

    pub fn eql(self: Uuid, other: Uuid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

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

fn isoCivilFromDays(days: i64) struct { year: i64, month: u8, day: u8 } {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const day_of_era = z - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1_460) + @divFloor(day_of_era, 36_524) -
            @divFloor(day_of_era, 146_096),
        365,
    );
    const year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_index + 2, 5) + 1;
    const month = month_index + (if (month_index < 10) @as(i64, 3) else -9);
    return .{
        .year = year + (if (month <= 2) @as(i64, 1) else 0),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn isoWriteSignedFourDigits(buffer: []u8, value: i64) !usize {
    if (value < 0) {
        const magnitude = std.math.cast(u64, -value) orelse return error.NoSpaceLeft;
        return (try std.fmt.bufPrint(buffer, "-{d:0>4}", .{magnitude})).len;
    }
    const magnitude = std.math.cast(u64, value) orelse return error.NoSpaceLeft;
    return (try std.fmt.bufPrint(buffer, "{d:0>4}", .{magnitude})).len;
}

fn isoCopy(output: []u8, bytes: []const u8) ![]const u8 {
    if (output.len < bytes.len) return error.NoSpaceLeft;
    @memcpy(output[0..bytes.len], bytes);
    return output[0..bytes.len];
}

fn isoWriteByte(output: []u8, byte: u8) !usize {
    if (output.len == 0) return error.NoSpaceLeft;
    output[0] = byte;
    return 1;
}

fn isoWriteByteAndTwoDigits(output: []u8, byte: u8, value: u8) !usize {
    if (output.len < 3) return error.NoSpaceLeft;
    output[0] = byte;
    _ = try std.fmt.bufPrint(output[1..3], "{d:0>2}", .{value});
    return 3;
}

fn isoWriteTwoDigits(buffer: []u8, value: u8) !usize {
    return std.fmt.bufPrint(buffer, "{d:0>2}", .{value});
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

fn isoParseYearDigits(text: []const u8) !i64 {
    if (text.len == 0 or text.len > 10) return error.TypeMismatch;
    var value: i64 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return error.TypeMismatch;
        const next = std.math.mul(i64, value, 10) catch return error.TypeMismatch;
        value = next + (char - '0');
    }
    return value;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isoDaysFromCivilYear(year: i64, month: u8, day: u8) !i64 {
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

const IsoParsedDate = struct {
    end: usize,
    year: i64,
    month: u8,
    day: u8,
};

fn isoParseSignedYear(text: []const u8) !i64 {
    if (text.len == 0 or text.len > 10) return error.TypeMismatch;

    var sign: i64 = 1;
    var digits = text;
    switch (text[0]) {
        '+' => digits = text[1..],
        '-' => {
            sign = -1;
            digits = text[1..];
        },
        '0'...'9' => {},
        else => return error.TypeMismatch,
    }

    // Four-digit years may omit a sign. Expanded years require a sign when
    // negative and may optionally use one when positive.
    if (digits.len < 4) return error.TypeMismatch;
    const magnitude: i64 = try isoParseYearDigits(digits);
    const year = sign * magnitude;
    return year;
}

fn isoParseDatePrefix(text: []const u8) !IsoParsedDate {
    if (text.len < 10) return error.TypeMismatch;

    var year_start: usize = 0;
    if (text[0] == '+' or text[0] == '-') year_start = 1;

    const first_hyphen = std.mem.indexOfScalarPos(
        u8,
        text,
        year_start,
        '-',
    ) orelse return error.TypeMismatch;
    if (first_hyphen < year_start + 4 or first_hyphen + 3 >= text.len) {
        return error.TypeMismatch;
    }

    const second_hyphen = first_hyphen + 3;
    if (text[second_hyphen] != '-') return error.TypeMismatch;
    const date_end = second_hyphen + 3;

    const year = try isoParseSignedYear(text[0..first_hyphen]);
    const month_value = try isoParseDigits(text[first_hyphen + 1 .. second_hyphen]);
    const day_value = try isoParseDigits(text[second_hyphen + 1 .. date_end]);
    const month = std.math.cast(u8, month_value) orelse return error.TypeMismatch;
    const day = std.math.cast(u8, day_value) orelse return error.TypeMismatch;

    return .{
        .end = date_end,
        .year = year,
        .month = month,
        .day = day,
    };
}

fn isoParseDateParts(text: []const u8) !struct { days: i64 } {
    const era = try isoSplitEra(text);
    var parsed = try isoParseDatePrefix(era.text);
    if (parsed.end != era.text.len) return error.TypeMismatch;
    if (era.bc and parsed.year <= 0) return error.TypeMismatch;
    if (era.bc) parsed.year = 1 - parsed.year;
    const cast_year = std.math.cast(i32, parsed.year) orelse return error.Overflow;
    return .{ .days = try isoDaysFromCivilYear(cast_year, parsed.month, parsed.day) };
}

const IsoEra = struct { text: []const u8, bc: bool };

fn isoSplitEra(text: []const u8) !IsoEra {
    if (text.len >= 2 and std.ascii.eqlIgnoreCase(text[text.len - 2 ..], "bc")) {
        var end = text.len - 2;
        while (end > 0 and isSpace(text[end - 1])) end -= 1;
        if (end == 0) return error.TypeMismatch;
        return .{ .text = text[0..end], .bc = true };
    }
    return .{ .text = text, .bc = false };
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

const IsoTimestampParts = struct {
    days: i64,
    time: []const u8,
    bc: bool,
};

fn isoSplitTimestamp(full_text: []const u8) !IsoTimestampParts {
    const era = try isoSplitEra(full_text);
    const parsed = try isoParseDatePrefix(era.text);
    if (parsed.end >= era.text.len) return error.TypeMismatch;
    switch (era.text[parsed.end]) {
        'T', ' ', 't' => {},
        else => return error.TypeMismatch,
    }
    var year = parsed.year;
    if (era.bc) {
        if (year <= 0) return error.TypeMismatch;
        year = 1 - year;
    }
    const cast_year = std.math.cast(i32, year) orelse return error.Overflow;
    const days = try isoDaysFromCivilYear(cast_year, parsed.month, parsed.day);
    return .{ .days = days, .time = era.text[parsed.end + 1 ..], .bc = era.bc };
}

fn isoOffsetSeconds(text: []const u8) !i64 {
    if (text.len == 0) return error.TypeMismatch;
    if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;

    const sign: i64 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.TypeMismatch,
    };
    const numeric = text[1..];
    if (numeric.len == 0 or numeric.len > 8) return error.TypeMismatch;

    var hours: u16 = 0;
    var minutes: u16 = 0;
    var seconds: u16 = 0;
    if (numeric.len <= 2) {
        hours = @intCast(try isoParseDigits(numeric));
    } else if (numeric.len == 4) {
        hours = @intCast(try isoParseDigits(numeric[0..2]));
        minutes = @intCast(try isoParseDigits(numeric[2..4]));
    } else if (numeric.len == 5 and numeric[2] == ':') {
        hours = @intCast(try isoParseDigits(numeric[0..2]));
        minutes = @intCast(try isoParseDigits(numeric[3..5]));
    } else if (numeric.len == 6) {
        hours = @intCast(try isoParseDigits(numeric[0..2]));
        minutes = @intCast(try isoParseDigits(numeric[2..4]));
        seconds = @intCast(try isoParseDigits(numeric[4..6]));
    } else if (numeric.len == 8 and numeric[2] == ':' and numeric[5] == ':') {
        hours = @intCast(try isoParseDigits(numeric[0..2]));
        minutes = @intCast(try isoParseDigits(numeric[3..5]));
        seconds = @intCast(try isoParseDigits(numeric[6..8]));
    } else {
        return error.TypeMismatch;
    }
    if (hours > 23 or minutes > 59 or seconds > 59) return error.TypeMismatch;
    return sign * (@as(i64, hours) * 3_600 + @as(i64, minutes) * 60 + seconds);
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

/// Parse a timezone-aware ISO time (`HH:MM[:SS[.fraction]]Z|±HH[:MM[:SS]]`).
pub fn parseIsoTimeTz(text: []const u8) !TimeTz {
    if (text.len < 2) return error.TypeMismatch;

    var base_end = text.len;
    var offset_text: []const u8 = "";
    const last = text[text.len - 1];
    if (last == 'Z' or last == 'z') {
        base_end = text.len - 1;
        offset_text = text[base_end..];
    } else {
        if (std.mem.indexOfAnyPos(u8, text, 1, "+-")) |marker| {
            base_end = marker;
            offset_text = text[marker..];
        }
    }
    if (base_end == 0 or offset_text.len == 0) return error.TypeMismatch;

    const time = try isoSplitTime(text[0..base_end], 9);
    const offset_seconds_i64 = try isoOffsetSeconds(offset_text);
    if (offset_seconds_i64 < -86_400 or offset_seconds_i64 > 86_400) return error.TypeMismatch;
    return .{
        .nanos_since_midnight = time.ns_since_midnight,
        .offset_seconds = @intCast(offset_seconds_i64),
    };
}

fn isoCombineDateAndTime(days: i64, time_text: []const u8) !Timestamp {
    const time = try isoSplitTime(time_text, 6);
    // Widen while combining so a negative date plus a positive time can cross
    // an i64-second boundary without an intermediate overflow.
    const day_us = @as(i128, days) * 86_400_000_000;
    const time_us = @as(i128, time.ns_since_midnight / 1_000);
    const total_us = day_us + time_us;
    return .{ .unix_us = std.math.cast(i64, total_us) orelse return error.Overflow };
}

/// Parse a naive ISO timestamp (`YYYY-MM-DD[T ]HH:MM[:SS[.fraction]]`) as UTC.
/// At most six fractional digits are accepted because `Timestamp` has
/// microsecond precision; a date without a time means midnight.
pub fn parseIsoTimestamp(text: []const u8) !Timestamp {
    if (std.mem.indexOfScalar(u8, text, ' ') == null and
        std.mem.indexOfAny(u8, text, "Tt") == null)
    {
        const parsed = try isoParseDateParts(text);
        return isoCombineDateAndTime(parsed.days, "00:00:00");
    }

    const parts = try isoSplitTimestamp(text);
    if (std.mem.indexOfAny(u8, parts.time, "+-Zz") != null) return error.TypeMismatch;
    return isoCombineDateAndTime(parts.days, parts.time);
}

/// Parse an ISO timestamp with a required UTC offset (`Z` or `±HH[:]MM`) and
/// normalize it to UTC in the returned `Timestamp`.
pub fn parseIsoTimestampTz(text: []const u8) !Timestamp {
    const parts = try isoSplitTimestamp(text);
    var offset_start: ?usize = null;
    var index: usize = 0;
    while (index < parts.time.len) : (index += 1) {
        switch (parts.time[index]) {
            '+', '-', 'Z', 'z' => {
                offset_start = index;
                break;
            },
            ':', '.', '0'...'9' => {},
            else => return error.TypeMismatch,
        }
    }
    const found_offset = offset_start orelse return error.TypeMismatch;
    const offset_seconds = try isoOffsetSeconds(parts.time[found_offset..]);

    var naive = try isoCombineDateAndTime(
        parts.days,
        parts.time[0..found_offset],
    );

    const offset_us = std.math.mul(i64, offset_seconds, 1_000_000) catch return error.Overflow;
    naive.unix_us = std.math.sub(i64, naive.unix_us, offset_us) catch return error.Overflow;
    return naive;
}

/// Parse an ISO timestamp as a UTC instant: a naive value is interpreted as
/// UTC, while `Z` or an explicit offset is normalized to UTC.
pub fn parseIsoTimestampInstant(text: []const u8) !Timestamp {
    if (std.mem.indexOfScalar(u8, text, ' ') == null and
        std.mem.indexOfAny(u8, text, "Tt") == null)
    {
        return parseIsoTimestamp(text);
    }
    const parts = try isoSplitTimestamp(text);
    if (std.mem.indexOfAny(u8, parts.time, "+-Zz") != null)
        return parseIsoTimestampTz(text);
    return parseIsoTimestamp(text);
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
    const second_offset = try parseIsoTimestampTz("1900-01-01 12:00:00-07:52:58");
    try std.testing.expectEqual(@as(i64, -2_208_917_222_000_000), second_offset.unix_us);

    // PostgreSQL spells pre-Gregorian output with an era suffix but maps it to
    // the astronomical year used by Date's signed-year representation.
    const bc_date = try parseIsoDate("0001-01-01 BC");
    try std.testing.expectEqual(@as(i32, -719528), bc_date.days_since_unix_epoch);
    const bc_timestamp = try parseIsoTimestampTz("0001-01-01 00:00:00+00 BC");
    try std.testing.expectEqual(@as(i64, -62_167_219_200_000_000), bc_timestamp.unix_us);
    try std.testing.expectEqual(@as(i32, -719528), (try parseIsoDate("0000-01-01")).days_since_unix_epoch);
    try std.testing.expectEqual(@as(i64, 0), (try parseIsoTimestampInstant("1970-01-01 01:00:00+01:00")).unix_us);
    try std.testing.expectEqual(@as(i64, 0), (try parseIsoTimestampInstant("1970-01-01T00:00:00Z")).unix_us);
    try std.testing.expectEqual(@as(i64, 0), (try parseIsoTimestampInstant("1970-01-01")).unix_us);

    try std.testing.expectError(error.TypeMismatch, parseIsoDate("2001-02-29"));
    try std.testing.expectError(error.TypeMismatch, parseIsoDate("2000-02-29x"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTime("24:00:00"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestamp("2000-01-01 00:00:00.1234567"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestamp("2000-01-01 00:00:00Z"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestampTz("2000-01-01 00:00:00"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimestampInstant("not-a-time"));
    try std.testing.expectError(error.TypeMismatch, parseIsoDate("0001-01-01 B.C."));
    try std.testing.expectError(error.TypeMismatch, parseIsoDate("0000-01-01 BC"));

    // Expanded and signed years round-trip across the full wrapper range.
    var buffer: [40]u8 = undefined;
    const wide_date = try parseIsoDate("12000-01-01");
    try std.testing.expectEqual(wide_date, try parseIsoDate(try wide_date.formatIso(&buffer)));

    const negative_date = try parseIsoDate("-0001-01-01");
    try std.testing.expectEqual(negative_date, try parseIsoDate(try negative_date.formatIso(&buffer)));

    const minimum_date = Date{ .days_since_unix_epoch = std.math.minInt(i32) };

    const maximum_date = Date{ .days_since_unix_epoch = std.math.maxInt(i32) };

    try std.testing.expectEqual(
        minimum_date,
        try parseIsoDate(try minimum_date.formatIso(&buffer)),
    );
    try std.testing.expectEqual(
        maximum_date,
        try parseIsoDate(try maximum_date.formatIso(&buffer)),
    );

    const wide_timestamp = try parseIsoTimestamp("12000-01-01T00:00:00");
    try std.testing.expectEqual(
        wide_timestamp,
        try parseIsoTimestampTz(try wide_timestamp.formatIsoUtc(&buffer)),
    );

    const negative_timestamp = try parseIsoTimestamp("-0001-01-01T00:00:00");
    try std.testing.expectEqual(
        negative_timestamp,
        try parseIsoTimestampTz(try negative_timestamp.formatIsoUtc(&buffer)),
    );
}

test "format ISO temporal wrappers without allocation" {
    var buffer: [32]u8 = undefined;

    const epoch_date = try (try parseIsoDate("1970-01-01")).formatIso(&buffer);
    try std.testing.expectEqualStrings("1970-01-01", epoch_date);

    const pre_epoch_date = try (try parseIsoDate("1969-12-31")).formatIso(&buffer);
    try std.testing.expectEqualStrings("1969-12-31", pre_epoch_date);

    const leap_date = try (try parseIsoDate("2000-02-29")).formatIso(&buffer);
    try std.testing.expectEqualStrings("2000-02-29", leap_date);

    const whole_second_time = try (try parseIsoTime("13:04:05")).formatIso(&buffer);
    try std.testing.expectEqualStrings("13:04:05", whole_second_time);

    const fractional_time = try (try parseIsoTime("13:04:05.120000000")).formatIso(&buffer);
    try std.testing.expectEqualStrings("13:04:05.12", fractional_time);

    const whole_second_timestamp = try (try parseIsoTimestamp(
        "2000-02-29T23:59:59",
    )).formatIsoUtc(&buffer);
    try std.testing.expectEqualStrings("2000-02-29T23:59:59Z", whole_second_timestamp);

    const pre_epoch_timestamp = try (try parseIsoTimestamp(
        "1969-12-31 23:59:59.999999",
    )).formatIsoUtc(&buffer);
    try std.testing.expectEqualStrings("1969-12-31T23:59:59.999999Z", pre_epoch_timestamp);

    const date = try parseIsoDate("2024-02-29");
    const time = try parseIsoTime("04:05:06.007");
    const timestamp = try parseIsoTimestamp("2024-02-29T04:05:06.000007");
    try std.testing.expectEqual(date, try parseIsoDate(try date.formatIso(&buffer)));
    try std.testing.expectEqual(time, try parseIsoTime(try time.formatIso(&buffer)));
    try std.testing.expectEqual(timestamp, try parseIsoTimestampTz(try timestamp.formatIsoUtc(&buffer)));

    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, date.formatIso(&tiny));
}

test "ISO formatter buffer lengths cover temporal extrema" {
    try std.testing.expectEqual(@as(usize, 17), Date.iso_buffer_len);
    try std.testing.expectEqual(@as(usize, 18), Time.iso_buffer_len);
    try std.testing.expectEqual(@as(usize, 32), Timestamp.iso_buffer_len);

    const minimum_date = Date{ .days_since_unix_epoch = std.math.minInt(i32) };
    const maximum_date = Date{ .days_since_unix_epoch = std.math.maxInt(i32) };
    var short_date: [Date.iso_buffer_len - 1]u8 = undefined;
    var date_buffer: [Date.iso_buffer_len]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, minimum_date.formatIso(&short_date));
    try std.testing.expectEqual(
        minimum_date,
        try parseIsoDate(try minimum_date.formatIso(&date_buffer)),
    );
    try std.testing.expectEqual(
        maximum_date,
        try parseIsoDate(try maximum_date.formatIso(&date_buffer)),
    );

    const maximum_time = Time{ .ns_since_midnight = 86_400_000_000_000 - 1 };
    var short_time: [Time.iso_buffer_len - 1]u8 = undefined;
    var time_buffer: [Time.iso_buffer_len]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, maximum_time.formatIso(&short_time));
    try std.testing.expectEqual(
        maximum_time,
        try parseIsoTime(try maximum_time.formatIso(&time_buffer)),
    );

    const minimum_timestamp = Timestamp{ .unix_us = std.math.minInt(i64) };
    const maximum_timestamp = Timestamp{ .unix_us = std.math.maxInt(i64) };
    var short_timestamp: [Timestamp.iso_buffer_len - 1]u8 = undefined;
    var timestamp_buffer: [Timestamp.iso_buffer_len]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, minimum_timestamp.formatIsoUtc(&short_timestamp));
    const formatted_minimum = try minimum_timestamp.formatIsoUtc(&timestamp_buffer);
    try std.testing.expectEqual(
        minimum_timestamp,
        try parseIsoTimestampInstant(formatted_minimum),
    );
    try std.testing.expectEqual(
        maximum_timestamp,
        try parseIsoTimestampInstant(try maximum_timestamp.formatIsoUtc(&timestamp_buffer)),
    );
}

test "parse and format timezone-aware times" {
    const time_tz = try parseIsoTimeTz("04:05:06.007000000+07:52:58");
    try std.testing.expectEqual(@as(u64, ((4 * 60 + 5) * 60 + 6) * 1_000_000_000 + 7_000_000), time_tz.nanos_since_midnight);
    try std.testing.expectEqual(@as(i32, 28378), time_tz.offset_seconds);

    var buffer: [TimeTz.iso_buffer_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "04:05:06.007+07:52:58",
        try time_tz.formatIso(&buffer),
    );

    const zero_offset = try parseIsoTimeTz("23:59:59Z");
    try std.testing.expectEqual(@as(i32, 0), zero_offset.offset_seconds);
    var short_buffer: [TimeTz.iso_buffer_len - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, zero_offset.formatIso(&short_buffer));

    const wrapped_utc = (try parseIsoTimeTz("00:00:00+02:00")).utcNanosSinceMidnight();
    try std.testing.expectEqual(@as(u64, 22 * 3_600_000_000_000), wrapped_utc);

    const crossed_utc = (try parseIsoTimeTz("01:00:00-01:00")).utcNanosSinceMidnight();
    try std.testing.expectEqual(@as(u64, 2 * 3_600_000_000_000), crossed_utc);

    try std.testing.expectError(error.TypeMismatch, parseIsoTimeTz("24:00:00+00"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimeTz("12:00:00"));
    try std.testing.expectError(error.TypeMismatch, parseIsoTimeTz("12:00:00+25:00"));
}

test "combine timezone-aware time with calendar date in UTC" {
    var buffer: [Timestamp.iso_buffer_len]u8 = undefined;
    const epoch_date = try parseIsoDate("1970-01-01");
    const one_hour_ahead = try parseIsoTimeTz("01:00:00+01:00");
    const epoch = try one_hour_ahead.utcTimestamp(epoch_date);
    try std.testing.expectEqual(@as(i64, 0), epoch.unix_us);

    // 2024-02-29 01:30 local at UTC-02:30 is 04:00 UTC on the same date.
    const same_day_date = try parseIsoDate("2024-02-29");
    const behind = try parseIsoTimeTz("01:30:00-02:30");
    const same_day_utc = try behind.utcTimestamp(same_day_date);
    try std.testing.expectEqualStrings(
        "2024-02-29T04:00:00Z",
        try same_day_utc.formatIsoUtc(&buffer),
    );

    // 1970-01-01 00:30 local at UTC+01:00 is 1969-12-31 23:30 UTC.
    const ahead = try parseIsoTimeTz("00:30:00+01:00");
    const previous_day_utc = try ahead.utcTimestamp(epoch_date);
    try std.testing.expectEqualStrings(
        "1969-12-31T23:30:00Z",
        try previous_day_utc.formatIsoUtc(&buffer),
    );

    const invalid_time = TimeTz{ .nanos_since_midnight = 86_400_000_000_000, .offset_seconds = 0 };
    try std.testing.expectError(error.InvalidArguments, invalid_time.utcTimestamp(epoch_date));
}

test "decompose UTC timestamps into explicit date and time" {
    const timestamp = try parseIsoTimestampInstant("2024-02-29T04:05:06.000007Z");
    const parts = try timestamp.toUtcDateTime();

    try std.testing.expectEqual(@as(i32, 19782), parts.date.days_since_unix_epoch);
    try std.testing.expectEqual(
        @as(u64, ((4 * 60 + 5) * 60 + 6) * 1_000_000_000 + 7_000),
        parts.time.ns_since_midnight,
    );

    var buffer: [Timestamp.iso_buffer_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2024-02-29T04:05:06.000007Z",
        try (try parts.date.toUtcDateTime(parts.time)).formatIsoUtc(&buffer),
    );

    for ([_]i64{ std.math.minInt(i64), -1, 0, 1, std.math.maxInt(i64) }) |unix_us| {
        const extreme = Timestamp{ .unix_us = unix_us };
        const extreme_parts = try extreme.toUtcDateTime();
        try std.testing.expect(extreme_parts.time.ns_since_midnight < 86_400_000_000_000);
        try std.testing.expectEqual(
            extreme,
            try extreme_parts.date.toUtcDateTime(extreme_parts.time),
        );
    }
}

test "decompose timestamps into explicit offset date and time" {
    const timestamp = try parseIsoTimestampInstant("2024-03-10T01:30:00.250000Z");
    const behind = try timestamp.toOffsetDateTime(-2 * 3_600 - 30 * 60);

    try std.testing.expectEqual(@as(i32, 19791), behind.date.days_since_unix_epoch);
    try std.testing.expectEqual(
        @as(u64, 23 * 3_600_000_000_000 + 250_000_000),
        behind.time.nanos_since_midnight,
    );
    try std.testing.expectEqual(@as(i32, -9_000), behind.time.offset_seconds);

    var buffer: [TimeTz.iso_buffer_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "23:00:00.25-02:30",
        try behind.time.formatIso(&buffer),
    );
    try std.testing.expectEqual(timestamp, try behind.utcTimestamp());

    // Positive offsets can move the wall clock to the next calendar day.
    const ahead = try timestamp.toOffsetDateTime(23 * 3_600 + 30 * 60);
    try std.testing.expectEqual(@as(i32, 19793), ahead.date.days_since_unix_epoch);
    try std.testing.expectEqual(
        @as(u64, 3_600_000_000_000 + 250_000_000),
        ahead.time.nanos_since_midnight,
    );
    try std.testing.expectEqual(@as(i32, 84_600), ahead.time.offset_seconds);

    try std.testing.expectEqual(timestamp, try ahead.utcTimestamp());
}

test "offset decomposition round-trips deterministic instants" {
    var prng = std.Random.DefaultPrng.init(0x7350_7c1e);
    const random = prng.random();

    for (0..2_000) |_| {
        const unix_us = random.int(i64);
        const offset_seconds: i32 = @intCast(random.intRangeAtMost(i32, -86_400, 86_400));
        const timestamp = Timestamp{ .unix_us = unix_us };
        const offset = try timestamp.toOffsetDateTime(offset_seconds);

        try std.testing.expectEqual(offset_seconds, offset.time.offset_seconds);
        try std.testing.expect(offset.date.days_since_unix_epoch >= std.math.minInt(i32));
        try std.testing.expect(offset.date.days_since_unix_epoch <= std.math.maxInt(i32));
        try std.testing.expect(offset.time.nanos_since_midnight < 86_400_000_000_000);
        try std.testing.expectEqual(timestamp, try offset.utcTimestamp());
    }
}

test "parseUuid accepts canonical text" {
    const uuid = try parseUuid("550e8400-e29b-41d4-a716-446655440000");
    try @import("std").testing.expectEqual(@as(u8, 0x55), uuid.bytes[0]);
    try @import("std").testing.expectEqual(@as(u8, 0), uuid.bytes[15]);
}

test "format UUID as canonical lowercase text without allocation" {
    const mixed = try parseUuid("550E8400-E29B-41D4-A716-4466554400FF");
    var buffer: [36]u8 = undefined;
    try std.testing.expectEqualStrings(
        "550e8400-e29b-41d4-a716-4466554400ff",
        try mixed.formatCanonical(&buffer),
    );

    var tiny: [35]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, mixed.formatCanonical(&tiny));

    const other = try parseUuid("550e8400-e29b-41d4-a716-4466554400fe");
    try std.testing.expect(mixed.eql(mixed));
    try std.testing.expect(!mixed.eql(other));
}
