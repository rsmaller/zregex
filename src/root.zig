//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const RegexAST = *const RegexASTInternal;

pub const RegexPattern = struct{
    ast: ?RegexAST,
    // instructions: RegexBytecode,
};

// For use when bytecode gen is introduced.
// const RegexBytecode = []RegexInstruction;

const RegexRepeaterType = enum {
    greedy,
    lazy,
    possessive,
};

const RegexBoundType = union(enum) {
    bounded: usize,
    unbounded: void,
};

const RegexRepetitionRangeType = struct {
    min: usize,
    max: RegexBoundType,
};

const RegexGroupType = struct {
    type: union(enum) {
        capturing: union(enum) {
            generic,
        },
        non_capturing: union(enum) {
            generic,
            atomic,
            lookahead,
            lookbehind,
        }
    },
    negated: bool,
    pub fn equals(self: *const RegexGroupType, b: RegexGroupType) bool {
        if (@intFromEnum(self.type) != @intFromEnum(b.type)) {
            return false;
        }
        if (self.negated != b.negated) {
            return false;
        }
        switch(self.type) {
            .capturing => |capt| {
                if (@intFromEnum(capt) != @intFromEnum(b.type.capturing)) {
                    return false;
                }
            },
            .non_capturing => |non_capt| {
                if (@intFromEnum(non_capt) != @intFromEnum(b.type.non_capturing)) {
                    return false;
                }
            }
        }
        return true;
    }
};

pub const RegexLeafAtomType = struct {
    leaf_atom: union(enum) {
        generic: u8,
        digit: void,
        word: void,
        word_boundary: void,
        whitespace: void,
        start_anchor: void,
        end_anchor: void,
        any: void,
        range: struct { // For ranges within char classes. Cannot contain metacharacters.
            character_min: u8,
            character_max: u8,
        },
    },
    inverted: bool,
    fn equals(self: *const RegexLeafAtomType, other: RegexLeafAtomType) bool {
        switch (self.leaf_atom) {
            .generic => |chr| {
                if (chr != other.leaf_atom.generic) {
                    return false;
                }
            },
            .range => |range| {
                if (range.character_min != other.leaf_atom.range.character_min) {
                    return false;
                }
                if (range.character_max != other.leaf_atom.range.character_max) {
                    return false;
                }
            },
            else => {},
        }
        return self.inverted == other.inverted;
    }
};

const RegexASTInternal = union(enum) { // Tagged union for node type.
    leaf_atom: RegexLeafAtomType,
    concatenation: struct {
        parts: []*RegexASTInternal, // Operation chaining two characters together.
    },
    alternation: struct{
        parts: []*RegexASTInternal,
    }, // Same as concatenation but semantically different and in a higher order function.
    group: struct {
        expr: *RegexASTInternal,
        id: ?usize,
        name: ?[]const u8, // Not nested in RegexGroupType for simplicity.
        group_data: RegexGroupType,
    },
    repetition: struct { // Parent node to another node constructed by a quantifier.
        child: *RegexASTInternal,
        reps: RegexRepetitionRangeType,
        rep_type: RegexRepeaterType,
    },
    class: struct { // Character class.
        items: []RegexLeafAtomType,
        negated: bool,
    },
    epsilon: void, // Generic empty node.
    pub fn equals(self: *const RegexASTInternal, b: *const RegexASTInternal) bool { // ASTs should be stored as pointers; expects comparison between pointer types.
        if (@intFromEnum(self.*) != @intFromEnum(b.*)) {
            return false;
        }
        switch (self.*) {
            .leaf_atom => {
                if (!self.leaf_atom.equals(b.leaf_atom)) {
                    return false;
                }
            },
            .alternation => |alt| {
                if (alt.parts.len != b.alternation.parts.len) {
                    return false;
                }
                for (alt.parts, 0..) |_, i| {
                    if (!alt.parts[i].equals(b.alternation.parts[i])) {
                        return false;
                    }
                }
            },
            .concatenation => |concat| {
                if (concat.parts.len != b.concatenation.parts.len) {
                    return false;
                }
                for (concat.parts, 0..) |_, i| {
                    if (!concat.parts[i].equals(b.concatenation.parts[i])) {
                        return false;
                    }
                }
            },
            .group => |grp| {
                if (grp.id != b.group.id) {
                    return false;
                }
                if (!grp.expr.equals(b.group.expr)) {
                    return false;
                }
                if (!grp.group_data.equals(b.group.group_data)) {
                    return false;
                }
            },
            .repetition => |rep| {
                if (rep.reps.min != b.repetition.reps.min) {
                    return false;
                }
                if (@intFromEnum(rep.reps.max) != @intFromEnum(b.repetition.reps.max)) {
                    return false;
                }
                switch(rep.reps.max) {
                    .bounded => |bound| {
                        if (bound != b.repetition.reps.max.bounded) {
                            return false;
                        }
                    },
                    .unbounded => {},
                }
                if (!rep.child.equals(b.repetition.child)) {
                    return false;
                }
            },
            .class => |classItem| {
                if (classItem.negated != b.class.negated) {
                    return false;
                }
                for (classItem.items, 0..) |_, i| {
                    if (!classItem.items[i].equals(b.class.items[i])) {
                        return false;
                    }
                }
            },
            .epsilon => {}, // Epsilons contain no data and are always the same.
        }
        return true;
    }
};

pub const RegexParsingError = error{
    TokenNotFound,
    EndOfString,
    InvalidRange,
    VariableLookbehindRange,
};

var EPSILON_UNIT: RegexASTInternal = .epsilon; // Generic epsilon copy used everywhere; contains no data.

pub fn compileRegex(allocator: anytype, str_to_parse: []const u8) anyerror!RegexPattern {
    var i: usize = 0;
    var j: usize = 1; // ID 0 is reserved for whole match.
    const ast = if (str_to_parse.len > 0) (try parseRegexExpr(allocator, str_to_parse, &i)) else &EPSILON_UNIT;
    errdefer {
        destroyRegexAST(allocator, ast) catch @panic("Failed to free AST after error!");
    }
    if (i != str_to_parse.len) {
        return RegexParsingError.TokenNotFound;
    }
    try setGroupIDs(ast, &j);
    try trimAST(ast, allocator);
    return RegexPattern{.ast = ast};
}

fn setGroupIDs(ast: *RegexASTInternal, id: *usize) !void {
    switch(ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            switch(grp.group_data.type) {
                .capturing => {
                    ast.group.id = id.*;
                    id.* += 1;
                },
                .non_capturing => {
                    ast.group.id = null;
                }
            }
            try setGroupIDs(grp.expr, id);
        }, // outside of group, just recurse.
        .alternation => |alt| {
            for (alt.parts) |item| {
                try setGroupIDs(item, id);
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try setGroupIDs(item, id);
            }
        },
        .repetition => |rep| {
            try setGroupIDs(rep.child, id);
        },
        .class => {
            return;
        },
        else => {
            return;
        },
    }
}

fn isEqualBound(a: RegexRepetitionRangeType, b: RegexRepetitionRangeType) bool {
    if (@intFromEnum(a.max) != @intFromEnum(b.max)) return false;
    switch(a.max) {
        .bounded => {
            return (a.min == b.min) and (a.max.bounded == b.max.bounded);
        },
        .unbounded => {
            return a.min == b.min;
        },
    }
}

fn addBound(a: RegexRepetitionRangeType, b: RegexRepetitionRangeType) RegexRepetitionRangeType {
    var result = a;
    result.min += b.min;
    switch(a.max) {
        .unbounded => {
            return result;
        },
        else => {
            switch(b.max) {
                .unbounded => {
                    result.max = .unbounded;
                    return result;
                },
                .bounded => {
                    result.max.bounded += b.max.bounded;
                    return result;
                }
            }
        }
    }
}

fn timesBound(a: RegexRepetitionRangeType, b: RegexRepetitionRangeType) RegexRepetitionRangeType {
    var result = a;
    result.min *= b.min;
    switch(a.max) {
        .unbounded => {
            return result;
        },
        else => {
            switch(b.max) {
                .unbounded => {
                    result.max = .unbounded;
                    return result;
                },
                else => {
                    result.max.bounded *= b.max.bounded;
                    return result;
                }
            }
        }
    }
}

fn alternationBound(a: RegexRepetitionRangeType, b: RegexRepetitionRangeType) RegexRepetitionRangeType {
    var result = a;
    if (a.min > b.min) {
        result.min = b.min;
    }
    switch(a.max) {
        .unbounded => {
            return result;
        },
        else => {
            switch(b.max) {
                .unbounded => {
                    result.max = .unbounded;
                    return result;
                },
                else => {
                    if (a.max.bounded < b.max.bounded) {
                        result.max.bounded = b.max.bounded;
                    }
                    return result;
                }
            }
        }
    }
}

fn matchRequirementRange(ast: *const RegexASTInternal) RegexRepetitionRangeType { // This function checks the width of characters that may be represented by an AST; it does NOT check how many characters the resulting bytecode will consume.
    var result = RegexRepetitionRangeType{.min = 0, .max = .{.bounded = 0}};
    switch(ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            return matchRequirementRange(grp.expr);
        }, // outside of group, just recurse.
        .alternation => |alt| {
            result = matchRequirementRange(alt.parts[0]);
            for (alt.parts[1..]) |item| {
                result = alternationBound(result, matchRequirementRange(item));
            }
            return result;
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                result = addBound(result, matchRequirementRange(item));
            }
            return result;
        },
        .repetition => |rep| {
            return timesBound(rep.reps, matchRequirementRange(rep.child));
        },
        .class => {
            return RegexRepetitionRangeType{.min = 1, .max = .{.bounded = 1}};
        },
        .leaf_atom => |leaf| {
            switch(leaf.leaf_atom) {
                .word_boundary, .start_anchor, .end_anchor => {
                    return RegexRepetitionRangeType{.min = 0, .max = .{.bounded = 0}};
                },
                else => {
                    return RegexRepetitionRangeType{.min = 1, .max = .{.bounded = 1}};
                }
            }
        },
        .epsilon => {
            return RegexRepetitionRangeType{.min = 0, .max = .{.bounded = 0}};
        }
    }
}

// Makes a copy of an array without duplicates, in-order. Assumes that pointer elements in array are heap-allocated and single-pointers.
// Types must be trivially comparable or structs/unions that implement an equals() method for duplicate checking.
fn removeDuplicates(allocator: anytype, arr: anytype) !@TypeOf(arr) {
    const T = @TypeOf(arr[0]);
    var list = try std.ArrayList(T).initCapacity(allocator, 1);
    var freed = try allocator.alloc(bool, arr.len);
    defer allocator.free(freed);
    @memset(freed, false);
    for (arr, 0..) |item, i| {
        if (freed[i]) continue;
        try list.append(allocator, item);
        for (i+1..arr.len) |j| {
            switch(@typeInfo(T)) {
                .pointer => |ptr| {
                    switch(@typeInfo(ptr.child)) {
                        .@"struct", .@"union" => {
                            if(arr[i].equals(arr[j])) {
                                freed[j] = true;
                                if (ptr.child == RegexASTInternal) {
                                    try destroyRegexAST(allocator, arr[j]);
                                } else {
                                    try allocator.free(arr[j]);
                                }
                            }
                        },
                        .int, .float, .bool, .comptime_int, .comptime_float, .@"enum", .error_set => {
                            if (arr[i].* == arr[j].*) {
                                freed[j] = true;
                                try allocator.free(arr[j]);
                            }
                        },
                        else => {
                            @compileError("Non-comparable type passed to remove duplicates function: " ++ @typeName(T));
                        }
                    }
                },
                .@"struct", .@"union" => {
                    if(arr[i].equals(arr[j])) {
                        freed[j] = true;
                    }
                },
                .int, .float, .bool, .comptime_int, .comptime_float, .@"enum", .error_set => {
                    if (arr[i] == arr[j]) {
                        freed[j] = true;
                    }
                },
                else => { // Unions should only be handled when they are RegexAST unions.
                    @compileError("Non-comparable type passed to remove duplicates function: " ++ @typeName(T));
                }
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn trimAST(ast: *RegexASTInternal, allocator: anytype) !void {
    switch(ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            if (grp.group_data.negated) {
                switch(grp.group_data.type) {
                    .capturing => {
                        return RegexParsingError.TokenNotFound;
                    },
                    .non_capturing => |non_capt| {
                        switch(non_capt) {
                            .atomic, .generic => {
                                return RegexParsingError.TokenNotFound;
                            },
                            else => {},
                        }
                    }
                }
            }
            switch(grp.group_data.type) {
                .capturing => {},
                .non_capturing => |non_capt| {
                    switch(non_capt) {
                        .lookbehind => {
                            const len = matchRequirementRange(grp.expr);
                            switch(len.max) {
                                .unbounded => {
                                    return RegexParsingError.VariableLookbehindRange;
                                },
                                .bounded => {
                                    if (len.max.bounded != len.min) {
                                        return RegexParsingError.VariableLookbehindRange;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            try trimAST(grp.expr, allocator);
        }, // outside of group, just recurse.
        .alternation => {
            const old_alt_parts = ast.alternation.parts;
            ast.alternation.parts = try removeDuplicates(allocator, ast.alternation.parts);
            allocator.free(old_alt_parts);
            for (ast.alternation.parts) |item| {
                try trimAST(item, allocator); // recurse after trimming.
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try trimAST(item, allocator);
            }
        },
        .repetition => |rep| {
            try trimAST(rep.child, allocator);
        },
        .class => {
            const old_cls_items = ast.class.items;
            ast.class.items = try removeDuplicates(allocator, ast.class.items);
            allocator.free(old_cls_items);
        },
        else => {
            return;
        },
    }
}

fn parseRegexExpr(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    var result = try allocator.create(RegexASTInternal);
    var result_list = try std.ArrayList(*RegexASTInternal).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            destroyRegexAST(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString; // Error out after deferring.
    if (str_to_parse[i.*] == '|' or str_to_parse[i.*] == ')') { // Handle epsilon as the first alternation argument.
        try result_list.append(allocator, &EPSILON_UNIT);
    } else { // If not an epsilon, just parse the first alternation as a regular term.
        try result_list.append(allocator, try parseRegexTerm(allocator, str_to_parse, i));
    }
    while (i.* < str_to_parse.len and str_to_parse[i.*] == '|') { // Parse through pipes as arguments.
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            break;
        }
        if (str_to_parse[i.*] == ')') { // Handle epsilon as the last alternation argument.
            try result_list.append(allocator, &EPSILON_UNIT);
            break;
        }
        try result_list.append(allocator, try parseRegexTerm(allocator, str_to_parse, i)); // Handle generic terms in alternation not caught by edge cases.
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{.alternation = .{.parts = list_slice}}; // Start parsing alternations first, and assume 2 alternations minimum.
    if (list_slice.len == 1) {
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

fn parseRegexTerm(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    var result = try allocator.create(RegexASTInternal);
    var result_list = try std.ArrayList(*RegexASTInternal).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            destroyRegexAST(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    try result_list.append(allocator, try parseRegexFactor(allocator, str_to_parse, i));
    while (i.* < str_to_parse.len and str_to_parse[i.*] != '|' and str_to_parse[i.*] != ')') { // If character pointed to is handled by expr or factor, break.
        try result_list.append(allocator, try parseRegexFactor(allocator, str_to_parse, i));
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{.concatenation = .{.parts = list_slice}};
    if (list_slice.len == 1) {
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

fn parseRegexCharClass(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    const result = try allocator.create(RegexASTInternal);
    var result_list = try std.ArrayList(RegexLeafAtomType).initCapacity(allocator, 1);
    var negated: bool = false;
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        // for (result_list.items) |item| {
        //     destroyRegexAST(allocator, item) catch @panic("Cant free AST after error!");
        // }
        allocator.destroy(result);
    }
    if (str_to_parse[i.*] == '^') { // handle ^ negation edge case for first part char class.
        negated = true;
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            return RegexParsingError.EndOfString;
        }
    }
    var item: RegexLeafAtomType = undefined;
    while (i.* < str_to_parse.len and (str_to_parse[i.*] != ']' or str_to_parse[i.* - 1] == '\\')) { // Parse until ending brace, excluding ending braces escaped with backslash.
        item = try fetchCharOrRangeInClass(str_to_parse, i); // Parse the first item in the class.
        try result_list.append(allocator, item);
        i.* += 1;
    }
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{.class = .{.items = list_slice, .negated = negated}};
    return result;
}

fn parseRegexFactor(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    if (str_to_parse[i.*] == '(' and (i.* == 0 or str_to_parse[i.* - 1] != '\\')) { // Count ( as group starter except when escaped.
        i.* += 1; // Consume '('.
        const result: *RegexASTInternal = try allocator.create(RegexASTInternal);
        errdefer allocator.destroy(result); // Only defers inside this if statement.
        if (i.* < str_to_parse.len - 2 and str_to_parse[i.*] == '?') { // check all possible lookahead flags if safe to do so.
            if (str_to_parse[i.* + 1] == '<' and str_to_parse[i.* + 2] == '=') {
                i.* += 3; // consume ?<=
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .lookbehind}, .negated = false}}};
            } else if (str_to_parse[i.* + 1] == '<' and str_to_parse[i.* + 2] == '!') {
                i.* += 3; // consume ?<!
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .lookbehind}, .negated = true}}};
            } else if (str_to_parse[i.* + 1] == '<') {
                var j: usize = i.* + 2;
                while (j < str_to_parse.len and str_to_parse[j] != '>') {
                    j += 1;
                }
                if (j >= str_to_parse.len) {
                    return RegexParsingError.EndOfString;
                }
                const name: []const u8 = str_to_parse[i.* + 2..j];
                i.* = j + 1;
                result.* = .{.group = .{ .expr = try parseRegexExpr(allocator, str_to_parse, i), .name = name, .id = 0, .group_data = .{.type = .{.capturing = .generic}, .negated = false}}};
            } else if (str_to_parse[i.* + 1] == '=') {
                i.* += 2; // consume ?=
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .lookahead}, .negated = false}}};
            } else if (str_to_parse[i.* + 1] == '!') {
                i.* += 2; // consume ?!
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .lookahead}, .negated = true}}};
            } else if (str_to_parse[i.* + 1] == ':') {
                i.* += 2; // consume ?:
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .generic}, .negated = false}}};
            } else if (str_to_parse[i.* + 1] == '>') {
                i.* += 2; // consume ?>
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .atomic}, .negated = false}}}; // Atomic groups do not capture.
            } else { // ? found but no matching flag.
                return RegexParsingError.TokenNotFound;
            }
        } else if (i.* < str_to_parse.len - 1 and str_to_parse[i.*] == '?') { // if only safe to check length 2 quantifiers, do that instead.
            if (str_to_parse[i.* + 1] == '=') {
                i.* += 2; // consume ?=
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .lookahead}, .negated = false}}};
            } else if (str_to_parse[i.* + 1] == '!') {
                i.* += 2; // consume ?!
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .lookahead}, .negated = true}}};
            } else if (str_to_parse[i.* + 1] == ':') {
                i.* += 2; // consume ?:
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .generic}, .negated = false}}};
            } else if (str_to_parse[i.* + 1] == '>') {
                i.* += 2; // consume ?>
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.non_capturing = .atomic}, .negated = false}}}; // Atomic groups do not capture.
            } else { // ? found but no matching flag.
                return RegexParsingError.TokenNotFound;
            }
        } else { // otherwise, do regular group.
            result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .name = null, .id = 0, .group_data = .{.type = .{.capturing = .generic}, .negated = false}}};
        }
        if (i.* >= str_to_parse.len or str_to_parse[i.*] != ')') {
            try destroyRegexAST(allocator, result.group.expr);
            return RegexParsingError.TokenNotFound;
        }
        i.* += 1; // consume ')'
        if (i.* < str_to_parse.len) { // Don't check quantifiers when ) is at the end of the string.
            return try checkQuantifiers(result, allocator, str_to_parse, i);
        } else {
            return result;
        }
    }
    var atom = try allocator.create(RegexASTInternal);
    var metacharacter: bool = undefined;
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') { // Handle generic escape sequence vs non escaped.
        i.* += 1; // Consume backslash.
        if (i.* >= str_to_parse.len) {
            allocator.destroy(atom);
            return RegexParsingError.EndOfString;
        }
        escaped = true;
        metacharacter = isEscapedMetacharacter(str_to_parse[i.*]);
    } else {
        metacharacter = isDefaultMetacharacter(str_to_parse[i.*]);
    }
    var char_to_set: u8 = str_to_parse[i.*]; // Grab character and set value based on escape sequence.
    if (escaped) {
        switch (str_to_parse[i.*]) {
            'n' => {
                char_to_set = '\n';
            },
            't' => {
                char_to_set = '\t';
            },
            'r' => {
                char_to_set = '\r';
            },
            else => {},
        }
    }
    if (char_to_set == '[' and !escaped) { // If character is a '[' and has not been escaped, then start parsing as a character class.
        allocator.destroy(atom);
        i.* += 1; // Consume the '['.
        atom = try parseRegexCharClass(allocator, str_to_parse, i);
    } else {
        atom.* = .{.leaf_atom = fetchCharLeafAtom(char_to_set, metacharacter) catch |err| {allocator.destroy(atom); return err;}}; // Manually catch/free with erroring to prevent double-free.
    }
    i.* += 1; // Consume most recently used character, either the current token or the end of char class.
    if (i.* >= str_to_parse.len) return atom; // Only if at end of string, otherwise check for repetition.
    return checkQuantifiers(atom, allocator, str_to_parse, i) catch |err| {allocator.destroy(atom); return err;};
}

fn fetchCharLeafAtom(char_to_set: u8, metacharacter: bool) !RegexLeafAtomType {
    switch(metacharacter) {
        true => {
            switch(char_to_set) {
                'd' => {
                    return .{.leaf_atom = .digit, .inverted = false};
                },
                'D' => {
                    return .{.leaf_atom = .digit, .inverted = true};
                },
                's' => {
                    return .{.leaf_atom = .whitespace, .inverted = false};
                },
                'S' => {
                    return .{.leaf_atom = .whitespace, .inverted = true};
                },
                'w' => {
                    return .{.leaf_atom = .word, .inverted = false};
                },
                'W' => {
                    return .{.leaf_atom = .word, .inverted = true};
                },
                'b' => {
                    return .{.leaf_atom = .word_boundary, .inverted = false};
                },
                'B' => {
                    return .{.leaf_atom = .word_boundary, .inverted = true};
                },
                '^' => {
                    return .{.leaf_atom = .start_anchor, .inverted = false};
                },
                '$' => {
                    return .{.leaf_atom = .end_anchor, .inverted = false};
                },
                '.' => {
                    return .{.leaf_atom = .any, .inverted = false};
                },
                '(', ')', '[', ']', '{', '}', '|' => {
                    return RegexParsingError.TokenNotFound;
                },
                else => {
                    return .{.leaf_atom = .{.generic = char_to_set}, .inverted = false};
                }
            }
        },
        false => {
            return .{.leaf_atom = .{.generic = char_to_set}, .inverted = false};
        }
    }
}

fn isDefaultMetacharacter(character: u8) bool {
    switch (character) {
        '$', '^', '.', '[', ']', '(', ')', '{', '}', '*', '+', '|', '?' => {
            return true;
        },
        else => {
            return false;
        },
    }
}

fn isEscapedMetacharacter(character: u8) bool {
    switch (character) {
        'b', 'B', 'd', 'D', 's', 'S', 'w', 'W' => {
            return true;
        },
        else => {
            return false;
        },
    }
}

fn assertRepetitionAllowance(atom: *RegexASTInternal,) !void {
    switch (atom.*) { // Validate that node is allowed to be repeated.
        .group => |grp| {
            switch(grp.group_data.type) {
                .non_capturing => {
                    return RegexParsingError.TokenNotFound;
                },
                else => {},
            }
        },
        .epsilon, .repetition, => {
            return RegexParsingError.TokenNotFound;
        },
        .leaf_atom => |leaf| {
            switch(leaf.leaf_atom) {
                .end_anchor, .start_anchor, .word_boundary => {
                    return RegexParsingError.TokenNotFound;
                },
                else => {},
            }
        },
        else => {

        },
    }
}

fn checkQuantifiers(atom: *RegexASTInternal, allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    var count_min: usize = undefined;
    var count_max: RegexBoundType = undefined;
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    var repetition_container: RegexRepetitionRangeType = undefined;
    switch (str_to_parse[i.*]) {
        '*' => {
            try assertRepetitionAllowance(atom);
            repetition_container = .{.min = 0, .max = .unbounded};
            i.* += 1;
        },
        '+' => {
            try assertRepetitionAllowance(atom);
            repetition_container = .{.min = 1, .max = .unbounded};
            i.* += 1;
        },
        '?' => {
            try assertRepetitionAllowance(atom);
            repetition_container = .{.min = 0, .max = .{.bounded = 1}};
            i.* += 1;
        },
        '{' => { // Permissive parsing on {,}
            try assertRepetitionAllowance(atom);
            i.* += 1; // Skip past curly brace.
            if (i.* >= str_to_parse.len) {
                return RegexParsingError.EndOfString;
            }
            if (str_to_parse[i.*] == ',') { // If no number is present before the , then the min is 0.
                count_min = 0;
            } else {
                const num_slice_index_min = i.* + (std.mem.indexOfNone(u8, str_to_parse[i.*..], "0123456789") orelse str_to_parse.len - i.*); // Grab the index where the numeric component of string ends.
                count_min = try std.fmt.parseUnsigned(usize, str_to_parse[i.*..num_slice_index_min], 10); // Slice through numeric component and grab int value.
                i.* = num_slice_index_min; // Set i to what was caught by integer conversion.
            }
            if (str_to_parse[i.*] != ',') { // If comma is not encountered, it is one number so min and max should be the same.
                count_max = .{.bounded = count_min};
            } else {
                i.* += 1;
                if (i.* >= str_to_parse.len) {
                    return RegexParsingError.EndOfString;
                }
                if (str_to_parse[i.*] == '}') { // If comma is encountered but no ending number is found, then max is the largest possible int.
                    count_max = .unbounded;
                } else {
                    const num_slice_index_max = i.* + (std.mem.indexOfNone(u8, str_to_parse[i.*..], "0123456789") orelse str_to_parse.len - i.*); // Same arithmetic as with min.
                    count_max = .{.bounded = try std.fmt.parseUnsigned(usize, str_to_parse[i.*..num_slice_index_max], 10)};
                    i.* = num_slice_index_max;
                }
            }
            if (i.* >= str_to_parse.len or str_to_parse[i.*] != '}') {
                return RegexParsingError.TokenNotFound;
            }
            repetition_container = .{.min = count_min, .max = count_max};
            i.* += 1;
        },
        else => { // If no quantifier is found, do not wrap in repetition.
            return atom;
        },
    }
    var rep_type: RegexRepeaterType = .greedy;
    if (i.* < str_to_parse.len and str_to_parse[i.*] == '+') {
        rep_type = .possessive;
        i.* += 1; // Consume the possessive +.
    } else if (i.* < str_to_parse.len and str_to_parse[i.*] == '?') {
        rep_type = .lazy;
        i.* += 1; // Consume the lazy ?.
    }
    const atom_parent = try allocator.create(RegexASTInternal); // Construct repetition node and wrap atom in it.
    atom_parent.* = .{.repetition = .{.child = atom, .reps = repetition_container, .rep_type = rep_type}};
    return atom_parent;
}

fn fetchCharOrRangeInClass(str_to_parse: []const u8, i: *usize) anyerror!RegexLeafAtomType { // For use in character class compilation to tokenize with '-' syntax awareness.
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') {
        i.* += 1; // Consume backslash.
        if (i.* >= str_to_parse.len) {
            return RegexParsingError.EndOfString;
        }
        escaped = true;
    }
    var char_to_set: u8 = str_to_parse[i.*];
    if (escaped) {
        switch (str_to_parse[i.*]) {
            'n' => {
                char_to_set = '\n';
            },
            't' => {
                char_to_set = '\t';
            },
            'r' => {
                char_to_set = '\r';
            },
            ']' => {
            },
            'd' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return RegexParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .digit, .inverted = false};
            },
            'D' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return RegexParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .digit, .inverted = true};
            },
            'w' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return RegexParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .word, .inverted = false};
            },
            'W' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return RegexParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .word, .inverted = true};
            },
            's' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return RegexParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .whitespace, .inverted = false};
            },
            'S' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return RegexParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .whitespace, .inverted = true};
            },
            'b', 'B' => { // Not allowed at all in char classes.
                return RegexParsingError.TokenNotFound;
            },
            else => {
                // leave it alone
            },
        }
    } else { // Bad edge case; here for later use if needed for refinement.
        // switch(char_to_set) {
        //     '$', '^', '(' => {
        //         return RegexParsingError.TokenNotFound;
        //     },
        //     else => {},
        // }
    }
    escaped = false;
    if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') { // Range syntax.
        if (i.* < str_to_parse.len - 2 and str_to_parse[i.* + 2] == ']') { // Return so that '-' is interpreted as a character at the end.
            return .{.leaf_atom = .{.generic = char_to_set}, .inverted = false};
        }
        i.* += 2; // Skip past current item and -.
        if (i.* >= str_to_parse.len) {
            return RegexParsingError.EndOfString;
        }
        if (str_to_parse[i.*] == '\\') {
            i.* += 1; // Consume backslash.
            if (i.* >= str_to_parse.len) {
                return RegexParsingError.EndOfString;
            }
            escaped = true;
        }
        var char_to_set2: u8 = str_to_parse[i.*]; // Grab character after -.
        if (escaped) {
            switch (str_to_parse[i.*]) {
                'n' => {
                    char_to_set2 = '\n';
                },
                't' => {
                    char_to_set2 = '\t';
                },
                'r' => {
                    char_to_set2 = '\r';
                },
                ']' => {
                },
                'b', 'B', 'd', 'D', 's', 'S', 'w', 'W' => { // Characters not allowed in ranges or at all.
                    return RegexParsingError.TokenNotFound;
                },
                else => {
                },
            }
        } else {
            switch(char_to_set) {
                '$', '^', '(' => {
                    return RegexParsingError.TokenNotFound;
                },
                else => {},
            }
        }
        if (char_to_set >= char_to_set2) {
            return RegexParsingError.InvalidRange;
        }
        return .{.leaf_atom = .{.range = .{.character_min = char_to_set, .character_max = char_to_set2}}, .inverted = false}; // If range is found, make range node.
    }
    return .{.leaf_atom = .{.generic = char_to_set}, .inverted = false}; // If range is found, make range node.
}

pub fn printRegexAST(out_interface: anytype, pattern: RegexPattern, show_match_width: bool) !void {
    if (pattern.ast) |ast| {
        try printRegexASTRecursive(out_interface, ast, show_match_width, 0);
    }
}

fn printRegexLeafAtom(out_interface: anytype, leaf: RegexLeafAtomType) !void {
    switch(leaf.leaf_atom) {
        .generic => |gen_leaf| {
            var buf: [2]u8 = undefined;
            if (gen_leaf == '\n') {
                buf[0] = '\\';
                buf[1] = 'n';
            } else if (gen_leaf == '\t') {
                buf[0] = '\\';
                buf[1] = 't';
            } else if (gen_leaf == '\r') {
                buf[0] = '\\';
                buf[1] = 'r';
            } else {
                buf[0] = gen_leaf;
                buf[1] = 0;
            }
            try out_interface.print("LITERAL(char = {s})\n", .{buf});
        },
        .range => |range| {
            var buf: [2]u8 = undefined;
            var buf2: [2]u8 = undefined;
            if (range.character_min == '\n') {
                buf[0] = '\\';
                buf[1] = 'n';
            } else if (range.character_min == '\t') {
                buf[0] = '\\';
                buf[1] = 't';
            } else if (range.character_min == '\r') {
                buf[0] = '\\';
                buf[1] = 'r';
            } else {
                buf[0] = range.character_min;
                buf[1] = 0;
            }
            if (range.character_max == '\n') {
                buf2[0] = '\\';
                buf2[1] = 'n';
            } else if (range.character_max == '\t') {
                buf2[0] = '\\';
                buf2[1] = 't';
            } else if (range.character_max == '\r') {
                buf2[0] = '\\';
                buf2[1] = 'r';
            } else {
                buf2[0] = range.character_max;
                buf2[1] = 0;
            }
            try out_interface.print("RANGE(min = {s}, max = {s})\n", .{buf, buf2});
        },
        else => {
            try out_interface.print("LITERAL(item = {s}, negated = {})\n", .{@tagName(leaf.leaf_atom), leaf.inverted});
        },
    }
}

fn printRegexASTRecursive(out_interface: anytype, ast: *const RegexASTInternal, show_match_width: bool, recursion_level: usize) !void {
    for (0..recursion_level) |_| {
        try out_interface.print("\t", .{});
    }
    const len: RegexRepetitionRangeType = matchRequirementRange(ast);
    if (show_match_width) {
        switch (len.max) {
            .bounded => {
                try out_interface.print("[Requisite match width is {d} - {d}] ", .{len.min, len.max.bounded});
            },
            .unbounded => {
                try out_interface.print("[Requisite match width is {d} - inf] ", .{len.min});
            },
        }
    }
    switch (ast.*) {
        .leaf_atom => |leaf| {
            try printRegexLeafAtom(out_interface, leaf);
        },
        .repetition => |rep| {
            switch (rep.reps.max) {
                .bounded => {
                    try out_interface.print("REPETITION(min = {}, max = {}, type = {s})\n", .{rep.reps.min, rep.reps.max.bounded, @tagName(rep.rep_type)});
                },
                .unbounded => {
                    try out_interface.print("REPETITION(min = {}, max = inf, type = {s})\n", .{rep.reps.min, @tagName(rep.rep_type)});
                },
            }
            try printRegexASTRecursive(out_interface, rep.child, show_match_width, recursion_level + 1);
        },
        .alternation => |alt| {
            try out_interface.print("ALTERNATION()\n", .{});
            for (0..alt.parts.len) |i| {
                try printRegexASTRecursive(out_interface, alt.parts[i], show_match_width, recursion_level + 1);
            }
        },
        .group => |grp| {
            try out_interface.print("GROUP(id = {?}, name = {?s}, type = {s}.", .{grp.id, grp.name, @tagName(grp.group_data.type)});
            switch(grp.group_data.type) {
                .capturing => {
                    try out_interface.print("{s}, ", .{@tagName(grp.group_data.type.capturing)});
                },
                .non_capturing => {
                    try out_interface.print("{s}, ", .{@tagName(grp.group_data.type.non_capturing)});
                },
            }
            try out_interface.print("negated = {})\n", .{grp.group_data.negated});
            try printRegexASTRecursive(out_interface, grp.expr, show_match_width, recursion_level + 1);
        },
        .concatenation => |concat| {
            try out_interface.print("CONCATENATION()\n", .{});
            for (0..concat.parts.len) |i| {
                try printRegexASTRecursive(out_interface, concat.parts[i], show_match_width, recursion_level + 1);
            }
        },
        .class => |class_item| {
            try out_interface.print("CLASS(negated = {})\n", .{class_item.negated});
            for (0..class_item.items.len) |i| {
                for (0..recursion_level+1) |_| {
                    try out_interface.print("\t", .{});
                }
                try printRegexLeafAtom(out_interface, class_item.items[i]);
            }
        },
        .epsilon => {
            try out_interface.print("EPSILON()\n", .{});
        },
    }
}

pub fn destroyRegexPattern(allocator: anytype, pattern: RegexPattern) !void {
    if (pattern.ast) |ast| {
        try destroyRegexAST(allocator, ast);
    }
    // add destructor for bytecode here.
}

pub fn destroyRegexAST(allocator: anytype, pattern: RegexAST) !void {
    switch (pattern.*) {
        .leaf_atom => {},
        .alternation => |alt| {
            for (alt.parts) |item| {
                try destroyRegexAST(allocator, item);
            }
            allocator.free(alt.parts);
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try destroyRegexAST(allocator, item);
            }
            allocator.free(concat.parts);
        },
        .group => |grp| {
            try destroyRegexAST(allocator, grp.expr);
        },
        .repetition => |rep| {
            try destroyRegexAST(allocator, rep.child);
        },
        .class => |class_item| {
            allocator.free(class_item.items);
        },
        .epsilon => {
            return;
        }, // Epsilons contain no data and are always the same. Uses a single element and should not be freed.
    }
    allocator.destroy(pattern);
}
