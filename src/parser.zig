const std = @import("std");
const zregex = @import("root.zig");
const type_reflection = @import("type_reflection.zig");
const core_types = @import("core_types.zig");
const repetition_types = @import("repetition_types.zig");
const ast_types = @import("ast_types.zig");
const scanner = @import("scanner.zig");

var EPSILON_UNIT: ast_types.ASTNode = .epsilon; // Generic epsilon copy used everywhere; contains no data.

pub fn compileToAST(allocator: anytype, str_to_parse: []const u8) !*ast_types.ASTNode {
    var i: usize = 0;
    var ast = if (str_to_parse.len > 0) (try parseExpr(allocator, str_to_parse, &i)) else &EPSILON_UNIT;
    errdefer {
        ast.deinit(allocator);
    }
    if (i != str_to_parse.len) {
        return core_types.ParsingError.EndOfString;
    }
    return ast;
}

fn parseExpr(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*ast_types.ASTNode {
    const len = str_to_parse.len;
    if (i.* >= len) return core_types.ParsingError.EndOfString;
    var result = try allocator.create(ast_types.ASTNode);
    errdefer result.deinit(allocator);
    result.* = .failed_parse;
    var result_list = try std.ArrayList(*ast_types.ASTNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            item.deinit(allocator);
        }
    }
    var currentTerm: *ast_types.ASTNode = undefined;
    if (str_to_parse[i.*] == '|' or str_to_parse[i.*] == ')') { // Handle epsilon as the first alternation argument.
        currentTerm = &EPSILON_UNIT;
    } else { // If not an epsilon, just parse the first alternation as a regular term.
        currentTerm = try parseTerm(allocator, str_to_parse, i);
    }
    try result_list.append(allocator, currentTerm);
    while (i.* < len and str_to_parse[i.*] == '|') { // Parse through pipes as arguments.
        i.* += 1;
        if (i.* >= len) {
            break;
        }
        if (str_to_parse[i.*] == ')') { // Handle epsilon as the last alternation argument.
            try result_list.append(allocator, &EPSILON_UNIT);
            break;
        }
        try result_list.append(allocator, try parseTerm(allocator, str_to_parse, i)); // Handle generic terms in alternation not caught by edge cases.
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{ .alternation = .{ .parts = list_slice } }; // Start parsing alternations first, and assume 2 alternations minimum.
    if (list_slice.len == 1) { // Optimize away an alternation of only 1 element.
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

fn parseTerm(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*ast_types.ASTNode {
    const len = str_to_parse.len;
    if (i.* >= len) return core_types.ParsingError.EndOfString;
    var result = try allocator.create(ast_types.ASTNode);
    errdefer result.deinit(allocator);
    result.* = .failed_parse;
    var result_list = try std.ArrayList(*ast_types.ASTNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    errdefer {
        for (result_list.items) |item| {
            item.deinit(allocator);
        }
    }
    var currentFactor = try parseFactor(allocator, str_to_parse, i);
    try result_list.append(allocator, currentFactor);
    while (i.* < len and str_to_parse[i.*] != '|' and str_to_parse[i.*] != ')') { // If character pointed to is handled by expr or factor, break.
        currentFactor = try parseFactor(allocator, str_to_parse, i);
        try result_list.append(allocator, currentFactor);
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    result.* = .{ .concatenation = .{ .parts = list_slice } };
    if (list_slice.len == 1) { // Destroy a concatenation of only 1 element; node is meant to sequentially link 2 or more elements together.
        allocator.destroy(result);
        result = list_slice[0];
        allocator.free(list_slice);
    }
    return result;
}

fn parseFactor(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*ast_types.ASTNode {
    const len = str_to_parse.len;
    if (i.* >= len) return core_types.ParsingError.EndOfString;
    if (str_to_parse[i.*] == '(' and (i.* == 0 or str_to_parse[i.* - 1] != '\\')) { // Count ( as group starter except when escaped.
        i.* += 1; // Consume '('.
        const result: *ast_types.ASTNode = try parseGroupExpr(allocator, str_to_parse, i);
        errdefer result.deinit(allocator);
        i.* += 1; // consume ')'
        if (i.* < len) { // Don't check quantifiers when ) is at the end of the string.
            return try parseQuantifiers(result, allocator, str_to_parse, i);
        } else {
            return result;
        }
    }
    var metacharacter: bool = undefined;
    var escaped: bool = false;
    if (str_to_parse[i.*] == '\\') { // Handle generic escape sequence vs non escaped.
        i.* += 1; // Consume backslash.
        if (i.* >= len) {
            return core_types.ParsingError.EndOfString;
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
    var atom: ?*ast_types.ASTNode = null;
    errdefer {
        if (atom) |_| atom.?.deinit(allocator);
    }
    if (char_to_set == '[' and !escaped) { // If character is a '[' and has not been escaped, then start parsing as a character class.
        i.* += 1; // Consume the '['.
        atom = try parseCharCLass(allocator, str_to_parse, i);
        i.* += 1; // Consume the ']'.
    } else {
        atom = try parseAtom(allocator, str_to_parse, i, char_to_set, metacharacter);
        i.* += 1; // Consume the last character of the leaf.
    }
    if (i.* >= len) return atom.?; // Only if at end of string, otherwise check for repetition.
    return try parseQuantifiers(atom.?, allocator, str_to_parse, i);
}

fn parseGroupExpr(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*ast_types.ASTNode {
    const len = str_to_parse.len;
    if (i.* >= len) return core_types.ParsingError.EndOfString;
    const result: *ast_types.ASTNode = try allocator.create(ast_types.ASTNode);
    result.* = .failed_parse;
    errdefer result.deinit(allocator);
    if (str_to_parse[i.*] == '?') {
        var lengthThreeLookaheadFound = true;
        if (i.* + 2 < len) { // Check for length 3 group markers.
            if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 3], "?<=")) {
                i.* += 3; // consume ?<=
                const expr = try parseExpr(allocator, str_to_parse, i); // Changed to initialize in local variable to prevent defer free segfault at 0x0. Possible compiler bug?
                result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .negated = false, .type = .{ .non_capturing = .{ .lookbehind = 0 } } } };
            } else if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 3], "?<!")) {
                i.* += 3; // consume ?<!
                const expr = try parseExpr(allocator, str_to_parse, i);
                result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .negated = true, .type = .{ .non_capturing = .{ .lookbehind = 0 } } } };
            } else if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 2], "?<")) {
                i.* += 1; // Consume '?'.
                const name = try allocator.dupe(u8, try scanner.scanGroupName(str_to_parse, i));
                errdefer allocator.free(name);
                const expr = try parseExpr(allocator, str_to_parse, i);
                result.* = .{ .group = .{ .expr = expr, .name = name, .id = 0, .type = .{ .capturing = .generic }, .negated = false } };
            } else {
                lengthThreeLookaheadFound = false;
            }
        }
        if (!lengthThreeLookaheadFound and i.* + 1 < len) { // Check length 2 lookahead flags if a longer length one was not found and it is safe to do so.
            if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 2], "?=")) {
                i.* += 2; // consume ?=
                const expr = try parseExpr(allocator, str_to_parse, i);
                result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .lookahead }, .negated = false } };
            } else if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 2], "?!")) {
                i.* += 2; // consume ?!
                const expr = try parseExpr(allocator, str_to_parse, i);
                result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .lookahead }, .negated = true } };
            } else if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 2], "?:")) {
                i.* += 2; // consume ?:
                const expr = try parseExpr(allocator, str_to_parse, i);
                result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .generic }, .negated = false } };
            } else if (std.mem.eql(u8, str_to_parse[i.* .. i.* + 2], "?>")) {
                i.* += 2; // consume ?>
                const expr = try parseExpr(allocator, str_to_parse, i);
                result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .non_capturing = .atomic }, .negated = false } };
            } else { // ? found but no matching flag.
                return core_types.ParsingError.TokenNotFound;
            }
        } else if (i.* + 2 >= len) { // If there is a flag start but no room for another character, emit an end of string error.
            return core_types.ParsingError.EndOfString;
        } else { // Assume the flag start is invalid.
            return core_types.ParsingError.TokenNotFound;
        }
    } else {
        const expr = try parseExpr(allocator, str_to_parse, i);
        result.* = .{ .group = .{ .expr = expr, .name = null, .id = 0, .type = .{ .capturing = .generic }, .negated = false } };
    }
    if (i.* >= len) { // Only need length check again if i is potentially incremented in parseExpr().
        return core_types.ParsingError.EndOfString;
    }
    if (str_to_parse[i.*] != ')') {
        return core_types.ParsingError.TokenNotFound;
    }
    return result;
}

fn parseCharCLass(allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*ast_types.ASTNode {
    if (i.* >= str_to_parse.len) return core_types.ParsingError.EndOfString;
    var result_list = try std.ArrayList(ast_types.AtomNode).initCapacity(allocator, 1);
    defer {
        result_list.deinit(allocator);
    }
    var negated: bool = false;
    if (str_to_parse[i.*] == '^') { // handle ^ negation edge case for first part char class.
        negated = true;
        i.* += 1;
        if (i.* >= str_to_parse.len) {
            return core_types.ParsingError.EndOfString;
        }
    }
    var item: ast_types.AtomNode = undefined;
    while (i.* < str_to_parse.len and (str_to_parse[i.*] != ']' or str_to_parse[i.* - 1] == '\\')) { // Parse until ending brace, excluding ending braces escaped with backslash.
        item = try scanner.scanClassAtom(str_to_parse, i); // Parse the first item in the class.
        try result_list.append(allocator, item);
        i.* += 1;
    }
    if (i.* >= str_to_parse.len) {
        return core_types.ParsingError.EndOfString;
    }
    const list_slice = try result_list.toOwnedSlice(allocator);
    const result = try allocator.create(ast_types.ASTNode);
    result.* = .{ .class = .{ .items = list_slice, .negated = negated } };
    return result;
}

fn parseQuantifiers(atom: *ast_types.ASTNode, allocator: anytype, str_to_parse: []const u8, i: *usize) anyerror!*ast_types.ASTNode {
    var count_min: usize = undefined;
    var count_max: repetition_types.RepetitionBoundType = undefined;
    if (i.* >= str_to_parse.len) {
        return core_types.ParsingError.EndOfString;
    }
    var repetition_container: repetition_types.RepetitionRangeType = undefined;
    switch (str_to_parse[i.*]) {
        '*' => {
            repetition_container = .{ .min = 0, .max = .unbounded };
            i.* += 1;
        },
        '+' => {
            repetition_container = .{ .min = 1, .max = .unbounded };
            i.* += 1;
        },
        '?' => {
            repetition_container = .{ .min = 0, .max = .{ .bounded = 1 } };
            i.* += 1;
        },
        '{' => { // Permissive parsing on {,}
            i.* += 1; // Skip past curly brace.
            if (i.* >= str_to_parse.len) {
                return core_types.ParsingError.EndOfString;
            }
            if (str_to_parse[i.*] == ',') { // If no number is present before the , then the min is 0.
                count_min = 0;
            } else {
                count_min = try scanner.scanNumeric(str_to_parse, i);
                if (i.* >= str_to_parse.len) {
                    return core_types.ParsingError.EndOfString;
                }
            }
            if (str_to_parse[i.*] != ',') { // If comma is not encountered, it is one number so min and max should be the same.
                count_max = .{ .bounded = count_min };
            } else {
                i.* += 1;
                if (i.* >= str_to_parse.len) {
                    return core_types.ParsingError.EndOfString;
                }
                if (str_to_parse[i.*] == '}') { // If comma is encountered but no ending number is found, then max is the largest possible int.
                    count_max = .unbounded;
                } else {
                    count_max = .{ .bounded = try scanner.scanNumeric(str_to_parse, i) };
                }
            }
            if (i.* >= str_to_parse.len or str_to_parse[i.*] != '}') {
                return core_types.ParsingError.TokenNotFound;
            }
            repetition_container = .{ .min = count_min, .max = count_max };
            i.* += 1;
        },
        else => { // If no quantifier is found, do not wrap in repetition.
            return atom;
        },
    }
    var rep_type: repetition_types.RepeaterType = .greedy;
    if (i.* < str_to_parse.len and str_to_parse[i.*] == '+') {
        rep_type = .possessive;
        i.* += 1; // Consume the possessive +.
    } else if (i.* < str_to_parse.len and str_to_parse[i.*] == '?') {
        rep_type = .lazy;
        i.* += 1; // Consume the lazy ?.
    }
    const atom_parent = try allocator.create(ast_types.ASTNode); // Construct repetition node and wrap atom in it.
    atom_parent.* = .{ .repetition = .{ .child = atom, .reps = repetition_container, .rep_type = rep_type } };
    return atom_parent;
}

fn parseAtom(allocator: anytype, str_to_parse: []const u8, i: *usize, char_to_set: u8, metacharacter: bool) anyerror!*ast_types.ASTNode {
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
                '^' => {
                    atom_result = .{ .atom = .start_anchor, .inverted = false };
                },
                '$' => {
                    atom_result = .{ .atom = .end_anchor, .inverted = false };
                },
                '.' => {
                    atom_result = .{ .atom = .any, .inverted = false };
                },
                '0'...'9' => { // Parse a backreference.
                    var z = i.*;
                    const num = try scanner.scanNumeric(str_to_parse, &z);
                    if (z > i.*) {
                        i.* = z - 1; // This method can scan backreferences, but it does not parse an entire unit.
                        // The parser expects a single consumable character after this function is called.
                    } else {
                        return core_types.ParsingError.TokenNotFound;
                    }
                    atom_result = .{ .atom = .{ .backref = num }, .inverted = false };
                },
                '(', ')', '[', ']', '{', '}', '|' => {
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
    const result = try allocator.create(ast_types.ASTNode);
    result.* = .{ .atom = atom_result };
    return result;
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
        'b', 'B', 'd', 'D', 's', 'S', 'w', 'W', '0'...'9' => {
            return true;
        },
        else => {
            return false;
        },
    }
}
