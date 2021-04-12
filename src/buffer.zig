const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;

const Line = struct {
    content: ArrayList(u8),
};

pub const Buffer = struct {
    allocator: *Allocator,
    lines: ArrayList(Line),

    pub fn init(allocator: *Allocator, content: []const u8) !*Buffer {
        var self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .lines = ArrayList(Line).init(allocator),
        };

        var iter = mem.split(content, "\n");
        while (iter.next()) |line_content| {
            var line = Line{
                .content = ArrayList(u8).init(allocator),
            };
            try line.content.appendSlice(line_content);

            try self.lines.append(line);
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        for (self.lines.items) |*line| {
            line.content.deinit();
        }
        self.lines.deinit();
        self.allocator.destroy(self);
    }

    pub fn getContent(
        self: *@This(),
        allocator: *Allocator,
        line_index: usize,
        column_index: usize,
        codepoint_length: usize,
    ) ![]const u8 {
        const result = try self.getContentInternal(
            allocator,
            line_index,
            column_index,
            codepoint_length,
        );

        if (result.content) |content| {
            return content;
        }

        return error.BufferGetContentError;
    }

    const GetContentResult = struct {
        content: ?[]u8,
        content_byte_length: usize,
        content_codepoint_length: usize,
        line_count: usize,
    };

    fn getContentInternal(
        self: *@This(),
        maybe_allocator: ?*Allocator,
        line_index: usize,
        column_index: usize,
        codepoint_length: usize,
    ) !GetContentResult {
        var content_byte_size: usize = 0;
        var content_codepoint_size: usize = 0;
        var content_line_count: usize = 0;

        var first_line_starting_byte: usize = 0;
        var first_line_starting_codepoint: usize = 0;
        {
            const line = self.lines.items[line_index];
            const view = try std.unicode.Utf8View.init(line.content.items);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |codepoint_slice| {
                if (first_line_starting_codepoint >= column_index) {
                    break;
                }
                first_line_starting_byte += codepoint_slice.len;
                first_line_starting_codepoint += 1;
            }
        }

        var i: usize = line_index;
        outer: while (i < self.lines.items.len) : (i += 1) {
            content_line_count += 1;

            if (content_codepoint_size >= codepoint_length) {
                break :outer;
            }

            const line: Line = self.lines.items[i];
            var line_content = line.content.items;

            if (i == line_index) {
                line_content = line_content[first_line_starting_byte..];
            }

            const view = try std.unicode.Utf8View.init(line_content);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |codepoint_slice| {
                content_byte_size += codepoint_slice.len;
                content_codepoint_size += 1;

                if (content_codepoint_size >= codepoint_length) {
                    break :outer;
                }
            }

            // New line character
            content_byte_size += 1;
            content_codepoint_size += 1;
        }

        var maybe_content = if (maybe_allocator) |allocator| blk: {
            var content_pos: usize = 0;
            var content = try allocator.alloc(u8, content_byte_size);

            i = line_index;
            outer: while (i < self.lines.items.len) : (i += 1) {
                if (content_pos >= content_byte_size) {
                    break :outer;
                }

                const line: Line = self.lines.items[i];
                var line_content = line.content.items;

                if (i == line_index) {
                    line_content = line_content[first_line_starting_byte..];
                }

                const view = try std.unicode.Utf8View.init(line_content);
                var iter = view.iterator();
                while (iter.nextCodepointSlice()) |codepoint_slice| {
                    mem.copy(u8, content[content_pos..], codepoint_slice);
                    content_pos += codepoint_slice.len;

                    if (content_pos >= content_byte_size) {
                        break :outer;
                    }
                }

                // New line character
                content[content_pos] = '\n';
                content_pos += 1;
            }

            std.debug.assert(content_pos == content_byte_size);
            break :blk content;
        } else null;

        return GetContentResult{
            .content = maybe_content,
            .content_byte_length = content_byte_size,
            .content_codepoint_length = content_codepoint_size,
            .line_count = content_line_count,
        };
    }
};
