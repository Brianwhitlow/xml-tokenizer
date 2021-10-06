const std = @import("std");
const meta = std.meta;
const testing = std.testing;
const unicode = std.unicode;

const xml = @import("../xml.zig");
pub const Token = @import("Token.zig");

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
    
};

pub const NextRet = ?(Error!Token);

pub fn next(self: *TokenStream) NextRet {
    switch (self.state.info) {
        .end => return null,
        
        .start => if (self.state.info.start) |prev_tok| switch (prev_tok) {
            .element_open => unreachable,
            .element_close_tag => unreachable,
            .element_close_inline => unreachable,
            
            .attribute_name => unreachable,
            .attribute_value_segment => unreachable,
            
            .comment => todo("Tokenize after prologue comments", .{}),
            .cdata => unreachable,
            .text => unreachable,
            .entity_reference => unreachable,
            .whitespace => {
                switch (self.getUtf8() orelse return null) {
                    '<' => return self.tokenizeAfterLeftAngleBracket(),
                    else => unreachable,
                }
            },
            
            .pi_target => todo("Tokenize after prologue processing instructions target.", .{}),
            .pi_token => todo("Tokenize after prologue processing instructions token.", .{}),
        } else switch (self.getByte() orelse return null) {
            ' ',
            '\t',
            '\n',
            '\r',
            => {
                self.incrByByte();
                self.incrByUtf8WhileWhitespace();
                const len = self.getIndex() - 0;
                const result = Token.init(0, .{ .whitespace = Token.Info.Whitespace { .len = len } });
                self.state.info.start = result.info;
                return @as(NextRet, result);
            },
            
            '<' => return self.tokenizeAfterLeftAngleBracket(),
            else => todo("Error for content in prologue.", .{}),
        },
        
        .in_root => |prev_tok| switch (prev_tok) {
            
            .element_open => return self.tokenizeAfterElementTagOrAttribute(),
            
            .element_close_tag,
            .element_close_inline,
            => {
                std.debug.assert(self.getByte().? == '>');
                return self.tokenizeAfterElementTagOrAttribute();
            },
            
            .attribute_name => {
                self.incrByUtf8WhileWhitespace();
                switch (self.getUtf8() orelse todo("Error for EOF or invalid UTF8 where equals was expected", .{})) {
                    '=' => {},
                    else => todo("Error for character '{u}' where '=' or whitespace was expected", .{self.getUtf8().?}),
                }
                
                std.debug.assert(self.getByte().? == '=');
                self.incrByByte();
                
                self.incrByUtf8WhileWhitespace();
                switch (self.getUtf8() orelse todo("Error for EOF or invalid UTF8 where string quote was expected.", .{})) {
                    '"',
                    '\'',
                    => {
                        std.debug.assert(self.state.last_quote == null);
                        self.state.last_quote = State.QuoteType.init(self.getByte().?);
                        
                        self.incrByByte();
                        const subsequent_char = self.getUtf8() orelse todo("Error for EOF or invalid UTF8 where string content or string terminator was expected.", .{});
                        if (self.state.last_quote.?.value() == subsequent_char) {
                            return self.setInRoot(Token.init(self.getIndex(), .{ .attribute_value_segment = .empty_quotes }));
                        }
                        
                        return self.tokenizeAttributeValueSegment();
                    },
                    else => todo("Error for character '{u}' where string quote was expected.", .{self.getUtf8().?}),
                }
            },
            
            .attribute_value_segment => {
                std.debug.assert(self.state.last_quote != null);
                if (self.getByte() orelse todo("Error for EOF or invalid UTF8 where character was expected", .{}) == self.state.last_quote.?.value()) {
                    self.state.last_quote = null;
                    self.incrByByte();
                    return self.tokenizeAfterElementTagOrAttribute();
                }
                
                return self.tokenizeAttributeValueSegment();
            },
            
            .comment => todo("Tokenize after 'comment'.", .{}),
            .cdata => todo("Tokenize after 'cdata'.", .{}),
            .entity_reference => todo("Tokenize after 'entity_reference'.", .{}),
            
            .text,
            .whitespace => {
                std.debug.assert(self.getByte().? == '<');
                return self.tokenizeAfterLeftAngleBracket();
            },
            
            .pi_target => todo("Tokenize after 'pi_target'.", .{}),
            .pi_token => todo("Tokenize after 'pi_token'.", .{}),
        },
        
        .trailing => {
            std.debug.assert(self.getDepth() == 0);
            if (self.state.info.trailing) |prev_tok| switch (prev_tok) {
                .element_open => unreachable,
                
                .element_close_tag,
                .element_close_inline,
                => {
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    
                    const start_index = self.getIndex();
                    switch (self.getUtf8() orelse return self.setEnd(null)) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => {
                            self.incrByUtf8WhileWhitespace();
                            const len = self.getIndex() - start_index;
                            const info = Token.Info.Whitespace { .len = len };
                            const result = Token.init(start_index, .{ .whitespace = info });
                            return self.setTrailing(result);
                        },
                        '<' => todo("Tokenize trailing tags.", .{}),
                        else => todo("Error for content in trailing section.", .{}),
                    }
                },
                
                .attribute_name => todo("Tokenize after 'attribute_name'.", .{}),
                .attribute_value_segment => todo("Tokenize after 'attribute_value_segment'.", .{}),
                .comment => todo("Tokenize after 'comment'.", .{}),
                .cdata => todo("Tokenize after 'cdata'.", .{}),
                .text => todo("Tokenize after 'text'.", .{}),
                .entity_reference => todo("Tokenize after 'entity_reference'.", .{}),
                .whitespace => {
                    switch (self.getUtf8() orelse return self.setEnd(null)) {
                        '<' => todo("Tokenize trailing tags after whitespace.", .{}),
                        else => todo("Consider this invariant.", .{})
                    }
                },
                .pi_target => todo("Tokenize after 'pi_target'.", .{}),
                .pi_token => todo("Tokenize after 'pi_token'.", .{}),
            } else todo("Consider this state (null trailing value).", .{});
        }
    }
}



inline fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.panic("TODO: " ++ fmt ++ "\n", args);
}

const State = struct {
    index: usize = 0,
    depth: usize = 0,
    info: Info = .{ .start = null },
    last_quote: ?QuoteType = null,
    
    const Info = union(enum) {
        end,
        start: ?std.meta.Tag(Token.Info),
        in_root: std.meta.Tag(Token.Info),
        trailing: ?std.meta.Tag(Token.Info),
    };
    
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
};

fn tokenizeAfterElementOpenForwardSlash(self: *TokenStream) NextRet {
    const start_index = self.getIndex();
    std.debug.assert(self.getUtf8().? == '/');
    self.incrByByte();
    if (self.getUtf8() orelse todo("Error if / is followed by EOF where '>' was expected", .{}) != '>') {
        todo("Error if / is followed by EOF where '>' was expected", .{});
    }
    
    const result = Token.init(start_index, .element_close_inline);
    self.state.depth -= 1;
    if (self.getDepth() == 0) return self.setTrailing(result);
    return self.setInRoot(result);
}

fn tokenizeAttributeValueSegment(self: *TokenStream) NextRet {
    std.debug.assert(self.state.last_quote != null);
    std.debug.assert(self.state.info.in_root == .attribute_name or self.state.info.in_root == .attribute_value_segment);
    
    const Closure = struct {
        fn tokenizeAfterAmpersand(ts: *TokenStream) NextRet {
            std.debug.assert(ts.getByte().? == '&');
            
            const start_index = ts.getIndex();
            ts.incrByByte();
            
            if (!xml.isValidUtf8NameStartChar(ts.getUtf8() orelse todo("Error for EOF or invalid UTF8 where entity reference name start char was expected.", .{}))) {
                return todo("Error for invalid entity reference name start char.", .{});
            }
            
            ts.incrByUtf8();
            ts.incrByUtf8While(xml.isValidUtf8NameCharOrColon);
            
            if (ts.getUtf8() orelse todo ("Error for EOF or invalid UTF8 where entity reference semicolon ';' terminator was expected.", .{}) != ';') {
                return todo("Error for character '{u}' where semicolon ';' terminator was expected.", .{ts.getUtf8().?});
            }
            
            const len = (ts.getIndex() + 1) - start_index;
            const info = Token.Info.AttributeValueSegment { .entity_reference = .{ .len = len } };
            const result = Token.init(start_index, .{ .attribute_value_segment = info });
            return ts.setInRoot(result);
        }
        
        fn tokenizeString(ts: *TokenStream) NextRet {
            std.debug.assert(ts.getUtf8().? != '&' and ts.getUtf8().? != ts.state.last_quote.?.value());
            
            const start_index = ts.getIndex();
            switch (ts.state.last_quote.?) {
                .double => ts.incrByUtf8While(struct { fn func(char: u21) bool { return char != '<' and char != '&' and char != '"'; }}.func),
                .single => ts.incrByUtf8While(struct { fn func(char: u21) bool { return char != '<' and char != '&' and char != '\''; }}.func),
            }
            
            if (ts.getByte() orelse todo("Error for EOF before string termination", .{}) == '<') {
                return todo("Error for encountering '<' in attribute string.", .{});
            }
            
            const len = ts.getIndex() - start_index;
            const info = Token.Info.AttributeValueSegment { .text = .{ .len = len } };
            const result = Token.init(start_index, .{ .attribute_value_segment = info });
            return ts.setInRoot(result);
        }
    };
    
    switch (self.getUtf8().?) {
        '&' => return Closure.tokenizeAfterAmpersand(self),
        ';' => {
            self.incrByByte();
            if (self.state.last_quote.?.value() == self.getByte() orelse todo("Error for EOF or invalid UTF8 where attribute string content or attribute string terminator was expected.", .{})) {
                self.incrByByte();
                return self.tokenizeAfterElementTagOrAttribute();
            }
            
            if ('&' == self.getByte().?){
                return Closure.tokenizeAfterAmpersand(self);
            }
            
            return Closure.tokenizeString(self);
        },
        else => {
            if (self.state.last_quote.?.value() == self.getByte().?) {
                self.incrByByte();
                return self.tokenizeAfterElementTagOrAttribute();
            }
            
            std.debug.assert(self.buffer[self.getIndex() - 1] == self.state.last_quote.?.value());
            return Closure.tokenizeString(self);
        },
    }
}

fn tokenizeAfterElementTagOrAttribute(self: *TokenStream) NextRet {
    std.debug.assert(self.getDepth() != 0 and self.state.info != .trailing);
    std.debug.assert(!xml.isValidUtf8NameCharOrColon(self.getUtf8().?));
    self.incrByUtf8WhileWhitespace();
    
    switch (self.getUtf8() orelse todo("Error for premature EOF after unclosed element tag.", .{})) {
        '/' => return self.tokenizeAfterElementOpenForwardSlash(),
        '>' => {
            self.incrByByte();
            switch (self.getUtf8() orelse todo("Error for EOF or invalid UTF8 where content or closing tags were expected.", .{})) {
                '<' => return self.tokenizeAfterLeftAngleBracket(),
                else => {
                    const start_index = self.getIndex();
                    var non_whitespace_chars: bool = false;
                    while (self.getUtf8()) |char| : (self.incrByUtf8()) switch (char) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => continue,
                        '<' => break,
                        else => non_whitespace_chars = true,
                    } else if (non_whitespace_chars or self.getDepth() != 0) {
                        return todo("Error for EOF where '<' was expected.", .{});
                    }
                    
                    const len = self.getIndex() - start_index;
                    if (non_whitespace_chars) {
                        std.debug.assert(self.getUtf8().? == '<');
                        const info = Token.Info.Text { .len = len };
                        const result = Token.init(start_index, .{ .text = info });
                        return self.setInRoot(result);
                    } else {
                        const info = Token.Info.Whitespace { .len = len };
                        const result = Token.init(start_index, .{ .whitespace = info });
                        return self.setInRoot(result);
                    }
                },
            }
        },
        else => {
            const start_index = self.getIndex();
            const tokenized_identifier = self.tokenizePrefixedIdentifier() catch |err| switch (err) {
                error.NoName => todo("Error for no name where one was expected.", .{}),
                error.InvalidNameStartChar => todo("Error for invalid name start char.", .{}),
                error.PrematureEof => todo("Error for premature EOF.", .{}),
            };
            
            const prefix_len = tokenized_identifier.prefix_len;
            const full_len = self.getIndex() - start_index;
            
            std.debug.assert(full_len == (prefix_len + @as(usize, if (prefix_len == 0) 0 else 1) + tokenized_identifier.identifier_len));
            
            const info = Token.Info.AttributeName { .prefix_len = prefix_len, .full_len = full_len };
            const result = Token.init(start_index, .{ .attribute_name = info });
            return self.setInRoot(result);
        },
    }
}

fn tokenizeAfterLeftAngleBracket(self: *TokenStream) NextRet {
    const start_index = self.getIndex();
    std.debug.assert(self.getUtf8().? == '<');
    self.incrByByte();
    
    switch (self.getUtf8() orelse todo("Error for ending file immediately after '<'.", .{})) {
        '?' => todo("Tokenize preprocessing instructions.", .{}),
        '!' => todo("Tokenize after '!'.", .{}),
        '/' => {
            self.incrByByte();
            
            const prefixed_identifier = self.tokenizePrefixedIdentifier() catch |err| switch (err) {
                error.NoName => todo("Error for no name where one was expected.", .{}),
                error.InvalidNameStartChar => todo("Error for invalid name start char.", .{}),
                error.PrematureEof => todo("Error for premature EOF.", .{}),
            };
            
            const info = Token.Info.ElementCloseTag {
                .prefix_len = prefixed_identifier.prefix_len,
                .identifier_len = prefixed_identifier.identifier_len,
                .full_len = blk: {
                    self.incrByUtf8WhileWhitespace();
                    break :blk switch (self.getUtf8() orelse todo("Error for EOF or invalid UTF8 where element close tag terminator was expected.", .{})) {
                        '>' => (self.getIndex() + 1) - start_index,
                        else => todo("Error for character '{u}' where element close tag terminator was expected.", .{self.getUtf8().?}),
                    };
                }
            };
            
            const result = Token.init(start_index, .{ .element_close_tag = info });
            return self.subDepth(result);
        },
        
        else => {
            const prefixed_identifier = self.tokenizePrefixedIdentifier() catch |err| switch (err) {
                error.NoName => todo("Error for no name where one was expected.", .{}),
                error.InvalidNameStartChar => todo("Error for invalid name start char.", .{}),
                error.PrematureEof => todo("Error for premature EOF.", .{}),
            };
            
            const info = Token.Info.ElementOpen {
                .prefix_len = prefixed_identifier.prefix_len,
                .full_len = self.getIndex() - start_index,
            };
            
            const result = Token.init(start_index, .{ .element_open = info });
            self.state.depth += 1;
            return self.setInRoot(result);
        }
    }
}


const IdentifierLength = struct { identifier_len: usize };
fn tokenizeIdentifier(self: *TokenStream) error { NoName, InvalidNameStartChar }!IdentifierLength {
    const start_index = self.getIndex();
    const name_start_char = self.getUtf8() orelse return error.NoName;
    if (!xml.isValidUtf8NameStartChar(name_start_char)) {
        return error.InvalidNameStartChar;
    }
    
    self.incrByUtf8();
    self.incrByUtf8While(xml.isValidUtf8NameChar);
    
    return IdentifierLength { .identifier_len = self.getIndex() - start_index };
}

const PrefixedIdentifierLength = struct { prefix_len: usize, identifier_len: usize };
fn tokenizePrefixedIdentifier(self: *TokenStream) error { NoName, InvalidNameStartChar, PrematureEof }!PrefixedIdentifierLength {
    const tokenized_first = try self.tokenizeIdentifier();
    switch (self.getUtf8() orelse return error.PrematureEof) {
        ':' => {
            self.incrByByte();
            const tokenized_second = try self.tokenizeIdentifier();
            return PrefixedIdentifierLength {
                .prefix_len = tokenized_first.identifier_len,
                .identifier_len = tokenized_second.identifier_len,
            };
        },
        else => return PrefixedIdentifierLength {
            .prefix_len = 0,
            .identifier_len = tokenized_first.identifier_len,
        },
    }
}




fn subDepth(self: *TokenStream, ret: Token) NextRet {
    std.debug.assert(self.state.depth != 0);
    std.debug.assert(self.state.info == .in_root);
    std.debug.assert(switch (ret.info) {
        .element_close_inline,
        .element_close_tag,
        => true,
        else => false,
    });
    self.state.depth -= 1;
    if (self.getDepth() == 0) return self.setTrailing(ret);
    return self.setInRoot(ret);
}



fn incrByUtf8WhileWhitespace(self: *TokenStream) void {
    self.incrByUtf8While(struct{ fn isSpace(char: u21) bool { return switch (char) {
        ' ',
        '\t',
        '\n',
        '\r',
        => true,
        else => false,
    }; } }.isSpace);
}

fn incrByUtf8While(self: *TokenStream, comptime matchFn: fn(u21)bool) void {
    while (self.getUtf8()) |char| : (self.incrByUtf8())
        if (!matchFn(char)) break;
}

fn incrByUtf8(self: *TokenStream) void {
    const codepoint = self.getUtf8() orelse return;
    self.state.index += unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
}

fn incrByByte(self: *TokenStream) void {
    requirements: {
        const codepoint = self.getUtf8() orelse std.debug.panic("Invalid UTF8 codepoint or EOF encountered when trying to increment by a single byte.", .{});
        const codepoint_len = unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
        std.debug.assert(codepoint_len == 1);
        break :requirements;
    }
    self.state.index += 1;
}



fn setEnd(self: *TokenStream, ret: NextRet) NextRet {
    self.state.info = .end;
    return ret;
}

fn setInRoot(self: *TokenStream, tok: Token) NextRet {
    self.state.info = .{ .in_root = tok.info };
    return tok;
}

fn setTrailing(self: *TokenStream, maybe_tok: ?Token) NextRet {
    self.state.info = .{ .trailing = if (maybe_tok) |tok| tok.info else null };
    return @as(NextRet, maybe_tok orelse null);
}



fn getDepth(self: TokenStream) usize { return self.state.depth; }

fn getIndex(self: TokenStream) usize { return self.state.index; }

fn getByte(self: TokenStream) ?u8 {
    const index = self.getIndex();
    const buffer = self.buffer;
    const in_range = (index < buffer.len);
    return if (in_range) buffer[index] else null;
}

fn getUtf8(self: TokenStream) ?u21 {
    const start_byte = self.getByte() orelse return null;
    const sequence_len = unicode.utf8ByteSequenceLength(start_byte) catch return null;
    
    const beg = self.state.index;
    const end = beg + sequence_len;
    if (end > self.buffer.len) return null;
    
    return unicode.utf8Decode(self.buffer[beg..end]) catch null;
}



const tests = struct {
    fn expectElementOpen(ts: *TokenStream, prefix: ?[]const u8, name: []const u8) !void {
        try Token.tests.expectElementOpen(ts.buffer, try (ts.next() orelse error.NullToken), prefix, name);
    }
    
    fn expectElementCloseTag(ts: *TokenStream, prefix: ?[]const u8, name: []const u8) !void {
        try Token.tests.expectElementCloseTag(ts.buffer, try (ts.next() orelse error.NullToken), prefix, name);
    }
    
    fn expectElementCloseInline(ts: *TokenStream) !void {
        try Token.tests.expectElementCloseInline(ts.buffer, try (ts.next() orelse error.NullToken));
    }
    
    fn expectText(ts: *TokenStream, content: []const u8) !void {
        try Token.tests.expectText(ts.buffer, try (ts.next() orelse error.NullToken), content);
    }
    
    fn expectWhitespace(ts: *TokenStream, content: []const u8) !void {
        try Token.tests.expectWhitespace(ts.buffer, try (ts.next() orelse error.NullToken), content);
    }
    
    fn expectEntityReference(ts: *TokenStream, name: []const u8) !void {
        try Token.tests.expectEntityReference(ts.buffer, try (ts.next() orelse error.NullToken), name);
    }
    
    fn expectComment(ts: *TokenStream, content: []const u8) !void {
        try Token.tests.expectComment(ts.buffer, try (ts.next() orelse error.NullToken), content);
    }
    
    fn expectAttributeName(ts: *TokenStream, prefix: ?[]const u8, name: []const u8) !void {
        try Token.tests.expectAttributeName(ts.buffer, try (ts.next() orelse error.NullToken), prefix, name);
    }
    
    fn expectAttributeValueSegment(ts: *TokenStream, segment: Token.tests.AttributeValueSegment) !void {
        try Token.tests.expectAttributeValueSegment(ts.buffer, try (ts.next() orelse error.NullToken), segment);
    }
    
    fn expectAttribute(ts: *TokenStream, prefix: ?[]const u8, name: []const u8, segments: []const Token.tests.AttributeValueSegment) !void {
        try expectAttributeName(ts, prefix, name);
        for (segments) |segment| {
            try expectAttributeValueSegment(ts, segment);
        }
    }
    
    
    
    fn expectNull(ts: *TokenStream) !void {
        try testing.expectEqual(@as(NextRet, null), ts.next());
    }
    
    fn expectError(ts: *TokenStream, err: Error) !void {
        try testing.expectError(err, ts.next() orelse return error.NullToken);
    }
};

test "empty source" {
    var ts = TokenStream.init("");
    try tests.expectNull(&ts);
}

test "whitespace source" {
    var ts = TokenStream.init(undefined);
    
    @setEvalBranchQuota(4_000);
    const spaces = .{ " ", "\t", "\n", "\r" };
    const spaces0 = .{""} ++ spaces;
    inline for (spaces0) |s0|
    inline for (spaces) |s1|
    inline for (spaces) |s2|
    inline for (spaces) |s3|
    inline for (.{1, 2, 3}) |mul|
    {
        const whitespace = (s0 ++ s1 ++ s2 ++ s3) ** mul;
        ts.reset(whitespace);
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectNull(&ts);
    };
}

test "empty tag close inline" {
    var ts = TokenStream.init(undefined);
    
    @setEvalBranchQuota(4_000);
    const spaces = .{ " ", "\t", "\n", "\r" };
    const spaces0 = .{""} ++ spaces;
    inline for (spaces0) |s0|
    inline for (spaces) |s1|
    inline for (spaces) |s2|
    inline for (spaces) |s3|
    inline for (.{1, 2, 3}) |mul|
    {
        const whitespace = (s0 ++ s1 ++ s2 ++ s3) ** mul;
        ts.reset("<empty" ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        ts.reset("<pre:empty" ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, "pre", "empty");
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        ts.reset(whitespace ++ "<root" ++ whitespace ++ "/>" ++ whitespace);
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectElementOpen(&ts, null, "root");
        try tests.expectElementCloseInline(&ts);
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectNull(&ts);
    };
}

test "empty tag close non-inline" {
    var ts = TokenStream.init(undefined);
    
    @setEvalBranchQuota(4_000);
    const spaces = .{ " ", "\t", "\n", "\r" };
    const spaces0 = .{""} ++ spaces;
    inline for (spaces0) |s0|
    inline for (spaces) |s1|
    inline for (spaces) |s2|
    inline for (spaces) |s3|
    inline for (.{1, 2, 3}) |mul|
    {
        const whitespace = (s0 ++ s1 ++ s2 ++ s3) ** mul;
        ts.reset("<empty></empty>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectElementCloseTag(&ts, null, "empty");
        try tests.expectNull(&ts);
        
        ts.reset("<pre:empty></pre:empty>");
        try tests.expectElementOpen(&ts, "pre", "empty");
        try tests.expectElementCloseTag(&ts, "pre", "empty");
        try tests.expectNull(&ts);
        
        ts.reset(whitespace ++ "<root></root>" ++ whitespace);
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectElementOpen(&ts, null, "root");
        try tests.expectElementCloseTag(&ts, null, "root");
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectNull(&ts);
    };
}

test "empty but nested tags" {
    var ts = TokenStream.init("<tag0><tag1><tag2><empty/></tag2></tag1></tag0>");
    try tests.expectElementOpen(&ts, null, "tag0");
    try tests.expectElementOpen(&ts, null, "tag1");
    try tests.expectElementOpen(&ts, null, "tag2");
    
    try tests.expectElementOpen(&ts, null, "empty");
    try tests.expectElementCloseInline(&ts);
    
    try tests.expectElementCloseTag(&ts, null, "tag2");
    try tests.expectElementCloseTag(&ts, null, "tag1");
    try tests.expectElementCloseTag(&ts, null, "tag0");
    try tests.expectNull(&ts);
}

test "empty tag with multiple attributes" {
    var ts = TokenStream.init("<empty foo:bar=\"baz\" fi:fo = 'fum' />");
    try tests.expectElementOpen(&ts, null, "empty");
    try tests.expectAttribute(&ts, "foo", "bar", &.{ .{ .text = "baz" } });
    try tests.expectAttribute(&ts, "fi", "fo", &.{ .{ .text = "fum" } });
    try tests.expectElementCloseInline(&ts);
    try tests.expectNull(&ts);
}

test "empty tag with attributes stress testing" {
    var ts = TokenStream.init(undefined);
    
    @setEvalBranchQuota(4_000);
    inline for (.{ "=", "=  ", " = ", "  =" }) |eql|
    inline for (.{ "'", "\"" }) |quote|
    inline for (.{ "", " " }) |whitespace|
    inline for (.{ @as(?[]const u8, "pre"), null }) |maybe_prefix|
    {
        const other_quote = if (quote[0] == '"') "'" else "\"";
        const prefix = if (maybe_prefix) |prfx| prfx ++ ":" else "";
        
        ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ quote ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{ .empty_quotes });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ "bar" ++ quote ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{ .{ .text = "bar" } });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        inline for (.{ 1, 2, 3, 4 }) |mul| {
            const entity_ref_name = "quot";
            const entity_ref = "&quot;";
            ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ (entity_ref ** mul) ++ quote ++ whitespace ++ "/>");
            try tests.expectElementOpen(&ts, null, "empty");
            try tests.expectAttribute(&ts, maybe_prefix, "foo", &(.{ .{ .entity_reference = entity_ref_name } } ** mul));
            try tests.expectElementCloseInline(&ts);
            try tests.expectNull(&ts);
        }
        
        inline for (.{ 1, 2, 3, 4 }) |mul| {
            const attr_text = (other_quote ** mul);
            ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++  attr_text ++ quote ++ whitespace ++ "/>");
            try tests.expectElementOpen(&ts, null, "empty");
            try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{ .{ .text = attr_text } });
            try tests.expectElementCloseInline(&ts);
            try tests.expectNull(&ts);
        }
        
        ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ other_quote ++ "barbaz" ++ other_quote ++ quote ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{ .{ .text = other_quote ++ "barbaz" ++ other_quote } });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ other_quote ++ "&apos;" ++ other_quote ++ quote ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{
            .{ .text = other_quote },
            .{ .entity_reference = "apos" },
            .{ .text = other_quote },
        });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ "&quot;bar&quot;" ++ quote ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{
            .{ .entity_reference = "quot" },
            .{ .text = "bar" },
            .{ .entity_reference = "quot" },
        });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
        
        ts.reset("<empty " ++ prefix ++ "foo" ++ eql ++ quote ++ "bar&amp;baz" ++ quote ++ whitespace ++ "/>");
        try tests.expectElementOpen(&ts, null, "empty");
        try tests.expectAttribute(&ts, maybe_prefix, "foo", &.{
            .{ .text = "bar" },
            .{ .entity_reference = "amp" },
            .{ .text = "baz" },
        });
        try tests.expectElementCloseInline(&ts);
        try tests.expectNull(&ts);
    };
}

test "whitespace content" {
    var ts = TokenStream.init(undefined);
    
    @setEvalBranchQuota(4_000);
    const spaces = .{ " ", "\t", "\n", "\r" };
    const spaces0 = .{""} ++ spaces;
    inline for (spaces0) |s0|
    inline for (spaces) |s1|
    inline for (spaces) |s2|
    inline for (spaces) |s3|
    inline for (.{1, 2, 3}) |mul|
    {
        const whitespace = (s0 ++ s1 ++ s2 ++ s3) ** mul;
        ts.reset("<root>" ++ whitespace ++ "</root>");
        try tests.expectElementOpen(&ts, null, "root");
        try tests.expectWhitespace(&ts, whitespace);
        try tests.expectElementCloseTag(&ts, null, "root");
        try tests.expectNull(&ts);
    };
}

test "utf8 content" {
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
}

test "mixed content & tags" {
    var ts = TokenStream.init(
        \\<root>
        \\    <child>
        \\    header
        \\    <node>inner<content/> </node>
        \\    footer
        \\    </child>
        \\</root>
    );
    try tests.expectElementOpen(&ts, null, "root");
    try tests.expectWhitespace(&ts, "\n    ");
    try tests.expectElementOpen(&ts, null, "child");
    try tests.expectText(&ts, "\n    header\n    ");
    try tests.expectElementOpen(&ts, null, "node");
    try tests.expectText(&ts, "inner");
    try tests.expectElementOpen(&ts, null, "content");
    try tests.expectElementCloseInline(&ts);
    try tests.expectWhitespace(&ts, " ");
    try tests.expectElementCloseTag(&ts, null, "node");
    try tests.expectText(&ts, "\n    footer\n    ");
    try tests.expectElementCloseTag(&ts, null, "child");
    std.debug.assert(ts.getDepth() == 1);
    try tests.expectWhitespace(&ts, "\n");
    try tests.expectElementCloseTag(&ts, null, "root");
    try tests.expectNull(&ts);
}
