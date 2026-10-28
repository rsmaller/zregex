const std = @import("std");
const core_types = @import("core_types.zig");
const vm_execution_types = @import("vm_execution_types.zig");
const VMExecutionContext = vm_execution_types.VMExecutionContext;

pub fn match_index_correlate(allocator: anytype, pattern: *const core_types.Pattern, string: []const u8, match_item: vm_execution_types.IntermediateMatch) !core_types.Match {
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
    return core_types.Match{ .groups = group_arr, .pattern_ptr = pattern };
}

pub fn match(allocator: anytype, pattern: *const core_types.Pattern, string: []const u8) !?core_types.Match {
    var test_start_ptr: usize = 0;
    var main_context = try VMExecutionContext.init(allocator, test_start_ptr);
    const bytecode = pattern.bytecode;
    defer main_context.deinit(allocator); // Should deinit the stack and the groups array.
    switch (bytecode[0]) {
        .header_start => {},
        else => {
            return core_types.BytecodeGenError.UnexpectedBytecodeType;
        },
    }
    var i: usize = 1;
    while (i < bytecode.len) : (i += 1) {
        switch (bytecode[i]) {
            .allocate_groups => |alloc_instr| {
                if (main_context.groups) |_| {
                    return core_types.VMError.InvalidGroupAllocation;
                } else {
                    main_context.groups = try allocator.alloc(vm_execution_types.IntermediateMatchGroup, alloc_instr.size);
                    if (main_context.groups) |grps| {
                        @memset(grps, .{.start = 0, .end = null});
                    }
                }
            },
            .header_end => {
                i += 1; // Skip past header end for VM to use next instruction as the start.
                break;
            },
            else => {
                return core_types.VMError.InvalidStackArrangement; // bytecode[0] should be alloc_groups instruction.
            },
        }
    }
    if (i >= bytecode.len) {
        return core_types.VMError.BadHeaderScan;
    }
    while (test_start_ptr < string.len) : (test_start_ptr += 1) {
        main_context.ip = i; // ensure to reset ip every time. ip index 0 should be the ALLOC_GROUPS() instruction, which is run only once at the start.
        main_context.str_ptr = test_start_ptr;
        main_context.current_group_ptr = null;
        const current_match = try main_context.internal_match(allocator, bytecode, string);
        if (current_match) |success| { // check the match value for null
            return try match_index_correlate(allocator, pattern, string, success);
        }
    }
    return null;
}
