const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;

const yaml = @import("yaml");

pub const Credentials = struct {
    rbid: []const u8,
    pwd: []const u8,

    pub fn deinit(self: Credentials, alloc: mem.Allocator) void {
        alloc.free(self.rbid);
        alloc.free(self.pwd);
    }

    pub fn parseYamlAlloc(self: *Credentials, value: yaml.Value, alloc: mem.Allocator) !void {
        const map = try value.asMap();

        self.rbid = try alloc.dupe(u8, try map.get("rbid").?.asString());
        self.pwd = try alloc.dupe(u8, try map.get("pwd").?.asString());
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
    name: []const u8,
    help: ?[]const u8,
    epc: u8,
    type: Type,

    pub fn deinit(self: Measure, alloc: mem.Allocator) void {
        alloc.free(self.name);
        if (self.help) |s| alloc.free(s);
    }

    pub fn parseYamlAlloc(self: *Measure, value: yaml.Value, alloc: mem.Allocator) !void {
        const map = try value.asMap();

        self.name = try alloc.dupe(u8, try map.get("name").?.asString());
        self.help = if (map.get("help")) |v| try alloc.dupe(u8, try v.asString()) else null;
        self.epc = @intCast(try map.get("epc").?.asInt());

        const type_raw = try map.get("type").?.asString();
        self.type = inline for (@typeInfo(Type).Enum.fields) |f| {
            if (mem.eql(u8, f.name, type_raw)) {
                break @enumFromInt( f.value);
            }
        } else unreachable;
    }
};

pub const Config = struct {
    device: []const u8,
    credentials: Credentials,
    target: Target,
    measures: []const Measure,

    pub fn deinit(self: Config, alloc: mem.Allocator) void {
        self.credentials.deinit(alloc);
        for (self.measures) |m| {
            m.deinit(alloc);
        }

        alloc.free(self.device);
        alloc.free(self.measures);
    }

    pub fn parseYamlAlloc(self: *Config, value: yaml.Value, alloc: mem.Allocator) !void {
        const map = try value.asMap();

        self.device = try alloc.dupe(u8, try map.get("device").?.asString());
        try self.credentials.parseYamlAlloc(map.get("credentials").?, alloc);
        try self.target.parseYaml(map.get("target").?);

        const measures_raw = try map.get("measures").?.asList();
        const measures = try alloc.alloc(Measure, measures_raw.len);
        for (0..measures.len) |i| {
            try measures[i].parseYamlAlloc(measures_raw[i], alloc);
        }
        self.measures = measures;
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
    defer actual.deinit(t.allocator);

    try t.expectEqualDeep(
        Config{
            .device = "/dev/ttyUSB0",
            .credentials = .{
                .rbid = "0123456789ABCDEF",
                .pwd = "0123456789",
            },
            .target = .{
                .class_group_code = 0x02,
                .class_code = 0x88,
                .instance_code = 0x01,
            },
            .measures = &.{
                .{
                    .name = "measured_instantaneous_electric_power",
                    .help = "瞬時電力計測値",
                    .epc = 0xE7,
                    .type = .signed_long,
                },
            },
        },
        actual,
    );
}
