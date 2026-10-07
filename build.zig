const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zregex_mod = b.addModule("zregex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const zregex_dylib = b.addLibrary(.{
        .name = "zregex",
        .linkage = .dynamic,
        .root_module = b.addModule("zregex_abi", .{
            .root_source_file = b.path("src/abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zregex", .module = zregex_mod },
            },
        }),
    });
    b.installArtifact(zregex_dylib);
    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zregex", .module = zregex_mod },
            },
        }),
    });
    const exe2 = b.addExecutable(.{
        .name = "example2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/example2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe2.root_module.linkLibrary(zregex_dylib);
    exe2.root_module.addIncludePath(b.path("include/"));
    b.installArtifact(exe);
    b.installArtifact(exe2);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const mod_tests = b.addTest(.{
        .root_module = zregex_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
