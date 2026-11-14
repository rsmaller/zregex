const std = @import("std");
const zregex = @import("root.zig");
const ascii_assertion = @import("ascii_assertion.zig");
const type_reflection = @import("type_reflection.zig");
const core_types = @import("core_types.zig");
const repetition_types = @import("repetition_types.zig");
const ast_types = @import("ast_types.zig");
const ASTNode = ast_types.ASTNode;
const ScanContext = @import("scanner.zig");

pub fn compileToAST(allocator: anytype, str_to_parse: []const u8) !*ASTNode {
    try ascii_assertion.assert_ascii_string(str_to_parse);
    var scanner: ScanContext = .init(str_to_parse);
    var ast = if (str_to_parse.len > 0) (try parseExpr(allocator, &scanner)) else try ASTNode.create(allocator, .epsilon);
    errdefer {
        ast.deinit(allocator);
    }
    if (scanner.ptr() != str_to_parse.len) {
        return core_types.ParsingError.EndOfString;
    }
    return ast;
}

/// The main parsing function which handles alternation syntax.
fn parseExpr(allocator: anytype, scanner: *ScanContext) anyerror!*ASTNode {
    const len = scanner.strlen();
    if (scanner.ptr() >= len) return core_types.ParsingError.EndOfString;
    var result = try ASTNode.create(allocator, .failed_parse);
    errdefer result.deinit(allocator);
    var result_list = try std.ArrayList(*ASTNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            item.deinit(allocator);
        }
    }
    var currentTerm: *ASTNode = undefined;

    // Parsing logic for alternations.
    // -------------------
    if (scanner.scanSeeCharacter('|') or scanner.scanSeeCharacter(')')) { // Handle epsilon as the first alternation argument.
        currentTerm = try ASTNode.create(allocator, .epsilon);
    } else { // If not an epsilon, just parse the first alternation as a regular term. This is where the parsing defaults when no alternations are encountered.
        currentTerm = try parseTerm(allocator, scanner);
    }
    try result_list.append(allocator, currentTerm);
    while (scanner.ptr() < len and scanner.scanHaveCharacter('|')) { // Parse through pipes as arguments.
        if (scanner.ptr() >= len or scanner.scanSeeCharacter(')')) { // Handle epsilon as the last alternation argument.
            try result_list.append(allocator, try ASTNode.create(allocator, .epsilon));
            break;
        }
        try result_list.append(allocator, try parseTerm(allocator, scanner)); // Handle generic terms in alternation not caught by edge cases.
    }
    // -------------------
    
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{ .alternation = .{ .parts = list_slice } }; // Start parsing alternations first, and assume 2 alternations minimum.
    if (list_slice.len == 1) { // Optimize away an alternation of only 1 element.
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

/// Parsing function which handles concatenation syntax.
fn parseTerm(allocator: anytype, scanner: *ScanContext) anyerror!*ASTNode {
    const len = scanner.strlen();
    if (scanner.ptr() >= len) return core_types.ParsingError.EndOfString;
    var result = try ASTNode.create(allocator, .failed_parse);
    errdefer result.deinit(allocator);
    var result_list = try std.ArrayList(*ASTNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            item.deinit(allocator);
        }
    }
    
    // Parsing logic for concatenations.
    // -------------------
    var currentFactor = try parseFactor(allocator, scanner);
    try result_list.append(allocator, currentFactor);
    while (scanner.ptr() < len and !scanner.scanSeeCharacter('|') and !scanner.scanSeeCharacter(')')) { // If character pointed to is handled by expr or factor, break.
        currentFactor = try parseFactor(allocator, scanner);
        try result_list.append(allocator, currentFactor);
    }
    // -------------------

    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{ .concatenation = .{ .parts = list_slice } };
    if (list_slice.len == 1) { // Destroy a concatenation of only 1 element; node is meant to sequentially link 2 or more elements together.
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

/// Parsing function which parses groups, character classes, or regular characters (atoms) and their postfix quantifiers.
fn parseFactor(allocator: anytype, scanner: *ScanContext) anyerror!*ASTNode {
    const len = scanner.strlen();
    if (scanner.ptr() >= len) return core_types.ParsingError.EndOfString;

    // Parsing logic for parenthesized groups.
    // -------------------
    if (scanner.scanSeeCharacter('(') and !scanner.scanSeeIsEscaped()) {
        try scanner.scanConsumeCharacter('(');
        const result: *ASTNode = try parseGroupExpr(allocator, scanner);
        errdefer result.deinit(allocator);
        try scanner.scanConsumeCharacter(')');
        if (scanner.ptr() < len) { // Don't check quantifiers when ) is at the end of the string.
            return try parseQuantifiers(result, allocator, scanner);
        } else {
            return result;
        }
    }
    // -------------------

    // Parsing logic for character classes, literals, and postfix quantifiers. 
    // -------------------
    var escaped: bool = false;
    if (scanner.scanHaveEscape()) {
        if (scanner.ptr() >= len) {
            return core_types.ParsingError.EndOfString;
        }
        escaped = true;
    }
    const metacharacter = isMetaCharacter(try scanner.scanReturnCurrentCharacter(), escaped);
    const char_to_set = try simplifiedEscapeCharacter(scanner, escaped);
    
    var atom: ?*ASTNode = null;
    errdefer {
        if (atom) |_| atom.?.deinit(allocator);
    }
    if (char_to_set == '[' and !escaped) { // If character is a '[' and has not been escaped, then start parsing as a character class.
        try scanner.scanConsumeCharacter('[');
        atom = try parseCharClass(allocator, scanner);
        try scanner.scanConsumeCharacter(']');
    } else {
        atom = try parseAtom(allocator, scanner, char_to_set, metacharacter);
        try scanner.scanConsumeAnyCharacter();
    }
    if (scanner.ptr() >= len) return atom.?; // Only if at end of string, otherwise check for repetition.
    return try parseQuantifiers(atom.?, allocator, scanner);
    // -------------------
}

/// Parsing function which handles groupings.
fn parseGroupExpr(allocator: anytype, scanner: *ScanContext) anyerror!*ASTNode {
    const len = scanner.strlen();
    if (scanner.ptr() >= len) return core_types.ParsingError.EndOfString;
    const result: *ASTNode = try ASTNode.create(allocator, .failed_parse);
    errdefer result.deinit(allocator);
    if (scanner.scanSeeCharacter('?')) {
        if (scanner.scanHaveString("?<=")) {
            const expr = try parseExpr(allocator, scanner); // Changed to initialize in local variable to prevent defer free segfault at 0x0. Possible compiler bug?
            result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .negated = false, .type = .{ .non_capturing = .{ .lookbehind = 0 } } } };
        } else if (scanner.scanHaveString("?<!")) {
            const expr = try parseExpr(allocator, scanner);
            result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .negated = true, .type = .{ .non_capturing = .{ .lookbehind = 0 } } } };
        } else if (scanner.scanHaveString("?<")) {
            try scanner.scanUnrollCharacter(); // Give back < for name scanner function.
            const name = try allocator.dupe(u8, try scanner.scanGroupName());
            errdefer allocator.free(name);
            const expr = try parseExpr(allocator, scanner);
            result.* = .{ .group = .{ .expr = expr, .name = name, .id = 0, .type = .{ .capturing = .generic }, .negated = false } };
        } else if (scanner.scanHaveString("?=")) {
            const expr = try parseExpr(allocator, scanner);
            result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .lookahead }, .negated = false } };
        } else if (scanner.scanHaveString("?!")) {
            const expr = try parseExpr(allocator, scanner);
            result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .lookahead }, .negated = true } };
        } else if (scanner.scanHaveString("?:")) {
            const expr = try parseExpr(allocator, scanner);
            result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .generic }, .negated = false } };
        } else if (scanner.scanHaveString("?>")) {
            const expr = try parseExpr(allocator, scanner);
            result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .atomic }, .negated = false } };
        } else { // ? found but no matching flag.
            return core_types.ParsingError.TokenNotFound;
        }
    } else { // If the group found is not marked with ?, parse as normal group.
        const expr = try parseExpr(allocator, scanner);
        result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .capturing = .generic }, .negated = false } };
    }
    if (!scanner.scanSeeCharacter(')')) {
        return core_types.ParsingError.EndOfString;
    }
    return result;
}

/// Parsing function which handles character classes.
fn parseCharClass(allocator: anytype, scanner: *ScanContext) anyerror!*ASTNode {
    if (scanner.ptr() >= scanner.strlen()) return core_types.ParsingError.EndOfString;
    var result_list = try std.ArrayList(ast_types.AtomNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    var negated: bool = false;
    if (scanner.scanHaveCharacter('^')) { // handle ^ negation edge case for first part char class.
        negated = true;
        if (scanner.ptr() >= scanner.strlen()) {
            return core_types.ParsingError.EndOfString;
        }
    }
    var item: ast_types.AtomNode = undefined;
    while (scanner.ptr() < scanner.strlen() and (!scanner.scanSeeCharacter(']') or scanner.scanSeeIsEscaped())) { // Parse until ending brace, excluding ending braces escaped with backslash.
        item = try scanner.scanClassAtom(); // Parse the first item in the class.
        if (scanner.ptr() >= scanner.strlen()) {
            return core_types.ParsingError.EndOfString;
        }
        try result_list.append(allocator, item);
    }
    if (scanner.ptr() >= scanner.strlen()) {
        return core_types.ParsingError.EndOfString;
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    const result = try allocator.create(ASTNode);
    result.* = .{ .class = .{ .items = list_slice, .negated = negated } };
    return result;
}

/// Parsing function which handles postfix quantifier operations on atom nodes (i.e. {1}, +, *, etc.)
fn parseQuantifiers(atom: *ASTNode, allocator: anytype, scanner: *ScanContext) anyerror!*ASTNode {
    var count_min: usize = undefined;
    var count_max: repetition_types.RepetitionBoundType = undefined;
    if (scanner.ptr() >= scanner.strlen()) {
        return core_types.ParsingError.EndOfString;
    }
    var repetition_container: repetition_types.RepetitionRangeType = undefined;
    switch (try scanner.scanReturnCurrentCharacter()) {
        '*' => {
            try scanner.scanConsumeCharacter('*');
            repetition_container = .{ .min = 0, .max = .unbounded };
        },
        '+' => {
            try scanner.scanConsumeCharacter('+');
            repetition_container = .{ .min = 1, .max = .unbounded };
        },
        '?' => {
            try scanner.scanConsumeCharacter('?');
            repetition_container = .{ .min = 0, .max = .{ .bounded = 1 } };
        },
        '{' => { // Permissive parsing on {,}
            try scanner.scanConsumeCharacter('{');
            if (scanner.ptr() >= scanner.strlen()) {
                return core_types.ParsingError.EndOfString;
            }
            if (scanner.scanSeeCharacter(',')) { // If no number is present before the , then the min is 0.
                count_min = 0;
            } else {
                count_min = try scanner.scanNumeric();
                if (scanner.ptr() >= scanner.strlen()) {
                    return core_types.ParsingError.EndOfString;
                }
            }
            if (!scanner.scanSeeCharacter(',')) { // If comma is not encountered, it is one number so min and max should be the same.
                count_max = .{ .bounded = count_min };
                try scanner.scanConsumeCharacter('}');
            } else {
                try scanner.scanConsumeCharacter(',');
                if (scanner.ptr() >= scanner.strlen()) {
                    return core_types.ParsingError.EndOfString;
                }
                if (scanner.scanHaveCharacter('}')) { // If comma is encountered but no ending number is found, then max is the largest possible int.
                    count_max = .unbounded;
                } else {
                    count_max = .{ .bounded = try scanner.scanNumeric() };
                    try scanner.scanConsumeCharacter('}');
                }
            }
            repetition_container = .{ .min = count_min, .max = count_max };
        },
        else => { // If no quantifier is found, do not wrap in repetition.
            return atom;
        },
    }
    var rep_type: repetition_types.RepeaterType = .greedy; // Greedy, possessive, and lazy awareness.
    if (scanner.scanHaveCharacter('+')) {
        rep_type = .possessive;
    } else if (scanner.scanHaveCharacter('?')) {
        rep_type = .lazy;
    }
    const atom_parent = try ASTNode.createWithData(allocator, .{ .repetition = .{ .child = atom, .reps = repetition_container, .rep_type = rep_type } }); // Construct repetition node and wrap atom in it.
    return atom_parent;
}

/// Parses a single character which does not have a special syntactic function. Note that an escaped character, metacharacter or otherwise,
/// which meets this description is parsed here (i.e. \d, \n, a, ., etc.)
fn parseAtom(allocator: anytype, scanner: *ScanContext, char_to_set: u8, metacharacter: bool) anyerror!*ASTNode {
    var atom_result: ast_types.AtomNode = undefined;
    switch (metacharacter) {
        true => {
            switch (char_to_set) {
                'd' => {
                    atom_result = .{ .atom = .digit, .inverted = false };
                },
                'D' => {
                    atom_result = .{ .atom = .digit, .inverted = true };
                },
                's' => {
                    atom_result = .{ .atom = .whitespace, .inverted = false };
                },
                'S' => {
                    atom_result = .{ .atom = .whitespace, .inverted = true };
                },
                'w' => {
                    atom_result = .{ .atom = .word, .inverted = false };
                },
                'W' => {
                    atom_result = .{ .atom = .word, .inverted = true };
                },
                'b' => {
                    atom_result = .{ .atom = .word_boundary, .inverted = false };
                },
                'B' => {
                    atom_result = .{ .atom = .word_boundary, .inverted = true };
                },
                '^', 'A' => {
                    atom_result = .{ .atom = .start_anchor, .inverted = false };
                },
                '$', 'Z' => {
                    atom_result = .{ .atom = .end_anchor, .inverted = false };
                },
                '.' => {
                    atom_result = .{ .atom = .any, .inverted = false };
                },
                'k' => {
                    if (!scanner.scanSeeString("k<")) {
                        return core_types.ParsingError.InvalidGroupName;
                    }
                    // var z = scanner.str_ptr + 1; // Skip to <, start of name.
                    const prev_ptr = scanner.ptr();
                    try scanner.scanConsumeCharacter('k');
                    const name = try scanner.scanGroupName();
                    if (scanner.ptr() > prev_ptr) {
                        try scanner.scanUnrollCharacter(); // This method can scan backreferences, but it does not parse an entire unit.
                        // The parser expects a single consumable character after this function is called.
                    } else {
                        return core_types.ParsingError.TokenNotFound;
                    }
                    const name_alloc = try allocator.dupe(u8, name);
                    atom_result = .{ .atom = .{ .backref_name = name_alloc, }, .inverted = false };
 
                },
                '0'...'9' => { // Parse an ID backreference.
                    const prev_ptr = scanner.ptr();
                    const num = try scanner.scanNumeric();
                    if (scanner.ptr() > prev_ptr) {
                        try scanner.scanUnrollCharacter(); // This method can scan backreferences, but it does not parse an entire unit.
                        // The parser expects a single consumable character after this function is called.
                    } else {
                        return core_types.ParsingError.TokenNotFound;
                    }
                    atom_result = .{ .atom = .{ .backref_id = num }, .inverted = false };
                },
                '(', ')', '[', ']', '{', '}', '|', '+', '*', '?' => {
                    return core_types.ParsingError.TokenNotFound;
                },
                else => {
                    atom_result = .{ .atom = .{ .generic = char_to_set }, .inverted = false };
                },
            }
        },
        false => {
            atom_result = .{ .atom = .{ .generic = char_to_set }, .inverted = false };
        },
    }
    const result = try allocator.create(ASTNode);
    result.* = .{ .atom = atom_result };
    return result;
}

/// Flattens character sequences which escape to a single character value into that character.
fn simplifiedEscapeCharacter(scanner: *ScanContext, escaped: bool) !u8 {
    var char_to_set: u8 = try scanner.scanReturnCurrentCharacter();
    if (escaped) {
        switch (char_to_set) {
            'n' => {
                char_to_set = '\n';
            },
            't' => {
                char_to_set = '\t';
            },
            'r' => {
                char_to_set = '\r';
            },
            'f' => {
                char_to_set = 0x0C; // Zig does not support form feed character literals; this is the best way to represent it.
            },
            else => {},
        }
    }
    return char_to_set;
}

fn isMetaCharacter(character: u8, escaped: bool) bool {
    if (escaped) {
        return isEscapedMetacharacter(character);
    } else {
        return isNonEscapedMetacharacter(character);
    }
}

fn isNonEscapedMetacharacter(character: u8) bool {
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
        'A', 'b', 'B', 'd', 'D', 'k', 's', 'S', 'w', 'W', 'Z', '0'...'9' => {
            return true;
        },
        else => {
            return false;
        },
    }
}
