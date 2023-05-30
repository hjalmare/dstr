const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main_tests = b.addTest(.{
        .name = "Test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
    });
    main_tests.linkLibC();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const exe = b.addExecutable(.{
        .name = "dstr",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
