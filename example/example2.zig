// An example program using zregex as a dynamic library + C header.
const std = @import("std");
const builtin = @import("builtin");
const cabi = @cImport(@cInclude("zregex.h"));

pub fn main(init: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){}; // Dynamic lib program only uses heap for simplicity.
    // const allocator = gpa.allocator();
    // defer {
    //     _ = gpa.deinit();
    // }
    // std.debug.print("Using allocator type {s}\n", .{@typeName(@TypeOf(gpa))});

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);
    if (args.len < 3) {
        @panic("Please provide a string and pattern!");
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    cabi.zregex_init_zig(stdout);
    const string_to_match = args[1]; //"john.doe@gmail.com";
    const compiled_pattern = cabi.zregex_compile(args[2]);
    defer cabi.zregex_destroy_pattern(compiled_pattern);
    try stdout.print("String: {s}, Pattern: {s}\n", .{ string_to_match, args[2] });
    try stdout.print("AST:\n", .{});
    cabi.zregex_print_ast(compiled_pattern, .{.show_match_width = true });
    try stdout.print("\nBytecode:\n", .{});
    cabi.zregex_print_bytecode(compiled_pattern);
    try stdout.print("\nMatch against string {s}:\n", .{string_to_match});
    const my_match = cabi.zregex_match(compiled_pattern, string_to_match);
    defer {
        if (my_match != null) {
            cabi.zregex_destroy_match(my_match);
        }
    }
    if (my_match) |match| {
        const match_str = cabi.zregex_name_index(match, "test");
        if (match_str) |str| {
            try stdout.print("Testing match name \"test\": \"{s}\"\n", .{str});
        } else {
            try stdout.print("Testing match name \"test\": <NULL>\n", .{});
        }
        const match_id_container = cabi.zregex_name_to_id(compiled_pattern, "test");
        if (match_id_container.present) {
            try stdout.print("Testing id fetch from name \"test\": {d}\n", .{match_id_container.value});
        } else {
            try stdout.print("Testing id fetch from name \"test\": NULL\n", .{});
        }
        for (0..match.*.group_count) |id| {
            try stdout.print("Group {d}", .{id});
            if (cabi.zregex_id_to_name(compiled_pattern, id)) |name| {
                try stdout.print(" <{s}>", .{name});
                cabi.zregex_destroy_name(name);
            }
            try stdout.print(": ", .{});
            const item = cabi.zregex_id_index(match, id);
            if (item) |non_null_item| {
                try stdout.print("\"{s}\"\n", .{non_null_item});
            } else {
                try stdout.print("<NULL>\n", .{});
            }
        }
    }
    try stdout.flush(); // Don't forget to flush!
}