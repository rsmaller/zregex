//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const core_regex_types = @import("core_regex_types.zig");
pub const regex_type_reflection = @import("regex_type_reflection.zig");
pub const regex_parser = @import("regex_parser.zig");
pub const regex_bytecode = @import("regex_bytecode.zig");

pub const Pattern = struct{
    ast: ?core_regex_types.AST,
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
