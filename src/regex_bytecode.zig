const std = @import("std");
const core_regex_types = @import("core_regex_types.zig");
const regex_gen_util = @import("regex_gen_util.zig");

pub const Instruction = union(enum) {
    split: struct {
        left: usize,
        right: usize,
    },
    repeat_start: struct {
        min: usize,
        max: core_regex_types.RepetitionBoundType,
        mode: core_regex_types.RepeaterType,
    },
    repeat_end: void,
    jmp: usize,
    literal: core_regex_types.LeafAtomNode,
    end_match: void,
    capture_start: usize,
    capture_end: usize,
    atomic_start: void,
    atomic_end: void,
    lookahead_start: void,
    lookahead_end: void,
    lookbehind_start: usize,
    lookbehind_end: void,
    neg_lookahead_start: void,
    neg_lookahead_end: void,
    neg_lookbehind_start: usize,
    neg_lookbehind_end: void,
    class: u256, // binary-optimized for every 8-bit character.
};

pub fn emit(allocator: anytype, ast: *const core_regex_types.ASTNode) ![]Instruction {
    var labels: std.ArrayList(usize) = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer labels.deinit(allocator);
    var fixups: std.ArrayList(usize) = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer fixups.deinit(allocator);
    var instructions: std.ArrayList(Instruction) = try std.ArrayList(Instruction).initCapacity(allocator, 8);
    defer instructions.deinit(allocator);
    var instruction_index: usize = 0;
    try emitLabel(allocator, &labels, &instruction_index);
    try emitRecursive(allocator, &labels, &instructions, &fixups, ast, &instruction_index, 0);
    _ = try emitInstruction(allocator, &instructions, &fixups, .end_match, &instruction_index);
    const result = try instructions.toOwnedSlice(allocator);
    try propagateFixups(fixups.items, labels.items, result);
    return result;
}

fn propagateFixups(fixups: []usize, labels: []usize, instructions: []Instruction) !void {
    for (0..fixups.len) |i| {
        const current = fixups[i];
        switch(instructions[current]) {
            .split => {
                instructions[current].split.left = labels[instructions[current].split.left];
                instructions[current].split.right = labels[instructions[current].split.right];
            },
            .jmp => {
                instructions[current].jmp = labels[instructions[current].jmp];
            },
            else => {

            }
        }
    }
}

fn emitLabel(allocator: anytype, labels: *std.ArrayList(usize), instruction_ptr: *usize) !void { // Emits a jump reference label at the current instruction pointer.
    try labels.append(allocator, instruction_ptr.*);
}

fn emitInstruction(allocator: anytype, instructions: *std.ArrayList(Instruction), fixups: *std.ArrayList(usize), data: Instruction, index_ptr: *usize) !usize {
    try instructions.append(allocator, data);
    index_ptr.* += 1;
    switch(data) {
        .jmp => {
            try fixups.append(allocator, index_ptr.* - 1);
        },
        .split => {
            try fixups.append(allocator, index_ptr.* - 1);
        },
        .end_match => {
        },
        else => {}, // Exhaustive switch requirement.
    }
    return index_ptr.* - 1;
}

fn emitRecursive(allocator: anytype, labels: *std.ArrayList(usize), instructions: *std.ArrayList(Instruction),
    fixups: *std.ArrayList(usize), ast: *const core_regex_types.ASTNode, instruction_ptr: *usize,
    recursion_level: usize) !void {
    switch (ast.*) {
        .leaf_atom => |leaf| {
            _ = try emitInstruction(allocator, instructions, fixups, .{ .literal = leaf }, instruction_ptr);
        },
        .repetition => |rep| {
            _ = try emitInstruction(allocator, instructions, fixups, .{.repeat_start = .{.min = rep.reps.min, .max = rep.reps.max, .mode = rep.rep_type}}, instruction_ptr);
            try emitRecursive(allocator, labels, instructions, fixups, rep.child, instruction_ptr, recursion_level + 1);
            _ = try emitInstruction(allocator, instructions, fixups, .repeat_end, instruction_ptr);
            try emitLabel(allocator, labels, instruction_ptr);
        },
        .alternation => |alt| {
            var jmp_end_indices = try std.ArrayList(usize).initCapacity(allocator, 2);
            defer jmp_end_indices.deinit(allocator);
            for (0..alt.parts.len-1) |i| {
                try emitLabel(allocator, labels, instruction_ptr);
                const split_index = try emitInstruction(allocator, instructions, fixups, .{.split = .{.left = labels.items.len, .right = 0}}, instruction_ptr);
                try emitLabel(allocator, labels, instruction_ptr);
                try emitRecursive(allocator, labels, instructions, fixups, alt.parts[i], instruction_ptr, recursion_level + 1);
                try jmp_end_indices.append(allocator, try emitInstruction(allocator, instructions, fixups, .{ .jmp = 0 }, instruction_ptr));
                instructions.items[split_index].split.right = labels.items.len;

            }
            try emitLabel(allocator, labels, instruction_ptr);
            try emitRecursive(allocator, labels, instructions, fixups, alt.parts[alt.parts.len-1], instruction_ptr, recursion_level + 1);
            try jmp_end_indices.append(allocator, try emitInstruction(allocator, instructions, fixups, .{ .jmp = 0 }, instruction_ptr));
            for (0..jmp_end_indices.items.len) |i| {
                instructions.items[jmp_end_indices.items[i]].jmp = labels.items.len; // Have every alternation jump to the end when complete.
            }
        },
        .group => |grp| {
            switch(grp.type) {
                .capturing => {
                    if (grp.id) |id| {
                        try emitLabel(allocator, labels, instruction_ptr);
                        _ = try emitInstruction(allocator, instructions, fixups, .{ .capture_start =  id }, instruction_ptr);
                        try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                        try emitLabel(allocator, labels, instruction_ptr);
                        _ = try emitInstruction(allocator, instructions, fixups, .{ .capture_end =  id }, instruction_ptr);
                    } else {
                        return core_regex_types.BytecodeGenError.InvalidGroupID;
                    }
                },
                .non_capturing => |grp_type| {
                    switch(grp_type) {
                        .atomic => {
                            try emitLabel(allocator, labels, instruction_ptr);
                            _ = try emitInstruction(allocator, instructions, fixups, .atomic_start, instruction_ptr);
                            try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                            try emitLabel(allocator, labels, instruction_ptr);
                            _ = try emitInstruction(allocator, instructions, fixups, .atomic_end, instruction_ptr);
                        },
                        .generic => {
                            try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                        },
                        .lookahead => {
                            if (grp.negated) {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .neg_lookahead_start, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .neg_lookahead_end, instruction_ptr);
                            } else {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .lookahead_start, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .lookahead_end, instruction_ptr);
                            }
                        },
                        .lookbehind => |look| {
                            if (grp.negated) {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{.neg_lookbehind_start = look }, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .neg_lookbehind_end, instruction_ptr);
                            } else {
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .{.lookbehind_start = look }, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, grp.expr, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, instruction_ptr);
                                _ = try emitInstruction(allocator, instructions, fixups, .lookbehind_end, instruction_ptr);
                            }
                        }
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
            const DIGIT_MASK: u256 = ((2<<10)-1)<<'0';
            const ALPHANUM_MASK: u256 = ((2<<26)-1)<<'a' | ((2<<26)-1)<<'A' | 1<<'_' | DIGIT_MASK;
            const WHITESPACE_MASK: u256 = 1<<' ' | 1<<'\n' | 1<<'\t';
            var accepted_chars: u256 = 0;
            for (0..class_item.items.len) |i| { // Encode each item into the bitmask.
                var mask_change_val: u256 = undefined;
                switch(class_item.items[i].leaf_atom) {
                    .generic => |gen| {
                        mask_change_val = @as(u256,1)<<gen;
                    },
                    .digit => {
                        mask_change_val = DIGIT_MASK;
                    },
                    .word => {
                        mask_change_val = ALPHANUM_MASK;
                    },
                    .word_boundary, .start_anchor, .end_anchor, .any => {
                        return core_regex_types.BytecodeGenError.InvalidClassMember;
                    },
                    .whitespace => {
                        mask_change_val = WHITESPACE_MASK;
                    },
                    .range => |range| {
                        mask_change_val = ((@as(u256, 2)<<(range.character_max-range.character_min))-1)<<range.character_min;
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
            _ = try emitInstruction(allocator, instructions, fixups, .{ .class = accepted_chars }, instruction_ptr);
        },
        .epsilon => {
        },
    }
}