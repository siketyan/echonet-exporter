const std = @import("std");
const debug = std.debug;
const Io = std.Io;
const ArrayList = std.array_list.Managed;
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

const Ip6AddrFormatter = struct {
    data: [16]u8,

    pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            "{X}:{X}:{X}:{X}:{X}:{X}:{X}:{X}",
            .{
                self.data[0..2],
                self.data[2..4],
                self.data[4..6],
                self.data[6..8],
                self.data[8..10],
                self.data[10..12],
                self.data[12..14],
                self.data[14..16],
            },
        );
    }
};

fn fmtIp6Addr(ip_addr: [16]u8) Ip6AddrFormatter {
    return .{ .data = ip_addr };
}

/// Low-level API for controlling BP35C0 via the underlying port.
pub fn BP35C0Raw(comptime Port: type) type {
    return struct {
        const Self = @This();
        const EventQueue = std.Deque(Event);

        port: *Port,
        allocator: mem.Allocator,
        event_queue: EventQueue,

        fn initUnsafe(port: *Port, allocator: mem.Allocator) Self {
            return Self{
                .port = port,
                .allocator = allocator,
                .event_queue = .empty,
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
            self.event_queue.deinit(self.allocator);
        }

        /// Write characters to the underlying port.
        fn write(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            log.debug("> " ++ fmt, args);
            try self.port.print(fmt, args);
        }

        /// Write a command line and CR + LF.
        fn writeLine(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            log.debug("> " ++ fmt, args);
            try self.port.print(fmt ++ "\r\n", args);
        }

        /// Read data from the port until CR + LF is found.
        fn readLine(self: *Self) ![]u8 {
            var buf = ArrayList(u8).init(self.allocator);
            var cr = false;

            while (true) {
                const b = try self.port.readByte();
                if (cr and b == LF) {
                    _ = buf.pop(); // Remove the last CR
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
            try self.port.readAll(&buf);
            debug.assert(mem.eql(u8, &buf, CRLF));
        }

        /// Read the next response from the device and interpret as an error or void.
        fn readResult(self: *Self) !void {
            var buf: [4]u8 = undefined;

            while (true) {
                try self.port.readAll(&buf);

                if (mem.eql(u8, &buf, "OK" ++ CRLF)) {
                    log.debug("< OK", .{});
                    return;
                }

                if (mem.eql(u8, &buf, "FAIL")) {
                    _ = try self.port.readByte();
                    try self.port.readAll(&buf);
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

                    // A reserved code lands here too, so it must not be fatal.
                    log.warn("Received an unexpected error code: {s}", .{&buf});
                    return error.UnexpectedErrorCode;
                }

                if (mem.startsWith(u8, &buf, "SK")) {
                    self.allocator.free(try self.readLine());
                    continue;
                }

                if (buf[0] == 'E') {
                    try self.port.putBack(&buf);

                    const event = try self.waitNewEvent();
                    try self.event_queue.pushBack(self.allocator, event);
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
            try self.port.writeAll(rbid);
            try self.port.writeAll(CRLF);
            return try self.readResult();
        }

        pub fn sksetpwd(self: *Self, pwd: []const u8) !void {
            try self.write("SKSETPWD {X} ", .{pwd.len});
            try self.port.writeAll(pwd);
            try self.port.writeAll(CRLF);
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
            try self.writeLine("SKLL64 {X}", .{&addr64});

            const buf = try self.readLine();
            defer self.allocator.free(buf);

            const ip6_addr = try Io.net.Ip6Address.parse(buf, 0);
            return ip6_addr.bytes;
        }

        pub fn skjoin(self: *Self, ip_addr: [16]u8) !void {
            try self.writeLine("SKJOIN {f}", .{fmtIp6Addr(ip_addr)});
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
            try self.write("SKSENDTO {X} {f} {X:0>4} {X} {X} {X:0>4} ", .{
                handle,
                fmtIp6Addr(ip_addr),
                port,
                @intFromEnum(sec),
                @intFromEnum(side),
                data.len,
            });
            try self.port.writeAll(data);

            log.debug("> {X}", .{data});

            // Unlike other commands, the response to SKSENDTO starts with CRLF.
            try self.readCRLF();
            return try self.readResult();
        }

        pub fn skterm(self: *Self) !void {
            try self.writeLine("SKTERM", .{});
            return self.readResult();
        }

        fn readWord(self: *Self) ![]u8 {
            var buf = ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            while (true) {
                const b = try self.port.readByte();
                if (b == ' ') {
                    break;
                }

                if (b == CR) {
                    debug.assert(try self.port.readByte() == LF);
                    break;
                }

                try buf.append(b);
            }

            return buf.toOwnedSlice();
        }

        fn readProperty(self: *Self, comptime name: []const u8) !void {
            var buf: [name.len + 3]u8 = undefined;
            try self.port.readAll(&buf);
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
            try self.port.readAll(data);

            _ = try self.readCRLF();

            log.debug("< ERXUDP {s} {s} {X:0>4} {X:0>4} {s} {X} {X} {X:0>4} {X}", .{
                sender,
                dest,
                rport,
                lport,
                sender_lla_raw,
                secured,
                side,
                data_len,
                data,
            });

            return .{
                ._allocator = self.allocator,
                .sender = (try Io.net.Ip6Address.parse(sender, 0)).bytes,
                .dest = (try Io.net.Ip6Address.parse(dest, 0)).bytes,
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

            log.debug("< EPANDESC ( Channel = {X}, Channel Page = {X}, PAN ID = {X}, Addr = {X}, LQI = {X}, Side = {X}, Pair ID = {s} )", .{
                channel,
                channel_page,
                pan_id,
                &addr,
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

            log.debug("< EVENT {X} {s} {X} {?X}", .{ num, sender, side, param });

            return .{
                .num = num,
                .sender = (try Io.net.Ip6Address.parse(sender, 0)).bytes,
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
            if (self.event_queue.popFront()) |event| {
                log.debug("Consumed a postponed event: {}", .{event});

                return event;
            }

            return try waitNewEvent(self);
        }

        pub fn pollEvent(self: *Self, timeout: i32) !?Event {
            if (self.event_queue.len > 0) {
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

            self.options.credentials = creds;
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
    const Buffer = struct {
        buffer: []u8,
        pos: usize = 0,
        len: usize = 0,
    };

    rx: Buffer,
    tx: Buffer,
    peek: std.Deque(u8),
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator) !Self {
        return Self{
            .rx = .{ .buffer = try allocator.alloc(u8, 1024) },
            .tx = .{ .buffer = try allocator.alloc(u8, 1024) },
            .peek = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.rx.buffer);
        self.allocator.free(self.tx.buffer);
        self.peek.deinit(self.allocator);
    }

    pub fn putBack(self: *Self, buf: []const u8) !void {
        try self.peek.pushFrontSlice(self.allocator, buf);
    }

    /// Queue up what the device would respond with.
    fn feed(self: *Self, data: []const u8) void {
        debug.assert(self.rx.len + data.len <= self.rx.buffer.len);

        @memcpy(self.rx.buffer[self.rx.len..][0..data.len], data);
        self.rx.len += data.len;
    }

    /// Everything written to the port so far.
    fn written(self: *const Self) []const u8 {
        return self.tx.buffer[0..self.tx.pos];
    }

    fn poll(self: *Self, timeout: i32) !bool {
        _ = timeout;

        return self.peek.len > 0 or self.rx.pos < self.rx.len;
    }

    fn read(self: *Self, buf: []u8) !usize {
        var len: usize = 0;
        while (len < buf.len) : (len += 1) {
            buf[len] = self.peek.popFront() orelse break;
        }
        if (len < buf.len) {
            const remaining = buf.len - len;
            @memcpy(buf[len..], self.rx.buffer[self.rx.pos..][0..remaining]);
            self.rx.pos += remaining;
            len += remaining;
        }

        return len;
    }

    fn readAll(self: *Self, buf: []u8) !void {
        if (try self.read(buf) != buf.len) return error.EndOfStream;
    }

    fn readByte(self: *Self) !u8 {
        var buf: [1]u8 = undefined;
        try self.readAll(&buf);
        return buf[0];
    }

    fn writeAll(self: *Self, bytes: []const u8) !void {
        @memcpy(self.tx.buffer[self.tx.pos..][0..bytes.len], bytes);
        self.tx.pos += bytes.len;
    }

    fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        var writer = Io.Writer.fixed(self.tx.buffer[self.tx.pos..]);
        try writer.print(fmt, args);
        self.tx.pos += writer.end;
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

    @memcpy(port.rx.buffer[0..6], "\r\nOK\r\n");
    try bp35c0.sksendto(
        1,
        "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78".*,
        3610,
        .encrypted,
        .B,
        "12345",
    );
    try t.expectEqualStrings(
        "SKSENDTO 1 FE80:0000:0000:0000:021D:1290:1234:5678 0E1A 1 0 0005 12345",
        port.tx.buffer[0..70],
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

test "readResult - maps every error code" {
    const t = std.testing;

    const cases = .{
        .{ "ER04", Error.CommandNotSupported },
        .{ "ER05", Error.InvalidArgument },
        .{ "ER06", Error.InvalidFormatOrOutOfRange },
        .{ "ER09", Error.UartInputError },
        .{ "ER10", Error.ExecutionFailed },
    };

    inline for (cases) |case| {
        var port = try TestingPort.init(t.allocator);
        defer port.deinit();

        var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
        defer bp35c0.event_queue.deinit(t.allocator);

        port.feed("FAIL " ++ case[0] ++ CRLF);

        try t.expectError(case[1], bp35c0.skreset());
    }
}

test "readResult - reports a reserved error code" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = BP35C0Raw(TestingPort).initUnsafe(&port, t.allocator);
    defer bp35c0.event_queue.deinit(t.allocator);

    port.feed("FAIL ER01" ++ CRLF);

    try t.expectError(error.UnexpectedErrorCode, bp35c0.skreset());
}

const epandesc_response =
    "EPANDESC" ++ CRLF ++
    "  Channel:21" ++ CRLF ++
    "  Channel Page:09" ++ CRLF ++
    "  Pan ID:8888" ++ CRLF ++
    "  Addr:12345678ABCDEF01" ++ CRLF ++
    "  LQI:E1" ++ CRLF ++
    "  Side:0" ++ CRLF ++
    "  PairID:AABBCCDD" ++ CRLF;

const remote_ip6_addr = "FE80:0000:0000:0000:021D:1290:1234:5678";

fn eventResponse(comptime num: []const u8) []const u8 {
    return "EVENT " ++ num ++ " " ++ remote_ip6_addr ++ " 0" ++ CRLF;
}

const testing_options: Options = .{
    .credentials = .{
        .rbid = "0123456789ABCDEF0123456789ABCDEF",
        .pwd = "0123456789AB",
    },
};

/// Builds a BP35C0 without the reset sequence that init() performs.
fn testingBP35C0(port: *TestingPort, allocator: mem.Allocator) BP35C0(TestingPort) {
    return BP35C0(TestingPort){
        .raw = BP35C0Raw(TestingPort).initUnsafe(port, allocator),
        .allocator = allocator,
        .options = testing_options,
    };
}

test "connect - performs the whole scan and join sequence" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = testingBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    port.feed("OK" ++ CRLF); // SKSETRBID
    port.feed("OK" ++ CRLF); // SKSETPWD
    port.feed("OK" ++ CRLF); // SKSCAN
    port.feed(eventResponse("20")); // Scan started
    port.feed(epandesc_response);
    port.feed(eventResponse("22")); // Scan completed
    port.feed(remote_ip6_addr ++ CRLF); // SKLL64
    port.feed("OK" ++ CRLF); // SKSREG S02
    port.feed("OK" ++ CRLF); // SKSREG S03
    port.feed("OK" ++ CRLF); // SKJOIN
    port.feed(eventResponse("25")); // Connection established

    try bp35c0.connect();

    try t.expect(bp35c0.is_connected);
    try t.expectEqualStrings(
        "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78",
        &bp35c0.remote_addr.?,
    );

    // The channel and the PAN ID of the found coordinator must be registered.
    try t.expectEqualStrings(
        "SKSETRBID 0123456789ABCDEF0123456789ABCDEF" ++ CRLF ++
            "SKSETPWD C 0123456789AB" ++ CRLF ++
            "SKSCAN 2 FFFFFFFF 6 0" ++ CRLF ++
            "SKLL64 12345678ABCDEF01" ++ CRLF ++
            "SKSREG S02 21" ++ CRLF ++
            "SKSREG S03 8888" ++ CRLF ++
            "SKJOIN " ++ remote_ip6_addr ++ CRLF,
        port.written(),
    );
}

test "connect - reports that no coordinator was found" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = testingBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    port.feed("OK" ++ CRLF); // SKSETRBID
    port.feed("OK" ++ CRLF); // SKSETPWD
    port.feed("OK" ++ CRLF); // SKSCAN
    port.feed(eventResponse("22")); // Scan completed without finding one

    try t.expectError(error.CoordinatorNotFound, bp35c0.connect());
    try t.expect(!bp35c0.is_connected);
}

test "connect - reports a failed join" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = testingBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    port.feed("OK" ++ CRLF); // SKSETRBID
    port.feed("OK" ++ CRLF); // SKSETPWD
    port.feed("OK" ++ CRLF); // SKSCAN
    port.feed(eventResponse("20"));
    port.feed(epandesc_response);
    port.feed(eventResponse("22"));
    port.feed(remote_ip6_addr ++ CRLF); // SKLL64
    port.feed("OK" ++ CRLF); // SKSREG S02
    port.feed("OK" ++ CRLF); // SKSREG S03
    port.feed("OK" ++ CRLF); // SKJOIN
    port.feed(eventResponse("24")); // Connection failed

    try t.expectError(error.ConnectionFailed, bp35c0.connect());
    try t.expect(!bp35c0.is_connected);
}

/// The link-local address of a node that is not the coordinator.
const other_ip6_addr = "FE80:0000:0000:0000:021D:1290:0003:C890";

fn erxudpResponse(comptime sender: []const u8, comptime data: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "ERXUDP {s} {s} 0E1A 0E1A 001D129012345678 1 0 {X:0>4} {s}" ++ CRLF,
        .{ sender, remote_ip6_addr, data.len, data },
    );
}

/// Builds a BP35C0 that has already joined the coordinator.
fn connectedBP35C0(port: *TestingPort, allocator: mem.Allocator) BP35C0(TestingPort) {
    var bp35c0 = testingBP35C0(port, allocator);
    bp35c0.is_connected = true;
    bp35c0.remote_addr = "\xFE\x80\x00\x00\x00\x00\x00\x00\x02\x1D\x12\x90\x12\x34\x56\x78".*;

    return bp35c0;
}

test "send - refuses to send while disconnected" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = testingBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    try t.expectError(error.NotConnected, bp35c0.send("12345"));
    try t.expectEqualStrings("", port.written());
}

test "send - writes the data to the coordinator" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = connectedBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    port.feed(CRLF ++ "OK" ++ CRLF);
    try bp35c0.send("12345");

    try t.expectEqualStrings(
        "SKSENDTO 1 " ++ remote_ip6_addr ++ " 0E1A 1 0 0005 12345",
        port.written(),
    );
}

test "recv - refuses to receive while disconnected" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = testingBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    try t.expectError(error.NotConnected, bp35c0.recv(0));
}

test "recv - returns the data sent by the coordinator" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = connectedBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    port.feed(erxudpResponse(remote_ip6_addr, "12345"));

    const data = try bp35c0.recv(0);
    defer t.allocator.free(data);

    try t.expectEqualStrings("12345", data);
}

test "recv - ignores traffic from another sender" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = connectedBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    port.feed(erxudpResponse(other_ip6_addr, "99999"));
    port.feed(erxudpResponse(remote_ip6_addr, "12345"));

    const data = try bp35c0.recv(0);
    defer t.allocator.free(data);

    try t.expectEqualStrings("12345", data);
}

test "recv - reports a timeout when nothing arrives" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = connectedBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    try t.expectError(error.TimedOut, bp35c0.recv(0));
}

test "setCredentials - refuses to replace the credentials while connected" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = connectedBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    try t.expectError(error.AlreadyConnected, bp35c0.setCredentials(.{
        .rbid = "FEDCBA9876543210FEDCBA9876543210",
        .pwd = "BA9876543210",
    }));
}

test "setCredentials - replaces the credentials while disconnected" {
    const t = std.testing;

    var port = try TestingPort.init(t.allocator);
    defer port.deinit();

    var bp35c0 = testingBP35C0(&port, t.allocator);
    defer bp35c0.raw.event_queue.deinit(t.allocator);

    try bp35c0.setCredentials(.{
        .rbid = "FEDCBA9876543210FEDCBA9876543210",
        .pwd = "BA9876543210",
    });

    try t.expectEqualStrings("FEDCBA9876543210FEDCBA9876543210", bp35c0.options.credentials.?.rbid);
    try t.expectEqualStrings("BA9876543210", bp35c0.options.credentials.?.pwd);
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
