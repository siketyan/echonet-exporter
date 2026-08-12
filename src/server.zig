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

test "handleRequest" {
    const t = std.testing;

    const conf: config.Config = .{
        .address = try net.IpAddress.parse("127.0.0.1", 12345),
        .device = try config.String.fromSlice(t.allocator, "/dev/ttyUSB0"),
        .target = .{
            .class_group_code = 0x02,
            .class_code = 0x88,
            .instance_code = 0x01,
        },
        .measures = try util.listFromSlice(config.Measure, t.allocator, &.{
            .{
                .name = try config.String.fromSlice(t.allocator, "measured_instantaneous_current_r"),
                .help = try config.String.fromSlice(t.allocator, "瞬時電流計測値 (R 相)"),
            },
            .{
                .name = try config.String.fromSlice(t.allocator, "measured_instantaneous_current_t"),
                .help = try config.String.fromSlice(t.allocator, "瞬時電流計測値 (T 相)"),
            },
        }),
        .properties = try util.listFromSlice(config.Property, t.allocator, &.{.{
            .epc = 0xE8,
            .layout = try util.listFromSlice(config.Layout, t.allocator, &.{
                .{
                    .type = .signed_short,
                    .name = try config.String.fromSlice(t.allocator, "measured_instantaneous_current_r"),
                },
                .{
                    .type = .signed_short,
                    .name = try config.String.fromSlice(t.allocator, "measured_instantaneous_current_t"),
                },
            }),
        }}),
    };
    defer conf.deinit();

    const controller = struct {
        fn handle(self: *const @This(), request: echonet.Frame) !?echonet.Frame {
            _ = self;
            _ = request;
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
                        .esv = 0x63, // Get_Res
                        .props = try echonet.PropertyList.fromSlice(t.allocator, &.{.{
                            .epc = 0xE8,
                            .edt = try util.listFromSlice(u8, t.allocator, "\x12\x34\x56\x79"),
                        }}),
                    },
                },
            };
        }
    }{};

    var input = Io.Reader.fixed(&.{});
    var output_buffer: [1024]u8 = undefined;
    var output = Io.Writer.fixed(&output_buffer);
    var http_server = http.Server.init(&input, &output);

    var request: http.Server.Request = .{
        .server = &http_server,
        .head = .{
            .method = .GET,
            .target = "/metrics",
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
    var server = Server(@TypeOf(controller)){
        .allocator = t.allocator,
        .io = t.io,
        .conf = conf,
        .txm = &txm,
        .controller = &controller,
    };
    try server.handleRequest(&request);

    const bytes = output.buffered();

    const expected_header_lf =
        \\HTTP/1.1 200 OK
        \\connection: close
        \\content-length: 309
        \\Content-Type: text/plain; version=0.0.4
        \\
        \\
    ;

    // Replace LF to CRLF.
    var expected_header: [expected_header_lf.len + 5]u8 = undefined;
    _ = mem.replace(u8, expected_header_lf, "\n", "\r\n", &expected_header);

    const expected_body =
        \\# TYPE measured_instantaneous_current_r gauge
        \\# HELP measured_instantaneous_current_r 瞬時電流計測値 (R 相)
        \\measured_instantaneous_current_r 4660
        \\# TYPE measured_instantaneous_current_t gauge
        \\# HELP measured_instantaneous_current_t 瞬時電流計測値 (T 相)
        \\measured_instantaneous_current_t 22137
        \\
    ;

    try t.expectEqualStrings(&expected_header, bytes[0..expected_header.len]);
    try t.expectEqualStrings(expected_body, bytes[expected_header.len..]);
}
