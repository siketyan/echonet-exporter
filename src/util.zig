const std = @import("std");
const mem = std.mem;

const ArrayList = std.array_list.Managed;

pub fn listFromSlice(comptime T: type, allocator: mem.Allocator, slice: []const T) !ArrayList(T) {
    var list = try ArrayList(T).initCapacity(allocator, slice.len);
    list.appendSliceAssumeCapacity(slice);

    return list;
}

test "listFromSlice - copies the items and fits them exactly" {
    const t = std.testing;

    const list = try listFromSlice(u8, t.allocator, "Hello, world!");
    defer list.deinit();

    try t.expectEqualStrings("Hello, world!", list.items);
    try t.expectEqual(13, list.capacity);
}

test "listFromSlice - accepts an empty slice" {
    const t = std.testing;

    const list = try listFromSlice(u8, t.allocator, "");
    defer list.deinit();

    try t.expectEqual(0, list.items.len);
}
