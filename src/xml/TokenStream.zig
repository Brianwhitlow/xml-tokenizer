const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;
const xml = @import("../xml.zig");

const TokenStream = @This();
buffer: []const u8,
state: State,

pub fn init(src: []const u8) TokenStream {
    return TokenStream {
        .buffer = src,
        .state = .{},
    };
}

pub fn reset(self: *TokenStream, new_src: ?[]const u8) void {
    self.* = TokenStream.init(new_src orelse self.buffer);
}

pub const Token = @import("Token.zig");

pub const Error = error {
    PrematureEof,
    ContentNotAllowedInPrologue,
    Malformed,
    InvalidNameChar,
    InvalidNameStartChar,
    ExpectedClosingTag,
};

/// The return type of TokenStream.next().
pub const NextRet = ?(Error!Token);

/// Returns null if there are no more tokens to parse.
pub fn next(self: *TokenStream) NextRet {
    // const on_start = self.state;
    // defer std.debug.assert(std.meta.activeTag(on_start.info) != self.state.info or switch (self.state.info) {
    //     .start => false,
    //     .err => true,
    //     .last_tok => |tok| (tok == .element_open)
    // });
    
    errdefer std.debug.assert(self.state.info == .err);
    switch (self.state.info) {
        .err => return null,
        .start => {
            std.debug.assert(self.getIndex() == 0);
            switch (self.getByte() orelse return self.returnError(Error.PrematureEof)) {
                ' ',
                '\t',
                '\n',
                '\r',
                => todo(),
                '<' => return self.tokenizeAfterLeftAngleBracket(),
                else => return self.returnError(Error.ContentNotAllowedInPrologue)
            }
        },
        
        .last_tok => |last_tok| {
            switch (last_tok) {
                .element_open => switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => {
                        self.incrByByte();
                        while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch(char) {
                            ' ',
                            '\t',
                            '\n',
                            '\r',
                            => continue,
                            '/' => return self.tokenizeAfterElementOpenWhitespaceSlash(),
                            '>' => {
                                self.incrByByte();
                                switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                                    '<' => return self.tokenizeAfterLeftAngleBracket(),
                                    else => todo()
                                }
                            },
                            else => todo()
                        } else todo();
                    },
                    
                    '/' => return self.tokenizeAfterElementOpenWhitespaceSlash(),
                    
                    '>' => {
                        self.incrByByte();
                        switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                            '<' => return self.tokenizeAfterLeftAngleBracket(),
                            else => todo()
                        }
                    },
                    else => unreachable,
                },
                
                .element_close_tag => {
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    switch (self.getUtf8() orelse return null) {
                        else => todo()
                    }
                },
                
                .element_close_inline => {
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    switch (self.getUtf8() orelse return null) {
                        else => todo()
                    }
                },
                
                .attribute_name => |attribute_name| {
                    _ = attribute_name;
                    todo();
                },
                
                .attribute_value_segment => |attribute_value_segment| {
                    _ = attribute_value_segment;
                    todo();
                },
                
                .comment => |comment| {
                    _ = comment;
                    todo();
                },
                
                .cdata => |cdata| {
                    _ = cdata;
                    todo();
                },
                
                .text => |text| {
                    _ = text;
                    todo();
                },
                
                .whitespace => |whitespace| {
                    _ = whitespace;
                    todo();
                },
                
                .pi_target => |pi_target| {
                    _ = pi_target;
                    todo();
                },
                
                .pi_token => |pi_token| {
                    _ = pi_token;
                    todo();
                },
            }
        },
    }
}

inline fn todo() noreturn {
    unreachable;
}

fn tokenizeAfterElementOpenWhitespaceSlash(self: *TokenStream) NextRet {
    const start_index = self.getIndex();
    self.incrByByte();
    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
        '>' => return self.returnToken(Token.init(start_index, .element_close_inline)),
        else => return self.returnError(Error.ExpectedClosingTag),
    }
}

fn tokenizeAfterLeftAngleBracket(self: *TokenStream) NextRet {
    std.debug.assert(self.getUtf8().? == '<');
    const start_index = self.getIndex();
    
    self.incrByByte();
    switch (self.getUtf8() orelse return self.returnError(Error.Malformed)) {
        '/' => {
            self.incrByByte();
            if (!xml.isValidUtf8NameStartChar(self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag))) {
                return self.returnError(Error.InvalidNameStartChar);
            }
            
            self.incrByUtf8Len();
            
            var prefix_len: usize = 0;
            var identifier_len: usize = 1;
            
            blk_while0: while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                ' ',
                '\t',
                '\n',
                '\r',
                => while (self.getUtf8()) |notnamechar| : (self.incrByUtf8Len()) switch (notnamechar) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => {},
                    '>' => break :blk_while0,
                    else => return self.returnError(Error.ExpectedClosingTag),
                } else return self.returnError(Error.ExpectedClosingTag),
                
                ':' => {
                    if (prefix_len != 0) {
                        return self.returnError(Error.InvalidNameChar);
                    }
                    
                    prefix_len = identifier_len;
                    identifier_len = 0;
                    
                    self.incrByByte();
                    const maybe_codepoint = self.getUtf8();
                    if (maybe_codepoint == null or !xml.isValidUtf8NameStartChar(maybe_codepoint.?)) {
                        return self.returnError(Error.InvalidNameStartChar);
                    }
                    
                    identifier_len += unicode.utf8CodepointSequenceLength(maybe_codepoint.?) catch unreachable;
                },
                
                '>' => break,
                
                else => {
                    if (!xml.isValidUtf8NameChar(char))
                        return self.returnError(Error.InvalidNameChar)
                    else {
                        identifier_len += unicode.utf8CodepointSequenceLength(char) catch unreachable;
                    }
                },
            } else return self.returnError(Error.ExpectedClosingTag);
            
            std.debug.assert(self.getUtf8().? == '>');
            
            const info = .{ .prefix_len = prefix_len, .identifier_len = identifier_len, .full_len = (self.getIndex() + 1) - start_index };
            const result = Token.initTag(start_index, .element_close_tag, info);
            return self.returnToken(result);
        },
        
        '?' => todo(),
        '!' => todo(),
        
        else => {
            if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) {
                return self.returnError(Error.InvalidNameStartChar);
            }
            
            self.incrByUtf8Len();
            
            var prefix_len: usize = 0;
            
            while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                ' ',
                '\t',
                '\n',
                '\r',
                '/',
                '>',
                => break,
                
                ':' => {
                    if (prefix_len != 0) {
                        return self.returnError(Error.InvalidNameChar);
                    }
                    prefix_len = self.getIndex() - (start_index + ("<".len));
                    
                    self.incrByByte();
                    const maybe_codepoint = self.getUtf8();
                    if (maybe_codepoint == null or !xml.isValidUtf8NameStartChar(maybe_codepoint.?)) {
                        return self.returnError(Error.InvalidNameStartChar);
                    }
                },
                
                else => if (!xml.isValidUtf8NameChar(char))
                    return self.returnError(Error.InvalidNameChar),
            } else return self.returnError(Error.ExpectedClosingTag);
            
            std.debug.assert(switch (self.getUtf8().?) {
                ' ',
                '\t',
                '\n',
                '\r',
                '/',
                '>',
                => true,
                else => false,
            });
            
            const info = .{ .prefix_len = prefix_len, .full_len = (self.getIndex() - start_index) };
            const result = Token.initTag(start_index, .element_open, info);
            return self.returnToken(result);
        }
    }
}



fn returnToken(self: *TokenStream, tok: Token) NextRet {
    self.state.info = .{ .last_tok = tok.info };
    return @as(NextRet, tok);
}

fn returnError(self: *TokenStream, err: Error) NextRet {
    self.state.info = .{ .err = err };
    return @as(NextRet, err);
}



/// Expects and asserts that the current UTF8 codepoint is valid.
fn incrByUtf8Len(self: *TokenStream) void {
    const codepoint = self.getUtf8() orelse return;
    self.state.index += unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
}

/// Asserts that the current utf8 codepoint is exactly one byte long,
/// thus ensuring that subsequent traversal will be valid.
fn incrByByte(self: *TokenStream) void {
    requirements: {
        const codepoint = self.getUtf8() orelse std.debug.panic("Invalid UTF8 codepoint or EOF encountered when trying to increment by a single byte.", .{});
        const codepoint_len = unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
        std.debug.assert(codepoint_len == 1);
        break :requirements;
    }
    self.state.index += 1;
}

fn getUtf8(self: TokenStream) ?u21 {
    const start_byte = self.getByte() orelse return null;
    const sequence_len = unicode.utf8ByteSequenceLength(start_byte) catch return null;
    
    const beg = self.state.index;
    const end = beg + sequence_len;
    if (end > self.buffer.len) return null;
    
    return unicode.utf8Decode(self.buffer[beg..end]) catch null;
}

fn getByte(self: TokenStream) ?u8 {
    const index = self.state.index;
    const buffer = self.buffer;
    const in_range = (index < buffer.len);
    return if (in_range) buffer[index] else null;
}

/// For convenience
fn getIndex(self: TokenStream) usize {
    return self.state.index;
}



const State = struct {
    index: usize = 0,
    info: Info = .start,
    
    const Info = union(enum) {
        err: Error,
        start,
        last_tok: Token.Info,
    };
};

const tests = struct {
    const expect_token = struct {
        fn elementOpen(src: []const u8, maybe_tok: NextRet, prefix: ?[]const u8, name: []const u8) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            
            const full_slice: []const u8 = blk: {
                const to_be_joined: []const []const u8 = if (prefix) |prfx| &.{ "<", prfx, ":", name } else &.{ "<", name };
                break :blk try std.mem.concat(testing.allocator, u8, to_be_joined);
            };
            defer testing.allocator.free(full_slice);
            
            try testing.expect(tok.info == .element_open);
            try testing.expectEqualStrings(tok.slice(src), full_slice);
            try testing.expectEqualStrings(tok.method(.element_open, "name", src), name);
            if (prefix) |prfx| {
                try testing.expectEqualStrings(tok.method(.element_open, "prefix", src).?, prfx);
            } else {
                try testing.expectEqual(tok.method(.element_open, "prefix", src), null);
            }
        }
        
        fn elementCloseTag(src: []const u8, maybe_tok: NextRet, prefix: ?[]const u8, name: []const u8) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            
            try testing.expect(tok.info == .element_close_tag);
            
            try testing.expectEqualStrings(tok.slice(src)[0..2], "</");
            try testing.expectEqualStrings(tok.slice(src)[tok.slice(src).len - 1..], ">");
            
            try testing.expectEqualStrings(tok.method(.element_close_tag, "name", src), name);
            if (prefix) |prfx| {
                try testing.expectEqualStrings(tok.method(.element_close_tag, "prefix", src).?, prfx);
            } else {
                try testing.expectEqual(tok.method(.element_close_tag, "prefix", src), null);
            }
        }
        
        fn elementCloseInline(src: []const u8, maybe_tok: NextRet) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expect(tok.info == .element_close_inline);
            try testing.expectEqualStrings(tok.slice(src), "/>");
        }
        
        fn isNull(maybe_tok: NextRet) !void {
            try testing.expect(maybe_tok == null);
        }
        
        fn isError(maybe_tok: NextRet, err: Error) !void {
            try testing.expectError(err, maybe_tok orelse return error.NullToken);
        }
    };
    
    fn expectElementOpen(ts: *TokenStream, prefix: ?[]const u8, name: []const u8) !void {
        try expect_token.elementOpen(ts.buffer, ts.next(), prefix, name);
    }
    
    fn expectElementCloseTag(ts: *TokenStream, prefix: ?[]const u8, name: []const u8) !void {
        try expect_token.elementCloseTag(ts.buffer, ts.next(), prefix, name);
    }
    
    fn expectElementCloseInline(ts: *TokenStream) !void {
        try expect_token.elementCloseInline(ts.buffer, ts.next());
    }
    
    fn expectNull(ts: *TokenStream) !void {
        try expect_token.isNull(ts.next());
    }
    
    fn expectError(ts: *TokenStream, err: Error) !void {
        try expect_token.isError(ts.next(), err);
    }
};

test "simple empty tags 1" {
    var ts = TokenStream.init(undefined);
    
    inline for (.{"<empty/>", "<empty    />"}) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
    }
    
    inline for (.{"<pree:empty/>", "<pree:empty    />"}) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, "pree", "empty");
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
    }
}

test "simple empty tags 2" {
    var ts = TokenStream.init(undefined);
    
    inline for (.{
        "<empty></empty>",
        "<empty></empty    >",
        "<empty    ></empty>",
        "<empty    ></empty    >",
    }) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectElementCloseTag(&ts, null, "empty");
        try tests.expectNull(&ts);
    }
    
    inline for (.{
        "<pree:empty></pree:empty>",
        "<pree:empty></pree:empty    >",
        "<pree:empty    ></pree:empty>",
        "<pree:empty    ></pree:empty    >",
    }) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, "pree", "empty");
        try tests.expectElementCloseTag(&ts, "pree", "empty");
        try tests.expectNull(&ts);
    }
}
