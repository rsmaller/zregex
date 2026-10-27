// Contains other VM execution related types that are not directly baked into the VM's execution context.
const std = @import("std");
const core_types = @import("core_types.zig");
const repetition_types = @import("repetition_types.zig");

pub const VMExecutionContext = @import("vm_execution_context.zig"); // Execution context file exposed as a type.

pub const IntermediateMatch = struct { // Intermediary representation of matches before they are returned to the user.
    groups: []const ?IntermediateMatchGroup,
};

pub const IntermediateMatchGroup = struct {
    start: usize, // Slices of original string passed in.
    end: usize,
};

pub const RepeatStackFrame = struct { // Reused RepeatStackFrame from repeat bytecode instruction. Unsure if needed.
    min: usize,
    max: repetition_types.RepetitionBoundType,
    mode: repetition_types.RepeaterType,
    previous_rep_ptr: ?usize,
    previous_str_ptr: usize,
    current_count: usize,
    escape_jmp_index: usize,
};

pub const ChoicePointStackFrame = struct {
    backtrack_ip: usize,
    stack_depth: usize,
    backtrack_str_ptr: usize,
    previous_count: usize,
    previous_rep_ptr: ?usize,
};

pub const GroupStackFrame = struct {
    current_group: usize,
    previous_group_ptr: ?usize, // the index that points to the previous group frame.
};

pub const LookaheadStackFrame = struct {
    saved_str_ptr: usize,
    negative: bool,
    jmp_index: ?usize,
};

pub const StackFrame = union(enum) {
    choice_point: ChoicePointStackFrame,
    repeat: RepeatStackFrame,
    group: GroupStackFrame,
    lookahead: LookaheadStackFrame,
    atomic: void, // doesn't have to do anything for now.
};

pub fn Stack(T: type) type {
    return struct {
        data: []T,
        size: usize,
        pub fn init(allocator: anytype) !Stack(T) {
            return .{
                .data = try allocator.alloc(T, 4),
                .size = 0,
            };
        }
        pub fn len(self: *const @This()) usize { // Returns the length of memory the stack contains.
            return self.data.len;
        }
        pub fn elementCount(self: *const @This()) usize { // Returns how many elements are in the stack currently.
            return self.size;
        }
        pub fn deinit(self: *@This(), allocator: anytype) void {
            allocator.free(self.data);
        }
        pub fn push(self: *@This(), allocator: anytype, item: T) !void {
            if (self.size >= self.data.len / 2) { // Dynamic doubling of array.
                self.data = try allocator.realloc(self.data, self.data.len * 2);
            }
            self.data[self.size] = item;
            self.size += 1;
        }
        pub fn pop(self: *@This(), allocator: anytype) !T {
            if (self.size == 0) {
                return core_types.VMError.StackEmptyError;
            }
            self.size -= 1;
            const ret: T = self.data[self.size];
            if (self.size <= self.data.len / 4) { // Dynamic halving of array.
                self.data = try allocator.realloc(self.data, self.data.len / 2);
            }
            return ret;
        }
        pub fn peek(self: *@This()) !T {
            if (!self.hasItem()) {
                return core_types.VMError.StackEmptyError;
            }
            return self.data[self.size - 1];
        }
        pub fn fetchPtrAtIndex(self: *@This(), index: usize) !*T {
            if (index >= self.size) {
                return core_types.VMError.InvalidStackAccess;
            }
            return &self.data[index];
        }
        pub fn fetchAtIndex(self: *@This(), index: usize) !T {
            return (try self.fetchPtrAtIndex(index)).*;
        }
        pub fn hasItem(self: *@This()) bool {
            return self.size > 0;
        }
    };
}

pub const MainStack = Stack(StackFrame);
