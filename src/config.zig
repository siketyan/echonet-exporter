const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;

const yaml = @import("yaml");

pub const String = struct {
    list: std.ArrayList(u8),

    pub fn deinit(self: String) void {
        self.list.deinit();
    }

    pub fn asSlice(self: String) []const u8 {
        return self.list.items;
    }

    pub fn fromSlice(allocator: mem.Allocator, slice: []const u8) !String {
        var list = try std.ArrayList(u8).initCapacity(allocator, slice.len);
        list.appendSliceAssumeCapacity(slice);

        return String{ .list = list };
    }
};

fn parseString(value: yaml.Value, allocator: mem.Allocator) !String {
    return try String.fromSlice(allocator, try value.asString());
}

fn parseArrayList(comptime T: type, value: yaml.Value, allocator: mem.Allocator) !std.ArrayList(T) {
    const value_list = try value.asList();
    var list = try std.ArrayList(T).initCapacity(allocator, value_list.len);
    for (value_list) |v| {
        var item: T = undefined;
        try item.parseYamlAlloc(v, allocator);
        list.appendAssumeCapacity(item);
    }

    return list;
}

fn parseOptional(comptime T: type, value: ?yaml.Value, allocator: mem.Allocator) !?T {
    if (value) |v| {
        var out: T = undefined;
        try out.parseYamlAlloc(v, allocator);
        return out;
    } else {
        return null;
    }
}

fn parseEnum(comptime T: type, value: yaml.Value) !T {
    const str = try value.asString();
    return inline for (@typeInfo(Type).@"enum".fields) |f| {
        if (mem.eql(u8, f.name, str)) {
            break @enumFromInt(f.value);
        }
    } else error.InvalidEnumValue;
}

fn deinitAll(comptime T: type, list: std.ArrayList(T)) void {
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

    pub fn parseYamlAlloc(self: *Credentials, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        self.rbid = try parseString(map.get("rbid").?, allocator);
        self.pwd = try parseString(map.get("pwd").?, allocator);
    }
};

pub const Target = struct {
    class_group_code: u8,
    class_code: u8,
    instance_code: u8,

    pub fn parseYaml(self: *Target, value: yaml.Value) !void {
        const map = try value.asMap();

        self.class_group_code = @intCast(try map.get("class_group_code").?.asInt());
        self.class_code = @intCast(try map.get("class_code").?.asInt());
        self.instance_code = @intCast(try map.get("instance_code").?.asInt());
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

    pub fn parseYamlAlloc(self: *Measure, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        self.name = try String.fromSlice(allocator, try map.get("name").?.asString());
        self.help = if (map.get("help")) |v| try String.fromSlice(allocator, try v.asString()) else null;
    }
};

pub const Layout = struct {
    type: Type,
    name: String,

    pub fn deinit(self: Layout) void {
        self.name.deinit();
    }

    pub fn parseYamlAlloc(self: *Layout, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        self.type = try parseEnum(Type, map.get("type").?);
        self.name = try parseString(map.get("name").?, allocator);
    }
};

pub const Property = struct {
    epc: u8,
    layout: std.ArrayList(Layout),

    pub fn deinit(self: Property) void {
        deinitAll(Layout, self.layout);
    }

    pub fn parseYamlAlloc(self: *Property, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        self.epc = @intCast(try map.get("epc").?.asInt());
        self.layout = try parseArrayList(Layout, map.get("layout").?, allocator);
    }
};

pub const Config = struct {
    address: std.net.Address,
    device: String,
    credentials: ?Credentials = null,
    target: Target,
    measures: std.ArrayList(Measure),
    properties: std.ArrayList(Property),

    pub fn deinit(self: Config) void {
        self.device.deinit();
        if (self.credentials) |creds| creds.deinit();
        deinitAll(Measure, self.measures);
        deinitAll(Property, self.properties);
    }

    pub fn parseYamlAlloc(self: *Config, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        var addr = mem.splitSequence(u8, try map.get("address").?.asString(), ":");
        self.address = try std.net.Address.parseIp(
            addr.next().?,
            try std.fmt.parseUnsigned(u16, addr.next().?, 10),
        );

        self.device = try String.fromSlice(allocator, try map.get("device").?.asString());
        self.credentials = try parseOptional(Credentials, map.get("credentials"), allocator);
        try self.target.parseYaml(map.get("target").?);
        self.measures = try parseArrayList(Measure, map.get("measures").?, allocator);
        self.properties = try parseArrayList(Property, map.get("properties").?, allocator);
    }

    pub fn loadYamlAlloc(buf: []const u8, alloc: mem.Allocator) !Config {
        var raw = try yaml.Yaml.load(alloc, buf);
        defer raw.deinit();

        var config: Config = undefined;
        try config.parseYamlAlloc(raw.docs.getLast(), alloc);

        return config;
    }

    pub fn loadYamlFileAlloc(path: []const u8, alloc: mem.Allocator) !Config {
        const fd = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer fd.close();

        const buf = try fd.readToEndAlloc(alloc, 4096);
        defer alloc.free(buf);

        return try Config.loadYamlAlloc(buf, alloc);
    }
};

fn listFromSlice(comptime T: type, allocator: mem.Allocator, slice: []const T) !std.ArrayList(T) {
    var list = try std.ArrayList(T).initCapacity(allocator, slice.len);
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
        .address = try std.net.Address.parseIp("0.0.0.0", 9100),
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

    try t.expect(actual.address.eql(expected.address));
    try t.expectEqualDeep(expected.device, actual.device);
    try t.expectEqualDeep(expected.credentials, actual.credentials);
    try t.expectEqualDeep(expected.target, actual.target);
    try t.expectEqualDeep(expected.measures, actual.measures);
}
