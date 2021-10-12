const std = @import("std");
const debug = std.debug;
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
            .dtd_start => |info| .{ .forwards = info.name_beg },
            .elem_open_tag => .{ .forwards = ("<".len) },
            .elem_close_tag => .{ .forwards = ("</").len },
            .attr_val_segment_entity_ref => .{ .forwards = ("&".len), .backwards = (";".len) },
            .content_entity_ref => .{ .forwards = ("&".len), .backwards = (";".len) },
            else => return null,
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
            else => return null,
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
        
        dtd_start: struct { name_beg: usize },
        
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
    debug.panic("TODO: " ++ fmt, if (@TypeOf(args) == @TypeOf(null)) .{} else args);
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



const TokenizeAfterLeftAngleBracketErrorUnion = union(enum) {
    success: Token,
    err: struct {
        index: usize,
        code: Error,
    },
    
    pub fn get(self: @This()) Error!Token {
        return switch (self) {
            .success => |tok| tok,
            .err => |err| err.code,
        };
    }
    
    pub fn getLastIndex(self: @This()) usize {
        return switch (self) {
            .success => |tok| tok.loc.end,
            .err => |err| err.index,
        };
    }
    
    const Error = error {
        ImmediateEof,
        QuestionMarkInvalidNameStartChar,
        QuestionMarkEof,
        BangEof,
        BangSquareBracketInPrologue,
        BangSquareBracketInTrailingSection,
        BangSquareBracketEof,
        BangSquareBracketInvalid,
        UnclosedCharData,
        BangDashEof,
        BangDashInvalid,
        DashDashEofInComment,
        DashDashInvalidInComment,
        DashDashInComment,
        UnclosedComment,
        BangInvalidInRoot,
        BangInvalidInTrailingSection,
        BangInvalidInPrologue,
        DoctypeStartEof,
        DoctypeStartInvalid,
        DoctypeInvalidRootNameStartChar,
        BangInvalid,
        ElementCloseInPrologue,
        ElementCloseInTrailingSection,
        SlashEof,
        InvalidElementCloseNameStartChar,
        ElementOpenInTrailingSection,
        InvalidElementOpenNameStartChar,
    };
    
    fn initErr(index: usize, code: Error) @This() {
        return @unionInit(@This(), "err", .{ .code = code, .index = index });
    }
    
    fn initTok(tag: Token.Tag, loc: Token.Loc) @This() {
        return @unionInit(@This(), "success", Token.init(tag, loc));
    }
};

fn tokenizeAfterLeftAngleBracket(
    comptime section: DocumentSection,
    start_index: usize,
    src: []const u8,
) TokenizeAfterLeftAngleBracketErrorUnion {
    debug.assert(src[start_index] == '<');
    var index: usize = start_index;
    
    const ResultType = TokenizeAfterLeftAngleBracketErrorUnion;
    const ErrorSet = ResultType.Error;
    
    index += 1;
    switch (getByte(index, src) orelse return ResultType.initErr(index, ErrorSet.ImmediateEof)) {
        '?' => {
            index += 1;
            if (!xml.isValidUtf8NameStartChar(getUtf8(index, src) orelse return ResultType.initErr(index, ErrorSet.QuestionMarkEof))) {
                return ResultType.initErr(index, ErrorSet.QuestionMarkInvalidNameStartChar);
            }
            
            index += getUtf8Len(index, src).?;
            while (getUtf8(index, src)) |name_char|
            : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                if (!xml.isValidUtf8NameChar(name_char)) break;
            }
            
            return ResultType.initTok(.pi_target, .{ .beg = start_index, .end = index });
        },
        
        '!' => {
            index += 1;
            switch (getByte(index, src) orelse return ResultType.initErr(index, ErrorSet.BangEof)) {
                '[' => switch (section) {
                    .prologue => return ResultType.initErr(index, ErrorSet.BangSquareBracketInPrologue),
                    .trailing => return ResultType.initErr(index, ErrorSet.BangSquareBracketInTrailingSection),
                    .root => {
                        const expected_chars = "CDATA[";
                        inline for (expected_chars) |expected_char| {
                            debug.assert(1 == (unicode.utf8ByteSequenceLength(expected_char) catch unreachable));
                            index += 1;
                            if ((getByte(index, src) orelse return ResultType.initErr(index, ErrorSet.BangSquareBracketEof)) != expected_char) {
                                return ResultType.initErr(index, ErrorSet.BangSquareBracketInvalid);
                            }
                        }
                        debug.assert(getByte(index, src).? == expected_chars[expected_chars.len - 1]);
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
                            
                            return ResultType.initTok(.content_cdata, .{ .beg = start_index, .end = index });
                        }
                        
                        return ResultType.initErr(index, ErrorSet.UnclosedCharData);
                    },
                },
                
                '-' => {
                    index += 1;
                    if ((getByte(index, src) orelse return ResultType.initErr(index, ErrorSet.BangDashEof)) != '-') {
                        return ResultType.initErr(index, ErrorSet.BangDashInvalid);
                    }
                    
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
                        
                        if ((getByte(index, src) orelse return ResultType.initErr(index, ErrorSet.DashDashEofInComment)) != '>') {
                            return ResultType.initErr(index, ErrorSet.DashDashInvalidInComment);
                        }
                        index += 1;
                        
                        return ResultType.initTok(.comment, .{ .beg = start_index, .end = index });
                    }
                    
                    return ResultType.initErr(index, ErrorSet.UnclosedComment);
                },
                
                'D' => switch (section) {
                    .root => return ResultType.initErr(index, ErrorSet.BangInvalidInRoot),
                    .trailing => return ResultType.initErr(index, ErrorSet.BangInvalidInTrailingSection),
                    .prologue => {
                        const expected_chars = "OCTYPE";
                        inline for (expected_chars) |expected_char| {
                            debug.assert(1 == (unicode.utf8ByteSequenceLength(expected_char) catch unreachable));
                            index += 1;
                            if ((getByte(index, src) orelse (expected_char +% 1)) != expected_char) {
                                return ResultType.initErr(index, ErrorSet.BangInvalidInPrologue);
                            }
                        }
                        debug.assert(getByte(index, src).? == expected_chars[expected_chars.len - 1]);
                        index += 1;
                        
                        switch (getByte(index, src) orelse return ResultType.initErr(index, ErrorSet.DoctypeStartEof)) {
                            ' ',
                            '\t',
                            '\n',
                            '\r',
                            => {},
                            else => return ResultType.initErr(index, ErrorSet.DoctypeStartInvalid),
                        }
                        
                        index += 1;
                        while (getByte(index, src)) |char| : (index += 1) switch (char) {
                            ' ',
                            '\t',
                            '\n',
                            '\r',
                            => continue,
                            else => break,
                        };
                        
                        const name_start_char = getUtf8(index, src) orelse xml.invalid_name_start_char;
                        if (!xml.isValidUtf8NameStartChar(name_start_char)) {
                            return ResultType.initErr(index, ErrorSet.DoctypeInvalidRootNameStartChar);
                        }
                        
                        const name_beg = index;
                        index += unicode.utf8CodepointSequenceLength(name_start_char) catch unreachable;
                        
                        while (getUtf8(index, src)) |name_char|
                        : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                            if (!xml.isValidUtf8NameChar(name_char)) break;
                        }
                        
                        const tag = Token.Tag { .dtd_start = .{ .name_beg = name_beg } };
                        const loc = Token.Loc { .beg = start_index, .end = index };
                        return ResultType.initTok(tag, loc);
                    },
                },
                
                else => return ResultType.initErr(index, ErrorSet.BangInvalid),
            }
        },
        
        '/' => switch (section) {
            .prologue => return ResultType.initErr(index, ErrorSet.ElementCloseInPrologue),
            .trailing => return ResultType.initErr(index, ErrorSet.ElementCloseInTrailingSection),
            .root => {
                index += 1;
                if (!xml.isValidUtf8NameStartChar(getUtf8(index, src) orelse return ResultType.initErr(index, ErrorSet.SlashEof))) {
                    return ResultType.initErr(index, ErrorSet.InvalidElementCloseNameStartChar);
                }
                index += getUtf8Len(index, src).?;
                
                while (getUtf8(index, src)) |name_char|
                : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }
                
                return ResultType.initTok(.elem_close_tag, .{ .beg = start_index, .end = index });
            },
        },
        
        else => switch (section) {
            .trailing => return ResultType.initErr(index, ErrorSet.ElementOpenInTrailingSection),
            .prologue,
            .root,
            => {
                if (!xml.isValidUtf8NameStartChar(getUtf8(index, src) orelse xml.invalid_name_start_char)) {
                    return ResultType.initErr(index, ErrorSet.InvalidElementOpenNameStartChar);
                }
                index += getUtf8Len(index, src).?;
                
                while (getUtf8(index, src)) |name_char|
                : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }
                
                return ResultType.initTok(.elem_open_tag, .{ .beg = start_index, .end = index });
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
        const tok = try tokenizeAfterLeftAngleBracket(section, 0, src).get();
        try testing.expectEqual(@as(Token.Tag, .pi_target), tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
    };
    
    // Comment
    inline for (.{ .prologue, .root, .trailing }) |section|
    inline for (.{ (""), ("- "), (" foo bar baz ") }) |comment_data|
    {
        const src = "<!--" ++ comment_data ++ "-->";
        const tok = try tokenizeAfterLeftAngleBracket(section, 0, src).get();
        try testing.expectEqual(@as(Token.Tag, .comment), tok.tag);
        try testing.expectEqualStrings(src, tok.slice(src));
        try testing.expectEqualStrings(comment_data, tok.data(src).?);
    };
    
    inline for (.{ (" "), ("\t"), ("\n\t") }) |whitespace|
    inline for (.{ (""), ("["), (" [") }) |end|
    {
        const name = "root";
        const slice = "<!DOCTYPE" ++ whitespace ++ name;
        const src = slice ++ end;
        const tok = try tokenizeAfterLeftAngleBracket(.prologue, 0, src).get();
        try testing.expectEqual(Token.Tag.dtd_start, tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
    };
    
    // CDATA section
    inline for (.{"", " "}) |whitespace|
    inline for(.{ (""), ("]"), ("]]"), ("]>"), ("foo") }) |base_cdata_data|
    {
        const cdata_data = base_cdata_data ++ whitespace;
        const src = "<![CDATA[" ++ cdata_data ++ "]]>";
        const tok = try tokenizeAfterLeftAngleBracket(.root, 0, src).get();
        try testing.expectEqual(@as(Token.Tag, .content_cdata), tok.tag);
        try testing.expectEqualStrings(src, tok.slice(src));
        try testing.expectEqualStrings(cdata_data, tok.data(src).?);
        
        try testing.expectError(error.BangSquareBracketInPrologue, tokenizeAfterLeftAngleBracket(.prologue, 0, src).get());
        try testing.expectError(error.BangSquareBracketInTrailingSection, tokenizeAfterLeftAngleBracket(.trailing, 0, src).get());
    };
    
    // Element close tag
    inline for (.{ "A", "foo" }) |name|
    inline for (.{ (""), (">"), ("\t>") }) |end|
    {
        const slice = "</" ++ name;
        const src = slice ++ end;
        const tok = try tokenizeAfterLeftAngleBracket(.root, 0, src).get();
        try testing.expectEqual(@as(Token.Tag, .elem_close_tag), tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
        
        try testing.expectError(error.ElementCloseInTrailingSection, tokenizeAfterLeftAngleBracket(.trailing, 0, src).get());
        try testing.expectError(error.ElementCloseInPrologue, tokenizeAfterLeftAngleBracket(.prologue, 0, src).get());
    };
    
    // Element open tag
    inline for (.{ .prologue, .root }) |section|
    inline for (.{ "A", "foo" }) |name|
    inline for (.{ (""), ("/>"), ("\t/>"), (">"), ("\t>") }) |end|
    {
        const slice = "<" ++ name;
        const src = slice ++ end;
        const tok = try tokenizeAfterLeftAngleBracket(section, 0, src).get();
        try testing.expectEqual(@as(Token.Tag, .elem_open_tag), tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
        
        try testing.expectError(error.ElementOpenInTrailingSection, tokenizeAfterLeftAngleBracket(.trailing, 0, src).get());
    };
    
}
