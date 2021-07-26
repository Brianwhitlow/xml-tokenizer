const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    
    
    
    pub const Token = union(enum) {
        
        
        pub const Markup = union(enum) {
            element: Element,
            
            pub const Element = union(enum) {
                open_beg: Index,
                open_end_parent: Index,
                open_end_empty: Index,
                
                close_beg: Index,
                close_end: Index,
                
                identifier: Range,
                eql: Index,
                string: Range,
            };
            
        };
        
        pub const Range = struct { beg: usize, end: usize };
        pub const Index = struct { index: usize };
        
    };
    
};
