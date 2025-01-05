const std = @import("std");
const debug = std.debug;
const io = std.io;
const log = std.log.scoped(.bp35c0);
const mem = std.mem;

const SerialPort = @import("./serial_port.zig").SerialPort;

const CR = '\r';
const LF = '\n';
const CRLF = "\r\n";

pub const ErrorCode = enum {
    /// Reserved
    ER01,
    /// Reserved
    ER02,
    /// Reserved
    ER03,
    /// Command not supported
    ER04,
    /// Invalid argument
    ER05,
    /// Invalid format or out of range
    ER06,
    /// Reserved
    ER07,
    /// Reserved
    ER08,
    /// UART input error
    ER09,
    /// Execution failed
    ER10,
};

pub const Error = error{
    CommandNotSupported,
    InvalidArgument,
    InvalidFormatOrOutOfRange,
    UartInputError,
    ExecutionFailed,
};

pub const SREG = enum {
    S02,
    S03,
    S07,
    S0A,
    S0B,
    S15,
    S16,
    S17,
    S1C,
    SA1,
    SA2,
    SA9,
    SF0,
    SFB,
    SFD,
    SFE,
    SFF,
};

pub const Side = enum(u8) {
    /// B side (Wi-SUN)
    B = 0,
    /// H side (HAN)
    H = 1,
};

pub const ScanMode = enum(u8) {
    /// ED scan
    ed_scan = 0,
    /// Active scan w/ IE
    active_scan_with_ie = 2,
    /// Active scan w/o IE
    active_scan_without_ie = 3,
};

pub const SecOption = enum(u8) {
    /// Use plaintext always.
    plain_text = 0,
    /// Use encrypted when a PANA session is active, otherwise the data will be ignored.
    encrypted = 1,
    /// Use encrypted when a PANA session is active, otherwise plaintext will be used.
    encrypted_fallback = 2,
};

pub const Event = union(enum) {
    const Self = @This();

    const ERXUDP = struct {
        _allocator: mem.Allocator,
        sender: [16]u8,
        dest: [16]u8,
        rport: u16,
        lport: u16,
        sender_lla: [8]u8,
        // TODO: rssi
        secured: bool,
        side: Side,
        data: []u8,

        pub fn deinit(self: ERXUDP) void {
            self._allocator.free(self.data);
        }
    };

    const EPANDESC = struct {
        channel: u8,
        channel_page: u8,
        pan_id: u16,
        addr: [8]u8,
        lqi: u8,
        side: Side,
        pair_id: [8]u8,
    };

    const EVENT = struct {
        num: u8,
        sender: [16]u8,
        side: Side,
        param: ?u8,
    };

    erxudp: ERXUDP,
    epandesc: EPANDESC,
    event: EVENT,

    pub fn deinit(self: Self) void {
        switch (self) {
            .erxudp => |e| e.deinit(),
            else => {},
        }
    }
};

fn formatIp6Addr(data: [16]u8, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    if (fmt.len != 0) std.fmt.invalidFmtError(fmt, data);
    _ = options;

    try std.fmt.format(
        writer,
        "{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}",
        .{
            std.fmt.fmtSliceHexUpper(data[0..2]),
            std.fmt.fmtSliceHexUpper(data[2..4]),
            std.fmt.fmtSliceHexUpper(data[4..6]),
            std.fmt.fmtSliceHexUpper(data[6..8]),
            std.fmt.fmtSliceHexUpper(data[8..10]),
            std.fmt.fmtSliceHexUpper(data[10..12]),
            std.fmt.fmtSliceHexUpper(data[12..14]),
            std.fmt.fmtSliceHexUpper(data[14..16]),
        },
    );
}

fn fmtIp6Addr(ip_addr: [16]u8) std.fmt.Formatter(formatIp6Addr) {
    return std.fmt.Formatter(formatIp6Addr){ .data = ip_addr };
}

/// Low-level API for controlling BP35C0 via the underlying port.
pub fn BP35C0Raw(comptime Port: type) type {
    return struct {
        const Self = @This();
        const EventQueue = std.fifo.LinearFifo(Event, .Dynamic);

        port: *Port,
        allocator: mem.Allocator,
        event_queue: EventQueue,

        fn initUnsafe(port: *Port, allocator: mem.Allocator) Self {
            return Self{
                .port = port,
                .allocator = allocator,
                .event_queue = EventQueue.init(allocator),
            };
        }

        pub fn init(port: *Port, allocator: mem.Allocator) !Self {
            var self = initUnsafe(port, allocator);

            try self.skreset();
            try self.sksreg(.SFE, "0"); // Turn off echo-back

            return self;
        }

        pub fn close(self: *Self) void {
            self.skterm() catch {};
            self.event_queue.deinit();
        }

        /// Write characters to the underlying port.
        fn write(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            log.debug("> " ++ fmt, args);
            try std.fmt.format(self.port.writer(), fmt, args);
        }

        /// Write a command line and CR + LF.
        fn writeLine(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            log.debug("> " ++ fmt, args);
            try std.fmt.format(self.port.writer(), fmt ++ "\r\n", args);
        }

        /// Read data from the port until CR + LF is found.
        fn readLine(self: *Self) ![]u8 {
            const reader = self.port.reader();

            var buf = std.ArrayList(u8).init(self.allocator);
            var cr = false;

            while (true) {
                const b = try reader.readByte();
                if (cr and b == LF) {
                    _ = buf.popOrNull(); // Remove the last CR
                    break;
                }

                cr = b == CR;
                try buf.append(b);
            }

            const s = try buf.toOwnedSlice();
            log.debug("< {s}", .{s});

            return s;
        }

        fn readCRLF(self: *Self) !void {
            var buf: [2]u8 = undefined;
            const len = try self.port.read(&buf);
            debug.assert(len == 2);
            debug.assert(mem.eql(u8, &buf, CRLF));
        }

        /// Read the next response from the device and interpret as an error or void.
        fn readResult(self: *Self) !void {
            const reader = self.port.reader();
            var buf: [4]u8 = undefined;

            while (true) {
                _ = try reader.readAll(&buf);

                // FIXME: I don't know why, sometimes unread CRLF is read here.
                if (mem.startsWith(u8, &buf, CRLF)) {
                    log.debug("FIXME: Unread CRLF here", .{});
                    @memcpy(buf[0..2], buf[2..4]);
                    _ = try reader.readAll(buf[2..4]);
                }

                if (mem.eql(u8, &buf, "OK" ++ CRLF)) {
                    log.debug("< OK", .{});
                    return;
                }

                if (mem.eql(u8, &buf, "FAIL")) {
                    _ = try reader.readByte();
                    _ = try reader.read(&buf);
                    _ = try self.readCRLF();

                    inline for (@typeInfo(ErrorCode).@"enum".fields) |f| {
                        if (mem.eql(u8, &buf, f.name)) {
                            const code: ErrorCode = @enumFromInt(f.value);
                            log.debug("< FAIL {s}", .{f.name});

                            switch (code) {
                                .ER04 => return error.CommandNotSupported,
                                .ER05 => return error.InvalidArgument,
                                .ER06 => return error.InvalidFormatOrOutOfRange,
                                .ER09 => return error.UartInputError,
                                .ER10 => return error.ExecutionFailed,
                                else => {},
                            }
                        }
                    }

                    debug.panic("Unexpected error code {s}", .{&buf});
                }

                if (mem.startsWith(u8, &buf, "SK")) {
                    self.allocator.free(try self.readLine());
                    continue;
                }

                if (buf[0] == 'E') {
                    try self.port.putBack(&buf);

                    const event = try self.waitNewEvent();
                    try self.event_queue.writeItem(event);
                    log.debug("Postponed an event: {}", .{event});

                    continue;
                }

                log.debug("Received an unexpected response: {any}", .{&buf});
            }
        }

        pub fn skreset(self: *Self) !void {
            try self.writeLine("SKRESET", .{});
            return try self.readResult();
        }

        pub fn sksreg(self: *Self, sreg: SREG, val: []const u8) !void {
            try self.writeLine("SKSREG {s} {s}", .{ @tagName(sreg), val });
            return try self.readResult();
        }

        pub fn sksetrbid(self: *Self, rbid: []const u8) !void {
            try self.write("SKSETRBID ", .{});
            try self.port.writer().writeAll(rbid);
            try self.port.writer().writeAll(CRLF);
            return try self.readResult();
        }

        pub fn sksetpwd(self: *Self, pwd: []const u8) !void {
            try self.write("SKSETPWD {X} ", .{pwd.len});
            try self.port.writer().writeAll(pwd);
            try self.port.writer().writeAll(CRLF);
            return try self.readResult();
        }

        pub fn skscan(self: *Self, mode: ScanMode, channel_mask: u32, duration: u8, side: Side) !void {
            try self.writeLine("SKSCAN {X} {X:0>8} {X} {X}", .{
                @intFromEnum(mode),
                channel_mask,
                duration,
                @intFromEnum(side),
            });

            return try self.readResult();
        }

        pub fn skll64(self: *Self, addr64: [8]u8) ![16]u8 {
            try self.writeLine("SKLL64 {}", .{std.fmt.fmtSliceHexUpper(&addr64)});

            const buf = try self.readLine();
            defer self.allocator.free(buf);

            const ip6_addr = try std.net.Ip6Address.parse(buf, 0);
            return ip6_addr.sa.addr;
        }

        pub fn skjoin(self: *Self, ip_addr: [16]u8) !void {
            try self.writeLine("SKJOIN {}", .{fmtIp6Addr(ip_addr)});
            return self.readResult();
        }

        pub fn sksendto(
            self: *Self,
            handle: u8,
            ip_addr: [16]u8,
            port: u16,
            sec: SecOption,
            side: Side,
            data: []const u8,
        ) !void {
            try self.write("SKSENDTO {X} {} {X:0>4} {X} {X} {X:0>4} ", .{
                handle,
                fmtIp6Addr(ip_addr),
                port,
                @intFromEnum(sec),
                @intFromEnum(side),
                data.len,
            });
            try self.port.writer().writeAll(data);
            try self.port.writer().writeAll(CRLF);

            log.debug("> {}", .{std.fmt.fmtSliceHexUpper(data)});

            return try self.readResult();
        }

        pub fn skterm(self: *Self) !void {
            try self.writeLine("SKTERM", .{});
            return self.readResult();
        }

        fn readWord(self: *Self) ![]u8 {
            const reader = self.port.reader();

            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            while (true) {
                const b = try reader.readByte();
                if (b == ' ') {
                    break;
                }

                if (b == CR) {
                    debug.assert(try reader.readByte() == LF);
                    break;
                }

                try buf.append(b);
            }

            return buf.toOwnedSlice();
        }

        fn readProperty(self: *Self, comptime name: []const u8) !void {
            var buf: [name.len + 3]u8 = undefined;
            _ = try self.port.reader().readAll(&buf);
            debug.assert(mem.eql(u8, &buf, "  " ++ name ++ ":"));
        }

        fn readUnsignedHex(self: *Self, comptime T: type) !T {
            const buf = try self.readWord();
            defer self.allocator.free(buf);

            return try std.fmt.parseUnsigned(T, buf, 16);
        }

        fn readErxudp(self: *Self) !Event.ERXUDP {
            const head = try self.readWord();
            defer self.allocator.free(head);
            debug.assert(mem.eql(u8, head, "ERXUDP"));

            const sender = try self.readWord();
            defer self.allocator.free(sender);
            debug.assert(sender.len == 39);

            const dest = try self.readWord();
            defer self.allocator.free(dest);
            debug.assert(dest.len == 39);

            const rport = try self.readUnsignedHex(u16);
            const lport = try self.readUnsignedHex(u16);

            const sender_lla_raw = try self.readWord();
            defer self.allocator.free(sender_lla_raw);
            debug.assert(sender_lla_raw.len == 16);

            var sender_lla: [8]u8 = undefined;
            _ = try std.fmt.hexToBytes(&sender_lla, sender_lla_raw);

            const secured = try self.readUnsignedHex(u8);
            const side = try self.readUnsignedHex(u8);

            const data_len = try self.readUnsignedHex(u16);
            const data = try self.allocator.alloc(u8, data_len);
            debug.assert(try self.port.reader().readAll(data) == data_len);

            _ = try self.readCRLF();

            log.debug("< ERXUDP {s} {s} {X:0>4} {X:0>4} {s} {X} {X} {X:0>4} {}", .{
                sender,
                dest,
                rport,
                lport,
                sender_lla_raw,
                secured,
                side,
                data_len,
                std.fmt.fmtSliceHexUpper(data),
            });

            return .{
                ._allocator = self.allocator,
                .sender = (try std.net.Ip6Address.parse(sender, 0)).sa.addr,
                .dest = (try std.net.Ip6Address.parse(dest, 0)).sa.addr,
                .rport = rport,
                .lport = lport,
                .sender_lla = sender_lla,
                .secured = secured != 0,
                .side = @enumFromInt(side),
                .data = data,
            };
        }

        fn readEpandesc(self: *Self) !Event.EPANDESC {
            const head = try self.readLine();
            defer self.allocator.free(head);
            debug.assert(mem.eql(u8, head, "EPANDESC"));

            try self.readProperty("Channel");
            const channel = try self.readUnsignedHex(u8);

            try self.readProperty("Channel Page");
            const channel_page = try self.readUnsignedHex(u8);

            try self.readProperty("Pan ID");
            const pan_id = try self.readUnsignedHex(u16);

            try self.readProperty("Addr");
            const addr_raw = try self.readWord();
            defer self.allocator.free(addr_raw);
            debug.assert(addr_raw.len == 16);

            var addr: [8]u8 = undefined;
            _ = try std.fmt.hexToBytes(&addr, addr_raw);

            try self.readProperty("LQI");
            const lqi = try self.readUnsignedHex(u8);

            try self.readProperty("Side");
            const side = try self.readUnsignedHex(u8);

            try self.readProperty("PairID");
            const pair_id = try self.readWord();
            defer self.allocator.free(pair_id);
            debug.assert(addr.len == 8);

            log.debug("< EPANDESC ( Channel = {X}, Channel Page = {X}, PAN ID = {X}, Addr = {}, LQI = {X}, Side = {X}, Pair ID = {s} )", .{
                channel,
                channel_page,
                pan_id,
                std.fmt.fmtSliceHexUpper(&addr),
                lqi,
                side,
                pair_id,
            });

            return .{
                .channel = channel,
                .channel_page = channel_page,
                .pan_id = pan_id,
                .addr = addr,
                .lqi = lqi,
                .side = @enumFromInt(side),
                .pair_id = pair_id[0..8].*,
            };
        }

        fn readEvent(self: *Self) !Event.EVENT {
            const head = try self.readWord();
            defer self.allocator.free(head);
            debug.assert(mem.eql(u8, head, "EVENT"));

            const num = try self.readUnsignedHex(u8);
            const sender = try self.readWord();
            defer self.allocator.free(sender);
            const side = try self.readUnsignedHex(u8);
            const param = if (num == 0x21 or num == 0x45) try self.readUnsignedHex(u8) else null;

            log.debug("< EVENT {X} {s} {X} {?X}", .{num, sender, side, param});

            return .{
                .num = num,
                .sender = (try std.net.Ip6Address.parse(sender, 0)).sa.addr,
                .side = @enumFromInt(side),
                .param = param,
            };
        }

        pub fn waitNewEvent(self: *Self) !Event {
            const head = try self.readWord();
            defer self.allocator.free(head);
            try self.port.putBack(" ");
            try self.port.putBack(head);

            if (mem.eql(u8, head, "EVENT")) {
                return .{ .event = try self.readEvent() };
            }

            if (mem.eql(u8, head, "EPANDESC")) {
                return .{ .epandesc = try self.readEpandesc() };
            }

            if (mem.eql(u8, head, "ERXUDP")) {
                return .{ .erxudp = try self.readErxudp() };
            }

            debug.panic("Unsupported event: {s}", .{head});
        }

        pub fn waitEvent(self: *Self) !Event {
            // Consume the event queue first.
            if (self.event_queue.readItem()) |event| {
                log.debug("Consumed a postponed event: {}", .{event});

                return event;
            }

            return try waitNewEvent(self);
        }

        pub fn pollEvent(self: *Self, timeout: i32) !?Event {
            if (self.event_queue.readableLength() > 0) {
                return try self.waitEvent();
            }

            if (!try self.port.poll(timeout)) {
                return null;
            }

            return try self.waitEvent();
        }
    };
}

pub const Credentials = struct {
    rbid: []const u8,
    pwd: []const u8,
};

pub const Options = struct {
    scan_channel_mask: u32 = 0xFFFF_FFFF,
    scan_duration: u8 = 6,
    credentials: ?Credentials = null,
};

pub fn BP35C0(comptime Port: type) type {
    return struct {
        const Self = @This();

        const HANDLE = 1;
        const PORT = 3610;

        raw: BP35C0Raw(Port),
        allocator: mem.Allocator,
        options: Options,

        is_connected: bool = false,
        remote_addr: ?[16]u8 = null,

        pub fn init(port: *Port, allocator: mem.Allocator, options: Options) !Self {
            return Self{
                .raw = try BP35C0Raw(Port).init(port, allocator),
                .allocator = allocator,
                .options = options,
            };
        }

        pub fn close(self: *Self) void {
            self.raw.close();
        }

        pub fn setCredentials(self: *Self, creds: Credentials) !void {
            if (self.is_connected) {
                return error.AlreadyConnected;
            }

            self.credentials = creds;
        }

        pub fn connect(self: *Self) !void {
            if (self.options.credentials) |creds| {
                try self.raw.sksetrbid(creds.rbid);
                try self.raw.sksetpwd(creds.pwd);
            }

            try self.raw.skscan(
                .active_scan_with_ie,
                self.options.scan_channel_mask,
                self.options.scan_duration,
                .B,
            );

            while (true) {
                const event = try self.raw.waitEvent();
                switch (event) {
                    .event => |e| switch (e.num) {
                        0x20 => break,
                        0x22 => return error.CoordinatorNotFound,
                        else => log.debug("Ignored an event: {}", .{e}),
                    },
                    else => log.debug("Ignored an event: {}", .{event}),
                }
            }

            // Use the first EPANDESC for the connection.
            const epandesc = try self.raw.readEpandesc();

            // Ignore other ones until scan completed (EVENT 22).
            while (true) {
                const event = try self.raw.waitEvent();
                switch (event) {
                    .event => |e| switch (e.num) {
                        0x22 => break,
                        else => log.debug("Ignored an event: {}", .{e}),
                    },
                    else => log.debug("Ignored an event: {}", .{event}),
                }
            }

            // Convert the address of the found corrdinator to an IPv6 address.
            self.remote_addr = try self.raw.skll64(epandesc.addr);

            var channel: [2]u8 = undefined;
            var pan_id: [4]u8 = undefined;
            _ = try std.fmt.bufPrint(&channel, "{X:0>2}", .{epandesc.channel});
            _ = try std.fmt.bufPrint(&pan_id, "{X:0>4}", .{epandesc.pan_id});

            try self.raw.sksreg(.S02, &channel);
            try self.raw.sksreg(.S03, &pan_id);
            try self.raw.skjoin(self.remote_addr orelse unreachable);

            // Wait for connection established (EVENT 25) or failed (EVENT 24)
            while (true) {
                const event = try self.raw.waitEvent();
                switch (event) {
                    .event => |e| switch (e.num) {
                        0x24 => return error.ConnectionFailed,
                        0x25 => break,
                        else => log.debug("Ignored an event: {}", .{e}),
                    },
                    else => log.debug("Ignored an event: {}", .{event}),
                }
            }

            self.is_connected = true;
        }

        pub fn recv(self: *Self, timeout: i32) ![]u8 {
            while (self.is_connected) {
                const event = try self.raw.pollEvent(timeout) orelse return error.TimedOut;
                const erxudp: Event.ERXUDP = switch (event) {
                    .erxudp => |e| e,
                    else => {
                        log.debug("Ignored an event: {}", .{event});
                        continue;
                    },
                };
                defer erxudp.deinit();

                // Ignore other senders and non ECHONET Lite traffic.
                if (!mem.eql(u8, &erxudp.sender, &(self.remote_addr orelse unreachable)) or
                    erxudp.rport != PORT or
                    erxudp.lport != PORT)
                {
                    continue;
                }

                return try self.allocator.dupe(u8, erxudp.data);
            } else {
                return error.NotConnected;
            }
        }

        pub fn send(self: *Self, data: []const u8) !void {
            if (!self.is_connected) {
                return error.NotConnected;
            }

            try self.raw.sksendto(
                HANDLE,
                self.remote_addr orelse unreachable,
                PORT,
                .encrypted,
                .B,
                data,
            );
        }
    };
}

const TestingPort = struct {
    const Self = @This();

    rx: io.FixedBufferStream([]u8),
    tx: io.FixedBufferStream([]u8),
    peek: std.fifo.LinearFifo(u8, .Dynamic),
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator) !Self {
        return Self{
            .rx = io.fixedBufferStream(try allocator.alloc(u8, 1024)),
            .tx = io.fixedBufferStream(try allocator.alloc(u8, 1024)),
            .peek = std.fifo.LinearFifo(u8, .Dynamic).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: Self) void {
        self.allocator.free(self.rx.buffer);
        self.allocator.free(self.tx.buffer);
        self.peek.deinit();
    }

    pub fn putBack(self: *Self, buf: []const u8) !void {
        try self.peek.unget(buf);
    }

    const Reader = io.Reader(*Self, anyerror, read);

    fn read(self: *Self, buf: []u8) !usize {
        var len = self.peek.read(buf);
        if (len < buf.len) {
            len += try self.rx.read(buf[len..]);
        }

        return len;
    }

    fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    fn writer(self: *Self) io.FixedBufferStream([]u8).Writer {
        return self.tx.writer();
    }
};

test "SKRESET" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.skreset();
    try t.expectEqualStrings("SKRESET\r\n", port.tx.buffer[0..9]);
}

test "SKSREG" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.sksreg(.S02, "21");
    try t.expectEqualStrings("SKSREG S02 21\r\n", port.tx.buffer[0..15]);

    @memcpy(port.rx.buffer[4..8], "OK\r\n");
    try bp35c0.sksreg(.S03, "1234");
    try t.expectEqualStrings("SKSREG S03 1234\r\n", port.tx.buffer[15..32]);
}

test "SKSETRBID" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.sksetrbid("00112233445566778899AABBCCDDEEFF");
    try t.expectEqualStrings("SKSETRBID 00112233445566778899AABBCCDDEEFF\r\n", port.tx.buffer[0..44]);
}

test "SKSETPWD" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.sksetpwd("0123456789AB");
    try t.expectEqualStrings("SKSETPWD C 0123456789AB\r\n", port.tx.buffer[0..25]);
}

test "SKSCAN" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.skscan(.active_scan_with_ie, 0xFFFF_FFFF, 6, .B);
    try t.expectEqualStrings("SKSCAN 2 FFFFFFFF 6 0\r\n", port.tx.buffer[0..23]);
}

test "SKLL64" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);

    @memcpy(port.rx.buffer[0..41], "FE80:0000:0000:0000:021D:1290:1234:5678\r\n");
    const ip6_addr = try bp35c0.skll64("\x00\x1D\x12\x90\x12\x34\x56\x78".*);
    try t.expectEqualStrings("\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78", &ip6_addr);
    try t.expectEqualStrings("SKLL64 001D129012345678\r\n", port.tx.buffer[0..25]);
}

test "SKJOIN" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.skjoin("\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78".*);
    try t.expectEqualStrings("SKJOIN FE80:0000:0000:0000:021D:1290:1234:5678\r\n", port.tx.buffer[0..48]);
}

test "SKSENDTO" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.sksendto(
        1,
        "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78".*,
        3610,
        .encrypted,
        .B,
        "12345",
    );
    try t.expectEqualStrings(
        "SKSENDTO 1 FE80:0000:0000:0000:021D:1290:1234:5678 0E1A 1 0 0005 12345\r\n",
        port.tx.buffer[0..72],
    );
}

test "SKTERM" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..4], "OK\r\n");
    try bp35c0.skterm();
    try t.expectEqualStrings("SKTERM\r\n", port.tx.buffer[0..8]);

    @memcpy(port.rx.buffer[4..15], "FAIL ER10\r\n");
    try t.expectError(Error.ExecutionFailed, bp35c0.skterm());
}

test "ERXUDP" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(
        port.rx.buffer[0..130],
        "ERXUDP FE80:0000:0000:0000:021D:1290:1234:5678 FE80:0000:0000:0000:021D:1290:1234:5678 0E1A 0E1A 001D129012345678 1 0 0005 12345\r\n",
    );

    const actual = try bp35c0.readErxudp();
    defer actual.deinit();

    const expected: Event.ERXUDP = .{
        ._allocator = t.allocator,
        .sender = "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78".*,
        .dest = "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78".*,
        .rport = 3610,
        .lport = 3610,
        .sender_lla = "\x00\x1D\x12\x90\x12\x34\x56\x78".*,
        .secured = true,
        .side = .B,
        .data = try t.allocator.dupe(u8, "12345"),
    };
    defer expected.deinit();

    try t.expectEqualDeep(expected, actual);
}

test "EPANDESC" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    const response_raw =
        \\EPANDESC
        \\  Channel:21
        \\  Channel Page:09
        \\  Pan ID:8888
        \\  Addr:12345678ABCDEF01
        \\  LQI:E1
        \\  Side:0
        \\  PairID:AABBCCDD
        \\
    ;

    // Replace LF to CRLF.
    var response: [130]u8 = undefined;
    _ = mem.replace(u8, response_raw, &.{LF}, CRLF, &response);
    @memcpy(port.rx.buffer[0..130], &response);

    const actual = try bp35c0.readEpandesc();
    const expected: Event.EPANDESC = .{
        .channel = 0x21,
        .channel_page = 0x09,
        .pan_id = 0x8888,
        .addr = "\x12\x34\x56\x78\xAB\xCD\xEF\x01".*,
        .lqi = 0xE1,
        .side = .B,
        .pair_id = "AABBCCDD".*,
    };

    try t.expectEqualDeep(expected, actual);
}

test "EVENT" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..52], "EVENT 1F FE80:0000:0000:0000:021D:1290:0003:C890 0\r\n");

    const actual = try bp35c0.readEvent();
    const expected: Event.EVENT = .{
        .num = 0x1F,
        .sender = "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x00\x03\xC8\x90".*,
        .side = .B,
        .param = null,
    };

    try t.expectEqualDeep(expected, actual);
}

test "waitEvent" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer port.deinit();

    @memcpy(port.rx.buffer[0..52], "EVENT 1F FE80:0000:0000:0000:021D:1290:0003:C890 0\r\n");

    const actual = try bp35c0.waitEvent();
    const expected: Event = .{ .event = .{
        .num = 0x1F,
        .sender = "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x00\x03\xC8\x90".*,
        .side = .B,
        .param = null,
    } };

    try t.expectEqualDeep(expected, actual);
}
