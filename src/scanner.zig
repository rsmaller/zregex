const std = @import("std");
const core_types = @import("core_types.zig");
const ast_types = @import("ast_types.zig");
// Scanning functions will look through the target string and increment the string pointer; they do not consider parsing-level grammar and therefore do not heap allocate any AST nodes.
// These functions only return atom node values, if any.

/// Scans through the string and grabs a numeric component as a size value.
pub fn scanNumeric(str_to_scan: []const u8, i: *usize) !usize {
    if (str_to_scan[i.*] < '0' or str_to_scan[i.*] > '9') {
        return core_types.ParsingError.TokenNotFound;
    }
    const num_slice_len = i.* + (std.mem.indexOfNone(u8, str_to_scan[i.*..], "0123456789") orelse str_to_scan.len - i.*); // Grab the index where the numeric component of string ends.
    const number = try std.fmt.parseUnsigned(usize, str_to_scan[i.*..num_slice_len], 10); // Slice through numeric component and grab int value.
    i.* = num_slice_len;
    return number;
}

///
pub fn scanGroupName(str_to_scan: []const u8, i: *usize) ![]const u8 {
    const len = str_to_scan.len;
    if (str_to_scan[i.*] != '<') {
        return core_types.ParsingError.InvalidGroupName;
    }
    const start = i.* + 1;
    var end: usize = start; // Consume '<'.
    while (end < len and str_to_scan[end] != '>') {
        switch (str_to_scan[end]) {
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
    if (str_to_scan[end] != '>') {
        return core_types.ParsingError.InvalidGroupName;
    }
    const name: []const u8 = str_to_scan[start .. end];
    i.* = end + 1; // Consume '>'.
    return name;
}

/// Tokenizes character classes with '-' syntax awareness. Consumes up to the last relevant character.
pub fn scanClassAtom(str_to_scan: []const u8, i: *usize) !ast_types.AtomNode {
    var escaped: bool = false;
    const len: usize = str_to_scan.len;
    if (scanHaveCharacter(str_to_scan, i, '\\')) {
        if (i.* >= len) {
            return core_types.ParsingError.EndOfString;
        }
        escaped = true;
    }
    var char_to_set: u8 = str_to_scan[i.*];
    try scanConsumeAnyCharacter(str_to_scan, i);
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
                char_to_set = 0x0C;
            },
            ']' => {}, // Here for explicitness; already handled in the char_to_set assignment line.
            'd' => {
                if (scanSeeCharacter(str_to_scan, i, '-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .digit, .inverted = false };
            },
            'D' => {
                if (scanSeeCharacter(str_to_scan, i, '-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .digit, .inverted = true };
            },
            'w' => {
                if (scanSeeCharacter(str_to_scan, i, '-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .word, .inverted = false };
            },
            'W' => {
                if (scanSeeCharacter(str_to_scan, i, '-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .word, .inverted = true };
            },
            's' => {
                if (scanSeeCharacter(str_to_scan, i, '-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .whitespace, .inverted = false };
            },
            'S' => {
                if (scanSeeCharacter(str_to_scan, i, '-')) {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .whitespace, .inverted = true };
            },
            'b', 'B', 'A', 'Z' => { // Not allowed at all in char classes.
                return core_types.ParsingError.TokenNotFound;
            },
            else => {}, // Exhaustive switching requirement.
        }
    }
    escaped = false;
    if (scanHaveCharacter(str_to_scan, i, '-')) { // Range syntax.
        if (scanSeeCharacter(str_to_scan, i, ']')) { // Return so that '-' is interpreted as a character at the end.
            return .{ .atom = .{ .generic = char_to_set }, .inverted = false };
        }
        if (i.* >= len) {
            return core_types.ParsingError.EndOfString;
        }
        if (scanHaveCharacter(str_to_scan, i, '\\')) {
            if (i.* >= len) {
                return core_types.ParsingError.EndOfString;
            }
            escaped = true;
        }
        var char_to_set2: u8 = str_to_scan[i.*]; // Grab character after -.
        try scanConsumeAnyCharacter(str_to_scan, i); // Consume the last character scanned in scanClassAtom.
        if (escaped) {
            switch (char_to_set2) {
                'n' => {
                    char_to_set2 = '\n';
                },
                't' => {
                    char_to_set2 = '\t';
                },
                'r' => {
                    char_to_set2 = '\r';
                },
                'f' => {
                    char_to_set = 0x0C;
                },
                ']' => {},
                'b', 'B', 'd', 'D', 's', 'S', 'w', 'W', 'k', 'A', 'Z' => { // Characters not allowed in ranges or at all.
                    return core_types.ParsingError.TokenNotFound;
                },
                else => {},
            }
        } else {
            switch (char_to_set) {
                '$', '^', '(' => {
                    return core_types.ParsingError.TokenNotFound;
                },
                else => {},
            }
        }
        if (char_to_set >= char_to_set2) {
            return core_types.ParsingError.InvalidRange;
        }
        return .{ .atom = .{ .range = .{ .character_min = char_to_set, .character_max = char_to_set2 } }, .inverted = false }; // If range is found, make range node.
    }
    return .{ .atom = .{ .generic = char_to_set }, .inverted = false };
}


// The scanning functions that are used for parser branching.

/// Returns a boolean representing whether a character is present in the input string.
pub fn scanSeeCharacter(str_to_scan: []const u8, i: *usize, character: u8) bool {
    return i.* < str_to_scan.len and str_to_scan[i.*] == character;
}

/// Returns a boolean representing whether a character is present in the input string and increments past the character if present.
pub fn scanHaveCharacter(str_to_scan: []const u8, i: *usize, character: u8) bool {
    const result = scanSeeCharacter(str_to_scan, i, character);
    if (result) {
        i.* += 1; // Consume character.
    }
    return result;
}

pub fn scanSeeString(str_to_scan: []const u8, i: *usize, string: []const u8) bool {
    if (string.len + i.* <= str_to_scan.len) {
        return std.mem.eql(u8, str_to_scan[i.*..i.*+string.len], string[0..string.len]);      
    }
    else return false;
}

pub fn scanHaveString(str_to_scan: []const u8, i: *usize, string: []const u8) bool {
    const result = scanSeeString(str_to_scan, i, string);
    if (result) {
        i.* += string.len;
    }
    return result;
}

/// Scans the escaping backslash; merely a specialization of scanHaveCharacter.
pub fn scanHaveEscape(str_to_scan: []const u8, i: *usize) bool {
    return scanHaveCharacter(str_to_scan, i, '\\');
}

/// Looks at the current character to see if it has been escaped; therefore it looks backwards.
pub fn scanSeeIsEscaped(str_to_scan: []const u8, i: *usize) bool {
    return i.* > 0 and str_to_scan[i.* - 1] == '\\';
}

/// Consumes a character in the input string and errors if it is not present.
pub fn scanConsumeCharacter(str_to_scan: []const u8, i: *usize, character: u8) !void {
    if (!scanHaveCharacter(str_to_scan, i, character)) {
        return core_types.ParsingError.TokenNotFound;
    }
}

/// Consumes any single character in the input string and errors if the slice pointer is at the end.
pub fn scanConsumeAnyCharacter(str_to_scan: []const u8, i: *usize) !void {
    if (i.* < str_to_scan.len) {
        i.* += 1;
    } else {
        return core_types.ParsingError.EndOfString;
    }
}
