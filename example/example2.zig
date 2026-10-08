// An example program using zregex as a dynamic library + C header.
const std = @import("std");
const cabi = @cImport(@cInclude("zregex.h"));

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    cabi.zregex_init_zig(stdout);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);
    const my_pat = cabi.zregex_compile(args[1]);
    if (args.len < 2) {
        @panic("Please provide a pattern!");
    }
    try stdout.print("Bytecode:\n", .{});
    cabi.zregex_print_bytecode(my_pat);
    try stdout.print("\nAST:\n", .{});
    cabi.zregex_print_ast(my_pat, .{.show_match_width = true});
    const my_match: *cabi.Match = cabi.zregex_match(my_pat, "abc");
    try stdout.print("\nMatches:\n", .{});
    for (0..my_match.group_count) |i| {
        if (my_match.groups[i] != 0) {
            try stdout.print("Grp {d}: {s}\n", .{ i, my_match.groups[i] });
        }
    }
    cabi.zregex_destroy_match(my_match);
    try stdout.flush();
}
