const std = @import("std");
const http = std.http;
const Io = std.Io;
const log = std.log.scoped(.server);
const mem = std.mem;
const net = Io.net;

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");
const util = @import("./util.zig");

const TransactionManager = @import("./transaction.zig").TransactionManager;

pub fn Server(comptime Controller: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        io: Io,
        conf: config.Config,
        txm: *TransactionManager,
        controller: *const Controller,
        rx_buf: [2048]u8 = undefined,
        tx_buf: [2048]u8 = undefined,

        pub fn init(
            allocator: mem.Allocator,
            io: Io,
            conf: config.Config,
            txm: *TransactionManager,
            controller: *const Controller,
        ) Self {
            return Self{
                .allocator = allocator,
                .io = io,
                .conf = conf,
                .txm = txm,
                .controller = controller,
            };
        }

        pub fn run(self: *Self) !void {
            const addr = self.conf.address;
            var server = try addr.listen(self.io, .{
                .reuse_address = true,
            });
            defer server.deinit(self.io);

            log.info("HTTP server is ready at {f}", .{addr});

            while (true) {
                var conn = try server.accept(self.io);
                defer conn.close(self.io);

                log.info("A new connection has been accepted", .{});

                try self.handleConnection(conn);
            }
        }

        fn handleConnection(self: *Self, conn: net.Stream) !void {
            var reader = conn.reader(self.io, &self.rx_buf);
            var writer = conn.writer(self.io, &self.tx_buf);
            var http_server = http.Server.init(&reader.interface, &writer.interface);
            while (true) {
                var request = http_server.receiveHead() catch return;

                log.info("{s} {s} {s}", .{
                    @tagName(request.head.version),
                    @tagName(request.head.method),
                    request.head.target,
                });

                try self.handleRequest(&request);
            }
        }

        fn handleRequest(self: *Self, request: *http.Server.Request) !void {
            if (!mem.eql(u8, request.head.target, "/metrics")) {
                try request.respond(&.{}, .{ .status = .not_found });
                log.info("404 Not Found", .{});
                return;
            }

            if (request.head.method != .GET) {
                try request.respond(&.{}, .{ .status = .method_not_allowed });
                log.info("405 Method Not Allowed", .{});
                return;
            }

            var props = try echonet.PropertyList.init(self.allocator, self.conf.measures.items.len);
            defer props.deinit();
            for (self.conf.properties.items) |p| {
                try props.list.append(.{ .epc = p.epc, .edt = null });
            }

            const tid = self.txm.begin();
            const target = self.conf.target;
            const req = echonet.Frame{
                .format1 = .{
                    .tid = tid,
                    .edata = .{
                        .seoj = .{
                            .class_group_code = 0x05,
                            .class_code = 0xFF,
                            .instance_code = 0x01,
                        },
                        .deoj = .{
                            .class_group_code = target.class_group_code,
                            .class_code = target.class_code,
                            .instance_code = target.instance_code,
                        },
                        .esv = 0x62, // Get
                        .props = props,
                    },
                },
            };

            const resp = try self.controller.handle(req) orelse {
                // TODO: Retry
                try request.respond(&.{}, .{ .status = .gateway_timeout });
                log.info("504 Gateway Timeout", .{});
                return;
            };
            defer resp.deinit();

            var body: Io.Writer.Allocating = .init(self.allocator);
            defer body.deinit();
            const writer = &body.writer;

            for (self.conf.properties.items) |property| {
                const edt = for (resp.format1.edata.props.asSlice()) |p| {
                    if (p.epc == property.epc) {
                        if (p.edt) |edt| break edt;
                    }
                } else continue;

                var reader = Io.Reader.fixed(edt.items);

                for (property.layout.items) |layout| {
                    const name = layout.name.asSlice();
                    try writer.print("# TYPE {s} gauge\n", .{name});

                    const measure: ?config.Measure = for (self.conf.measures.items) |m| {
                        if (mem.eql(u8, m.name.asSlice(), layout.name.asSlice())) {
                            break m;
                        }
                    } else null;

                    if (measure) |m| {
                        if (m.help) |help| {
                            try writer.print("# HELP {s} {s}\n", .{ name, help.asSlice() });
                        }
                    }

                    try writer.writeAll(name);
                    try writer.writeByte(' ');

                    try switch (layout.type) {
                        .signed_char => writer.print("{d}", .{try reader.takeInt(i8, .big)}),
                        .signed_short => writer.print("{d}", .{try reader.takeInt(i16, .big)}),
                        .signed_long => writer.print("{d}", .{try reader.takeInt(i32, .big)}),
                        .unsigned_char => writer.print("{d}", .{try reader.takeInt(u8, .big)}),
                        .unsigned_short => writer.print("{d}", .{try reader.takeInt(u16, .big)}),
                        .unsigned_long => writer.print("{d}", .{try reader.takeInt(u32, .big)}),
                    };

                    try writer.writeByte('\n');
                }
            }

            try request.respond(body.writer.buffered(), .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain; version=0.0.4" },
                },
            });

            log.info("200 OK", .{});
        }
    };
}

/// A controller that replies with a canned frame instead of talking to a device.
const TestingController = struct {
    /// The frame to reply with, or null to report a timeout.
    response: ?echonet.Frame = null,

    fn handle(self: *const @This(), request: echonet.Frame) !?echonet.Frame {
        _ = request;

        const response = self.response orelse return null;
        return try response.clone();
    }
};

/// Builds a config exposing the R and T phase currents carried by EPC 0xE8.
fn testingConfig(allocator: mem.Allocator, with_help: bool) !config.Config {
    return config.Config{
        .address = try net.IpAddress.parse("127.0.0.1", 12345),
        .device = try config.String.fromSlice(allocator, "/dev/ttyUSB0"),
        .target = .{
            .class_group_code = 0x02,
            .class_code = 0x88,
            .instance_code = 0x01,
        },
        .measures = try util.listFromSlice(config.Measure, allocator, &.{
            .{
                .name = try config.String.fromSlice(allocator, "measured_instantaneous_current_r"),
                .help = if (with_help) try config.String.fromSlice(allocator, "瞬時電流計測値 (R 相)") else null,
            },
            .{
                .name = try config.String.fromSlice(allocator, "measured_instantaneous_current_t"),
                .help = if (with_help) try config.String.fromSlice(allocator, "瞬時電流計測値 (T 相)") else null,
            },
        }),
        .properties = try util.listFromSlice(config.Property, allocator, &.{.{
            .epc = 0xE8,
            .layout = try util.listFromSlice(config.Layout, allocator, &.{
                .{
                    .type = .signed_short,
                    .name = try config.String.fromSlice(allocator, "measured_instantaneous_current_r"),
                },
                .{
                    .type = .signed_short,
                    .name = try config.String.fromSlice(allocator, "measured_instantaneous_current_t"),
                },
            }),
        }}),
    };
}

/// Builds a Get_Res carrying the given value for the given property.
fn testingResponse(allocator: mem.Allocator, epc: u8, edt: []const u8) !echonet.Frame {
    return echonet.Frame{
        .format1 = .{
            .tid = 0x1234,
            .edata = .{
                .seoj = .{
                    .class_group_code = 0x02,
                    .class_code = 0x88,
                    .instance_code = 0x01,
                },
                .deoj = .{
                    .class_group_code = 0x05,
                    .class_code = 0xFF,
                    .instance_code = 0x01,
                },
                .esv = 0x72, // Get_Res
                .props = try echonet.PropertyList.fromSlice(allocator, &.{.{
                    .epc = epc,
                    .edt = try util.listFromSlice(u8, allocator, edt),
                }}),
            },
        },
    };
}

/// Runs a single request against the server and returns the raw response.
fn handleTestRequest(
    conf: config.Config,
    controller: *const TestingController,
    method: http.Method,
    target: []const u8,
    out: []u8,
) ![]const u8 {
    var input = Io.Reader.fixed(&.{});
    var output = Io.Writer.fixed(out);
    var http_server = http.Server.init(&input, &output);

    var request: http.Server.Request = .{
        .server = &http_server,
        .head = .{
            .method = method,
            .target = target,
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = false,
        },
        .head_buffer = &.{},
    };

    var txm = TransactionManager.init();
    var server = Server(TestingController){
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .conf = conf,
        .txm = &txm,
        .controller = controller,
    };

    try server.handleRequest(&request);

    return output.buffered();
}

/// Asserts on the response head, which is CRLF separated, and returns the body.
fn expectHead(expected: []const u8, actual: []const u8) ![]const u8 {
    const t = std.testing;

    var buf: [512]u8 = undefined;
    const len = mem.replacementSize(u8, expected, "\n", "\r\n");
    _ = mem.replace(u8, expected, "\n", "\r\n", buf[0..len]);

    try t.expect(actual.len >= len);
    try t.expectEqualStrings(buf[0..len], actual[0..len]);

    return actual[len..];
}

test "handleRequest - responds with the metrics of every configured property" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, true);
    defer conf.deinit();

    const response = try testingResponse(t.allocator, 0xE8, "\x12\x34\x56\x79");
    defer response.deinit();

    const controller = TestingController{ .response = response };

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .GET, "/metrics", &out);

    const body = try expectHead(
        \\HTTP/1.1 200 OK
        \\connection: close
        \\content-length: 309
        \\Content-Type: text/plain; version=0.0.4
        \\
        \\
    , bytes);

    try t.expectEqualStrings(
        \\# TYPE measured_instantaneous_current_r gauge
        \\# HELP measured_instantaneous_current_r 瞬時電流計測値 (R 相)
        \\measured_instantaneous_current_r 4660
        \\# TYPE measured_instantaneous_current_t gauge
        \\# HELP measured_instantaneous_current_t 瞬時電流計測値 (T 相)
        \\measured_instantaneous_current_t 22137
        \\
    , body);
}

/// Builds a config whose single property carries one value of every type.
fn testingTypesConfig(allocator: mem.Allocator) !config.Config {
    const Layouts = std.array_list.Managed(config.Layout);
    var layout = try Layouts.initCapacity(allocator, @typeInfo(config.Type).@"enum".fields.len);
    inline for (@typeInfo(config.Type).@"enum".fields) |f| {
        layout.appendAssumeCapacity(.{
            .type = @enumFromInt(f.value),
            .name = try config.String.fromSlice(allocator, f.name),
        });
    }

    return config.Config{
        .address = try net.IpAddress.parse("127.0.0.1", 12345),
        .device = try config.String.fromSlice(allocator, "/dev/ttyUSB0"),
        .target = .{
            .class_group_code = 0x02,
            .class_code = 0x88,
            .instance_code = 0x01,
        },
        .measures = try util.listFromSlice(config.Measure, allocator, &.{}),
        .properties = try util.listFromSlice(config.Property, allocator, &.{.{
            .epc = 0xE8,
            .layout = layout,
        }}),
    };
}

test "handleRequest - formats a value of every type" {
    const t = std.testing;

    const conf = try testingTypesConfig(t.allocator);
    defer conf.deinit();

    // The same bytes are read as signed and as unsigned, so a mistake in the
    // width or the signedness cannot go unnoticed.
    const response = try testingResponse(t.allocator, 0xE8, "\xFF" ++ // signed_char
        "\xFF\xFE" ++ // signed_short
        "\xFF\xFF\xFF\xFD" ++ // signed_long
        "\xFF" ++ // unsigned_char
        "\xFF\xFE" ++ // unsigned_short
        "\xFF\xFF\xFF\xFD" // unsigned_long
    );
    defer response.deinit();

    const controller = TestingController{ .response = response };

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .GET, "/metrics", &out);

    const body = try expectHead(
        \\HTTP/1.1 200 OK
        \\connection: close
        \\content-length: 268
        \\Content-Type: text/plain; version=0.0.4
        \\
        \\
    , bytes);

    try t.expectEqualStrings(
        \\# TYPE signed_char gauge
        \\signed_char -1
        \\# TYPE signed_short gauge
        \\signed_short -2
        \\# TYPE signed_long gauge
        \\signed_long -3
        \\# TYPE unsigned_char gauge
        \\unsigned_char 255
        \\# TYPE unsigned_short gauge
        \\unsigned_short 65534
        \\# TYPE unsigned_long gauge
        \\unsigned_long 4294967293
        \\
    , body);
}

test "handleRequest - omits the help line of a measure without one" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, false);
    defer conf.deinit();

    const response = try testingResponse(t.allocator, 0xE8, "\x12\x34\x56\x79");
    defer response.deinit();

    const controller = TestingController{ .response = response };

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .GET, "/metrics", &out);

    const body = try expectHead(
        \\HTTP/1.1 200 OK
        \\connection: close
        \\content-length: 169
        \\Content-Type: text/plain; version=0.0.4
        \\
        \\
    , bytes);

    try t.expectEqualStrings(
        \\# TYPE measured_instantaneous_current_r gauge
        \\measured_instantaneous_current_r 4660
        \\# TYPE measured_instantaneous_current_t gauge
        \\measured_instantaneous_current_t 22137
        \\
    , body);
}

test "handleRequest - skips a property missing from the response" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, true);
    defer conf.deinit();

    // The device answered about another property than the configured 0xE8.
    const response = try testingResponse(t.allocator, 0xE7, "\x00\x00\x01\xF4");
    defer response.deinit();

    const controller = TestingController{ .response = response };

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .GET, "/metrics", &out);

    const body = try expectHead(
        \\HTTP/1.1 200 OK
        \\connection: close
        \\content-length: 0
        \\Content-Type: text/plain; version=0.0.4
        \\
        \\
    , bytes);

    try t.expectEqualStrings("", body);
}

test "handleRequest - reports a property value that is too short" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, true);
    defer conf.deinit();

    // The layout expects two 16 bit values, but only one of them arrived.
    const response = try testingResponse(t.allocator, 0xE8, "\x12\x34");
    defer response.deinit();

    const controller = TestingController{ .response = response };

    var out: [1024]u8 = undefined;
    try t.expectError(
        error.EndOfStream,
        handleTestRequest(conf, &controller, .GET, "/metrics", &out),
    );
}

test "handleRequest - responds 404 to an unknown path" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, true);
    defer conf.deinit();

    const controller = TestingController{};

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .GET, "/", &out);

    const body = try expectHead(
        \\HTTP/1.1 404 Not Found
        \\connection: close
        \\content-length: 0
        \\
        \\
    , bytes);

    try t.expectEqualStrings("", body);
}

test "handleRequest - responds 405 to a request that is not a GET" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, true);
    defer conf.deinit();

    const controller = TestingController{};

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .POST, "/metrics", &out);

    const body = try expectHead(
        \\HTTP/1.1 405 Method Not Allowed
        \\connection: close
        \\content-length: 0
        \\
        \\
    , bytes);

    try t.expectEqualStrings("", body);
}

test "handleRequest - responds 504 when the controller reports a timeout" {
    const t = std.testing;

    const conf = try testingConfig(t.allocator, true);
    defer conf.deinit();

    // No response, so the controller reports a timeout.
    const controller = TestingController{ .response = null };

    var out: [1024]u8 = undefined;
    const bytes = try handleTestRequest(conf, &controller, .GET, "/metrics", &out);

    const body = try expectHead(
        \\HTTP/1.1 504 Gateway Timeout
        \\connection: close
        \\content-length: 0
        \\
        \\
    , bytes);

    try t.expectEqualStrings("", body);
}
