const std = @import("std");
const renderer = @import("opengl_renderer.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = &gpa.allocator;

    try renderer.init(allocator);
    defer renderer.deinit();

    var main_font = try renderer.Font.init("monospace", "");
    defer main_font.deinit();

    while (!renderer.shouldClose()) {
        renderer.beginFrame() catch unreachable;
        defer renderer.endFrame() catch unreachable;

        renderer.setColor(renderer.Color{ 255, 0, 0 });
        try renderer.drawRect(.{
            .x = 0,
            .y = 0,
            .w = 100,
            .h = 100,
        });
        renderer.setColor(renderer.Color{ 0, 255, 0 });
        _ = try renderer.drawCodepoint('l', main_font, 32, 0, 0);
    }
}
