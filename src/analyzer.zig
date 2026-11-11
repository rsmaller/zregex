const std = @import("std");
const ast_types = @import("ast_types.zig");
const core_types = @import("core_types.zig");
const repetition_types = @import("repetition_types.zig");
const type_reflection = @import("type_reflection.zig");

pub fn analyze(allocator: anytype, ast: *ast_types.ASTNode) !ast_types.AnalyzedAST {
    var current_grp_id: usize = 1;
    try genericASTAnalyze(ast, &current_grp_id); // Analysis tree-walks split from trimming to simplify debugging; may be merged at a later date.
    try trimAST(allocator, ast);
    var mapping = try mapNames(allocator, ast);
    errdefer {
        mapping.id_to_name_map.deinit();
        destroyNameMap(allocator, &mapping.name_to_id_map); // name map owns name string allocations; therefore, it frees them.
    }
    try groupIDAnalyze(ast, current_grp_id, mapping);
    return ast_types.AnalyzedAST{
        .ast = ast,
        .map = mapping,
        .group_count = current_grp_id,
        .allocator = allocator,
    };
}

fn destroyNameMap(allocator: anytype, map: *std.StringHashMap(usize)) void {
    var iter = map.iterator();
    while (true) {
        const item = iter.next();
        if (item) |to_free| {
            allocator.free(to_free.key_ptr.*);
        }
        else { break; }
    }
    map.deinit();
}

fn mapNames(allocator: anytype, ast: *ast_types.ASTNode) !core_types.NameIDMap {
    var name_to_id_map = std.StringHashMap(usize).init(allocator);
    errdefer destroyNameMap(allocator, &name_to_id_map);
    var id_to_name_map = std.AutoHashMap(usize, []const u8).init(allocator);
    errdefer id_to_name_map.deinit();
    try mapNamesRecursive(allocator, &name_to_id_map, &id_to_name_map, ast);
    return .{ .name_to_id_map = name_to_id_map, .id_to_name_map = id_to_name_map, .allocator = allocator, };
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
                    const name_alloc = try allocator.dupe(u8, name); // Both hashmaps will share the same memory for keys/values.
                    errdefer allocator.free(name_alloc);
                    if (!(try name_to_id_map.getOrPut(name_alloc)).found_existing) {
                        try name_to_id_map.put(name_alloc, id);
                        try id_to_name_map.put(id, name_alloc);
                    } else {
                        return core_types.AnalysisError.DuplicateGroupName;
                    }
                } else {
                    return core_types.AnalysisError.NullGroupID;
                }
            }
            try mapNamesRecursive(allocator, name_to_id_map, id_to_name_map, grp.expr);
        },
        .repetition => |rep| {
            try mapNamesRecursive(allocator, name_to_id_map, id_to_name_map, rep.child);
        },
        .class, .failed_parse, .epsilon, .atom => {},
        // Does not use an else clause so the compiler errors when other cases that might need to be handled aren't.
    }
}

/// Recursively walks through the AST tree, sets group IDs using outvalue parameter id, and asserts semantic rules.
fn genericASTAnalyze(ast: *ast_types.ASTNode, id: *usize) !void {
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
            try genericASTAnalyze(grp.expr, id);
        }, // outside of group, just recurse.
        .alternation => |alt| {
            for (alt.parts) |item| {
                try genericASTAnalyze(item, id);
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try genericASTAnalyze(item, id);
            }
        },
        .repetition => |rep| {
            try assertRepetitionAllowance(rep.child);
            try genericASTAnalyze(rep.child, id);
        },
        .class => {
            return;
        },
        else => {
            return;
        },
    }
}

fn groupIDAnalyze(ast: *ast_types.ASTNode, group_count: usize, name_map: core_types.NameIDMap) !void {
    switch (ast.*) {
        .group => |grp| { // set ID, increment, and then recurse for group.
            try groupIDAnalyze(grp.expr, group_count, name_map);
        }, // outside of group, just recurse.
        .alternation => |alt| {
            for (alt.parts) |item| {
                try groupIDAnalyze(item, group_count, name_map);
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try groupIDAnalyze(item, group_count, name_map);
            }
        },
        .repetition => |rep| {
            try groupIDAnalyze(rep.child, group_count, name_map);
        },
        .class => {
            return;
        },
        .atom => |atom| {
            switch(atom.atom) {
                .backref_id => |id| {
                    if (id >= group_count) {
                        return core_types.AnalysisError.InvalidGroupID;
                    }
                },
                .backref_name => |name| {
                    if (!name_map.name_to_id_map.contains(name)) {
                        return core_types.AnalysisError.InvalidGroupName;
                    }
                },
                else => {},
            } 
        },
        else => {
            return;
        },
    }
}

fn assertRepetitionAllowance(atom: *ast_types.ASTNode) !void {
    switch (atom.*) { // Validate that node is allowed to be repeated.
        .group => {},
        .repetition, .epsilon => { // If *somehow* either of these happen, throw an error.
            return core_types.AnalysisError.InvalidRepetition;
        },
        .atom => |leaf| {
            switch (leaf.atom) {
                .end_anchor, .start_anchor, .word_boundary => {
                    return core_types.AnalysisError.InvalidRepetition;
                },
                else => {},
            }
        },
        else => {},
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
/// Should only be used for analysis length assertions, like lookbehinds, or debug printing.
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
        .atom => |leaf| {
            switch (leaf.atom) {
                .word_boundary, .start_anchor, .end_anchor => {
                    return repetition_types.RepetitionRangeType{ .min = 0, .max = .{ .bounded = 0 } };
                },
                .backref_name, .backref_id => {
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

/// Makes a copy of an array of AST nodes without duplicates, in-order. Assumes that pointer elements are heap-allocated and single-pointers.
fn removeDuplicatesAST(allocator: anytype, arr: []*ast_types.ASTNode) !@TypeOf(arr) {
    const T = @TypeOf(arr[0]);
    var list = try std.ArrayList(T).initCapacity(allocator, 1);
    errdefer list.deinit(allocator);
    var freed = try allocator.alloc(bool, arr.len);
    defer allocator.free(freed);
    @memset(freed, false);
    for (arr, 0..) |item, i| {
        if (freed[i]) continue;
        try list.append(allocator, item);
        for (i + 1..arr.len) |j| {
            if (arr[i].equals(arr[j])) {
                freed[j] = true;
                arr[j].deinit(allocator);
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Type-generic duplicate removal function. Makes a copy of an array without duplicates, in-order. Assumes that pointer 
/// elements are heap-allocated and single-pointers. Types must be trivially comparable or structs/unions that implement 
/// an equals() method for duplicate checking.
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
                    .pointer => |ptr| { // Function assumes AST-like structure where pointers are on the heap.
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
        .alternation => |*alt| {
            const old_alt_parts = alt.parts;
            alt.parts = try removeDuplicatesAST(allocator, alt.parts);
            allocator.free(old_alt_parts);
            if (alt.parts.len == 1) {
                const old_alt_item: *ast_types.ASTNode = @alignCast(alt.parts[0]);
                allocator.free(alt.parts);
                ast.* = old_alt_item.*; // Truncation trick that overwrites the alternation node with its first and only alternation.
                                        // This simplifies the AST and prevents single-alternation alternation nodes after analysis.
                                        // DO NOT ACCESS "alt" AFTER THIS LINE IN THIS SCOPE! The alternation tag is no longer active
                                        // after this line.
                allocator.destroy(old_alt_item);
                try trimAST(allocator, ast); // Re-trim AST as the truncated alternation part.
            } else {
                for (alt.parts) |item| {
                    try trimAST(allocator, item); // recurse after trimming.
                }
            }
        },
        .concatenation => |concat| {
            for (concat.parts) |item| {
                try trimAST(allocator, item);
            }
        },
        .repetition => |rep| {
            if (rep.reps.equals(.{.min = 1, .max = .{.bounded = 1}})) { // Truncation trick similar to one-alternation alternations. 
                const rep_to_free = rep.child;                          // This overwrites the current AST node with the repetition's 
                ast.* = rep.child.*;                                    // child when the repetition is meaningless (i.e. {1} or {1,1}).
                allocator.destroy(rep_to_free);                         // Again, do NOT access "rep" after the AST overwrite!
            } else {
                try trimAST(allocator, rep.child);
            }
        },
        .class => |*cls| {
            const old_cls_items = cls.items;
            cls.items = try removeDuplicates(allocator, cls.items);
            allocator.free(old_cls_items);
        },
        else => {
            return;
        },
    }
}
