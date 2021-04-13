const std = @import("std");
const log = std.log;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("fontconfig/fontconfig.h");
    @cInclude("epoxy/gl.h");
    @cInclude("GLFW/glfw3.h");
});

pub const Key = @import("key.zig").Key;
pub const KeyMod = @import("key.zig").KeyMod;

pub const OnKeyCallback = fn (key: Key, mods: u32) void;
pub const OnCharCallback = fn (codepoint: u32) void;
pub const OnScrollCallback = fn (dx: f64, dy: f64) void;

const Renderer = struct {
    allocator: *Allocator,

    window: *c.GLFWwindow,
    shader: Program,
    vertex_buffer: u32,
    index_buffer: u32,
    vertex_array: u32,
    white_texture: u32,
    should_redraw: bool = false,

    vertices: ArrayList(Vertex),
    indices: ArrayList(Index),
    commands: ArrayList(Command),

    fc_config: *c.FcConfig,
    ft_library: c.FT_Library,

    last_draw_indexed_command: ?usize = null,
    current_color: Color = Color{ 255, 255, 255 },

    window_width: i32 = 0,
    window_height: i32 = 0,

    on_key_callback: OnKeyCallback,
    on_char_callback: OnCharCallback,
    on_scroll_callback: OnScrollCallback,
};

var g_renderer: Renderer = undefined;

const Vertex = extern struct {
    pos: [2]f32,
    texcoord: [2]f32,
    color: [4]u8,
};

const Index = u32;

pub const Color = [3]u8;

const VERTEX_SHADER =
    \\#version 330
    \\layout (location = 0) in vec2 a_pos;
    \\layout (location = 1) in vec2 a_texcoord;
    \\layout (location = 2) in vec4 a_color;
    \\out vec2 f_texcoord;
    \\out vec4 f_color;
    \\void main() {
    \\  gl_Position = vec4(a_pos, 0.0, 1.0);
    \\  f_texcoord = a_texcoord;
    \\  f_color = a_color;
    \\}
;

const FRAGMENT_SHADER =
    \\#version 330
    \\out vec4 out_color;
    \\in vec2 f_texcoord;
    \\in vec4 f_color;
    \\uniform sampler2D atlas_texture;
    \\void main() {
    \\  out_color = texture(atlas_texture, f_texcoord) * f_color;
    \\}
;

const Program = struct {
    id: u32,

    fn init(vertex_text: [:0]const u8, fragment_text: [:0]const u8) !Program {
        var success: c_int = 0;
        var info_log: [512:0]u8 = undefined;
        info_log[0] = 0;

        var vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
        c.glShaderSource(vertex_shader, 1, &vertex_text.ptr, null);
        c.glCompileShader(vertex_shader);
        c.glGetShaderiv(vertex_shader, c.GL_COMPILE_STATUS, &success);
        if (success == 0) {
            c.glGetShaderInfoLog(vertex_shader, info_log.len, null, &info_log[0]);
            std.debug.print("Shader compile error:\n{s}\n", .{info_log});
            return error.ShaderCompileError;
        }

        var fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
        c.glShaderSource(fragment_shader, 1, &fragment_text.ptr, null);
        c.glCompileShader(fragment_shader);
        c.glGetShaderiv(fragment_shader, c.GL_COMPILE_STATUS, &success);
        if (success == 0) {
            c.glGetShaderInfoLog(fragment_shader, info_log.len, null, &info_log[0]);
            std.debug.print("Shader compile error:\n{s}\n", .{info_log});
            return error.ShaderCompileError;
        }

        var shader_program = c.glCreateProgram();
        c.glAttachShader(shader_program, vertex_shader);
        c.glAttachShader(shader_program, fragment_shader);
        c.glLinkProgram(shader_program);
        c.glGetProgramiv(shader_program, c.GL_LINK_STATUS, &success);
        if (success == 0) {
            c.glGetProgramInfoLog(shader_program, info_log.len, null, &info_log[0]);
            std.debug.print("Shader link error:\n{s}\n", .{info_log});
            return error.ShaderLinkError;
        }

        c.glDeleteShader(vertex_shader);
        c.glDeleteShader(fragment_shader);

        return Program{
            .id = shader_program,
        };
    }

    fn deinit(self: *Program) void {
        c.glDeleteProgram(self.id);
    }

    fn use(self: *Program) void {
        c.glUseProgram(self.id);
    }
};

const Glyph = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    yoff: i32,
    xoff: i32,
    advance: i32,
};

pub const MAX_FONT_SIZE = 128;
const MAX_CODEPOINT = 256;

const FontAtlas = struct {
    width: i32,
    height: i32,
    texture: u32,
    glyphs: [MAX_CODEPOINT + 1]Glyph,

    fn getGlyph(self: *@This(), codepoint: u32) *Glyph {
        if (codepoint > MAX_CODEPOINT) {
            log.err("failed to get glyph for codepoint: {}", .{codepoint});
            return &self.glyphs[0];
        }
        return &self.glyphs[codepoint];
    }
};

pub const Font = struct {
    data: []u8,
    face: c.FT_Face,
    atlases: [MAX_FONT_SIZE + 1]?*FontAtlas = [_]?*FontAtlas{null} ** (MAX_FONT_SIZE + 1),

    pub fn init(base_font_name: []const u8, style: []const u8) !*Font {
        const full_font_name = try mem.concat(
            g_renderer.allocator,
            u8,
            &[_][]const u8{ base_font_name, ":", style },
        );
        defer g_renderer.allocator.free(full_font_name);

        const full_font_name_z = try g_renderer.allocator.dupeZ(u8, full_font_name);
        defer g_renderer.allocator.free(full_font_name_z);

        var path = try getPath(g_renderer.allocator, full_font_name_z);
        defer g_renderer.allocator.destroy(path);

        const file = try std.fs.openFileAbsolute(mem.spanZ(path), .{ .read = true });
        defer file.close();

        const stat = try file.stat();
        const file_data = try file.readToEndAlloc(g_renderer.allocator, stat.size);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(
            g_renderer.ft_library,
            file_data.ptr,
            @intCast(c_long, file_data.len),
            0,
            &face,
        ) != 0) {
            return error.FreeTypeLoadFaceError;
        }

        var self = try g_renderer.allocator.create(Font);
        self.* = .{
            .data = file_data,
            .face = face,
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        _ = c.FT_Done_Face(self.face);
        for (self.atlases) |maybe_atlas| {
            if (maybe_atlas) |atlas| {
                c.glDeleteTextures(1, &atlas.texture);
                g_renderer.allocator.destroy(atlas);
            }
        }
        g_renderer.allocator.free(self.data);
        g_renderer.allocator.destroy(self);
    }

    fn getPath(allocator: *Allocator, font_name: [*:0]const u8) ![*:0]const u8 {
        var pat: *c.FcPattern = c.FcNameParse(font_name) orelse return error.FontConfigFailedToParseName;
        defer c.FcPatternDestroy(pat);

        _ = c.FcConfigSubstitute(
            g_renderer.fc_config,
            pat,
            @intToEnum(c.enum__FcMatchKind, c.FcMatchPattern),
        );
        c.FcDefaultSubstitute(pat);

        var result: c.FcResult = undefined;
        var font: *c.FcPattern = c.FcFontMatch(
            g_renderer.fc_config,
            pat,
            &result,
        ) orelse return error.FontConfigFailedToMatchFont;
        defer c.FcPatternDestroy(font);

        var file: [*c]u8 = undefined;
        if (c.FcPatternGetString(
            font,
            c.FC_FILE,
            0,
            &file,
        ) == @intToEnum(c.enum__FcResult, c.FcResultMatch)) {
            return try allocator.dupeZ(u8, mem.spanZ(file));
        }

        return error.FontConfigFailedToGetPath;
    }

    pub fn getAtlas(self: *@This(), font_size: u32) !*FontAtlas {
        std.debug.assert(font_size <= MAX_FONT_SIZE);

        if (self.atlases[@intCast(usize, font_size)]) |atlas| return atlas;

        var atlas = try g_renderer.allocator.create(FontAtlas);

        _ = c.FT_Set_Char_Size(self.face, 0, font_size << 6, 72, 72);

        var max_dim = (1 + @intCast(u32, self.face.*.size.*.metrics.height >> 6)) *
            @floatToInt(u32, std.math.ceil(std.math.sqrt(@as(f64, MAX_CODEPOINT))));
        var tex_width: u32 = 1;
        while (tex_width < max_dim) {
            tex_width <<= 1;
        }
        var tex_height: u32 = tex_width;

        atlas.width = @intCast(i32, tex_width);
        atlas.height = @intCast(i32, tex_height);

        var pixels: []u8 = try g_renderer.allocator.alloc(
            u8,
            @intCast(usize, atlas.width * atlas.height * 4),
        );
        defer g_renderer.allocator.free(pixels);

        var pen_x: u32 = 0;
        var pen_y: u32 = 0;

        var i: u32 = 0;
        while (i < MAX_CODEPOINT + 1) : (i += 1) {
            _ = c.FT_Load_Char(
                self.face,
                i,
                c.FT_LOAD_RENDER | c.FT_LOAD_FORCE_AUTOHINT | c.FT_LOAD_TARGET_LIGHT,
            );
            var bmp: *c.FT_Bitmap = &self.face.*.glyph.*.bitmap;

            if (pen_x + bmp.width >= tex_width) {
                pen_x = 0;
                pen_y += @intCast(u32, (self.face.*.size.*.metrics.height >> 6) + 1);
            }

            var row: u32 = 0;
            while (row < bmp.rows) : (row += 1) {
                var col: u32 = 0;
                while (col < bmp.width) : (col += 1) {
                    var x = pen_x + col;
                    var y = pen_y + row;
                    var value: u8 = bmp.buffer[row * @intCast(u32, bmp.pitch) + col];
                    pixels[(y * tex_width + x) * 4 + 0] = 255;
                    pixels[(y * tex_width + x) * 4 + 1] = 255;
                    pixels[(y * tex_width + x) * 4 + 2] = 255;
                    pixels[(y * tex_width + x) * 4 + 3] = value;
                }
            }

            atlas.glyphs[i].x = @intCast(i32, pen_x);
            atlas.glyphs[i].y = @intCast(i32, pen_y);
            atlas.glyphs[i].w = @intCast(i32, bmp.width);
            atlas.glyphs[i].h = @intCast(i32, bmp.rows);

            atlas.glyphs[i].yoff = self.face.*.glyph.*.bitmap_top;
            atlas.glyphs[i].xoff = self.face.*.glyph.*.bitmap_left;
            atlas.glyphs[i].advance = @intCast(i32, self.face.*.glyph.*.advance.x >> 6);

            pen_x += bmp.width + 1;
        }

        c.glGenTextures(1, &atlas.texture);
        c.glBindTexture(c.GL_TEXTURE_2D, atlas.texture);

        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);

        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            atlas.width,
            atlas.height,
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pixels.ptr,
        );

        self.atlases[@intCast(usize, font_size)] = atlas;

        return atlas;
    }

    pub fn getCharHeight(self: *@This(), font_size: u32) i32 {
        return @floatToInt(i32, std.math.round(
            @intToFloat(f64, self.face.*.height * @intCast(i32, font_size)) / @intToFloat(f64, self.face.*.units_per_EM),
        ));
    }

    pub fn getCharAdvance(self: *@This(), font_size: u32, codepoint: u32) !i32 {
        const atlas = try self.getAtlas(font_size);
        const glyph = atlas.getGlyph(codepoint);
        return glyph.advance;
    }

    pub fn getCharMaxAscender(self: *@This(), font_size: u32) i32 {
        return @floatToInt(i32, std.math.round(
            @intToFloat(f64, self.face.*.ascender * @intCast(i32, font_size)) / @intToFloat(f64, self.face.*.units_per_EM),
        ));
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const CommandTag = enum {
    draw,
    set_scissor,
};

const Command = union(CommandTag) {
    draw: struct {
        texture: u32,
        first_index: u32,
        index_count: u32,
    },
    set_scissor: struct {
        rect: Rect,
    },
};

pub fn init(
    allocator: *Allocator,
    options: struct {
        on_key_callback: OnKeyCallback,
        on_char_callback: OnCharCallback,
        on_scroll_callback: OnScrollCallback,
    },
) !void {
    if (c.FcInit() != c.FcTrue) {
        return error.FontConfigInitError;
    }
    var fc_config = c.FcInitLoadConfigAndFonts() orelse return error.FontConfigInitError;

    var ft_library: c.FT_Library = null;
    if (c.FT_Init_FreeType(&ft_library) != 0) {
        return error.FreetypeInitError;
    }

    if (c.glfwInit() != c.GLFW_TRUE) {
        return error.GlfwInitError;
    }

    _ = c.glfwSetErrorCallback(struct {
        fn callback(error_code: c_int, description: [*c]const u8) callconv(.C) void {
            std.log.err("{s}", .{description});
        }
    }.callback);

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 2);
    var glfw_window = c.glfwCreateWindow(800, 600, "Zed", null, null) orelse return error.GlfwInitError;

    c.glfwMakeContextCurrent(glfw_window);
    c.glfwSwapInterval(1);

    _ = c.glfwSetFramebufferSizeCallback(glfw_window, struct {
        fn callback(
            _: ?*c.GLFWwindow,
            width: c_int,
            height: c_int,
        ) callconv(.C) void {}
    }.callback);

    _ = c.glfwSetCharCallback(glfw_window, struct {
        fn callback(
            _: ?*c.GLFWwindow,
            codepoint: c_uint,
        ) callconv(.C) void {
            g_renderer.on_char_callback(@intCast(u32, codepoint));
        }
    }.callback);

    _ = c.glfwSetKeyCallback(glfw_window, struct {
        fn callback(
            _: ?*c.GLFWwindow,
            key: c_int,
            scancode: c_int,
            action: c_int,
            mods: c_int,
        ) callconv(.C) void {
            if (action == c.GLFW_PRESS or action == c.GLFW_REPEAT) {
                g_renderer.on_key_callback(@intToEnum(Key, key), @intCast(u32, mods));
            }
        }
    }.callback);

    _ = c.glfwSetScrollCallback(glfw_window, struct {
        fn callback(_: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.C) void {
            g_renderer.on_scroll_callback(xoffset, yoffset);
        }
    }.callback);

    var vertex_array: u32 = 0;
    var vertex_buffer: u32 = 0;
    var index_buffer: u32 = 0;

    {
        c.glGenVertexArrays(1, &vertex_array);
        c.glBindVertexArray(vertex_array);

        c.glGenBuffers(1, &vertex_buffer);
        c.glGenBuffers(1, &index_buffer);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, vertex_buffer);
        c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, index_buffer);

        c.glVertexAttribPointer(
            0,
            2,
            c.GL_FLOAT,
            c.GL_FALSE,
            @sizeOf(Vertex),
            @intToPtr(*allowzero c_void, @byteOffsetOf(Vertex, "pos")),
        );
        c.glEnableVertexAttribArray(0);

        c.glVertexAttribPointer(
            1,
            2,
            c.GL_FLOAT,
            c.GL_FALSE,
            @sizeOf(Vertex),
            @intToPtr(*allowzero c_void, @byteOffsetOf(Vertex, "texcoord")),
        );
        c.glEnableVertexAttribArray(1);

        c.glVertexAttribPointer(
            2,
            4,
            c.GL_UNSIGNED_BYTE,
            c.GL_TRUE,
            @sizeOf(Vertex),
            @intToPtr(*allowzero c_void, @byteOffsetOf(Vertex, "color")),
        );
        c.glEnableVertexAttribArray(2);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, 0);
        c.glBindVertexArray(0);
    }

    var white_texture: u32 = 0;
    {
        var pixels: [4]u8 = [_]u8{ 255, 255, 255, 255 };
        c.glGenTextures(1, &white_texture);
        c.glBindTexture(c.GL_TEXTURE_2D, white_texture);

        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);

        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            1,
            1,
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            &pixels[0],
        );

        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    c.glfwSetWindowUserPointer(glfw_window, @ptrCast(*c_void, &g_renderer));
    g_renderer.allocator = allocator;
    g_renderer.fc_config = fc_config;

    g_renderer = Renderer{
        .allocator = allocator,
        .window = glfw_window,
        .shader = try Program.init(VERTEX_SHADER, FRAGMENT_SHADER),
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .vertex_array = vertex_array,
        .white_texture = white_texture,

        .commands = ArrayList(Command).init(allocator),
        .vertices = try ArrayList(Vertex).initCapacity(allocator, 1 << 14),
        .indices = try ArrayList(Index).initCapacity(allocator, 1 << 14),

        .fc_config = fc_config,
        .ft_library = ft_library,

        .on_key_callback = options.on_key_callback,
        .on_char_callback = options.on_char_callback,
        .on_scroll_callback = options.on_scroll_callback,
    };
}

pub fn deinit() void {
    c.glDeleteTextures(1, &g_renderer.white_texture);
    c.glDeleteVertexArrays(1, &g_renderer.vertex_array);
    c.glDeleteBuffers(1, &g_renderer.vertex_buffer);
    c.glDeleteBuffers(1, &g_renderer.index_buffer);
    g_renderer.shader.deinit();
    g_renderer.commands.deinit();
    g_renderer.vertices.deinit();
    g_renderer.indices.deinit();
    c.glfwDestroyWindow(g_renderer.window);
    c.glfwTerminate();
    c.FcConfigDestroy(g_renderer.fc_config);
    c.FcFini();
}

pub fn shouldClose() bool {
    return c.glfwWindowShouldClose(g_renderer.window) == c.GLFW_TRUE;
}

pub fn beginFrame() !void {
    if (g_renderer.should_redraw) {
        c.glfwPollEvents();
    } else {
        c.glfwWaitEvents();
    }
    g_renderer.should_redraw = false;

    g_renderer.commands.shrinkRetainingCapacity(0);
    g_renderer.vertices.shrinkRetainingCapacity(0);
    g_renderer.indices.shrinkRetainingCapacity(0);
    g_renderer.last_draw_indexed_command = null;

    try getWindowSize(&g_renderer.window_width, &g_renderer.window_height);

    try setScissor(.{
        .x = 0,
        .y = 0,
        .w = g_renderer.window_width,
        .h = g_renderer.window_height,
    });
}

pub fn endFrame() !void {
    c.glEnable(c.GL_BLEND);
    c.glEnable(c.GL_SCISSOR_TEST);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    c.glViewport(0, 0, g_renderer.window_width, g_renderer.window_height);

    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
    c.glClearColor(0, 0, 0, 0);

    c.glBindVertexArray(g_renderer.vertex_array);

    c.glBindBuffer(c.GL_ARRAY_BUFFER, g_renderer.vertex_buffer);
    c.glBufferData(
        c.GL_ARRAY_BUFFER,
        @sizeOf(Vertex) * @intCast(isize, g_renderer.vertices.items.len),
        g_renderer.vertices.items.ptr,
        c.GL_DYNAMIC_DRAW,
    );

    c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, g_renderer.index_buffer);
    c.glBufferData(
        c.GL_ELEMENT_ARRAY_BUFFER,
        @sizeOf(Index) * @intCast(isize, g_renderer.indices.items.len),
        g_renderer.indices.items.ptr,
        c.GL_DYNAMIC_DRAW,
    );

    g_renderer.shader.use();

    var atlas_uniform_loc = c.glGetUniformLocation(g_renderer.shader.id, "atlas_texture");

    for (g_renderer.commands.items) |cmd| {
        switch (cmd) {
            .draw => |draw| {
                c.glActiveTexture(c.GL_TEXTURE0);
                c.glBindTexture(c.GL_TEXTURE_2D, draw.texture);
                c.glUniform1i(atlas_uniform_loc, 0);

                c.glDrawElements(
                    c.GL_TRIANGLES,
                    @intCast(c_int, draw.index_count),
                    if (@sizeOf(Index) == 2) c.GL_UNSIGNED_SHORT else c.GL_UNSIGNED_INT,
                    @intToPtr(?*c_void, draw.first_index * @sizeOf(Index)),
                );
            },
            .set_scissor => |scissor| {
                c.glScissor(
                    scissor.rect.x,
                    scissor.rect.y,
                    scissor.rect.w,
                    scissor.rect.h,
                );
            },
        }
    }

    c.glBindVertexArray(0);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, 0);

    c.glfwSwapBuffers(g_renderer.window);
}

pub fn requestRedraw() void {
    g_renderer.should_redraw = true;
}

pub fn getClipboardString(allocator: *Allocator) !?[]const u8 {
    var maybe_c_str = c.glfwGetClipboardString(g_renderer.window);
    if (maybe_c_str) |c_str| {
        return try allocator.dupe(u8, mem.spanZ(c_str));
    }
    return null;
}

pub fn setClipboardString(str: []const u8) !void {
    var str_z = try g_renderer.allocator.dupeZ(u8, str);
    defer g_renderer.allocator.free(str_z);
    c.glfwSetClipboardString(g_renderer.window, str_z);
}

pub fn getWindowSize(w: *i32, h: *i32) !void {
    c.glfwGetFramebufferSize(g_renderer.window, w, h);
}

fn pushCommand(cmd: Command) !void {
    g_renderer.last_draw_indexed_command = null;
    if (cmd == .draw) {
        g_renderer.last_draw_indexed_command = g_renderer.commands.items.len;
    }
    try g_renderer.commands.append(cmd);
}

pub fn setColor(color: Color) void {
    g_renderer.current_color = color;
}

pub fn setScissor(rect: Rect) !void {
    var win_width: i32 = undefined;
    var win_height: i32 = undefined;
    try getWindowSize(&win_width, &win_height);

    const cmd = Command{
        .set_scissor = .{ .rect = Rect{
            .x = rect.x,
            .y = win_height - rect.y - rect.h,
            .w = rect.w,
            .h = rect.h,
        } },
    };
    try pushCommand(cmd);
}

pub fn drawRect(
    rect: Rect,
) !void {
    try drawRectInternal(
        &rect,
        &Rect{ .x = 0, .y = 0, .w = 1, .h = 1 },
        g_renderer.white_texture,
        1,
        1,
    );
}

pub fn drawCodepoint(
    codepoint: u32,
    font: *Font,
    font_size: u32,
    x: i32,
    y: i32,
) !i32 {
    const atlas = try font.getAtlas(font_size);
    const glyph = atlas.getGlyph(codepoint);

    const max_ascender = font.getCharMaxAscender(font_size);

    switch (codepoint) {
        '\t' | '\n' | '\r' => {},
        else => {
            try drawRectInternal(
                &Rect{
                    .x = x + glyph.*.xoff,
                    .y = y + (max_ascender - glyph.*.yoff),
                    .w = glyph.*.w,
                    .h = glyph.*.h,
                },
                &Rect{
                    .x = glyph.*.x,
                    .y = glyph.*.y,
                    .w = glyph.*.w,
                    .h = glyph.*.h,
                },
                atlas.texture,
                @intCast(u32, atlas.width),
                @intCast(u32, atlas.height),
            );
        },
    }

    return glyph.*.advance;
}

pub fn drawText(
    text: []const u8,
    font: *Font,
    font_size: u32,
    x: i32,
    y: i32,
    options: struct {
        tab_width: i32 = 4,
    },
) !i32 {
    var advance: i32 = 0;

    const atlas = try font.getAtlas(font_size);

    const max_ascender = font.getCharMaxAscender(font_size);

    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        const glyph = atlas.getGlyph(codepoint);

        var glyph_advance = glyph.*.advance;

        switch (codepoint) {
            '\t' => {
                glyph_advance *= options.tab_width;
            },
            '\n' | '\r' => {},
            else => {
                try drawRectInternal(
                    &Rect{
                        .x = advance + x + glyph.*.xoff,
                        .y = y + (max_ascender - glyph.*.yoff),
                        .w = glyph.*.w,
                        .h = glyph.*.h,
                    },
                    &Rect{
                        .x = glyph.*.x,
                        .y = glyph.*.y,
                        .w = glyph.*.w,
                        .h = glyph.*.h,
                    },
                    atlas.texture,
                    @intCast(u32, atlas.width),
                    @intCast(u32, atlas.height),
                );
            },
        }

        advance += glyph_advance;
    }

    return advance;
}

fn drawRectInternal(
    quad_rect: *const Rect,
    tex_rect: *const Rect,
    texture: u32,
    texture_width: u32,
    texture_height: u32,
) !void {
    var draw_command: *Command = if (g_renderer.last_draw_indexed_command) |cmd_index| blk: {
        var cmd = &g_renderer.commands.items[cmd_index];
        if (cmd.draw.texture != texture or cmd.draw.first_index + cmd.draw.index_count != g_renderer.indices.items.len) {
            const new_cmd = Command{
                .draw = .{
                    .texture = texture,
                    .first_index = @intCast(u32, g_renderer.indices.items.len),
                    .index_count = 0,
                },
            };
            try pushCommand(new_cmd);
            break :blk &g_renderer.commands.items[g_renderer.commands.items.len - 1];
        }
        break :blk cmd;
    } else blk: {
        const new_cmd = Command{
            .draw = .{
                .texture = texture,
                .first_index = @intCast(u32, g_renderer.indices.items.len),
                .index_count = 0,
            },
        };
        try pushCommand(new_cmd);
        break :blk &g_renderer.commands.items[g_renderer.commands.items.len - 1];
    };

    const win_width = @intToFloat(f32, g_renderer.window_width);
    const win_height = @intToFloat(f32, g_renderer.window_height);

    var x1 = @intToFloat(f32, quad_rect.x) / win_width;
    x1 = (x1 * 2.0) - 1.0;
    var y1 = (win_height - @intToFloat(f32, quad_rect.y)) / win_height;
    y1 = (y1 * 2.0) - 1.0;

    var x2 = @intToFloat(f32, quad_rect.x + quad_rect.w) / win_width;
    x2 = (x2 * 2.0) - 1.0;
    var y2 = (win_height - @intToFloat(f32, quad_rect.y + quad_rect.h)) / win_height;
    y2 = (y2 * 2.0) - 1.0;

    const tx1 = @intToFloat(f32, tex_rect.x) / @intToFloat(f32, texture_width);
    const ty1 = @intToFloat(f32, tex_rect.y) / @intToFloat(f32, texture_height);

    const tx2 = @intToFloat(f32, tex_rect.x + tex_rect.w) / @intToFloat(f32, texture_width);
    const ty2 = @intToFloat(f32, tex_rect.y + tex_rect.h) / @intToFloat(f32, texture_height);

    const col = [4]u8{
        g_renderer.current_color[0],
        g_renderer.current_color[1],
        g_renderer.current_color[2],
        255,
    };

    const vertices = [4]Vertex{
        .{
            .pos = .{ x1, y2 },
            .texcoord = .{ tx1, ty2 },
            .color = col,
        },
        .{
            .pos = .{ x1, y1 },
            .texcoord = .{ tx1, ty1 },
            .color = col,
        },
        .{
            .pos = .{ x2, y2 },
            .texcoord = .{ tx2, ty2 },
            .color = col,
        },
        .{
            .pos = .{ x2, y1 },
            .texcoord = .{ tx2, ty1 },
            .color = col,
        },
    };

    const vertices_base = @intCast(Index, g_renderer.vertices.items.len);
    const indices = [6]Index{
        vertices_base + 0,
        vertices_base + 1,
        vertices_base + 2,
        vertices_base + 1,
        vertices_base + 3,
        vertices_base + 2,
    };

    try g_renderer.vertices.appendSlice(&vertices);
    try g_renderer.indices.appendSlice(&indices);

    draw_command.draw.index_count += @intCast(u32, indices.len);
}
