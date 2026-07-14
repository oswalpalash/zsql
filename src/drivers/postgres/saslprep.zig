const std = @import("std");
const tables = @import("saslprep_tables.zig");

const hangul = struct {
    const s_base: u21 = 0xac00;
    const l_base: u21 = 0x1100;
    const v_base: u21 = 0x1161;
    const t_base: u21 = 0x11a7;
    const l_count: u21 = 19;
    const v_count: u21 = 21;
    const t_count: u21 = 28;
    const n_count: u21 = v_count * t_count;
    const s_count: u21 = l_count * n_count;
};

pub fn normalizeNfkc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(input) catch return error.InvalidUtf8;
    var decomposed: std.ArrayListUnmanaged(u21) = .empty;
    defer decomposed.deinit(allocator);

    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= hangul.s_base and codepoint < hangul.s_base + hangul.s_count) {
            const index = codepoint - hangul.s_base;
            try appendCanonical(allocator, &decomposed, hangul.l_base + index / hangul.n_count);
            try appendCanonical(allocator, &decomposed, hangul.v_base + (index % hangul.n_count) / hangul.t_count);
            const trailing = index % hangul.t_count;
            if (trailing != 0) try appendCanonical(allocator, &decomposed, hangul.t_base + trailing);
        } else if (decomposition(codepoint)) |scalars| {
            for (scalars) |scalar| try appendCanonical(allocator, &decomposed, scalar);
        } else {
            try appendCanonical(allocator, &decomposed, codepoint);
        }
    }

    const composed_len = composeCanonical(decomposed.items);

    var encoded_len: usize = 0;
    for (decomposed.items[0..composed_len]) |codepoint| {
        encoded_len = std.math.add(
            usize,
            encoded_len,
            std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable,
        ) catch return error.OutOfMemory;
    }
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    var offset: usize = 0;
    for (decomposed.items[0..composed_len]) |codepoint| {
        offset += std.unicode.utf8Encode(codepoint, encoded[offset..]) catch unreachable;
    }
    std.debug.assert(offset == encoded.len);
    return encoded;
}

fn appendCanonical(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u21),
    codepoint: u21,
) !void {
    try output.append(allocator, codepoint);
    const class = combiningClass(codepoint);
    if (class == 0) return;

    var index = output.items.len - 1;
    while (index != 0) {
        const previous_class = combiningClass(output.items[index - 1]);
        if (previous_class == 0 or previous_class <= class) break;
        std.mem.swap(u21, &output.items[index - 1], &output.items[index]);
        index -= 1;
    }
}

fn composeCanonical(codepoints: []u21) usize {
    if (codepoints.len == 0) return 0;

    var write_index: usize = 1;
    var starter_index: usize = 0;
    var starter = codepoints[0];
    var previous_class: u8 = combiningClass(starter);
    for (codepoints[1..]) |codepoint| {
        const class = combiningClass(codepoint);
        const combined = if (previous_class == 0 or previous_class < class)
            composePair(starter, codepoint)
        else
            null;
        if (combined) |value| {
            codepoints[starter_index] = value;
            starter = value;
        } else {
            if (class == 0) {
                starter_index = write_index;
                starter = codepoint;
            }
            previous_class = class;
            codepoints[write_index] = codepoint;
            write_index += 1;
        }
    }
    return write_index;
}

fn composePair(first: u21, second: u21) ?u21 {
    if (first >= hangul.l_base and first < hangul.l_base + hangul.l_count and
        second >= hangul.v_base and second < hangul.v_base + hangul.v_count)
    {
        const l_index = first - hangul.l_base;
        const v_index = second - hangul.v_base;
        return hangul.s_base + (l_index * hangul.v_count + v_index) * hangul.t_count;
    }
    if (first >= hangul.s_base and first < hangul.s_base + hangul.s_count and
        (first - hangul.s_base) % hangul.t_count == 0 and
        second > hangul.t_base and second < hangul.t_base + hangul.t_count)
    {
        return first + (second - hangul.t_base);
    }
    return composition(first, second);
}

fn inRanges(codepoint: u21, ranges: []const tables.Range) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = ranges[middle];
        if (codepoint < range.first) {
            high = middle;
        } else if (codepoint > range.last) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn decomposition(codepoint: u21) ?[]const u21 {
    var low: usize = 0;
    var high = tables.decompositions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = tables.decompositions[middle];
        if (codepoint < entry.codepoint) {
            high = middle;
        } else if (codepoint > entry.codepoint) {
            low = middle + 1;
        } else {
            const start: usize = @intCast(entry.offset);
            return tables.decomposition_scalars[start..][0..entry.len];
        }
    }
    return null;
}

fn combiningClass(codepoint: u21) u8 {
    var low: usize = 0;
    var high = tables.combining_classes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = tables.combining_classes[middle];
        if (codepoint < entry.codepoint) {
            high = middle;
        } else if (codepoint > entry.codepoint) {
            low = middle + 1;
        } else {
            return entry.class;
        }
    }
    return 0;
}

fn composition(first: u21, second: u21) ?u21 {
    var low: usize = 0;
    var high = tables.compositions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = tables.compositions[middle];
        if (first < entry.first or (first == entry.first and second < entry.second)) {
            high = middle;
        } else if (first > entry.first or (first == entry.first and second > entry.second)) {
            low = middle + 1;
        } else {
            return entry.composed;
        }
    }
    return null;
}

fn expectOrderedRanges(ranges: []const tables.Range) !void {
    for (ranges, 0..) |range, index| {
        try std.testing.expect(range.first <= range.last);
        if (index != 0) try std.testing.expect(ranges[index - 1].last < range.first);
    }
}

test "generated SASLprep Unicode 3.2 tables are ordered and connected" {
    try expectOrderedRanges(&tables.non_ascii_space_ranges);
    try expectOrderedRanges(&tables.mapped_to_nothing_ranges);
    try expectOrderedRanges(&tables.prohibited_ranges);
    try expectOrderedRanges(&tables.unassigned_ranges);
    try expectOrderedRanges(&tables.randal_ranges);
    try expectOrderedRanges(&tables.lcat_ranges);

    var scalar_end: usize = 0;
    for (tables.decompositions, 0..) |entry, index| {
        if (index != 0) try std.testing.expect(tables.decompositions[index - 1].codepoint < entry.codepoint);
        try std.testing.expectEqual(scalar_end, @as(usize, @intCast(entry.offset)));
        scalar_end += entry.len;
    }
    try std.testing.expectEqual(tables.decomposition_scalars.len, scalar_end);

    for (tables.combining_classes, 0..) |entry, index| {
        try std.testing.expect(entry.class != 0);
        if (index != 0) try std.testing.expect(tables.combining_classes[index - 1].codepoint < entry.codepoint);
    }
    for (tables.compositions, 0..) |entry, index| {
        if (index == 0) continue;
        const previous = tables.compositions[index - 1];
        try std.testing.expect(previous.first < entry.first or
            (previous.first == entry.first and previous.second < entry.second));
    }
}

test "generated SASLprep tables expose Unicode 3.2 reference points" {
    try std.testing.expect(inRanges(0x00a0, &tables.non_ascii_space_ranges));
    try std.testing.expect(inRanges(0x00ad, &tables.mapped_to_nothing_ranges));
    try std.testing.expect(inRanges(0x0000, &tables.prohibited_ranges));
    try std.testing.expect(inRanges(0x0221, &tables.unassigned_ranges));
    try std.testing.expect(inRanges(0x05d0, &tables.randal_ranges));
    try std.testing.expect(inRanges('A', &tables.lcat_ranges));
    try std.testing.expectEqualSlices(u21, &.{ 'f', 'i' }, decomposition(0xfb01).?);
    try std.testing.expectEqual(@as(u8, 230), combiningClass(0x0301));
    try std.testing.expectEqual(@as(?u21, 0x00e9), composition('e', 0x0301));
}

test "Unicode 3.2 NFKC handles compatibility canonical and Hangul forms" {
    const vectors = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "plain ASCII", .expected = "plain ASCII" },
        .{ .input = "\xc2\xaa\xef\xac\x81", .expected = "afi" }, // feminine ordinal + fi ligature
        .{ .input = "\xef\xbc\xba\xef\xbc\xb3\xef\xbc\xb1\xef\xbc\xac", .expected = "ZSQL" },
        .{ .input = "e\xcc\x81", .expected = "\xc3\xa9" },
        .{ .input = "\xe2\x84\xab", .expected = "\xc3\x85" },
        .{ .input = "\xe1\x84\x80\xe1\x85\xa1", .expected = "\xea\xb0\x80" },
        .{ .input = "\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8", .expected = "\xea\xb0\x81" },
        .{ .input = "\xea\xb0\x81", .expected = "\xea\xb0\x81" },
    };
    for (vectors) |vector| {
        const normalized = try normalizeNfkc(std.testing.allocator, vector.input);
        defer std.testing.allocator.free(normalized);
        try std.testing.expectEqualStrings(vector.expected, normalized);
    }
    try std.testing.expectError(error.InvalidUtf8, normalizeNfkc(std.testing.allocator, "\xff"));
}

test "Unicode 3.2 NFKC matches every changed single-codepoint result" {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (tables.nfkc_changed_ranges) |range| {
        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            var input_buf: [4]u8 = undefined;
            const input_len = std.unicode.utf8Encode(codepoint, &input_buf) catch unreachable;
            const normalized = try normalizeNfkc(std.testing.allocator, input_buf[0..input_len]);
            defer std.testing.allocator.free(normalized);

            var header: [8]u8 = undefined;
            std.mem.writeInt(u32, header[0..4], codepoint, .big);
            std.mem.writeInt(u32, header[4..8], @intCast(normalized.len), .big);
            hash.update(&header);
            hash.update(normalized);
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(tables.nfkc_changed_sha256, digest);
}

fn normalizeNfkcWithFailures(allocator: std.mem.Allocator) !void {
    const normalized = try normalizeNfkc(allocator, "\xef\xbc\xbae\xcc\x81\xe1\x84\x80\xe1\x85\xa1");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("Z\xc3\xa9\xea\xb0\x80", normalized);
}

test "Unicode 3.2 NFKC cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        normalizeNfkcWithFailures,
        .{},
    );
}
