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
                identifier: Range,
            };
            
            pub const Attribute = struct {
                identifier: Range,
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
        
        pub const Range = struct { beg: usize, end: usize };
        pub const Index = struct { index: usize };
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
                        result = .{ .element_begin = .{ .identifier = .{
                            .namespace = .{ .beg = self.index, .end = self.index },
                            .identifier = .{ .beg = self.index, .end = undefined, },
                        } } };
                    },
                    
                },
                
                .tag_element_open
                => |*tag_element_open| switch (tag_element_open.*) {
                    .check_valid_start_char
                    => {
                        switch (current_char) {
                            'A'...'Z',
                            'a'...'z',
                            '\u{C0}'...'\u{D6}',
                            '\u{D8}'...'\u{F6}',
                            '_',
                            => {
                                tag_element_open.* = .seek_element_name_end;
                                self.index += 1;
                            },
                            
                            else
                            => {
                                const utf8_byte_seq_len = std.unicode.utf8ByteSequenceLength(current_char) catch {
                                    if (true) unreachable;
                                    result = .{ .invalid = .{ .index = self.index } };
                                    break;
                                };
                                
                                if (self.index + utf8_byte_seq_len > self.buffer.len) {
                                    if (true) unreachable;
                                    result = .{ .invalid = .{ .index = self.index } };
                                    break;
                                }
                                
                                const utf8_cp = std.unicode.utf8Decode(self.buffer[self.index..self.index + utf8_byte_seq_len]) catch {
                                    if (true) unreachable;
                                    result = .{ .invalid = .{ .index = self.index } };
                                    break;
                                };
                                
                                switch (utf8_cp) {
                                    '\u{F8}'...'\u{2FF}',
                                    '\u{370}'...'\u{37D}',
                                    '\u{37F}'...'\u{1FFF}',
                                    '\u{200C}'...'\u{200D}',
                                    '\u{2070}'...'\u{218F}',
                                    '\u{2C00}'...'\u{2FEF}',
                                    '\u{3001}'...'\u{D7FF}',
                                    '\u{F900}'...'\u{FDCF}',
                                    '\u{FDF0}'...'\u{FFFD}',
                                    '\u{10000}'...'\u{EFFFF}',
                                    => {
                                        tag_element_open.* = .seek_element_name_end;
                                        self.index += utf8_byte_seq_len;
                                    },
                                    
                                    else
                                    => {
                                        if (true) unreachable;
                                        result = .{ .invalid = .{ .index = self.index } };
                                        break;
                                    },
                                }
                                
                            },
                        }
                    },
                    
                    .seek_element_name_end,
                    => unreachable,
                },
                
            }
        }
        
        return result;
    }
    
    pub const ParseState = union(enum) {
        start,
        tag_open,
        tag_element_open: enum {
            check_valid_start_char,
            seek_element_name_end,
        },
        
        tag_pi_open,
    };
    
};

test "T1" {
    var tokenizer = Tokenizer{
        .buffer = 
        \\<faf version="1.0" encoding="UTF-8">
    };
    
    var current = tokenizer.next();
    _ = current;
}
