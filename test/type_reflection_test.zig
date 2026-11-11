const std = @import("std");
const zregex = @import("zregex");
const type_reflection = zregex.type_reflection;

test "indirection" {
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
