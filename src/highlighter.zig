const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const editor = @import("editor.zig");
const Regex = @import("regex.zig").Regex;
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

pub const FaceType = enum {
    default,
    border,
    status_line,
    status_line_focused,
    keyword,
    @"type",
    constant,
    comment,
    preprocessor,
    string,
    label,
    punctuation,
    operator,
    function,
    max,
};

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
                // keyword:
                .{ .foreground = "#d4f0ff" },
                // type:
                .{ .foreground = "#87d7ff" },
                // constant:
                .{ .foreground = "#70c0b1" },
                // comment:
                .{ .foreground = "#808080" },
                // preprocessor:
                .{ .foreground = "#b5bd68" },
                // string:
                .{ .foreground = "#e7c547" },
                // label:
                .{ .foreground = "#70c0b1" },
                // punctuation:
                .{ .foreground = "#ffffff" },
                // operator:
                .{ .foreground = "#d4f0ff" },
                // function:
                .{ .foreground = "#b5bd68" },
            },
        );
    }

    pub fn getFace(self: *const ColorScheme, kind: FaceType) Face {
        return self.faces[@enumToInt(kind)];
    }
};

pub const TokenType = enum {
    normal,
    inside_delimeter,
    delimeter_start,
    delimeter_end,
};

pub const Token = struct {
    kind: TokenType,
    face_type: FaceType,
    length: usize,
};

pub const Highlighter = struct {
    allocator: *Allocator,
    regex: Regex,
    patterns: []InternalPattern,
    default_face: FaceType,

    pub const PatternType = enum {
        normal,
        push,
        pop,
    };

    pub const Pattern = struct {
        kind: PatternType = .normal,
        face_type: FaceType,
        pattern: []const u8,
        sub_highlighter: ?*Highlighter = null,
    };

    const InternalPattern = struct {
        kind: PatternType,
        face_type: FaceType,
        sub_highlighter: ?*Highlighter,
    };

    pub fn init(
        allocator: *Allocator,
        default_face: FaceType,
        patterns: []const Pattern,
    ) !*Highlighter {
        var self = try allocator.create(Highlighter);
        errdefer allocator.destroy(self);

        var regex = try Regex.init(allocator);
        for (patterns) |pattern, i| {
            try regex.addPattern(i, pattern.pattern);
        }

        var internal_patterns = try allocator.alloc(InternalPattern, patterns.len);
        for (patterns) |pattern, i| {
            internal_patterns[i] = InternalPattern{
                .kind = pattern.kind,
                .face_type = pattern.face_type,
                .sub_highlighter = pattern.sub_highlighter,
            };
        }

        self.* = Highlighter{
            .allocator = allocator,
            .regex = regex,
            .patterns = internal_patterns,
            .default_face = default_face,
        };
        return self;
    }

    pub fn deinit(self: *Highlighter) void {
        for (self.patterns) |pattern| {
            if (pattern.sub_highlighter) |sub_highlighter| {
                sub_highlighter.deinit();
            }
        }

        self.allocator.free(self.patterns);
        self.regex.deinit();
        self.allocator.destroy(self);
    }
};

pub const HighlighterState = struct {
    highlighter: *Highlighter,
    stack: std.ArrayList(*HighlighterState),

    pub fn init(highlighter: *Highlighter) !*HighlighterState {
        const allocator = highlighter.allocator;

        var self = try allocator.create(HighlighterState);

        self.* = HighlighterState{
            .highlighter = highlighter,
            .stack = std.ArrayList(*HighlighterState).init(allocator),
        };

        try self.resetStack();

        return self;
    }

    pub fn deinit(self: *HighlighterState) void {
        const allocator = self.highlighter.allocator;
        self.stack.deinit();
        allocator.destroy(self);
    }

    pub fn resetStack(self: *HighlighterState) !void {
        self.stack.shrinkRetainingCapacity(0);
        try self.stack.append(self);
    }

    pub fn highlightLine(
        self: *HighlighterState,
        tokens: *std.ArrayList(Token),
        text: []const u8,
    ) !void {
        var current_state = self.stack.items[self.stack.items.len - 1];
        current_state.highlighter.regex.setBuffer(text);

        tokens.shrinkRetainingCapacity(0);

        var last_regex_end: isize = 0;
        var last_end: isize = 0;

        var match_start: usize = 0;
        var match_end: usize = 0;
        while (current_state.highlighter.regex.nextMatch(&match_start, &match_end)) |pattern_index| {
            const pattern = &current_state.highlighter.patterns[pattern_index];
            const face_type = pattern.face_type;

            const in_between_length: isize =
                (last_regex_end + @intCast(isize, match_start)) - last_end;
            const match_length: isize =
                @intCast(isize, match_end) - @intCast(isize, match_start);

            last_end = last_regex_end + @intCast(isize, match_end);

            const token_type: TokenType = switch (pattern.kind) {
                .normal => .normal,
                .push => .delimeter_start,
                .pop => .delimeter_end,
            };

            if (in_between_length > 0) {
                const token = Token{
                    .kind = if (self.stack.items.len > 1)
                        TokenType.inside_delimeter
                    else
                        TokenType.normal,
                    .face_type = current_state.highlighter.default_face,
                    .length = @intCast(usize, in_between_length),
                };
                try tokens.append(token);
            }

            if (match_length > 0) {
                const token = Token{
                    .kind = token_type,
                    .face_type = face_type,
                    .length = @intCast(usize, match_length),
                };
                try tokens.append(token);
            }

            switch (pattern.kind) {
                .normal => {},
                .push => {
                    last_regex_end += @intCast(isize, match_end);

                    const sub_highlighter: *Highlighter = pattern.sub_highlighter.?;
                    var sub_state = try HighlighterState.init(sub_highlighter);
                    try self.stack.append(sub_state);

                    current_state = self.stack.items[self.stack.items.len - 1];

                    current_state.highlighter.regex.setBuffer(
                        text[@intCast(usize, last_regex_end)..],
                    );
                },
                .pop => {
                    last_regex_end += @intCast(isize, match_end);

                    current_state.deinit();

                    _ = self.stack.pop();
                    std.debug.assert(self.stack.items.len > 0);
                    current_state = self.stack.items[self.stack.items.len - 1];

                    current_state.highlighter.regex.setBuffer(
                        text[@intCast(usize, last_regex_end)..],
                    );
                },
            }
        }

        if (match_end < text.len) {
            const token = Token{
                .kind = if (self.stack.items.len > 1)
                    TokenType.inside_delimeter
                else
                    TokenType.normal,
                .face_type = current_state.highlighter.default_face,
                .length = text.len - match_end,
            };
            try tokens.append(token);
        }
    }
};

comptime {
    _ = Highlighter.init;
    _ = Highlighter.deinit;

    _ = HighlighterState.init;
    _ = HighlighterState.deinit;
    _ = HighlighterState.resetStack;
    _ = HighlighterState.highlightLine;
}

test "highlighter" {
    const allocator = std.testing.allocator;

    const highlighter = try Highlighter.init(allocator, .default, &[_]Highlighter.Pattern{
        .{
            .face_type = .keyword,
            .pattern = "\\b(" ++
                "_Alignas|_Alignof|_Noreturn|_Static_assert|_Thread_local|" ++
                "sizeof|static|struct|switch|typedef|union|volatile|while|" ++
                "for|goto|if|inline|register|restrict|return|" ++
                "auto|break|case|const|continue|default|do|else|enum|extern" ++
                ")\\b",
        },
        .{
            .kind = .push,
            .face_type = .comment,
            .pattern = "/\\*",
            .sub_highlighter = try Highlighter.init(allocator, .comment, &[_]Highlighter.Pattern{
                .{
                    .kind = .pop,
                    .face_type = .comment,
                    .pattern = "\\*/",
                },
            }),
        },
    });
    defer highlighter.deinit();

    var state = try HighlighterState.init(highlighter);
    defer state.deinit();

    var tokens = std.ArrayList(Token).init(allocator);
    defer tokens.deinit();

    const text =
        \\const /*int main() { case hey
        \\hello*/  printf("hello, world")
        \\}
    ;

    var iter = mem.split(text, "\n");
    while (iter.next()) |line| {
        std.log.warn("Line", .{});
        try state.highlightLine(&tokens, line);
        for (tokens.items) |token| {
            std.log.warn("{}", .{token});
        }
    }
}
