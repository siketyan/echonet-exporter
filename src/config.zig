const std = @import("std");
const debug = std.debug;
const Io = std.Io;
const log = std.log.scoped(.config);
const mem = std.mem;

const yaml = @import("yaml");
const ArrayList = std.array_list.Managed;

pub const String = struct {
    list: ArrayList(u8),

    pub fn deinit(self: String) void {
        self.list.deinit();
    }

    pub fn asSlice(self: String) []const u8 {
        return self.list.items;
    }

    pub fn fromSlice(allocator: mem.Allocator, slice: []const u8) !String {
        var list = try ArrayList(u8).initCapacity(allocator, slice.len);
        list.appendSliceAssumeCapacity(slice);

        return String{ .list = list };
    }
};

/// Look up a required field, reporting the name of a missing one.
fn getField(map: yaml.Yaml.Map, name: []const u8) !yaml.Yaml.Value {
    return map.get(name) orelse {
        // The returned error tells the caller what happened; this tells the user where.
        log.warn("Missing required field: {s}", .{name});
        return error.MissingField;
    };
}

fn parseString(value: yaml.Yaml.Value, allocator: mem.Allocator) !String {
    return try String.fromSlice(allocator, value.asScalar() orelse return error.TypeMismatch);
}

fn parseArrayList(comptime T: type, value: yaml.Yaml.Value, allocator: mem.Allocator) !ArrayList(T) {
    const value_list = value.asList() orelse return error.TypeMismatch;
    var list = try ArrayList(T).initCapacity(allocator, value_list.len);
    errdefer deinitAll(T, list);

    for (value_list) |v| {
        var item: T = undefined;
        try item.parseYamlAlloc(v, allocator);
        list.appendAssumeCapacity(item);
    }

    return list;
}

fn parseOptional(comptime T: type, value: ?yaml.Yaml.Value, allocator: mem.Allocator) !?T {
    if (value) |v| {
        var out: T = undefined;
        try out.parseYamlAlloc(v, allocator);
        return out;
    } else {
        return null;
    }
}

fn parseInt(comptime T: type, value: yaml.Yaml.Value) !T {
    return try std.fmt.parseInt(T, value.asScalar() orelse return error.TypeMismatch, 0);
}

fn parseEnum(comptime T: type, value: yaml.Yaml.Value) !T {
    const str = value.asScalar() orelse return error.TypeMismatch;
    return inline for (@typeInfo(T).@"enum".fields) |f| {
        if (mem.eql(u8, f.name, str)) {
            break @enumFromInt(f.value);
        }
    } else error.InvalidEnumValue;
}

fn deinitAll(comptime T: type, list: ArrayList(T)) void {
    for (list.items) |item| {
        item.deinit();
    }

    list.deinit();
}

pub const Credentials = struct {
    rbid: String,
    pwd: String,

    pub fn deinit(self: Credentials) void {
        self.rbid.deinit();
        self.pwd.deinit();
    }

    pub fn parseYamlAlloc(self: *Credentials, value: yaml.Yaml.Value, allocator: mem.Allocator) !void {
        const map = value.asMap() orelse return error.TypeMismatch;

        self.rbid = try parseString(try getField(map, "rbid"), allocator);
        errdefer self.rbid.deinit();

        self.pwd = try parseString(try getField(map, "pwd"), allocator);
    }
};

pub const Target = struct {
    class_group_code: u8,
    class_code: u8,
    instance_code: u8,

    pub fn parseYaml(self: *Target, value: yaml.Yaml.Value) !void {
        const map = value.asMap() orelse return error.TypeMismatch;

        self.class_group_code = try parseInt(u8, try getField(map, "class_group_code"));
        self.class_code = try parseInt(u8, try getField(map, "class_code"));
        self.instance_code = try parseInt(u8, try getField(map, "instance_code"));
    }
};

pub const Type = enum {
    signed_char,
    signed_short,
    signed_long,
    unsigned_char,
    unsigned_short,
    unsigned_long,
};

pub const Measure = struct {
    name: String,
    help: ?String,

    pub fn deinit(self: Measure) void {
        self.name.deinit();
        if (self.help) |s| s.deinit();
    }

    pub fn parseYamlAlloc(self: *Measure, value: yaml.Yaml.Value, allocator: mem.Allocator) !void {
        const map = value.asMap() orelse return error.TypeMismatch;

        self.name = try parseString(try getField(map, "name"), allocator);
        errdefer self.name.deinit();

        self.help = if (map.get("help")) |v| try parseString(v, allocator) else null;
    }
};

pub const Layout = struct {
    type: Type,
    name: String,

    pub fn deinit(self: Layout) void {
        self.name.deinit();
    }

    pub fn parseYamlAlloc(self: *Layout, value: yaml.Yaml.Value, allocator: mem.Allocator) !void {
        const map = value.asMap() orelse return error.TypeMismatch;

        self.type = try parseEnum(Type, try getField(map, "type"));
        self.name = try parseString(try getField(map, "name"), allocator);
    }
};

pub const Property = struct {
    epc: u8,
    layout: ArrayList(Layout),

    pub fn deinit(self: Property) void {
        deinitAll(Layout, self.layout);
    }

    pub fn parseYamlAlloc(self: *Property, value: yaml.Yaml.Value, allocator: mem.Allocator) !void {
        const map = value.asMap() orelse return error.TypeMismatch;

        self.epc = try parseInt(u8, try getField(map, "epc"));
        self.layout = try parseArrayList(Layout, try getField(map, "layout"), allocator);
    }
};

pub const Config = struct {
    address: Io.net.IpAddress,
    device: String,
    credentials: ?Credentials = null,
    target: Target,
    measures: ArrayList(Measure),
    properties: ArrayList(Property),

    pub fn deinit(self: Config) void {
        self.device.deinit();
        if (self.credentials) |creds| creds.deinit();
        deinitAll(Measure, self.measures);
        deinitAll(Property, self.properties);
    }

    pub fn parseYamlAlloc(self: *Config, value: yaml.Yaml.Value, allocator: mem.Allocator) !void {
        const map = value.asMap() orelse return error.TypeMismatch;

        const address = (try getField(map, "address")).asScalar() orelse return error.TypeMismatch;
        var addr = mem.splitSequence(u8, address, ":");
        const host = addr.next() orelse return error.InvalidAddress;
        const port = addr.next() orelse return error.InvalidAddress;
        self.address = try Io.net.IpAddress.parse(host, try std.fmt.parseUnsigned(u16, port, 10));

        self.device = try parseString(try getField(map, "device"), allocator);
        errdefer self.device.deinit();

        self.credentials = try parseOptional(Credentials, map.get("credentials"), allocator);
        errdefer if (self.credentials) |creds| creds.deinit();

        try self.target.parseYaml(try getField(map, "target"));

        self.measures = try parseArrayList(Measure, try getField(map, "measures"), allocator);
        errdefer deinitAll(Measure, self.measures);

        self.properties = try parseArrayList(Property, try getField(map, "properties"), allocator);
    }

    pub fn loadYamlAlloc(buf: []const u8, alloc: mem.Allocator) !Config {
        var raw: yaml.Yaml = .{ .source = buf };
        defer raw.deinit(alloc);
        try raw.load(alloc);

        var config: Config = undefined;
        try config.parseYamlAlloc(raw.docs.getLast(), alloc);

        return config;
    }

    pub fn loadYamlFileAlloc(path: []const u8, alloc: mem.Allocator, io: Io) !Config {
        const buf = try Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4096));
        defer alloc.free(buf);

        return try Config.loadYamlAlloc(buf, alloc);
    }
};

fn listFromSlice(comptime T: type, allocator: mem.Allocator, slice: []const T) !ArrayList(T) {
    var list = try ArrayList(T).initCapacity(allocator, slice.len);
    list.appendSliceAssumeCapacity(slice);

    return list;
}

test "load config" {
    const t = std.testing;

    const config =
        \\address: 0.0.0.0:9100
        \\device: /dev/ttyUSB0
        \\credentials:
        \\  rbid: '0123456789ABCDEF'
        \\  pwd: '0123456789'
        \\target:
        \\  class_group_code: 0x02
        \\  class_code: 0x88
        \\  instance_code: 0x01
        \\measures:
        \\  - name: measured_instantaneous_electric_power
        \\    help: 瞬時電力計測値
        \\properties:
        \\  - epc: 0xE7
        \\    layout:
        \\      - type: signed_long
        \\        name: measured_instantaneous_electric_power
    ;

    const actual = try Config.loadYamlAlloc(config, t.allocator);
    defer actual.deinit();

    const expected = Config{
        .address = try Io.net.IpAddress.parse("0.0.0.0", 9100),
        .device = try String.fromSlice(t.allocator, "/dev/ttyUSB0"),
        .credentials = .{
            .rbid = try String.fromSlice(t.allocator, "0123456789ABCDEF"),
            .pwd = try String.fromSlice(t.allocator, "0123456789"),
        },
        .target = .{
            .class_group_code = 0x02,
            .class_code = 0x88,
            .instance_code = 0x01,
        },
        .measures = try listFromSlice(Measure, t.allocator, &.{.{
            .name = try String.fromSlice(t.allocator, "measured_instantaneous_electric_power"),
            .help = try String.fromSlice(t.allocator, "瞬時電力計測値"),
        }}),
        .properties = try listFromSlice(Property, t.allocator, &.{.{
            .epc = 0xE7,
            .layout = try listFromSlice(Layout, t.allocator, &.{.{
                .type = .signed_long,
                .name = try String.fromSlice(t.allocator, "measured_instantaneous_electric_power"),
            }}),
        }}),
    };
    defer expected.deinit();

    try t.expect(actual.address.eql(&expected.address));
    try t.expectEqualDeep(expected.device, actual.device);
    try t.expectEqualDeep(expected.credentials, actual.credentials);
    try t.expectEqualDeep(expected.target, actual.target);
    try t.expectEqualDeep(expected.measures, actual.measures);
    try t.expectEqualDeep(expected.properties, actual.properties);
}

test "load config - without the optional fields" {
    const t = std.testing;

    const config =
        \\address: 0.0.0.0:9100
        \\device: /dev/ttyUSB0
        \\target:
        \\  class_group_code: 0x02
        \\  class_code: 0x88
        \\  instance_code: 0x01
        \\measures:
        \\  - name: measured_instantaneous_electric_power
        \\properties:
        \\  - epc: 0xE7
        \\    layout:
        \\      - type: signed_long
        \\        name: measured_instantaneous_electric_power
    ;

    const actual = try Config.loadYamlAlloc(config, t.allocator);
    defer actual.deinit();

    try t.expectEqual(null, actual.credentials);
    try t.expectEqual(null, actual.measures.items[0].help);
}

test "load config - reports a missing field" {
    const t = std.testing;

    // The EPC of the only property is missing, so the fields parsed before it
    // must be released while unwinding.
    const config =
        \\address: 0.0.0.0:9100
        \\device: /dev/ttyUSB0
        \\target:
        \\  class_group_code: 0x02
        \\  class_code: 0x88
        \\  instance_code: 0x01
        \\measures:
        \\  - name: measured_instantaneous_electric_power
        \\properties:
        \\  - layout:
        \\      - type: signed_long
        \\        name: measured_instantaneous_electric_power
    ;

    try t.expectError(error.MissingField, Config.loadYamlAlloc(config, t.allocator));
}

test "load config - reports a field of an unexpected type" {
    const t = std.testing;

    const config =
        \\address: 0.0.0.0:9100
        \\device:
        \\  - /dev/ttyUSB0
        \\target:
        \\  class_group_code: 0x02
        \\  class_code: 0x88
        \\  instance_code: 0x01
        \\measures: []
        \\properties: []
    ;

    try t.expectError(error.TypeMismatch, Config.loadYamlAlloc(config, t.allocator));
}

test "load config - reports an unknown layout type" {
    const t = std.testing;

    const config =
        \\address: 0.0.0.0:9100
        \\device: /dev/ttyUSB0
        \\target:
        \\  class_group_code: 0x02
        \\  class_code: 0x88
        \\  instance_code: 0x01
        \\measures:
        \\  - name: measured_instantaneous_electric_power
        \\properties:
        \\  - epc: 0xE7
        \\    layout:
        \\      - type: float
        \\        name: measured_instantaneous_electric_power
    ;

    try t.expectError(error.InvalidEnumValue, Config.loadYamlAlloc(config, t.allocator));
}

test "load config - reports an address without a port" {
    const t = std.testing;

    const config =
        \\address: 0.0.0.0
        \\device: /dev/ttyUSB0
        \\target:
        \\  class_group_code: 0x02
        \\  class_code: 0x88
        \\  instance_code: 0x01
        \\measures: []
        \\properties: []
    ;

    try t.expectError(error.InvalidAddress, Config.loadYamlAlloc(config, t.allocator));
}
