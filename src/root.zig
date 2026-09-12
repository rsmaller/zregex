const std = @import("std");
pub const core_regex_types = @import("core_regex_types.zig");
pub const regex_type_reflection = @import("regex_type_reflection.zig");
pub const regex_parser = @import("regex_parser.zig");
pub const regex_bytecode = @import("regex_bytecode.zig");
pub const regex_gen_util = @import("regex_gen_util.zig");
pub const regex_vm = @import("regex_vm.zig");

pub const Pattern = struct {
    ast: ?core_regex_types.AST,
    bytecode: []regex_bytecode.Instruction,
    pub fn match(self: *const Pattern, allocator: anytype, string: []const u8) !Match {
        return try regex_vm.match(allocator, self.bytecode, string);
    }
};

pub const Match = regex_vm.Match;

pub const ASTPrintOptions = core_regex_types.ASTPrintOptions; // re-namespacing print options type for easier interfacing.

pub fn compile(allocator: anytype, str_to_parse: []const u8) anyerror!Pattern {
    const ast = try regex_parser.compile(allocator, str_to_parse);
    return Pattern{
        .ast = ast,
        .bytecode = try regex_bytecode.emit(allocator, ast),
    };
}

pub fn printAST(out_interface: anytype, ast: core_regex_types.AST, options: core_regex_types.ASTPrintOptions) !void {
    try printASTRecursive(out_interface, ast, options, 0);
}
pub fn printBytecode(allocator: anytype, out_interface: anytype, bytecode: []regex_bytecode.Instruction) !void {
    for (0..bytecode.len) |i| {
        try out_interface.print("{d}:\t", .{i});
        switch(bytecode[i]) {
            .split => |spl| {
                try out_interface.print("SPLIT({d}, {d})\n", .{spl.left, spl.right});
            },
            .jmp => |jmp| {
                try out_interface.print("JMP({d})\n", .{jmp});
            },
            .repeat_start => |rep| {
                switch(rep.max) {
                    .bounded => {
                        try out_interface.print("REP_START({d}, {d}, {s})\n", .{rep.min, rep.max.bounded, @tagName(rep.mode)});
                    },
                    .unbounded => {
                        try out_interface.print("REP_START({d}, inf, {s})\n", .{rep.min, @tagName(rep.mode)});
                    }
                }
            },
            .repeat_end => {
                try out_interface.print("REP_END\n", .{});
            },
            .class => |class_binary| {
                try out_interface.print("CLASS(", .{});
                try regex_gen_util.print_binary(allocator, out_interface, class_binary, .{.show_leading_zeroes = false});
                try out_interface.print(")\n", .{});
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
        }
    }
}

pub fn destroyPattern(allocator: anytype, pattern: Pattern) !void {
    if (pattern.ast) |ast| {
        try regex_parser.destroyAST(allocator, ast);
    }
    allocator.free(pattern.bytecode);
}

// Internals.
fn printASTRecursive(out_interface: anytype, ast: *const core_regex_types.ASTNode, options: core_regex_types.ASTPrintOptions, recursion_level: usize) !void {
    for (0..recursion_level) |_| {
        try out_interface.print("\t", .{});
    }
    const len: core_regex_types.RepetitionRangeType = regex_parser.matchRequirementRange(ast);
    if (options.show_match_width) {
        switch (len.max) {
            .bounded => {
                try out_interface.print("[Requisite match width is {d} - {d}] -> ", .{len.min, len.max.bounded});
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
                    try out_interface.print("REPETITION(min = {}, max = {}, type = {s})\n", .{rep.reps.min, rep.reps.max.bounded, @tagName(rep.rep_type)});
                },
                .unbounded => {
                    try out_interface.print("REPETITION(min = {}, max = inf, type = {s})\n", .{rep.reps.min, @tagName(rep.rep_type)});
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
            try out_interface.print("GROUP(id = {?}, name = {?s}, type = {s}.", .{grp.id, grp.name, @tagName(grp.type)});
            switch(grp.type) {
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
                for (0..recursion_level+1) |_| {
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

fn printLeafAtom(out_interface: anytype, leaf: core_regex_types.LeafAtomNode) !void { // prints leaf of AST or bytecode.
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