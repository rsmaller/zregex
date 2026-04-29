const std = @import("std");
const zregex = @import("./root.zig");

fn expectASTEqual(a: *const zregex.RegexPattern, b: *const zregex.RegexPattern) !void {
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
            try std.testing.expect(alt.len == b.alternation.len);
            for (alt, 0..) |_, i| {
                try expectASTEqual(alt[i], b.alternation[i]);
            }
        },
        .concatenation => |concat| {
            try std.testing.expect(concat.len == b.concatenation.len);
            for (concat, 0..) |_, i| {
                try expectASTEqual(concat[i], b.concatenation[i]);
            }
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

    var testAST = &zregex.RegexPattern{
        .alternation = try allocator.alloc(*zregex.RegexPattern, 1),
    };
    defer allocator.free(testAST.alternation);

    testAST.alternation[0] = try allocator.create(zregex.RegexPattern);
    defer allocator.destroy(testAST.alternation[0]);

    testAST.alternation[0].* = .{
        .concatenation = try allocator.alloc(*zregex.RegexPattern, 1),
    };
    defer allocator.free(testAST.alternation[0].concatenation);

    testAST.alternation[0].concatenation[0] = try allocator.create(zregex.RegexPattern);
    defer allocator.destroy(testAST.alternation[0].concatenation[0]);

    testAST.alternation[0].concatenation[0].* = .{
        .literal = .{
            .character = 'a',
            .metacharacter = false,
        }
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