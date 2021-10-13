const std = @import("std");
const debug = std.debug;
const testing = std.testing;
const unicode = std.unicode;

const utility = @import("../utility.zig");
const getByte = utility.getByte;
const getUtf8Len = utility.getUtf8Len;
const getUtf8 = utility.getUtf8;

/// Expects `@TypeOf(char) == 'u8' or @TypeOf(char) == 'u21'`
fn lenOfUtf8OrNull(char: anytype) ?u3 {
    const T = @TypeOf(char);
    return switch (T) {
        u8 => unicode.utf8ByteSequenceLength(char) catch null,
        u21 => unicode.utf8CodepointSequenceLength(char) catch null,
        else => @compileError("Expected u8 or u21, got " ++ @typeName(T)),
    };
}

const xml = @import("../xml.zig");

inline fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    debug.panic("TODO: " ++ fmt, if (@TypeOf(args) == @TypeOf(null)) .{} else args);
}

pub const DocumentSection = enum { prologue, root, trailing };

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub fn init(tag: Tag, loc: Loc) Token {
        return Token{
            .tag = tag,
            .loc = loc,
        };
    }

    pub fn slice(self: Token, src: []const u8) []const u8 {
        return self.loc.slice(src);
    }

    pub fn name(self: Token, src: []const u8) ?[]const u8 {
        const Offset = struct {
            forwards: usize = 0,
            backwards: usize = 0,
        };
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

const TokenOrError = enum { tok, err };

pub const AfterLeftAngleBracket = union(TokenOrError) {
    const Self = @This();
    tok: Token,
    err: struct {
        index: usize,
        code: Error,
    },

    pub fn tokenize(
        comptime section: DocumentSection,
        start_index: usize,
        src: []const u8,
    ) Self {
        debug.assert(src[start_index] == '<');
        var index: usize = start_index;

        index += 1;
        const start_byte = getByte(index, src) orelse return Self.initErr(index, Error.ImmediateEof);
        switch (start_byte) {
            '?' => {
                index += 1;
                const name_start_char = getUtf8(index, src) orelse return Self.initErr(index, Error.QuestionMarkEof);
                if (!xml.isValidUtf8NameStartChar(name_start_char)) {
                    return Self.initErr(index, Error.QuestionMarkInvalidNameStartChar);
                }

                index += lenOfUtf8OrNull(name_start_char).?;
                while (getUtf8(index, src)) |name_char| : (index += lenOfUtf8OrNull(name_char).?) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }

                return Self.initTok(.pi_target, .{ .beg = start_index, .end = index });
            },

            '!' => {
                index += 1;
                switch (getByte(index, src) orelse return Self.initErr(index, Error.BangEof)) {
                    '[' => switch (section) {
                        .prologue => return Self.initErr(index, Error.BangSquareBracketInPrologue),
                        .trailing => return Self.initErr(index, Error.BangSquareBracketInTrailingSection),
                        .root => {
                            const expected_chars = "CDATA[";
                            inline for (expected_chars) |expected_char| {
                                debug.assert(1 == (unicode.utf8ByteSequenceLength(expected_char) catch unreachable));
                                index += 1;
                                if ((getByte(index, src) orelse return Self.initErr(index, Error.BangSquareBracketEof)) != expected_char) {
                                    return Self.initErr(index, Error.BangSquareBracketInvalid);
                                }
                            }
                            debug.assert(getByte(index, src).? == expected_chars[expected_chars.len - 1]);
                            index += 1;

                            while (getUtf8(index, src)) |char| : (index += unicode.utf8CodepointSequenceLength(char) catch unreachable) {
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

                                return Self.initTok(.content_cdata, .{ .beg = start_index, .end = index });
                            }

                            return Self.initErr(index, Error.UnclosedCharData);
                        },
                    },

                    '-' => {
                        index += 1;
                        if ((getByte(index, src) orelse return Self.initErr(index, Error.BangDashEof)) != '-') {
                            return Self.initErr(index, Error.BangDashInvalid);
                        }

                        index += 1;
                        while (getUtf8(index, src)) |char| : (index += unicode.utf8CodepointSequenceLength(char) catch unreachable) {
                            if (char != '-') {
                                continue;
                            }
                            index += 1;

                            if ((getByte(index, src) orelse 0) != '-') {
                                continue;
                            }
                            index += 1;

                            if ((getByte(index, src) orelse return Self.initErr(index, Error.DashDashEofInComment)) != '>') {
                                return Self.initErr(index, Error.DashDashInvalidInComment);
                            }
                            index += 1;

                            return Self.initTok(.comment, .{ .beg = start_index, .end = index });
                        }

                        return Self.initErr(index, Error.UnclosedComment);
                    },

                    'D' => switch (section) {
                        .root => return Self.initErr(index, Error.BangInvalidInRoot),
                        .trailing => return Self.initErr(index, Error.BangInvalidInTrailingSection),
                        .prologue => {
                            const expected_chars = "OCTYPE";
                            inline for (expected_chars) |expected_char| {
                                debug.assert(1 == (unicode.utf8ByteSequenceLength(expected_char) catch unreachable));
                                index += 1;
                                if ((getByte(index, src) orelse (expected_char +% 1)) != expected_char) {
                                    return Self.initErr(index, Error.BangInvalidInPrologue);
                                }
                            }
                            debug.assert(getByte(index, src).? == expected_chars[expected_chars.len - 1]);
                            index += 1;

                            switch (getByte(index, src) orelse return Self.initErr(index, Error.DoctypeStartEof)) {
                                ' ',
                                '\t',
                                '\n',
                                '\r',
                                => {},
                                else => return Self.initErr(index, Error.DoctypeStartInvalid),
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
                                return Self.initErr(index, Error.DoctypeInvalidRootNameStartChar);
                            }

                            const name_beg = index;
                            index += unicode.utf8CodepointSequenceLength(name_start_char) catch unreachable;

                            while (getUtf8(index, src)) |name_char| : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                                if (!xml.isValidUtf8NameChar(name_char)) break;
                            }

                            const tag = Token.Tag{ .dtd_start = .{ .name_beg = name_beg } };
                            const loc = Token.Loc{ .beg = start_index, .end = index };
                            return Self.initTok(tag, loc);
                        },
                    },

                    else => return Self.initErr(index, Error.BangInvalid),
                }
            },

            '/' => switch (section) {
                .prologue => return Self.initErr(index, Error.ElementCloseInPrologue),
                .trailing => return Self.initErr(index, Error.ElementCloseInTrailingSection),
                .root => {
                    index += 1;
                    const name_start_char = getUtf8(index, src) orelse return Self.initErr(index, Error.SlashEof);
                    if (!xml.isValidUtf8NameStartChar(name_start_char)) {
                        return Self.initErr(index, Error.InvalidElementCloseNameStartChar);
                    }
                    index += lenOfUtf8OrNull(name_start_char).?;

                    while (getUtf8(index, src)) |name_char| : (index += lenOfUtf8OrNull(name_char).?) {
                        if (!xml.isValidUtf8NameChar(name_char)) break;
                    }

                    return Self.initTok(.elem_close_tag, .{ .beg = start_index, .end = index });
                },
            },

            else => switch (section) {
                .trailing => return Self.initErr(index, Error.ElementOpenInTrailingSection),
                .prologue,
                .root,
                => {
                    const name_start_char = getUtf8(index, src) orelse return Self.initErr(index, Error.InvalidUtf8);
                    if (!xml.isValidUtf8NameStartChar(name_start_char)) {
                        return Self.initErr(index, Error.InvalidElementOpenNameStartChar);
                    }
                    index += lenOfUtf8OrNull(name_start_char).?;

                    while (getUtf8(index, src)) |name_char| : (index += lenOfUtf8OrNull(name_char).?) {
                        if (!xml.isValidUtf8NameChar(name_char)) break;
                    }

                    return Self.initTok(.elem_open_tag, .{ .beg = start_index, .end = index });
                },
            },
        }
    }

    pub fn get(self: @This()) Error!Token {
        return switch (self) {
            .tok => |tok| tok,
            .err => |err| err.code,
        };
    }

    pub fn getLastIndex(self: @This()) usize {
        return switch (self) {
            .tok => |tok| tok.loc.end,
            .err => |err| err.index,
        };
    }

    pub const Error = error{
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
        InvalidUtf8,
        InvalidElementOpenNameStartChar,
    };

    fn initErr(index: usize, code: Error) @This() {
        return @unionInit(@This(), "err", .{ .code = code, .index = index });
    }

    fn initTok(tag: Token.Tag, loc: Token.Loc) @This() {
        return @unionInit(@This(), "tok", Token.init(tag, loc));
    }
};

test "AfterLeftAngleBracket" {
    // Processing Instructions Target
    inline for (.{ .prologue, .root, .trailing }) |section| {
        inline for (.{ "A", "foo" }) |name|
            inline for (.{ (""), ("?>"), ("\t?>") }) |end| {
                const slice = "<?" ++ name;
                const src = slice ++ end;
                const tok = try AfterLeftAngleBracket.tokenize(section, 0, src).get();
                try testing.expectEqual(@as(Token.Tag, .pi_target), tok.tag);
                try testing.expectEqualStrings(slice, tok.slice(src));
                try testing.expectEqualStrings(name, tok.name(src).?);
            };
    }

    // Comment
    inline for (.{ .prologue, .root, .trailing }) |section| {
        inline for (.{ (""), ("- "), (" foo bar baz ") }) |comment_data| {
            const src = "<!--" ++ comment_data ++ "-->";
            const tok = try AfterLeftAngleBracket.tokenize(section, 0, src).get();
            try testing.expectEqual(@as(Token.Tag, .comment), tok.tag);
            try testing.expectEqualStrings(src, tok.slice(src));
            try testing.expectEqualStrings(comment_data, tok.data(src).?);
        }
    }

    // DTD start
    inline for (.{ (" "), ("\t"), ("\n\t") }) |whitespace| {
        inline for (.{ (""), ("["), (" [") }) |end| {
            const name = "root";
            const slice = "<!DOCTYPE" ++ whitespace ++ name;
            const src = slice ++ end;
            const tok = try AfterLeftAngleBracket.tokenize(.prologue, 0, src).get();
            try testing.expectEqual(Token.Tag.dtd_start, tok.tag);
            try testing.expectEqualStrings(slice, tok.slice(src));
            try testing.expectEqualStrings(name, tok.name(src).?);
        }
    }

    // CDATA section
    inline for (.{ "", " " }) |whitespace| {
        inline for (.{ (""), ("]"), ("]]"), ("]>"), ("foo") }) |base_cdata_data| {
            const cdata_data = base_cdata_data ++ whitespace;
            const src = "<![CDATA[" ++ cdata_data ++ "]]>";
            const tok = try AfterLeftAngleBracket.tokenize(.root, 0, src).get();
            try testing.expectEqual(@as(Token.Tag, .content_cdata), tok.tag);
            try testing.expectEqualStrings(src, tok.slice(src));
            try testing.expectEqualStrings(cdata_data, tok.data(src).?);

            try testing.expectError(error.BangSquareBracketInPrologue, AfterLeftAngleBracket.tokenize(.prologue, 0, src).get());
            try testing.expectError(error.BangSquareBracketInTrailingSection, AfterLeftAngleBracket.tokenize(.trailing, 0, src).get());
        }
    }

    // Element close tag
    inline for (.{ "A", "foo" }) |name| {
        inline for (.{ (""), (">"), ("\t>") }) |end| {
            const slice = "</" ++ name;
            const src = slice ++ end;
            const tok = try AfterLeftAngleBracket.tokenize(.root, 0, src).get();
            try testing.expectEqual(@as(Token.Tag, .elem_close_tag), tok.tag);
            try testing.expectEqualStrings(slice, tok.slice(src));
            try testing.expectEqualStrings(name, tok.name(src).?);

            try testing.expectError(error.ElementCloseInTrailingSection, AfterLeftAngleBracket.tokenize(.trailing, 0, src).get());
            try testing.expectError(error.ElementCloseInPrologue, AfterLeftAngleBracket.tokenize(.prologue, 0, src).get());
        }
    }

    // Element open tag
    inline for (.{ .prologue, .root }) |section| {
        inline for (.{ "A", "foo" }) |name|
            inline for (.{ (""), ("/>"), ("\t/>"), (">"), ("\t>") }) |end| {
                const slice = "<" ++ name;
                const src = slice ++ end;
                const tok = try AfterLeftAngleBracket.tokenize(section, 0, src).get();
                try testing.expectEqual(@as(Token.Tag, .elem_open_tag), tok.tag);
                try testing.expectEqualStrings(slice, tok.slice(src));
                try testing.expectEqualStrings(name, tok.name(src).?);

                try testing.expectError(error.ElementOpenInTrailingSection, AfterLeftAngleBracket.tokenize(.trailing, 0, src).get());
            };
    }
}

pub const ContentOrWhitespace = union(TokenOrError) {
    const Self = @This();
    tok: Token,
    err: struct {
        index: usize,
        code: Error,
    },

    pub fn tokenize(
        start_index: usize,
        src: []const u8,
    ) Self {
        debug.assert(if (getByte(start_index, src)) |char| switch (char) {
            '<' => false,
            else => true,
        } else false);
        var index: usize = start_index;

        switch (getByte(index, src) orelse return Self.initErr(index, Error.ImmediateEof)) {
            '&' => {
                index += 1;
                const name_start_char = getUtf8(index, src) orelse return Self.initErr(index, Error.EntityReferenceNameStartCharEof);
                if (!xml.isValidUtf8NameStartChar(name_start_char)) {
                    return Self.initErr(index, Error.EntityReferenceNameStartCharInvalid);
                }

                index += unicode.utf8CodepointSequenceLength(name_start_char) catch unreachable;
                while (getUtf8(index, src)) |name_char| : (index += unicode.utf8CodepointSequenceLength(name_char) catch unreachable) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }

                if ((getByte(index, src) orelse return Self.initErr(index, Error.UnterminatedEntityReferenceEof)) != ';') {
                    return Self.initErr(index, Error.UnterminatedEntityReferenceInvalid);
                }

                index += 1;
                return Self.initTok(.content_entity_ref, .{ .beg = start_index, .end = index });
            },

            else => {
                const non_whitespace_chars: bool = blk: {
                    while (getUtf8(index, src)) |content_char| : (index += lenOfUtf8OrNull(content_char).?) {
                        switch (content_char) {
                            ' ',
                            '\t',
                            '\n',
                            '\r',
                            => continue,
                            '<',
                            '&',
                            => break :blk false,
                            else => {
                                while (getUtf8(index, src)) |subsequent_content_char| : (index += lenOfUtf8OrNull(subsequent_content_char).?) {
                                    switch (subsequent_content_char) {
                                        '<',
                                        '&',
                                        => break :blk true,
                                        else => continue,
                                    }
                                } else return Self.initErr(index, Error.ContentFollowedByEof);
                            },
                        }
                    } else break :blk false;
                };

                const loc = Token.Loc{ .beg = start_index, .end = index };
                if (non_whitespace_chars) {
                    return Self.initTok(.content_text, loc);
                } else {
                    return Self.initTok(.whitespace, loc);
                }
            },
        }
    }

    pub fn get(self: *const @This()) Error!Token {
        return switch (self.*) {
            .tok => |tok| tok,
            .err => |err| err.code,
        };
    }

    pub fn getLastIndex(self: @This()) usize {
        return switch (self) {
            .tok => |tok| tok.loc.end,
            .err => |err| err.index,
        };
    }

    pub const Error = error{
        ImmediateEof,
        EntityReferenceNameStartCharEof,
        EntityReferenceNameStartCharInvalid,
        UnterminatedEntityReferenceEof,
        UnterminatedEntityReferenceInvalid,
        ContentFollowedByEof,
    };

    fn initTok(tag: Token.Tag, loc: Token.Loc) @This() {
        return @unionInit(@This(), "tok", Token.init(tag, loc));
    }

    fn initErr(index: usize, code: Error) @This() {
        return @unionInit(@This(), "err", .{ .code = code, .index = index });
    }
};

test "ContentOrWhitespace" {
    // Whitespace
    inline for (.{ (" "), ("\t"), ("    ") }) |slice| {
        inline for (.{ (""), ("<"), ("&") }) |end| {
            const src = slice ++ end;
            const tok = try ContentOrWhitespace.tokenize(0, src).get();
            try testing.expectEqual(Token.Tag.whitespace, tok.tag);
            try testing.expectEqualStrings(slice, tok.slice(src));
        }
    }
    // Text content
    inline for (.{ ("f"), (" foo bar baz "), (" z") }) |slice| {
        inline for (.{ ("<"), ("&") }) |end| {
            const src = slice ++ end;
            const tok = try ContentOrWhitespace.tokenize(0, src).get();
            try testing.expectEqual(Token.Tag.content_text, tok.tag);
            try testing.expectEqualStrings(slice, tok.slice(src));

            const src_no_end = slice;
            try testing.expectError(error.ContentFollowedByEof, ContentOrWhitespace.tokenize(0, src_no_end).get());
        }
    }

    // Entity reference content
    inline for (.{ ("amp"), ("A"), ("foo0") }) |name| {
        const slice = "&" ++ name ++ ";";
        const src = slice;
        const tok = try ContentOrWhitespace.tokenize(0, src).get();
        try testing.expectEqual(Token.Tag.content_entity_ref, tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
        try testing.expectEqualStrings(name, tok.name(src).?);
    }
}

/// Appears after tokenizing an element open tag.
/// Not guaranteed to succeed; may suggest to defer to another tokenizing strategy.
pub const AttributeNameOrElementCloseInline = union(TokenOrError) {
    const Self = @This();
    tok: Token,
    err: struct {
        index: usize,
        code: Error,
    },

    pub fn tokenize(
        continuation_start_index: usize,
        src: []const u8,
    ) Self {
        var index: usize = continuation_start_index;

        while (getByte(index, src)) |char| : (index += 1) switch (char) {
            ' ',
            '\t',
            '\n',
            '\r',
            => continue,
            else => break,
        } else return Self.initErr(index, Error.ImmediateEof);

        const start_index = index;
        switch (getUtf8(index, src) orelse return Self.initErr(index, Error.ImmediateInvalidUtf8)) {
            '/' => {
                index += 1;
                if ((getByte(index, src) orelse return Self.initErr(index, Error.SlashEof)) != '>') {
                    return Self.initErr(index, Error.SlashInvalid);
                }

                index += 1;
                return Self.initTok(.elem_close_inline, .{ .beg = start_index, .end = index });
            },

            '>' => {
                index += 1;
                switch (getUtf8(index, src) orelse return Self.initErr(index, Error.UnclosedElementOpenTagEof)) {
                    '<' => return Self.initErr(index, error.MustTokenizeAfterLeftAngleBracket),
                    else => return Self.initErr(index, error.MustTokenizeContent),
                }
            },

            else => {
                const name_start_char = getUtf8(index, src).?;
                if (!xml.isValidUtf8NameStartChar(name_start_char)) {
                    return Self.initErr(index, error.InvalidAttributeNameStartChar);
                }
                index += unicode.utf8CodepointSequenceLength(name_start_char) catch unreachable;

                while (getUtf8(index, src)) |name_char| : (index += lenOfUtf8OrNull(name_char).?) {
                    if (!xml.isValidUtf8NameChar(name_char)) break;
                }

                return Self.initTok(.attr_name, .{ .beg = start_index, .end = index });
            },
        }
    }

    pub fn get(self: @This()) Error!Token {
        return switch (self) {
            .tok => |tok| tok,
            .err => |err| err.code,
        };
    }

    pub fn getLastIndex(self: @This()) usize {
        return switch (self) {
            .tok => |tok| tok.loc.end,
            .err => |err| err.index,
        };
    }

    pub const Error = error{
        ImmediateEof,
        ImmediateInvalidUtf8,
        SlashEof,
        SlashInvalid,
        UnclosedElementOpenTagEof,
        InvalidAttributeNameStartChar,

        /// Following are not explicitly error messages; they are 100% guaranteed to be recoverable.
        /// They're more like signals to continue tokenizing with other appropriate functions.

        MustTokenizeAfterLeftAngleBracket,
        MustTokenizeContent,
    };

    fn initTok(tag: Token.Tag, loc: Token.Loc) @This() {
        return @unionInit(@This(), "tok", Token.init(tag, loc));
    }

    fn initErr(index: usize, code: Error) @This() {
        return @unionInit(@This(), "err", .{ .code = code, .index = index });
    }
};

test "AttributeNameOrElementCloseInline" {
    // Inline Close
    inline for (.{ (""), (" "), ("\n\t") }) |whitespace| {
        const slice = "/>";
        const src = whitespace ++ slice;
        const tok = try AttributeNameOrElementCloseInline.tokenize(0, src).get();
        try testing.expectEqual(Token.Tag.elem_close_inline, tok.tag);
        try testing.expectEqualStrings(slice, tok.slice(src));
    }

    // Attribute Name
    inline for (.{ (""), (" "), ("\n\t") }) |whitespace| {
        inline for (.{ (""), ("="), ("\t") }) |end| {
            const slice = "foo";
            const src = whitespace ++ slice ++ end;
            const tok = try AttributeNameOrElementCloseInline.tokenize(0, src).get();
            try testing.expectEqual(Token.Tag.attr_name, tok.tag);
            try testing.expectEqualStrings(slice, tok.slice(src));
        }
    }
}
