const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = try std.SemanticVersion.parse(zon.version);

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", version);

    const ignore_elevation_loss = b.option(bool, "ignore-loss", "Ignore elevation loss when calculating route cost. Default: false") orelse false;
    options.addOption(bool, "ignore_elevation_loss", ignore_elevation_loss);

    const compute_a_star = b.option(bool, "compute-a-star", "Compute A* heuristic for routing. Default: false") orelse false;
    options.addOption(bool, "compute_a_star", compute_a_star);

    // Exported as the `zill` module so other subprojects (convert) can import it.
    const zill_mod = b.addModule("zill", .{
        .root_source_file = b.path("src/graph/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    zill_mod.addOptions("options", options);

    // ============= zill executable =============

    const zill_exe = b.addExecutable(.{
        .name = "zill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zill", .module = zill_mod },
            },
        }),
    });
    b.installArtifact(zill_exe);
    zill_exe.root_module.addImport("args", b.dependency("args", .{ .target = target, .optimize = optimize }).module("args"));

    const run_step = b.step("run", "Build and run `zill` (find routes in a .zl graph)");
    const run_cmd = b.addRunArtifact(zill_exe);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| run_cmd.addArgs(args);

    // ============= browser module (wasm32) =============

    // Served to the dashboard. Same graph library, no OS underneath, no entry
    // point: the host drives it through the exports in src/wasm.zig.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimization mode for the browser module. Default: ReleaseSafe") orelse .ReleaseSafe;
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .baseline,
    });

    const zill_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/graph/graph.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    zill_wasm_mod.addOptions("options", options);

    const wasm_exe = b.addExecutable(.{
        .name = "zill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{
                .{ .name = "zill", .module = zill_wasm_mod },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    // `export fn` alone does not reach the wasm export section for a
    // freestanding module; rdynamic publishes the entry points to the host.
    wasm_exe.rdynamic = true;
    wasm_exe.import_memory = false;
    wasm_exe.export_memory = true;
    wasm_exe.initial_memory = 16 * 1024 * 1024;

    const wasm_step = b.step("wasm", "Build the browser WebAssembly module into zig-out/bin/zill.wasm");
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&install_wasm.step);

    // ============= tests =============

    const zill_tests = b.addTest(.{ .root_module = zill_mod });
    zill_tests.root_module.addImport("zbench", b.dependency("zbench", .{ .target = target, .optimize = optimize }).module("zbench"));
    const run_zill_tests = b.addRunArtifact(zill_tests);

    if (b.args) |args| zill_tests.filters = args;

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zill_tests.step);
}
