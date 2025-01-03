const std = @import("std");
const debug = std.debug;
const fifo = std.fifo;
const log = std.log;
const mem = std.mem;
const net = std.net;

const Connection = @import("./connection.zig").Connection;

pub const Client = struct {
    conn: Connection,
    alloc: mem.Allocator,

    pub fn init(conn: Connection, alloc: mem.Allocator) Client {
        return Client{
            .conn = conn,
            .alloc = alloc,
        };
    }

    pub fn close(self: *Client) void {
        self.skterm() catch {};
        self.conn.close();
    }

    pub fn sksreg(self: *Client, sreg: []const u8, val: []const u8) !void {
        log.debug("> SKSREG {s} {s}", .{ sreg, val });

        try self.conn.writeLine("SKSREG {s} {s}", .{ sreg, val });
        try self.waitOk();
    }

    pub fn skreset(self: *Client) !void {
        log.debug("> SKRESET", .{});

        try self.conn.writeLine("SKRESET", .{});
        try self.waitOk();
    }

    pub fn sksetpwd(self: *Client, pwd: []const u8) !void {
        log.debug("> SKSETPWD {X} [REDACTED]", .{pwd.len});

        try self.conn.writeLine("SKSETPWD {X} {s}", .{ pwd.len, pwd });
        try self.waitOk();
    }

    pub fn sksetrbid(self: *Client, rbid: []const u8) !void {
        log.debug("> SKSETRBID [REDACTED]", .{});

        try self.conn.writeLine("SKSETRBID {s}", .{rbid});
        try self.waitOk();
    }

    pub fn skscan(self: *Client, mode: u8, channel_mask: u32, duration: u8, side: u8) !void {
        log.debug("> SKSCAN {X} {X:0>8} {X} {X}", .{ mode, channel_mask, duration, side });

        try self.conn.writeLine("SKSCAN {X} {X:0>8} {X} {X}", .{ mode, channel_mask, duration, side });
        try self.waitOk();
    }

    pub fn skll64(self: *Client, addr: [8]u8) !std.net.Ip6Address {
        log.debug("> SKLL64 {}", .{std.fmt.fmtSliceHexUpper(&addr)});

        try self.conn.writeLine("SKLL64 {}", .{std.fmt.fmtSliceHexUpper(&addr)});
        const read = try self.conn.readLine();

        log.debug("< {s}", .{read});

        return try net.Ip6Address.parse(read, 0);
    }

    fn formatIp6Addr(
        data: net.Ip6Address,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, data);
        _ = options;

        const addr = data.sa.addr;
        try std.fmt.format(
            writer,
            "{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}:{X:0>4}",
            .{
                std.fmt.fmtSliceHexUpper(addr[0..2]),
                std.fmt.fmtSliceHexUpper(addr[2..4]),
                std.fmt.fmtSliceHexUpper(addr[4..6]),
                std.fmt.fmtSliceHexUpper(addr[6..8]),
                std.fmt.fmtSliceHexUpper(addr[8..10]),
                std.fmt.fmtSliceHexUpper(addr[10..12]),
                std.fmt.fmtSliceHexUpper(addr[12..14]),
                std.fmt.fmtSliceHexUpper(addr[14..16]),
            },
        );
    }

    pub fn skjoin(self: *Client, addr: net.Ip6Address) !void {
        log.debug("> SKJOIN {}", .{std.fmt.Formatter(formatIp6Addr){ .data = addr }});

        try self.conn.writeLine("SKJOIN {}", .{std.fmt.Formatter(formatIp6Addr){ .data = addr }});
        try self.waitOk();
    }

    pub fn skterm(self: *Client) !void {
        try self.conn.writeLine("SKTERM", .{});
        _ = try self.conn.readLine(); // "FAIL ER10" if any connection is not established, "OK" otherwise.
    }

    pub fn sksendto(self: *Client, handle: u8, dest: net.Ip6Address, sec: u8, side: u8, data: []const u8) !void {
        log.debug("> SKSENDTO {X} {} {X:0>4} {X} {X} {X:0>4} [BINARY]", .{
            handle,
            std.fmt.Formatter(formatIp6Addr){ .data = dest },
            dest.getPort(),
            sec,
            side,
            data.len,
        });

        try self.conn.writeLine("SKSENDTO {X} {} {X:0>4} {X} {X} {X:0>4} {s}", .{
            handle,
            std.fmt.Formatter(formatIp6Addr){ .data = dest },
            dest.getPort(),
            sec,
            side,
            data.len,
            data,
        });
        try self.waitOk();
    }

    pub const Epandesc = struct {
        channel: u8,
        channel_page: u8,
        pan_id: u16,
        addr: [8]u8,
        lqi: u8,
        side: u8,
        pair_id: [8]u8,
    };

    pub fn readEpandesc(self: *Client) !Epandesc {
        debug.assert(mem.eql(u8, try self.conn.readLine(), "EPANDESC"));

        const reader = struct {
            conn: *Connection,

            fn readValue(this: @This()) ![]const u8 {
                var it = mem.splitBackwards(u8, try this.conn.readLine(), ":");
                return it.first();
            }

            fn readU8(this: @This()) !u8 {
                return try std.fmt.parseUnsigned(u8, try this.readValue(), 16);
            }

            fn readU16(this: @This()) !u16 {
                return try std.fmt.parseUnsigned(u16, try this.readValue(), 16);
            }

            fn readBytes(this: @This(), comptime len: usize) ![len]u8 {
                const hex = try this.readValue();
                var out: [len]u8 = undefined;
                _ = try std.fmt.hexToBytes(&out, hex);
                return out;
            }

            fn readChars(this: @This(), comptime len: usize) ![len]u8 {
                return (try this.readValue())[0..len].*;
            }
        }{
            .conn = &self.conn,
        };

        const desc = Epandesc{
            .channel = try reader.readU8(),
            .channel_page = try reader.readU8(),
            .pan_id = try reader.readU16(),
            .addr = try reader.readBytes(8),
            .lqi = try reader.readU8(),
            .side = try reader.readU8(),
            .pair_id = try reader.readChars(8),
        };

        log.debug("< EPANDESC ( Channel = {X}, Channel Page = {X}, PAN ID = {X}, Addr = {}, LQI = {X}, Side = {X}, Pair ID = {s} )", .{
            desc.channel,
            desc.channel_page,
            desc.pan_id,
            std.fmt.fmtSliceHexUpper(&desc.addr),
            desc.lqi,
            desc.side,
            desc.pair_id,
        });

        return desc;
    }

    pub const Erxudp = struct {
        sender: net.Ip6Address,
        dest: net.Ip6Address,
        sender_lla: [8]u8,
        // rssi: u8,
        secured: u8,
        side: u8,
        data: []u8,
    };

    pub fn readErxudp(self: *Client) !Erxudp {
        const read = try self.readWord();
        debug.assert(mem.eql(u8, read, "ERXUDP"));

        const sender_addr = try self.readWord();
        const dest_addr = try self.readWord();
        const sender_port = try self.readUnsignedHex(u16);
        const dest_port = try self.readUnsignedHex(u16);
        const sender_lla = try self.readHexBytes(8);
        const secured = try self.readUnsignedHex(u8);
        const side = try self.readUnsignedHex(u8);
        const data_len = try self.readUnsignedHex(u16);
        const data = try self.readExactBytes(data_len);

        _ = try self.conn.readLine();

        log.debug("< ERXUDP {s} {s} {X:0>4} {X:0>4} {} {X} {X} {X:0>4} [BINARY]", .{
            sender_addr,
            dest_addr,
            sender_port,
            dest_port,
            std.fmt.fmtSliceHexUpper(&sender_lla),
            secured,
            side,
            data_len,
        });

        return Erxudp{
            .sender = try net.Ip6Address.parse(sender_addr, sender_port),
            .dest = try net.Ip6Address.parse(dest_addr, dest_port),
            .sender_lla = sender_lla,
            .secured = secured,
            .side = side,
            .data = data,
        };
    }

    pub const Event = struct {
        num: u8,
        sender: net.Ip6Address,
        side: u8,
        param: ?u8,
    };

    pub fn readEvent(self: *Client) !Event {
        debug.assert(mem.eql(u8, try self.readWord(), "EVENT"));

        var it = mem.split(u8, try self.conn.readLine(), " ");

        const num = try std.fmt.parseInt(u8, it.next() orelse unreachable, 16);
        const sender = it.next() orelse unreachable;
        const side = try std.fmt.parseInt(u8, it.next() orelse unreachable, 16);
        const param = if (it.next()) |p| try std.fmt.parseInt(u8, p, 16) else null;

        log.debug("< EVENT {X} {s} {X} {?X}", .{ num, sender, side, param });

        return Event{
            .num = num,
            .sender = try net.Ip6Address.parse(sender, 0),
            .side = side,
            .param = param,
        };
    }

    pub const EventLike = union(enum) {
        event: Event,
        epandesc: Epandesc,
        erxudp: Erxudp,
    };

    pub fn readEventLike(self: *Client) !EventLike {
        const read = try self.conn.peekWordAlloc(self.alloc, 16);

        if (std.mem.eql(u8, read, "EVENT")) {
            return EventLike{ .event = try self.readEvent() };
        }

        if (std.mem.eql(u8, read, "EPANDESC")) {
            return EventLike{ .epandesc = try self.readEpandesc() };
        }

        if (std.mem.eql(u8, read, "ERXUDP")) {
            return EventLike{ .erxudp = try self.readErxudp() };
        }

        debug.panic("unexpected event: {s}", .{read});
    }

    // Wait for a "OK" response, ignoring other events.
    fn waitOk(self: *Client) !void {
        while (!mem.eql(u8, try self.conn.readLine(), "OK")) {}
        log.debug("< OK", .{});
    }

    fn readWord(self: *Client) ![]u8 {
        return try self.conn.readWordAlloc(self.alloc, 64);
    }

    fn readUnsignedHex(self: *Client, comptime T: type) !T {
        const read = try self.readWord();
        return try std.fmt.parseUnsigned(T, read, 16);
    }

    fn readHexBytes(self: *Client, comptime len: usize) ![len]u8 {
        var buf: [len]u8 = undefined;
        const read = try self.readWord();
        _ = try std.fmt.hexToBytes(&buf, read);
        return buf;
    }

    fn readExactBytes(self: *Client, len: usize) ![]u8 {
        const buf = try self.alloc.alloc(u8, len);
        try self.conn.readExact(buf);
        return buf;
    }
};
