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
    lib.root_module.strip = optimize != .Debug;
    // Link C runtime for native (Rust staticlib references libc symbols like strlen)
    lib.root_module.link_libc = true;
    // Build and link Rust regex (native)
    const cargo_native = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--release" });
    cargo_native.setCwd(b.path("libs/regex"));
    lib.step.dependOn(&cargo_native.step);
    lib.addObjectFile(b.path("libs/regex/target/release/libaifw_regex.a"));
    b.installArtifact(lib);

    // WASM freestanding module (for browser)
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const aifw_core_wasm_mod = b.createModule(.{
        .root_source_file = b.path("core/aifw_core.zig"),
        .target = wasm_target,
        .optimize = std.builtin.OptimizeMode.ReleaseSmall,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "liboneaifw_core", // will produce liboneaifw_core.wasm
        .root_module = aifw_core_wasm_mod,
    });
    wasm_exe.root_module.strip = optimize != .Debug;
    // Build as a library-style WASM module without an entry point
    wasm_exe.entry = .disabled;
    // Ensure required exports are retained in the final WASM
    wasm_exe.root_module.export_symbol_names = &[_][]const u8{
        "strlen",
        "aifw_malloc",
        "aifw_free_sized",
        "aifw_string_free",
        "aifw_default_mask_bits",
        "aifw_shutdown",
        "aifw_session_create",
        "aifw_session_destroy",
        // "aifw_session_mask",
        // "aifw_session_restore",
        "aifw_session_mask_and_out_meta",
        "aifw_session_restore_with_meta",
        "aifw_session_get_pii_spans",
    };

    const cargo_wasm = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--release", "--target", "wasm32-unknown-unknown" });
    cargo_wasm.setCwd(b.path("libs/regex"));

    // Reduce Rust archive into a single relocatable wasm object to avoid noisy archive members
    const extract_cmd = b.addSystemCommand(&[_][]const u8{
        "sh", "-lc",
        "set -e\n" ++
            "cd libs/regex/target/wasm32-unknown-unknown/release\n" ++
            "rm -f aifw_regex_extracted.o\n" ++
            "MEMBER=$(llvm-ar t libaifw_regex.a | grep -E 'aifw_regex-.*\\.rcgu\\.o' | head -n1)\n" ++
            "llvm-ar x libaifw_regex.a \"$MEMBER\"\n" ++
            "mv \"$MEMBER\" aifw_regex_extracted.o\n",
    });
    extract_cmd.step.dependOn(&cargo_wasm.step);

    wasm_exe.step.dependOn(&extract_cmd.step);
    wasm_exe.addObjectFile(b.path("libs/regex/target/wasm32-unknown-unknown/release/aifw_regex_extracted.o"));

    b.installArtifact(wasm_exe);

    // Build liboneaifw_core.wasm only (no symlink into webapp; packaged via aifw-js)
    const web_step = b.step("web:wasm", "Build liboneaifw_core.wasm for packaging");
    web_step.dependOn(&wasm_exe.step);

    // Tests (native)
    const unit_tests = b.addTest(.{ .root_module = aifw_core_native });
    unit_tests.root_module.strip = false;
    unit_tests.root_module.unwind_tables = .sync;
    unit_tests.root_module.omit_frame_pointer = false;
    unit_tests.root_module.error_tracing = true;
    unit_tests.root_module.link_libc = true;
    // Ensure Rust native staticlib is built before unit tests and link it
    unit_tests.step.dependOn(&cargo_native.step);
    unit_tests.addObjectFile(b.path("libs/regex/target/release/libaifw_regex.a"));
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.setEnvironmentVariable("ZIG_BACKTRACE", "full");

    const test_step = b.step("test", "Run test-aifw-core");
    test_step.dependOn(&run_tests.step);

    const integ_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test-aifw-core/test_session.zig"),
        .target = target,
        .optimize = optimize,
    });
    integ_test_mod.strip = false;
    integ_test_mod.unwind_tables = .sync;
    integ_test_mod.omit_frame_pointer = false;
    integ_test_mod.error_tracing = true;

    // Integration test executable (native)
    const integ = b.addExecutable(.{
        .name = "aifw_core_test",
        .root_module = integ_test_mod,
    });
    integ.root_module.strip = false;
    integ.root_module.unwind_tables = .sync;
    integ.root_module.omit_frame_pointer = false;
    integ.root_module.error_tracing = true;
    integ.root_module.link_libc = true;
    integ.root_module.addImport("aifw_core", aifw_core_native);
    // Ensure Rust native staticlib is built before integration test and link it
    integ.step.dependOn(&cargo_native.step);
    integ.addObjectFile(b.path("libs/regex/target/release/libaifw_regex.a"));
    b.installArtifact(integ);

    const run_integ = b.addRunArtifact(integ);
    run_integ.setEnvironmentVariable("ZIG_BACKTRACE", "full");
    const integ_step = b.step("inttest", "Run integration test executable");
    integ_step.dependOn(&run_integ.step);
}
