const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Regex = @import("regex.zig").Regex;

pub const FileTypeOptions = struct {
    increase_indent_pattern: []const u8,
    decrease_indent_pattern: []const u8,
    indent_next_line_pattern: ?[]const u8 = null,
    unindented_line_pattern: ?[]const u8 = null,
    zero_indent_pattern: ?[]const u8 = null,
    tab_width: u32 = 4,
    expand_tab: bool = true,
};

pub const FileType = struct {
    allocator: *Allocator,
    name: []const u8,
    increase_indent_regex: Regex,
    decrease_indent_regex: Regex,
    indent_next_line_regex: Regex,
    unindented_line_regex: Regex,
    zero_indent_regex: Regex,
    tab_width: usize,
    expand_tab: bool,

    pub fn init(allocator: *Allocator, name: []const u8, options: FileTypeOptions) !*FileType {
        var self = try allocator.create(FileType);
        errdefer allocator.destroy(self);

        var increase_indent_regex = try Regex.init(allocator);
        try increase_indent_regex.addPattern(0, options.increase_indent_pattern);

        var decrease_indent_regex = try Regex.init(allocator);
        try decrease_indent_regex.addPattern(0, options.decrease_indent_pattern);

        var indent_next_line_regex = try Regex.init(allocator);
        if (options.indent_next_line_pattern) |pattern| {
            try indent_next_line_regex.addPattern(0, pattern);
        }

        var unindented_line_regex = try Regex.init(allocator);
        if (options.unindented_line_pattern) |pattern| {
            try unindented_line_regex.addPattern(0, pattern);
        }

        var zero_indent_regex = try Regex.init(allocator);
        if (options.zero_indent_pattern) |pattern| {
            try zero_indent_regex.addPattern(0, pattern);
        }

        self.* = FileType{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .increase_indent_regex = increase_indent_regex,
            .decrease_indent_regex = decrease_indent_regex,
            .indent_next_line_regex = indent_next_line_regex,
            .unindented_line_regex = unindented_line_regex,
            .zero_indent_regex = zero_indent_regex,
            .tab_width = options.tab_width,
            .expand_tab = options.expand_tab,
        };

        return self;
    }

    pub fn deinit(self: *FileType) void {
        self.increase_indent_regex.deinit();
        self.decrease_indent_regex.deinit();
        self.indent_next_line_regex.deinit();
        self.unindented_line_regex.deinit();
        self.zero_indent_regex.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};
