const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aifw_core_native = b.addModule("aifw_core", .{
        .root_source_file = b.path("core/aifw_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    // const aifw_core_native = b.createModule(.{
    //     .root_source_file = b.path("core/aifw_core.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    // Native static library
    const lib = b.addLibrary(.{
        .name = "oneaifw_core",
        .root_module = aifw_core_native,
        .linkage = .static,
    });
    lib.root_module.strip = true;
    // Build and link Rust regex (native)
    const cargo_native = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--release" });
    cargo_native.setCwd(b.path("libs/regex"));
    lib.step.dependOn(&cargo_native.step);
    lib.addObjectFile(b.path("libs/regex/target/release/libaifw_regex.a"));
    b.installArtifact(lib);

    // WASM freestanding static library (for browser)
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const aifw_core_wasm = b.createModule(.{
        .root_source_file = b.path("core/aifw_core.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const wasm = b.addLibrary(.{
        .name = "oneaifw_core_wasm",
        .root_module = aifw_core_wasm,
        .linkage = .static,
    });
    wasm.root_module.strip = true;
    // Build and link Rust regex (wasm)
    const cargo_wasm = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--release", "--target", "wasm32-unknown-unknown" });
    cargo_wasm.setCwd(b.path("libs/regex"));
    wasm.step.dependOn(&cargo_wasm.step);
    wasm.addObjectFile(b.path("libs/regex/target/wasm32-unknown-unknown/release/libaifw_regex.a"));
    b.installArtifact(wasm);

    // Tests (native)
    const unit_tests = b.addTest(.{ .root_module = aifw_core_native });
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run test-aifw-core");
    test_step.dependOn(&run_tests.step);

    const integ_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test-aifw-core/test_session.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Integration test executable (native)
    const integ = b.addExecutable(.{
        .name = "aifw_core_test",
        .root_module = integ_test_mod,
    });
    integ.root_module.addImport("aifw_core", aifw_core_native);
    b.installArtifact(integ);

    const run_integ = b.addRunArtifact(integ);
    const integ_step = b.step("inttest", "Run integration test executable");
    integ_step.dependOn(&run_integ.step);
}
