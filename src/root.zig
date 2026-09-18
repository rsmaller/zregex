const std = @import("std");
pub const core_types = @import("core_types.zig");
pub const type_reflection = @import("type_reflection.zig");
pub const parser = @import("parser.zig");
pub const codegen = @import("codegen.zig");
pub const core_util = @import("core_util.zig");
pub const vm = @import("vm.zig");

pub const Pattern = struct {
    ast: ?core_types.AST,
    bytecode: []codegen.Instruction,
    pub fn match(self: *const Pattern, allocator: anytype, string: []const u8) !Match {
        return try vm.match(allocator, self.bytecode, string);
    }
};

pub const Match = vm.Match;

pub const ASTPrintOptions = core_types.ASTPrintOptions; // re-namespacing print options type for easier interfacing.

pub fn compile(allocator: anytype, str_to_parse: []const u8) anyerror!Pattern {
    const sized_ast = try parser.compile(allocator, str_to_parse);
    return Pattern{
        .ast = sized_ast.ast,
        .bytecode = try codegen.emit(allocator, sized_ast.ast, sized_ast.group_count),
    };
}

pub fn printAST(out_interface: anytype, ast: core_types.AST, options: core_types.ASTPrintOptions) !void {
    try printASTRecursive(out_interface, ast, options, 0);
}
pub fn printBytecode(allocator: anytype, out_interface: anytype, bytecode: []codegen.Instruction) !void {
    for (0..bytecode.len) |i| {
        try out_interface.print("{d}:\t", .{i});
        switch (bytecode[i]) {
            .allocate_groups => |alloc| {
                try out_interface.print("ALLOC_GROUPS({d})\n", .{alloc.size});
            },
            .split => |spl| {
                try out_interface.print("SPLIT({d}, {d})\n", .{ spl.left, spl.right });
            },
            .jmp => |jmp| {
                try out_interface.print("JMP({d})\n", .{jmp});
            },
            .repeat_start => |rep| {
                switch (rep.max) {
                    .bounded => {
                        try out_interface.print("REP_START(min={d}, max={d}, {s})\n", .{ rep.min, rep.max.bounded, @tagName(rep.mode) });
                    },
                    .unbounded => {
                        try out_interface.print("REP_START(min={d}, max=inf, {s})\n", .{ rep.min, @tagName(rep.mode) });
                    },
                }
            },
            .repeat_end => |rep_end| {
                try out_interface.print("REP_END(jmp={d})\n", .{rep_end});
            },
            .class => |class_binary| {
                try out_interface.print("CLASS(", .{});
                try core_util.print_binary(allocator, out_interface, class_binary, .{ .show_leading_zeroes = false });
                try out_interface.print(")\n", .{});
            },
            .end_match => {
                try out_interface.print("MATCH\n", .{});
            },
            .literal => |lit| {
                try printLiteralInstruction(out_interface, lit);
            },
            .capture_start => |cap| {
                try out_interface.print("CAP_START(id={d})\n", .{cap});
            },
            .capture_end => |cap| {
                try out_interface.print("CAP_END(id={d})\n", .{cap});
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
                try out_interface.print("LOOKBEHIND_START(len={d})\n", .{len});
            },
            .lookbehind_end => |len| {
                try out_interface.print("LOOKBEHIND_END(len={d})\n", .{len});
            },
            .neg_lookahead_start => {
                try out_interface.print("NEG_LOOKAHEAD_START\n", .{});
            },
            .neg_lookahead_end => {
                try out_interface.print("NEG_LOOKAHEAD_END\n", .{});
            },
            .neg_lookbehind_start => |len| {
                try out_interface.print("NEG_LOOKBEHIND_START(len={d})\n", .{len});
            },
            .neg_lookbehind_end => |len| {
                try out_interface.print("NEG_LOOKBEHIND_END(len={d})\n", .{len});
            },
        }
    }
}

pub fn destroyPattern(allocator: anytype, pattern: Pattern) !void {
    if (pattern.ast) |ast| {
        try parser.destroyAST(allocator, ast);
    }
    allocator.free(pattern.bytecode);
}

// Internals.
fn printASTRecursive(out_interface: anytype, ast: *const core_types.ASTNode, options: core_types.ASTPrintOptions, recursion_level: usize) !void {
    for (0..recursion_level) |_| {
        try out_interface.print("\t", .{});
    }
    const len: core_types.RepetitionRangeType = parser.matchRequirementRange(ast);
    if (options.show_match_width) {
        switch (len.max) {
            .bounded => {
                try out_interface.print("[Requisite match width is {d} - {d}] -> ", .{ len.min, len.max.bounded });
            },
            .unbounded => {
                try out_interface.print("[Requisite match width is {d} - inf] -> ", .{len.min});
            },
        }
    }
    switch (ast.*) {
        .leaf_atom => |leaf| {
            try printLeafAtom(out_interface, leaf);
        },
        .repetition => |rep| {
            switch (rep.reps.max) {
                .bounded => {
                    try out_interface.print("REPETITION(min = {}, max = {}, type = {s})\n", .{ rep.reps.min, rep.reps.max.bounded, @tagName(rep.rep_type) });
                },
                .unbounded => {
                    try out_interface.print("REPETITION(min = {}, max = inf, type = {s})\n", .{ rep.reps.min, @tagName(rep.rep_type) });
                },
            }
            try printASTRecursive(out_interface, rep.child, options, recursion_level + 1);
        },
        .alternation => |alt| {
            try out_interface.print("ALTERNATION()\n", .{});
            for (0..alt.parts.len) |i| {
                try printASTRecursive(out_interface, alt.parts[i], options, recursion_level + 1);
            }
        },
        .group => |grp| {
            try out_interface.print("GROUP(id = {?}, name = {?s}, type = {s}.", .{ grp.id, grp.name, @tagName(grp.type) });
            switch (grp.type) {
                .capturing => {
                    try out_interface.print("{s}, ", .{@tagName(grp.type.capturing)});
                },
                .non_capturing => {
                    try out_interface.print("{s}, ", .{@tagName(grp.type.non_capturing)});
                },
            }
            try out_interface.print("negated = {})\n", .{grp.negated});
            try printASTRecursive(out_interface, grp.expr, options, recursion_level + 1);
        },
        .concatenation => |concat| {
            try out_interface.print("CONCATENATION()\n", .{});
            for (0..concat.parts.len) |i| {
                try printASTRecursive(out_interface, concat.parts[i], options, recursion_level + 1);
            }
        },
        .class => |class_item| {
            try out_interface.print("CLASS(negated = {})\n", .{class_item.negated});
            for (0..class_item.items.len) |i| {
                for (0..recursion_level + 1) |_| {
                    try out_interface.print("\t", .{});
                }
                try printLeafAtom(out_interface, class_item.items[i]);
            }
        },
        .epsilon => {
            try out_interface.print("EPSILON()\n", .{});
        },
    }
}

fn printLiteralInstruction(out_interface: anytype, instruction: codegen.LiteralInstruction) !void { // prints leaf of AST or bytecode.
    switch (instruction.data) {
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
        else => {
            try out_interface.print("LITERAL(item = {s}, negated = {})\n", .{ @tagName(instruction.data), instruction.inverted });
        },
    }
}

fn printLeafAtom(out_interface: anytype, leaf: core_types.LeafAtomNode) !void { // prints leaf of AST or bytecode.
    switch (leaf.leaf_atom) {
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
            try out_interface.print("RANGE(min = {s}, max = {s})\n", .{ buf, buf2 });
        },
        else => {
            try out_interface.print("LITERAL(item = {s}, negated = {})\n", .{ @tagName(leaf.leaf_atom), leaf.inverted });
        },
    }
}

