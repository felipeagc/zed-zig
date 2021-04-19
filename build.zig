const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zed", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    exe.linkLibC();
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("epoxy");
    exe.linkSystemLibrary("oniguruma");
    exe.linkSystemLibrary("fontconfig");
    exe.linkSystemLibrary("freetype");

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
    };
    for (tests) |test_| {
        test_.linkLibC();
        test_.setBuildMode(mode);
        test_.linkSystemLibrary("glfw");
        test_.linkSystemLibrary("epoxy");
        test_.linkSystemLibrary("oniguruma");
        test_.linkSystemLibrary("fontconfig");
        test_.linkSystemLibrary("freetype");
        test_step.dependOn(&test_.step);
    }
}
