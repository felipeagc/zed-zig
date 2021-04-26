const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("oniguruma.h");
});

pub fn initLibrary() !void {
    var use_encs = [_]c.OnigEncoding{&c.OnigEncodingUTF8};
    if (c.onig_initialize(&use_encs[0], use_encs.len) != 0) {
        return error.RegexLibraryInitError;
    }
}

pub fn deinitLibrary() void {
    _ = c.onig_end();
}

pub const Regex = struct {
    allocator: *Allocator,
    regset: *c.OnigRegSet,
    pattern_ids: ArrayList(usize),

    str: [*c]const u8 = null,
    end: [*c]const u8 = null,

    start: [*c]const u8 = null,
    range: [*c]const u8 = null,

    pub fn init(allocator: *Allocator) !Regex {
        var regset: ?*c.OnigRegSet = null;
        if (c.onig_regset_new(&regset, 0, null) != c.ONIG_NORMAL or regset == null) {
            return error.RegexInitError;
        }

        return Regex{
            .allocator = allocator,
            .regset = regset.?,
            .pattern_ids = ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Regex) void {
        c.onig_regset_free(self.regset);
        self.pattern_ids.deinit();
    }

    pub fn addPattern(self: *Regex, id: usize, pattern: []const u8) !void {
        if (pattern.len == 0) {
            return error.RegexPatternEmpty;
        }

        var einfo = mem.zeroes(c.OnigErrorInfo);

        var pattern_regex: c.OnigRegex = null;
        if (c.onig_new(
            &pattern_regex,
            &pattern[0],
            @ptrCast([*]const u8, &pattern[0]) + pattern.len,
            c.ONIG_OPTION_DEFAULT,
            &c.OnigEncodingUTF8,
            &c.OnigSyntaxOniguruma,
            &einfo,
        ) != c.ONIG_NORMAL) {
            return error.RegexAddPatternError;
        }

        if (c.onig_regset_add(self.regset, pattern_regex) != c.ONIG_NORMAL) {
            return error.RegexAddPatternError;
        }

        try self.pattern_ids.append(id);
    }

    pub fn setBuffer(self: *Regex, buffer: []const u8) void {
        self.str = buffer.ptr;
        self.end = @ptrCast([*]const u8, buffer.ptr) + buffer.len;
        self.start = self.str;
        self.range = self.end;
    }

    pub fn nextMatch(self: *Regex, maybe_match_start: ?*usize, maybe_match_end: ?*usize) ?usize {
        if (self.str == null or self.start == self.range) {
            return null;
        }

        var match_pos: c_int = 0;
        var regex_index: c_int = c.onig_regset_search(
            self.regset,
            self.str,
            self.end,
            self.start,
            self.range,
            @intToEnum(c.OnigRegSetLead, c.ONIG_REGSET_POSITION_LEAD),
            c.ONIG_OPTION_NONE,
            &match_pos,
        );

        if (regex_index >= 0) {
            var maybe_region: ?*c.OnigRegion = c.onig_regset_get_region(
                self.regset,
                regex_index,
            );
            if (maybe_region) |region| {
                if (region.beg[0] < 0 or region.end[0] < 0) {
                    return null;
                }

                if (maybe_match_start) |match_start| match_start.* = @intCast(usize, region.beg[0]);
                if (maybe_match_end) |match_end| match_end.* = @intCast(usize, region.end[0]);

                self.start = self.str + @intCast(usize, region.end[0]);

                c.onig_region_clear(region);
                return self.pattern_ids.items[@intCast(usize, regex_index)];
            }
        }

        return null;
    }
};

comptime {
    _ = Regex.init;
    _ = Regex.deinit;
    _ = Regex.addPattern;
    _ = Regex.setBuffer;
    _ = Regex.nextMatch;
}
