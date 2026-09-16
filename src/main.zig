const std = @import("std");
const zregex = @import("zregex");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const fixed_alloc_buffer_size: comptime_int = if (comptime builtin.mode == .Debug) 0 else 65535;
    var fixed_alloc_buffer: [fixed_alloc_buffer_size]u8 = undefined;
    var AllocatorBackend = if (comptime builtin.mode == .Debug) std.heap.DebugAllocator(.{}){} else std.heap.FixedBufferAllocator.init(&fixed_alloc_buffer); // Use heap in debug mode and stack array for allocation in optimized mode.
    const allocator = AllocatorBackend.allocator();
    std.debug.print("Using allocator type {s}\n", .{@typeName(@TypeOf(AllocatorBackend))});
    std.debug.print("Size of fixed alloc buffer: {d}\n", .{fixed_alloc_buffer.len});
    defer {
        if (comptime zregex.type_reflection.declExists(@TypeOf(allocator), "deinit", std.builtin.Type.Fn)) {
            _ = allocator.deinit();
        }
    }
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const string_to_match = "john.doe@gmail.com";
    // const pattern: []const u8 = "(?<=abc|ab)(?<name1>hiii)(|a|b|c|a|)\\ba \\B [\\q-\\z]^\\[\\*\\..(?>abc)\\n(|)(?=\\s{3,}+|)(?!\\s{3,}+|)(?<=az)[^\\t-\\n](?<!az)[abc]+?-(|\\d{,5})-(\\d{,}|-\\d{15})$";
    // const pattern: []const u8 = "[((((abcd)))))](?<=abc)(?<name1>hiii)(|a|b|c|a|)\\ba \\B [\\q-\\z]^\\[\\*\\..(?>abc)\\n(|)(?=\\s{3,}+|)(?!\\s{3,}+|)(?<=az)[^\\t-\\n](?<!az)[abc]+?-(|\\d{,5})-(\\d{,}|-\\d{15})$";
    // const pattern: []const u8 = "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$";
    // const pattern = "[abc]";
    const pattern = "(?>abc)";
    const compiledPattern = try zregex.compile(allocator, pattern);
    defer zregex.destroyPattern(allocator, compiledPattern) catch @panic("Could not free compiled pattern!");
    try stdout.print("Pattern: {s}\n", .{pattern});
    if (compiledPattern.ast) |ast| {
        try stdout.print("AST:\n", .{});
        try zregex.printAST(stdout, ast, .{ .show_match_width = true });
        try stdout.print("\nBytecode:\n", .{});
        try zregex.printBytecode(allocator, stdout, compiledPattern.bytecode);
    }
    try stdout.print("\nMatch against string {s}:\n", .{string_to_match});
    const myMatch = try compiledPattern.match(allocator, string_to_match);
    _ = myMatch;
    try stdout.flush(); // Don't forget to flush!
}
