const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const Allocator = std.mem.Allocator;
const KeyMap = @import("keymap.zig").KeyMap;
const MiniBuffer = @import("minibuffer.zig").MiniBuffer;
const Buffer = @import("buffer.zig").Buffer;
const BufferPanel = @import("buffer_panel.zig").BufferPanel;
const ColorScheme = @import("highlighter.zig").ColorScheme;
const regex = @import("regex.zig");

pub const Command = fn (panel: *Panel, args: [][]const u8) anyerror!void;

pub const EditorOptions = struct {
    main_font: *renderer.Font,
    main_font_size: u32 = 18,
    scroll_margin: u32 = 5,
    status_line_padding: u32 = 4,
    minibuffer_line_padding: u32 = 4,
    border_size: u32 = 3,
};

pub const KeyResult = enum {
    none,
    submap,
    command,
};

const Editor = struct {
    allocator: *Allocator,
    options: EditorOptions,

    panel_vts: std.ArrayList(*const PanelVT),
    panel_vt_map: std.StringHashMap(usize),

    panels: std.ArrayList(*Panel),
    selected_panel: usize = 0,

    global_commands: CommandRegistry,
    global_keymap: KeyMap,

    minibuffer: *MiniBuffer,

    key_buffer: std.ArrayList(u8),
    color_scheme: ColorScheme,
};

pub const PanelVT = struct {
    name: []const u8,

    get_status_line: fn (self: *Panel, allocator: *Allocator) anyerror![]const u8,
    draw: fn (self: *Panel, rect: renderer.Rect) anyerror!void,
    deinit: fn (self: *Panel) void,

    on_key: ?fn (self: *Panel, key: renderer.Key, mods: u32) anyerror!KeyResult = null,
    on_char: ?fn (self: *Panel, codepoint: u32) anyerror!KeyResult = null,
    on_scroll: ?fn (self: *Panel, dx: f64, dy: f64) anyerror!void = null,

    register_vt: ?fn (allocator: *Allocator) anyerror!void = null,
    unregister_vt: ?fn () void = null,

    command_registry: ?*CommandRegistry = null,
};

pub const Panel = struct {
    vt: *const PanelVT,

    pub fn init(allocator: *Allocator, vt: *const PanelVT) !Panel {
        return Panel{
            .vt = vt,
        };
    }

    pub fn deinit(self: *Panel) void {
        self.vt.deinit(self);
    }

    pub fn onKey(panel: *Panel, key: renderer.Key, mods: u32) anyerror!KeyResult {
        if (panel.vt.on_key) |panel_on_key| {
            return panel_on_key(panel, key, mods);
        }

        return KeyResult.none;
    }

    pub fn onChar(panel: *Panel, codepoint: u32) anyerror!KeyResult {
        if (panel.vt.on_char) |panel_on_char| {
            return panel_on_char(panel, codepoint);
        }

        return KeyResult.none;
    }
};

pub const CommandRegistry = struct {
    commands: std.StringArrayHashMap(Command),

    pub fn init(allocator: *Allocator) CommandRegistry {
        return CommandRegistry{
            .commands = std.StringArrayHashMap(Command).init(allocator),
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.commands.deinit();
    }

    pub fn register(self: *CommandRegistry, name: []const u8, command: Command) !void {
        try self.commands.put(name, command);
    }

    pub fn get(self: *CommandRegistry, name: []const u8) ?Command {
        return self.commands.get(name);
    }
};

var g_editor: Editor = undefined;

fn onKey(key: renderer.Key, mods: u32) void {
    var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];

    if (key == .@"<esc>") {
        if (g_editor.key_buffer.items.len > 0) {
            resetKeyBuffer();
            return;
        }
    }

    if (g_editor.minibuffer.active) {
        _ = g_editor.minibuffer.onKey(panel, key, mods) catch |err| {
            std.log.err("minibuffer onKey error: {}", .{err});
        };
        return;
    }

    const maybe_seq: ?[]const u8 = KeyMap.keyToKeySeq(g_editor.allocator, key, mods) catch |err| {
        std.log.err("sequence onKey error: {}", .{err});
        return;
    };
    defer if (maybe_seq) |seq| {
        g_editor.allocator.free(seq);
    };

    if (maybe_seq) |seq| {
        if (g_editor.key_buffer.items.len > 0) g_editor.key_buffer.append(' ') catch unreachable;
        g_editor.key_buffer.appendSlice(seq) catch unreachable;

        var result = KeyResult.none;

        result = panel.onKey(key, mods) catch |err| blk: {
            std.log.err("panel onKey error: {}", .{err});
            break :blk .none;
        };

        if (result != .command) {
            const global_result = g_editor.global_keymap.tryExecute(
                panel,
                g_editor.key_buffer.items,
            ) catch |err| blk: {
                std.log.err("global onKey error: {}", .{err});
                break :blk .none;
            };

            if (result != .submap) result = global_result;
        }

        if (result != .submap) {
            resetKeyBuffer();
        }
    }
}

fn onChar(codepoint: u32) void {
    var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];

    if (g_editor.minibuffer.active) {
        _ = g_editor.minibuffer.onChar(panel, codepoint) catch |err| {
            std.log.err("minibuffer onChar error: {}", .{err});
        };
        return;
    }

    const maybe_seq: ?[]const u8 = KeyMap.codepointToKeySeq(g_editor.allocator, codepoint) catch |err| {
        std.log.err("sequence onChar error: {}", .{err});
        return;
    };
    defer if (maybe_seq) |seq| {
        g_editor.allocator.free(seq);
    };

    if (maybe_seq) |seq| {
        if (g_editor.key_buffer.items.len > 0) g_editor.key_buffer.append(' ') catch unreachable;
        g_editor.key_buffer.appendSlice(seq) catch unreachable;

        var result = KeyResult.none;

        result = panel.onChar(codepoint) catch |err| blk: {
            std.log.err("panel onChar error: {}", .{err});
            break :blk .none;
        };

        if (result != .command) {
            const global_result = g_editor.global_keymap.tryExecute(
                panel,
                g_editor.key_buffer.items,
            ) catch |err| blk: {
                std.log.err("global onChar error: {}", .{err});
                break :blk .none;
            };

            if (result != .submap) result = global_result;
        }

        if (result != .submap) {
            resetKeyBuffer();
        }
    }
}

pub fn getKeyBuffer() []const u8 {
    return g_editor.key_buffer.items;
}

fn resetKeyBuffer() void {
    g_editor.key_buffer.shrinkRetainingCapacity(0);
}

fn onScroll(dx: f64, dy: f64) void {
    var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];
    if (panel.vt.on_scroll) |panel_on_scroll| {
        panel_on_scroll(panel, dx, dy) catch |err| {
            std.log.err("onScroll error: {}", .{err});
        };
    }
}

fn commandHandler(panel: *Panel, command_string: []const u8) anyerror!void {
    var parts = std.ArrayList([]const u8).init(g_editor.allocator);
    defer parts.deinit();

    var iter = std.mem.split(command_string, " ");
    while (iter.next()) |part| {
        try parts.append(part);
    }

    if (parts.items.len == 0) return;

    const command_name = parts.items[0];
    const args = parts.items[1..];

    if (g_editor.global_commands.get(command_name)) |command| {
        command(panel, args) catch |err| {
            std.log.err("error executing command: {}", .{err});
        };
    } else if (panel.vt.command_registry) |panel_command_registry| {
        if (panel_command_registry.get(command_name)) |command| {
            command(panel, args) catch |err| {
                std.log.err("error executing command: {}", .{err});
            };
        }
    }
}

fn commandNewSplit(panel: *Panel, args: [][]const u8) anyerror!void {
    try g_editor.panels.insert(
        g_editor.selected_panel + 1,
        try BufferPanel.init(
            g_editor.allocator,
            try BufferPanel.getScratchBuffer(g_editor.allocator),
        ),
    );
}

fn commandCloseSplit(panel: *Panel, args: [][]const u8) anyerror!void {
    const removed_panel = g_editor.panels.orderedRemove(g_editor.selected_panel);
    removed_panel.deinit();

    if (g_editor.panels.items.len > 0) {
        g_editor.selected_panel = std.math.min(g_editor.selected_panel, g_editor.panels.items.len - 1);
    } else {
        g_editor.selected_panel = 0;
    }
}

pub fn init(allocator: *Allocator) !void {
    try renderer.init(allocator, .{
        .on_key_callback = onKey,
        .on_char_callback = onChar,
        .on_scroll_callback = onScroll,
    });
    errdefer renderer.deinit();

    try regex.initLibrary();

    g_editor = Editor{
        .allocator = allocator,

        .options = .{
            .main_font = try renderer.Font.init("Cascadia Code", "regular"),
        },

        .panel_vts = std.ArrayList(*const PanelVT).init(allocator),
        .panel_vt_map = std.StringHashMap(usize).init(allocator),

        .panels = std.ArrayList(*Panel).init(allocator),

        .global_keymap = try KeyMap.init(allocator),
        .global_commands = CommandRegistry.init(allocator),

        .minibuffer = try MiniBuffer.init(allocator),

        .key_buffer = std.ArrayList(u8).init(allocator),

        .color_scheme = try ColorScheme.jellybeansTheme(allocator),
    };

    try registerPanelVT(&@import("buffer_panel.zig").VT);

    try g_editor.global_keymap.bind("C-=", struct {
        fn callback(panel: *Panel, args: [][]const u8) anyerror!void {
            g_editor.options.main_font_size +%= 1;
            g_editor.options.main_font_size = std.math.clamp(
                g_editor.options.main_font_size,
                8,
                renderer.MAX_FONT_SIZE,
            );
        }
    }.callback);

    try g_editor.global_keymap.bind("C--", struct {
        fn callback(panel: *Panel, args: [][]const u8) anyerror!void {
            g_editor.options.main_font_size -%= 1;
            g_editor.options.main_font_size = std.math.clamp(
                g_editor.options.main_font_size,
                8,
                renderer.MAX_FONT_SIZE,
            );
        }
    }.callback);

    try g_editor.global_keymap.bind("C-j", struct {
        fn callback(panel: *Panel, args: [][]const u8) anyerror!void {
            g_editor.selected_panel +%= 1;
            g_editor.selected_panel %= (g_editor.panels.items.len);
        }
    }.callback);

    try g_editor.global_keymap.bind("C-k", struct {
        fn callback(panel: *Panel, args: [][]const u8) anyerror!void {
            g_editor.selected_panel -%= 1;
            g_editor.selected_panel %= (g_editor.panels.items.len);
        }
    }.callback);

    try g_editor.global_keymap.bind(":", struct {
        fn callback(panel: *Panel, args: [][]const u8) anyerror!void {
            try g_editor.minibuffer.activate(":", .{
                .on_confirm = commandHandler,
            });
        }
    }.callback);

    try g_editor.global_keymap.bind("<space> w /", commandNewSplit);
    try g_editor.global_keymap.bind("<space> w d", commandCloseSplit);

    try g_editor.global_commands.register("vsp", commandNewSplit);
    try g_editor.global_commands.register("q", commandCloseSplit);
}

pub fn deinit() void {
    for (g_editor.panels.items) |panel| {
        panel.deinit();
    }

    for (g_editor.panel_vts.items) |panel_vt| {
        if (panel_vt.unregister_vt) |unregister_vt| {
            unregister_vt();
        }
    }

    g_editor.key_buffer.deinit();
    g_editor.minibuffer.deinit();
    g_editor.global_keymap.deinit();
    g_editor.global_commands.deinit();
    g_editor.panels.deinit();
    g_editor.options.main_font.deinit();
    g_editor.panel_vt_map.deinit();
    g_editor.panel_vts.deinit();

    regex.deinitLibrary();

    renderer.deinit();
}

pub fn getOptions() *EditorOptions {
    return &g_editor.options;
}

pub fn getMiniBuffer() *MiniBuffer {
    return g_editor.minibuffer;
}

pub fn getColorScheme() *ColorScheme {
    return &g_editor.color_scheme;
}

pub fn addPanel(panel: *Panel) !void {
    try g_editor.panels.append(panel);
}

fn registerPanelVT(vt: *const PanelVT) !void {
    const vt_index = g_editor.panel_vts.items.len;
    try g_editor.panel_vts.append(vt);
    try g_editor.panel_vt_map.put(vt.name, vt_index);

    if (vt.register_vt) |register_vt| {
        try register_vt(g_editor.allocator);
    }
}

pub fn isPanelSelected(panel: *Panel) bool {
    for (g_editor.panels.items) |other_panel, i| {
        if (panel == other_panel) return i == g_editor.selected_panel;
    }
    return false;
}

pub fn draw() !void {
    var window_width: i32 = undefined;
    var window_height: i32 = undefined;
    try renderer.getWindowSize(&window_width, &window_height);

    const color_scheme = getColorScheme();

    const border_color = color_scheme.getFace(.border).background;
    const border_size = @intCast(i32, g_editor.options.border_size);
    const border_count = @intCast(i32, g_editor.panels.items.len - 1);

    var pw: i32 = @divTrunc(
        (window_width - (border_size * border_count)),
        @intCast(i32, g_editor.panels.items.len),
    );

    var ph: i32 = window_height;
    var px: i32 = 0;
    var py: i32 = 0;

    const char_height = g_editor.options.main_font.getCharHeight(g_editor.options.main_font_size);

    const minibuffer_padding = @intCast(i32, g_editor.options.minibuffer_line_padding);
    const minibuffer_height: i32 = (minibuffer_padding * 2) + char_height;

    for (g_editor.panels.items) |panel, i| {
        if (i == g_editor.panels.items.len - 1) {
            pw = (window_width - px);
        }

        const status_padding: i32 = @intCast(i32, g_editor.options.status_line_padding);
        const status_line_height: i32 = (status_padding * 2) + char_height;

        const panel_height = ph - status_line_height - minibuffer_height;

        // Draw panel
        {
            const inner_rect = renderer.Rect{
                .x = px,
                .y = py,
                .w = pw,
                .h = panel_height,
            };
            try renderer.setScissor(inner_rect);
            renderer.setColor(color_scheme.getFace(.default).background);
            try renderer.drawRect(inner_rect);
            panel.vt.draw(panel, inner_rect) catch |err| {
                std.log.err("Panel draw error: {}", .{err});
            };
        }

        // Draw status line
        {
            var line_background = color_scheme.getFace(.status_line).background;
            var line_foreground = color_scheme.getFace(.status_line).foreground;
            if (i == g_editor.selected_panel) {
                line_background = color_scheme.getFace(.status_line_focused).background;
                line_foreground = color_scheme.getFace(.status_line_focused).foreground;
            }

            const inner_rect = renderer.Rect{
                .x = px,
                .y = py + panel_height,
                .w = pw,
                .h = status_line_height,
            };
            try renderer.setScissor(inner_rect);
            renderer.setColor(line_background);
            try renderer.drawRect(inner_rect);

            const status_line_text = try panel.vt.get_status_line(
                panel,
                g_editor.allocator,
            );
            defer g_editor.allocator.free(status_line_text);

            renderer.setColor(line_foreground);
            _ = try renderer.drawText(
                status_line_text,
                g_editor.options.main_font,
                g_editor.options.main_font_size,
                inner_rect.x + status_padding,
                inner_rect.y + status_padding,
                .{},
            );
        }

        px += pw;

        // Draw border
        if (i != g_editor.panels.items.len - 1) {
            const border_rect = renderer.Rect{
                .x = px,
                .y = py,
                .w = border_size,
                .h = panel_height + status_line_height,
            };
            try renderer.setScissor(border_rect);
            renderer.setColor(border_color);
            try renderer.drawRect(border_rect);

            px += border_size;
        }
    }

    // Draw minibuffer
    {
        const minibuffer_rect = renderer.Rect{
            .x = 0,
            .y = window_height - minibuffer_height,
            .w = window_width,
            .h = minibuffer_height,
        };
        g_editor.minibuffer.draw(minibuffer_rect) catch |err| {
            std.log.err("Minibuffer draw error: {}", .{err});
        };
    }
}

pub fn mainLoop() void {
    while (!renderer.shouldClose()) {
        renderer.beginFrame() catch unreachable;
        defer renderer.endFrame() catch unreachable;

        if (g_editor.panels.items.len == 0) {
            const scratch_buffer = BufferPanel.getScratchBuffer(
                g_editor.allocator,
            ) catch unreachable;

            const panel = BufferPanel.init(
                g_editor.allocator,
                scratch_buffer,
            ) catch unreachable;

            addPanel(panel) catch unreachable;

            g_editor.selected_panel = 0;
        }

        draw() catch |err| {
            std.log.err("draw error: {}", .{err});
        };
    }
}
