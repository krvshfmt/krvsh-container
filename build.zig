const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public Zig module, imported by consumers as "krvs".
    const mod = b.addModule("krvs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "krvs",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // C-ABI static library: separate module rooted at c_root.zig (keeps exports + links
    // libc for the C allocator). The plain lib stays libc-free.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/c_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    capi_mod.link_libc = true;
    const capi = b.addLibrary(.{
        .name = "krvs_c",
        .root_module = capi_mod,
        .linkage = .static,
    });
    capi.installHeadersDirectory(b.path("include"), "", .{});
    b.installArtifact(capi);

    // Shared C-ABI library: same c_root module, dynamic linkage. This is what the
    // Python ctypes bindings (python/krvs) load. Produces libkrvs_c.{dylib,so,dll}.
    const capi_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/c_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    capi_shared_mod.link_libc = true;
    const capi_shared = b.addLibrary(.{
        .name = "krvs_c",
        .root_module = capi_shared_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(capi_shared);

    // Copy the shared library into the Python package (python/krvs/_libs/) so an
    // installed package can find it without the zig-out/ tree. `zig build` keeps this
    // in sync; the Python loader checks _libs/ first, then zig-out/lib for dev.
    const sync_pylib = b.addUpdateSourceFiles();
    sync_pylib.addCopyFileToSource(capi_shared.getEmittedBin(), b.fmt("python/krvs/_libs/{s}", .{sharedLibName("krvs_c", target.result)}));
    b.getInstallStep().dependOn(&sync_pylib.step);

    // Zig unit tests.
    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // C smoke test: compile test/capi_smoke.c, link the C-ABI lib, run it.
    const csmoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    csmoke_mod.addCSourceFile(.{ .file = b.path("test/capi_smoke.c"), .flags = &.{"-std=c11"} });
    csmoke_mod.addIncludePath(b.path("include"));
    csmoke_mod.linkLibrary(capi);
    csmoke_mod.link_libc = true;
    const csmoke = b.addExecutable(.{
        .name = "capi_smoke",
        .root_module = csmoke_mod,
    });
    const run_csmoke = b.addRunArtifact(csmoke);

    const test_step = b.step("test", "Run unit tests + C smoke test");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_csmoke.step);
}

/// Platform-correct shared-library filename for a target (no path), e.g.
/// libkrvs_c.dylib / libkrvs_c.so / krvs_c.dll.
fn sharedLibName(comptime stem: []const u8, target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .windows => stem ++ ".dll",
        .macos => "lib" ++ stem ++ ".dylib",
        else => "lib" ++ stem ++ ".so",
    };
}
