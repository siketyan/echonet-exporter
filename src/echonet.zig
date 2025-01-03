const std = @import("std");
const debug = std.debug;
const io = std.io;
const mem = std.mem;

pub const EOJ = struct {
    /// Class group code
    class_group_code: u8,
    /// Class code
    class_code: u8,
    /// Instance code
    instance_code: u8,

    pub fn read(self: *EOJ, reader: io.AnyReader) !void {
        self.class_group_code = try reader.readByte();
        self.class_code = try reader.readByte();
        self.instance_code = try reader.readByte();
    }

    pub fn write(self: EOJ, writer: io.AnyWriter) !void {
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
    edt: []const u8 = &.{},

    pub fn deinit(self: Property, alloc: mem.Allocator) void {
        alloc.free(self.edt);
    }

    pub fn readAlloc(self: *Property, reader: io.AnyReader, alloc: mem.Allocator) !void {
        self.epc = try reader.readByte();

        const pdc = try reader.readByte();
        const edt = try alloc.alloc(u8, pdc);
        debug.assert(try reader.readAll(edt) == pdc);
        self.edt = edt;
    }

    pub fn write(self: Property, writer: io.AnyWriter) !void {
        try writer.writeByte(self.epc);
        try writer.writeByte(@intCast(self.edt.len)); // PDC
        try writer.writeAll(self.edt);
    }

    pub fn len(self: Property) usize {
        return 1 + 1 + self.edt.len; // EPC + PDC + EDT
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
    props: []const Property,

    pub fn deinit(self: EDATA, alloc: mem.Allocator) void {
        for (self.props) |p| {
            p.deinit(alloc);
        }

        alloc.free(self.props);
    }

    pub fn readAlloc(self: *EDATA, reader: io.AnyReader, alloc: mem.Allocator) !void {
        try self.seoj.read(reader);
        try self.deoj.read(reader);

        self.esv = try reader.readByte();

        const opc = try reader.readByte();
        const props = try alloc.alloc(Property, opc);
        for (0..opc) |i| {
            try props[i].readAlloc(reader, alloc);
        }
        self.props = props;
    }

    pub fn write(self: EDATA, writer: io.AnyWriter) !void {
        try self.seoj.write(writer);
        try self.deoj.write(writer);
        try writer.writeByte(self.esv);
        try writer.writeByte(@intCast(self.props.len)); // OPC

        for (self.props) |prop| {
            try prop.write(writer);
        }
    }

    pub fn len(self: EDATA) usize {
        var sum: usize = EOJ.len() + EOJ.len() + 1 + 1; // SEOJ + DEOJ + ESV + OPC
        for (self.props) |prop| {
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
        edata: []u8,
    };

    pub fn deinit(self: Frame, alloc: mem.Allocator) void {
        switch (self) {
            .format1 => |f| {
                f.edata.deinit(alloc);
            },
            else => {},
        }
    }

    pub fn getTID(self: Frame) u16 {
        return switch (self) {
            .format1 => |f| f.tid,
            .format2 => |f| f.tid,
        };
    }

    pub fn readAlloc(self: *Frame, reader: io.AnyReader, alloc: mem.Allocator) !void {
        const ehd1 = try reader.readByte();
        debug.assert(ehd1 == 0x10);

        const ehd2 = try reader.readByte();
        switch (ehd2) {
            0x81 => {
                self.format1.tid = try reader.readInt(u16, .big);
                try self.format1.edata.readAlloc(reader, alloc);
            },
            0x82 => {
                self.format2.tid = try reader.readInt(u16, .big);
                _ = try reader.readAll(self.format2.edata);
            },
            else => debug.panic("unexpected EHD2: 0x{X:0>2}", .{ehd2}),
        }
    }

    pub fn write(self: Frame, writer: io.AnyWriter) !void {
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
                try writer.writeAll(f.edata);
            }
        }
    }

    pub fn toBytesAlloc(self: Frame, alloc: mem.Allocator) ![]u8 {
        var stream = io.fixedBufferStream(try alloc.alloc(u8, self.len()));
        try self.write(stream.writer().any());

        return stream.getWritten();
    }

    pub fn len(self: Frame) usize {
        var sum: usize = 2 + 2; // EHD + TI

        switch (self) {
            .format1 => |f| {
                sum += f.edata.len();
            },
            .format2 => |f| {
                sum += f.edata.len;
            },
        }

        return sum;
    }
};

test "reading from bytes - format 1" {
    const allocator = std.testing.allocator;

    var stream = io.fixedBufferStream("\x10\x81\x12\x34\x05\xFF\x01\x02\x88\x01\x62\x02\xE7\x00\xE8\x00");

    var frame: Frame = undefined;
    try frame.readAlloc(stream.reader().any(), allocator);
    defer frame.deinit(allocator);

    const expected = Frame {
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
                .props = &.{
                    .{ .epc = 0xE7 },
                    .{ .epc = 0xE8 },
                },
            },
        },
    };

    try std.testing.expectEqualDeep(expected, frame);
}

test "writing to bytes - format 1" {
    const allocator = std.testing.allocator;

    const frame = Frame {
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
                .props = &.{
                    .{ .epc = 0xE7 },
                    .{ .epc = 0xE8 },
                },
            },
        },
    };

    const bytes = try frame.toBytesAlloc(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqualStrings("\x10\x81\x12\x34\x05\xFF\x01\x02\x88\x01\x62\x02\xE7\x00\xE8\x00", bytes);
}
