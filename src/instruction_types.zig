// Instruction types organized into a single file; accessible via core_types.zig.
const std = @import("std");
const repetition_types = @import("repetition_types.zig");

pub const LiteralInstruction = struct {
    inverted: bool,
    data: union(enum) {
        generic: u8,
        digit: void,
        word: void,
        word_boundary: void,
        whitespace: void,
        start_anchor: void,
        end_anchor: void,
        any: void,
    },
};

pub const Instruction = union(enum) {
    header_start: void,
    allocate_groups: struct {
        size: usize,
    },
    header_end: void,
    split: struct {
        left: usize,
        right: usize,
    },
    repeat_start: struct {
        min: usize,
        max: repetition_types.RepetitionBoundType, // Reused repetition bound
        mode: repetition_types.RepeaterType,
        escape_jmp: usize,
    },
    repeat_end: usize,
    jmp: usize,
    literal: LiteralInstruction,
    end_match: void,
    capture_start: usize,
    capture_end: usize,
    atomic_start: void,
    atomic_end: void,
    lookahead_start: void,
    lookahead_end: void,
    lookbehind_start: usize,
    lookbehind_end: void,
    neg_lookahead_start: usize,
    neg_lookahead_end: void,
    neg_lookbehind_start: struct {
        len: usize,
        jmp: usize,
    },
    neg_lookbehind_end: void,
    class: u256, // binary-optimized for every 8-bit character.
};