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
        
        attribute_name: Length,
        @"=",
        quoted_entity_ref: Length,
        quoted_text: Length,
        empty_quotes,
        
        
        @">",
        @"/>",
        @"?>",
        
        @"<!--",
        commented_text: Length,
        @"-->",
        
        @"<![CDATA[",
        cdata_text: Length,
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
            const beg = if (self == .invalid and index == src.len) 0 else index;
            const end = beg + switch (self) {
                .invalid => 1,
                .bof => 0,
                .eof => 0,
                
                .text,
                .entity_ref,
                .whitespace,
                => |info| info.len,
                
                .@"<{name}",
                .@"</{name}",
                .@"<?{name}",
                => |info| info.len,
                
                .attribute_name => |info| info.len,
                .@"=" => 1,
                .quoted_entity_ref => |info| info.len,
                .quoted_text => |info| info.len,
                .empty_quotes => 0,
                
                .@">",
                .@"/>",
                .@"?>",
                => @tagName(self).len,
                
                .@"<!--" => @tagName(self).len,
                .commented_text => |info| info.len,
                .@"-->" => @tagName(self).len,
                
                .@"<![CDATA[" => @tagName(self).len,
                .cdata_text => |info| info.len,
                .@"]]>" => @tagName(self).len,
                
                .@"%",
                .@"*",
                .@",",
                .@"(",
                .@")",
                => @tagName(self).len,
                
                .@"<!DOCTYPE",
                .@"<!ENTITY",
                .@"<!ELEMENT",
                .@"<!ATTLIST",
                .@"<!NOTATION",
                .@"]>",
                => @tagName(self).len,
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
        
        .attribute_name => {
            std.debug.assert(self.getUtf8().? == '=');
            const start_index = self.getIndex().?;
            _ = self.incrementUtf8UntilNonWhitespace();
            return self.returnToken(Token.init(start_index, .@"="));
        },
        
        .text => switch (self.getUtf8() orelse return self.returnInvalid(null)) {
            '<' => return self.afterTagOpen(),
            '&' => return self.getEntityReference(false),
            else => return self.returnInvalid(null),
        },
        
        .entity_ref => return self.getContent(false),
        
        .whitespace => switch (self.getUtf8() orelse return self.returnEof()) {
            '<' => return self.afterTagOpen(),
            else => return self.returnInvalid(null),
        },
        
        .@"<{name}" => return self.getNextAttributeNameOrTagEnd(),
        
        .@"</{name}" => {
            if (self.getUtf8() orelse 0 != '>') return self.returnInvalid(null);
            return self.getTagEnd();
        },
        
        .@"<?{name}" => todo(),
        
        .@"=" => {
            self.incrByUtf8();
            _ = self.incrementUtf8UntilNonWhitespace();
            
            switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                '"',
                '\'',
                => {
                    const quote_type = QuoteType.from(@intCast(u8, self.getUtf8().?));
                    self.incrByUtf8();
                    self.state.last_quote = quote_type;
                    return switch (quote_type) {
                        .double => self.getQuotedTextOrEntityRef(.double),
                        .single => self.getQuotedTextOrEntityRef(.single),
                    };
                },
                else => return self.returnInvalid(null),
            }
        },
        
        .empty_quotes => return self.getQuotedTextContinuation(),
        
        .commented_text => {
            std.debug.assert(self.getUtf8() orelse 0 == '-');
            const start_index = self.getIndex().?;
            var self_copy: Tokenizer = self.*;
            self_copy.incrByUtf8();
            switch (self_copy.getUtf8() orelse {
                self.* = self_copy;
                return self.returnInvalid(null);
            }) {
                '-' => {
                    self_copy.incrByUtf8();
                    self.* = self_copy;
                    return switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                        '>' => self.returnToken(Token.init(start_index, .@"-->")),
                        else => self.returnInvalid(null)
                    };
                },
                
                else => {},
            }
        },
        
        .cdata_text => {
            const start_index = self.getIndex().?;
            std.debug.assert(self.getUtf8().? == ']');
            
            self.incrByUtf8();
            std.debug.assert(self.getUtf8().? == ']');
            
            self.incrByUtf8();
            std.debug.assert(self.getUtf8() orelse 0 == '>');
            
            return self.returnToken(Token.init(start_index, .@"]]>"));
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
        
        .@"<![CDATA[" => {
            std.debug.assert(self.getUtf8() orelse 0 == '[');
            self.incrByUtf8();
            const start_index = self.getIndex() orelse return self.returnInvalid(null);
            switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                ']' => {
                    self.incrByUtf8();
                    switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                        ']' => {
                            self.incrByUtf8();
                            switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                                '>' => return self.returnToken(Token.init(start_index, .@"]]>")),
                                else => {}
                            }
                        },
                        else => {}
                    }
                },
                
                else => {}
            }
            
            while (self.getUtf8() != null) {
                
                _ = self.incrByUtf8UntilFalse(struct {
                    fn func(c: u21) bool { return c != ']'; }
                }.func);
                
                std.debug.assert(self.getUtf8() orelse 0 == ']');
                
                var self_copy: Tokenizer = self.*;
                self_copy.incrByUtf8();
                
                switch (self_copy.getUtf8() orelse {
                    self.* = self_copy;
                    return self.returnInvalid(null);
                }) {
                    ']' => {
                        self_copy.incrByUtf8();
                        switch (self_copy.getUtf8() orelse {
                            self.* = self_copy;
                            return self.returnInvalid(null);
                        }) {
                            '>' => return self.returnToken(Token.initTag(start_index, .cdata_text, .{ .len = self.getIndex().? - start_index })),
                            else => {},
                        }
                    },
                    
                    else => {},
                }
                
                self.* = self_copy;
            }
        },
        
        .@"]]>" => return self.getContent(false),
        .@"<!--" => {
            std.debug.assert(self.getUtf8().? == '-');
            self.incrByUtf8();
            const start_index = self.getIndex() orelse return self.returnInvalid(null);
            switch (self.getUtf8().?) {
                '-' => {
                    var self_copy: Tokenizer = self.*;
                    self_copy.incrByUtf8();
                    switch (self_copy.getUtf8() orelse {
                        self.* = self_copy;
                        return self.returnInvalid(null);
                    }) {
                        '-' => {
                            self_copy.incrByUtf8();
                            self.* = self_copy;
                            return switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                                '>' => self.returnToken(Token.init(start_index, .@"-->")),
                                else => self.returnInvalid(null)
                            };
                        },
                        
                        else => {},
                    }
                },
                
                else => {},
            }
            
            var len: usize = 0;
            while (true) {
                len += self.incrByUtf8UntilFalse(struct {
                    fn func(c: u21) bool { return c != '-'; }
                }.func);
                
                std.debug.assert(self.getUtf8() orelse 0 == '-');
                
                var self_copy = self.*;
                self_copy.incrByUtf8();
                
                switch (self_copy.getUtf8() orelse {
                    self.* = self_copy;
                    return self.returnInvalid(null);
                }) {
                    '-' => {
                        self_copy.incrByUtf8();
                        switch (self_copy.getUtf8() orelse {
                            self.* = self_copy;
                            return self.returnInvalid(null);
                        }) {
                            '>' => return self.returnToken(Token.initTag(start_index, .commented_text, .{ .len = len })),
                            else => {
                                self.* = self_copy;
                                return self.returnInvalid(null);
                            }
                        }
                    },
                    
                    else => {}
                }
            }
        },
        
        .@"-->",
        .@"?>",
        .@"/>",
        .@">",
        => return self.getContent(true),
        
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

fn getContent(self: *Tokenizer, comptime enable_eof: bool) Token {
    std.debug.assert(self.getUtf8().? == '>' or self.getUtf8().? == ';');
    self.incrByUtf8();
    const start_index = self.getIndex() orelse return if (enable_eof) self.returnEof() else self.returnInvalid(null);
    const whitespace_len = self.incrementUtf8UntilNonWhitespace();
    
    const maybe_whitespace_result = Token.initTag(start_index, .whitespace, .{ .len = whitespace_len });
    
    switch (self.getUtf8() orelse return self.returnToken(maybe_whitespace_result)) {
        '&',
        '<',
        => return if (whitespace_len == 0) self.afterTagOpen() else self.returnToken(maybe_whitespace_result),
        
        else => {
            const remaining_len = self.incrByUtf8UntilFalse(struct {
                fn func(c: u21) bool {
                    return c != '<' and c != '&';
                }
            }.func);
            
            const len = whitespace_len + remaining_len;
            const result = Token.initTag(start_index, .text, .{ .len = len });
            return self.returnToken(result);
        },
    }
}

fn getQuotedTextOrEntityRef(self: *Tokenizer, comptime quote_type: QuoteType) Token {
    const quote = comptime quote_type.value();
    const start_index = self.getIndex() orelse return self.returnInvalid(null);
    
    const len = self.incrByUtf8UntilFalse(struct {
        fn func(c: u21) bool { return c != quote and c != '&'; }
    }.func);
    
    const maybe_result = Token.initTag(start_index, .quoted_text, .{ .len = len });
    const actual_result_before_check = switch (self.getUtf8() orelse return self.returnInvalid(null)) {
        quote => self.returnToken(maybe_result),
        '&' => return if (len == 0) self.getEntityReference(true) else self.returnToken(maybe_result),
        else => unreachable,
    };
    
    return switch (actual_result_before_check.info) {
        .quoted_text => |info| self.returnToken(if (info.len == 0) Token.init(actual_result_before_check.index, .empty_quotes) else actual_result_before_check),
        else => actual_result_before_check,
    };
}



fn getQuotedTextContinuation(self: *Tokenizer) Token {
    switch (self.getUtf8() orelse return self.returnInvalid(null)) {
        '&' => return self.getEntityReference(true),
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

fn getEntityReference(self: *Tokenizer, comptime quoted: bool) Token {
    std.debug.assert(self.getUtf8().? == '&');
    
    const start_index = self.getIndex().?;
    self.incrByUtf8();
    const len = self.incrByUtf8UntilFalse(struct {
        fn func(c: u21) bool {
            return c != ';';
        }
    }.func);
    
    const maybe_result = Token.initTag(start_index, if (quoted) .quoted_entity_ref else .entity_ref, .{ .len = len + 2 });
    
    if (self.getUtf8() orelse 0 != ';') return self.returnInvalid(null);
    return self.returnToken(maybe_result);
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
    
    const maybe_result = Token.initTag(start_index, .quoted_entity_ref, .{ .len = len + 2 });
    
    if (self.getUtf8() orelse 0 != ';') return self.returnInvalid(null);
    return self.returnToken(maybe_result);
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
            
            const output = Token.initTag(start_index, .attribute_name, .{ .len = len });
            return self.returnToken(output);
        },
        
        '/' => return self.getInlineClose(),
        '>' => return self.getTagEnd(),
        else => unreachable,
    }
    
    unreachable;
}



fn getTagEnd(self: *Tokenizer) Token {
    std.debug.assert(self.getUtf8().? == '>');
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
        '?' => todo(),
        '!' => {
            self.incrByUtf8();
            switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                '-' => {
                    self.incrByUtf8();
                    return switch (self.getUtf8() orelse return self.returnInvalid(null)) {
                        '-' => self.returnToken(Token.init(start_index, .@"<!--")),
                        else => self.returnInvalid(null)
                    };
                },
                
                '[' => {
                    for ("CDATA[") |char| {
                        self.incrByUtf8();
                        if (self.getUtf8() orelse (char +% 1) != char) return self.returnInvalid(null);
                    }
                    return self.returnToken(Token.init(start_index, .@"<![CDATA["));
                },
                'D' => todo(),
                else => return self.returnInvalid(null)
            }
        },
        '/' => {
            self.incrByUtf8();
            const name_len = self.incrByUtf8UntilFalse(struct {
                fn func(c: u21) bool {
                    return switch (c) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        '>',
                        => false,
                        else => true,
                    };
                }
            }.func);
            _ = self.incrementUtf8UntilNonWhitespace();
            
            const maybe_result = Token.initTag(start_index, .@"</{name}", .{ .len = ("</".len) + name_len });
            return if (name_len == 0) self.returnInvalid(null) else self.returnToken(maybe_result);
        },
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

pub const State = struct {
    index: usize = 0,
    last_quote: ?QuoteType = null,
    prev: Token.Info.Tag = .bof,
};

const QuoteType = enum(u8) {
    single = '\'',
    double = '"',
    
    pub fn from(char: u8) @This() {
        return switch (char) {
            '\'',
            '"',
            => @intToEnum(@This(), char),
            else => unreachable
        };
    }
    
    pub fn value(self: QuoteType) u8 {
        return @enumToInt(self);
    }
};

test {
    std.debug.print("\n", .{});
    
    const xml_text =
        \\ <!-- COMMENT TEXT --> <elem> <![CDATA[]]> </elem>
    ;
    
    
    var tokenizer = Tokenizer.init(xml_text);
    while (tokenizer.next()) |tok| {
        _ = tok;
        //std.debug.print("'{s}': '{s}'\n", .{@tagName(tok.info), tok.slice(xml_text)});
    }
}
