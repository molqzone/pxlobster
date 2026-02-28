const std = @import("std");

fn configureLibUsb(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    libusb_lib_dir: ?[]const u8,
    libusb_link_file: ?[]const u8,
) void {
    if (b.lazyDependency("libusb", .{})) |libusb_dep| {
        artifact.addIncludePath(libusb_dep.path(""));
        artifact.addIncludePath(libusb_dep.path("libusb"));
    }

    artifact.linkLibC();

    if (libusb_lib_dir) |lib_dir| {
        artifact.addLibraryPath(.{ .cwd_relative = lib_dir });
    }

    if (libusb_link_file) |link_file| {
        artifact.addObjectFile(.{ .cwd_relative = link_file });
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

    const mod = b.addModule("pxlobster", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const resources_mod = b.createModule(.{
        .root_source_file = b.path("resources/firmware.zig"),
        .target = target,
        .optimize = optimize,
    });
    const clap_dep = b.dependency("clap", .{});

    const exe = b.addExecutable(.{
        .name = "pxlobster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pxlobster", .module = mod },
                .{ .name = "pxresources", .module = resources_mod },
                .{ .name = "clap", .module = clap_dep.module("clap") },
            },
        }),
    });
    configureLibUsb(b, exe, libusb_lib_dir, libusb_link_file);

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
    configureLibUsb(b, mod_tests, libusb_lib_dir, libusb_link_file);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    configureLibUsb(b, exe_tests, libusb_lib_dir, libusb_link_file);

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
    configureLibUsb(b, capture_tests, libusb_lib_dir, libusb_link_file);
    const run_capture_tests = b.addRunArtifact(capture_tests);

    const args_clap_integration = b.addExecutable(.{
        .name = "args_clap_integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/args_it.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap_dep.module("clap") },
                .{ .name = "args", .module = b.createModule(.{
                    .root_source_file = b.path("src/args.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "clap", .module = clap_dep.module("clap") },
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
