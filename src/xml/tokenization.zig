const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;

const xml = @import("../xml.zig");


const DocumentSection = enum { prologue, root, trailing };

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    
    pub fn init(tag: Tag, loc: Loc) Token {
        return Token {
            .tag = tag,
            .loc = loc,
        };
    }
    
    pub fn slice(self: Token, src: []const u8) []const u8 {
        return self.loc.slice(src);
    }
    
    pub fn name(self: Token, src: []const u8) ?[]const u8 {
        const Offset = struct { forwards: usize = 0, backwards: usize = 0, };
        const offset: Offset = switch (self.tag) {
            .pi_target => .{ .forwards = ("<?".len) },
            .elem_open_tag => .{ .forwards = ("<".len) },
            .elem_close_tag => .{ .forwards = ("</").len },
            .attr_val_segment_entity_ref => .{ .forwards = ("&".len), .backwards = (";".len) },
            .content_entity_ref => .{ .forwards = ("&".len), .backwards = (";".len) },
            
            .pi_tok_string,
            .pi_tok_other,
            .pi_end,
            .whitespace,
            .comment,
            .elem_close_inline,
            .attr_name,
            .attr_val_empty,
            .attr_val_segment_text,
            .content_text,
            .content_cdata,
            => return null,
        };
        
        const sliced = self.slice(src);
        const beg = offset.forwards;
        const end = sliced.len - offset.backwards;
        return sliced[beg..end];
    }
    
    pub fn data(self: Token, src: []const u8) ?[]const u8 {
        const Offset = struct { forwards: usize = 0, backwards: usize = 0 };
        const offset: Offset = switch (self.tag) {
            .pi_tok_string => .{ .forwards = 1, .backwards = 1 },
            .comment => .{ .forwards = ("<!--".len), .backwards = ("-->".len) },
            .content_cdata => .{ .forwards = ("<![CDATA[".len), .backwards = ("]]>".len) },
            
            .pi_target,
            .pi_tok_other,
            .pi_end,
            .whitespace,
            .elem_open_tag,
            .elem_close_tag,
            .elem_close_inline,
            .attr_name,
            .attr_val_empty,
            .attr_val_segment_text,
            .attr_val_segment_entity_ref,
            .content_text,
            .content_entity_ref,
            => return null,
        };
        
        const sliced = self.slice(src);
        const beg = offset.forwards;
        const end = sliced.len - offset.backwards;
        return sliced[beg..end];
    }
    
    pub const Tag = union(enum) {
        pi_target,
        pi_tok_string,
        pi_tok_other,
        pi_end,
        
        whitespace,
        comment,
        
        elem_open_tag,
        elem_close_tag,
        elem_close_inline,
        
        attr_name,
        attr_val_empty,
        attr_val_segment_text,
        attr_val_segment_entity_ref,
        
        content_text,
        content_cdata,
        content_entity_ref,
    };

    pub const Loc = struct {
        beg: usize,
        end: usize,
        
        pub fn slice(self: @This(), src: []const u8) []const u8 {
            return src[self.beg..self.end];
        }
    };
};

inline fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.panic("TODO: " ++ fmt, if (@TypeOf(args) == @TypeOf(null)) .{} else args);
}

fn getByte(index: usize, src: []const u8) ?u8 {
    if (index >= src.len) return null;
    return src[index];
}

fn getUtf8(index: usize, src: []const u8) ?u21 {
    const cp_len = getUtf8Len(index, src) orelse return null;
    const beg = index;
    const end = beg + cp_len;
    return if (end <= src.len) (unicode.utf8Decode(src[beg..end]) catch null) else null;
}

fn getUtf8Len(index: usize, src: []const u8) ?u3 {
    const start_byte = getByte(index, src) orelse return null;
    return unicode.utf8ByteSequenceLength(start_byte) catch null;
}

fn tokenizeAfterLeftAngleBracket(
    comptime section: DocumentSection,
    start_index: usize,
    src: []const u8,
) error{
    ImmediateEof,
    InvalidSquareBracketInPrologue,
    InvalidSquareBracketInTrailingSection,
    ElementOpenInTrailingSection,
    ElementCloseInPrologue,
    ElementCloseInTrailingSection,
    
    QMarkInvalid,
    
    BangInvalid,
    UnclosedCommentDashDash,
    UnclosedCommentInvalid,
    
    BangSquareBracketInvalid,
    UnclosedCharData,
    
    InvalidElementCloseNameStartChar,
    
    InvalidElementOpenNameStartChar,
}!Token {
    std.debug.assert(src[start_index] == '<');
    var index: usize = start_index;
    
    index += 1;
    switch (getByte(index, src) orelse return error.ImmediateEof) {
        '?' => {
            index += 1;
            if (!xml.isValidUtf8NameStartChar(getUtf8(index, src) orelse xml.invalid_name_start_char)) {
                return error.QMarkInvalid;
            }
            
            index += getUtf8Len(index, src).?;
            while (getUtf8(index, src)) |name_char|
            : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                if (!xml.isValidUtf8NameChar(name_char)) break;
            }
            
            return Token.init(.pi_target, .{ .beg = start_index, .end = index });
        },
        
        '!' => {
            index += 1;
            switch (getByte(index, src) orelse return error.BangInvalid) {
                '[' => switch (section) {
                    .prologue => return error.InvalidSquareBracketInPrologue,
                    .trailing => return error.InvalidSquareBracketInTrailingSection,
                    .root => {
                        const expected_chars = "CDATA[";
                        inline for (expected_chars) |expected_char| {
                            std.debug.assert(1 == (unicode.utf8ByteSequenceLength(expected_char) catch unreachable));
                            index += 1;
                            if ((getByte(index, src) orelse (expected_char +% 1)) != expected_char) {
                                return error.BangSquareBracketInvalid;
                            }
                        }
                        std.debug.assert(getByte(index, src).? == expected_chars[expected_chars.len - 1]);
                        index += 1;
                        
                        while (getUtf8(index, src)) |char|
                        : (index += unicode.utf8CodepointSequenceLength(char) catch unreachable) {
                            if (char != ']') {
                                continue;
                            }
                            index += 1;
                            
                            if ((getByte(index, src) orelse 0) != ']') {
                                index -= 1;
                                continue;
                            }
                            index += 1;
                            
                            if ((getByte(index, src) orelse 0) != '>') {
                                index -= 2;
                                continue;
                            }
                            index += 1;
                            
                            return Token.init(.content_cdata, .{ .beg = start_index, .end = index });
                        }
                        
                        return error.UnclosedCharData;
                    },
                },
                
                '-' => {
                    index += 1;
                    if ((getByte(index, src) orelse 0) != '-') return error.BangInvalid;
                    
                    index += 1;
                    while (getUtf8(index, src)) |char|
                    : (index += unicode.utf8CodepointSequenceLength(char) catch unreachable) {
                        if (char != '-') {
                            continue;
                        }
                        index += 1;
                        
                        if ((getByte(index, src) orelse 0) != '-') {
                            continue;
                        }
                        index += 1;
                        
                        if ((getByte(index, src) orelse 0) != '>') {
                            return error.UnclosedCommentDashDash;
                        }
                        index += 1;
                        
                        return Token.init(.comment, .{ .beg = start_index, .end = index });
                    }
                    
                    return error.UnclosedCommentInvalid;
                },
                
                'D' => todo("Tokenize after <!D", null),
                
                else => todo("Handle tokenization for after '<!{c}'.", .{getByte(index, src).?}),
            }
        },
        
        '/' => switch (section) {
            .prologue => return error.ElementCloseInPrologue,
            .trailing => return error.ElementCloseInTrailingSection,
            .root => {
                index += 1;
                if (!xml.isValidUtf8NameStartChar(getUtf8(index, src) orelse xml.invalid_name_start_char)) {
                    return error.InvalidElementCloseNameStartChar;
                }
                index += getUtf8Len(index, src).?;
                
                while (getUtf8(index, src)) |name_char|
                : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }
                
                return Token.init(.elem_close_tag, .{ .beg = start_index, .end = index });
            },
        },
        
        else => switch (section) {
            .trailing => return error.ElementOpenInTrailingSection,
            .prologue,
            .root,
            => {
                if (!xml.isValidUtf8NameStartChar(getUtf8(index, src) orelse xml.invalid_name_start_char)) {
                    return error.InvalidElementOpenNameStartChar;
                }
                index += getUtf8Len(index, src).?;
                
                while (getUtf8(index, src)) |name_char|
                : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }
                
                return Token.init(.elem_open_tag, .{ .beg = start_index, .end = index });
            },
        },
    }
}


test "tokenizeAfterLeftAngleBracket" {
    // Processing Instructions Target
    inline for (.{ .prologue, .root, .trailing }) |section|
    inline for (.{ "A", "foo" }) |name|
    inline for (.{ (""), ("?>"), ("\t?>") }) |end|
    {
        const slice = "<?" ++ name;
        const src = slice ++ end;
        const tok = try tokenizeAfterLeftAngleBracket(section, 0, src);
        try testing.expectEqual(@as(Token.Tag, .pi_target), tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
    };
    
    // Comment
    inline for (.{ .prologue, .root, .trailing }) |section|
    inline for (.{ (""), ("- "), (" foo bar baz ") }) |comment_data|
    {
        const src = "<!--" ++ comment_data ++ "-->";
        const tok = try tokenizeAfterLeftAngleBracket(section, 0, src);
        try testing.expectEqual(@as(Token.Tag, .comment), tok.tag);
        try testing.expectEqualStrings(src, tok.slice(src));
        try testing.expectEqualStrings(comment_data, tok.data(src).?);
    };
    
    // CDATA section
    inline for (.{"", " "}) |whitespace|
    inline for(.{ (""), ("]"), ("]]"), ("]>"), ("foo") }) |base_cdata_data|
    {
        const cdata_data = base_cdata_data ++ whitespace;
        const src = "<![CDATA[" ++ cdata_data ++ "]]>";
        const tok = try tokenizeAfterLeftAngleBracket(.root, 0, src);
        try testing.expectEqual(@as(Token.Tag, .content_cdata), tok.tag);
        try testing.expectEqualStrings(src, tok.slice(src));
        try testing.expectEqualStrings(cdata_data, tok.data(src).?);
        
        try testing.expectError(error.InvalidSquareBracketInPrologue, tokenizeAfterLeftAngleBracket(.prologue, 0, src));
        try testing.expectError(error.InvalidSquareBracketInTrailingSection, tokenizeAfterLeftAngleBracket(.trailing, 0, src));
    };
    
    // Element close tag
    inline for (.{ "A", "foo" }) |name|
    inline for (.{ (""), (">"), ("\t>") }) |end|
    {
        const slice = "</" ++ name;
        const src = slice ++ end;
        const tok = try tokenizeAfterLeftAngleBracket(.root, 0, src);
        try testing.expectEqual(@as(Token.Tag, .elem_close_tag), tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
        
        try testing.expectError(error.ElementCloseInTrailingSection, tokenizeAfterLeftAngleBracket(.trailing, 0, src));
        try testing.expectError(error.ElementCloseInPrologue, tokenizeAfterLeftAngleBracket(.prologue, 0, src));
    };
    
    // Element open tag
    inline for (.{ .prologue, .root }) |section|
    inline for (.{ "A", "foo" }) |name|
    inline for (.{ (""), ("/>"), ("\t/>"), (">"), ("\t>") }) |end|
    {
        const slice = "<" ++ name;
        const src = slice ++ end;
        const tok = try tokenizeAfterLeftAngleBracket(section, 0, src);
        try testing.expectEqual(@as(Token.Tag, .elem_open_tag), tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
        
        try testing.expectError(error.ElementOpenInTrailingSection, tokenizeAfterLeftAngleBracket(.trailing, 0, src));
    };
    
    inline for([_]struct { err: anyerror, section: DocumentSection, index: usize = 0, src: []const u8 } {
        .{ .err = error.ImmediateEof,                          .section = .root,     .src = "<" },
        .{ .err = error.InvalidSquareBracketInPrologue,        .section = .prologue, .src = "<![" },
        .{ .err = error.InvalidSquareBracketInTrailingSection, .section = .trailing, .src = "<![" },
        .{ .err = error.ElementOpenInTrailingSection,          .section = .trailing, .src = "<foo" },
        .{ .err = error.ElementCloseInPrologue,                .section = .prologue, .src = "</foo" },
        .{ .err = error.ElementCloseInTrailingSection,         .section = .trailing, .src = "</foo" },
        .{ .err = error.QMarkInvalid,                          .section = .root,     .src = "<?" },
        .{ .err = error.BangInvalid,                           .section = .root,     .src = "<!" },
        .{ .err = error.UnclosedCommentDashDash,               .section = .root,     .src = "<!-- -- " },
        .{ .err = error.UnclosedCommentInvalid,                .section = .root,     .src = "<!--    " },
        .{ .err = error.BangSquareBracketInvalid,              .section = .root,     .src = "<![CDATA   " },
        .{ .err = error.UnclosedCharData,                      .section = .root,     .src = "<![CDATA[  " },
        .{ .err = error.InvalidElementOpenNameStartChar,       .section = .root,     .src = "<3CP0>" },
        .{ .err = error.InvalidElementCloseNameStartChar,      .section = .root,     .src = "</3CP0>" },
    }) |info|
    {
        try testing.expectError(
            info.err,
            tokenizeAfterLeftAngleBracket(info.section, info.index, info.src)
        );
    }
    
}
