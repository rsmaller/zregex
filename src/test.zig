const std = @import("std");
const zregex = @import("./root.zig");

fn expectASTEqual(a: zregex.RegexPattern, b: zregex.RegexPattern) !void {
    try std.testing.expect(@intFromEnum(a.*) == @intFromEnum(b.*));
    switch (a.*) {
        .literal => |lit| {
            try std.testing.expect(lit.metacharacter == b.literal.metacharacter);
            try std.testing.expect(lit.character == b.literal.character);
        },
        .range => |range| {
            try std.testing.expect(range.character_min == b.range.character_min);
            try std.testing.expect(range.character_max == b.range.character_max);
        },
        .alternation => |alt| {
            try std.testing.expect(alt.parts.len == b.alternation.parts.len);
            for (alt.parts, 0..) |_, i| {
                try expectASTEqual(alt.parts[i], b.alternation.parts[i]);
            }
        },
        .concatenation => |concat| {
            try std.testing.expect(concat.parts.len == b.concatenation.parts.len);
            for (concat.parts, 0..) |_, i| {
                try expectASTEqual(concat.parts[i], b.concatenation.parts[i]);
            }
        },
        .group => |grp| {
            try std.testing.expect(grp.id == b.group.id);
            try std.testing.expect(grp.capturing == b.group.capturing);
            try std.testing.expect(grp.group_type == b.group.group_type);
            try expectASTEqual(grp.expr, b.group.expr);
        },
        .repetition => |rep| {
            try std.testing.expect(rep.reps_min == b.repetition.reps_min);
            try std.testing.expect(rep.reps_max == b.repetition.reps_max);
            try expectASTEqual(rep.child, b.repetition.child);
        },
        .class => |classItem| {
            try std.testing.expect(classItem.negated == b.class.negated);
            for (classItem.items, 0..) |_, i| {
                try expectASTEqual(classItem.items[i], b.class.items[i]);
            }
        },
        .epsilon => {}, // Epsilons contain no data and are always the same.
    }
}

test "a" {
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a"; // Change this line to do another test.

    const compiledPattern = try zregex.compileRegex(allocator, pattern);
    defer zregex.destroyRegexPattern(allocator, compiledPattern) catch @panic("Could not free pattern!");

    const testAST: zregex.RegexPattern = &.{
        .literal = .{.character = 'a', .metacharacter = false},
    };

    try expectASTEqual(testAST, compiledPattern);
}

test "error" {
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a{"; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.EndOfString, zregex.compileRegex(allocator, pattern));
}