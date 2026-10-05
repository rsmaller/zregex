const std = @import("std");
const zregex = @import("zregex");
const builtin = @import("builtin");
const debug_enabled = builtin.mode == .Debug;

pub fn main(init: std.process.Init) !void {
    const fixed_alloc_buffer_size: comptime_int = if (debug_enabled) 0 else 65535;
    var fixed_alloc_buffer: [fixed_alloc_buffer_size]u8 = undefined;
    var AllocatorBackend = if (debug_enabled) std.heap.DebugAllocator(.{}){} else std.heap.FixedBufferAllocator.init(&fixed_alloc_buffer); // Use heap in debug mode and stack array for allocation in optimized mode.
    const allocator = AllocatorBackend.allocator();
    defer {
        if (comptime zregex.type_reflection.declExists(@TypeOf(AllocatorBackend), "deinit", std.builtin.Type.Fn)) {
            _ = AllocatorBackend.deinit();
        }
    }
    std.debug.print("Using allocator type {s}\n", .{@typeName(@TypeOf(AllocatorBackend))});
    std.debug.print("Size of fixed alloc buffer: {d}\n", .{fixed_alloc_buffer.len});
    
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);
    if (args.len < 3) {
        @panic("Please provide a string and pattern!");
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const string_to_match = args[1]; //"john.doe@gmail.com";
    const pattern = args[2];
    var compiled_pattern = try zregex.compile(allocator, pattern);
    defer compiled_pattern.deinit(allocator);
    try stdout.print("String: {s}, Pattern: {s}\n", .{string_to_match, pattern});
    if (compiled_pattern.ast) |ast| {
        try stdout.print("AST:\n", .{});
        try zregex.printAST(stdout, ast, .{ .show_match_width = true });
        try stdout.print("\nBytecode:\n", .{});
        try zregex.printBytecode(allocator, stdout, compiled_pattern.bytecode);
    }
    try stdout.print("\nMatch against string {s}:\n", .{string_to_match});
    const my_match = try compiled_pattern.match(allocator, string_to_match);
    defer {
        if (my_match) |matched| {
            matched.deinit(allocator);
        }
    }
    if (my_match) |match| {
        for (match.groups, 0..) |item, id| {
            try stdout.print("Group {d} ", .{id});
            if (compiled_pattern.getNameById(id)) |name| {
                try stdout.print("<{s}>", .{name});
            }
            try stdout.print(": ", .{});
            if (item) |non_null_item| {
                try stdout.print("\"{s}\"\n", .{ non_null_item });
            } else {
                try stdout.print("<NULL>\n", .{ });
            }
        }
    }
    try stdout.flush(); // Don't forget to flush!
}
