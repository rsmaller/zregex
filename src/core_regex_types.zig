const regex_type_reflection = @import("regex_type_reflection.zig");
pub const AST = *const ASTNode;

pub const RepeaterType = enum {
    greedy,
    lazy,
    possessive,
};

pub const RepetitionBoundType = union(enum) {
    bounded: usize,
    unbounded: void,
    pub fn equals(self: *const RepetitionBoundType, other: RepetitionBoundType) bool {
        if (@intFromEnum(self.*) != @intFromEnum(other)) {
            return false;
        }
        switch(self.*) {
            .bounded => |bound| {
                if (bound != other.bounded) {
                    return false;
                }
            },
            .unbounded => {},
        }
        return true;
    }
};

pub const RepetitionRangeType = struct {
    min: usize,
    max: RepetitionBoundType,
    pub fn equals(self: *const RepetitionRangeType, other: RepetitionRangeType) bool {
        if (self.min != other.min) {
            return false;
        }
        if (!self.max.equals(other.max)) {
            return false;
        }
        return true;
    }
};

pub const RepetitionNode = struct { // Parent node to another node constructed by a quantifier.
    child: *ASTNode,
    reps: RepetitionRangeType,
    rep_type: RepeaterType,
    pub fn equals(self: *const RepetitionNode, other: RepetitionNode) bool {
        if (!self.reps.equals(other.reps)) {
            return false;
        }
        if (self.rep_type != other.rep_type) {
            return false;
        }
        if (!self.child.equals(other.child)) {
            return false;
        }
        return true;
    }
};

pub const GroupNode = struct {
    expr: *ASTNode,
    id: ?usize,
    name: ?[]const u8, // Not nested in GroupNode for simplicity.
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
    pub fn equals(self: *const GroupNode, other: GroupNode) bool {
        if (@intFromEnum(self.type) != @intFromEnum(other.type)) {
            return false;
        }
        if (self.id != other.id) {
            return false;
        }
        if (!self.expr.equals(other.expr)) {
            return false;
        }
        if (self.negated != other.negated) {
            return false;
        }
        switch(self.type) {
            .capturing => |capt| {
                if (@intFromEnum(capt) != @intFromEnum(other.type.capturing)) {
                    return false;
                }
            },
            .non_capturing => |non_capt| {
                if (@intFromEnum(non_capt) != @intFromEnum(other.type.non_capturing)) {
                    return false;
                }
            }
        }
        return true;
    }
};

pub const LeafAtomNode = struct {
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
    pub fn equals(self: *const LeafAtomNode, other: LeafAtomNode) bool {
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

pub const AlternationNode = struct{
    parts: []*ASTNode,
    pub fn equals(self: *const AlternationNode, other: AlternationNode) bool {
        if (self.parts.len != other.parts.len) {
            return false;
        }
        for (self.parts, 0..) |_, i| {
            if (!self.parts[i].equals(other.parts[i])) {
                return false;
            }
        }
        return true;
    }
}; // Same as concatenation but semantically different and in a higher order function.

pub const ConcatenationNode = struct{
    parts: []*ASTNode,  // Operation chaining two characters together.
    pub fn equals(self: *const ConcatenationNode, other: ConcatenationNode) bool {
        if (self.parts.len != other.parts.len) {
            return false;
        }
        for (self.parts, 0..) |_, i| {
            if (!self.parts[i].equals(other.parts[i])) {
                return false;
            }
        }
        return true;
    }
};

pub const ClassNode = struct { // Character class.
    items: []LeafAtomNode,
    negated: bool,
    pub fn equals(self: *const ClassNode, other: ClassNode) bool {
        if (self.negated != other.negated) {
            return false;
        }
        if (self.items.len != other.items.len) {
            return false;
        }
        for (0..self.items.len) |i| {
            if (!self.items[i].equals(other.items[i])) {
                return false;
            }
        }
        return true;
    }
};

pub const ASTNode = union(enum) { // Tagged union for node type.
    leaf_atom: LeafAtomNode,
    concatenation: ConcatenationNode,
    alternation: AlternationNode,
    group: GroupNode,
    repetition: RepetitionNode,
    class: ClassNode,
    epsilon: void, // Generic empty node.
    pub fn equals(self: *const ASTNode, other: anytype) bool { // ASTs should be stored as pointers; expects comparison between pointer types.
        comptime {
    if (regex_type_reflection.UnwrappedPointer(@TypeOf(other)) != ASTNode) {
        @compileError("Type of other node for comparison between ASTNode must also be a ASTNode or *ASTNode");
    }
}
    const other_unwrapped_pointer: ASTNode = regex_type_reflection.unwrapPointer(other);
    if (@intFromEnum(self.*) != @intFromEnum(other_unwrapped_pointer)) {
        return false;
    }
    switch (self.*) {
        .leaf_atom => {
            if (!self.leaf_atom.equals(other_unwrapped_pointer.leaf_atom)) {
                return false;
            }
        },
        .alternation => |alt| {
            if (!alt.equals(other_unwrapped_pointer.alternation)) {
                return false;
            }
        },
        .concatenation => |concat| {
            if (!concat.equals(other_unwrapped_pointer.concatenation)) {
                return false;
            }
        },
        .group => |grp| {
            if (!grp.equals(other_unwrapped_pointer.group)) {
                return false;
            }
        },
        .repetition => |rep| {
            if (!rep.equals(other_unwrapped_pointer.repetition)) {
                return false;
            }
        },
        .class => |classItem| {
            if (!classItem.equals(other_unwrapped_pointer.class)) {
                return false;
            }
        },
        .epsilon => {}, // Epsilons contain no data and are always the same.
            }
    return true;
}
};

pub const ParsingError = error{
    TokenNotFound,
    EndOfString,
    InvalidRange,
    VariableLookbehindRange,
};