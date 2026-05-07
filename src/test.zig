const std = @import("std");
const zregex = @import("./root.zig");

fn expectLiteralEqual(a: zregex.RegexLiteralType, b: zregex.RegexLiteralType) !void {
    switch (a.literal) {
        .generic => |chr| {
            try std.testing.expect(chr == b.literal.generic);
        },
        .range => |range| {
            try std.testing.expect(range.character_min == b.literal.range.character_min);
            try std.testing.expect(range.character_max == b.literal.range.character_max);
        },
        else => {},
    }
    try std.testing.expect(a.negated == b.negated);
}

fn expectASTEqual(a: zregex.RegexAST, b: zregex.RegexAST) !void {
    try std.testing.expect(@intFromEnum(a.*) == @intFromEnum(b.*));
    switch (a.*) {
        .literal => {
            try expectLiteralEqual(a.literal, b.literal);
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
            try std.testing.expect(@intFromEnum(grp.group_data) == @intFromEnum(b.group.group_data));
            switch(grp.group_data) {
                .capturing => |capt| {
                    try std.testing.expect(@intFromEnum(capt) == @intFromEnum(b.group.group_data.capturing));
                },
                .non_capturing => |non_capt| {
                    try std.testing.expect(@intFromEnum(non_capt) == @intFromEnum(b.group.group_data.non_capturing));
                }
            }
            try expectASTEqual(grp.expr, b.group.expr);
        },
        .repetition => |rep| {
            try std.testing.expect(rep.reps.min == b.repetition.reps.min);
            try std.testing.expect(@intFromEnum(rep.reps.max) == @intFromEnum(b.repetition.reps.max));
            switch(rep.reps.max) {
                .bounded => |bound| {
                    try std.testing.expect(bound == b.repetition.reps.max.bounded);
                },
                .unbounded => {},
            }
            try expectASTEqual(rep.child, b.repetition.child);
        },
        .class => |classItem| {
            try std.testing.expect(classItem.negated == b.class.negated);
            for (classItem.items, 0..) |_, i| {
                try expectLiteralEqual(classItem.items[i], b.class.items[i]);
            }
        },
        .epsilon => {}, // Epsilons contain no data and are always the same.
    }
}

test "a" {
    std.debug.print("Running test a\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a"; // Change this line to do another test.

    const compiledPattern = try zregex.compileRegex(allocator, pattern);
    defer zregex.destroyRegexPattern(allocator, compiledPattern) catch @panic("Could not free pattern!");

    const testAST: zregex.RegexAST = &.{
        .literal = .{
            .literal = .{.generic = 'a'},
            .negated = false,
        },
    };

    try expectASTEqual(testAST, compiledPattern);
}

test "unclosed_brace" {
    std.debug.print("Running test unclosed_brace\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a{"; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.EndOfString, zregex.compileRegex(allocator, pattern));
}

test "unopened_brace" {
    std.debug.print("Running test unopened_brace\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a}"; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.TokenNotFound, zregex.compileRegex(allocator, pattern));
}

test "unclosed_group" {
    std.debug.print("Running test unclosed_group\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a("; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.EndOfString, zregex.compileRegex(allocator, pattern));
}

test "unopened_group" {
    std.debug.print("Running test unopened_group\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a)"; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.TokenNotFound, zregex.compileRegex(allocator, pattern));
}

test "unclosed_class" {
    std.debug.print("Running test unclosed_class\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a["; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.EndOfString, zregex.compileRegex(allocator, pattern));
}

test "unopened_class" {
    std.debug.print("Running test unopened_class\n", .{});
    var dbg = std.heap.DebugAllocator(.{}){};
    defer {
        std.testing.expect(dbg.deinit() == .ok) catch @panic("Leak found!");
    }
    const allocator = dbg.allocator();

    const pattern = "a]"; // Change this line to change the test.

    try std.testing.expectError(zregex.RegexParsingError.TokenNotFound, zregex.compileRegex(allocator, pattern));
}