const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const Token = union(enum) {
        invalid,
        bof,
        eof,
        
        element_start: Index,
        element_name: Range,
        attribute_name: Range,
        attribute_value: Range,
        text: Range,
        char_data: Range,
        element_end: Index,
        
        pub const Index = struct { index: usize };
        pub const Range = struct { beg: usize, end: usize };
    };
    
    pub fn next(self: *Tokenizer) Token {
        var result: Token = .invalid;
        
        while (self.index < self.buffer.len) {
            const current_char = self.buffer[self.index];
            switch (self.parse_state) {
                .start
                => switch (current_char) {
                    ' ', '\t', '\n', '\r',
                    => self.index += 1,
                    
                    '<',
                    => {
                        self.index += 1;
                        self.parse_state = .angle_bracket_left;
                    },
                    
                    else
                    => unreachable,
                },
                
                .angle_bracket_left
                => unreachable,
            }
        }
        
        return result;
    }
    
    pub const ParseState = union(enum) {
        start,
        angle_bracket_left: AngleBracketLeft,
        
        pub const AngleBracketLeft = union(enum) {
            first_encounter,
        };
    };
    
};

test "Declare" {
    var tokenizer = Tokenizer{
        .buffer =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<content >
        \\    <inner att="val"/>
        \\</content>
    };
    
    var current = tokenizer.getNext();
    
}
