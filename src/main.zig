const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = &gpa.allocator;

    try renderer.init(allocator);
    defer renderer.deinit();

    try editor.init(allocator);
    defer editor.deinit();

    while (!renderer.shouldClose()) {
        renderer.beginFrame() catch unreachable;
        defer renderer.endFrame() catch unreachable;

        const options = editor.getOptions();

        var window_width: i32 = undefined;
        var window_height: i32 = undefined;
        try renderer.getWindowSize(&window_width, &window_height);

        renderer.setColor(editor.getFace("background").color);
        try renderer.drawRect(renderer.Rect{
            .x = 0,
            .y = 0,
            .w = window_width,
            .h = window_height,
        });

        renderer.setColor(editor.getFace("foreground").color);

        _ = try renderer.drawText(
            "hello world",
            options.main_font,
            options.main_font_size,
            0,
            0,
            .{},
        );
    }
}
