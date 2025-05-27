const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    if (target.result.os.tag == .windows)
        @panic("Windows does not support the file executable attribute. Try using WSL.");

    const optimize = b.standardOptimizeOption(.{});

    const narser = b.addModule("narser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.addModule("narser_bin", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var tests_path = std.Build.Step.Options.create(b);
    tests_path.addOptionPath("tests_path", b.path("src/tests"));
    narser.addImport("tests", tests_path.createModule());

    exe_mod.addImport("narser", narser);

    const lib_mod = b.addModule("libnarser", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "narser",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "narser",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const narser_unit_tests = b.addTest(.{
        .root_module = narser,
    });

    const run_narser_unit_tests = b.addRunArtifact(narser_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_narser_unit_tests.step);
}
