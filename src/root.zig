const std = @import("std");
const analyzer = @import("analyzer.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const printing = @import("printing.zig");
pub const type_reflection = @import("type_reflection.zig"); // Provided to the end user for declaration checks; they are useful!
pub const core_types = @import("core_types.zig"); // The only type interface to be exposed to the user.

// Re-namespaced to the root of the module to increase brevity of the type when used.
pub const Pattern = core_types.Pattern; // A fully compiled pattern with name mappings, the AST, and the bytecode.
pub const Match = core_types.Match;
pub const ASTPrintOptions = core_types.ASTPrintOptions;

pub fn printAST(out_interface: anytype, pattern: Pattern, options: ASTPrintOptions) void {
    printing.printAST(out_interface, pattern, options);
}

pub fn printBytecode(out_interface: anytype, pattern: Pattern) void {
    printing.printBytecode(out_interface, pattern);
}

pub fn compile(allocator: anytype, str_to_parse: []const u8) !Pattern {
    var ast = try parser.compileToAST(allocator, str_to_parse);
    var analyzed_ast = analyzer.analyze(allocator, ast) catch |err| { // Only deinit the ast directly if analysis fails.
        ast.deinit(allocator);
        return err;
    };
    errdefer analyzed_ast.deinit(); // If errors occur elsewhere, deinit the entire analyzed ast including ast.
    const bytecode = try codegen.emit(allocator, analyzed_ast);
    // No need to defer at end; failure means it was never allocated.
    return Pattern{
        .ast = analyzed_ast.ast,
        .map = analyzed_ast.map,
        .bytecode = bytecode,
        .allocator = allocator, // The compile function, analyzer, and codegen are all done under one allocator which is stored here.
    };
}


