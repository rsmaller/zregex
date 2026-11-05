const std = @import("std");
const core_types = @import("core_types.zig");
const vm_execution_types = @import("vm_execution_types.zig");
const instruction_types = @import("instruction_types.zig");
const VMExecutionContext = vm_execution_types.VMExecutionContext;

pub fn matchIndexCorrelate(allocator: anytype, pattern: *const core_types.Pattern, string: []const u8, match_item: vm_execution_types.IntermediateMatch) !core_types.Match {
    var group_arr = try allocator.alloc(?[:0]const u8, match_item.groups.len);
    for (match_item.groups, 0..) |group, i| {
        if (group.end) |non_null_end| {
            const string_slice = string[group.start..non_null_end];
            const allocation = try allocator.allocSentinel(u8, string_slice.len, 0);
            @memcpy(allocation[0..string_slice.len], string_slice);
            allocation[string_slice.len] = 0;
            group_arr[i] = allocation[0..string_slice.len :0];
        } else {
            group_arr[i] = null;
        }
    }
    return core_types.Match{ .groups = group_arr, .pattern_ptr = pattern, .allocator = allocator };
}

fn matchContextStart(allocator: anytype, bytecode: []instruction_types.Instruction, i: *usize) !VMExecutionContext {
    i.* = 0;
    var group_alloc: ?[]vm_execution_types.IntermediateMatchGroup = null;
    errdefer {
        if (group_alloc) |_| {
            allocator.free(group_alloc.?);
        }
    }
    switch (bytecode[i.*]) {
        .header_start => {
            i.* += 1;
        },
        else => {
            return core_types.MatchError.BadHeaderScan;
        },
    }
    while (i.* < bytecode.len) : (i.* += 1) {
        switch (bytecode[i.*]) {
            .allocate_groups => |alloc_instr| {
                if (group_alloc) |_| {
                    return core_types.MatchError.DuplicateGroupAllocation;
                } else {
                    group_alloc = try allocator.alloc(vm_execution_types.IntermediateMatchGroup, alloc_instr.size);
                    @memset(group_alloc.?, .{.start = 0, .end = null});
                }
            },
            .header_end => {
                i.* += 1; // Skip past header end for VM to use next instruction as the start.
                break;
            },
            else => {
                return core_types.MatchError.BadHeaderScan;
            },
        }
    }
    if (i.* >= bytecode.len) {
        return core_types.MatchError.BadHeaderScan;
    }
    const result = try VMExecutionContext.init(allocator, group_alloc orelse {
        return core_types.MatchError.NoGroupAllocation;
    }, 0);
    return result;
}

pub fn match(allocator: anytype, pattern: *const core_types.Pattern, string: []const u8) !?core_types.Match {
    var i: usize = 0;
    const bytecode = pattern.bytecode;
    var main_context = try matchContextStart(allocator, bytecode, &i);
    defer main_context.deinit(allocator); // Should deinit the stack and the groups array.
    var test_start_ptr: usize = 0;
    while (test_start_ptr < string.len) : (test_start_ptr += 1) {
        main_context.ip = i; // ensure to reset ip every time. ip index 0 should be the ALLOC_GROUPS() instruction, which is run only once at the start.
        main_context.str_ptr = test_start_ptr;
        main_context.current_group_ptr = null;
        const current_match = try main_context.internalMatch(allocator, bytecode, string);
        if (current_match) |success| { // check the match value for null
            return try matchIndexCorrelate(allocator, pattern, string, success);
        }
    }
    return null;
}
