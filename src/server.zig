const std = @import("std");
const http = std.http;
const io = std.io;
const log = std.log.scoped(.server);
const mem = std.mem;
const net = std.net;

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");
const util = @import("./util.zig");

const TransactionManager = @import("./transaction.zig").TransactionManager;

fn fmtAddress(addr: net.Address) std.fmt.Formatter(net.Address.format) {
    return std.fmt.Formatter(net.Address.format){ .data = addr };
}

pub fn Server(comptime Controller: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        conf: config.Config,
        txm: *TransactionManager,
        controller: *const Controller,
        rx_buf: [2048]u8 = undefined,
        tx_buf: [2048]u8 = undefined,

        pub fn init(
            allocator: mem.Allocator,
            conf: config.Config,
            txm: *TransactionManager,
            controller: *const Controller,
        ) Self {
            return Self{
                .allocator = allocator,
                .conf = conf,
                .txm = txm,
                .controller = controller,
            };
        }

        pub fn run(self: *Self) !void {
            const addr = self.conf.address;
            var server = try addr.listen(.{
                .reuse_address = true,
            });

            log.info("HTTP server is ready at {}", .{fmtAddress(addr)});

            while (true) {
                const conn = try server.accept();
                defer conn.stream.close();

                log.info("A new connection from {} has been accepted", .{fmtAddress(conn.address)});

                try self.handleConnection(conn);
            }
        }

        fn handleConnection(self: *Self, conn: net.Server.Connection) !void {
            var http_server = http.Server.init(conn, &self.rx_buf);
            while (http_server.state == .ready) {
                var request = http_server.receiveHead() catch continue;

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

            var body = std.ArrayList(u8).init(self.allocator);
            defer body.deinit();
            const writer = body.writer();

            for (self.conf.measures.items) |measure| {
                const name = measure.name.asSlice();
                try std.fmt.format(writer, "# TYPE {s} gauge\n", .{name});
                if (measure.help) |help| {
                    try std.fmt.format(writer, "# HELP {s} {s}\n", .{ name, help.asSlice() });
                }

                for (self.conf.properties.items) |property| {
                    const edt: std.ArrayList(u8) = for (resp.format1.edata.props.asSlice()) |p| {
                        if (p.epc == property.epc) {
                            if (p.edt) |edt| break edt;
                        }
                    } else continue;

                    var stream = io.fixedBufferStream(edt.items);
                    const reader = stream.reader();

                    for (property.layout.items) |layout| {
                        try writer.writeAll(name);
                        try writer.writeByte(' ');

                        try switch (layout.type) {
                            .signed_char => std.fmt.formatIntValue(try reader.readInt(i8, .big), "d", .{}, writer),
                            .signed_short => std.fmt.formatIntValue(try reader.readInt(i16, .big), "d", .{}, writer),
                            .signed_long => std.fmt.formatIntValue(try reader.readInt(i32, .big), "d", .{}, writer),
                            .unsigned_char => std.fmt.formatIntValue(try reader.readInt(u8, .big), "d", .{}, writer),
                            .unsigned_short => std.fmt.formatIntValue(try reader.readInt(u16, .big), "d", .{}, writer),
                            .unsigned_long => std.fmt.formatIntValue(try reader.readInt(u32, .big), "d", .{}, writer),
                        };

                        try writer.writeByte('\n');
                    }
                }
            }

            try request.respond(body.items, .{});
            log.info("200 OK", .{});
        }
    };
}

test "handleRequest" {
    const t = std.testing;

    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();

    const conf: config.Config = .{
        .address = try net.Address.parseIp("127.0.0.1", 12345),
        .device = try config.String.fromSlice(t.allocator, "/dev/ttyUSB0"),
        .target = .{
            .class_group_code = 0x02,
            .class_code = 0x88,
            .instance_code = 0x01,
        },
        .measures = try util.listFromSlice(config.Measure, t.allocator, &.{.{
            .name = try config.String.fromSlice(t.allocator, "measured_instantaneous_electric_power"),
            .help = try config.String.fromSlice(t.allocator, "瞬時電力計測値"),
        }}),
        .properties = try util.listFromSlice(config.Property, t.allocator, &.{.{
            .epc = 0xE7,
            .layout = try util.listFromSlice(config.Layout, t.allocator, &.{.{
                .type = .signed_long,
                .name = try config.String.fromSlice(t.allocator, "measured_instantaneous_electric_power"),
            }}),
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
                        .props = try echonet.PropertyList.fromSlice(t.allocator, &.{}),
                    },
                },
            };
        }
    }{};

    const fd = try tmp_dir.dir.createFile("dummy.sock", .{ .read = true });
    defer fd.close();

    var http_server = http.Server.init(.{
        .address = conf.address,
        .stream = .{ .handle = fd.handle },
    }, &.{});

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
            .compression = .none,
        },
        .head_end = undefined,
        .reader_state = undefined,
    };

    var txm = TransactionManager.init();
    var server = Server(@TypeOf(controller)){
        .allocator = t.allocator,
        .conf = conf,
        .txm = &txm,
        .controller = &controller,
    };
    try server.handleRequest(&request);

    try fd.seekTo(0);
    const bytes = try fd.readToEndAlloc(t.allocator, 1024);
    defer t.allocator.free(bytes);

    const expected_header_lf =
        \\HTTP/1.1 200 OK
        \\connection: close
        \\content-length: 118
        \\
        \\
    ;

    // Replace LF to CRLF.
    var expected_header: [expected_header_lf.len + 4]u8 = undefined;
    _ = mem.replace(u8, expected_header_lf, "\n", "\r\n", &expected_header);

    const expected_body =
        \\# TYPE measured_instantaneous_electric_power gauge
        \\# HELP measured_instantaneous_electric_power 瞬時電力計測値
        \\
    ;

    try t.expectEqualStrings(&expected_header, bytes[0..expected_header.len]);
    try t.expectEqualStrings(expected_body, bytes[expected_header.len..]);
}
