const std = @import("std");
const zregex = @import("zregex");
const test_options = @import("test_options");
const file_scan = @import("corpus_scan.zig");
const core_types = zregex.core_types;

test "abc" {
    var val = try zregex.compile(std.testing.allocator, "abc");
    defer val.deinit();
}

// test "fuzz_parser" { // Not necessary for now.
//     const t = struct {
//         var data: [test_options.fuzzlen]u8 = undefined;
//         fn fuzzFn(_: void, smith: *std.testing.Smith) !void {
//             const len = smith.slice(&data);
//             var item = zregex.compile(std.testing.allocator, data[0..len]) catch {
//                 return;
//             }; // Compilation errors are OK, as long as they don't crash :)
//             defer item.deinit();
//         }
//     };
//     const corpus = try file_scan.readCorpusFromFile(std.testing.io, std.testing.allocator, "./test/unit_test_patterns.txt");
//     defer corpus.deinit();
//     try std.testing.fuzz({}, t.fuzzFn, .{
//         .corpus = corpus.items,
//     });
// }


pub fn debugPrint(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print(fmt, args);
}

const FudgeIOStruct = struct {
    print: @TypeOf(debugPrint) = debugPrint,
};

test "fuzz_vm" {
    const t = struct {
        var data1: [test_options.fuzzlen]u8 = undefined;
        var data2: [test_options.fuzzlen]u8 = undefined;
        fn fuzzFn(_: void, smith: *std.testing.Smith) !void {
            const len1 = smith.slice(&data1);
            const len2 = smith.slice(&data2);
            var item = zregex.compile(std.testing.allocator, data1[0..len1]) catch  {
                // std.debug.print("Parse error encountered: {s}\n", .{@errorName(err)});
                return;
            }; // Compilation errors are OK, as long as they don't crash :)
            defer item.deinit();
            var match = item.match(std.testing.allocator, data2[0..len2]) catch |err| {
                switch(err) {
                    core_types.ParsingError.NonAsciiString => {
                        return;
                    },
                    else => {
                        std.debug.print("Pattern: {s}\n", .{data1});
                        std.debug.print("Match string: {s}\n", .{data2});
                        zregex.printBytecode(FudgeIOStruct{}, item);
                        std.debug.print("Match error encountered: {s}\n", .{@errorName(err)});
                        return err;
                    },
                }
            };
            defer { 
                if(match) |*mat| mat.deinit();
            }
        }
    };
    const corpus = try file_scan.readCorpusFromFile(std.testing.io, std.testing.allocator, "./test/unit_test_patterns.txt");
    defer corpus.deinit();
    try std.testing.fuzz({}, t.fuzzFn, .{
        .corpus = corpus.items,   
    });
}

