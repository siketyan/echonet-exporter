// Transport is the lower layer of ECHONET Lite and not covered by the specification.
// Usually Wi-SUN + IPv6 + UDP stack is used for the B route integration.
// BP35C0 is the only supported device for now and it covers entire the stack.

const std = @import("std");

const serial_port = @import("./transport/serial_port.zig");
const bp35c0 = @import("./transport/bp35c0.zig");

pub const SerialPort = serial_port.SerialPort;
pub const BP35C0 = bp35c0.BP35C0;

comptime {
    std.testing.refAllDecls(@This());
}
