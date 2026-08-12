const std = @import("std");

const TidValue = std.atomic.Value(u16);

pub const TransactionManager = struct {
    tid: TidValue,

    pub fn init() TransactionManager {
        return TransactionManager{
            .tid = TidValue.init(1),
        };
    }

    pub fn begin(self: *TransactionManager) u16 {
        return self.tid.fetchAdd(1, .seq_cst);
    }
};

test "begin - hands out a new transaction ID each time" {
    const t = std.testing;

    var txm = TransactionManager.init();

    try t.expectEqual(1, txm.begin());
    try t.expectEqual(2, txm.begin());
    try t.expectEqual(3, txm.begin());
}

test "begin - wraps around at the end of the range" {
    const t = std.testing;

    var txm = TransactionManager.init();
    txm.tid.store(std.math.maxInt(u16), .seq_cst);

    // The transaction ID is 16 bits wide on the wire, so running out of them
    // has to wrap rather than overflow.
    try t.expectEqual(0xFFFF, txm.begin());
    try t.expectEqual(0, txm.begin());
    try t.expectEqual(1, txm.begin());
}
