const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const BufferPanel = @import("buffer_panel.zig").BufferPanel;
const Buffer = @import("buffer.zig").Buffer;
const args_parser = @import("args.zig");

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
    const options = try args_parser.parseForCurrentProcess(struct {}, allocator);
    defer options.deinit();

    if (options.positionals.len > 0) {
        for (options.positionals) |path| {
            const buffer = editor.addBufferFromFile(path) catch |err| {
                std.log.err("Failed to open buffer: \"{s}\": {}", .{ path, err });
                continue;
            };
            try editor.addPanel(try BufferPanel.init(allocator, buffer));
        }
    }

    editor.mainLoop();
}

