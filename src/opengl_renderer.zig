const std = @import("std");
const glfw = @import("glfw.zig");
const gl = @import("gl.zig");
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
});

pub const Key = @import("key.zig").Key;
pub const KeyMod = @import("key.zig").KeyMod;

pub const OnKeyCallback = fn (key: Key, mods: u32) void;
pub const OnCharCallback = fn (codepoint: u32) void;
pub const OnScrollCallback = fn (dx: f64, dy: f64) void;

const Renderer = struct {
    allocator: *Allocator,

    window: *glfw.Window,
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

        var vertex_shader = gl.createShader(gl.VERTEX_SHADER);
        gl.shaderSource(vertex_shader, 1, &vertex_text.ptr, null);
        gl.compileShader(vertex_shader);
        gl.getShaderiv(vertex_shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            gl.getShaderInfoLog(vertex_shader, info_log.len, null, &info_log[0]);
            std.debug.print("Shader compile error:\n{s}\n", .{info_log});
            return error.ShaderCompileError;
        }

        var fragment_shader = gl.createShader(gl.FRAGMENT_SHADER);
        gl.shaderSource(fragment_shader, 1, &fragment_text.ptr, null);
        gl.compileShader(fragment_shader);
        gl.getShaderiv(fragment_shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            gl.getShaderInfoLog(fragment_shader, info_log.len, null, &info_log[0]);
            std.debug.print("Shader compile error:\n{s}\n", .{info_log});
            return error.ShaderCompileError;
        }

        var shader_program = gl.createProgram();
        gl.attachShader(shader_program, vertex_shader);
        gl.attachShader(shader_program, fragment_shader);
        gl.linkProgram(shader_program);
        gl.getProgramiv(shader_program, gl.LINK_STATUS, &success);
        if (success == 0) {
            gl.getProgramInfoLog(shader_program, info_log.len, null, &info_log[0]);
            std.debug.print("Shader link error:\n{s}\n", .{info_log});
            return error.ShaderLinkError;
        }

        gl.deleteShader(vertex_shader);
        gl.deleteShader(fragment_shader);

        return Program{
            .id = shader_program,
        };
    }

    fn deinit(self: *Program) void {
        gl.deleteProgram(self.id);
    }

    fn use(self: *Program) void {
        gl.useProgram(self.id);
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

const MAX_FONT_SIZE = 128;
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
    atlases: [MAX_FONT_SIZE]?*FontAtlas = [_]?*FontAtlas{null} ** MAX_FONT_SIZE,

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
                gl.deleteTextures(1, &atlas.texture);
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

    pub fn getAtlas(self: *@This(), font_size: i32) !*FontAtlas {
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

        gl.genTextures(1, &atlas.texture);
        gl.bindTexture(gl.TEXTURE_2D, atlas.texture);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA,
            atlas.width,
            atlas.height,
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
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

    try glfw.init();

    try glfw.windowHint(.ContextVersionMajor, 3);
    try glfw.windowHint(.ContextVersionMinor, 2);
    var glfw_window = try glfw.createWindow(800, 600, "Zed", null, null);

    try glfw.makeContextCurrent(glfw_window);
    try gl.load(@as(?*c_void, null), struct {
        fn callback(ctx: ?*c_void, name: [:0]const u8) ?*c_void {
            return @intToPtr(
                ?*c_void,
                @ptrToInt(glfw.getProcAddress(name) catch unreachable),
            );
        }
    }.callback);
    try glfw.swapInterval(1);

    _ = try glfw.setFramebufferSizeCallback(glfw_window, struct {
        fn callback(
            _: *glfw.Window,
            width: c_int,
            height: c_int,
        ) callconv(.C) void {}
    }.callback);

    _ = try glfw.setCharCallback(glfw_window, struct {
        fn callback(
            _: *glfw.Window,
            codepoint: c_uint,
        ) callconv(.C) void {
            g_renderer.on_char_callback(@intCast(u32, codepoint));
        }
    }.callback);

    _ = try glfw.setKeyCallback(glfw_window, struct {
        fn callback(
            _: *glfw.Window,
            key: c_int,
            scancode: c_int,
            action: c_int,
            mods: c_int,
        ) callconv(.C) void {
            if (action == @enumToInt(glfw.KeyState.Press) or action == @enumToInt(glfw.KeyState.Repeat)) {
                g_renderer.on_key_callback(@intToEnum(Key, key), @intCast(u32, mods));
            }
        }
    }.callback);

    _ = try glfw.setScrollCallback(glfw_window, struct {
        fn callback(_: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.C) void {
            g_renderer.on_scroll_callback(xoffset, yoffset);
        }
    }.callback);

    var vertex_array: u32 = 0;
    var vertex_buffer: u32 = 0;
    var index_buffer: u32 = 0;

    {
        gl.genVertexArrays(1, &vertex_array);
        gl.bindVertexArray(vertex_array);

        gl.genBuffers(1, &vertex_buffer);
        gl.genBuffers(1, &index_buffer);

        gl.bindBuffer(gl.ARRAY_BUFFER, vertex_buffer);
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, index_buffer);

        gl.vertexAttribPointer(
            0,
            2,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(Vertex),
            @intToPtr(*allowzero c_void, @byteOffsetOf(Vertex, "pos")),
        );
        gl.enableVertexAttribArray(0);

        gl.vertexAttribPointer(
            1,
            2,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(Vertex),
            @intToPtr(*allowzero c_void, @byteOffsetOf(Vertex, "texcoord")),
        );
        gl.enableVertexAttribArray(1);

        gl.vertexAttribPointer(
            2,
            4,
            gl.UNSIGNED_BYTE,
            gl.TRUE,
            @sizeOf(Vertex),
            @intToPtr(*allowzero c_void, @byteOffsetOf(Vertex, "color")),
        );
        gl.enableVertexAttribArray(2);

        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
    }

    var white_texture: u32 = 0;
    {
        var pixels: [4]u8 = [_]u8{ 255, 255, 255, 255 };
        gl.genTextures(1, &white_texture);
        gl.bindTexture(gl.TEXTURE_2D, white_texture);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA,
            1,
            1,
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            &pixels[0],
        );

        gl.bindTexture(gl.TEXTURE_2D, 0);
    }

    try glfw.setWindowUserPointer(glfw_window, @ptrCast(*c_void, &g_renderer));
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
    gl.deleteTextures(1, &g_renderer.white_texture);
    gl.deleteVertexArrays(1, &g_renderer.vertex_array);
    gl.deleteBuffers(1, &g_renderer.vertex_buffer);
    gl.deleteBuffers(1, &g_renderer.index_buffer);
    g_renderer.shader.deinit();
    g_renderer.commands.deinit();
    g_renderer.vertices.deinit();
    g_renderer.indices.deinit();
    glfw.destroyWindow(g_renderer.window) catch unreachable;
    glfw.terminate() catch unreachable;
    c.FcConfigDestroy(g_renderer.fc_config);
    c.FcFini();
}

pub fn shouldClose() bool {
    return glfw.windowShouldClose(g_renderer.window) catch unreachable;
}

pub fn beginFrame() !void {
    if (g_renderer.should_redraw) {
        try glfw.pollEvents();
    } else {
        try glfw.waitEvents();
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
    gl.enable(gl.BLEND);
    gl.enable(gl.SCISSOR_TEST);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    gl.viewport(0, 0, g_renderer.window_width, g_renderer.window_height);

    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.clearColor(0, 0, 0, 0);

    gl.bindVertexArray(g_renderer.vertex_array);

    gl.bindBuffer(gl.ARRAY_BUFFER, g_renderer.vertex_buffer);
    gl.bufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(Vertex) * @intCast(isize, g_renderer.vertices.items.len),
        g_renderer.vertices.items.ptr,
        gl.DYNAMIC_DRAW,
    );

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, g_renderer.index_buffer);
    gl.bufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @sizeOf(Index) * @intCast(isize, g_renderer.indices.items.len),
        g_renderer.indices.items.ptr,
        gl.DYNAMIC_DRAW,
    );

    g_renderer.shader.use();

    var atlas_uniform_loc = gl.getUniformLocation(g_renderer.shader.id, "atlas_texture");

    for (g_renderer.commands.items) |cmd| {
        switch (cmd) {
            .draw => |draw| {
                gl.activeTexture(gl.TEXTURE0);
                gl.bindTexture(gl.TEXTURE_2D, draw.texture);
                gl.uniform1i(atlas_uniform_loc, 0);

                gl.drawElements(
                    gl.TRIANGLES,
                    @intCast(c_int, draw.index_count),
                    if (@sizeOf(Index) == 2) gl.UNSIGNED_SHORT else gl.UNSIGNED_INT,
                    @intToPtr(?*c_void, draw.first_index * @sizeOf(Index)),
                );
            },
            .set_scissor => |scissor| {
                gl.scissor(
                    scissor.rect.x,
                    scissor.rect.y,
                    scissor.rect.w,
                    scissor.rect.h,
                );
            },
        }
    }

    gl.bindVertexArray(0);
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);

    try glfw.swapBuffers(g_renderer.window);
}

pub fn requestRedraw() void {
    g_renderer.should_redraw = true;
}

pub fn getClipboardString(allocator: *Allocator) !?[]const u8 {
    var maybe_c_str = try glfw.getClipboardString(g_renderer.window);
    if (maybe_c_str) |c_str| {
        return try allocator.dupe(u8, mem.spanZ(c_str));
    }
    return null;
}

pub fn setClipboardString(str: []const u8) !void {
    var str_z = try g_renderer.allocator.dupeZ(u8, str);
    defer g_renderer.allocator.free(str_z);
    try glfw.setClipboardString(g_renderer.window, str_z);
}

pub fn getWindowSize(w: *i32, h: *i32) !void {
    try glfw.getFramebufferSize(g_renderer.window, w, h);
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
    const atlas = try font.getAtlas(@intCast(i32, font_size));
    const glyph = atlas.getGlyph(codepoint);

    const max_ascender = font.getCharMaxAscender(@intCast(i32, font_size));

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

    const atlas = try font.getAtlas(@intCast(i32, font_size));

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
