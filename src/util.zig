const std = @import("std");
const renderer = @import("opengl_renderer.zig");
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

            if (std.math.absFloat(self.value - self.to) > self.epsilon) {
                self.value = lerp(self.value, self.to, delta * self.rate);
            } else {
                self.value = self.to;
            }
        }
    };
}

pub fn normalizePath(allocator: *Allocator, path: []const u8) ![]const u8 {
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

    return try std.fs.realpathAlloc(allocator, actual_path);
}
