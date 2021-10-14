const std = @import("std");
const unicode = std.unicode;

pub fn getByte(src: []const u8, index: usize) ?u8 {
    if (index >= src.len) return null;
    return src[index];
}

pub fn getUtf8Len(src: []const u8, index: usize) ?u3 {
    const start_byte = getByte(src, index) orelse return null;
    return unicode.utf8ByteSequenceLength(start_byte) catch null;
}

pub fn getUtf8(src: []const u8, index: usize) ?u21 {
    const cp_len = getUtf8Len(src, index) orelse return null;
    const beg = index;
    const end = beg + cp_len;
    const slice = if (end <= src.len) src[beg..end] else return null;
    return unicode.utf8Decode(slice) catch null;
}
