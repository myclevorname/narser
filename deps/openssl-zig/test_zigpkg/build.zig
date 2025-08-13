const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_openssl = b.addModule("openssl", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "openssl",
        .root_module = mod_openssl,
    });

    const dep_openssl_zig = b.dependency("openssl", .{});

    mod_openssl.linkLibrary(dep_openssl_zig.artifact("crypto"));
    mod_openssl.linkLibrary(dep_openssl_zig.artifact("ssl"));

    b.installArtifact(lib);
}
