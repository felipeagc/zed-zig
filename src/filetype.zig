const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Regex = @import("regex.zig").Regex;

pub const FileTypeOptions = struct {
    increase_indentation_pattern: []const u8,
    decrease_indentation_pattern: []const u8,
    tab_width: u32 = 4,
    expand_tab: bool = true,
};

pub const FileType = struct {
    allocator: *Allocator,
    name: []const u8,
    increase_indentation_regex: Regex,
    decrease_indentation_regex: Regex,
    tab_width: usize,
    expand_tab: bool,

    pub fn init(allocator: *Allocator, name: []const u8, options: FileTypeOptions) !*FileType {
        var self = try allocator.create(FileType);
        errdefer allocator.destroy(self);

        var increase_indentation_regex = try Regex.init(allocator);
        try increase_indentation_regex.addPattern(0, options.increase_indentation_pattern);
        var decrease_indentation_regex = try Regex.init(allocator);
        try decrease_indentation_regex.addPattern(0, options.decrease_indentation_pattern);

        self.* = FileType{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .increase_indentation_regex = increase_indentation_regex,
            .decrease_indentation_regex = decrease_indentation_regex,
            .tab_width = options.tab_width,
            .expand_tab = options.expand_tab,
        };

        return self;
    }

    pub fn deinit(self: *FileType) void {
        self.increase_indentation_regex.deinit();
        self.decrease_indentation_regex.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};
