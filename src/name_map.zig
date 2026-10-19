const std = @import("std");
const ast_types = @import("ast_types.zig");
const core_types = @import("core_types.zig");

pub const NameIDMap = struct {
    name_to_id_map: std.StringHashMap(usize),
    id_to_name_map: std.AutoHashMap(usize, []const u8),
};

pub fn mapNames(allocator: anytype, ast: *ast_types.ASTNode) !NameIDMap {
    var name_to_id_map = std.StringHashMap(usize).init(allocator);
    var id_to_name_map = std.AutoHashMap(usize, []const u8).init(allocator);
    try mapNamesRecursive(allocator, &name_to_id_map, &id_to_name_map, ast);
    return .{ .name_to_id_map = name_to_id_map, .id_to_name_map = id_to_name_map };
}

pub fn mapNamesRecursive(allocator: anytype, name_to_id_map: *std.StringHashMap(usize), id_to_name_map: *std.AutoHashMap(usize, []const u8), ast: *ast_types.ASTNode) !void {
    switch(ast.*) {
        .concatenation => |concat| {
            for (concat.parts) |part| {
                try mapNamesRecursive(allocator, name_to_id_map, id_to_name_map, part);
            }
        },
        .alternation => |alt| {
            for (alt.parts) |part| {
                try mapNamesRecursive(allocator, name_to_id_map, id_to_name_map, part);
            }
        },
        .group => |grp| {
            if (grp.name) |name| {
                if (grp.id) |id| {
                    try name_to_id_map.put(name, id);
                    try id_to_name_map.put(id, name);
                } else {
                    return core_types.BytecodeGenError.InvalidGroupID;
                }
            }
            try mapNamesRecursive(allocator, name_to_id_map, id_to_name_map, grp.expr);
        },
        .repetition => |rep| {
            try mapNamesRecursive(allocator, name_to_id_map, id_to_name_map, rep.child);
        },
        .class, .failed_parse, .epsilon, .leaf_atom => {},
        // Does not use an else clause so the compiler errors when other cases that might need to be handled aren't.
    }
}