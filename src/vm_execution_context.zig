// This entire file represents the VMExecutionContext struct.
// This file is exposed as a type in vm_execution_types.
const std = @import("std");
const vm_execution_types = @import("vm_execution_types.zig");
const core_types = @import("core_types.zig");
const instruction_types = @import("instruction_types.zig");
const repetition_types = @import("repetition_types.zig");

// VM stack re-namespacing for brevity.
const MainStack = vm_execution_types.MainStack;
const RepeatStackFrame = vm_execution_types.RepeatStackFrame;
const GroupStackFrame = vm_execution_types.GroupStackFrame;
const IntermediateMatchGroup = vm_execution_types.IntermediateMatchGroup;
const IntermediateMatch = vm_execution_types.IntermediateMatch;

// INTERNAL CONTEXT VALUES
stack: MainStack,
ip: usize,
jmp_queued: bool,
repetition_consumed_input: bool, // Used to stop infinite looping of repetition.
str_ptr: usize,
current_group_ptr: ?usize, // the index that points to the current group frame.
current_rep_ptr: ?usize,
groups: ?[]?IntermediateMatchGroup,


// PUBLIC MEMBER FUNCTIONS
pub fn init(allocator: anytype, start_ptr: usize) !@This() {
    return .{
        .stack = try MainStack.init(allocator),
        .ip = 0,
        .jmp_queued = false,
        .repetition_consumed_input = true,
        .current_rep_ptr = null,
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

pub fn internal_match(self: *@This(), allocator: anytype, bytecode: []instruction_types.Instruction, string: []const u8) !?IntermediateMatch {
    while (self.ip < bytecode.len) {
        self.jmp_queued = false;
        switch (bytecode[self.ip]) {
            .allocate_groups, .header_start, .header_end => { // This should only be done once per higher-level call to the VM, at bytecode index 0.
                return core_types.VMError.InvalidStackArrangement;
            },
            .split => |split_instr| {
                try self.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = split_instr.right, .backtrack_str_ptr = self.str_ptr, .stack_depth = self.stack.len(), .previous_count = (try self.currentCount()), .previous_rep_ptr = self.current_rep_ptr } });
                self.ip = split_instr.left;
            },
            .repeat_start => |rep| {
                try self.stack.push(allocator, .{ .repeat = .{ .min = rep.min, .mode = rep.mode, .max = rep.max, .previous_rep_ptr = self.current_rep_ptr, .previous_str_ptr =  self.str_ptr, .current_count = 0, .escape_jmp_index = rep.escape_jmp_index } });
                self.current_rep_ptr = self.stack.elementCount() - 1;
                if (rep.min == 0 and rep.mode != .possessive) { // allow a backtrack before doing any repetition iterations.
                    try self.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = rep.escape_jmp_index, .backtrack_str_ptr = self.str_ptr, .stack_depth = self.stack.len(), .previous_count = (try self.currentCount()), .previous_rep_ptr = self.current_rep_ptr } });
                } // repeat_end points to the instruction after the repeat_start, which is the instruction in the context here.
            },
            .repeat_end => |end| {
                try self.repeat_next_iteration(allocator, end);
            },
            .jmp => |jmp_instr| {
                self.jmp(jmp_instr);
            },
            .literal => |lit| {
                const literal_match_container = literal_match(lit, string, self.str_ptr);
                if (literal_match_container.matching) {
                    if (literal_match_container.consuming) {
                        self.str_ptr += 1;
                    }
                } else {
                    if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = true })) {
                        return null;
                    }
                }
            },
            .end_match => {
                if (self.groups) |grps| {
                    return IntermediateMatch{ .groups = grps };
                } else {
                    return core_types.VMError.InvalidGroupAllocation;
                }
            },
            .capture_start => |cap| {
                try self.stack.push(allocator, .{ .group = .{ .current_group = cap, .previous_group_ptr = self.current_group_ptr } });
                self.current_group_ptr = self.stack.elementCount() - 1; // Top of the stack just pushed to is the group_ptr.
                (try self.currentGroupReference()).* = .{ .start = self.str_ptr, .end = 0 };
            },
            .capture_end => {
                (try self.currentGroupReference()).*.?.end = self.str_ptr;
                const group_frame = try self.currentGroupFrame();
                self.current_group_ptr = group_frame.previous_group_ptr;
            },
            .atomic_start => {
                try self.stack.push(allocator, .atomic);
            },
            .atomic_end => {
                var atomic_frame_found: bool = false;
                while (self.stack.hasItem()) {
                    const current = try self.stack.pop(allocator);
                    switch (current) {
                        .atomic => {
                            atomic_frame_found = true;
                            break; // Breaks out of the while loop when the frame is found.
                        },
                        else => {},
                    }
                }
                if (!atomic_frame_found) {
                    return core_types.VMError.InvalidStackArrangement;
                }
            },
            .lookahead_start => {
                try self.stack.push(allocator, .{ .lookahead = .{ .saved_str_ptr = self.str_ptr, .negative = false, .jmp_index = null } });
            },
            .lookahead_end => {
                var lookahead_frame_found: bool = false;
                while (self.stack.hasItem()) {
                    const current = try self.stack.pop(allocator);
                    switch (current) {
                        .lookahead => |look| {
                            self.str_ptr = look.saved_str_ptr;
                            lookahead_frame_found = true;
                            break; // Breaks out of the while loop when the frame is found.
                        },
                        else => {},
                    }
                }
                if (!lookahead_frame_found) {
                    return core_types.VMError.InvalidStackArrangement;
                }
            },
            .lookbehind_start => |len| {
                try self.stack.push(allocator, .{ .lookahead = .{ .saved_str_ptr = self.str_ptr, .negative = false, .jmp_index = null } });
                if (self.str_ptr >= len) {
                    self.str_ptr -= len;
                } else {
                    if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = true })) {
                        return null;
                    }
                }
            },
            .lookbehind_end => {
                var lookahead_frame_found: bool = false;
                while (self.stack.hasItem()) {
                    const current = try self.stack.pop(allocator);
                    switch (current) {
                        .lookahead => |look| {
                            self.str_ptr = look.saved_str_ptr;
                            lookahead_frame_found = true;
                            break; // Breaks out of the while loop when the frame is found.
                        },
                        else => {},
                    }
                }
                if (!lookahead_frame_found) {
                    return core_types.VMError.InvalidStackArrangement;
                }
            },
            .neg_lookahead_start => |jmp_index| {
                try self.stack.push(allocator, .{ .lookahead = .{ .saved_str_ptr = self.str_ptr, .negative = true, .jmp_index = jmp_index } });
            },
            .neg_lookahead_end => { // if this is reached that means the inside matched, which means the assertion failed, so backtrack.
                if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = false })) {
                std.debug.print("LOOKAHEAD NEG FAIL!!!\n", .{});
                return null;
            }
            },
            .neg_lookbehind_start => |neg_lookbehind| {
                try self.stack.push(allocator, .{ .lookahead = .{ .saved_str_ptr = self.str_ptr, .negative = true, .jmp_index = neg_lookbehind.jmp_index } });
                if (self.str_ptr >= neg_lookbehind.len) {
                    self.str_ptr -= neg_lookbehind.len;
                } else {
                    if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = true })) {
                        return null;
                    }
                }
            },
            .neg_lookbehind_end => {
                if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = false })) {
                    std.debug.print("LOOKAHEAD NEG FAIL!!!\n", .{});
                    return null;
                }
            },
            .class => |class| {
                if (class_match(class, string, self.str_ptr)) {
                    self.str_ptr += 1;
                } else {
                    if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = true })) {
                        return null;
                    }
                }
            },
            .backref => |id| {
                const group_compare_slice = try self.groupIndex(id);
                if (group_compare_slice) |slice| {
                    const len: usize = slice.end - slice.start;
                    if (std.mem.eql(u8, string[slice.start..slice.end], string[self.str_ptr..])) {
                        self.str_ptr += len;
                    } else {
                        if (!try self.backtrack(allocator, .{ .allow_across_lookthroughs = true })) {
                            return null;
                        }
                    }
                }
            },
        }
        if (!self.jmp_queued) {
            self.ip += 1; // don't skip past the instruction that was just set.
        }
    }
    return null;
}

// PRIVATE MEMBER FUNCTIONS
fn jmp(self: *@This(), jmp_point: usize) void {
    self.ip = jmp_point;
    self.jmp_queued = true;
}

fn currentRepFrameReference(self: *@This()) !?*RepeatStackFrame {
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
        return null;
    }
}

fn currentCount(self: *@This()) !usize {
    if (try self.currentRepFrameReference()) |frame_ref| {
        return frame_ref.current_count;
    }
    return core_types.VMError.NullIndexAccess;
}

fn currentGroupFrame(self: *@This()) !GroupStackFrame { // Returns the value of the frame representing the current group.
    switch (try self.stack.fetchAtIndex(self.current_group_ptr.?)) {
        .group => |grp| {
            return grp;
        },
        else => {
            return core_types.VMError.InvalidStackArrangement;
        },
    }
}

fn currentGroupId(self: *@This()) !?usize { // Uses the frame of the current group to grab the current group ID.
    return (try self.currentGroupFrame()).current_group;
}

fn currentGroupReference(self: *@This()) !*?IntermediateMatchGroup {
    if (self.groups) |grps| {
        return &grps[(try self.currentGroupId()).?];
    } else {
        return core_types.VMError.NullIndexAccess;
    }
}

fn groupIndex(self: *@This(), id: usize) !?IntermediateMatchGroup {
    if (self.groups) |grps| {
        return grps[id];
    } else {
        return core_types.VMError.NullIndexAccess;
    }
}

// Sets the VM to the next repetition iteration and returns true if the given repetition has incremented the str pointer successfully.
 fn repeat_next_iteration(self: *@This(), allocator: anytype, jump_index: usize) !void {
    var current_frame_ref: *RepeatStackFrame = undefined;
    if (try self.currentRepFrameReference()) |frame_ref| {
        current_frame_ref = frame_ref;
    } else {
        return core_types.VMError.NullIndexAccess;
    }
    current_frame_ref.current_count += 1;
    self.repetition_consumed_input = self.str_ptr > current_frame_ref.previous_str_ptr;
    const min: usize = current_frame_ref.min;
    const max: repetition_types.RepetitionBoundType = current_frame_ref.max;
    const mode: repetition_types.RepeaterType = current_frame_ref.mode;
    const current_count = try self.currentCount();
    if (current_count < min) {
        self.jmp(jump_index); // there should not be a choice point saved here; there is no backtracking to be done with a different amount because min is the minimum allowed in range.
    } else if (repetition_count_cmp(current_count, max, .GE) or !self.repetition_consumed_input) { // Exit if within range and repetition did not consume anything, or if past max.
        self.current_rep_ptr = current_frame_ref.previous_rep_ptr; // set to previous rep frame when exiting.
        self.jmp(self.ip + 1);
        self.repetition_consumed_input = true; // Set back to true when exiting to ensure future repetitions do not exit early.
    } else {
        switch (mode) {
            .greedy => {
                try self.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = self.ip + 1, .backtrack_str_ptr = self.str_ptr, .stack_depth = self.stack.len(), .previous_count = (try self.currentCount()), .previous_rep_ptr = self.current_rep_ptr } });
                self.jmp(jump_index);
            },
            .lazy => {
                try self.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = jump_index, .backtrack_str_ptr = self.str_ptr, .stack_depth = self.stack.len(), .previous_count = (try self.currentCount()), .previous_rep_ptr = self.current_rep_ptr } });
                self.jmp(self.ip + 1);
            },
            .possessive => {
                self.jmp(jump_index);
            },
        }
    }
}

fn backtrack(self: *@This(), allocator: anytype, options: BacktrackOptions) !bool { // Returns false when there is no fallback.
    while (self.stack.hasItem()) {
    const current_item = try self.stack.pop(allocator);
    switch (current_item) {
        .group => |grp| {
            self.current_group_ptr = grp.previous_group_ptr;
            self.groups.?[grp.current_group] = null;
        },
        .repeat => |rep| {
            const current_count = rep.current_count; // DO NOT use self.currentCount() here. That function tries to stack access the repetition frame that was just popped here.
                switch (rep.mode) {
                .greedy => {
                    self.current_rep_ptr = rep.previous_rep_ptr;
                },
                .lazy => {
                    self.current_rep_ptr = rep.previous_rep_ptr;
                },
                .possessive => { // Exit repetition if within range; otherwise fail the match.
                        if (repetition_count_cmp(current_count, rep.max, .LE) and current_count >= rep.min) {
                    self.jmp(rep.escape_jmp_index);
                    return true;
                } else {
                    return false;
                }
                },
            }
        },
        .choice_point => |choice| {
            self.str_ptr = choice.backtrack_str_ptr;
            self.current_rep_ptr = choice.previous_rep_ptr;
            if (try self.currentRepFrameReference()) |frame_ref| { // Don't null error if there is no frame; there may be no current counter.
                    frame_ref.current_count = choice.previous_count;
            } else {
                std.debug.print("Choice point previous count not set: {d}\n", .{choice.previous_count});
            }
            self.jmp(choice.backtrack_ip);
            return true; // no failure incurred when backtracking has a fallback.
            },
        .lookahead => |look| {
            if (look.negative and options.allow_across_lookthroughs) {
                if (look.jmp_index) |look_jmp_index| {
                    std.debug.print("Jumping out of negative; succeeded!\n", .{});
                    self.str_ptr = look.saved_str_ptr;
                    self.jmp(look_jmp_index + 1);
                    return true; // did NOT incur a failing state.
                    } else {
                    return core_types.VMError.NullIndexAccess;
                }
                // jump past end instruction; past the end instruction should only be reached when neg lookahead "fails".
                }
        },
        .atomic => {
            return false;
        },
    }
}
    return false;
}

// PRIVATE NON-MEMBER FUNCTIONS AND PRIVATE TYPES
// Private function for count comparison.
fn repetition_count_cmp(count: usize, max: repetition_types.RepetitionBoundType, cmp: ComparisonType) bool {
    switch (max) {
        .bounded => |bounded_max| {
            switch (cmp) {
                .LT => {
                    return count < bounded_max;
                },
                .LE => {
                    return count <= bounded_max;
                },
                .EQ => {
                    return count == bounded_max;
                },
                .GT => {
                    return count > bounded_max;
                },
                .GE => {
                    return count >= bounded_max;
                },
            }
        },
        .unbounded => {
            switch (cmp) {
                .LT, .LE => {
                    return true;
                },
                .GT, .GE, .EQ => {
                    return false;
                },
            }
        },
    }
}

fn literal_match(literal: anytype, string: []const u8, index: usize) ConditionalConsumingMatch {
    if (index > string.len) { // Not >=. == string.len is sometimes used for certain assertions.
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
        .start_anchor => { // Start and end anchors default to multiline matching.
            matching = index == 0 or string[index - 1] == '\n';
            consuming = false;
        },
        .end_anchor => {
            matching = index == string.len or ((index + 1) < string.len and string[index + 1] == '\n');
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

fn class_match(class: u256, string: []const u8, index: usize) bool {
    if (index >= string.len) {
        return false;
    }
    return ((@as(u256, 1) << string[index]) & class) != 0;
}

fn isDigit(string: []const u8, index: usize) bool {
    if (index >= string.len) return false;
    const char: u8 = string[index];
    return char >= '0' and char <= '9';
}

fn isWord(string: []const u8, index: usize) bool {
    if (index >= string.len) return false;
    const char: u8 = string[index];
    return isDigit(string, index) or (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

fn isWhitespace(string: []const u8, index: usize) bool {
    if (index >= string.len) return false;
    const char: u8 = string[index];
    return char == ' ' or char == '\n' or char == '\t' or char == '\r';
}

const ConditionalConsumingMatch = struct {
    matching: bool,
    consuming: bool,
};

const ComparisonType = enum { LT, LE, EQ, GT, GE };

const BacktrackOptions = struct {
    allow_across_lookthroughs: bool, // prevents always allowing backtracks to a negative lookthrough frame to succeed if the backtrack is triggered by a negative end instruction.
};
