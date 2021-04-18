const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Allocator = std.mem.Allocator;

pub const Command = fn(panel: *editor.Panel, args: []const u8) anyerror!void;

pub const Binding = union(enum) {
    submap: *SubMap,
    command: Command,
};

pub const SubMap = struct {
    allocator: *Allocator,
    map: std.StringHashMap(Binding),

    fn init(allocator: *Allocator) !*SubMap {
        var self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .map = std.StringHashMap(Binding).init(allocator),
        };
        return self;
    }

    fn deinit(self: *@This()) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value == .submap) {
                entry.value.submap.deinit();
            }
        }

        self.map.deinit();
        self.allocator.destroy(self);
    }

    fn trigger(self: *@This(), key: []const u8, panel: *editor.Panel) !?*SubMap {
        if (self.map.get(key)) |binding| {
            switch (binding) {
                .submap => |submap| {
                    return submap;
                },
                .command => |command| {
                    try command(panel, "");
                    return null;
                },
            }
        }

        return null;
    }
};

pub const KeyMap = struct {
    allocator: *Allocator,
    root_submap: *SubMap,
    current_submap: *SubMap,

    pub fn init(allocator: *Allocator) !KeyMap {
        var root_submap = try SubMap.init(allocator);

        return KeyMap{
            .allocator = allocator,
            .root_submap = root_submap,
            .current_submap = root_submap,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.root_submap.deinit();
    }

    pub fn onKey(
        self: *@This(),
        key: renderer.Key,
        mods: u32,
        panel: *editor.Panel,
    ) !bool {
        const valid_key = switch (key) {
            .@"<space>",
            .@"<esc>",
            .@"<enter>",
            .@"<tab>",
            .@"<backspace>",
            .@"<insert>",
            .@"<delete>",
            .@"<right>",
            .@"<left>",
            .@"<down>",
            .@"<up>",
            .@"<page_up>",
            .@"<page_down>",
            .@"<home>",
            .@"<end>",
            .@"<caps_lock>",
            .@"<scroll_lock>",
            .@"<num_lock>",
            .@"<print_screen>",
            .@"<pause>",
            .@"<f1>",
            .@"<f2>",
            .@"<f3>",
            .@"<f4>",
            .@"<f5>",
            .@"<f6>",
            .@"<f7>",
            .@"<f8>",
            .@"<f9>",
            .@"<f10>",
            .@"<f11>",
            .@"<f12>",
            .@"<f13>",
            .@"<f14>",
            .@"<f15>",
            .@"<f16>",
            .@"<f17>",
            .@"<f18>",
            .@"<f19>",
            .@"<f20>",
            .@"<f21>",
            .@"<f22>",
            .@"<f23>",
            .@"<f24>",
            .@"<f25>",
            .menu,
            => true,
            else => mods & (renderer.KeyMod.control | renderer.KeyMod.alt) != 0,
        };

        if (!valid_key) return false;

        const key_name = @tagName(key);
        const control_prefix = if (mods & renderer.KeyMod.control != 0) "C-" else "";
        const alt_prefix = if (mods & renderer.KeyMod.alt != 0) "A-" else "";
        const shift_prefix = if (mods & renderer.KeyMod.shift != 0) "S-" else "";

        const key_combo = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}{s}",
            .{
                control_prefix,
                alt_prefix,
                shift_prefix,
                key_name,
            },
        );
        defer self.allocator.free(key_combo);

        var maybe_submap = self.current_submap.trigger(key_combo, panel) catch |err| {
            self.current_submap = self.root_submap;
            std.log.info("onKey error: {}", .{err});
            return false;
        };

        if (maybe_submap) |next_submap| {
            self.current_submap = next_submap;
            return true;
        }

        self.current_submap = self.root_submap;
        return false;
    }

    pub fn onChar(self: *@This(), codepoint: u32, panel: *editor.Panel) !bool {
        var bytes = [_]u8{0} ** 4;
        const byte_count = try std.unicode.utf8Encode(@intCast(u21, codepoint), &bytes);
        const key_name = bytes[0..byte_count];

        var maybe_submap = self.current_submap.trigger(key_name, panel) catch |err| {
            self.current_submap = self.root_submap;
            std.log.info("onChar error: {}", .{err});
            return false;
        };

        if (maybe_submap) |next_submap| {
            self.current_submap = next_submap;
            return true;
        }

        self.current_submap = self.root_submap;
        return false;
    }

    pub fn bind(self: *@This(), sequence: []const u8, command: Command) !void {
        var submap = self.root_submap;

        var split_iter = std.mem.split(sequence, " ");
        while (split_iter.next()) |part| {
            const is_action = split_iter.rest().len == 0;

            if (submap.map.get(part)) |binding| {
                if (is_action) {
                    if (binding == .submap) binding.submap.deinit();

                    try submap.map.put(part, Binding{ .command = command });
                } else if (binding == .command) {
                    try submap.map.put(part, Binding{
                        .submap = try SubMap.init(self.allocator),
                    });
                }
            } else {
                if (is_action) {
                    try submap.map.put(part, Binding{ .command = command });
                } else {
                    try submap.map.put(part, Binding{
                        .submap = try SubMap.init(self.allocator),
                    });
                }
            }

            if (!is_action) {
                submap = submap.map.get(part).?.submap;
            } else {
                break;
            }
        }
    }
};
