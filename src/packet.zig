const std = @import("std");
const mem = std.mem;
const net = std.net;

pub const Ip6Packet = struct {
    next_header: u8,
    hop_limit: u8,
    source_addr: net.Ip6Address,
    dest_addr: net.Ip6Address,
    payload: []u8,

    pub fn toBytesAlloc(self: Ip6Packet, alloc: mem.Allocator) ![]u8 {
        const buf = try alloc.alloc(u8, self.payload.len + 40);
        @memset(buf[0..40], 0);

        buf[0] = 0b0110_0000;
        buf[6] = self.next_header;
        buf[7] = self.hop_limit;

        mem.writeInt(u16, buf[4..6], @intCast(self.payload.len), .big);

        @memcpy(buf[8..24], &self.source_addr.sa.addr);
        @memcpy(buf[24..40], &self.dest_addr.sa.addr);
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
            const buf = .{bytes[i], if (bytes.len - i >= 2) bytes[i + 1] else 0};
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
    payload: []u8,

    pub fn init(source_addr: net.Ip6Address, dest_addr: net.Ip6Address, payload: []u8) UdpPacket {
        var checksum = Checksum{};

        checksum.addBytes(&source_addr.sa.addr);
        checksum.addBytes(&dest_addr.sa.addr);
        checksum.add(17); // next_header
        checksum.add(source_addr.getPort());
        checksum.add(dest_addr.getPort());
        checksum.add(@intCast((payload.len + 8) * 2));
        checksum.addBytes(payload);

        return UdpPacket {
            .source_port = source_addr.getPort(),
            .dest_port = dest_addr.getPort(),
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