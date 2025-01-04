const std = @import("std");
const fs = std.fs;
const http = std.http;
const io = std.io;
const log = std.log;
const mem = std.mem;
const net = std.net;

const pcapfile = @import("pcapfile");

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");

const transport = @import("./transport.zig");
const SerialPort = transport.SerialPort;
const BP35C0 = transport.BP35C0(SerialPort);

const TransactionManager = @import("./transaction.zig").TransactionManager;
const Controller = @import("./controller.zig").Controller;

// const packet = @import("./packet.zig");
// const Ip6Packet = packet.Ip6Packet;
// const UdpPacket = packet.UdpPacket;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // defer std.debug.assert(gpa.deinit() == .ok);

    const conf = try config.Config.loadYamlFileAlloc("config.yaml", allocator);
    defer conf.deinit();

    // var pcap_fd = try fs.cwd().createFile("test.pcap", .{});
    // defer pcap_fd.close();

    // var writer = pcapfile.pcap.initWriter(.{ .network = .IPV6 }, pcap_fd.writer());
    // try writer.writeFileHeader();

    var port = try SerialPort.open(conf.device.asSlice(), 115_200, allocator);
    defer port.close();

    var bp35c0 = BP35C0.init(&port, allocator, .{
        .credentials = .{
            .rbid = conf.credentials.rbid.asSlice(),
            .pwd = conf.credentials.pwd.asSlice(),
        },
    });
    defer bp35c0.close();

    try bp35c0.connect();

    var txm = TransactionManager.init();
    const controller = Controller(BP35C0){
        .allocator = allocator,
        .transport = &bp35c0,
        // .writer = &writer,
    };

    const addr = try net.Address.parseIp4("0.0.0.0", 9100);
    var server = try addr.listen(.{ .reuse_address = true });
    log.info("HTTP server is ready at {}", .{std.fmt.Formatter(net.Address.format){ .data = addr }});

    var rx_buf: [2048]u8 = undefined;
    var tx_buf: [2048]u8 = undefined;

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        log.info("A new connection from {} has been accepted", .{
            std.fmt.Formatter(net.Address.format){ .data = conn.address },
        });

        var http_server = http.Server.init(conn, &rx_buf);
        while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch continue;

            log.info("{s} {s} {s}", .{
                @tagName(request.head.version),
                @tagName(request.head.method),
                request.head.target,
            });

            if (!mem.eql(u8, request.head.target, "/metrics")) {
                try request.respond(&.{}, .{ .status = .not_found });
                log.info("404 Not Found", .{});
                continue;
            }

            if (request.head.method != .GET) {
                try request.respond(&.{}, .{ .status = .method_not_allowed });
                log.info("405 Method Not Allowed", .{});
                continue;
            }

            var props = try echonet.PropertyList.init(allocator, conf.measures.items.len);
            defer props.deinit();
            for (conf.measures.items) |measure| {
                try props.list.append(.{ .epc = measure.epc, .edt = null });
            }

            const tid = txm.begin();
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
                            .class_group_code = conf.target.class_group_code,
                            .class_code = conf.target.class_code,
                            .instance_code = conf.target.instance_code,
                        },
                        .esv = 0x62, // Get
                        .props = props,
                    },
                },
            };

            const resp = try controller.handle(req) orelse {
                // TODO: Retry
                try request.respond(&.{}, .{ .status = .gateway_timeout });
                log.info("504 Gateway Timeout", .{});
                continue;
            };
            defer resp.deinit();

            var response = request.respondStreaming(.{
                .send_buffer = &tx_buf,
                .respond_options = .{
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain; version=0.0.4" },
                    },
                },
            });
            defer response.end() catch {};
            defer log.info("200 OK", .{});

            for (resp.format1.edata.props.asSlice()) |prop| {
                const measure: config.Measure = for (conf.measures.items) |m| {
                    if (m.epc == prop.epc) {
                        break m;
                    }
                } else continue;

                const edt = prop.edt orelse unreachable;
                const value = switch (measure.type) {
                    .signed_long => mem.readInt(i32, edt.items[0..4], .big),
                };

                const name = measure.name.asSlice();
                if (measure.help) |help| {
                    try std.fmt.format(response.writer(), "# HELP {s} {s}\n", .{ name, help.asSlice() });
                }

                try std.fmt.format(response.writer(), "# TYPE {s} gauge\n", .{name});
                try std.fmt.format(response.writer(), "{s} {d}\n", .{ name, value });
            }
        }
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
