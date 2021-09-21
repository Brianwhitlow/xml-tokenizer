const std = @import("std");
const meta = std.meta;
const unicode = std.unicode;
const xml = @import("../xml.zig");

const Tokenizer = @This();
buffer: []const u8,
state: Sate,

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
    info: Info = .invalid,
    
    pub fn init(index: usize, info: Info) Token {
        return Token {
            .index = index,
            .info = info,
        };
    }
    
    pub fn initTag(index: usize, tag: meta.Tag(Info), info_value: meta.TagPayload(Info, tag)) Token {
        return Token.init(index, @unionInit(Info, @tagName(tag), info_value));
    }
    
    pub fn slice(self: Token, src: []const u8) []const u8 {
        return self.info.slice(self.index, src);
    }
    
    pub const Info = union(enum) {
        invalid,
        eof,
        
        @"<",
        @">",
        
        @"</",
        @"/>",
        
        @"<?",
        @"?>",
        
        @"<!--",
        @"-->",
        
        @"<![CDATA[",
        @"]]>", // may also appear within the context of a dtd
        
        name: Length,
        text: Length,
        whitespace: Length,
        entity_ref: Length,
        
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
        
        pub fn slice(self: Info, index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + switch (self) {
                .invalid => 1,
                .eof => 0,
                .@"<",
                .@">",
                .@"</",
                .@"/>",
                .@"<?",
                .@"?>",
                .@"<!--",
                .@"-->",
                .@"<![CDATA[",
                .@"]]>",
                .@"(",
                .@")",
                .@"%",
                .@"*",
                .@",",
                .@"<!DOCTYPE",
                .@"<!ENTITY",
                .@"<!ELEMENT",
                .@"<!ATTLIST",
                .@"<!NOTATION",
                .@"]>",
                => @tagName(self).len,
                
                name,
                text,
                whitespace,
                entity_ref,
                => |lengthed| lengthed.len,
            };
            
            return src[beg..end];
        }
    };
};

pub fn next(self: *Tokenizer) ?Token {
    switch (self.state.info) {
        .end => return null,
        
        .invalid => {
            self.state.info = .end;
            return Token.init(self.state.index, .invalid);
        },
        
        .start => if (self.getUtf8()) |codepoint0| switch (codepoint0) {
            ' ',
            '\t',
            '\n',
            '\r',
            => {
                self.state.index += 1;
                while (self.getUtf8()) |cp| switch (cp) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => self.incrByUtf8(),
                    '<' => {
                        self.incrByUtf8();
                        self.state.info = .@"<";
                        break;
                    },
                    else => {
                        self.incrByUtf8();
                        self.state.info = .invalid;
                        break;
                    },
                } else {
                    self.state.info = .end;
                }
                
                return Token.initTag(0, .whitespace, .{ .len = self.state.index });
            },
            
            '<' => {
                self.incrByUtf8();
                if (self.getUtf8()) |cp| switch (cp) {
                    '!' => unreachable,
                    '?' => unreachable,
                    else => if (xml.isValidUtf8NameChar(cp)) {
                        
                    },
                } else return Token.init(self.state.index, .invalid);
            },
        }
    }
    
    unreachable;
}

const State = struct {
    index: usize = 0,
    info: Info,
    
    const Info = union(enum) {
        end,
        invalid,
        start,
        @"<",
    };
};

fn incrByUtf8(self: *Tokenizer) void {
    self.state.index += if (self.getUtf8()) |cp| (unicode.utf8CodepointSequenceLength(cp) catch unreachable) else 0;
}

fn getUtf8(self: Tokenizer) ?u21 {
    const start_byte = self.getByte() orelse return null;
    const codepoint_len = unicode.utf8CodepointSequenceLength(start_byte) catch return null;
    const end = self.state.index + codepoint_len;
    if (end > self.buffer.len) return null;
    return unicode.utf8Decode(self.buffer[self.state.index..end]) catch null;
}

fn getByte(self: Tokenizer) ?u8 {
    if (self.state.index >= self.buffer.len) return self.buffer[self.state.index];
    return null;
}
