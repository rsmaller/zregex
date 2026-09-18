const std = @import("std");
const core_types = @import("core_types.zig");
const codegen = @import("codegen.zig");

pub const Match = struct {
    groups: []const MatchGroup,
};

pub const MatchGroup = struct {
    data: []const u8, // Slices of original string passed in.
};

const RepeatStackFrame = struct { // Reused RepeatStackFrame from repeat bytecode instruction. Unsure if needed.
    min: usize,
    max: core_types.RepetitionBoundType,
    mode: core_types.RepeaterType,
};

const ChoicePointStackFrame = struct {
    backtrack_ip: usize,
    stack_depth: usize,
};

const StackFrame = union(enum) {
    repeat: RepeatStackFrame,
    choice_point: ChoicePointStackFrame,
    // choice_point for backtracking later.

};

fn Stack(T: type) type {
    return struct {
        data: []T,
        size: usize,
        fn init(allocator: anytype) !Stack(T) {
            return .{
                .data = try allocator.alloc(T, 4),
                .size = 0,
            };
        }
        fn deinit(self: *@This(), allocator: anytype) void {
            allocator.free(self.data);
        }
        fn push(self: *@This(), allocator: anytype, item: T) !void {
            if (self.size >= self.data.len / 2) { // Dynamic doubling of array.
                self.data = try allocator.realloc(self.data, self.data.len * 2);
            }
            self.data[self.size] = item;
            self.size += 1;
        }
        fn pop(self: *@This(), allocator: anytype) !T {
            if (self.size == 0) {
                return core_types.StackError.StackEmptyError;
            }
            self.size -= 1;
            const ret: T = self.data[self.size];
            if (self.size <= self.data.len / 4) { // Dynamic halving of array.
                self.data = try allocator.realloc(self.data, self.data.len / 2);
            }
            return ret;
        }
        fn peek(self: *@This()) !T {
            if (self.size == 0) {
                return core_types.StackError.StackEmptyError;
            }
            return self.data[self.size - 1];
        }
    };
}

const VMMainStack = Stack(StackFrame);

pub fn match(allocator: anytype, bytecode: []codegen.Instruction, string: []const u8) !Match {
    // VM contents.
    var main_stack = try VMMainStack.init(allocator);
    defer main_stack.deinit(allocator);
    var group_index_stack = try Stack(usize).init(allocator);
    try group_index_stack.push(allocator, 0); // Push group index 0 as main match in stack.
    defer group_index_stack.deinit(allocator);
    var ip: usize = 0;
    var groups: ?[]MatchGroup = null;
    errdefer {
        if (groups) |grps| {
            allocator.free(grps);
        }
    }

    while (ip < bytecode.len) : (ip += 1) {
        switch (bytecode[ip]) {
            .allocate_groups => |alloc_instr| {
                if (groups) |_| {
                    return core_types.VMError.InvalidGroupAllocation;
                } else {
                    groups = try allocator.alloc(MatchGroup, alloc_instr.size);
                }
            },
            .split => |split_instr| {
                try main_stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = split_instr.right, .stack_depth = main_stack.data.len } });
                ip = split_instr.left;
            },
            .repeat_start => {},
            .repeat_end => {},
            .jmp => |jmp_instr| {
                ip = jmp_instr;
            },
            .literal => {
                // try to match
                // or else backtrack
            },
            .end_match => {
                if (groups) |grps| {
                    return Match{ .groups = grps };
                } else {
                    return core_types.StackError.StackEmptyError;
                }
            },
            .capture_start => {
                // push capture id
                // make current slice point to pushed group id
                // current slice should be adjusted until added to capture_end
            },
            .capture_end => {
                // pop capture id
                // save current slice to popped id in array
            },
            .atomic_start => {},
            .atomic_end => {},
            .lookahead_start => {},
            .lookahead_end => {},
            .lookbehind_start => {},
            .lookbehind_end => {},
            .neg_lookahead_start => {},
            .neg_lookahead_end => {},
            .neg_lookbehind_start => {},
            .neg_lookbehind_end => {},
            .class => {},
        }
    }
    // Failed matching contents.
    _ = string;
    return Match{ .groups = undefined };
}
