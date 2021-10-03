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
    ContentNotAllowedInPrologue,
    ContentNotAllowedInTrailingSection,
    Malformed,
    InvalidNameChar,
    InvalidNameStartChar,
    ExpectedClosingTag,
    EntityReferenceMissingName,
};

/// The return type of TokenStream.next().
pub const NextRet = ?(Error!Token);

/// Returns null if there are no more tokens to parse.
pub fn next(self: *TokenStream) NextRet {
    errdefer std.debug.assert(self.state.info == .err);
    switch (self.state.info) {
        .err => return null,
        .start => {
            std.debug.assert(self.getIndex() == 0);
            switch (self.getByte() orelse return null) {
                ' ',
                '\t',
                '\n',
                '\r',
                => while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => continue,
                    '<' => return self.returnToken(Token.initTag(0, .whitespace, .{ .len = self.getIndex() - 0 })),
                    else => return self.returnError(Error.ContentNotAllowedInPrologue)
                } else return self.returnToken(Token.initTag(0, .whitespace, .{ .len = self.getIndex() - 0 })),
                '<' => return self.tokenizeAfterLeftAngleBracket(),
                else => return self.returnError(Error.ContentNotAllowedInPrologue)
            }
        },
        
        .last_tok => |last_tok| {
            switch (last_tok) {
                .element_open => {
                    self.state.depth += 1;
                    return self.tokenizeAfterElementOpenOrAttributeValue();
                },
                
                .element_close_tag => {
                    self.state.depth -= 1;
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    return if (self.getUtf8() != null) self.tokenizeContent() else self.returnNullIfDepth0(Error.ExpectedClosingTag);
                },
                
                .element_close_inline => {
                    self.state.depth -= 1;
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    return if (self.getUtf8() != null) self.tokenizeContent() else self.returnNullIfDepth0(Error.ExpectedClosingTag);
                },
                
                .attribute_name => {
                    std.debug.assert(switch (self.getUtf8().?) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        '=',
                        => true,
                        else => false
                    });
                    
                    while (self.getUtf8()) |char| : (self.incrByByte()) switch (char) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => continue,
                        '=' => break,
                        else => return self.returnError(Error.ExpectedClosingTag)
                    } else return self.returnError(Error.ExpectedClosingTag);
                    
                    std.debug.assert(self.getUtf8().? == '=');
                    
                    self.incrByByte();
                    while (self.getUtf8()) |char| : (self.incrByByte()) switch (char) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => continue,
                        '"',
                        '\'',
                        => break,
                        else => return self.returnError(Error.ExpectedClosingTag),
                    } else return self.returnError(Error.ExpectedClosingTag);
                    
                    std.debug.assert(switch (self.getUtf8().?) {
                        '"',
                        '\'',
                        => true,
                        else => false,
                    });
                    
                    self.state.last_quote = State.QuoteType.initUtf8(self.getUtf8().?);
                    self.incrByByte();
                    
                    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                        '"',
                        '\'',
                        => {
                            const current_quote_type = State.QuoteType.init(self.getByte().?);
                            if (self.state.last_quote.? != current_quote_type) {
                                return self.tokenizeAttributeValueSegmentText();
                            }
                            
                            const result = Token.initTag(self.getIndex(), .attribute_value_segment, .empty_quotes);
                            return self.returnToken(result);
                        },
                        '&' => return self.tokenizeAttributeValueSegmentEntityRef(),
                        else => return self.tokenizeAttributeValueSegmentText(),
                    }
                },
                
                .attribute_value_segment => switch (self.getUtf8().?) {
                    '"',
                    '\'',
                    => {
                        std.debug.assert(self.state.last_quote.? == State.QuoteType.init(self.getByte().?));
                        self.incrByByte();
                        self.state.last_quote = null;
                        return self.tokenizeAfterElementOpenOrAttributeValue();
                    },
                    ';' => {
                        self.incrByByte();
                        switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                            '"',
                            '\'',
                            => {
                                if (self.state.last_quote.? == State.QuoteType.init(self.getByte().?)) {
                                    self.incrByByte();
                                    self.state.last_quote = null;
                                    return self.tokenizeAfterElementOpenOrAttributeValue();
                                }
                                return self.tokenizeAttributeValueSegmentText();
                            },
                            '&' => return self.tokenizeAttributeValueSegmentEntityRef(),
                            else => return self.tokenizeAttributeValueSegmentText(),
                        }
                    },
                    '&' => return self.tokenizeAttributeValueSegmentEntityRef(),
                    else => unreachable,
                },
                
                .comment => {
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    switch (self.getUtf8() orelse return self.returnNullIfDepth0(Error.ExpectedClosingTag)) {
                        '<' => return self.tokenizeAfterLeftAngleBracket(),
                        else => return self.tokenizeContent(),
                    }
                },
                
                .cdata => |cdata| {
                    _ = cdata;
                    todo();
                },
                
                .text => switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                    '<' => return self.tokenizeAfterLeftAngleBracket(),
                    '&' => return self.tokenizeAfterAmpersandInContent(),
                    else => unreachable,
                },
                
                .entity_reference => {
                    std.debug.assert(self.getUtf8().? == ';');
                    self.incrByByte();
                    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                        '<' => return self.tokenizeAfterLeftAngleBracket(),
                        '&' => return self.tokenizeAfterAmpersandInContent(),
                        else => return self.tokenizeContent(),
                    }
                },
                
                .whitespace => switch (self.getUtf8() orelse return self.returnNullIfDepth0(Error.ExpectedClosingTag)) {
                    '<' => return self.tokenizeAfterLeftAngleBracket(),
                    '&' => return self.tokenizeAfterAmpersandInContent(),
                    else => unreachable,
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

const State = struct {
    index: usize = 0,
    info: Info = .start,
    depth: usize = 0,
    last_quote: ?QuoteType = null,
    
    const QuoteType = enum(u8) {
        single = '\'',
        double = '"',
        pub fn init(char: u8) QuoteType {
            std.debug.assert(switch (char) {
                '\'',
                '"',
                => true,
                else => false,
            });
            return @intToEnum(QuoteType, char);
        }
        
        pub fn initUtf8(char: u21) QuoteType {
            std.debug.assert(unicode.utf8CodepointSequenceLength(char) catch unreachable == 1);
            return QuoteType.init(@intCast(u8, char));
        }
        
        pub fn value(self: QuoteType) u8 {
            return @enumToInt(self);
        }
    };
    
    const Info = union(enum) {
        err: Error,
        start,
        last_tok: Token.Info,
    };
};

fn tokenizeAfterAmpersandInContent(self: *TokenStream) NextRet {
    std.debug.assert(self.getUtf8().? == '&');
    const start_index = self.getIndex();
    self.incrByByte();
    switch (self.getUtf8() orelse return self.returnError(Error.EntityReferenceMissingName)) {
        ';' => return self.returnError(Error.EntityReferenceMissingName),
        else => {
            const codepoint = self.getUtf8().?;
            if (!xml.isValidUtf8NameStartChar(codepoint) and codepoint != ':') {
                return self.returnError(Error.InvalidNameStartChar);
            }
            self.incrByUtf8Len();
        }
    }
    
    while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
        ';' => break,
        else => if (!xml.isValidUtf8NameCharOrColon(char))
            return self.returnError(Error.InvalidNameChar) 
    } else return self.returnError(Error.ExpectedClosingTag);
    
    std.debug.assert(self.getUtf8().? == ';');
    
    const info = .{ .len = (self.getIndex() + 1) - start_index };
    const result = Token.initTag(start_index, .entity_reference, info);
    return self.returnToken(result);
}

fn tokenizeContent(self: *TokenStream) NextRet {
    const start_index = self.getIndex();
    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
        '<' => return self.tokenizeAfterLeftAngleBracket(),
        '&' => return self.tokenizeAfterAmpersandInContent(),
        else => {
            var non_whitespace: bool = false;
            while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                ' ',
                '\t',
                '\n',
                '\r',
                => {},
                '&',
                '<',
                => break,
                else => non_whitespace = true,
            } else if (self.state.depth == 0 and non_whitespace) {
                return self.returnError(Error.ContentNotAllowedInTrailingSection);
            }
            
            const info = .{ .len = (self.getIndex() - start_index) };
            const result = if (non_whitespace)
                Token.initTag(start_index, .text, info)
            else
                Token.initTag(start_index, .whitespace, info);
            return self.returnToken(result);
        }
    }
}

fn tokenizeElementCloseInline(self: *TokenStream) NextRet {
    const start_index = self.getIndex();
    self.incrByByte();
    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
        '>' => return self.returnToken(Token.init(start_index, .element_close_inline)),
        else => return self.returnError(Error.ExpectedClosingTag),
    }
}

fn tokenizeAfterElementOpenOrAttributeValue(self: *TokenStream) NextRet {
    std.debug.assert(self.state.last_quote == null);
    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
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
                '/' => return self.tokenizeElementCloseInline(),
                '>' => {
                    self.incrByByte();
                    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                        '<' => return self.tokenizeAfterLeftAngleBracket(),
                        else => return self.tokenizeContent()
                    }
                },
                else => {
                    if (!xml.isValidUtf8NameStartChar(char)) {
                        return self.returnError(Error.InvalidNameStartChar);
                    }
                    
                    const start_index = self.getIndex();
                    var prefix_len: usize = 0;
                    
                    self.incrByUtf8Len();
                    while (self.getUtf8()) |name_char| : (self.incrByUtf8Len()) switch(name_char) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        '=',
                        => {
                            const full_len = self.getIndex() - start_index;
                            const info = .{ .prefix_len = prefix_len, .full_len = full_len };
                            const result = Token.initTag(start_index, .attribute_name, info);
                            return self.returnToken(result);
                        },
                        
                        ':' => {
                            if (prefix_len != 0) {
                                return self.returnError(Error.InvalidNameChar);
                            }
                            prefix_len = self.getIndex() - start_index;
                            
                            self.incrByByte();
                            const maybe_codepoint = self.getUtf8();
                            if (maybe_codepoint == null or !xml.isValidUtf8NameStartChar(maybe_codepoint.?)) {
                                return self.returnError(Error.InvalidNameStartChar);
                            }
                        },
                        
                        else => if (!xml.isValidUtf8NameChar(name_char))
                            return self.returnError(Error.InvalidNameChar)
                    } else return self.returnError(Error.ExpectedClosingTag);
                }
            } else return self.returnError(Error.ExpectedClosingTag);
        },
        '/' => return self.tokenizeElementCloseInline(),
        '>' => {
            self.incrByByte();
            return self.tokenizeContent();
        },
        else => unreachable,
    }
}

fn tokenizeAttributeValueSegmentEntityRef(self: *TokenStream) NextRet {
    std.debug.assert(self.getUtf8().? == '&');
    const start_index = self.getIndex();
    self.incrByByte();
    if (!xml.isValidUtf8NameStartChar(self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag))) {
        return self.returnError(Error.InvalidNameStartChar);
    }
    
    self.incrByUtf8Len();
    while (self.getUtf8()) |name_char| : (self.incrByUtf8Len()) switch (name_char) {
        ';' => break,
        else => if (!xml.isValidUtf8NameCharOrColon(name_char))
            return self.returnError(Error.InvalidNameChar)
    } else return self.returnError(Error.ExpectedClosingTag);
    
    std.debug.assert(self.getUtf8().? == ';');
    const len = (self.getIndex() + 1) - start_index;
    const info = Token.Info.AttributeValueSegment { .entity_reference = .{ .len = len } };
    const result = Token.initTag(start_index, .attribute_value_segment, info);
    return self.returnToken(result);
}

fn tokenizeAttributeValueSegmentText(self: *TokenStream) NextRet {
    const start_index = self.getIndex();
    
    while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
        '"',
        '\'',
        => {
            const current_quote_type = State.QuoteType.init(self.getByte().?);
            if (self.state.last_quote.? == current_quote_type) break;
        },
        '&' => break,
        '<' => return self.returnError(Error.Malformed),
        else => continue,
    };
    
    // Using Token.initTag here causes a segfault at runtime if we use anonymous union initialization. Something to do with initializing the union 
    const len = (self.getIndex() - start_index);
    const info = Token.Info.AttributeValueSegment { .text = .{ .len = len } };
    const result = Token.initTag(start_index, .attribute_value_segment, info);
    return self.returnToken(result);
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
        '!' => {
            self.incrByByte();
            switch (self.getUtf8() orelse return self.returnError(Error.Malformed)) {
                '-' => {
                    self.incrByByte();
                    switch (self.getUtf8() orelse return self.returnError(Error.Malformed)) {
                        '-' => {
                            self.incrByByte();
                            while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                                '-' => {
                                    self.incrByByte();
                                    switch (self.getUtf8() orelse return self.returnError(Error.ExpectedClosingTag)) {
                                        '-' => {
                                            self.incrByByte();
                                            switch (self.getUtf8() orelse return self.returnError(Error.Malformed)) {
                                                '>' => {
                                                    const info = .{ .len = (self.getIndex() + 1) - start_index };
                                                    const result = Token.initTag(start_index, .comment, info);
                                                    return self.returnToken(result);
                                                },
                                                else => return self.returnError(Error.Malformed),
                                            }
                                        },
                                        
                                        else => continue,
                                    }
                                },
                                else => continue
                            } else return self.returnError(Error.ExpectedClosingTag);
                        },
                        else => return self.returnError(Error.Malformed)
                    }
                },
                
                '[' => todo(),
                
                else => return self.returnError(Error.Malformed),
            }
        },
        
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



fn returnNullIfDepth0(self: *TokenStream, otherwise_error: Error) NextRet {
    return if (self.state.depth == 0) null else return self.returnError(otherwise_error);
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
inline fn getIndex(self: TokenStream) usize {
    return self.state.index;
}



const tests = struct {
    const expect_token = struct {
        fn elementOpen(src: []const u8, maybe_tok: NextRet, prefix: ?[]const u8, name: []const u8) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            
            const full_slice: []const u8 = try std.mem.concat(testing.allocator, u8, @as([]const []const u8, if (prefix) |prfx| &.{ "<", prfx, ":", name } else &.{ "<", name }));
            defer testing.allocator.free(full_slice);
            
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .element_open), tok.info);
            try testing.expectEqualStrings(full_slice, tok.slice(src));
            try testing.expectEqualStrings(name, tok.info.element_open.name(tok.index, src));
            if (prefix) |prfx|
                try testing.expectEqualStrings(prfx, tok.info.element_open.prefix(tok.index, src) orelse return error.NullPrefix)
            else {
                try testing.expectEqual(@as(?[]const u8, null), tok.info.element_open.prefix(tok.index, src));
            }
        }
        
        fn elementCloseTag(src: []const u8, maybe_tok: NextRet, prefix: ?[]const u8, name: []const u8) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .element_close_tag), tok.info);
            try testing.expectEqualStrings("</", tok.slice(src)[0..2]);
            try testing.expectEqualStrings(">", tok.slice(src)[tok.slice(src).len - 1..]);
            try testing.expectEqualStrings(name, tok.info.element_close_tag.name(tok.index, src));
            if (prefix) |prfx|
                try testing.expectEqualStrings(prfx, tok.info.element_close_tag.prefix(tok.index, src) orelse return error.NullPrefix)
            else {
                try testing.expectEqual(@as(?[]const u8, null), tok.info.element_close_tag.prefix(tok.index, src));
            }
        }
        
        fn elementCloseInline(src: []const u8, maybe_tok: NextRet) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .element_close_inline), tok.info);
            try testing.expectEqualStrings("/>", tok.slice(src));
        }
        
        fn text(src: []const u8, maybe_tok: NextRet, content: []const u8) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .text), tok.info);
            try testing.expectEqualStrings(content, tok.slice(src));
        }
        
        fn whitespace(src: []const u8, maybe_tok: NextRet, content: []const u8) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .whitespace), tok.info);
            try testing.expectEqualStrings(content, tok.slice(src));
        }
        
        fn entityReference(src: []const u8, maybe_tok: NextRet, name: []const u8) !void {
            const full_slice = try std.mem.concat(testing.allocator, u8, &.{ "&", name, ";" });
            defer testing.allocator.free(full_slice);
            
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .entity_reference), tok.info);
            try testing.expectEqualStrings(full_slice, tok.slice(src));
            try testing.expectEqualStrings(name, tok.info.entity_reference.name(tok.index, src));
        }
        
        fn comment(src: []const u8, maybe_tok: NextRet, content: []const u8) !void {
            const full_slice = try std.mem.concat(testing.allocator, u8, &.{ "<!--", content, "-->" });
            defer testing.allocator.free(full_slice);
            
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .comment), tok.info);
            try testing.expectEqualStrings(full_slice, tok.slice(src));
            try testing.expectEqualStrings(content, tok.info.comment.data(tok.index, src));
        }
        
        fn attributeName(src: []const u8, maybe_tok: NextRet, prefix: ?[]const u8, name: []const u8) !void {
            const full_slice: []const u8 = if (prefix) |prfx| @as([]const u8, try std.mem.concat(testing.allocator, u8, &.{ prfx, ":", name })) else name;
            defer if (prefix != null) testing.allocator.free(full_slice);
            
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .attribute_name), tok.info);
            try testing.expectEqualStrings(full_slice, tok.slice(src));
            try testing.expectEqualStrings(name, tok.info.attribute_name.name(tok.index, src));
            if (prefix) |prfx|
                try testing.expectEqualStrings(prfx, tok.info.attribute_name.prefix(tok.index, src) orelse return error.NullPrefix)
            else {
                try testing.expectEqual(@as(?[]const u8, null), tok.info.attribute_name.prefix(tok.index, src));
            }
        }
        
        const AttributeValueSegment = union(std.meta.Tag(Token.Info.AttributeValueSegment)) {
            empty_quotes,
            text: []const u8,
            entity_reference: struct{ name: []const u8 },
        };
        
        fn attributeValueSegment(src: []const u8, maybe_tok: NextRet, segment: AttributeValueSegment) !void {
            const tok: Token = try (maybe_tok orelse error.NullToken);
            try testing.expectEqual(@as(std.meta.Tag(Token.Info), .attribute_value_segment), tok.info);
            try testing.expectEqual(std.meta.activeTag(segment), tok.info.attribute_value_segment);
            
            const full_slice: []const u8 = switch (segment) {
                .empty_quotes => "",
                .text => |text| text,
                .entity_reference => |entity_reference| try std.mem.concat(testing.allocator, u8, &.{ "&", entity_reference.name, ";" }),
            };
            defer switch (segment) {
                .empty_quotes => {},
                .text => {},
                .entity_reference => testing.allocator.free(full_slice),
            };
            
            try testing.expectEqualStrings(full_slice, tok.slice(src));
            switch (segment) {
                .empty_quotes => {},
                .text => {},
                .entity_reference => |entity_reference| {
                    const name = tok.info.attribute_value_segment.entity_reference.name(tok.index, src);
                    try testing.expectEqualStrings(entity_reference.name, name);
                }
            }
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
    
    fn expectText(ts: *TokenStream, content: []const u8) !void {
        try expect_token.text(ts.buffer, ts.next(), content);
    }
    
    fn expectWhitespace(ts: *TokenStream, content: []const u8) !void {
        try expect_token.whitespace(ts.buffer, ts.next(), content);
    }
    
    fn expectEntityReference(ts: *TokenStream, name: []const u8) !void {
        try expect_token.entityReference(ts.buffer, ts.next(), name);
    }
    
    fn expectComment(ts: *TokenStream, content: []const u8) !void {
        try expect_token.comment(ts.buffer, ts.next(), content);
    }
    
    fn expectAttributeName(ts: *TokenStream, prefix: ?[]const u8, name: []const u8) !void {
        try expect_token.attributeName(ts.buffer, ts.next(), prefix, name);
    }
    
    fn expectAttributeValueSegment(ts: *TokenStream, segment: expect_token.AttributeValueSegment) !void {
        try expect_token.attributeValueSegment(ts.buffer, ts.next(), segment);
    }
    
    fn expectAttribute(ts: *TokenStream, prefix: ?[]const u8, name: []const u8, segments: []const expect_token.AttributeValueSegment) !void {
        try expectAttributeName(ts, prefix, name);
        for (segments) |segment| {
            try expectAttributeValueSegment(ts, segment);
        }
    }
    
    
    
    fn expectNull(ts: *TokenStream) !void {
        try expect_token.isNull(ts.next());
    }
    
    fn expectError(ts: *TokenStream, err: Error) !void {
        try expect_token.isError(ts.next(), err);
    }
};

test "empty source" {
    var ts = TokenStream.init("");
    try tests.expectNull(&ts);
}

test "empty source with whitespace" {
    var ts = TokenStream.init(" ");
    try tests.expectWhitespace(&ts, " ");
    try tests.expectNull(&ts);
}

test "content in prologue" {
    var ts = TokenStream.init("foo");
    try tests.expectError(&ts, Error.ContentNotAllowedInPrologue);
    try tests.expectNull(&ts);
}

test "simple empty tags" {
    var ts = TokenStream.init(undefined);
    
    const ws = " \t\n\r";
    
    inline for (.{
        "<empty" ++ ("") ++ "/>",
        "<empty" ++ (ws) ++ "/>",
    }) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
    }
    
    inline for (.{
        "<pree:empty" ++ ("") ++ "/>",
        "<pree:empty" ++ (ws) ++ "/>",
    }) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, "pree", "empty");
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
    }
    
    inline for (.{
        "<empty" ++ ("") ++ ">" ++ "</empty" ++ ("") ++ ">",
        "<empty" ++ ("") ++ ">" ++ "</empty" ++ (ws) ++ ">",
        "<empty" ++ (ws) ++ ">" ++ "</empty" ++ ("") ++ ">",
        "<empty" ++ (ws) ++ ">" ++ "</empty" ++ (ws) ++ ">",
    }) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectElementCloseTag(&ts, null, "empty");
        try tests.expectNull(&ts);
    }
    
    inline for (.{
        "<pree:empty" ++ ("") ++ ">" ++ "</pree:empty" ++ ("") ++ ">",
        "<pree:empty" ++ ("") ++ ">" ++ "</pree:empty" ++ ("") ++ ">",
        "<pree:empty" ++ (ws) ++ ">" ++ "</pree:empty" ++ (ws) ++ ">",
        "<pree:empty" ++ (ws) ++ ">" ++ "</pree:empty" ++ (ws) ++ ">",
    }) |src| {
        ts.reset(src);
        try tests.expectElementOpen(&ts, "pree", "empty");
        try tests.expectElementCloseTag(&ts, "pree", "empty");
        try tests.expectNull(&ts);
    }
}

test "significant whitespace" {
    var ts = TokenStream.init(undefined);
    
    inline for (.{
        " ",
        "\t",
        "\n",
        "\r",
        "\t \t",
        "\n\r\t\n",
    })
    |whitespace| {
        ts.reset("<root>" ++ whitespace ++ "</root>");
        try tests.expectElementOpen(&ts, null, "root");
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectElementCloseTag(&ts, null, "root");
        try tests.expectNull(&ts);
    }
    
    ts.reset("\n<empty/>\t");
    try tests.expectWhitespace(&ts, "\n");
    try tests.expectElementOpen(&ts, null, "empty");
    try tests.expectElementCloseInline(&ts);
    try tests.expectWhitespace(&ts, "\t");
    try tests.expectNull(&ts);
}

test "basic content" {
    var ts = TokenStream.init(undefined);
    
    inline for (.{"", "    "}) |ws| {
        ts.reset("<root" ++ ws ++ "> foo bar baz </root >");
        try tests.expectElementOpen(&ts, null, "root");
        try tests.expectText(&ts, " foo bar baz ");
        try tests.expectElementCloseTag(&ts, null, "root");
        try tests.expectNull(&ts);
    }
}

test "entity references" {
    var ts = TokenStream.init(undefined);
    
    ts.reset("<root>&amp;&lt; FOOBAR &gt;</root >");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectEntityReference(&ts, "amp");
    try tests.expectEntityReference(&ts, "lt");
    try tests.expectText(&ts, " FOOBAR ");
    try tests.expectEntityReference(&ts, "gt");
    try tests.expectElementCloseTag(&ts, null, "root");
    try tests.expectNull(&ts);
    
    
    
    ts.reset("<root> &amp;&lt;\t FOOBAR\t&gt; \t </root >");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectWhitespace(&ts, " ");
    try tests.expectEntityReference(&ts, "amp");
    try tests.expectEntityReference(&ts, "lt");
    try tests.expectText(&ts, "\t FOOBAR\t");
    try tests.expectEntityReference(&ts, "gt");
    try tests.expectWhitespace(&ts, " \t ");
    try tests.expectElementCloseTag(&ts, null, "root");
    try tests.expectNull(&ts);
}

test "UTF8 content" {
    var ts = TokenStream.init(undefined);
    
    const utf8_content =
        // edited to exclude any ampersands and left/right angle brackets
        \\
        \\      ði ıntəˈnæʃənəl fəˈnɛtık əsoʊsiˈeıʃn
        \\      Y [ˈʏpsilɔn], Yen [jɛn], Yoga [ˈjoːgɑ]
        \\
        \\    APL:
        \\
        \\      ((V⍳V)=⍳⍴V)/V←,V    ⌷←⍳→⍴∆∇⊃‾⍎⍕⌈
        \\
        \\    Nicer typography in plain text files:
        \\
        \\      ╔══════════════════════════════════════════╗
        \\      ║                                          ║
        \\      ║   • ‘single’ and “double” quotes         ║
        \\      ║                                          ║
        \\      ║   • Curly apostrophes: “We’ve been here” ║
        \\      ║                                          ║
        \\      ║   • Latin-1 apostrophe and accents: '´`  ║
        \\      ║                                          ║
        \\      ║   • ‚deutsche‘ „Anführungszeichen“       ║
        \\      ║                                          ║
        \\      ║   • †, ‡, ‰, •, 3–4, —, −5/+5, ™, …      ║
        \\      ║                                          ║
        \\      ║   • ASCII safety test: 1lI|, 0OD, 8B     ║
        \\      ║                      ╭─────────╮         ║
        \\      ║   • the euro symbol: │ 14.95 € │         ║
        \\      ║                      ╰─────────╯         ║
        \\      ╚══════════════════════════════════════════╝
        \\
        \\    Greek (in Polytonic):
        \\
        \\      The Greek anthem:
        \\
        \\      Σὲ γνωρίζω ἀπὸ τὴν κόψη
        \\      τοῦ σπαθιοῦ τὴν τρομερή,
        \\      σὲ γνωρίζω ἀπὸ τὴν ὄψη
        \\      ποὺ μὲ βία μετράει τὴ γῆ.
        \\
        \\      ᾿Απ᾿ τὰ κόκκαλα βγαλμένη
        \\      τῶν ῾Ελλήνων τὰ ἱερά
        \\      καὶ σὰν πρῶτα ἀνδρειωμένη
        \\      χαῖρε, ὦ χαῖρε, ᾿Ελευθεριά!
        \\
        \\      From a speech of Demosthenes in the 4th century BC:
        \\
        \\      Οὐχὶ ταὐτὰ παρίσταταί μοι γιγνώσκειν, ὦ ἄνδρες ᾿Αθηναῖοι,
        \\      ὅταν τ᾿ εἰς τὰ πράγματα ἀποβλέψω καὶ ὅταν πρὸς τοὺς
        \\      λόγους οὓς ἀκούω· τοὺς μὲν γὰρ λόγους περὶ τοῦ
        \\      τιμωρήσασθαι Φίλιππον ὁρῶ γιγνομένους, τὰ δὲ πράγματ᾿ 
        \\      εἰς τοῦτο προήκοντα,  ὥσθ᾿ ὅπως μὴ πεισόμεθ᾿ αὐτοὶ
        \\      πρότερον κακῶς σκέψασθαι δέον. οὐδέν οὖν ἄλλο μοι δοκοῦσιν
        \\      οἱ τὰ τοιαῦτα λέγοντες ἢ τὴν ὑπόθεσιν, περὶ ἧς βουλεύεσθαι,
        \\      οὐχὶ τὴν οὖσαν παριστάντες ὑμῖν ἁμαρτάνειν. ἐγὼ δέ, ὅτι μέν
        \\      ποτ᾿ ἐξῆν τῇ πόλει καὶ τὰ αὑτῆς ἔχειν ἀσφαλῶς καὶ Φίλιππον
        \\      τιμωρήσασθαι, καὶ μάλ᾿ ἀκριβῶς οἶδα· ἐπ᾿ ἐμοῦ γάρ, οὐ πάλαι
        \\      γέγονεν ταῦτ᾿ ἀμφότερα· νῦν μέντοι πέπεισμαι τοῦθ᾿ ἱκανὸν
        \\      προλαβεῖν ἡμῖν εἶναι τὴν πρώτην, ὅπως τοὺς συμμάχους
        \\      σώσομεν. ἐὰν γὰρ τοῦτο βεβαίως ὑπάρξῃ, τότε καὶ περὶ τοῦ
        \\      τίνα τιμωρήσεταί τις καὶ ὃν τρόπον ἐξέσται σκοπεῖν· πρὶν δὲ
        \\      τὴν ἀρχὴν ὀρθῶς ὑποθέσθαι, μάταιον ἡγοῦμαι περὶ τῆς
        \\      τελευτῆς ὁντινοῦν ποιεῖσθαι λόγον.
        \\
        \\      Δημοσθένους, Γ´ ᾿Ολυνθιακὸς
        \\
        \\    Georgian:
        \\
        \\      From a Unicode conference invitation:
        \\
        \\      გთხოვთ ახლავე გაიაროთ რეგისტრაცია Unicode-ის მეათე საერთაშორისო
        \\      კონფერენციაზე დასასწრებად, რომელიც გაიმართება 10-12 მარტს,
        \\      ქ. მაინცში, გერმანიაში. კონფერენცია შეჰკრებს ერთად მსოფლიოს
        \\      ექსპერტებს ისეთ დარგებში როგორიცაა ინტერნეტი და Unicode-ი,
        \\      ინტერნაციონალიზაცია და ლოკალიზაცია, Unicode-ის გამოყენება
        \\      ოპერაციულ სისტემებსა, და გამოყენებით პროგრამებში, შრიფტებში,
        \\      ტექსტების დამუშავებასა და მრავალენოვან კომპიუტერულ სისტემებში.
        \\
        \\    Russian:
        \\
        \\      From a Unicode conference invitation:
        \\
        \\      Зарегистрируйтесь сейчас на Десятую Международную Конференцию по
        \\      Unicode, которая состоится 10-12 марта 1997 года в Майнце в Германии.
        \\      Конференция соберет широкий круг экспертов по  вопросам глобального
        \\      Интернета и Unicode, локализации и интернационализации, воплощению и
        \\      применению Unicode в различных операционных системах и программных
        \\      приложениях, шрифтах, верстке и многоязычных компьютерных системах.
        \\
        \\    Thai (UCS Level 2):
        \\
        \\      Excerpt from a poetry on The Romance of The Three Kingdoms (a Chinese
        \\      classic 'San Gua'):
        \\
        \\      [----------------------------|------------------------]
        \\        ๏ แผ่นดินฮั่นเสื่อมโทรมแสนสังเวช  พระปกเกศกองบู๊กู้ขึ้นใหม่
        \\      สิบสองกษัตริย์ก่อนหน้าแลถัดไป       สององค์ไซร้โง่เขลาเบาปัญญา
        \\        ทรงนับถือขันทีเป็นที่พึ่ง           บ้านเมืองจึงวิปริตเป็นนักหนา
        \\      โฮจิ๋นเรียกทัพทั่วหัวเมืองมา         หมายจะฆ่ามดชั่วตัวสำคัญ
        \\        เหมือนขับไสไล่เสือจากเคหา      รับหมาป่าเข้ามาเลยอาสัญ
        \\      ฝ่ายอ้องอุ้นยุแยกให้แตกกัน          ใช้สาวนั้นเป็นชนวนชื่นชวนใจ
        \\        พลันลิฉุยกุยกีกลับก่อเหตุ          ช่างอาเพศจริงหนาฟ้าร้องไห้
        \\      ต้องรบราฆ่าฟันจนบรรลัย           ฤๅหาใครค้ำชูกู้บรรลังก์ ฯ
        \\
        \\      (The above is a two-column text. If combining characters are handled
        \\      correctly, the lines of the second column should be aligned with the
        \\      | character above.)
        \\
        \\    Ethiopian:
        \\
        \\      Proverbs in the Amharic language:
        \\
        \\      ሰማይ አይታረስ ንጉሥ አይከሰስ።
        \\      ብላ ካለኝ እንደአባቴ በቆመጠኝ።
        \\      ጌጥ ያለቤቱ ቁምጥና ነው።
        \\      ደሀ በሕልሙ ቅቤ ባይጠጣ ንጣት በገደለው።
        \\      የአፍ ወለምታ በቅቤ አይታሽም።
        \\      አይጥ በበላ ዳዋ ተመታ።
        \\      ሲተረጉሙ ይደረግሙ።
        \\      ቀስ በቀስ፥ ዕንቁላል በእግሩ ይሄዳል።
        \\      ድር ቢያብር አንበሳ ያስር።
        \\      ሰው እንደቤቱ እንጅ እንደ ጉረቤቱ አይተዳደርም።
        \\      እግዜር የከፈተውን ጉሮሮ ሳይዘጋው አይድርም።
        \\      የጎረቤት ሌባ፥ ቢያዩት ይስቅ ባያዩት ያጠልቅ።
        \\      ሥራ ከመፍታት ልጄን ላፋታት።
        \\      ዓባይ ማደሪያ የለው፥ ግንድ ይዞ ይዞራል።
        \\      የእስላም አገሩ መካ የአሞራ አገሩ ዋርካ።
        \\      ተንጋሎ ቢተፉ ተመልሶ ባፉ።
        \\      ወዳጅህ ማር ቢሆን ጨርስህ አትላሰው።
        \\      እግርህን በፍራሽህ ልክ ዘርጋ።
        \\
        \\    Runes:
        \\
        \\      ᚻᛖ ᚳᚹᚫᚦ ᚦᚫᛏ ᚻᛖ ᛒᚢᛞᛖ ᚩᚾ ᚦᚫᛗ ᛚᚪᚾᛞᛖ ᚾᚩᚱᚦᚹᛖᚪᚱᛞᚢᛗ ᚹᛁᚦ ᚦᚪ ᚹᛖᛥᚫ
        \\
        \\      (Old English, which transcribed into Latin reads 'He cwaeth that he
        \\      bude thaem lande northweardum with tha Westsae.' and means 'He said
        \\      that he lived in the northern land near the Western Sea.')
        \\
        \\    Braille:
        \\
        \\      ⡌⠁⠧⠑ ⠼⠁⠒  ⡍⠜⠇⠑⠹⠰⠎ ⡣⠕⠌
        \\
        \\      ⡍⠜⠇⠑⠹ ⠺⠁⠎ ⠙⠑⠁⠙⠒ ⠞⠕ ⠃⠑⠛⠔ ⠺⠊⠹⠲ ⡹⠻⠑ ⠊⠎ ⠝⠕ ⠙⠳⠃⠞
        \\      ⠱⠁⠞⠑⠧⠻ ⠁⠃⠳⠞ ⠹⠁⠞⠲ ⡹⠑ ⠗⠑⠛⠊⠌⠻ ⠕⠋ ⠙⠊⠎ ⠃⠥⠗⠊⠁⠇ ⠺⠁⠎
        \\      ⠎⠊⠛⠝⠫ ⠃⠹ ⠹⠑ ⠊⠇⠻⠛⠹⠍⠁⠝⠂ ⠹⠑ ⠊⠇⠻⠅⠂ ⠹⠑ ⠥⠝⠙⠻⠞⠁⠅⠻⠂
        \\      ⠁⠝⠙ ⠹⠑ ⠡⠊⠑⠋ ⠍⠳⠗⠝⠻⠲ ⡎⠊⠗⠕⠕⠛⠑ ⠎⠊⠛⠝⠫ ⠊⠞⠲ ⡁⠝⠙
        \\      ⡎⠊⠗⠕⠕⠛⠑⠰⠎ ⠝⠁⠍⠑ ⠺⠁⠎ ⠛⠕⠕⠙ ⠥⠏⠕⠝ ⠰⡡⠁⠝⠛⠑⠂ ⠋⠕⠗ ⠁⠝⠹⠹⠔⠛ ⠙⠑ 
        \\      ⠡⠕⠎⠑ ⠞⠕ ⠏⠥⠞ ⠙⠊⠎ ⠙⠁⠝⠙ ⠞⠕⠲
        \\
        \\      ⡕⠇⠙ ⡍⠜⠇⠑⠹ ⠺⠁⠎ ⠁⠎ ⠙⠑⠁⠙ ⠁⠎ ⠁ ⠙⠕⠕⠗⠤⠝⠁⠊⠇⠲
        \\
        \\      ⡍⠔⠙⠖ ⡊ ⠙⠕⠝⠰⠞ ⠍⠑⠁⠝ ⠞⠕ ⠎⠁⠹ ⠹⠁⠞ ⡊ ⠅⠝⠪⠂ ⠕⠋ ⠍⠹
        \\      ⠪⠝ ⠅⠝⠪⠇⠫⠛⠑⠂ ⠱⠁⠞ ⠹⠻⠑ ⠊⠎ ⠏⠜⠞⠊⠊⠥⠇⠜⠇⠹ ⠙⠑⠁⠙ ⠁⠃⠳⠞
        \\      ⠁ ⠙⠕⠕⠗⠤⠝⠁⠊⠇⠲ ⡊ ⠍⠊⠣⠞ ⠙⠁⠧⠑ ⠃⠑⠲ ⠔⠊⠇⠔⠫⠂ ⠍⠹⠎⠑⠇⠋⠂ ⠞⠕
        \\      ⠗⠑⠛⠜⠙ ⠁ ⠊⠕⠋⠋⠔⠤⠝⠁⠊⠇ ⠁⠎ ⠹⠑ ⠙⠑⠁⠙⠑⠌ ⠏⠊⠑⠊⠑ ⠕⠋ ⠊⠗⠕⠝⠍⠕⠝⠛⠻⠹ 
        \\      ⠔ ⠹⠑ ⠞⠗⠁⠙⠑⠲ ⡃⠥⠞ ⠹⠑ ⠺⠊⠎⠙⠕⠍ ⠕⠋ ⠳⠗ ⠁⠝⠊⠑⠌⠕⠗⠎ 
        \\      ⠊⠎ ⠔ ⠹⠑ ⠎⠊⠍⠊⠇⠑⠆ ⠁⠝⠙ ⠍⠹ ⠥⠝⠙⠁⠇⠇⠪⠫ ⠙⠁⠝⠙⠎
        \\      ⠩⠁⠇⠇ ⠝⠕⠞ ⠙⠊⠌⠥⠗⠃ ⠊⠞⠂ ⠕⠗ ⠹⠑ ⡊⠳⠝⠞⠗⠹⠰⠎ ⠙⠕⠝⠑ ⠋⠕⠗⠲ ⡹⠳
        \\      ⠺⠊⠇⠇ ⠹⠻⠑⠋⠕⠗⠑ ⠏⠻⠍⠊⠞ ⠍⠑ ⠞⠕ ⠗⠑⠏⠑⠁⠞⠂ ⠑⠍⠏⠙⠁⠞⠊⠊⠁⠇⠇⠹⠂ ⠹⠁⠞
        \\      ⡍⠜⠇⠑⠹ ⠺⠁⠎ ⠁⠎ ⠙⠑⠁⠙ ⠁⠎ ⠁ ⠙⠕⠕⠗⠤⠝⠁⠊⠇⠲
        \\
        \\      (The first couple of paragraphs of "A Christmas Carol" by Dickens)
        \\
        \\    Compact font selection example text:
        \\
        \\      ABCDEFGHIJKLMNOPQRSTUVWXYZ /0123456789
        \\      abcdefghijklmnopqrstuvwxyz £©µÀÆÖÞßéöÿ
        \\      –—‘“”„†•…‰™œŠŸž€ ΑΒΓΔΩαβγδω АБВГДабвгд
        \\      ∀∂∈ℝ∧∪≡∞ ↑↗↨↻⇣ ┐┼╔╘░►☺♀ ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა
        \\
        \\    Greetings in various languages:
        \\
        \\      Hello world, Καλημέρα κόσμε, コンニチハ
        \\
        \\    Box drawing alignment tests:                                          █
        \\                                                                          ▉
        \\      ╔══╦══╗  ┌──┬──┐  ╭──┬──╮  ╭──┬──╮  ┏━━┳━━┓  ┎┒┏┑   ╷  ╻ ┏┯┓ ┌┰┐    ▊ ╱╲╱╲╳╳╳
        \\      ║┌─╨─┐║  │╔═╧═╗│  │╒═╪═╕│  │╓─╁─╖│  ┃┌─╂─┐┃  ┗╃╄┙  ╶┼╴╺╋╸┠┼┨ ┝╋┥    ▋ ╲╱╲╱╳╳╳
        \\      ║│╲ ╱│║  │║   ║│  ││ │ ││  │║ ┃ ║│  ┃│ ╿ │┃  ┍╅╆┓   ╵  ╹ ┗┷┛ └┸┘    ▌ ╱╲╱╲╳╳╳
        \\      ╠╡ ╳ ╞╣  ├╢   ╟┤  ├┼─┼─┼┤  ├╫─╂─╫┤  ┣┿╾┼╼┿┫  ┕┛┖┚     ┌┄┄┐ ╎ ┏┅┅┓ ┋ ▍ ╲╱╲╱╳╳╳
        \\      ║│╱ ╲│║  │║   ║│  ││ │ ││  │║ ┃ ║│  ┃│ ╽ │┃  ░░▒▒▓▓██ ┊  ┆ ╎ ╏  ┇ ┋ ▎
        \\      ║└─╥─┘║  │╚═╤═╝│  │╘═╪═╛│  │╙─╀─╜│  ┃└─╂─┘┃  ░░▒▒▓▓██ ┊  ┆ ╎ ╏  ┇ ┋ ▏
        \\      ╚══╩══╝  └──┴──┘  ╰──┴──╯  ╰──┴──╯  ┗━━┻━━┛           └╌╌┘ ╎ ┗╍╍┛ ┋  ▁▂▃▄▅▆▇█
        \\
    ;
    
    ts.reset("<root>" ++ utf8_content ++ "</root>");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectText(&ts, utf8_content);
    try tests.expectElementCloseTag(&ts, null, "root");
    try tests.expectNull(&ts);
}

test "nested tags" {
    var ts = TokenStream.init(undefined);
    
    ts.reset("<foo> <bar/> </foo>");
    try tests.expectElementOpen(&ts, null, "foo");
    try tests.expectWhitespace(&ts, " ");
    try tests.expectElementOpen(&ts, null, "bar");
    try tests.expectElementCloseInline(&ts);
    try tests.expectWhitespace(&ts, " ");
    try tests.expectElementCloseTag(&ts, null, "foo");
    
    ts.reset("<foo><bar> baz </bar></foo>");
    try tests.expectElementOpen(&ts, null, "foo");
    try tests.expectElementOpen(&ts, null, "bar");
    try tests.expectText(&ts, " baz ");
    try tests.expectElementCloseTag(&ts, null, "bar");
    try tests.expectElementCloseTag(&ts, null, "foo");
}

test "comment" {
    var ts = TokenStream.init(undefined);
    
    ts.reset("<!-- Aloha! -->");
    try tests.expectComment(&ts, " Aloha! ");
    try tests.expectNull(&ts);
    
    // note that we omit a closing tag
    ts.reset("<root> <!--wowza!-->\t");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectWhitespace(&ts, " ");
    try tests.expectComment(&ts, "wowza!");
    try tests.expectWhitespace(&ts, "\t");
    // since the 'depth' is not zero (there are not an equal number of element openings and element closings),
    // we error out here.
    try tests.expectError(&ts, Error.ExpectedClosingTag);
    try tests.expectNull(&ts);
    
    // but be careful, because this behaviour is not semantically intelligent;
    // it only requires the number of open tags and close tags to be equal
    ts.reset("<root><!--jeez-louise--></fakeroot>");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectComment(&ts, "jeez-louise");
    try tests.expectElementCloseTag(&ts, null, "fakeroot");
    try tests.expectNull(&ts);
}

test "attributes" {
    var ts = TokenStream.init(undefined);
    
    // the important thing to note here is that all of the variants of the 'seperators' have no impact on the
    // the outputs of the composed sources.
    inline for (.{ "'", "\"" }) |quote|
    inline for (.{ "", "    " }) |ws|
    inline for (.{ "=", "= ", " =", " = " }) |eql|
    {
        // empty quotes
        ts.reset("<foo bar" ++ eql ++ quote ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{ .empty_quotes });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // without namespace
        ts.reset("<foo bar" ++ eql ++ quote ++ "baz" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{ .{ .text = "baz" } });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // with namespace
        ts.reset("<foo foo2:bar" ++ eql ++ quote ++ "baz" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, "foo2", "bar", &.{ .{ .text = "baz" } });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // with closing tag, for good measure
        ts.reset("<foo bar" ++ eql ++ quote ++ "baz" ++ quote ++ ws ++ "></foo>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{ .{ .text = "baz" } });
        try tests.expectElementCloseTag(&ts, null, "foo");
        try tests.expectNull(&ts);
        
        // multiple attributes
        ts.reset("<foo bar" ++ eql ++ quote ++ quote ++ " " ++ "bar2" ++ eql ++ quote ++ "baz2" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{ .empty_quotes });
        try tests.expectAttribute(&ts, null, "bar2", &.{ .{ .text = "baz2" } });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // single entity reference
        ts.reset("<foo bar" ++ eql ++ quote ++ "&amp;" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{ .{ .entity_reference = .{ .name = "amp" } } });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // two entity references
        ts.reset("<foo bar" ++ eql ++ quote ++ "&amp;&lt;" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{
            .{ .entity_reference = .{ .name = "amp" } },
            .{ .entity_reference = .{ .name = "lt" } },
        });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // mixed segments 1
        ts.reset("<foo bar" ++ eql ++ quote ++ "&amp;TEXT&lt;" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{
            .{ .entity_reference = .{ .name = "amp" } },
            .{ .text = "TEXT" },
            .{ .entity_reference = .{ .name = "lt" } },
        });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        // mixed segments 2
        ts.reset("<foo bar" ++ eql ++ quote ++ "TEXT&lt;TEXT" ++ quote ++ ws ++ "/>");
        try tests.expectElementOpen(&ts, null, "foo");
        try tests.expectAttribute(&ts, null, "bar", &.{
            .{ .text = "TEXT" },
            .{ .entity_reference = .{ .name = "lt" } },
            .{ .text = "TEXT" },
        });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
    };
    
}

test "depth testing" {
    var ts = TokenStream.init(undefined);
    
    ts.reset("<root>\t");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectWhitespace(&ts, "\t");
    try tests.expectError(&ts, Error.ExpectedClosingTag);
    try tests.expectNull(&ts);
    
    ts.reset("<root >foobarbaz");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectText(&ts, "foobarbaz");
    try tests.expectError(&ts, Error.ExpectedClosingTag);
    try tests.expectNull(&ts);
    
    ts.reset("<root/>foobarbaz");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectElementCloseInline(&ts);
    try tests.expectError(&ts, Error.ContentNotAllowedInTrailingSection);
    try tests.expectNull(&ts);
    
    ts.reset("<root>foobarbaz<sub/>\t</root> ");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectText(&ts, "foobarbaz");
    try tests.expectElementOpen(&ts, null, "sub");
    try tests.expectElementCloseInline(&ts);
    try tests.expectWhitespace(&ts, "\t");
    try tests.expectElementCloseTag(&ts, null, "root");
    try tests.expectWhitespace(&ts, " ");
    try tests.expectNull(&ts);
    
    ts.reset("<root>foobarbaz<sub/>\t</root> ñ");
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectText(&ts, "foobarbaz");
    try tests.expectElementOpen(&ts, null, "sub");
    try tests.expectElementCloseInline(&ts);
    try tests.expectWhitespace(&ts, "\t");
    try tests.expectElementCloseTag(&ts, null, "root");
    try tests.expectError(&ts, Error.ContentNotAllowedInTrailingSection);
    try tests.expectNull(&ts);
}
