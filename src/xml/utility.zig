const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;
const unicode = std.unicode;
const testing = std.testing;

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

/// Expects `@TypeOf(char) == 'u8' or @TypeOf(char) == 'u21'`
pub fn lenOfUtf8OrNull(char: anytype) ?u3 {
    const T = @TypeOf(char);
    return switch (T) {
        u8 => unicode.utf8ByteSequenceLength(char) catch null,
        u21 => unicode.utf8CodepointSequenceLength(char) catch null,
        else => @compileError("Expected u8 or u21, got " ++ @typeName(T)),
    };
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

fn FieldNamesDiffResultType(comptime A: type, comptime B: type) type {
    const len = fieldNamesCommon(A, B).len;
    const a_len = meta.fieldNames(A).len;
    const b_len = meta.fieldNames(B).len;
    return struct {
        a: *const [a_len - len][]const u8,
        b: *const [b_len - len][]const u8,
    };
}

pub fn comptimeJoin(comptime separator: []const u8, comptime slices: []const []const u8) []const u8 {
    comptime {
        var buffer = [_]u8{0} ** (separator.len * slices.len + 1 + accum: {
            var accum_result = 0;
            for (slices) |slice| accum_result += slice.len;
            break :accum accum_result;
        });
        
        var idx: usize = 0;
        for (slices[0..]) |slice| {
            const to_append: []const u8 = " " ++ slice;
            mem.copy(u8, buffer[idx..], to_append);
            idx += to_append.len;
        }
        
        return buffer[1..];
    }
}

pub fn fieldNamesDiff(comptime A: type, comptime B: type) FieldNamesDiffResultType(A, B) {
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

