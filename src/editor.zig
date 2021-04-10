const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const Allocator = std.mem.Allocator;
const KeyMap = @import("keymap.zig").KeyMap;

pub const EditorOptions = struct {
    main_font: *renderer.Font,
    main_font_size: u32 = 18,
    tab_width: u32 = 4,
    scroll_margin: u32 = 5,
    status_line_padding: u32 = 4,
    border_size: u32 = 2,
};

const Face = struct {
    color: renderer.Color,
};

const Editor = struct {
    allocator: *Allocator,
    options: EditorOptions,

    faces: std.ArrayList(Face),
    face_map: std.StringHashMap(usize),

    panel_vts: std.ArrayList(*const PanelVT),
    panel_vt_map: std.StringHashMap(usize),

    panels: std.ArrayList(*Panel),
    selected_panel: usize = 0,

    global_keymap: KeyMap,
};

pub const PanelVT = struct {
    name: []const u8,

    get_status_line: fn (self: *Panel, allocator: *Allocator) anyerror![]const u8,
    draw: fn (self: *Panel, rect: renderer.Rect) anyerror!void,
    deinit: fn (self: *Panel) void,

    on_key: ?fn (self: *Panel, key: renderer.Key, mods: u32) anyerror!void = null,
    on_char: ?fn (self: *Panel, codepoint: u32) anyerror!void = null,
    on_scroll: ?fn (self: *Panel, dx: f64, dy: f64) anyerror!void = null,

    register_vt: ?fn () anyerror!void = null,
    unregister_vt: ?fn () void = null,
};

pub const Panel = struct {
    vt: *const PanelVT,
};

var g_editor: Editor = undefined;

fn onKey(key: renderer.Key, mods: u32) void {
    if (!g_editor.global_keymap.onKey(key, mods)) {
        var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];
        if (panel.vt.on_key) |panel_on_key| {
            panel_on_key(panel, key, mods) catch |err| {
                std.log.info("onKey error: {}", .{err});
            };
        }
    }
}

fn onChar(codepoint: u32) void {
    if (!g_editor.global_keymap.onChar(codepoint)) {
        var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];
        if (panel.vt.on_char) |panel_on_char| {
            panel_on_char(panel, codepoint) catch |err| {
                std.log.info("onChar error: {}", .{err});
            };
        }
    }
}

fn onScroll(dx: f64, dy: f64) void {
    var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];
    if (panel.vt.on_scroll) |panel_on_scroll| {
        panel_on_scroll(panel, dx, dy) catch |err| {
            std.log.info("onScroll error: {}", .{err});
        };
    }
}

pub fn init(allocator: *Allocator) !void {
    try renderer.init(allocator, .{
        .on_key_callback = onKey,
        .on_char_callback = onChar,
        .on_scroll_callback = onScroll,
    });

    g_editor = Editor{
        .allocator = allocator,
        .options = .{
            .main_font = try renderer.Font.init("Cascadia Code", "regular"),
        },
        .faces = std.ArrayList(Face).init(allocator),
        .face_map = std.StringHashMap(usize).init(allocator),

        .panel_vts = std.ArrayList(*const PanelVT).init(allocator),
        .panel_vt_map = std.StringHashMap(usize).init(allocator),

        .panels = std.ArrayList(*Panel).init(allocator),

        .global_keymap = try KeyMap.init(allocator),
    };

    try setFace("foreground", .{ 0xff, 0xff, 0xff });
    try setFace("background", .{ 0x0c, 0x15, 0x1b });

    try setFace("border", .{ 0x30, 0x30, 0x30 });

    try setFace("status_line_background", .{ 0x30, 0x30, 0x30 });
    try setFace("status_line_foreground", .{ 0xd4, 0xf0, 0xff });

    try setFace("status_line_focused_background", .{ 0x87, 0xd7, 0xff });
    try setFace("status_line_focused_foreground", .{ 0x0c, 0x15, 0x1b });

    try registerPanelVT(&@import("buffer_panel.zig").VT);
}

pub fn deinit() void {
    for (g_editor.panels.items) |panel| {
        panel.vt.deinit(panel);
    }

    for (g_editor.panel_vts.items) |panel_vt| {
        if (panel_vt.unregister_vt) |unregister_vt| {
            unregister_vt();
        }
    }

    g_editor.global_keymap.deinit();
    g_editor.panels.deinit();
    g_editor.options.main_font.deinit();
    g_editor.face_map.deinit();
    g_editor.faces.deinit();
    g_editor.panel_vt_map.deinit();
    g_editor.panel_vts.deinit();

    renderer.deinit();
}

pub fn getOptions() *EditorOptions {
    return &g_editor.options;
}

pub fn setFace(name: []const u8, color: renderer.Color) !void {
    const face_index = if (g_editor.face_map.get(name)) |face_index| blk: {
        break :blk face_index;
    } else blk: {
        const face_index = g_editor.faces.items.len;
        try g_editor.faces.append(Face{ .color = color });
        try g_editor.face_map.put(name, face_index);
        break :blk face_index;
    };

    g_editor.faces.items[face_index] = Face{
        .color = color,
    };
}

pub fn getFace(name: []const u8) Face {
    const face_index = getFaceIndex(name);
    return g_editor.faces.items[face_index];
}

pub fn getFaceFromIndex(face_index: usize) Face {
    return g_editor.faces.items[face_index];
}

pub fn getFaceIndex(name: []const u8) usize {
    if (g_editor.face_map.get(name)) |face_index| {
        return face_index;
    }

    return 0;
}

fn registerPanelVT(vt: *const PanelVT) !void {
    const vt_index = g_editor.panel_vts.items.len;
    try g_editor.panel_vts.append(vt);
    try g_editor.panel_vt_map.put(vt.name, vt_index);

    if (vt.register_vt) |register_vt| {
        try register_vt();
    }
}

pub fn addPanel(panel: *Panel) !void {
    try g_editor.panels.append(panel);
}

pub fn draw() !void {
    var window_width: i32 = undefined;
    var window_height: i32 = undefined;
    try renderer.getWindowSize(&window_width, &window_height);

    const border_color = getFace("border").color;
    const border_size = @intCast(i32, g_editor.options.border_size);
    const border_count = @intCast(i32, g_editor.panels.items.len - 1);

    var pw: i32 = @divTrunc(
        (window_width - (border_size * border_count)),
        @intCast(i32, g_editor.panels.items.len),
    );

    var ph: i32 = window_height;
    var px: i32 = 0;
    var py: i32 = 0;

    for (g_editor.panels.items) |panel, i| {
        if (i == g_editor.panels.items.len - 1) {
            pw = (window_width - px);
        }

        const char_height = g_editor.options.main_font.getCharHeight(g_editor.options.main_font_size);
        const status_padding: i32 = @intCast(i32, g_editor.options.status_line_padding);
        const status_line_height: i32 = (status_padding * 2) + char_height;

        {
            var line_background = getFace("status_line_background").color;
            var line_foreground = getFace("status_line_foreground").color;
            if (i == g_editor.selected_panel) {
                line_background = getFace("status_line_focused_background").color;
                line_foreground = getFace("status_line_focused_foreground").color;
            }

            const inner_rect = renderer.Rect{
                .x = px,
                .y = py,
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
                px + status_padding,
                py + status_padding,
                .{},
            );
        }

        {
            const inner_rect = renderer.Rect{
                .x = px,
                .y = py + status_line_height,
                .w = pw,
                .h = ph - status_line_height,
            };
            try renderer.setScissor(inner_rect);
            renderer.setColor(getFace("background").color);
            try renderer.drawRect(inner_rect);
            try panel.vt.draw(panel, inner_rect);
        }

        px += pw;

        if (i != g_editor.panels.items.len - 1) {
            const border_rect = renderer.Rect{
                .x = px,
                .y = py,
                .w = border_size,
                .h = ph,
            };
            try renderer.setScissor(border_rect);
            renderer.setColor(border_color);
            try renderer.drawRect(border_rect);

            px += border_size;
        }
    }
}

pub fn mainLoop() void {
    while (!renderer.shouldClose()) {
        renderer.beginFrame() catch unreachable;
        defer renderer.endFrame() catch unreachable;

        draw() catch {};
    }
}
