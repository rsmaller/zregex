const std = @import("std");
const zregex = @import("zregex");
const type_reflection = zregex.type_reflection;

test "ptr_indirection" {
    const Ptr2Type = type_reflection.ChainedConstPointer(i32, 2);
    const PtrType = type_reflection.ChainedConstPointer(i32, 1);
    const NonPtrType = i32;
    std.debug.assert(type_reflection.UnwrappedPointer(PtrType) == type_reflection.UnwrappedPointer(NonPtrType));
    type_reflection.assertTypeEquality(type_reflection.UnwrappedPointer(PtrType), type_reflection.UnwrappedPointer(NonPtrType));
    const test_val = 5;
    const x: NonPtrType = test_val;
    const y: PtrType = &x;
    const z: Ptr2Type = &y;
    std.debug.assert(
        type_reflection.unwrapPointer(x) == test_val and 
        type_reflection.unwrapPointer(y) == test_val and
        type_reflection.unwrapPointer(z) == test_val and 
        type_reflection.unwrappedPointerIndirectionCount(@TypeOf(z)) == 2 
    );
}

test "opt_indirection" {
    const OptType = ?i32;
    const NonOptType = i32;
    try std.testing.expect(type_reflection.UnwrappedOptional(OptType) == type_reflection.UnwrappedOptional(NonOptType));
    const x: OptType = 5;
    const y: i32 = type_reflection.unwrapOptional(x);
    try std.testing.expect(y == x.?);
}

test "tags" {
    const MyEnum = enum {
        hello,
        goodbye,
        etc
    };
    try std.testing.expect(type_reflection.Tag(MyEnum) == MyEnum);
    const tag: type_reflection.Tag(MyEnum) = .etc;
    _ = tag;
}

test "equality" {
    const MyStruct = struct {
        x: i32,
        y: i32,
        pub fn equals(self: *const @This(), other: @This()) bool {
            return self.x == other.x and self.y == other.y;
        }
    };
    const one: MyStruct = .{.x = 5, .y = 6};
    const two: MyStruct = .{.x = 5, .y = 6};
    const three: MyStruct = .{.x = 1, .y = 6};
    try std.testing.expect(type_reflection.genericEqualityDispatch(one, two));
    try std.testing.expect(!type_reflection.genericEqualityDispatch(two, three));
}
