const std = @import("std");
const debug = std.debug;
const io = std.Io;
const mem = std.mem;
const ArrayList = std.array_list.Managed;

const util = @import("./util.zig");

pub const EOJ = struct {
    /// Class group code
    class_group_code: u8,
    /// Class code
    class_code: u8,
    /// Instance code
    instance_code: u8,

    pub fn read(self: *EOJ, reader: *io.Reader) !void {
        self.class_group_code = try reader.takeByte();
        self.class_code = try reader.takeByte();
        self.instance_code = try reader.takeByte();
    }

    pub fn write(self: EOJ, writer: *io.Writer) !void {
        try writer.writeByte(self.class_group_code);
        try writer.writeByte(self.class_code);
        try writer.writeByte(self.instance_code);
    }

    pub fn len() usize {
        return 3;
    }
};

pub const Property = struct {
    /// ECHONET Lite Property (EPC)
    epc: u8,
    /// Property value data (EDT)
    edt: ?ArrayList(u8) = null,

    pub fn deinit(self: Property) void {
        if (self.edt) |edt| edt.deinit();
    }

    pub fn clone(self: Property) !Property {
        var cloned = self;
        if (self.edt) |edt| {
            cloned.edt = try edt.clone();
        }

        return cloned;
    }

    pub fn readAlloc(self: *Property, reader: *io.Reader, allocator: mem.Allocator) !void {
        self.epc = try reader.takeByte();

        const pdc = try reader.takeByte();
        if (pdc > 0) {
            const edt = try allocator.alloc(u8, pdc);
            errdefer allocator.free(edt);

            try reader.readSliceAll(edt);
            self.edt = ArrayList(u8).fromOwnedSlice(allocator, edt);
        } else {
            self.edt = null;
        }
    }

    pub fn write(self: Property, writer: *io.Writer) !void {
        try writer.writeByte(self.epc);
        if (self.edt) |edt| {
            try writer.writeByte(@intCast(edt.items.len)); // PDC
            try writer.writeAll(edt.items);
        } else {
            try writer.writeByte(0); // PDC
        }
    }

    pub fn len(self: Property) usize {
        return 1 + 1 + if (self.edt) |edt| edt.items.len else 0; // EPC + PDC + EDT
    }
};

pub const PropertyList = struct {
    const Self = @This();
    const List = ArrayList(Property);

    list: List,

    pub fn init(allocator: mem.Allocator, capacity: usize) mem.Allocator.Error!Self {
        return Self{ .list = try List.initCapacity(allocator, capacity) };
    }

    pub fn deinit(self: Self) void {
        for (self.asSlice()) |i| i.deinit();
        self.list.deinit();
    }

    pub fn clone(self: Self) !Self {
        var cloned = self;
        cloned.list = try self.list.clone();
        for (cloned.list.items) |*p| {
            p.* = try p.clone();
        }

        return cloned;
    }

    pub fn fromSlice(allocator: mem.Allocator, slice: []const Property) !Self {
        var list = try List.initCapacity(allocator, slice.len);
        list.appendSliceAssumeCapacity(slice);

        return Self{ .list = list };
    }

    pub fn fromOwnedSlice(allocator: mem.Allocator, slice: []Property) Self {
        return Self{ .list = List.fromOwnedSlice(allocator, slice) };
    }

    pub inline fn asSlice(self: Self) []const Property {
        return self.list.items;
    }

    pub inline fn len(self: Self) usize {
        return self.asSlice().len;
    }
};

pub const EDATA = struct {
    /// Source ECHONET Lite object specification
    seoj: EOJ,
    /// Destination ECHONET Lite object specification
    deoj: EOJ,
    /// ECHONET Lite service (ESV)
    esv: u8,
    /// Processing Target Properties
    props: PropertyList,

    pub fn deinit(self: EDATA) void {
        self.props.deinit();
    }

    pub fn clone(self: EDATA) !EDATA {
        var cloned = self;
        cloned.props = try self.props.clone();

        return cloned;
    }

    pub fn readAlloc(self: *EDATA, reader: *io.Reader, allocator: mem.Allocator) !void {
        try self.seoj.read(reader);
        try self.deoj.read(reader);

        self.esv = try reader.takeByte();

        const opc = try reader.takeByte();
        const props = try allocator.alloc(Property, opc);

        // Only the properties read so far own anything worth releasing.
        var read: usize = 0;
        errdefer {
            for (props[0..read]) |prop| prop.deinit();
            allocator.free(props);
        }

        while (read < opc) : (read += 1) {
            try props[read].readAlloc(reader, allocator);
        }

        self.props = PropertyList.fromOwnedSlice(allocator, props);
    }

    pub fn write(self: EDATA, writer: *io.Writer) !void {
        try self.seoj.write(writer);
        try self.deoj.write(writer);
        try writer.writeByte(self.esv);
        try writer.writeByte(@intCast(self.props.len())); // OPC

        for (self.props.asSlice()) |prop| {
            try prop.write(writer);
        }
    }

    pub fn len(self: EDATA) usize {
        var sum: usize = EOJ.len() + EOJ.len() + 1 + 1; // SEOJ + DEOJ + ESV + OPC
        for (self.props.asSlice()) |prop| {
            sum += prop.len();
        }

        return sum;
    }
};

pub const Frame = union(enum) {
    format1: Format1,
    format2: Format2,

    pub const Format1 = struct {
        /// Transaction ID
        tid: u16,
        /// ECHONET Lite data
        edata: EDATA,
    };

    pub const Format2 = struct {
        /// Transaction ID
        tid: u16,
        /// ECHONET Lite data
        edata: ArrayList(u8),
    };

    pub fn deinit(self: Frame) void {
        switch (self) {
            .format1 => |f| f.edata.deinit(),
            .format2 => |f| f.edata.deinit(),
        }
    }

    pub fn clone(self: Frame) !Frame {
        var cloned = self;
        switch (cloned) {
            .format1 => |*f| f.edata = try f.edata.clone(),
            .format2 => |*f| f.edata = try f.edata.clone(),
        }

        return cloned;
    }

    pub fn getTID(self: Frame) u16 {
        return switch (self) {
            .format1 => |f| f.tid,
            .format2 => |f| f.tid,
        };
    }

    pub fn readAlloc(self: *Frame, reader: *io.Reader, alloc: mem.Allocator) !void {
        // A frame arrives from the network, so a malformed one must not be fatal.
        const ehd1 = try reader.takeByte();
        if (ehd1 != 0x10) return error.InvalidFrameHeader;

        const ehd2 = try reader.takeByte();
        switch (ehd2) {
            0x81 => {
                self.* = .{ .format1 = undefined };
                self.format1.tid = try reader.takeInt(u16, .big);
                try self.format1.edata.readAlloc(reader, alloc);
            },
            0x82 => {
                self.* = .{ .format2 = undefined };
                self.format2.tid = try reader.takeInt(u16, .big);

                // The EDATA of a format 2 frame is arbitrary, so it spans the rest of the frame.
                const edata = try reader.allocRemaining(alloc, .unlimited);
                self.format2.edata = ArrayList(u8).fromOwnedSlice(alloc, edata);
            },
            else => return error.UnsupportedFrameFormat,
        }
    }

    pub fn write(self: Frame, writer: *io.Writer) !void {
        try writer.writeByte(0x10); // EHD1

        switch (self) {
            .format1 => |f| {
                try writer.writeByte(0x81); // EHD2
                try writer.writeInt(u16, f.tid, .big);
                try f.edata.write(writer);
            },
            .format2 => |f| {
                try writer.writeByte(0x82); // EHD2
                try writer.writeInt(u16, f.tid, .big);
                try writer.writeAll(f.edata.items);
            },
        }
    }

    pub fn toBytesAlloc(self: Frame, alloc: mem.Allocator) ![]u8 {
        const bytes = try alloc.alloc(u8, self.len());
        var writer = io.Writer.fixed(bytes);
        try self.write(&writer);
        debug.assert(writer.end == bytes.len);
        return bytes;
    }

    pub fn len(self: Frame) usize {
        var sum: usize = 2 + 2; // EHD + TI

        switch (self) {
            .format1 => |f| {
                sum += f.edata.len();
            },
            .format2 => |f| {
                sum += f.edata.items.len;
            },
        }

        return sum;
    }
};

test "reading from bytes - format 1" {
    const t = std.testing;

    var reader = io.Reader.fixed("\x10\x81\x12\x34\x05\xFF\x01\x02\x88\x01\x62\x02\xE7\x00\xE8\x00");

    var frame: Frame = undefined;
    try frame.readAlloc(&reader, t.allocator);
    defer frame.deinit();

    const expected = Frame{
        .format1 = .{
            .tid = 0x1234,
            .edata = .{
                .seoj = .{
                    .class_group_code = 0x05,
                    .class_code = 0xFF,
                    .instance_code = 0x01,
                },
                .deoj = .{
                    .class_group_code = 0x02,
                    .class_code = 0x88,
                    .instance_code = 0x01,
                },
                .esv = 0x62, // Get
                .props = try PropertyList.fromSlice(t.allocator, &.{
                    .{ .epc = 0xE7 },
                    .{ .epc = 0xE8 },
                }),
            },
        },
    };
    defer expected.deinit();

    try t.expectEqualDeep(expected, frame);
}

test "writing to bytes - format 1" {
    const t = std.testing;

    const frame = Frame{
        .format1 = .{
            .tid = 0x1234,
            .edata = .{
                .seoj = .{
                    .class_group_code = 0x05,
                    .class_code = 0xFF,
                    .instance_code = 0x01,
                },
                .deoj = .{
                    .class_group_code = 0x02,
                    .class_code = 0x88,
                    .instance_code = 0x01,
                },
                .esv = 0x62, // Get
                .props = try PropertyList.fromSlice(t.allocator, &.{
                    .{ .epc = 0xE7 },
                    .{ .epc = 0xE8 },
                }),
            },
        },
    };
    defer frame.deinit();

    const bytes = try frame.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings("\x10\x81\x12\x34\x05\xFF\x01\x02\x88\x01\x62\x02\xE7\x00\xE8\x00", bytes);
}

/// A Get_Res carrying 500 W in the instantaneous electric power (EPC 0xE7).
const format1_with_edt = "\x10\x81\x12\x34\x02\x88\x01\x05\xFF\x01\x72\x01\xE7\x04\x00\x00\x01\xF4";

/// Builds the frame equivalent to format1_with_edt.
fn format1WithEdt(allocator: mem.Allocator) !Frame {
    return Frame{
        .format1 = .{
            .tid = 0x1234,
            .edata = .{
                .seoj = .{
                    .class_group_code = 0x02,
                    .class_code = 0x88,
                    .instance_code = 0x01,
                },
                .deoj = .{
                    .class_group_code = 0x05,
                    .class_code = 0xFF,
                    .instance_code = 0x01,
                },
                .esv = 0x72, // Get_Res
                .props = try PropertyList.fromSlice(allocator, &.{.{
                    .epc = 0xE7,
                    .edt = try util.listFromSlice(u8, allocator, "\x00\x00\x01\xF4"),
                }}),
            },
        },
    };
}

test "reading from bytes - format 1 with a property value" {
    const t = std.testing;

    var reader = io.Reader.fixed(format1_with_edt);

    var actual: Frame = undefined;
    try actual.readAlloc(&reader, t.allocator);
    defer actual.deinit();

    const expected = try format1WithEdt(t.allocator);
    defer expected.deinit();

    try t.expectEqualDeep(expected, actual);
}

test "writing to bytes - format 1 with a property value" {
    const t = std.testing;

    const frame = try format1WithEdt(t.allocator);
    defer frame.deinit();

    const bytes = try frame.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(format1_with_edt, bytes);
}

test "reading from bytes - format 2" {
    const t = std.testing;

    var reader = io.Reader.fixed("\x10\x82\x12\x34\xDE\xAD\xBE\xEF");

    var actual: Frame = undefined;
    try actual.readAlloc(&reader, t.allocator);
    defer actual.deinit();

    try t.expectEqual(0x1234, actual.getTID());
    try t.expectEqualStrings("\xDE\xAD\xBE\xEF", actual.format2.edata.items);
}

test "writing to bytes - format 2" {
    const t = std.testing;

    const frame = Frame{
        .format2 = .{
            .tid = 0x1234,
            .edata = try util.listFromSlice(u8, t.allocator, "\xDE\xAD\xBE\xEF"),
        },
    };
    defer frame.deinit();

    const bytes = try frame.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings("\x10\x82\x12\x34\xDE\xAD\xBE\xEF", bytes);
}

/// A Get_Res answering about the instantaneous power and current at once.
const format1_with_two_properties =
    "\x10\x81\x12\x34\x02\x88\x01\x05\xFF\x01\x72\x02" ++
    "\xE7\x04\x00\x00\x01\xF4" ++
    "\xE8\x04\x12\x34\x56\x79";

fn format1WithTwoProperties(allocator: mem.Allocator) !Frame {
    return Frame{
        .format1 = .{
            .tid = 0x1234,
            .edata = .{
                .seoj = .{
                    .class_group_code = 0x02,
                    .class_code = 0x88,
                    .instance_code = 0x01,
                },
                .deoj = .{
                    .class_group_code = 0x05,
                    .class_code = 0xFF,
                    .instance_code = 0x01,
                },
                .esv = 0x72, // Get_Res
                .props = try PropertyList.fromSlice(allocator, &.{
                    .{
                        .epc = 0xE7,
                        .edt = try util.listFromSlice(u8, allocator, "\x00\x00\x01\xF4"),
                    },
                    .{
                        .epc = 0xE8,
                        .edt = try util.listFromSlice(u8, allocator, "\x12\x34\x56\x79"),
                    },
                }),
            },
        },
    };
}

test "reading from bytes - format 1 with several property values" {
    const t = std.testing;

    var reader = io.Reader.fixed(format1_with_two_properties);

    var actual: Frame = undefined;
    try actual.readAlloc(&reader, t.allocator);
    defer actual.deinit();

    const expected = try format1WithTwoProperties(t.allocator);
    defer expected.deinit();

    try t.expectEqualDeep(expected, actual);
}

test "writing to bytes - format 1 with several property values" {
    const t = std.testing;

    const frame = try format1WithTwoProperties(t.allocator);
    defer frame.deinit();

    // toBytesAlloc asserts that len() agrees with what write() produced.
    try t.expectEqual(format1_with_two_properties.len, frame.len());

    const bytes = try frame.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(format1_with_two_properties, bytes);
}

test "reading from bytes - reports a frame cut short" {
    const t = std.testing;

    // The value of the second property is missing its last two bytes.
    var reader = io.Reader.fixed(format1_with_two_properties[0 .. format1_with_two_properties.len - 2]);

    var frame: Frame = undefined;
    try t.expectError(error.EndOfStream, frame.readAlloc(&reader, t.allocator));
}

test "reading from bytes - rejects an unknown EHD1" {
    const t = std.testing;

    var reader = io.Reader.fixed("\x20\x81\x12\x34\x05\xFF\x01\x02\x88\x01\x62\x00");

    var frame: Frame = undefined;
    try t.expectError(error.InvalidFrameHeader, frame.readAlloc(&reader, t.allocator));
}

test "reading from bytes - rejects an unsupported EHD2" {
    const t = std.testing;

    var reader = io.Reader.fixed("\x10\x83\x12\x34\xDE\xAD\xBE\xEF");

    var frame: Frame = undefined;
    try t.expectError(error.UnsupportedFrameFormat, frame.readAlloc(&reader, t.allocator));
}

test "clone - format 1 does not share the property value with the original" {
    const t = std.testing;

    const original = try format1WithEdt(t.allocator);
    defer original.deinit();

    const cloned = try original.clone();
    defer cloned.deinit();

    // Mutating the original must leave the clone untouched.
    const edt = original.format1.edata.props.list.items[0].edt.?;
    edt.items[0] = 0xFF;

    const bytes = try cloned.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(format1_with_edt, bytes);
}

test "clone - format 2 does not share the data with the original" {
    const t = std.testing;

    const original = Frame{
        .format2 = .{
            .tid = 0x1234,
            .edata = try util.listFromSlice(u8, t.allocator, "\xDE\xAD\xBE\xEF"),
        },
    };
    defer original.deinit();

    const cloned = try original.clone();
    defer cloned.deinit();

    // Mutating the original must leave the clone untouched.
    original.format2.edata.items[0] = 0xFF;

    const bytes = try cloned.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings("\x10\x82\x12\x34\xDE\xAD\xBE\xEF", bytes);
}
