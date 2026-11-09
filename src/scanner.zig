const std = @import("std");
const core_types = @import("core_types.zig");
const ast_types = @import("ast_types.zig");

// Scanner context.
string: []const u8,
str_ptr: usize,


pub fn init(input_string: []const u8) @This() {
    return .{
        .string = input_string,
        .str_ptr = 0,
    };  
}

// Helper methods to make parsing bounds checks easier.
/// Returns the input position pointer.
pub fn ptr(self: *const @This()) usize {
    return self.str_ptr;
}

/// Returns the length of the input string.
pub fn strlen(self: *const @This()) usize {
    return self.string.len;
}

// Scanning functions will look through the target string and increment the string pointer; they do not consider parsing-level grammar 
// and therefore do not heap allocate any AST nodes. These functions only return atom node values, if any.

// -------------------- Non-error-capable Functions --------------------

/// Returns a boolean representing whether a character is present in the input string.
pub fn scanSeeCharacter(self: *@This(), character: u8) bool {
    return self.scanHasMoreCharacters() and self.string[self.str_ptr] == character; // Does not use helper function because this function should not error; only consuming functions should.
}

/// Returns a boolean representing whether a character is present in the input string and increments past the character if present.
pub fn scanHaveCharacter(self: *@This(), character: u8) bool {
    const result = self.scanSeeCharacter(character);
    if (result) {
        self.str_ptr += 1; // Consume character.
    }
    return result;
}

/// Returns a boolean representing whether a substring is present in the input string.
pub fn scanSeeString(self: *@This(), substring: []const u8) bool {
    if (self.scanHasAtLeastMoreCharacters(substring.len)) {
        return std.mem.eql(u8, self.string[self.str_ptr..self.str_ptr+substring.len], substring[0..substring.len]);      
    }
    else return false;
}

/// Returns a boolean representing whether a substring is present in the input string and increments past the substring if present.
pub fn scanHaveString(self: *@This(), substring: []const u8) bool {
    const result = self.scanSeeString(substring);
    if (result) {
        self.str_ptr += substring.len;
    }
    return result;
}

/// Scans the escaping backslash; merely a specialization of scanHaveCharacter.
pub fn scanHaveEscape(self: *@This()) bool {
    return self.scanHaveCharacter('\\');
}

/// Looks at the current character to see if it has been escaped; therefore it looks backwards.
pub fn scanSeeIsEscaped(self: *@This()) bool {
    return self.str_ptr > 0 and self.string[self.str_ptr - 1] == '\\';
}

/// Returns true if there are more characters available to scan and false otherwise. 
pub fn scanHasMoreCharacters(self: *@This()) bool {
    return self.ptr() < self.strlen();
}

/// Returns true if there are at least at_least number of characters left to consume. 
pub fn scanHasAtLeastMoreCharacters(self: *@This(), at_least: usize) bool {
    return self.ptr() + at_least <= self.strlen();
}

// -------------------- Error-capable Functions --------------------

/// Scans through the string and grabs a numeric component as a size value.
pub fn scanNumeric(self: *@This()) !usize {
    if (self.string[self.str_ptr] < '0' or self.string[self.str_ptr] > '9') {
        return core_types.ParsingError.TokenNotFound;
    }
    const num_slice_len = self.str_ptr + (std.mem.indexOfNone(u8, self.string[self.str_ptr..], "0123456789") orelse self.string.len - self.str_ptr); // Grab the index where the numeric component of string ends.
    const number = try std.fmt.parseUnsigned(usize, self.string[self.str_ptr..num_slice_len], 10); // Slice through numeric component and grab int value.
    self.str_ptr = num_slice_len;
    return number;
}

/// Scans through the string and grabs a group name as a string value.
pub fn scanGroupName(self: *@This()) ![]const u8 {
    const len = self.strlen();
    if (try self.scanReturnCurrentCharacter() != '<') {
        return core_types.ParsingError.InvalidGroupName;
    }
    const start = self.str_ptr + 1;
    var end: usize = start; // Consume '<'.
    while (end < len and self.string[end] != '>') {
        switch (self.string[end]) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            else => {
                return core_types.ParsingError.InvalidGroupName;
            },
        }
        end += 1;
    }
    if (end >= len) {
        return core_types.ParsingError.EndOfString;
    }
    if (self.string[end] != '>') {
        return core_types.ParsingError.InvalidGroupName;
    }
    const name: []const u8 = self.string[start .. end];
    self.str_ptr = end + 1; // Consume '>'.
    return name;
}

/// Handles the left hand side of a character class range expression and returns a leaf node if the value encountered cannot exist in a range.
/// Also has side effect of handling escaped characters which become different literals inside a class expression. 
pub fn scanClassRangeLHS(self: *@This(), char_to_set: *u8, escaped: bool) !?ast_types.AtomNode {
    if (escaped) {
        switch (char_to_set.*) {
            'n' => {
                char_to_set.* = '\n';
                return null;
            },
            't' => {
                char_to_set.* = '\t';
                return null;
            },
            'r' => {
                char_to_set.* = '\r';
                return null;
            },
            'f' => {
                char_to_set.* = 0x0C;
                return null;
            },
            'd' => {
                if (self.scanSeeCharacter('-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .digit, .inverted = false };
            },
            'D' => {
                if (self.scanSeeCharacter('-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .digit, .inverted = true };
            },
            'w' => {
                if (self.scanSeeCharacter('-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .word, .inverted = false };
            },
            'W' => {
                if (self.scanSeeCharacter('-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .word, .inverted = true };
            },
            's' => {
                if (self.scanSeeCharacter('-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .whitespace, .inverted = false };
            },
            'S' => {
                if (self.scanSeeCharacter('-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .whitespace, .inverted = true };
            },
            'b', 'B', 'A', 'Z' => { // Not allowed at all in char classes.
                return core_types.ParsingError.TokenNotFound;
            },
            else => {
                return null;
            }, // Exhaustive switching requirement.
        }
    } else {
        return null;
    }
}

/// Handles the right hand side of a character class range expression; it simply does the same side-effect conversion 
/// that the LHS scanner does, but does not return a node.
pub fn scanClassRangeRHS(self: *@This(), char_to_set: *u8, escaped: bool) !void {
    _ = self; // Kept to keep syntax consistent.
    if (escaped) {
        switch (char_to_set.*) {
            'n' => {
                char_to_set.* = '\n';
            },
            't' => {
                char_to_set.* = '\t';
            },
            'r' => {
                char_to_set.* = '\r';
            },
            'f' => {
                char_to_set.* = 0x0C;
            },
            ']' => {},
            'b', 'B', 'd', 'D', 's', 'S', 'w', 'W', 'k', 'A', 'Z' => { // Characters not allowed in ranges or at all.
                return core_types.ParsingError.TokenNotFound;
            },
            else => {},
        }
    } 
}

/// Tokenizes character classes with '-' syntax awareness. Consumes up to the last relevant character.
pub fn scanClassAtom(self: *@This()) !ast_types.AtomNode {
    var escaped: bool = false;
    const len: usize = self.string.len;
    if (self.scanHaveEscape()) {
        if (self.str_ptr >= len) {
            return core_types.ParsingError.EndOfString;
        }
        escaped = true;
    }
    var char_to_set: u8 = try self.scanReturnCurrentCharacter();
    try self.scanConsumeAnyCharacter();
    if (try self.scanClassRangeLHS(&char_to_set, escaped)) |lhs| {
        return lhs;
    }
    escaped = false;
    if (self.scanHaveCharacter('-')) { // Range syntax.
        if (self.scanSeeCharacter(']')) { // Return so that '-' is interpreted as a character at the end.
            return .{ .atom = .{ .generic = char_to_set }, .inverted = false };
        }
        if (self.str_ptr >= len) {
            return core_types.ParsingError.EndOfString;
        }
        if (self.scanHaveEscape()) {
            if (self.str_ptr >= len) {
                return core_types.ParsingError.EndOfString;
            }
            escaped = true;
        }
        var char_to_set2: u8 = try self.scanReturnCurrentCharacter(); // Grab character after -.
        try self.scanConsumeAnyCharacter(); // Consume the character that was just fetched. 
        try self.scanClassRangeRHS(&char_to_set2, escaped); 
        if (char_to_set > char_to_set2) {
            return core_types.ParsingError.InvalidRange;
        }
        return .{ .atom = .{ .range = .{ .character_min = char_to_set, .character_max = char_to_set2 } }, .inverted = false }; // If range is found, make range node.
    }
    return .{ .atom = .{ .generic = char_to_set }, .inverted = false };
}

/// Consumes a character in the input string and errors if it is not present.
pub fn scanConsumeCharacter(self: *@This(), character: u8) !void {
    if (!self.scanHaveCharacter(character)) {
        return core_types.ParsingError.TokenNotFound;
    }
}

/// Consumes any single character in the input string and errors if the slice pointer is at the end.
pub fn scanConsumeAnyCharacter(self: *@This()) !void {
    if (self.str_ptr < self.string.len) {
        self.str_ptr += 1;
    } else {
        return core_types.ParsingError.EndOfString; 
    }
}

/// Returns the character that will be scanned next.
pub fn scanReturnCurrentCharacter(self: *@This()) !u8 {
    if (self.str_ptr >= self.string.len) {
        return core_types.ParsingError.EndOfString;
    }
    return self.string[self.str_ptr];
}

/// Unrolls the scanner to reuse a token in a different scanning/parsing process.
pub fn scanUnrollCharacter(self: *@This()) !void {
    if (self.str_ptr == 0) {
        return core_types.ParsingError.BeforeStartOfString; 
    }
    self.str_ptr -= 1;
}

/// An assertion which errors if the scanner has run out of input data. 
pub fn scanExpectMoreCharacters(self: *@This()) !void {
    if (!self.scanHasMoreCharacters()) {
        return core_types.ParsingError.EndOfString;
    }
}

/// An assertion which errors if the scanner does not have at_least number of characters available to consume.
pub fn scanExpectAtleastMoreCharacters(self: *@This(), at_least: usize) !void {
    if (!self.scanHasAtLeastMoreCharacters(at_least)) {
        return core_types.ParsingError.EndOfString;
    }
}
