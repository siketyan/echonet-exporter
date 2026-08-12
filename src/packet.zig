const std = @import("std");
const mem = std.mem;
const net = std.Io.net;

pub const Ip6Packet = struct {
    next_header: u8,
    hop_limit: u8,
    source_addr: net.Ip6Address,
    dest_addr: net.Ip6Address,
    payload: []const u8,

    pub fn toBytesAlloc(self: Ip6Packet, alloc: mem.Allocator) ![]u8 {
        const buf = try alloc.alloc(u8, self.payload.len + 40);
        @memset(buf[0..40], 0);

        buf[0] = 0b0110_0000;
        buf[6] = self.next_header;
        buf[7] = self.hop_limit;

        mem.writeInt(u16, buf[4..6], @intCast(self.payload.len), .big);

        @memcpy(buf[8..24], &self.source_addr.bytes);
        @memcpy(buf[24..40], &self.dest_addr.bytes);
        @memcpy(buf[40..], self.payload);

        return buf;
    }
};

const Checksum = struct {
    value: u32 = 0,

    fn add(self: *Checksum, value: u16) void {
        self.value += value;

        while (self.value & 0xFFFF_0000 != 0) {
            self.value = (self.value & 0xFFFF) + (self.value >> 16);
        }
    }

    fn addBytes(self: *Checksum, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const buf: [2]u8 = .{ bytes[i], if (bytes.len - i >= 2) bytes[i + 1] else 0 };
            self.add(mem.readInt(u16, &buf, .big));
            i += 2;
        }
    }

    fn get(self: *Checksum) u16 {
        const val: u16 = @intCast(self.value);
        return ~val;
    }
};

pub const UdpPacket = struct {
    source_port: u16,
    dest_port: u16,
    checksum: u16,
    payload: []const u8,

    pub fn init(source_addr: net.Ip6Address, dest_addr: net.Ip6Address, payload: []const u8) UdpPacket {
        var checksum = Checksum{};

        checksum.addBytes(&source_addr.bytes);
        checksum.addBytes(&dest_addr.bytes);
        checksum.add(17); // next_header
        checksum.add(source_addr.port);
        checksum.add(dest_addr.port);
        // The length appears both in the pseudo header and in the UDP header.
        checksum.add(@intCast((payload.len + 8) * 2));
        checksum.addBytes(payload);

        return UdpPacket{
            .source_port = source_addr.port,
            .dest_port = dest_addr.port,
            .checksum = checksum.get(),
            .payload = payload,
        };
    }

    pub fn toBytesAlloc(self: UdpPacket, alloc: mem.Allocator) ![]u8 {
        var buf = try alloc.alloc(u8, self.payload.len + 8);
        @memset(buf[0..8], 0);

        mem.writeInt(u16, buf[0..2], self.source_port, .big);
        mem.writeInt(u16, buf[2..4], self.dest_port, .big);
        mem.writeInt(u16, buf[4..6], @intCast(self.payload.len + 8), .big);
        mem.writeInt(u16, buf[6..8], self.checksum, .big);

        @memcpy(buf[8..], self.payload);

        return buf;
    }
};

const testing_source_addr = "\xFE\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01";
const testing_dest_addr = "\xFE\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02";

/// An ECHONET Lite Get_Res carrying 500 W.
const testing_payload = "\x10\x81\x12\x34\x02\x88\x01\x05\xFF\x01\x72\x01\xE7\x04\x00\x00\x01\xF4";

fn testingAddrs() ![2]net.Ip6Address {
    return .{
        try net.Ip6Address.parse("fe80::1", 3610),
        try net.Ip6Address.parse("fe80::2", 3610),
    };
}

test "writing an IPv6 packet to bytes" {
    const t = std.testing;

    const addrs = try testingAddrs();
    const packet = Ip6Packet{
        .next_header = 17, // UDP
        .hop_limit = 64,
        .source_addr = addrs[0],
        .dest_addr = addrs[1],
        .payload = "\xDE\xAD\xBE\xEF",
    };

    const bytes = try packet.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(
        "\x60\x00\x00\x00" ++ // Version 6, traffic class and flow label
            "\x00\x04" ++ // Payload length
            "\x11" ++ // Next header (UDP)
            "\x40" ++ // Hop limit
            testing_source_addr ++
            testing_dest_addr ++
            "\xDE\xAD\xBE\xEF",
        bytes,
    );
}

test "writing a UDP packet to bytes" {
    const t = std.testing;

    const addrs = try testingAddrs();
    const packet = UdpPacket.init(addrs[0], addrs[1], testing_payload);

    try t.expectEqual(3610, packet.source_port);
    try t.expectEqual(3610, packet.dest_port);
    try t.expectEqual(0x6643, packet.checksum);

    const bytes = try packet.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(
        "\x0E\x1A" ++ // Source port
            "\x0E\x1A" ++ // Destination port
            "\x00\x1A" ++ // Length, including this header
            "\x66\x43" ++ // Checksum
            testing_payload,
        bytes,
    );
}

test "the UDP checksum pads a payload of an odd length" {
    const t = std.testing;

    const addrs = try testingAddrs();

    // The trailing byte of an odd length payload is padded with a zero, and the
    // carries of the sum are folded back in.
    try t.expectEqual(0xE79E, UdpPacket.init(addrs[0], addrs[1], "\xFF\xFF\xFF").checksum);
    try t.expectEqual(0xA5A3, UdpPacket.init(addrs[0], addrs[1], "\x41").checksum);
}
