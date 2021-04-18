const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const BufferPanel = @import("buffer_panel.zig").BufferPanel;
const Buffer = @import("buffer.zig").Buffer;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = &gpa.allocator;

    try editor.init(allocator);
    defer editor.deinit();

    // var buffer = try Buffer.initWithContent(allocator, 
    //     \\hello world
    //     \\yo
    //     \\second line
    //     \\
    //     \\	olá mundo -- em português
    //     );

    var buffer = try Buffer.initFromFile(allocator, "~/downloads/s7.c");

    // var buffer = try Buffer.init(allocator, "abc");
    defer buffer.deinit();

    {
        var buffer_panel = try BufferPanel.init(allocator, buffer);
        try editor.addPanel(buffer_panel);
    }

    {
        var buffer_panel = try BufferPanel.init(allocator, buffer);
        try editor.addPanel(buffer_panel);
    }

    editor.mainLoop();
}
