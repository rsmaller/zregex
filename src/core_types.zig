// The core file which contains the primary user-facing types, marked pub.
const std = @import("std");
const type_reflection = @import("type_reflection.zig");
const vm = @import("vm.zig");

// Imported types from sorted files.
const ast_types = @import("ast_types.zig");
const instruction_types = @import("instruction_types.zig");

pub const NameIDMap = struct {
    name_to_id_map: std.StringHashMap(usize),
    id_to_name_map: std.AutoHashMap(usize, []const u8),
};

pub const Pattern = struct {
    ast: ?*ast_types.ASTNode,
    map: NameIDMap,
    bytecode: []instruction_types.Instruction,
    allocator: std.mem.Allocator,
    pub fn match(self: *const Pattern, allocator: anytype, string: []const u8) !?Match {
        return try vm.match(allocator, self, string);
    }
    pub fn deinit(self: *@This()) void {
        if (self.ast) |ast| {
            ast.deinit(self.allocator);
        }
        self.allocator.free(self.bytecode);
        self.map.name_to_id_map.deinit();
        self.map.id_to_name_map.deinit();
    }
    pub fn nameToId(self: *const @This(), name: []const u8) ?usize {
        return self.map.name_to_id_map.get(name);
    }
    pub fn idToName(self: *const @This(), id: usize) ?[]const u8 {
        return self.map.id_to_name_map.get(id);
    }
};

pub const Match = struct {
    groups: []?[:0]const u8,
    pattern_ptr: *const Pattern,
    pub fn deinit(self: *const @This(), allocator: anytype) void {
        for (self.groups) |grp| {
            if (grp) |non_null_grp| {
                allocator.free(non_null_grp);
            }
        }
        allocator.free(self.groups);
    }
    pub fn nameIndex(self: *const @This(), name: []const u8) ?[]const u8 {
        if (self.pattern_ptr.nameToId(name)) |id| {
            return self.groups[id];
        }
        return null;
    }
    pub fn idIndex(self: *const @This(), id: usize) ?[]const u8 {
        return self.groups[id];
    }
};

pub const ParsingError = error{
    TokenNotFound,
    EndOfString,
    InvalidRange,
    VariableLookbehindRange,
    InvalidGroupName,
};

pub const BytecodeGenError = error{
    InvalidGroupID,
    InvalidClassMember,
    InvalidTypeConversion,
    UnexpectedBytecodeType,
};

pub const VMError = error{
    InvalidGroupAllocation,
    InvalidStackArrangement,
    BadHeaderScan,
    StackEmptyError,
    InvalidStackAccess,
    NullIndexAccess,
};

pub const AnalysisError = error{
    UnknownLength,
};
