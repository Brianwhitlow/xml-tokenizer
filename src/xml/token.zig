const std = @import("std");
const meta = std.meta;
const testing = std.testing;

const Token = @This();
index: usize = 0,
info: Info = .bof,

pub fn init(index: usize, info: Info) Token {
    return Token {
        .index = index,
        .info = info,
    };
}

pub fn initTag(index: usize, comptime tag: Info.Tag, value: Info.TagStrPayload(@tagName(tag))) Token {
    return Token.init(index, @unionInit(Info, @tagName(tag), value));
}

pub fn initTagStr(index: usize, comptime tag_name: []const u8, value: Info.TagStrPayload(tag_name)) Token {
    return Token.init(index, @unionInit(Info, tag_name, value));
}

pub fn slice(self: Token, src: []const u8) []const u8 {
    return self.info.slice(self.index, src);
}

pub const Info = union(enum) {
    bof,
    eof,
    invalid,
    
    element_open: ElementId,
    element_close: ElementId,
    attribute: Attribute,
    
    empty_whitespace: EmptyWhitespace,
    text: Text,
    char_data: CharData,
    
    comment: Comment,
    processing_instructions: ProcessingInstructions,
    doctype_declaration: DoctypeDeclaration,
    
    pub fn TagStrPayload(comptime tag_name: []const u8) type {
        return @TypeOf(@field(@unionInit(Info, tag_name, undefined), tag_name));
    }
    pub const Tag = @TypeOf(Info.bof);
    
    pub fn slice(self: Info, index: usize, src: []const u8) []const u8 {
        inline for (std.meta.fields(Info)) |field| {
            const FieldType = blk: {
                const MaybeOutput = TagStrPayload(field.name);
                break :blk if (MaybeOutput == void) struct {} else MaybeOutput;
            };
            const ExpectedFnType = fn(FieldType, usize, []const u8)[]const u8;
            
            if (@hasDecl(FieldType, "slice")) {
                const decl_info = std.meta.declarationInfo(FieldType, "slice");
                const match = switch (decl_info.data) { .Fn => |info| (info.fn_type == ExpectedFnType), else => false };
                if (match and self == @field(Tag, field.name))
                    return @field(self, field.name).slice(index, src);
            }
        }
        return &[_]u8 {};
    }
    
    
    
    pub const ElementId = struct {
        colon_offset: ?usize,
        len: usize,
        
        /// Effectively the same as concatenating the results
        /// of `self.namespace(index, src, true)` and `self.name(index, src)`,
        pub fn slice(self: ElementId, index: usize, src: []const u8) []const u8 {
            const end = index + self.len;
            return src[index..end];
        }
        
        pub fn namespace(self: ElementId, index: usize, src: []const u8, include_colon: bool) ?[]const u8 {
            const sliced = self.slice(index, src);
            const end = (self.colon_offset orelse return null) + @boolToInt(include_colon);
            return sliced[0..end];
        }
        
        pub fn name(self: ElementId, index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = if (self.colon_offset) |offset| (offset + 1) else 0;
            return sliced[beg..];
        }
    };
    
    pub const Attribute = struct {
        colon_offset: ?usize,
        prefixed_name_len: usize,
        separation: usize,
        value_len: usize,
        
        pub fn slice(self: Attribute, index: usize, src: []const u8) []const u8 {
            const end = index + self.prefixed_name_len + self.separation + self.value_len;
            return src[index..end];
        }
        
        pub fn prefix(self: Attribute, index: usize, src: []const u8, include_colon: bool) ?[]const u8 {
            const sliced = self.slice(index, src);
            const end = (self.colon_offset orelse return null) + @boolToInt(include_colon);
            return sliced[0..end];
        }
        
        pub fn name(self: Attribute, index: usize, src: []const u8) []const u8 {
            const sliced = self.slice(index, src);
            const beg = if (self.colon_offset) |offset| offset + 1 else 0;
            const end = self.prefixed_name_len;
            return sliced[beg..end];
        }
        
        pub fn prefixedName(self: Attribute, index: usize, src: []const u8) ?[]const u8 {
            if (self.colon_offset == null) return null;
            const sliced = self.slice(index, src);
            const end = self.prefixed_name_len;
            return sliced[0..end];
        }
        
        pub fn value(self: Attribute, index: usize, src: []const u8, include_quotes: bool) []const u8 {
            const sliced = self.slice(index, src);
            const beg = self.prefixed_name_len + self.separation + @boolToInt(!include_quotes);
            const end = sliced.len - @boolToInt(!include_quotes);
            return sliced[beg..end];
        }
    };
    
    pub const EmptyWhitespace = Text;
    
    pub const Text = struct {
        len: usize,
        
        pub fn slice(self: Text, index: usize, src: []const u8) []const u8 {
            const end = index + self.len;
            return src[index..end];
        }
    };
    
    pub const CharData = EnclosedData("<![CDATA[", "]]>");
    
    pub const Comment = EnclosedData("<!--", "-->");
    pub const ProcessingInstructions = EnclosedData("<?", "?>");
    pub const DoctypeDeclaration = EnclosedData("<!DOCTYPE", ">");
    
    /// This is used for any section other than text/whitespace that is enclosed between two tokens,
    /// and which is not fully tokenized; it is only referenced as a raw section of data, to be tokenized/parsed
    /// by some other means.
    fn EnclosedData(comptime beg_str: []const u8, comptime end_str: []const u8) type {
        return struct {
            len: usize, // refers only to the length of the data comprised between beg_str and end_str.
            
            pub const str_beg = beg_str;
            pub const str_end = end_str;
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const end = index + str_beg.len + self.len + str_end.len;
                return src[index..end];
            }
            
            pub fn data(self: @This(), index: usize, src: []const u8) []const u8 {
                const sliced = self.slice(index, src);
                const beg = str_beg.len;
                const end = beg + self.len;
                return sliced[beg..end];
            }
        };
    }
    
};

test "Void" {
    inline for (.{
        Token { .index = 0, .info = .bof },
        Token { .index = 0, .info = .eof },
        Token { .index = 0, .info = .invalid },
    }) |token| {
        try testing.expectEqualStrings(token.slice("foo bar baz"), "");
    }
}

test "ElementId" {
    inline for (.{"element_open", "element_close"}) |field_name| {
        std.debug.assert(@hasField(Info, field_name));
        
        with_namespace: {
            const namespace: []const u8 = "foo:";
            const name: []const u8 = "bar";
            const src: []const u8 = namespace ++ name;
            const colon_idx = namespace.len - 1;
            
            const token = Token.init(0, @unionInit(Info, field_name, .{ .colon_offset = colon_idx, .len = src.len }));
            const specific = @field(token.info, field_name);
            
            try testing.expectEqualStrings(specific.slice(0, src), src);
            try testing.expectEqualStrings(specific.name(0, src), name);
            try testing.expectEqualStrings(specific.namespace(0, src, false).?, namespace[0..colon_idx]);
            try testing.expectEqualStrings(specific.namespace(0, src, true).?, namespace);
            
            break :with_namespace;
        }
        
        without_namespace: {
            const src: []const u8 = "foo";
            
            const token = Token.init(0, @unionInit(Info, field_name, .{ .colon_offset = null, .len = src.len }));
            try testing.expectEqualStrings(token.info.slice(0, src), src);
            
            const active_field = @field(token.info, field_name);
            try testing.expectEqualStrings(active_field.name(0, src), src);
            try testing.expectEqual(active_field.namespace(0, src, false), null);
            try testing.expectEqual(active_field.namespace(0, src, true), null);
            break :without_namespace;
        }
    }
}

test "Attribute" {
    with_prefix: {
        const prefix = "foo:";
        const name: []const u8 = "bar";
        const prefixed_name = prefix ++ name;
        const eql: []const u8 = "=";
        const value: []const u8 = "'baz'";
        const src: []const u8 = prefixed_name ++ eql ++ value;
        const colon_idx = prefix.len - 1;
        
        const token = Token.init(0, .{ .attribute = .{
            .colon_offset = colon_idx,
            .prefixed_name_len = prefixed_name.len,
            .separation = eql.len,
            .value_len = value.len,
        } });
        
        try testing.expectEqualStrings(token.slice(src), src);
        try testing.expectEqualStrings(token.info.attribute.prefix(0, src, false).?, prefix[0..colon_idx]);
        try testing.expectEqualStrings(token.info.attribute.prefix(0, src, true).?, prefix);
        try testing.expectEqualStrings(token.info.attribute.name(0, src), name);
        try testing.expectEqualStrings(token.info.attribute.prefixedName(0, src).?, prefixed_name);
        try testing.expectEqualStrings(token.info.attribute.value(0, src, false), value[1..value.len - 1]);
        try testing.expectEqualStrings(token.info.attribute.value(0, src, true), value);
        
        break :with_prefix;
    }
    
    without_prefix: {
        const name: []const u8 = "foo";
        const eql: []const u8 = " = ";
        const value: []const u8 = "'bar'";
        const src: []const u8 = name ++ eql ++ value;
        
        const token = Token.init(0, .{ .attribute = .{
            .colon_offset = null,
            .prefixed_name_len = name.len,
            .separation = eql.len,
            .value_len = value.len,
        } });
        
        try testing.expectEqualStrings(token.slice(src), src);
        try testing.expectEqual(token.info.attribute.prefix(0, src, false), null);
        try testing.expectEqual(token.info.attribute.prefix(0, src, true), null);
        try testing.expectEqualStrings(token.info.attribute.name(0, src), name);
        try testing.expectEqual(token.info.attribute.prefixedName(0, src), null);
        try testing.expectEqualStrings(token.info.attribute.value(0, src, false), value[1..value.len - 1]);
        try testing.expectEqualStrings(token.info.attribute.value(0, src, true), value);
        
        break :without_prefix;
    }
}

test "Text" {
    inline for (.{"empty_whitespace", "text"}) |field_name| {
        std.debug.assert(@hasField(Info, field_name));
        
        const src = "foo bar baz";
        const token = Token.init(0, @unionInit(Info, field_name, .{ .len = src.len }));
        try testing.expectEqualStrings(token.slice(src), src);
    }
}

test "EncapsulatedData" {
    inline for (.{"char_data", "comment", "processing_instructions", "doctype_declaration"}) |field_name| {
        std.debug.assert(@hasField(Info, field_name));
        
        const EncapsulatedData = @TypeOf(@field(Token.init(undefined, undefined).info, field_name));
        const str_beg = EncapsulatedData.str_beg;
        const str_end = EncapsulatedData.str_end;
        const data = "foo bar baz";
        const src = str_beg ++ data ++ str_end;
        
        const token = Token.init(0, @unionInit(Info, field_name, .{ .len = data.len }));
        
        const active_field_value = @field(token.info, field_name);
        try testing.expectEqualStrings(token.slice(src), src);
        try testing.expectEqualStrings(active_field_value.data(0, src), data);
    }
}
