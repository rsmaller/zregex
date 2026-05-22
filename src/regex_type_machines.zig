const builtin = @import("builtin");

pub fn UnwrappedPointer(T: type) type {
    switch(@typeInfo(T)) {
        .pointer => |ptr| {
            return ptr.child;
        },
        else => {
            return T;
        }
    }
}

pub fn unwrapPointer(item: anytype) UnwrappedPointer(@TypeOf(item)) {
    switch(@typeInfo(@TypeOf(item))) {
        .pointer => {
            return item.*;
        },
        else => {
            return item;
        }
    }
}

pub fn assertFunctionExists(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError("Type " ++ @typeName(T) ++ " does not have the field " ++ name ++ ". Please make sure the field exists and is marked pub");
    }
    switch(@typeInfo(@TypeOf(@field(T, name)))) {
        .@"fn" => {
        },
        else => {
            @compileError("Type " ++ @typeName(T) ++ " has field " ++ name ++ " but it is not a function");
        }
    }
}

pub fn genericEqualityDispatch(a: anytype, b: anytype) bool {  // Compares two items of types that are either trivially comparable or comparable with an equals() method.
    const item1 = unwrapPointer(a); // Compare dereferenced values of pointer elements; does not perform address comparison.
    const item2 = unwrapPointer(b);
    const T = @TypeOf(item1);
    if (T != @TypeOf(item2)) { // Check type equality; error when comparing different types.
        @compileError("Cannot compare different types " ++ @typeName(T) ++ " and " ++ @typeName(@TypeOf(item2)));
    }
    switch (@typeInfo(T)) {
        .int, .float, .bool, .comptime_int, .comptime_float, .@"enum", .error_set => {
            return item1 == item2;
        },
        .@"struct", .@"union" => {
            assertFunctionExists(T, "equals");
            return item1.equals(item2);
        },
        else => {
            @compileError("Types " ++ @TypeOf(a) ++ " and " ++ @TypeOf(b) ++ " are not comparable");
        }
    }
}