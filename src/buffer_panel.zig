const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
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

    pub fn init(allocator: *Allocator) !*editor.Panel {
        var self = try allocator.create(BufferPanel);
        self.* = @This(){
            .allocator = allocator,
            .panel = .{ .vt = &VT },
        };
        return &self.panel;
    }

    fn getStatusLine(panel: *editor.Panel, allocator: *Allocator) anyerror![]const u8 {
        return try allocator.dupe(u8, "** unnamed buffer **");
    }

    fn draw(panel: *editor.Panel, rect: renderer.Rect) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
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
