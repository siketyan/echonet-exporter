const std = @import("std");
const http = std.http;
const log = std.log.scoped(.server);
const mem = std.mem;
const net = std.net;

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");
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
            for (self.conf.measures.items) |measure| {
                try props.list.append(.{ .epc = measure.epc, .edt = null });
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

            var response = request.respondStreaming(.{
                .send_buffer = &self.tx_buf,
                .respond_options = .{
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain; version=0.0.4" },
                    },
                },
            });
            defer response.end() catch {};
            defer log.info("200 OK", .{});

            for (resp.format1.edata.props.asSlice()) |prop| {
                const measure: config.Measure = for (self.conf.measures.items) |m| {
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
    };
}
