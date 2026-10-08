// The core file which contains the primary types for parser-generated ASTs and errors, parsing or otherwise.
const std = @import("std");
const type_reflection = @import("type_reflection.zig");
const vm = @import("vm.zig");

pub const Pattern = struct {
    ast: ?AST,
    map: NameIDMap,
    bytecode: []Instruction,
    allocator: std.mem.Allocator,
    pub fn match(self: *const Pattern, allocator: anytype, string: []const u8) !?SlicedMatch {
        return try vm.match(allocator, self, string);
    }
    pub fn deinit(self: *@This()) void {
        if (self.ast) |ast| {
            ast.deinit(self.allocator);
        }
        self.allocator.free(self.bytecode);
        self.map.name_to_id_map.deinit();
        self.map.id_to_name_map.deinit();
    }
    pub fn getIdByName(self: *const @This(), name: []const u8) ?usize {
        return self.map.name_to_id_map.get(name);
    }
    pub fn getNameById(self: *const @This(), id: usize) ?[]const u8 {
        return self.map.id_to_name_map.get(id);
    }
};

pub const SlicedMatch = struct {
    groups: []?[:0]const u8,
    pattern_ptr: *const Pattern,
    pub fn deinit(self: *const @This(), allocator: anytype) void {
        for (self.groups) |grp| {
            if (grp) |non_null_grp| {
                allocator.free(non_null_grp);
            }
        }
        allocator.free(self.groups);
    }
    pub fn getMatchFromName(self: *const @This(), name: []const u8) ?[]const u8 {
        if (self.pattern_ptr.getIdByName(name)) |id| {
            return self.groups[id];
        }
        return null;
    }
    pub fn getMatchFromId(self: *const @This(), id: usize) ?[]const u8 {
        return self.groups[id];
    }
};

pub const Match = struct {
    groups: []const ?MatchGroup,
};

pub const MatchGroup = struct {
    start: usize, // Slices of original string passed in.
    end: usize,
};

pub const NameIDMap = struct {
    name_to_id_map: std.StringHashMap(usize),
    id_to_name_map: std.AutoHashMap(usize, []const u8),
};

pub const LiteralInstruction = struct {
    inverted: bool,
    data: union(enum) {
        generic: u8,
        digit: void,
        word: void,
        word_boundary: void,
        whitespace: void,
        start_anchor: void,
        end_anchor: void,
        any: void,
    },
};

pub const Instruction = union(enum) {
    header_start: void,
    allocate_groups: struct {
        size: usize,
    },
    header_end: void,
    split: struct {
        left: usize,
        right: usize,
    },
    repeat_start: struct {
        min: usize,
        max: RepetitionBoundType,
        mode: RepeaterType,
        escape_jmp: usize,
    },
    repeat_end: usize,
    jmp: usize,
    literal: LiteralInstruction,
    end_match: void,
    capture_start: usize,
    capture_end: usize,
    atomic_start: void,
    atomic_end: void,
    lookahead_start: void,
    lookahead_end: void,
    lookbehind_start: usize,
    lookbehind_end: void,
    neg_lookahead_start: usize,
    neg_lookahead_end: void,
    neg_lookbehind_start: struct {
        len: usize,
        jmp: usize,
    },
    neg_lookbehind_end: void,
    class: u256, // binary-optimized for every 8-bit character.
};

pub const AST = *ASTNode;

pub const GroupSizedAST = struct {
    ast: AST,
    group_count: usize,
};

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
        switch (self.*) {
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
    type: union(enum) { capturing: union(enum) {
        generic,
    }, non_capturing: union(enum) {
        generic: void,
        atomic: void,
        lookahead: void,
        lookbehind: usize,
    } },
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
        switch (self.type) {
            .capturing => |capt| {
                if (@intFromEnum(capt) != @intFromEnum(other.type.capturing)) {
                    return false;
                }
            },
            .non_capturing => |non_capt| {
                if (@intFromEnum(non_capt) != @intFromEnum(other.type.non_capturing)) {
                    return false;
                }
            },
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
        if (std.meta.activeTag(self.leaf_atom) != std.meta.activeTag(other.leaf_atom)) {
            return false;
        }
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

pub const AlternationNode = struct {
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

pub const ConcatenationNode = struct {
    parts: []*ASTNode, // Operation chaining two characters together.
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
    failed_parse: void,
    pub fn equals(self: *const ASTNode, other: anytype) bool { // ASTs should be stored as pointers; expects comparison between pointer types.
        comptime {
            if (type_reflection.UnwrappedPointer(@TypeOf(other)) != ASTNode) {
                @compileError("Type of other node for comparison between ASTNode must also be a ASTNode or *ASTNode");
            }
        }
        const other_unwrapped_pointer: ASTNode = type_reflection.unwrapPointer(other);
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
            .failed_parse => {},
        }
        return true;
    }
    pub fn deinit(self: *@This(), allocator: anytype) void {
        switch (self.*) {
            .leaf_atom => {},
            .alternation => |alt| {
                for (alt.parts) |item| {
                    item.deinit(allocator);
                }
                allocator.free(alt.parts);
            },
            .concatenation => |concat| {
                for (concat.parts) |item| {
                    item.deinit(allocator);
                }
                allocator.free(concat.parts);
            },
            .group => |grp| {
                grp.expr.deinit(allocator);
            },
            .repetition => |rep| {
                rep.child.deinit(allocator);
            },
            .class => |class_item| {
                allocator.free(class_item.items);
            },
            .epsilon, .failed_parse => {
                return;
            }, // Epsilons contain no data and are always the same. Uses a single element and should not be freed.
        }
        allocator.destroy(self);
    }
};

pub const ParsingError = error{
    TokenNotFound,
    EndOfString,
    InvalidRange,
    VariableLookbehindRange,
    InvalidGroupName,
};

pub const BytecodeGenError = error{
    InvalidGroupID,
    InvalidClassMember,
    InvalidTypeConversion,
    UnexpectedBytecodeType,
};

pub const StackError = error{
    StackEmptyError,
    InvalidStackAccess,
};

pub const VMError = error{
    InvalidGroupAllocation,
    InvalidStackArrangement,
    BadHeaderScan,
    FailedMatch,
    NullIndexAccess,
};
