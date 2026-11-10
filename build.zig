const std = @import("std");
const builtin = @import("builtin");

const Translator = @import("translate_c").Translator;

/// Since Zig is currently unstable, this program will not compile if the major and minor versions of the Zig compiler
/// do not match exactly what is expected in the source code.
pub fn assertMajorMinorZigVersion(comptime ver: []const u8) void {
    comptime {
        const zig_required_version_string = ver;
        const zig_required_version = std.SemanticVersion.parse(zig_required_version_string) catch unreachable;
        const current_zig_version = builtin.zig_version;
        const current_zig_version_string = std.fmt.comptimePrint("{d}.{d}.{d}", .{current_zig_version.major, current_zig_version.minor, current_zig_version.patch});
        if (
            current_zig_version.major != zig_required_version.major or
            current_zig_version.minor != zig_required_version.minor
        ) {
            const version_err_msg =
                \\ This program requires zig version
                ++ " " ++ zig_required_version_string ++
                \\ but version
                ++ " " ++ current_zig_version_string ++
                \\ was found.
                ;
            @compileError(version_err_msg);
        }
    }
}

pub fn build(b: *std.Build) void {
    assertMajorMinorZigVersion("0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules for C ABI.
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

    // ZRegex internal modules.
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

    // Main library build options.
    const zregex_build_options = b.addOptions();
    const codelim = b.option(usize, "codelim", "The amount of instruction iterations permitted in the VM before an error is produced. If not provided, the amount is unbounded");
    zregex_build_options.addOption(?usize, "codelim", codelim);
    zregex_mod.addOptions("zregex_build_options", zregex_build_options);

    // Executables.
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

    // Tests.
    const test_filter = b.option([]const u8, "test-filter", "The target test to run.");
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zregex", .module = zregex_mod },
            },
        }),
        .filters = 
            if (test_filter) |filter|
                &.{filter}
            else
                &.{},
        .use_llvm = true, // Required for fuzzer.
    });

    // Test options.
    const test_options = b.addOptions();
    const fuzzlen = b.option(usize, "fuzzlen", "The length of the buffer the fuzzer will use for testing.") orelse 32; // Default fuzz length is 32.
    std.debug.print("Fuzzing will be done with length {d}\n", .{fuzzlen});
    test_options.addOption(usize, "fuzzlen", fuzzlen);
    exe_tests.root_module.addOptions("test_options", test_options);

    // Type reflection testing.
    const reflection_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/type_reflection_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zregex", .module = zregex_mod },
            },
        }),
    });

    // Test runners.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const run_reflection_tests = b.addRunArtifact(reflection_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_reflection_tests.step);
}
