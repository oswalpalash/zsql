const std = @import("std");
const tables = @import("saslprep_tables.zig");

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
