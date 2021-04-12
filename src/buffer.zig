const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;

const Line = struct {
    content: ArrayList(u8),

    fn init(allocator: *Allocator, content: []const u8) !Line {
        var line = Line{
            .content = ArrayList(u8).init(allocator),
        };
        try line.content.appendSlice(content);
        return line;
    }

    fn deinit(self: *@This()) void {
        self.content.deinit();
    }
};

pub const Buffer = struct {
    allocator: *Allocator,
    lines: ArrayList(Line),

    pub fn init(allocator: *Allocator) !*Buffer {
        var self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .lines = ArrayList(Line).init(allocator),
        };

        errdefer self.deinit();

        try self.lines.append(try Line.init(allocator, ""));

        return self;
    }

    pub fn initWithContent(allocator: *Allocator, content: []const u8) !*Buffer {
        var self = try Buffer.init(allocator);
        errdefer self.deinit();

        try self.insert(content, 0, 0);

        return self;
    }

    pub fn clone(self: *@This()) !*Buffer {
        var new_buffer = try Buffer.init(self.allocator);
        errdefer new_buffer.deinit();

        for (new_buffer.lines.items) |*line| {
            line.deinit();
        }

        try new_buffer.lines.resize(self.lines.items.len);

        for (self.lines.items) |*line, i| {
            new_buffer.lines.items[i] = try Line.init(self.allocator, line.content.items);
        }

        return new_buffer;
    }

    pub fn getLine(self: *@This(), index: usize) ![]const u8 {
        if (index >= self.lines.items.len) {
            return error.BufferLineOutOfBounds;
        }
        return self.lines.items[index];
    }

    pub fn deinit(self: *@This()) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
        self.allocator.destroy(self);
    }

    pub fn insert(
        self: *@This(),
        text: []const u8,
        line_index: usize,
        column_index: usize,
    ) !void {
        if (text.len == 0) return;

        var actual_line_index = line_index;
        var actual_column_index = column_index;

        if (actual_line_index >= self.lines.items.len) {
            actual_line_index = self.lines.items.len - 1;
            actual_column_index = try std.unicode.utf8CountCodepoints(
                self.lines.items[actual_line_index].content.items,
            );
        }

        const result = try self.getContentInternal(
            null,
            actual_line_index,
            actual_column_index,
            0,
        );

        var inserted_lines = ArrayList(Line).init(self.allocator);
        defer inserted_lines.deinit();

        var iter = mem.split(text, "\n");
        while (iter.next()) |line_content| {
            try inserted_lines.append(try Line.init(self.allocator, line_content));
        }

        if (inserted_lines.items.len == 0) return;

        var first_line: *Line = &inserted_lines.items[0];
        try first_line.content.insertSlice(0, result.before_content);

        var last_line = &inserted_lines.items[inserted_lines.items.len - 1];
        try last_line.content.appendSlice(result.after_content);

        self.lines.items[actual_line_index].deinit();
        self.lines.items[actual_line_index] = first_line.*;

        if (inserted_lines.items.len > 1) {
            try self.lines.insertSlice(actual_line_index + 1, inserted_lines.items[1..]);
        }
    }

    pub fn delete(
        self: *@This(),
        line_index: usize,
        column_index: usize,
        codepoint_length: usize,
    ) !void {
        if (codepoint_length == 0) return;

        const result = try self.getContentInternal(
            null,
            line_index,
            column_index,
            codepoint_length,
        );

        if (result.line_count == 0) return;

        {
            const first_line: *Line = &self.lines.items[line_index];
            first_line.content.shrinkRetainingCapacity(result.before_content.len);
            try first_line.content.appendSlice(result.after_content);
        }

        const deleted_lines = self.lines.items[line_index + 1 .. line_index + result.line_count];
        for (deleted_lines) |*line| {
            line.deinit();
        }

        const new_line_count = self.lines.items.len - deleted_lines.len;

        mem.copy(
            Line,
            self.lines.items[line_index + 1 .. new_line_count],
            self.lines.items[line_index + 1 + deleted_lines.len .. self.lines.items.len],
        );

        self.lines.shrinkRetainingCapacity(new_line_count);
    }

    pub fn getEntireContent(self: *@This(), allocator: *Allocator) ![]const u8 {
        var content = ArrayList(u8).init(allocator);

        for (self.lines.items) |line| {
            try content.appendSlice(line.content.items);
            try content.append('\n');
        }

        return content.toOwnedSlice();
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
        content_byte_length: usize = 0,
        content_codepoint_length: usize = 0,
        before_content: []const u8 = "",
        after_content: []const u8 = "",
        line_count: usize = 0,
    };

    fn getContentInternal(
        self: *@This(),
        maybe_allocator: ?*Allocator,
        line_index: usize,
        column_index: usize,
        codepoint_length: usize,
    ) !GetContentResult {
        if (line_index >= self.lines.items.len) {
            return GetContentResult{
                .content = if (maybe_allocator) |allocator| try allocator.alloc(u8, 0) else null,
            };
        }

        var content_byte_size: usize = 0;
        var content_codepoint_size: usize = 0;
        var content_line_count: usize = 0;

        const first_line = &self.lines.items[line_index];

        var first_line_starting_byte: usize = 0;
        var first_line_starting_codepoint: usize = 0;
        {
            const view = try std.unicode.Utf8View.init(first_line.content.items);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |codepoint_slice| {
                if (first_line_starting_codepoint >= column_index) {
                    break;
                }
                first_line_starting_byte += codepoint_slice.len;
                first_line_starting_codepoint += 1;
            }
        }

        if (codepoint_length == 0) {
            return GetContentResult{
                .content = if (maybe_allocator) |allocator| try allocator.alloc(u8, 0) else null,
                .before_content = first_line.content.items[0..first_line_starting_byte],
                .after_content = first_line.content.items[first_line_starting_byte..],
                .line_count = 0,
            };
        }

        var bytes_consumed_in_last_line: usize = 0;

        var i: usize = line_index;
        outer: while (i < self.lines.items.len) : (i += 1) {
            content_line_count += 1;
            bytes_consumed_in_last_line = 0;

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
                bytes_consumed_in_last_line += codepoint_slice.len;
                content_codepoint_size += 1;

                if (content_codepoint_size >= codepoint_length) {
                    break :outer;
                }
            }

            // New line character
            content_byte_size += 1;
            content_codepoint_size += 1;
        }

        const last_line = &self.lines.items[line_index + (content_line_count - 1)];

        var before_content: []const u8 = first_line.content.items[0..first_line_starting_byte];
        var after_content: []const u8 = if (first_line == last_line) blk: {
            break :blk first_line.content.items[first_line_starting_byte + bytes_consumed_in_last_line ..];
        } else blk: {
            break :blk last_line.content.items[bytes_consumed_in_last_line..];
        };

        var maybe_content = if (maybe_allocator) |allocator| blk: {
            var content_pos: usize = 0;
            var content = try allocator.alloc(u8, content_byte_size);
            errdefer allocator.free(content);

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

            if (content_pos != content_byte_size) {
                return error.BufferGetContentInvalidContentPos;
            }

            break :blk content;
        } else null;

        return GetContentResult{
            .content = maybe_content,
            .content_byte_length = content_byte_size,
            .content_codepoint_length = content_codepoint_size,
            .before_content = before_content,
            .after_content = after_content,
            .line_count = content_line_count,
        };
    }

    fn print(self: *@This()) void {
        std.debug.print("Buffer contents:\n", .{});
        for (self.lines.items) |line| {
            std.debug.print("\t\"{s}\"\n", .{line.content.items});
        }
    }
};

comptime {
    _ = Buffer.init;
    _ = Buffer.initWithContent;
    _ = Buffer.clone;
    _ = Buffer.getContent;
    _ = Buffer.getEntireContent;
    _ = Buffer.insert;
    _ = Buffer.delete;
    _ = Buffer.print;
}

test "buffer" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    var buffer = try Buffer.initWithContent(allocator,
        \\hello world
        \\second line
        \\
        \\olá mundo -- em português
    );
    defer buffer.deinit();

    {
        const result = try buffer.getContentInternal(allocator, 0, 0, 0);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, ""));
        expect(result.line_count == 0);
    }

    {
        const result = try buffer.getContentInternal(allocator, 0, 0, 11);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, "hello world"));
        expect(result.line_count == 1);
        expect(mem.eql(u8, result.before_content, ""));
        expect(mem.eql(u8, result.after_content, ""));
    }

    {
        const result = try buffer.getContentInternal(allocator, 0, 0, 12);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, "hello world\n"));
        expect(result.line_count == 2);
        expect(mem.eql(u8, result.before_content, ""));
        expect(mem.eql(u8, result.after_content, "second line"));
    }

    {
        const result = try buffer.getContentInternal(allocator, 0, 0, 18);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, "hello world\nsecond"));
        expect(result.line_count == 2);
        expect(mem.eql(u8, result.before_content, ""));
        expect(mem.eql(u8, result.after_content, " line"));
    }

    {
        const result = try buffer.getContentInternal(allocator, 0, 0, 24);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, "hello world\nsecond line\n"));
        expect(result.line_count == 3);
    }

    {
        const result = try buffer.getContentInternal(allocator, 0, 5, 0);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, ""));
        expect(mem.eql(u8, result.before_content, "hello"));
        expect(mem.eql(u8, result.after_content, " world"));
        expect(result.line_count == 0);
    }

    {
        const result = try buffer.getContentInternal(allocator, 3, 0, 9);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, "olá mundo"));
        expect(result.line_count == 1);
    }

    {
        const result = try buffer.getContentInternal(allocator, 3, 4, 5);
        const content = result.content.?;
        defer allocator.free(content);

        expect(mem.eql(u8, content, "mundo"));
        expect(result.line_count == 1);
    }

    {
        try buffer.delete(0, 10, 39);

        const content = try buffer.getEntireContent(allocator);
        defer allocator.free(content);

        expect(mem.eql(u8, content,
            \\hello worls
            \\
        ));
    }

    {
        try buffer.insert("hello\nyo\nyo\n", 0, 5);

        const content = try buffer.getEntireContent(allocator);
        defer allocator.free(content);

        expect(mem.eql(u8, content,
            \\hellohello
            \\yo
            \\yo
            \\ worls
            \\
        ));
    }

    {
        try buffer.insert("new content", 10, 2);

        const content = try buffer.getEntireContent(allocator);
        defer allocator.free(content);

        expect(mem.eql(u8, content,
            \\hellohello
            \\yo
            \\yo
            \\ worlsnew content
            \\
        ));
    }

    {
        var new_buffer = try buffer.clone();
        defer new_buffer.deinit();
    }
}
