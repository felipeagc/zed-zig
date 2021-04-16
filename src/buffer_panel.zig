const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Buffer = @import("buffer.zig").Buffer;
const KeyMap = @import("keymap.zig").KeyMap;
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

const Mode = enum {
    normal,
    insert,
    visual,
};

var normal_key_map: KeyMap = undefined;
var insert_key_map: KeyMap = undefined;
var visual_key_map: KeyMap = undefined;

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
    mode: Mode = .normal,
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
            try self.getModeMaxCol(),
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
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        var map = switch (self.mode) {
            .normal => normal_key_map,
            .insert => insert_key_map,
            .visual => visual_key_map,
        };

        _ = try map.onKey(key, mods, panel);
    }

    fn onChar(panel: *editor.Panel, codepoint: u32) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        switch (self.mode) {
            .normal => {
                _ = try normal_key_map.onChar(codepoint, panel);
            },
            .visual => {
                _ = try visual_key_map.onChar(codepoint, panel);
            },
            .insert => {
                var buf = [4]u8{ 0, 0, 0, 0 };
                const len = try std.unicode.utf8Encode(@intCast(u21, codepoint), &buf);
                try self.buffer.insert(buf[0..len], self.cursor_line, self.cursor_column);
                self.cursor_column += 1;

                try self.fixupCursor();
            },
        }
    }

    fn onScroll(panel: *editor.Panel, dx: f64, dy: f64) anyerror!void {
        // std.log.info("scroll: {} {}", .{ dx, dy });
    }

    fn normalMoveLeft(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        if (self.cursor_column > 0) {
            self.cursor_column -= 1;
        }

        try self.fixupCursor();
    }

    fn normalMoveRight(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        if ((self.cursor_column + 1) < line_length) {
            self.cursor_column += 1;
        }

        try self.fixupCursor();
    }

    fn normalMoveUp(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
        }
    }

    fn normalMoveDown(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if ((self.cursor_line + 1) < self.buffer.getLineCount()) {
            self.cursor_line += 1;
        }
    }

    fn normalModeDeleteChar(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        try self.buffer.delete(self.cursor_line, self.cursor_column, 1);
    }

    fn normalModeDeleteCharBefore(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        if (self.cursor_column > 0) {
            try self.buffer.delete(self.cursor_line, self.cursor_column - 1, 1);
            self.cursor_column -= 1;

            try self.fixupCursor();
        }
    }

    fn normalModeDeleteLine(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        if (self.cursor_line == 0) {
            try self.buffer.delete(self.cursor_line, 0, line_length + 1);
        } else {
            const prev_line = try self.buffer.getLine(self.cursor_line - 1);
            const prev_line_length = try std.unicode.utf8CountCodepoints(prev_line);
            try self.buffer.delete(self.cursor_line - 1, prev_line_length, line_length + 1);
        }

        const line_count = self.buffer.getLineCount();
        const max_line = if (line_count > 0) (line_count - 1) else 0;
        self.cursor_line = std.math.clamp(self.cursor_line, 0, max_line);
    }

    fn normalModeJoinLines(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        try self.buffer.delete(self.cursor_line, line_length, 1); // delete newline
        try self.buffer.insert(" ", self.cursor_line, line_length); // insert space

        self.cursor_column = line_length;
        try self.fixupCursor();
    }

    fn enterInsertMode(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        try self.fixupCursor();
    }

    fn enterInsertModeEndOfLine(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        self.cursor_column = try self.getModeMaxCol();
        try self.fixupCursor();
    }

    fn enterInsertModeBeginningOfLine(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        self.cursor_column = 0;
        try self.fixupCursor();
    }

    fn enterInsertModeNextLine(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        try self.buffer.insert("\n", self.cursor_line, line_length);

        self.mode = .insert;
        self.cursor_column = 0;
        self.cursor_line += 1;
        try self.fixupCursor();
    }

    fn enterInsertModePrevLine(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.buffer.insert("\n", self.cursor_line, 0);

        self.mode = .insert;
        self.cursor_column = 0;
        try self.fixupCursor();
    }

    fn exitInsertMode(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .normal;

        try self.fixupCursor();
    }

    fn getModeMaxCol(self: *BufferPanel) !usize {
        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        return switch (self.mode) {
            .insert => line_length,
            .normal, .visual => if (line_length > 0) (line_length - 1) else 0,
        };
    }

    fn fixupCursor(self: *BufferPanel) !void {
        const max_col = try self.getModeMaxCol();
        self.cursor_column = std.math.clamp(self.cursor_column, 0, max_col);
    }

    fn insertModeMoveRight(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        const line_count = self.buffer.getLineCount();
        const line = try self.buffer.getLine(self.cursor_line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        self.cursor_column += 1;
        if (self.cursor_column > line_length and (self.cursor_line + 1) < line_count) {
            self.cursor_column = 0;
            self.cursor_line += 1;
        }

        try self.fixupCursor();
    }

    fn insertModeMoveLeft(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        if (self.cursor_column == 0) {
            if (self.cursor_line > 0) {
                self.cursor_line -= 1;
                const line = try self.buffer.getLine(self.cursor_line);
                const line_length = try std.unicode.utf8CountCodepoints(line);
                self.cursor_column = line_length;
            }
        } else {
            self.cursor_column -= 1;
        }

        try self.fixupCursor();
    }

    fn insertModeMoveUp(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
        }
    }

    fn insertModeMoveDown(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if ((self.cursor_line + 1) < self.buffer.getLineCount()) {
            self.cursor_line += 1;
        }
    }

    fn insertModeBackspace(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (!(self.cursor_column == 0 and self.cursor_line == 0)) {
            try insertModeMoveLeft(panel, &[_]u8{}, 1);
            try self.buffer.delete(self.cursor_line, self.cursor_column, 1);
        }
    }

    fn insertModeInsertNewLine(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.buffer.insert("\n", self.cursor_line, self.cursor_column);
        try insertModeMoveRight(panel, &[_]u8{}, 1);
    }

    fn pasteAfter(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const clipboard_content = (try renderer.getClipboardString(self.allocator)) orelse return;
        defer self.allocator.free(clipboard_content);

        const content_codepoint_count = try std.unicode.utf8CountCodepoints(clipboard_content);
        if (content_codepoint_count == 0) return;

        if (clipboard_content[clipboard_content.len - 1] == '\n') {
            const line = try self.buffer.getLine(self.cursor_line);
            const line_length = try std.unicode.utf8CountCodepoints(line);
            try self.buffer.insert("\n", self.cursor_line, line_length);
            try self.buffer.insert(clipboard_content[0 .. clipboard_content.len - 1], self.cursor_line + 1, 0);
            self.cursor_line += 1;
            self.cursor_column = 0;
        } else {
            try self.buffer.insert(clipboard_content, self.cursor_line, self.cursor_column + 1);
            self.cursor_column += content_codepoint_count;
        }

        try self.fixupCursor();
    }

    fn pasteBefore(panel: *editor.Panel, args: []const u8, count: i64) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        const clipboard_content = (try renderer.getClipboardString(self.allocator)) orelse return;
        defer self.allocator.free(clipboard_content);

        const content_codepoint_count = try std.unicode.utf8CountCodepoints(clipboard_content);
        if (content_codepoint_count == 0) return;

        if (clipboard_content[clipboard_content.len - 1] == '\n') {
            try self.buffer.insert(clipboard_content, self.cursor_line, 0);
            self.cursor_column = 0;
        } else {
            try self.buffer.insert(clipboard_content, self.cursor_line, self.cursor_column);
            self.cursor_column += (content_codepoint_count - 1);
        }

        try self.fixupCursor();
    }

    fn registerVT(allocator: *Allocator) anyerror!void {
        normal_key_map = try KeyMap.init(allocator);
        insert_key_map = try KeyMap.init(allocator);
        visual_key_map = try KeyMap.init(allocator);

        try normal_key_map.bind("h", normalMoveLeft);
        try normal_key_map.bind("l", normalMoveRight);
        try normal_key_map.bind("j", normalMoveDown);
        try normal_key_map.bind("k", normalMoveUp);
        try normal_key_map.bind("<left>", normalMoveLeft);
        try normal_key_map.bind("<right>", normalMoveRight);
        try normal_key_map.bind("<down>", normalMoveDown);
        try normal_key_map.bind("<up>", normalMoveUp);

        try normal_key_map.bind("x", normalModeDeleteChar);
        try normal_key_map.bind("X", normalModeDeleteCharBefore);
        try normal_key_map.bind("d d", normalModeDeleteLine);
        try normal_key_map.bind("J", normalModeJoinLines);
        try normal_key_map.bind("i", enterInsertMode);
        try normal_key_map.bind("I", enterInsertModeBeginningOfLine);
        try normal_key_map.bind("A", enterInsertModeEndOfLine);
        try normal_key_map.bind("o", enterInsertModeNextLine);
        try normal_key_map.bind("O", enterInsertModePrevLine);
        try normal_key_map.bind("p", pasteAfter);
        try normal_key_map.bind("P", pasteBefore);

        try insert_key_map.bind("<esc>", exitInsertMode);
        try insert_key_map.bind("<left>", insertModeMoveLeft);
        try insert_key_map.bind("<right>", insertModeMoveRight);
        try insert_key_map.bind("<up>", insertModeMoveUp);
        try insert_key_map.bind("<down>", insertModeMoveDown);
        try insert_key_map.bind("<backspace>", insertModeBackspace);
        try insert_key_map.bind("<enter>", insertModeInsertNewLine);
    }

    fn unregisterVT() void {
        visual_key_map.deinit();
        insert_key_map.deinit();
        normal_key_map.deinit();
    }
};
