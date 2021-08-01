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
                range: Range,
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
                
                .tag_open
                => |tag_open| switch (current_char) {
                    '?',
                    => unreachable,
                    
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
        },
    };
    
};

test "T1" {
    var tokenizer = Tokenizer{
        .buffer = 
        \\<?xml version="1.0" encoding="UTF-8"?>
    };
    
    var current = tokenizer.next();
    _ = current;
}
