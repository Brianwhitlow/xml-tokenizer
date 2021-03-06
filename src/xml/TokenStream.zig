const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;
const testing = std.testing;

const assert = debug.assert;

const xml = @import("xml.zig");
const utility = @import("utility.zig");

fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    debug.panic("TODO: " ++ fmt ++ "\n", if (@TypeOf(args) == @TypeOf(null)) .{} else args);
}

const Token = xml.Token;

const TokenStream = @This();
src: []const u8,
state: State,

pub fn init(src: []const u8) TokenStream {
    return .{
        .src = src,
        .state = .{
            .index = 0,
            .depth = 0,
            .mode = .{ .prologue = .start },
            .last_attr_quote = null,
        }
    };
}

pub fn reset(ts: *TokenStream, new_src: ?[]const u8) void {
    ts.* = TokenStream.init(new_src orelse ts.src);
}

pub const NextReturnType = ?Result;
pub const Result = union(enum) {
    const Self = @This();
    token: Token,
    err: Error,
    
    pub const Error = error {
        
    };
    
    pub fn getToken(self: Self) Error!Token {
        return switch (self) {
            .token => |token| token,
            .err => |err| err,
        };
    }
    
    fn initToken(tag: Token.Tag, loc: Token.Loc) Self {
        return @unionInit(Self, "token", Token.init(tag, loc));
    }
    
    fn initError(err: Error) Self {
        return @unionInit(Self, "err", err);
    }
};

pub fn next(ts: *TokenStream) NextReturnType {
    switch (ts.state.mode) {
        .prologue => |prologue| {
            assert(ts.state.depth == 0);
            defer {
                const depth_is_0 = (ts.state.depth == 0);
                switch (ts.state.mode) {
                    .prologue,
                    .trailing,
                    => assert(depth_is_0),
                    .root => assert(!depth_is_0),
                }
            }
            
            switch (prologue) {
                .start => {
                    //defer {
                    //    //const bad_State = !switch (ts.state.mode) {
                    //    //    .prologue => |end_prologue_state| end_prologue_state != .start,
                    //    //    else => true,
                    //    //};
                    //    //_ = bad_State;
                    //    //if (bad_State) `std.debug.panic("std.assert(false)` should be here", .{});
                    //}
                    assert(ts.state.index == 0);
                    const start_index = ts.state.index;
                    
                    ts.state.index += xml.whitespaceLength(ts.src, ts.state.index);
                    if (ts.state.index != 0) {
                        const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
                        return ts.returnToken(.prologue, .whitespace, loc);
                    }
                    
                    return switch (utility.getByte(ts.src, ts.state.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => todo("error.prologue_start_nonwhitespace", null),
                    };
                },
                
                .pi_target => return ts.tokenizeAfterPiTarget(.prologue),
                .pi_tok_string => return ts.tokenizeAfterPiTokString(.prologue),
                .pi_tok_other => return ts.tokenizeAfterPiTokOther(.prologue),
                .pi_end => return ts.tokenizeAfterPiEnd(.prologue),
                
                .whitespace => {
                    assert(ts.state.index != 0);
                    return switch (utility.getByte(ts.src, ts.state.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => todo("error.prologue_whitespace_invalid", null),
                    };
                },
                .comment => {
                    assert(ts.src[ts.state.index - 1] == '>');
                    switch (utility.getByte(ts.src, ts.state.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => return ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => {
                            const start_index = ts.state.index;
                            const whitespace_len = xml.whitespaceLength(ts.src, ts.state.index);
                            ts.state.index += whitespace_len;
                            if (whitespace_len == 0) {
                                return todo("error.prologue_comment_invalid", null);
                            }
                            
                            const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
                            return ts.returnToken(.prologue, .whitespace, loc);
                        },
                    }
                },
            }
        },
        
        .root => |root| {
            assert(ts.state.depth != 0);
            defer {
                const depth_is_0 = (ts.state.depth == 0);
                const state_is_not_root = (ts.state.mode != .root);
                if (depth_is_0 or state_is_not_root) {
                    assert(depth_is_0 and state_is_not_root);
                }
                assert(ts.state.mode != .prologue);
            }
            
            switch (root) {
                .pi_target => return ts.tokenizeAfterPiTarget(.root),
                .pi_tok_string => return ts.tokenizeAfterPiTokString(.root),
                .pi_tok_other => return ts.tokenizeAfterPiTokOther(.root),
                .pi_end => return ts.tokenizeAfterPiEnd(.root),
                
                .whitespace => switch (utility.getByte(ts.src, ts.state.index) orelse todo("error.root_whitespace_eof", null)) {
                    '<' => return ts.tokenizeAfterLeftAngleBracket(.root),
                    '&' => return ts.tokenizeContentEntityRef(),
                    else => todo("error.root_whitespace_invalid", null),
                },
                
                .elem_open => return ts.tokenizeAfterElementOpenOrAttributeValueEnd(),
                
                .elem_close_inline,
                .elem_close_tag,
                => {
                    ts.sideEffectsAfterElementCloseTagOrInline(.root);
                    switch (utility.getByte(ts.src, ts.state.index) orelse switch (root) {
                        .elem_close_inline => todo("error.root_elem_close_inline_eof", null),
                        .elem_close_tag => todo("error.root_elem_close_tag_eof", null),
                        else => unreachable,
                    }) {
                        '<' => return ts.tokenizeAfterLeftAngleBracket(.root),
                        '&' => return ts.tokenizeContentEntityRef(),
                        else => return ts.tokenizeContentTextOrWhitespace(),
                    }
                },
                
                .attr_name => {
                    assert(ts.state.last_attr_quote == null);
                    
                    ts.state.index += xml.whitespaceLength(ts.src, ts.state.index);
                    if (utility.getByte(ts.src, ts.state.index) orelse todo("error.root_attr_name_eof", null) != '=') {
                        todo("error.root_attr_name_invalid", null);
                    }
                    ts.state.index += 1;
                    ts.state.index += xml.whitespaceLength(ts.src, ts.state.index);
                    const quote = utility.getByte(ts.src, ts.state.index) orelse todo("error.root_attr_name_equals_eof", null);
                    if (!xml.isStringQuote(quote)) {
                        todo("error.root_attr_name_equals_invalid", null);
                    }
                    
                    ts.state.index += 1;
                    const start_index = ts.state.index;
                    
                    const start_byte = utility.getByte(ts.src, ts.state.index) orelse todo("error.root_attr_name_equals_quote_eof", null);
                    if (start_byte == quote) {
                        const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
                        const tag = Token.Tag.attr_val_empty;
                        return ts.returnToken(.root, tag, loc);
                    }
                    
                    ts.state.last_attr_quote = xml.StringQuote.from(quote);
                    return ts.tokenizeAttributeValueSegment();
                },
                
                .attr_val_empty => {
                    assert(ts.state.last_attr_quote == null);
                    assert(xml.isStringQuote(utility.getByte(ts.src, ts.state.index).?));
                    ts.state.index += 1;
                    return ts.tokenizeAfterElementOpenOrAttributeValueEnd();
                },
                
                .attr_val_segment_text,
                .attr_val_segment_entity_ref,
                => {
                    assert(ts.state.last_attr_quote != null);
                    
                    const start_byte = utility.getByte(ts.src, ts.state.index).?;
                    if (start_byte == ts.state.last_attr_quote.?.value()) {
                        ts.state.last_attr_quote = null;
                        ts.state.index += 1;
                        return ts.tokenizeAfterElementOpenOrAttributeValueEnd();
                    }
                    
                    return ts.tokenizeAttributeValueSegment();
                },
                
                .content_text => switch (utility.getByte(ts.src, ts.state.index) orelse todo("error.root_content_text_eof", null)) {
                    '<' => return ts.tokenizeAfterLeftAngleBracket(.root),
                    '&' => return ts.tokenizeContentEntityRef(),
                    else => todo("error.root_content_text_invalid", null),
                },
                
                .comment,
                .content_cdata,
                .content_entity_ref,
                => switch (utility.getByte(ts.src, ts.state.index) orelse switch (root) {
                    .comment => todo("error.root_content_comment_eof", null),
                    .content_cdata => todo("error.root_content_cdata_eof", null),
                    .content_entity_ref => todo("error.root_content_entityref_eof", null),
                    else => unreachable,
                }) {
                    '<' => return ts.tokenizeAfterLeftAngleBracket(.root),
                    '&' => return ts.tokenizeContentEntityRef(),
                    else => return ts.tokenizeContentTextOrWhitespace(),
                },
            }
        },
        
        .trailing => |trailing| {
            assert(ts.state.depth == 0);
            defer {
                assert(ts.state.depth == 0);
                assert(ts.state.mode == .trailing);
            }
            switch (trailing) {
                .whitespace => {
                    switch (utility.getByte(ts.src, ts.state.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => return ts.tokenizeAfterLeftAngleBracket(.trailing),
                        else => todo("error.trailing_whitespace_invalid", null),
                    }
                },
                
                .elem_close_tag,
                .elem_close_inline,
                => {
                    ts.sideEffectsAfterElementCloseTagOrInline(.trailing);
                    const start_index = ts.state.index;
                    
                    const whitespace_len = xml.whitespaceLength(ts.src, ts.state.index);
                    ts.state.index += whitespace_len;
                    if (whitespace_len != 0) {
                        return ts.returnToken(.trailing, .whitespace, .{ .beg = start_index, .end = ts.state.index });
                    }
                    
                    switch (utility.getByte(ts.src, ts.state.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => return ts.tokenizeAfterLeftAngleBracket(.trailing),
                        else => switch (trailing) {
                            .elem_close_tag =>  todo("error.trailing_elem_close_tag_invalid", null),
                            .elem_close_inline =>  todo("error.trailing_elem_close_inline_invalid", null),
                            else => unreachable,
                        },
                    }
                },
                
                .end => return @as(NextReturnType, null),
            }
        },
    }
}

fn sideEffectsAfterElementCloseTagOrInline(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) void {
    assert(ts.state.mode == state);
    assert(switch (state) {
        .prologue => false,
        .root => true,
        .trailing => true,
    });
    assert(switch (@field(ts.state.mode, @tagName(state))) {
        .elem_close_tag,
        .elem_close_inline,
        => true,
        else => false,
    });
    
    switch (@field(ts.state.mode, @tagName(state))) {
        .elem_close_tag => {
            ts.state.index += xml.whitespaceLength(ts.src, ts.state.index);
            const byte = utility.getByte(ts.src, ts.state.index) orelse switch (state) {
                .prologue => unreachable,
                .root => todo("error.root_unclosed_elem_close_tag_eof", null),
                .trailing => todo("error.trailing_unclosed_elem_close_tag_eof", null),
            };
            if (byte != '>') switch (state) {
                .prologue => unreachable,
                .root => todo("error.root_unclosed_elem_close_tag_invalid", null),
                .trailing => todo("error.trailing_unclosed_elem_close_tag_invalid", null),
            };
            ts.state.index += 1;
        },
        .elem_close_inline => {
            assert(utility.getByte(ts.src, ts.state.index - 1).? == '>');
            assert(utility.getByte(ts.src, ts.state.index - 2).? == '/');
        },
        else => unreachable,
    }
}

fn tokenizeAfterElementOpenOrAttributeValueEnd(ts: *TokenStream) NextReturnType {
    assert(ts.state.mode == .root);
    assert(switch (ts.state.mode.root) {
        .elem_open,
        .attr_val_empty,
        => true,
        
        .attr_val_segment_text,
        .attr_val_segment_entity_ref,
        => (ts.state.last_attr_quote == null),
        
        else => false,
    });
    const whitespace_len = xml.whitespaceLength(ts.src, ts.state.index);
    ts.state.index += whitespace_len;
    switch (utility.getByte(ts.src, ts.state.index) orelse todo("error.root_unclosed_elem_open_eof", null)) {
        '/' => return ts.tokenizeElementCloseInlineAfterForwardSlash(),
        '>' => {
            ts.state.index += 1;
            switch (utility.getByte(ts.src, ts.state.index) orelse todo("error.root_elem_open_eof", null)) {
                '<' => return ts.tokenizeAfterLeftAngleBracket(.root),
                '&' => return ts.tokenizeContentEntityRef(),
                else => return ts.tokenizeContentTextOrWhitespace(),
            }
        },
        else => {
            if (whitespace_len == 0) {
                todo("error.root_unclosed_elem_open_invalid", null);
            }
            
            const start_index = ts.state.index;
            const name_len = xml.validUtf8NameLength(ts.src, start_index);
            ts.state.index += name_len;
            if (name_len == 0) {
                todo("error.root_unclosed_elem_open_invalid", null);
            }
            return ts.returnToken(.root, .attr_name, .{ .beg = start_index, .end = ts.state.index });
        },
    }
}

fn tokenizeAttributeValueSegment(ts: *TokenStream) NextReturnType {
    assert(ts.state.last_attr_quote != null);
    assert(utility.getByte(ts.src, ts.state.index).? != ts.state.last_attr_quote.?.value());
    assert(ts.state.mode == .root);
    assert(switch (ts.state.mode.root) {
        .attr_name => true,
        .attr_val_segment_text => true,
        .attr_val_segment_entity_ref => true,
        else => false,
    });
    
    const start_index = ts.state.index;
    switch (utility.getByte(ts.src, start_index).?) {
        '&' => {
            ts.state.index += 1;
            const name_len = xml.validUtf8NameLength(ts.src, ts.state.index);
            ts.state.index += name_len;
            if (name_len == 0) {
                todo("error.root_unclosed_attr_val_ampersand_invalid", null);
            }
            
            if (utility.getByte(ts.src, ts.state.index) orelse todo("error.root_unclosed_attr_val_ampersand_name_eof", null) != ';') {
                todo("error.root_unclosed_attr_val_ampersand_name_invalid", null);
            }
            
            ts.state.index += 1;
            const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
            const tag = Token.Tag.attr_val_segment_entity_ref;
            return ts.returnToken(.root, tag, loc);
        },
        else => {
            while (utility.getUtf8(ts.src, ts.state.index)) |text_char| : (ts.state.index += utility.lenOfUtf8OrNull(text_char).?) {
                const should_break = (text_char == '&') or (text_char == ts.state.last_attr_quote.?.value());
                if (should_break) break;
            } else todo("Error for eof following unclosed attribute comment.", null);
            
            const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
            const tag = Token.Tag.attr_val_segment_text;
            return ts.returnToken(.root, tag, loc);
        },
    }
}

fn tokenizeContentTextOrWhitespace(ts: *TokenStream) NextReturnType {
    assert(ts.state.mode == .root);
    assert(switch (ts.state.mode.root) {
        .comment,
        .elem_open,
        .elem_close_tag,
        .elem_close_inline,
        .content_entity_ref,
        .content_cdata,
        .attr_val_segment_text,
        .attr_val_segment_entity_ref,
        .attr_val_empty,
        => true,
        else => false,
    });
    assert(switch (utility.getByte(ts.src, ts.state.index).?) {
        '&', '<' => false,
        else => true,
    });
    
    const start_index = ts.state.index;
    
    const all_whitespace = outerloop: while (utility.getByte(ts.src, ts.state.index)) |ws_char| : (ts.state.index += 1) {
        switch (ws_char) {
            '<',
            '&',
            => break :outerloop true,
            else => {
                if (xml.isSpace(ws_char)) {
                    continue :outerloop;
                }
                
                while (utility.getUtf8(ts.src, ts.state.index)) |non_ws_char| : (ts.state.index += utility.lenOfUtf8OrNull(non_ws_char).?) {
                    switch (non_ws_char) {
                        '<',
                        '&',
                        => break,
                        else => {
                            const disallowed_strings = [_][]const u8 {
                                "]]>",
                            };
                            
                            inline for (disallowed_strings) |disallowed_str| {
                                if (disallowed_str[0] == non_ws_char and mem.startsWith(u8, ts.src[ts.state.index + 1..], disallowed_str[1..])) {
                                    ts.state.index += disallowed_str.len;
                                    todo("Error for disallowed token '{s}' in content.", .{ disallowed_str });
                                }
                            }
                        },
                    }
                }
                
                break :outerloop false;
            }
        }
    } else true;
    
    const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
    const tag = if (all_whitespace) Token.Tag.whitespace else Token.Tag.content_text;
    return if (all_whitespace)
        ts.returnToken(.root, tag, loc)
    else
        ts.returnToken(.root, tag, loc);
}

fn tokenizeContentEntityRef(ts: *TokenStream) NextReturnType {
    assert(utility.getByte(ts.src, ts.state.index).? == '&');
    assert(ts.state.mode == .root);
    assert(switch (ts.state.mode.root) {
        .pi_target => false,
        .pi_tok_string => false,
        .pi_tok_other => false,
        .pi_end => true,
        
        .whitespace => true,
        .comment => true,
        
        .elem_open => true,
        .elem_close_tag => true,
        .elem_close_inline => true,
        
        .attr_name => false,
        .attr_val_empty => true,
        
        .attr_val_segment_text,
        .attr_val_segment_entity_ref,
        => (ts.state.last_attr_quote == null),
        
        .content_text => true,
        .content_cdata => true,
        .content_entity_ref => true,
    });
    
    const start_index = ts.state.index;
    ts.state.index += 1;
    
    const name_len = xml.validUtf8NameLength(ts.src, ts.state.index);
    ts.state.index += name_len;
    if (name_len == 0) {
        if (ts.state.index == ts.src.len) {
            todo("error.root_content_ampersand_eof", null);
        }
        todo("error.root_content_ampersand_invalid", null);
    }
    
    const sc = if (utility.getByte(ts.src, ts.state.index)) |char| char
    else todo("error.root_content_ampersand_name_eof", null);
    if (sc != ';') {
        todo("error.root_content_ampersand_name_invalid", null);
    }
    
    ts.state.index += 1;
    return ts.returnToken(.root, .content_entity_ref, .{ .beg = start_index, .end = ts.state.index });
}

fn tokenizePiTok(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) NextReturnType {
    assert(!xml.isSpace(utility.getByte(ts.src, ts.state.index).?));
    assert(ts.state.mode == state);
    const state_tag_name = @tagName(state);
    const active_mode = @field(ts.state.mode, state_tag_name);
    assert(switch (active_mode) {
        .pi_target,
        .pi_tok_other,
        .pi_tok_string,
        => true,
        else => false,
    });
    
    const start_index = ts.state.index;
    const start_byte: u8 = utility.getByte(ts.src, start_index) orelse switch (active_mode) {
        .pi_target => todo("error." ++ state_tag_name ++ "_pi_target_eof", null),
        .pi_tok_other => todo("error." ++ state_tag_name ++ "_pi_tok_other_eof", null),
        .pi_tok_string => todo("error." ++ state_tag_name ++ "_pi_tok_string_eof", null),
        else => unreachable,
    };
    if (start_byte == '?' and (utility.getByte(ts.src, ts.state.index + 1) orelse 0) == '>') {
        ts.state.index += 2;
        return ts.returnToken(state, .pi_end, .{ .beg = start_index, .end = ts.state.index });
    }
    
    if (xml.isStringQuote(start_byte)) {
        ts.state.index += 1;
        while (utility.getUtf8(ts.src, ts.state.index)) |str_char| : (ts.state.index += utility.lenOfUtf8OrNull(str_char).?) {
            if (str_char == start_byte) {
                ts.state.index += 1;
                break;
            }
        } else switch (active_mode) {
            .pi_target => todo("error." ++ state_tag_name ++ "_pi_target_unclosed_tok_string_eof", null),
            .pi_tok_other => todo("error." ++ state_tag_name ++ "_pi_tok_other_unclosed_tok_string_eof", null),
            .pi_tok_string => todo("error." ++ state_tag_name ++ "_pi_tok_string_unclosed_tok_string_eof", null),
            else => unreachable,
        }
        
        return ts.returnToken(state, .pi_tok_string, .{ .beg = start_index, .end = ts.state.index });
    }
    
    while (utility.getUtf8(ts.src, ts.state.index)) |pi_tok_char| : (ts.state.index += utility.lenOfUtf8OrNull(pi_tok_char).?) {
        const len = utility.lenOfUtf8OrNull(pi_tok_char).?;
        const is_byte = (len == 1);
        
        const is_space = is_byte and xml.isSpace(@intCast(u8, pi_tok_char));
        const is_string_quote = is_byte and xml.isStringQuote(@intCast(u8, pi_tok_char));
        const is_pi_end = (pi_tok_char == '?') and ((utility.getByte(ts.src, ts.state.index + 1) orelse 0) == '>');
        
        if (is_space or is_string_quote or is_pi_end) break;
    } else todo("Error for unclosed PI other token followed by eof.", null);
    
    return ts.returnToken(state, .pi_tok_other, .{ .beg = start_index, .end = ts.state.index });
}

fn tokenizeAfterPiEnd(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) NextReturnType {
    assert(state == ts.state.mode);
    assert(@field(ts.state.mode, @tagName(state)) == .pi_end);
    const start_index = ts.state.index;
    const start_byte = utility.getByte(ts.src, start_index) orelse return ts.returnNullSetTrailingEnd();
    switch (start_byte) {
        '<' => return ts.tokenizeAfterLeftAngleBracket(state),
        else => {
            const whitespace_len = xml.whitespaceLength(ts.src, start_index);
            ts.state.index += whitespace_len;
            if (whitespace_len == 0) {
                return todo("error." ++ @tagName(state) ++ "_pi_end_invalid", null);
            }
            return ts.returnToken(state, .whitespace, .{ .beg = start_index, .end = ts.state.index });
        },
    }
}

fn tokenizeAfterPiTokOther(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) NextReturnType {
    assert(state == ts.state.mode);
    assert(@field(ts.state.mode, @tagName(state)) == .pi_tok_other);
    ts.state.index += xml.whitespaceLength(ts.src, ts.state.index);
    return ts.tokenizePiTok(state);
}

fn tokenizeAfterPiTokString(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) NextReturnType {
    assert(state == ts.state.mode);
    assert(@field(ts.state.mode, @tagName(state)) == .pi_tok_string);
    ts.state.index += xml.whitespaceLength(ts.src, ts.state.index);
    return ts.tokenizePiTok(state);
}

fn tokenizeAfterPiTarget(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) NextReturnType {
    assert(state == ts.state.mode);
    assert(@field(ts.state.mode, @tagName(state)) == .pi_target);
    switch (utility.getByte(ts.src, ts.state.index) orelse todo("error." ++ @tagName(state) ++ "_unclosed_pi_target_eof", null)) {
        '?' => {
            const start_index = ts.state.index;
            ts.state.index += 1;
            if (utility.getByte(ts.src, ts.state.index) orelse todo("error." ++ @tagName(state) ++ "_unclosed_pi_target_questionmark_eof", null) == '>') {
                ts.state.index += 1;
                return ts.returnToken(state, .pi_end, .{ .beg = start_index, .end = ts.state.index });
            }
            todo("error." ++ @tagName(state) ++ "_unclosed_pi_target_questionmark_invalid", null);
        },
        else => {
            const whitespace_len = xml.whitespaceLength(ts.src, ts.state.index);
            if (whitespace_len == 0) {
                todo("error." ++ @tagName(state) ++ "_unclosed_pi_target_invalid", null);
            }
            ts.state.index += whitespace_len;
            return ts.tokenizePiTok(state);
        },
    }
}

fn tokenizeElementCloseInlineAfterForwardSlash(ts: *TokenStream) NextReturnType {
    assert(utility.getByte(ts.src, ts.state.index).? == '/');
    assert(ts.state.mode == .root);
    assert(ts.state.depth != 0);
    assert(switch (ts.state.mode.root) {
        .elem_open,
        .attr_val_empty,
        .attr_val_segment_text,
        .attr_val_segment_entity_ref,
        => true,
        else => false,
    });
    
    const start_index = ts.state.index;
    ts.state.index += 1;
    if (utility.getByte(ts.src, ts.state.index) orelse todo("Error for unclosed element open tag followed by '/' and then eof.", null) != '>') {
        todo("Error for unclosed element open tag followed by '/' and then '{c}'.", .{ utility.getByte(ts.src, ts.state.index).? });
    }
    
    ts.state.index += 1;
    const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
    const tag = Token.Tag.elem_close_inline;
    
    ts.state.depth -= 1;
    return if (ts.state.depth == 0)
        ts.returnToken(.trailing, tag, loc)
    else
        ts.returnToken(.root, tag, loc);
}

fn tokenizeAfterLeftAngleBracket(ts: *TokenStream, comptime state: meta.Tag(State.Mode)) NextReturnType {
    assert(utility.getByte(ts.src, ts.state.index).? == '<');
    assert(ts.state.mode == state);
    
    const start_index = ts.state.index;
    ts.state.index += 1;
    switch (utility.getByte(ts.src, ts.state.index) orelse todo("Error for left angle bracket followed by eof.", null)) {
        '?' => {
            ts.state.index += 1;
            const name_len = xml.validUtf8NameLength(ts.src, ts.state.index);
            if (name_len == 0) {
                todo("Error for lack of pi target name", null);
            }
            ts.state.index += name_len;
            return ts.returnToken(state, .pi_target, .{ .beg = start_index, .end = ts.state.index });
        },
        '!' => {
            ts.state.index += 1;
            return switch (utility.getByte(ts.src, ts.state.index) orelse todo("Eof after '<!'.", null)) {
                '-' => dash_blk: {
                    ts.state.index += 1;
                    break :dash_blk switch (utility.getByte(ts.src, ts.state.index) orelse todo("Error for eof after '<!-'.", null)) {
                        '-' => dash_dash_blk: {
                            ts.state.index += 1;
                            while (utility.getUtf8(ts.src, ts.state.index)) |comment_char| : (ts.state.index += utility.lenOfUtf8OrNull(comment_char).?) {
                                if (comment_char != '-') continue;
                                
                                ts.state.index += 1;
                                if (utility.getByte(ts.src, ts.state.index) orelse 0 != '-') continue;
                                
                                ts.state.index += 1;
                                if (utility.getByte(ts.src, ts.state.index) orelse 0 != '>') continue;
                                
                                ts.state.index += 1;
                                break :dash_dash_blk ts.returnToken(state, .comment, .{ .beg = start_index, .end = ts.state.index });
                            } else break :dash_dash_blk todo("Error for unclosed comment followed by eof or invalid UTF8.", null);
                        },
                        else => todo("Error for '<!-{c}'", .{ utility.getByte(ts.src, ts.state.index) }),
                    };
                },
                
                '[' => switch (state) {
                    .prologue => return todo("Error for '<![' in prologue.", null),
                    .root => {
                        ts.state.index += 1;
                        const expected_chars = "CDATA[";
                        if (!mem.startsWith(u8, ts.src[math.clamp(ts.state.index, 0, ts.src.len)..], expected_chars)) {
                            ts.state.index = math.clamp(ts.state.index + expected_chars.len, 0, ts.src.len);
                            todo("Error for invalid characters after '<![', when '<![CDATA[' was expected.", null);
                        }
                        ts.state.index += expected_chars.len;
                        
                        while (utility.getUtf8(ts.src, ts.state.index)) |cdata_char| : (ts.state.index += utility.lenOfUtf8OrNull(cdata_char).?) {
                            if (cdata_char != ']') continue;
                            
                            const next_char0 = utility.getByte(ts.src, ts.state.index + "]".len) orelse continue;
                            if (next_char0 != ']') continue;
                            
                            const next_char1 = utility.getByte(ts.src, ts.state.index + "]]".len) orelse continue;
                            if (next_char1 != '>') continue;
                            
                            ts.state.index += "]]>".len;
                            return ts.returnToken(.root, .content_cdata, .{ .beg = start_index, .end = ts.state.index });
                            
                        } else return todo("Error unclosed CDATA section followed by eof or invalid.", null);
                    },
                    .trailing => todo("Error for '<![' in trailing section.", null),
                },
                
                'D' => {
                    ts.state.index += 1;
                    if (mem.startsWith(u8, ts.src[ts.state.index..], "OCTYPE")) {
                        switch (state) {
                            .prologue => {
                                ts.state.index += "OCTYPE".len;
                                todo("Error for unsupported '<!DOCTYPE'.", null);
                            },
                            .root => todo("Error for '<!DOCTYPE' in root.", null),
                            .trailing => todo("Error for '<!DOCTYPE' in trailing section.", null),
                        }
                    } else {
                        const invalid_start = ts.state.index - 1;
                        ts.state.index = math.clamp(ts.state.index + "OCTYPE".len, 0, ts.src.len);
                        todo("Error for invalid '<!{s}'.", .{ ts.src[invalid_start..ts.state.index] });
                    }
                },
                
                else => todo("Error for '<!{c}'.", .{ utility.getByte(ts.src, ts.state.index).? }),
            };
        },
        '/' => switch (state) {
            .prologue => return todo("Error for '</' in prologue.", null),
            .trailing => todo("Error for element close tag start in trailing section.", null),
            .root => {
                ts.state.index += 1;
                const name_len = xml.validUtf8NameLength(ts.src, ts.state.index);
                ts.state.index += name_len;
                if (name_len == 0) {
                    todo("Error for no name following '</'.", null);
                }
                const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
                const tag = .elem_close_tag;
                
                assert(ts.state.depth > 0);
                ts.state.depth -= 1;
                return if (ts.state.depth == 0) ts.returnToken(.trailing, tag, loc) else ts.returnToken(.root, tag, loc);
            },
        },
        else => switch (state) {
            .trailing => todo("Error for element open tag start in trailing section.", null),
            .prologue,
            .root,
            => {
                const name_len = xml.validUtf8NameLength(ts.src, ts.state.index);
                ts.state.index += name_len;
                if (name_len == 0) {
                    todo("Error for no name following '<'.", null);
                }
                const loc = Token.Loc { .beg = start_index, .end = ts.state.index };
                const tag = .elem_open;
                switch (state) {
                    .trailing => @compileError("unreachable"),
                    .prologue => {
                        ts.state.depth += 1;
                        assert(ts.state.depth == 1);
                        return ts.returnToken(.root, tag, loc);
                    },
                    .root => {
                        assert(ts.state.depth != 0);
                        ts.state.depth += 1;
                        return ts.returnToken(.root, tag, loc);
                    },
                }
            },
        },
    }
}



fn returnNullSetTrailingEnd(ts: *TokenStream) NextReturnType {
    ts.state.mode = .{ .trailing = .end };
    return null;
}



fn returnToken(ts: *TokenStream, comptime set_state: meta.Tag(State.Mode), tag: Token.Tag, loc: Token.Loc) Result {
    assert(switch (set_state) {
        .prologue => switch (ts.state.mode) { .prologue => true, else => false },
        .root => switch (ts.state.mode) { .prologue, .root => true, else => false },
        .trailing => switch (ts.state.mode) { else => true },
    });
    ts.state.mode = @unionInit(
        State.Mode,
        @tagName(set_state),
        meta.stringToEnum(
            meta.TagPayload(State.Mode, set_state),
            @tagName(tag),
        ) orelse debug.panic("'{s}' has no field '{s}'.", .{@typeName(meta.TagPayload(State.Mode, set_state)), @tagName(tag)}),
    );
    return Result.initToken(tag, loc);
}

const constraint = struct {
    
    const ModesEnabledArray = std.enums.EnumArray(meta.Tag(State.Mode), bool);
    fn modeIsOneOf(ts: *TokenStream, comptime modes: ModesEnabledArray) bool {
        comptime var iterator = modes.iterator();
        while (iterator.next()) |entry| {
            if (entry.key == ts.state.mode) {
                return entry.value;
            }
        }
        unreachable;
    }
    
};

const State = struct {
    index: usize,
    depth: usize,
    mode: Mode = .{ .prologue = .start },
    last_attr_quote: ?xml.StringQuote,
    
    const Mode = union(enum) {
        prologue: Prologue,
        root: Root,
        trailing: Trailing,
        
        /// Use this to ensure that a given enum field of `Mode` only has fields found within `Token.Tag`,
        /// save for given 'exceptions'.
        fn assertSimilarToTokenTag(comptime T: type, comptime exceptions: []const T) void {
            const diff = utility.fieldNamesDiff(Token.Tag, T);
            outerloop: inline for (diff.b) |actual| {
                inline for (exceptions) |exempted| {
                    if (mem.eql(u8, actual, @tagName(exempted))) {
                        continue :outerloop;
                    }
                }
                @compileError(std.fmt.comptimePrint("Field '{s}' in '{s}' has not been exempted.", .{actual, @typeName(T)}));
            }
        }
        
        const Prologue = enum {
            start,
            whitespace,
            pi_target,
            pi_tok_string,
            pi_tok_other,
            pi_end,
            comment,
            
            comptime {
                @setEvalBranchQuota(2000);
                assertSimilarToTokenTag(@This(), &.{ .start });
            }
        };
        
        const Root = enum {
            pi_target,
            pi_tok_string,
            pi_tok_other,
            pi_end,
            
            whitespace,
            comment,
            
            elem_open,
            elem_close_tag,
            elem_close_inline,
            
            attr_name,
            attr_val_empty,
            attr_val_segment_text,
            attr_val_segment_entity_ref,
            
            content_text,
            content_cdata,
            content_entity_ref,
            
            comptime {
                @setEvalBranchQuota(2000);
                assertSimilarToTokenTag(@This(), &.{});
            }
        };
        
        const Trailing = enum {
            whitespace,
            elem_close_tag,
            elem_close_inline,
            end,
            
            comptime {
                assertSimilarToTokenTag(@This(), &.{ .end });
            }
        };
    };
};



pub const tests = struct {
    const UnwrapNextErr = (error{ NullToken } || Result.Error);
    fn unwrapNext(result: NextReturnType) UnwrapNextErr!Token {
        const unwrapped = result orelse return error.NullToken;
        return unwrapped.getToken();
    }
    
    pub fn expectPiTarget(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectPiTarget(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectPiTokOther(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectPiTokOther(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectPiTokString(ts: *TokenStream, expected_data: []const u8, quote_type: xml.StringQuote) !void {
        try Token.tests.expectPiTokString(ts.src, try unwrapNext(ts.next()), expected_data, quote_type);
    }
    
    pub fn expectPiEnd(ts: *TokenStream) !void {
        try Token.tests.expectPiEnd(ts.src, try unwrapNext(ts.next()));
    }
    
    pub fn expectWhitespace(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectWhitespace(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectComment(ts: *TokenStream, expected_data: []const u8) !void {
        try Token.tests.expectComment(ts.src, try unwrapNext(ts.next()), expected_data);
    }
    
    pub fn expectElemOpen(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectElemOpen(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectElemCloseTag(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectElemCloseTag(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectElemCloseInline(ts: *TokenStream) !void {
        try Token.tests.expectElemCloseInline(ts.src, try unwrapNext(ts.next()));
    }
    
    pub fn expectAttrName(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectAttrName(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectAttrValEmpty(ts: *TokenStream) !void {
        try Token.tests.expectAttrValEmpty(ts.src, try unwrapNext(ts.next()));
    }
    
    pub fn expectAttrValSegmentText(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectAttrValSegmentText(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectAttrValSegmentEntityRef(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectAttrValSegmentEntityRef(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectContentText(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectContentText(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectContentCData(ts: *TokenStream, expected_data: []const u8) !void {
        try Token.tests.expectContentCData(ts.src, try unwrapNext(ts.next()), expected_data);
    }
    
    pub fn expectContentEntityRef(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectContentEntityRef(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectError(ts: *TokenStream, err: Result.Error) !void {
        const result: Result = try (ts.next() orelse error.NullToken);
        try testing.expectError(err, result.getToken());
    }
    
    pub fn expectNull(ts: *TokenStream) !void {
        try testing.expectEqual(@as(NextReturnType, null), ts.next());
    }
};


test "TokenStream empty source" {
    var ts = TokenStream.init("");
    try tests.expectNull(&ts);
}

test "TokenStream whitespace only" {
    const whitespace = " \t\n\r";
    var ts = TokenStream.init(whitespace);
    try tests.expectWhitespace(&ts, whitespace);
    try tests.expectNull(&ts);
}

test "TokenStream prologue comment" {
    var ts: TokenStream = undefined;
    const data_samples = .{ (""), ("- "), (" foo bar baz") };
    const whitespace_samples = .{ (""), (" \t\n\r") };
    inline for (data_samples) |data| {
        ts.reset("<!--" ++ data ++ "-->");
        try tests.expectComment(&ts, data);
        try tests.expectNull(&ts);
        
        inline for (whitespace_samples) |whitespace_a| {
            inline for (whitespace_samples) |whitespace_b| {
                ts.reset(whitespace_a ++ "<!--" ++ data ++ "-->" ++ whitespace_b);
                if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                try tests.expectComment(&ts, data);
                if (whitespace_b.len != 0) try tests.expectWhitespace(&ts, whitespace_b);
                try tests.expectNull(&ts);
                
                
                inline for (whitespace_samples) |whitespace_c| {
                    inline for (data_samples) |data2| {
                        const comment1 = "<!--" ++ data ++ "-->";
                        const comment2 = "<!--" ++ data2 ++ "-->";
                        ts.reset(whitespace_a ++ comment1 ++ whitespace_b ++ comment2 ++ whitespace_c);
                        if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                        try tests.expectComment(&ts, data);
                        if (whitespace_b.len != 0) try tests.expectWhitespace(&ts, whitespace_b);
                        try tests.expectComment(&ts, data2);
                        if (whitespace_c.len != 0) try tests.expectWhitespace(&ts, whitespace_c);
                        try tests.expectNull(&ts);
                    }
                }
            }
        }
    }
}

test "TokenStream prologue processing instructions" {
    var ts: TokenStream = undefined;
    const target_samples = [_][]const u8 { ("foo"), ("A") };
    const whitespace_samples = [_][]const u8 { (""), (" "), (" \t\n\r") };
    const non_name_token_samples = [_][]const u8 { ("?"), ("&;") };
    const string_quotes = comptime string_quotes: {
        var blk_out: [xml.string_quotes.len]*const [1]u8 = undefined;
        for (xml.string_quotes) |string_quote, idx|
            blk_out[idx] = &[_] u8 { string_quote };
        break :string_quotes blk_out;
    };
    
    inline for (target_samples) |target| {
        inline for (whitespace_samples) |whitespace_ignored| {
            ts.reset("<?" ++ target ++ whitespace_ignored ++ "?>");
            try tests.expectPiTarget(&ts, target);
            try tests.expectPiEnd(&ts);
            try tests.expectNull(&ts);
        }
        
        inline for (whitespace_samples) |whitespace_a| {
            inline for (whitespace_samples) |whitespace_ignored| {
                inline for (whitespace_samples) |whitespace_c| {
                    ts.reset(whitespace_a ++ "<?" ++ target ++ whitespace_ignored ++ "?>" ++ whitespace_c);
                    if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                    try tests.expectPiTarget(&ts, target);
                    try tests.expectPiEnd(&ts);
                    if (whitespace_c.len != 0) try tests.expectWhitespace(&ts, whitespace_c);
                    try tests.expectNull(&ts);
                }
            }
        }
        
        inline for (whitespace_samples[1..]) |whitespace_obligatory| { // must exclude first element, which is an empty string; here, we require a whitespace always.
            inline for (whitespace_samples) |whitespace_ignored| {
                inline for (non_name_token_samples) |non_name_token| {
                    ts.reset("<?" ++ target ++ whitespace_obligatory ++ non_name_token ++ whitespace_ignored ++ "?>");
                    try tests.expectPiTarget(&ts, target);
                    try tests.expectPiTokOther(&ts, non_name_token);
                    try tests.expectPiEnd(&ts);
                    try tests.expectNull(&ts);
                    
                    inline for (string_quotes) |string_quote| {
                        const quote_type = comptime xml.StringQuote.from(string_quote[0]);
                        inline for (string_quotes) |other_string_quote| {
                            const other_quote_type = comptime xml.StringQuote.from(other_string_quote[0]);
                            comptime if (quote_type == other_quote_type) continue;
                            inline for ([_][]const u8 {
                                (other_string_quote ++ "bar" ++ other_string_quote),
                                (other_string_quote ** 2),
                                (other_string_quote),
                                ("foo"),
                                (""),
                            } ++ non_name_token_samples) |data| {
                                @setEvalBranchQuota(2000);
                                ts.reset("<?" ++ target ++ whitespace_obligatory ++ string_quote ++ data ++ string_quote ++ whitespace_ignored ++ "?>");
                                try tests.expectPiTarget(&ts, target);
                                try tests.expectPiTokString(&ts, data, quote_type);
                                try tests.expectPiEnd(&ts);
                                try tests.expectNull(&ts);
                            }
                        }
                    }
                }
                
                inline for (string_quotes) |string_quote| {
                    const quote_type = comptime xml.StringQuote.from(string_quote[0]);
                    ts.reset(
                        "<?"
                        ++ target
                        ++ whitespace_obligatory ++ "foo"
                        ++ whitespace_obligatory ++ "="
                        ++ whitespace_ignored ++ string_quote ++ "bar" ++ string_quote
                        ++ whitespace_ignored
                        ++ "?>"
                    );
                    try tests.expectPiTarget(&ts, target);
                    try tests.expectPiTokOther(&ts, "foo");
                    try tests.expectPiTokOther(&ts, "=");
                    try tests.expectPiTokString(&ts, "bar", quote_type);
                    try tests.expectPiEnd(&ts);
                    try tests.expectNull(&ts);
                }
            }
        }
        
    }
}

test "TokenStream empty element" {
    var ts: TokenStream = undefined;
    const whitespace_samples = [_][]const u8 { (""), (" "), ("\t"), ("\n"), ("\r"), (" \t\n\r") };
    inline for (whitespace_samples) |whitespace_a| {
        inline for (whitespace_samples) |whitespace_b| {
            inline for (whitespace_samples) |whitespace_ignored_a| {
                ts.reset(whitespace_a ++ "<foo" ++ whitespace_ignored_a ++ "/>" ++ whitespace_b);
                if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                try tests.expectElemOpen(&ts, "foo");
                try tests.expectElemCloseInline(&ts);
                if (whitespace_b.len != 0) try tests.expectWhitespace(&ts, whitespace_b);
                try tests.expectNull(&ts);
            
                inline for (whitespace_samples) |whitespace_ignored_b| {
                    @setEvalBranchQuota(16000);
                    const ws_a = whitespace_a;
                    const ws_b = whitespace_b;
                    const ws_ign_a = whitespace_ignored_a;
                    const ws_ign_b = whitespace_ignored_b;
                    
                    ts.reset(ws_a ++ "<foo" ++ ws_ign_a ++ "></foo" ++ ws_ign_b ++ ">" ++ ws_b);
                    if (ws_a.len != 0) try tests.expectWhitespace(&ts, ws_a);
                    try tests.expectElemOpen(&ts, "foo");
                    try tests.expectElemCloseTag(&ts, "foo");
                    if (ws_b.len != 0) try tests.expectWhitespace(&ts, ws_b);
                }
            }
        }
    }
    
    // Note that ':' is tokenized as a name token
    ts.reset("<:/>");
    try tests.expectElemOpen(&ts, ":");
    try tests.expectElemCloseInline(&ts);
    try tests.expectNull(&ts);
}

test "TokenStream element with content" {
    var ts: TokenStream = undefined;
    
    ts.reset("<a>foo</a>");
    try tests.expectElemOpen(&ts, "a");
    try tests.expectContentText(&ts, "foo");
    try tests.expectElemCloseTag(&ts, "a");
    try tests.expectNull(&ts);
    
    ts.reset("<b> bar </b>");
    try tests.expectElemOpen(&ts, "b");
    try tests.expectContentText(&ts, " bar ");
    try tests.expectElemCloseTag(&ts, "b");
    try tests.expectNull(&ts);
    
    ts.reset("<c>&baz;</c>");
    try tests.expectElemOpen(&ts, "c");
    try tests.expectContentEntityRef(&ts, "baz");
    try tests.expectElemCloseTag(&ts, "c");
    try tests.expectNull(&ts);
    
    ts.reset("<d>\n&fee;\n</d>");
    try tests.expectElemOpen(&ts, "d");
    try tests.expectWhitespace(&ts, "\n");
    try tests.expectContentEntityRef(&ts, "fee");
    try tests.expectWhitespace(&ts, "\n");
    try tests.expectElemCloseTag(&ts, "d");
    try tests.expectNull(&ts);
    
    ts.reset("<e>zig&phi; zag </e>");
    try tests.expectElemOpen(&ts, "e");
    try tests.expectContentText(&ts, "zig");
    try tests.expectContentEntityRef(&ts, "phi");
    try tests.expectContentText(&ts, " zag ");
    try tests.expectElemCloseTag(&ts, "e");
    try tests.expectNull(&ts);
    
    ts.reset("<g>&fo;&knack;&fum;</g>");
    try tests.expectElemOpen(&ts, "g");
    try tests.expectContentEntityRef(&ts, "fo");
    try tests.expectContentEntityRef(&ts, "knack");
    try tests.expectContentEntityRef(&ts, "fum");
    try tests.expectElemCloseTag(&ts, "g");
    try tests.expectNull(&ts);
}

test "TokenStream root processing instructions" {
    var ts = TokenStream.init(undefined);
    
    ts.reset("<A><?foo?></A>");
    try tests.expectElemOpen(&ts, "A");
    try tests.expectPiTarget(&ts, "foo");
    try tests.expectPiEnd(&ts);
    try tests.expectElemCloseTag(&ts, "A");
    try tests.expectNull(&ts);
}

test "TokenStream element attribute" {
    var ts: TokenStream = undefined;
    
    ts.reset("<foo bar='baz'/>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValSegmentText(&ts, "baz");
    try tests.expectElemCloseInline(&ts);
    try tests.expectNull(&ts);
    
    const whitespace_samples = [_][]const u8 { "", " ", " \t\n\r" };
    const text_samples = [_][]const u8 { "foo ?? bar", " " };
    const name_samples = [_][]const u8 { ("foo"), ("a"), ("A0"), ("SHI:FOO") };
    const quote_strings: [xml.string_quotes.len]*const [1]u8 = comptime quote_strings: {
        var blk_result: [xml.string_quotes.len]*const [1]u8 = undefined;
        for (blk_result) |*out, idx| {
            out.* = &[_]u8 { xml.string_quotes[idx] };
        }
        break :quote_strings blk_result;
    };
    
    const ElemCloseInfo = union(enum) {
        Inline,
        Tag: struct { name: []const u8 },
        
        fn string(
            comptime elem_close_info: @This(),
            comptime ignored_whitespace: ?[]const u8,
            comptime inner_content: ?[]const u8,
        ) []const u8 {
            return switch (elem_close_info) {
                .Inline => (ignored_whitespace orelse "") ++ "/>",
                .Tag => |tag| ">"
                ++ (inner_content orelse "") ++
                "</" ++ tag.name ++ (ignored_whitespace orelse "") ++ ">",
            };
        }
        
        fn expect(elem_close_info: @This(), tkstrm: *TokenStream) !void {
            try switch (elem_close_info) {
                .Inline => tests.expectElemCloseInline(tkstrm),
                .Tag => |tag| tests.expectElemCloseTag(tkstrm, tag.name),
            };
        }
    };
    
    inline for ([meta.fields(ElemCloseInfo).len]ElemCloseInfo {
        .Inline,
        .{ .Tag = .{ .name = "foo" } },
    }) |elem_close_info| {
    @setEvalBranchQuota(10_000);
        inline for (quote_strings) |quote| {
            inline for (whitespace_samples) |ws_a| {
                inline for (whitespace_samples) |ws_b| {
                    inline for (whitespace_samples) |ws_c| {
                        inline for (whitespace_samples) |ws_d| {
                            ts.reset("<foo bar" ++ ws_a ++ "=" ++ ws_b ++ quote ++ quote ++ ws_c ++ elem_close_info.string(ws_d, null));
                            try tests.expectElemOpen(&ts, "foo");
                            try tests.expectAttrName(&ts, "bar");
                            try tests.expectAttrValEmpty(&ts);
                            try elem_close_info.expect(&ts);
                            try tests.expectNull(&ts);
                            
                            inline for (text_samples) |text_data| {
                                ts.reset("<foo bar" ++ ws_a ++ "=" ++ ws_b ++ quote ++ text_data ++ quote ++ ws_c ++ elem_close_info.string(ws_a, null));
                                try tests.expectElemOpen(&ts, "foo");
                                try tests.expectAttrName(&ts, "bar");
                                try tests.expectAttrValSegmentText(&ts, text_data);
                                try elem_close_info.expect(&ts);
                                try tests.expectNull(&ts);
                            }
                            
                            inline for (name_samples) |entref_name| {
                                ts.reset("<foo bar" ++ ws_a ++ "=" ++ ws_b ++ quote ++ "&" ++ entref_name ++ ";" ++ quote ++ ws_c ++ elem_close_info.string(ws_a, null));
                                try tests.expectElemOpen(&ts, "foo");
                                try tests.expectAttrName(&ts, "bar");
                                try tests.expectAttrValSegmentEntityRef(&ts, entref_name);
                                try elem_close_info.expect(&ts);
                                try tests.expectNull(&ts);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "TokenStream element attribute followed by content" {
    var ts: TokenStream = undefined;
    
    ts.reset("<foo bar = ''> fee phi fo fum </foo>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValEmpty(&ts);
    try tests.expectContentText(&ts, " fee phi fo fum ");
    try tests.expectElemCloseTag(&ts, "foo");
    try tests.expectNull(&ts);
    
    ts.reset("<foo bar = 'baz'> fee phi fo fum </foo>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValSegmentText(&ts, "baz");
    try tests.expectContentText(&ts, " fee phi fo fum ");
    try tests.expectElemCloseTag(&ts, "foo");
    try tests.expectNull(&ts);
    
    ts.reset("<foo bar = '&baz;'> fee phi fo fum </foo>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValSegmentEntityRef(&ts, "baz");
    try tests.expectContentText(&ts, " fee phi fo fum ");
    try tests.expectElemCloseTag(&ts, "foo");
    try tests.expectNull(&ts);
    
    
    
    ts.reset("<foo bar = ''>&lorem-ipsum;</foo>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValEmpty(&ts);
    try tests.expectContentEntityRef(&ts, "lorem-ipsum");
    try tests.expectElemCloseTag(&ts, "foo");
    try tests.expectNull(&ts);
    
    ts.reset("<foo bar = 'baz'>&lorem-ipsum;</foo>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValSegmentText(&ts, "baz");
    try tests.expectContentEntityRef(&ts, "lorem-ipsum");
    try tests.expectElemCloseTag(&ts, "foo");
    try tests.expectNull(&ts);
    
    ts.reset("<foo bar = '&baz;'>&lorem-ipsum;</foo>");
    try tests.expectElemOpen(&ts, "foo");
    try tests.expectAttrName(&ts, "bar");
    try tests.expectAttrValSegmentEntityRef(&ts, "baz");
    try tests.expectContentEntityRef(&ts, "lorem-ipsum");
    try tests.expectElemCloseTag(&ts, "foo");
    try tests.expectNull(&ts);
}

test "TokenStream depth awareness" {
    var ts: TokenStream = undefined;
    
    ts.reset("<a><b><c/></b></a>");
    try tests.expectElemOpen(&ts, "a");
    try tests.expectElemOpen(&ts, "b");
    try tests.expectElemOpen(&ts, "c");
    
    try tests.expectElemCloseInline(&ts);
    try tests.expectElemCloseTag(&ts, "b");
    try tests.expectElemCloseTag(&ts, "a");
    
    try tests.expectNull(&ts);
    
    // Note: not context-aware; only aware of depth.
    ts.reset("<a><b></a></b>");
    try tests.expectElemOpen(&ts, "a");
    try tests.expectElemOpen(&ts, "b");
    try tests.expectElemCloseTag(&ts, "a");
    try tests.expectElemCloseTag(&ts, "b");
    
    try tests.expectNull(&ts);
}

test "TokenStream CDATA Sections" {
    var ts: TokenStream = undefined;
    
    const char_data_samples = [_][]const u8 { (""), ("["), ("[["), ("]"), ("]]"), ("]>"), ("] ]>"), ("]]]"), (" foo??bar??baz ") };
    const whitespace_samples = [_][]const u8 { (""), (" "), ("\t"), ("\n"), ("\r"), (" \t\n\r") };
    const name_samples = [_][]const u8 { (""), ("foo"), ("a"), ("A0"), ("SHI:FOO"), };
    
    inline for (char_data_samples) |data| {
        @setEvalBranchQuota(6000);
        
        ts.reset("<root>" ++ "<![CDATA[" ++ data ++ "]]>" ++ "</root>");
        try tests.expectElemOpen(&ts, "root");
        try tests.expectContentCData(&ts, data);
        try tests.expectElemCloseTag(&ts, "root");
        try tests.expectNull(&ts);
        
        inline for (whitespace_samples) |ws_a| {
            inline for (whitespace_samples) |ws_b| {
                ts.reset("<root>" ++ ws_a ++ "<![CDATA[" ++ data ++ "]]>" ++ ws_b ++ "</root>");
                try tests.expectElemOpen(&ts, "root");
                if (ws_a.len != 0) try tests.expectWhitespace(&ts, ws_a);
                try tests.expectContentCData(&ts, data);
                if (ws_b.len != 0) try tests.expectWhitespace(&ts, ws_b);
                try tests.expectElemCloseTag(&ts, "root");
                try tests.expectNull(&ts);
            }
        }
        
        inline for (char_data_samples) |text_data_a| {
            inline for (char_data_samples) |text_data_b| {
                ts.reset("<root>" ++ text_data_a ++ "<![CDATA[" ++ data ++ "]]>" ++ text_data_b ++ "</root>");
                try tests.expectElemOpen(&ts, "root");
                if (text_data_a.len != 0) try tests.expectContentText(&ts, text_data_a);
                try tests.expectContentCData(&ts, data);
                if (text_data_b.len != 0) try tests.expectContentText(&ts, text_data_b);
                try tests.expectElemCloseTag(&ts, "root");
                try tests.expectNull(&ts);
            }
        }
        
        inline for (name_samples) |name_a| {
            inline for (name_samples) |name_b| {
                const entref_a: []const u8 = if (name_a.len != 0) "&" ++ name_a ++ ";" else "";
                const entref_b: []const u8 = if (name_b.len != 0) "&" ++ name_b ++ ";" else "";
                ts.reset("<root>" ++ entref_a ++ "<![CDATA[" ++ data ++ "]]>" ++ entref_b ++ "</root>");
                try tests.expectElemOpen(&ts, "root");
                if (name_a.len != 0) try tests.expectContentEntityRef(&ts, name_a);
                try tests.expectContentCData(&ts, data);
                if (name_b.len != 0) try tests.expectContentEntityRef(&ts, name_b);
                try tests.expectElemCloseTag(&ts, "root");
                try tests.expectNull(&ts);
            }
        }
    }
}

test "TokenStream root comment" {
    var ts: TokenStream = undefined;
    
    const text_samples = [_][]const u8 { (""), ("foo bar baz") };
    const data_samples = [_][]const u8 { (""), (" "), ("- "), (" -> "), (" foo bar baz ") };
    const whitespace_samples = [_][]const u8 { (""), (" "), ("\t"), ("\n"), ("\r"), (" \t\n\r") };
    const name_samples = [_][]const u8 { (""), ("foo"), ("a"), ("A0"), ("SHI:FOO"), };
    
    inline for (data_samples) |data| {
        @setEvalBranchQuota(6000);
        
        ts.reset("<root>" ++ "<!--" ++ data ++ "-->" ++ "</root>");
        try tests.expectElemOpen(&ts, "root");
        try tests.expectComment(&ts, data);
        try tests.expectElemCloseTag(&ts, "root");
        try tests.expectNull(&ts);
        
        inline for (whitespace_samples) |ws_a| {
            inline for (whitespace_samples) |ws_b| {
                ts.reset("<root>" ++ ws_a ++ "<!--" ++ data ++ "-->" ++ ws_b ++ "</root>");
                try tests.expectElemOpen(&ts, "root");
                if (ws_a.len != 0) try tests.expectWhitespace(&ts, ws_a);
                try tests.expectComment(&ts, data);
                if (ws_b.len != 0) try tests.expectWhitespace(&ts, ws_b);
                try tests.expectElemCloseTag(&ts, "root");
                try tests.expectNull(&ts);
            }
        }
        
        inline for (text_samples) |text_data_a| {
            inline for (text_samples) |text_data_b| {
                ts.reset("<root>" ++ text_data_a ++ "<!--" ++ data ++ "-->" ++ text_data_b ++ "</root>");
                try tests.expectElemOpen(&ts, "root");
                if (text_data_a.len != 0) try tests.expectContentText(&ts, text_data_a);
                try tests.expectComment(&ts, data);
                if (text_data_b.len != 0) try tests.expectContentText(&ts, text_data_b);
                try tests.expectElemCloseTag(&ts, "root");
                try tests.expectNull(&ts);
            }
        }
        
        inline for (name_samples) |name_a| {
            inline for (name_samples) |name_b| {
                const entref_a: []const u8 = if (name_a.len != 0) "&" ++ name_a ++ ";" else "";
                const entref_b: []const u8 = if (name_b.len != 0) "&" ++ name_b ++ ";" else "";
                ts.reset("<root>" ++ entref_a ++ "<!--" ++ data ++ "-->" ++ entref_b ++ "</root>");
                try tests.expectElemOpen(&ts, "root");
                if (name_a.len != 0) try tests.expectContentEntityRef(&ts, name_a);
                try tests.expectComment(&ts, data);
                if (name_b.len != 0) try tests.expectContentEntityRef(&ts, name_b);
                try tests.expectElemCloseTag(&ts, "root");
                try tests.expectNull(&ts);
            }
        }
    }
}

test "TokenStream prologue invalids" {
    // var ts: TokenStream = undefined;
    
    // ts.reset("a");
    // try tests.expectError(&ts, error.character_in_prologue);
    // try tests.expectNull(&ts);
    // 
    // ts.reset(" b");
    // try tests.expectWhitespace(&ts, " ");
    // try tests.expectError(&ts, error.character_in_prologue);
    // try tests.expectNull(&ts);
    // 
    // ts.reset("<!-- -->c");
    // try tests.expectComment(&ts, " ");
    // try tests.expectError(&ts, error.character_in_prologue);
    // try tests.expectNull(&ts);
    // 
    // ts.reset("<?foo?>d");
    // try tests.expectPiTarget(&ts, "foo");
    // try tests.expectPiEnd(&ts);
    // try tests.expectError(&ts, error.character_in_prologue);
    // try tests.expectNull(&ts);
    // 
    // ts.reset("<![");
    // try tests.expectError(&ts, error.markup_in_prologue);
    // try tests.expectNull(&ts);
    // 
    // ts.reset("</");
    // try tests.expectError(&ts, error.markup_in_prologue);
    // try tests.expectNull(&ts);
}
