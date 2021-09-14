const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;

pub const TokenStream = @import("xml/TokenStream.zig");
pub const Token = @import("xml/Token.zig");

pub fn isValidNameStartCharUtf8(char: u21) bool {
    return switch (char) {
        'A'...'Z',
        'a'...'z',
        '_',
        '\u{c0}'    ... '\u{d6}',
        '\u{d8}'    ... '\u{f6}',
        '\u{f8}'    ... '\u{2ff}',
        '\u{370}'   ... '\u{37d}',
        '\u{37f}'   ... '\u{1fff}',
        '\u{200c}'  ... '\u{200d}',
        '\u{2070}'  ... '\u{218f}',
        '\u{2c00}'  ... '\u{2fef}',
        '\u{3001}'  ... '\u{d7ff}',
        '\u{f900}'  ... '\u{fdcf}',
        '\u{fdf0}'  ... '\u{fffd}',
        '\u{10000}' ... '\u{effff}',
        => true,
        
        else
        => false,
    };
}

pub fn isValidNameCharUtf8(char: u21) bool {
    return isValidNameStartCharUtf8(char) or switch (char) {
        '0'...'9',
        '-',
        '.',
        '\u{b7}',
        '\u{0300}'...'\u{036f}',
        '\u{203f}'...'\u{2040}',
        => true,
        
        else
        => false,
    };
}

pub usingnamespace struct {
    pub fn isValidNameStartCharUtf8At(index: usize, src: []const u8) bool {
        return isValidNameCharUtf8AtImpl(index, src, isValidNameStartCharUtf8);
    }
    
    pub fn isValidNameCharUtf8At(index: usize, src: []const u8) bool {
        return isValidNameCharUtf8AtImpl(index, src, isValidNameCharUtf8);
    }
    
    fn isValidNameCharUtf8AtImpl(index: usize, src: []const u8, comptime constraint: (fn(u21)bool)) bool {
        if (index >= src.len) return false;
        const char = src[index];
        const end = index + (unicode.utf8ByteSequenceLength(char) catch return false);
        
        if (end >= src.len) return false;
        const utf8_cp = unicode.utf8Decode(src[index..end]) catch return false;
        return constraint(utf8_cp);
    }
};

comptime {
    _ = @This();
    _ = TokenStream;
    _ = Token;
}
