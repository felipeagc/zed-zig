const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Binding = union(enum) {
    submap: void,
    command: editor.Command,
};

pub const KeyMap = struct {
    allocator: *Allocator,
    map: std.StringArrayHashMap(Binding),

    pub fn init(allocator: *Allocator) !KeyMap {
        return KeyMap{
            .allocator = allocator,
            .map = std.StringArrayHashMap(Binding).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key);
        }
        self.map.deinit();
    }

    pub fn tryExecute(self: *@This(), panel: *editor.Panel, sequence: []const u8) !editor.KeyResult {
        if (sequence.len == 0) return .none;

        if (self.map.get(sequence)) |binding| {
            switch (binding) {
                .submap => return .submap,
                .command => |command| {
                    try command(panel, &[_][]const u8{});
                    return .command;
                },
            }
        } else {
            var i: usize = sequence.len - 1;
            while (i > 0) : (i -= 1) {
                if (sequence[i] == ' ') break;
            }

            if (i == 0) return .none;

            const wildcard_seq = try mem.concat(
                self.allocator,
                u8,
                &.{ sequence[0 .. i + 1], "<?>" },
            );
            defer self.allocator.free(wildcard_seq);

            if (self.map.get(wildcard_seq)) |binding| {
                switch (binding) {
                    .submap => return .submap,
                    .command => |command| {
                        try command(panel, &[1][]const u8{sequence[i + 1 ..]});
                        return .command;
                    },
                }
            }
        }

        return .none;
    }

    pub fn bind(self: *@This(), sequence: []const u8, command: editor.Command) !void {
        var seq_builder = std.ArrayList(u8).init(self.allocator);
        defer seq_builder.deinit();

        var split_iter = std.mem.tokenize(sequence, " ");
        while (split_iter.next()) |part| {
            if (seq_builder.items.len > 0) try seq_builder.append(' ');
            try seq_builder.appendSlice(part);

            const semi_seq = try self.allocator.dupe(u8, seq_builder.items);

            const is_action = split_iter.rest().len == 0;

            const binding_existed = self.map.get(semi_seq) != null;

            if (is_action) {
                try self.map.put(semi_seq, Binding{ .command = command });
            } else {
                try self.map.put(semi_seq, Binding{ .submap = .{} });
            }

            if (binding_existed) {
                self.allocator.free(semi_seq);
            }
        }
    }

    pub fn keyToKeySeq(allocator: *Allocator, key: renderer.Key, mods: u32) !?[]const u8 {
        const valid_key = switch (key) {
            // .@"<space>",
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

        if (!valid_key) return null;

        const key_name = @tagName(key);
        const control_prefix = if (mods & renderer.KeyMod.control != 0) "C-" else "";
        const alt_prefix = if (mods & renderer.KeyMod.alt != 0) "A-" else "";
        const shift_prefix = if (mods & renderer.KeyMod.shift != 0) "S-" else "";

        return try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}{s}",
            .{
                control_prefix,
                alt_prefix,
                shift_prefix,
                key_name,
            },
        );
    }

    pub fn codepointToKeySeq(allocator: *Allocator, codepoint: u32) !?[]const u8 {
        var bytes = [_]u8{0} ** 4;
        const key_name = if (codepoint == ' ') "<space>" else blk: {
            const byte_count = try std.unicode.utf8Encode(@intCast(u21, codepoint), &bytes);
            break :blk bytes[0..byte_count];
        };

        return try allocator.dupe(u8, key_name);
    }
};
