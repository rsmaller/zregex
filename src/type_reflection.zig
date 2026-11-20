const std = @import("std");

// -------------------- Pointer and Optional Indirection Functions --------------------

/// Returns a pointer type to T of "indirection" levels of indirection.
pub fn ChainedPointer(T: type, indirection: comptime_int) type {
    if (indirection <= 0) {
        return T;
    } 
    return ChainedPointer(*T, indirection - 1);
}

/// Returns a pointer type to T of "indirection" levels of const indirection.
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

/// Counts the number of pointer indirections a pointer type contains.
pub fn unwrappedPointerIndirectionCount(comptime T: type) comptime_int {
    switch(@typeInfo(T)) {
        .pointer => |ptr| {
            return unwrappedPointerIndirectionCount(ptr.child) + 1;
        },
        else => {
            return 0;
        }
    }
}

/// Will peel back an optional type's optional if present.
pub fn UnwrappedOptional(T: type) type {
    switch (@typeInfo(T)) {
        .optional => |opt| {
            return opt.child;
        },
        else => {
            return T;
        }
    }
}

/// Will peel back an optional value's optional if present.
pub fn unwrapOptional(item: anytype) UnwrappedOptional(@TypeOf(item)) {
    switch(@typeInfo(@TypeOf(item))) {
        .optional => {
            return item.?;
        },
        else => {
            return item;
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

// -------------------- Tag-Fetching Functions --------------------

/// Returns a tag-interfacing type for any given type that has tags.
pub fn Tag(comptime T: type) type {
    if(!@hasField(IntrospectedTypeInfoPayloadType(T), "tag_type")) {
        @compileError("Tagging can only be done for types that implement tag_type, type " ++ @typeName(T) ++ " is not a permitted type.");
    }
    switch(@typeInfo(T)) {
        .@"enum" => {
            return T;
        },
        .@"union" => {
            return unwrapOptional(IntrospectedTypeInfoPayload(T).tag_type);
        },
        else => {
            return void;
        },
    }
}

// -------------------- Declaration- and Payload-Fetching Functions --------------------

/// Grabs a union's active tag and returns the payload for it.
pub fn ActiveUnionPayload(comptime item: anytype) @TypeOf(@field(item, @tagName(item))) {
    return @field(item, @tagName(item));
}

/// Grabs kind of a type by fetching the type info union's payload.
pub fn IntrospectedTypeInfoPayload(T: type) @TypeOf(ActiveUnionPayload(@typeInfo(T))) {
    return ActiveUnionPayload(@typeInfo(T));
}

/// Grabs kind of a type by fetching the type of the type info union's payload.
pub fn IntrospectedTypeInfoPayloadType(T: type) type {
    return @TypeOf(IntrospectedTypeInfoPayload(T));
}

/// Takes in an array of types from std.builtin.Type and returns a boolean representing whether
/// a field has been made on an arbitrary type.
pub fn fieldExists(comptime T: type, comptime name: []const u8, comptime field_types: []const type) bool {
    if (!@hasField(T, name)) {
        return false;
    }
    const payload_type = IntrospectedTypeInfoPayloadType(@TypeOf(@field(T, name)));
    inline for (comptime field_types) |type_item| {
        if (comptime payload_type == type_item) {
            return true;
        }
    }
    return false;
}

/// Takes in an array of types from std.builtin.Type to assert a field has been made on an arbitrary type.
pub fn assertFieldExists(comptime T: type, comptime name: []const u8, comptime field_types: []const type) void {
    if (!@hasField(T, name)) {
        @compileError("Type " ++ @typeName(T) ++ " does not have field " ++ name ++ ". Please make sure the field exists and is marked pub");
    }
    const payload_type = IntrospectedTypeInfoPayloadType(@TypeOf(@field(T, name)));
    inline for (comptime field_types) |type_item| {
        if (comptime payload_type == type_item) {
            return;
        }
    }
    @compileError("Type " ++ @typeName(T) ++ " has field " ++ name ++ " but it is of type " ++ @typeName(payload_type) ++ " and not of the given types");
}

/// Takes in an array of types from std.builtin.Type and returns a boolean representing whether
/// a decl has been made on an arbitrary type.
pub fn declExists(comptime T: type, comptime name: []const u8, comptime decl_types: []const type) bool {
    if (!@hasDecl(T, name)) {
        return false;
    }
    const payload_type = IntrospectedTypeInfoPayloadType(@TypeOf(@field(T, name)));
    inline for (comptime decl_types) |type_item| {
        if (comptime payload_type == type_item) {
            return true;
        }
    }
    return false;
}

/// Takes in an array of types from std.builtin.Type to assert a decl has been made on an arbitrary type.
pub fn assertDeclExists(comptime T: type, comptime name: []const u8, comptime decl_types: []const type) void { // Takes in a type from std.builtin.Type to assert a decl of a specific builtin type exists.
    if (!@hasDecl(T, name)) {
        @compileError("Type " ++ @typeName(T) ++ " does not have decl " ++ name ++ ". Please make sure the decl exists and is marked pub");
    }
    const payload_type = IntrospectedTypeInfoPayloadType(@TypeOf(@field(T, name)));
    inline for (comptime decl_types) |type_item| {
        if (comptime payload_type == type_item) {
            return;
        }
    }
    @compileError("Type " ++ @typeName(T) ++ " has decl " ++ name ++ " but it is of type " ++ @typeName(payload_type) ++ " and not of the given types");
}

// -------------------- General Type-Generic Functions --------------------

/// Compares two items with variable pointer indirections of types that are either trivially
/// comparable or comparable with an equals() method.
pub fn genericEqualityDispatch(a: anytype, b: anytype) bool {
    const item1 = unwrapPointer(a); // Compare dereferenced values of pointer elements; does not perform address comparison.
    const item2 = unwrapPointer(b);
    const T = @TypeOf(item1);
    if (T != @TypeOf(item2)) { // Check type equality; error when comparing different types.
        @compileError("Cannot compare different types " ++ @typeName(T) ++ " and " ++ @typeName(@TypeOf(item2)));
    }
    switch (comptime @typeInfo(T)) {
        .int, .float, .bool, .comptime_int, .comptime_float, .@"enum", .error_set => {
            return item1 == item2;
        },
        .@"struct", .@"union" => {
            assertDeclExists(T, "equals", (&[_]type{std.builtin.Type.Fn})[0..]); // When comparing structs and unions, ensure both have the equals method and agree on equality.
            return item1.equals(item2) and item2.equals(item1);
        },
        else => {
            @compileError("Types " ++ @TypeOf(a) ++ " and " ++ @TypeOf(b) ++ " are not comparable");
        }
    }
}

/// Trivial type checking assertion.
pub fn assertTypeEquality(comptime a: type, comptime b: type) void {
    if (a == b) return;
    @compileError("Expected type " ++ @typeName(a) ++ " but found " ++ @typeName(b));
}