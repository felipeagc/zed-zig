const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const MiniBuffer = @This();

allocator: Allocator,
text: ArrayList(u8),
prompt: ?[]const u8 = null,
callbacks: Callbacks = .{},
cursor: usize = 0,
active: bool = false,
options: ArrayList([]const u8),
filtered_option_indices: ArrayList(usize),
selected_option: usize = 0,
panel: ?*editor.Panel = null,

pub const Callbacks = struct {
    on_change: ?editor.Command = null,
    on_confirm: ?editor.Command = null,
    on_cancel: ?editor.Command = null,
};

pub fn init(allocator: Allocator) !*MiniBuffer {
    const self = try allocator.create(MiniBuffer);

    self.* = MiniBuffer{
        .allocator = allocator,
        .text = ArrayList(u8).init(allocator),
        .options = ArrayList([]const u8).init(allocator),
        .filtered_option_indices = ArrayList(usize).init(allocator),
    };
    return self;
}

pub fn deinit(self: *MiniBuffer) void {
    for (self.options.items) |option| {
        self.allocator.free(option);
    }
    self.options.deinit();
    self.filtered_option_indices.deinit();

    if (self.prompt) |prompt| {
        self.allocator.free(prompt);
    }

    self.text.deinit();
    self.allocator.destroy(self);
}

pub fn insert(
    self: *MiniBuffer,
    text: []const u8,
    column: usize,
) !void {
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

pub fn delete(
    self: *MiniBuffer,
    column: usize,
    codepoint_length: usize,
) !void {
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

pub fn getContent(self: *MiniBuffer, allocator: Allocator) ![]const u8 {
    return try allocator.dupe(u8, self.text.items);
}

pub fn draw(self: *MiniBuffer, rect: renderer.Rect) !void {
    const color_scheme = editor.getColorScheme();

    try renderer.setScissor(rect);
    renderer.setColor(color_scheme.getFace(.default).background);
    try renderer.drawRect(rect);

    // Only proceed to draw text if minibuffer is active
    if (!self.active) return;

    const options = editor.getOptions();
    const font = options.main_font;
    const font_size = options.main_font_size;
    const char_height = font.getCharHeight(font_size);

    const cursor_width = @divTrunc(try font.getCharAdvance(font_size, ' '), 5);

    const padding = @intCast(i32, options.minibuffer_line_padding);

    var cursor_advance: i32 = 0;

    var iter = (try std.unicode.Utf8View.init(self.text.items)).iterator();
    var codepoint_index: usize = 0;
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint_index == self.cursor) {
            break;
        }
        cursor_advance += try font.getCharAdvance(font_size, codepoint);
        codepoint_index += 1;
    }

    renderer.setColor(color_scheme.getFace(.default).foreground);

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

    const compl_display_item_count = std.math.min(
        @intCast(i32, options.minibuffer_completion_item_count),
        @intCast(i32, self.options.items.len),
    );
    const compl_height = compl_display_item_count * char_height;
    const compl_rect = renderer.Rect{
        .w = rect.w,
        .h = compl_height,
        .x = rect.x,
        .y = rect.y - compl_height,
    };

    // Draw completion options

    try renderer.setScissor(compl_rect);

    renderer.setColor(color_scheme.getFace(.border).background);
    try renderer.drawRect(compl_rect);

    var text_y = compl_rect.y + compl_rect.h;
    var i: usize = self.selected_option;
    while (i < self.filtered_option_indices.items.len) : (i += 1) {
        const option_index = self.filtered_option_indices.items[i];
        const option = self.options.items[option_index];

        text_y -= char_height;

        if (self.selected_option == i) {
            renderer.setColor(color_scheme.getFace(.selection).background);
            try renderer.drawRect(.{
                .w = compl_rect.w,
                .h = char_height,
                .x = compl_rect.x,
                .y = text_y,
            });
        }

        renderer.setColor(color_scheme.getFace(.default).foreground);
        _ = try renderer.drawText(
            option,
            font,
            font_size,
            compl_rect.x,
            text_y,
            .{},
        );
    }
}

pub fn activate(
    self: *MiniBuffer,
    panel: ?*editor.Panel,
    prompt: []const u8,
    options: []const []const u8,
    callbacks: Callbacks,
) !void {
    if (self.prompt) |existing_prompt| {
        self.allocator.free(existing_prompt);
    }
    for (self.options.items) |option| {
        self.allocator.free(option);
    }

    try self.options.resize(options.len);
    for (self.options.items) |*option, i| {
        option.* = try self.allocator.dupe(u8, options[i]);
    }

    std.sort.sort(
        []const u8,
        self.options.items,
        {},
        struct {
            fn cmp(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.cmp,
    );

    self.panel = panel;

    self.prompt = try self.allocator.dupe(u8, prompt);
    self.callbacks = callbacks;

    self.resetContent();
    self.active = true;

    try self.onChange();
}

pub fn deactivate(self: *MiniBuffer) void {
    self.active = false;
    self.resetContent();
}

fn getSelectedContent(self: *MiniBuffer) []const u8 {
    if (self.options.items.len > 0 and
        self.filtered_option_indices.items.len > 0 and
        self.selected_option < self.filtered_option_indices.items.len and
        self.filtered_option_indices.items[self.selected_option] < self.options.items.len)
    {
        return self.options.items[self.filtered_option_indices.items[self.selected_option]];
    } else {
        return self.text.items;
    }
}

fn onChange(self: *MiniBuffer) !void {
    self.selected_option = 0;

    self.filtered_option_indices.shrinkRetainingCapacity(0);

    for (self.options.items) |option, i| {
        if (self.text.items.len == 0 or
            mem.indexOf(u8, option, self.text.items) != null)
        {
            try self.filtered_option_indices.append(i);
        }
    }

    if (self.callbacks.on_change) |on_change| {
        if (self.panel) |panel| {
            try on_change(panel, &[_][]const u8{self.text.items});
        }
    }
}

pub fn onChar(
    self: *MiniBuffer,
    codepoint: u32,
) anyerror!bool {
    if (!self.active) return false;

    var text = [4]u8{ 0, 0, 0, 0 };
    var text_bytes = try std.unicode.utf8Encode(@intCast(u21, codepoint), &text);
    try self.insert(text[0..text_bytes], self.cursor);
    self.cursor += 1;

    try self.onChange();

    return true;
}

pub fn onKeySeq(
    self: *MiniBuffer,
    seq: []const u8,
) anyerror!bool {
    if (!self.active) return false;

    const allocator = self.allocator;

    const content = try allocator.dupe(u8, self.getSelectedContent());
    defer allocator.free(content);

    if (mem.eql(u8, seq, "<esc>")) {
        self.resetContent();
        self.active = false;

        if (self.callbacks.on_cancel) |on_cancel| {
            if (self.panel) |panel| {
                try on_cancel(panel, &[_][]const u8{content});
            }
        }
    } else if (mem.eql(u8, seq, "<enter>")) {
        self.resetContent();
        self.active = false;

        if (self.callbacks.on_confirm) |on_confirm| {
            if (self.panel) |panel| {
                try on_confirm(panel, &[_][]const u8{content});
            }
        }
    } else if (mem.eql(u8, seq, "<backspace>")) {
        if (self.cursor > 0) {
            self.cursor -= 1;
            try self.delete(self.cursor, 1);

            try self.onChange();
        }
    } else if (mem.eql(u8, seq, "<delete>")) {
        const text_length = try std.unicode.utf8CountCodepoints(self.text.items);
        if (self.cursor < text_length) {
            try self.delete(self.cursor, 1);

            try self.onChange();
        }
    } else if (mem.eql(u8, seq, "<left>") or mem.eql(u8, seq, "C-b")) {
        if (self.cursor > 0) {
            self.cursor -= 1;
        }
    } else if (mem.eql(u8, seq, "<right>") or mem.eql(u8, seq, "C-f")) {
        if ((self.cursor + 1) <= self.text.items.len) {
            self.cursor += 1;
        }
    } else if (mem.eql(u8, seq, "<up>") or mem.eql(u8, seq, "C-p")) {
        if ((self.selected_option + 1) < self.filtered_option_indices.items.len) {
            self.selected_option += 1;
        }
    } else if (mem.eql(u8, seq, "<down>") or mem.eql(u8, seq, "C-n")) {
        if (self.selected_option > 0) {
            self.selected_option -= 1;
        }
    } else {
        return false;
    }

    return true;
}

comptime {
    _ = MiniBuffer.init;
    _ = MiniBuffer.deinit;
    _ = MiniBuffer.insert;
    _ = MiniBuffer.delete;
    _ = MiniBuffer.resetContent;
    _ = MiniBuffer.getContent;
    _ = MiniBuffer.draw;
    _ = MiniBuffer.onChar;
    _ = MiniBuffer.onKeySeq;
}

test "minibuffer" {
    const testing = std.testing;
    const allocator = testing.allocator;
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
