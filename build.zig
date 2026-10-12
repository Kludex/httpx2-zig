//! Build the Python extension and run the pure Zig test target.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target_name = b.graph.environ_map.get("HATCH_ZIG_TARGET") orelse "";
    const default_target: std.Target.Query = if (target_name.len > 0) target: {
        var query = std.Target.Query.parse(.{ .arch_os_abi = target_name }) catch
            @panic("invalid HATCH_ZIG_TARGET");
        query.cpu_model = .baseline;
        break :target query;
    } else .{ .cpu_model = .baseline };
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("transport.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const python_include = b.graph.environ_map.get("HATCH_ZIG_PYTHON_INCLUDE") orelse return;
    const ext_suffix = b.graph.environ_map.get("HATCH_ZIG_EXT_SUFFIX") orelse return;

    const mod = b.createModule(.{
        .root_source_file = b.path("transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = python_include });
    mod.addCSourceFile(.{ .file = b.path("python_shim.c"), .flags = &.{"-std=c11"} });
    const lib = b.addLibrary(.{
        .name = "_httpx2_zig",
        .root_module = mod,
        .linkage = .dynamic,
    });
    switch (target.result.os.tag) {
        .macos => lib.linker_allow_shlib_undefined = true,
        .windows => {
            const libdir = b.graph.environ_map.get("HATCH_ZIG_PYTHON_LIBDIR") orelse
                @panic("HATCH_ZIG_PYTHON_LIBDIR is required on Windows");
            const libname = b.graph.environ_map.get("HATCH_ZIG_PYTHON_LIB") orelse
                @panic("HATCH_ZIG_PYTHON_LIB is required on Windows");
            mod.addLibraryPath(.{ .cwd_relative = libdir });
            mod.linkSystemLibrary(libname, .{});
        },
        else => {},
    }
    const install = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .{ .custom = "../httpx2_zig" },
        b.fmt("_httpx2_zig{s}", .{ext_suffix}),
    );
    b.getInstallStep().dependOn(&install.step);
}
