const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const Color = renderer.Color;

pub const HighlightGroup = struct {
    face_name: []const u8,
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
};

pub const ColorScheme = struct {
    groups: std.ArrayList(Group), // Indexed by face index

    const Group = struct {
        foreground: ?Color = null,
        background: ?Color = null,
    };

    pub fn init(allocator: *Allocator, highlight_groups: []const HighlightGroup) !ColorScheme {
        var groups = std.ArrayList(Group).init(allocator);

        for (highlight_groups) |group| {
            const face_index = editor.getFaceIndex(group.face_name);
            try groups.resize(std.math.max(groups.items.len, face_index + 1));

            var new_group = Group{};
            if (group.foreground) |color_str| {
                new_group.foreground = try colorFromStr(color_str);
            }
            if (group.background) |color_str| {
                new_group.background = try colorFromStr(color_str);
            }
            groups.items[face_index] = new_group;
        }

        return ColorScheme{
            .groups = groups,
        };
    }

    pub fn deinit(self: *ColorScheme) void {
        self.groups.deinit();
    }

    pub fn colorFromStr(str: []const u8) !Color {
        if (str.len != 7) return error.InvalidColor;
        if (str[0] != '#') return error.InvalidColor;

        return Color{
            try std.fmt.parseUnsigned(u8, str[1..3], 16),
            try std.fmt.parseUnsigned(u8, str[3..5], 16),
            try std.fmt.parseUnsigned(u8, str[5..7], 16),
        };
    }

    pub fn defaultDark(allocator: *Allocator) !ColorScheme {
        return try ColorScheme.init(
            allocator,
            &.{
                .{ .face_name = "default", .foreground = "#0c151b" },
                .{ .face_name = "foreground", .foreground = "#ffffff" },
                .{ .face_name = "status_line_background", .foreground = "#303030" },
            },
        );
    }
};

pub const Highlighter = struct {};
