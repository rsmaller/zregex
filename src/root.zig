const std = @import("std");
pub const core_types = @import("core_types.zig");
pub const type_reflection = @import("type_reflection.zig");
pub const parser = @import("parser.zig");
pub const codegen = @import("codegen.zig");
pub const core_util = @import("core_util.zig");
pub const vm = @import("vm.zig");

pub const Pattern = core_types.Pattern;

pub const Match = core_types.SlicedMatch;

pub const ASTPrintOptions = extern struct {
    show_match_width: bool = false,
};

pub fn compile(allocator: anytype, str_to_parse: []const u8) !Pattern {
    var sized_ast = try parser.compile(allocator, str_to_parse);
    errdefer sized_ast.ast.deinit(allocator);
    var name_map = try codegen.mapNames(allocator, sized_ast.ast);
    errdefer {
        name_map.id_to_name_map.deinit();
        name_map.name_to_id_map.deinit();
    }
    const bytecode = try codegen.emit(allocator, sized_ast.ast, sized_ast.group_count);
    // No need to defer at end; failure means it was never allocated.
    return Pattern{
        .ast = sized_ast.ast,
        .map = name_map,
        .bytecode = bytecode,
        .allocator = allocator,
    };
}

pub fn printAST(out_interface: *std.Io.Writer, pattern: core_types.Pattern, options: ASTPrintOptions) void {
    if (pattern.ast) |ast| {
        printASTRecursive(out_interface, ast, options, 0) catch {};
    } else {
        out_interface.print("<Null AST>\n", .{}) catch {};
    }

}

pub fn printBytecode(out_interface: *std.Io.Writer, pattern: core_types.Pattern) void {
    const bytecode: []core_types.Instruction = pattern.bytecode;
    for (0..bytecode.len) |i| {
        out_interface.print("{d}:\t", .{i}) catch {};
        switch (bytecode[i]) {
            .header_start => {
                out_interface.print("HEADER_START\n", .{}) catch {};
            },
            .header_end => {
                out_interface.print("HEADER_END\n", .{}) catch {};
            },
            .allocate_groups => |alloc| {
                out_interface.print("ALLOC_GROUPS({d})\n", .{alloc.size}) catch {};
            },
            .split => |spl| {
                out_interface.print("SPLIT({d}, {d})\n", .{ spl.left, spl.right }) catch {};
            },
            .jmp => |jmp| {
                out_interface.print("JMP({d})\n", .{jmp}) catch {};
            },
            .repeat_start => |rep| {
                switch (rep.max) {
                    .bounded => {
                        out_interface.print("REP_START(min={d}, max={d}, esc={d}, {s})\n", .{ rep.min, rep.max.bounded, rep.escape_jmp, @tagName(rep.mode) }) catch {};
                    },
                    .unbounded => {
                        out_interface.print("REP_START(min={d}, max=inf, esc={d}, {s})\n", .{ rep.min, rep.escape_jmp, @tagName(rep.mode) }) catch {};
                    },
                }
            },
            .repeat_end => |rep_end| {
                out_interface.print("REP_END(jmp={d})\n", .{rep_end}) catch {};
            },
            .class => |class_binary| {
                out_interface.print("CLASS(", .{}) catch {};
                core_util.print_binary(out_interface, class_binary, .{ .show_leading_zeroes = false });
                out_interface.print(")\n", .{}) catch {};
            },
            .end_match => {
                out_interface.print("MATCH\n", .{}) catch {};
            },
            .literal => |lit| {
                printLiteralInstruction(out_interface, lit) catch {};
            },
            .capture_start => |cap| {
                out_interface.print("CAP_START(id={d})\n", .{cap}) catch {};
            },
            .capture_end => |cap| {
                out_interface.print("CAP_END(id={d})\n", .{cap}) catch {};
            },
            .atomic_start => {
                out_interface.print("ATOMIC_START\n", .{}) catch {};
            },
            .atomic_end => {
                out_interface.print("ATOMIC_END\n", .{}) catch {};
            },
            .lookahead_start => {
                out_interface.print("LOOKAHEAD_START\n", .{}) catch {};
            },
            .lookahead_end => {
                out_interface.print("LOOKAHEAD_END\n", .{}) catch {};
            },
            .lookbehind_start => |len| {
                out_interface.print("LOOKBEHIND_START(len={d})\n", .{len}) catch {};
            },
            .lookbehind_end => {
                out_interface.print("LOOKBEHIND_END\n", .{}) catch {};
            },
            .neg_lookahead_start => |jmp| {
                out_interface.print("NEG_LOOKAHEAD_START(jmp={d})\n", .{jmp}) catch {};
            },
            .neg_lookahead_end => {
                out_interface.print("NEG_LOOKAHEAD_END\n", .{}) catch {};
            },
            .neg_lookbehind_start => |neg_lookbehind| {
                out_interface.print("NEG_LOOKBEHIND_START(len={d}, jmp={d})\n", .{ neg_lookbehind.len, neg_lookbehind.jmp }) catch {};
            },
            .neg_lookbehind_end => {
                out_interface.print("NEG_LOOKBEHIND_END\n", .{}) catch {};
            },
        }
    }
}

// Internals.
fn printASTRecursive(out_interface: anytype, ast: *const core_types.ASTNode, options: ASTPrintOptions, recursion_level: usize) !void {
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
        .failed_parse => {
            try out_interface.print("FAILED_PARSE()\n", .{});
        },
    }
}

fn printLiteralInstruction(out_interface: anytype, instruction: core_types.LiteralInstruction) !void { // prints leaf of AST or bytecode.
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
