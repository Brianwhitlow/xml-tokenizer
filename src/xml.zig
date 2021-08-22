const std = @import("std");
const testing = std.testing;

pub const Index = struct { index: usize };
pub const Range = struct {
    beg: usize,
    end: usize,
    pub fn slice(self: Range, buffer: []const u8) []const u8 {
        return buffer[self.beg..self.end];
    }
};

pub const Token = union(enum) {
    bof,
    eof,
    invalid: Index,
    
    element_open: ElementId,
    element_close: ElementId,
    attribute: Attribute,
    
    empty_whitespace: Range,
    text: Range,
    char_data: CharData,
    
    comment: Comment,
    processing_instructions: ProcessingInstructions,
    
    
    
    pub const ElementId = struct {
        namespace_colon: ?Index,
        identifier: Range,
        pub fn slice(self: ElementId, buffer: []const u8) []const u8 {
            return buffer[self.identifier.beg..self.identifier.end];
        }
        
        pub fn namespace(self: ElementId, buffer: []const u8) ?[]const u8 {
            return if (self.namespace_colon)
            |namespace_colon| buffer[self.identifier.beg..namespace_colon.index]
            else null;
        }
        
        pub fn name(self: ElementId, buffer: []const u8) []const u8 {
            return if (self.namespace_colon)
            |namespace_colon| buffer[namespace_colon.index + 1..self.identifier.end]
            else self.identifier.slice(buffer);
        }
    };
    
    pub const Attribute = struct {
        parent: ElementId,
        name: Range,
        val: Range,
        pub fn slice(self: Attribute, buffer: []const u8) []const u8 {
            return buffer[self.name.beg..self.val.end];
        }
        
        pub fn value(self: Attribute, buffer: []const u8) []const u8 {
            const buffer_slice = self.val.slice(buffer);
            const beg = 1;
            const end = buffer_slice.len - 1;
            return buffer_slice[beg..end];
        }
    };
    
    pub const CharData = struct {
        range: Range,
        pub fn data(self: CharData, buffer: []const u8) []const u8 {
            const slice = self.range.slice(buffer);
            const beg = "<![CDATA[".len;
            const end = self.range.end - "]]>".len;
            return slice[beg..end];
        }
    };
    
    pub const Comment = struct {
        range: Range,
        pub fn data(self: Comment, xml_text: []const u8) []const u8 {
            const beg = self.range.beg + "<!--".len;
            const end = self.range.end - "-->".len;
            return xml_text[beg..end];
        }
    };
    
    pub const ProcessingInstructions = struct {
        target: Range,
        instructions: Range,
        pub fn slice(self: ProcessingInstructions, buffer: []const u8) []const u8 {
            const beg = self.target.beg - "<?".len;
            const end = self.instructions.end + "?>".len;
            return buffer[beg..end];
        }
    };
    
};

pub const TokenStream = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const ParseState = union(enum) {
        start,
        start_whitespace,
        left_angle_bracket,
        element_name_start_char: ElementNameStartChar,
        inside_element_open: InsideElementOpen,
        found_right_angle_bracket,
        right_angle_bracket: RightAngleBracket,
        left_angle_bracket_fwd_slash,
        close_element_name_start_char: ElementNameStartChar,
        close_element_name_end_char,
        found_adhoc_markup,
        found_adhoc_markup_dash,
        inside_comment: InsideComment,
        left_angle_bracket_qmark,
        pi_target_name_start_char: Index,
        pi_target_name_end_char: PITargetNameEndChar,
        eof,
        
        pub const ElementNameStartChar = struct {
            start: Index,
            colon: ?Index,
        };
        
        pub const InsideElementOpen = struct {
            el_id: Token.ElementId,
            state: State,
            
            pub const State = union(enum) {
                whitespace,
                attribute_name_start_char: Index,
                attribute_seek_eql: AttributeNameCache,
                attribute_eql: AttributeNameCache,
                attribute_value_start_quote: AttributeNameValueCache,
                attribute_value_end_quote,
                forward_slash,
                pub const AttributeNameCache = Range;
                pub const AttributeNameValueCache = struct {
                    name: Range,
                    value_start: Index,
                };
            };
            
        };
        
        pub const RightAngleBracket = struct {
            start: Index,
            non_whitespace_chars: bool,
        };
        
        pub const InsideComment = struct {
            start: usize,
            state: State,
            
            pub const State = enum {
                seek_dash,
                found_dash1,
                found_dash2,
            };
        };
        
        pub const PITargetNameEndChar = struct {
            target: Range,
            state: State,
            
            pub const State = enum {
                seek_qm,
                in_string,
                found_qm,
            };
        };
        
    };
    
    pub fn reset(self: *TokenStream, new_buffer: ?[]const u8) Token {
        self.parse_state = .start;
        self.index = 0;
        self.buffer = new_buffer orelse self.buffer;
        return .bof;
    }
    
    pub fn next(self: *TokenStream) Token {
        var result: Token = .{ .invalid = .{ .index = self.index } };
        
        const on_start = .{ .index = self.index };
        defer std.debug.assert( self.index >= on_start.index );
        
        mainloop: while (self.index < self.buffer.len)
        : ({
            // This is to ensure that there is never a state invariant where the result has been changed but not returned.
            std.debug.assert(result.invalid.index == on_start.index);
        }) {
            const current_char = self.buffer[self.index];
            switch (self.parse_state) {
                .start
                => switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    => {
                        self.parse_state = .start_whitespace;
                        self.index += 1;
                    },
                    
                    '<',
                    => {
                        self.parse_state = .left_angle_bracket;
                        self.index += 1;
                    },
                    
                    else
                    => {
                        break :mainloop;
                    },
                },
                
                .start_whitespace
                => switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    => self.index += 1,
                    
                    '<',
                    => {
                        self.parse_state = .left_angle_bracket;
                        result = .{ .empty_whitespace = .{ .beg = 0, .end = self.index } };
                        self.index += 1;
                        break :mainloop;
                    },
                    
                    else
                    => break :mainloop,
                },
                
                .left_angle_bracket
                => switch (current_char) {
                    '!',
                    => {
                        self.parse_state = .found_adhoc_markup;
                        self.index += 1;
                    },
                    
                    '?',
                    => {
                        self.parse_state = .left_angle_bracket_qmark;
                        self.index += 1;
                    },
                    
                    '/',
                    => {
                        self.parse_state = .left_angle_bracket_fwd_slash;
                        self.index += 1;
                    },
                    
                    else
                    => {
                        const current_utf8_cp = blk: {
                            const opt_blk_out = self.currentUtf8Codepoint();
                            if (opt_blk_out == null or !isValidXmlNameStartCharUtf8(opt_blk_out.?))
                                break :mainloop;
                            break :blk opt_blk_out.?;
                        };
                        
                        self.parse_state = .{ .element_name_start_char = .{
                            .start = .{ .index = self.index },
                            .colon = null,
                        } };
                        
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .element_name_start_char
                => |element_name_start_char| switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    '/',
                    => {
                        result = .{ .element_open = .{
                            .namespace_colon = element_name_start_char.colon,
                            .identifier = .{ .beg = element_name_start_char.start.index, .end = self.index },
                        } };
                        
                        self.parse_state = .{ .inside_element_open = .{
                            .el_id = result.element_open,
                            .state = if (current_char == '/') .forward_slash else .whitespace,
                        } };
                        
                        self.index += 1;
                        break :mainloop;
                    },
                    
                    '>',
                    => {
                        result = .{ .element_open = .{
                            .namespace_colon = element_name_start_char.colon,
                            .identifier = .{ .beg = element_name_start_char.start.index, .end = self.index },
                        } };
                        
                        self.parse_state = .found_right_angle_bracket;
                        break :mainloop;
                    },
                    
                    ':',
                    => {
                        self.parse_state = .{ .element_name_start_char = .{
                            .start = element_name_start_char.start,
                            .colon = .{ .index = self.index },
                        } };
                        self.index += 1;
                    },
                    
                    else
                    => {
                        const current_utf8_cp = blk: {
                            const opt_blk_out = self.currentUtf8Codepoint();
                            if (opt_blk_out == null or !isValidXmlNameCharUtf8(opt_blk_out.?))
                                break :mainloop;
                            break :blk opt_blk_out.?;
                        };
                        
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .inside_element_open
                => |inside_element_open| switch (inside_element_open.state) {
                    .whitespace
                    => switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => self.index += 1,
                        
                        '>',
                        => {
                            self.parse_state = .found_right_angle_bracket;
                        },
                        
                        '/',
                        => {
                            self.parse_state.inside_element_open.state = .forward_slash;
                            self.index += 1;
                        },
                        
                        else
                        => {
                            const current_utf8_cp = blk: {
                                const opt_blk_out = self.currentUtf8Codepoint();
                                if (opt_blk_out == null or !isValidXmlNameStartCharUtf8(opt_blk_out.?))
                                    break :mainloop;
                                break :blk opt_blk_out.?;
                            };
                            
                            self.parse_state.inside_element_open.state = .{ .attribute_name_start_char = .{ .index = self.index, } };
                            
                            self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                        },
                    },
                    
                    .attribute_name_start_char
                    => |attribute_name_start_char| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        '=',
                        => self.parse_state.inside_element_open.state = .{ .attribute_seek_eql = .{
                                .beg = attribute_name_start_char.index,
                                .end = self.index
                        } },
                        
                        // This is required to properly tokenize cases like 'xml:<name>' and 'xmlns:<namespace name>'
                        ':',
                        => self.index += 1,
                        
                        else
                        => {
                            const current_utf8_cp = blk: {
                                const opt_blk_out = self.currentUtf8Codepoint();
                                if (opt_blk_out == null or !isValidXmlNameCharUtf8(opt_blk_out.?))
                                    break :mainloop;
                                break :blk opt_blk_out.?;
                            };
                            
                            self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                        },
                    },
                    
                    .attribute_seek_eql
                    => |attribute_seek_eql| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => self.index += 1,
                        
                        '=',
                        => {
                            self.parse_state.inside_element_open.state = .{ .attribute_eql = attribute_seek_eql };
                            self.index += 1;
                        },
                        
                        else
                        => break :mainloop,
                    },
                    
                    .attribute_eql
                    => |attribute_eql| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => self.index += 1,
                        
                        '"',
                        => {
                            self.parse_state.inside_element_open.state = .{ .attribute_value_start_quote = .{
                                .name = attribute_eql,
                                .value_start = .{ .index = self.index },
                            } };
                            self.index += 1;
                        },
                        
                        else
                        => break :mainloop,
                    },
                    
                    .attribute_value_start_quote
                    => |attribute_value_start_quote| switch (current_char) {
                        '"',
                        => {
                            self.index += 1;
                            self.parse_state.inside_element_open.state = .attribute_value_end_quote;
                            
                            result = .{ .attribute = .{
                                .parent = inside_element_open.el_id,
                                .name = attribute_value_start_quote.name,
                                .val = .{
                                    .beg = attribute_value_start_quote.value_start.index,
                                    .end = self.index,
                                },
                            } };
                            
                            break :mainloop;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .attribute_value_end_quote
                    => switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => {
                            self.parse_state.inside_element_open.state = .whitespace;
                            self.index += 1;
                        },
                        
                        '>',
                        => self.parse_state = .found_right_angle_bracket,
                        
                        '/',
                        => {
                            self.parse_state.inside_element_open.state = .forward_slash;
                            self.index += 1;
                        },
                        
                        else
                        => break :mainloop,
                    },
                    
                    .forward_slash
                    => switch (current_char) {
                        '>',
                        => {
                            result = .{ .element_close = inside_element_open.el_id };
                            self.parse_state = .found_right_angle_bracket;
                            break :mainloop;
                        },
                        
                        else
                        => break :mainloop,
                    },
                },
                
                .left_angle_bracket_fwd_slash
                => {
                    const current_utf8_cp = blk: {
                        const opt_blk_out = self.currentUtf8Codepoint();
                        if (opt_blk_out == null or !isValidXmlNameStartCharUtf8(opt_blk_out.?))
                            break :mainloop;
                        break :blk opt_blk_out.?;
                    };
                    
                    self.parse_state = .{ .close_element_name_start_char = .{
                        .start = .{ .index = self.index },
                        .colon = null,
                    } };
                    
                    self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                },
                
                .close_element_name_start_char
                => |close_element_name_start_char| switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    '>',
                    => {
                        result = .{ .element_close = .{
                            .namespace_colon = close_element_name_start_char.colon,
                            .identifier = .{
                                .beg = close_element_name_start_char.start.index,
                                .end = self.index,
                            }
                        } };
                        self.parse_state = .close_element_name_end_char;
                        
                        if (current_char == '>' and self.index == self.buffer.len) {
                            self.parse_state = .eof;
                            result = .eof;
                            break :mainloop;
                        }
                        
                        break :mainloop;
                    },
                    
                    ':',
                    => {
                        self.parse_state.close_element_name_start_char.colon = .{ .index = self.index };
                        self.index += 1;
                    },
                    
                    else
                    => {
                        const current_utf8_cp = blk: {
                            const opt_blk_out = self.currentUtf8Codepoint();
                            if (opt_blk_out == null or !isValidXmlNameCharUtf8(opt_blk_out.?))
                                break :mainloop;
                            break :blk opt_blk_out.?;
                        };
                        
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .close_element_name_end_char
                => switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    => self.index += 1,
                    
                    '>',
                    => self.parse_state = .found_right_angle_bracket,
                    
                    else
                    => break :mainloop,
                },
                
                .right_angle_bracket
                => |right_angle_bracket| {
                    const range = Range {
                        .beg = right_angle_bracket.start.index,
                        .end = self.index,
                    };
                    
                    switch (current_char) {
                        '<',
                        => {
                            const end_of_file_condition = self.index == self.buffer.len;
                            const at_least_whitespace_found = self.index != right_angle_bracket.start.index;
                            
                            if (at_least_whitespace_found) {
                                result =
                                if (right_angle_bracket.non_whitespace_chars) .{ .text = range, }
                                else .{ .empty_whitespace = range };
                            }
                            
                            self.parse_state = .left_angle_bracket;
                            self.index += 1;
                            
                            if (end_of_file_condition) {
                                result = .{ .invalid = .{ .index = self.index } };
                            }
                            
                            if (at_least_whitespace_found or end_of_file_condition) {
                                break :mainloop;
                            }
                        },
                        
                        ' ', '\t', '\n', '\r',
                        => {
                            self.index += 1;
                            if (self.index == self.buffer.len) {
                                result = .eof;
                                break :mainloop;
                            }
                        },
                        
                        else
                        => {
                            self.parse_state.right_angle_bracket.non_whitespace_chars = true;
                            self.index += 1;
                            if (self.index == self.buffer.len) {
                                result = .eof;
                                break :mainloop;
                            }
                        },
                    }
                    
                },
                
                .found_adhoc_markup
                => switch (current_char) {
                    '-',
                    => {
                        self.parse_state = .found_adhoc_markup_dash;
                        self.index += 1;
                    },
                    
                    '[',
                    => unreachable,
                    
                    'D',
                    => unreachable,
                    
                    'E',
                    => unreachable,
                    
                    'A',
                    => unreachable,
                    
                    else
                    => break :mainloop,
                },
                
                .found_adhoc_markup_dash
                => switch (current_char) {
                    '-',
                    => {
                        self.index += 1;
                        self.parse_state = .{ .inside_comment = .{
                            .start = self.index - ("<!--".len),
                            .state = .seek_dash,
                        } };
                    },
                    
                    else
                    => break :mainloop,
                },
                
                .inside_comment
                => |inside_comment| switch (inside_comment.state) {
                    .seek_dash,
                    => switch (current_char) {
                        '-',
                        => {
                            self.parse_state.inside_comment.state = .found_dash1;
                            self.index += 1;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .found_dash1,
                    => switch (current_char) {
                        '-',
                        => {
                            self.parse_state.inside_comment.state = .found_dash2;
                            self.index += 1;
                        },
                        
                        else
                        => {
                            self.parse_state.inside_comment.state = .seek_dash;
                            self.index += 1;
                        }
                    },
                    
                    .found_dash2,
                    => switch (current_char) {
                        '>',
                        => {
                            self.parse_state = .found_right_angle_bracket;
                            result = .{ .comment = .{ .range = .{ .beg = inside_comment.start, .end = self.index + 1 } } };
                            break :mainloop;
                        },
                        
                        else
                        => break :mainloop,
                    },
                },
                
                .found_right_angle_bracket
                => {
                    self.index += 1;
                    self.parse_state = .{ .right_angle_bracket = .{
                        .start = .{ .index = self.index },
                        .non_whitespace_chars = false,
                    } };
                    
                    if (self.index == self.buffer.len) {
                        result = .eof;
                        break :mainloop;
                    }
                },
                
                .left_angle_bracket_qmark
                => {
                    const current_utf8_cp = blk: {
                        const opt_blk_out = self.currentUtf8Codepoint();
                        if (opt_blk_out == null or !isValidXmlNameStartCharUtf8(opt_blk_out.?))
                            break :mainloop;
                        break :blk opt_blk_out.?;
                    };
                    
                    self.parse_state = .{ .pi_target_name_start_char = .{ .index = self.index } };
                    self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                },
                
                .pi_target_name_start_char
                => |pi_target_name_start_char| switch (current_char) {
                    ' ', '\t', '\n', '\r', '?',
                    => {
                        self.parse_state = .{ .pi_target_name_end_char = .{
                            .target = .{ .beg = pi_target_name_start_char.index, .end = self.index },
                            .state = if (current_char == '?') .found_qm else .seek_qm,
                        } };
                        self.index += 1;
                    },
                    
                    else
                    => {
                        const current_utf8_cp = blk: {
                            const opt_blk_out = self.currentUtf8Codepoint();
                            if (opt_blk_out == null or !isValidXmlNameCharUtf8(opt_blk_out.?))
                                break :mainloop;
                            break :blk opt_blk_out.?;
                        };
                        
                        self.index += std.unicode.utf8CodepointSequenceLength(current_utf8_cp) catch unreachable;
                    },
                },
                
                .pi_target_name_end_char
                => |pi_target_name_end_char| switch (pi_target_name_end_char.state) {
                    .seek_qm,
                    => switch (current_char) {
                        '"',
                        => {
                            self.parse_state.pi_target_name_end_char.state = .in_string;
                            self.index += 1;
                        },
                        
                        '?',
                        => {
                            self.parse_state.pi_target_name_end_char.state = .found_qm;
                            self.index += 1;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .in_string
                    => switch (current_char) {
                        '"',
                        => {
                            self.parse_state.pi_target_name_end_char.state = .seek_qm;
                            self.index += 1;
                        },
                        
                        else
                        => {
                            self.index += 1;
                        },
                    },
                    
                    .found_qm
                    => switch (current_char) {
                        '>',
                        => {
                            result = .{ .processing_instructions = .{
                                .target = pi_target_name_end_char.target,
                                .instructions = .{ .beg = pi_target_name_end_char.target.end + 1, .end = self.index - 1 },
                            } };
                            
                            self.parse_state = .found_right_angle_bracket;
                            break :mainloop;
                        },
                        
                        else
                        => {
                            break :mainloop;
                        },
                    },
                },
                
                .eof
                => unreachable,
            }
        }
        
        if (result == .invalid and self.index < self.buffer.len) {
            result.invalid.index = self.index;
        }
        
        return result;
        
    }
    
    fn currentUtf8Codepoint(self: TokenStream) ?u21 {
        const utf8_cp_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.index]) catch return null;
        if (self.index + utf8_cp_len > self.buffer.len) return null;
        return std.unicode.utf8Decode(self.buffer[self.index..self.index + utf8_cp_len]) catch null;
    }
    
};

pub fn isValidXmlNameStartCharUtf8(char: u21) bool {
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

pub fn isValidXmlNameCharUtf8(char: u21) bool {
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

test "T0" {
    std.debug.print("\n", .{});
    const xml_text = 
        \\<book>
        // not well formed, since the namespace declaration for 'test' doesn't exist;
        // this is just to make sure that namespaces are captured correctly.
        \\    <test:extra discount = "20%"/>
        \\    <title lang="en" lang2= "ge" >Learning XML</title >
        \\    <author>Erik T. Ray</author>
        \\</book>
    ;
    
    var tokenizer = TokenStream { .buffer = xml_text };
    var current: Token = .bof;
    
    current = tokenizer.next();
    try expectEqualElementOpen(xml_text, current, null, "book");
        
        
        
        current = tokenizer.next();
        try expectEqualEmptyWhitespace(xml_text, current, "\n    ");
        
        
        
        current = tokenizer.next();
        try expectEqualElementOpen(xml_text, current, "test", "extra");
        
            current = tokenizer.next();
            try expectEqualAttribute(xml_text, current, .{ .namespace = "test", .name = "extra" }, .{ .name = "discount", .eql = " = ", .val = "20%" });
            
        current = tokenizer.next();
        try expectEqualElementClose(xml_text, current, "test", "extra");
        
        
        
        current = tokenizer.next();
        try expectEqualEmptyWhitespace(xml_text, current, "\n    ");
        
        
        
        current = tokenizer.next();
        try expectEqualElementOpen(xml_text, current, null, "title");
            
            current = tokenizer.next();
            try expectEqualAttribute(xml_text, current, .{ .namespace = null, .name = "title" }, .{ .name = "lang", .eql = "=", .val = "en" });
            
            current = tokenizer.next();
            try expectEqualAttribute(xml_text, current, .{ .namespace = null, .name = "title" }, .{ .name = "lang2", .eql = "= ", .val = "ge" });
            
            current = tokenizer.next();
            try expectEqualText(xml_text, current, "Learning XML");
            
        current = tokenizer.next();
        try expectEqualElementClose(xml_text, current, null, "title");
        
        
        
        current = tokenizer.next();
        try expectEqualEmptyWhitespace(xml_text, current, "\n    ");
        
        
        
        current = tokenizer.next();
        try expectEqualElementOpen(xml_text, current, null, "author");
            
            current = tokenizer.next();
            try expectEqualText(xml_text, current, "Erik T. Ray");
            
        current = tokenizer.next();
        try expectEqualElementClose(xml_text, current, null, "author");
        
        
        
        current = tokenizer.next();
        try expectEqualEmptyWhitespace(xml_text, current, "\n");
        
        
        
    current = tokenizer.next();
    try expectEqualElementClose(xml_text, current, null, "book");
    
    current = tokenizer.next();
    try testing.expect(current == .eof);
    
    current = tokenizer.next();
    try testing.expect(current == .invalid);
    
}

test "Empty Element with attributes" {
    const xml_text =
        \\<book title="Don Quijote" author="Miguel Cervantes"/>
    ;
    
    var tokenizer = TokenStream { .buffer = xml_text };
    var current: Token = .bof;
    
    current = tokenizer.next();
    try expectEqualElementOpen(xml_text, current, null, "book");
    
    current = tokenizer.next();
    try expectEqualAttribute(xml_text, current, .{ .namespace = null, .name = "book" }, .{ .name = "title", .eql = "=", .val = "Don Quijote" });
    
    current = tokenizer.next();
    try expectEqualAttribute(xml_text, current, .{ .namespace = null, .name = "book" }, .{ .name = "author", .eql = "=", .val = "Miguel Cervantes" });
    
    current = tokenizer.next();
    try expectEqualElementClose(xml_text, current, null, "book");
    
    current = tokenizer.next();
    try testing.expect(current == .eof);
    
    current = tokenizer.next();
    try testing.expect(current == .invalid);
    
}

test "Tag Whitespace Variants" {
    const xml_text =
        \\<person/>
        \\<person />
        \\<person></person>
        \\<person ></person >
        \\<person></person >
        \\<person ></person>

        \\<person id="0"/>
        \\<person id ="0"/>
        \\<person id= "0"/>
        \\<person id = "0"/>

        \\<person id="0" />
        \\<person id ="0" />
        \\<person id= "0" />
        \\<person id = "0" />

        \\<person id="0"></person>
        \\<person id ="0"></person>
        \\<person id= "0"></person>
        \\<person id = "0"></person>

        \\<person id="0" ></person>
        \\<person id ="0" ></person>
        \\<person id= "0" ></person>
        \\<person id = "0" ></person>

        \\<person id="0"></person >
        \\<person id ="0"></person >
        \\<person id= "0"></person >
        \\<person id = "0"></person >

        \\<person id="0" ></person >
        \\<person id ="0" ></person >
        \\<person id= "0" ></person >
        \\<person id = "0" ></person >
    ;
    
    const initial_elements_with_no_attributes = 6;
    const element_count = std.mem.count(u8, xml_text, "\n");
    
    var tokenizer = TokenStream { .buffer = xml_text };
    var current: Token = .bof;
    
    
    { // First five elements with no attribute
        var idx: usize = 0;
        errdefer std.debug.print("\nOn iteration {}\n", .{idx});
        
        while (idx < initial_elements_with_no_attributes) : (idx += 1) {
            current = tokenizer.next();
            try expectEqualElementOpen(xml_text, current, null, "person");
            
            current = tokenizer.next();
            try expectEqualElementClose(xml_text, current, null, "person");
            
            current = tokenizer.next();
            try expectEqualEmptyWhitespace(xml_text, current, "\n");
        }
    }
    
    { // All the rest
        var idx: usize = 0;
        errdefer std.debug.print("\nOn iteration {} (after first set)\n", .{idx});
        
        const eql_sign = [_][]const u8 {
            "=",
            " =",
            "= ",
            " = ",
        };
        
        while (idx < (element_count - initial_elements_with_no_attributes)) : (idx += 1) {
            current = tokenizer.next();
            try expectEqualElementOpen(xml_text, current, null, "person");
            
            current = tokenizer.next();
            try expectEqualAttribute(xml_text, current, .{ .namespace = null, .name = "person"}, .{ .name = "id", .eql = eql_sign[idx % 4], .val = "0" });
            
            current = tokenizer.next();
            try expectEqualElementClose(xml_text, current, null, "person");
            
            current = tokenizer.next();
            try expectEqualEmptyWhitespace(xml_text, current, "\n");
        }
    }
    
}

test "Comments" {
    const xml_text = 
        \\<!-- faf -->
        \\<!---->
        \\<!--- -->
    ;
    
    var tokenizer = TokenStream { .buffer = xml_text };
    var current: Token = .bof;
    
    current = tokenizer.next();
    try testing.expect(current == .comment);
    try testing.expectEqualStrings(" faf ", current.comment.data(xml_text));
    
    current = tokenizer.next();
    try expectEqualEmptyWhitespace(xml_text, current, "\n");
    
    current = tokenizer.next();
    try testing.expect(current == .comment);
    try testing.expectEqualStrings("", current.comment.data(xml_text));
    
    current = tokenizer.next();
    try expectEqualEmptyWhitespace(xml_text, current, "\n");
    
    current = tokenizer.next();
    try testing.expect(current == .comment);
    try testing.expectEqualStrings("- ", current.comment.data(xml_text));
    
    current = tokenizer.next();
    try testing.expect(current == .eof);
    
    current = tokenizer.next();
    try testing.expect(current == .invalid);
    
}

test "Processing Instructions" {
    const xml_text = 
        \\<?faf ""?>
        \\<?did moob?>
        \\<?xml encoding="UTF-8"?>
    ;
    
    var tokenizer = TokenStream { .buffer = xml_text };
    var current: Token = .bof;
    
    current = tokenizer.next();
    try expectEqualProcessingInstructions(xml_text, current, "faf", "\"\"");
    
    current = tokenizer.next();
    try expectEqualEmptyWhitespace(xml_text, current, "\n");
    
    current = tokenizer.next();
    try expectEqualProcessingInstructions(xml_text, current, "did", "moob");
    
    current = tokenizer.next();
    try expectEqualEmptyWhitespace(xml_text, current, "\n");
    
    current = tokenizer.next();
    try expectEqualProcessingInstructions(xml_text, current, "xml", "encoding=\"UTF-8\"");
    
    current = tokenizer.next();
    try testing.expect(current == .eof);
    
    current = tokenizer.next();
    try testing.expect(current == .invalid);
}

fn expectEqualElementIdNamespace(
    xml_text: []const u8,
    el_id: Token.ElementId,
    expect_opt_namespace: ?[]const u8,
) !void {
    const got_opt_namespace = el_id.namespace(xml_text);
    
    if (expect_opt_namespace) |expect_namespace| {
        // Either both or neither must be null for succeeding the test.
        try testing.expect(got_opt_namespace != null);
        
        const got_namespace = got_opt_namespace.?;
        try testing.expectEqualStrings(expect_namespace, got_namespace);
    } else {
        // Either both or neither must be null for succeeding the test.
        try testing.expect(got_opt_namespace == null);
    }
}

fn expectEqualElementIdName(
    xml_text: []const u8, 
    el_id: Token.ElementId, 
    expect_name: []const u8,
) !void {
    const got_name = el_id.name(xml_text);
    try testing.expectEqualStrings(expect_name, got_name);
}

fn expectEqualElementIdIdentifier(
    xml_text: []const u8,
    el_id: Token.ElementId,
    expect_opt_namespace: ?[]const u8,
    expect_name: []const u8,
) !void {
    try expectEqualElementIdNamespace(xml_text, el_id, expect_opt_namespace);
    try expectEqualElementIdName(xml_text, el_id, expect_name);
    
    const expect_identifier
    = if (expect_opt_namespace) |ns| try std.mem.join(testing.allocator, ":", &.{ns, expect_name})
    else expect_name;
    
    defer if (expect_opt_namespace != null) testing.allocator.free(expect_identifier);
    
    try testing.expectEqualStrings(expect_identifier, el_id.identifier.slice(xml_text));
}



fn expectEqualElementOpen(
    xml_text: []const u8,
    tok: Token,
    expect_opt_namespace: ?[]const u8,
    expect_name: []const u8,
) !void {
    try testing.expect(tok == .element_open);
    const el_id = tok.element_open;
    
    try expectEqualElementIdIdentifier(xml_text, el_id, expect_opt_namespace, expect_name);
}

fn expectEqualText(
    xml_text: []const u8,
    tok: Token,
    text: []const u8
) !void {
    try testing.expect(tok == .text);
    try testing.expectEqualStrings(text, tok.text.slice(xml_text));
}

fn expectEqualEmptyWhitespace(
    xml_text: []const u8,
    tok: Token,
    expect_whitespace: []const u8,
) !void {
    for (expect_whitespace) |char| {
        // `expectEqualEmptyWhitespace` expects whitespace characters only.
        std.debug.assert(switch (char) {
            ' ', '\t', '\n', '\r', => true,
            else                   => false,
        });
    }
    
    try testing.expect(tok == .empty_whitespace);
    const got_whitespace = tok.empty_whitespace.slice(xml_text);
    
    try testing.expectEqualStrings(expect_whitespace, got_whitespace);
}

fn expectEqualElementClose(
    xml_text: []const u8,
    tok: Token,
    expect_opt_namespace: ?[]const u8,
    expect_name: []const u8
) !void {
    try testing.expect(tok == .element_close);
    const el_id = tok.element_close;
    
    try expectEqualElementIdIdentifier(xml_text, el_id, expect_opt_namespace, expect_name);
}

fn expectEqualAttributeParent(
    xml_text: []const u8,
    attr: Token.Attribute,
    expect_opt_namespace: ?[]const u8,
    expect_name: []const u8,
) !void {
    try expectEqualElementIdIdentifier(xml_text, attr.parent, expect_opt_namespace, expect_name);
}

fn expectEqualAttributeName(
    xml_text: []const u8,
    attr: Token.Attribute,
    expect_name: []const u8,
) !void {
    try testing.expectEqualStrings(expect_name, attr.name.slice(xml_text));
}

fn expectEqualAttributeValue(
    xml_text: []const u8,
    attr: Token.Attribute,
    expect_value: []const u8,
) !void {
    const expect_value_with_quotes = try std.mem.join(testing.allocator, "", &.{ "\"", expect_value, "\"" });
    defer testing.allocator.free(expect_value_with_quotes);
    
    const got_value = attr.value(xml_text);
    const got_value_with_quotes = attr.val.slice(xml_text);
    
    try testing.expectEqualStrings(expect_value,             got_value);
    try testing.expectEqualStrings(expect_value_with_quotes, got_value_with_quotes);
}

fn expectEqualAttribute(
    xml_text: []const u8,
    tok: Token,
    expect_parent: struct {
        namespace: ?[]const u8,
        name: []const u8
    },
    expect_name_value_pair: struct {
        name: []const u8,
        eql: []const u8, // e.g. ` = `, `= `, ` =`, etc.
        val: []const u8,
    },
) !void {
    try testing.expect(tok == .attribute);
    const attr = tok.attribute;
    try expectEqualAttributeParent(xml_text, attr, expect_parent.namespace, expect_parent.name);
    try expectEqualAttributeName(xml_text, attr, expect_name_value_pair.name);
    try expectEqualAttributeValue(xml_text, attr, expect_name_value_pair.val);
    
    const got_eql: []const u8 = blk: {
        const beg = attr.name.end;
        const end = attr.val.beg;
        break :blk xml_text[beg..end];
    };
    
    try testing.expectEqualStrings(expect_name_value_pair.eql, got_eql);
}

fn expectEqualProcessingInstructions(
    xml_text: []const u8,
    tok: Token,
    expect_target: []const u8,
    expect_instructions: []const u8,
) !void {
    try testing.expect(tok == .processing_instructions);
    const pi_instructions = tok.processing_instructions;
    
    const got_target = pi_instructions.target.slice(xml_text);
    const got_instructions = pi_instructions.instructions.slice(xml_text);
    const got_slice = pi_instructions.slice(xml_text);
    
    try testing.expectEqualStrings(expect_target, got_target);
    try testing.expectEqualStrings(expect_instructions, got_instructions);
    
    const expect_slice = try std.mem.join(testing.allocator, "", &.{ "<?", got_target, " ", got_instructions, "?>" });
    defer testing.allocator.free(expect_slice);
    
    try testing.expectEqualStrings(expect_slice, got_slice);
}
