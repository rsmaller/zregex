const std = @import("std");
const cabi = @cImport(@cInclude("zregex.h"));

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);
    const my_pat = cabi.zregex_compile(args[1]);
    const my_match: *cabi.Match = cabi.zregex_match(my_pat, "abc");
    for (0..my_match.group_count) |i| {
        if (my_match.groups[i] != 0) {
            // std.debug.print("Grp {d}: ptr {*}\n", .{ i, my_match.groups[i] });
            std.debug.print("Grp {d}: {s}\n", .{ i, my_match.groups[i] });
        }
    }
    cabi.zregex_destroy_match(my_match);
    try stdout.flush();
}
