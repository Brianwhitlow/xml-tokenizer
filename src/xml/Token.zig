const std = @import("std");
const meta = std.meta;
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

pub fn initTag(index: usize, comptime tag: meta.Tag(Info), value: meta.TagPayload(Info, tag)) Token {
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
    text: Text,
    entity_reference: EntityReference,
    whitespace: Whitespace,
    
    pi_target: ProcessingInstructionsTarget,
    pi_token: ProcessingInstructionsToken,
    
    
    
    // Assert that all variants of Union have a `slice` method
    fn allVariantsHaveSliceFunc(comptime Union: type) bool {
        inline for (meta.fields(Union)) |field_info| {
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
        inline for (comptime meta.fieldNames(Info)) |field_name| {
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
        empty_quotes: EmptyQuotes,
        
        comptime {
            std.debug.assert(allVariantsHaveSliceFunc(@This()));
        }
        
        pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
            inline for (comptime meta.fieldNames(@This())) |name| {
                if (@field(@This(), name) == self)
                    return @field(self, name).slice(index, src);
            }
            
            unreachable;
        }
        
        pub const EmptyQuotes = struct {
            pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + 0;
                const result = src[beg..end];
                std.debug.assert(std.mem.eql(u8, result, ""));
                return result;
            }
        };
    };
    
    pub const Comment = DataSection("<!--", "-->");
    pub const CharDataSection = DataSection("<![CDATA[", "]]>");
    pub const Text = Length;
    
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
    
    pub const Whitespace = Length;
    
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
            inline for (comptime meta.fieldNames(@This())) |name| {
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

pub const tests = struct {
    const testing = std.testing;
    
    pub fn expectElementOpen(src: []const u8, tok: Token, prefix: ?[]const u8, name: []const u8) !void {
        const full_slice: []const u8 = try std.mem.concat(testing.allocator, u8, @as([]const []const u8, if (prefix) |prfx| &.{ "<", prfx, ":", name } else &.{ "<", name }));
        defer testing.allocator.free(full_slice);
        
        try testing.expectEqual(@as(meta.Tag(Token.Info), .element_open), tok.info);
        try testing.expectEqualStrings(full_slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.info.element_open.name(tok.index, src));
        if (prefix) |prfx|
            try testing.expectEqualStrings(prfx, tok.info.element_open.prefix(tok.index, src) orelse return error.NullPrefix)
        else
            try testing.expectEqual(@as(?[]const u8, null), tok.info.element_open.prefix(tok.index, src));
    }
    
    pub fn expectAttributeName(src: []const u8, tok: Token, prefix: ?[]const u8, name: []const u8) !void {
        const full_slice: []const u8 = if (prefix) |prfx| @as([]const u8, try std.mem.concat(testing.allocator, u8, &.{ prfx, ":", name })) else name;
        defer if (prefix != null) testing.allocator.free(full_slice);
        
        try testing.expectEqual(@as(meta.Tag(Token.Info), .attribute_name), tok.info);
        try testing.expectEqualStrings(full_slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.info.attribute_name.name(tok.index, src));
        if (prefix) |prfx|
            try testing.expectEqualStrings(prfx, tok.info.attribute_name.prefix(tok.index, src) orelse return error.NullPrefix)
        else
            try testing.expectEqual(@as(?[]const u8, null), tok.info.attribute_name.prefix(tok.index, src));
    }
    
    pub fn expectElementCloseTag(src: []const u8, tok: Token, prefix: ?[]const u8, name: []const u8) !void {
        try testing.expectEqual(@as(meta.Tag(Token.Info), .element_close_tag), tok.info);
        try testing.expectEqualStrings("</", tok.slice(src)[0..2]);
        try testing.expectEqualStrings(">", tok.slice(src)[tok.slice(src).len - 1..]);
        try testing.expectEqualStrings(name, tok.info.element_close_tag.name(tok.index, src));
        if (prefix) |prfx|
            try testing.expectEqualStrings(prfx, tok.info.element_close_tag.prefix(tok.index, src) orelse return error.NullPrefix)
        else
            try testing.expectEqual(@as(?[]const u8, null), tok.info.element_close_tag.prefix(tok.index, src));
    }
    
    pub fn expectElementCloseInline(src: []const u8, tok: Token) !void {
        try testing.expectEqual(@as(meta.Tag(Token.Info), .element_close_inline), tok.info);
        try testing.expectEqualStrings("/>", tok.slice(src));
    }
    
    pub fn expectText(src: []const u8, tok: Token, content: []const u8) !void {
        try testing.expectEqual(@as(meta.Tag(Token.Info), .text), tok.info);
        try testing.expectEqualStrings(content, tok.slice(src));
    }
    
    pub fn expectWhitespace(src: []const u8, tok: Token, content: []const u8) !void {
        try testing.expectEqual(@as(meta.Tag(Token.Info), .whitespace), tok.info);
        try testing.expectEqualStrings(content, tok.slice(src));
    }
    
    pub fn expectEntityReference(src: []const u8, tok: Token, name: []const u8) !void {
        const full_slice = try std.mem.concat(testing.allocator, u8, &.{ "&", name, ";" });
        defer testing.allocator.free(full_slice);
        
        try testing.expectEqual(@as(meta.Tag(Token.Info), .entity_reference), tok.info);
        try testing.expectEqualStrings(full_slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.info.entity_reference.name(tok.index, src));
    }
    
    pub fn expectComment(src: []const u8, tok: Token, content: []const u8) !void {
        const full_slice = try std.mem.concat(testing.allocator, u8, &.{ "<!--", content, "-->" });
        defer testing.allocator.free(full_slice);
        
        try testing.expectEqual(@as(meta.Tag(Token.Info), .comment), tok.info);
        try testing.expectEqualStrings(full_slice, tok.slice(src));
        try testing.expectEqualStrings(content, tok.info.comment.data(tok.index, src));
    }
    
    pub const AttributeValueSegment = union(meta.Tag(Token.Info.AttributeValueSegment)) {
        empty_quotes,
        text: []const u8,
        entity_reference: struct{ name: []const u8 },
    };
    
    pub fn expectAttributeValueSegment(src: []const u8, tok: Token, segment: AttributeValueSegment) !void {
        try testing.expectEqual(@as(meta.Tag(Token.Info), .attribute_value_segment), tok.info);
        try testing.expectEqual(meta.activeTag(segment), tok.info.attribute_value_segment);
        
        const full_slice: []const u8 = switch (segment) {
            .empty_quotes => "",
            .text => |text| text,
            .entity_reference => |entity_reference| try std.mem.concat(testing.allocator, u8, &.{ "&", entity_reference.name, ";" }),
        };
        defer switch (segment) {
            .empty_quotes => {},
            .text => {},
            .entity_reference => testing.allocator.free(full_slice),
        };
        
        try testing.expectEqualStrings(full_slice, tok.slice(src));
        switch (segment) {
            .empty_quotes => {},
            .text => {},
            .entity_reference => |entity_reference| {
                const name = tok.info.attribute_value_segment.entity_reference.name(tok.index, src);
                try testing.expectEqualStrings(entity_reference.name, name);
            }
        }
    }
};
