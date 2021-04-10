const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const BufferPanel = @import("buffer_panel.zig").BufferPanel;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = &gpa.allocator;

    try editor.init(allocator);
    defer editor.deinit();

    {
        var buffer_panel = try BufferPanel.init(allocator);
        try editor.addPanel(buffer_panel);
    }

    {
        var buffer_panel = try BufferPanel.init(allocator);
        try editor.addPanel(buffer_panel);
    }

    editor.mainLoop();
}
