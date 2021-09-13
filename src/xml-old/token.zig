const std = @import("std");

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
        const Self = @This();
        colon: ?Index,
        identifier: Range,
        
        pub fn slice(self: Self, buffer: []const u8) []const u8 {
            return self.identifier.slice(buffer);
        }
        
        pub fn namespace(self: Self, buffer: []const u8) ?[]const u8 {
            if (self.colon == null)
                return null;
            const beg = self.identifier.beg;
            const end = self.colon.?.index;
            return buffer[beg..end];
        }
        
        pub fn name(self: Self, buffer: []const u8) []const u8 {
            if (self.colon == null)
                return self.identifier.slice(buffer);
            const beg = self.colon.?.index + 1;
            const end = self.identifier.end;
            return buffer[beg..end];
        }
    };
    
    pub const Attribute = struct {
        name: Range,
        val: Range,
        pub fn slice(self: Attribute, buffer: []const u8) []const u8 {
            const beg = self.name.beg;
            const end = self.val.end;
            return buffer[beg..end];
        }
        
        pub fn value(self: Attribute, buffer: []const u8) []const u8 {
            const beg = self.val.beg + 1;
            const end = self.val.end - 1;
            return buffer[beg..end];
        }
    };
    
    pub const CharData = struct {
        const Self = @This();
        range: Range,
        
        pub fn init(beg: usize, end: usize) Self {
            return Self { .range = Range.init(beg, end) };
        }
        
        pub fn data(self: Self, buffer: []const u8) []const u8 {
            const beg = self.range.beg + ("<![CDATA[".len);
            const end = self.range.end - ("]]>".len);
            return buffer[beg..end];
        }
    };
    
    pub const Comment = struct {
        const Self = @This();
        range: Range,
        
        pub fn init(beg: usize, end: usize) Self {
            return Self { .range = Range.init(beg, end) };
        }
        
        pub fn data(self: Comment, buffer: []const u8) []const u8 {
            const beg = self.range.beg + "<!--".len;
            const end = self.range.end - "-->".len;
            return buffer[beg..end];
        }
    };
    
    pub const ProcessingInstructions = struct {
        const Self = @This();
        target: Range,
        instructions: Range,
        
        pub fn slice(self: Self, buffer: []const u8) []const u8 {
            const beg = self.target.beg - "<?".len;
            const end = self.instructions.end + "?>".len;
            return buffer[beg..end];
        }
    };
};

pub const Index = struct {
    index: usize,
    
    pub fn init(value: usize) Index {
        return .{ .index = value };
    }
};

pub const Range = struct {
    beg: usize,
    end: usize,
    
    pub fn init(beg: usize, end: usize) Range {
        return .{
            .beg = beg,
            .end = end
        };
    }
    
    pub fn slice(self: Range, buffer: []const u8) []const u8 {
        return buffer[self.beg..self.end];
    }
    
    pub fn length(self: Range) usize {
        std.debug.assert(self.beg <= self.end);
        return self.end - self.beg;
    }
};
