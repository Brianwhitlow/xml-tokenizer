const std = @import("std");

pub const Index = struct { index: usize };
pub const Range = struct {
    beg: usize,
    end: usize,
    
    pub fn slice(self: Range, buffer: []const u8) []const u8 {
        return buffer[self.beg..self.end];
    }
};

pub const Token = union(enum) {
    invalid: Index,
    bof,
    eof,
    
    element_open: ElementOpen,
    attribute: Attribute,
    element_close: ElementClose,
    
    text: Text,
    
    processing_instructions: ProcessingInstructions,
    comment: Comment,
    
    pub const ElementOpen = ElementId;
    pub const Attribute = NameValuePair;
    pub const ElementClose = ElementId;
    
    pub const Text = union(enum) {
        content: Range,
        char_data: Range,
        empty_whitespace: Range,
    };
    
    pub const ProcessingInstructions = struct {
        target: Range,
        instructions: Range,
        
        pub fn slice(self: ProcessingInstructions, buffer: []const u8) []const u8 {
            return buffer[self.target.beg - "<?".len..self.instructions.end + "?>".len];
        }
        
    };
    
    pub const Comment = struct {
        content: Range,
        
        pub fn slice(self: Comment, buffer: []const u8) []const u8 {
            return buffer[self.content.beg - "<!--".len..self.content.end + "-->".len];
        }
        
    };
    
    pub const ElementId = struct {
        namespace: Range,
        identifier: Range,
        
        pub fn slice(self: ElementId, buffer: []const u8) []const u8 {
            return buffer[self.namespace.beg..self.identifier.end];
        } 
        
    };
    
    pub const NameValuePair = struct {
        name: Range,
        value: Range,
        
        pub fn slice(self: NameValuePair, buffer: []const u8) []const u8 {
            return buffer[self.name.beg..self.value.end + 1];
        }
        
    };
    
};

pub const TokenStream = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const ParseState = union(enum) {
        start,
        tag_open,
        seek_element_name_end: struct {
            namespace_beg: usize,
            identifier_beg: usize,
        },
        
        seek_element_begin_end: ElementNameCache,
        
        tokenizing_attribute: struct {
            element_name_cache: ElementNameCache,
            state: union(enum) {
                seek_name_end: NameStart,
                seek_eql: AttrNameCache,
                seek_quote1: AttrNameCache,
                seek_quote2: struct {
                    attr_name_cache: AttrNameCache,
                    value_start: Index,
                },
                
                pub const AttrNameCache = Range;
                pub const NameStart = Index;
            },
        },
        
        in_content: struct {
            start: Index,
            non_whitespace_characters: bool = false,
        },
        
        element_close: union(enum) {
            start,
            seek_name_end: NameCache,
            seek_bracket,
            
            pub const NameCache = struct {
                namespace_beg: usize,
                identifier_beg: usize,
            };
        },
        
        pub const ElementNameCache = struct {
            namespace_beg: usize,
            identifier_beg: usize,
            identifier_end: usize,
        };
        
    };
    
    pub fn next(self: *TokenStream) Token {
        std.debug.assert(blk: {
            if (self.parse_state == .start) {
                break :blk self.index == 0;
            }
            break :blk true;
        });
        
        while (self.index < self.buffer.len) {
            const current_char = self.buffer[self.index];
            
            switch (self.parse_state) {
                .start
                => switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    => self.index += 1,
                    
                    '<',
                    => {
                        self.parse_state = .tag_open;
                        self.index += 1;
                    },
                    
                    else
                    => unreachable,
                },
                
                .tag_open
                => switch (current_char) {
                    '?',
                    => unreachable,
                    
                    '!',
                    => unreachable,
                    
                    '/',
                    => {
                        self.parse_state = .{ .element_close = .start };
                        self.index += 1;
                    },
                    
                    else
                    => {
                        const current_utf8_cp = self.currentUtf8Codepoint() orelse unreachable;
                        if (!isValidXmlNameStartCharUtf8(current_utf8_cp)) unreachable;
                        self.parse_state = .{ .seek_element_name_end = .{
                            .namespace_beg = self.index,
                            .identifier_beg = self.index,
                        } };
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .seek_element_name_end
                => |*seek_element_name_end| switch (current_char) {
                    ':',
                    => {
                        self.index += 1;
                        seek_element_name_end.identifier_beg = self.index;
                    },
                    
                    ' ', '\t', '\n', '\r',
                    => {
                        const result = Token { .element_open = .{
                            .namespace = .{
                                .beg = seek_element_name_end.namespace_beg,
                                .end = seek_element_name_end.identifier_beg - 1,
                            },
                            
                            .identifier = .{
                                .beg = seek_element_name_end.identifier_beg,
                                .end = self.index
                            },
                        } };
                        
                        self.parse_state = .{ .seek_element_begin_end = .{
                            .namespace_beg = result.element_open.namespace.beg,
                            .identifier_beg = result.element_open.identifier.beg,
                            .identifier_end = result.element_open.identifier.end,
                        } };
                        
                        self.index += 1;
                        return result;
                    },
                    
                    '>',
                    => {
                        const result = Token { .element_open = .{
                            .namespace = .{
                                .beg = seek_element_name_end.namespace_beg,
                                .end = seek_element_name_end.identifier_beg - 1,
                            },
                            
                            .identifier = .{
                                .beg = seek_element_name_end.identifier_beg,
                                .end = self.index
                            },
                        } };
                        
                        self.index += 1;
                        self.parse_state = .{ .in_content = .{ .start = .{ .index = self.index } } };
                        
                        return result;
                    },
                    
                    else
                    => {
                        const current_utf8_cp = self.currentUtf8Codepoint() orelse unreachable;
                        if (!isValidXmlNameCharUtf8(current_utf8_cp)) unreachable;
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .seek_element_begin_end
                => |seek_element_begin_end| switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    => self.index += 1,
                    
                    '/',
                    => {
                        if (!safeAccessCmpBufferIndex(u8, self.buffer, self.index + 1, '>')) unreachable;
                        
                        const result = Token { .element_close = .{
                            .namespace = .{
                                .beg = seek_element_begin_end.namespace_beg,
                                .end = seek_element_begin_end.identifier_beg - 1
                            },
                            
                            .identifier = .{
                                .beg = seek_element_begin_end.identifier_beg,
                                .end = seek_element_begin_end.identifier_end,
                            },
                        } };
                        
                        self.index += 2;
                        self.parse_state = .{ .in_content = .{ .start = .{ .index = self.index } } };
                        
                        return result;
                    },
                    
                    '>',
                    => {
                        self.index += 1;
                        self.parse_state = .{ .in_content = .{ .start = .{ .index = self.index } } };
                    },
                    
                    else
                    => {
                        const current_utf8_cp = self.currentUtf8Codepoint() orelse unreachable;
                        if (!isValidXmlNameStartCharUtf8(current_utf8_cp)) unreachable;
                        self.parse_state = .{ .tokenizing_attribute = .{
                            .element_name_cache = seek_element_begin_end,
                            .state = .{ .seek_name_end = .{ .index = self.index } },
                        } };
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .tokenizing_attribute
                => |*tokenizing_attribute| switch (tokenizing_attribute.state) {
                    .seek_name_end
                    => |seek_name_end| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        '=',
                        => {
                            tokenizing_attribute.state = .{ .seek_eql = .{
                                .beg = seek_name_end.index,
                                .end = self.index,
                            } };
                        },
                        
                        else
                        => {
                            const current_utf8_cp = self.currentUtf8Codepoint() orelse unreachable;
                            if (!isValidXmlNameCharUtf8(current_utf8_cp)) unreachable;
                            self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                        },
                    },
                    
                    .seek_eql
                    => |seek_eql| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => self.index += 1,
                        
                        '=',
                        => {
                            tokenizing_attribute.state = .{ .seek_quote1 = seek_eql };
                            self.index += 1;
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .seek_quote1
                    => |seek_quote1| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => self.index += 1,
                        
                        '"',
                        => {
                            self.index += 1;
                            tokenizing_attribute.state = .{ .seek_quote2 = .{
                                .attr_name_cache = seek_quote1,
                                .value_start = .{ .index = self.index } }
                            };
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .seek_quote2
                    => |seek_quote2| switch (current_char) {
                        '"',
                        => {
                            const result = Token {
                                .attribute = .{
                                    .name = seek_quote2.attr_name_cache,
                                    .value = .{
                                        .beg = seek_quote2.value_start.index,
                                        .end = self.index
                                    },
                                },
                            };
                            
                            self.index += 1;
                            self.parse_state = .{ .seek_element_begin_end = tokenizing_attribute.element_name_cache };
                            
                            return result;
                        },
                        
                        else
                        => self.index += 1,
                    },
                },
                
                .in_content
                => |*in_content| switch (current_char) {
                    '<',
                    => {
                        const result = blk: {
                            if (in_content.non_whitespace_characters) {
                                break :blk Token { .text = .{ .content = .{
                                    .beg = in_content.start.index,
                                    .end = self.index,
                                } } };
                            }
                            
                            break :blk Token { .text = .{ .empty_whitespace = .{
                                .beg = in_content.start.index,
                                .end = self.index,
                            } } };
                        };
                        
                        self.parse_state = .tag_open;
                        self.index += 1;
                        return result;
                    },
                    
                    else
                    => {
                        in_content.non_whitespace_characters = in_content.non_whitespace_characters or switch (current_char) {
                            ' ', '\t', '\n', '\r',
                            => false,
                            
                            else
                            => true,
                        };
                        self.index += 1;
                    },
                },
                
                .element_close
                => |*element_close| switch (element_close.*) {
                    .start
                    => {
                        const current_utf8_cp = self.currentUtf8Codepoint() orelse unreachable;
                        if (!isValidXmlNameStartCharUtf8(current_utf8_cp)) unreachable;
                        element_close.* = .{ .seek_name_end = .{
                            .namespace_beg = self.index,
                            .identifier_beg = self.index,
                        } };
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                    
                    .seek_name_end
                    => |*seek_name_end| switch (current_char) {
                        ':',
                        => {
                            self.index += 1;
                            seek_name_end.identifier_beg = self.index;
                        },
                        
                        ' ', '\t', '\n', '\r',
                        '>',
                        => {
                            const result = Token { .element_close = .{
                                .namespace = .{ .beg = seek_name_end.namespace_beg, .end = seek_name_end.identifier_beg - 1 },
                                .identifier = .{ .beg = seek_name_end.identifier_beg, .end = self.index },
                            } };
                            
                            self.index += 1;
                            if (current_char == '>') {
                                self.parse_state = .{ .in_content = .{ .start = .{ .index = self.index } } };
                            } else {
                                element_close.* = .seek_bracket;
                            }
                            
                            return result;
                        },
                        
                        else
                        => {
                            const current_utf8_cp = self.currentUtf8Codepoint() orelse unreachable;
                            if (!isValidXmlNameCharUtf8(current_utf8_cp)) unreachable;
                            self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                        },
                    },
                    
                    .seek_bracket
                    => switch (current_char) {
                        '>',
                        => {
                            self.index += 1;
                            self.parse_state = .{ .in_content = .{ .start = .{ .index = self.index } } };
                        },
                        
                        ' ', '\t', '\n', '\r',
                        => self.index += 1,
                        
                        else
                        => unreachable,
                    },
                },
            }
        }
        
        return .eof;
        
    }
    
    fn currentUtf8Codepoint(self: TokenStream) ?u21 {
        const utf8_cp_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.index]) catch return null;
        if (self.index + utf8_cp_len > self.buffer.len) return null;
        return std.unicode.utf8Decode(self.buffer[self.index..self.index + utf8_cp_len]) catch null;
    }
    
};

/// Returns false if index would be an out-of-bounds access, or if `buffer[index] != with`.
fn safeAccessCmpBufferIndex(comptime T: type, buffer: []const T, index: usize, with: T) bool {
    return index < buffer.len and buffer[index] == with;
}

fn isValidXmlNameStartCharUtf8(char: u21) bool {
    return switch (char) {
        'A'...'Z',
        'a'...'z',
        '_',
        '\u{c0}'    ... '\u{d6}',
        '\u{d8}'    ... '\u{f6}',
        '\u{f8}'    ... '\u{2ff}',
        '\u{370}'   ... '\u{37d}',
        '\u{37f}'   ... '\u{1fff}',
        '\u{200c}'  ... '\u{200d}',
        '\u{2070}'  ... '\u{218f}',
        '\u{2c00}'  ... '\u{2fef}',
        '\u{3001}'  ... '\u{d7ff}',
        '\u{f900}'  ... '\u{fdcf}',
        '\u{fdf0}'  ... '\u{fffd}',
        '\u{10000}' ... '\u{effff}',
        => true,
        
        else
        => false,
    };
}

fn isValidXmlNameCharUtf8(char: u21) bool {
    return isValidXmlNameStartCharUtf8(char) or switch (char) {
        '0'...'9',
        '-',
        '.',
        '\u{b7}',
        '\u{0300}'...'\u{036f}',
        '\u{203f}'...'\u{2040}',
        => true,
        
        else
        => false,
    };
}

test "T1" {
    std.debug.print("\n", .{});
    defer std.debug.print("\n", .{});
    const testing = std.testing;
    
    var tokenizer = TokenStream{ .buffer = 
        \\<book category="WEB">
        \\    <extra discount = "20%"/>
        \\    <title lang="en">Learning XML</title >
        \\    <author>Erik T. Ray</author>
        \\</book>
    };
    
    var current = tokenizer.next();
    try testing.expectEqualStrings("book", current.element_open.identifier.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("category", current.attribute.name.slice(tokenizer.buffer));
    try testing.expectEqualStrings("WEB", current.attribute.value.slice(tokenizer.buffer));
    try testing.expectEqualStrings("category=\"WEB\"", current.attribute.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("\n    ", current.text.empty_whitespace.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("extra", current.element_open.identifier.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("discount", current.attribute.name.slice(tokenizer.buffer));
    try testing.expectEqualStrings("20%", current.attribute.value.slice(tokenizer.buffer));
    try testing.expectEqualStrings("discount = \"20%\"", current.attribute.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("extra", current.element_close.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("\n    ", current.text.empty_whitespace.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("title", current.element_open.identifier.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("lang", current.attribute.name.slice(tokenizer.buffer));
    try testing.expectEqualStrings("en", current.attribute.value.slice(tokenizer.buffer));
    try testing.expectEqualStrings("lang=\"en\"", current.attribute.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("Learning XML", current.text.content.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("title", current.element_close.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("\n    ", current.text.empty_whitespace.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("author", current.element_open.identifier.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("Erik T. Ray", current.text.content.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("author", current.element_close.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("\n", current.text.empty_whitespace.slice(tokenizer.buffer));
    
    
    
    current = tokenizer.next();
    try testing.expectEqualStrings("book", current.element_close.slice(tokenizer.buffer));
}
