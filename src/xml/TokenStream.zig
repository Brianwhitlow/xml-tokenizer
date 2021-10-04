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
                const Closure = struct { fn retWhitespace(ts: *TokenStream) NextRet {
                    const len = ts.getIndex() - 0;
                    const result = Token.init(0, .{ .whitespace = Token.Info.Whitespace { .len = len } });
                    ts.state.info.start = result.info;
                    return result;
                } };
                
                self.incrByByte();
                while (self.getUtf8()) |char| : (self.incrByUtf8()) switch (char) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => continue,
                    '<' => return Closure.retWhitespace(self),
                    else => todo("Error for content in prologue.", .{}),
                } else return Closure.retWhitespace(self);
            },
            
            '<' => return self.tokenizeAfterLeftAngleBracket(),
            else => todo("Error for content in prologue.", .{}),
        },
        
        .in_root => |prev_tok| switch (prev_tok) {
            
            .element_open => return self.tokenizeAfterElementOpenOrAttribute(),
            
            .element_close_tag => todo("Tokenize after 'element_close_tag'.", .{}),
            .element_close_inline => todo("Tokenize after 'element_close_inline'.", .{}),
            
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
                    return self.tokenizeAfterElementOpenOrAttribute();
                }
                
                return self.tokenizeAttributeValueSegment();
            },
            
            .comment => todo("Tokenize after 'comment'.", .{}),
            .cdata => todo("Tokenize after 'cdata'.", .{}),
            .text => todo("Tokenize after 'text'.", .{}),
            .entity_reference => todo("Tokenize after 'entity_reference'.", .{}),
            .whitespace => todo("Tokenize after 'whitespace'.", .{}),
            .pi_target => todo("Tokenize after 'pi_target'.", .{}),
            .pi_token => todo("Tokenize after 'pi_token'.", .{}),
        },
        
        .trailing => {
            std.debug.assert(self.getDepth() == 0);
            if (self.state.info.trailing) |prev_tok| switch (prev_tok) {
                .element_open => unreachable,
                .element_close_tag => todo("Tokenize after 'element_close_tag'.", .{}),
                .element_close_inline => {
                    std.debug.assert(self.getUtf8().? == '>');
                    self.incrByByte();
                    
                    const start_index = self.getIndex();
                    if (self.getUtf8() == null) return null;
                    
                    self.incrByUtf8WhileWhitespace();
                    
                    const len = self.getIndex() - start_index;
                    const info = Token.Info.Whitespace { .len = len };
                    const result = Token.init(start_index, .{ .whitespace = info });
                    return self.setTrailing(result);
                },
                .attribute_name => todo("Tokenize after 'attribute_name'.", .{}),
                .attribute_value_segment => todo("Tokenize after 'attribute_value_segment'.", .{}),
                .comment => todo("Tokenize after 'comment'.", .{}),
                .cdata => todo("Tokenize after 'cdata'.", .{}),
                .text => todo("Tokenize after 'text'.", .{}),
                .entity_reference => todo("Tokenize after 'entity_reference'.", .{}),
                .whitespace => {
                    switch (self.getUtf8() orelse return null) {
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
    
    self.state.depth -= 1;
    const result = Token.init(start_index, .element_close_inline);
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
                return self.tokenizeAfterElementOpenOrAttribute();
            }
            
            if ('&' == self.getByte().?){
                return Closure.tokenizeAfterAmpersand(self);
            }
            
            return Closure.tokenizeString(self);
        },
        else => {
            if (self.state.last_quote.?.value() == self.getByte().?) {
                self.incrByByte();
                return self.tokenizeAfterElementOpenOrAttribute();
            }
            
            std.debug.assert(self.buffer[self.getIndex() - 1] == self.state.last_quote.?.value());
            return Closure.tokenizeString(self);
        },
    }
}

fn tokenizeAfterElementOpenOrAttribute(self: *TokenStream) NextRet {
    
    std.debug.assert(!xml.isValidUtf8NameCharOrColon(self.getUtf8().?));
    self.incrByUtf8WhileWhitespace();
    
    switch (self.getUtf8() orelse todo("Error for premature EOF after unclosed element tag.", .{})) {
        '/' => return self.tokenizeAfterElementOpenForwardSlash(),
        '>' => todo("Tokenize after element open tag.", .{}),
        else => {
            const Closure = struct {
                fn retAttrName(ts: *TokenStream, start_idx: usize, prefix_len: usize) NextRet {
                    const len = ts.getIndex() - start_idx;
                    const info = Token.Info.AttributeName { .prefix_len = prefix_len, .full_len = len };
                    const result = Token.init(start_idx, .{ .attribute_name = info });
                    return ts.setInRoot(result);
                }
            };
            
            if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) todo("Error on invalid attribute name start char.", .{});
            const start_index = self.getIndex();
            self.incrByUtf8();
            
            self.incrByUtf8While(xml.isValidUtf8NameChar);
            switch (self.getUtf8() orelse todo("Error on invalid attribute name char or premature EOF.", .{})) {
                ' ',
                '\t',
                '\n',
                '\r',
                '=',
                => return Closure.retAttrName(self, start_index, 0),
                
                ':' => {
                    const prefix_len = self.getIndex() - start_index;
                    self.incrByByte();
                    
                    if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) todo("Error on invalid attribute name start char.", .{});
                    self.incrByUtf8();
                    
                    self.incrByUtf8While(xml.isValidUtf8NameChar);
                    return Closure.retAttrName(self, start_index, prefix_len);
                },
                
                else => todo("Error on invalid attribute name char", .{}),
            }
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
        '/' => todo("Tokenize element close tags.", .{}),
        else => {
            const Closure = struct { fn retName(ts: *TokenStream, start_idx: usize, prefix_len: usize) NextRet {
                std.debug.assert(ts.buffer[start_idx] == '<');
                const len = ts.getIndex() - start_idx;
                const info = Token.Info.ElementOpen { .prefix_len = prefix_len, .full_len = len };
                const result = Token.init(start_idx, .{ .element_open = info });
                ts.state.depth += 1;
                return ts.setInRoot(result);
            } };
            
            if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) {
                todo("Error for invalid start char for element name.", .{});
            }
            
            self.incrByUtf8();
            self.incrByUtf8While(xml.isValidUtf8NameChar);
            switch (self.getUtf8() orelse todo("Error for ending file immediately after element name", .{})) {
                ' ',
                '\t',
                '\n',
                '\r',
                '/',
                '>',
                => return Closure.retName(self, start_index, 0),
                ':' => {
                    const prefix_len = self.getIndex() - (start_index + ("<".len));
                    self.incrByByte();
                    if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) {
                        todo("Error for invalid start char for element name.", .{});
                    }
                    
                    self.incrByUtf8();
                    self.incrByUtf8While(xml.isValidUtf8NameChar);
                    switch (self.getUtf8() orelse todo("Error for ending file immediately after element name", .{})) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        '/',
                        '>',
                        => return Closure.retName(self, start_index, prefix_len),
                        else => todo("Error for invalid name char", .{})
                    }
                },
                else => todo("Error for invalid name char", .{}),
            }
        }
    }
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

test "empty tag with multiple attributes" {
    var ts = TokenStream.init(undefined);
    
    ts.reset("<empty foo:bar=\"baz\" fi:fo = 'fum' />");
    try tests.expectElementOpen(&ts, null, "empty");
    try tests.expectAttribute(&ts, "foo", "bar", &.{ .{ .text = "baz" } });
    try tests.expectAttribute(&ts, "fi", "fo", &.{ .{ .text = "fum" } });
    try tests.expectElementCloseInline(&ts);
    try tests.expectNull(&ts);
}
