const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const BufferPanel = @import("buffer_panel.zig").BufferPanel;
const Buffer = @import("buffer.zig").Buffer;

const GlobalAllocator = struct {
    const Internal = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}) else struct {};

    internal: Internal = Internal{},

    fn deinit(self: *@This()) void {
        if (builtin.mode == .Debug) {
            _ = self.internal.deinit();
        }
    }

    fn getAllocator(self: *@This()) *std.mem.Allocator {
        if (builtin.mode == .Debug) {
            return &self.internal.allocator;
        } else {
            return std.heap.c_allocator;
        }
    }
};

pub fn main() anyerror!void {
    var global_allocator = GlobalAllocator{};
    defer global_allocator.deinit();

    const allocator = global_allocator.getAllocator();

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
