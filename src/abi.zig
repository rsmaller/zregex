// Frontend for zregex dynamic lib containing CABI-compatible functions which call the zregex main library functions.
// The zregex module can itself be imported into a zig program as well.
const std = @import("std");
const zregex = @import("zregex");

var io_ref: ?*std.Io.Writer = null;
var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const BytecodeHandle = *opaque {}; // All translate to void * values in C header.
const PatternHandle = *opaque {};

fn CStyleOptional(T: type) type {
    return extern struct {
        value: T,
        present: bool,
    };
}

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
        grp_ptr[i] = @ptrCast(grp); // Reuse groups allocated in VM.
    }
    allocator.free(match_item.?.groups);
    allocation.* = Match{ .groups = grp_ptr, .group_count = match_item.?.groups.len, .pattern_ptr = @ptrCast(pat) };
    return allocation;
}

pub export fn zregex_name_index(match_handle: *Match, name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const pat: *zregex.Pattern = @ptrCast(@alignCast(match_handle.pattern_ptr));
    const cap_id: ?usize = pat.nameToId(std.mem.span(name));
    if (cap_id) |id| {
        return match_handle.groups[id];
    } else {
        return null;
    }
}

pub export fn zregex_id_index(match_handle: *Match, id: usize) callconv(.c) ?[*:0]const u8 {
    if (id < match_handle.group_count) {
        return match_handle.groups[id];
    } else {
        return null;
    }
}

// Returns a C-style optional that contains the id corresponding to a specific name in a ZRegex pattern.
pub export fn zregex_name_to_id(pattern_handle: PatternHandle, name: [*:0]const u8) callconv(.c) CStyleOptional(usize) {
    const pat: *zregex.Pattern = @ptrCast(@alignCast(pattern_handle));
    const cap_id: ?usize = pat.nameToId(std.mem.span(name));
    if (cap_id) |id| {
        return .{ .value = id, .present = true };
    } else {
        return .{ .value = undefined, .present = false };
    }
}

// Allocates a new string representing the name corresponding with the id, if present. (names are stored internally as non-sentinel slices of the string they're compiled from)
pub export fn zregex_id_to_name(pattern_handle: PatternHandle, id: usize) callconv(.c) ?[*:0]const u8 {
    const pat: *zregex.Pattern = @ptrCast(@alignCast(pattern_handle));
    const name = pat.idToName(id);
    if (name) |non_null_name| {
        var allocation: [*:0]u8 = allocator.allocSentinel(u8, non_null_name.len, 0) catch { return null; };
        @memcpy(allocation[0..non_null_name.len], non_null_name[0..]);
        return allocation;
    } else {
        return null;
    }
}

pub export fn zregex_destroy_name(name: [*:0]const u8) callconv(.c) void {
    allocator.free(std.mem.span(name));
}

pub export fn zregex_destroy_match(match_handle: *Match) callconv(.c) void {
    for (0..match_handle.group_count) |i| {
        if (match_handle.groups[i]) |curgrp| {
            allocator.free(curgrp[0..std.mem.len(curgrp):0]);
        }
    }
    allocator.free(match_handle.groups[0..match_handle.group_count]);
    allocator.destroy(match_handle);
}
