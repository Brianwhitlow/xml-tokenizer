const std = @import("std");
const debug = std.debug;
const utility = @import("utility.zig");

comptime {
    _ = utility;
    _ = Token;
    _ = TokenStream;
}

pub const Token = @import("Token.zig");
pub const TokenStream = @import("TokenStream.zig");



pub const spaces = [_]u8{ ' ', '\t', '\n', '\r' };
pub fn isSpace(char: u8) bool {
    return switch (char) {
        ' ',
        '\t',
        '\n',
        '\r',
        => true,
        else => false,
    };
}

pub const StringQuote = enum(u8) {
    single = '\'',
    double = '\"',

    pub fn value(self: @This()) u8 {
        return @enumToInt(self);
    }

    pub fn from(char: u8) @This() {
        return @intToEnum(@This(), char);
    }
};
pub const string_quotes = [_]u8{ '\"', '\'' };
pub fn isStringQuote(char: u8) bool {
    return switch (char) {
        '\"',
        '\'',
        => true,
        else => false,
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
pub fn isValidUtf8NameStartChar(codepoint: u21) bool {
    return switch (codepoint) {
        ':',
        'A'...'Z',
        'a'...'z',
        '_',
        '\u{c0}'...'\u{d6}',
        '\u{d8}'...'\u{f6}',
        '\u{f8}'...'\u{2ff}',
        '\u{370}'...'\u{37d}',
        '\u{37f}'...'\u{1fff}',
        '\u{200c}'...'\u{200d}',
        '\u{2070}'...'\u{218f}',
        '\u{2c00}'...'\u{2fef}',
        '\u{3001}'...'\u{d7ff}',
        '\u{f900}'...'\u{fdcf}',
        '\u{fdf0}'...'\u{fffd}',
        '\u{10000}'...'\u{effff}',
        => true,

        else => false,
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
pub fn isValidUtf8NameChar(codepoint: u21) bool {
    return @call(.{ .modifier = .always_inline }, isValidUtf8NameStartChar, .{codepoint}) or switch (codepoint) {
        '0'...'9',
        '-',
        '.',
        '\u{b7}',
        '\u{0300}'...'\u{036f}',
        '\u{203f}'...'\u{2040}',
        => true,

        else => false,
    };
}



pub fn validUtf8NameLength(src: []const u8, start_index: usize) usize {
    const name_start_char = utility.getUtf8(src, start_index) orelse return 0;
    if (!isValidUtf8NameStartChar(name_start_char)) {
        return 0;
    }
    const start_len = utility.lenOfUtf8OrNull(name_start_char).?;
    return start_len + utility.matchUtf8SubsectionLength(src, start_index + start_len, isValidUtf8NameChar);
}
test "validUtf8NameLength" {
    inline for ([_]struct { src: []const u8, start: usize, expected: usize }{
        .{ .start = 0, .src = "n",          .expected = "n".len       },
        .{ .start = 1, .src = "\tfoo:bar",  .expected = "foo:bar".len },
        .{ .start = 0, .src = "baz=",       .expected = "baz".len     },
        .{ .start = 0, .src = "0baz=",      .expected = 0             },
        .{ .start = 0, .src = "b0b=",       .expected = "b0b".len     },
    }) |info| {
        try std.testing.expectEqual(validUtf8NameLength(info.src, info.start), info.expected);
    }
}



pub fn whitespaceLength(src: []const u8, start_index: usize) usize {
    return utility.matchAsciiSubsectionLength(src, start_index, isSpace);
}
test "whitespaceLength" {
    inline for ([_]struct { src: []const u8, start: usize, expected: usize }{
        .{ .start = 0, .src = "",       .expected = 0            },
        .{ .start = 0, .src = "<",      .expected = 0            },
        .{ .start = 0, .src = "\t\n\r", .expected = "\t\n\r".len },
        .{ .start = 0, .src = " <",     .expected = " ".len      },
        .{ .start = 1, .src = ">\n\t<", .expected = "\n\t".len   },
    }) |info| {
        try std.testing.expectEqual(whitespaceLength(info.src, info.start), info.expected);
    }
}
