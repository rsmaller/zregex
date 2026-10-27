const std = @import("std");
const analyzer = @import("analyzer.zig");
const core_types = @import("core_types.zig");
const ast_types = @import("ast_types.zig");
const instruction_types = @import("instruction_types.zig");

pub fn printBytecode(out_interface: anytype, pattern: core_types.Pattern) void {
    const bytecode: []instruction_types.Instruction = pattern.bytecode;
    for (0..bytecode.len) |i| {
        out_interface.print("{d}:\t", .{i}) catch |err| {
            std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
        };
        switch (bytecode[i]) {
            .header_start => {
                out_interface.print("HEADER_START\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .header_end => {
                out_interface.print("HEADER_END\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .allocate_groups => |alloc| {
                out_interface.print("ALLOC_GROUPS({d})\n", .{alloc.size}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .split => |spl| {
                out_interface.print("SPLIT({d}, {d})\n", .{ spl.left, spl.right }) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .jmp => |jmp| {
                out_interface.print("JMP({d})\n", .{jmp}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .repeat_start => |rep| {
                switch (rep.max) {
                    .bounded => {
                        out_interface.print("REP_START(min={d}, max={d}, esc={d}, {s})\n", .{ rep.min, rep.max.bounded, rep.escape_jmp, @tagName(rep.mode) }) catch |err| {
                            std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                        };
                    },
                    .unbounded => {
                        out_interface.print("REP_START(min={d}, max=inf, esc={d}, {s})\n", .{ rep.min, rep.escape_jmp, @tagName(rep.mode) }) catch |err| {
                            std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                        };
                    },
                }
            },
            .repeat_end => |rep_end| {
                out_interface.print("REP_END(jmp={d})\n", .{rep_end}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .class => |class_binary| {
                out_interface.print("CLASS(", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
                printBinary(out_interface, class_binary, .{ .show_leading_zeroes = false });
                out_interface.print(")\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .end_match => {
                out_interface.print("MATCH\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .literal => |lit| {
                printLiteralInstruction(out_interface, lit) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .capture_start => |cap| {
                out_interface.print("CAP_START(id={d})\n", .{cap}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .capture_end => |cap| {
                out_interface.print("CAP_END(id={d})\n", .{cap}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .atomic_start => {
                out_interface.print("ATOMIC_START\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .atomic_end => {
                out_interface.print("ATOMIC_END\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .lookahead_start => {
                out_interface.print("LOOKAHEAD_START\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .lookahead_end => {
                out_interface.print("LOOKAHEAD_END\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .lookbehind_start => |len| {
                out_interface.print("LOOKBEHIND_START(len={d})\n", .{len}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .lookbehind_end => {
                out_interface.print("LOOKBEHIND_END\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .neg_lookahead_start => |jmp| {
                out_interface.print("NEG_LOOKAHEAD_START(jmp={d})\n", .{jmp}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .neg_lookahead_end => {
                out_interface.print("NEG_LOOKAHEAD_END\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .neg_lookbehind_start => |neg_lookbehind| {
                out_interface.print("NEG_LOOKBEHIND_START(len={d}, jmp={d})\n", .{ neg_lookbehind.len, neg_lookbehind.jmp }) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .neg_lookbehind_end => {
                out_interface.print("NEG_LOOKBEHIND_END\n", .{}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
            .backref => |id| {
                out_interface.print("BACKREF(id={d})\n", .{id}) catch |err| {
                    std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
                };
            },
        }
    }
}

fn printBinary(out_interface: anytype, binval: anytype, options: struct { show_leading_zeroes: bool = false }) void { // Accepts an integer and prints out its binary with the respective width.
    const T = @TypeOf(binval);
    const info = @typeInfo(T);
    const bitlength = @sizeOf(T) * 8;
    var digit_arr: [bitlength]u1 = [1]u1{0} ** bitlength;
    switch (info) {
        .int => {
            var digit_arr_index: usize = @as(usize, bitlength) - 1;
            var next: T = binval;
            while (digit_arr_index > 0 and next > 0) {
                digit_arr[digit_arr_index] = @as(u1, @truncate(next & 1));
                digit_arr_index -= 1;
                next >>= 1;
            }
            digit_arr[0] = @as(u1, @truncate(next & 1));
            const filled_data: usize = bitlength - digit_arr_index;
            if (options.show_leading_zeroes) {
                for (0..digit_arr.len) |i| {
                    out_interface.print("{d}", .{digit_arr[i]}) catch {};
                }
            } else {
                for (digit_arr.len - filled_data + 1..digit_arr.len) |i| {
                    out_interface.print("{d}", .{digit_arr[i]}) catch {};
                }
            }
        },
        else => {
            @compileError("Invalid type " ++ @typeName(T) ++ " passed to printBinary()");
        },
    }
}

pub fn printAST(out_interface: anytype, pattern: core_types.Pattern, options: core_types.ASTPrintOptions) void {
    if (pattern.ast) |ast| {
        printASTRecursive(out_interface, ast, options, 0) catch |err| {
            std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
        };
    } else {
        out_interface.print("<Null AST>\n", .{}) catch |err| {
            std.debug.print("Error encountered in zregex: {s}\n", .{@errorName(err)});
        };
    }
}

// Internals.
fn printASTRecursive(out_interface: anytype, ast: *ast_types.ASTNode, options: core_types.ASTPrintOptions, recursion_level: usize) !void {
    for (0..recursion_level) |_| {
        try out_interface.print("\t", .{});
    }
    if (options.show_match_width) {
        const len = analyzer.matchRequirementRange(ast);
        if (len) |non_error_len| {
            switch (non_error_len.max) {
                .bounded => {
                    try out_interface.print("[Requisite match width is {d} - {d}] -> ", .{ non_error_len.min, non_error_len.max.bounded });
                },
                .unbounded => {
                    try out_interface.print("[Requisite match width is {d} - inf] -> ", .{non_error_len.min});
                },
            }
        } else |err| {
            switch (err) {
                error.UnknownLength => {
                    try out_interface.print("[Requisite match width is UNKNOWN] -> ", .{});
                },
                else => {
                    return err;
                }
            }
        }
    }
    switch (ast.*) {
        .atom => |leaf| {
            try printAtom(out_interface, leaf);
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
                try printAtom(out_interface, class_item.items[i]);
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

fn printLiteralInstruction(out_interface: anytype, instruction: instruction_types.LiteralInstruction) !void { // prints leaf of AST or bytecode.
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

fn printAtom(out_interface: anytype, leaf: ast_types.AtomNode) !void { // prints leaf of AST or bytecode.
    switch (leaf.atom) {
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
        .backref => |id| {
            try out_interface.print("BACKREF(id = {d})\n", .{id});
        },
        else => {
            try out_interface.print("LITERAL(item = {s}, negated = {})\n", .{ @tagName(leaf.atom), leaf.inverted });
        },
    }
}