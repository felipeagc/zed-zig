const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("opengl_renderer.zig");
const Regex = @import("regex.zig").Regex;
const mem = std.mem;
const Allocator = mem.Allocator;

pub fn Animation(comptime T: type) type {
    return struct {
        value: T = 0,
        to: T = 0,
        rate: T = 20,
        epsilon: T = 0.1,

        fn lerp(a: T, b: T, t: T) T {
            return a + (b - a) * t;
        }

        pub fn update(self: *@This(), delta: T) void {
            if (self.value != self.to) {
                renderer.requestRedraw();
            }

            if (@fabs(self.value - self.to) > self.epsilon) {
                self.value = lerp(self.value, self.to, delta * self.rate);
            } else {
                self.value = self.to;
            }
        }
    };
}

pub fn normalizePath(allocator: Allocator, path: []const u8) ![]const u8 {
    var actual_path = path;
    defer if (actual_path.ptr != path.ptr) {
        allocator.free(actual_path);
    };

    if (mem.startsWith(u8, path, "~")) {
        if (std.os.getenv("HOME")) |home_path| {
            actual_path = try mem.concat(
                allocator,
                u8,
                &[_][]const u8{ home_path, path[1..] },
            );
        }
    }

    return if (std.fs.realpathAlloc(allocator, actual_path)) |realpath|
        realpath
    else |_|
        (try allocator.dupe(u8, actual_path));
}

pub const Walker = struct {
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    ignore_regex: ?Regex,

    pub const Entry = struct {
        /// The containing directory. This can be used to operate directly on `basename`
        /// rather than `path`, avoiding `error.NameTooLong` for deeply nested paths.
        /// The directory remains open until `next` or `deinit` is called.
        dir: std.fs.Dir,
        /// TODO make this null terminated for API convenience
        basename: []const u8,

        path: []const u8,
        kind: std.fs.IterableDir.Entry.Kind,
    };

    const StackItem = struct {
        dir_it: std.fs.IterableDir.Iterator,
        dirname_len: usize,
    };

    /// Recursively iterates over a directory.
    /// Must call `Walker.deinit` when done.
    /// `dir_path` must not end in a path separator.
    /// The order of returned file system entries is undefined.
    pub fn init(allocator: Allocator, dir_path: []const u8, ignore_regex: ?Regex) !Walker {
        std.debug.assert(!mem.endsWith(u8, dir_path, std.fs.path.sep_str));

        var dir = try std.fs.cwd().openIterableDir(dir_path, .{});
        errdefer dir.close();

        var name_buffer = std.ArrayList(u8).init(allocator);
        errdefer name_buffer.deinit();

        try name_buffer.appendSlice(dir_path);

        var walker = Walker{
            .stack = std.ArrayList(Walker.StackItem).init(allocator),
            .name_buffer = name_buffer,
            .ignore_regex = ignore_regex,
        };

        try walker.stack.append(Walker.StackItem{
            .dir_it = dir.iterate(),
            .dirname_len = dir_path.len,
        });

        return walker;
    }

    /// After each call to this function, and on deinit(), the memory returned
    /// from this function becomes invalid. A copy must be made in order to keep
    /// a reference to the path.
    pub fn next(self: *Walker) !?Entry {
        while (true) {
            if (self.stack.items.len == 0) return null;
            // `top` becomes invalid after appending to `self.stack`.
            var top = &self.stack.items[self.stack.items.len - 1];
            const dirname_len = top.dirname_len;
            if (try top.dir_it.next()) |base| {
                if (self.ignore_regex) |*ignore_regex| {
                    ignore_regex.setBuffer(base.name);
                    if (ignore_regex.nextMatch(null, null) != null) {
                        continue;
                    }
                }

                self.name_buffer.shrinkRetainingCapacity(dirname_len);
                try self.name_buffer.append(std.fs.path.sep);
                try self.name_buffer.appendSlice(base.name);

                if (base.kind == .Directory) {
                    var new_dir = top.dir_it.dir.openIterableDir(base.name, .{}) catch |err| switch (err) {
                        error.NameTooLong => unreachable, // no path sep in base.name
                        else => |e| return e,
                    };
                    {
                        errdefer new_dir.close();
                        try self.stack.append(StackItem{
                            .dir_it = new_dir.iterate(),
                            .dirname_len = self.name_buffer.items.len,
                        });
                        top = &self.stack.items[self.stack.items.len - 1];
                    }
                }
                return Entry{
                    .dir = top.dir_it.dir,
                    .basename = self.name_buffer.items[dirname_len + 1 ..],
                    .path = self.name_buffer.items,
                    .kind = base.kind,
                };
            } else {
                self.stack.pop().dir_it.dir.close();
            }
        }
    }

    pub fn deinit(self: *Walker) void {
        while (self.stack.popOrNull()) |*item| item.dir_it.dir.close();
        self.stack.deinit();
        self.name_buffer.deinit();
        if (self.ignore_regex) |ignore_regex| {
            ignore_regex.deinit();
        }
    }
};

pub fn Channel(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        queue: [N]T = undefined,
        queue_head: usize = 0,
        queue_tail: usize = 0,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        fn queuePush(self: *Self, item: T) !void {
            var item_ptr = &self.queue[self.queue_head];
            const new_head = (self.queue_head + 1) % self.queue.len;
            if (new_head == self.queue_tail) {
                return error.ChannelQueueFull;
            }
            self.queue_head = new_head;
            item_ptr.* = item;
        }

        fn queuePop(self: *Self) ?T {
            if (self.queue_head != self.queue_tail) {
                const event = self.queue[self.queue_tail];
                self.queue_tail = (self.queue_tail + 1) % self.queue.len;
                return event;
            }
            return null;
        }

        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.queuePush(item);

            // Signal new queue item
            self.cond.signal();
        }

        pub fn receiveOrNull(self: *Self) ?T {
            self.mutex.lock();

            const item = self.queuePop();

            self.cond.signal();
            self.mutex.unlock();
            return item;
        }

        pub fn receive(self: *Self) T {
            self.mutex.lock();

            while (self.queue_head == self.queue_tail) {
                self.cond.wait(&self.mutex);
            }

            const item = self.queuePop().?;

            self.cond.signal();
            self.mutex.unlock();

            return item;
        }
    };
}

pub fn runCommandAlloc(
    allocator: Allocator,
    options: struct {
        command: []const u8,
        stdin_text: ?[]const u8,
        stdout_text: ?*[]const u8,
        stderr_text: ?*[]const u8,
    },
) !std.ChildProcess.Term {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    if (builtin.os.tag != .windows) {
        try args.append("/usr/bin/env");
    }

    var iter = mem.split(u8, options.command, " ");
    while (iter.next()) |part| {
        try args.append(part);
    }

    if (args.items.len == 0) {
        return error.InvalidRunCommand;
    }

    var proc = std.ChildProcess.init(args.items, allocator);

    proc.stdin_behavior = if (options.stdin_text == null) .Ignore else .Pipe;
    proc.stdout_behavior = if (options.stdout_text == null) .Ignore else .Pipe;
    proc.stderr_behavior = if (options.stderr_text == null) .Ignore else .Pipe;

    try proc.spawn();

    if (options.stdin_text) |stdin_text| {
        var writer = proc.stdin.?.writer();
        try writer.writeAll(stdin_text);
        proc.stdin.?.close();
        proc.stdin = null;
    }

    if (options.stdout_text) |stdout_text| {
        var out_reader = proc.stdout.?.reader();
        stdout_text.* = try out_reader.readAllAlloc(allocator, std.math.max(
            if (options.stdin_text) |stdin_text| (stdin_text.len * 2) else 0,
            1024 * 64,
        ));
    }

    if (options.stderr_text) |stderr_text| {
        var err_reader = proc.stderr.?.reader();
        stderr_text.* = try err_reader.readAllAlloc(allocator, std.math.max(
            if (options.stdin_text) |stdin_text| (stdin_text.len * 2) else 0,
            1024 * 64,
        ));
    }

    return try proc.wait();
}
