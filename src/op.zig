pub const Op = enum(u8) {
    and2,
    or2,
    xor2,
    not1,
    dff,

    pub fn inputCount(self: Op) usize {
        return switch (self) {
            .and2, .or2, .xor2, .dff => 2,
            .not1 => 1,
        };
    }

    pub fn outputCount(self: Op) usize {
        _ = self;
        return 1;
    }
};
