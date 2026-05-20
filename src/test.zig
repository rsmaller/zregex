const std = @import("std");
const zregex = @import("./root.zig");

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
        .leaf_atom = .{
            .leaf_atom = .{.generic = 'a'},
            .inverted = false,
        },
    };

    try std.testing.expect(testAST.equals(compiledPattern.ast.?) == true);
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