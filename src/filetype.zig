const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Regex = @import("regex.zig").Regex;
const Highlighter = @import("highlighter.zig").Highlighter;
const FaceType = @import("highlighter.zig").FaceType;

pub const FileType = @This();

allocator: Allocator,
name: []const u8,
extensions: [][]const u8,
increase_indent_regex: ?Regex = null,
decrease_indent_regex: ?Regex = null,
indent_next_line_regex: ?Regex = null,
zero_indent_regex: ?Regex = null,
tab_width: usize,
expand_tab: bool,
formatter_command: ?[]const u8,
brackets: []Bracket,
highlighter: ?*Highlighter,

pub const Bracket = struct {
    open: []const u8,
    close: []const u8,
};

const Options = struct {
    extensions: [][]const u8 = &[_][]const u8{},
    increase_indent_pattern: ?[]const u8 = null,
    decrease_indent_pattern: ?[]const u8 = null,
    indent_next_line_pattern: ?[]const u8 = null,
    zero_indent_pattern: ?[]const u8 = null,
    tab_width: u32 = 4,
    expand_tab: bool = true,
    formatter_command: ?[]const u8 = null,
    brackets: []const Bracket = &[_]Bracket{},
    highlighters: ?[]struct {
        name: []const u8,
        default_face: FaceType = FaceType.default,
        patterns: []struct {
            @"type": Highlighter.PatternType = .normal,
            face: FaceType = FaceType.default,
            pattern: []const u8,
            sub_highlighter: ?[]const u8 = null,
        },
    } = null,
};

pub fn init(allocator: Allocator, name: []const u8, json_desc: []const u8) !*FileType {
    const json_options = std.json.ParseOptions{ .allocator = allocator };

    var stream = std.json.TokenStream.init(json_desc);

    @setEvalBranchQuota(2000);
    var options = try std.json.parse(Options, &stream, json_options);
    defer std.json.parseFree(Options, options, json_options);

    var highlighter: ?*Highlighter = null;

    if (options.highlighters) |highlighter_descs| {
        var highlighters = std.StringHashMap(*Highlighter).init(allocator);
        defer highlighters.deinit();

        for (highlighter_descs) |highlighter_desc| {
            var patterns = try allocator.alloc(
                Highlighter.Pattern,
                highlighter_desc.patterns.len,
            );
            defer allocator.free(patterns);

            for (highlighter_desc.patterns) |pattern, i| {
                const sub: ?*Highlighter = if (pattern.sub_highlighter) |subname|
                    highlighters.get(subname) orelse return error.SubHighlighterNotFound
                else
                    null;

                patterns[i] = Highlighter.Pattern{
                    .kind = pattern.@"type",
                    .face_type = pattern.face,
                    .pattern = pattern.pattern,
                    .sub_highlighter = sub,
                    .sub_highlighter_is_owned = true,
                };
            }

            try highlighters.put(highlighter_desc.name, try Highlighter.init(
                allocator,
                highlighter_desc.default_face,
                patterns,
            ));
        }

        highlighter = highlighters.get("root");
    }

    var self = try allocator.create(FileType);
    errdefer allocator.destroy(self);

    var increase_indent_regex: ?Regex = null;
    errdefer if (increase_indent_regex) |regex| regex.deinit();
    if (options.increase_indent_pattern) |pattern| {
        increase_indent_regex = try Regex.init(allocator);
        try increase_indent_regex.?.addPattern(0, pattern);
    }

    var decrease_indent_regex: ?Regex = null;
    errdefer if (decrease_indent_regex) |regex| regex.deinit();
    if (options.decrease_indent_pattern) |pattern| {
        decrease_indent_regex = try Regex.init(allocator);
        try decrease_indent_regex.?.addPattern(0, pattern);
    }

    var indent_next_line_regex: ?Regex = null;
    errdefer if (indent_next_line_regex) |regex| regex.deinit();
    if (options.indent_next_line_pattern) |pattern| {
        indent_next_line_regex = try Regex.init(allocator);
        try indent_next_line_regex.?.addPattern(0, pattern);
    }

    var zero_indent_regex: ?Regex = null;
    errdefer if (zero_indent_regex) |regex| regex.deinit();
    if (options.zero_indent_pattern) |pattern| {
        zero_indent_regex = try Regex.init(allocator);
        try zero_indent_regex.?.addPattern(0, pattern);
    }

    var brackets = try allocator.alloc(Bracket, options.brackets.len);
    errdefer allocator.free(brackets);
    for (options.brackets) |bracket, i| {
        brackets[i].open = try allocator.dupe(u8, bracket.open);
        brackets[i].close = try allocator.dupe(u8, bracket.close);
    }

    var extensions = try allocator.alloc([]const u8, options.extensions.len);
    errdefer {
        for (extensions) |ext| allocator.free(ext);
        allocator.free(extensions);
    }
    for (options.extensions) |ext, i| {
        extensions[i] = try allocator.dupe(u8, ext);
    }

    const formatter_command: ?[]const u8 = if (options.formatter_command) |command|
        try allocator.dupe(u8, command)
    else
        null;
    errdefer if (formatter_command) |cmd| allocator.free(cmd);

    self.* = FileType{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .extensions = extensions,
        .increase_indent_regex = increase_indent_regex,
        .decrease_indent_regex = decrease_indent_regex,
        .indent_next_line_regex = indent_next_line_regex,
        .zero_indent_regex = zero_indent_regex,
        .tab_width = options.tab_width,
        .expand_tab = options.expand_tab,
        .formatter_command = formatter_command,
        .brackets = brackets,
        .highlighter = highlighter,
    };

    return self;
}

pub fn deinit(self: *FileType) void {
    for (self.extensions) |ext| {
        self.allocator.free(ext);
    }
    self.allocator.free(self.extensions);

    if (self.highlighter) |highlighter| {
        highlighter.deinit();
    }

    for (self.brackets) |bracket| {
        self.allocator.free(bracket.open);
        self.allocator.free(bracket.close);
    }
    self.allocator.free(self.brackets);
    if (self.formatter_command) |command| {
        self.allocator.free(command);
    }
    if (self.increase_indent_regex) |*regex| {
        regex.deinit();
    }
    if (self.decrease_indent_regex) |*regex| {
        regex.deinit();
    }
    if (self.indent_next_line_regex) |*regex| {
        regex.deinit();
    }
    if (self.zero_indent_regex) |*regex| {
        regex.deinit();
    }
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}
