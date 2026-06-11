const std = @import("std");
const core_regex_types = @import("core_regex_types.zig");

const Instruction = union(enum) {
    split: struct {
        left: usize,
        right: usize,
    },
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
};

pub fn emit(allocator: anytype, out_interface: anytype, ast: *const core_regex_types.ASTNode, show_match_width: bool) ![]Instruction {
    var labels: std.ArrayList(usize) = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer labels.deinit(allocator);
    var fixups: std.ArrayList(usize) = try std.ArrayList(usize).initCapacity(allocator, 8);
    defer fixups.deinit(allocator);
    var instructions: std.ArrayList(Instruction) = try std.ArrayList(Instruction).initCapacity(allocator, 8);
    defer instructions.deinit(allocator);
    var instruction_index: usize = 0;
    try emitRecursive(allocator, &labels, &instructions, &fixups, out_interface, ast, show_match_width, &instruction_index, 0);
    try emitLabel(allocator, &labels, out_interface, &instruction_index);
    _ = try emitInstruction(out_interface, allocator, &labels, &instructions, &fixups, .end_match, &instruction_index);
    for (0..labels.items.len) |i| {
        try out_interface.print("{d}:{d} ", .{i, labels.items[i]});
    }
    try out_interface.print("\n", .{});
    for (0..fixups.items.len) |i| {
        try out_interface.print("{d} ", .{fixups.items[i]});
    }
    try out_interface.print("\n", .{});
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

fn printLeafAtom(out_interface: anytype, leaf: core_regex_types.LeafAtomNode) !void {
    switch(leaf.leaf_atom) {
        .generic => |gen_leaf| {
            var buf: [2]u8 = undefined;
            if (gen_leaf == '\n') {
                buf[0] = '\\';
                buf[1] = 'n';
            } else if (gen_leaf == '\t') {
                buf[0] = '\\';
                buf[1] = 't';
            } else if (gen_leaf == '\r') {
                buf[0] = '\\';
                buf[1] = 'r';
            } else {
                buf[0] = gen_leaf;
                buf[1] = 0;
            }
            try out_interface.print("LITERAL(char = {s})\n", .{buf});
        },
        .range => |range| {
            var buf: [2]u8 = undefined;
            var buf2: [2]u8 = undefined;
            if (range.character_min == '\n') {
                buf[0] = '\\';
                buf[1] = 'n';
            } else if (range.character_min == '\t') {
                buf[0] = '\\';
                buf[1] = 't';
            } else if (range.character_min == '\r') {
                buf[0] = '\\';
                buf[1] = 'r';
            } else {
                buf[0] = range.character_min;
                buf[1] = 0;
            }
            if (range.character_max == '\n') {
                buf2[0] = '\\';
                buf2[1] = 'n';
            } else if (range.character_max == '\t') {
                buf2[0] = '\\';
                buf2[1] = 't';
            } else if (range.character_max == '\r') {
                buf2[0] = '\\';
                buf2[1] = 'r';
            } else {
                buf2[0] = range.character_max;
                buf2[1] = 0;
            }
            try out_interface.print("RANGE(min = {s}, max = {s})\n", .{buf, buf2});
        },
        else => {
            try out_interface.print("LITERAL(item = {s}, negated = {})\n", .{@tagName(leaf.leaf_atom), leaf.inverted});
        },
    }
}

pub fn readOutBytecode(out_interface: anytype, bytecode: []Instruction) !void {
    for (0..bytecode.len) |i| {
        try out_interface.print("{d}:\t", .{i});
        switch(bytecode[i]) {
            .split => |spl| {
                try out_interface.print("SPLIT({d}, {d})\n", .{spl.left, spl.right});
            },
            .jmp => |jmp| {
                try out_interface.print("JMP({d})\n", .{jmp});
            },
            .end_match => {
                try out_interface.print("MATCH\n", .{});
            },
            .literal => |lit| {
                try printLeafAtom(out_interface, lit);
            },
            .capture_start => |cap| {
                try out_interface.print("CAP_START({d})\n", .{cap});
            },
            .capture_end => |cap| {
                try out_interface.print("CAP_END({d})\n", .{cap});
            },
            .atomic_start => {
                try out_interface.print("ATOMIC_START\n", .{});
            },
            .atomic_end => {
                try out_interface.print("ATOMIC_END\n", .{});
            },
            .lookahead_start => {
                try out_interface.print("LOOKAHEAD_START\n", .{});
            },
            .lookahead_end => {
                try out_interface.print("LOOKAHEAD_END\n", .{});
            },
            .lookbehind_start => |len| {
                try out_interface.print("LOOKBEHIND_START({d})\n", .{len});
            },
            .lookbehind_end => {
                try out_interface.print("LOOKBEHIND_END\n", .{});
            },
            .neg_lookahead_start => {
                try out_interface.print("NEG_LOOKAHEAD_START\n", .{});
            },
            .neg_lookahead_end => {
                try out_interface.print("NEG_LOOKAHEAD_END\n", .{});
            },
            .neg_lookbehind_start => |len| {
                try out_interface.print("NEG_LOOKBEHIND_START({d})\n", .{len});
            },
            .neg_lookbehind_end => {
                try out_interface.print("NEG_LOOKBEHIND_END\n", .{});
            },
            // else => {
            //     try out_interface.print("OTHER\n", .{});
            // }
        }
    }
}

fn emitLabel(allocator: anytype, labels: *std.ArrayList(usize), out_interface: anytype, instruction_ptr: *usize) !void {
    try labels.append(allocator, instruction_ptr.*);
    _ = out_interface;
    // try out_interface.print("LABEL {d}\n", .{labels.items.len - 1});
}

fn emitInstruction(out_interface: anytype, allocator: anytype, labels: *std.ArrayList(usize), instructions: *std.ArrayList(Instruction), fixups: *std.ArrayList(usize), data: Instruction, index_ptr: *usize) !usize {
    try instructions.append(allocator, data);
    index_ptr.* += 1;
    // _ = fixups;
    _ = labels;
    _ = out_interface;
    switch(data) {
        .jmp => {
            try fixups.append(allocator, index_ptr.* - 1);
            // try out_interface.print("JMP {d}\n", .{jmp});
        },
        .split => {
            try fixups.append(allocator, index_ptr.* - 1);
            // try out_interface.print("SPLIT {d} {d}\n", .{spl.left, spl.right});
        },
        .end_match => {
            // try out_interface.print("MATCH\n", .{});
        },
        else => {

        },
    }
    return index_ptr.* - 1;
}

fn emitRecursive(allocator: anytype, labels: *std.ArrayList(usize), instructions: *std.ArrayList(Instruction),
    fixups: *std.ArrayList(usize),
    out_interface: anytype, ast: *const core_regex_types.ASTNode, show_match_width: bool, instruction_ptr: *usize,
    recursion_level: usize) !void {
    // _ = out_interface;
    switch (ast.*) {
        .leaf_atom => |leaf| {
            _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{ .literal = leaf }, instruction_ptr);
        },
        .repetition => |rep| {
            switch (rep.reps.max) {
                .bounded => {
                },
                .unbounded => {
                },
            }
            try emitRecursive(allocator, labels, instructions, fixups, out_interface, rep.child, show_match_width, instruction_ptr, recursion_level + 1);
        },
        .alternation => |alt| {
            var jmp_end_indices = try std.ArrayList(usize).initCapacity(allocator, 2);
            defer jmp_end_indices.deinit(allocator);
            for (0..alt.parts.len-1) |i| {
                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                const split_index = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{.split = .{.left = labels.items.len, .right = 0}}, instruction_ptr); // fix this.
                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                try emitRecursive(allocator, labels, instructions, fixups, out_interface, alt.parts[i], show_match_width, instruction_ptr, recursion_level + 1);
                try jmp_end_indices.append(allocator, try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{ .jmp = 0 }, instruction_ptr));
                instructions.items[split_index].split.right = labels.items.len;

            }
            try emitLabel(allocator, labels, out_interface, instruction_ptr);
            try emitRecursive(allocator, labels, instructions, fixups, out_interface, alt.parts[alt.parts.len-1], show_match_width, instruction_ptr, recursion_level + 1);
            try jmp_end_indices.append(allocator, try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{ .jmp = 0 }, instruction_ptr));
            for (0..jmp_end_indices.items.len) |i| {
                instructions.items[jmp_end_indices.items[i]].jmp = labels.items.len;
            }
        },
        .group => |grp| {
            switch(grp.type) {
                .capturing => {
                    if (grp.id) |id| {
                        try emitLabel(allocator, labels, out_interface, instruction_ptr);
                        _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{ .capture_start =  id }, instruction_ptr);
                        try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                        try emitLabel(allocator, labels, out_interface, instruction_ptr);
                        _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{ .capture_end =  id }, instruction_ptr);
                    } else {
                        return core_regex_types.BytecodeGenError.InvalidGroupID;
                    }
                },
                .non_capturing => |grp_type| {
                    switch(grp_type) {
                        .atomic => {
                            try emitLabel(allocator, labels, out_interface, instruction_ptr);
                            _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .atomic_start, instruction_ptr);
                            try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                            try emitLabel(allocator, labels, out_interface, instruction_ptr);
                            _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .atomic_end, instruction_ptr);
                        },
                        .generic => {

                        },
                        .lookahead => {
                            if (grp.negated) {
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .neg_lookahead_start, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .neg_lookahead_end, instruction_ptr);
                            } else {
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .lookahead_start, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .lookahead_end, instruction_ptr);
                            }
                        },
                        .lookbehind => |look| {
                            if (grp.negated) {
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{.neg_lookbehind_start = look }, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .neg_lookbehind_end, instruction_ptr);
                            } else {
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{.lookbehind_start = look }, instruction_ptr);
                                try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                                try emitLabel(allocator, labels, out_interface, instruction_ptr);
                                _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .lookbehind_end, instruction_ptr);
                            }
                        }
                    }
                    // try emitRecursive(allocator, labels, instructions, fixups, out_interface, grp.expr, show_match_width, instruction_ptr, recursion_level + 1);
                },
            }
        },
        .concatenation => |concat| {
            for (0..concat.parts.len) |i| {
                try emitRecursive(allocator, labels, instructions, fixups, out_interface, concat.parts[i], show_match_width, instruction_ptr, recursion_level + 1);
            }
        },
        .class => |class_item| {
            // for (0..class_item.items.len) |i| {
            //     _ = try emitInstruction(out_interface, allocator, labels, instructions, fixups, .{ .literal = class_item.items[i] }, instruction_ptr);
            // }
        },
        .epsilon => {
        },
    }
}