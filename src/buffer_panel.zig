const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Buffer = @import("buffer.zig").Buffer;
const FileType = @import("filetype.zig").FileType;
const MiniBuffer = @import("minibuffer.zig").MiniBuffer;
const KeyMap = @import("keymap.zig").KeyMap;
const Command = @import("editor.zig").Command;
const CommandRegistry = @import("editor.zig").CommandRegistry;
const util = @import("util.zig");
const Regex = @import("regex.zig").Regex;
const Highlighter = @import("highlighter.zig").Highlighter;
const FaceType = @import("highlighter.zig").FaceType;
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

const SCRATCH_BUFFER_NAME = "** scratch **";

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

fn positionIsBetween(pos: Position, start: Position, end: Position) bool {
    const is_after_start = pos.line > start.line or (start.line == pos.line and pos.column >= start.column);
    const is_before_end = pos.line < end.line or (pos.line == end.line and pos.column <= end.column);
    return is_after_start and is_before_end;
}

var g_filetypes: std.StringArrayHashMap(*FileType) = undefined;
var g_filetype_extensions: std.StringArrayHashMap(*FileType) = undefined;
var g_buffers: std.ArrayList(*Buffer) = undefined;
var command_registry: CommandRegistry = undefined;
var normal_key_map: KeyMap = undefined;
var insert_key_map: KeyMap = undefined;
var visual_key_map: KeyMap = undefined;
var visual_line_key_map: KeyMap = undefined;

pub const VT = editor.PanelVT{
    .name = "buffer",

    .draw = BufferPanel.draw,
    .get_status_line = BufferPanel.getStatusLine,
    .get_key_map = BufferPanel.getKeyMap,
    .deinit = BufferPanel.deinit,

    .on_char = BufferPanel.onChar,
    .on_scroll = BufferPanel.onScroll,

    .register_vt = BufferPanel.registerVT,
    .unregister_vt = BufferPanel.unregisterVT,

    .command_registry = &command_registry,
};

const Position = struct {
    line: usize = 0,
    column: usize = 0,
};

pub const BufferPanel = struct {
    panel: editor.Panel,
    allocator: *Allocator,
    buffer: *Buffer,
    mode: Mode = .normal,
    cursor: Position = .{},
    mark: Position = .{},
    scroll_x: util.Animation(f64) = .{},
    scroll_y: util.Animation(f64) = .{},
    scroll_to_cursor: bool = false,
    search_string: ?[]const u8 = null,
    search_regex: ?Regex = null,

    pub fn init(allocator: *Allocator, buffer: *Buffer) !*editor.Panel {
        var self = try allocator.create(BufferPanel);
        self.* = @This(){
            .panel = try editor.Panel.init(allocator, &VT),
            .allocator = allocator,
            .buffer = buffer,
        };
        return &self.panel;
    }

    fn resetView(self: *BufferPanel) void {
        self.cursor = .{};
        self.mark = .{};
        self.scroll_x = .{};
        self.scroll_y = .{};
        self.mode = .normal;
    }

    pub fn addBufferFromFile(allocator: *Allocator, path: []const u8) !*Buffer {
        const actual_path = try util.normalizePath(allocator, path);
        defer allocator.free(actual_path);

        for (g_buffers.items) |buffer| {
            if (buffer.absolute_path) |buffer_path| {
                if (mem.eql(u8, buffer_path, actual_path)) {
                    return buffer;
                }
            }
        }

        var ext = std.fs.path.extension(path);
        if (ext.len > 0 and ext[0] == '.') ext = ext[1..]; // Remove '.'
        const filetype = g_filetype_extensions.get(ext) orelse getFileType("default");

        const buffer = try Buffer.initFromFile(allocator, .{
            .path = actual_path,
            .filetype = filetype,
        });
        try g_buffers.append(buffer);
        return buffer;
    }

    pub fn registerFileType(filetype: *FileType) !void {
        if (g_filetypes.get(filetype.name)) |existing_filetype| {
            existing_filetype.deinit();
        }

        try g_filetypes.put(filetype.name, filetype);

        for (filetype.extensions) |ext| {
            try g_filetype_extensions.put(ext, filetype);
        }
    }

    pub fn getFileType(name: []const u8) *FileType {
        if (g_filetypes.get(name)) |filetype| {
            return filetype;
        }

        return g_filetypes.get("default") orelse unreachable;
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
            std.log.err("could not insert begin checkpoint: {}", .{err});
        };
    }

    fn endCheckpoint(self: *BufferPanel) void {
        self.buffer.endCheckpoint(self.cursor.line, self.cursor.column) catch |err| {
            std.log.err("could not insert end checkpoint: {}", .{err});
        };
    }

    fn getLineY(self: *BufferPanel, line_index: usize, rect: *const renderer.Rect, char_height: i32) i32 {
        return rect.y - @floatToInt(
            i32,
            std.math.floor(self.scroll_y.value * @intToFloat(f64, char_height)),
        ) + (@intCast(i32, line_index) * char_height);
    }

    fn getSelectionRegion(self: *BufferPanel, start_pos: *Position, end_pos: *Position) !void {
        const cursor = try self.getFixedCursorPos();
        if (cursor.line < self.mark.line) {
            start_pos.* = cursor;
            end_pos.* = self.mark;
        } else if (self.mark.line < cursor.line) {
            start_pos.* = self.mark;
            end_pos.* = cursor;
        } else if (cursor.column < self.mark.column) {
            start_pos.* = cursor;
            end_pos.* = self.mark;
        } else {
            start_pos.* = self.mark;
            end_pos.* = cursor;
        }
    }

    fn drawToken(
        self: *BufferPanel,
        text: []const u8,
        face: FaceType,
        font: *renderer.Font,
        font_size: u32,
        x: i32,
        y: i32,
    ) callconv(.Inline) !i32 {
        var advance: i32 = 0;

        const color_scheme = editor.getColorScheme();
        renderer.setColor(color_scheme.getFace(face).foreground);

        var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (iter.nextCodepoint()) |codepoint| {
            advance += try renderer.drawCodepoint(
                codepoint,
                font,
                font_size,
                x + advance,
                y,
                .{
                    .tab_width = @intCast(i32, self.buffer.filetype.tab_width),
                },
            );
        }

        return advance;
    }

    fn draw(panel: *editor.Panel, rect: renderer.Rect) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        // TODO: use actual delta time
        defer self.scroll_y.update(1.0 / 60.0);
        defer self.scroll_x.update(1.0 / 60.0);

        const color_scheme = editor.getColorScheme();

        const cursor = try self.getFixedCursorPos();
        const options = editor.getOptions();
        const font = options.main_font;
        const font_size = options.main_font_size;
        const char_height = font.getCharHeight(font_size);
        const scroll_margin = @intToFloat(f64, options.scroll_margin);
        const scroll_y = self.scroll_y.value;
        const line_count = self.buffer.getLineCount();
        if (line_count == 0) return;

        var first_line: usize = @floatToInt(usize, std.math.floor(scroll_y));
        if (first_line >= line_count) {
            first_line = @intCast(usize, line_count) - 1;
        }

        var last_line: usize = @floatToInt(usize, std.math.floor(
            scroll_y + (@intToFloat(f64, rect.h) / @intToFloat(f64, char_height)),
        ));
        if (last_line >= line_count) {
            last_line = @intCast(usize, line_count) - 1;
        }
        last_line = std.math.max(first_line, last_line);

        if (!try self.buffer.highlightRange(first_line, last_line)) {
            renderer.requestRedraw();
        }

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
            renderer.setColor(color_scheme.getFace(.border).background);

            var start_pos = Position{};
            var end_pos = Position{};
            try self.getSelectionRegion(&start_pos, &end_pos);
            start_pos.line = std.math.max(start_pos.line, if (first_line > 0) first_line - 1 else 0);
            end_pos.line = std.math.min(end_pos.line, last_line + 1);

            var current_line_index = start_pos.line;
            while (current_line_index <= end_pos.line) : (current_line_index += 1) {
                const line = self.buffer.lines.items[current_line_index];
                const line_y = self.getLineY(current_line_index, &rect, char_height);

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

                if (char_index == 0) {
                    _ = try renderer.drawRect(renderer.Rect{
                        .x = char_x,
                        .y = line_y,
                        .w = try font.getCharAdvance(font_size, ' '),
                        .h = char_height,
                    });
                }
            }
        }

        // Draw visual line mode selection background
        if (self.mode == .visual_line) {
            renderer.setColor(color_scheme.getFace(.border).background);

            var start_pos = Position{};
            var end_pos = Position{};
            try self.getSelectionRegion(&start_pos, &end_pos);
            start_pos.line = std.math.max(start_pos.line, if (first_line > 0) first_line - 1 else 0);
            end_pos.line = std.math.min(end_pos.line, last_line + 1);

            var current_line_index = start_pos.line;
            while (current_line_index <= end_pos.line) : (current_line_index += 1) {
                const line = self.buffer.lines.items[current_line_index];
                const line_y = self.getLineY(current_line_index, &rect, char_height);

                var line_advance: i32 = 0;

                var iter = std.unicode.Utf8View.initUnchecked(line.content.items).iterator();
                while (iter.nextCodepoint()) |codepoint| {
                    line_advance += try font.getCharAdvance(font_size, codepoint);
                }

                if (line_advance == 0) {
                    line_advance = try font.getCharAdvance(font_size, ' ');
                }

                _ = try renderer.drawRect(renderer.Rect{
                    .x = rect.x,
                    .y = line_y,
                    .w = line_advance,
                    .h = char_height,
                });
            }
        }

        // Draw text
        renderer.setColor(color_scheme.getFace(.default).foreground);
        var current_line_index = first_line;
        while (current_line_index <= last_line) : (current_line_index += 1) {
            const line = self.buffer.lines.items[current_line_index];
            const line_y = self.getLineY(current_line_index, &rect, char_height);

            var advance: i32 = 0;
            var line_end_pos: usize = 0;
            for (line.tokens.items) |token| {
                advance += try self.drawToken(
                    line.content.items[line_end_pos .. line_end_pos + token.length],
                    token.face_type,
                    font,
                    font_size,
                    rect.x + advance,
                    line_y,
                );
                line_end_pos += token.length;
            }

            const remaining_text = line.content.items[line_end_pos..];
            if (remaining_text.len > 0) {
                advance += try self.drawToken(
                    remaining_text,
                    FaceType.default,
                    font,
                    font_size,
                    rect.x + advance,
                    line_y,
                );
            }
        }

        // Draw cursor
        {
            const cursor_line_content = try self.buffer.getLine(cursor.line);
            const cursor_line_length = try std.unicode.utf8CountCodepoints(
                cursor_line_content,
            );

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
                    char_advance *= @intCast(i32, self.buffer.filetype.tab_width);
                }
                cursor_x += char_advance;
                i += 1;
            }

            renderer.setColor(color_scheme.getFace(.default).foreground);
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
                        renderer.setColor(color_scheme.getFace(.default).background);

                        _ = try renderer.drawCodepoint(
                            cursor_codepoint,
                            font,
                            font_size,
                            cursor_x,
                            cursor_y,
                            .{
                                .tab_width = @intCast(i32, self.buffer.filetype.tab_width),
                            },
                        );
                    },
                }
            }
        }
    }

    fn deinit(panel: *editor.Panel) void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (self.search_string) |search_string| {
            self.allocator.free(search_string);
        }
        if (self.search_regex) |*search_regex| {
            search_regex.deinit();
        }
        self.allocator.destroy(self);
    }

    fn getKeyMap(panel: *editor.Panel) *KeyMap {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        return switch (self.mode) {
            .normal => &normal_key_map,
            .insert => &insert_key_map,
            .visual => &visual_key_map,
            .visual_line => &visual_line_key_map,
        };
    }

    fn onChar(panel: *editor.Panel, codepoint: u32) anyerror!bool {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        switch (self.mode) {
            .normal, .visual, .visual_line => return false,
            .insert => {
                const filetype = self.buffer.filetype;

                var buf = [4]u8{ 0, 0, 0, 0 };
                const len = try std.unicode.utf8Encode(@intCast(u21, codepoint), &buf);
                const inserted_buf = buf[0..len];

                try self.fixupCursor();

                var is_closer = false;
                var is_opener = false;
                var used_bracket: ?FileType.Bracket = null;
                for (filetype.brackets) |bracket| {
                    is_opener = mem.eql(u8, bracket.open, inserted_buf);
                    is_closer = mem.eql(u8, bracket.close, inserted_buf);
                    if (is_opener or is_closer) {
                        used_bracket = bracket;
                        break;
                    }
                }

                var skip_insert = false;
                if (is_closer) {
                    var iter = std.unicode.Utf8View.initUnchecked(
                        try self.buffer.getLine(self.cursor.line),
                    ).iterator();

                    var codepoint_count: usize = 0;
                    while (iter.nextCodepointSlice()) |c| {
                        if (codepoint_count == self.cursor.column) {
                            if (mem.eql(u8, c, used_bracket.?.close)) {
                                skip_insert = true;
                            }
                            break;
                        }
                        codepoint_count += 1;
                    }
                }

                if (!skip_insert) {
                    if (is_opener) {
                        try self.buffer.insert(
                            used_bracket.?.close,
                            self.cursor.line,
                            self.cursor.column,
                        );
                    }
                    try self.buffer.insert(
                        inserted_buf,
                        self.cursor.line,
                        self.cursor.column,
                    );
                }

                self.cursor.column += 1;

                try self.fixupCursor();

                if (is_opener or is_closer) {
                    const leading_whitespace_before: usize =
                        getLeadingWhitespaceCodepointCount(
                        try self.buffer.getLine(self.cursor.line),
                    );

                    if (self.cursor.column <= (leading_whitespace_before + 1)) {
                        try self.autoIndentSingleLine(self.cursor.line);

                        const leading_whitespace_after: usize =
                            getLeadingWhitespaceCodepointCount(
                            try self.buffer.getLine(self.cursor.line),
                        );
                        self.cursor.column = leading_whitespace_after + 1;
                    }
                }

                return true;
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

    fn normalMoveLeft(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        if (self.cursor.column > 0) {
            self.cursor.column -= 1;
        }

        try self.fixupCursor();
    }

    fn normalMoveRight(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        if ((self.cursor.column + 1) < line_length) {
            self.cursor.column += 1;
        }

        try self.fixupCursor();
    }

    fn normalMoveUp(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (self.cursor.line > 0) {
            self.cursor.line -= 1;
        }

        self.scrollToCursor();
    }

    fn normalMoveDown(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if ((self.cursor.line + 1) < self.buffer.getLineCount()) {
            self.cursor.line += 1;
        }

        self.scrollToCursor();
    }

    fn normalMoveToTop(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.line = 0;

        self.scrollToCursor();
    }

    fn normalMoveToBottom(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.line = self.buffer.getLineCount() - 1;

        self.scrollToCursor();
    }

    fn normalMoveToLineStart(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.cursor.column = 0;

        try self.fixupCursor();
    }

    fn normalMoveToLineEnd(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        self.cursor.column = line_length - 1;

        try self.fixupCursor();
    }

    fn normalModeDeleteChar(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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

    fn normalModeDeleteCharBefore(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.fixupCursor();

        if (self.cursor.column > 0) {
            const content = try self.buffer.getContent(
                self.allocator,
                self.cursor.line,
                self.cursor.column - 1,
                1,
            );
            defer self.allocator.free(content);
            try renderer.setClipboardString(content);
            try self.buffer.delete(self.cursor.line, self.cursor.column - 1, 1);

            self.cursor.column -= 1;

            try self.fixupCursor();
        }
    }

    fn normalModeDeleteLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        const content = try self.buffer.getContent(
            self.allocator,
            self.cursor.line,
            0,
            line_length + 1,
        );
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

    fn normalModeJoinLines(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const line_index = (try self.getFixedCursorPos()).line;
        if ((line_index + 1) >= self.buffer.getLineCount()) return;

        const next_line_index = line_index + 1;
        const next_line = try self.buffer.getLine(next_line_index);
        const leading_whitespace = getLeadingWhitespaceCodepointCount(next_line);
        try self.buffer.delete(next_line_index, 0, leading_whitespace); // delete next line's leading whitespace

        const line = try self.buffer.getLine(line_index);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        try self.buffer.delete(line_index, line_length, 1); // delete newline
        try self.buffer.insert(" ", line_index, line_length); // insert space

        self.cursor.column = line_length;
        try self.fixupCursor();
    }

    fn enterInsertModeBefore(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        self.mode = .insert;

        self.beginCheckpoint();

        try self.fixupCursor();
    }

    fn enterInsertModeAfter(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        self.mode = .insert;

        self.beginCheckpoint();

        self.cursor.column += 1;
        try self.fixupCursor();
    }

    fn enterInsertModeEndOfLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        self.mode = .insert;

        self.beginCheckpoint();

        self.cursor.column = try self.getModeMaxCol(self.cursor.line);
        try self.fixupCursor();
    }

    fn enterInsertModeBeginningOfLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        self.mode = .insert;

        self.beginCheckpoint();

        self.cursor.column = 0;
        try self.fixupCursor();
    }

    fn enterInsertModeNextLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        self.beginCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);

        try self.buffer.insert("\n", self.cursor.line, line_length);

        self.mode = .insert;
        self.cursor.column = 0;
        self.cursor.line += 1;

        try self.autoIndentSingleLine(self.cursor.line);
        self.cursor.column = try std.unicode.utf8CountCodepoints(
            try self.buffer.getLine(self.cursor.line),
        );

        try self.fixupCursor();
    }

    fn enterInsertModePrevLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        try self.fixupCursor();

        self.beginCheckpoint();

        try self.buffer.insert("\n", self.cursor.line, 0);

        self.mode = .insert;
        self.cursor.column = 0;

        try self.autoIndentSingleLine(self.cursor.line);
        self.cursor.column = try std.unicode.utf8CountCodepoints(
            try self.buffer.getLine(self.cursor.line),
        );

        try self.fixupCursor();
    }

    fn exitInsertMode(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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

    fn insertModeMoveRight(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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

    fn insertModeMoveLeft(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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

    fn insertModeMoveUp(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (self.cursor.line > 0) {
            self.cursor.line -= 1;
        }

        self.scrollToCursor();
    }

    fn insertModeMoveDown(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if ((self.cursor.line + 1) < self.buffer.getLineCount()) {
            self.cursor.line += 1;
        }

        self.scrollToCursor();
    }

    fn insertModeBackspace(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (!(self.cursor.column == 0 and self.cursor.line == 0)) {
            try insertModeMoveLeft(panel, &[_][]const u8{});
            const first_content = try self.buffer.getContent(
                self.allocator,
                self.cursor.line,
                self.cursor.column,
                1,
            );
            defer self.allocator.free(first_content);
            try self.buffer.delete(self.cursor.line, self.cursor.column, 1);

            if (mem.eql(u8, first_content, " ")) {
                while (self.cursor.column > 0 and self.cursor.column % self.buffer.filetype.tab_width != 0) {
                    const content = try self.buffer.getContent(
                        self.allocator,
                        self.cursor.line,
                        self.cursor.column - 1,
                        1,
                    );
                    defer self.allocator.free(content);
                    if (!mem.eql(u8, content, " ")) {
                        break;
                    }

                    try insertModeMoveLeft(panel, &[_][]const u8{});
                    try self.buffer.delete(self.cursor.line, self.cursor.column, 1);
                }
            }
        }
    }

    fn insertModeDelete(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.fixupCursor();
        try self.buffer.delete(self.cursor.line, self.cursor.column, 1);
    }

    fn insertModeInsertNewLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const filetype = self.buffer.filetype;

        try self.buffer.insert("\n", self.cursor.line, self.cursor.column);
        try insertModeMoveRight(panel, &[_][]const u8{});
        try self.fixupCursor();

        var found_bracket = false;
        const prev_line_content = try self.buffer.getLine(self.cursor.line - 1);
        const new_line_content = try self.buffer.getLine(self.cursor.line);
        for (filetype.brackets) |bracket| {
            if (mem.endsWith(u8, prev_line_content, bracket.open) and
                mem.startsWith(u8, new_line_content, bracket.close))
            {
                found_bracket = true;
                try self.buffer.insert("\n", self.cursor.line, self.cursor.column);
                try self.autoIndentSingleLine(self.cursor.line + 1);
                break;
            }
        }

        try self.autoIndentSingleLine(self.cursor.line);
        self.cursor.column = getLeadingWhitespaceCodepointCount(
            try self.buffer.getLine(self.cursor.line),
        );

        try self.fixupCursor();
    }

    fn insertModeInsertTab(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        if (self.buffer.filetype.expand_tab) {
            const tab_width = self.buffer.filetype.tab_width;
            const spaces = tab_width - (@intCast(u32, self.cursor.column) % 4);

            var i: u32 = 0;
            while (i < spaces) : (i += 1) {
                try self.buffer.insert(" ", self.cursor.line, self.cursor.column);
                try insertModeMoveRight(panel, &[_][]const u8{});
            }
        } else {
            try self.buffer.insert("\t", self.cursor.line, self.cursor.column);
            try insertModeMoveRight(panel, &[_][]const u8{});
        }
    }

    fn pasteAfter(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const clipboard_content = (try renderer.getClipboardString(self.allocator)) orelse return;
        defer self.allocator.free(clipboard_content);

        const content_codepoint_count = try std.unicode.utf8CountCodepoints(
            clipboard_content,
        );
        if (content_codepoint_count == 0) return;

        if (clipboard_content[clipboard_content.len - 1] == '\n') {
            const line = try self.buffer.getLine(self.cursor.line);
            const line_length = try std.unicode.utf8CountCodepoints(line);
            try self.buffer.insert("\n", self.cursor.line, line_length);
            try self.buffer.insert(
                clipboard_content[0 .. clipboard_content.len - 1],
                self.cursor.line + 1,
                0,
            );
            self.cursor.line += 1;
            self.cursor.column = 0;
        } else {
            try self.buffer.insert(
                clipboard_content,
                self.cursor.line,
                self.cursor.column + 1,
            );
            self.cursor.column += content_codepoint_count;
        }

        try self.fixupCursor();
    }

    fn pasteBefore(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const clipboard_content = (try renderer.getClipboardString(self.allocator)) orelse return;
        defer self.allocator.free(clipboard_content);

        const content_codepoint_count = try std.unicode.utf8CountCodepoints(
            clipboard_content,
        );
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

    fn yankLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const line = try self.buffer.getLine(self.cursor.line);
        const line_length = try std.unicode.utf8CountCodepoints(line);
        const content = try self.buffer.getContent(
            self.allocator,
            self.cursor.line,
            0,
            line_length + 1,
        );
        defer self.allocator.free(content);

        try renderer.setClipboardString(content);
    }

    fn enterVisualMode(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .visual;
        try self.fixupCursor();

        self.mark = self.cursor;
    }

    fn enterVisualLineMode(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .visual_line;
        try self.fixupCursor();

        self.mark = self.cursor;
    }

    fn exitVisualMode(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        self.mode = .normal;
        try self.fixupCursor();
    }

    fn exitVisualLineMode(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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
                if ((line_index != cursor.line or
                    word.codepoint_start_pos > cursor.column) and
                    word.class != .whitespace)
                {
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
                if ((line_index != cursor.line or
                    (word.codepoint_start_pos + word.codepoint_length - 1) > cursor.column) and
                    word.class != .whitespace)
                {
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
                if ((line_index < first_line_index or
                    word.codepoint_start_pos < cursor.column) and
                    word.class != .whitespace)
                {
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

    fn moveToNextWordStart(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var cursor = try self.getFixedCursorPos();
        var line: usize = cursor.line;
        if (try self.getNextWordStart(cursor, &line)) |word| {
            self.cursor.line = line;
            self.cursor.column = word.codepoint_start_pos;
        } else {
            const line_length = try std.unicode.utf8CountCodepoints(
                try self.buffer.getLine(cursor.line),
            );
            self.cursor.column = if (line_length > 0) line_length - 1 else 0;
        }

        try self.fixupCursor();
    }

    fn moveToNextWordEnd(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var cursor = try self.getFixedCursorPos();
        var line: usize = cursor.line;
        if (try self.getNextWordEnd(cursor, &line)) |word| {
            self.cursor.line = line;
            self.cursor.column = word.codepoint_start_pos + word.codepoint_length - 1;
        }

        try self.fixupCursor();
    }

    fn moveToPrevWordStart(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var cursor = try self.getFixedCursorPos();
        var line: usize = cursor.line;
        if (try self.getPrevWordStart(cursor, &line)) |word| {
            self.cursor.line = line;
            self.cursor.column = word.codepoint_start_pos;
        }

        try self.fixupCursor();
    }

    fn deleteToNextWordStart(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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
            const line_length = try std.unicode.utf8CountCodepoints(
                try self.buffer.getLine(start_pos.line),
            );
            end_pos.column = line_length;
        }

        if (end_pos.line > start_pos.line) {
            end_pos.line = start_pos.line;
            const line_length = try std.unicode.utf8CountCodepoints(
                try self.buffer.getLine(start_pos.line),
            );
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

    fn deleteToNextWordEnd(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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
            const line_length = try std.unicode.utf8CountCodepoints(
                try self.buffer.getLine(start_pos.line),
            );
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

    fn deleteToPrevWordStart(panel: *editor.Panel, args: [][]const u8) anyerror!void {
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

    fn undo(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.buffer.undo(&self.cursor.line, &self.cursor.column);
        try self.fixupCursor();
    }

    fn redo(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        try self.buffer.redo(&self.cursor.line, &self.cursor.column);
        try self.fixupCursor();
    }

    fn normalFindCharForward(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (args.len != 1) return error.InvalidFindParameters;

        const needle_utf8 = args[0];
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

    fn normalFindCharBackward(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (args.len != 1) return error.InvalidFindParameters;

        const needle_utf8 = args[0];
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

    fn normalReplaceChar(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (args.len != 1) return error.InvalidReplaceParameters;

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const needle_utf8 = args[0];

        const cursor = try self.getFixedCursorPos();
        try self.buffer.delete(cursor.line, cursor.column, 1);
        try self.buffer.insert(needle_utf8, cursor.line, cursor.column);
    }

    fn visualModeDelete(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        const content = try self.buffer.getContent(
            self.allocator,
            start_pos.line,
            start_pos.column,
            distance + 1,
        );
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        try self.buffer.delete(start_pos.line, start_pos.column, distance + 1);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn visualModeYank(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        const content = try self.buffer.getContent(
            self.allocator,
            start_pos.line,
            start_pos.column,
            distance + 1,
        );
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn visualModePaste(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const maybe_pasted_content = try renderer.getClipboardString(self.allocator);
        defer if (maybe_pasted_content) |pasted_content| {
            self.allocator.free(pasted_content);
        };

        const pasted_content = maybe_pasted_content orelse "";

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        const content = try self.buffer.getContent(
            self.allocator,
            start_pos.line,
            start_pos.column,
            distance + 1,
        );
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        try self.buffer.delete(start_pos.line, start_pos.column, distance + 1);
        try self.buffer.insert(pasted_content, start_pos.line, start_pos.column);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn visualLineModeDelete(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        start_pos.column = 0;

        const end_line = try self.buffer.getLine(end_pos.line);
        end_pos.column = try std.unicode.utf8CountCodepoints(end_line);

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        const content = try self.buffer.getContent(
            self.allocator,
            start_pos.line,
            start_pos.column,
            distance + 1,
        );
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        try self.buffer.delete(start_pos.line, start_pos.column, distance + 1);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn visualLineModeYank(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const cursor = try self.getFixedCursorPos();

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        start_pos.column = 0;

        const end_line = try self.buffer.getLine(end_pos.line);
        end_pos.column = try std.unicode.utf8CountCodepoints(end_line);

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        const content = try self.buffer.getContent(
            self.allocator,
            start_pos.line,
            start_pos.column,
            distance + 1,
        );
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn visualLineModePaste(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const maybe_pasted_content = try renderer.getClipboardString(self.allocator);
        defer if (maybe_pasted_content) |pasted_content| {
            self.allocator.free(pasted_content);
        };

        const pasted_content = maybe_pasted_content orelse "";

        self.beginCheckpoint();
        defer self.endCheckpoint();

        const cursor = try self.getFixedCursorPos();

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        start_pos.column = 0;

        const end_line = try self.buffer.getLine(end_pos.line);
        end_pos.column = try std.unicode.utf8CountCodepoints(end_line);

        const distance = try self.buffer.getCodepointDistance(
            start_pos.line,
            start_pos.column,
            end_pos.line,
            end_pos.column,
        );

        const content = try self.buffer.getContent(
            self.allocator,
            start_pos.line,
            start_pos.column,
            distance + 1,
        );
        defer self.allocator.free(content);
        try renderer.setClipboardString(content);

        try self.buffer.delete(start_pos.line, start_pos.column, distance + 1);
        try self.buffer.insert(pasted_content, start_pos.line, start_pos.column);

        self.cursor = start_pos;

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn gotoNextSearchMatch(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (self.search_regex == null) return;
        var regex = self.search_regex.?;

        const cursor = try self.getFixedCursorPos();
        var match_pos = cursor;

        var i: usize = cursor.line;
        outer: while (i < self.buffer.lines.items.len) : (i += 1) {
            const content = try self.buffer.getLine(i);

            var codepoint_index: usize = 0;
            var byte_index: usize = 0;
            var iter = std.unicode.Utf8View.initUnchecked(content).iterator();

            regex.setBuffer(content);
            var match_start: usize = 0;
            var match_end: usize = 0;
            while (regex.nextMatch(&match_start, &match_end)) |_| {
                while (true) {
                    const codepoint_slice = iter.peek(1);

                    if (codepoint_slice.len == 0) break;
                    if (byte_index == match_start) break;

                    _ = iter.nextCodepoint();
                    byte_index += codepoint_slice.len;
                    codepoint_index += 1;
                }

                if (i != cursor.line or cursor.column < codepoint_index) {
                    match_pos.line = i;
                    match_pos.column = codepoint_index;
                    break :outer;
                }
            }
        }

        self.cursor = match_pos;
        try self.fixupCursor();
    }

    fn gotoPrevSearchMatch(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (self.search_regex == null) return;
        var regex = self.search_regex.?;

        const cursor = try self.getFixedCursorPos();
        var match_pos = cursor;

        var i: isize = @intCast(isize, cursor.line);
        outer: while (i >= 0) : (i -= 1) {
            const line = self.buffer.lines.items[@intCast(usize, i)];
            const content = line.content.items;

            var codepoint_index: usize = 0;
            var byte_index: usize = 0;
            var iter = std.unicode.Utf8View.initUnchecked(content).iterator();

            regex.setBuffer(content);
            var match_start: usize = 0;
            var match_end: usize = 0;
            while (regex.nextMatch(&match_start, &match_end)) |_| {
                while (true) {
                    const codepoint_slice = iter.peek(1);

                    if (codepoint_slice.len == 0) break;
                    if (byte_index == match_start) break;

                    _ = iter.nextCodepoint();
                    byte_index += codepoint_slice.len;
                    codepoint_index += 1;
                }

                if (i != cursor.line or cursor.column > codepoint_index) {
                    match_pos.line = @intCast(usize, i);
                    match_pos.column = codepoint_index;
                    break :outer;
                }
            }
        }

        self.cursor = match_pos;
        try self.fixupCursor();
    }

    fn bufferForwardSearchConfirm(panel: *editor.Panel, text: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var regex = try Regex.init(self.allocator);

        try regex.addPattern(0, text);

        if (self.search_string) |search_string| {
            self.allocator.free(search_string);
        }
        if (self.search_regex) |*search_regex| {
            search_regex.deinit();
        }

        self.search_string = try self.allocator.dupe(u8, text);
        self.search_regex = regex;

        try gotoNextSearchMatch(panel, &[_][]const u8{});
    }

    fn bufferBackwardSearchConfirm(panel: *editor.Panel, text: []const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var regex = try Regex.init(self.allocator);

        try regex.addPattern(0, text);

        if (self.search_string) |search_string| {
            self.allocator.free(search_string);
        }
        if (self.search_regex) |*search_regex| {
            search_regex.deinit();
        }

        self.search_string = try self.allocator.dupe(u8, text);
        self.search_regex = regex;

        try gotoPrevSearchMatch(panel, &[_][]const u8{});
    }

    fn normalModeForwardSearch(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var minibuffer = editor.getMiniBuffer();
        try minibuffer.activate(
            panel,
            "/",
            &[_][]const u8{},
            .{
                .on_confirm = bufferForwardSearchConfirm,
            },
        );
    }

    fn normalModeBackwardSearch(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var minibuffer = editor.getMiniBuffer();
        try minibuffer.activate(
            panel,
            "?",
            &[_][]const u8{},
            .{
                .on_confirm = bufferBackwardSearchConfirm,
            },
        );
    }

    fn getLeadingWhitespaceCodepointCount(line: []const u8) usize {
        var length: usize = 0;

        var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
        while (iter.nextCodepoint()) |codepoint| {
            switch (codepoint) {
                ' ', '\t' => length += 1,
                else => break,
            }
        }

        return length;
    }

    fn getPrevUnindentedLine(self: *BufferPanel, line_index: usize) !usize {
        const filetype = self.buffer.filetype;
        const increase_indent_regex =
            &(filetype.increase_indent_regex orelse return error.MissingIncreaseIndentRegex);
        const decrease_indent_regex =
            &(filetype.decrease_indent_regex orelse return error.MissingDecreaseIndentRegex);

        var i: isize = @intCast(isize, line_index) - 1;
        while (i >= 0) : (i -= 1) {
            const line_content = try self.buffer.getLine(@intCast(usize, i));
            increase_indent_regex.setBuffer(line_content);
            decrease_indent_regex.setBuffer(line_content);
            if (line_content.len > 0 and
                line_content[0] != ' ' and
                line_content[0] != '\t' and
                increase_indent_regex.nextMatch(null, null) == null and
                decrease_indent_regex.nextMatch(null, null) == null)
            {
                break;
            }
        }
        return @intCast(usize, std.math.max(0, i));
    }

    fn getLineIndentLevel(self: *BufferPanel, line_index: usize) !f64 {
        const filetype = self.buffer.filetype;

        const line_content = try self.buffer.getLine(line_index);

        var level: f64 = 0.0;
        var iter = std.unicode.Utf8View.initUnchecked(line_content).iterator();
        while (iter.nextCodepoint()) |c| {
            switch (c) {
                '\t' => level += 1.0,
                ' ' => level += (1.0 / @intToFloat(f64, filetype.tab_width)),
                else => break,
            }
        }

        return level;
    }

    fn indentLine(self: *BufferPanel, line_index: usize, indent_level: usize) !void {
        const filetype = self.buffer.filetype;

        const line_content = self.buffer.lines.items[line_index].content.items;

        const leading_whitespace = getLeadingWhitespaceCodepointCount(line_content);

        try self.buffer.delete(line_index, 0, leading_whitespace);

        const indent_char: u8 = if (filetype.expand_tab) ' ' else '\t';
        const indent_count: usize = if (filetype.expand_tab) indent_level * filetype.tab_width else indent_level;

        var i: usize = 0;
        while (i < indent_count) : (i += 1) {
            try self.buffer.insert(&[_]u8{indent_char}, line_index, 0);
        }
    }

    fn autoIndentSingleLine(self: *BufferPanel, line_index: usize) !void {
        if (self.buffer.filetype.increase_indent_regex == null or
            self.buffer.filetype.decrease_indent_regex == null)
        {
            return;
        }

        const increase_indent_regex = &self.buffer.filetype.increase_indent_regex.?;
        const decrease_indent_regex = &self.buffer.filetype.decrease_indent_regex.?;
        const maybe_zero_indent_regex = &self.buffer.filetype.zero_indent_regex;
        const maybe_indent_next_line_regex = &self.buffer.filetype.indent_next_line_regex;

        var level: isize = 0;

        if (maybe_zero_indent_regex.*) |*zero_indent_regex| {
            const line_content = try self.buffer.getLine(line_index);
            zero_indent_regex.setBuffer(line_content);
            if (zero_indent_regex.nextMatch(null, null) != null) {
                try self.indentLine(line_index, 0);
                return;
            }
        }

        var i: usize = try self.getPrevUnindentedLine(line_index);
        while (i <= line_index) : (i += 1) {
            const line_content = try self.buffer.getLine(i);

            if (i + 1 == line_index) {
                if (maybe_indent_next_line_regex.*) |*indent_next_line_regex| {
                    indent_next_line_regex.setBuffer(line_content);
                    increase_indent_regex.setBuffer(try self.buffer.getLine(line_index));
                    if (indent_next_line_regex.nextMatch(null, null) != null and
                        increase_indent_regex.nextMatch(null, null) == null)
                    {
                        level += 1;
                    }
                }
            }

            increase_indent_regex.setBuffer(line_content);
            if (i != line_index and increase_indent_regex.nextMatch(null, null) != null) {
                level += 1;
            }

            decrease_indent_regex.setBuffer(line_content);
            if (decrease_indent_regex.nextMatch(null, null) != null) {
                level -= 1;
            }
        }

        try self.indentLine(line_index, @intCast(usize, std.math.max(0, level)));
    }

    fn autoIndentRegion(self: *BufferPanel, start_line: usize, end_line: usize) !void {
        if (self.buffer.filetype.increase_indent_regex == null or
            self.buffer.filetype.decrease_indent_regex == null)
        {
            return;
        }

        const increase_indent_regex = &self.buffer.filetype.increase_indent_regex.?;
        const decrease_indent_regex = &self.buffer.filetype.decrease_indent_regex.?;
        const maybe_zero_indent_regex = &self.buffer.filetype.zero_indent_regex;
        const maybe_indent_next_line_regex = &self.buffer.filetype.indent_next_line_regex;

        var level: isize = 0;

        var i: usize = try self.getPrevUnindentedLine(start_line);
        while (i <= end_line) : (i += 1) {
            {
                const line_content = try self.buffer.getLine(i);
                decrease_indent_regex.setBuffer(line_content);
                if (decrease_indent_regex.nextMatch(null, null) != null) {
                    level -= 1;
                }
            }

            var prev_line_caused_indent = false;

            if (i > 0) {
                const prev_line_content = try self.buffer.getLine(i - 1);
                const line_content = try self.buffer.getLine(i);

                if (maybe_indent_next_line_regex.*) |*indent_next_line_regex| {
                    indent_next_line_regex.setBuffer(prev_line_content);
                    increase_indent_regex.setBuffer(line_content);

                    prev_line_caused_indent =
                        indent_next_line_regex.nextMatch(null, null) != null and
                        increase_indent_regex.nextMatch(null, null) == null;
                }
            }

            if (prev_line_caused_indent) level += 1;

            if (start_line <= i and i <= end_line) {
                try self.indentLine(i, @intCast(usize, std.math.max(0, level)));

                if (maybe_zero_indent_regex.*) |*zero_indent_regex| {
                    const line_content = try self.buffer.getLine(i);
                    zero_indent_regex.setBuffer(line_content);
                    if (zero_indent_regex.nextMatch(null, null) != null) {
                        try self.indentLine(i, 0);
                    }
                }
            }

            if (prev_line_caused_indent) level -= 1;

            {
                const line_content = try self.buffer.getLine(i);
                increase_indent_regex.setBuffer(line_content);
                if (increase_indent_regex.nextMatch(null, null) != null) {
                    level += 1;
                }
            }
        }
    }

    fn normalIndentLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const line_index = (try self.getFixedCursorPos()).line;

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.autoIndentSingleLine(line_index);

        try self.fixupCursor();
    }

    fn normalIndentToEnd(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        const line_count = self.buffer.getLineCount();

        const start_line = (try self.getFixedCursorPos()).line;
        const end_line = if (line_count > 0) line_count - 1 else line_count;

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.autoIndentRegion(start_line, end_line);

        try self.fixupCursor();
    }

    fn visualIndentLine(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.autoIndentRegion(start_pos.line, end_pos.line);

        self.mode = .normal;
        try self.fixupCursor();
    }

    fn normalLeftShift(panel: *editor.Panel, _: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        const line_index = (try self.getFixedCursorPos()).line;

        const indent_level_float = try self.getLineIndentLevel(line_index);
        const indent_level = @floatToInt(usize, std.math.ceil(indent_level_float));

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.indentLine(line_index, if (indent_level > 0) indent_level - 1 else 0);
    }

    fn normalRightShift(panel: *editor.Panel, _: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);
        const line_index = (try self.getFixedCursorPos()).line;

        const indent_level_float = try self.getLineIndentLevel(line_index);
        const indent_level = @floatToInt(usize, std.math.ceil(indent_level_float));

        self.beginCheckpoint();
        defer self.endCheckpoint();

        try self.indentLine(line_index, indent_level + 1);
    }

    fn visualLeftShift(panel: *editor.Panel, _: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        var line_index = start_pos.line;
        while (line_index <= end_pos.line) : (line_index += 1) {
            const indent_level_float = try self.getLineIndentLevel(line_index);
            const indent_level = @floatToInt(usize, std.math.ceil(indent_level_float));

            try self.indentLine(line_index, if (indent_level > 0) indent_level - 1 else 0);
        }
    }

    fn visualRightShift(panel: *editor.Panel, _: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        var start_pos = Position{};
        var end_pos = Position{};
        try self.getSelectionRegion(&start_pos, &end_pos);

        self.beginCheckpoint();
        defer self.endCheckpoint();

        var line_index = start_pos.line;
        while (line_index <= end_pos.line) : (line_index += 1) {
            const indent_level_float = try self.getLineIndentLevel(line_index);
            const indent_level = @floatToInt(usize, std.math.ceil(indent_level_float));

            try self.indentLine(line_index, indent_level + 1);
        }
    }

    fn runFormatter(panel: *editor.Panel, _: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (self.buffer.filetype.formatter_command == null) {
            return;
        }
        const command = self.buffer.filetype.formatter_command.?;

        const content = try self.buffer.getEntireContent(self.allocator);
        defer self.allocator.free(content);

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        if (builtin.os.tag != .windows) {
            try args.append("/usr/bin/env");
        }

        var iter = mem.split(command, " ");
        while (iter.next()) |part| {
            try args.append(part);
        }

        if (args.items.len == 0) {
            return error.InvalidFormatterCommand;
        }

        var proc = try std.ChildProcess.init(args.items, self.allocator);
        defer proc.deinit();

        proc.stdin_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        proc.stdout_behavior = .Pipe;

        try proc.spawn();

        var writer = proc.stdin.?.writer();
        try writer.writeAll(content);
        proc.stdin.?.close();
        proc.stdin = null;

        var reader = proc.stdout.?.reader();
        const formatted_content = try reader.readAllAlloc(self.allocator, content.len * 2);
        defer self.allocator.free(formatted_content);

        var err_reader = proc.stderr.?.reader();
        const error_content = try err_reader.readAllAlloc(self.allocator, 1024 * 16);
        defer self.allocator.free(error_content);

        _ = try proc.wait();

        if (error_content.len > 0) {
            std.log.err("formatter error: {s}", .{error_content});
        }

        if (formatted_content.len > 0) {
            self.beginCheckpoint();
            defer self.endCheckpoint();

            try self.buffer.delete(0, 0, content.len);
            try self.buffer.insert(formatted_content, 0, 0);
        }
    }

    fn commandWriteFile(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (args.len != 0) return error.InvalidCommandParameters;

        self.buffer.save() catch |err| {
            std.log.err("Failed to save buffer: \"{s}\"", .{self.buffer.name});
            return err;
        };
    }

    fn commandEditFile(panel: *editor.Panel, args: [][]const u8) anyerror!void {
        var self = @fieldParentPtr(BufferPanel, "panel", panel);

        if (args.len != 1) return error.InvalidCommandParameters;

        const path = args[0];

        if (BufferPanel.addBufferFromFile(self.allocator, path)) |new_buffer| {
            self.buffer = new_buffer;
            self.resetView();
        } else |err| {
            std.log.err("Failed to open buffer: {s}", .{path});
        }
    }

    fn registerVT(allocator: *Allocator) anyerror!void {
        g_buffers = std.ArrayList(*Buffer).init(allocator);
        g_filetypes = std.StringArrayHashMap(*FileType).init(allocator);
        g_filetype_extensions = std.StringArrayHashMap(*FileType).init(allocator);
        command_registry = CommandRegistry.init(allocator);
        normal_key_map = try KeyMap.init(allocator);
        insert_key_map = try KeyMap.init(allocator);
        visual_key_map = try KeyMap.init(allocator);
        visual_line_key_map = try KeyMap.init(allocator);

        try registerFileType(try FileType.init(
            allocator,
            "default",
            @embedFile("../filetypes/default.json"),
        ));

        try registerFileType(try FileType.init(
            allocator,
            "c",
            @embedFile("../filetypes/c.json"),
        ));

        try registerFileType(try FileType.init(
            allocator,
            "zig",
            @embedFile("../filetypes/zig.json"),
        ));

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
            try key_map.bind("n", gotoNextSearchMatch);
            try key_map.bind("N", gotoPrevSearchMatch);
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
        try normal_key_map.bind("= =", normalIndentLine);
        try normal_key_map.bind("= G", normalIndentToEnd);
        try normal_key_map.bind("< <", normalLeftShift);
        try normal_key_map.bind("> >", normalRightShift);
        try normal_key_map.bind("<space> m f", runFormatter);

        try normal_key_map.bind("/", normalModeForwardSearch);
        try normal_key_map.bind("?", normalModeBackwardSearch);

        try insert_key_map.bind("<esc>", exitInsertMode);
        try insert_key_map.bind("<left>", insertModeMoveLeft);
        try insert_key_map.bind("<right>", insertModeMoveRight);
        try insert_key_map.bind("<up>", insertModeMoveUp);
        try insert_key_map.bind("<down>", insertModeMoveDown);
        try insert_key_map.bind("<backspace>", insertModeBackspace);
        try insert_key_map.bind("<delete>", insertModeDelete);
        try insert_key_map.bind("<enter>", insertModeInsertNewLine);
        try insert_key_map.bind("<tab>", insertModeInsertTab);

        try visual_key_map.bind("<esc>", exitVisualMode);
        try visual_key_map.bind("v", exitVisualMode);
        try visual_key_map.bind("d", visualModeDelete);
        try visual_key_map.bind("y", visualModeYank);
        try visual_key_map.bind("p", visualModePaste);
        try visual_key_map.bind("=", visualIndentLine);
        try visual_key_map.bind("<", visualLeftShift);
        try visual_key_map.bind(">", visualRightShift);

        try visual_line_key_map.bind("<esc>", exitVisualLineMode);
        try visual_line_key_map.bind("V", exitVisualLineMode);
        try visual_line_key_map.bind("d", visualLineModeDelete);
        try visual_line_key_map.bind("y", visualLineModeYank);
        try visual_line_key_map.bind("p", visualLineModePaste);
        try visual_line_key_map.bind("=", visualIndentLine);
        try visual_line_key_map.bind("<", visualLeftShift);
        try visual_line_key_map.bind(">", visualRightShift);

        try command_registry.register("w", commandWriteFile);
        try command_registry.register("e", commandEditFile);

        try normal_key_map.bind("C-p", struct {
            fn callback(panel: *editor.Panel, args: [][]const u8) anyerror!void {
                var arena = std.heap.ArenaAllocator.init(editor.getAllocator());
                defer arena.deinit();
                const arena_allocator = &arena.allocator;

                var options = std.ArrayList([]const u8).init(arena_allocator);
                defer options.deinit();

                var ignore_regex = try Regex.init(arena_allocator);
                try ignore_regex.addPattern(0, editor.getOptions().wild_ignore);

                var walker = try util.Walker.init(arena_allocator, ".", ignore_regex);
                defer walker.deinit();

                while (try walker.next()) |entry| {
                    if (entry.kind != .Directory) {
                        try options.append(try arena_allocator.dupe(u8, entry.path));
                    }
                }

                var minibuffer = editor.getMiniBuffer();
                try minibuffer.activate(
                    panel,
                    "Find: ",
                    options.items,
                    .{},
                );
            }
        }.callback);

        try normal_key_map.bind("C-b", struct {
            fn callback(panel: *editor.Panel, args: [][]const u8) anyerror!void {
                var arena = std.heap.ArenaAllocator.init(editor.getAllocator());
                defer arena.deinit();
                const arena_allocator = &arena.allocator;

                var options = std.ArrayList([]const u8).init(arena_allocator);
                defer options.deinit();

                for (g_buffers.items) |buffer| {
                    try options.append(try arena_allocator.dupe(u8, buffer.name));
                }

                var minibuffer = editor.getMiniBuffer();
                try minibuffer.activate(
                    panel,
                    "Buffer: ",
                    options.items,
                    .{},
                );
            }
        }.callback);
    }

    fn unregisterVT() void {
        for (g_buffers.items) |buffer| {
            buffer.deinit();
        }

        {
            var iter = g_filetypes.iterator();
            while (iter.next()) |entry| {
                entry.value.deinit();
            }
        }

        visual_line_key_map.deinit();
        visual_key_map.deinit();
        insert_key_map.deinit();
        normal_key_map.deinit();
        command_registry.deinit();
        g_filetypes.deinit();
        g_filetype_extensions.deinit();
        g_buffers.deinit();
    }

    pub fn getScratchBuffer(allocator: *Allocator) !*Buffer {
        for (g_buffers.items) |buffer| {
            if (mem.eql(u8, buffer.name, SCRATCH_BUFFER_NAME)) {
                return buffer;
            }
        }

        const scratch_buffer = try Buffer.initWithContent(
            allocator,
            "",
            .{
                .name = SCRATCH_BUFFER_NAME,
                .filetype = getFileType("default"),
            },
        );

        try g_buffers.append(scratch_buffer);

        return scratch_buffer;
    }
};

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
