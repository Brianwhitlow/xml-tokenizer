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
    
    //const on_start = self.state;
    //defer std.debug.assert(!meta.eql(on_start.info, self.state.info));
    
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
            .element_open => return self.tokenizeAfterElementOpenOrAttributeAndWhitespace(),
            .element_close_tag => todo("Tokenize after 'element_close_tag'.", .{}),
            .element_close_inline => todo("Tokenize after 'element_close_inline'.", .{}),
            .attribute_name => todo("Tokenize attributes.", .{}),
            
            .attribute_value_segment => todo("Tokenize attributes.", .{}),
            
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

fn tokenizeAfterElementOpenOrAttributeAndWhitespace(self: *TokenStream) NextRet {
    
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



test "empty source" {
    var ts = TokenStream.init("");
    try testing.expectEqual(ts.next(), null);
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
        try Token.tests.expectWhitespace(ts.buffer, try ts.next().?, whitespace);
        try testing.expectEqual(ts.next(), null);
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
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "empty");
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
        
        ts.reset("<pre:empty" ++ whitespace ++ "/>");
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, "pre", "empty");
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
        
        ts.reset(whitespace ++ "<root" ++ whitespace ++ "/>" ++ whitespace);
        try Token.tests.expectWhitespace(ts.buffer, try ts.next().?, whitespace);
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "root");
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try Token.tests.expectWhitespace(ts.buffer, try ts.next().?, whitespace);
        try testing.expectEqual(ts.next(), null);
    };
    
}

test "empty tag with attribute" {
    var ts = TokenStream.init(undefined);
    
    @setEvalBranchQuota(4_000);
    inline for (.{ "=", "=  ", " = ", "  =" }) |eql|
    inline for (.{ "'", "\"" }) |quote|
    inline for (.{ "", " " }) |whitespace|
    {
        ts.reset("<empty " ++ "foo" ++ eql ++ quote ++ quote ++ whitespace ++ "/>");
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "empty");
        try Token.tests.expectAttributeName(ts.buffer, try ts.next().?, null, "foo");
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .empty_quotes);
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
        
        ts.reset("<empty " ++ "foo:bar" ++ eql ++ quote ++ quote ++ whitespace ++ "/>");
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "empty");
        try Token.tests.expectAttributeName(ts.buffer, try ts.next().?, "foo", "bar");
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .empty_quotes);
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
        
        ts.reset("<empty " ++ "foo" ++ eql ++ quote ++ "bar" ++ quote ++ whitespace ++ "/>");
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "empty");
        try Token.tests.expectAttributeName(ts.buffer, try ts.next().?, null, "foo");
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .{ .text = "bar" });
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
        
        ts.reset("<empty " ++ "foo:bar" ++ eql ++ quote ++ "baz" ++ quote ++ whitespace ++ "/>");
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "empty");
        try Token.tests.expectAttributeName(ts.buffer, try ts.next().?, "foo", "bar");
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .{ .text = "baz" });
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
        
        
        ts.reset("<empty " ++ "foo" ++ eql ++ quote ++ "&lt;bar&gt;" ++ quote ++ whitespace ++ "/>");
        try Token.tests.expectElementOpen(ts.buffer, try ts.next().?, null, "empty");
        try Token.tests.expectAttributeName(ts.buffer, try ts.next().?, null, "foo");
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .{ .entity_reference = .{ .name = "lt" } });
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .{ .text = "bar" });
        try Token.tests.expectAttributeValueSegment(ts.buffer, try ts.next().?, .{ .entity_reference = .{ .name = "gt" } });
        try Token.tests.expectElementCloseInline(ts.buffer, try ts.next().?);
        try testing.expectEqual(ts.next(), null);
    };
}
