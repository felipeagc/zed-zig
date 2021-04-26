const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const util = @import("util.zig");
const FileType = @import("filetype.zig").FileType;

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

const TextOp = union(enum) {
    insert: struct {
        line: usize,
        column: usize,
        text: []const u8,
        codepoint_length: usize,
    },
    delete: struct {
        line: usize,
        column: usize,
        text: []const u8,
        codepoint_length: usize,
    },
    begin_checkpoint: struct {
        line: usize,
        column: usize,
    },
    end_checkpoint: struct {
        line: usize,
        column: usize,
    },
};

const TextOpOptions = struct {
    save_history: bool,
};

pub const BufferOptions = struct {
    filetype: *FileType,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const Buffer = struct {
    allocator: *Allocator,
    lines: ArrayList(Line),
    undo_stack: ArrayList(TextOp),
    redo_stack: ArrayList(TextOp),
    name: []const u8,
    absolute_path: ?[]const u8,
    filetype: *FileType,

    pub fn init(allocator: *Allocator, options: BufferOptions) !*Buffer {
        var self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .lines = ArrayList(Line).init(allocator),
            .undo_stack = ArrayList(TextOp).init(allocator),
            .redo_stack = ArrayList(TextOp).init(allocator),
            .name = try allocator.dupe(u8, options.name orelse "** unnamed buffer **"),
            .absolute_path = if (options.path) |path| try std.fs.realpathAlloc(
                allocator,
                path,
            ) else null,
            .filetype = options.filetype,
        };

        errdefer self.deinit();

        try self.lines.append(try Line.init(allocator, ""));

        return self;
    }

    pub fn initWithContent(allocator: *Allocator, content: []const u8, options: BufferOptions) !*Buffer {
        var self = try Buffer.init(allocator, options);
        errdefer self.deinit();

        try self.insertInternal(content, 0, 0, .{
            .save_history = false,
        });

        return self;
    }

    pub fn initFromFile(allocator: *Allocator, options: BufferOptions) !*Buffer {
        if (options.path == null) return error.BufferInitMissingPath;

        const file = try std.fs.cwd().createFile(options.path.?, .{
            .read = true,
            .truncate = false,
        });
        defer file.close();

        var actual_path = try util.normalizePath(allocator, options.path.?);
        defer allocator.free(actual_path);

        const stat = try file.stat();
        const content = try file.readToEndAlloc(allocator, @intCast(usize, stat.size));
        defer allocator.free(content);

        var self = try Buffer.initWithContent(allocator, content, .{
            .name = std.fs.path.basename(actual_path),
            .path = actual_path,
            .filetype = options.filetype,
        });
        errdefer self.deinit();

        return self;
    }

    pub fn clone(self: *@This(), options: BufferOptions) !*Buffer {
        var new_buffer = try Buffer.init(self.allocator, options);
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

    pub fn save(self: *@This()) !void {
        if (self.absolute_path) |path| {
            try std.fs.deleteFileAbsolute(path);

            var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
            defer file.close();

            const content = try self.getEntireContent(self.allocator);
            defer self.allocator.free(content);

            try file.writeAll(content);

            std.log.info("Wrote: {s}", .{path});
        } else {
            return error.BufferNoPathSpecified;
        }
    }

    pub fn getLineCount(self: *@This()) usize {
        return self.lines.items.len;
    }

    pub fn getLine(self: *@This(), index: usize) ![]const u8 {
        if (index >= self.lines.items.len) {
            return error.BufferLineOutOfBounds;
        }
        return self.lines.items[index].content.items;
    }

    pub fn deinit(self: *@This()) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }

        for (self.undo_stack.items) |op| {
            switch (op) {
                .insert => {
                    self.allocator.free(op.insert.text);
                },
                .delete => {
                    self.allocator.free(op.delete.text);
                },
                .end_checkpoint, .begin_checkpoint => {},
            }
        }

        for (self.redo_stack.items) |op| {
            switch (op) {
                .insert => {
                    self.allocator.free(op.insert.text);
                },
                .delete => {
                    self.allocator.free(op.delete.text);
                },
                .end_checkpoint, .begin_checkpoint => {},
            }
        }

        self.allocator.free(self.name);
        if (self.absolute_path) |path| {
            self.allocator.free(path);
        }
        self.undo_stack.deinit();
        self.redo_stack.deinit();
        self.lines.deinit();
        self.allocator.destroy(self);
    }

    fn insertInternal(
        self: *@This(),
        text: []const u8,
        line_index: usize,
        column_index: usize,
        comptime options: TextOpOptions,
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

        if (options.save_history) {
            for (self.redo_stack.items) |op| {
                switch (op) {
                    .insert => self.allocator.free(op.insert.text),
                    .delete => self.allocator.free(op.delete.text),
                    .end_checkpoint, .begin_checkpoint => {},
                }
            }

            self.redo_stack.shrinkRetainingCapacity(0);

            try self.undo_stack.append(TextOp{
                .insert = .{
                    .line = line_index,
                    .column = column_index,
                    .text = try self.allocator.dupe(u8, text),
                    .codepoint_length = try std.unicode.utf8CountCodepoints(text),
                },
            });
        }
    }

    pub fn insert(
        self: *@This(),
        text: []const u8,
        line_index: usize,
        column_index: usize,
    ) !void {
        return self.insertInternal(
            text,
            line_index,
            column_index,
            .{ .save_history = true },
        );
    }

    fn deleteInternal(
        self: *@This(),
        line_index: usize,
        column_index: usize,
        codepoint_length: usize,
        comptime options: TextOpOptions,
    ) !void {
        if (codepoint_length == 0) return;

        const result = try self.getContentInternal(
            if (options.save_history) self.allocator else null,
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

        if (options.save_history) {
            for (self.redo_stack.items) |op| {
                switch (op) {
                    .insert => self.allocator.free(op.insert.text),
                    .delete => self.allocator.free(op.delete.text),
                    .end_checkpoint, .begin_checkpoint => {},
                }
            }
            self.redo_stack.shrinkRetainingCapacity(0);

            try self.undo_stack.append(TextOp{
                .delete = .{
                    .line = line_index,
                    .column = column_index,
                    .text = result.content.?,
                    .codepoint_length = codepoint_length,
                },
            });
        }
    }

    pub fn delete(
        self: *@This(),
        line_index: usize,
        column_index: usize,
        codepoint_length: usize,
    ) !void {
        return self.deleteInternal(
            line_index,
            column_index,
            codepoint_length,
            .{ .save_history = true },
        );
    }

    pub fn getEntireContent(self: *@This(), allocator: *Allocator) ![]const u8 {
        var content = ArrayList(u8).init(allocator);
        try content.ensureCapacity(self.lines.items.len * 40);

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

    fn undoOp(self: *@This(), op: TextOp) !void {
        try self.redo_stack.append(op);
        switch (op) {
            .insert => {
                try self.deleteInternal(
                    op.insert.line,
                    op.insert.column,
                    op.insert.codepoint_length,
                    .{ .save_history = false },
                );
            },
            .delete => {
                try self.insertInternal(
                    op.delete.text,
                    op.delete.line,
                    op.delete.column,
                    .{ .save_history = false },
                );
            },
            .begin_checkpoint, .end_checkpoint => {},
        }
    }

    pub fn undo(self: *@This(), line: *usize, column: *usize) !void {
        if (self.undo_stack.popOrNull()) |op| {
            try self.undoOp(op);
            if (op != .end_checkpoint) return;
        }

        while (self.undo_stack.popOrNull()) |op| {
            try self.undoOp(op);
            if (op == .begin_checkpoint) {
                line.* = op.begin_checkpoint.line;
                column.* = op.begin_checkpoint.column;
                return;
            }
        }
    }

    fn redoOp(self: *@This(), op: TextOp) !void {
        try self.undo_stack.append(op);
        switch (op) {
            .insert => {
                try self.insertInternal(
                    op.insert.text,
                    op.insert.line,
                    op.insert.column,
                    .{ .save_history = false },
                );
            },
            .delete => {
                try self.deleteInternal(
                    op.delete.line,
                    op.delete.column,
                    op.delete.codepoint_length,
                    .{ .save_history = false },
                );
            },
            .begin_checkpoint, .end_checkpoint => {},
        }
    }

    pub fn redo(self: *@This(), line: *usize, column: *usize) !void {
        if (self.redo_stack.popOrNull()) |op| {
            try self.redoOp(op);
            if (op != .begin_checkpoint) return;
        }

        while (self.redo_stack.popOrNull()) |op| {
            try self.redoOp(op);
            if (op == .end_checkpoint) {
                line.* = op.end_checkpoint.line;
                column.* = op.end_checkpoint.column;
                return;
            }
        }
    }

    pub fn beginCheckpoint(self: *@This(), line: usize, column: usize) !void {
        try self.undo_stack.append(TextOp{
            .begin_checkpoint = .{
                .line = line,
                .column = column,
            },
        });
    }

    pub fn endCheckpoint(self: *@This(), line: usize, column: usize) !void {
        if (self.undo_stack.items.len > 0) {
            const last_op = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last_op.* == .begin_checkpoint) {
                _ = self.undo_stack.pop();
                return;
            }
        }

        try self.undo_stack.append(TextOp{
            .end_checkpoint = .{
                .line = line,
                .column = column,
            },
        });
    }

    pub fn getCodepointDistance(
        self: *@This(),
        start_line: usize,
        start_column: usize,
        end_line: usize,
        end_column: usize,
    ) !usize {
        if (end_line < start_line) return error.GetCodepointDistanceInvalidEndLine;
        if (end_line == start_line and end_column < start_column) return error.GetCodepointDistanceInvalidEndColumn;
        if (end_line == start_line and end_column == start_column) return 0;

        var distance: usize = 0;

        var line_index: usize = start_line;
        parent: while (line_index <= end_line) : (line_index += 1) {
            const line = try self.getLine(line_index);
            var iter = (try std.unicode.Utf8View.init(line)).iterator();
            var column_index: usize = 0;
            while (iter.nextCodepoint()) |codepoint| {
                if (line_index > start_line or (line_index == start_line and column_index > start_column)) {
                    distance += 1;
                }
                if (line_index >= end_line and column_index >= end_column) {
                    break :parent;
                }
                column_index += 1;
            }

            if (line_index != start_line or column_index != start_column) {
                distance += 1; // new line character
            }
        }

        return distance;
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
    _ = Buffer.undo;
    _ = Buffer.redo;
    _ = Buffer.getCodepointDistance;
}

test "buffer" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    var buffer = try Buffer.initWithContent(allocator,
        \\hello world
        \\second line
        \\
        \\olá mundo -- em português
    , .{});
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

        expect((try buffer.getCodepointDistance(0, 0, 0, 0)) == 0);
        expect((try buffer.getCodepointDistance(0, 0, 0, 1)) == 1);
        expect((try buffer.getCodepointDistance(0, 0, 0, 2)) == 2);
        expect((try buffer.getCodepointDistance(0, 0, 1, 0)) == 11);
        expect((try buffer.getCodepointDistance(0, 0, 2, 0)) == 14);
    }

    {
        var new_buffer = try buffer.clone(.{});
        defer new_buffer.deinit();
    }
}

test "buffer2" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;

    var buffer = try Buffer.initWithContent(allocator,
        \\
        \\a
        \\}
    , .{});
    defer buffer.deinit();

    expect((try buffer.getCodepointDistance(0, 0, 1, 1)) == 2);
}
