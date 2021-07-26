const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    
    pub const Token = union(enum) {
        markup: Markup,
        element: Element,
        
        pub const Element = union(enum) {
            begin_open: Index,        // `<`
            begin_close: Index,       // `</`
            end: Index,               // `>`
            end_empty: Index,         // `/>`
            
            identifier: Range,
            eql: Index, // '='
            
            string_begin: Index, // effectively matches `"` or `'`.
            string_end: Index, // effectively matches `"` or `'`.
            entity_reference: Range, // first index matches '&', penultimate index matches ';'.
        };
        
        pub const Index = struct {
            index: usize,
        };
        
        pub const Range = struct {
            beg: usize,
            end: usize,
            
            pub fn sliceFrom(self: Range, slice: []const u8) []const u8 {
                return slice[self.beg..self.end];
            }
            
            pub fn length(self: Range) usize {
                std.debug.assert(self.end >= self.beg);
                return self.end - self.beg;
            }
            
        };
        
    };
    
    pub const ParseState = union(enum) {
        start,
    };
    
};
