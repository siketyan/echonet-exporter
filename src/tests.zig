//! The root of the test step.
//!
//! Tests are only compiled for the source files reachable from here, so a new
//! file has to be listed below to have its tests run at all. Reaching them
//! through the imports of main.zig alone would silently skip whatever the
//! binary does not happen to use.

test {
    _ = @import("./config.zig");
    _ = @import("./controller.zig");
    _ = @import("./echonet.zig");
    _ = @import("./main.zig");
    _ = @import("./packet.zig");
    _ = @import("./server.zig");
    _ = @import("./transaction.zig");
    _ = @import("./transport.zig");
    _ = @import("./transport/bp35c0.zig");
    _ = @import("./transport/serial_port.zig");
    _ = @import("./util.zig");
}
