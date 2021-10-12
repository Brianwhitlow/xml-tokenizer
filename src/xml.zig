const std = @import("std");
const tokenization = @import("xml/tokenization.zig");

pub inline fn isValidUtf8NameStartChar(codepoint: u21) bool {
    return switch (codepoint) {
        ':',
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
pub const valid_name_start_char: u8 = blk: {
    var result: u8 = 0;
    while (!isValidUtf8NameStartChar(result)) result += 1;
    break :blk result;
};
pub const invalid_name_start_char: u8 = blk: {
    var result: u8 = 0;
    while (isValidUtf8NameStartChar(result)) result += 1;
    break :blk result;
};



pub inline fn isValidUtf8NameChar(codepoint: u21) bool {
    return @call(.{ .modifier = .always_inline }, isValidUtf8NameStartChar, .{codepoint}) or switch (codepoint) {
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
pub const valid_name_char: u8 = blk: {
    var result: u8 = 0;
    while (!isValidUtf8NameChar(result)) result += 1;
    break :blk result;
};
pub const invalid_name_char: u8 = blk: {
    var result: u8 = 0;
    while (isValidUtf8NameChar(result)) result += 1;
    break :blk result;
};


test {
    try std.testing.expect(!isValidUtf8NameStartChar(invalid_name_start_char));
    try std.testing.expect(!isValidUtf8NameChar(invalid_name_char));
}

comptime {
    _ = tokenization;
}
