const std = @import("std");
const renderer = @import("opengl_renderer.zig");

pub fn fromVoidPtr(comptime T: type, ptr: *c_void) T {
    return @ptrCast(T, @alignCast(@alignOf(T), ptr));
}

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

            if (std.math.abs(self.value - self.to) > self.epsilon) {
                self.value = lerp(self.value, self.to, delta * self.rate);
            } else {
                self.value = self.to;
            }
        }
    };
}
