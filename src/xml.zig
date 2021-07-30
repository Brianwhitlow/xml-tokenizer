const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const Token = union(enum) {
        invalid,
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
        
        pub const ElementClose = union(enum) {
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
        var out = Token .invalid;
        
        while (self.index < self.buffer.len) {
            switch (self.parse_state) {
                .start
                => unreachable,
            }
        }
        
        return out;
    }
    
    pub const ParseState = union(enum) {
        start,
    };
    
};
