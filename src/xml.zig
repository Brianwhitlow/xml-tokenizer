pub const Token = union(enum) {
    invalid: Index,
    bof,
    eof,
    
    element_open_name: ElementName,
    attribute: Attribute,
    element_close,
    element_close_name: ElementName,
    
    comment: Range,
    
    pi_target: Range,
    pi_contents: Range,
    
    text: Text,
    
    pub const ElementName = struct {
        name: Range,
        namespace: Range,
    };
    
    pub const Attribute = struct {
        name: Range,
        value: Range,
    };
    
    pub const Text = union(enum) {
        plain: Range,
        char_data: Range,
        empty_whitespace: Range,
    };
    
    pub const Index = struct { index: usize };
    pub const Range = struct {
        beg: usize,
        end: usize,
        
        pub fn slice(self: Range, buffer: []const u8) []const u8 {
            return buffer[self.beg..self.end];
        }
    };
    
};

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    parse_state: ParseState = .start,
    
    pub const ParseState = union(enum) {
        start,
    };
    
    pub fn next(self: *Tokenizer) Token {
        
        while (self.index < self.buffer.len) {
            const current_char = self.buffer[self.index];
            switch (self.parse_state) {
                .start
                => unreachable,
            }
        }
        
    }
    
};

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
