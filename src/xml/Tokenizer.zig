const std = @import("std");
const meta = std.meta;
const unicode = std.unicode;
const xml = @import("../xml.zig");

const Tokenizer = @This();
buffer: []const u8,
state: State,

pub fn init(source: []const u8) Tokenizer {
    return Tokenizer {
        .buffer = source,
        .state = .{},
    };
}

pub fn reset(self: *Tokenizer, new_source: ?[]const u8) void {
    self.* = Tokenizer.init(new_source orelse self.buffer);
}

pub const Token = struct {
    index: usize = 0,
    info: Info = .bof,
    
    pub fn init(index: usize, info: Info) Token {
        return Token {
            .index = index,
            .info = info,
        };
    }
    
    pub fn initTag(index: usize, comptime tag: meta.Tag(Info), info_value: meta.TagPayload(Info, tag)) Token {
        return Token.init(index, @unionInit(Info, @tagName(tag), info_value));
    }
    
    pub fn slice(self: Token, src: []const u8) []const u8 {
        return self.info.slice(self.index, src);
    }
    
    pub const Info = union(enum) {
        invalid,
        bof,
        eof,
        
        text: Length,
        entity_ref: Length,
        whitespace: Length,
        
        @"<{name}": Length,
        @"</{name}": Length,
        @"<?{name}": Length,
        
        name: Length,
        @"=",
        quoted_entity_ref: Length,
        quoted_text: Length,
        
        @">",
        @"/>",
        @"?>",
        
        @"<!--",
        @"-->",
        
        @"<![CDATA[",
        @"]]>", // may also appear within the context of a dtd
        
        // exclusive to the context of a dtd:
        
        @"%",
        @"*",
        @",",
        @"(",
        @")",
        
        @"<!DOCTYPE",
        @"<!ENTITY",
        @"<!ELEMENT",
        @"<!ATTLIST",
        @"<!NOTATION",
        @"]>",
        
        pub const Length = struct { len: usize };
        pub const Tag = meta.TagType(Info);
        
        pub fn slice(self: Info, index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + switch (self) {
                .bof,
                .eof,
                => 0,
                
                .invalid,
                => 1,
                
                .name,
                .text,
                .whitespace,
                .entity_ref,
                .quoted_text,
                .quoted_entity_ref,
                .@"<{name}",
                .@"</{name}",
                .@"<?{name}",
                => |variable| variable.len,
                
                else => @tagName(self).len,
            };
            
            std.debug.print("\n{}\n", .{self});
            
            return src[beg..end];
        }
    };
};

pub fn next(self: *Tokenizer) ?Token {
    switch (self.state.prev) {
        .invalid => return null,
        .eof => return null,
        .bof => switch (self.getUtf8() orelse return self.returnInvalid(null)) {
            ' ',
            '\t',
            '\n',
            '\r',
            => {
                const start_index = self.getIndex().?;
                self.incrByUtf8();
                const len = 1 + self.incrementUtf8UntilNonWhitespace();
                return self.returnToken(Token.initTag(start_index, .whitespace, .{ .len = len }));
            },
            
            '<' => return self.afterTagOpen(),
            else => return self.returnInvalid(null)
        },
        
        .name => {
            std.debug.assert(self.getUtf8().? == '=');
            const start_index = self.getIndex().?;
            _ = self.incrementUtf8UntilNonWhitespace();
            return self.returnToken(Token.init(start_index, .@"="));
        },
        
        .text => todo(),
        .entity_ref => todo(),
        
        .whitespace => switch (self.getUtf8() orelse return self.returnEof()) {
            '<' => return self.afterTagOpen(),
            else => return self.returnInvalid(null),
        },
        
        .@"<{name}" => return self.getNextAttributeNameOrTagEnd(),
        
        .@"</{name}" => todo(),
        .@"<?{name}" => todo(),
        
        
        
        .@"=" => {
            self.incrByUtf8();
            _ = self.incrementUtf8UntilNonWhitespace();
            
            switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                '"' => {
                    self.state.last_quote = .double;
                    self.incrByUtf8();
                    return self.getQuotedTextOrEntityRef(.double);
                },
                '\'' => {
                    self.state.last_quote = .single;
                    self.incrByUtf8();
                    return self.getQuotedTextOrEntityRef(.single);
                },
                else => return self.returnInvalid(null),
            }
        },
        
        .quoted_entity_ref => {
            std.debug.assert(self.getUtf8().? == ';');
            self.incrByUtf8();
            switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                '"',
                '\'',
                '&',
                => return self.getQuotedTextContinuation(),
                
                else => switch (self.state.last_quote.?) {
                    .double => return self.getQuotedTextOrEntityRef(.double),
                    .single => return self.getQuotedTextOrEntityRef(.single),
                },
            }
        },
        
        .quoted_text => return self.getQuotedTextContinuation(),
        
        .@"<!--" => todo(),
        .@"<![CDATA[" => todo(),
        
        .@"]]>",
        .@"-->",
        .@"?>",
        .@">",
        .@"/>",
        => {
            std.debug.assert(self.getUtf8().? == '>');
            self.incrByUtf8();
            const start_index = self.getIndex() orelse return self.returnEof();
            _ = start_index;
            
            todo();
        },
        
        .@"%" => todo(),
        
        .@"(" => todo(),
        .@")" => todo(),
        .@"," => todo(),
        .@"*" => todo(),
        
        .@"<!DOCTYPE" => todo(),
        .@"<!ENTITY" => todo(),
        .@"<!ELEMENT" => todo(),
        .@"<!ATTLIST" => todo(),
        .@"<!NOTATION" => todo(),
        .@"]>" => todo(),

    }
    
    unreachable;
}

inline fn todo() noreturn {
    unreachable;
}

fn getQuotedTextOrEntityRef(self: *Tokenizer, comptime quote_type: State.QuoteType) Token {
    const quote = @enumToInt(quote_type);
    const start_index = self.getIndex() orelse return self.returnInvalid(null);
    
    const len = self.incrByUtf8UntilFalse(struct {
        fn func(c: u21) bool { return c != quote and c != '&'; }
    }.func);
    
    const maybe_result = Token.initTag(start_index, .quoted_text, .{ .len = len });
    
    return switch (self.getUtf8() orelse return self.returnInvalid(null)) {
        quote => self.returnToken(maybe_result),
        '&' => return if (len == 0) self.getQuotedEntityReference() else self.returnToken(maybe_result),
        else => unreachable,
    };
}



fn getQuotedTextContinuation(self: *Tokenizer) Token {
    switch (self.getUtf8() orelse return self.returnInvalid(null)) {
        '&' => return self.getQuotedEntityReference(),
        '"', '\'' => {
            if (self.state.last_quote) |last_quote| {
                if (@enumToInt(last_quote) != self.getUtf8().?)
                    return self.returnInvalid(null);
                self.state.last_quote = null;
            } else unreachable;
            
            self.incrByUtf8();
            return self.getNextAttributeNameOrTagEnd();
        },
        else => unreachable,
    }
}

fn getQuotedEntityReference(self: *Tokenizer) Token {
    std.debug.assert(self.getUtf8().? == '&');
    
    const start_index = self.getIndex().?;
    self.incrByUtf8();
    const len = self.incrByUtf8UntilFalse(struct {
        fn func(c: u21) bool {
            return c != ';';
        }
    }.func);
    
    switch (self.getUtf8() orelse return self.returnInvalid(null)) {
        ';' => return self.returnToken(Token.initTag(start_index, .quoted_entity_ref, .{ .len = len + 2 })),
        else => unreachable,
    }
}

fn getNextAttributeNameOrTagEnd(self: *Tokenizer) Token {
    switch (self.getUtf8() orelse return self.returnInvalid(null)) {
        ' ',
        '\t',
        '\n',
        '\r',
        => {
            _ = self.incrementUtf8UntilNonWhitespace();
            if (self.getUtf8()) |codepoint| {
                
                const invalid_start_char = !xml.isValidUtf8NameStartChar(codepoint);
                if (invalid_start_char) switch (codepoint) {
                    '/' => return self.getInlineClose(),
                    '>' => return self.getTagEnd(),
                    else => return self.returnInvalid(null)
                };
                
            } else return self.returnInvalid(null);
            
            const start_index = self.getIndex().?;
            const len = self.incrByUtf8UntilFalse(xml.isValidUtf8NameCharOrColon);
            
            const output = Token.initTag(start_index, .name, .{ .len = len });
            return self.returnToken(output);
        },
        
        '/' => return self.getInlineClose(),
        '>' => return self.getTagEnd(),
        else => unreachable,
    }
    
    unreachable;
}



fn getTagEnd(self: *Tokenizer) Token {
    return self.returnToken(Token.init(self.getIndex().?, .@">"));
}

fn getInlineClose(self: *Tokenizer) Token {
    std.debug.assert(self.getUtf8().? == '/');
    const start_index = self.getIndex().?;
    
    self.incrByUtf8();
    const codepoint = self.getUtf8() orelse return self.returnInvalid(null);
    
    return if (codepoint == '>') self.returnToken(Token.init(start_index, .@"/>")) else self.returnInvalid(null);
}

fn afterTagOpen(self: *Tokenizer) Token {
    std.debug.assert(self.getUtf8() orelse 0 == '<');
    const start_index = self.getIndex().?;
    
    self.incrByUtf8();
    switch (self.getUtf8() orelse return self.returnInvalid(self.state.index - 1)) {
        '?' => unreachable,
        '!' => unreachable,
        '/' => unreachable,
        else => {
            if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) return self.returnInvalid(null);
            
            self.incrByUtf8();
            _ = self.incrByUtf8UntilFalse(xml.isValidUtf8NameCharOrColon);
            
            const len = (self.getIndexOrLen().? - start_index);
            return self.returnToken(Token.initTag(start_index, .@"<{name}", .{ .len = len }));
        },
    }
}



fn incrementUtf8UntilNonWhitespace(self: *Tokenizer) usize {
    return self.incrByUtf8UntilFalse(struct { fn func(c: u21) bool {
        return switch (c) {
            ' ',
            '\t',
            '\n',
            '\r',
            => true,
            else => false
        };
    } }.func);
}

/// Increments by the byte length of each encountered UTF8 sequence,
/// until `constraint(codepoint) == false`, and returns the total traversed length in bytes.
fn incrByUtf8UntilFalse(self: *Tokenizer, comptime constraint: fn(u21)bool) usize {
    var len: usize = 0;
    while (self.getUtf8()) |codepoint| : ({
        self.incrByUtf8();
        len += unicode.utf8CodepointSequenceLength(codepoint) catch 0;
    }) if (!constraint(codepoint)) break;
    return len;
}



fn returnEof(self: *Tokenizer) Token {
    std.debug.assert((self.getIndexOrLen() orelse self.buffer.len - 1) == self.buffer.len);
    return self.returnToken(Token.init(self.getIndexOrLen().?, .eof));
}

fn returnInvalid(self: *Tokenizer, index: ?usize) Token {
    return self.returnToken(Token.init(index orelse self.state.index, .invalid));
}

fn returnToken(self: *Tokenizer, tok: Token) Token {
    self.state.prev = tok.info;
    return tok;
}



fn incrByUtf8(self: *Tokenizer) void {
    self.state.index += if (self.getUtf8()) |cp| (unicode.utf8CodepointSequenceLength(cp) catch unreachable) else 0;
}

fn getUtf8(self: Tokenizer) ?u21 {
    const start_byte = self.getByte() orelse return null;
    const codepoint_len = unicode.utf8ByteSequenceLength(start_byte) catch return null;
    const end = self.state.index + codepoint_len;
    if (end > self.buffer.len) return null;
    return unicode.utf8Decode(self.buffer[self.state.index..end]) catch null;
}

fn getByte(self: Tokenizer) ?u8 {
    return if (self.getIndex()) |index| self.buffer[index] else null;
}

fn getIndexOrLen(self: Tokenizer) ?usize {
    if (self.state.index <= self.buffer.len) return self.state.index;
    return null;
}

fn getIndex(self: Tokenizer) ?usize {
    if (self.state.index < self.buffer.len) return self.state.index;
    return null;
}

const State = struct {
    index: usize = 0,
    last_quote: ?QuoteType = null,
    prev: Token.Info.Tag = .bof,
    
    const QuoteType = enum(u8) { single = '\'', double = '"' };
};

test {
    std.debug.print("\n", .{});
    
    const xml_text =
        \\  <elema42da foo="do&quot;re&amp;&quot;fa"/>
    ;
    
    var tokenizer = Tokenizer.init(xml_text);
    
    while (tokenizer.next()) |tok| {
        std.debug.print("'{s}': '{s}'\n", .{@tagName(tok.info), tok.slice(xml_text)});
    }
}
