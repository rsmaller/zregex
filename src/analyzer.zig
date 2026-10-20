const std = @import("std");
const ast_types = @import("ast_types.zig");
const core_types = @import("core_types.zig");
const repetition_types = @import("repetition_types.zig");
const type_reflection = @import("type_reflection.zig");

pub fn analyze(allocator: anytype, ast: *ast_types.ASTNode) !ast_types.AnalyzedAST {
    var j: usize = 1;
    try setGroupIDs(ast, &j);
    try trimAST(allocator, ast);
    var mapping = try mapNames(allocator, ast);
    errdefer {
        mapping.id_to_name_map.deinit();
        mapping.name_to_id_map.deinit();
    }
    return ast_types.AnalyzedAST{
        .ast = ast,
        .map = mapping,
        .group_count = j,
        .allocator = allocator,
    };
}

fn mapNames(allocator: anytype, ast: *ast_types.ASTNode) !core_types.NameIDMap {
    var name_to_id_map = std.StringHashMap(usize).init(allocator);
    var id_to_name_map = std.AutoHashMap(usize, []const u8).init(allocator);
    try mapNamesRecursive(allocator, &name_to_id_map, &id_to_name_map, ast);
    return .{ .name_to_id_map = name_to_id_map, .id_to_name_map = id_to_name_map };
}

fn mapNamesRecursive(allocator: anytype, name_to_id_map: *std.StringHashMap(usize), id_to_name_map: *std.AutoHashMap(usize, []const u8), ast: *ast_types.ASTNode) !void {
    switch (ast.*) {
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

fn setGroupIDs(ast: *ast_types.ASTNode, id: *usize) !void {
    switch (ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            switch (grp.type) {
                .capturing => {
                    ast.group.id = id.*;
                    id.* += 1;
                },
                .non_capturing => {
                    ast.group.id = null;
                },
            }
            try setGroupIDs(grp.expr, id);
        }, // outside of group, just recurse.
        .alternation => |alt| {
            for (alt.parts) |item| {
                try setGroupIDs(item, id);
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try setGroupIDs(item, id);
            }
        },
        .repetition => |rep| {
            try setGroupIDs(rep.child, id);
        },
        .class => {
            return;
        },
        else => {
            return;
        },
    }
}

fn isEqualBound(a: repetition_types.RepetitionRangeType, b: repetition_types.RepetitionRangeType) bool {
    if (@intFromEnum(a.max) != @intFromEnum(b.max)) return false;
    switch (a.max) {
        .bounded => {
            return (a.min == b.min) and (a.max.bounded == b.max.bounded);
        },
        .unbounded => {
            return a.min == b.min;
        },
    }
}

fn addBound(a: repetition_types.RepetitionRangeType, b: repetition_types.RepetitionRangeType) repetition_types.RepetitionRangeType {
    var result = a;
    result.min += b.min;
    switch (a.max) {
        .unbounded => {
            return result;
        },
        else => {
            switch (b.max) {
                .unbounded => {
                    result.max = .unbounded;
                    return result;
                },
                .bounded => {
                    result.max.bounded += b.max.bounded;
                    return result;
                },
            }
        },
    }
}

fn timesBound(a: repetition_types.RepetitionRangeType, b: repetition_types.RepetitionRangeType) repetition_types.RepetitionRangeType {
    var result = a;
    result.min *= b.min;
    switch (a.max) {
        .unbounded => {
            return result;
        },
        else => {
            switch (b.max) {
                .unbounded => {
                    result.max = .unbounded;
                    return result;
                },
                else => {
                    result.max.bounded *= b.max.bounded;
                    return result;
                },
            }
        },
    }
}

/// Constructs an AST length range by grabbing the smallest and largest length assertion of two given alternations.
/// i.e. (a){0,5}|(abc+) matches 0-5 characters on the left side and 3-inf on the right, therefore matches 0-inf.
fn alternationBound(a: repetition_types.RepetitionRangeType, b: repetition_types.RepetitionRangeType) repetition_types.RepetitionRangeType {
    var result = a;
    if (a.min > b.min) {
        result.min = b.min;
    }
    switch (a.max) {
        .unbounded => {
            return result;
        },
        else => {
            switch (b.max) {
                .unbounded => {
                    result.max = .unbounded;
                    return result;
                },
                else => {
                    if (a.max.bounded < b.max.bounded) {
                        result.max.bounded = b.max.bounded;
                    }
                    return result;
                },
            }
        },
    }
}

/// Checks the width of characters that may be represented by an AST; it does NOT check how many characters the resulting bytecode will consume.
/// Should only be used for analysis length assertions or debug printing.
pub fn matchRequirementRange(ast: *const ast_types.ASTNode) core_types.AnalysisError!repetition_types.RepetitionRangeType {
    var result = repetition_types.RepetitionRangeType{ .min = 0, .max = .{ .bounded = 0 } };
    switch (ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            return try matchRequirementRange(grp.expr);
        }, // outside of group, just recurse.
        .alternation => |alt| {
            result = try matchRequirementRange(alt.parts[0]);
            for (alt.parts[1..]) |item| {
                result = alternationBound(result, try matchRequirementRange(item));
            }
            return result;
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                result = addBound(result, try matchRequirementRange(item));
            }
            return result;
        },
        .repetition => |rep| {
            return timesBound(rep.reps, try matchRequirementRange(rep.child));
        },
        .class => {
            return repetition_types.RepetitionRangeType{ .min = 1, .max = .{ .bounded = 1 } };
        },
        .leaf_atom => |leaf| {
            switch (leaf.leaf_atom) {
                .word_boundary, .start_anchor, .end_anchor => {
                    return repetition_types.RepetitionRangeType{ .min = 0, .max = .{ .bounded = 0 } };
                },
                .backref => {
                    return core_types.AnalysisError.UnknownLength;
                },
                else => {
                    return repetition_types.RepetitionRangeType{ .min = 1, .max = .{ .bounded = 1 } };
                },
            }
        },
        .epsilon, .failed_parse => {
            return repetition_types.RepetitionRangeType{ .min = 0, .max = .{ .bounded = 0 } };
        },
    }
}

// Makes a copy of an array without duplicates, in-order. Assumes that pointer elements are heap-allocated and single-pointers.
// Types must be trivially comparable or structs/unions that implement an equals() method for duplicate checking.
fn removeDuplicates(allocator: anytype, arr: anytype) !@TypeOf(arr) {
    const T = @TypeOf(arr[0]);
    var list = try std.ArrayList(T).initCapacity(allocator, 1);
    var freed = try allocator.alloc(bool, arr.len);
    defer allocator.free(freed);
    @memset(freed, false);
    for (arr, 0..) |item, i| {
        if (freed[i]) continue;
        try list.append(allocator, item);
        for (i + 1..arr.len) |j| {
            if (type_reflection.genericEqualityDispatch(arr[i], arr[j])) {
                freed[j] = true;
                switch (@typeInfo(T)) {
                    .pointer => |ptr| {
                        if (ptr.child == ast_types.ASTNode) {
                            arr[j].deinit(allocator);
                        } else {
                            try allocator.free(arr[j]);
                        }
                    },
                    else => {},
                }
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn trimAST(allocator: anytype, ast: *ast_types.ASTNode) !void {
    switch (ast.*) {
        .group => |grp| {
            switch (grp.type) {
                .capturing => {},
                .non_capturing => |non_capt| {
                    switch (non_capt) {
                        .lookbehind => {
                            const len = matchRequirementRange(grp.expr) catch {
                                return core_types.ParsingError.VariableLookbehindRange;
                            };
                            switch (len.max) {
                                .unbounded => {
                                    return core_types.ParsingError.VariableLookbehindRange;
                                },
                                .bounded => {
                                    if (len.max.bounded != len.min) {
                                        return core_types.ParsingError.VariableLookbehindRange;
                                    }
                                    ast.group.type.non_capturing.lookbehind = len.max.bounded;
                                },
                            }
                        },
                        else => {},
                    }
                },
            }
            try trimAST(allocator, grp.expr);
        }, // outside of group, just recurse.
        .alternation => {
            const old_alt_parts = ast.alternation.parts;
            ast.alternation.parts = try removeDuplicates(allocator, ast.alternation.parts);
            allocator.free(old_alt_parts);
            for (ast.alternation.parts) |item| {
                try trimAST(allocator, item); // recurse after trimming.
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try trimAST(allocator, item);
            }
        },
        .repetition => |rep| {
            try trimAST(allocator, rep.child);
        },
        .class => {
            const old_cls_items = ast.class.items;
            ast.class.items = try removeDuplicates(allocator, ast.class.items);
            allocator.free(old_cls_items);
        },
        else => {
            return;
        },
    }
}
