//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const RegexPattern = RegexAST;

const RegexAST = union(enum) { // Tagged union for node type.
    literal: struct{ // Generic single characters.
        metacharacter: bool,
        character: u8,
    },
    range: struct { // For ranges within char classes. Cannot contain metacharacters.
        character_min: u8,
        character_max: u8,
    },
    concatenation: []*RegexAST, // Operation chaining two characters together. Used for grouping
    alternation: []*RegexAST, // Same as concatenation but semantically different and in a higher order function.
    repetition: struct { // Parent node to another node constructed by a quantifier.
        child: *RegexAST,
        reps_min: usize,
        reps_max: usize,
    },
    class: struct { // Character class.
        items: []*RegexAST,
        negated: bool,
    },
    epsilon: struct{}, // Generic empty node.
};

const RegexParsingError = error {
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
    result.* = .{.alternation = try allocator.alloc(*RegexAST, 2)}; // Start parsing alternations first, and assume 2 alternations minimum.
    if (str_to_parse[i.*] == '|' or str_to_parse[i.*] == ')') { // Handle epsilon as the first alternation argument.
        result.alternation[0] = try allocator.create(RegexAST);
        result.alternation[0].* = .{.epsilon = .{}};
    } else { // If not an epsilon, just parse the first alternation as a regular term.
        result.alternation[0] = try parseRegexTerm(allocator, str_to_parse, i);
    }
    var alternationCount: usize = 1;
    while (i.* < str_to_parse.len and str_to_parse[i.*] == '|') { // Parse through pipes as arguments.
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            break;
        }
        if (str_to_parse[i.*] == ')') { // Handle epsilon as the last alternation argument.
            result.alternation[alternationCount] = try allocator.create(RegexAST);
            result.alternation[alternationCount].* = .{.epsilon = .{}};
            alternationCount += 1;
            break;
        }
        if (alternationCount >= result.alternation.len) { // Resize alternations array as needed.
            result.alternation = try allocator.realloc(result.alternation, result.alternation.len * 2);
        }
        result.alternation[alternationCount] = try parseRegexTerm(allocator, str_to_parse, i); // Handle generic terms in alternation not caught by edge cases.
        alternationCount += 1;
    }
    if (alternationCount == 1) { // Remove the alternation if it does not alternate anything.
        const result_temp = result.alternation[0];
        allocator.free(result.alternation);
        allocator.destroy(result);
        return result_temp;
    }
    result.alternation = try allocator.realloc(result.alternation, alternationCount); // Trim the alternations array to prevent garbage data pointer access.
    return result;
}

fn parseRegexTerm(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    var result = try allocator.create(RegexAST);
    result.* = .{.concatenation = try allocator.alloc(*RegexAST, 2)}; // Assume 2 concatenations minimum.
    result.concatenation[0] = try parseRegexFactor(allocator, str_to_parse, i); // Parse initial factor.
    var concatenationCount: usize = 1;
    while(i.* < str_to_parse.len and str_to_parse[i.*] != '|' and str_to_parse[i.*] != ')') { // If character pointed to is handled by expr or factor, break.
        if (concatenationCount >= result.concatenation.len) { // Resize concatenation array as needed.
            result.concatenation = try allocator.realloc(result.concatenation, result.concatenation.len * 2);
        }
        result.concatenation[concatenationCount] = try parseRegexFactor(allocator, str_to_parse, i); // Add next factor to concatenation.
        concatenationCount += 1;
    }
    if (concatenationCount == 1) { // Remove concatenation node when nothing is concatenated.
        const result_temp = result.concatenation[0];
        allocator.free(result.concatenation);
        allocator.destroy(result);
        return result_temp;
    }
    result.concatenation = try allocator.realloc(result.concatenation, concatenationCount); // Trim the concatenation array to prevent garbage data pointer access.
    return result;
}

fn isDefaultMetacharacter(character: u8) bool {
    switch(character) {
        '$', '^', '.', '[' => {
            return true;
        },
        else => {
            return false;
        }
    }
}

fn isEscapedMetacharacter(character: u8) bool {
    switch(character) {
        'b', 'B', 'd', 'D', 's', 'S', 'w', 'W' => {
            return true;
        },
        else => {
            return false;
        }
    }
}

fn checkQuantifiers(atom: *RegexAST, allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    var count_min: usize = 0;
    var count_max: usize = 0;
    if (i.* >= str_to_parse.len) {
        return RegexParsingError.EndOfString;
    }
    switch(str_to_parse[i.*]) {
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
        }
    }
    const atom_parent = try allocator.create(RegexAST); // Construct repetition node and wrap atom in it.
    atom_parent.* = .{.repetition = .{.child = atom, .reps_min = count_min, .reps_max = count_max}};
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
        switch(str_to_parse[i.*]) {
            'n' => {
                charToSet = '\n';
            },
            't' => {
                charToSet = '\t';
            },
            'r' => {
                charToSet = '\r';
            },
            else => {}
        }
    }
    escaped = false;
    if (i.* < str_to_parse.len - 1  and str_to_parse[i.* + 1] == '-') { // Range syntax.
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
            switch(str_to_parse[i.*]) {
                'n' => {
                    charToSet2 = '\n';
                },
                't' => {
                    charToSet2 = '\t';
                },
                'r' => {
                    charToSet2 = '\r';
                },
                else => {}
            }
        }
        if (charToSet >= charToSet2) {
            return RegexParsingError.InvalidRange;
        }
        return .{.range = .{.character_min = charToSet, .character_max = charToSet2}}; // If range is found, make range node.
    }
    return .{.literal = .{.character = charToSet, .metacharacter = false}}; // If range is not found, make a literal node.
}

fn parseRegexCharClass(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    var result = try allocator.create(RegexAST);
    result.* = .{.class = .{ .items = try allocator.alloc(*RegexAST, 2), .negated = false}};
    if (str_to_parse[i.*] == '^') { // handle ^ negation edge case for first part char class.
        result.*.class.negated = true;
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            return RegexParsingError.EndOfString;
        }
    }
    result.class.items[0] = try allocator.create(RegexAST);
    result.class.items[0].* = try fetchCharOrRange(str_to_parse, i); // Parse the first item in the class.
    var classCount: usize = 1;
    i.* += 1;
    while (i.* < str_to_parse.len and (str_to_parse[i.*] != ']' or str_to_parse[i.* - 1] == '\\')) { // Parse until ending brace, excluding ending braces escaped with backslash.
        if (classCount >= result.class.items.len) { // Resize class item count accordingly.
            result.class.items = try allocator.realloc(result.class.items, result.class.items.len * 2);
        }
        result.class.items[classCount] = try allocator.create(RegexAST); // Grab the current item.
        result.class.items[classCount].* = try fetchCharOrRange(str_to_parse, i);
        classCount += 1;
        i.* += 1;
    }
    result.class.items = try allocator.realloc(result.class.items, classCount); // Trim the class items array to avoid garbage data pointer access.
    return result;
}

fn parseRegexFactor(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*RegexAST {
    if (i.* >= str_to_parse.len) return RegexParsingError.EndOfString;
    if (str_to_parse[i.*] == '(' and (i.* == 0 or str_to_parse[i.* - 1] != '\\')) { // Count ( as group starter except when escaped.
        i.* += 1; // Consume '('.
        const result = try parseRegexExpr(allocator, str_to_parse, i); // Parse expression within concat group.
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
        switch(str_to_parse[i.*]) {
            'n' => {
                charToSet = '\n';
            },
            't' => {
                charToSet = '\t';
            },
            'r' => {
                charToSet = '\r';
            },
            else => {}
        }
    }
    if (charToSet == '[' and !escaped) { // If character is a '[' and has not been escaped, then start parsing as a character class.
        allocator.destroy(atom);
        i.* += 1; // Consume the '['.
        atom = try parseRegexCharClass(allocator, str_to_parse, i);
    } else {
        atom.* = .{.literal = .{.character = charToSet, .metacharacter = metacharacter}};
    }
    i.* += 1; // Consume most recently used character, either the current token or the end of char class.
    if (i.* >= str_to_parse.len) return atom; // Only if at end of string, otherwise check for repetition.
    return try checkQuantifiers(atom, allocator, str_to_parse, i);
}

pub fn printRegexAST(out_interface: anytype, ast: *RegexAST) !void {
    try printRegexASTRecursive(out_interface, ast, 0);
}

fn printRegexASTRecursive(out_interface: anytype, ast: *RegexAST, recursionLevel: usize) !void {
    for (0..recursionLevel) |_| {
        try out_interface.print("\t", .{});
    }
    switch(ast.*) {
        .literal => |lit| {
            var buf: [2]u8 = undefined;
            if (lit.character == '\n')      { buf[0] = '\\'; buf[1] = 'n'; }
            else if (lit.character == '\t') { buf[0] = '\\'; buf[1] = 't'; }
            else if (lit.character == '\r') { buf[0] = '\\'; buf[1] = 'r'; }
            else                            { buf[0] = lit.character; buf[1] = 0; }
            try out_interface.print("LITERAL(char = {s}, metachar = {})\n", .{buf, lit.metacharacter});
        },
        .range => |range| {
            var buf: [2]u8 = undefined;
            var buf2: [2]u8 = undefined;
            if (range.character_min == '\n')        { buf[0] = '\\'; buf[1] = 'n'; }
            else if (range.character_min == '\t')   { buf[0] = '\\'; buf[1] = 't'; }
            else if (range.character_min == '\r')   { buf[0] = '\\'; buf[1] = 'r'; }
            else                                    { buf[0] = range.character_min; buf[1] = 0; }
            if (range.character_max == '\n')        { buf2[0] = '\\'; buf2[1] = 'n'; }
            else if (range.character_max == '\t')   { buf2[0] = '\\'; buf2[1] = 't'; }
            else if (range.character_max == '\r')   { buf2[0] = '\\'; buf2[1] = 'r'; }
            else                                    { buf2[0] = range.character_max; buf2[1] = 0; }
            try out_interface.print("RANGE(min = {s}, max = {s})\n", .{buf, buf2});
        },
        .repetition => |rep| {
            try out_interface.print("REPETITION(min = {}, max = {})\n", .{rep.reps_min, rep.reps_max});
            try printRegexASTRecursive(out_interface, rep.child, recursionLevel + 1);
        },
        .alternation => |alt| {
            try out_interface.print("ALTERNATION()\n", .{});
            for (0..alt.len) |i| {
                try printRegexASTRecursive(out_interface, alt[i], recursionLevel + 1);
            }
        },
        .concatenation => |concat| {
            try out_interface.print("CONCATENATION()\n", .{});
            for (0..concat.len) |i| {
                try printRegexASTRecursive(out_interface, concat[i], recursionLevel + 1);
            }
        },
        .class => |classItem| {
            try out_interface.print("CLASS(negated = {})\n", .{classItem.negated});
            for (0..classItem.items.len) |i| {
                try printRegexASTRecursive(out_interface, classItem.items[i], recursionLevel + 1);
            }
        },
        .epsilon => |_| {
            try out_interface.print("EPSILON()\n", .{});
        }
    }
}

