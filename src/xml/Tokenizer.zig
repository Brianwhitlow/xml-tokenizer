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
        string: Length,
        
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
                .invalid => 1,
                .bof,
                .eof => 0,
                
                .name,
                .text,
                .whitespace,
                .entity_ref,
                .@"<{name}",
                .@"</{name}",
                .@"<?{name}",
                => |variable| variable.len,
                
                else => @tagName(self).len,
            };
            
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
                while (self.getUtf8()) |codepoint| : (self.incrByUtf8()) switch (codepoint) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => continue,
                    // including '<'
                    else => break,
                };
                return self.returnToken(Token.initTag(start_index, .whitespace, .{ .len = (self.getIndex().? - start_index) }));
            },
            
            '<' => return self.afterTagOpen(),
            else => return self.returnInvalid(null)
        },
        
        .name => {
            std.debug.assert(self.getUtf8().? == '=');
            self.incrByUtf8();
        },
        
        .string => unreachable,
        .text => unreachable,
        .entity_ref => unreachable,
        
        .whitespace => switch (self.getUtf8() orelse return self.returnEof()) {
            ' ',
            '\t',
            '\n',
            '\r',
            => std.debug.assert(false),
            '<' => return self.afterTagOpen(),
            else => return self.returnInvalid(null),
        },
        
        .@"<{name}" => switch (self.getUtf8() orelse return self.returnInvalid(null)) {
            ' ',
            '\t',
            '\n',
            '\r',
            => {
                self.incrementUtf8UntilNonWhitespace();
                if (self.getUtf8()) |codepoint| switch (codepoint) {
                    '/' => return self.getInlineClose(),
                    '>' => return self.getTagEnd(),
                    else => if (!xml.isValidUtf8NameStartChar(codepoint)) return self.returnInvalid(null)
                } else return self.returnInvalid(null);
                
                var output = Token.initTag(self.getIndex().?, .name, .{ .len = 0 });
                self.incrByUtf8UntilFalse(xml.isValidUtf8NameCharOrColon);
                
                switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => {
                        output.info.name.len = (self.getIndex().? - output.index);
                        self.incrByUtf8UntilFalse(struct { fn func(c: u21) bool { return c != '='; } }.func);
                    },
                    '=' => output.info.name.len = (self.getIndex().? - output.index),
                    else => unreachable,
                }
                
                return self.returnToken(output);
            },
            
            '/' => return self.getInlineClose(),
            '>' => return self.getTagEnd(),
            else => std.debug.assert(false),
        },
        .@"</{name}" => unreachable,
        .@"<?{name}" => unreachable,
        
        .@"=" => unreachable,
        
        
        .@"<!--" => unreachable,
        .@"<![CDATA[" => unreachable,
        
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
            
            unreachable;
        },
        
        .@"%" => unreachable,
        
        .@"(" => unreachable,
        .@")" => unreachable,
        .@"," => unreachable,
        .@"*" => unreachable,
        
        .@"<!DOCTYPE" => unreachable,
        .@"<!ENTITY" => unreachable,
        .@"<!ELEMENT" => unreachable,
        .@"<!ATTLIST" => unreachable,
        .@"<!NOTATION" => unreachable,
        .@"]>" => unreachable,

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
    
    const result = if (codepoint == '>') self.returnToken(Token.init(start_index, .@"/>")) else self.returnInvalid(null);
    return result;
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
            self.incrByUtf8UntilFalse(xml.isValidUtf8NameCharOrColon);
            
            const len = (self.getIndexOrLen().? - start_index);
            return self.returnToken(Token.initTag(start_index, .@"<{name}", .{ .len = len }));
        },
    }
}



fn incrementUtf8UntilNonWhitespace(self: *Tokenizer) void {
    self.incrByUtf8UntilFalse(struct { fn func(c: u21) bool {
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

fn incrByUtf8UntilFalse(self: *Tokenizer, comptime constraint: fn(u21)bool) void {
    while (self.getUtf8()) |codepoint| : (self.incrByUtf8())
        if (!constraint(codepoint)) break;
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
    prev: Token.Info.Tag = .bof,
};

test {
    std.debug.print("\n", .{});
    
    const xml_text =
        \\  <elema42da foo= />
    ;
    
    var tokenizer = Tokenizer.init(xml_text);
    while (tokenizer.next()) |tok| {
        std.debug.print("'{s}': '{s}'\n", .{@tagName(tok.info), tok.slice(xml_text)});
    }
}
