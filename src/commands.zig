const std = @import("std");
const editor = @import("editor.zig");

pub fn writeFile(panel: *editor.Panel, args: [][]const u8) anyerror!void {
    if (args.len != 1) return error.InvalidWriteParameters;

    std.log.info("Writing file", .{});
}
