const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const MiniBuffer = struct {
    allocator: *Allocator,
    text: ArrayList(u8),
    prompt: ?[]const u8 = null,
    callbacks: Callbacks = .{},
    cursor: usize = 0,
    active: bool = false,

    pub const Callback = fn (panel: *editor.Panel, text: []const u8) anyerror!void;
    pub const Callbacks = struct {
        on_change: ?Callback = null,
        on_confirm: ?Callback = null,
        on_cancel: ?Callback = null,
    };

    pub fn init(allocator: *Allocator) !*MiniBuffer {
        const self = try allocator.create(MiniBuffer);
        self.* = MiniBuffer{
            .allocator = allocator,
            .text = ArrayList(u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *MiniBuffer) void {
        if (self.prompt) |prompt| {
            self.allocator.free(prompt);
        }
        self.text.deinit();
        self.allocator.destroy(self);
    }

    pub fn insert(self: *MiniBuffer, text: []const u8, column: usize) !void {
        if (text.len == 0) return;

        var byte_pos: usize = 0;
        var codepoint_pos: usize = 0;

        const view = try std.unicode.Utf8View.init(self.text.items);
        var iter = view.iterator();
        while (iter.nextCodepointSlice()) |codepoint_slice| {
            if (codepoint_pos == column) {
                break;
            }
            byte_pos += codepoint_slice.len;
            codepoint_pos += 1;
        }

        try self.text.insertSlice(byte_pos, text);
    }

    pub fn delete(self: *MiniBuffer, column: usize, codepoint_length: usize) !void {
        if (codepoint_length == 0) return;

        var byte_pos: usize = 0;
        var codepoint_pos: usize = 0;

        var region_start_byte: usize = 0;
        var region_byte_length: usize = 0;
        var region_codepoint_length: usize = 0;

        const view = try std.unicode.Utf8View.init(self.text.items);
        var iter = view.iterator();
        while (iter.nextCodepointSlice()) |codepoint_slice| {
            if (codepoint_pos == column) {
                region_start_byte = byte_pos;
            }

            byte_pos += codepoint_slice.len;
            codepoint_pos += 1;

            if (region_codepoint_length >= codepoint_length) {
                break;
            }

            if (codepoint_pos >= column) {
                region_byte_length += codepoint_slice.len;
                region_codepoint_length += 1;
            }
        }

        if (codepoint_pos <= column) return;

        mem.copy(
            u8,
            self.text.items[region_start_byte..],
            self.text.items[region_start_byte + region_byte_length ..],
        );
        self.text.shrinkRetainingCapacity(self.text.items.len - region_byte_length);
    }

    pub fn resetContent(self: *MiniBuffer) void {
        self.text.shrinkRetainingCapacity(0);
        self.cursor = 0;
    }

    pub fn getContent(self: *MiniBuffer, allocator: *Allocator) ![]const u8 {
        return try allocator.dupe(u8, self.text.items);
    }

    pub fn draw(self: *MiniBuffer, rect: renderer.Rect) !void {
        try renderer.setScissor(rect);

        // Only proceed to draw text if minibuffer is active
        if (!self.active) return;

        const options = editor.getOptions();
        const font = options.main_font;
        const font_size = options.main_font_size;
        const char_height = font.getCharHeight(font_size);

        const cursor_width = @divTrunc(try font.getCharAdvance(font_size, ' '), 5);

        const padding = @intCast(i32, options.minibuffer_line_padding);

        var cursor_advance: i32 = 0;

        var iter = std.unicode.Utf8View.initUnchecked(self.text.items).iterator();
        var codepoint_index: usize = 0;
        while (iter.nextCodepoint()) |codepoint| {
            if (codepoint_index == self.cursor) {
                break;
            }
            cursor_advance += try font.getCharAdvance(font_size, codepoint);
            codepoint_index += 1;
        }

        renderer.setColor(editor.getFace("foreground").color);

        // Draw prompt
        const prompt_advance = if (self.prompt) |prompt| blk: {
            break :blk try renderer.drawText(
                prompt,
                font,
                font_size,
                rect.x + padding,
                rect.y + padding,
                .{},
            );
        } else blk: {
            break :blk 0;
        };

        // Draw text
        _ = try renderer.drawText(
            self.text.items,
            font,
            font_size,
            prompt_advance + rect.x + padding,
            rect.y + padding,
            .{},
        );

        // Draw cursor
        try renderer.drawRect(.{
            .w = cursor_width,
            .h = char_height,
            .x = prompt_advance + rect.x + padding + cursor_advance,
            .y = rect.y + padding,
        });
    }

    pub fn activate(self: *MiniBuffer, prompt: []const u8, callbacks: Callbacks) !void {
        if (self.prompt) |existing_prompt| {
            self.allocator.free(existing_prompt);
        }

        self.prompt = try self.allocator.dupe(u8, prompt);
        self.callbacks = callbacks;

        self.resetContent();
        self.active = true;
    }

    pub fn deactivate(self: *MiniBuffer) void {
        self.active = false;
        self.resetContent();
    }

    pub fn onChar(self: *MiniBuffer, panel: *editor.Panel, codepoint: u32) anyerror!bool {
        var text = [4]u8{ 0, 0, 0, 0 };
        var text_bytes = try std.unicode.utf8Encode(@intCast(u21, codepoint), &text);
        try self.insert(text[0..text_bytes], self.cursor);
        self.cursor += 1;

        if (self.callbacks.on_change) |on_change| {
            try on_change(panel, self.text.items);
        }

        return true;
    }

    pub fn onKey(self: *MiniBuffer, panel: *editor.Panel, key: renderer.Key, mods: u32) anyerror!bool {
        const allocator = self.allocator;
        const content = try allocator.dupe(u8, self.text.items);
        defer allocator.free(content);

        return switch (key) {
            .@"<esc>" => blk: {
                self.resetContent();
                self.active = false;

                if (self.callbacks.on_cancel) |on_cancel| {
                    try on_cancel(panel, content);
                }
                break :blk true;
            },
            .@"<enter>" => blk: {
                self.resetContent();
                self.active = false;

                if (self.callbacks.on_confirm) |on_confirm| {
                    try on_confirm(panel, content);
                }
                break :blk true;
            },
            .@"<backspace>" => blk: {
                if (self.cursor > 0) {
                    self.cursor -= 1;
                    try self.delete(self.cursor, 1);

                    if (self.callbacks.on_change) |on_change| {
                        try on_change(panel, content);
                    }
                }
                break :blk true;
            },
            .@"<delete>" => blk: {
                const text_length = try std.unicode.utf8CountCodepoints(self.text.items);
                if (self.cursor < text_length) {
                    try self.delete(self.cursor, 1);

                    if (self.callbacks.on_change) |on_change| {
                        try on_change(panel, content);
                    }
                }
                break :blk true;
            },
            .@"<left>" => blk: {
                if (self.cursor > 0) self.cursor -= 1;
                break :blk true;
            },
            .@"<right>" => blk: {
                if ((self.cursor + 1) <= self.text.items.len) self.cursor += 1;
                break :blk true;
            },
            else => false,
        };
    }
};

comptime {
    _ = MiniBuffer.init;
    _ = MiniBuffer.deinit;
    _ = MiniBuffer.insert;
    _ = MiniBuffer.delete;
    _ = MiniBuffer.resetContent;
    _ = MiniBuffer.getContent;
    _ = MiniBuffer.draw;
    _ = MiniBuffer.onChar;
    _ = MiniBuffer.onKey;
}

test "minibuffer" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const expect = testing.expect;
    const expectEqualStrings = testing.expectEqualStrings;

    const minibuffer = try MiniBuffer.init(allocator);
    defer minibuffer.deinit();

    try minibuffer.insert("hello world", 0);
    try minibuffer.insert(" howdy", 5);

    expectEqualStrings("hello howdy world", minibuffer.text.items);

    try minibuffer.delete(5, 6);
    expectEqualStrings("hello world", minibuffer.text.items);

    try minibuffer.insert(" hello", 11);
    expectEqualStrings("hello world hello", minibuffer.text.items);

    try minibuffer.delete(1, 1);
    expectEqualStrings("hllo world hello", minibuffer.text.items);

    try minibuffer.delete(2, 3);
    expectEqualStrings("hlworld hello", minibuffer.text.items);

    try minibuffer.delete(13, 1);
    expectEqualStrings("hlworld hello", minibuffer.text.items);
}
