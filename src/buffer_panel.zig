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

fn getFirstPosition(a: Position, b: Position) usize {
    if (a.line < b.line) {
        return 0;
    } else if (b.line < a.line) {
        return 1;
    } else if (a.column < b.column) {
        return 0;
    } else {
        return 1;
    }
}

fn positionIsBetween(pos: Position, start: Position, end: Position) bool {
    const is_after_start = pos.line > start.line or (start.line == pos.line and pos.column >= start.column);
    const is_before_end = pos.line < end.line or (pos.line == end.line and pos.column <= end.column);
    return is_after_start and is_before_end;
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

    fn init(text: []const u8) WordIterator {
        return WordIterator{ .text = text };
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
    scroll_to_cursor: bool = false,

    pub fn init(allocator: *Allocator, buffer: *Buffer) !*editor.Panel {
        var self = try allocator.create(BufferPanel);
        self.* = @This(){
            .allocator = allocator,
            .buffer = buffer,
        };
        return &self.panel;
    }

    fn scrollToCursor(self: *BufferPanel) void {
        self.scroll_to_cursor = true;
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
        self.scrollToCursor();
    }

    fn getStatusLine(panel: *editor.Panel, allocator: *Allocator) anyerror![]const u8 {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const cursor_pos = try self.getFixedCursorPos();
        const mode_name = switch (self.mode) {
            .normal => "[N]",
            .insert => "[I]",
            .visual => "[V]",
            .visual_line => "[V]",
        };

        return try std.fmt.allocPrint(allocator, "{s} {s} L#{} C#{}", .{
            mode_name,
            self.buffer.name,
            cursor_pos.line + 1,
            cursor_pos.column + 1,
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

        defer self.scroll_y.update(1.0 / 60.0);
        defer self.scroll_x.update(1.0 / 60.0);

        const cursor = try self.getFixedCursorPos();
        const options = editor.getOptions();
        const font = options.main_font;
        const font_size = options.main_font_size;
        const char_height = font.getCharHeight(font_size);
        const scroll_margin = @intToFloat(f64, options.scroll_margin);
        const scroll_y = self.scroll_y.value;
        const line_count = self.buffer.getLineCount();
        if (line_count == 0) return;

        var first_line: isize = @floatToInt(isize, std.math.floor(scroll_y));
        if (first_line >= line_count) {
            first_line = @intCast(isize, line_count) - 1;
        }

        var last_line: isize = @floatToInt(isize, std.math.floor(
            scroll_y + (@intToFloat(f64, rect.h) / @intToFloat(f64, char_height)),
        ));
        if (last_line >= line_count) {
            last_line = @intCast(isize, line_count) - 1;
        }
        last_line = std.math.max(first_line, last_line);

        if (self.scroll_to_cursor) {
            const float_char_height = @intToFloat(f64, char_height);
            const cursor_pos_y_px: f64 = @intToFloat(f64, cursor.line) * float_char_height;
            const margin_start_y_px: f64 = (self.scroll_y.to + scroll_margin) * float_char_height;
            const margin_end_y_px = (self.scroll_y.to - scroll_margin) * float_char_height + @intToFloat(f64, rect.h);

            if (margin_start_y_px > cursor_pos_y_px) {
                self.scroll_y.to = @intToFloat(f64, cursor.line) - scroll_margin;
                self.scroll_y.to = std.math.max(0, self.scroll_y.to);
            } else if (margin_end_y_px < (cursor_pos_y_px + float_char_height)) {
                self.scroll_y.to = @intToFloat(f64, cursor.line) + scroll_margin + 1.0 - (@intToFloat(f64, rect.h) / float_char_height);
                self.scroll_y.to = std.math.max(0, self.scroll_y.to);
            }

            self.scroll_to_cursor = false;
        }

        const buffer = self.buffer;

        // Draw visual mode selection background
        if (self.mode == .visual) {
            renderer.setColor(editor.getFace("border").color);

            const first_position = getFirstPosition(cursor, self.mark);
            const start_pos = if (first_position == 0) cursor else self.mark;
            const end_pos = if (first_position == 1) cursor else self.mark;

            var current_line_index: isize = first_line;
            while (current_line_index <= last_line) : (current_line_index += 1) {
                const line = self.buffer.lines.items[@intCast(usize, current_line_index)];
                const line_y = rect.y - @floatToInt(
                    i32,
                    std.math.floor(scroll_y * @intToFloat(f64, char_height)),
                ) + (@intCast(i32, current_line_index) * char_height);

                var char_x = rect.x;
                var char_index: usize = 0;

                var iter = std.unicode.Utf8View.initUnchecked(line.content.items).iterator();
                while (iter.nextCodepoint()) |codepoint| {
                    const char_advance = try font.getCharAdvance(font_size, codepoint);

                    if (positionIsBetween(
                        Position{ .line = @intCast(usize, current_line_index), .column = char_index },
                        start_pos,
                        end_pos,
                    )) {
                        _ = try renderer.drawRect(renderer.Rect{
                            .x = char_x,
                            .y = line_y,
                            .w = char_advance,
                            .h = char_height,
                        });
                    }

                    char_x += char_advance;
                    char_index += 1;
                }
            }
        }

        // Draw visual line mode selection background
        if (self.mode == .visual_line) {
            renderer.setColor(editor.getFace("border").color);

            const first_position = getFirstPosition(cursor, self.mark);
            const start_pos = if (first_position == 0) cursor else self.mark;
            const end_pos = if (first_position == 1) cursor else self.mark;

            var current_line_index: isize = first_line;
            while (current_line_index <= last_line) : (current_line_index += 1) {
                if (@intCast(usize, current_line_index) >= start_pos.line and
                    @intCast(usize, current_line_index) <= end_pos.line)
                {
                    const line = self.buffer.lines.items[@intCast(usize, current_line_index)];
                    const line_y = rect.y - @floatToInt(
                        i32,
                        std.math.floor(scroll_y * @intToFloat(f64, char_height)),
                    ) + (@intCast(i32, current_line_index) * char_height);

                    var line_advance: i32 = 0;

                    var iter = std.unicode.Utf8View.initUnchecked(line.content.items).iterator();
                    while (iter.nextCodepoint()) |codepoint| {
                        line_advance += try font.getCharAdvance(font_size, codepoint);
                    }

                    _ = try renderer.drawRect(renderer.Rect{
                        .x = rect.x,
                        .y = line_y,
                        .w = line_advance,
                        .h = char_height,
                    });
                }
            }
        }

        // Draw text
        renderer.setColor(editor.getFace("foreground").color);
        var current_line_index: isize = first_line;
        while (current_line_index <= last_line) : (current_line_index += 1) {
            const line = self.buffer.lines.items[@intCast(usize, current_line_index)];
            const line_y = rect.y - @floatToInt(
                i32,
                std.math.floor(scroll_y * @intToFloat(f64, char_height)),
            ) + (@intCast(i32, current_line_index) * char_height);

            _ = try renderer.drawText(
                line.content.items,
                font,
                font_size,
                rect.x,
                line_y,
                .{},
            );
        }

        // Draw cursor
        {
            const cursor_line_content = try self.buffer.getLine(cursor.line);
            const cursor_line_length = try std.unicode.utf8CountCodepoints(cursor_line_content);

            var cursor_x: i32 = rect.x;
            const cursor_y = rect.y - @floatToInt(
                i32,
                std.math.floor(scroll_y * @intToFloat(f64, char_height)),
            ) + (@intCast(i32, cursor.line) * char_height);

            const view = try std.unicode.Utf8View.init(cursor_line_content);
            var iter = view.iterator();

            var cursor_codepoint: u32 = ' ';
            var cursor_width = try font.getCharAdvance(font_size, ' ');
            if (self.mode == .insert) {
                cursor_width = @divTrunc(cursor_width, 5);
            }

            var i: usize = 0;
            while (iter.nextCodepoint()) |codepoint| {
                if (i == cursor.column) {
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
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (std.math.absFloat(dy) > 0) {
            var new_target = self.scroll_y.to - 5 * dy;
            const buffer_height = @intToFloat(f64, self.buffer.getLineCount());

            new_target = std.math.max(0, new_target);
            new_target = std.math.min(buffer_height - 1, new_target);
            self.scroll_y.to = new_target;
        }
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

        self.scrollToCursor();
    }

    fn normalMoveDown(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if ((self.cursor.line + 1) < self.buffer.getLineCount()) {
            self.cursor.line += 1;
        }

        self.scrollToCursor();
    }

    fn normalMoveToTop(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.line = 0;

        self.scrollToCursor();
    }

    fn normalMoveToBottom(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.line = self.buffer.getLineCount() - 1;

        self.scrollToCursor();
    }

    fn normalMoveToLineStart(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.column = 0;

        try self.fixupCursor();
    }

    fn normalMoveToLineEnd(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        self.cursor.column = line_length - 1;

        try self.fixupCursor();
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

        try self.fixupCursor();
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

        self.scrollToCursor();
    }

    fn insertModeMoveDown(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if ((self.cursor.line + 1) < self.buffer.getLineCount()) {
            self.cursor.line += 1;
        }

        self.scrollToCursor();
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

            var iter = WordIterator.init(line);
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

            var iter = WordIterator.init(line);
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

            var iter = WordIterator.init(line);
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

    fn normalFindCharForward(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var split_iter = mem.split(args, " ");
        const needle_utf8 = split_iter.next() orelse return error.InvalidCommandArgs;
        const needle_codepoint = try std.unicode.utf8Decode(needle_utf8);

        const cursor = try self.getFixedCursorPos();
        const line = try self.buffer.getLine(cursor.line);
        const view = try std.unicode.Utf8View.init(line);
        var iter = view.iterator();

        var i: usize = 0;
        while (iter.nextCodepoint()) |codepoint| {
            if (i > cursor.column and codepoint == needle_codepoint) {
                self.cursor.column = i;
                break;
            }
            i += 1;
        }

        try self.fixupCursor();
    }

    fn normalFindCharBackward(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var split_iter = mem.split(args, " ");
        const needle_utf8 = split_iter.next() orelse return error.InvalidCommandArgs;
        const needle_codepoint = try std.unicode.utf8Decode(needle_utf8);

        const cursor = try self.getFixedCursorPos();
        const line = try self.buffer.getLine(cursor.line);
        const view = try std.unicode.Utf8View.init(line);
        var iter = view.iterator();

        var i: usize = 0;
        while (iter.nextCodepoint()) |codepoint| {
            if (i < cursor.column and codepoint == needle_codepoint) {
                self.cursor.column = i;
                break;
            }
            i += 1;
        }

        try self.fixupCursor();
    }

    fn normalReplaceChar(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        var split_iter = mem.split(args, " ");
        const needle_utf8 = split_iter.next() orelse return error.InvalidCommandArgs;

        const cursor = try self.getFixedCursorPos();
        try self.buffer.delete(cursor.line, cursor.column, 1);
        try self.buffer.insert(needle_utf8, cursor.line, cursor.column);
    }

    fn visualModeDelete(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        const first_position = getFirstPosition(cursor, self.mark);
        const start_pos = if (first_position == 0) cursor else self.mark;
        const end_pos = if (first_position == 1) cursor else self.mark;

        const distance = try self.buffer.getCodepointDistance(start_pos.line, start_pos.column, end_pos.line, end_pos.column);

        try self.buffer.delete(start_pos.line, start_pos.column, distance + 1);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn visualLineModeDelete(panel: *editor.Panel, args: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        const first_position = getFirstPosition(cursor, self.mark);
        var start_pos = if (first_position == 0) cursor else self.mark;
        var end_pos = if (first_position == 1) cursor else self.mark;

        start_pos.column = 0;

        const end_line = try self.buffer.getLine(end_pos.line);
        end_pos.column = try std.unicode.utf8CountCodepoints(end_line);

        const distance = try self.buffer.getCodepointDistance(start_pos.line, start_pos.column, end_pos.line, end_pos.column);

        try self.buffer.delete(start_pos.line, start_pos.column, distance + 1);

        self.cursor = start_pos;

        self.mode = .normal;
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
            try key_map.bind("f <?>", normalFindCharForward);
            try key_map.bind("F <?>", normalFindCharBackward);
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
        try normal_key_map.bind("r <?>", normalReplaceChar);

        try insert_key_map.bind("<esc>", exitInsertMode);
        try insert_key_map.bind("<left>", insertModeMoveLeft);
        try insert_key_map.bind("<right>", insertModeMoveRight);
        try insert_key_map.bind("<up>", insertModeMoveUp);
        try insert_key_map.bind("<down>", insertModeMoveDown);
        try insert_key_map.bind("<backspace>", insertModeBackspace);
        try insert_key_map.bind("<enter>", insertModeInsertNewLine);
        try insert_key_map.bind("<tab>", insertModeInsertTab);

        try visual_key_map.bind("<esc>", exitVisualMode);
        try visual_key_map.bind("v", exitVisualMode);
        try visual_key_map.bind("d", visualModeDelete);

        try visual_line_key_map.bind("<esc>", exitVisualLineMode);
        try visual_line_key_map.bind("V", exitVisualLineMode);
        try visual_line_key_map.bind("d", visualLineModeDelete);
    }

    fn unregisterVT() void {
        visual_line_key_map.deinit();
        visual_key_map.deinit();
        insert_key_map.deinit();
        normal_key_map.deinit();
    }
};
