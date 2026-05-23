//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const regex_type_reflection = @import("regex_type_reflection.zig");
const regex_parser = @import("regex_parser.zig");

pub const Pattern = struct{
    ast: ?regex_parser.AST,
    // instructions: []Instruction,
};

pub fn compile(allocator: anytype, str_to_parse: []const u8) anyerror!Pattern {
    const ast = try regex_parser.compile(allocator, str_to_parse);
    return Pattern{
        .ast = ast,
        // .instructions = regex_bytecode.emit(ast) or something like that.
    };
}

pub const printAST = regex_parser.printAST;

pub fn destroyPattern(allocator: anytype, pattern: Pattern) !void {
    if (pattern.ast) |ast| {
        try regex_parser.destroyAST(allocator, ast);
    }
    // add destructor for bytecode here.
}
