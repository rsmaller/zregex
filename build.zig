const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});

    const zregex_header: Translator = .init(translate_c, .{
        .c_source_file = b.path("include/zregex.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_headers: Translator = .init(translate_c, .{
        .c_source_file = b.path("include/c.h"),
        .target = target,
        .optimize = optimize,
    });

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
            .link_libc = true,
            .imports = &.{
                .{ .name = "zregex", .module = zregex_mod },
                .{ .name = "c_headers", .module = c_headers.mod },
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
            .imports = &.{
                .{ .name = "zregex_header", .module = zregex_header.mod },
            },
        }),
    });
    exe2.root_module.linkLibrary(zregex_dylib);
    b.installArtifact(exe);
    b.installArtifact(exe2);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zregex", .module = zregex_mod },
            },
        }),
        .use_llvm = true,
    });
    const test_options = b.addOptions();
    const fuzzlen = b.option(usize, "fuzzlen", "The length of the buffer the fuzzer will use for testing.") orelse 32; // Default fuzz length is 32.
    std.debug.print("Fuzzing will be done with length {d}\n", .{fuzzlen});
    test_options.addOption(usize, "fuzzlen", fuzzlen);
    exe_tests.root_module.addOptions("test_options", test_options);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
