const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Buffer = @import("buffer.zig").Buffer;
const KeyMap = @import("keymap.zig").KeyMap;
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

var normal_key_map: KeyMap = undefined;

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
    panel: editor.Panel = .{ .vt = &VT },
    allocator: *Allocator,
    buffer: *Buffer,
    cursor_line: usize = 0,
    cursor_column: usize = 0,
    scroll_x: util.Animation(f64) = .{},
    scroll_y: util.Animation(f64) = .{},

    pub fn init(allocator: *Allocator, buffer: *Buffer) !*editor.Panel {
        var self = try allocator.create(BufferPanel);
        self.* = @This(){
            .allocator = allocator,
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
        const scroll_y = self.scroll_y.value;
        const line_count = self.buffer.getLineCount();
        if (line_count == 0) return;

        const first_line: isize = @floatToInt(isize, std.math.floor(scroll_y));
        var last_line: isize = @floatToInt(isize, std.math.floor(
            scroll_y + (@intToFloat(f64, rect.h) / @intToFloat(f64, char_height)),
        ));
        if (last_line >= line_count) {
            last_line = @intCast(isize, line_count) - 1;
        }
        last_line = std.math.max(first_line, last_line);

        renderer.setColor(editor.getFace("foreground").color);

        const buffer = self.buffer;
        for (buffer.lines.items) |line, i| {
            const line_y = rect.y - @floatToInt(
                i32,
                std.math.floor(scroll_y * @intToFloat(f64, char_height)),
            ) + (@intCast(i32, i) * char_height);

            _ = try renderer.drawText(
                line.content.items,
                font,
                font_size,
                rect.x,
                line_y,
                .{},
            );
        }

        const cursor_line = self.cursor_line;
        const cursor_line_content = try self.buffer.getLine(cursor_line);
        const cursor_line_length = try std.unicode.utf8CountCodepoints(cursor_line_content);
        const cursor_column = std.math.clamp(
            self.cursor_column,
            0,
            std.math.max(1, cursor_line_length) - 1,
        );

        // Draw cursor
        {
            var cursor_x: i32 = 0;
            const cursor_y = rect.y - @floatToInt(
                i32,
                std.math.floor(scroll_y * @intToFloat(f64, char_height)),
            ) + (@intCast(i32, cursor_line) * char_height);

            const view = try std.unicode.Utf8View.init(cursor_line_content);
            var iter = view.iterator();

            var cursor_codepoint: u32 = ' ';

            var i: usize = 0;
            while (iter.nextCodepoint()) |codepoint| {
                if (i == cursor_column) {
                    cursor_codepoint = codepoint;
                    break;
                }

                var char_advance = try font.getCharAdvance(font_size, codepoint);
                if (codepoint == '\t') {
                    char_advance *= @intCast(i32, options.tab_width);
                }
                cursor_x += char_advance;
                i += 1;
            }

            renderer.setColor(editor.getFace("foreground").color);
            try renderer.drawRect(.{
                .w = try font.getCharAdvance(font_size, ' '),
                .h = char_height,
                .x = cursor_x,
                .y = cursor_y,
            });

            switch (cursor_codepoint) {
                '\t', '\n', '\r' => {},
                else => {
                    renderer.setColor(editor.getFace("background").color);
                    _ = try renderer.drawCodepoint(
                        cursor_codepoint,
                        font,
                        font_size,
                        cursor_x,
                        cursor_y,
                    );
                },
            }
        }
    }

    fn deinit(panel: *editor.Panel) void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.allocator.destroy(self);
    }

    fn onKey(panel: *editor.Panel, key: renderer.Key, mods: u32) anyerror!void {
        _ = try normal_key_map.onKey(key, mods, panel);
    }

    fn onChar(panel: *editor.Panel, codepoint: u32) anyerror!void {
        _ = try normal_key_map.onChar(codepoint, panel);
    }

    fn onScroll(panel: *editor.Panel, dx: f64, dy: f64) anyerror!void {
        // std.log.info("scroll: {} {}", .{ dx, dy });
    }

    fn normalMoveLeft(count: ?i32, object: ?u32, user_data: ?*c_void) anyerror!void {
        var self = util.fromVoidPtr(*BufferPanel, user_data.?);
        if (self.cursor_column > 0) {
            self.cursor_column -= 1;
        }
    }

    fn normalMoveRight(count: ?i32, object: ?u32, user_data: ?*c_void) anyerror!void {
        var self = util.fromVoidPtr(*BufferPanel, user_data.?);
        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        if ((self.cursor_column + 1) < line_length) {
            self.cursor_column += 1;
        }
    }

    fn normalMoveUp(count: ?i32, object: ?u32, user_data: ?*c_void) anyerror!void {
        var self = util.fromVoidPtr(*BufferPanel, user_data.?);
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
        }
    }

    fn normalMoveDown(count: ?i32, object: ?u32, user_data: ?*c_void) anyerror!void {
        var self = util.fromVoidPtr(*BufferPanel, user_data.?);
        if ((self.cursor_line + 1) < self.buffer.getLineCount()) {
            self.cursor_line += 1;
        }
    }

    fn registerVT(allocator: *Allocator) anyerror!void {
        normal_key_map = try KeyMap.init(allocator);

        try normal_key_map.bind("h", normalMoveLeft);
        try normal_key_map.bind("l", normalMoveRight);
        try normal_key_map.bind("j", normalMoveDown);
        try normal_key_map.bind("k", normalMoveUp);
    }

    fn unregisterVT() void {
        normal_key_map.deinit();
    }
};
