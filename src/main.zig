const std = @import("std");
const log = std.log;

const config = @import("./config.zig");
const echonet = @import("./echonet.zig");

const transport = @import("./transport.zig");
const SerialPort = transport.SerialPort;
const BP35C0 = transport.BP35C0(SerialPort);

const TransactionManager = @import("./transaction.zig").TransactionManager;
const Controller = @import("./controller.zig").Controller;
const Server = @import("./server.zig").Server(Controller(BP35C0));

// const packet = @import("./packet.zig");
// const Ip6Packet = packet.Ip6Packet;
// const UdpPacket = packet.UdpPacket;

pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .bp35c0, .level = .debug },
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const conf = try config.Config.loadYamlFileAlloc("config.yaml", allocator, init.io);
    defer conf.deinit();

    // var pcap_fd = try fs.cwd().createFile("test.pcap", .{});
    // defer pcap_fd.close();

    // try writer.writeFileHeader();

    var port = try SerialPort.open(conf.device.asSlice(), 115_200, allocator, init.io);
    defer port.close();

    var bp35c0 = try BP35C0.init(&port, allocator, .{
        .credentials = if (conf.credentials) |creds| .{
            .rbid = creds.rbid.asSlice(),
            .pwd = creds.pwd.asSlice(),
        } else null,
    });
    defer bp35c0.close();

    try bp35c0.connect();

    var txm = TransactionManager.init();
    const controller = Controller(BP35C0){
        .allocator = allocator,
        .transport = &bp35c0,
        .retry = conf.retry,
        // .writer = &writer,
    };

    var server = Server.init(allocator, init.io, conf, &txm, &controller);

    try server.run();
}

comptime {
    std.testing.refAllDecls(@This());
}
