const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("GL/gl.h");
});

const WindowSystem = @import("common.zig").WindowSystem;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var window_system = try WindowSystem.init(allocator);
    defer window_system.deinit();

    var window = try window_system.createWindow(800, 600, .{
        .opengl = true,
    });
    defer window.deinit();
    // var window2 = try WaylandWindow.init(window_system, 800, 600);

    while (!window.shouldClose()) {
        while (window_system.nextEvent()) |event| {
            std.log.info("{}", .{event});
        }

        window.glMakeContextCurrent();
        window_system.glSwapInterval(1);

        c.glClearColor(0.0, 1.0, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        window.glSwapBuffers();

        // try window_system.pollEvents();
        try window_system.waitEvents(null);
    }
}
