const std = @import("std");
const ScanProtocolsStep = @import("window/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const scanner = ScanProtocolsStep.create(b);
    const wayland = std.build.Pkg{
        .name = "wayland",
        .source = .{ .generated = &scanner.result },
    };

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");

    scanner.generate("wl_seat", 7);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("zxdg_decoration_manager_v1", 1);

    const exe = b.addExecutable("zed", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    exe.linkLibC();

    exe.linkSystemLibrary("oniguruma");
    exe.linkSystemLibrary("freetype");

    if (target.getOsTag() == .linux) {
        scanner.addCSource(exe);
        exe.step.dependOn(&scanner.step);
        exe.addPackage(wayland);

        exe.linkSystemLibrary("wayland-client");
        exe.linkSystemLibrary("wayland-egl");
        exe.linkSystemLibrary("wayland-cursor");
        exe.linkSystemLibrary("xkbcommon");
        exe.linkSystemLibrary("epoxy");
        exe.linkSystemLibrary("fontconfig");
    }

    exe.addPackage(std.build.Pkg{
        .name = "window",
        .source = .{.path = "./window/common.zig"},
        .dependencies = &.{
            wayland,
        },
    });

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");

    const tests = [_]*std.build.LibExeObjStep{
        b.addTest("src/buffer.zig"),
        b.addTest("src/minibuffer.zig"),
        b.addTest("src/highlighter.zig"),
    };
    for (tests) |test_| {
        test_.linkLibC();
        test_.setBuildMode(mode);
        test_.linkSystemLibrary("epoxy");
        test_.linkSystemLibrary("oniguruma");
        test_.linkSystemLibrary("fontconfig");
        test_.linkSystemLibrary("freetype");
        test_step.dependOn(&test_.step);
    }
}
