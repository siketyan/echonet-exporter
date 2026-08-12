const std = @import("std");
const io = std.Io;
const log = std.log.scoped(.controller);
const mem = std.mem;

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");

pub fn Controller(comptime Transport: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        transport: *Transport,
        retry: config.Retry = .{},
        // writer: *@TypeOf(writer),

        /// Sends the request and waits for the response of the same transaction.
        /// The request is retransmitted until the configured attempts are exhausted,
        /// as the underlying transport is UDP and gives no delivery guarantee.
        /// Returns null if no response arrived within any of the attempts.
        pub fn handle(self: *const Self, req: echonet.Frame) !?echonet.Frame {
            const buf = try req.toBytesAlloc(self.allocator);
            defer self.allocator.free(buf);

            var attempt: u8 = 0;
            return while (attempt < self.retry.max_attempts) : (attempt += 1) {
                if (attempt > 0) {
                    log.warn("No response for the transaction {X:0>4}, retransmitting ({d}/{d})", .{
                        req.getTID(),
                        attempt + 1,
                        self.retry.max_attempts,
                    });
                }

                try self.transport.send(buf);

                // A response to an earlier attempt is accepted as well, since every
                // attempt of a transaction carries the same TID.
                if (try self.receive(req.getTID())) |resp| break resp;
            } else null;
        }

        /// Waits for the response of the transaction, ignoring the frames of another one.
        /// Returns null if nothing arrived within the configured time-out.
        fn receive(self: *const Self, tid: u16) !?echonet.Frame {
            while (true) {
                const data = self.transport.recv(self.retry.timeout_ms) catch |err| {
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

                if (resp.getTID() != tid) {
                    log.info("Response from another transaction, ignoring: {any}", .{resp});
                    continue;
                }

                return try resp.clone();
            }
        }
    };
}

/// A transport that replays canned responses instead of talking to a device.
const TestingTransport = struct {
    const Self = @This();

    allocator: mem.Allocator,
    /// Frames or errors to be returned by recv(), in this order.
    responses: []const anyerror![]const u8,
    /// Number of recv() calls made so far.
    recv_count: usize = 0,
    /// Error to be returned by recv() once the responses are exhausted.
    error_on_exhausted: anyerror = error.TimedOut,
    /// Number of send() calls made so far.
    send_count: usize = 0,
    /// The last frame passed to send(), owned by this struct.
    sent: ?[]u8 = null,
    /// The last time-out passed to recv().
    timeout: ?i32 = null,

    fn deinit(self: *Self) void {
        if (self.sent) |sent| self.allocator.free(sent);
    }

    fn send(self: *Self, data: []const u8) !void {
        if (self.sent) |sent| self.allocator.free(sent);
        self.sent = try self.allocator.dupe(u8, data);
        self.send_count += 1;
    }

    /// Returns a buffer owned by the caller, as the real transports do.
    fn recv(self: *Self, timeout: i32) anyerror![]u8 {
        self.timeout = timeout;

        if (self.recv_count >= self.responses.len) return self.error_on_exhausted;
        defer self.recv_count += 1;

        return try self.allocator.dupe(u8, try self.responses[self.recv_count]);
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

test "handle - retransmits the request until the response arrives" {
    const t = std.testing;

    // The first attempt is lost somewhere, the second one is answered.
    var transport = TestingTransport{
        .allocator = t.allocator,
        .responses = &.{ error.TimedOut, response_bytes },
    };
    defer transport.deinit();

    const controller = Controller(TestingTransport){
        .allocator = t.allocator,
        .transport = &transport,
        .retry = .{ .max_attempts = 3, .timeout_ms = 1000 },
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    const resp = try controller.handle(req) orelse return error.TestExpectedResponse;
    defer resp.deinit();

    try t.expectEqual(2, transport.send_count);
    try t.expectEqual(1000, transport.timeout);

    // The retransmitted request must be the same one, TID included.
    try t.expectEqualStrings(request_bytes, transport.sent.?);

    const bytes = try resp.toBytesAlloc(t.allocator);
    defer t.allocator.free(bytes);

    try t.expectEqualStrings(response_bytes, bytes);
}

test "handle - returns null once the attempts are exhausted" {
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
        .retry = .{ .max_attempts = 3 },
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    try t.expect(try controller.handle(req) == null);
    try t.expectEqual(3, transport.send_count);
}

test "handle - sends the request once when the retries are disabled" {
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
        .retry = .{ .max_attempts = 1 },
    };

    const req = try testingRequest(t.allocator, 0x1234);
    defer req.deinit();

    try t.expect(try controller.handle(req) == null);
    try t.expectEqual(1, transport.send_count);
}

test "handle - propagates errors other than a timeout without retrying" {
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
    try t.expectEqual(1, transport.send_count);
}
