const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Buffer = @import("buffer.zig").Buffer;
const KeyMap = @import("keymap.zig").KeyMap;
const util = @import("util.zig");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
};

const CharClass = enum {
    whitespace,
    alphanum,
    other,
};

fn codepointToCharClass(codepoint: u32) CharClass {
    return if (codepoint > 0x07f)
        CharClass.alphanum
    else switch (codepoint) {
        'a'...'z' => CharClass.alphanum,
        'A'...'Z' => CharClass.alphanum,
        '0'...'1' => CharClass.alphanum,
        '_' => CharClass.alphanum,
        ' ', '\n', '\r', '\t' => CharClass.whitespace,
        else => CharClass.other,
    };
}

const WordIterator = struct {
    text: []const u8,
    pos: usize = 0,
    codepoint_pos: usize = 0,

    const Word = struct {
        text: []const u8,
        codepoint_start_pos: usize,
        codepoint_length: usize,
        class: CharClass,
    };

    fn init(text: []const u8) !WordIterator {
        return WordIterator{
            .text = text,
        };
    }

    fn nextWord(self: *WordIterator) ?Word {
        if (self.pos >= self.text.len) return null;

        const start_pos = self.pos;
        const codepoint_start_pos = self.codepoint_pos;

        var codepoint_length: usize = 0;
        var byte_length: usize = 0;
        var char_class: CharClass = undefined;

        var iter = std.unicode.Utf8Iterator{
            .bytes = self.text[self.pos..],
            .i = 0,
        };
        while (iter.nextCodepointSlice()) |codepoint_slice| {
            const codepoint = std.unicode.utf8Decode(codepoint_slice) catch unreachable;
            const current_char_class = codepointToCharClass(codepoint);
            if (codepoint_length == 0) char_class = current_char_class;

            if (char_class != current_char_class) {
                break;
            }

            codepoint_length += 1;
            byte_length += codepoint_slice.len;
        }

        self.pos += byte_length;
        self.codepoint_pos += codepoint_length;
        return Word{
            .text = self.text[start_pos..self.pos],
            .codepoint_start_pos = codepoint_start_pos,
            .codepoint_length = codepoint_length,
            .class = char_class,
        };
    }
};

var normal_key_map: KeyMap = undefined;
var insert_key_map: KeyMap = undefined;
var visual_key_map: KeyMap = undefined;
var visual_line_key_map: KeyMap = undefined;

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

const Position = struct {
    line: usize = 0,
    column: usize = 0,
};

pub const BufferPanel = struct {
    panel: editor.Panel = .{ .vt = &VT },
    allocator: *Allocator,
    buffer: *Buffer,
    mode: Mode = .normal,
    cursor: Position = .{},
    mark: Position = .{},
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

    fn getFixedCursorPos(self: *BufferPanel) !Position {
        const line_count = self.buffer.getLineCount();
        const max_line = if (line_count > 0) (line_count - 1) else 0;
        const line = std.math.clamp(self.cursor.line, 0, max_line);

        const max_col = try self.getModeMaxCol(line);
        const column = std.math.clamp(self.cursor.column, 0, max_col);

        return Position{
            .line = line,
            .column = column,
        };
    }

    fn fixupCursor(self: *BufferPanel) !void {
        self.cursor = try self.getFixedCursorPos();
    }

    fn getStatusLine(panel: *editor.Panel, allocator: *Allocator) anyerror![]const u8 {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const buffer_name = "** unnamed buffer **";

        const cursor_pos = try self.getFixedCursorPos();
        const mode_name = switch (self.mode) {
            .normal => "[N]",
            .insert => "[I]",
            .visual => "[V]",
            .visual_line => "[V]",
        };

        return try std.fmt.allocPrint(allocator, "{s} {s} L#{} C#{}", .{
            mode_name,
            buffer_name,
            cursor_pos.line,
            cursor_pos.column,
        });
    }

    fn beginCheckpoint(self: *BufferPanel) void {
        self.buffer.beginCheckpoint(self.cursor.line, self.cursor.column) catch |err| {
            std.log.warn("could not insert begin checkpoint: {}", .{err});
        };
    }

    fn endCheckpoint(self: *BufferPanel) void {
        self.buffer.endCheckpoint(self.cursor.line, self.cursor.column) catch |err| {
            std.log.warn("could not insert end checkpoint: {}", .{err});
        };
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

        const cursor_line = self.cursor.line;
        const cursor_line_content = try self.buffer.getLine(cursor_line);
        const cursor_line_length = try std.unicode.utf8CountCodepoints(cursor_line_content);
        const cursor_column = std.math.clamp(
            self.cursor.column,
            0,
            try self.getModeMaxCol(self.cursor.line),
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
            var cursor_width = try font.getCharAdvance(font_size, ' ');
            if (self.mode == .insert) {
                cursor_width = @divTrunc(cursor_width, 5);
            }

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
                .w = cursor_width,
                .h = char_height,
                .x = cursor_x,
                .y = cursor_y,
            });

            if (self.mode != .insert) {
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
            .visual_line => visual_line_key_map,
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
            .visual_line => {
                _ = try visual_line_key_map.onChar(codepoint, panel);
            },
            .insert => {
                var buf = [4]u8{ 0, 0, 0, 0 };
                const len = try std.unicode.utf8Encode(@intCast(u21, codepoint), &buf);
                try self.buffer.insert(buf[0..len], self.cursor.line, self.cursor.column);
                self.cursor.column += 1;

                try self.fixupCursor();
            },
        }
    }

    fn onScroll(panel: *editor.Panel, dx: f64, dy: f64) anyerror!void {
        // std.log.info("scroll: {} {}", .{ dx, dy });
    }

    fn normalMoveLeft(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        if (self.cursor.column > 0) {
            self.cursor.column -= 1;
        }

        try self.fixupCursor();
    }

    fn normalMoveRight(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        if ((self.cursor.column + 1) < line_length) {
            self.cursor.column += 1;
        }

        try self.fixupCursor();
    }

    fn normalMoveUp(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (self.cursor.line > 0) {
            self.cursor.line -= 1;
        }
    }

    fn normalMoveDown(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if ((self.cursor.line + 1) < self.buffer.getLineCount()) {
            self.cursor.line += 1;
        }
    }

    fn normalMoveToTop(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.line = 0;
    }

    fn normalMoveToBottom(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.line = self.buffer.getLineCount() - 1;
    }

    fn normalMoveToLineStart(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.column = 0;
    }

    fn normalMoveToLineEnd(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        self.cursor.column = line_length - 1;
    }

    fn normalModeDeleteChar(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.fixupCursor();

        const line = try self.buffer.getLine(self.cursor.line);
        if ((try std.unicode.utf8CountCodepoints(line)) == 0) return;

        const content = try self.buffer.getContent(self.allocator, self.cursor.line, self.cursor.column, 1);
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        try self.buffer.delete(self.cursor.line, self.cursor.column, 1);
    }

    fn normalModeDeleteCharBefore(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.fixupCursor();

        if (self.cursor.column > 0) {
            const content = try self.buffer.getContent(self.allocator, self.cursor.line, self.cursor.column - 1, 1);
            defer self.allocator.free(content);
            try renderer.setClipboardString(content);
            try self.buffer.delete(self.cursor.line, self.cursor.column - 1, 1);

            self.cursor.column -= 1;

            try self.fixupCursor();
        }
    }

    fn normalModeDeleteLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        const content = try self.buffer.getContent(self.allocator, self.cursor.line, 0, line_length + 1);
        defer self.allocator.free(content);

        if (self.cursor.line == 0) {
            try self.buffer.delete(self.cursor.line, 0, line_length + 1);
        } else {
            const prev_line = try self.buffer.getLine(self.cursor.line - 1);
            const prev_line_length = try std.unicode.utf8CountCodepoints(prev_line);
            try self.buffer.delete(self.cursor.line - 1, prev_line_length, line_length + 1);
        }

        try renderer.setClipboardString(content);

        const line_count = self.buffer.getLineCount();
        const max_line = if (line_count > 0) (line_count - 1) else 0;
        self.cursor.line = std.math.clamp(self.cursor.line, 0, max_line);
    }

    fn normalModeJoinLines(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        try self.buffer.delete(self.cursor.line, line_length, 1); // delete newline
        try self.buffer.insert(" ", self.cursor.line, line_length); // insert space

        self.cursor.column = line_length;
        try self.fixupCursor();
    }

    fn enterInsertModeBefore(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        self.beginCheckpoint();

        try self.fixupCursor();
    }

    fn enterInsertModeAfter(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        self.beginCheckpoint();

        self.cursor.column += 1;
        try self.fixupCursor();
    }

    fn enterInsertModeEndOfLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        self.beginCheckpoint();

        self.cursor.column = try self.getModeMaxCol(self.cursor.line);
        try self.fixupCursor();
    }

    fn enterInsertModeBeginningOfLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .insert;

        self.beginCheckpoint();

        self.cursor.column = 0;
        try self.fixupCursor();
    }

    fn enterInsertModeNextLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        try self.buffer.insert("\n", self.cursor.line, line_length);

        self.mode = .insert;
        self.cursor.column = 0;
        self.cursor.line += 1;
        try self.fixupCursor();
    }

    fn enterInsertModePrevLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();

        try self.buffer.insert("\n", self.cursor.line, 0);

        self.mode = .insert;
        self.cursor.column = 0;
        try self.fixupCursor();
    }

    fn exitInsertMode(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .normal;

        if (self.cursor.column > 0) {
            self.cursor.column -= 1;
        }
        try self.fixupCursor();

        self.endCheckpoint();
    }

    fn getModeMaxCol(self: *BufferPanel, line_index: usize) !usize {
        const line = try self.buffer.getLine(line_index);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        return switch (self.mode) {
            .insert => line_length,
            .normal,
            .visual,
            .visual_line,
            => if (line_length > 0) (line_length - 1) else 0,
        };
    }

    fn insertModeMoveRight(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        const line_count = self.buffer.getLineCount();
        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        self.cursor.column += 1;
        if (self.cursor.column > line_length and (self.cursor.line + 1) < line_count) {
            self.cursor.column = 0;
            self.cursor.line += 1;
        }

        try self.fixupCursor();
    }

    fn insertModeMoveLeft(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        if (self.cursor.column == 0) {
            if (self.cursor.line > 0) {
                self.cursor.line -= 1;
                const line = try self.buffer.getLine(self.cursor.line);
                const line_length = try std.unicode.utf8CountCodepoints(line);
                self.cursor.column = line_length;
            }
        } else {
            self.cursor.column -= 1;
        }

        try self.fixupCursor();
    }

    fn insertModeMoveUp(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (self.cursor.line > 0) {
            self.cursor.line -= 1;
        }
    }

    fn insertModeMoveDown(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if ((self.cursor.line + 1) < self.buffer.getLineCount()) {
            self.cursor.line += 1;
        }
    }

    fn insertModeBackspace(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (!(self.cursor.column == 0 and self.cursor.line == 0)) {
            try insertModeMoveLeft(panel, &[_]u8{});
            const first_content = try self.buffer.getContent(self.allocator, self.cursor.line, self.cursor.column, 1);
            defer self.allocator.free(first_content);
            try self.buffer.delete(self.cursor.line, self.cursor.column, 1);

            if (mem.eql(u8, first_content, " ")) {
                while (self.cursor.column > 0 and self.cursor.column % editor.getOptions().tab_width != 0) {
                    const content = try self.buffer.getContent(self.allocator, self.cursor.line, self.cursor.column - 1, 1);
                    defer self.allocator.free(content);
                    if (!mem.eql(u8, content, " ")) {
                        break;
                    }

                    try insertModeMoveLeft(panel, &[_]u8{});
                    try self.buffer.delete(self.cursor.line, self.cursor.column, 1);
                }
            }
        }
    }

    fn insertModeInsertNewLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.buffer.insert("\n", self.cursor.line, self.cursor.column);
        try insertModeMoveRight(panel, &[_]u8{});
    }

    fn insertModeInsertTab(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (editor.getOptions().expandtab) {
            const tab_width = editor.getOptions().tab_width;
            const spaces = tab_width - (@intCast(u32, self.cursor.column) % 4);

            var i: u32 = 0;
            while (i < spaces) : (i += 1) {
                try self.buffer.insert(" ", self.cursor.line, self.cursor.column);
                try insertModeMoveRight(panel, &[_]u8{});
            }
        } else {
            try self.buffer.insert("\t", self.cursor.line, self.cursor.column);
            try insertModeMoveRight(panel, &[_]u8{});
        }
    }

    fn pasteAfter(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const clipboard_content = (try renderer.getClipboardString(self.allocator)) orelse return;
        defer self.allocator.free(clipboard_content);

        const content_codepoint_count = try std.unicode.utf8CountCodepoints(clipboard_content);
        if (content_codepoint_count == 0) return;

        if (clipboard_content[clipboard_content.len - 1] == '\n') {
            const line = try self.buffer.getLine(self.cursor.line);
            const line_length = try std.unicode.utf8CountCodepoints(line);
            try self.buffer.insert("\n", self.cursor.line, line_length);
            try self.buffer.insert(clipboard_content[0 .. clipboard_content.len - 1], self.cursor.line + 1, 0);
            self.cursor.line += 1;
            self.cursor.column = 0;
        } else {
            try self.buffer.insert(clipboard_content, self.cursor.line, self.cursor.column + 1);
            self.cursor.column += content_codepoint_count;
        }

        try self.fixupCursor();
    }

    fn pasteBefore(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const clipboard_content = (try renderer.getClipboardString(self.allocator)) orelse return;
        defer self.allocator.free(clipboard_content);

        const content_codepoint_count = try std.unicode.utf8CountCodepoints(clipboard_content);
        if (content_codepoint_count == 0) return;

        if (clipboard_content[clipboard_content.len - 1] == '\n') {
            try self.buffer.insert(clipboard_content, self.cursor.line, 0);
            self.cursor.column = 0;
        } else {
            try self.buffer.insert(clipboard_content, self.cursor.line, self.cursor.column);
            self.cursor.column += (content_codepoint_count - 1);
        }

        try self.fixupCursor();
    }

    fn yankLine(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        const content = try self.buffer.getContent(self.allocator, self.cursor.line, 0, line_length + 1);
        defer self.allocator.free(content);

        try renderer.setClipboardString(content);
    }

    fn enterVisualMode(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .visual;
        try self.fixupCursor();

        self.mark = self.cursor;
    }

    fn enterVisualLineMode(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .visual_line;
        try self.fixupCursor();

        self.mark = self.cursor;
    }

    fn exitVisualMode(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .normal;
        try self.fixupCursor();
    }

    fn exitVisualLineMode(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .normal;
        try self.fixupCursor();
    }

    fn getNextWordStart(self: *BufferPanel, cursor: Position, out_line: *usize) !?WordIterator.Word {
        var line_index: usize = cursor.line;
        while (line_index < self.buffer.getLineCount()) : (line_index += 1) {
            const line = try self.buffer.getLine(line_index);

            var iter = try WordIterator.init(line);
            while (iter.nextWord()) |word| {
                if ((line_index != cursor.line or word.codepoint_start_pos > cursor.column) and word.class != .whitespace) {
                    out_line.* = line_index;
                    return word;
                }
            }
        }

        return null;
    }

    fn getNextWordEnd(self: *BufferPanel, cursor: Position, out_line: *usize) !?WordIterator.Word {
        var line_index: usize = cursor.line;
        while (line_index < self.buffer.getLineCount()) : (line_index += 1) {
            const line = try self.buffer.getLine(line_index);

            var iter = try WordIterator.init(line);
            while (iter.nextWord()) |word| {
                if ((line_index != cursor.line or (word.codepoint_start_pos + word.codepoint_length - 1) > cursor.column) and word.class != .whitespace) {
                    out_line.* = line_index;
                    return word;
                }
            }
        }

        return null;
    }

    fn getPrevWordStart(self: *BufferPanel, cursor: Position, out_line: *usize) !?WordIterator.Word {
        var maybe_word: ?WordIterator.Word = null;
        var first_line_index = cursor.line;
        var line_index: isize = @intCast(isize, cursor.line);
        while (line_index >= 0) : (line_index -= 1) {
            const line = try self.buffer.getLine(@intCast(usize, line_index));

            var iter = try WordIterator.init(line);
            while (iter.nextWord()) |word| {
                if ((line_index < first_line_index or word.codepoint_start_pos < cursor.column) and word.class != .whitespace) {
                    out_line.* = @intCast(usize, line_index);
                    maybe_word = word;
                }
            }

            if (maybe_word != null) {
                return maybe_word;
            }
        }

        return null;
    }

    fn moveToNextWordStart(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var cursor = try self.getFixedCursorPos();
        var line: usize = cursor.line;
        if (try self.getNextWordStart(cursor, &line)) |word| {
            self.cursor.line = line;
            self.cursor.column = word.codepoint_start_pos;
        } else {
            const line_length = try std.unicode.utf8CountCodepoints(try self.buffer.getLine(cursor.line));
            self.cursor.column = line_length - 1;
        }

        try self.fixupCursor();
    }

    fn moveToNextWordEnd(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var cursor = try self.getFixedCursorPos();
        var line: usize = cursor.line;
        if (try self.getNextWordEnd(cursor, &line)) |word| {
            self.cursor.line = line;
            self.cursor.column = word.codepoint_start_pos + word.codepoint_length - 1;
        }

        try self.fixupCursor();
    }

    fn moveToPrevWordStart(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var cursor = try self.getFixedCursorPos();
        var line: usize = cursor.line;
        if (try self.getPrevWordStart(cursor, &line)) |word| {
            self.cursor.line = line;
            self.cursor.column = word.codepoint_start_pos;
        }

        try self.fixupCursor();
    }

    fn deleteToNextWordStart(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        var start_pos = try self.getFixedCursorPos();
        var end_pos = start_pos;

        var line: usize = start_pos.line;
        if (try self.getNextWordStart(start_pos, &line)) |word| {
            end_pos.line = line;
            end_pos.column = word.codepoint_start_pos;
        } else {
            end_pos.line = start_pos.line;
            const line_length = try std.unicode.utf8CountCodepoints(try self.buffer.getLine(start_pos.line));
            end_pos.column = line_length;
        }

        if (end_pos.line > start_pos.line) {
            end_pos.line = start_pos.line;
            const line_length = try std.unicode.utf8CountCodepoints(try self.buffer.getLine(start_pos.line));
            end_pos.column = line_length + 1;
        }

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        try self.buffer.delete(start_pos.line, start_pos.column, distance);

        try self.fixupCursor();
    }

    fn deleteToNextWordEnd(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        var start_pos = try self.getFixedCursorPos();
        var end_pos = start_pos;

        var line: usize = start_pos.line;
        if (try self.getNextWordEnd(start_pos, &line)) |word| {
            end_pos.line = line;
            end_pos.column = word.codepoint_start_pos + word.codepoint_length;
        }

        if (end_pos.line > start_pos.line) {
            end_pos.line = start_pos.line;
            const line_length = try std.unicode.utf8CountCodepoints(try self.buffer.getLine(start_pos.line));
            end_pos.column = line_length + 1;
        }

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        try self.buffer.delete(start_pos.line, start_pos.column, distance);

        try self.fixupCursor();
    }

    fn deleteToPrevWordStart(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        var end_pos = try self.getFixedCursorPos();
        var start_pos = end_pos;

        var line: usize = end_pos.line;
        if (try self.getPrevWordStart(end_pos, &line)) |word| {
            start_pos.line = line;
            start_pos.column = word.codepoint_start_pos;
        }

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        try self.buffer.delete(start_pos.line, start_pos.column, distance);

        self.cursor = start_pos;

        try self.fixupCursor();
    }

    fn undo(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.buffer.undo(&self.cursor.line, &self.cursor.column);
        try self.fixupCursor();
    }

    fn redo(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.buffer.redo(&self.cursor.line, &self.cursor.column);
        try self.fixupCursor();
    }

    fn registerVT(allocator: *Allocator) anyerror!void {
        normal_key_map = try KeyMap.init(allocator);
        insert_key_map = try KeyMap.init(allocator);
        visual_key_map = try KeyMap.init(allocator);
        visual_line_key_map = try KeyMap.init(allocator);

        const normal_key_maps = [_]*KeyMap{
            &normal_key_map,
            &visual_key_map,
            &visual_line_key_map,
        };
        inline for (normal_key_maps) |key_map| {
            try key_map.bind("h", normalMoveLeft);
            try key_map.bind("l", normalMoveRight);
            try key_map.bind("j", normalMoveDown);
            try key_map.bind("k", normalMoveUp);
            try key_map.bind("<left>", normalMoveLeft);
            try key_map.bind("<right>", normalMoveRight);
            try key_map.bind("<down>", normalMoveDown);
            try key_map.bind("<up>", normalMoveUp);
            try key_map.bind("g g", normalMoveToTop);
            try key_map.bind("G", normalMoveToBottom);
            try key_map.bind("0", normalMoveToLineStart);
            try key_map.bind("$", normalMoveToLineEnd);
            try key_map.bind("w", moveToNextWordStart);
            try key_map.bind("e", moveToNextWordEnd);
            try key_map.bind("b", moveToPrevWordStart);
        }

        try normal_key_map.bind("d w", deleteToNextWordStart);
        try normal_key_map.bind("d e", deleteToNextWordEnd);
        try normal_key_map.bind("d b", deleteToPrevWordStart);

        try normal_key_map.bind("x", normalModeDeleteChar);
        try normal_key_map.bind("X", normalModeDeleteCharBefore);
        try normal_key_map.bind("d d", normalModeDeleteLine);
        try normal_key_map.bind("J", normalModeJoinLines);
        try normal_key_map.bind("i", enterInsertModeBefore);
        try normal_key_map.bind("I", enterInsertModeBeginningOfLine);
        try normal_key_map.bind("a", enterInsertModeAfter);
        try normal_key_map.bind("A", enterInsertModeEndOfLine);
        try normal_key_map.bind("o", enterInsertModeNextLine);
        try normal_key_map.bind("O", enterInsertModePrevLine);
        try normal_key_map.bind("p", pasteAfter);
        try normal_key_map.bind("P", pasteBefore);
        try normal_key_map.bind("y y", yankLine);
        try normal_key_map.bind("v", enterVisualMode);
        try normal_key_map.bind("V", enterVisualLineMode);
        try normal_key_map.bind("u", undo);
        try normal_key_map.bind("C-r", redo);

        try insert_key_map.bind("<esc>", exitInsertMode);
        try insert_key_map.bind("<left>", insertModeMoveLeft);
        try insert_key_map.bind("<right>", insertModeMoveRight);
        try insert_key_map.bind("<up>", insertModeMoveUp);
        try insert_key_map.bind("<down>", insertModeMoveDown);
        try insert_key_map.bind("<backspace>", insertModeBackspace);
        try insert_key_map.bind("<enter>", insertModeInsertNewLine);
        try insert_key_map.bind("<tab>", insertModeInsertTab);

        try visual_key_map.bind("<esc>", exitVisualMode);

        try visual_line_key_map.bind("<esc>", exitVisualLineMode);
    }

    fn unregisterVT() void {
        visual_line_key_map.deinit();
        visual_key_map.deinit();
        insert_key_map.deinit();
        normal_key_map.deinit();
    }
};
