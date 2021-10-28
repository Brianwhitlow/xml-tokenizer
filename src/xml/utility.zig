const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;
const unicode = std.unicode;
const testing = std.testing;

const utility = @This();

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

pub fn lenOfUtf8OrNull(char: u21) ?u3 {
    return unicode.utf8CodepointSequenceLength(char) catch null;
}

pub fn matchUtf8SubsectionLength(src: []const u8, start_index: usize, comptime func: fn(u21)bool) usize {
    var index: usize = start_index;
    while (getUtf8(src, index)) |char| : (index += lenOfUtf8OrNull(char).?) {
        if (!func(char)) break;
    }
    return index - start_index;
}

pub fn matchAsciiSubsectionLength(src: []const u8, start_index: usize, comptime func: fn(u8)bool) usize {
    var index: usize = start_index;
    while (getByte(src, index)) |char| : (index += 1) {
        if (!func(char)) break;
    }
    return index - start_index;
}

pub fn fieldNamesCommon(comptime A: type, comptime B: type) []const []const u8 {
    comptime {
        const a_fields = meta.fieldNames(A);
        const b_fields = meta.fieldNames(B);
        
        if (a_fields.len == 0 or b_fields.len == 0) {
            return &.{};
        }
        
        var buffer: [math.max(a_fields.len, b_fields.len)][]const u8 = undefined;
        var len: usize = 0;
        
        for (a_fields) |a_name| {
            for (b_fields) |b_name| {
                if (mem.eql(u8, a_name, b_name)) {
                    len += 1;
                    buffer[len - 1] = a_name;
                }
            }
        }
        
        return buffer[0..len];
    }
}

pub fn fieldNamesDiff(comptime A: type, comptime B: type) struct {
    a: *const [meta.fieldNames(A).len - in_common.len][]const u8,
    b: *const [meta.fieldNames(B).len - in_common.len][]const u8,
    const in_common = utility.fieldNamesCommon(A, B);
} {
    const common_fields = comptime fieldNamesCommon(A, B);
    const a_fields = comptime meta.fieldNames(A);
    const b_fields = comptime meta.fieldNames(B);
    
    const a_max_len = (a_fields.len - common_fields.len);
    const b_max_len = (b_fields.len - common_fields.len);
    
    if (common_fields.len == 0) {
        return .{
            .a = a_fields[0..a_max_len],
            .b = b_fields[0..b_max_len]
        };
    }
    
    comptime var a_buffer = [_][]const u8 { undefined } ** a_max_len;
    comptime var a_len: usize = 0;
    
    outerloop: inline for (a_fields) |name| {
        inline for (common_fields) |common_name| {
            if (comptime mem.eql(u8, name, common_name)) continue :outerloop;
        }
        a_len += 1;
        a_buffer[a_len - 1] = name;
    }
    
    comptime var b_buffer = [_][]const u8 { undefined } ** b_max_len;
    comptime var b_len: usize = 0;
    
    outerloop: inline for (b_fields) |name| {
        inline for (common_fields) |common_name| {
            if (comptime mem.eql(u8, name, common_name)) continue :outerloop;
        }
        b_len += 1;
        b_buffer[b_len - 1] = name;
    }
    
    const a = a_buffer[0..a_len];
    const b = b_buffer[0..b_len];
    
    return .{
        .a = a,
        .b = b,
    };
}

