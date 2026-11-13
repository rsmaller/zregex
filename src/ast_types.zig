// AST types organized into a single file; accessible via core_types.zig.
const std = @import("std");
const type_reflection = @import("type_reflection.zig");
const core_types = @import("core_types.zig");
const repetition_types = @import("repetition_types.zig");

pub const RepetitionNode = struct { // Parent node to another node constructed by a quantifier.
    child: *ASTNode,
    reps: repetition_types.RepetitionRangeType,
    rep_type: repetition_types.RepeaterType,
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
            generic: void,
            atomic: void,
            lookahead: void,
            lookbehind: usize,
        },
    },
    negated: bool,
    pub fn equals(self: *const GroupNode, other: GroupNode) bool {
        if (std.meta.activeTag(self.type) != std.meta.activeTag(other.type)) {
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
                if (std.meta.activeTag(capt) != std.meta.activeTag(other.type.capturing)) {
                    return false;
                }
            },
            .non_capturing => |non_capt| {
                if (std.meta.activeTag(non_capt) != std.meta.activeTag(other.type.non_capturing)) {
                    return false;
                }
            },
        }
        return true;
    }
};

pub const AtomNode = struct {
    atom: union(enum) {
        generic: u8,
        backref_id: usize,
        backref_name: []const u8,
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
    pub fn equals(self: *const AtomNode, other: AtomNode) bool {
        if (std.meta.activeTag(self.atom) != std.meta.activeTag(other.atom)) {
            return false;
        }
        switch (self.atom) {
            .generic => |chr| {
                if (chr != other.atom.generic) {
                    return false;
                }
            },
            .range => |range| {
                if (range.character_min != other.atom.range.character_min) {
                    return false;
                }
                if (range.character_max != other.atom.range.character_max) {
                    return false;
                }
            },
            .backref_id => |id| {
                if (id != other.atom.backref_id) {
                    return false;
                }
            },
            .backref_name => |name| {
                if (!std.mem.eql(u8, name, other.atom.backref_name)) {
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
    items: []AtomNode,
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

pub const ASTNode = union(enum) {
    atom: AtomNode,
    concatenation: ConcatenationNode,
    alternation: AlternationNode,
    group: GroupNode,
    repetition: RepetitionNode,
    class: ClassNode,
    epsilon: void, // Generic empty node.
    failed_parse: void,
    /// Allows one to create simple void-valued tag nodes in-place.
    pub fn create(allocator: anytype, comptime tag: anytype) !*@This() {
        const ret = try allocator.create(@This());
        if (comptime @FieldType(@This(), @tagName(tag)) == void) { 
            ret.* = tag;
        } else {
            @compileError("Can't assign non-void tag to ASTNode without values. Please create a node with data!");
        }
        return ret;
    }
    /// Allows one to create any AST node (with data) in-place.
    pub fn createWithData(allocator: anytype, data: ASTNode) !*@This() {
        const ret = try allocator.create(@This());
        ret.* = data;
        return ret;
    }
    /// Returns a 1-to-1 copy of an AST using a recursive deep copy.
    pub fn duplicate(self: *const ASTNode, allocator: anytype) !*@This() {
        const ret = try allocator.create(ASTNode);
        errdefer allocator.destroy(ret);
        ret.* = self.*; // Copy the entire node's data over and re-assign pointers after.
        switch (ret.*) {
            .atom => |*atom| { // Right now, only have to duplicate backref name. If changed, make sure deep copy respects that!
                switch (atom.atom) {
                    .backref_name => |name| {
                       atom.atom.backref_name = try allocator.dupe(u8, name); // duplicate backref name.
                    },
                    else => {},
                }
            },
            .concatenation => |*concat| {
                for (concat.parts, 0..) |item, i| {
                    concat.parts[i] = try item.duplicate(allocator); // Recursively duplicate every item in concat.
                } 
            },
            .alternation => |*alt| {
                for (alt.parts, 0..) |item, i| {
                    alt.parts[i] = try item.duplicate(allocator);
                }
            },
            .group => |*grp| {
                if (grp.name) |name| {
                    grp.name = try allocator.dupe(u8, name);
                } else {
                    grp.name = null; // Shouldn't be necessary but just in case. 
                }
                grp.expr = try grp.expr.duplicate(allocator);
            },
            .repetition => |*rep| {
                rep.child = try rep.child.duplicate(allocator);
            },
            .class => |*cls| {
                cls.items = try allocator.dupe(AtomNode, cls.items);
            },
            .epsilon => {},
            .failed_parse => {},
        }
        return ret;
    }
    pub fn equals(self: *const ASTNode, other: *const ASTNode) bool { // ASTs should be stored as pointers; expects comparison between pointer types.
        if (std.meta.activeTag(self.*) != std.meta.activeTag(other.*)) {
            return false;
        }
        switch (self.*) {
            .atom => {
                if (!self.atom.equals(other.atom)) {
                    return false;
                }
            },
            .alternation => |alt| {
                if (!alt.equals(other.alternation)) {
                    return false;
                }
            },
            .concatenation => |concat| {
                if (!concat.equals(other.concatenation)) {
                    return false;
                }
            },
            .group => |grp| {
                if (!grp.equals(other.group)) {
                    return false;
                }
            },
            .repetition => |rep| {
                if (!rep.equals(other.repetition)) {
                    return false;
                }
            },
            .class => |class_item| {
                if (!class_item.equals(other.class)) { // Compiler decided to complain about "access of union field 'class' while field 'class' is active".
                    return false;                      // Could be another bug? @ptrCast() fixes it, for now.
                }
            },
            .epsilon => {}, // Epsilons and failed parses contain no data and are always the same.
            .failed_parse => {},
        }
        return true;
    }
    pub fn deinit(self: *@This(), allocator: anytype) void {
        switch (self.*) {
            .atom => |atom| {
                switch(atom.atom) {
                    .backref_name => |name| {
                        allocator.free(name);
                    },
                    else => {},
                }
                allocator.destroy(self);
            },
            .alternation => |alt| {
                for (alt.parts) |item| {
                    item.deinit(allocator);
                }
                allocator.free(alt.parts);
                allocator.destroy(self);
            },
            .concatenation => |concat| {
                for (concat.parts) |item| {
                    item.deinit(allocator);
                }
                allocator.free(concat.parts);
                allocator.destroy(self);
            },
            .group => |grp| {
                grp.expr.deinit(allocator);
                if (grp.name) |_| {
                    allocator.free(grp.name.?);
                }
                allocator.destroy(self);
            },
            .repetition => |rep| {
                rep.child.deinit(allocator);
                allocator.destroy(self);
            },
            .class => |class_item| {
                allocator.free(class_item.items);
                allocator.destroy(self);
            },
            .failed_parse => { // Failed parses point to a heap allocation and should be freed.
                allocator.destroy(self);
            },
            .epsilon => {
                allocator.destroy(self);
            }, 
        }
    }
};

pub const AnalyzedAST = struct { // User-facing AST returned.
    ast: *ASTNode,
    group_count: usize,
    map: core_types.NameIDMap,
    allocator: std.mem.Allocator, // The analyzed AST
    pub fn deinit(self: *@This()) void {
        self.ast.deinit(self.allocator); // For the sake of not bloating the namespace, and not exploding the size of the AST, each node does not contain its own allocator.
        self.map.name_to_id_map.deinit();
        self.map.id_to_name_map.deinit();
    }
};
