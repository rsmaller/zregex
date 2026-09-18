const std = @import("std");
const core_types = @import("core_types.zig");
const core_util = @import("core_util.zig");

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
    allocate_groups: struct {
        size: usize,
    },
    split: struct {
        left: usize,
        right: usize,
    },
    repeat_start: struct {
        min: usize,
        max: core_types.RepetitionBoundType,
        mode: core_types.RepeaterType,
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
    lookbehind_end: usize,
    neg_lookahead_start: void,
    neg_lookahead_end: void,
    neg_lookbehind_start: usize,
    neg_lookbehind_end: usize,
    class: u256, // binary-optimized for every 8-bit character.
};

pub fn emit(allocator: anytype, ast: *const core_types.ASTNode, group_count: usize) ![]Instruction {
    var labels: std.ArrayList(usize) = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer labels.deinit(allocator);
    var fixups: std.ArrayList(usize) = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer fixups.deinit(allocator);
    var instructions: std.ArrayList(Instruction) = try std.ArrayList(Instruction).initCapacity(allocator, 8);
    defer instructions.deinit(allocator);
    var instruction_index: usize = 0;
    _ = try emitInstruction(allocator, &instructions, &fixups, .{ .permit_fixups = false }, .{ .allocate_groups = .{ .size = group_count } }, &instruction_index); // always allocate array for match groups first.
    _ = try emitInstruction(allocator, &instructions, &fixups, .{ .permit_fixups = false }, .{ .capture_start = 0 }, &instruction_index);
    try emitLabel(allocator, &labels, &instruction_index);
    try emitRecursive(allocator, &labels, &instructions, &fixups, ast, &instruction_index, 0);
    _ = try emitInstruction(allocator, &instructions, &fixups, .{ .permit_fixups = false }, .{ .capture_end = 0 }, &instruction_index);
    _ = try emitInstruction(allocator, &instructions, &fixups, .{ .permit_fixups = false }, .end_match, &instruction_index);
    const result = try instructions.toOwnedSlice(allocator);
    try propagateFixups(fixups.items, labels.items, result);
    return result;
}

// Replaces JMP and SPLIT instruction label values with actual bytecode-pointing values.
fn propagateFixups(fixups: []usize, labels: []usize, instructions: []Instruction) !void {
    for (0..fixups.len) |i| {
        const current = fixups[i];
        switch (instructions[current]) {
            .split => {
                instructions[current].split.left = labels[instructions[current].split.left];
                instructions[current].split.right = labels[instructions[current].split.right];
            },
            .jmp => {
                instructions[current].jmp = labels[instructions[current].jmp];
            },
            else => {},
        }
    }
}

fn emitLabel(allocator: anytype, labels: *std.ArrayList(usize), instruction_ptr: *usize) !void { // Emits a jump reference label at the current instruction pointer.
    try labels.append(allocator, instruction_ptr.*);
}

fn emitInstruction(allocator: anytype, instructions: *std.ArrayList(Instruction), fixups: *std.ArrayList(usize), permit_fixups: struct { permit_fixups: bool }, data: Instruction, index_ptr: *usize) !usize {
    try instructions.append(allocator, data);
    index_ptr.* += 1;
    if (permit_fixups.permit_fixups) {
        switch (data) {
            .jmp => {
                try fixups.append(allocator, index_ptr.* - 1);
            },
            .split => {
                try fixups.append(allocator, index_ptr.* - 1);
            },
            .end_match => {},
            else => {}, // Exhaustive switch requirement.
        }
    }
    return index_ptr.* - 1;
}

fn leafToLiteralInstruction(leaf: core_types.LeafAtomNode) !LiteralInstruction {
    var ret: LiteralInstruction = undefined;
    ret.inverted = leaf.inverted;
    switch (leaf.leaf_atom) {
        .any => {
            ret.data = .any;
        },
        .digit => {
            ret.data = .digit;
        },
        .end_anchor => {
            ret.data = .end_anchor;
        },
        .generic => |character| {
            ret.data = .{ .generic = character };
        },
        .word => {
            ret.data = .word;
        },
        .word_boundary => {
            ret.data = .word_boundary;
        },
        .start_anchor => {
            ret.data = .start_anchor;
        },
        .whitespace => {
            ret.data = .whitespace;
        },
        .range => {
            return core_types.BytecodeGenError.InvalidTypeConversion;
        },
    }
    return ret;
}

fn emitRecursive(allocator: anytype, labels: *std.ArrayList(usize), instructions: *std.ArrayList(Instruction), fixups: *std.ArrayList(usize), ast: *const core_types.ASTNode, instruction_ptr: *usize, recursion_level: usize) !void {
    switch (ast.*) {
        .leaf_atom => |leaf| {
            _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .literal = try leafToLiteralInstruction(leaf) }, instruction_ptr);
        },
        .repetition => |rep| {
            const rep_start_index = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .repeat_start = .{ .min = rep.reps.min, .max = rep.reps.max, .mode = rep.rep_type } }, instruction_ptr);
            try emitRecursive(allocator, labels, instructions, fixups, rep.child, instruction_ptr, recursion_level + 1);
            _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .repeat_end = rep_start_index }, instruction_ptr);
            try emitLabel(allocator, labels, instruction_ptr);
        },
        .alternation => |alt| {
            var jmp_instructions_indices = try std.ArrayList(usize).initCapacity(allocator, 2);
            defer jmp_instructions_indices.deinit(allocator);
            for (0..alt.parts.len - 1) |i| {
                try emitLabel(allocator, labels, instruction_ptr);
                const split_index = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = true }, .{ .split = .{ .left = labels.items.len, .right = 0 } }, instruction_ptr); // Left of the split is the label right after it; replaced with bytecode index after fixup.
                try emitLabel(allocator, labels, instruction_ptr);
                try emitRecursive(allocator, labels, instructions, fixups, alt.parts[i], instruction_ptr, recursion_level + 1);
                try jmp_instructions_indices.append(allocator, try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .jmp = 0 }, instruction_ptr));
                instructions.items[split_index].split.right = labels.items.len; // Right side of split is the label that will be generated after all labels/code are generated on the left side.
            }
            try emitLabel(allocator, labels, instruction_ptr);
            try emitRecursive(allocator, labels, instructions, fixups, alt.parts[alt.parts.len - 1], instruction_ptr, recursion_level + 1);
            try jmp_instructions_indices.append(allocator, try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .jmp = 0 }, instruction_ptr));
            for (0..jmp_instructions_indices.items.len) |i| {
                instructions.items[jmp_instructions_indices.items[i]].jmp = instructions.items.len; // Have every alternation jump to the end when complete; calculated without a fixup and therefore does not use a label pointer.
            }
        },
        .group => |grp| {
            switch (grp.type) {
                .capturing => {
                    if (grp.id) |id| {
                        try emitLabel(allocator, labels, instruction_ptr);
                        _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .capture_start = id }, instruction_ptr);
                        try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                        try emitLabel(allocator, labels, instruction_ptr);
                        _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .capture_end = id }, instruction_ptr);
                    } else {
                        return core_types.BytecodeGenError.InvalidGroupID;
                    }
                },
                .non_capturing => |grp_type| {
                    switch (grp_type) {
                        .atomic => {
                            try emitLabel(allocator, labels, instruction_ptr);
                            _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .atomic_start, instruction_ptr);
                            try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                            try emitLabel(allocator, labels, instruction_ptr);
                            _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .atomic_end, instruction_ptr);
                        },
                        .generic => {
                            try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                        },
                        .lookahead => {
                            if (grp.negated) {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .neg_lookahead_start, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .neg_lookahead_end, instruction_ptr);
                            } else {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .lookahead_start, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .lookahead_end, instruction_ptr);
                            }
                        },
                        .lookbehind => |look| {
                            if (grp.negated) {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .neg_lookbehind_start = look }, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .neg_lookbehind_end = look }, instruction_ptr);
                            } else {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .lookbehind_start = look }, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .lookbehind_end = look }, instruction_ptr);
                            }
                        },
                    }
                },
            }
        },
        .concatenation => |concat| {
            for (0..concat.parts.len) |i| {
                try emitRecursive(allocator, labels, instructions, fixups, concat.parts[i], instruction_ptr, recursion_level + 1);
            }
        },
        .class => |class_item| {
            const DIGIT_MASK: u256 = ((2 << 10) - 1) << '0';
            const ALPHANUM_MASK: u256 = ((2 << 26) - 1) << 'a' | ((2 << 26) - 1) << 'A' | 1 << '_' | DIGIT_MASK;
            const WHITESPACE_MASK: u256 = 1 << ' ' | 1 << '\n' | 1 << '\t';
            var accepted_chars: u256 = 0;
            for (0..class_item.items.len) |i| { // Encode each item into the bitmask.
                var mask_change_val: u256 = undefined;
                switch (class_item.items[i].leaf_atom) {
                    .generic => |gen| {
                        mask_change_val = @as(u256, 1) << gen;
                    },
                    .digit => {
                        mask_change_val = DIGIT_MASK;
                    },
                    .word => {
                        mask_change_val = ALPHANUM_MASK;
                    },
                    .word_boundary, .start_anchor, .end_anchor, .any => {
                        return core_types.BytecodeGenError.InvalidClassMember;
                    },
                    .whitespace => {
                        mask_change_val = WHITESPACE_MASK;
                    },
                    .range => |range| {
                        mask_change_val = ((@as(u256, 2) << (range.character_max - range.character_min)) - 1) << range.character_min;
                    },
                }
                if (class_item.items[i].inverted) {
                    mask_change_val = ~mask_change_val;
                }
                accepted_chars |= mask_change_val;
            }
            if (class_item.negated) {
                accepted_chars = ~accepted_chars;
            }
            _ = try emitInstruction(allocator, instructions, fixups, .{ .permit_fixups = false }, .{ .class = accepted_chars }, instruction_ptr);
        },
        .epsilon => {},
    }
}

