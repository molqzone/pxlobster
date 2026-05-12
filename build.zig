const std = @import("std");

const windows_libusb_sources = [_][]const u8{
    "core.c",
    "descriptor.c",
    "hotplug.c",
    "io.c",
    "strerror.c",
    "sync.c",
    "os/events_windows.c",
    "os/threads_windows.c",
    "os/windows_common.c",
    "os/windows_usbdk.c",
    "os/windows_winusb.c",
};

fn readPackageVersion(b: *std.Build) []const u8 {
    const zon_path = b.pathFromRoot("build.zig.zon");
    const zon = std.Io.Dir.cwd().readFileAlloc(b.graph.io, zon_path, b.allocator, .limited(64 * 1024)) catch
        @panic("failed to read build.zig.zon");
    const key = ".version = \"";
    const start = std.mem.find(u8, zon, key) orelse
        @panic("failed to locate package version in build.zig.zon");
    const value_start = start + key.len;
    const value_end = std.mem.findScalarPos(u8, zon, value_start, '"') orelse
        @panic("failed to parse package version in build.zig.zon");
    return zon[value_start..value_end];
}

fn addWindowsLibUsbConfigHeader(b: *std.Build) *std.Build.Step.ConfigHeader {
    const config_template = b.addWriteFiles();
    const config_template_path = config_template.add("libusb/config.h.in",
        \\#ifndef PXLIBUSB_CONFIG_H
        \\#define PXLIBUSB_CONFIG_H
        \\
        \\/* Minimal libusb config for Windows GNU/Clang static builds. */
        \\
        \\#define DEFAULT_VISIBILITY @DEFAULT_VISIBILITY@
        \\#define ENABLE_LOGGING @ENABLE_LOGGING@
        \\#define PLATFORM_WINDOWS @PLATFORM_WINDOWS@
        \\#define PRINTF_FORMAT(a, b) @PRINTF_FORMAT@
        \\
        \\#endif
        \\
    );

    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = config_template_path },
        .include_path = "config.h",
        .include_guard_override = "PXLIBUSB_CONFIG_H",
    }, .{
        .DEFAULT_VISIBILITY = "",
        .ENABLE_LOGGING = 1,
        .PLATFORM_WINDOWS = 1,
        .PRINTF_FORMAT = "__attribute__((format(printf, a, b)))",
    });
}

fn addLibUsbHeaders(
    artifact: *std.Build.Step.Compile,
    libusb_dep: *std.Build.Dependency,
) void {
    artifact.root_module.addIncludePath(libusb_dep.path(""));
    artifact.root_module.addIncludePath(libusb_dep.path("libusb"));
}

fn buildBundledWindowsLibUsb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libusb_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "usb-1.0",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(libusb_dep.path("libusb"));
    lib.root_module.addIncludePath(libusb_dep.path("libusb/os"));
    lib.root_module.addConfigHeader(addWindowsLibUsbConfigHeader(b));
    lib.root_module.addCMacro("_WIN32_WINNT", "0x0600");
    lib.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
    if (optimize != .Debug) {
        lib.root_module.addCMacro("NDEBUG", "1");
    }
    lib.root_module.addCSourceFiles(.{
        .root = libusb_dep.path("libusb"),
        .files = &windows_libusb_sources,
        .flags = &.{"-std=gnu11"},
    });

    return lib;
}

fn configureLibUsb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    artifact: *std.Build.Step.Compile,
    libusb_dep: *std.Build.Dependency,
    libusb_lib_dir: ?[]const u8,
    libusb_link_file: ?[]const u8,
) void {
    addLibUsbHeaders(artifact, libusb_dep);

    if (target.result.os.tag == .windows and libusb_lib_dir == null and libusb_link_file == null) {
        artifact.root_module.linkLibrary(buildBundledWindowsLibUsb(b, target, optimize, libusb_dep));
        return;
    }

    artifact.root_module.link_libc = true;

    if (libusb_lib_dir) |lib_dir| {
        artifact.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
    }

    if (libusb_link_file) |link_file| {
        artifact.root_module.addObjectFile(.{ .cwd_relative = link_file });
    } else {
        artifact.root_module.linkSystemLibrary("usb-1.0", .{
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
        });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libusb_lib_dir = b.option([]const u8, "libusb-lib-dir", "Custom libusb library directory");
    const libusb_link_file = b.option([]const u8, "libusb-link-file", "Custom libusb import/static archive");
    const libusb_dep = b.dependency("libusb", .{});
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const libusb_translate = b.addTranslateC(.{
        .root_source_file = libusb_dep.path("libusb/libusb.h"),
        .target = target,
        .optimize = optimize,
    });
    libusb_translate.addIncludePath(libusb_dep.path(""));
    libusb_translate.addIncludePath(libusb_dep.path("libusb"));
    if (target.result.os.tag == .windows) {
        libusb_translate.defineCMacro("_FORTIFY_SOURCE", "0");
        libusb_translate.defineCMacro("__MINGW_FORTIFY_LEVEL", "0");
    }
    const c_bindings_mod = libusb_translate.createModule();
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", readPackageVersion(b));

    const mod = b.addModule("pxlobster", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_bindings_mod },
        },
    });

    const resources_mod = b.createModule(.{
        .root_source_file = b.path("resources/firmware.zig"),
        .target = target,
        .optimize = optimize,
    });
    const clap_mod = clap_dep.module("clap");

    const exe = b.addExecutable(.{
        .name = "pxlobster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pxlobster", .module = mod },
                .{ .name = "pxresources", .module = resources_mod },
                .{ .name = "clap", .module = clap_mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    configureLibUsb(b, target, optimize, exe, libusb_dep, libusb_lib_dir, libusb_link_file);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    configureLibUsb(b, target, optimize, mod_tests, libusb_dep, libusb_lib_dir, libusb_link_file);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    configureLibUsb(b, target, optimize, exe_tests, libusb_dep, libusb_lib_dir, libusb_link_file);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const capture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pxlobster", .module = mod },
                .{ .name = "pxresources", .module = resources_mod },
            },
        }),
    });
    configureLibUsb(b, target, optimize, capture_tests, libusb_dep, libusb_lib_dir, libusb_link_file);
    const run_capture_tests = b.addRunArtifact(capture_tests);

    const args_clap_integration = b.addExecutable(.{
        .name = "args_clap_integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/args_it.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap_mod },
                .{ .name = "args", .module = b.createModule(.{
                    .root_source_file = b.path("src/args.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "clap", .module = clap_mod },
                    },
                }) },
            },
        }),
    });
    const run_args_clap_integration = b.addRunArtifact(args_clap_integration);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_capture_tests.step);
    test_step.dependOn(&run_args_clap_integration.step);
}
