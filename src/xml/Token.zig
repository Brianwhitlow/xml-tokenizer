const std = @import("std");
const debug = std.debug;

const Token = @This();
index: usize,
info: Info,

pub fn init(index: usize, info: Info) Token {
    return Token {
        .index = index,
        .info = info,
    };
}

pub fn initTag(index: usize, comptime tag: std.meta.Tag(Info), value: std.meta.TagPayload(Info, tag)) Token {
    return Token.init(index, @unionInit(Info, @tagName(tag), value));
}

pub fn slice(self: Token, src: []const u8) []const u8 {
    return self.info.slice(self.index, src);
}

pub const Info = union(enum) {
    element_open: ElementOpen,
    element_close_tag: ElementCloseTag,
    element_close_inline: ElementCloseInline,
    
    attribute_name: AttributeName,
    attribute_value_segment: AttributeValueSegment,
    
    comment: Comment,
    cdata: CharDataSection,
    text: Length,
    entity_reference: EntityReference,
    whitespace: Length,
    
    pi_target: ProcessingInstructionsTarget,
    pi_token: ProcessingInstructionsToken,
    
    
    
    // Assert that all variants of Union have a `slice` method
    fn allVariantsHaveSliceFunc(comptime Union: type) bool {
        inline for (std.meta.fields(Union)) |field_info| {
            const FieldType = field_info.field_type;
            return @hasDecl(FieldType, "slice") and switch (@TypeOf(@field(FieldType, "slice"))) {
                fn (FieldType, usize, []const u8) []const u8,
                fn (FieldType, usize, []const u8) ?[]const u8,
                => true,
                else => false,
            };
        }
    }
    
    comptime {
        std.debug.assert(allVariantsHaveSliceFunc(@This()));
    }
    
    
    
    pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
        inline for (comptime std.meta.fieldNames(Info)) |field_name| {
            if (@field(Info, field_name) == self) {
                return @field(self, field_name).slice(index, src);
            }
        }
        
        unreachable;
    }
    
    pub const ElementOpen = struct {
        prefix_len: usize, // slice[prefix_len] == ':' if prefix_len != 0
        full_len: usize,
        
        /// Returns a slice matching the following pseudo-REGEX:
        /// `<` `({0}:)?` `{1}`
        /// Where:
        /// * 0 is prefix, obtainable through through the `prefix` method.
        /// * 1 is name, obtainable through the `name` method.
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + self.full_len;
            return src[beg..end];
        }
        
        pub fn prefix(self: @This(), index: usize, src: []const u8) ?[]const u8 {
            const sliced = self.slice(index, src);
            const beg = ("<".len);
            const end = beg + self.prefix_len;
            return if (self.prefix_len != 0) sliced[beg..end] else null;
        }
        
        pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = ("<").len + if (self.prefix_len == 0) 0 else (self.prefix_len + 1);
            return sliced[beg..];
        }
    };
    
    pub const ElementCloseTag = struct {
        prefix_len: usize, // slice[prefix_len] == ':' if prefix_len != 0
        identifier_len: usize,
        full_len: usize,
        
        /// Returns a slice matching the following pseudo-REGEX:
        /// `</` `({0}:)?` `{1}` `{S}?` `>`
        /// Where:
        /// * 0 is prefix, obtainable through through the `prefix` method.
        /// * 1 is name, obtainable through the `name` method.
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + self.full_len;
            return src[beg..end];
        }
        
        pub fn prefix(self: @This(), index: usize, src: []const u8) ?[]const u8 {
            const sliced = self.slice(index, src);
            const beg = ("</".len);
            const end = beg + self.prefix_len;
            return if (self.prefix_len != 0) sliced[beg..end] else null;
        }
        
        pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = ("</".len) + if (self.prefix_len == 0) 0 else (self.prefix_len + 1);
            const end = beg + self.identifier_len;
            return sliced[beg..end];
        }
    };
    
    pub const ElementCloseInline = struct {
        pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + ("/>".len);
            const result = src[beg..end];
            std.debug.assert(std.mem.eql(u8, result, "/>"));
            return result;
        }
    };
    
    pub const AttributeName = struct {
        prefix_len: usize, // slice[prefix_len] == ':' if prefix_len != 0
        full_len: usize,
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + self.full_len;
            return src[beg..end];
        }
        
        pub fn prefix(self: @This(), index: usize, src: []const u8) ?[]const u8 {
            const sliced = self.slice(index, src);
            const beg = 0;
            const end = beg + self.prefix_len;
            return if (self.prefix_len != 0) sliced[beg..end] else null;
        }
        
        pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = if (self.prefix_len == 0) 0 else (self.prefix_len + 1);
            return sliced[beg..];
        }
    };
    
    pub const AttributeValueSegment = union(enum) {
        text: Length,
        entity_reference: EntityReference,
        
        comptime {
            std.debug.assert(allVariantsHaveSliceFunc(@This()));
        }
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            inline for (comptime std.meta.fieldNames(@This())) |name| {
                if (@field(@This(), name) == self)
                    return @field(self, name).slice(index, src);
            }
            
            unreachable;
        }
    };
    
    pub const Comment = DataSection("<!--", "-->");
    pub const CharDataSection = DataSection("<![CDATA[", "]]>");
    
    pub const EntityReference = struct {
        len: usize,
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + self.len;
            return src[beg..end];
        }
        
        pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = ("&".len);
            const end = sliced.len - (";".len);
            return sliced[beg..end];
        }
    };
    
    pub const ProcessingInstructionsTarget = struct {
        target_len: usize,
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = beg + ("<?".len) + self.target_len;
            return src[beg..end];
        }
        
        pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = ("<?".len);
            const end = beg + self.target_len;
            return sliced[beg..end];
        }
    };
    
    pub const ProcessingInstructionsToken = union(enum) {
        name: Length,
        eql: @This().Eql,
        string: @This().QuotedString,
        end_tag: @This().EndTag,
        
        // Assert that all info variants have a `slice` method
        comptime {
            std.debug.assert(allVariantsHaveSliceFunc(@This()));
        }
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            inline for (comptime std.meta.fieldNames(@This())) |name| {
                if (@field(@This(), name) == self)
                    return @field(self, name).slice(index, src);
            }
            
            unreachable;
        }
        
        pub const Eql = struct {
            pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + ("=".len);
                return src[beg..end];
            }
        };
        
        pub const QuotedString = struct {
            content_len: usize,
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + ("'".len) + self.content_len + ("'".len);
                return src[beg..end];
            }
            
            pub fn data(self: @This(), index: usize, src: []const u8) []const u8 {
                const sliced = self.slice(index, src);
                const beg = ("'".len);
                const end = beg + self.content_len;
                return sliced[beg..end];
            }
        };
        
        pub const EndTag = struct {
            pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + ("?>".len);
                return src[beg..end];
            }
        };
    };
    
    
    
    const Length = struct {
        len: usize,
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            const beg = index;
            const end = index + self.len;
            return src[beg..end];
        }
    };
    
    fn DataSection(comptime start_tag: []const u8, comptime end_tag: []const u8) type {
        return struct {
            len: usize,
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + self.len;
                return src[beg..end];
            }
            
            pub fn data(self: @This(), index: usize, src: []const u8) []const u8 {
                const sliced = self.slice(index, src);
                const beg = start_tag.len;
                const end = sliced.len - end_tag.len;
                return sliced[beg..end];
            }
        };
    }
};
