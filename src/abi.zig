const std = @import("std");
const zregex = @import("zregex");

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const BytecodeHandle = *opaque {};
const PatternHandle = *opaque {};

pub const Match = extern struct {
    groups: [*]?[*:0]const u8,
    pattern_ptr: PatternHandle,
    group_count: usize,
};

// export const print_ast = zregex.printAST;

// pub export fn print_bytecode(out_interface: *std.Io.Writer, bytecode: BytecodeHandle) callconv(.c) void {
//     const internal: *[]zregex.core_types.Instruction = @ptrCast(@alignCast(bytecode));
//     zregex.printBytecode(out_interface, internal.*);
// }

pub export fn zregex_compile(str_to_parse: [*:0]u8) callconv(.c) ?PatternHandle {
    const string: []u8 = std.mem.span(str_to_parse);
    const pattern: zregex.Pattern = zregex.compile(allocator, string) catch {
        return null;
    };
    const ret = allocator.create(zregex.Pattern) catch {
        return null;
    };
    ret.* = pattern;
    return @ptrCast(ret);
}

pub export fn zregex_destroy_pattern(pattern_handle: PatternHandle) callconv(.c) void {
    const pat: *zregex.Pattern = @ptrCast(@alignCast(pattern_handle));
    pat.deinit();
    allocator.destroy(pat);
}

pub export fn zregex_match(pattern_handle: PatternHandle, string: [*:0]u8) callconv(.c) ?*Match {
    const pat: *zregex.Pattern = @ptrCast(@alignCast(pattern_handle));
    const str = std.mem.span(string);
    const match_item = pat.match(allocator, str) catch {
        return null;
    };
    if (match_item) |_| {} else {
        return null;
    }
    const allocation = allocator.create(Match) catch {
        return null;
    };
    const grp_alloc = allocator.alloc(?[*:0]const u8, match_item.?.groups.len) catch {
        allocator.destroy(allocation);
        return null;
    };
    const grp_ptr: [*]?[*:0]const u8 = @ptrCast(grp_alloc.ptr);
    for (match_item.?.groups, 0..) |grp, i| {
        grp_ptr[i] = @ptrCast(grp);
    }
    allocator.free(match_item.?.groups);
    allocation.* = Match{ .groups = grp_ptr, .group_count = match_item.?.groups.len, .pattern_ptr = @ptrCast(pat) };
    return allocation;
}

pub export fn zregex_destroy_match(match_handle: *Match) callconv(.c) void {
    for (0..match_handle.group_count) |i| {
        if (match_handle.groups[i]) |curgrp| {
            allocator.free(curgrp[0 .. std.mem.len(curgrp) + 1]);
        }
    }
    allocator.free(match_handle.groups[0..match_handle.group_count]);
    allocator.destroy(match_handle);
}
