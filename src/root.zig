const std = @import("std");
pub const core_regex_types = @import("core_regex_types.zig");
pub const regex_type_reflection = @import("regex_type_reflection.zig");
pub const regex_parser = @import("regex_parser.zig");
pub const regex_bytecode = @import("regex_bytecode.zig");

pub const Pattern = struct{
    ast: ?core_regex_types.AST,
    bytecode: []regex_bytecode.Instruction,
};

pub const ASTPrintOptions = core_regex_types.ASTPrintOptions; // re-namespacing print options type for easier interfacing.

pub fn compile(allocator: anytype, str_to_parse: []const u8) anyerror!Pattern {
    const ast = try regex_parser.compile(allocator, str_to_parse);
    return Pattern{
        .ast = ast,
        .bytecode = try regex_bytecode.emit(allocator, ast),
    };
}

pub const printAST = regex_parser.printAST;
pub const printBytecode = regex_bytecode.readOutBytecode;

pub fn destroyPattern(allocator: anytype, pattern: Pattern) !void {
    if (pattern.ast) |ast| {
        try regex_parser.destroyAST(allocator, ast);
    }
    allocator.free(pattern.bytecode);
}
