const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const Allocator = std.mem.Allocator;

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
};

var g_editor: Editor = undefined;

pub fn init(allocator: *Allocator) !void {
    g_editor = Editor{
        .allocator = allocator,
        .options = .{
            .main_font = try renderer.Font.init("Cascadia Code", "regular"),
        },
        .faces = std.ArrayList(Face).init(allocator),
        .face_map = std.StringHashMap(usize).init(allocator),
    };

    try setFace("foreground", renderer.Color{ 0xff, 0xff, 0xff });
    try setFace("background", renderer.Color{ 0x0c, 0x15, 0x1b });
}

pub fn deinit() void {
    g_editor.options.main_font.deinit();
    g_editor.face_map.deinit();
    g_editor.faces.deinit();
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
