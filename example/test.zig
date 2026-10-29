const std = @import("std");
const zregex = @import("zregex");

test "abc" {
    var val  = try zregex.compile(std.testing.allocator, "abc");
    defer val.deinit();
}

test "fuzzy" {
    const t = struct {
        var data: [32]u8 = undefined;
        fn fuzzFn(_: void, smith: *std.testing.Smith) !void {
            const len = smith.slice(&data);
            var item = try zregex.compile(std.testing.allocator, data[0..len]);
            defer item.deinit();
        }
    };
    try std.testing.fuzz({}, t.fuzzFn, .{});
}