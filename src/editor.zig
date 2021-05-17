const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const Allocator = std.mem.Allocator;
const KeyMap = @import("keymap.zig").KeyMap;
const MiniBuffer = @import("minibuffer.zig").MiniBuffer;
const Buffer = @import("buffer.zig").Buffer;
const BufferPanel = @import("buffer_panel.zig").BufferPanel;
const ColorScheme = @import("highlighter.zig").ColorScheme;
const FileType = @import("filetype.zig").FileType;
const regex = @import("regex.zig");
const util = @import("util.zig");
const win = @import("window");
const mem = std.mem;

const SCRATCH_BUFFER_NAME = "** scratch **";
const BUILD_BUFFER_NAME = "** build **";
const MESSAGES_BUFFER_NAME = "** messages **";

pub const Command = fn (panel: *Panel, args: [][]const u8) anyerror!void;

pub const EditorOptions = struct {
    main_font: *renderer.Font,
    main_font_size: u32 = 18,
    scroll_margin: u32 = 5,
    status_line_padding: u32 = 4,
    minibuffer_line_padding: u32 = 4,
    border_size: u32 = 3,
    minibuffer_completion_item_count: u32 = 5,
    wild_ignore: []const u8 = "^(zig-cache|\\.git|.*\\.o|.*\\.obj|.*\\.exe|.*\\.bin)",
};

pub const KeyResult = enum {
    none,
    submap,
    command,
};

pub const TaskReq = union(enum) {
    run_build: struct {
        command: []const u8,
    },
    quit: void,
};

pub const TaskResp = union(enum) {
    build_finished: struct {
        success: bool,
        output: []const u8,
    },
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

    filetypes: std.StringArrayHashMap(*FileType),
    filetype_extensions: std.StringArrayHashMap(*FileType),
    buffers: std.ArrayList(*Buffer),

    task_req_channel: util.Channel(TaskReq, 1024) = .{},
    task_resp_channel: util.Channel(TaskResp, 1024) = .{},
    task_threads: [4]*std.Thread,
};

pub const PanelVT = struct {
    name: []const u8,

    get_status_line: fn (self: *Panel, allocator: *Allocator) anyerror![]const u8,
    get_key_map: fn (self: *Panel) *KeyMap,
    draw: fn (self: *Panel, rect: renderer.Rect) anyerror!void,
    deinit: fn (self: *Panel) void,

    on_key_seq: ?fn (self: *Panel, []const u8) anyerror!KeyResult = null,
    on_char: ?fn (self: *Panel, codepoint: u32) anyerror!bool = null,
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

    pub fn onKeySeq(panel: *Panel, seq: []const u8) anyerror!KeyResult {
        if (panel.vt.on_key_seq) |panel_on_key_seq| {
            return panel_on_key_seq(panel, seq);
        }

        return KeyResult.none;
    }

    pub fn onChar(panel: *Panel, codepoint: u32) anyerror!bool {
        if (panel.vt.on_char) |panel_on_char| {
            return panel_on_char(panel, codepoint);
        }

        return false;
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

fn onKey(key: win.Key, mods: win.KeyMods) void {
    var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];

    if (key == .escape) {
        if (g_editor.key_buffer.items.len > 0) {
            resetKeyBuffer();
            return;
        }
    }

    const maybe_seq: ?[]const u8 = KeyMap.keyToKeySeq(
        g_editor.allocator,
        key,
        mods,
    ) catch |err| {
        std.log.err("sequence onKey error: {}", .{err});
        return;
    };
    defer if (maybe_seq) |seq| {
        g_editor.allocator.free(seq);
    };

    if (maybe_seq) |seq| {
        try executeKeySeq(panel, seq);
    }
}

fn onChar(codepoint: u32) void {
    var panel: *Panel = g_editor.panels.items[g_editor.selected_panel];

    if (g_editor.minibuffer.active) {
        _ = g_editor.minibuffer.onChar(codepoint) catch |err| {
            std.log.err("minibuffer onChar error: {}", .{err});
        };
        return;
    }

    const inserted_character = panel.onChar(codepoint) catch |err| {
        std.log.err("failed to insert character: {}", .{err});
        return;
    };
    if (inserted_character) {
        return;
    }

    const maybe_seq: ?[]const u8 = KeyMap.codepointToKeySeq(
        g_editor.allocator,
        codepoint,
    ) catch |err| {
        std.log.err("sequence onChar error: {}", .{err});
        return;
    };
    defer if (maybe_seq) |seq| {
        g_editor.allocator.free(seq);
    };

    if (maybe_seq) |seq| {
        try executeKeySeq(panel, seq);
    }
}

fn executeKeySeq(panel: *Panel, partial_seq: []const u8) !void {
    if (g_editor.minibuffer.active) {
        _ = g_editor.minibuffer.onKeySeq(partial_seq) catch |err| {
            std.log.err("minibuffer onKeySeq error: {}", .{err});
        };
        return;
    }

    if (g_editor.key_buffer.items.len > 0) {
        g_editor.key_buffer.append(' ') catch unreachable;
    }
    g_editor.key_buffer.appendSlice(partial_seq) catch unreachable;

    const keymaps = [_]*KeyMap{
        panel.vt.get_key_map(panel),
        &g_editor.global_keymap,
    };

    var got_submap = false;
    for (keymaps) |keymap| {
        const result = keymap.tryExecute(
            panel,
            g_editor.key_buffer.items,
        ) catch |err| blk: {
            std.log.err("onKeySeq error: {}", .{err});
            break :blk .none;
        };

        switch (result) {
            .submap => got_submap = true,
            .command => break,
            else => {},
        }
    }

    if (!got_submap) {
        resetKeyBuffer();
    }
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

fn executeCommand(panel: *Panel, args: [][]const u8) anyerror!void {
    if (args.len != 1) return error.InvalidCommandArgs;
    const command_string = args[0];

    var parts = std.ArrayList([]const u8).init(g_editor.allocator);
    defer parts.deinit();

    var iter = std.mem.split(command_string, " ");
    while (iter.next()) |part| {
        try parts.append(part);
    }

    if (parts.items.len == 0) return;

    const command_name = parts.items[0];
    const cmd_args = parts.items[1..];

    if (g_editor.global_commands.get(command_name)) |command| {
        command(panel, cmd_args) catch |err| {
            std.log.err("error executing command: {}", .{err});
        };
    } else if (panel.vt.command_registry) |panel_command_registry| {
        if (panel_command_registry.get(command_name)) |command| {
            command(panel, cmd_args) catch |err| {
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
            try getNamedBuffer(SCRATCH_BUFFER_NAME),
        ),
    );
}

fn commandCloseSplit(panel: *Panel, args: [][]const u8) anyerror!void {
    const removed_panel = g_editor.panels.orderedRemove(g_editor.selected_panel);
    removed_panel.deinit();

    if (g_editor.panels.items.len > 0) {
        g_editor.selected_panel = std.math.min(
            g_editor.selected_panel,
            g_editor.panels.items.len - 1,
        );
    } else {
        g_editor.selected_panel = 0;
    }
}

fn taskRunner(_: void) void {
    outer: while (true) {
        const task_req = g_editor.task_req_channel.receive();
        defer renderer.pushEvent(.dummy);

        switch (task_req) {
            .run_build => |req| {
                defer g_editor.allocator.free(req.command);

                var stdout: []const u8 = "";
                var stderr: []const u8 = "";

                const run_result = util.runCommandAlloc(g_editor.allocator, .{
                    .command = req.command,
                    .stdin_text = null,
                    .stdout_text = &stdout,
                    .stderr_text = &stderr,
                });

                if (run_result) |term| {
                    const success = (term == .Exited and term.Exited == 0);

                    if (success) {
                        if (stderr.len > 0) g_editor.allocator.free(stderr);
                    } else {
                        if (stdout.len > 0) g_editor.allocator.free(stdout);
                    }

                    g_editor.task_resp_channel.send(.{
                        .build_finished = .{
                            .success = success,
                            .output = if (success) stdout else stderr,
                        },
                    }) catch |err| {
                        std.log.err("failed to send task response: {}", .{err});
                    };
                } else |err| {
                    std.log.err("failed to run build command: {}", .{err});

                    g_editor.task_resp_channel.send(.{
                        .build_finished = .{
                            .success = false,
                            .output = std.fmt.allocPrint(
                                g_editor.allocator,
                                "Failed to start command: {s}\n",
                                .{req.command},
                            ) catch unreachable,
                        },
                    }) catch |send_err| {
                        std.log.err("failed to send task response: {}", .{send_err});
                    };
                }
            },
            .quit => break :outer,
        }
    }
}

fn buildProject(panel: *Panel, args: [][]const u8) anyerror!void {
    const command: []const u8 = "zig build";
    const command_dupe = try g_editor.allocator.dupe(u8, command);

    const build_buffer = try getNamedBuffer(BUILD_BUFFER_NAME);

    const build_message = try std.fmt.allocPrint(
        g_editor.allocator,
        "Starting build: {s}\n",
        .{command},
    );
    defer g_editor.allocator.free(build_message);

    try build_buffer.clearContent();
    try build_buffer.insert(0, 0, build_message);

    try g_editor.panels.insert(
        g_editor.selected_panel + 1,
        try BufferPanel.init(g_editor.allocator, build_buffer),
    );

    try g_editor.task_req_channel.send(.{
        .run_build = .{
            .command = command_dupe,
        },
    });
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
            .main_font = try renderer.Font.init("JetBrains Mono", "semibold"),
        },

        .panel_vts = std.ArrayList(*const PanelVT).init(allocator),
        .panel_vt_map = std.StringHashMap(usize).init(allocator),

        .panels = std.ArrayList(*Panel).init(allocator),

        .global_keymap = try KeyMap.init(allocator),
        .global_commands = CommandRegistry.init(allocator),

        .minibuffer = try MiniBuffer.init(allocator),

        .key_buffer = std.ArrayList(u8).init(allocator),

        .color_scheme = try ColorScheme.jellybeansTheme(allocator),

        .buffers = std.ArrayList(*Buffer).init(allocator),
        .filetypes = std.StringArrayHashMap(*FileType).init(allocator),
        .filetype_extensions = std.StringArrayHashMap(*FileType).init(allocator),

        .task_threads = undefined,
    };

    for (g_editor.task_threads) |*task_thread| {
        task_thread.* = try std.Thread.spawn(taskRunner, {});
    }

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
            var command_count: usize = 0;
            command_count += g_editor.global_commands.commands.count();
            if (panel.vt.command_registry) |panel_command_registry| {
                command_count += panel_command_registry.commands.count();
            }

            const options = try g_editor.allocator.alloc([]const u8, command_count);
            defer g_editor.allocator.free(options);

            var command_index: usize = 0;

            for (g_editor.global_commands.commands.items()) |*entry| {
                options[command_index] = entry.key;
                command_index += 1;
            }

            if (panel.vt.command_registry) |panel_command_registry| {
                for (panel_command_registry.commands.items()) |*entry| {
                    options[command_index] = entry.key;
                    command_index += 1;
                }
            }

            try g_editor.minibuffer.activate(
                panel,
                ":",
                options,
                .{
                    .on_confirm = executeCommand,
                },
            );
        }
    }.callback);

    try g_editor.global_keymap.bind("<space> w /", commandNewSplit);
    try g_editor.global_keymap.bind("<space> w d", commandCloseSplit);

    try g_editor.global_keymap.bind("<f7>", buildProject);

    try g_editor.global_commands.register("vsp", commandNewSplit);
    try g_editor.global_commands.register("q", commandCloseSplit);

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

    try logMessage("Message 1\n", .{});
    try logMessage("Message 2\n", .{});
}

pub fn deinit() void {
    for (g_editor.task_threads) |task_thread| {
        g_editor.task_req_channel.send(.quit) catch |err| {
            std.log.err("failed to send quit task to task runner: {}", .{err});
        };
    }
    for (g_editor.task_threads) |task_thread| {
        task_thread.wait();
    }

    for (g_editor.panels.items) |panel| {
        panel.deinit();
    }

    for (g_editor.panel_vts.items) |panel_vt| {
        if (panel_vt.unregister_vt) |unregister_vt| {
            unregister_vt();
        }
    }

    for (g_editor.buffers.items) |buffer| {
        buffer.deinit();
    }

    {
        var iter = g_editor.filetypes.iterator();
        while (iter.next()) |entry| {
            entry.value.deinit();
        }
    }

    g_editor.filetypes.deinit();
    g_editor.filetype_extensions.deinit();
    g_editor.buffers.deinit();

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

pub fn getAllocator() *Allocator {
    return g_editor.allocator;
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

pub fn getBuffers() []*Buffer {
    return g_editor.buffers.items;
}

pub fn addBufferFromFile(path: []const u8) !*Buffer {
    const allocator = g_editor.allocator;

    const actual_path = try util.normalizePath(allocator, path);
    defer allocator.free(actual_path);

    for (g_editor.buffers.items) |buffer| {
        if (buffer.absolute_path) |buffer_path| {
            if (mem.eql(u8, buffer_path, actual_path)) {
                return buffer;
            }
        }
    }

    var ext = std.fs.path.extension(path);
    if (ext.len > 0 and ext[0] == '.') ext = ext[1..]; // Remove '.'
    const filetype = g_editor.filetype_extensions.get(ext) orelse getFileType("default");

    const buffer = try Buffer.initFromFile(allocator, .{
        .path = actual_path,
        .filetype = filetype,
    });
    try g_editor.buffers.append(buffer);
    return buffer;
}

pub fn getNamedBuffer(name: []const u8) !*Buffer {
    const allocator = g_editor.allocator;

    for (g_editor.buffers.items) |buffer| {
        if (mem.eql(u8, buffer.name, name)) {
            return buffer;
        }
    }

    const buffer = try Buffer.initWithContent(
        allocator,
        "",
        .{
            .name = name,
            .filetype = getFileType("default"),
        },
    );

    try g_editor.buffers.append(buffer);

    return buffer;
}

pub fn logMessage(comptime fmt: []const u8, args: anytype) !void {
    const messages_buffer = try getNamedBuffer(MESSAGES_BUFFER_NAME);
    const buf = try std.fmt.allocPrint(g_editor.allocator, fmt, args);
    defer g_editor.allocator.free(buf);

    const last_line_index = if (messages_buffer.getLineCount() > 0)
        (messages_buffer.getLineCount() - 1)
    else
        0;

    const last_line_length = try std.unicode.utf8CountCodepoints(
        try messages_buffer.getLine(last_line_index),
    );

    try messages_buffer.insert(last_line_index, last_line_length, buf);
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

pub fn registerFileType(filetype: *FileType) !void {
    if (g_editor.filetypes.get(filetype.name)) |existing_filetype| {
        existing_filetype.deinit();
    }

    try g_editor.filetypes.put(filetype.name, filetype);

    for (filetype.extensions) |ext| {
        try g_editor.filetype_extensions.put(ext, filetype);
    }
}

pub fn getFileType(name: []const u8) *FileType {
    if (g_editor.filetypes.get(name)) |filetype| {
        return filetype;
    }

    return g_editor.filetypes.get("default") orelse unreachable;
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

const DirIterator = struct {
    allocator: *Allocator,
    stack: std.ArrayList(std.fs.Dir),
    current_iterator: ?std.fs.Dir.Iterator = null,

    const Entry = struct {
        path: []const u8,
        kind: std.fs.File.Kind,
    };

    fn init(allocator: *Allocator, base_dir: std.fs.Dir) !DirIterator {
        var stack = std.ArrayList(std.fs.Dir).init(allocator);
        try stack.append(base_dir);
        return DirIterator{
            .allocator = allocator,
            .stack = stack,
        };
    }

    fn deinit(self: *const DirIterator) void {
        self.stack.deinit();
    }

    fn next(self: *DirIterator) !?Entry {
        if (self.current_iterator == null) {
            if (self.stack.popOrNull()) |dir| {
                self.current_iterator = dir.iterate();
            }
        }

        if (self.current_iterator) |iter| {
            if (try iter.next()) |entry| {
                if (entry.kind == null)
                    return Entry{
                        .path = entry.name, // TODO: full path
                        .kind = entry.kind,
                    };
            } else {
                self.current_iterator = null;
            }
        }

        if (self.stack.popOrNull()) |dir| {}

        return null;
    }
};

pub fn mainLoop() void {
    while (!renderer.shouldClose()) {
        renderer.beginFrame() catch unreachable;

        if (g_editor.panels.items.len == 0) {
            const scratch_buffer = getNamedBuffer(
                SCRATCH_BUFFER_NAME,
            ) catch unreachable;

            const panel = BufferPanel.init(
                g_editor.allocator,
                scratch_buffer,
            ) catch unreachable;

            addPanel(panel) catch unreachable;

            g_editor.selected_panel = 0;
        }

        while (g_editor.task_resp_channel.receiveOrNull()) |resp| {
            switch (resp) {
                .build_finished => |build_finished| {
                    defer g_editor.allocator.free(build_finished.output);

                    if (getNamedBuffer(BUILD_BUFFER_NAME)) |build_buffer| {
                        build_buffer.clearContent() catch continue;
                        build_buffer.insert(0, 0, build_finished.output) catch continue;

                        if (build_finished.success) {
                            build_buffer.insert(0, 0, "Build success!\n\n") catch continue;
                        } else {
                            build_buffer.insert(0, 0, "Build failed!\n\n") catch continue;
                        }
                    } else |err| {
                        std.log.err("failed to get build buffer: {}", .{err});
                    }
                },
            }
        }

        draw() catch |err| {
            std.log.err("draw error: {}", .{err});
        };

        defer renderer.endFrame() catch unreachable;
    }
}
