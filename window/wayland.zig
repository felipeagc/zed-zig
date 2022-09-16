const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("epoxy/egl.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-names.h");
    @cInclude("xkbcommon/xkbcommon-compose.h");
});

const common = @import("common.zig");
const keys = @import("key.zig");

const Event = common.Event;
const WindowSystem = common.WindowSystem;
const WindowOptions = common.WindowOptions;
const Window = common.Window;
const Key = keys.Key;
const KeyMods = keys.KeyMods;
const KeyState = keys.KeyState;
const xkbKeysymToKey = keys.xkbKeysymToKey;

pub const WaylandWindowSystem = struct {
    allocator: Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    egl_display: c.EGLDisplay = null,

    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,

    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,

    data_device_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    keyboard_enter_serial: u32 = 0,

    cursor_theme: ?*wl.CursorTheme = null,
    cursor_left_ptr: ?Cursor = null,

    repeat_rate: i32 = 30,
    repeat_delay: i32 = 300,
    repeat_timer: ?std.time.Timer = null,
    repeat_count: u64 = 0,
    repeat_keycode: ?c.xkb_keycode_t = null,

    xkb_context: *c.struct_xkb_context,
    xkb_compose_table: *c.struct_xkb_compose_table,
    xkb_compose_state: *c.struct_xkb_compose_state,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    queue_mutex: std.Thread.Mutex = .{},
    event_write_fd: std.os.fd_t,
    event_read_fd: std.os.fd_t,
    event_queue: [4096]Event = undefined,
    event_queue_head: usize = 0,
    event_queue_tail: usize = 0,

    clipboard_content: std.ArrayList(u8),

    window_system: WindowSystem,

    const Cursor = struct {
        cursor: *wl.Cursor,
        image: *wl.CursorImage,
        surface: *wl.Surface,

        fn init(window_system: *WaylandWindowSystem, name: [*:0]const u8) !Cursor {
            const cursor = window_system.cursor_theme.?.getCursor(name) orelse return error.WaylandWindowSystemInvalidCursor;
            const image = cursor.images[0];
            const buffer = try image.getBuffer();
            const surface = try window_system.compositor.?.createSurface();
            surface.attach(buffer, 0, 0);
            surface.commit();

            return Cursor{
                .cursor = cursor,
                .image = image,
                .surface = surface,
            };
        }

        fn deinit(self: *Cursor) void {
            self.surface.destroy();
        }
    };

    pub fn init(allocator: Allocator) !*WindowSystem {
        var self = try allocator.create(WaylandWindowSystem);

        var display = try wl.Display.connect(null);
        var registry = try display.getRegistry();

        const xkb_context = c.xkb_context_new(
            0, // no flags
        ) orelse return error.XkbInitError;

        var locale = std.os.getenv("LC_ALL");
        if (locale == null) locale = std.os.getenv("LC_CTYPE");
        if (locale == null) locale = std.os.getenv("LANG");
        if (locale == null) locale = std.os.getenv("C");

        const locale_z = allocator.dupeZ(
            u8,
            locale.?,
        ) catch unreachable;
        defer allocator.free(locale_z);

        const xkb_compose_table = c.xkb_compose_table_new_from_locale(
            xkb_context,
            locale_z.ptr,
            0, // no flags
        ) orelse return error.XkbInitError;

        const xkb_compose_state = c.xkb_compose_state_new(
            xkb_compose_table,
            0, // no flags
        ) orelse return error.XkbInitError;

        const event_fds = try std.os.pipe();

        self.* = WaylandWindowSystem{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .xkb_context = xkb_context,
            .xkb_compose_table = xkb_compose_table,
            .xkb_compose_state = xkb_compose_state,
            .clipboard_content = std.ArrayList(u8).init(allocator),

            .event_read_fd = event_fds[0],
            .event_write_fd = event_fds[1],

            .window_system = WindowSystem{
                .deinit_fn = deinit,
                .next_event_fn = nextEvent,
                .poll_events_fn = pollEvents,
                .wait_events_fn = waitEvents,
                .push_event_fn = pushEvent,
                .get_clipboard_content_alloc_fn = getClipboardContentAlloc,
                .set_clipboard_content_fn = setClipboardContent,
                .gl_swap_interval_fn = glSwapInterval,

                .create_window_fn = WaylandWindow.init,
            },
        };

        registry.setListener(*WaylandWindowSystem, registryListener, self);
        _ = display.roundtrip();

        self.cursor_theme = try wl.CursorTheme.load(null, 24, self.shm.?);
        self.cursor_left_ptr = try Cursor.init(self, "left_ptr");

        return &self.window_system;
    }

    fn deinit(window_system: *WindowSystem) void {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);

        std.os.close(self.event_read_fd);
        std.os.close(self.event_write_fd);

        if (self.cursor_left_ptr) |*ptr| {
            ptr.deinit();
        }
        if (self.cursor_theme) |cursor_theme| {
            cursor_theme.destroy();
        }
        if (self.keyboard) |keyboard| {
            keyboard.release();
        }
        if (self.pointer) |pointer| {
            pointer.release();
        }
        if (self.egl_display) |egl_display| {
            _ = c.eglTerminate(egl_display);
        }
        if (self.seat) |seat| {
            seat.release();
        }
        if (self.decoration_manager) |decoration_manager| {
            decoration_manager.destroy();
        }
        if (self.data_device) |data_device| {
            data_device.release();
        }
        if (self.wm_base) |wm_base| {
            wm_base.destroy();
        }
        self.clipboard_content.deinit();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    fn getEGLDisplay(self: *WaylandWindowSystem) c.EGLDisplay {
        if (self.egl_display) |egl_display| {
            return egl_display;
        } else {
            self.egl_display = c.eglGetDisplay(
                @ptrCast(*anyopaque, self.display),
            );
            _ = c.eglInitialize(self.egl_display, null, null);
            return self.egl_display;
        }
    }

    fn registryListener(
        registry: *wl.Registry,
        event: wl.Registry.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        switch (event) {
            .global => |global| {
                if (std.cstr.cmp(global.interface, wl.Compositor.getInterface().name) == 0) {
                    window_system.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
                } else if (std.cstr.cmp(global.interface, xdg.WmBase.getInterface().name) == 0) {
                    window_system.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
                } else if (std.cstr.cmp(global.interface, zxdg.DecorationManagerV1.getInterface().name) == 0) {
                    window_system.decoration_manager = registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
                } else if (std.cstr.cmp(global.interface, wl.Shm.getInterface().name) == 0) {
                    window_system.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                    window_system.seat = registry.bind(global.name, wl.Seat, 4) catch return;
                    window_system.seat.?.setListener(*WaylandWindowSystem, seatListener, window_system);
                } else if (std.cstr.cmp(global.interface, wl.DataDeviceManager.getInterface().name) == 0) {
                    window_system.data_device_manager = registry.bind(global.name, wl.DataDeviceManager, 3) catch return;
                }

                if (window_system.data_device == null) {
                    if (window_system.data_device_manager) |data_device_manager| {
                        if (window_system.seat) |seat| {
                            if (data_device_manager.getDataDevice(seat)) |data_device| {
                                window_system.data_device = data_device;

                                data_device.setListener(
                                    *WaylandWindowSystem,
                                    dataDeviceListener,
                                    window_system,
                                );
                            } else |err| {
                                std.log.err("failed to get data device: {}", .{err});
                            }
                        }
                    }
                }
            },
            .global_remove => {},
        }
    }

    fn seatListener(
        seat: *wl.Seat,
        event: wl.Seat.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        switch (event) {
            .capabilities => |capability| {
                if (capability.capabilities.pointer and window_system.pointer == null) {
                    window_system.pointer = seat.getPointer() catch return;
                    window_system.pointer.?.setListener(
                        *WaylandWindowSystem,
                        pointerListener,
                        window_system,
                    );
                }
                if (!capability.capabilities.pointer and window_system.pointer != null) {
                    window_system.pointer.?.release();
                    window_system.pointer = null;
                }

                if (capability.capabilities.keyboard and window_system.keyboard == null) {
                    window_system.keyboard = seat.getKeyboard() catch return;
                    window_system.keyboard.?.setListener(
                        *WaylandWindowSystem,
                        keyboardListener,
                        window_system,
                    );
                }
                if (!capability.capabilities.keyboard and window_system.keyboard != null) {
                    window_system.keyboard.?.release();
                    window_system.keyboard = null;
                }
            },
            else => {},
        }
    }

    fn dataSourceListener(
        data_source: *wl.DataSource,
        event: wl.DataSource.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        switch (event) {
            .send => |send| {
                if (std.cstr.cmp(send.mime_type, "text/plain") == 0 or
                    std.cstr.cmp(send.mime_type, "text/plain;charset=utf-8") == 0 or
                    std.cstr.cmp(send.mime_type, "UTF8_STRING") == 0 or
                    std.cstr.cmp(send.mime_type, "STRING") == 0 or
                    std.cstr.cmp(send.mime_type, "TEXT") == 0)
                {
                    _ = std.os.write(
                        send.fd,
                        window_system.clipboard_content.items,
                    ) catch |err| {
                        std.log.err("failed to write clipboard contents: {}", .{err});
                        return;
                    };
                }

                std.os.close(send.fd);
            },
            .cancelled => |_| {
                data_source.destroy();
            },
            else => {},
        }
    }

    fn dataOfferListener(
        data_offer: *wl.DataOffer,
        event: wl.DataOffer.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        _ = data_offer;
        _ = window_system;

        switch (event) {
            .offer => |_| {},
            else => {},
        }
    }

    fn dataDeviceListener(
        _: *wl.DataDevice,
        event: wl.DataDevice.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        switch (event) {
            .data_offer => |data_offer| {
                data_offer.id.setListener(
                    *WaylandWindowSystem,
                    dataOfferListener,
                    window_system,
                );
            },
            .selection => |selection| {
                if (selection.id == null) return;
                var data_offer = selection.id.?;

                defer data_offer.destroy();

                const pipe_fds: [2]std.os.fd_t = std.os.pipe() catch return;
                defer std.os.close(pipe_fds[0]);

                data_offer.receive("text/plain;charset=utf-8", pipe_fds[1]);
                std.os.close(pipe_fds[1]);

                _ = window_system.display.roundtrip();

                window_system.clipboard_content.shrinkRetainingCapacity(0);

                var buf: [1024]u8 = undefined;
                while (true) {
                    const bytes_read = std.os.read(pipe_fds[0], &buf) catch return;
                    if (bytes_read == 0) break;

                    window_system.clipboard_content.appendSlice(
                        buf[0..bytes_read],
                    ) catch return;
                }
            },
            else => {},
        }
    }

    fn pointerListener(
        pointer: *wl.Pointer,
        event: wl.Pointer.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        switch (event) {
            .enter => |enter| {
                const cursor: *Cursor = &window_system.cursor_left_ptr.?;
                pointer.setCursor(
                    enter.serial,
                    cursor.surface,
                    @intCast(i32, cursor.image.hotspot_x),
                    @intCast(i32, cursor.image.hotspot_y),
                );
            },
            .leave => {},
            .motion => |motion| {
                window_system.window_system.pushEvent(Event{
                    .mouse_motion = .{
                        .x = motion.surface_x.toInt(),
                        .y = motion.surface_y.toInt(),
                    },
                }) catch |err| {
                    std.log.err("failed to push mouse motion event: {}", .{err});
                };
            },
            .axis => |axis| {
                var emit_event = Event{
                    .scroll = .{ .x = 0, .y = 0 },
                };

                switch (axis.axis) {
                    .horizontal_scroll => {
                        emit_event.scroll.x = -axis.value.toDouble();
                        if (emit_event.scroll.x > 0) {
                            emit_event.scroll.x = 1;
                        } else {
                            emit_event.scroll.x = -1;
                        }
                    },
                    .vertical_scroll => {
                        emit_event.scroll.y = -axis.value.toDouble();
                        if (emit_event.scroll.y > 0) {
                            emit_event.scroll.y = 1;
                        } else {
                            emit_event.scroll.y = -1;
                        }
                    },
                    else => {},
                }

                window_system.window_system.pushEvent(emit_event) catch |err| {
                    std.log.err("failed to push scroll event: {}", .{err});
                };
            },
            .button => |_| {},
            else => {},
        }
    }

    fn keyboardListener(
        _: *wl.Keyboard,
        event: wl.Keyboard.Event,
        window_system: *WaylandWindowSystem,
    ) void {
        switch (event) {
            .key => |key| {
                if (window_system.xkb_state) |xkb_state| {
                    const keycode = key.key + 8;
                    const keysym = c.xkb_state_key_get_one_sym(xkb_state, keycode);

                    const mods = window_system.getCurrentMods();

                    window_system.emitKeyEvent(
                        xkbKeysymToKey(keysym),
                        mods,
                        switch (key.state) {
                            .pressed => .pressed,
                            .released => .released,
                            else => .pressed,
                        },
                    );

                    var compose_accepted = false;

                    switch (key.state) {
                        .pressed => {
                            window_system.startKeyRepeat(keycode) catch unreachable;

                            if (!mods.control) {
                                compose_accepted = (c.xkb_compose_state_feed(
                                    window_system.xkb_compose_state,
                                    keysym,
                                ) == c.XKB_COMPOSE_FEED_ACCEPTED);
                            }
                        },
                        .released => {
                            if (window_system.repeat_keycode == keycode) {
                                window_system.stopKeyRepeat();
                            }
                        },
                        _ => {},
                    }

                    if (compose_accepted) {
                        var buf: [128]u8 = undefined;
                        var ptr = @ptrCast([*:0]u8, &buf[0]);

                        switch (c.xkb_compose_state_get_status(
                            window_system.xkb_compose_state,
                        )) {
                            c.XKB_COMPOSE_COMPOSED => {
                                const byte_count = c.xkb_compose_state_get_utf8(
                                    window_system.xkb_compose_state,
                                    ptr,
                                    buf.len,
                                );
                                if (byte_count > 0) {
                                    const str = buf[0..@intCast(usize, byte_count)];
                                    const view = std.unicode.Utf8View.init(str) catch |err| {
                                        std.log.err("Unicode parse error: {}", .{err});
                                        return;
                                    };
                                    var iter = view.iterator();
                                    while (iter.nextCodepoint()) |codepoint| {
                                        window_system.emitCodepointEvent(codepoint);
                                    }
                                }
                            },
                            c.XKB_COMPOSE_NOTHING => {
                                const codepoint: u32 = c.xkb_state_key_get_utf32(
                                    xkb_state,
                                    key.key + 8,
                                );
                                if (codepoint > 0) {
                                    window_system.emitCodepointEvent(codepoint);
                                }
                            },
                            c.XKB_COMPOSE_COMPOSING => {},
                            c.XKB_COMPOSE_CANCELLED => {},
                            else => {},
                        }
                    }
                }
            },
            .modifiers => |modifiers| {
                if (window_system.xkb_keymap) |_| {
                    _ = c.xkb_state_update_mask(
                        window_system.xkb_state,
                        modifiers.mods_depressed,
                        modifiers.mods_latched,
                        modifiers.mods_locked,
                        0,
                        0,
                        modifiers.group,
                    );
                }
            },
            .repeat_info => |repeat_info| {
                window_system.repeat_rate = repeat_info.rate;
                window_system.repeat_delay = repeat_info.delay;
            },
            .enter => |enter| {
                window_system.keyboard_enter_serial = enter.serial;
                c.xkb_compose_state_reset(window_system.xkb_compose_state);
            },
            .leave => {
                c.xkb_compose_state_reset(window_system.xkb_compose_state);
                window_system.stopKeyRepeat();
            },
            .keymap => |keymap| {
                const map_shm = std.os.mmap(
                    null,
                    keymap.size,
                    std.os.PROT.READ,
                    std.os.MAP.PRIVATE,
                    keymap.fd,
                    0,
                ) catch unreachable;

                const xkb_keymap = c.xkb_keymap_new_from_string(
                    window_system.xkb_context,
                    map_shm.ptr,
                    c.XKB_KEYMAP_FORMAT_TEXT_V1,
                    c.XKB_KEYMAP_COMPILE_NO_FLAGS,
                );

                std.os.close(keymap.fd);
                std.os.munmap(map_shm);

                const xkb_state = c.xkb_state_new(xkb_keymap);

                if (window_system.xkb_state) |xkb_state_| {
                    c.xkb_state_unref(xkb_state_);
                }
                if (window_system.xkb_keymap) |xkb_keymap_| {
                    c.xkb_keymap_unref(xkb_keymap_);
                }

                window_system.xkb_keymap = xkb_keymap;
                window_system.xkb_state = xkb_state;
            },
        }
    }

    fn pushEvent(window_system: *WindowSystem, event: Event) anyerror!void {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        _ = try std.os.write(self.event_write_fd, &[_]u8{0});

        var event_ptr = &self.event_queue[self.event_queue_head];
        const new_head = (self.event_queue_head + 1) % self.event_queue.len;
        if (new_head == self.event_queue_tail) {
            return error.EventQueueFull;
        }
        self.event_queue_head = new_head;
        event_ptr.* = event;
    }

    fn nextEvent(window_system: *WindowSystem) ?Event {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.event_queue_head != self.event_queue_tail) {
            const event = self.event_queue[self.event_queue_tail];
            self.event_queue_tail = (self.event_queue_tail + 1) % self.event_queue.len;
            return event;
        }
        return null;
    }

    fn startKeyRepeat(self: *WaylandWindowSystem, keycode: c.xkb_keycode_t) !void {
        self.repeat_timer = try std.time.Timer.start();
        self.repeat_keycode = keycode;
        self.repeat_count = 0;
    }

    fn stopKeyRepeat(self: *WaylandWindowSystem) void {
        self.repeat_timer = null;
        self.repeat_keycode = null;
        self.repeat_count = 0;
    }

    fn getCurrentMods(self: *WaylandWindowSystem) KeyMods {
        var mods: KeyMods = .{};
        if (self.xkb_state) |xkb_state| {
            if (c.xkb_state_mod_name_is_active(
                xkb_state,
                c.XKB_MOD_NAME_CTRL,
                c.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) {
                mods.control = true;
            }
            if (c.xkb_state_mod_name_is_active(
                xkb_state,
                c.XKB_MOD_NAME_SHIFT,
                c.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) {
                mods.shift = true;
            }
            if (c.xkb_state_mod_name_is_active(
                xkb_state,
                c.XKB_MOD_NAME_ALT,
                c.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) {
                mods.alt = true;
            }
            if (c.xkb_state_mod_name_is_active(
                xkb_state,
                c.XKB_MOD_NAME_CAPS,
                c.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) {
                mods.caps_lock = true;
            }
            if (c.xkb_state_mod_name_is_active(
                xkb_state,
                c.XKB_MOD_NAME_NUM,
                c.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) {
                mods.num_lock = true;
            }
        }
        return mods;
    }

    fn emitKeyEvent(
        self: *WaylandWindowSystem,
        key: Key,
        mods: KeyMods,
        state: KeyState,
    ) void {
        self.window_system.pushEvent(Event{
            .keyboard = .{
                .key = key,
                .mods = mods,
                .state = state,
            },
        }) catch |err| {
            std.log.err("failed to push key event: {}", .{err});
        };
    }

    fn emitCodepointEvent(self: *WaylandWindowSystem, codepoint: u32) void {
        switch (codepoint) {
            0...31 => {},
            else => {
                self.window_system.pushEvent(Event{
                    .codepoint = .{
                        .codepoint = codepoint,
                    },
                }) catch |err| {
                    std.log.err("failed to push codepoint event: {}", .{err});
                };
            },
        }
    }

    fn handleKeyRepeat(self: *WaylandWindowSystem) !void {
        if (self.repeat_timer) |*repeat_timer| {
            const timer_millis: u64 = repeat_timer.read() / 1_000_000;
            if (timer_millis >= self.repeat_delay) {
                const timer_no_delay = timer_millis - @intCast(u64, self.repeat_delay);

                const constant_delay = 1000 / @intCast(u64, self.repeat_rate);

                const new_repeat_count = 1 + (timer_no_delay / constant_delay);
                if (new_repeat_count > self.repeat_count) {
                    if (self.xkb_state) |xkb_state| {
                        const keycode = self.repeat_keycode.?;
                        const keysym = c.xkb_state_key_get_one_sym(
                            xkb_state,
                            keycode,
                        );

                        const mods = self.getCurrentMods();
                        self.emitKeyEvent(
                            xkbKeysymToKey(keysym),
                            mods,
                            .repeat,
                        );

                        if (!mods.control) {
                            const codepoint: u32 = c.xkb_state_key_get_utf32(
                                xkb_state,
                                keycode,
                            );
                            if (codepoint > 0) {
                                self.emitCodepointEvent(codepoint);
                            }
                        }
                    }
                }

                self.repeat_count = new_repeat_count;
            }
        }
    }

    fn pumpEvents(self: *WaylandWindowSystem) !void {
        _ = self.display.flush();

        var fds = [_]std.os.linux.pollfd{
            .{
                .fd = self.display.getFd(),
                .events = std.os.linux.POLL.IN | std.os.linux.POLL.PRI,
                .revents = 0,
            },
            .{
                .fd = self.event_read_fd,
                .events = std.os.linux.POLL.IN | std.os.linux.POLL.PRI,
                .revents = 0,
            },
        };

        const timeout: i32 = if (self.repeat_timer) |*repeat_timer| blk: {
            const initial_delay = self.repeat_delay;
            const rate_delay = @divTrunc(1000, self.repeat_rate);

            const min_delay = std.math.min(initial_delay, rate_delay);

            const timer_millis = @intCast(i32, repeat_timer.read() / 1_000_000);

            break :blk @rem(timer_millis, min_delay);
        } else -1;

        _ = try std.os.poll(&fds, timeout);

        if (fds[1].revents != 0) {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            var dummy_buf = [1]u8{0};
            _ = std.os.read(self.event_read_fd, &dummy_buf) catch 0;
        }

        if (fds[0].revents != 0) {
            _ = self.display.dispatch();
        } else {
            _ = self.display.dispatchPending();
        }

        try self.handleKeyRepeat();
    }

    fn pollEvents(window_system: *WindowSystem) anyerror!void {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);
        try self.pumpEvents();
    }

    // Timeout in nanoseconds
    fn waitEvents(window_system: *WindowSystem) anyerror!void {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);

        while (true) {
            _ = try self.pumpEvents();

            {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();

                // Check if there's new events
                if (self.event_queue_head != self.event_queue_tail) {
                    break;
                }
            }
        }
    }

    fn getClipboardContentAlloc(
        window_system: *WindowSystem,
        allocator: Allocator,
    ) anyerror!?[]const u8 {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);
        if (self.clipboard_content.items.len > 0) {
            return try allocator.dupe(u8, self.clipboard_content.items);
        } else {
            return null;
        }
    }

    fn setClipboardContent(
        window_system: *WindowSystem,
        content: []const u8,
    ) anyerror!void {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);

        if (self.data_device_manager) |data_device_manager| {
            if (self.data_device) |data_device| {
                if (data_device_manager.createDataSource()) |data_source| {
                    self.clipboard_content.shrinkRetainingCapacity(0);
                    try self.clipboard_content.appendSlice(content);

                    data_source.setListener(
                        *WaylandWindowSystem,
                        dataSourceListener,
                        self,
                    );

                    data_source.offer("text/plain");
                    data_source.offer("text/plain;charset=utf-8");
                    data_source.offer("UTF8_STRING");
                    data_source.offer("STRING");
                    data_source.offer("TEXT");

                    data_device.setSelection(data_source, self.keyboard_enter_serial);
                } else |err| {
                    std.log.err("failed to get data source: {}", .{err});
                }
            }
        }
    }

    fn glSwapInterval(window_system: *WindowSystem, _: i32) void {
        var self = @fieldParentPtr(WaylandWindowSystem, "window_system", window_system);
        _ = c.eglSwapInterval(self.getEGLDisplay(), 1);
    }
};

const WaylandWindow = struct {
    window_system: *WaylandWindowSystem,
    window: Window,

    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,
    running: bool = true,
    toplevel_decoration: *zxdg.ToplevelDecorationV1,
    width: i32,
    height: i32,

    egl_context: ?*anyopaque,
    egl_surface: ?*anyopaque,
    egl_window: ?*wl.EglWindow,

    fn init(
        generic_window_system: *WindowSystem,
        width: i32,
        height: i32,
        options: WindowOptions,
    ) anyerror!*Window {
        var window_system = @fieldParentPtr(
            WaylandWindowSystem,
            "window_system",
            generic_window_system,
        );

        const allocator = window_system.allocator;

        var self = try allocator.create(WaylandWindow);

        const surface = try window_system.compositor.?.createSurface();
        const xdg_surface = try window_system.wm_base.?.getXdgSurface(surface);
        const xdg_toplevel = try xdg_surface.getToplevel();
        const toplevel_decoration = try window_system.decoration_manager.?
            .getToplevelDecoration(xdg_toplevel);

        var egl_context: ?*anyopaque = null;
        var egl_surface: ?*anyopaque = null;
        var egl_window: ?*wl.EglWindow = null;

        if (options.opengl) {
            _ = c.eglBindAPI(c.EGL_OPENGL_API);
            const attributes = [_]c.EGLint{
                c.EGL_RED_SIZE,   8,
                c.EGL_GREEN_SIZE, 8,
                c.EGL_BLUE_SIZE,  8,
                c.EGL_NONE,
            };
            var config: c.EGLConfig = undefined;
            var num_config: c.EGLint = undefined;
            _ = c.eglChooseConfig(
                window_system.getEGLDisplay(),
                &attributes[0],
                &config,
                1,
                &num_config,
            );
            egl_context = c.eglCreateContext(
                window_system.getEGLDisplay(),
                config,
                null,
                null,
            );

            egl_window = try wl.EglWindow.create(
                surface,
                @intCast(c_int, width),
                @intCast(c_int, height),
            );
            egl_surface = c.eglCreateWindowSurface(
                window_system.getEGLDisplay(),
                config,
                @ptrToInt(egl_window),
                null,
            );
            _ = c.eglMakeCurrent(
                window_system.getEGLDisplay(),
                egl_surface,
                egl_surface,
                egl_context,
            );
        }

        self.* = WaylandWindow{
            .window_system = window_system,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .xdg_toplevel = xdg_toplevel,
            .egl_context = egl_context,
            .egl_surface = egl_surface,
            .egl_window = egl_window,
            .toplevel_decoration = toplevel_decoration,
            .width = width,
            .height = height,

            .window = Window{
                .deinit_fn = deinit,
                .should_close_fn = shouldClose,
                .get_size_fn = getSize,
                .gl_make_context_current_fn = glMakeContextCurrent,
                .gl_swap_buffers_fn = glSwapBuffers,
            },
        };

        xdg_surface.setListener(*WaylandWindow, xdgSurfaceListener, self);
        xdg_toplevel.setListener(*WaylandWindow, xdgToplevelListener, self);

        self.surface.commit();
        _ = window_system.display.roundtrip();

        return &self.window;
    }

    fn deinit(window: *Window) void {
        var self = @fieldParentPtr(WaylandWindow, "window", window);

        const allocator = self.window_system.allocator;
        if (self.egl_surface) |egl_surface| {
            _ = c.eglDestroySurface(
                self.window_system.getEGLDisplay(),
                egl_surface,
            );
        }
        if (self.egl_window) |egl_window| {
            egl_window.destroy();
        }
        self.toplevel_decoration.destroy();
        self.xdg_toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();

        allocator.destroy(self);
    }

    fn xdgSurfaceListener(
        xdg_surface: *xdg.Surface,
        event: xdg.Surface.Event,
        window: *WaylandWindow,
    ) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                window.surface.commit();
            },
        }
    }

    fn xdgToplevelListener(
        _: *xdg.Toplevel,
        event: xdg.Toplevel.Event,
        window: *WaylandWindow,
    ) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width >= 0 and configure.height >= 0) {
                    window.width = configure.width;
                    window.height = configure.height;
                    if (window.egl_window) |egl_window| {
                        egl_window.resize(configure.width, configure.height, 0, 0);
                    }

                    window.window_system.window_system.pushEvent(Event{
                        .window_resize = .{
                            .width = configure.width,
                            .height = configure.height,
                            .window = &window.window,
                        },
                    }) catch |err| {
                        std.log.err("failed to push window resize event: {}", .{err});
                    };
                }
            },
            .close => {
                window.running = false;
            },
        }
    }

    fn shouldClose(window: *Window) bool {
        var self = @fieldParentPtr(WaylandWindow, "window", window);
        return !self.running;
    }

    fn glMakeContextCurrent(window: *Window) void {
        var self = @fieldParentPtr(WaylandWindow, "window", window);
        _ = c.eglMakeCurrent(
            self.window_system.getEGLDisplay(),
            self.egl_surface,
            self.egl_surface,
            self.egl_context,
        );
    }

    fn glSwapBuffers(window: *Window) void {
        var self = @fieldParentPtr(WaylandWindow, "window", window);
        _ = c.eglSwapBuffers(self.window_system.getEGLDisplay(), self.egl_surface);
    }

    fn getSize(window: *Window, width: *i32, height: *i32) void {
        var self = @fieldParentPtr(WaylandWindow, "window", window);
        width.* = self.width;
        height.* = self.height;
    }
};
