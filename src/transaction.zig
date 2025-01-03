const std = @import("std");

const TidValue = std.atomic.Value(u16);

pub const TransactionManager = struct {
    tid: TidValue,

    pub fn init() TransactionManager {
        return TransactionManager {
            .tid = TidValue.init(1),
        };
    }

    pub fn begin(self: *TransactionManager) u16 {
        return self.tid.fetchAdd(1, .seq_cst);
    }
};
