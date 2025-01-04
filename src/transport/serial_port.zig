const std = @import("std");
const fifo = std.fifo;
const fs = std.fs;
const io = std.io;
const log = std.log.scoped(.serial_port);
const mem = std.mem;

const serial = @import("serial");

/// The cross-platform and low-level support API for a serial port.
/// Serial ports are represented as a file descriptor in Unix-like platforms.
/// It includes peeking support for reading and some tweaks.
pub const SerialPort = struct {
    const Self = @This();

    fd: fs.File,
    fifo: fifo.LinearFifo(u8, .Dynamic),

    fn init(fd: fs.File, allocator: mem.Allocator) Self {
        return Self{
            .fd = fd,
            .fifo = fifo.LinearFifo(u8, .Dynamic).init(allocator),
        };
    }

    pub fn open(path: []const u8, baud_rate: u32, allocator: mem.Allocator) !Self {
        const fd = try fs.cwd().openFile(path, .{ .mode = .read_write });

        try serial.configureSerialPort(fd, serial.SerialConfig{
            .baud_rate = baud_rate,
        });

        log.debug("The serial port {s} has been configured for baud rate {d}", .{ path, baud_rate });

        return init(fd, allocator);
    }

    pub fn close(self: Self) void {
        self.fifo.deinit();
        self.fd.close();

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

    pub const ReadError = fs.File.ReadError;
    pub const Reader = io.Reader(*Self, ReadError, read);

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        const fifo_len = self.fifo.read(buf);
        if (fifo_len == buf.len) {
            log.debug("Read {d} bytes from the FIFO buffer and the buffer is already filled", .{fifo_len});

            return fifo_len;
        }

        const raw_len = try self.fd.read(buf[fifo_len..]);

        log.debug("Read {d} bytes from the FIFO buffer and {d} bytes from the port", .{ fifo_len, raw_len });

        return fifo_len + raw_len;
    }

    /// Create a `io.Reader` for the serial port with peeking support.
    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub const PutBackError = error{OutOfMemory};

    /// Put the buffer back to the stream so we can read it again.
    pub fn putBack(self: *Self, buf: []const u8) PutBackError!void {
        try self.fifo.unget(buf);

        log.debug("Put back {d} bytes to the FIFO buffer", .{buf.len});
    }

    pub const PeekError = PutBackError || ReadError;

    /// Read from the port to fill the buffer and put back it immediately.
    pub fn peek(self: *Self, buf: []u8) PeekError!usize {
        const len = try self.read(buf);
        if (len > 0) {
            try self.putBack(buf);
        }

        return len;
    }

    pub const WriteError = fs.File.WriteError;
    pub const Writer = fs.File.Writer;

    /// Create a `io.Writer` for the serial port.
    pub fn writer(self: *Self) Writer {
        return self.fd.writer();
    }
};

test {
    const t = std.testing;

    const tmp_dir = t.tmpDir(.{});
    const fd = try tmp_dir.dir.createFile("serial_port.dat", .{ .read = true });
    var port = SerialPort.init(fd, t.allocator);
    defer port.close();

    try port.writer().writeAll("Hello, world!");
    try fd.seekTo(0);

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
