// Generic bounded repetition types that are used in multiple areas (AST, codegen, VM)
pub const RepeaterType = enum {
    greedy,
    lazy,
    possessive,
};

pub const RepetitionBoundType = union(enum) {
    bounded: usize,
    unbounded: void,
    pub fn equals(self: *const RepetitionBoundType, other: RepetitionBoundType) bool {
        if (@intFromEnum(self.*) != @intFromEnum(other)) {
            return false;
        }
        switch (self.*) {
            .bounded => |bound| {
                if (bound != other.bounded) {
                    return false;
                }
            },
            .unbounded => {},
        }
        return true;
    }
};

pub const RepetitionRangeType = struct {
    min: usize,
    max: RepetitionBoundType,
    pub fn equals(self: *const RepetitionRangeType, other: RepetitionRangeType) bool {
        if (self.min != other.min) {
            return false;
        }
        if (!self.max.equals(other.max)) {
            return false;
        }
        return true;
    }
};