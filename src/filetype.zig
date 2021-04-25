const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const FileType = struct {
    allocator: *Allocator,
    name: []const u8,

    pub fn init(allocator: *Allocator, name: []const u8) !*FileType {
        var self = try allocator.create(FileType);
        errdefer allocator.destroy(self);

        self.* = FileType{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
        };

        return self;
    }

    pub fn deinit(self: *FileType) void {
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};
