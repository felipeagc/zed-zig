const std = @import("std");
const renderer = @import("opengl_renderer.zig");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;

pub const SubMap = struct {
    allocator: *Allocator,

    fn init(allocator: *Allocator) !*SubMap {
        var self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn onKey(self: *@This(), key: renderer.Key, mods: u32) anyerror!?*SubMap {
        return null;
    }

    fn onChar(self: *@This(), codepoint: u32) anyerror!?*SubMap {
        return null;
    }
};

pub const KeyMap = struct {
    root_submap: *SubMap,
    current_submap: *SubMap,

    pub const Action = fn () anyerror!void;

    pub fn init(allocator: *Allocator) !KeyMap {
        var root_submap = try SubMap.init(allocator);

        return @This(){
            .root_submap = root_submap,
            .current_submap = root_submap,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.root_submap.deinit();
    }

    pub fn onKey(self: *@This(), key: renderer.Key, mods: u32) bool {
        var maybe_submap = self.current_submap.onKey(key, mods) catch |err| {
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

    pub fn onChar(self: *@This(), codepoint: u32) bool {
        var maybe_submap = self.current_submap.onChar(codepoint) catch |err| {
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
};
