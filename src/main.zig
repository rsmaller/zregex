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

    // const pattern: []const u8 = "(?<=abc|ab)(?<name1>hiii)(|a|b|c|a|)\\ba \\B [\\q-\\z]^\\[\\*\\..(?>abc)\\n(|)(?=\\s{3,}+|)(?!\\s{3,}+|)(?<=az)[^\\t-\\n](?<!az)[abc]+?-(|\\d{,5})-(\\d{,}|-\\d{15})$";
    const pattern: []const u8 = "(?<=abc)(?<name1>hiii)(|a|b|c|a|)\\ba \\B [\\q-\\z]^\\[\\*\\..(?>abc)\\n(|)(?=\\s{3,}+|)(?!\\s{3,}+|)(?<=az)[^\\t-\\n](?<!az)[abc]+?-(|\\d{,5})-(\\d{,}|-\\d{15})$";
    // const pattern: []const u8 = "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$";
    // const pattern: []const u8 = "a{";
    // const pattern: []const u8 = "yes";
    const regexAST: zregex.RegexPattern = try zregex.compileRegex(allocator, pattern);
    try stdout.print("Pattern: {s}\n", .{pattern});
    try stdout.flush();

    try zregex.printRegexAST(stdout, regexAST, true);

    try stdout.flush(); // Don't forget to flush!

    try zregex.destroyRegexPattern(allocator, regexAST);
}