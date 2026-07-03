const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp = b.addExecutable(.{
        .name = "affective-core-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mcp.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(mcp);

    const embedded = b.addLibrary(.{
        .name = "affective-core-embedded",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/affective_core_embedded.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    embedded.bundle_compiler_rt = true;
    const android_ndk_usr = b.option([]const u8, "android-ndk-usr", "Path to the Android NDK sysroot/usr directory");
    const sqlite_include = b.option([]const u8, "sqlite-include", "Directory containing sqlite3.h for embedded targets with vendored SQLite");
    const sqlite_obj = b.option([]const u8, "sqlite-obj", "Path to a compiled sqlite3.o object file for embedded targets with vendored SQLite");
    if (target.result.abi == .android or target.result.os.tag == .ios) {
        embedded.root_module.link_libc = true;
    }
    if (target.result.abi == .android) {
        embedded.root_module.single_threaded = true;
    }
    if (android_ndk_usr) |usr| {
        embedded.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ usr, "include" }) });
        const android_arch_include = switch (target.result.cpu.arch) {
            .aarch64 => "aarch64-linux-android",
            .x86_64 => "x86_64-linux-android",
            else => null,
        };
        if (android_arch_include) |subdir| {
            embedded.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ usr, "include", subdir }) });
        }
    }
    if (target.result.os.tag != .ios) {
        if (sqlite_include) |dir| {
            embedded.root_module.addIncludePath(.{ .cwd_relative = dir });
        }
        if (sqlite_obj) |path| {
            embedded.root_module.addObjectFile(.{ .cwd_relative = path });
        } else {
            embedded.root_module.linkSystemLibrary("sqlite3", .{});
        }
    }
    b.installArtifact(embedded);

    const api_health = b.addExecutable(.{
        .name = "affective-core-api-health",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_api_health.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(api_health);

    const api_e2e = b.addExecutable(.{
        .name = "affective-core-api-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_api_e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(api_e2e);

    const brain_quality_e2e = b.addExecutable(.{
        .name = "brain-quality-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_brain_quality_e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    brain_quality_e2e.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(brain_quality_e2e);

    const session = b.addExecutable(.{
        .name = "affective-core-session",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_session.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    session.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(session);

    const affective_mcp = b.addExecutable(.{
        .name = "affective-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_affective_mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    affective_mcp.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(affective_mcp);

    const affective_mcp_stdio = b.addExecutable(.{
        .name = "affective-mcp-stdio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_affective_mcp_stdio.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    affective_mcp_stdio.root_module.addIncludePath(b.path("include"));
    affective_mcp_stdio.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(affective_mcp_stdio);

    const session_lib = b.addLibrary(.{
        .name = "affective-core-session",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_session_lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    session_lib.bundle_compiler_rt = true;
    if (target.result.os.tag != .ios) {
        session_lib.root_module.linkSystemLibrary("sqlite3", .{});
    } else {
        session_lib.root_module.link_libc = true;
    }

    const llm_tester_manifest = b.addExecutable(.{
        .name = "affective-core-llm-tester-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_llm_tester_manifest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(llm_tester_manifest);

    const install_llm_tester_manifest = b.addInstallArtifact(llm_tester_manifest, .{});
    const run_llm_tester_manifest_cmd = b.addRunArtifact(llm_tester_manifest);
    run_llm_tester_manifest_cmd.step.dependOn(&install_llm_tester_manifest.step);
    if (b.args) |args| run_llm_tester_manifest_cmd.addArgs(args);

    const llm_tester_manifest_step = b.step("llm-tester-manifest", "Generate LLM tester scenario manifest JSON");
    llm_tester_manifest_step.dependOn(&run_llm_tester_manifest_cmd.step);

    const mcp_host = b.addExecutable(.{
        .name = "mcp-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_mcp_host.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mcp_host.root_module.addIncludePath(b.path("include"));
    mcp_host.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(mcp_host);

    const install_mcp_host = b.addInstallArtifact(mcp_host, .{});
    const mcp_host_step = b.step("mcp-host", "Build and install the embedded brain CLI harness");
    mcp_host_step.dependOn(&install_mcp_host.step);

    const install_mcp = b.addInstallArtifact(mcp, .{});
    const mcp_step = b.step("mcp", "Build and install the stdio MCP server");
    mcp_step.dependOn(&install_mcp.step);

    const install_affective_mcp = b.addInstallArtifact(affective_mcp, .{});
    const affective_mcp_step = b.step("affective-mcp", "Build and install the TCP-backed Affective MCP host");
    affective_mcp_step.dependOn(&install_affective_mcp.step);

    const install_affective_mcp_stdio = b.addInstallArtifact(affective_mcp_stdio, .{});
    const affective_mcp_stdio_step = b.step("affective-mcp-stdio", "Build and install the embedded stdio-only Affective MCP host");
    affective_mcp_stdio_step.dependOn(&install_affective_mcp_stdio.step);

    const install_embedded = b.addInstallArtifact(embedded, .{});
    const install_embedded_header = b.addInstallHeaderFile(b.path("include/affective_core_embedded.h"), "affective_core_embedded.h");
    const embedded_step = b.step("embedded", "Build and install the Affective embeddable static library");
    embedded_step.dependOn(&install_embedded.step);
    embedded_step.dependOn(&install_embedded_header.step);

    const install_session = b.addInstallArtifact(session, .{});
    const install_session_lib = b.addInstallArtifact(session_lib, .{});
    const install_session_header = b.addInstallHeaderFile(b.path("include/affective_core_session.h"), "affective_core_session.h");
    const session_step = b.step("session", "Build and install the Brain Session Protocol runtime");
    session_step.dependOn(&install_session.step);
    session_step.dependOn(&install_session_lib.step);
    session_step.dependOn(&install_session_header.step);

    const run_api_health_cmd = b.addRunArtifact(api_health);
    run_api_health_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_api_health_cmd.addArgs(args);

    const api_health_step = b.step("api-health", "Check configured LLM provider API routes");
    api_health_step.dependOn(&run_api_health_cmd.step);

    const run_api_e2e_cmd = b.addRunArtifact(api_e2e);
    run_api_e2e_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_api_e2e_cmd.addArgs(args);

    const api_e2e_step = b.step("api-e2e", "Run live LLM and image API contract checks");
    api_e2e_step.dependOn(&run_api_e2e_cmd.step);

    const install_brain_quality_e2e = b.addInstallArtifact(brain_quality_e2e, .{});
    const run_brain_quality_e2e_cmd = b.addRunArtifact(brain_quality_e2e);
    run_brain_quality_e2e_cmd.step.dependOn(&install_brain_quality_e2e.step);
    if (b.args) |args| run_brain_quality_e2e_cmd.addArgs(args);

    const brain_quality_e2e_step = b.step("brain-quality-e2e", "Run live brain quality E2E scenarios and emit snapshot JSON");
    brain_quality_e2e_step.dependOn(&run_brain_quality_e2e_cmd.step);

    const lint_module_size = b.addExecutable(.{
        .name = "lint-module-size",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lint_module_size.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lint_module_size = b.addRunArtifact(lint_module_size);
    if (b.args) |args| run_lint_module_size.addArgs(args);

    const lint_module_size_step = b.step("lint-module-size", "Check Zig module size and print the top offenders");
    lint_module_size_step.dependOn(&run_lint_module_size.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addIncludePath(b.path("include"));
    tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const embedded_ffi_fuzz = b.addExecutable(.{
        .name = "embedded-ffi-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_embedded_ffi_fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    embedded_ffi_fuzz.root_module.addIncludePath(b.path("include"));
    embedded_ffi_fuzz.root_module.linkSystemLibrary("sqlite3", .{});
    const install_embedded_ffi_fuzz = b.addInstallArtifact(embedded_ffi_fuzz, .{});
    const embedded_ffi_fuzz_build_step = b.step("embedded-ffi-fuzz-build", "Build embedded JSON dispatch fuzz harness");
    embedded_ffi_fuzz_build_step.dependOn(&install_embedded_ffi_fuzz.step);

    const run_embedded_ffi_fuzz = b.addRunArtifact(embedded_ffi_fuzz);
    run_embedded_ffi_fuzz.step.dependOn(&install_embedded_ffi_fuzz.step);
    if (b.args) |args| run_embedded_ffi_fuzz.addArgs(args);

    const embedded_ffi_fuzz_step = b.step("embedded-ffi-fuzz", "Run embedded JSON dispatch fuzz harness (pass --iterations N --seed S)");
    embedded_ffi_fuzz_step.dependOn(&run_embedded_ffi_fuzz.step);

    const dispatch_deadlock_stress = b.addExecutable(.{
        .name = "dispatch-deadlock-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_dispatch_deadlock_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dispatch_deadlock_stress.root_module.addIncludePath(b.path("include"));
    dispatch_deadlock_stress.root_module.linkSystemLibrary("sqlite3", .{});
    const install_dispatch_deadlock_stress = b.addInstallArtifact(dispatch_deadlock_stress, .{});
    const dispatch_deadlock_stress_build_step = b.step("dispatch-deadlock-stress-build", "Build dispatch deadlock stress harness");
    dispatch_deadlock_stress_build_step.dependOn(&install_dispatch_deadlock_stress.step);

    const run_dispatch_deadlock_stress = b.addRunArtifact(dispatch_deadlock_stress);
    run_dispatch_deadlock_stress.step.dependOn(&install_dispatch_deadlock_stress.step);
    if (b.args) |args| run_dispatch_deadlock_stress.addArgs(args);

    const dispatch_deadlock_stress_step = b.step("dispatch-deadlock-stress", "Run dispatch deadlock stress harness (pass --cycles N --pressure N --seed S)");
    dispatch_deadlock_stress_step.dependOn(&run_dispatch_deadlock_stress.step);

    const dispatch_deadlock_model = b.addExecutable(.{
        .name = "dispatch-deadlock-model",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_dispatch_deadlock_model.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dispatch_deadlock_model = b.addRunArtifact(dispatch_deadlock_model);
    if (b.args) |args| run_dispatch_deadlock_model.addArgs(args);

    const dispatch_deadlock_model_step = b.step("dispatch-deadlock-model", "Exhaustively model-check dispatch routing for internal deadlocks");
    dispatch_deadlock_model_step.dependOn(&run_dispatch_deadlock_model.step);

    const reinit_brain_cmd = b.addSystemCommand(&.{ "sh", "scripts/reinit_brain_data.sh" });
    if (b.args) |args| reinit_brain_cmd.addArgs(args);

    const reinit_brain_step = b.step("reinit-brain", "Clear persisted brain memory, logs, reminders, captures, and audio");
    reinit_brain_step.dependOn(&reinit_brain_cmd.step);
}
