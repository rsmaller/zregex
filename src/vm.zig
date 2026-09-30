const std = @import("std");

const codegen = @import("codegen.zig");
const core_types = @import("core_types.zig");

pub const SlicedMatch = struct {
    groups: [][]const u8,
};

const Match = struct {
    groups: []const MatchGroup,
};

pub const MatchGroup = struct {
    start: usize, // Slices of original string passed in.
    end: usize,
};

const RepeatStackFrame = struct { // Reused RepeatStackFrame from repeat bytecode instruction. Unsure if needed.
    min: usize,
    max: core_types.RepetitionBoundType,
    mode: core_types.RepeaterType,
    previous_rep_ptr: ?usize, // TODO: rename this to previous_rep_ptr.
    current_count: usize,
    // TODO: add an actual counter here that repetitions will increment while this is the current frame.
};

const ChoicePointStackFrame = struct {
    backtrack_ip: usize,
    stack_depth: usize,
    backtrack_str_ptr: usize,
    previous_count: usize, // TODO: make sure backtracking sets the current stack frame's count to this count.
};

const GroupStackFrame = struct {
    current_group: usize,
    previous_group_ptr: ?usize, // the index that points to the previous group frame.
};

const StackFrame = union(enum) {
    choice_point: ChoicePointStackFrame,
    repeat: RepeatStackFrame,
    group: GroupStackFrame,
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
            if (!self.hasItem()) {
                return core_types.StackError.StackEmptyError;
            }
            return self.data[self.size - 1];
        }
        fn fetchPtrAtIndex(self: *@This(), index: usize) !*T {
            if (index >= self.size) {
                return core_types.StackError.InvalidStackAccess;
            }
            return &self.data[index];
        }
        fn fetchAtIndex(self: *@This(), index: usize) !T {
            return (try self.fetchPtrAtIndex(index)).*;
        }
        fn hasItem(self: *@This()) bool {
            return self.size > 0;
        }
    };
}

const VMMainStack = Stack(StackFrame);

const VMExecutionContext = struct {
    stack: VMMainStack,
    ip: usize,
    jmp_queued: bool,
    str_ptr: usize,
    current_group_ptr: ?usize, // the index that points to the current group frame.
    current_rep_ptr: ?usize, // TODO: change this to a ?usize and have it be current_rep_ptr
    groups: ?[]MatchGroup,
    pub fn init(allocator: anytype, start_ptr: usize) !VMExecutionContext {
        return .{
            .stack = try VMMainStack.init(allocator),
            .ip = 0,
            .jmp_queued = false,
            .current_rep_ptr = null, // TODO: change this to current_rep_ptr = null,
            .str_ptr = start_ptr,
            .current_group_ptr = null,
            .groups = null,
        };
    }
    pub fn deinit(self: *@This(), allocator: anytype) void {
        self.stack.deinit(allocator);
        if (self.groups) |grps| {
            allocator.free(grps);
        }
    }
    pub fn jmp(self: *@This(), jmp_point: usize) void {
        self.ip = jmp_point;
        self.jmp_queued = true;
    }
    pub fn currentRepFrameReference(self: *@This()) !*RepeatStackFrame {
        if (self.current_rep_ptr) |rep_ptr| {
            switch ((try self.stack.fetchPtrAtIndex(rep_ptr)).*) {
                .repeat => |*rep| {
                    return rep;
                },
                else => {
                    return core_types.VMError.InvalidStackArrangement;
                },
            }
        } else {
            return core_types.VMError.NullIndexAccess;
        }
    }
    pub fn currentCount(self: *@This()) !usize {
        return (try self.currentRepFrameReference()).current_count;
    }
    pub fn currentGroupFrame(self: *@This()) !GroupStackFrame { // Returns the value of the frame representing the current group.
        switch (try self.stack.fetchAtIndex(try unpack_index_panic(self.current_group_ptr))) {
            .group => |grp| {
                return grp;
            },
            else => {
                return core_types.VMError.InvalidStackArrangement;
            },
        }
    }
    pub fn currentGroupId(self: *@This()) !?usize { // Uses the frame of the current group to grab the current group ID.
        return (try self.currentGroupFrame()).current_group;
    }
    pub fn currentGroupReference(self: *@This()) !*MatchGroup {
        if (self.groups) |grps| {
            return &grps[try unpack_index_panic(try self.currentGroupId())];
        } else {
            return core_types.VMError.NullIndexAccess;
        }
    }
    pub fn backtrack(self: *@This(), allocator: anytype) !bool { // Returns false when there is no fallback.
        std.debug.print("BACKTRACKING!!!\n", .{});
        while (self.stack.hasItem()) {
            const current_item = try self.stack.pop(allocator);
            switch (current_item) {
                .group => |grp| {
                    self.current_group_ptr = grp.previous_group_ptr; // null check here; may not be necessary?
                },
                .repeat => |rep| {
                    self.current_rep_ptr = rep.previous_rep_ptr;
                },
                .choice_point => |choice| {
                    self.str_ptr = choice.backtrack_str_ptr;
                    (try self.currentRepFrameReference()).current_count = choice.previous_count; // TODO: change this to match pointer changes.
                    self.jmp(choice.backtrack_ip);
                    return true; // no failure incurred when backtracking has a fallback.
                },
            }
        }
        return false;
    }
};

fn unpack_index_panic(index: ?usize) !usize {
    if (index) |ret| {
        return ret;
    }
    return core_types.VMError.NullIndexAccess;
}

fn unpack_item_tag_panic(item: anytype, comptime tag: @typeInfo(@TypeOf(item)).@"union".tag_type.?) !@FieldType(@TypeOf(item), @tagName(tag)) {
    switch (item) {
        tag => |ret| {
            return ret;
        },
        else => {
            return core_types.VMError.InvalidStackArrangement;
        },
    }
}

pub fn isDigit(string: []const u8, index: usize) bool {
    if (index >= string.len) return false;
    const char: u8 = string[index];
    return char >= '0' and char <= '9';
}

pub fn isWord(string: []const u8, index: usize) bool {
    if (index >= string.len) return false;
    const char: u8 = string[index];
    return isDigit(string, index) or (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

pub fn isWhitespace(string: []const u8, index: usize) bool {
    if (index >= string.len) return false;
    const char: u8 = string[index];
    return char == ' ' or char == '\n' or char == '\t' or char == '\r';
}

pub fn match_index_correlate(allocator: anytype, string: []const u8, match_item: Match) !SlicedMatch {
    var group_arr = try allocator.alloc([]const u8, match_item.groups.len);
    for (match_item.groups, 0..) |group, i| {
        group_arr[i] = string[group.start..group.end];
    }
    return SlicedMatch{ .groups = group_arr };
}

fn repetition_count_lt(count: usize, max: core_types.RepetitionBoundType) bool {
    switch (max) {
        .bounded => |bounded_max| {
            return count < bounded_max;
        },
        .unbounded => {
            return true;
        },
    }
}

fn class_match(class: u256, string: []const u8, index: usize) bool {
    if (index >= string.len) {
        return false;
    }
    return ((@as(u256, 1) << string[index]) & class) != 0;
}

const ConditionalConsumingMatch = struct {
    matching: bool,
    consuming: bool,
};

fn literal_match(literal: anytype, string: []const u8, index: usize) ConditionalConsumingMatch {
    if (index > string.len) {
        return .{ .matching = false, .consuming = false };
    }
    var matching = false;
    var consuming = true;
    switch (literal.data) {
        .generic => |gen| {
            if (index >= string.len) {
                matching = false;
            } else {
                matching = string[index] == gen;
            }
        },
        .digit => {
            matching = isDigit(string, index);
        },
        .word => {
            matching = isWord(string, index);
        },
        .word_boundary => {
            if (index == 0 and index >= string.len) {
                matching = false;
            } else if (index == 0) {
                matching = isWord(string, index);
            } else if (index == string.len) {
                matching = isWord(string, index - 1);
            } else if (index != 0 and index <= string.len) {
                matching = isWord(string, index - 1) != isWord(string, index);
            } else {
                matching = false; // failsafe.
            }
            consuming = false;
        },
        .whitespace => {
            matching = isWhitespace(string, index);
        },
        .start_anchor => {
            consuming = false;
        },
        .end_anchor => {
            consuming = false;
        },
        .any => {
            matching = true;
            if (index >= string.len or string[index] == '\n') matching = false;
        },
    }
    if (literal.inverted) {
        matching = !matching;
    }
    return .{ .matching = matching, .consuming = consuming };
}

fn repeat_next_iteration(allocator: anytype, main_context: *VMExecutionContext, bytecode: []codegen.Instruction, jump_index: usize) !void {
    // std.debug.print("ending repetition\n", .{});
    var min: usize = undefined;
    var max: core_types.RepetitionBoundType = undefined;
    var mode: core_types.RepeaterType = undefined;
    (try main_context.currentRepFrameReference()).current_count += 1; // TODO: change this to increment on the current repetition frame.
    switch (bytecode[jump_index - 1]) { // switch on the data the repetition_end refers to.
        .repeat_start => |rep_instr| {
            min = rep_instr.min;
            max = rep_instr.max;
            mode = rep_instr.mode;
        },
        else => {
            return core_types.BytecodeGenError.UnexpectedBytecodeType;
        },
    }
    if (try main_context.currentCount() < min) { // TODO: use fetchAtIndex() method to grab the current counter.
        main_context.jmp(jump_index); // there should not be a choice point saved here; there is no backtracking to be done with a different amount because min is the minimum allowed in range.
    } else {
        switch (mode) {
            .greedy => {
                if (repetition_count_lt(try main_context.currentCount(), max)) { // TODO: use fetchAtIndex() method to grab the current counter.
                    try main_context.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = main_context.ip + 1, .backtrack_str_ptr = main_context.str_ptr, .stack_depth = main_context.stack.data.len, .previous_count = (try main_context.currentCount()) } }); // TODO: change to pointers.
                    main_context.jmp(jump_index);
                } else {
                    main_context.current_rep_ptr = (try main_context.currentRepFrameReference()).previous_rep_ptr; // set to previous rep frame when exiting.
                    main_context.jmp(main_context.ip + 1);
                }
            },
            .lazy => {},
            .possessive => {},
        }
    }
}

pub fn internal_match(allocator: anytype, main_context: *VMExecutionContext, bytecode: []codegen.Instruction, string: []const u8) !?Match {
    // VM contents.
    while (main_context.ip < bytecode.len) {
        main_context.jmp_queued = false;
        switch (bytecode[main_context.ip]) {
            .allocate_groups => { // This should only be done once per higher-level call to the VM, at bytecode index 0.
                return core_types.VMError.InvalidStackArrangement;
            },
            .split => |split_instr| {
                // std.debug.print("doing split\n", .{});
                try main_context.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = split_instr.right, .backtrack_str_ptr = main_context.str_ptr, .stack_depth = main_context.stack.data.len, .previous_count = (try main_context.currentCount()) } }); // TODO: change to pointers.
                main_context.ip = split_instr.left;
            },
            .repeat_start => |rep| {
                // std.debug.print("starting repetition\n", .{});
                try main_context.stack.push(allocator, .{ .repeat = .{ .min = rep.min, .mode = rep.mode, .max = rep.max, .previous_rep_ptr = main_context.current_rep_ptr, .current_count = 0 } }); // TODO: change to pointers.
                main_context.current_rep_ptr = main_context.stack.size - 1; // TODO: init counter in stack push and change this to current repeat pointer.
            },
            .repeat_end => |end| {
                // std.debug.print("ending repetition\n", .{});
                try repeat_next_iteration(allocator, main_context, bytecode, end);
                // TODO: unroll pointer to previous repetition.
            },
            .jmp => |jmp_instr| {
                // std.debug.print("jumping\n", .{});
                main_context.jmp(jmp_instr);
            },
            .literal => |lit| {
                // std.debug.print("matching a literal\n", .{});
                const literal_match_container = literal_match(lit, string, main_context.str_ptr);
                if (literal_match_container.matching) {
                    if (literal_match_container.consuming) {
                        main_context.str_ptr += 1;
                    }
                } else {
                    if (!try main_context.backtrack(allocator)) {
                        return null;
                    }
                }
            },
            .end_match => {
                // std.debug.print("match over!\n", .{});
                if (main_context.groups) |grps| {
                    return Match{ .groups = grps };
                } else {
                    return core_types.VMError.InvalidGroupAllocation;
                }
            },
            .capture_start => |cap| {
                // std.debug.print("starting capture {d}", .{cap});
                try main_context.stack.push(allocator, .{ .group = .{ .current_group = cap, .previous_group_ptr = main_context.current_group_ptr } });
                // if (main_context.current_group_ptr) |arg2| {
                //     std.debug.print(", pushed group frame index {d} onto stack pointing to prev index {d}\n", .{ main_context.stack.size - 1, arg2 });
                // } else {
                //     std.debug.print(", pushed group frame index {d} onto stack pointing to prev index NULL\n", .{main_context.stack.size - 1});
                // }
                main_context.current_group_ptr = main_context.stack.size - 1; // Top of the stack just pushed to is the group_ptr.
                (try main_context.currentGroupReference()).start = main_context.str_ptr;
            },
            .capture_end => {
                (try main_context.currentGroupReference()).end = main_context.str_ptr;
                const group_frame = try main_context.currentGroupFrame();
                main_context.current_group_ptr = group_frame.previous_group_ptr;
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
            .class => |class| {
                if (class_match(class, string, main_context.str_ptr)) {
                    main_context.str_ptr += 1;
                } else {
                    if (!try main_context.backtrack(allocator)) {
                        return null;
                    }
                }
            },
        }
        if (!main_context.jmp_queued) {
            main_context.ip += 1; // don't skip past the instruction that was just set.
        }
    }
    return null;
}

pub fn match(allocator: anytype, bytecode: []codegen.Instruction, string: []const u8) !?SlicedMatch {
    var test_start_ptr: usize = 0;
    var main_context = try VMExecutionContext.init(allocator, test_start_ptr);
    defer main_context.deinit(allocator); // Should deinit the stack and the groups array.
    switch (bytecode[0]) {
        .allocate_groups => |alloc_instr| {
            // std.debug.print("allocating groups\n", .{});
            if (main_context.groups) |_| {
                return core_types.VMError.InvalidGroupAllocation;
            } else {
                main_context.groups = try allocator.alloc(MatchGroup, alloc_instr.size);
            }
        },
        else => {
            return core_types.VMError.InvalidStackArrangement; // bytecode[0] should be alloc_groups instruction.
        },
    }
    while (test_start_ptr < string.len) : (test_start_ptr += 1) {
        main_context.ip = 1; // ensure to reset ip every time. ip index 0 should be the ALLOC_GROUPS() instruction, which is run only once at the start.
        main_context.str_ptr = test_start_ptr;
        main_context.current_group_ptr = null;
        const current_match = try internal_match(allocator, &main_context, bytecode, string);
        if (current_match) |success| { // check the match value for null
            return try match_index_correlate(allocator, string, success);
        }
    }
    return null;
}
