const std = @import("std");
const mem = std.mem;

const ArrayList = std.ArrayList;

pub fn listFromSlice(comptime T: type, allocator: mem.Allocator, slice: []const T) !ArrayList(T) {
    var list = try ArrayList(T).initCapacity(allocator, slice.len);
    list.appendSliceAssumeCapacity(slice);

    return list;
}
