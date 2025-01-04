const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;

const yaml = @import("yaml");

const String = struct {
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

pub const Credentials = struct {
    rbid: String,
    pwd: String,

    pub fn deinit(self: Credentials) void {
        self.rbid.deinit();
        self.pwd.deinit();
    }

    pub fn parseYamlAlloc(self: *Credentials, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        self.rbid = try String.fromSlice(allocator, try map.get("rbid").?.asString());
        self.pwd = try String.fromSlice(allocator, try map.get("pwd").?.asString());
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
    signed_long,
};

pub const Measure = struct {
    name: String,
    help: ?String,
    epc: u8,
    type: Type,

    pub fn deinit(self: Measure) void {
        self.name.deinit();
        if (self.help) |s| s.deinit();
    }

    pub fn parseYamlAlloc(self: *Measure, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        self.name = try String.fromSlice(allocator, try map.get("name").?.asString());
        self.help = if (map.get("help")) |v| try String.fromSlice(allocator, try v.asString()) else null;
        self.epc = @intCast(try map.get("epc").?.asInt());

        const type_raw = try map.get("type").?.asString();
        self.type = inline for (@typeInfo(Type).@"enum".fields) |f| {
            if (mem.eql(u8, f.name, type_raw)) {
                break @enumFromInt(f.value);
            }
        } else unreachable;
    }
};

pub const Config = struct {
    address: std.net.Address,
    device: String,
    credentials: Credentials,
    target: Target,
    measures: std.ArrayList(Measure),

    pub fn deinit(self: Config) void {
        self.device.deinit();
        self.credentials.deinit();
        for (self.measures.items) |m| m.deinit();
        self.measures.deinit();
    }

    pub fn parseYamlAlloc(self: *Config, value: yaml.Value, allocator: mem.Allocator) !void {
        const map = try value.asMap();

        var addr = mem.splitSequence(u8, try map.get("address").?.asString(), ":");
        self.address = try std.net.Address.parseIp(
            addr.next().?,
            try std.fmt.parseUnsigned(u16, addr.next().?, 10),
        );

        self.device = try String.fromSlice(allocator, try map.get("device").?.asString());
        try self.credentials.parseYamlAlloc(map.get("credentials").?, allocator);
        try self.target.parseYaml(map.get("target").?);

        const measures_raw = try map.get("measures").?.asList();
        const measures = try allocator.alloc(Measure, measures_raw.len);
        for (0..measures.len) |i| {
            try measures[i].parseYamlAlloc(measures_raw[i], allocator);
        }
        self.measures = std.ArrayList(Measure).fromOwnedSlice(allocator, measures);
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
        \\    epc: 0xE7
        \\    type: signed_long
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
        .measures = blk: {
            var list = try std.ArrayList(Measure).initCapacity(t.allocator, 1);
            list.appendAssumeCapacity(.{
                .name = try String.fromSlice(t.allocator, "measured_instantaneous_electric_power"),
                .help = try String.fromSlice(t.allocator, "瞬時電力計測値"),
                .epc = 0xE7,
                .type = .signed_long,
            });
            break :blk list;
        },
    };
    defer expected.deinit();

    try t.expect(actual.address.eql(expected.address));
    try t.expectEqualDeep(expected.device, actual.device);
    try t.expectEqualDeep(expected.credentials, actual.credentials);
    try t.expectEqualDeep(expected.target, actual.target);
    try t.expectEqualDeep(expected.measures, actual.measures);
}
