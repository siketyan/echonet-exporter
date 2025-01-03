const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const log = std.log;
const mem = std.mem;

const serial = @import("serial");

const peek_stream = @import("./peek_stream.zig");

const VTIME = 5;
const VMIN = 6;

pub const Connection = struct {
    buf: [1024]u8,
    fd: fs.File,
    stream: peek_stream.PeekStream(.{ .Static = 1024 }, fs.File.Reader),

    pub fn init(path: []const u8) !Connection {
        const fd = try fs.cwd().openFile(path, .{ .mode = .read_write });

        try serial.configureSerialPort(fd, serial.SerialConfig{
            .baud_rate = 115_200,
        });

        var settings = try std.posix.tcgetattr(fd.handle);

        settings.cc[VTIME] = 100;
        settings.cc[VMIN] = 0;

        try std.posix.tcsetattr(fd.handle, .NOW, settings);

        return Connection {
            .buf = undefined,
            .fd = fd,
            .stream = peek_stream.peekStream(1024, fd.reader()),
        };
    }

    pub fn close(self: *Connection) void {
        self.fd.close();
    }

    pub fn peekLine(self: *Connection) ![]u8 {
        const read = try self.readLine();
        try self.stream.putBack("\r\n");
        try self.stream.putBack(read);
        return read;
    }

    pub fn peekWordAlloc(self: *Connection, alloc: mem.Allocator, max_size: usize) ![]u8 {
        const read = try self.readWordAlloc(alloc, max_size);
        try self.stream.putBackByte(' ');
        try self.stream.putBack(read);
        return read;
    }

    pub fn tryRead(self: *Connection, buf: []u8) !usize {
        return try self.stream.read(buf);
    }

    pub fn readLine(self: *Connection) ![]u8 {
        const read = try self.stream.reader().readUntilDelimiter(&self.buf, '\n');

        // Remove CR at the last of the buffer so we removed CR + LF.
        return read[0 .. read.len - 1];
    }

    pub fn readLineAlloc(self: *Connection, alloc: mem.Allocator) ![]u8 {
        const read = try self.readLine();

        const buf = try alloc.alloc(u8, read.len);
        @memcpy(buf, read);

        return buf;
    }

    pub fn readWord(self: *Connection, buf: []u8) ![]u8 {
        return try self.stream.reader().readUntilDelimiter(buf, ' ');
    }

    pub fn readWordAlloc(self: *Connection, alloc: mem.Allocator, max_size: usize) ![]u8 {
        return try self.stream.reader().readUntilDelimiterAlloc(alloc, ' ', max_size);
    }

    pub fn readExact(self: *Connection, buf: []u8) !void {
        const len = try self.stream.reader().readAll(buf);
        debug.assert(len == buf.len);
    }

    pub fn writeLine(self: *Connection, comptime fmt: []const u8, args: anytype) !void {
        try std.fmt.format(self.fd.writer(), fmt, args);
        try self.fd.writer().writeAll("\r\n");
    }
};
