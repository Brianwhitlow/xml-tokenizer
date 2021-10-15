const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;
const testing = std.testing;
const unicode = std.unicode;

const xml = @import("../xml.zig");
const utility = @import("utility.zig");
const tokenize_strategies = @This();

const DocumentSection = xml.DocumentSection;
comptime {
    const expected_fields = .{
        "prologue",
        "root",
        "trailing",
    };
    
    debug.assert(meta.trait.hasFields(DocumentSection, expected_fields));
    debug.assert(meta.fields(DocumentSection).len == 3);
}

const Token = xml.Token;
comptime {
    const expected_fields = .{
        "pi_target",
        "pi_tok_string",
        "pi_tok_other",
        "pi_end",

        "whitespace",
        "comment",

        "elem_open_tag",
        "elem_close_tag",
        "elem_close_inline",

        "attr_name",
        "attr_val_empty",
        "attr_val_segment_text",
        "attr_val_segment_entity_ref",

        "content_text",
        "content_cdata",
        "content_entity_ref",
    };
    
    debug.assert(meta.trait.hasFields(xml.Token.Tag, expected_fields));
    debug.assert(meta.fields(xml.Token.Tag).len == expected_fields.len);
}

inline fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    debug.panic("TODO: " ++ fmt, if (@TypeOf(args) == @TypeOf(null)) .{} else args);
}

pub const TagGuess = enum {
    const Self = @This();
    elem_open_tag,
    elem_close_tag,
    pi_target,
    comment,
    content_cdata,

    comptime {
        _ = toTokenTag;
        const field_names = meta.fieldNames(Self);
        debug.assert(meta.trait.hasFields(Token.Tag, field_names));
    }

    /// Returns the built-in slice that has been used to guess the tag.
    pub fn checkedSlice(self: Self) []const u8 {
        return switch (self) {
            .elem_open_tag => "<",
            .elem_close_tag => "</",
            .pi_target => "<?",
            .comment => "<!-",
            .content_cdata => "<![",
        };
    }

    pub fn expectedSubsequentSlice(self: Self) ?[]const u8 {
        return switch (self) {
            .elem_open_tag => null,
            .elem_close_tag => null,
            .pi_target => null,
            .comment => "-",
            .content_cdata => "CDATA[",
        };
    }

    pub fn toTokenTag(self: Self) meta.Tag(Token.Tag) {
        return std.meta.stringToEnum(meta.Tag(Token.Tag), @tagName(self)).?;
    }

    pub const Error = @typeInfo(@typeInfo(@TypeOf(Self.guessFrom)).Fn.return_type.?).ErrorUnion.error_set;

    pub fn guessFrom(src: []const u8, start_index: usize) error{
        ImmediateEof,
        BangEof,
        BangUnrecognized,
    }!Self {
        debug.assert((utility.getByte(src, start_index) orelse 0) == '<');
        const result: Error!Self =
            if (utility.getByte(src, start_index + "<".len)) |byte0| switch (byte0) {
            '?' => Self.pi_target,
            '/' => Self.elem_close_tag,

            '!' => if (utility.getByte(src, start_index + "<!".len)) |byte1| switch (byte1) {
                '[' => Self.content_cdata,
                '-' => Self.comment,
                else => Error.BangUnrecognized,
            } else Error.BangEof,

            else => Self.elem_open_tag,
        } else Error.ImmediateEof;

        debug.assert(if (result) |guess| blk: {
            const expected = guess.checkedSlice();
            const actual = src[start_index .. start_index + expected.len];
            break :blk mem.eql(u8, expected, actual);
        } else |_| true);

        return result;
    }
};

test "TagGuess" {
    inline for (.{
        // note that the following characters aren't validated; it is left to the caller to then verify
        // that the subsequent bytes are valid.
        "foo",
        "  ",
        "0",
    }) |anything_else| {
        try testing.expectError(error.ImmediateEof, TagGuess.guessFrom("<", 0));
        try testing.expectEqual(TagGuess.elem_open_tag, try TagGuess.guessFrom("<" ++ anything_else, 0));

        try testing.expectEqual(TagGuess.content_cdata, try TagGuess.guessFrom("<![", 0));
        try testing.expectEqual(TagGuess.content_cdata, try TagGuess.guessFrom("<![" ++ anything_else, 0));

        try testing.expectEqual(TagGuess.comment, try TagGuess.guessFrom("<!-", 0));
        try testing.expectEqual(TagGuess.comment, try TagGuess.guessFrom("<!-" ++ anything_else, 0));

        try testing.expectEqual(TagGuess.elem_close_tag, try TagGuess.guessFrom("</", 0));
        try testing.expectEqual(TagGuess.elem_close_tag, try TagGuess.guessFrom("</" ++ anything_else, 0));

        try testing.expectEqual(TagGuess.pi_target, try TagGuess.guessFrom("<?", 0));
        try testing.expectEqual(TagGuess.pi_target, try TagGuess.guessFrom("<?" ++ anything_else, 0));
    }
}

fn ErrorAndIndex(comptime ErrorSet: type) type {
    return struct {
        index: usize,
        code: ErrorSet,
    };
}

fn TokenOrErrorAndIndex(comptime ErrorSet: type) type {
    return union(enum) {
        const Self = @This();
        tok: Token,
        err: @This().ErrorAndIndex,

        pub const Error = ErrorSet;
        pub const ErrorAndIndex = tokenize_strategies.ErrorAndIndex(Error);

        pub fn get(self: Self) ErrorSet!Token {
            return switch (self) {
                .tok => |tok| tok,
                .err => |err| err.code,
            };
        }

        pub fn lastIndex(self: Self) usize {
            return switch (self) {
                .tok => |tok| tok.loc.end,
                .err => |err| err.index,
            };
        }

        fn initTok(tok: Token) Self {
            return @unionInit(Self, "tok", tok);
        }

        fn initErr(index: usize, err: ErrorSet) Self {
            return @unionInit(Self, "err", .{ .index = index, .code = err });
        }
    };
}

pub const LeftAngleBracket = TokenOrErrorAndIndex(TagGuess.Error || error{
    ElementCloseInPrologue,

    ElementOpenInTrailing,
    ElementCloseInTrailing,

    ExpectedElementOpenName,
    ExpectedElementCloseName,

    ExpectedProcessingInstructionsTarget,

    ExpectedCommentDash,
    DashDashInComment,
    UnclosedComment,

    CDataSectionInPrologue,
    CDataSectionInTrailing,
    ExpectedCDataKeyword,
    UnclosedCDataSection,
});

pub fn leftAngleBracket(src: []const u8, start_index: usize, comptime document_section: xml.DocumentSection) LeftAngleBracket {
    const ResultType = LeftAngleBracket;

    debug.assert((utility.getByte(src, start_index) orelse 0) == '<');
    var index: usize = start_index;

    const expected_tag = TagGuess.guessFrom(src, start_index) catch |err| {
        index += @as(usize, switch (err) {
            error.ImmediateEof => 0,
            error.BangEof => 1,
            error.BangUnrecognized => 1,
        });
        return ResultType.initErr(index, err);
    };

    index += expected_tag.checkedSlice().len;

    switch (expected_tag) {
        .elem_close_tag,
        .elem_open_tag,
        => {
            switch (document_section) {
                .prologue => switch (expected_tag) {
                    .elem_open_tag => {},
                    .elem_close_tag => return ResultType.initErr(index, error.ElementCloseInPrologue),
                    else => unreachable,
                },

                .trailing => switch (expected_tag) {
                    .elem_open_tag => return ResultType.initErr(index, error.ElementOpenInTrailing),
                    .elem_close_tag => return ResultType.initErr(index, error.ElementCloseInTrailing),
                    else => unreachable,
                },

                .root => {},
            }

            const name_len = xml.validUtf8NameLength(src, index);
            if (name_len == 0) {
                const err_code = switch (expected_tag) {
                    .elem_open_tag => error.ExpectedElementOpenName,
                    .elem_close_tag => error.ExpectedElementCloseName,
                    else => unreachable,
                };
                return ResultType.initErr(index, err_code);
            }

            index += name_len;
        },

        .pi_target => {
            const target_name_len = xml.validUtf8NameLength(src, index);
            if (target_name_len == 0) return ResultType.initErr(index, error.ExpectedProcessingInstructionsTarget);
            index += target_name_len;
            return ResultType.initTok(Token.init(.pi_target, .{ .beg = start_index, .end = index }));
        },

        .comment => {
            const expected_subsequent_slice = expected_tag.expectedSubsequentSlice().?;
            const actual_subsequent_slice = utility.clampedSubSlice(src, index, index + expected_subsequent_slice.len);

            if (expected_subsequent_slice.len != actual_subsequent_slice.len) {
                return ResultType.initErr(index, error.ExpectedCommentDash);
            }

            for (expected_subsequent_slice) |char| {
                if (char != (utility.getByte(src, index) orelse char + 1)) {
                    return ResultType.initErr(index, error.ExpectedCommentDash);
                }
                index += utility.lenOfUtf8OrNull(char).?;
            }

            while (utility.getUtf8(src, index)) |comment_char| : (index += utility.lenOfUtf8OrNull(comment_char).?) {
                if (comment_char != '-') continue;
                if ((utility.getByte(src, index + "-".len) orelse 0) != '-') continue;
                if ((utility.getByte(src, index + "--".len) orelse 0) != '>') return ResultType.initErr(index, error.DashDashInComment);

                index += ("-->".len);
                break;
            } else return ResultType.initErr(index, error.UnclosedComment);
        },

        .content_cdata => {
            switch (document_section) {
                .prologue => return ResultType.initErr(index, error.CDataSectionInPrologue),
                .trailing => return ResultType.initErr(index, error.CDataSectionInTrailing),
                .root => {},
            }

            const expected_subsequent_slice = expected_tag.expectedSubsequentSlice().?;
            const actual_subsequent_slice = utility.clampedSubSlice(src, index, index + expected_subsequent_slice.len);

            if (expected_subsequent_slice.len != actual_subsequent_slice.len) {
                return ResultType.initErr(index, error.ExpectedCDataKeyword);
            }

            for (expected_subsequent_slice) |char| {
                if (char != (utility.getByte(src, index) orelse char + 1)) {
                    return ResultType.initErr(index, error.ExpectedCDataKeyword);
                }
                index += utility.lenOfUtf8OrNull(char).?;
            }

            while (utility.getUtf8(src, index)) |cdata_char| : (index += utility.lenOfUtf8OrNull(cdata_char).?) {
                if (cdata_char != ']') continue;
                if (!mem.eql(u8, utility.clampedSubSlice(src, index + "]".len, index + "]]>".len), "]>")) continue;

                index += ("]]>".len);
                break;
            } else return ResultType.initErr(index, error.UnclosedCDataSection);
        },
    }

    return ResultType.initTok(Token.init(expected_tag.toTokenTag(), .{ .beg = start_index, .end = index }));
}

test "leftAngleBracket" {
    // stress testing
    @setEvalBranchQuota(1500);
    inline for (.{ .prologue, .root, .trailing }) |document_section| {
        inline for (.{ (""), ("\t\n"), ("wrfwfn34908jdjo239u") }) |start| {
            inline for (.{ (""), ("   "), ("/"), (">"), ("/>"), ("\t/>") }) |end| {
                inline for (.{ ("foobar"), ("foo:bar"), ("A"), (":foo:bar:baz:") }) |name| {
                    if (document_section != .trailing) {
                        const slice = "<" ++ name;
                        const src = start ++ slice ++ end;
                        const result = leftAngleBracket(src, start.len, document_section);
                        const tok = try result.get();
                        try testing.expectEqual(Token.Tag.elem_open_tag, tok.tag);
                        try testing.expectEqualStrings(slice, tok.slice(src));
                        try testing.expectEqualStrings(name, tok.name(src) orelse return testing.expect(false));
                    }

                    if (document_section == .root) {
                        const slice = "</" ++ name;
                        const src = start ++ slice ++ end;
                        const result = leftAngleBracket(src, start.len, document_section);
                        const tok = try result.get();
                        try testing.expectEqual(Token.Tag.elem_close_tag, tok.tag);
                        try testing.expectEqualStrings(slice, tok.slice(src));
                        try testing.expectEqualStrings(name, tok.name(src) orelse return testing.expect(false));
                    }

                    {
                        const slice = "<?" ++ name;
                        const src = start ++ slice ++ end;
                        const result = leftAngleBracket(src, start.len, document_section);
                        const tok = try result.get();
                        try testing.expectEqualStrings(slice, tok.slice(src));
                        try testing.expectEqualStrings(name, tok.name(src) orelse return testing.expect(false));
                    }
                }
            }

            inline for (.{("<")}) |comment_data| {
                const slice = "<!--" ++ comment_data ++ "-->";
                const src = start ++ slice;
                const result = leftAngleBracket(src, start.len, document_section);
                const tok = try result.get();
                try testing.expectEqual(Token.Tag.comment, tok.tag);
                try testing.expectEqualStrings(slice, tok.slice(src));
                try testing.expectEqualStrings(comment_data, tok.data(src) orelse return testing.expect(false));
            }

            if (document_section == .root) inline for (.{ "", "<", "]", "]]", "]>", "foo bar baz" }) |char_data| {
                const slice = "<![CDATA[" ++ char_data ++ "]]>";
                const src = start ++ slice;
                const result = leftAngleBracket(src, start.len, document_section);
                const tok = try result.get();
                try testing.expectEqual(Token.Tag.content_cdata, tok.tag);
                try testing.expectEqualStrings(slice, tok.slice(src));
                try testing.expectEqualStrings(char_data, tok.data(src) orelse return testing.expect(false));
            };
        }
    }

    const valid_elem_name = [_]u8{xml.valid_name_start_char};
    const invalid_elem_name = [_]u8{xml.invalid_name_start_char};
    inline for (comptime meta.fieldNames(LeftAngleBracket.Error)) |err_name| {
        const err: LeftAngleBracket.Error = @field(LeftAngleBracket.Error, err_name);
        switch (err) {
            error.ImmediateEof => try testing.expectError(err, leftAngleBracket("<", 0, .root).get()),
            error.BangEof => try testing.expectError(err, leftAngleBracket("<!", 0, .root).get()),
            error.BangUnrecognized => try testing.expectError(err, leftAngleBracket("<!D", 0, .root).get()),
            error.ElementCloseInPrologue => try testing.expectError(err, leftAngleBracket("</", 0, .prologue).get()),
            error.ElementOpenInTrailing => try testing.expectError(err, leftAngleBracket("<" ++ valid_elem_name, 0, .trailing).get()),
            error.ElementCloseInTrailing => try testing.expectError(err, leftAngleBracket("</", 0, .trailing).get()),
            error.ExpectedElementOpenName => try testing.expectError(err, leftAngleBracket("<" ++ invalid_elem_name, 0, .root).get()),
            error.ExpectedElementCloseName => try testing.expectError(err, leftAngleBracket("</" ++ invalid_elem_name, 0, .root).get()),
            error.ExpectedProcessingInstructionsTarget => try testing.expectError(err, leftAngleBracket("<?", 0, .root).get()),
            error.ExpectedCommentDash => try testing.expectError(err, leftAngleBracket("<!- ", 0, .root).get()),
            error.DashDashInComment => try testing.expectError(err, leftAngleBracket("<!-- -- ", 0, .root).get()),
            error.UnclosedComment => try testing.expectError(err, leftAngleBracket("<!-- ", 0, .root).get()),
            error.CDataSectionInPrologue => try testing.expectError(err, leftAngleBracket("<![CDATA[ ]]>", 0, .prologue).get()),
            error.CDataSectionInTrailing => try testing.expectError(err, leftAngleBracket("<![CDATA[ ]]>", 0, .trailing).get()),
            error.ExpectedCDataKeyword => try testing.expectError(err, leftAngleBracket("<![CDAT ]]>", 0, .root).get()),
            error.UnclosedCDataSection => try testing.expectError(err, leftAngleBracket("<![CDATA[ ]]", 0, .root).get()),
        }
    }
}
