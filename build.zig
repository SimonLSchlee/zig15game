const std = @import("std");
const builtin = @import("builtin");

fn addAssets(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const assets = [_]struct { []const u8, []const u8 }{
        .{ "assets/movesuccess.qoa", "movesuccess" },
        .{ "assets/movefailed.qoa", "movefailed" },
        .{ "assets/winner.qoa", "winner" },
    };

    for (assets) |asset| {
        const path, const name = asset;
        exe.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(path) });
    }
}

const App = struct {
    name: []const u8,
    path: std.Build.LazyPath,
};

// wasm references used to create this:
// https://github.com/permutationlock/zig_emscripten_threads/blob/main/build.zig
// https://ziggit.dev/docs?topic=3531
// https://ziggit.dev/t/state-of-concurrency-support-on-wasm32-freestanding/1465/8
// https://ziggit.dev/t/why-suse-offset-converter-is-needed/4131/3
// https://github.com/raysan5/raylib/blob/master/src/build.zig
// https://github.com/silbinarywolf/3d-raylib-toy-project/blob/main/raylib-zig/build.zig
// https://github.com/ziglang/zig/issues/10836
// https://github.com/bluesillybeard/ZigAndRaylibSetup/blob/main/build.zig
// https://github.com/Not-Nik/raylib-zig/issues/24
// https://github.com/raysan5/raylib/wiki/Working-for-Web-%28HTML5%29

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .bulk_memory,
        }),
        .os_tag = .emscripten,
    });
    const is_wasm = target.result.cpu.arch == .wasm32;
    const actual_target = if (is_wasm) wasm_target else target;

    const raylib_optimize = b.option(
        std.builtin.OptimizeMode,
        "raylib-optimize",
        "Prioritize performance, safety, or binary size (-O flag), defaults to value of optimize option",
    ) orelse optimize;

    const strip = b.option(
        bool,
        "strip",
        "Strip debug info to reduce binary size, defaults to false",
    ) orelse false;

    const raylib_dep = b.dependency("raylib", .{
        .target = actual_target,
        .optimize = raylib_optimize,
        .rmodels = false,
    });
    const raylib_artifact = raylib_dep.artifact("raylib");

    const app = App{
        .name = "zig15game",
        .path = b.path("src/main.zig"),
    };

    if (is_wasm) {
        if (b.sysroot == null) {
            @panic("Pass '--sysroot \"[path to emsdk installation]/upstream/emscripten\"'");
        }

        const exe_lib = b.addStaticLibrary(.{
            .name = app.name,
            .root_source_file = app.path,
            .target = wasm_target,
            .optimize = optimize,
            .link_libc = true,
        });
        // exe_lib.shared_memory = true;
        // TODO currently deactivated because it seems as if it doesn't work with local hosting debug workflow
        exe_lib.shared_memory = false;
        exe_lib.root_module.single_threaded = false;

        exe_lib.linkLibrary(raylib_artifact);
        exe_lib.addIncludePath(raylib_dep.path("src"));

        const sysroot_include = b.pathJoin(&.{ b.sysroot.?, "cache", "sysroot", "include" });
        var dir = std.fs.openDirAbsolute(sysroot_include, std.fs.Dir.OpenDirOptions{ .access_sub_paths = true, .no_follow = true }) catch @panic("No emscripten cache. Generate it!");
        dir.close();

        exe_lib.addIncludePath(.{ .cwd_relative = sysroot_include });
        addAssets(b, exe_lib);

        const emcc_exe = switch (builtin.os.tag) { // TODO bundle emcc as a build dependency
            .windows => "emcc.bat",
            else => "emcc",
        };

        const emcc_exe_path = b.pathJoin(&.{ b.sysroot.?, emcc_exe });
        const emcc_command = b.addSystemCommand(&[_][]const u8{emcc_exe_path});
        emcc_command.addArgs(&[_][]const u8{
            "-o",
            "zig-out/web/index.html",
            "-sFULL-ES3=1",
            "-sUSE_GLFW=3",
            "-O3",

            // "-sAUDIO_WORKLET=1",
            // "-sWASM_WORKERS=1",

            "-sASYNCIFY",
            // TODO currently deactivated because it seems as if it doesn't work with local hosting debug workflow
            // "-pthread",
            // "-sPTHREAD_POOL_SIZE=4",

            "-sINITIAL_MEMORY=167772160",
            //"-sEXPORTED_FUNCTIONS=_main,__builtin_return_address",

            // USE_OFFSET_CONVERTER required for @returnAddress used in
            // std.mem.Allocator interface
            "-sUSE_OFFSET_CONVERTER",
            "--shell-file",
            b.path("src/shell.html").getPath(b),
        });

        const link_items: []const *std.Build.Step.Compile = &.{
            raylib_artifact,
            exe_lib,
        };
        for (link_items) |item| {
            emcc_command.addFileArg(item.getEmittedBin());
            emcc_command.step.dependOn(&item.step);
        }

        const install = emcc_command;
        b.default_step.dependOn(&install.step);
    } else {
        const exe = b.addExecutable(.{
            .name = app.name,
            .root_source_file = app.path,
            .target = target,
            .optimize = optimize,
        });
        addAssets(b, exe);
        exe.root_module.strip = strip;
        exe.linkLibrary(raylib_artifact);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        addAssets(b, unit_tests);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}
