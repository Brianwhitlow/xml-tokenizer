const std = @import("std");
const unicode = std.unicode;

pub fn getByte(index: usize, src: []const u8) ?u8 {
    if (index >= src.len) return null;
    return src[index];
}

pub fn getUtf8Len(index: usize, src: []const u8) ?u3 {
    const start_byte = getByte(index, src) orelse return null;
    return unicode.utf8ByteSequenceLength(start_byte) catch null;
}

pub fn getUtf8(index: usize, src: []const u8) ?u21 {
    const cp_len = getUtf8Len(index, src) orelse return null;
    const beg = index;
    const end = beg + cp_len;
    const slice = if (end <= src.len) src[beg..end] else return null;
    return unicode.utf8Decode(slice) catch null;
}
