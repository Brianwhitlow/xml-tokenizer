const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;
const xml = @import("../xml.zig");
const Token = @import("Token.zig");

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
                    => todo(),
                    '/' => {
                        const start_index = self.getIndex();
                        self.incrByByte();
                        
                        switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                            '>' => return self.returnToken(Token.init(start_index, .element_close_inline)),
                            else => return self.returnError(Error.ExpectedClosingTag),
                        }
                    },
                    
                    '>' => {
                        self.incrByByte();
                        switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                            '<' => return self.tokenizeAfterLeftAngleBracket(),
                            else => todo()
                        }
                    },
                    else => unreachable,
                },
                
                .element_close_tag => |element_close_tag| {
                    _ = element_close_tag;
                    todo();
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
                
                .comment => |comment| {
                    _ = comment;
                    todo();
                },
                
                .cdata => |cdata| {
                    _ = cdata;
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

fn tokenizeAfterLeftAngleBracket(self: *TokenStream) NextRet {
    std.debug.assert(self.getUtf8().? == '<');
    const start_index = self.getIndex();
    
    self.incrByByte();
    switch (self.getUtf8() orelse return self.returnError(Error.Malformed)) {
        '/' => todo(),
        '?' => todo(),
        '!' => todo(),
        else => {
            if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) {
                return self.returnError(Error.InvalidNameStartChar);
            }
            
            self.incrByUtf8Len();
            
            while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                ' ',
                '\t',
                '\n',
                '\r',
                '/',
                '>',
                ':',
                => break,
                else => if (!xml.isValidUtf8NameChar(char))
                    return self.returnError(Error.InvalidNameChar),
                    
            } else return self.returnError(Error.ExpectedClosingTag);
            
            switch (self.getUtf8().?) {
                ' ',
                '\t',
                '\n',
                '\r',
                '/',
                '>',
                => {
                    const info = .{ .prefix_len = 0, .full_len = (self.getIndex() - start_index) };
                    const result = Token.initTag(start_index, .element_open, info);
                    return self.returnToken(result);
                },
                
                ':' => {
                    const prefix_len = self.getIndex() - (("<".len) + start_index);
                    self.incrByByte();
                    
                    if (!xml.isValidUtf8NameStartChar(self.getUtf8() orelse return self.returnError(Error.Malformed))) {
                        return self.returnError(Error.InvalidNameStartChar);
                    }
                    
                    while (self.getUtf8()) |char| : (self.incrByUtf8Len()) {
                        switch (char) {
                            ' ',
                            '\t',
                            '\n',
                            '\r',
                            '/',
                            '>',
                            => {
                                const info = .{ .prefix_len = prefix_len, .full_len = (self.getIndex() - start_index) };
                                const maybe_result = Token.initTag(start_index, .element_open, info);
                                return self.returnToken(maybe_result);
                            },
                            
                            ':' => return self.returnError(Error.InvalidNameChar),
                            
                            else => if (!xml.isValidUtf8NameChar(char)) {
                                return self.returnError(Error.InvalidNameChar);
                            }
                        }
                    } else return self.returnError(Error.ExpectedClosingTag);
                },
                
                else => unreachable
            }
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

test {
    var ts = TokenStream.init(
        \\<empty/>
    );
    
    var current = try ts.next().?;
    try testing.expectEqualStrings(current.slice(ts.buffer), "<empty");
    try testing.expectEqualStrings(current.method(.element_open, "name", ts.buffer), "empty");
    try testing.expectEqual(current.method(.element_open, "prefix", ts.buffer), null);
    
    current = try ts.next().?;
    try testing.expectEqualStrings(current.slice(ts.buffer), "/>");
    
    ts.reset(
        \\<pree:empty/>
    );
    
    current = try ts.next().?;
    try testing.expectEqualStrings(current.slice(ts.buffer), "<pree:empty");
    try testing.expectEqualStrings(current.method(.element_open, "name", ts.buffer), "empty");
    try testing.expectEqualStrings(current.method(.element_open, "prefix", ts.buffer).?, "pree");
    
    current = try ts.next().?;
    try testing.expectEqualStrings(current.slice(ts.buffer), "/>");
    
    try testing.expect(ts.next() == null);
}
