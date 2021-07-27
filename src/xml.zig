const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const Token = union(enum) {
        invalid,
        bof,
        eof,
        
        element: Element,
        processing_instruction: ProcessingInstruction,
        char_data: CharData,
        comment: Comment,
        
        pub const Element = union(enum) {
            begin_open: Index,        // `<`
            begin_close: Index,       // `</`
            end: Index,               // `>`
            end_empty: Index,         // `/>`
            
            namespace: Range,
            identifier: Range,
            eql: Index, // '='
            
            string_begin: Index, // effectively matches `"` or `'`.
            string_end: Index, // effectively matches `"` or `'`.
            entity_reference: Range, // first index matches '&', penultimate index matches ';'.
        };
        
        pub const ProcessingInstruction = union(enum) {
            beg: Index, // first index of `<?`
            end: Index, // first index of `?>`
            
            target: Range,
            instructions: Range,
        };
        
        pub const CharData = union(enum) {
            beg: Index, // first index of `<![CDATA[`
            end: Index, // first index of `]]>`
        };
        
        pub const Comment = union(enum) {
            beg: Index, // first index of `<!--`
            end: Index, // first index of `-->`
        };
        
        pub const Index = struct { index: usize };
        pub const Range = struct { beg: usize, end: usize };
    };
    
    pub fn getNext(self: *Tokenizer) Token {
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
        angle_bracket_left,
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
