const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "echonet-exporter",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("pcapfile", b.dependency("zig-pcapfile", .{}).module("zig-pcapfile"));
    exe.root_module.addImport("serial", b.dependency("serial", .{}).module("serial"));
    exe.root_module.addImport("yaml", b.dependency("zig-yaml", .{}).module("yaml"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("pcapfile", b.dependency("zig-pcapfile", .{}).module("zig-pcapfile"));
    unit_tests.root_module.addImport("serial", b.dependency("serial", .{}).module("serial"));
    unit_tests.root_module.addImport("yaml", b.dependency("zig-yaml", .{}).module("yaml"));

    b.installArtifact(unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
