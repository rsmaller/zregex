//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const RegexAST = *const RegexASTInternal;

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

const RegexGroupType = union(enum) {
    capturing: enum {
        generic,
    },
    non_capturing: enum {
        generic,
        atomic,
        positive_lookahead,
        positive_lookbehind,
        negative_lookahead,
        negative_lookbehind,
    },
};

const RegexLiteralType = struct {
    literal: union(enum) {
        generic: u8,
        digit: void,
        word: void,
        whitespace: void,
        start_anchor: void,
        end_anchor: void,
        range: struct { // For ranges within char classes. Cannot contain metacharacters.
            character_min: u8,
        character_max: u8,
        },
    },
    negated: bool,
};

const RegexASTInternal = union(enum) { // Tagged union for node type.
    literal: RegexLiteralType,
    concatenation: struct {
        parts: []*RegexASTInternal, // Operation chaining two characters together.
    },
    alternation: struct{
        parts: []*RegexASTInternal,
    }, // Same as concatenation but semantically different and in a higher order function.
    group: struct {
        expr: *RegexASTInternal,
        id: ?usize,
        group_data: RegexGroupType,
    },
    repetition: struct { // Parent node to another node constructed by a quantifier.
        child: *RegexASTInternal,
        reps: RegexRepetitionRangeType,
        rep_type: RegexRepeaterType,
    },
    class: struct { // Character class.
        items: []RegexLiteralType,
        negated: bool,
    },
    epsilon: void, // Generic empty node.
};

var EPSILON_UNIT: RegexASTInternal = .epsilon; // Generic epsilon copy used everywhere; contains no data.

pub const RegexParsingError = error{
    TokenNotFound,
    EndOfString,
    InvalidRange,
};

pub fn compileRegex(allocator: anytype, str_to_parse: []const u8) anyerror!*RegexASTInternal {
    var i: usize = 0;
    var j: usize = 1; // ID 0 is reserved for whole match.
    const ret = try parseRegexExpr(allocator, str_to_parse, &i);
    try setGroupIDs(ret, &j);
    return ret;
}

fn setGroupIDs(ast: *RegexASTInternal, id: *usize) !void {
    switch(ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            switch(grp.group_data) {
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

fn parseRegexExpr(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    var result = try allocator.create(RegexASTInternal);
    var result_list = try std.ArrayList(*RegexASTInternal).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            destroyRegexPattern(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
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
    result.* = .{ .alternation = .{.parts = list_slice } }; // Start parsing alternations first, and assume 2 alternations minimum.
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
            destroyRegexPattern(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    try result_list.append(allocator, try parseRegexFactor(allocator, str_to_parse, i));
    while (i.* < str_to_parse.len and str_to_parse[i.*] != '|' and str_to_parse[i.*] != ')') { // If character pointed to is handled by expr or factor, break.
        try result_list.append(allocator, try parseRegexFactor(allocator, str_to_parse, i));
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{ .concatenation = .{.parts = list_slice} };
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
    var result_list = try std.ArrayList(RegexLiteralType).initCapacity(allocator, 1);
    var negated: bool = false;
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        // for (result_list.items) |item| {
        //     destroyRegexPattern(allocator, item) catch @panic("Cant free AST after error!");
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
    var item: RegexLiteralType = undefined;
    while (i.* < str_to_parse.len and (str_to_parse[i.*] != ']' or str_to_parse[i.* - 1] == '\\')) { // Parse until ending brace, excluding ending braces escaped with backslash.
        item = try fetchCharOrRangeInClass(str_to_parse, i); // Parse the first item in the class.
        try result_list.append(allocator, item);
        i.* += 1;
    }
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{ .class = .{ .items = list_slice, .negated = negated } };
    return result;
}

fn parseRegexFactor(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    if (str_to_parse[i.*] == '(' and (i.* == 0 or str_to_parse[i.* - 1] != '\\')) { // Count ( as group starter except when escaped.
        i.* += 1; // Consume '('.
        const result: *RegexASTInternal = try allocator.create(RegexASTInternal);
        if (i.* < str_to_parse.len - 2 and str_to_parse[i.*] == '?') { // check all possible lookahead flags if safe to do so.
            if (str_to_parse[i.* + 1] == '<' and str_to_parse[i.* + 2] == '=') {
                i.* += 3; // consume ?<=
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .positive_lookbehind}}};
            } else if (str_to_parse[i.* + 1] == '<' and str_to_parse[i.* + 2] == '!') {
                i.* += 3; // consume ?<!
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .negative_lookbehind}}};
            } else if (str_to_parse[i.* + 1] == '=') {
                i.* += 2; // consume ?=
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .positive_lookahead}}};
            } else if (str_to_parse[i.* + 1] == '!') {
                i.* += 2; // consume ?!
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .negative_lookahead}}};
            } else if (str_to_parse[i.* + 1] == ':') {
                i.* += 2; // consume ?:
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .generic}}};
            } else if (str_to_parse[i.* + 1] == '>') {
                i.* += 2; // consume ?>
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .atomic}}}; // Atomic groups do not capture.
            } else { // ? found but no matching flag.
                allocator.destroy(result);
                return RegexParsingError.TokenNotFound;
            }
        } else if (i.* < str_to_parse.len - 1 and str_to_parse[i.*] == '?') { // if only safe to check length 2 quantifiers, do that instead.
            if (str_to_parse[i.* + 1] == '=') {
                i.* += 2; // consume ?=
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .positive_lookahead}}};
            } else if (str_to_parse[i.* + 1] == '!') {
                i.* += 2; // consume ?!
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .negative_lookahead}}};
            } else if (str_to_parse[i.* + 1] == ':') {
                i.* += 2; // consume ?:
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .generic}}};
            } else if (str_to_parse[i.* + 1] == '>') {
                i.* += 2; // consume ?>
                result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.non_capturing = .atomic}}}; // Atomic groups do not capture.
            } else { // ? found but no matching flag.
                allocator.destroy(result);
                return RegexParsingError.TokenNotFound;
            }
        } else { // otherwise, do regular group.
            result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .id = 0, .group_data = .{.capturing = .generic}}};
        }
        if (i.* >= str_to_parse.len or str_to_parse[i.*] != ')') {
            allocator.destroy(result);
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
    errdefer allocator.destroy(atom);
    var metacharacter: bool = undefined;
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') { // Handle generic escape sequence vs non escaped.
        i.* += 1; // Consume backslash.
        if (i.* >= str_to_parse.len) {
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
        atom.* = .{ .literal = fetchCharLiteral(char_to_set, metacharacter)};
    }
    i.* += 1; // Consume most recently used character, either the current token or the end of char class.
    if (i.* >= str_to_parse.len) return atom; // Only if at end of string, otherwise check for repetition.
    return try checkQuantifiers(atom, allocator, str_to_parse, i);
}

fn fetchCharLiteral(char_to_set: u8, metacharacter: bool) RegexLiteralType {
    switch(metacharacter) {
        true => {
            switch(char_to_set) {
                'd' => {
                    return .{.literal = .digit, .negated = false};
                },
                'D' => {
                    return .{.literal = .digit, .negated = true};
                },
                's' => {
                    return .{.literal = .whitespace, .negated = false};
                },
                'S' => {
                    return .{.literal = .whitespace, .negated = true};
                },
                'w' => {
                    return .{.literal = .word, .negated = false};
                },
                'W' => {
                    return .{.literal = .word, .negated = true};
                },
                '^' => {
                    return .{.literal = .start_anchor, .negated = false};
                },
                '$' => {
                    return .{.literal = .end_anchor, .negated = false};
                },
                else => {
                    return .{.literal = .{.generic = char_to_set}, .negated = false};
                }
            }
        },
        false => {
            return .{.literal = .{.generic = char_to_set}, .negated = false};
        }
    }
}

fn isDefaultMetacharacter(character: u8) bool {
    switch (character) {
        '$', '^', '.', '[' => {
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

fn checkQuantifiers(atom: *RegexASTInternal, allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexASTInternal {
    var count_min: usize = undefined;
    var count_max: RegexBoundType = undefined;
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    var repetition_container: RegexRepetitionRangeType = undefined;
    switch (str_to_parse[i.*]) {
        '*' => {
            repetition_container = .{.min = 0, .max = .unbounded};
            i.* += 1;
        },
        '+' => {
            repetition_container = .{.min = 1, .max = .unbounded};
            i.* += 1;
        },
        '?' => {
            repetition_container = .{.min = 0, .max = .{.bounded = 1}};
            i.* += 1;
        },
        '{' => { // Permissive parsing on {,}
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
                if (str_to_parse[i.*] == '}') { // If comma is encountered but no ending number is foumd, then max is the largest possible int.
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
    atom_parent.* = .{ .repetition = .{ .child = atom, .reps = repetition_container, .rep_type = rep_type } };
    return atom_parent;
}

fn fetchCharOrRangeInClass(str_to_parse: []const u8, i: *usize) anyerror!RegexLiteralType { // For use in character class compilation to tokenize with '-' syntax awareness.
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
            ']' => {},
            else => {
                return RegexParsingError.TokenNotFound;
            },
        }
    }
    escaped = false;
    if (i.* < str_to_parse.len - 1 and str_to_parse[i.* + 1] == '-') { // Range syntax.
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
                ']' => {},
                else => {
                    return RegexParsingError.TokenNotFound;
                },
            }
        }
        if (char_to_set >= char_to_set2) {
            return RegexParsingError.InvalidRange;
        }
        return .{.literal = .{ .range = .{ .character_min = char_to_set, .character_max = char_to_set2 } }, .negated = false}; // If range is found, make range node.
    }
    return .{.literal = .{ .generic = char_to_set}, .negated = false}; // If range is found, make range node.
}

pub fn printRegexAST(out_interface: anytype, ast: RegexAST) !void {
    try printRegexASTRecursive(out_interface, ast, 0);
}

fn printRegexLiteral(out_interface: anytype, lit: RegexLiteralType) !void {
    switch(lit.literal) {
        .generic => |gen_lit| {
            var buf: [2]u8 = undefined;
            if (gen_lit == '\n') {
                buf[0] = '\\';
                buf[1] = 'n';
            } else if (gen_lit == '\t') {
                buf[0] = '\\';
                buf[1] = 't';
            } else if (gen_lit == '\r') {
                buf[0] = '\\';
                buf[1] = 'r';
            } else {
                buf[0] = gen_lit;
                buf[1] = 0;
            }
            try out_interface.print("LITERAL(char = {s})\n", .{ buf });
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
            try out_interface.print("LITERAL(char = {s})\n", .{@tagName(lit.literal)});
        },
    }
}

fn printRegexASTRecursive(out_interface: anytype, ast: *const RegexASTInternal, recursion_level: usize) !void {
    for (0..recursion_level) |_| {
        try out_interface.print("\t", .{});
    }
    switch (ast.*) {
        .literal => |lit| {
            try printRegexLiteral(out_interface, lit);
        },
        .repetition => |rep| {
            switch (rep.reps.max) {
                .bounded => {
                    try out_interface.print("REPETITION(min = {}, max = {}, type = {s})\n", .{ rep.reps.min, rep.reps.max.bounded, @tagName(rep.rep_type) });
                },
                .unbounded => {
                    try out_interface.print("REPETITION(min = {}, max = inf, type = {s})\n", .{ rep.reps.min, @tagName(rep.rep_type) });
                },
            }
            try printRegexASTRecursive(out_interface, rep.child, recursion_level + 1);
        },
        .alternation => |alt| {
            try out_interface.print("ALTERNATION()\n", .{});
            for (0..alt.parts.len) |i| {
                try printRegexASTRecursive(out_interface, alt.parts[i], recursion_level + 1);
            }
        },
        .group => |grp| {
            try out_interface.print("GROUP(id = {?}, type = {s}.", .{grp.id, @tagName(grp.group_data)});
            switch(grp.group_data) {
                .capturing => {
                    try out_interface.print("{s})\n", .{@tagName(grp.group_data.capturing)});
                },
                .non_capturing => {
                    try out_interface.print("{s})\n", .{@tagName(grp.group_data.non_capturing)});
                },
            }
            try printRegexASTRecursive(out_interface, grp.expr, recursion_level + 1);
        },
        .concatenation => |concat| {
            try out_interface.print("CONCATENATION()\n", .{});
            for (0..concat.parts.len) |i| {
                try printRegexASTRecursive(out_interface, concat.parts[i], recursion_level + 1);
            }
        },
        .class => |classItem| {
            try out_interface.print("CLASS(negated = {})\n", .{classItem.negated});
            for (0..classItem.items.len) |i| {
                for (0..recursion_level+1) |_| {
                    try out_interface.print("\t", .{});
                }
                try printRegexLiteral(out_interface, classItem.items[i]);
            }
        },
        .epsilon => {
            try out_interface.print("EPSILON()\n", .{});
        },
    }
}

pub fn destroyRegexPattern(allocator: anytype, pattern: RegexAST) !void {
    switch (pattern.*) {
        .literal => {},
        .alternation => |alt| {
            for (alt.parts) |item| {
                try destroyRegexPattern(allocator, item);
            }
            allocator.free(alt.parts);
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try destroyRegexPattern(allocator, item);
            }
            allocator.free(concat.parts);
        },
        .group => |grp| {
            try destroyRegexPattern(allocator, grp.expr);
        },
        .repetition => |rep| {
            try destroyRegexPattern(allocator, rep.child);
        },
        .class => |classItem| {
            allocator.free(classItem.items);
        },
        .epsilon => {
            return;
        }, // Epsilons contain no data and are always the same. Uses a single element and should not be freed.
    }
    allocator.destroy(pattern);
}
