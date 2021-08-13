const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const Token = union(enum) {
        invalid: Index,
        bof,
        eof,
        
        element_begin: ElementOpen,
        element_close: ElementClose,
        text: Text,
        comment: Comment,
        processing_instructions: ProcessingInstructions,
        
        pub const ElementOpen = union(enum) {
            identifier: Identifier,
            attribute: Attribute,
            
            pub const Identifier = struct {
                namespace: Range,
                name: Range,
            };
            
            pub const Attribute = struct {
                name: Range,
                value: Range,
            };
            
        };
        
        pub const ElementClose = struct {
            identifier: Range,
        };
        
        pub const Text = union(enum) {
            plain: Range,
            char_data: Range,
            empty_whitespace: Range,
        };
        
        pub const Comment = Range;
        
        pub const ProcessingInstructions = union(enum) {
            target: Range,
            instructions: Range,
        };
        
        pub const Index = struct { index: usize, };
        pub const Range = struct {
            beg: usize,
            end: usize,
            
            pub fn slice(self: Range, buffer: []const u8) []const u8 {
                return buffer[self.beg..self.end];
            }
        };
    };
    
    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{ .invalid = .{ .index = self.index } };
        
        while (self.index < self.buffer.len) {
            const current_char = self.buffer[self.index];
            switch (self.parse_state) {
                .start
                => switch (current_char) {
                    '<',
                    => {
                        self.parse_state = .tag_open;
                        self.index += 1;
                    },
                    
                    ' ', '\t', '\n', '\r',
                    => {
                        self.index += 1;
                    },
                    
                    else
                    => {
                        result = .{ .invalid = .{ .index = self.index } };
                        break;
                    },
                },
                
                .tag_pi_open
                => unreachable,
                
                .tag_open
                => switch (current_char) {
                    '?',
                    => {
                        self.parse_state = .tag_pi_open;
                        self.index += 1;
                        result = .{ .processing_instructions = .{ .target = .{
                            .beg = self.index,
                            .end = undefined,
                        } } };
                    },
                    
                    '!',
                    => unreachable,
                    
                    '/',
                    => unreachable,
                    
                    ':', // Making one exception here to what the W3C Recommendation says, since it seems like the convention is to not accept it as the first character.
                    => unreachable,
                    
                    else
                    => {
                        self.parse_state = .{ .tag_element_open = .check_valid_start_char };
                    },
                    
                },
                
                .tag_element_open
                => |*tag_element_open| switch (tag_element_open.*) {
                    .check_valid_start_char
                    => {
                        const utf8_cp = self.currentUtf8Codepoint() orelse {
                            result = .{ .invalid = .{ .index = self.index } };
                            break;
                        };
                        
                        if (!isValidXmlNameStartCharUtf8(utf8_cp)) {
                            result = .{ .invalid = .{ .index = self.index } };
                            break;
                        }
                        
                        tag_element_open.* = .{ .seek_element_name_end = .{ .start_index = self.index } };
                        self.index += std.unicode.utf8CodepointSequenceLength(utf8_cp) catch unreachable;
                    },
                    
                    .seek_element_name_end,
                    => |seek_element_name_end| switch (current_char) {
                        ' ', '\t', '\n', '\r',
                        => {
                            tag_element_open.* = .seek_tag_end;
                            result.element_begin.identifier.name.end = self.index;
                            break;
                        },
                        
                        ':',
                        => {
                            result.element_begin.identifier.namespace.end = self.index;
                            self.index += 1;
                            result.element_begin.identifier.name.beg = self.index;
                        },
                        
                        else
                        => {
                            
                            const utf8_cp = self.currentUtf8Codepoint() orelse {
                                result = .{ .invalid = .{ .index = self.index } };
                                break;
                            };
                            
                            if (!isValidXmlNameCharUtf8(utf8_cp)) {
                                result = .{ .invalid = .{ .index = self.index } };
                                break;
                            }
                            
                            self.index += std.unicode.utf8ByteSequenceLength(current_char) catch {
                                result = .{ .invalid = .{ .index = self.index } };
                                break;
                            };
                        },
                    },
                    
                    .seek_tag_end
                    => unreachable,
                },
                
            }
        }
        
        return result;
    }
    
    fn currentUtf8Codepoint(self: Tokenizer) ?u21 {
        const utf8_byte_seq_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.index]) catch return null;
        if (self.index + utf8_byte_seq_len > self.buffer.len) return null;
        const utf8_cp = std.unicode.utf8Decode(self.buffer[self.index..self.index + utf8_byte_seq_len]) catch return null;
        return utf8_cp;
    }
    
    pub const ParseState = union(enum) {
        start,
        tag_open,
        tag_element_open: union(enum) {
            check_valid_start_char,
            seek_element_name_end: struct { start_index: usize },
            seek_tag_end,
        },
        
        tag_pi_open,
    };
    
};

test "T1" {
    const testing = std.testing;
    
    var tokenizer = Tokenizer{
        .buffer = 
        \\<dir:ñañ dof="1.0"
        \\  tin="UTF-8"
        \\>
    };
    
    var current = tokenizer.next();
    try testing.expectEqualStrings("dir", current.element_begin.identifier.namespace.slice(tokenizer.buffer));
    try testing.expectEqualStrings("ñañ", current.element_begin.identifier.name.slice(tokenizer.buffer));
    
    current = tokenizer.next();
    try testing.expectEqualStrings("dof", current.element_begin.attribute.name.slice(tokenizer.buffer));
    try testing.expectEqualStrings("1.0", current.element_begin.attribute.value.slice(tokenizer.buffer));
    
}
