const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.serial_port);
const mem = std.mem;

const serial = @import("serial");

/// The cross-platform and low-level support API for a serial port.
/// Serial ports are represented as a file descriptor in Unix-like platforms.
/// It includes peeking support for reading and some tweaks.
pub const SerialPort = struct {
    const Self = @This();

    fd: Io.File,
    io: Io,
    fifo: std.Deque(u8),
    allocator: mem.Allocator,

    fn init(fd: Io.File, io: Io, allocator: mem.Allocator) Self {
        return Self{
            .fd = fd,
            .io = io,
            .fifo = .empty,
            .allocator = allocator,
        };
    }

    pub fn open(path: []const u8, baud_rate: u32, allocator: mem.Allocator, io: Io) !Self {
        const fd = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });

        try serial.configureSerialPort(fd, serial.SerialConfig{
            .baud_rate = baud_rate,
        });

        log.debug("The serial port {s} has been configured for baud rate {d}", .{ path, baud_rate });

        return init(fd, io, allocator);
    }

    pub fn close(self: *Self) void {
        self.fifo.deinit(self.allocator);
        self.fd.close(self.io);

        log.debug("The serial port has been closed successfully", .{});
    }

    const PollError = std.posix.PollError || error{
        BrokenPipe,
        Other,
    };

    /// Wait for the next data will be available with timeout.
    /// ref: https://github.com/serialport/serialport-rs/blob/22d69ba3105030e29dabf6fa621bdf3467e99f73/src/posix/poll.rs#L23-L52
    pub fn poll(self: *Self, timeout: i32) PollError!bool {
        // TODO: Windows support
        const posix = std.posix;

        var fds: [1]posix.pollfd = .{.{
            .fd = self.fd.handle,
            .events = posix.POLL.IN,
            .revents = undefined,
        }};

        const wait = try posix.poll(&fds, timeout);
        if (wait != 1) {
            return false;
        }

        return switch (fds[0].revents) {
            posix.POLL.IN => true,
            posix.POLL.HUP | posix.POLL.NVAL => error.BrokenPipe,
            else => error.Other,
        };
    }

    pub const ReadError = Io.File.ReadStreamingError;

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        var fifo_len: usize = 0;
        while (fifo_len < buf.len) : (fifo_len += 1) {
            buf[fifo_len] = self.fifo.popFront() orelse break;
        }
        if (fifo_len == buf.len) {
            log.debug("Read {d} bytes from the FIFO buffer and the buffer is already filled", .{fifo_len});

            return fifo_len;
        }

        const raw_len = self.fd.readStreaming(self.io, &.{buf[fifo_len..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };

        log.debug("Read {d} bytes from the FIFO buffer and {d} bytes from the port", .{ fifo_len, raw_len });

        return fifo_len + raw_len;
    }

    pub fn readAll(self: *Self, buf: []u8) ReadError!void {
        var offset: usize = 0;
        while (offset < buf.len) {
            const len = try self.read(buf[offset..]);
            if (len == 0) return error.EndOfStream;
            offset += len;
        }
    }

    pub fn readByte(self: *Self) ReadError!u8 {
        var buf: [1]u8 = undefined;
        try self.readAll(&buf);
        return buf[0];
    }

    pub const PutBackError = error{OutOfMemory};

    /// Put the buffer back to the stream so we can read it again.
    pub fn putBack(self: *Self, buf: []const u8) PutBackError!void {
        try self.fifo.pushFrontSlice(self.allocator, buf);

        log.debug("Put back {d} bytes to the FIFO buffer", .{buf.len});
    }

    pub const PeekError = PutBackError || ReadError;

    /// Read from the port to fill the buffer and put back it immediately.
    pub fn peek(self: *Self, buf: []u8) PeekError!usize {
        const len = try self.read(buf);
        if (len > 0) {
            try self.putBack(buf[0..len]);
        }

        return len;
    }

    pub const WriteError = Io.File.Writer.Error;

    pub fn writeAll(self: *Self, bytes: []const u8) WriteError!void {
        return self.fd.writeStreamingAll(self.io, bytes);
    }

    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) WriteError!void {
        var buffer: [256]u8 = undefined;
        var writer = self.fd.writer(self.io, &buffer);
        writer.interface.print(fmt, args) catch return writer.err.?;
        writer.interface.flush() catch return writer.err.?;
    }
};

test {
    const t = std.testing;

    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();

    const write_fd = try tmp_dir.dir.createFile(t.io, "serial_port.dat", .{ .read = true });
    var write_port = SerialPort.init(write_fd, t.io, t.allocator);
    try write_port.writeAll("Hello, world!");
    write_port.close();

    const read_fd = try tmp_dir.dir.openFile(t.io, "serial_port.dat", .{ .mode = .read_write });
    var port = SerialPort.init(read_fd, t.io, t.allocator);
    defer port.close();

    var buf: [5]u8 = undefined;
    var len = try port.read(&buf);
    try t.expectEqual(5, len);
    try t.expectEqualStrings("Hello", &buf);

    try port.putBack(&buf);

    var buf2: [7]u8 = undefined;
    len = try port.peek(&buf2);
    try t.expectEqual(7, len);
    try t.expectEqualStrings("Hello, ", &buf2);

    var buf3: [13]u8 = undefined;
    len = try port.read(&buf3);
    try t.expectEqual(13, len);
    try t.expectEqualStrings("Hello, world!", &buf3);
}

test "poll - reports whether the next data is available" {
    const t = std.testing;

    // A pipe stays empty until written to, unlike a regular file, which always
    // reports itself as ready.
    const fds = try std.Io.Threaded.pipe2(.{});

    var write_fd: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer write_fd.close(t.io);

    var port = SerialPort.init(.{ .handle = fds[0], .flags = .{ .nonblocking = false } }, t.io, t.allocator);
    defer port.close();

    try t.expect(!try port.poll(0));

    try write_fd.writeStreamingAll(t.io, "Hello");

    try t.expect(try port.poll(0));
}
