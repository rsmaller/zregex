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
            var item = zregex.compile(std.testing.allocator, data[0..len]) catch {
                return;
            }; // Compilation errors are OK, as long as they don't crash :)
            defer item.deinit();
        }
    };
    try std.testing.fuzz({}, t.fuzzFn, .{});
}