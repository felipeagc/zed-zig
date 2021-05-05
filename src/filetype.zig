const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Regex = @import("regex.zig").Regex;

pub const FileType = struct {
    allocator: *Allocator,
    name: []const u8,
    increase_indent_regex: ?Regex = null,
    decrease_indent_regex: ?Regex = null,
    indent_next_line_regex: ?Regex = null,
    zero_indent_regex: ?Regex = null,
    tab_width: usize,
    expand_tab: bool,
    formatter_command: ?[]const u8,
    brackets: []Bracket,

    pub const Bracket = struct {
        open: []const u8,
        close: []const u8,
    };

    pub const Options = struct {
        increase_indent_pattern: ?[]const u8 = null,
        decrease_indent_pattern: ?[]const u8 = null,
        indent_next_line_pattern: ?[]const u8 = null,
        zero_indent_pattern: ?[]const u8 = null,
        tab_width: u32 = 4,
        expand_tab: bool = true,
        formatter_command: ?[]const u8 = null,
        brackets: []const Bracket = &[_]Bracket{},
    };

    pub fn init(allocator: *Allocator, name: []const u8, options: Options) !*FileType {
        var self = try allocator.create(FileType);
        errdefer allocator.destroy(self);

        var increase_indent_regex: ?Regex = null;
        if (options.increase_indent_pattern) |pattern| {
            increase_indent_regex = try Regex.init(allocator);
            try increase_indent_regex.?.addPattern(0, pattern);
        }

        var decrease_indent_regex: ?Regex = null;
        if (options.decrease_indent_pattern) |pattern| {
            decrease_indent_regex = try Regex.init(allocator);
            try decrease_indent_regex.?.addPattern(0, pattern);
        }

        var indent_next_line_regex: ?Regex = null;
        if (options.indent_next_line_pattern) |pattern| {
            indent_next_line_regex = try Regex.init(allocator);
            try indent_next_line_regex.?.addPattern(0, pattern);
        }

        var zero_indent_regex: ?Regex = null;
        if (options.zero_indent_pattern) |pattern| {
            zero_indent_regex = try Regex.init(allocator);
            try zero_indent_regex.?.addPattern(0, pattern);
        }

        var brackets = try allocator.alloc(Bracket, options.brackets.len);
        for (options.brackets) |bracket, i| {
            brackets[i].open = try allocator.dupe(u8, bracket.open);
            brackets[i].close = try allocator.dupe(u8, bracket.close);
        }

        self.* = FileType{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .increase_indent_regex = increase_indent_regex,
            .decrease_indent_regex = decrease_indent_regex,
            .indent_next_line_regex = indent_next_line_regex,
            .zero_indent_regex = zero_indent_regex,
            .tab_width = options.tab_width,
            .expand_tab = options.expand_tab,
            .formatter_command = if (options.formatter_command) |command| try allocator.dupe(u8, command) else null,
            .brackets = brackets,
        };

        return self;
    }

    pub fn deinit(self: *FileType) void {
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
};
