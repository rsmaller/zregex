const std = @import("std");
const regex_type_reflection = @import("regex_type_reflection.zig");

pub fn print_binary(allocator: anytype, out_interface: anytype, binval: anytype) !void { // Accepts an integer and prints out its binary with the respective width.
    const T =   @TypeOf(binval);
    const info = @typeInfo(T);
    switch(info) {
        .int => {
            var items = try std.ArrayList(u1).initCapacity(allocator, 1);
            var next: T = binval;
            while (next != 0) {
                try items.append(allocator, @as(u1, @truncate(next & 1)));
                next >>= 1;
            }
            const datasize = @sizeOf(T) * 8;
            const leading_zeroes = datasize - items.items.len;
            for (0..leading_zeroes) |_| {
                try out_interface.print("0", .{});
            }
            if (items.items.len > 1) {
                std.debug.print("LENGTHHHH: {d}, datasize: {d}\n", .{items.items.len, datasize});
                var x = items.items.len-1;
                while (x > 0) {
                    try out_interface.print("{d}", .{items.items[x]});
                    x -= 1;
                }
                try out_interface.print("{d}", .{items.items[0]});
            } else {
                try out_interface.print("{d}", .{items.items[0]});
            }
            items.deinit(allocator);
        },
        else => {
            @compileError("Invalid type " ++ @typeName(T) ++ " passed to print_binary()");
        }
    }
}