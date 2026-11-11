const std = @import("std");

/// Returns a pointer to T of indirection levels of indirection.
pub fn ChainedPointer(T: type, indirection: comptime_int) type {
    if (indirection <= 0) {
        return T;
    } 
    return ChainedPointer(*T, indirection - 1);
}

/// Returns a pointer to T of indirection levels of const indirection.
pub fn ChainedConstPointer(T: type, indirection: comptime_int) type {
    if (indirection <= 0) {
        return T;
    }
    return ChainedConstPointer(*const T, indirection - 1);
}

/// Gets the base type of a pointer type; removes all levels of pointer indirection from the pointed-to type.
pub fn UnwrappedPointer(T: type) type {
    switch(@typeInfo(T)) {
        .pointer => |ptr| {
            return UnwrappedPointer(ptr.child);
        },
        else => {
            return T;
        }
    }
}

pub fn unwrappedPointerIndirectionCount(T: type) comptime_int {
    switch(@typeInfo(T)) {
        .pointer => |ptr| {
            return unwrappedPointerIndirectionCount(ptr.child) + 1;
        },
        else => {
            return 0;
        }
    }
}

/// Gets the base value of a pointer value; dereferences all levels of pointer indirection from the pointed-to value.
pub fn unwrapPointer(item: anytype) UnwrappedPointer(@TypeOf(item)) {
    switch(@typeInfo(@TypeOf(item))) {
        .pointer => {
            return unwrapPointer(item.*);
        },
        else => {
            return item;
        }
    }
}

pub fn IntrospectedTypeClass(T: type) type {
    return switch(@typeInfo(T)) {
        .type => |payload| @TypeOf(payload),
        .void => |payload| @TypeOf(payload),
        .bool => |payload| @TypeOf(payload),
        .noreturn => |payload| @TypeOf(payload),
        .comptime_float => |payload| @TypeOf(payload),
        .comptime_int => |payload| @TypeOf(payload),
        .undefined => |payload| @TypeOf(payload),
        .null => |payload| @TypeOf(payload),
        .int => |payload| @TypeOf(payload),
        .float => |payload| @TypeOf(payload),
        .pointer => |payload| @TypeOf(payload),
        .array => |payload| @TypeOf(payload),
        .@"struct" => |payload| @TypeOf(payload),
        .optional => |payload| @TypeOf(payload),
        .error_union => |payload| @TypeOf(payload),
        .error_set => |payload| @TypeOf(payload),
        .@"enum" => |payload| @TypeOf(payload),
        .@"union" => |payload| @TypeOf(payload),
        .@"fn" => |payload| @TypeOf(payload),
        .@"opaque" => |payload| @TypeOf(payload),
        .frame => |payload| @TypeOf(payload),
        .@"anyframe" => |payload| @TypeOf(payload),
        .vector => |payload| @TypeOf(payload),
        .enum_literal => |payload| @TypeOf(payload),
        .spirv => |payload| @TypeOf(payload),
    };
}

pub fn declExists(comptime T: type, comptime name: []const u8, comptime decl_type: type) bool {
    if (!@hasDecl(T, name)) {
        return false;
    }
    const payload_type = IntrospectedTypeClass(@TypeOf(@field(T, name)));
    if (payload_type != decl_type) {
        return false;
    }
    return true;
}

pub fn assertDeclExists(comptime T: type, comptime name: []const u8, comptime decl_type: type) void { // Takes in a type from std.builtin.Type to assert a decl of a specific builtin type exists.
    if (!@hasDecl(T, name)) {
    @compileError("Type " ++ @typeName(T) ++ " does not have the field " ++ name ++ ". Please make sure the field exists and is marked pub");
}
    const payload_type = IntrospectedTypeClass(@TypeOf(@field(T, name)));
    if (payload_type != decl_type) {
        @compileError("Type " ++ @typeName(T) ++ " has field " ++ name ++ " but it is of type " ++ @typeName(payload_type) ++ " and not of type " ++ @typeName(decl_type));
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
            assertDeclExists(T, "equals", std.builtin.Type.Fn); // When comparing structs and unions, ensure both have the equals method and agree on equality.
            return item1.equals(item2) and item2.equals(item1);
        },
        else => {
            @compileError("Types " ++ @TypeOf(a) ++ " and " ++ @TypeOf(b) ++ " are not comparable");
        }
    }
}

pub fn assertTypeEquality(a: type, b: type) void {
    if (a != b) {
        @compileError("Expected type " ++ a ++ " but received type " ++ b);
    }
}
