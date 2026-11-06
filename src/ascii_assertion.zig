const std = @import("std");
const core_types = @import("core_types.zig");

pub fn assert_ascii_string(string: []const u8) !void {
    for (string) |char| {
        if (!std.ascii.isPrint(char)) {
            return core_types.ParsingError.NonAsciiString;
        }
    }
}
