const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const WaylandWindowSystem = @import("wayland.zig").WaylandWindowSystem;

pub const key = @import("key.zig");
pub const Key = key.Key;
pub const KeyMods = key.KeyMods;
pub const KeyState = key.KeyState;

pub const WindowOptions = struct {
    opengl: bool,
};

pub const Event = union(enum) {
    dummy: void,
    configure: void,
    window_resize: struct {
        width: i32,
        height: i32,
        window: *Window,
    },
    keyboard: struct {
        key: Key,
        mods: KeyMods,
        state: KeyState,
    },
    codepoint: struct {
        codepoint: u32,
    },
    scroll: struct {
        x: f64,
        y: f64,
    },
    mouse_motion: struct {
        x: i32,
        y: i32,
    },
};

pub const WindowSystem = struct {
    deinit_fn: *const fn (self: *WindowSystem) void,
    next_event_fn: *const fn (self: *WindowSystem) ?Event,
    poll_events_fn: *const fn (self: *WindowSystem) anyerror!void,
    wait_events_fn: *const fn (self: *WindowSystem) anyerror!void,
    push_event_fn: *const fn (self: *WindowSystem, event: Event) anyerror!void,
    get_clipboard_content_alloc_fn: *const fn (
        self: *WindowSystem,
        allocator: Allocator,
    ) anyerror!?[]const u8,
    set_clipboard_content_fn: *const fn (
        self: *WindowSystem,
        content: []const u8,
    ) anyerror!void,
    gl_swap_interval_fn: *const fn (self: *WindowSystem, interval: i32) void,

    create_window_fn: *const fn (
        self: *WindowSystem,
        width: i32,
        height: i32,
        options: WindowOptions,
    ) anyerror!*Window,

    pub fn init(allocator: Allocator) anyerror!*WindowSystem {
        if (builtin.os.tag == .linux) {
            if (std.os.getenv("WAYLAND_DISPLAY") != null) {
                return WaylandWindowSystem.init(allocator);
            } else {
                return error.NoDisplayFound;
            }
        } else {
            return error.UnsupportedOS;
        }
    }

    pub fn deinit(self: *WindowSystem) void {
        self.deinit_fn(self);
    }

    pub fn nextEvent(self: *WindowSystem) ?Event {
        return self.next_event_fn(self);
    }

    pub fn pollEvents(self: *WindowSystem) anyerror!void {
        return self.poll_events_fn(self);
    }

    pub fn waitEvents(self: *WindowSystem) anyerror!void {
        return self.wait_events_fn(self);
    }

    pub fn pushEvent(self: *WindowSystem, event: Event) anyerror!void {
        return self.push_event_fn(self, event);
    }

    pub fn glSwapInterval(self: *WindowSystem, interval: i32) void {
        return self.gl_swap_interval_fn(self, interval);
    }

    pub fn createWindow(
        self: *WindowSystem,
        width: i32,
        height: i32,
        options: WindowOptions,
    ) anyerror!*Window {
        return self.create_window_fn(
            self,
            width,
            height,
            options,
        );
    }

    pub fn getClipboardContentAlloc(
        self: *WindowSystem,
        allocator: Allocator,
    ) !?[]const u8 {
        return self.get_clipboard_content_alloc_fn(self, allocator);
    }

    pub fn setClipboardContent(
        self: *WindowSystem,
        content: []const u8,
    ) !void {
        return self.set_clipboard_content_fn(self, content);
    }
};

pub const Window = struct {
    deinit_fn: *const fn (self: *Window) void,
    should_close_fn: *const fn (self: *Window) bool,
    get_size_fn: *const fn (self: *Window, width: *i32, height: *i32) void,
    gl_make_context_current_fn: *const fn (self: *Window) void,
    gl_swap_buffers_fn: *const fn (self: *Window) void,

    pub fn deinit(self: *Window) void {
        self.deinit_fn(self);
    }

    pub fn shouldClose(self: *Window) bool {
        return self.should_close_fn(self);
    }

    pub fn getSize(self: *Window, width: *i32, height: *i32) void {
        return self.get_size_fn(self, width, height);
    }

    pub fn glMakeContextCurrent(self: *Window) void {
        return self.gl_make_context_current_fn(self);
    }

    pub fn glSwapBuffers(self: *Window) void {
        return self.gl_swap_buffers_fn(self);
    }
};
