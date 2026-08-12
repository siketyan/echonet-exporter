const std = @import("std");
const io = std.Io;
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
                defer self.allocator.free(data);

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

                var reader = io.Reader.fixed(data);

                var resp: echonet.Frame = undefined;
                try resp.readAlloc(&reader, self.allocator);
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

/// A transport that replays canned responses instead of talking to a device.
const TestingTransport = struct {
    const Self = @This();

    allocator: mem.Allocator,
    /// Frames to be returned by recv(), in this order.
    responses: []const []const u8,
    /// Number of recv() calls made so far.
    recv_count: usize = 0,
    /// Error to be returned by recv() once the responses are exhausted.
    error_on_exhausted: anyerror = error.TimedOut,
    /// The last frame passed to send(), owned by this struct.
    sent: ?[]u8 = null,

    fn deinit(self: *Self) void {
        if (self.sent) |sent| self.allocator.free(sent);
    }

    fn send(self: *Self, data: []const u8) !void {
        if (self.sent) |sent| self.allocator.free(sent);
        self.sent = try self.allocator.dupe(u8, data);
    }

    /// Returns a buffer owned by the caller, as the real transports do.
    fn recv(self: *Self, timeout: i32) anyerror![]u8 {
        _ = timeout;

        if (self.recv_count >= self.responses.len) return self.error_on_exhausted;
        defer self.recv_count += 1;

        return try self.allocator.dupe(u8, self.responses[self.recv_count]);
    }
};

/// A Get request for the instantaneous electric power (EPC 0xE7).
fn testingRequest(allocator: mem.Allocator, tid: u16) !echonet.Frame {
    return echonet.Frame{
        .format1 = .{
            .tid = tid,
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
                .props = try echonet.PropertyList.fromSlice(allocator, &.{.{ .epc = 0xE7 }}),
            },
        },
    };
}

/// The serialized form of testingRequest() with TID 0x1234.
const request_bytes = "\x10\x81\x12\x34\x05\xFF\x01\x02\x88\x01\x62\x01\xE7\x00";

/// A Get_Res for the request above, carrying 500 W.
const response_bytes = "\x10\x81\x12\x34\x02\x88\x01\x05\xFF\x01\x72\x01\xE7\x04\x00\x00\x01\xF4";

/// The same response, but belonging to another transaction.
const other_response_bytes = "\x10\x81\x00\x01\x02\x88\x01\x05\xFF\x01\x72\x01\xE7\x04\x00\x00\x00\x64";

test "handle - sends the request and returns the response of the same transaction" {
    const t = std.testing;

    var transport = TestingTransport{
        .allocator = t.allocator,
        .responses = &.{response_bytes},
    };
    defer transport.deinit();

    const controller = Controller(TestingTransport){
        .allocator = t.allocator,
        .transport = &transport,
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    const resp = try controller.handle(req) orelse return error.TestExpectedResponse;
    defer resp.deinit();

    try t.expectEqualStrings(request_bytes, transport.sent.?);

    // The returned frame must outlive the buffer it was parsed from.
    const bytes = try resp.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(response_bytes, bytes);
}

test "handle - ignores responses from another transaction" {
    const t = std.testing;

    var transport = TestingTransport{
        .allocator = t.allocator,
        .responses = &.{ other_response_bytes, response_bytes },
    };
    defer transport.deinit();

    const controller = Controller(TestingTransport){
        .allocator = t.allocator,
        .transport = &transport,
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    const resp = try controller.handle(req) orelse return error.TestExpectedResponse;
    defer resp.deinit();

    try t.expectEqual(0x1234, resp.getTID());
    try t.expectEqual(2, transport.recv_count);

    const bytes = try resp.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(response_bytes, bytes);
}

test "handle - returns null when the transport timed out" {
    const t = std.testing;

    var transport = TestingTransport{
        .allocator = t.allocator,
        .responses = &.{},
        .error_on_exhausted = error.TimedOut,
    };
    defer transport.deinit();

    const controller = Controller(TestingTransport){
        .allocator = t.allocator,
        .transport = &transport,
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    try t.expect(try controller.handle(req) == null);
}

test "handle - propagates errors other than a timeout" {
    const t = std.testing;

    var transport = TestingTransport{
        .allocator = t.allocator,
        .responses = &.{},
        .error_on_exhausted = error.NotConnected,
    };
    defer transport.deinit();

    const controller = Controller(TestingTransport){
        .allocator = t.allocator,
        .transport = &transport,
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    try t.expectError(error.NotConnected, controller.handle(req));
}
