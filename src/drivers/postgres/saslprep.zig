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

    var scalar_count: usize = 0;
    var counting_iterator = view.iterator();
    while (counting_iterator.nextCodepoint()) |codepoint| {
        const additional: usize = if (codepoint >= hangul.s_base and codepoint < hangul.s_base + hangul.s_count)
            if ((codepoint - hangul.s_base) % hangul.t_count == 0) 2 else 3
        else if (decomposition(codepoint)) |scalars|
            scalars.len
        else
            1;
        scalar_count = std.math.add(usize, scalar_count, additional) catch return error.OutOfMemory;
    }

    var decomposed: std.ArrayListUnmanaged(u21) = .empty;
    defer {
        secureFreeSlice(u21, allocator, decomposed.allocatedSlice());
    }
    try decomposed.ensureTotalCapacityPrecise(allocator, scalar_count);

    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= hangul.s_base and codepoint < hangul.s_base + hangul.s_count) {
            const index = codepoint - hangul.s_base;
            appendCanonical(&decomposed, hangul.l_base + index / hangul.n_count);
            appendCanonical(&decomposed, hangul.v_base + (index % hangul.n_count) / hangul.t_count);
            const trailing = index % hangul.t_count;
            if (trailing != 0) appendCanonical(&decomposed, hangul.t_base + trailing);
        } else if (decomposition(codepoint)) |scalars| {
            for (scalars) |scalar| appendCanonical(&decomposed, scalar);
        } else {
            appendCanonical(&decomposed, codepoint);
        }
    }
    std.debug.assert(decomposed.items.len == scalar_count);

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

fn secureFreeSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    memory: []T,
) void {
    if (memory.len == 0) return;
    const bytes = std.mem.sliceAsBytes(memory);
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(T), @returnAddress());
}

/// Apply PostgreSQL-compatible SASLprep to UTF-8 password bytes.
///
/// The returned bytes are allocator-owned and may contain a credential. The
/// caller must securely zero them before freeing. Invalid UTF-8 and prohibited
/// input are intentionally distinct so the authentication layer can implement
/// PostgreSQL's raw-password fallback without masking allocation failure.
pub fn prepare(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(input) catch return error.InvalidUtf8;
    var mapped: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        secureFreeSlice(u8, allocator, mapped.allocatedSlice());
    }
    try mapped.ensureTotalCapacityPrecise(allocator, input.len);

    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (inRanges(codepoint, &tables.non_ascii_space_ranges)) {
            mapped.appendAssumeCapacity(' ');
        } else if (!inRanges(codepoint, &tables.mapped_to_nothing_ranges)) {
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
            mapped.appendSliceAssumeCapacity(encoded[0..len]);
        }
    }
    if (mapped.items.len == 0) return error.Prohibited;

    const normalized = try normalizeNfkc(allocator, mapped.items);
    errdefer {
        secureFreeSlice(u8, allocator, normalized);
    }

    const normalized_view = std.unicode.Utf8View.init(normalized) catch unreachable;
    var normalized_iterator = normalized_view.iterator();
    var first: ?u21 = null;
    var last: u21 = undefined;
    var has_randal = false;
    var has_lcat = false;
    while (normalized_iterator.nextCodepoint()) |codepoint| {
        if (inRanges(codepoint, &tables.prohibited_ranges) or
            inRanges(codepoint, &tables.unassigned_ranges))
        {
            return error.Prohibited;
        }
        if (first == null) first = codepoint;
        last = codepoint;
        has_randal = has_randal or inRanges(codepoint, &tables.randal_ranges);
        has_lcat = has_lcat or inRanges(codepoint, &tables.lcat_ranges);
    }

    if (first == null) return error.Prohibited;
    if (has_randal and (has_lcat or
        !inRanges(first.?, &tables.randal_ranges) or
        !inRanges(last, &tables.randal_ranges)))
    {
        return error.Prohibited;
    }
    return normalized;
}

fn appendCanonical(output: *std.ArrayListUnmanaged(u21), codepoint: u21) void {
    output.appendAssumeCapacity(codepoint);
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

test "PostgreSQL SASLprep maps and normalizes RFC vectors" {
    const vectors = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "user", .expected = "user" },
        .{ .input = "USER", .expected = "USER" },
        .{ .input = "I\xc2\xadX", .expected = "IX" },
        .{ .input = "\xc2\xaa", .expected = "a" },
        .{ .input = "\xe2\x85\xa8", .expected = "IX" },
        .{ .input = "a\xc2\xa0b", .expected = "a b" },
        // U+200B appears in both mapping tables; PostgreSQL applies C.1.2 first.
        .{ .input = "a\xe2\x80\x8bb", .expected = "a b" },
        .{ .input = "\xd8\xa7\x31\xd8\xa8", .expected = "\xd8\xa7\x31\xd8\xa8" },
    };
    for (vectors) |vector| {
        const prepared = try prepare(std.testing.allocator, vector.input);
        defer {
            std.crypto.secureZero(u8, prepared);
            std.testing.allocator.free(prepared);
        }
        try std.testing.expectEqualStrings(vector.expected, prepared);
    }
}

test "PostgreSQL SASLprep rejects invalid prohibited unassigned and bidi input" {
    inline for (.{
        "",
        "\xc2\xad", // maps to empty
        "password\x07", // ASCII control
        "password\xc8\xa1", // U+0221 was unassigned in Unicode 3.2
        "\xd8\xa7A\xd8\xa8", // RandALCat mixed with LCat
        "\xd8\xa7\x31", // RandALCat string must end with RandALCat
        "\x31\xd8\xa7", // RandALCat string must begin with RandALCat
    }) |input| {
        try std.testing.expectError(error.Prohibited, prepare(std.testing.allocator, input));
    }
    try std.testing.expectError(error.InvalidUtf8, prepare(std.testing.allocator, "\xff"));
}

fn prepareWithFailures(allocator: std.mem.Allocator) !void {
    const prepared = try prepare(allocator, "S\xc2\xade\xcc\x81cret\xc2\xa0");
    defer {
        std.crypto.secureZero(u8, prepared);
        allocator.free(prepared);
    }
    try std.testing.expectEqualStrings("S\xc3\xa9cret ", prepared);
}

test "PostgreSQL SASLprep cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        prepareWithFailures,
        .{},
    );
}

const WipeCheckingAllocator = struct {
    child: std.mem.Allocator,
    free_count: usize = 0,
    all_freed_zero: bool = true,

    fn allocator(self: *WipeCheckingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *WipeCheckingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return false;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *WipeCheckingAllocator = @ptrCast(@alignCast(context));
        self.free_count += 1;
        for (memory) |byte| {
            if (byte != 0) {
                self.all_freed_zero = false;
                break;
            }
        }
        self.child.rawFree(memory, alignment, return_address);
    }
};

test "PostgreSQL SASLprep erases intermediates before allocator release" {
    var checking = WipeCheckingAllocator{ .child = std.testing.allocator };
    try std.testing.expectError(error.Prohibited, prepare(checking.allocator(), "Sensitive\x00Password"));
    try std.testing.expect(checking.free_count != 0);
    try std.testing.expect(checking.all_freed_zero);
}
