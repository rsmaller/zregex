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
    previous_count: usize,
};

const ChoicePointStackFrame = struct {
    backtrack_ip: usize,
    stack_depth: usize,
    backtrack_str_ptr: usize,
};

const GroupStackFrame = struct {
    current_group: usize,
    previous_group: ?usize,
};

const StackFrame = union(enum) {
    choice_point: ChoicePointStackFrame,
    repeat: RepeatStackFrame,
    group: GroupStackFrame,
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
            if (!self.hasItem()) {
                return core_types.StackError.StackEmptyError;
            }
            return self.data[self.size - 1];
        }
        fn hasItem(self: *@This()) bool {
            return self.size > 0;
        }
    };
}

const VMMainStack = Stack(StackFrame);

pub fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

pub fn isWord(char: u8) bool {
    return isDigit(char) or (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

pub fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\n' or char == '\t' or char == '\r'; 
}

const VMExecutionContext = struct {
    stack: VMMainStack,
    ip: usize,
    str_ptr: usize,
    current_group: usize,
    current_count: usize,
    groups: ?[]MatchGroup,
    pub fn init(allocator: anytype, start_ptr: usize) !VMExecutionContext {
        return .{
            .stack = try VMMainStack.init(allocator),
            .ip = 0,
            .current_count = 0,
            .str_ptr = start_ptr,
            .current_group = 0,
            .groups = null,
        };
    }
    pub fn deinit(self: *@This(), allocator: anytype) void {
        self.stack.deinit(allocator);
    }
    pub fn backtrack(self: *@This(), allocator: anytype) !bool { // Returns true when resulting in a failing state.
        while (self.stack.hasItem()) {
            const current_item = try self.stack.pop(allocator);
            switch(current_item) {
                .group => |grp| {
                    if (grp.previous_group) |prev_grp| {
                        self.current_group = prev_grp;
                    }
                },
                .repeat => |rep| {
                    self.current_count = rep.previous_count;
                },
                .choice_point => |choice| {
                    self.ip = choice.backtrack_ip;
                    self.str_ptr = choice.backtrack_str_ptr;
                    return false; // no failure incurred when backtracking has a fallback.
                },
            }
        }
        return true;
    }
};

pub fn match_index_correlate(allocator: anytype, string: []const u8, match_item: Match) !SlicedMatch {
    var group_arr = try allocator.alloc([]const u8, match_item.groups.len);
    for (match_item.groups, 0..) |group, i| {
        group_arr[i] = string[group.start..group.end];
    }
    return SlicedMatch{.groups = group_arr};
}

pub fn match(allocator: anytype, bytecode: []codegen.Instruction, string: []const u8) !?SlicedMatch {
    var test_start_ptr: usize = 0;
    var main_context = try VMExecutionContext.init(allocator, test_start_ptr);
    defer main_context.deinit(allocator);
    while (test_start_ptr < string.len) : (test_start_ptr += 1) {
        main_context.ip = 0; // ensure to reset ip every time.
        main_context.str_ptr = test_start_ptr;
        main_context.current_group = 0;
        const current_match = try vm_internal_match(allocator, &main_context, bytecode, string);
        if (current_match) |success| { // check the match value for null
            const result = try match_index_correlate(allocator, string, success);
            allocator.free(success.groups);
            return result;
        }
    }
    return null;
}

pub fn vm_internal_match(allocator: anytype, main_context: *VMExecutionContext, bytecode: []codegen.Instruction, string: []const u8) !?Match {
    // VM contents.
    errdefer {
        if (main_context.groups) |grps| {
            allocator.free(grps);
        }
    }
    while (main_context.ip < bytecode.len) {
        // std.debug.print("Current ip is {d}\n", .{main_context.ip});
        var ip_set: bool = false;
        switch (bytecode[main_context.ip]) {
            .allocate_groups => |alloc_instr| {
                std.debug.print("allocating groups\n", .{});
                if (main_context.groups) |_| {
                    return core_types.VMError.InvalidGroupAllocation;
                } else {
                    main_context.groups = try allocator.alloc(MatchGroup, alloc_instr.size);
                }
            },
            .split => |split_instr| {
                std.debug.print("doing split\n", .{});
                try main_context.stack.push(allocator, .{ .choice_point = .{ .backtrack_ip = split_instr.right, .backtrack_str_ptr = main_context.str_ptr, .stack_depth = main_context.stack.data.len } });
                main_context.ip = split_instr.left;
            },
            .repeat_start => |rep| {
                std.debug.print("starting repetition\n", .{});
                try main_context.stack.push(allocator, .{.repeat = .{ .min = rep.min, .mode = rep.mode, .max = rep.max, .previous_count = main_context.current_count } });
                main_context.current_count = 0; // start new counting.
            },
            .repeat_end => {
                std.debug.print("ending repetition\n", .{});
                // increment counter.
                // do conditional backtracking based on greedy, lazy, or possessive.
                // jump back to start of repetition, right after repeat start.
                // when popping repeat frame, ensure to set counter back to what it was. previously, stored in repeat_start node.
            },
            .jmp => |jmp_instr| {
                std.debug.print("jumping\n", .{});
                main_context.ip = jmp_instr;
                ip_set = true;
            },
            .literal => |lit| {
                std.debug.print("matching a literal\n", .{});
                var matched = false;
                var consuming = true;
                switch(lit.data) {
                    .generic => |gen| {
                        matched = string[main_context.str_ptr] == gen;
                    },
                    .digit => {
                        matched = isDigit(string[main_context.str_ptr]);
                    },
                    .word => {
                        matched = isWord(string[main_context.str_ptr]);
                    },
                    .word_boundary => {
                        if (main_context.str_ptr == 0 and main_context.str_ptr >= string.len) {
                            matched = false;
                        } else if (main_context.str_ptr == 0) {
                            matched = isWord(string[main_context.str_ptr]);
                        } else if (main_context.str_ptr == string.len) {
                            matched = isWord(string[main_context.str_ptr - 1]);
                        } else if (main_context.str_ptr != 0 and main_context.str_ptr <= string.len) {
                            matched = isWord(string[main_context.str_ptr - 1]) != isWord(string[main_context.str_ptr]); 
                        } else {
                            matched = false; // failsafe.
                        }
                        consuming = false;
                    },
                    .whitespace => {
                        matched = isWhitespace(string[main_context.str_ptr]);
                    },
                    .start_anchor => {
                        consuming = false;
                    },
                    .end_anchor => {
                        consuming = false;
                    },
                    .any => {
                        matched = true;
                        if (main_context.str_ptr >= string.len or string[main_context.str_ptr] == '\n') matched = false;
                    },
                }
                matched = matched and !lit.inverted;
                if (matched) {
                    if (consuming) {
                        main_context.str_ptr += 1;
                    }
                } else {
                    // backtrack
                    const failure = try main_context.backtrack(allocator);
                    if (failure) {
                        // Failed matching contents.
                        if (main_context.groups) |grps| {
                            allocator.free(grps); // free the groups if there is no error but match fails.
                        }
                        return null;
                    }
                    ip_set = true;
                }
            },
            .end_match => {
                std.debug.print("match over!\n", .{});
                if (main_context.groups) |grps| {
                    return Match{ .groups = grps };
                } else {
                    return core_types.VMError.InvalidGroupAllocation;
                }
            },
            .capture_start => |cap| {
                std.debug.print("starting capture {d}\n", .{cap});
                try main_context.stack.push(allocator, .{ .group = .{.current_group = cap, .previous_group = main_context.current_group} });
                main_context.current_group = cap;
                if (main_context.groups) |grps| {
                    grps[main_context.current_group].start = main_context.str_ptr; // current match group slice starts here.
                }
                // make current slice point to pushed group id
                // current slice should be adjusted until added to capture_end
            },
            .capture_end => |cap| {
                std.debug.print("ending capture {d}\n", .{cap});
                const popped_group = try main_context.stack.pop(allocator);
                switch(popped_group) {
                    .group => |tested_group| {
                        if (main_context.groups) |grps| {
                            grps[tested_group.current_group].end = main_context.str_ptr;
                        } else {
                            return core_types.VMError.InvalidGroupAllocation;
                        }
                    },
                    else => {
                        std.debug.print("Found {s} instead of Group frame!\n", .{@typeName(@TypeOf(popped_group))});
                        return core_types.VMError.InvalidStackArrangement;
                    },
                }
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
        if (!ip_set) {
            main_context.ip += 1; // don't skip past the instruction that was just set.
        }
    }
    // Failed matching contents.
    if (main_context.groups) |grps| {
        allocator.free(grps); // free the groups if there is no error but match fails.
    }
    return null;
}
