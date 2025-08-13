const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use-llvm", "Use the LLVM backend");
    const openssl = b.option(bool, "openssl", "Link against OpenSSL") orelse false;
    const strip = b.option(bool, "strip", "Remove debugging symbols");

    if (target.result.os.tag == .windows)
        @panic("Windows does not support the file executable attribute. Try using WSL.");

    const narser = b.addModule("narser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOptionPath("tests_path", b.path("src/tests"));
    options.addOption(bool, "openssl", openssl);

    const options_mod = options.createModule();
    narser.addImport("options", options_mod);

    const exe = b.addExecutable(.{
        .name = "narser",
        .use_llvm = use_llvm,
        .root_module = b.addModule("exe", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "narser", .module = narser },
                .{ .name = "options", .module = options_mod },
            },
        }),
    });

    if (openssl) {
        const openssl_dep = b.lazyDependency("openssl", .{
            .target = target,
            .optimize = optimize,
        });
        if (openssl_dep) |d| {
            exe.root_module.link_libc = true;
            exe.root_module.linkLibrary(d.artifact("ssl"));
            exe.root_module.linkLibrary(d.artifact("crypto"));
        }
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const narser_unit_tests = b.addTest(.{
        .root_module = narser,
    });

    const run_narser_unit_tests = b.addRunArtifact(narser_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_narser_unit_tests.step);
}
