const std = @import("std");
const fs = std.fs;
const http = std.http;
const io = std.io;
const log = std.log;
const mem = std.mem;
const net = std.net;

const pcapfile = @import("pcapfile");

const Connection = @import("./connection.zig").Connection;
const Client = @import("./client.zig").Client;
const TransactionManager = @import("./transaction.zig").TransactionManager;

const packet = @import("./packet.zig");
const Ip6Packet = packet.Ip6Packet;
const UdpPacket = packet.UdpPacket;

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // defer std.debug.assert(gpa.deinit() == .ok);

    const conf = try config.Config.loadYamlFileAlloc("config.yaml", allocator);
    defer conf.deinit(allocator);

    // var pcap_fd = try fs.cwd().createFile("test.pcap", .{});
    // defer pcap_fd.close();

    // var writer = pcapfile.pcap.initWriter(.{ .network = .IPV6 }, pcap_fd.writer());
    // try writer.writeFileHeader();

    var client = Client.init(try Connection.init(conf.device), allocator);
    defer client.close();

    try client.skreset();
    try client.sksreg("SFE", "0"); // Disable echo-back

    // Set credentials
    try client.sksetpwd(conf.credentials.pwd);
    try client.sksetrbid(conf.credentials.rbid);

    try client.skscan(2, 0xFFFFFFFF, 5, 0);

    const epandesc = loop: {
        var desc: ?Client.Epandesc = null;
        while (true) {
            const event = try client.readEvent();
            if (event.num == 0x20) {
                desc = try client.readEpandesc();
            } else {
                break :loop desc;
            }
        }
    } orelse return;

    try client.sksreg("S2", try std.fmt.allocPrint(allocator, "{X:0>2}", .{epandesc.channel}));
    try client.sksreg("S3", try std.fmt.allocPrint(allocator, "{X:0>4}", .{epandesc.pan_id}));

    var ip6_addr = try client.skll64(epandesc.addr);
    try client.skjoin(ip6_addr);

    ip6_addr.setPort(3610);

    while (true) {
        const event = try client.readEventLike();
        switch (event) {
            .event => |e| if (e.num == 0x25) break,
            else => log.debug("Ignored an event: {any}", .{event}),
        }
    }

    var txm = TransactionManager.init();

    const State = struct {
        allocator: mem.Allocator,
        client: *Client,
        // writer: *@TypeOf(writer),
        addr: net.Ip6Address,
        deoj: echonet.EOJ,

        const Self = @This();

        fn handle(state: *const Self, req: echonet.Frame) !echonet.Frame {
            const buf = try req.toBytesAlloc(state.allocator);
            defer state.allocator.free(buf);

            try state.client.sksendto(1, state.addr, 1, 0, buf);

            var resp: echonet.Frame = undefined;
            while (true) {
                const event = try state.client.readEventLike();
                const e = switch (event) {
                    .erxudp => |e| e,
                    else => continue,
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

                if (e.dest.getPort() == 3610) {
                    var stream = io.fixedBufferStream(e.data);
                    try resp.readAlloc(stream.reader().any(), state.allocator);
                    if (resp.getTID() == req.getTID()) {
                        break;
                    }

                    log.info("Response from another transaction, ignoring: {any}", .{resp});
                    resp.deinit(state.allocator);
                }
            } else unreachable;

            return resp;
        }
    };

    const state = State{
        .allocator = allocator,
        .client = &client,
        // .writer = &writer,
        .addr = ip6_addr,
        .deoj = .{
            .class_group_code = conf.target.class_group_code,
            .class_code = conf.target.class_code,
            .instance_code = conf.target.instance_code,
        },
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

            const props = try allocator.alloc(echonet.Property, conf.measures.len);
            defer allocator.free(props);
            for (0..conf.measures.len) |i| {
                props[i] = .{ .epc = conf.measures[i].epc };
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
                        .deoj = state.deoj,
                        .esv = 0x62, // Get
                        .props = props,
                    },
                },
            };

            const resp = try state.handle(req);
            defer resp.deinit(allocator);

            for (resp.format1.edata.props) |prop| {
                const measure: config.Measure = for (conf.measures) |m| {
                    if (m.epc == prop.epc) {
                        break m;
                    }
                } else continue;

                const value = switch (measure.type) {
                    .signed_long => mem.readInt(i32, prop.edt[0..4], .big),
                };

                if (measure.help) |help| {
                    try std.fmt.format(response.writer(), "# HELP {s} {s}\n", .{ measure.name, help });
                }

                try std.fmt.format(response.writer(), "# TYPE {s} gauge\n", .{measure.name});
                try std.fmt.format(response.writer(), "{s} {d}\n", .{ measure.name, value });
            }
        }
    }
}

test {
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(echonet);
}
