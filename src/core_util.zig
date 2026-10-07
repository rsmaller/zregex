const std = @import("std");
const type_reflection = @import("type_reflection.zig");

pub fn print_binary(out_interface: anytype, binval: anytype, options: struct { show_leading_zeroes: bool = false }) void { // Accepts an integer and prints out its binary with the respective width.
    const T = @TypeOf(binval);
    const info = @typeInfo(T);
    const bitlength = @sizeOf(T) * 8;
    var digit_arr: [bitlength]u1 = [1]u1{0} ** bitlength;
    switch (info) {
        .int => {
            var digit_arr_index: usize = @as(usize, bitlength) - 1;
            var next: T = binval;
            while (digit_arr_index > 0 and next > 0) {
                digit_arr[digit_arr_index] = @as(u1, @truncate(next & 1));
                digit_arr_index -= 1;
                next >>= 1;
            }
            digit_arr[0] = @as(u1, @truncate(next & 1));
            const filled_data: usize = bitlength - digit_arr_index;
            if (options.show_leading_zeroes) {
                for (0..digit_arr.len) |i| {
                    out_interface.print("{d}", .{digit_arr[i]}) catch {};
                }
            } else {
                for (digit_arr.len - filled_data + 1..digit_arr.len) |i| {
                    out_interface.print("{d}", .{digit_arr[i]}) catch {};
                }
            }
        },
        else => {
            @compileError("Invalid type " ++ @typeName(T) ++ " passed to print_binary()");
        },
    }
}
