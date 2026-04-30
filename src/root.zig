//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const RegexPattern = *const RegexAST;

const RegexAST = union(enum) { // Tagged union for node type.
    literal: struct { // Generic single characters.
        metacharacter: bool,
        character: u8,
    },
    range: struct { // For ranges within char classes. Cannot contain metacharacters.
        character_min: u8,
        character_max: u8,
    },
    concatenation: struct {
        parts: []*RegexAST, // Operation chaining two characters together.
    },
    alternation: struct{
        parts: []*RegexAST,
    }, // Same as concatenation but semantically different and in a higher order function.
    group: struct {
        expr: *RegexAST,
        capturing: bool,
        id: usize,
        group_type: enum {
            regular,
            lookahead,
            lookbehind
        },
    },
    repetition: struct { // Parent node to another node constructed by a quantifier.
        child: *RegexAST,
        reps_min: usize,
        reps_max: usize,
        possessive: bool,
    },
    class: struct { // Character class.
        items: []*RegexAST,
        negated: bool,
    },
    epsilon: void, // Generic empty node.
};

var EPSILON_UNIT: RegexAST = .epsilon; // Generic epsilon copy used everywhere; contains no data.

pub const RegexParsingError = error{
    TokenNotFound,
    EndOfString,
    InvalidRange,
};

pub fn compileRegex(allocator: anytype, str_to_parse: []const u8) anyerror!*RegexAST {
    var i: usize = 0;
    return parseRegexExpr(allocator, str_to_parse, &i);
}

fn parseRegexExpr(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    var result = try allocator.create(RegexAST);
    var resultList = try std.ArrayList(*RegexAST).initCapacity(allocator, 1);
    defer {
        resultList.deinit(allocator);
    }
    errdefer {
        for (resultList.items) |item| {
            destroyRegexPattern(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    if (str_to_parse[i.*] == '|' or str_to_parse[i.*] == ')') { // Handle epsilon as the first alternation argument.
        try resultList.append(allocator, &EPSILON_UNIT);
    } else { // If not an epsilon, just parse the first alternation as a regular term.
        try resultList.append(allocator, try parseRegexTerm(allocator, str_to_parse, i));
    }
    while (i.* < str_to_parse.len and str_to_parse[i.*] == '|') { // Parse through pipes as arguments.
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            break;
        }
        if (str_to_parse[i.*] == ')') { // Handle epsilon as the last alternation argument.
            try resultList.append(allocator, &EPSILON_UNIT);
            break;
        }
        try resultList.append(allocator, try parseRegexTerm(allocator, str_to_parse, i)); // Handle generic terms in alternation not caught by edge cases.
    }
    const listSlice = try resultList.toOwnedSlice(allocator);
    result.* = .{ .alternation = .{.parts = listSlice } }; // Start parsing alternations first, and assume 2 alternations minimum.
    if (listSlice.len == 1) {
        allocator.destroy(result);
        result = listSlice[0];
        allocator.free(listSlice);
    }
    return result;
}

fn parseRegexTerm(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    var result = try allocator.create(RegexAST);
    var resultList = try std.ArrayList(*RegexAST).initCapacity(allocator, 1);
    defer {
        resultList.deinit(allocator);
    }
    errdefer {
        for (resultList.items) |item| {
            destroyRegexPattern(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    try resultList.append(allocator, try parseRegexFactor(allocator, str_to_parse, i));
    while (i.* < str_to_parse.len and str_to_parse[i.*] != '|' and str_to_parse[i.*] != ')') { // If character pointed to is handled by expr or factor, break.
        try resultList.append(allocator, try parseRegexFactor(allocator, str_to_parse, i));
    }
    const listSlice = try resultList.toOwnedSlice(allocator);
    result.* = .{ .concatenation = .{.parts = listSlice} };
    if (listSlice.len == 1) {
        allocator.destroy(result);
        result = listSlice[0];
        allocator.free(listSlice);
    }
    return result;
}

fn parseRegexCharClass(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    const result = try allocator.create(RegexAST);
    var resultList = try std.ArrayList(*RegexAST).initCapacity(allocator, 1);
    var negated: bool = false;
    defer {
        resultList.deinit(allocator);
    }
    errdefer {
        for (resultList.items) |item| {
            destroyRegexPattern(allocator, item) catch @panic("Cant free AST after error!");
        }
        allocator.destroy(result);
    }
    if (str_to_parse[i.*] == '^') { // handle ^ negation edge case for first part char class.
        negated = true;
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            return RegexParsingError.EndOfString;
        }
    }
    var item = try allocator.create(RegexAST);
    item.* = try fetchCharOrRange(str_to_parse, i); // Parse the first item in the class.
    try resultList.append(allocator, item);
    i.* += 1; // Be careful if new code is added here, could cause underflow with i.* - 1.
    while (i.* < str_to_parse.len and (str_to_parse[i.*] != ']' or str_to_parse[i.* - 1] == '\\')) { // Parse until ending brace, excluding ending braces escaped with backslash.
        item = try allocator.create(RegexAST);
        item.* = try fetchCharOrRange(str_to_parse, i); // Parse the first item in the class.
        try resultList.append(allocator, item);
        i.* += 1;
    }
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    const listSlice = try resultList.toOwnedSlice(allocator);
    result.* = .{ .class = .{ .items = listSlice, .negated = negated } };
    return result;
}

fn parseRegexFactor(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    if (str_to_parse[i.*] == '(' and (i.* == 0 or str_to_parse[i.* - 1] != '\\')) { // Count ( as group starter except when escaped.
        i.* += 1; // Consume '('.
        var result: *RegexAST = undefined;
        if (false) {          // if lookahead peeked
            result = undefined;               // parse lookahead here with special logic.
        } else {
            result = try allocator.create(RegexAST);
            result.* = .{.group = .{.expr = try parseRegexExpr(allocator, str_to_parse, i), .capturing = true, .id = 0, .group_type = .regular}};  // Parse expression within concat group.
        }
        if (i.* >= str_to_parse.len or str_to_parse[i.*] != ')') {
            return RegexParsingError.TokenNotFound;
        }
        i.* += 1; // consume ')'
        if (i.* < str_to_parse.len) { // Don't check quantifiers when ) is at the end of the string.
            return try checkQuantifiers(result, allocator, str_to_parse, i);
        } else {
            return result;
        }
    }
    var atom = try allocator.create(RegexAST);
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
    var charToSet: u8 = str_to_parse[i.*]; // Grab character and set value based on escape sequence.
    if (escaped) {
        switch (str_to_parse[i.*]) {
            'n' => {
                charToSet = '\n';
            },
            't' => {
                charToSet = '\t';
            },
            'r' => {
                charToSet = '\r';
            },
            else => {},
        }
    }
    if (charToSet == '[' and !escaped) { // If character is a '[' and has not been escaped, then start parsing as a character class.
        allocator.destroy(atom);
        i.* += 1; // Consume the '['.
        atom = try parseRegexCharClass(allocator, str_to_parse, i);
    } else {
        atom.* = .{ .literal = .{ .character = charToSet, .metacharacter = metacharacter } };
    }
    i.* += 1; // Consume most recently used character, either the current token or the end of char class.
    if (i.* >= str_to_parse.len) return atom; // Only if at end of string, otherwise check for repetition.
    return try checkQuantifiers(atom, allocator, str_to_parse, i);
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

fn checkQuantifiers(atom: *RegexAST, allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    var count_min: usize = 0;
    var count_max: usize = 0;
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    switch (str_to_parse[i.*]) {
        '*' => {
            count_min = 0;
            count_max = std.math.maxInt(usize);
            i.* += 1;
        },
        '+' => {
            count_min = 1;
            count_max = std.math.maxInt(usize);
            i.* += 1;
        },
        '?' => {
            count_min = 0;
            count_max = 1;
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
                count_max = count_min;
            } else {
                i.* += 1;
                if (i.* >= str_to_parse.len) {
                    return RegexParsingError.EndOfString;
                }
                if (str_to_parse[i.*] == '}') { // If comma is encountered but no ending number is foumd, then max is the largest possible int.
                    count_max = std.math.maxInt(usize);
                } else {
                    const num_slice_index_max = i.* + (std.mem.indexOfNone(u8, str_to_parse[i.*..], "0123456789") orelse str_to_parse.len - i.*); // Same arithmetic as with min.
                    count_max = try std.fmt.parseUnsigned(usize, str_to_parse[i.*..num_slice_index_max], 10);
                    i.* = num_slice_index_max;
                }
            }
            if (i.* >= str_to_parse.len or str_to_parse[i.*] != '}') {
                return RegexParsingError.TokenNotFound;
            }
            i.* += 1;
        },
        else => { // If no quantifier is found, do not wrap in repetition.
            return atom;
        },
    }
    var possessive: bool = false;
    if (i.* < str_to_parse.len and str_to_parse[i.*] == '+') {
        possessive = true;
        i.* += 1; // Consume the possessive +.
    }
    const atom_parent = try allocator.create(RegexAST); // Construct repetition node and wrap atom in it.
    atom_parent.* = .{ .repetition = .{ .child = atom, .reps_min = count_min, .reps_max = count_max, .possessive = possessive } };
    return atom_parent;
}

fn fetchCharOrRange(str_to_parse: []const u8, i: *usize) anyerror!RegexAST { // For use in character class compilation to tokenize with '-' syntax awareness.
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') {
        i.* += 1; // Consume backslash.
        if (i.* >= str_to_parse.len) {
            return RegexParsingError.EndOfString;
        }
        escaped = true;
    }
    var charToSet: u8 = str_to_parse[i.*];
    if (escaped) {
        switch (str_to_parse[i.*]) {
            'n' => {
                charToSet = '\n';
            },
            't' => {
                charToSet = '\t';
            },
            'r' => {
                charToSet = '\r';
            },
            else => {},
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
        var charToSet2: u8 = str_to_parse[i.*]; // Grab character after -.
        if (escaped) {
            switch (str_to_parse[i.*]) {
                'n' => {
                    charToSet2 = '\n';
                },
                't' => {
                    charToSet2 = '\t';
                },
                'r' => {
                    charToSet2 = '\r';
                },
                else => {},
            }
        }
        if (charToSet >= charToSet2) {
            return RegexParsingError.InvalidRange;
        }
        return .{ .range = .{ .character_min = charToSet, .character_max = charToSet2 } }; // If range is found, make range node.
    }
    return .{ .literal = .{ .character = charToSet, .metacharacter = false } }; // If range is not found, make a literal node.
}

pub fn printRegexAST(out_interface: anytype, ast: RegexPattern) !void {
    try printRegexASTRecursive(out_interface, ast, 0);
}

fn printRegexASTRecursive(out_interface: anytype, ast: *const RegexAST, recursionLevel: usize) !void {
    for (0..recursionLevel) |_| {
        try out_interface.print("\t", .{});
    }
    switch (ast.*) {
        .literal => |lit| {
            var buf: [2]u8 = undefined;
            if (lit.character == '\n') {
                buf[0] = '\\';
                buf[1] = 'n';
            } else if (lit.character == '\t') {
                buf[0] = '\\';
                buf[1] = 't';
            } else if (lit.character == '\r') {
                buf[0] = '\\';
                buf[1] = 'r';
            } else {
                buf[0] = lit.character;
                buf[1] = 0;
            }
            try out_interface.print("LITERAL(char = {s}, metachar = {})\n", .{ buf, lit.metacharacter });
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
            try out_interface.print("RANGE(min = {s}, max = {s})\n", .{ buf, buf2 });
        },
        .repetition => |rep| {
            try out_interface.print("REPETITION(min = {}, max = {}, possessive = {})\n", .{ rep.reps_min, rep.reps_max, rep.possessive });
            try printRegexASTRecursive(out_interface, rep.child, recursionLevel + 1);
        },
        .alternation => |alt| {
            try out_interface.print("ALTERNATION()\n", .{});
            for (0..alt.parts.len) |i| {
                try printRegexASTRecursive(out_interface, alt.parts[i], recursionLevel + 1);
            }
        },
        .group => |grp| {
            try out_interface.print("GROUP(capturing = {}, id = {}, type = {s})\n", .{grp.capturing, grp.id, @tagName(grp.group_type)});
            try printRegexASTRecursive(out_interface, grp.expr, recursionLevel + 1);
        },
        .concatenation => |concat| {
            try out_interface.print("CONCATENATION()\n", .{});
            for (0..concat.parts.len) |i| {
                try printRegexASTRecursive(out_interface, concat.parts[i], recursionLevel + 1);
            }
        },
        .class => |classItem| {
            try out_interface.print("CLASS(negated = {})\n", .{classItem.negated});
            for (0..classItem.items.len) |i| {
                try printRegexASTRecursive(out_interface, classItem.items[i], recursionLevel + 1);
            }
        },
        .epsilon => {
            try out_interface.print("EPSILON()\n", .{});
        },
    }
}

pub fn destroyRegexPattern(allocator: anytype, pattern: RegexPattern) !void {
    switch (pattern.*) {
        .literal => {},
        .range => {},
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
            for (classItem.items) |item| {
                try destroyRegexPattern(allocator, item);
            }
            allocator.free(classItem.items);
        },
        .epsilon => {
            return;
        }, // Epsilons contain no data and are always the same. Uses a single element and should not be freed.
    }
    allocator.destroy(pattern);
}
