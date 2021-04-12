const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Buffer = @import("buffer.zig").Buffer;
const Allocator = std.mem.Allocator;

pub const VT = editor.PanelVT{
    .name = "buffer",

    .draw = BufferPanel.draw,
    .get_status_line = BufferPanel.getStatusLine,
    .deinit = BufferPanel.deinit,

    .on_key = BufferPanel.onKey,
    .on_char = BufferPanel.onChar,
    .on_scroll = BufferPanel.onScroll,

    .register_vt = BufferPanel.registerVT,
    .unregister_vt = BufferPanel.unregisterVT,
};

pub const BufferPanel = struct {
    panel: editor.Panel,
    allocator: *Allocator,
    buffer: *Buffer,

    pub fn init(allocator: *Allocator, buffer: *Buffer) !*editor.Panel {
        var self = try allocator.create(BufferPanel);
        self.* = @This(){
            .allocator = allocator,
            .panel = .{ .vt = &VT },
            .buffer = buffer,
        };
        return &self.panel;
    }

    fn getStatusLine(panel: *editor.Panel, allocator: *Allocator) anyerror![]const u8 {
        return try allocator.dupe(u8, "** unnamed buffer **");
    }

    fn draw(panel: *editor.Panel, rect: renderer.Rect) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const options = editor.getOptions();
        const font = options.main_font;
        const font_size = options.main_font_size;
        const char_height = font.getCharHeight(font_size);

        renderer.setColor(editor.getFace("foreground").color);

        const buffer = self.buffer;
        for (buffer.lines.items) |line, i| {
            _ = try renderer.drawText(
                line.content.items,
                font,
                font_size,
                rect.x,
                rect.y + (@intCast(i32, i) * char_height),
                .{},
            );
        }
    }

    fn deinit(panel: *editor.Panel) void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.allocator.destroy(self);
    }

    fn onKey(panel: *editor.Panel, key: renderer.Key, mods: u32) anyerror!void {
        // std.log.info("key: {s}", .{@tagName(key)});
    }

    fn onChar(panel: *editor.Panel, codepoint: u32) anyerror!void {
        // std.log.info("codepoint: {}", .{codepoint});
    }

    fn onScroll(panel: *editor.Panel, dx: f64, dy: f64) anyerror!void {
        // std.log.info("scroll: {} {}", .{ dx, dy });
    }

    fn registerVT() anyerror!void {}

    fn unregisterVT() void {}
};
