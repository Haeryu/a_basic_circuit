const std = @import("std");

fn wasmModule(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    module.export_symbol_names = &.{
        "abc_reset",
        "abc_add_node",
        "abc_add_counter",
        "abc_remove_node",
        "abc_connect",
        "abc_disconnect",
        "abc_set_input",
        "abc_set_counter",
        "abc_ram_configure",
        "abc_ram_read_low",
        "abc_ram_read_high",
        "abc_ram_write",
        "abc_ram_snapshot",
        "abc_ram_snapshot_address_low",
        "abc_ram_snapshot_address_high",
        "abc_ram_snapshot_word_low",
        "abc_ram_snapshot_word_high",
        "abc_run",
        "abc_value",
        "abc_state",
        "abc_restore_state",
        "abc_sem_valid_shape",
        "abc_sem_input_count",
        "abc_sem_output_count",
        "abc_sem_input_width",
        "abc_sem_output_width",
        "abc_sem_input_field",
        "abc_sem_output_field",
        "abc_sem_connection_status",
        "abc_width_reset",
        "abc_width_add_group",
        "abc_width_add_sum",
        "abc_width_add_pow",
        "abc_width_solve",
        "abc_width_value",
        "abc_def_reset",
        "abc_def_add_node",
        "abc_def_add_wire",
        "abc_def_compile",
        "abc_def_group_count",
        "abc_def_group_value",
        "abc_def_group_min",
        "abc_def_group_max",
        "abc_def_group_dependent",
        "abc_def_binding",
        "abc_def_relation_count",
        "abc_def_relation_kind",
        "abc_def_relation_a",
        "abc_def_relation_b",
        "abc_def_relation_c",
        "abc_doc_reset",
        "abc_doc_add_node",
        "abc_doc_add_wire",
        "abc_doc_begin_custom",
        "abc_doc_add_custom_child",
        "abc_doc_add_custom_wire",
        "abc_doc_add_custom_input",
        "abc_doc_add_custom_output",
        "abc_doc_finish_custom",
        "abc_doc_analyze",
        "abc_doc_compile",
        "abc_doc_scalar_count",
        "abc_doc_state_count",
        "abc_doc_state_root",
        "abc_doc_state_local",
        "abc_doc_state_has_local",
        "abc_doc_state_style",
        "abc_doc_state_index",
        "abc_doc_state_kind",
        "abc_doc_state_restore",
        "abc_doc_state_node",
        "abc_doc_diagnostic_count",
        "abc_doc_diagnostic_root",
        "abc_doc_diagnostic_target",
        "abc_doc_diagnostic_pin",
        "abc_doc_diagnostic_internal",
        "abc_doc_diagnostic_status",
        "abc_doc_diagnostic_source_width",
        "abc_doc_diagnostic_target_width",
        "abc_doc_top_handle",
        "abc_doc_custom_child_handle",
        "abc_doc_handle_input_count",
        "abc_doc_handle_input_width",
        "abc_doc_handle_input_connected",
        "abc_doc_handle_input_node",
        "abc_doc_handle_output_count",
        "abc_doc_handle_output_width",
        "abc_doc_handle_output_node",
    };

    const wasm = b.addExecutable(.{
        .name = "a_basic_circuit",
        .root_module = module,
    });
    wasm.entry = .disabled;
    return wasm;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("a_basic_circuit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run circuit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const wasm = wasmModule(b, optimize);

    const install_wasm = b.addInstallArtifact(wasm, .{});
    b.getInstallStep().dependOn(&install_wasm.step);

    const wasm_step = b.step("wasm", "Build the browser WebAssembly module");
    wasm_step.dependOn(&install_wasm.step);

    // `publish` builds a deployable static site under the Zig install prefix.
    // The frontend sources stay in web-src/; zig-out/web/ is generated output.
    const publish_wasm = wasmModule(b, .ReleaseFast);
    const publish_files = b.step("publish-files", "Install deployable browser files");
    publish_files.dependOn(&b.addInstallFileWithDir(b.path("web-src/index.html"), .{ .custom = "web" }, "index.html").step);
    publish_files.dependOn(&b.addInstallFileWithDir(b.path("web-src/css/style.css"), .{ .custom = "web/css" }, "style.css").step);
    publish_files.dependOn(&b.addInstallFileWithDir(b.path("web-src/js/app.js"), .{ .custom = "web/js" }, "app.js").step);
    publish_files.dependOn(&b.addInstallFileWithDir(b.path("web-src/js/circuit.js"), .{ .custom = "web/js" }, "circuit.js").step);
    inline for (.{ "clipboard", "clock", "routing", "history", "project", "symbols" }) |name| {
        publish_files.dependOn(&b.addInstallFileWithDir(b.path("web-src/js/" ++ name ++ ".js"), .{ .custom = "web/js" }, name ++ ".js").step);
    }
    publish_files.dependOn(&b.addInstallFileWithDir(publish_wasm.getEmittedBin(), .{ .custom = "web/wasm" }, "a_basic_circuit.wasm").step);

    const publish_step = b.step("publish", "Build the deployable site into zig-out/web/");
    publish_step.dependOn(publish_files);

    const web_tests = b.addSystemCommand(&.{ "node", "--test", "--test-concurrency=1", "tools/test-web.mjs", "tools/test-clock.mjs", "tools/test-clipboard.mjs", "tools/test-routing.mjs", "tools/test-editor-model.mjs", "tools/test-history.mjs", "tools/test-project.mjs" });
    web_tests.setCwd(b.path("."));
    web_tests.step.dependOn(publish_step);
    const web_test_step = b.step("test-web", "Publish and test browser bus compilation against actual WASM (Node 22+)");
    web_test_step.dependOn(&web_tests.step);

    const serve = b.addSystemCommand(&.{ "python", "tools/serve.py" });
    serve.setCwd(b.path("."));
    serve.stdio = .inherit;
    serve.step.dependOn(publish_step);

    const serve_step = b.step("serve", "Publish and serve the site locally");
    serve_step.dependOn(&serve.step);
}
