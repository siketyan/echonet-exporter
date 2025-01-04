const std = @import("std");
const io = std.io;
const log = std.log.scoped(.controller);
const mem = std.mem;

const echonet = @import("./echonet.zig");

pub fn Controller(comptime Transport: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        transport: *Transport,
        // writer: *@TypeOf(writer),

        pub fn handle(self: *const Self, req: echonet.Frame) !?echonet.Frame {
            const buf = try req.toBytesAlloc(self.allocator);
            defer self.allocator.free(buf);

            try self.transport.send(buf);

            return while (true) {
                const data = self.transport.recv(5000) catch |err| {
                    switch (err) {
                        error.TimedOut => return null,
                        else => return err,
                    }
                };

                // const udp = UdpPacket.init(e.sender, e.dest, e.data);
                // const ip6 = Ip6Packet{
                //     .next_header = 17, // UDP
                //     .hop_limit = 64,
                //     .source_addr = e.sender,
                //     .dest_addr = e.dest,
                //     .payload = try udp.toBytesAlloc(state.allocator),
                // };
                //
                // try state.writer.writeRecord(.{}, try ip6.toBytesAlloc(state.allocator));

                var stream = io.fixedBufferStream(data);

                var resp: echonet.Frame = undefined;
                try resp.readAlloc(stream.reader().any(), self.allocator);
                defer resp.deinit();

                if (resp.getTID() != req.getTID()) {
                    log.info("Response from another transaction, ignoring: {any}", .{resp});
                    continue;
                }

                break try resp.clone();
            };
        }
    };
}
