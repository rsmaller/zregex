const std = @import("std");
const core_types = @import("core_types.zig");
const ast_types = @import("ast_types.zig");
// Scanning functions will look through the target string and increment the string pointer; they do not consider parsing-level grammar and therefore do not heap allocate any AST nodes.
// These functions only return atom node values, if any.

/// Scans through the string and grabs a numeric component as a size value.
pub fn scanNumeric(str_to_scan: []const u8, i: *usize) !usize {
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

/// Tokenizes character classes with '-' syntax awareness.
pub fn scanClassAtom(str_to_scan: []const u8, i: *usize) !ast_types.AtomNode {
    var escaped: bool = false;
    const len: usize = str_to_scan.len;
    if (str_to_scan[i.*] == '\\') {
        i.* += 1; // Consume backslash.
        if (i.* >= len) {
            return core_types.ParsingError.EndOfString;
        }
        escaped = true;
    }
    var char_to_set: u8 = str_to_scan[i.*];
    if (escaped) {
        switch (str_to_scan[i.*]) {
            'n' => {
                char_to_set = '\n';
            },
            't' => {
                char_to_set = '\t';
            },
            'r' => {
                char_to_set = '\r';
            },
            ']' => {}, // Here for explicitness; already handled in the char_to_set assignment line.
            'd' => {
            if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') {
                return core_types.ParsingError.TokenNotFound;
            }
            return .{ .atom = .digit, .inverted = false };
        },
            'D' => {
                if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .digit, .inverted = true };
            },
            'w' => {
                if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .word, .inverted = false };
            },
            'W' => {
                if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .word, .inverted = true };
            },
            's' => {
                if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .whitespace, .inverted = false };
            },
            'S' => {
                if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') {
                    return core_types.ParsingError.TokenNotFound;
                }
                return .{ .atom = .whitespace, .inverted = true };
            },
            'b', 'B' => { // Not allowed at all in char classes.
                return core_types.ParsingError.TokenNotFound;
            },
            else => {}, // Exhaustive switching requirement.
        }
    }
    escaped = false;
    if (i.* + 1 < len and str_to_scan[i.* + 1] == '-') { // Range syntax.
        if (i.* + 2 < len and str_to_scan[i.* + 2] == ']') { // Return so that '-' is interpreted as a character at the end.
            return .{ .atom = .{ .generic = char_to_set }, .inverted = false };
    }
        i.* += 2; // Skip past current item and -.
        if (i.* >= len) {
            return core_types.ParsingError.EndOfString;
        }
        if (str_to_scan[i.*] == '\\') {
            i.* += 1; // Consume backslash.
            if (i.* >= len) {
                return core_types.ParsingError.EndOfString;
            }
            escaped = true;
        }
        var char_to_set2: u8 = str_to_scan[i.*]; // Grab character after -.
        if (escaped) {
            switch (str_to_scan[i.*]) {
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
                'b', 'B', 'd', 'D', 's', 'S', 'w', 'W' => { // Characters not allowed in ranges or at all.
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