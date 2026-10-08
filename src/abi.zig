// Frontend for zregex dynamic lib containing CABI-compatible functions which call the zregex main library functions.
// The zregex module can itself be imported into a zig program as well.
const std = @import("std");
const zregex = @import("zregex");

var io_ref: ?*std.Io.Writer = null;
var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const BytecodeHandle = *opaque {}; // All translate to void * values in C header.
const PatternHandle = *opaque {};

pub const Match = extern struct { // CABI-compatible reconstruction of zregex match struct with opaque pattern handle and char **groups.
    groups: [*]?[*:0]const u8,
    pattern_ptr: PatternHandle,
    group_count: usize,
};

pub export fn zregex_init_zig(io_handle: *std.Io.Writer) void { // Hooks into IO for zig files; C IO handle to be determined.
    io_ref = io_handle;
}

pub export fn zregex_print_bytecode(pattern_handle: PatternHandle) callconv(.c) void {
    const internal: *zregex.Pattern = @ptrCast(@alignCast(pattern_handle));
    if (io_ref) |io| {
        zregex.printBytecode(io, internal.*);
    } else {
        @panic("Null I/O reference cannot be accessed for printing. Please ensure library has been properly initialized!");
    }
}

pub export fn zregex_print_ast(pattern_handle: PatternHandle, options: zregex.ASTPrintOptions) callconv(.c) void {
    const internal: *zregex.Pattern = @ptrCast(@alignCast(pattern_handle));
    if (io_ref) |io| {
        zregex.printAST(io, internal.*, options);
    } else {
        @panic("Null I/O reference cannot be accessed for printing. Please ensure library has been properly initialized!");
    }
}

pub export fn zregex_compile(str: [*:0]u8) callconv(.c) ?PatternHandle {
    const string: []u8 = std.mem.span(str);
    var pattern: zregex.Pattern = zregex.compile(allocator, string) catch {
        return null;
    };
    const ret = allocator.create(zregex.Pattern) catch {
        pattern.deinit();
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
