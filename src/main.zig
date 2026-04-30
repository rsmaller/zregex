const std = @import("std");
const zregex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() != .ok) {
            @panic("Leak detected!");
        }
    }
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const pattern: []const u8 = "(abc)\\n(|)(?=\\d{3,}+|)[^\\t-\\n][abc]-(|\\d{,5})-(\\d{,}|-\\d{15})";
    // const pattern: []const u8 = "a";
    // const pattern: []const u8 = "a{";
    // const pattern: []const u8 = "yes";
    const regexAST: zregex.RegexPattern = try zregex.compileRegex(allocator, pattern);
    try stdout.print("Pattern: {s}\n", .{pattern});
    try stdout.flush();

    try zregex.printRegexAST(stdout, regexAST);

    try stdout.flush(); // Don't forget to flush!

    try zregex.destroyRegexPattern(allocator, regexAST);
}