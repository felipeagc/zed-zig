const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const Color = renderer.Color;

pub const FaceDesc = struct {
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
};

pub const Face = struct {
    foreground: Color = .{ 0xff, 0xff, 0xff },
    background: Color = .{ 0x0c, 0x15, 0x1b },
};

pub const FaceType = enum { default, border, status_line, status_line_focused, max };

pub const FaceCollection = [@enumToInt(FaceType.max)]Face;

pub const ColorScheme = struct {
    faces: FaceCollection,

    pub fn init(face_descs: [@enumToInt(FaceType.max)]FaceDesc) !ColorScheme {
        var faces = [1]Face{.{}} ** @enumToInt(FaceType.max);
        for (face_descs) |desc, i| {
            if (desc.background) |background| {
                faces[i].background = try colorFromStr(background);
            }
            if (desc.foreground) |foreground| {
                faces[i].foreground = try colorFromStr(foreground);
            }
        }
        return ColorScheme{ .faces = faces };
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
        return comptime try ColorScheme.init(
            [_]FaceDesc{
                // default:
                .{ .foreground = "#ffffff", .background = "#0c151b" },
                // border:
                .{ .foreground = "#303030", .background = "#303030" },
                // status_line:
                .{ .foreground = "#d4f0ff", .background = "#303030" },
                // status_line_focused:
                .{ .foreground = "#0c151b", .background = "#87d7ff" },
            },
        );
    }

    pub fn getFace(self: *const ColorScheme, kind: FaceType) Face {
        return self.faces[@enumToInt(kind)];
    }
};

pub const Highlighter = struct {};
