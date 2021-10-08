const std = @import("std");
const debug = std.debug;
const unicode = std.unicode;
const testing = std.testing;

const xml = @import("../xml.zig");

const TokenStream = @This();
buffer: []const u8,
state: State,

pub fn init(src: []const u8) TokenStream {
    return TokenStream {
        .buffer = src,
        .state = .{},
    };
}

pub fn reset(self: *TokenStream, new_src: ?[]const u8) void {
    self.* = TokenStream.init(new_src orelse self.buffer);
}

fn copy(self: TokenStream) TokenStream {
    return self;
}

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    
    pub fn init(tag: Tag, loc: Loc) Token {
        return Token {
            .tag = tag,
            .loc = loc,
        };
    }
    
    pub const Loc = struct {
        start: usize,
        end: usize,
    };
    
    pub const Tag = union(enum) {
        pi_target,
        pi_string,
        pi_tok,
        pi_end,
        
        dtd_tok,
        
        comment,
        whitespace,
        
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
        
        pub fn hasName(self: @This()) bool {
            return switch (self) {
                .dtd_tok => todo("Consider DTD tokens.", .{}),
                
                .pi_tok,
                .pi_string,
                .pi_end,
                .comment,
                .whitespace,
                .elem_close_inline,
                .attr_name,
                .attr_val_empty,
                .attr_val_segment_text,
                .content_text,
                .content_cdata,
                => false,
                
                .pi_target,
                .elem_open_tag,
                .elem_close_tag,
                .attr_val_segment_entity_ref,
                .content_entity_ref,
                => true,
            };
        }
        
        pub fn hasData(self: @This()) bool {
            return switch (self) {
                .dtd_tok => todo("Consider DTD tokens.", .{}),
                
                .pi_target,
                .pi_tok,
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
                => false,
                
                .pi_string,
                .comment,
                .content_cdata,
                => true,
            };
        }
    };
    
    pub fn slice(self: Token, src: []const u8) []const u8 {
        return src[self.loc.start..self.loc.end];
    }
    
    pub fn name(self: Token, src: []const u8) ?[]const u8 {
        if (!self.tag.hasName()) return null;
        const sliced = self.slice(src);
        
        const offset_fwd = switch (self.tag) {
            .pi_target => ("<?").len,
            .elem_open_tag => ("<").len,
            .elem_close_tag => ("</").len,
            .attr_val_segment_entity_ref => ("&").len,
            .content_entity_ref => ("&").len,
            else => unreachable,
        };
        
        const offset_bkwd = switch (self.tag) {
            .pi_target => ("").len,
            .elem_open_tag => ("").len,
            .elem_close_tag => ("").len,
            .attr_val_segment_entity_ref => (";").len,
            .content_entity_ref => (";").len,
            else => unreachable,
        };
        
        const beg = 0 + offset_fwd;
        const end = sliced.len - offset_bkwd;
        return sliced[beg..end];
    }
    
    pub fn data(self: Token, src: []const u8) ?[]const u8 {
        if (!self.tag.hasData()) return null;
        const sliced = self.slice(src);
        
        const offset_fwd = switch (self.tag) {
            .pi_string => blk: {
                const blk_out = ("'".len);
                std.debug.assert(blk_out == "\"".len);
                break :blk blk_out;
            },
            .comment => ("<!--".len),
            .content_cdata => ("<![CDATA[".len),
            else => unreachable,
        };
        
        const offset_bkwd = switch (self.tag) {
            .pi_string => blk: {
                const blk_out = ("'".len);
                std.debug.assert(blk_out == "\"".len);
                break :blk blk_out;
            },
            .comment => ("-->".len),
            .content_cdata => ("]]>".len),
            else => unreachable,
        };
        
        const beg = 0 + offset_fwd;
        const end = sliced.len - offset_bkwd;
        return sliced[beg..end];
    }
};

pub const NextRet = ?(Error!Token);
pub const Error = error {};

pub fn next(self: *TokenStream) NextRet {
    const state: *State = &self.state;
    switch (self.state.info) {
        .start => {
            debug.assert(state.index == 0);
            const start_char = self.getByte() orelse return self.setEndReturnNull();
            
            const result = switch (start_char) {
                ' ',
                '\t',
                '\n',
                '\r',
                => self.tokenizeWhitespace(),
                '<' => self.tokenizeAfterLeftAngleBracket() catch |err| switch (err) {
                    else => todo("Handle {}.", .{err}),
                },
                else => return todo("Error for character '{c}' in prologue.", .{self.getByte().?}),
            };
            
            return self.prologueSetStateUsing(result);
        },
        
        .prologue => |prologue_tag| {
            switch (prologue_tag) {
                .pi_target => todo("Tokenize after prologue 'pi_target'.", .{}),
                .pi_string => todo("Tokenize after prologue 'pi_string'.", .{}),
                .pi_tok => todo("Tokenize after prologue 'pi_tok'.", .{}),
                .pi_end => todo("Tokenize after prologue 'pi_end'.", .{}),
                
                .dtd_tok => todo("Tokenize after prologue 'dtd_tok'.", .{}),
                
                .comment => {
                    std.debug.assert(self.getByte().? == '>');
                    state.index += 1;
                    switch (self.getByte() orelse {
                        state.info = .end;
                        return null;
                    }) {
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => {
                            const result = self.tokenizeWhitespace();
                            state.info.prologue = result.tag;
                            return @as(NextRet, result);
                        },
                        '<' => {
                            const result = self.tokenizeAfterLeftAngleBracket() catch |err| switch (err) {
                                else => todo("Handle {}.", .{err}),
                            };
                            
                            return self.prologueSetStateUsing(result);
                        },
                        else => todo("Error for character '{u}' in prologue.", .{self.getByte().?})
                    }
                },
                .whitespace => {
                    if ('<' != self.getByte() orelse return self.setEndReturnNull()) return todo("Error for character '{c}' in prologue.", .{self.getByte().?});
                    
                    const result = self.tokenizeAfterLeftAngleBracket() catch |err| switch (err) {
                        else => todo("Handle {}.", .{err}),
                    };
                    
                    return self.prologueSetStateUsing(result);
                },
                
                .elem_open_tag => unreachable,
                .elem_close_tag => unreachable,
                .elem_close_inline => unreachable,
                
                .attr_name => unreachable,
                .attr_val_empty => unreachable,
                .attr_val_segment_text => unreachable,
                .attr_val_segment_entity_ref => unreachable,
                
                .content_text => unreachable,
                .content_cdata => unreachable,
                .content_entity_ref => unreachable,
            }
        },
        
        .root => |root_tag| {
            _ = root_tag;
            todo("Tokenize after root_tag.", .{});
        },
        
        .trailing => |trailing_tag| {
            _ = trailing_tag;
            todo("Tokenize after trailing_tag.", .{});
        },
        
        .cached_err => |cached_err| {
            state.info = .end;
            return cached_err;
        },
        
        .end => return null,
    }
}

inline fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    debug.panic("TODO: " ++ fmt ++ "\n", args);
}

const State = struct {
    index: usize = 0,
    depth: usize = 0,
    last_quote: ?StringQuote = null,
    info: Info = .start,
    
    const Info = union(enum) {
        start,
        prologue: Token.Tag,
        root: Token.Tag,
        trailing: Token.Tag,
        cached_err: Error,
        end,
    };
    
    const StringQuote = enum(u8) {
        const Self = @This();
        single = '\'',
        double = '"',
        
        fn init(char: u8) Self {
            return switch (char) {
                '\'',
                '"',
                => @intToEnum(Self, char),
                else => unreachable,
            };
        }
        
        fn initUtf8(codepoint: u21) Self {
            return switch (codepoint) {
                '\'',
                '"',
                => return Self.init(@intCast(u8, codepoint)),
                else => unreachable,
            };
        }
        
        fn value(self: Self) u8 {
            return @enumToInt(self);
        }
    };
};

fn setEndReturnNull(self: *TokenStream) NextRet {
    self.state.info = .end;
    return null;
}



fn tokenizeAfterLeftAngleBracket(self: *TokenStream) error {
    ImmediateEof,
    BangEof,
    BangDashEof,
    BangDashInvalid,
    UnclosedCommentEof,
    DashDashEof,
    DashDashInvalid
}!Token {
    const state: *State = &self.state;
    std.debug.assert(self.getByte().? == '<');
    
    const start_index = state.index;
    state.index += 1;
    switch (self.getByte() orelse return error.ImmediateEof) {
        '?' => todo("Tokenize after '<?'.", .{}),
        '!' => {
            state.index += 1;
            switch (self.getByte() orelse return error.BangEof) {
                '-' => {
                    state.index += 1;
                    if ((self.getByte() orelse return error.BangDashEof) != '-') {
                        return error.BangDashInvalid;
                    }
                    
                    state.index += 1;
                    while (self.getUtf8()) |char| {
                        if (char == '-') {
                            state.index += 1;
                            if ((self.getByte() orelse return error.UnclosedCommentEof) != '-') continue;
                            
                            state.index += 1;
                            if ((self.getByte() orelse return error.DashDashEof) != '>') return error.DashDashInvalid;
                            
                            break;
                        }
                        state.index += unicode.utf8CodepointSequenceLength(char) catch unreachable;
                    } else return error.UnclosedCommentEof;
                    
                    std.debug.assert(self.getByte().? == '>');
                    return Token.init(.comment, .{ .start = start_index, .end = state.index + 1 });
                },
                '[' => todo("Tokenize after '<!['.", .{}),
                else => todo("Error for character '{c}' where '-' or '[' was expected.", .{self.getByte().?}),
            }
        },
        else => todo("Tokenize after '<{c}'", .{self.getByte().?}),
    }
}

fn tokenizeWhitespace(self: *TokenStream) Token {
    const state: *State = &self.state;
    std.debug.assert(switch (self.getByte().?) {
        ' ',
        '\t',
        '\n',
        '\r',
        => true,
        else => false,
    });
    
    const start_index = state.index;
    state.index += 1;
    while (self.getByte()) |subsequent_char| switch (subsequent_char) {
        ' ',
        '\t',
        '\n',
        '\r',
        => state.index += 1,
        else => break,
    };
    
    return Token.init(.whitespace, .{ .start = start_index, .end = state.index });
}



fn prologueSetStateUsing(self: *TokenStream, result: Token) NextRet {
    const state: *State = &self.state;
    switch (result.tag) {
        .pi_target => todo("Tokenize pi_target.", .{}),
        .pi_string => unreachable,
        .pi_tok => unreachable,
        .pi_end => unreachable,
        
        .dtd_tok => todo("Tokenize dtd_tok.", .{}),
        
        .comment => state.info = .{ .prologue = result.tag },
        .whitespace => state.info = .{ .prologue = result.tag },
        
        .elem_open_tag => todo("Tokenize elem_open_tag.", .{}),
        .elem_close_tag => unreachable,
        .elem_close_inline => unreachable,
        
        .attr_name => unreachable,
        .attr_val_empty => unreachable,
        .attr_val_segment_text => unreachable,
        .attr_val_segment_entity_ref => unreachable,
        
        .content_text => unreachable,
        .content_cdata => {
            const err = todo("Assign error to CDATA section in prologue.", .{});
            state.info = .{ .cached_err = err };
            return @as(NextRet, err);
        },
        .content_entity_ref => unreachable,
    }
    
    return @as(NextRet, result);
}



fn getByte(self: TokenStream) ?u8 {
    const index = self.state.index;
    const buffer = self.buffer;
    const in_range = (index < buffer.len);
    return if (in_range) buffer[index] else null;
}

fn getUtf8(self: TokenStream) ?u21 {
    return blk: {
        const start_byte = self.getByte() orelse break :blk null;
        const sequence_len = unicode.utf8ByteSequenceLength(start_byte) catch break :blk null;
        
        const beg = self.state.index;
        const end = beg + sequence_len;
        if (end > self.buffer.len) break :blk null;
        
        break :blk unicode.utf8Decode(self.buffer[beg..end]) catch null;
    };
}


const tests = struct {
    const token = struct {
        fn expectTokenTagAndSlice(src: []const u8, tok: Token, expected_tag: Token.Tag, expected_slice_components: []const []const u8) !void {
            std.debug.assert(expected_slice_components.len != 0);
            try testing.expectEqual(expected_tag, tok.tag);
            
            const expected_slice: []const u8 = try std.mem.concat(testing.allocator, u8, expected_slice_components);
            defer testing.allocator.free(expected_slice);
            try testing.expectEqualStrings(expected_slice, tok.slice(src));
        }
        
        fn expectProcessingInstructionsTarget(src: []const u8, tok: Token, name: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .pi_target, &.{ "<?", name });
            try testing.expectEqualStrings(tok.name(src).?, name);
        }
        
        fn expectProcessingInstructionsToken(src: []const u8, tok: Token, slice: []const u8) !void {
            _ = src;
            _ = tok;
            _ = slice;
            todo("Consider this test.", .{});
        }
        
        fn expectProcessingInstructionsEnd(src: []const u8, tok: Token) !void {
            try expectTokenTagAndSlice(src, tok, .pi_end, .{ "?>" });
        }
        
        fn expectDtdToken() !void {
            todo("Consider how to test DTD tokens.", .{});
        }
        
        fn expectComment(src: []const u8, tok: Token, data: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .comment, &.{ "<!--", data, "-->" });
            try testing.expectEqualStrings(data, tok.data(src).?);
        }
        
        fn expectWhitespace(src: []const u8, tok: Token, whitespace: []const u8) !void {
            debug.assert(whitespace.len != 0 and for (whitespace) |char| switch (char) {
                ' ',
                '\t',
                '\n',
                '\r',
                => {},
                else => break false,
            } else true);
            
            try expectTokenTagAndSlice(src, tok, .whitespace, &.{ whitespace });
        }
        
        fn expectElementOpenTag(src: []const u8, tok: Token, name: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .elem_open_tag, &.{ "<", name });
            try testing.expectEqualStrings(name, tok.name(src).?);
        }
        
        fn expectElementCloseTag(src: []const u8, tok: Token, name: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .elem_close_tag, &.{ "</", name });
            try testing.expectEqualStrings(name, tok.name(src).?);
        }
        
        fn expectElementCloseInline(src: []const u8, tok: Token) !void {
            try expectTokenTagAndSlice(src, tok, .elem_close_inline, &.{ "/>" });
        }
        
        fn expectAttributeName(src: []const u8, tok: Token, name: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .attr_name, &.{ name });
        }
        
        fn expectAttributeValueSegmentEmpty(src: []const u8, tok: Token) !void {
            try expectTokenTagAndSlice(src, tok, .attr_val_empty, &.{ "" });
        }
        
        fn expectAttributeValueSegmentText(src: []const u8, tok: Token, data: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .attr_val_segment_text, &.{ data });
        }
        
        fn expectAttributeValueSegmentEntityRef(src: []const u8, tok: Token, name: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .attr_val_segment_entity_ref, &.{ "&", name, ";" });
            try testing.expectEqualStrings(name, tok.name(src).?);
        }
        
        fn expectContentText(src: []const u8, tok: Token, data: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .content_text, &.{ data });
        }
        
        fn expectContentCharData(src: []const u8, tok: Token, data: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .content_cdata, &.{ "<![CDATA[", data, "]]>" });
            try testing.expectEqualStrings(data, tok.data(src).?);
        }
        
        fn expectContentEntityReference(src: []const u8, tok: Token, name: []const u8) !void {
            try expectTokenTagAndSlice(src, tok, .content_entity_ref, &.{ "&", name, ";" });
            try testing.expectEqualStrings(name, tok.name(src).?);
        }
    };
    
    const token_stream = struct {
        
        fn expectWhitespace(ts: *TokenStream, whitespace: []const u8) !void {
            const tok = try (ts.next() orelse error.NullToken);
            try token.expectWhitespace(ts.buffer, tok, whitespace);
        }
        
        fn expectComment(ts: *TokenStream, data: []const u8) !void {
            const tok = try (ts.next() orelse error.NullToken);
            try token.expectComment(ts.buffer, tok, data);
        }
        
        
        
        fn expectError(ts: *TokenStream, err: TokenStream.Error) !void {
            try testing.expectError(err, ts.next());
        }
        
        fn expectNull(ts: *TokenStream) !void {
            const T = TokenStream.NextRet;
            const expected = @as(T, null);
            const actual = ts.next();
            try testing.expectEqual(expected, actual);
        }
    };
};


test "empty source" {
    var ts = TokenStream.init("");
    try tests.token_stream.expectNull(&ts);
}

test "whitespace source" {
    var ts = TokenStream.init(undefined);
    
    const spaces = [_][1:0]u8{ " ".*, "\t".*, "\n".*, "\r".* };
    inline for (spaces) |s0|
    inline for (spaces) |s1|
    inline for (spaces) |s2|
    inline for (spaces) |s3|
    inline for (.{1, 2, 3}) |mul0|
    inline for (.{1, 2, 3}) |mul1|
    {
        @setEvalBranchQuota(12_000);
        const whitespace = ((s0 ** mul1) ++ (s1 ** mul1) ++ (s2 ** mul1) ++ (s3 ** mul1)) ** mul0;
        ts.reset(&whitespace);
        try tests.token_stream.expectWhitespace(&ts, &whitespace);
        try tests.token_stream.expectNull(&ts);
    };
}

test "lone comment" {
    var ts = TokenStream.init(undefined);
    
    inline for (.{
        "",
        "- ",
        "foo bar baz",
    }) |comment_content| {
        ts.reset("<!--" ++ comment_content ++ "-->");
        try tests.token_stream.expectComment(&ts, comment_content);
        try tests.token_stream.expectNull(&ts);
        
        ts.reset("<!--" ++ comment_content ++ "-->\t");
        try tests.token_stream.expectComment(&ts, comment_content);
        try tests.token_stream.expectWhitespace(&ts, "\t");
        try tests.token_stream.expectNull(&ts);
        
        ts.reset("\t<!--" ++ comment_content ++ "-->");
        try tests.token_stream.expectWhitespace(&ts, "\t");
        try tests.token_stream.expectComment(&ts, comment_content);
        try tests.token_stream.expectNull(&ts);
    }
}
