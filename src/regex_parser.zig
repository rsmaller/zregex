const std = @import("std");
const zregex = @import("root.zig");
const regex_type_reflection = @import("regex_type_reflection.zig");
const core_regex_types = @import("core_regex_types.zig");

var EPSILON_UNIT: core_regex_types.ASTNode = .epsilon; // Generic epsilon copy used everywhere; contains no data.

fn setGroupIDs(ast: *core_regex_types.ASTNode, id: *usize) !void {
    switch(ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            switch(grp.type) {
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

fn isEqualBound(a: core_regex_types.RepetitionRangeType, b: core_regex_types.RepetitionRangeType) bool {
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

fn addBound(a: core_regex_types.RepetitionRangeType, b: core_regex_types.RepetitionRangeType) core_regex_types.RepetitionRangeType {
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

fn timesBound(a: core_regex_types.RepetitionRangeType, b: core_regex_types.RepetitionRangeType) core_regex_types.RepetitionRangeType {
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

fn alternationBound(a: core_regex_types.RepetitionRangeType, b: core_regex_types.RepetitionRangeType) core_regex_types.RepetitionRangeType {
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

fn matchRequirementRange(ast: *const core_regex_types.ASTNode) core_regex_types.RepetitionRangeType { // This function checks the width of characters that may be represented by an AST; it does NOT check how many characters the resulting bytecode will consume.
    var result = core_regex_types.RepetitionRangeType{.min = 0, .max = .{.bounded = 0}};
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
            return core_regex_types.RepetitionRangeType{
                .min = 1,
                .max = .{
                    .bounded = 1
                }
            };
        },
        .leaf_atom => |leaf| {
            switch(leaf.leaf_atom) {
                .word_boundary, .start_anchor, .end_anchor => {
                    return core_regex_types.RepetitionRangeType{
                        .min = 0,
                        .max = .{
                            .bounded = 0
                        }
                    };
                },
                else => {
                    return core_regex_types.RepetitionRangeType{
                        .min = 1,
                        .max = .{
                            .bounded = 1
                        }
                    };
                }
            }
        },
        .epsilon => {
            return core_regex_types.RepetitionRangeType{
                .min = 0,
                .max = .{
                    .bounded = 0
                }
            };
        }
    }
}

// Makes a copy of an array without duplicates, in-order. Assumes that pointer elements are heap-allocated and single-pointers.
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
            if (regex_type_reflection.genericEqualityDispatch(arr[i], arr[j])) {
                freed[j] = true;
                switch(@typeInfo(T)) {
                    .pointer => |ptr| {
                        if (ptr.child == core_regex_types.ASTNode) {
                            try destroyAST(allocator, arr[j]);
                        } else {
                            try allocator.free(arr[j]);
                        }
                    },
                    else => {}
                }
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn trimAST(ast: *core_regex_types.ASTNode, allocator: anytype) !void {
    switch(ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            if (grp.negated) {
            switch(grp.type) {
                .capturing => {
                    return core_regex_types.ParsingError.TokenNotFound;
                },
                .non_capturing => |non_capt| {
                    switch(non_capt) {
                        .atomic, .generic => {
                            return core_regex_types.ParsingError.TokenNotFound;
                        },
                        else => {},
                    }
                }
            }
        }
        switch(grp.type) {
            .capturing => {},
            .non_capturing => |non_capt| {
                switch(non_capt) {
                    .lookbehind => {
                        const len = matchRequirementRange(grp.expr);
                        switch(len.max) {
                            .unbounded => {
                                return core_regex_types.ParsingError.VariableLookbehindRange;
                            },
                            .bounded => {
                                if (len.max.bounded != len.min) {
                                    return core_regex_types.ParsingError.VariableLookbehindRange;
                                }
                                ast.group.type.non_capturing.lookbehind = len.max.bounded;
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

fn parseExpr(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*core_regex_types.ASTNode {
    var result = try allocator.create(core_regex_types.ASTNode);
    var result_list = try std.ArrayList(*core_regex_types.ASTNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            destroyAST(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    if (i.* >= str_to_parse.len) return core_regex_types.ParsingError.EndOfString; // Error out after deferring.
    if (str_to_parse[i.*] == '|' or str_to_parse[i.*] == ')') { // Handle epsilon as the first alternation argument.
        try result_list.append(allocator, &EPSILON_UNIT);
    } else { // If not an epsilon, just parse the first alternation as a regular term.
        try result_list.append(allocator, try parseTerm(allocator, str_to_parse, i));
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
        try result_list.append(allocator, try parseTerm(allocator, str_to_parse, i)); // Handle generic terms in alternation not caught by edge cases.
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{
        .alternation = .{
            .parts = list_slice
        }
    }; // Start parsing alternations first, and assume 2 alternations minimum.
    if (list_slice.len == 1) {
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

fn parseTerm(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*core_regex_types.ASTNode {
    if (i.* >= str_to_parse.len) return core_regex_types.ParsingError.EndOfString;
    var result = try allocator.create(core_regex_types.ASTNode);
    var result_list = try std.ArrayList(*core_regex_types.ASTNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            destroyAST(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    try result_list.append(allocator, try parseFactor(allocator, str_to_parse, i));
    while (i.* < str_to_parse.len and str_to_parse[i.*] != '|' and str_to_parse[i.*] != ')') { // If character pointed to is handled by expr or factor, break.
        try result_list.append(allocator, try parseFactor(allocator, str_to_parse, i));
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{
        .concatenation = .{
            .parts = list_slice
        }
    };
    if (list_slice.len == 1) {
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

fn parseCharClass(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*core_regex_types.ASTNode {
    if (i.* >= str_to_parse.len) return core_regex_types.ParsingError.EndOfString;
    const result = try allocator.create(core_regex_types.ASTNode);
    var result_list = try std.ArrayList(core_regex_types.LeafAtomNode).initCapacity(allocator, 1);
    var negated: bool = false;
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        allocator.destroy(result);
    }
    if (str_to_parse[i.*] == '^') { // handle ^ negation edge case for first part char class.
        negated = true;
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            return core_regex_types.ParsingError.EndOfString;
        }
    }
    var item: core_regex_types.LeafAtomNode = undefined;
    while (i.* < str_to_parse.len and (str_to_parse[i.*] != ']' or str_to_parse[i.* - 1] == '\\')) { // Parse until ending brace, excluding ending braces escaped with backslash.
        item = try fetchCharOrRangeInClass(str_to_parse, i); // Parse the first item in the class.
        try result_list.append(allocator, item);
        i.* += 1;
    }
    if (i.* >= str_to_parse.len) {
        return core_regex_types.ParsingError.EndOfString;
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{
        .class = .{
            .items = list_slice,
            .negated = negated
        }
    };
    return result;
}

fn parseFactor(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*core_regex_types.ASTNode {
    if (i.* >= str_to_parse.len) return core_regex_types.ParsingError.EndOfString;
    if (str_to_parse[i.*] == '(' and (i.* == 0 or str_to_parse[i.* - 1] != '\\')) { // Count ( as group starter except when escaped.
        i.* += 1; // Consume '('.
        const result: *core_regex_types.ASTNode = try allocator.create(core_regex_types.ASTNode);
        errdefer allocator.destroy(result); // Only defers inside this if statement.
        if (i.* < str_to_parse.len - 2 and str_to_parse[i.*] == '?') { // check all possible lookahead flags if safe to do so.
            if (str_to_parse[i.* + 1] == '<' and str_to_parse[i.* + 2] == '=') {
            i.* += 3; // consume ?<=
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null, .id = 0,
                    .type = .{
                        .non_capturing = .{.lookbehind = 0},
                    },
                    .negated = false
                }
            };
        } else if (str_to_parse[i.* + 1] == '<' and str_to_parse[i.* + 2] == '!') {
            i.* += 3; // consume ?<!
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .{.lookbehind = 0},
                    },
                    .negated = true}
            };
        } else if (str_to_parse[i.* + 1] == '<') {
            var j: usize = i.* + 2;
            while (j < str_to_parse.len and str_to_parse[j] != '>') {
                j += 1;
            }
            if (j >= str_to_parse.len) {
                return core_regex_types.ParsingError.EndOfString;
            }
            const name: []const u8 = str_to_parse[i.* + 2..j];
            i.* = j + 1;
            result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = name,
                    .id = 0,
                    .type = .{
                        .capturing = .generic
                    },
                    .negated = false
                }
            };
        } else if (str_to_parse[i.* + 1] == '=') {
            i.* += 2; // consume ?=
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .lookahead
                    },
                    .negated = false
                }
            };
        } else if (str_to_parse[i.* + 1] == '!') {
            i.* += 2; // consume ?!
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .lookahead
                    },
                    .negated = true
                }
            };
        } else if (str_to_parse[i.* + 1] == ':') {
            i.* += 2; // consume ?:
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .generic
                    },
                    .negated = false
                }
            };
        } else if (str_to_parse[i.* + 1] == '>') {
            i.* += 2; // consume ?>
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .atomic
                    },
                    .negated = false
                }
            };
        } else { // ? found but no matching flag.
                return core_regex_types.ParsingError.TokenNotFound;
        }
        } else if (i.* < str_to_parse.len - 1 and str_to_parse[i.*] == '?') { // if only safe to check length 2 quantifiers, do that instead.
            if (str_to_parse[i.* + 1] == '=') {
            i.* += 2; // consume ?=
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .lookahead
                    },
                    .negated = false
                }
            };
        } else if (str_to_parse[i.* + 1] == '!') {
            i.* += 2; // consume ?!
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .lookahead
                    },
                    .negated = true
                }
            };
        } else if (str_to_parse[i.* + 1] == ':') {
            i.* += 2; // consume ?:
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .generic
                    },
                    .negated = false
                }
            };
        } else if (str_to_parse[i.* + 1] == '>') {
            i.* += 2; // consume ?>
                result.* = .{
                .group = .{
                    .expr = try parseExpr(allocator, str_to_parse, i),
                    .name = null,
                    .id = 0,
                    .type = .{
                        .non_capturing = .atomic
                    },
                    .negated = false
                }
            };
        } else { // ? found but no matching flag.
                return core_regex_types.ParsingError.TokenNotFound;
        }
        } else { // otherwise, do regular group.
            result.* = .{
            .group = .{
                .expr = try parseExpr(allocator, str_to_parse, i),
                .name = null,
                .id = 0,
                .type = .{
                    .capturing = .generic
                },
                .negated = false
            }
        };
        }
        if (i.* >= str_to_parse.len or str_to_parse[i.*] != ')') {
            try destroyAST(allocator, result.group.expr);
            return core_regex_types.ParsingError.TokenNotFound;
        }
        i.* += 1; // consume ')'
        if (i.* < str_to_parse.len) { // Don't check quantifiers when ) is at the end of the string.
            return try checkQuantifiers(result, allocator, str_to_parse, i);
        } else {
            return result;
        }
    }
    var atom = try allocator.create(core_regex_types.ASTNode);
    var metacharacter: bool = undefined;
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') { // Handle generic escape sequence vs non escaped.
        i.* += 1; // Consume backslash.
        if (i.* >= str_to_parse.len) {
        allocator.destroy(atom);
        return core_regex_types.ParsingError.EndOfString;
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
        atom = try parseCharClass(allocator, str_to_parse, i);
    } else {
        atom.* = .{
            .leaf_atom = fetchCharLeafAtom(char_to_set, metacharacter) catch |err| {
                allocator.destroy(atom);
                return err; // Manually catch/free with erroring to prevent double-free.
            }
        };
    }
    i.* += 1; // Consume most recently used character, either the current token or the end of char class.
    if (i.* >= str_to_parse.len) return atom; // Only if at end of string, otherwise check for repetition.
    return checkQuantifiers(atom, allocator, str_to_parse, i) catch |err| {
        allocator.destroy(atom);
        return err;
    };
}

fn fetchCharLeafAtom(char_to_set: u8, metacharacter: bool) !core_regex_types.LeafAtomNode {
    switch(metacharacter) {
        true => {
            switch(char_to_set) {
                'd' => {
                    return .{
                        .leaf_atom = .digit,
                        .inverted = false
                    };
                },
                'D' => {
                    return .{
                        .leaf_atom = .digit,
                        .inverted = true
                    };
                },
                's' => {
                    return .{
                        .leaf_atom = .whitespace,
                        .inverted = false
                    };
                },
                'S' => {
                    return .{
                        .leaf_atom = .whitespace,
                        .inverted = true
                    };
                },
                'w' => {
                    return .{
                        .leaf_atom = .word,
                        .inverted = false
                    };
                },
                'W' => {
                    return .{
                        .leaf_atom = .word,
                        .inverted = true
                    };
                },
                'b' => {
                    return .{
                        .leaf_atom = .word_boundary,
                        .inverted = false
                    };
                },
                'B' => {
                    return .{
                        .leaf_atom = .word_boundary,
                        .inverted = true
                    };
                },
                '^' => {
                    return .{
                        .leaf_atom = .start_anchor,
                        .inverted = false
                    };
                },
                '$' => {
                    return .{
                        .leaf_atom = .end_anchor,
                        .inverted = false
                    };
                },
                '.' => {
                    return .{
                        .leaf_atom = .any,
                        .inverted = false
                    };
                },
                '(', ')', '[', ']', '{', '}', '|' => {
                    return core_regex_types.ParsingError.TokenNotFound;
                },
                else => {
                    return .{
                        .leaf_atom = .{
                            .generic = char_to_set
                        },
                        .inverted = false
                    };
                }
            }
        },
        false => {
            return .{
                .leaf_atom = .{
                    .generic = char_to_set
                },
                .inverted = false
            };
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

fn assertRepetitionAllowance(atom: *core_regex_types.ASTNode) !void {
    switch (atom.*) { // Validate that node is allowed to be repeated.
        .group => |grp| {
        switch(grp.type) {
            .non_capturing => {
                return core_regex_types.ParsingError.TokenNotFound;
            },
            else => {},
        }
    },
        .epsilon, .repetition, => {
            return core_regex_types.ParsingError.TokenNotFound;
        },
        .leaf_atom => |leaf| {
            switch(leaf.leaf_atom) {
                .end_anchor, .start_anchor, .word_boundary => {
                    return core_regex_types.ParsingError.TokenNotFound;
                },
                else => {},
            }
        },
        else => {},
    }
}

fn checkQuantifiers(atom: *core_regex_types.ASTNode, allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*core_regex_types.ASTNode {
    var count_min: usize = undefined;
    var count_max: core_regex_types.RepetitionBoundType = undefined;
    if (i.* >= str_to_parse.len) {
        return core_regex_types.ParsingError.EndOfString;
    }
    var repetition_container: core_regex_types.RepetitionRangeType = undefined;
    switch (str_to_parse[i.*]) {
        '*' => {
            try assertRepetitionAllowance(atom);
            repetition_container = .{
                .min = 0,
                .max = .unbounded
            };
            i.* += 1;
        },
        '+' => {
            try assertRepetitionAllowance(atom);
            repetition_container = .{
                .min = 1,
                .max = .unbounded
            };
            i.* += 1;
        },
        '?' => {
            try assertRepetitionAllowance(atom);
            repetition_container = .{
                .min = 0,
                .max = .{
                    .bounded = 1
                }
            };
            i.* += 1;
        },
        '{' => { // Permissive parsing on {,}
            try assertRepetitionAllowance(atom);
            i.* += 1; // Skip past curly brace.
            if (i.* >= str_to_parse.len) {
                return core_regex_types.ParsingError.EndOfString;
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
                    return core_regex_types.ParsingError.EndOfString;
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
                return core_regex_types.ParsingError.TokenNotFound;
            }
            repetition_container = .{.min = count_min, .max = count_max};
            i.* += 1;
        },
        else => { // If no quantifier is found, do not wrap in repetition.
            return atom;
        },
    }
    var rep_type: core_regex_types.RepeaterType = .greedy;
    if (i.* < str_to_parse.len and str_to_parse[i.*] == '+') {
        rep_type = .possessive;
        i.* += 1; // Consume the possessive +.
    } else if (i.* < str_to_parse.len and str_to_parse[i.*] == '?') {
        rep_type = .lazy;
        i.* += 1; // Consume the lazy ?.
    }
    const atom_parent = try allocator.create(core_regex_types.ASTNode); // Construct repetition node and wrap atom in it.
    atom_parent.* = .{
        .repetition = .{
            .child = atom,
            .reps = repetition_container,
            .rep_type = rep_type
        }
    };
    return atom_parent;
}

fn fetchCharOrRangeInClass(str_to_parse: []const u8, i: *usize) anyerror!core_regex_types.LeafAtomNode { // For use in character class compilation to tokenize with '-' syntax awareness.
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') {
        i.* += 1; // Consume backslash.
        if (i.* >= str_to_parse.len) {
            return core_regex_types.ParsingError.EndOfString;
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
                    return core_regex_types.ParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .digit, .inverted = false};
            },
            'D' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return core_regex_types.ParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .digit, .inverted = true};
            },
            'w' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return core_regex_types.ParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .word, .inverted = false};
            },
            'W' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return core_regex_types.ParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .word, .inverted = true};
            },
            's' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return core_regex_types.ParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .whitespace, .inverted = false};
            },
            'S' => {
                if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') {
                    return core_regex_types.ParsingError.TokenNotFound;
                }
                return .{.leaf_atom = .whitespace, .inverted = true};
            },
            'b', 'B' => { // Not allowed at all in char classes.
                return core_regex_types.ParsingError.TokenNotFound;
            },
            else => {},
        }
    }
    escaped = false;
    if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') { // Range syntax.
        if (i.* < str_to_parse.len - 2 and str_to_parse[i.* + 2] == ']') { // Return so that '-' is interpreted as a character at the end.
            return .{
        .leaf_atom = .{
            .generic = char_to_set
        },
        .inverted = false
    };
    }
        i.* += 2; // Skip past current item and -.
        if (i.* >= str_to_parse.len) {
            return core_regex_types.ParsingError.EndOfString;
        }
        if (str_to_parse[i.*] == '\\') {
            i.* += 1; // Consume backslash.
            if (i.* >= str_to_parse.len) {
                return core_regex_types.ParsingError.EndOfString;
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
                    return core_regex_types.ParsingError.TokenNotFound;
                },
                else => {},
            }
        } else {
            switch(char_to_set) {
                '$', '^', '(' => {
                    return core_regex_types.ParsingError.TokenNotFound;
                },
                else => {},
            }
        }
        if (char_to_set >= char_to_set2) {
            return core_regex_types.ParsingError.InvalidRange;
        }
        return .{
            .leaf_atom = .{
                .range = .{
                    .character_min = char_to_set,
                    .character_max = char_to_set2
                }
            },
            .inverted = false
        }; // If range is found, make range node.
    }
    return .{
        .leaf_atom = .{
            .generic = char_to_set
        },
        .inverted = false
    }; // If range is found, make range node.
}

fn printLeafAtom(out_interface: anytype, leaf: core_regex_types.LeafAtomNode) !void {
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

fn printASTRecursive(out_interface: anytype, ast: *const core_regex_types.ASTNode, show_match_width: bool, recursion_level: usize) !void {
    for (0..recursion_level) |_| {
        try out_interface.print("\t", .{});
    }
    const len: core_regex_types.RepetitionRangeType = matchRequirementRange(ast);
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
            try printLeafAtom(out_interface, leaf);
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
            try printASTRecursive(out_interface, rep.child, show_match_width, recursion_level + 1);
        },
        .alternation => |alt| {
            try out_interface.print("ALTERNATION()\n", .{});
            for (0..alt.parts.len) |i| {
                try printASTRecursive(out_interface, alt.parts[i], show_match_width, recursion_level + 1);
            }
        },
        .group => |grp| {
            try out_interface.print("GROUP(id = {?}, name = {?s}, type = {s}.", .{grp.id, grp.name, @tagName(grp.type)});
            switch(grp.type) {
                .capturing => {
                    try out_interface.print("{s}, ", .{@tagName(grp.type.capturing)});
                },
                .non_capturing => {
                    try out_interface.print("{s}, ", .{@tagName(grp.type.non_capturing)});
                },
            }
            try out_interface.print("negated = {})\n", .{grp.negated});
            try printASTRecursive(out_interface, grp.expr, show_match_width, recursion_level + 1);
        },
        .concatenation => |concat| {
            try out_interface.print("CONCATENATION()\n", .{});
            for (0..concat.parts.len) |i| {
                try printASTRecursive(out_interface, concat.parts[i], show_match_width, recursion_level + 1);
            }
        },
        .class => |class_item| {
            try out_interface.print("CLASS(negated = {})\n", .{class_item.negated});
            for (0..class_item.items.len) |i| {
                for (0..recursion_level+1) |_| {
                    try out_interface.print("\t", .{});
                }
                try printLeafAtom(out_interface, class_item.items[i]);
            }
        },
        .epsilon => {
            try out_interface.print("EPSILON()\n", .{});
        },
    }
}

pub fn printAST(out_interface: anytype, pattern: zregex.Pattern, show_match_width: bool) !void {
    if (pattern.ast) |ast| {
        try printASTRecursive(out_interface, ast, show_match_width, 0);
    }
}

pub fn destroyAST(allocator: anytype, pattern: core_regex_types.AST) !void {
    switch (pattern.*) {
        .leaf_atom => {},
        .alternation => |alt| {
            for (alt.parts) |item| {
                try destroyAST(allocator, item);
            }
            allocator.free(alt.parts);
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try destroyAST(allocator, item);
            }
            allocator.free(concat.parts);
        },
        .group => |grp| {
            try destroyAST(allocator, grp.expr);
        },
        .repetition => |rep| {
            try destroyAST(allocator, rep.child);
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

pub fn compile(allocator: anytype, str_to_parse: []const u8) anyerror!core_regex_types.AST {
    var i: usize = 0;
    var j: usize = 1; // ID 0 is reserved for whole match.
    const ast = if (str_to_parse.len > 0) (try parseExpr(allocator, str_to_parse, &i)) else &EPSILON_UNIT;
    errdefer {
        destroyAST(allocator, ast) catch @panic("Failed to free AST after error!");
    }
    if (i != str_to_parse.len) {
        return core_regex_types.ParsingError.TokenNotFound;
    }
    try setGroupIDs(ast, &j);
    try trimAST(ast, allocator);
    return ast;
}